//! Remote process access and DLL injection, even across bitness.

const std = @import("std");

const inject = @import("../root.zig");
const win = @import("tuft_sys").win;
const Memory = @import("tuft_mem").Memory;
const Symbols = @import("tuft_mem").Symbols;

const log = std.log.scoped(.tuft_inject);

const Arch = inject.Arch;

const remote_thread_timeout_ms: u32 = 30_000;

pub fn currentPid() u32 {
    return win.GetCurrentProcessId();
}

pub fn findPid(name: []const u8) !u32 {
    const snapshot = win.CreateToolhelp32Snapshot(win.TH32CS_SNAPPROCESS, 0);
    if (snapshot == win.INVALID_HANDLE_VALUE) return error.SnapshotFailed;
    defer win.CloseHandle(snapshot);

    var entry: win.PROCESSENTRY32W = .{};
    if (win.Process32FirstW(snapshot, &entry) == .FALSE) return error.ProcessNotFound;
    while (true) {
        if (nameEquals(&entry.szExeFile, name)) return entry.th32ProcessID;
        if (win.Process32NextW(snapshot, &entry) == .FALSE) break;
    }
    return error.ProcessNotFound;
}

/// Any case. Fills at most `out.len`.
pub fn pidsNamed(name: []const u8, out: []u32) ![]u32 {
    const snapshot = win.CreateToolhelp32Snapshot(win.TH32CS_SNAPPROCESS, 0);
    if (snapshot == win.INVALID_HANDLE_VALUE) return error.SnapshotFailed;
    defer win.CloseHandle(snapshot);

    var n: usize = 0;
    var entry: win.PROCESSENTRY32W = .{};
    if (win.Process32FirstW(snapshot, &entry) == .FALSE) return out[0..0];
    while (n < out.len) {
        if (nameEquals(&entry.szExeFile, name)) {
            out[n] = entry.th32ProcessID;
            n += 1;
        }
        if (win.Process32NextW(snapshot, &entry) == .FALSE) break;
    }
    return out[0..n];
}

pub fn nowMs() u64 {
    return win.GetTickCount64();
}

pub const ProcessEntry = struct {
    pid: u32,
    parent_pid: u32,
    /// Only valid until the next `next`.
    name: []const u8,
};

/// As of `init`.
pub const Processes = struct {
    snapshot: win.HANDLE,
    entry: win.PROCESSENTRY32W = .{},
    started: bool = false,
    name_buf: [win.MAX_PATH * 3]u8 = undefined,

    pub fn init() !Processes {
        const snapshot = win.CreateToolhelp32Snapshot(win.TH32CS_SNAPPROCESS, 0);
        if (snapshot == win.INVALID_HANDLE_VALUE) return error.SnapshotFailed;
        return .{ .snapshot = snapshot };
    }

    pub fn deinit(self: *Processes) void {
        win.CloseHandle(self.snapshot);
        self.* = undefined;
    }

    pub fn next(self: *Processes) ?ProcessEntry {
        const found = if (self.started) win.Process32NextW(self.snapshot, &self.entry) else win.Process32FirstW(self.snapshot, &self.entry);
        self.started = true;
        if (found == .FALSE) return null;
        return .{
            .pid = self.entry.th32ProcessID,
            .parent_pid = self.entry.th32ParentProcessID,
            .name = toUtf8(&self.name_buf, &self.entry.szExeFile),
        };
    }
};

pub const ModuleEntry = struct {
    base: usize,
    size: usize,
    /// Only valid until the next `next`.
    name: []const u8,
};

/// As of `init`, including a WoW64 process's 32-bit ones.
pub const Modules = struct {
    snapshot: win.HANDLE,
    entry: win.MODULEENTRY32W = .{},
    started: bool = false,
    name_buf: [256 * 3]u8 = undefined,

    /// `error.ModuleListUnavailable` if elevated, protected or just started.
    pub fn init(pid: u32) !Modules {
        const snapshot = win.CreateToolhelp32Snapshot(win.TH32CS_SNAPMODULE | win.TH32CS_SNAPMODULE32, pid);
        if (snapshot == win.INVALID_HANDLE_VALUE) return error.ModuleListUnavailable;
        return .{ .snapshot = snapshot };
    }

    pub fn deinit(self: *Modules) void {
        win.CloseHandle(self.snapshot);
        self.* = undefined;
    }

    pub fn next(self: *Modules) ?ModuleEntry {
        const found = if (self.started) win.Module32NextW(self.snapshot, &self.entry) else win.Module32FirstW(self.snapshot, &self.entry);
        self.started = true;
        if (found == .FALSE) return null;
        return .{
            .base = self.entry.modBaseAddr,
            .size = self.entry.modBaseSize,
            .name = toUtf8(&self.name_buf, &self.entry.szModule),
        };
    }
};

