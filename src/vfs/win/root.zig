//! The ntdll hooks, where all user-mode file I/O ends up. Virtual files get a real handle too,
//! a signaled event, so waits and `CloseHandle` just work.

const std = @import("std");

const hook = @import("tuft_hook");
const TypedHook = hook.TypedHook;
const RwLock = @import("tuft_sys").sync.RwLock;

const Vfs = @import("../root.zig");
const File = Vfs.File;
const paths = Vfs.paths;
const nt = @import("nt.zig");
const names = @import("names.zig");
const virtual = @import("virtual.zig");
const dirs = @import("dirs.zig");

const log = std.log.scoped(.tuft_vfs);

/// Per open file. Real files only use `listing`.
pub const FileState = struct {
    lock: RwLock = .{},
    position: u64 = 0,
    options: u32 = 0,
    delete_on_close: bool = false,
    port: ?nt.HANDLE = null,
    port_key: usize = 0,
    skip_port_on_success: bool = false,
    listing: ?*dirs.Listing = null,

    pub fn deinit(self: *FileState, vfs: *Vfs, file: *File) void {
        if (self.listing) |l| l.destroy(vfs.allocator);
        if (self.delete_on_close) if (file.node) |n| vfs.store.unlink(n);
    }
};

pub fn threadId() u32 {
    return nt.GetCurrentThreadId();
}

/// NT time, 100ns since 1601.
pub fn now() i64 {
    var t: i64 = 0;
    nt.GetSystemTimeAsFileTime(&t);
    return t;
}

/// The loader's opening a DLL on this thread, holding its lock.
pub fn holdsLoaderLock() bool {
    return nt.RtlIsCriticalSectionLockedByThread(@ptrCast(std.os.windows.peb().LoaderLock)) != 0;
}

/// Set while we're in a hook on this thread, so listeners' own I/O goes straight through.
threadlocal var inside: bool = false;

fn enter() bool {
    if (inside or !Vfs.active()) return false;
    inside = true;
    return true;
}

fn leave() void {
    inside = false;
}

pub const Hooks = struct {
    create: ?*TypedHook(nt.NtCreateFileFn) = null,
    open: ?*TypedHook(nt.NtOpenFileFn) = null,
    read: ?*TypedHook(nt.NtReadFileFn) = null,
    write: ?*TypedHook(nt.NtWriteFileFn) = null,
    close: ?*TypedHook(nt.NtCloseFn) = null,
    query_info: ?*TypedHook(nt.NtQueryInformationFileFn) = null,
    set_info: ?*TypedHook(nt.NtSetInformationFileFn) = null,
    query_volume: ?*TypedHook(nt.NtQueryVolumeInformationFileFn) = null,
    query_dir: ?*TypedHook(nt.NtQueryDirectoryFileFn) = null,
    query_dir_ex: ?*TypedHook(nt.NtQueryDirectoryFileExFn) = null,
    attributes: ?*TypedHook(nt.NtQueryAttributesFileFn) = null,
    full_attributes: ?*TypedHook(nt.NtQueryFullAttributesFileFn) = null,
    delete: ?*TypedHook(nt.NtDeleteFileFn) = null,
    flush: ?*TypedHook(nt.NtFlushBuffersFileFn) = null,
    section: ?*TypedHook(nt.NtCreateSectionFn) = null,
    duplicate: ?*TypedHook(nt.NtDuplicateObjectFn) = null,

    pub fn install(self: *Hooks, vfs: *Vfs) !void {
        names.init();
        errdefer self.uninstall();
        const ntdll = @import("tuft_sys").module.findBase("ntdll.dll") orelse return error.NoNtdll;
        self.create = try add(ntdll, "NtCreateFile", nt.NtCreateFileFn, onCreate, vfs);
        self.open = try add(ntdll, "NtOpenFile", nt.NtOpenFileFn, onOpen, vfs);
        self.read = try add(ntdll, "NtReadFile", nt.NtReadFileFn, onRead, vfs);
        self.write = try add(ntdll, "NtWriteFile", nt.NtWriteFileFn, onWrite, vfs);
        self.close = try add(ntdll, "NtClose", nt.NtCloseFn, onClose, vfs);
        self.query_info = try add(ntdll, "NtQueryInformationFile", nt.NtQueryInformationFileFn, onQueryInfo, vfs);
        self.set_info = try add(ntdll, "NtSetInformationFile", nt.NtSetInformationFileFn, onSetInfo, vfs);
        self.query_volume = try add(ntdll, "NtQueryVolumeInformationFile", nt.NtQueryVolumeInformationFileFn, onQueryVolume, vfs);
        self.query_dir = try add(ntdll, "NtQueryDirectoryFile", nt.NtQueryDirectoryFileFn, onQueryDir, vfs);
        // Windows 10 1709+
        self.query_dir_ex = add(ntdll, "NtQueryDirectoryFileEx", nt.NtQueryDirectoryFileExFn, onQueryDirEx, vfs) catch null;
        self.attributes = try add(ntdll, "NtQueryAttributesFile", nt.NtQueryAttributesFileFn, onAttributes, vfs);
        self.full_attributes = try add(ntdll, "NtQueryFullAttributesFile", nt.NtQueryFullAttributesFileFn, onFullAttributes, vfs);
        self.delete = try add(ntdll, "NtDeleteFile", nt.NtDeleteFileFn, onDelete, vfs);
        self.flush = try add(ntdll, "NtFlushBuffersFile", nt.NtFlushBuffersFileFn, onFlush, vfs);
        self.section = try add(ntdll, "NtCreateSection", nt.NtCreateSectionFn, onSection, vfs);
        self.duplicate = try add(ntdll, "NtDuplicateObject", nt.NtDuplicateObjectFn, onDuplicate, vfs);
    }

    pub fn uninstall(self: *Hooks) void {
        inline for (@typeInfo(Hooks).@"struct".field_names) |name| {
            if (@field(self, name)) |h| h.destroy();
            @field(self, name) = null;
        }
    }
};

