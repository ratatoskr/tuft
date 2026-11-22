const std = @import("std");
const zwin = std.os.windows;

const sys = @import("../root.zig");

const win = @import("api.zig");
const memory = @import("memory.zig");

const Section = sys.module.Section;

pub fn mainBase() usize {
    return @intFromPtr(win.GetModuleHandleW(null).?);
}

/// Doesn't allocate.
pub fn findBase(name: []const u8) ?usize {
    var buf: [win.MAX_PATH:0]u16 = undefined;
    if (name.len >= buf.len) return null;
    const n = std.unicode.utf8ToUtf16Le(&buf, name) catch return null;
    buf[n] = 0;
    const handle = win.GetModuleHandleW(buf[0..n :0].ptr) orelse return null;
    return @intFromPtr(handle);
}

pub fn containingBase(addr: usize) ?usize {
    var base: ?*anyopaque = null;
    _ = win.RtlPcToFileHeader(@ptrFromInt(addr), &base);
    return @intFromPtr(base orelse return null);
}

pub fn nameOf(base: usize, buf: []u8) ?[]const u8 {
    var wide: [win.MAX_PATH:0]u16 = undefined;
    const len = win.GetModuleFileNameW(@ptrFromInt(base), &wide, wide.len);
    if (len == 0 or len >= wide.len) return null;
    const path = wide[0..len];
    const start = if (std.mem.lastIndexOfAny(u16, path, &.{ '\\', '/' })) |i| i + 1 else 0;
    const n = std.unicode.utf16LeToUtf8(buf, path[start..]) catch return null;
    return buf[0..n];
}

pub fn pathOf(base: usize, buf: []u8) ?[]const u8 {
    var wide: [win.MAX_PATH:0]u16 = undefined;
    const len = win.GetModuleFileNameW(@ptrFromInt(base), &wide, wide.len);
    if (len == 0 or len >= wide.len) return null;
    const n = std.unicode.utf16LeToUtf8(buf, wide[0..len]) catch return null;
    return buf[0..n];
}

pub fn imageSize(base: usize) !usize {
    const nt = try ntHeaders(base);
    const optional = @intFromPtr(nt) + @sizeOf(win.IMAGE_NT_HEADERS_PREFIX);
    if (nt.FileHeader.SizeOfOptionalHeader < win.optional_header_size_of_image_offset + 4) return error.InvalidImage;
    const size: *align(1) const u32 = @ptrFromInt(optional + win.optional_header_size_of_image_offset);
    return size.*;
}

pub fn entryPoint(base: usize) !?usize {
    const nt = try ntHeaders(base);
    const optional = @intFromPtr(nt) + @sizeOf(win.IMAGE_NT_HEADERS_PREFIX);
    // AddressOfEntryPoint is at the same offset in PE32 and PE32+
    const offset = 16;
    if (nt.FileHeader.SizeOfOptionalHeader < offset + 4) return error.InvalidImage;
    const rva: *align(1) const u32 = @ptrFromInt(optional + offset);
    return if (rva.* == 0) null else base + rva.*;
}

/// Reads headers from the mapped image as you go.
pub const SectionIterator = struct {
    base: usize,
    headers: []align(1) const win.IMAGE_SECTION_HEADER,
    index: usize = 0,

    pub fn next(self: *SectionIterator) ?Section {
        if (self.index == self.headers.len) return null;
        const h = &self.headers[self.index];
        self.index += 1;
        const name = std.mem.sliceTo(&h.Name, 0);
        var s: Section = .{
            .name_buf = h.Name,
            .name_len = @intCast(name.len),
            .start = self.base + h.VirtualAddress,
            .len = h.Misc.VirtualSize,
            .executable = h.Characteristics & win.IMAGE_SCN_MEM_EXECUTE != 0,
            .readable = h.Characteristics & win.IMAGE_SCN_MEM_READ != 0,
            .writable = h.Characteristics & win.IMAGE_SCN_MEM_WRITE != 0,
        };
        @memset(s.name_buf[s.name_len..], 0);
        return s;
    }
};

pub fn sections(base: usize) !SectionIterator {
    const nt = try ntHeaders(base);
    const first_addr = @intFromPtr(nt) + @sizeOf(win.IMAGE_NT_HEADERS_PREFIX) + nt.FileHeader.SizeOfOptionalHeader;
    const count = nt.FileHeader.NumberOfSections;
    if (!memory.isReadable(first_addr, @as(usize, count) * @sizeOf(win.IMAGE_SECTION_HEADER))) return error.InvalidImage;
    const first: [*]align(1) const win.IMAGE_SECTION_HEADER = @ptrFromInt(first_addr);
    return .{ .base = base, .headers = first[0..count] };
}