/// Only needs limited access, so even elevated processes tell us.
pub const Image = struct {
    arch: Arch,
    /// In the buffer passed to `queryImage`.
    path: []const u8,
};

pub fn queryImage(pid: u32, path_buf: []u8) !Image {
    const handle = win.OpenProcess(win.PROCESS_QUERY_LIMITED_INFORMATION, .FALSE, pid) orelse return error.OpenFailed;
    defer win.CloseHandle(handle);
    var wide: [1024]u16 = undefined;
    var len: win.DWORD = wide.len;
    if (win.QueryFullProcessImageNameW(handle, 0, &wide, &len) == .FALSE) return error.QueryFailed;
    if (path_buf.len < std.unicode.calcWtf8Len(wide[0..len])) return error.NameTooLong;
    return .{ .arch = try archOf(handle), .path = path_buf[0..std.unicode.wtf16LeToWtf8(path_buf, wide[0..len])] };
}

/// Services run in 0.
pub fn sessionOf(pid: u32) !u32 {
    var session: win.DWORD = 0;
    if (win.ProcessIdToSessionId(pid, &session) == .FALSE) return error.QueryFailed;
    return session;
}

pub fn windowedPids(allocator: std.mem.Allocator) ![]u32 {
    const Collect = struct {
        allocator: std.mem.Allocator,
        pids: std.ArrayList(u32) = .empty,
        failed: bool = false,

        fn each(hwnd: win.HWND, context: isize) callconv(.winapi) win.BOOL {
            const self: *@This() = @ptrFromInt(@as(usize, @bitCast(context)));
            if (win.IsWindowVisible(hwnd) == .FALSE) return .TRUE;
            if (win.GetWindow(hwnd, win.GW_OWNER) != null) return .TRUE;
            const ex_style: usize = @bitCast(win.GetWindowLongPtrW(hwnd, win.GWL_EXSTYLE));
            if (ex_style & win.WS_EX_TOOLWINDOW != 0) return .TRUE;
            var pid: win.DWORD = 0;
            _ = win.GetWindowThreadProcessId(hwnd, &pid);
            if (std.mem.indexOfScalar(u32, self.pids.items, pid) == null) {
                self.pids.append(self.allocator, pid) catch {
                    self.failed = true;
                    return .FALSE;
                };
            }
            return .TRUE;
        }
    };
    var collect: Collect = .{ .allocator = allocator };
    errdefer collect.pids.deinit(allocator);
    _ = win.EnumWindows(Collect.each, @bitCast(@intFromPtr(&collect)));
    if (collect.failed) return error.OutOfMemory;
    return collect.pids.toOwnedSlice(allocator);
}

/// 3 bytes per UTF-16 unit is always enough.
fn toUtf8(buf: []u8, wide: []const u16) []const u8 {
    const w = std.mem.sliceTo(wide, 0);
    return buf[0..std.unicode.wtf16LeToWtf8(buf, w)];
}

pub fn sleepMs(ms: u32) void {
    win.Sleep(ms);
}

pub const CallOptions = struct {
    /// Resumes a paused target after `stall_ms`, since its main thread may hold a lock the call needs.
    paused: ?*bool = null,
    stall_ms: u32 = 250,
};