fn add(ntdll: usize, comptime name: []const u8, comptime T: type, comptime callback: anytype, vfs: *Vfs) !*TypedHook(T) {
    const address = @import("tuft_sys").module.findExport(ntdll, name) orelse return error.MissingExport;
    const h = try hook.memory.Address.at(address).createFn(T, callback, vfs);
    errdefer h.destroy();
    try h.enable();
    return h;
}

// Opens

fn accessOf(mask: u32) Vfs.Access {
    const all = mask & (nt.GENERIC_ALL | nt.MAXIMUM_ALLOWED) != 0;
    return .{
        .read = all or mask & (nt.GENERIC_READ | nt.FILE_READ_DATA) != 0,
        .write = all or mask & (nt.GENERIC_WRITE | nt.FILE_WRITE_DATA) != 0,
        .append = all or mask & (nt.GENERIC_WRITE | nt.FILE_APPEND_DATA) != 0,
        .delete = all or mask & nt.DELETE != 0,
        .execute = all or mask & (nt.GENERIC_EXECUTE | nt.FILE_EXECUTE) != 0,
    };
}

fn dispositionOf(d: u32) Vfs.Disposition {
    return switch (d) {
        0 => .supersede,
        2 => .create,
        3 => .open_or_create,
        4 => .overwrite,
        5 => .overwrite_or_create,
        else => .open,
    };
}

fn directoryOf(options: u32) ?bool {
    if (options & nt.FILE_DIRECTORY_FILE != 0) return true;
    if (options & nt.FILE_NON_DIRECTORY_FILE != 0) return false;
    return null;
}

pub fn denialStatus(d: Vfs.Denial) nt.NTSTATUS {
    return switch (d) {
        .access_denied => .ACCESS_DENIED,
        .not_found => .OBJECT_NAME_NOT_FOUND,
        .sharing_violation => nt.STATUS_SHARING_VIOLATION,
        .write_protected => nt.STATUS_MEDIA_WRITE_PROTECTED,
    };
}

fn notFound(status: nt.NTSTATUS) bool {
    return status == .OBJECT_NAME_NOT_FOUND or status == nt.STATUS_OBJECT_PATH_NOT_FOUND;
}