fn ntHeaders(base: usize) !*align(1) const win.IMAGE_NT_HEADERS_PREFIX {
    if (!memory.isReadable(base, @sizeOf(win.IMAGE_DOS_HEADER))) return error.InvalidImage;
    const dos: *align(1) const win.IMAGE_DOS_HEADER = @ptrFromInt(base);
    if (dos.e_magic != win.IMAGE_DOS_SIGNATURE or dos.e_lfanew <= 0) return error.InvalidImage;

    const nt_addr = base + @as(usize, @intCast(dos.e_lfanew));
    if (!memory.isReadable(nt_addr, @sizeOf(win.IMAGE_NT_HEADERS_PREFIX))) return error.InvalidImage;
    const nt: *align(1) const win.IMAGE_NT_HEADERS_PREFIX = @ptrFromInt(nt_addr);
    if (nt.Signature != win.IMAGE_NT_SIGNATURE) return error.InvalidImage;
    return nt;
}

/// The loader follows forwarders for us.
pub fn findExport(base: usize, name: []const u8) ?usize {
    var buf: [256:0]u8 = undefined;
    if (name.len >= buf.len) return null;
    @memcpy(buf[0..name.len], name);
    buf[name.len] = 0;
    const proc = win.GetProcAddress(@ptrFromInt(base), buf[0..name.len :0].ptr) orelse return null;
    return @intFromPtr(proc);
}

pub fn findOrdinal(base: usize, ordinal: u16) ?usize {
    // An ordinal goes where the name pointer would, in the low word
    const proc = win.GetProcAddress(@ptrFromInt(base), @ptrFromInt(ordinal)) orelse return null;
    return @intFromPtr(proc);
}

pub fn load(allocator: std.mem.Allocator, path: []const u8) !usize {
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(allocator, path);
    defer allocator.free(wide);
    const handle = win.LoadLibraryW(wide.ptr) orelse return error.LoadFailed;
    return @intFromPtr(handle);
}

pub fn loadBeside(allocator: std.mem.Allocator, path: []const u8) !usize {
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(allocator, path);
    defer allocator.free(wide);
    const handle = win.LoadLibraryExW(wide.ptr, null, win.LOAD_WITH_ALTERED_SEARCH_PATH) orelse return error.LoadFailed;
    return @intFromPtr(handle);
}

/// Waits for its threads to exit first, since their last steps still run in its code. False if one was
/// still going after the wait, so it's left loaded, since freeing it would crash that thread.
pub fn unload(base: usize) bool {
    if (imageSize(base)) |size| {
        if (!waitForThreadsStartedIn(base, size, thread_exit_timeout_ms)) return false;
    } else |_| {}
    _ = win.FreeLibrary(@ptrFromInt(base));
    return true;
}

const thread_exit_timeout_ms = 5000;

/// Skips the calling thread. False if one hadn't exited by `timeout_ms`.
fn waitForThreadsStartedIn(start: usize, len: usize, timeout_ms: u32) bool {
    const current = zwin.GetCurrentThreadId();
    const deadline = win.GetTickCount64() + timeout_ms;
    const access = win.SYNCHRONIZE | win.THREAD_QUERY_INFORMATION;
    var all_exited = true;
    // Each handle is the cursor for the next call, so close it after that call
    var cursor: ?win.HANDLE = null;
    defer if (cursor) |h| win.CloseHandle(h);
    while (true) {
        var next: ?win.HANDLE = null;
        const status = win.NtGetNextThread(zwin.GetCurrentProcess(), cursor, access, 0, 0, &next);
        if (cursor) |h| win.CloseHandle(h);
        cursor = null;
        if (status != .SUCCESS) return all_exited;
        const thread = next.?;
        cursor = thread;
        if (win.GetThreadId(thread) == current) continue;

        var started_at: usize = 0;
        if (win.NtQueryInformationThread(thread, win.ThreadQuerySetWin32StartAddress, &started_at, @sizeOf(usize), null) != .SUCCESS) continue;
        if (started_at < start or started_at - start >= len) continue;
        const now = win.GetTickCount64();
        if (win.WaitForSingleObject(thread, if (now >= deadline) 0 else @intCast(deadline - now)) != win.WAIT_OBJECT_0) all_exited = false;
    }
}