pub const Process = struct {
    pid: u32,
    handle: win.HANDLE,
    process_arch: Arch,

    /// Grants ourselves access if the DACL keeps us out.
    pub fn open(pid: u32) !Process {
        const access = win.PROCESS_CREATE_THREAD | win.PROCESS_VM_OPERATION | win.PROCESS_VM_READ |
            win.PROCESS_VM_WRITE | win.PROCESS_QUERY_INFORMATION | win.SYNCHRONIZE | win.PROCESS_SUSPEND_RESUME;
        const handle = win.OpenProcess(access, .FALSE, pid) orelse switch (win.GetLastError()) {
            .INVALID_PARAMETER => return error.ProcessNotFound,
            .ACCESS_DENIED => blk: {
                grantAccess(pid, access) catch |err| {
                    log.warn("pid {d} keeps us out, and we couldn't let ourselves in: {t}", .{ pid, err });
                    return error.AccessDenied;
                };
                break :blk win.OpenProcess(access, .FALSE, pid) orelse return error.AccessDenied;
            },
            else => return error.OpenFailed,
        };
        errdefer win.CloseHandle(handle);
        return .{ .pid = pid, .handle = handle, .process_arch = try archOf(handle) };
    }

    /// Some launchers set a DACL that keeps others out, but we own the game so we can change it.
    fn grantAccess(pid: u32, access: win.DWORD) !void {
        const handle = win.OpenProcess(win.READ_CONTROL | win.WRITE_DAC, .FALSE, pid) orelse return error.OpenFailed;
        defer win.CloseHandle(handle);
        var dacl: ?*anyopaque = null;
        var descriptor: ?*anyopaque = null;
        if (win.GetSecurityInfo(handle, win.SE_KERNEL_OBJECT, win.DACL_SECURITY_INFORMATION, null, null, &dacl, null, &descriptor) != 0)
            return error.SecurityQueryFailed;
        defer _ = win.LocalFree(descriptor);
        const entry = [_]win.EXPLICIT_ACCESS_W{.{
            .grfAccessPermissions = access,
            .grfAccessMode = win.SET_ACCESS,
            .grfInheritance = 0,
            .Trustee = .{ .TrusteeForm = win.TRUSTEE_IS_NAME, .TrusteeType = win.TRUSTEE_IS_USER, .ptstrName = std.unicode.utf8ToUtf16LeStringLiteral("CURRENT_USER") },
        }};
        var updated: ?*anyopaque = null;
        if (win.SetEntriesInAclW(entry.len, &entry, dacl, &updated) != 0) return error.SecurityUpdateFailed;
        defer _ = win.LocalFree(updated);
        if (win.SetSecurityInfo(handle, win.SE_KERNEL_OBJECT, win.DACL_SECURITY_INFORMATION, null, null, updated, null) != 0)
            return error.SecurityUpdateFailed;
        log.info("pid {d} kept other processes out, so we let ourselves in", .{pid});
    }

    pub fn close(self: *Process) void {
        win.CloseHandle(self.handle);
        self.* = undefined;
    }

    pub fn arch(self: *const Process) Arch {
        return self.process_arch;
    }

    /// Counted, so each `pause` needs an `unpause`.
    pub fn pause(self: *const Process) !void {
        if (win.NtSuspendProcess(self.handle) != .SUCCESS) return error.PauseFailed;
    }

    pub fn unpause(self: *const Process) void {
        _ = win.NtResumeProcess(self.handle);
    }

    /// `error.ProcessExited` if the target exits first.
    fn waitFor(self: *const Process, thread: win.HANDLE, timeout_ms: u32) !enum { done, timeout } {
        const handles = [_]win.HANDLE{ thread, self.handle };
        return switch (win.WaitForMultipleObjects(handles.len, &handles, .FALSE, timeout_ms)) {
            win.WAIT_OBJECT_0 => .done,
            win.WAIT_OBJECT_0 + 1 => error.ProcessExited,
            win.WAIT_TIMEOUT => .timeout,
            else => error.WaitFailed,
        };
    }

    pub fn exitsWithin(self: *const Process, timeout_ms: u32) bool {
        return win.WaitForSingleObject(self.handle, timeout_ms) == win.WAIT_OBJECT_0;
    }

    pub fn exited(self: *const Process) bool {
        return win.WaitForSingleObject(self.handle, 0) == win.WAIT_OBJECT_0;
    }

    pub fn read(self: *const Process, address: usize, into: []u8) !void {
        var n: usize = 0;
        if (win.ReadProcessMemory(self.handle, address, into.ptr, into.len, &n) == .FALSE or n != into.len) return error.ReadFailed;
    }

    pub fn write(self: *const Process, address: usize, bytes: []const u8) !void {
        var n: usize = 0;
        if (win.WriteProcessMemory(self.handle, address, bytes.ptr, bytes.len, &n) == .FALSE or n != bytes.len) return error.WriteFailed;
    }

    /// Valid while this stays put and open. Decoding assumes our own instruction set.
    pub fn memory(self: *const Process) Memory {
        return .{ .context = @constCast(self), .vtable = &memory_vtable };
    }

    const memory_vtable: Memory.VTable = .{ .read = memoryRead, .write = memoryWrite };

    fn memoryRead(context: ?*anyopaque, address: usize, out: []u8) Memory.Error!void {
        const self: *const Process = @ptrCast(@alignCast(context));
        self.read(address, out) catch return error.Unreadable;
    }

    fn memoryWrite(context: ?*anyopaque, address: usize, bytes: []const u8) Memory.Error!void {
        const self: *const Process = @ptrCast(@alignCast(context));
        self.write(address, bytes) catch return error.Unwritable;
    }

    /// Module names both ways. Valid while this stays put and open.
    pub fn symbols(self: *const Process) Symbols {
        return .{ .context = @constCast(self), .vtable = &symbols_vtable };
    }

    const symbols_vtable: Symbols.VTable = .{ .resolve = symbolsResolve, .describe = symbolsDescribe };

    fn symbolsResolve(context: ?*anyopaque, name: []const u8) ?usize {
        const self: *const Process = @ptrCast(@alignCast(context));
        return self.findModuleNow(name) catch null;
    }

    // Ask the kernel instead of listing modules, views call this every frame
    fn symbolsDescribe(context: ?*anyopaque, address: usize, buf: []u8) ?[]const u8 {
        const self: *const Process = @ptrCast(@alignCast(context));
        const base = self.imageContaining(address) orelse return null;
        var path: [1024]u16 = undefined;
        const len = win.K32GetMappedFileNameW(self.handle, base, &path, path.len);
        if (len == 0) return null;
        const wide = path[0..len];
        const name = wide[if (std.mem.lastIndexOfScalar(u16, wide, '\\')) |i| i + 1 else 0..];
        var utf8: [260 * 3]u8 = undefined;
        const n = std.unicode.utf16LeToUtf8(&utf8, name) catch return null;
        return std.fmt.bufPrint(buf, "{s}+0x{x}", .{ utf8[0..n], address - base }) catch null;
    }

    fn imageContaining(self: *const Process, address: usize) ?usize {
        var info: win.MEMORY_BASIC_INFORMATION = undefined;
        if (win.VirtualQueryEx(self.handle, address, &info, @sizeOf(win.MEMORY_BASIC_INFORMATION)) == 0) return null;
        if (info.Type != win.MEM_IMAGE) return null;
        return @intFromPtr(info.AllocationBase orelse return null);
    }

    pub fn alloc(self: *const Process, size: usize) !usize {
        const addr = win.VirtualAllocEx(self.handle, null, size, .{ .COMMIT = true, .RESERVE = true }, .{ .READWRITE = true });
        return if (addr) |a| @intFromPtr(a) else error.AllocFailed;
    }

    pub fn free(self: *const Process, address: usize) void {
        _ = win.VirtualFreeEx(self.handle, @ptrFromInt(address), 0, .{ .RELEASE = true });
    }

    /// Any case, WoW64 modules count too.
    pub fn findModule(self: *const Process, name: []const u8) error{ SnapshotFailed, ModuleNotFound }!usize {
        // A just-started target's module list can briefly fail or be empty, so retry
        var attempt: u32 = 0;
        while (attempt < 50) : (attempt += 1) {
            if (attempt != 0) win.Sleep(10);
            return self.findModuleNow(name) catch |err| switch (err) {
                error.ModuleListUnavailable => continue,
                error.ModuleNotFound => return error.ModuleNotFound,
            };
        }
        return error.SnapshotFailed;
    }

    /// Doesn't wait. Use on a paused target, where waiting won't help.
    pub fn findModuleNow(self: *const Process, name: []const u8) error{ ModuleListUnavailable, ModuleNotFound }!usize {
        const snapshot = win.CreateToolhelp32Snapshot(win.TH32CS_SNAPMODULE | win.TH32CS_SNAPMODULE32, self.pid);
        if (snapshot == win.INVALID_HANDLE_VALUE) return error.ModuleListUnavailable;
        defer win.CloseHandle(snapshot);

        var entry: win.MODULEENTRY32W = .{};
        if (win.Module32FirstW(snapshot, &entry) == .FALSE) return error.ModuleListUnavailable;
        while (true) {
            if (nameEquals(&entry.szModule, name)) return entry.modBaseAddr;
            if (win.Module32NextW(snapshot, &entry) == .FALSE) break;
        }
        return error.ModuleNotFound;
    }

    /// Read from the target's PE image. Follows forwarders.
    pub fn findExport(self: *const Process, allocator: std.mem.Allocator, base: usize, name: []const u8) !usize {
        return exports.find(self, allocator, base, name);
    }

    /// Runs as a thread in the target. Returns the exit code, the result cut to 32 bits.
    pub fn call(self: *const Process, function: usize, argument: usize, options: CallOptions) !u32 {
        const thread = win.CreateRemoteThread(self.handle, null, 0, function, argument, 0, null) orelse return error.RemoteThreadFailed;
        defer win.CloseHandle(thread);

        if (options.paused) |paused| if (paused.*) {
            if (try self.waitFor(thread, options.stall_ms) == .timeout) {
                self.unpause();
                paused.* = false;
            }
        };
        if (try self.waitFor(thread, remote_thread_timeout_ms) == .timeout) return error.RemoteThreadTimeout;
        var exit_code: win.DWORD = 0;
        if (win.GetExitCodeThread(thread, &exit_code) == .FALSE) return error.ExitCodeFailed;
        return exit_code;
    }

    /// `free` it when done.
    pub fn allocWrite(self: *const Process, bytes: []const u8) !usize {
        const addr = try self.alloc(bytes.len);
        errdefer self.free(addr);
        try self.write(addr, bytes);
        return addr;
    }

    /// Remote `LoadLibraryW`.
    pub fn loadLibrary(self: *const Process, allocator: std.mem.Allocator, dll_path: []const u8, options: CallOptions) !void {
        const kernel32 = self.findModule("kernel32.dll") catch |err| {
            log.err("Can't find kernel32.dll in pid {d}: {t}", .{ self.pid, err });
            return err;
        };
        const load = self.findExport(allocator, kernel32, "LoadLibraryW") catch |err| {
            log.err("Can't find LoadLibraryW in pid {d}'s kernel32.dll (at 0x{x}): {t}", .{ self.pid, kernel32, err });
            return err;
        };
        log.debug("Loading {s} into pid {d} (LoadLibraryW at 0x{x})", .{ dll_path, self.pid, load });

        const wide = try std.unicode.utf8ToUtf16LeAllocZ(allocator, dll_path);
        defer allocator.free(wide);

        const arg = try self.allocWrite(std.mem.sliceAsBytes(wide[0 .. wide.len + 1]));
        defer self.free(arg);

        // The result is the module base cut to 32 bits, 0 means it failed
        if (try self.call(load, arg, options) == 0) return error.LoadLibraryFailed;
    }

    /// No argument. Returns its exit code.
    pub fn callExport(self: *const Process, allocator: std.mem.Allocator, module_base: usize, name: []const u8) !u32 {
        return self.call(try self.findExport(allocator, module_base, name), 0, .{});
    }
};