/// Everything NtCreateFile and NtOpenFile take, so they share one path.
const OpenArgs = struct {
    out: *nt.HANDLE,
    access: u32,
    oa: *nt.OBJECT_ATTRIBUTES,
    iosb: *nt.IO_STATUS_BLOCK,
    allocation: ?*i64 = null,
    attributes: u32 = 0,
    share: u32,
    disposition: u32 = 1,
    options: u32,
    ea: ?*anyopaque = null,
    ea_len: u32 = 0,
    create: ?*const nt.NtCreateFileFn = null,
    open: ?*const nt.NtOpenFileFn = null,

    fn real(self: *const OpenArgs, oa: *nt.OBJECT_ATTRIBUTES) nt.NTSTATUS {
        if (self.create) |c| return c(self.out, self.access, oa, self.iosb, self.allocation, self.attributes, self.share, self.disposition, self.options, self.ea, self.ea_len);
        return self.open.?(self.out, self.access, oa, self.iosb, self.share, self.options);
    }
};

fn onCreate(vfs: *Vfs, h: *TypedHook(nt.NtCreateFileFn), out: *nt.HANDLE, access: u32, oa: *nt.OBJECT_ATTRIBUTES, iosb: *nt.IO_STATUS_BLOCK, allocation: ?*i64, attributes: u32, share: u32, disposition: u32, options: u32, ea: ?*anyopaque, ea_len: u32) callconv(.winapi) nt.NTSTATUS {
    const args: OpenArgs = .{ .out = out, .access = access, .oa = oa, .iosb = iosb, .allocation = allocation, .attributes = attributes, .share = share, .disposition = disposition, .options = options, .ea = ea, .ea_len = ea_len, .create = h.original() };
    if (!enter()) return args.real(oa);
    defer leave();
    return openFile(vfs, &args);
}

fn onOpen(vfs: *Vfs, h: *TypedHook(nt.NtOpenFileFn), out: *nt.HANDLE, access: u32, oa: *nt.OBJECT_ATTRIBUTES, iosb: *nt.IO_STATUS_BLOCK, share: u32, options: u32) callconv(.winapi) nt.NTSTATUS {
    const args: OpenArgs = .{ .out = out, .access = access, .oa = oa, .iosb = iosb, .share = share, .options = options, .open = h.original() };
    if (!enter()) return args.real(oa);
    defer leave();
    return openFile(vfs, &args);
}

fn openFile(vfs: *Vfs, args: *const OpenArgs) nt.NTSTATUS {
    var path_buf: [names.max]u8 = undefined;
    const by_id = args.options & nt.FILE_OPEN_BY_FILE_ID != 0;
    const path = names.resolve(vfs, args.oa, by_id, &path_buf) orelse return args.real(args.oa);

    var redirect_buf: [names.max]u8 = undefined;
    var req: Vfs.OpenRequest = .{
        .path = path,
        .requested = path,
        .access = accessOf(args.access),
        .disposition = dispositionOf(args.disposition),
        .directory = directoryOf(args.options),
        .thread = threadId(),
        .loader = holdsLoaderLock(),
        .redirect_buf = &redirect_buf,
    };
    vfs.open.fire(.{&req});
    if (req.denied) |d| {
        const status = denialStatus(d);
        args.iosb.u.Status = status;
        args.iosb.Information = 0;
        vfs.open_failed.fire(.{ &req, @backingInt(status) });
        return status;
    }
    const redirected = req.path.ptr != path.ptr;
    const requested: ?[]const u8 = if (redirected) path else null;

    var key_buf: [names.max]u8 = undefined;
    const key = paths.key(&key_buf, req.path);
    const kind = vfs.store.exists(key);
    // Virtual files win. Folders are real if they're really there
    if (kind == .file) return openVirtual(vfs, args, &req, requested, key);

    const status = if (redirected) redirect: {
        var wide: [names.max]u16 = undefined;
        const name = names.toNt(req.path, &wide) orelse break :redirect nt.STATUS_OBJECT_PATH_NOT_FOUND;
        var us = nt.UNICODE_STRING.from(name);
        var oa = args.oa.*;
        oa.RootDirectory = null;
        oa.ObjectName = &us;
        break :redirect args.real(&oa);
    } else args.real(args.oa);

    if (nt.ok(status)) {
        const file = vfs.newFile(req.path, requested, .{
            .access = req.access,
            .kind = .real,
            .directory = req.directory orelse false,
        }) catch return status;
        vfs.track(@intFromPtr(args.out.*), file);
        vfs.opened.fire(.{file});
        return status;
    }
    if (notFound(status) and (kind == .dir or creatable(vfs, &req, key))) return openVirtual(vfs, args, &req, requested, key);
    vfs.open_failed.fire(.{ &req, @backingInt(status) });
    return status;
}