pub fn systemBase(name: []const u8) !usize {
    var dir: [win.MAX_PATH]u16 = undefined;
    const dir_len = win.GetSystemDirectoryW(&dir, dir.len);
    if (dir_len == 0 or dir_len >= dir.len) return error.PathTooLong;
    var name_utf8: [win.MAX_PATH]u8 = undefined;
    const sep_name = std.fmt.bufPrint(&name_utf8, "\\{s}", .{name}) catch return error.PathTooLong;
    var path: [win.MAX_PATH:0]u16 = undefined;
    const len = try join(&path, &.{dir[0..dir_len]}, sep_name, &.{});
    // Full path, so we get that exact file
    if (win.GetModuleHandleW(path[0..len :0].ptr)) |h| return @intFromPtr(h);
    const h = win.LoadLibraryW(path[0..len :0].ptr) orelse return error.LoadFailed;
    return @intFromPtr(h);
}

/// Wide `parts`, then `utf8`, then wide `tail`, NUL-terminated. Returns the length.
fn join(out: *[win.MAX_PATH:0]u16, parts: []const []const u16, utf8: []const u8, tail: []const u16) !usize {
    var len: usize = 0;
    for (parts) |part| {
        if (len + part.len > out.len) return error.PathTooLong;
        @memcpy(out[len..][0..part.len], part);
        len += part.len;
    }
    if (len + utf8.len > out.len) return error.PathTooLong;
    len += std.unicode.utf8ToUtf16Le(out[len..], utf8) catch return error.PathTooLong;
    if (len + tail.len > out.len) return error.PathTooLong;
    @memcpy(out[len..][0..tail.len], tail);
    len += tail.len;
    out[len] = 0;
    return len;
}

pub fn selfBase() usize {
    return containingBase(@intFromPtr(&selfBase)).?;
}

const tests = struct {
    test "unload waits for threads" {
        const Worker = struct {
            var done: std.atomic.Value(bool) = .init(false);

            fn run(_: ?*anyopaque) callconv(.winapi) win.DWORD {
                win.Sleep(200);
                done.store(true, .release);
                return 0;
            }
        };
        const thread = win.CreateThread(null, 0, Worker.run, null, 0, null) orelse return error.SkipZigTest;
        defer win.CloseHandle(thread);

        // Threads started elsewhere would hit the timeout
        try std.testing.expect(waitForThreadsStartedIn(@intFromPtr(&Worker.run), 1, 5000));
        try std.testing.expect(Worker.done.load(.acquire));
        // Actually gone, not just done with its work
        try std.testing.expectEqual(win.WAIT_OBJECT_0, win.WaitForSingleObject(thread, 0));
    }

    test "a thread still running means it's not done" {
        const Slow = struct {
            fn run(_: ?*anyopaque) callconv(.winapi) win.DWORD {
                win.Sleep(500);
                return 0;
            }
        };
        const thread = win.CreateThread(null, 0, Slow.run, null, 0, null) orelse return error.SkipZigTest;
        defer win.CloseHandle(thread);
        try std.testing.expect(!waitForThreadsStartedIn(@intFromPtr(&Slow.run), 1, 20));
        _ = win.WaitForSingleObject(thread, 0xFFFF_FFFF);
    }

    test "nameOf" {
        var buf: [64]u8 = undefined;
        const base = findBase("kernel32.dll").?;
        try std.testing.expect(std.ascii.eqlIgnoreCase("kernel32.dll", nameOf(base, &buf).?));
        var path_buf: [512]u8 = undefined;
        try std.testing.expect(std.fs.path.isAbsolute(pathOf(base, &path_buf).?));
    }

    test "findExport" {
        const base = findBase("kernel32.dll").?;
        try std.testing.expect(findExport(base, "Sleep") != null);
        try std.testing.expectEqual(null, findExport(base, "NoSuchExportZZ"));
    }

    test "load, unload, selfBase" {
        const base = try load(std.testing.allocator, "version.dll");
        try std.testing.expectEqual(base, findBase("version.dll").?);
        try std.testing.expect(findExport(base, "GetFileVersionInfoSizeW") != null);
        try std.testing.expect(unload(base));
        try std.testing.expectError(error.LoadFailed, load(std.testing.allocator, "no_such_library_zz.dll"));

        try std.testing.expectEqual(mainBase(), selfBase());
    }

    test "systemBase" {
        const kernel32 = try systemBase("kernel32.dll");
        try std.testing.expectEqual(findBase("kernel32.dll").?, kernel32);
        const loaded = try systemBase("msimg32.dll");
        try std.testing.expectEqual(loaded, findBase("msimg32.dll").?);
        try std.testing.expectEqual(loaded, try systemBase("msimg32.dll"));
        try std.testing.expectError(error.LoadFailed, systemBase("no_such_library_zz.dll"));
    }

    test "image helpers" {
        const base = mainBase();
        try std.testing.expectEqual(base, containingBase(@intFromPtr(&mainBase)).?);
        const size = try imageSize(base);
        try std.testing.expect(size > 0);

        var has_text = false;
        var it = try sections(base);
        while (it.next()) |s| {
            try std.testing.expect(s.start >= base and s.start + s.len <= base + size);
            if (std.mem.eql(u8, s.name(), ".text")) has_text = s.executable and s.readable;
        }
        try std.testing.expect(has_text);

        try std.testing.expect(findBase("kernel32.dll") != null);
        try std.testing.expectEqual(null, findBase("not_loaded_zz.dll"));
        try std.testing.expectEqual(null, containingBase(0x10));
        var not_an_image: [256]u8 = @splat(0);
        try std.testing.expectError(error.InvalidImage, sections(@intFromPtr(&not_an_image)));
    }
};