fn archOf(handle: win.HANDLE) !Arch {
    var process_machine: u16 = win.IMAGE_FILE_MACHINE_UNKNOWN;
    var native_machine: u16 = win.IMAGE_FILE_MACHINE_UNKNOWN;
    if (win.IsWow64Process2(handle, &process_machine, &native_machine) == .FALSE) return error.ArchQueryFailed;
    // UNKNOWN means not under WoW64
    const machine = if (process_machine == win.IMAGE_FILE_MACHINE_UNKNOWN) native_machine else process_machine;
    return switch (machine) {
        win.IMAGE_FILE_MACHINE_I386 => .x86,
        win.IMAGE_FILE_MACHINE_AMD64 => .x64,
        else => error.UnsupportedArch,
    };
}

fn nameEquals(wide: []const u16, name: []const u8) bool {
    const w = std.mem.sliceTo(wide, 0);
    if (w.len != name.len) return false;
    for (w, name) |c, n| {
        if (std.ascii.toLower(@truncate(c)) != std.ascii.toLower(n)) return false;
    }
    return true;
}

/// Reads a remote module's exports in its own bitness.
const exports = struct {
    const Error = error{
        InvalidImage,
        ExportNotFound,
        ReadFailed,
        NameTooLong,
        SnapshotFailed,
        ModuleNotFound,
        OutOfMemory,
    };

    fn find(process: *const Process, allocator: std.mem.Allocator, base: usize, name: []const u8) Error!usize {
        var dos: [64]u8 = undefined;
        try process.read(base, &dos);
        if (std.mem.readInt(u16, dos[0..2], .little) != 0x5A4D) return error.InvalidImage; // 'MZ'
        const e_lfanew = std.mem.readInt(i32, dos[60..64], .little);
        if (e_lfanew <= 0) return error.InvalidImage;
        const nt = base + @as(usize, @intCast(e_lfanew));

        var sig_file: [6]u8 = undefined;
        try process.read(nt, &sig_file);
        if (std.mem.readInt(u32, sig_file[0..4], .little) != 0x0000_4550) return error.InvalidImage; // 'PE\0\0'
        const magic_off = nt + 24;
        var magic_bytes: [2]u8 = undefined;
        try process.read(magic_off, &magic_bytes);
        // PE32 (0x10B) and PE32+ (0x20B) keep the export directory at different offsets
        const is_pe32_plus = std.mem.readInt(u16, &magic_bytes, .little) == 0x20B;
        const export_dir_rva_off = magic_off + (if (is_pe32_plus) @as(usize, 112) else 96);

        var dir: [8]u8 = undefined;
        try process.read(export_dir_rva_off, &dir);
        const export_rva = std.mem.readInt(u32, dir[0..4], .little);
        const export_size = std.mem.readInt(u32, dir[4..8], .little);
        if (export_rva == 0) return error.ExportNotFound;

        // Export directory is 40 bytes
        var hdr: [40]u8 = undefined;
        try process.read(base + export_rva, &hdr);
        const number_of_functions = std.mem.readInt(u32, hdr[20..24], .little);
        const number_of_names = std.mem.readInt(u32, hdr[24..28], .little);
        const functions_rva = std.mem.readInt(u32, hdr[28..32], .little);
        const names_rva = std.mem.readInt(u32, hdr[32..36], .little);
        const ordinals_rva = std.mem.readInt(u32, hdr[36..40], .little);

        const names = try readU32s(process, allocator, base + names_rva, number_of_names);
        defer allocator.free(names);
        const ordinals = try readU16s(process, allocator, base + ordinals_rva, number_of_names);
        defer allocator.free(ordinals);

        var name_buf: [512]u8 = undefined;
        const index = for (names, 0..) |name_rva, i| {
            const got = try readCString(process, base + name_rva, &name_buf);
            if (exportNameMatches(got, name)) break i;
        } else return error.ExportNotFound;

        const ordinal = ordinals[index];
        if (ordinal >= number_of_functions) return error.InvalidImage;
        var func_rva_bytes: [4]u8 = undefined;
        try process.read(base + functions_rva + @as(usize, ordinal) * 4, &func_rva_bytes);
        const func_rva = std.mem.readInt(u32, &func_rva_bytes, .little);

        // An RVA inside the export directory is a forwarder string
        if (func_rva >= export_rva and func_rva < export_rva + export_size) {
            const forward = try readCString(process, base + func_rva, &name_buf);
            return followForwarder(process, allocator, forward);
        }
        return base + func_rva;
    }

    fn followForwarder(process: *const Process, allocator: std.mem.Allocator, forward: []const u8) Error!usize {
        const dot = std.mem.lastIndexOfScalar(u8, forward, '.') orelse return error.InvalidImage;
        const module_stem = forward[0..dot];
        const export_name = forward[dot + 1 ..];
        var dll_buf: [272]u8 = undefined;
        const dll_name = std.fmt.bufPrint(&dll_buf, "{s}.dll", .{module_stem}) catch return error.InvalidImage;
        const module_base = process.findModule(dll_name) catch |err| {
            log.err("{s} is forwarded to {s}, which isn't loaded in pid {d}: {t}", .{ export_name, dll_name, process.pid, err });
            return err;
        };
        return find(process, allocator, module_base, export_name);
    }

    /// Allows x86 stdcall decoration like `name@8`.
    fn exportNameMatches(got: []const u8, name: []const u8) bool {
        if (std.mem.eql(u8, got, name)) return true;
        return got.len > name.len and got[name.len] == '@' and std.mem.eql(u8, got[0..name.len], name);
    }

    fn readU32s(process: *const Process, allocator: std.mem.Allocator, address: usize, count: u32) ![]u32 {
        const out = try allocator.alloc(u32, count);
        errdefer allocator.free(out);
        try process.read(address, std.mem.sliceAsBytes(out));
        return out;
    }

    fn readU16s(process: *const Process, allocator: std.mem.Allocator, address: usize, count: u32) ![]u16 {
        const out = try allocator.alloc(u16, count);
        errdefer allocator.free(out);
        try process.read(address, std.mem.sliceAsBytes(out));
        return out;
    }

    fn readCString(process: *const Process, address: usize, buf: []u8) ![]const u8 {
        // Read in chunks so a name near the end of a region still works
        var len: usize = 0;
        while (len < buf.len) {
            const chunk = @min(buf.len - len, 64);
            process.read(address + len, buf[len .. len + chunk]) catch {
                if (len == 0) return error.ReadFailed;
                break;
            };
            if (std.mem.indexOfScalar(u8, buf[len .. len + chunk], 0)) |i| return buf[0 .. len + i];
            len += chunk;
        }
        return error.NameTooLong;
    }
};