/// New files in a `putDir` folder are virtual.
fn creatable(vfs: *Vfs, req: *const Vfs.OpenRequest, key: []const u8) bool {
    if (!req.disposition.creates()) return false;
    const parent = paths.parent(key) orelse return false;
    return vfs.store.isExplicitDir(parent);
}

fn openVirtual(vfs: *Vfs, args: *const OpenArgs, req: *Vfs.OpenRequest, requested: ?[]const u8, key: []const u8) nt.NTSTATUS {
    const status = openVirtualInner(vfs, args, req, requested, key);
    args.iosb.u.Status = status;
    if (!nt.ok(status)) {
        args.iosb.Information = 0;
        vfs.open_failed.fire(.{ req, @backingInt(status) });
    }
    return status;
}

fn openVirtualInner(vfs: *Vfs, args: *const OpenArgs, req: *Vfs.OpenRequest, requested: ?[]const u8, key: []const u8) nt.NTSTATUS {
    const want_dir = req.directory;
    var info: usize = nt.FILE_OPENED;
    const node = if (vfs.store.lookup(key)) |existing| existing: {
        if (req.disposition == .create) {
            vfs.store.release(existing);
            return .OBJECT_NAME_COLLISION;
        }
        if ((want_dir == true and existing.kind == .file) or (want_dir == false and existing.kind == .dir)) {
            vfs.store.release(existing);
            return if (existing.kind == .file) nt.STATUS_NOT_A_DIRECTORY else nt.STATUS_FILE_IS_A_DIRECTORY;
        }
        switch (req.disposition) {
            .overwrite, .overwrite_or_create, .supersede => {
                if (existing.kind == .file) existing.truncate(vfs.allocator, 0) catch {};
                info = if (req.disposition == .supersede) nt.FILE_SUPERSEDED else nt.FILE_OVERWRITTEN;
            },
            else => {},
        }
        break :existing existing;
    } else created: {
        if (!req.disposition.creates()) return .OBJECT_NAME_NOT_FOUND;
        const kind: Vfs.Store.Kind = if (want_dir == true) .dir else .file;
        info = nt.FILE_CREATED;
        break :created vfs.store.create(req.path, kind, true) catch return nt.STATUS_INSUFFICIENT_RESOURCES;
    };
    defer vfs.store.release(node);

    const event = nt.CreateEventW(null, .TRUE, .TRUE, null) orelse return nt.STATUS_INSUFFICIENT_RESOURCES;
    const file = vfs.newFile(req.path, requested, .{
        .access = req.access,
        .kind = .virtual,
        .directory = node.kind == .dir,
        .node = node,
    }) catch {
        std.os.windows.CloseHandle(event);
        return nt.STATUS_INSUFFICIENT_RESOURCES;
    };
    file.state.options = args.options;
    file.state.delete_on_close = args.options & nt.FILE_DELETE_ON_CLOSE != 0;
    vfs.track(@intFromPtr(event), file);
    args.out.* = event;
    args.iosb.Information = info;
    vfs.opened.fire(.{file});
    return .SUCCESS;
}

/// Runs the open listeners for a lookup without a handle. Null if refused, with the status.
fn checkPath(vfs: *Vfs, oa: *nt.OBJECT_ATTRIBUTES, path_buf: *[names.max]u8, redirect_buf: *[names.max]u8) union(enum) { path: []const u8, denied: nt.NTSTATUS, untracked } {
    const path = names.resolve(vfs, oa, false, path_buf) orelse return .untracked;
    var req: Vfs.OpenRequest = .{
        .path = path,
        .requested = path,
        .access = .{},
        .disposition = .open,
        .directory = null,
        .thread = threadId(),
        .query = true,
        .loader = holdsLoaderLock(),
        .redirect_buf = redirect_buf,
    };
    vfs.open.fire(.{&req});
    if (req.denied) |d| return .{ .denied = denialStatus(d) };
    return .{ .path = req.path };
}