test {
    _ = tests;
}

pub fn inSystemDir(path: []const u8) bool {
    const dir = std.fs.path.dirname(path) orelse return false;
    var buf: [win.MAX_PATH]u16 = undefined;
    for ([_]*const fn ([*]u16, u32) callconv(.winapi) u32{ &win.GetSystemDirectoryW, &win.GetSystemWow64DirectoryW }) |get| {
        const len = get(&buf, buf.len);
        if (len == 0 or len >= buf.len) continue;
        var utf8: [win.MAX_PATH * 3]u8 = undefined;
        const n = std.unicode.utf16LeToUtf8(&utf8, buf[0..len]) catch continue;
        if (std.ascii.eqlIgnoreCase(std.mem.trimEnd(u8, dir, "\\/"), std.mem.trimEnd(u8, utf8[0..n], "\\/"))) return true;
    }
    return false;
}

pub fn inSystemTree(path: []const u8) bool {
    var buf: [win.MAX_PATH]u16 = undefined;
    for ([_]*const fn ([*]u16, u32) callconv(.winapi) u32{ &win.GetSystemDirectoryW, &win.GetSystemWow64DirectoryW }) |get| {
        const len = get(&buf, buf.len);
        if (len == 0 or len >= buf.len) continue;
        var utf8: [win.MAX_PATH * 3]u8 = undefined;
        const n = std.unicode.utf16LeToUtf8(&utf8, buf[0..len]) catch continue;
        const dir = std.mem.trimEnd(u8, utf8[0..n], "\\/");
        if (path.len > dir.len and std.ascii.startsWithIgnoreCase(path, dir) and (path[dir.len] == '\\' or path[dir.len] == '/')) return true;
    }
    return false;
}

pub fn lazyFn(comptime dll: []const u8, comptime name: []const u8, comptime F: type) ?*const F {
    const Cache = LazyCache(dll, name, F);
    var address = Cache.address.load(.acquire);
    if (address == 0) {
        const base = findBase(dll) orelse (systemBase(dll) catch return null);
        address = findExport(base, name) orelse return null;
        Cache.address.store(address, .release);
    }
    return @ptrFromInt(address);
}

/// Captures all three so each function gets its own cache.
fn LazyCache(comptime dll: []const u8, comptime name: []const u8, comptime F: type) type {
    return struct {
        const key = .{ dll, name, F };
        var address: std.atomic.Value(usize) = .init(0);
    };
}

test "lazyFn" {
    const GetTickCountFn = fn () callconv(.winapi) u32;
    const get = lazyFn("kernel32.dll", "GetTickCount", GetTickCountFn).?;
    _ = get();
    try std.testing.expectEqual(null, lazyFn("kernel32.dll", "tuft_no_such_export", GetTickCountFn));
    try std.testing.expectEqual(null, lazyFn("tuft_no_such_dll.dll", "GetTickCount", GetTickCountFn));
}