fn onAttributes(vfs: *Vfs, h: *TypedHook(nt.NtQueryAttributesFileFn), oa: *nt.OBJECT_ATTRIBUTES, out: *nt.FILE_BASIC_INFORMATION) callconv(.winapi) nt.NTSTATUS {
    if (!enter()) return h.original()(oa, out);
    defer leave();
    var path_buf: [names.max]u8 = undefined;
    var redirect_buf: [names.max]u8 = undefined;
    const path = switch (checkPath(vfs, oa, &path_buf, &redirect_buf)) {
        .untracked => return h.original()(oa, out),
        .denied => |s| return s,
        .path => |p| p,
    };
    if (virtualNode(vfs, path, oa, h.original(), out)) |node| {
        defer vfs.store.release(node);
        out.* = virtual.basicInfo(node);
        return .SUCCESS;
    }
    return queryReal(path, oa, h.original(), out);
}

fn onFullAttributes(vfs: *Vfs, h: *TypedHook(nt.NtQueryFullAttributesFileFn), oa: *nt.OBJECT_ATTRIBUTES, out: *nt.FILE_NETWORK_OPEN_INFORMATION) callconv(.winapi) nt.NTSTATUS {
    if (!enter()) return h.original()(oa, out);
    defer leave();
    var path_buf: [names.max]u8 = undefined;
    var redirect_buf: [names.max]u8 = undefined;
    const path = switch (checkPath(vfs, oa, &path_buf, &redirect_buf)) {
        .untracked => return h.original()(oa, out),
        .denied => |s| return s,
        .path => |p| p,
    };
    if (virtualNode(vfs, path, oa, h.original(), out)) |node| {
        defer vfs.store.release(node);
        out.* = virtual.networkInfo(node);
        return .SUCCESS;
    }
    return queryReal(path, oa, h.original(), out);
}

/// The virtual node to answer with. Folders only if the real one isn't there.
fn virtualNode(vfs: *Vfs, path: []const u8, oa: *nt.OBJECT_ATTRIBUTES, original: anytype, out: anytype) ?*Vfs.Store.Node {
    var key_buf: [names.max]u8 = undefined;
    const node = vfs.store.lookup(paths.key(&key_buf, path)) orelse return null;
    if (node.kind == .file) return node;
    if (notFound(queryReal(path, oa, original, out))) return node;
    vfs.store.release(node);
    return null;
}

fn queryReal(path: []const u8, oa: *nt.OBJECT_ATTRIBUTES, original: anytype, out: anytype) nt.NTSTATUS {
    var wide: [names.max]u16 = undefined;
    const name = names.toNt(path, &wide) orelse return original(oa, out);
    var us = nt.UNICODE_STRING.from(name);
    var copy = oa.*;
    copy.RootDirectory = null;
    copy.ObjectName = &us;
    return original(&copy, out);
}

fn onDelete(vfs: *Vfs, h: *TypedHook(nt.NtDeleteFileFn), oa: *nt.OBJECT_ATTRIBUTES) callconv(.winapi) nt.NTSTATUS {
    if (!enter()) return h.original()(oa);
    defer leave();
    var path_buf: [names.max]u8 = undefined;
    const path = names.resolve(vfs, oa, false, &path_buf) orelse return h.original()(oa);
    var key_buf: [names.max]u8 = undefined;
    if (vfs.store.exists(paths.key(&key_buf, path)) == .file) {
        _ = vfs.store.remove(paths.key(&key_buf, path));
        return .SUCCESS;
    }
    return h.original()(oa);
}

// Handles

fn onRead(vfs: *Vfs, h: *TypedHook(nt.NtReadFileFn), handle: nt.HANDLE, event: ?nt.HANDLE, apc: ?*const nt.IO_APC_ROUTINE, apc_context: ?*anyopaque, iosb: *nt.IO_STATUS_BLOCK, buffer: [*]u8, length: u32, offset: ?*const i64, key: ?*const u32) callconv(.winapi) nt.NTSTATUS {
    if (!enter()) return h.original()(handle, event, apc, apc_context, iosb, buffer, length, offset, key);
    defer leave();
    const file = vfs.lookup(@intFromPtr(handle)) orelse return h.original()(handle, event, apc, apc_context, iosb, buffer, length, offset, key);
    defer file.release(vfs);
    if (file.kind == .virtual) return virtual.read(vfs, file, .{ .event = event, .apc = apc, .apc_context = apc_context, .iosb = iosb }, buffer, length, offset);

    const status = h.original()(handle, event, apc, apc_context, iosb, buffer, length, offset, key);
    const at: ?u64 = if (offset) |o| (if (o.* >= 0) @intCast(o.*) else null) else null;
    if (status == .PENDING) {
        _ = file.stats.reads.fetchAdd(1, .monotonic);
        _ = file.stats.pending.fetchAdd(1, .monotonic);
        var r: Vfs.Read = .{ .file = file, .offset = at, .data = buffer[0..0], .requested = length, .pending = true };
        vfs.read.fire(.{&r});
    } else if (nt.ok(status)) {
        const n = @min(iosb.Information, length);
        _ = file.stats.reads.fetchAdd(1, .monotonic);
        _ = file.stats.bytes_read.fetchAdd(n, .monotonic);
        var r: Vfs.Read = .{ .file = file, .offset = at, .data = buffer[0..n], .requested = length, .pending = false };
        vfs.read.fire(.{&r});
    }
    return status;
}

fn onWrite(vfs: *Vfs, h: *TypedHook(nt.NtWriteFileFn), handle: nt.HANDLE, event: ?nt.HANDLE, apc: ?*const nt.IO_APC_ROUTINE, apc_context: ?*anyopaque, iosb: *nt.IO_STATUS_BLOCK, buffer: [*]const u8, length: u32, offset: ?*const i64, key: ?*const u32) callconv(.winapi) nt.NTSTATUS {
    if (!enter()) return h.original()(handle, event, apc, apc_context, iosb, buffer, length, offset, key);
    defer leave();
    const file = vfs.lookup(@intFromPtr(handle)) orelse return h.original()(handle, event, apc, apc_context, iosb, buffer, length, offset, key);
    defer file.release(vfs);

    const at: ?u64 = if (offset) |o| (if (o.* >= 0) @intCast(o.*) else null) else null;
    var w: Vfs.Write = .{ .file = file, .offset = at, .data = buffer[0..length] };
    vfs.write.fire(.{&w});
    if (w.denied) |d| {
        const status = denialStatus(d);
        iosb.u.Status = status;
        iosb.Information = 0;
        return status;
    }
    if (file.kind == .virtual) return virtual.write(vfs, file, .{ .event = event, .apc = apc, .apc_context = apc_context, .iosb = iosb }, buffer[0..length], offset);

    const status = h.original()(handle, event, apc, apc_context, iosb, buffer, length, offset, key);
    if (nt.ok(status)) {
        _ = file.stats.writes.fetchAdd(1, .monotonic);
        // Pending writes are counted in full, since they rarely come up short
        _ = file.stats.bytes_written.fetchAdd(if (status == .PENDING) length else @min(iosb.Information, length), .monotonic);
    }
    return status;
}

fn onClose(vfs: *Vfs, h: *TypedHook(nt.NtCloseFn), handle: nt.HANDLE) callconv(.winapi) nt.NTSTATUS {
    // Always untracked, or a reused handle value would look like the old file
    const file = vfs.untrack(@intFromPtr(handle));
    const status = h.original()(handle);
    if (file) |f| {
        if (status == nt.STATUS_HANDLE_NOT_CLOSABLE) {
            vfs.track(@intFromPtr(handle), f);
            return status;
        }
        const entered = enter();
        defer if (entered) leave();
        f.release(vfs);
    }
    return status;
}

fn onDuplicate(vfs: *Vfs, h: *TypedHook(nt.NtDuplicateObjectFn), source_process: nt.HANDLE, source: nt.HANDLE, target_process: ?nt.HANDLE, target: ?*nt.HANDLE, access: u32, attributes: u32, options: u32) callconv(.winapi) nt.NTSTATUS {
    const ours = source_process == nt.current_process;
    const closes = ours and options & nt.DUPLICATE_CLOSE_SOURCE != 0;
    const file = if (!ours) null else if (closes) vfs.untrack(@intFromPtr(source)) else vfs.lookup(@intFromPtr(source));
    const status = h.original()(source_process, source, target_process, target, access, attributes, options);
    const f = file orelse return status;
    if (nt.ok(status) and target_process == nt.current_process and target != null) {
        vfs.track(@intFromPtr(target.?.*), f);
    } else if (!nt.ok(status) and closes) {
        vfs.track(@intFromPtr(source), f);
    } else {
        f.release(vfs);
    }
    return status;
}

fn onQueryInfo(vfs: *Vfs, h: *TypedHook(nt.NtQueryInformationFileFn), handle: nt.HANDLE, iosb: *nt.IO_STATUS_BLOCK, buffer: [*]u8, length: u32, class: u32) callconv(.winapi) nt.NTSTATUS {
    const file = virtualFile(vfs, handle) orelse return h.original()(handle, iosb, buffer, length, class);
    defer file.release(vfs);
    return virtual.queryInfo(file, iosb, buffer, length, class);
}

fn onSetInfo(vfs: *Vfs, h: *TypedHook(nt.NtSetInformationFileFn), handle: nt.HANDLE, iosb: *nt.IO_STATUS_BLOCK, buffer: [*]const u8, length: u32, class: u32) callconv(.winapi) nt.NTSTATUS {
    const file = virtualFile(vfs, handle) orelse return h.original()(handle, iosb, buffer, length, class);
    defer file.release(vfs);
    if (!enter()) return virtual.setInfo(vfs, file, iosb, buffer, length, class);
    defer leave();
    return virtual.setInfo(vfs, file, iosb, buffer, length, class);
}

fn onQueryVolume(vfs: *Vfs, h: *TypedHook(nt.NtQueryVolumeInformationFileFn), handle: nt.HANDLE, iosb: *nt.IO_STATUS_BLOCK, buffer: [*]u8, length: u32, class: u32) callconv(.winapi) nt.NTSTATUS {
    const file = virtualFile(vfs, handle) orelse return h.original()(handle, iosb, buffer, length, class);
    defer file.release(vfs);
    return virtual.queryVolume(iosb, buffer, length, class);
}

fn onFlush(vfs: *Vfs, h: *TypedHook(nt.NtFlushBuffersFileFn), handle: nt.HANDLE, iosb: *nt.IO_STATUS_BLOCK) callconv(.winapi) nt.NTSTATUS {
    const file = virtualFile(vfs, handle) orelse return h.original()(handle, iosb);
    defer file.release(vfs);
    iosb.u.Status = .SUCCESS;
    iosb.Information = 0;
    return .SUCCESS;
}

fn onSection(vfs: *Vfs, h: *TypedHook(nt.NtCreateSectionFn), out: *nt.HANDLE, access: u32, oa: ?*nt.OBJECT_ATTRIBUTES, max_size: ?*i64, protect: u32, attributes: u32, handle: ?nt.HANDLE) callconv(.winapi) nt.NTSTATUS {
    const fh = handle orelse return h.original()(out, access, oa, max_size, protect, attributes, handle);
    const file = virtualFile(vfs, fh) orelse return h.original()(out, access, oa, max_size, protect, attributes, handle);
    defer file.release(vfs);
    return virtual.section(file, h.original(), out, oa, max_size, protect, attributes);
}

/// Virtual files answer even for bypassed threads, since the system can't.
fn virtualFile(vfs: *Vfs, handle: nt.HANDLE) ?*File {
    const file = vfs.lookup(@intFromPtr(handle)) orelse return null;
    if (file.kind == .virtual) return file;
    file.release(vfs);
    return null;
}

// Listings

fn onQueryDir(vfs: *Vfs, h: *TypedHook(nt.NtQueryDirectoryFileFn), handle: nt.HANDLE, event: ?nt.HANDLE, apc: ?*const nt.IO_APC_ROUTINE, apc_context: ?*anyopaque, iosb: *nt.IO_STATUS_BLOCK, buffer: [*]u8, length: u32, class: u32, single: u8, pattern: ?*nt.UNICODE_STRING, restart: u8) callconv(.winapi) nt.NTSTATUS {
    const Real = struct {
        original: *const nt.NtQueryDirectoryFileFn,
        handle: nt.HANDLE,
        event: ?nt.HANDLE,
        apc: ?*const nt.IO_APC_ROUTINE,
        apc_context: ?*anyopaque,
        iosb: *nt.IO_STATUS_BLOCK,
        buffer: [*]u8,
        length: u32,
        class: u32,
        single: u8,

        fn call(ctx: *const anyopaque, again: bool, p: ?*nt.UNICODE_STRING) nt.NTSTATUS {
            const s: *const @This() = @ptrCast(@alignCast(ctx));
            return s.original(s.handle, s.event, s.apc, s.apc_context, s.iosb, s.buffer, s.length, s.class, s.single, p, @intFromBool(again));
        }
    };
    const real: Real = .{ .original = h.original(), .handle = handle, .event = event, .apc = apc, .apc_context = apc_context, .iosb = iosb, .buffer = buffer, .length = length, .class = class, .single = single };
    return listDir(vfs, handle, .{
        .ctx = &real,
        .call = Real.call,
        .c = .{ .event = event, .apc = apc, .apc_context = apc_context, .iosb = iosb },
        .buffer = buffer,
        .length = length,
        .class = class,
        .single = single != 0,
        .restart = restart != 0,
        .pattern = pattern,
    });
}

fn onQueryDirEx(vfs: *Vfs, h: *TypedHook(nt.NtQueryDirectoryFileExFn), handle: nt.HANDLE, event: ?nt.HANDLE, apc: ?*const nt.IO_APC_ROUTINE, apc_context: ?*anyopaque, iosb: *nt.IO_STATUS_BLOCK, buffer: [*]u8, length: u32, class: u32, flags: u32, pattern: ?*nt.UNICODE_STRING) callconv(.winapi) nt.NTSTATUS {
    const Real = struct {
        original: *const nt.NtQueryDirectoryFileExFn,
        handle: nt.HANDLE,
        event: ?nt.HANDLE,
        apc: ?*const nt.IO_APC_ROUTINE,
        apc_context: ?*anyopaque,
        iosb: *nt.IO_STATUS_BLOCK,
        buffer: [*]u8,
        length: u32,
        class: u32,
        flags: u32,

        fn call(ctx: *const anyopaque, again: bool, p: ?*nt.UNICODE_STRING) nt.NTSTATUS {
            const s: *const @This() = @ptrCast(@alignCast(ctx));
            const f = (s.flags & ~nt.SL_RESTART_SCAN) | (if (again) nt.SL_RESTART_SCAN else 0);
            return s.original(s.handle, s.event, s.apc, s.apc_context, s.iosb, s.buffer, s.length, s.class, f, p);
        }
    };
    const real: Real = .{ .original = h.original(), .handle = handle, .event = event, .apc = apc, .apc_context = apc_context, .iosb = iosb, .buffer = buffer, .length = length, .class = class, .flags = flags };
    return listDir(vfs, handle, .{
        .ctx = &real,
        .call = Real.call,
        .c = .{ .event = event, .apc = apc, .apc_context = apc_context, .iosb = iosb },
        .buffer = buffer,
        .length = length,
        .class = class,
        .single = flags & nt.SL_RETURN_SINGLE_ENTRY != 0,
        .restart = flags & nt.SL_RESTART_SCAN != 0,
        .pattern = pattern,
    });
}

fn listDir(vfs: *Vfs, handle: nt.HANDLE, q: dirs.Query) nt.NTSTATUS {
    const file = vfs.lookup(@intFromPtr(handle)) orelse return q.call(q.ctx, q.restart, q.pattern);
    defer file.release(vfs);
    // Only merge real folders for listening threads, and always answer for virtual ones
    if (file.kind == .real and !enter()) return q.call(q.ctx, q.restart, q.pattern);
    defer if (file.kind == .real) leave();
    // Async listings can't be merged, so they get the real one
    if (file.kind == .real and (q.c.event != null or q.c.apc != null)) return q.call(q.ctx, q.restart, q.pattern);
    return dirs.query(vfs, file, q);
}

test {
    _ = names;
    _ = dirs;
    _ = virtual;
    _ = @import("tests.zig");
}
