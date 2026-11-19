//! What NT calls do on a virtual file's handle. The handle is really a signaled event,
//! so waits on it return right away, and every call here finishes before returning.

const std = @import("std");

const Vfs = @import("../root.zig");
const File = Vfs.File;
const Store = Vfs.Store;
const nt = @import("nt.zig");
const names = @import("names.zig");

/// Tags our file ids so they don't look like NTFS ones.
const id_tag: u64 = 0x7AF5 << 48;

pub fn attributes(kind: Store.Kind) u32 {
    return if (kind == .dir) nt.FILE_ATTRIBUTE_DIRECTORY else nt.FILE_ATTRIBUTE_ARCHIVE;
}

pub fn allocationSize(size: u64) i64 {
    return @intCast(std.mem.alignForward(u64, size, 4096));
}

pub fn basicInfo(node: *Store.Node) nt.FILE_BASIC_INFORMATION {
    const t = node.times();
    return .{ .CreationTime = t.created, .LastAccessTime = t.modified, .LastWriteTime = t.modified, .ChangeTime = t.modified, .FileAttributes = attributes(node.kind) };
}

pub fn networkInfo(node: *Store.Node) nt.FILE_NETWORK_OPEN_INFORMATION {
    const t = node.times();
    const size = node.size();
    return .{
        .CreationTime = t.created,
        .LastAccessTime = t.modified,
        .LastWriteTime = t.modified,
        .ChangeTime = t.modified,
        .AllocationSize = allocationSize(size),
        .EndOfFile = @intCast(size),
        .FileAttributes = attributes(node.kind),
    };
}

pub const Completion = struct {
    event: ?nt.HANDLE,
    apc: ?*const nt.IO_APC_ROUTINE,
    apc_context: ?*anyopaque,
    iosb: *nt.IO_STATUS_BLOCK,
};

/// Fills in the status and signals whoever's waiting, like the system does for I/O that finishes right away.
pub fn complete(file: *File, c: Completion, status: nt.NTSTATUS, information: usize) nt.NTSTATUS {
    c.iosb.u.Status = status;
    c.iosb.Information = information;
    if (!nt.ok(status)) return status;
    if (c.event) |e| _ = nt.SetEvent(e);
    if (c.apc) |apc| {
        _ = nt.NtQueueApcThread(nt.current_thread, @ptrCast(apc), c.apc_context, c.iosb, null);
        return status;
    }
    file.state.lock.lockShared();
    const port = file.state.port;
    const key = file.state.port_key;
    const skip = file.state.skip_port_on_success;
    file.state.lock.unlockShared();
    // No context means the caller asked for no packet, like an event with its low bit set
    if (port != null and c.apc_context != null and !skip) {
        _ = nt.NtSetIoCompletion(port.?, key, c.apc_context, status, information);
    }
    return status;
}

/// Where the call starts, under the file's state lock.
fn startOffset(file: *File, offset: ?*const i64, end: u64) u64 {
    const o = if (offset) |p| p.* else nt.use_position;
    if (o == nt.write_to_end or (file.access.append and !file.access.write)) return end;
    if (o < 0) return file.state.position;
    return @intCast(o);
}

pub fn read(vfs: *Vfs, file: *File, c: Completion, buffer: [*]u8, length: u32, offset: ?*const i64) nt.NTSTATUS {
    if (file.directory) return nt.STATUS_INVALID_DEVICE_REQUEST;
    if (!file.access.read) return .ACCESS_DENIED;
    const node = file.node.?;
    file.state.lock.lock();
    const start = startOffset(file, offset, node.size());
    const n = node.read(start, buffer[0..length]);
    file.state.position = start + n;
    file.state.lock.unlock();

    _ = file.stats.reads.fetchAdd(1, .monotonic);
    _ = file.stats.bytes_read.fetchAdd(n, .monotonic);
    var r: Vfs.Read = .{ .file = file, .offset = start, .data = buffer[0..n], .requested = length, .pending = false };
    vfs.read.fire(.{&r});
    const status: nt.NTSTATUS = if (n == 0 and length > 0) .END_OF_FILE else .SUCCESS;
    return complete(file, c, status, n);
}

pub fn write(vfs: *Vfs, file: *File, c: Completion, data: []const u8, offset: ?*const i64) nt.NTSTATUS {
    if (file.directory) return nt.STATUS_INVALID_DEVICE_REQUEST;
    if (!file.access.write and !file.access.append) return .ACCESS_DENIED;
    const node = file.node.?;
    file.state.lock.lock();
    const start = startOffset(file, offset, node.size());
    node.write(vfs.allocator, start, data) catch {
        file.state.lock.unlock();
        return nt.STATUS_INSUFFICIENT_RESOURCES;
    };
    file.state.position = start + data.len;
    file.state.lock.unlock();
    _ = file.stats.writes.fetchAdd(1, .monotonic);
    _ = file.stats.bytes_written.fetchAdd(data.len, .monotonic);
    return complete(file, c, .SUCCESS, data.len);
}

/// Copies `value` into `out`, returning the status and how much it wrote.
fn put(out: []u8, value: anytype) struct { nt.NTSTATUS, usize } {
    const bytes = std.mem.asBytes(&value);
    if (out.len < bytes.len) return .{ .INFO_LENGTH_MISMATCH, 0 };
    @memcpy(out[0..bytes.len], bytes);
    return .{ .SUCCESS, bytes.len };
}

/// A `FileNameLength` plus name, cut short with `BUFFER_OVERFLOW` if it doesn't fit.
fn putName(out: []u8, path: []const u8) struct { nt.NTSTATUS, usize } {
    if (out.len < 4) return .{ .INFO_LENGTH_MISMATCH, 0 };
    var wide: [names.max]u16 = undefined;
    const rel = names.volumeRelative(path);
    const n = std.unicode.wtf8ToWtf16Le(&wide, rel) catch 0;
    std.mem.replaceScalar(u16, wide[0..n], Vfs.paths.sep, '\\');
    const bytes = std.mem.sliceAsBytes(wide[0..n]);
    std.mem.writeInt(u32, out[0..4], @intCast(bytes.len), .little);
    const fit = @min(bytes.len, out.len - 4);
    @memcpy(out[4..][0..fit], bytes[0..fit]);
    return .{ if (fit < bytes.len) .BUFFER_OVERFLOW else .SUCCESS, 4 + fit };
}

const ModeInfo = extern struct { mode: u32 };
const U32Info = extern struct { value: u32 };
const I64Info = extern struct { value: i64 };

pub fn queryInfo(file: *File, iosb: *nt.IO_STATUS_BLOCK, buffer: [*]u8, length: u32, class: u32) nt.NTSTATUS {
    const out = buffer[0..length];
    const node = file.node.?;
    const size = node.size();
    file.state.lock.lockShared();
    const position = file.state.position;
    const delete_pending = file.state.delete_on_close;
    const mode = file.state.options & (nt.FILE_SYNCHRONOUS_IO_ALERT | nt.FILE_SYNCHRONOUS_IO_NONALERT | nt.FILE_DELETE_ON_CLOSE);
    file.state.lock.unlockShared();
    const standard: nt.FILE_STANDARD_INFORMATION = .{
        .AllocationSize = allocationSize(size),
        .EndOfFile = @intCast(size),
        .NumberOfLinks = 1,
        .DeletePending = @intFromBool(delete_pending),
        .Directory = @intFromBool(node.kind == .dir),
    };
    const result: struct { nt.NTSTATUS, usize } = switch (class) {
        nt.FileInfoClass.basic => put(out, basicInfo(node)),
        nt.FileInfoClass.standard => put(out, standard),
        nt.FileInfoClass.internal => put(out, I64Info{ .value = @bitCast(id_tag | node.id) }),
        nt.FileInfoClass.ea => put(out, U32Info{ .value = 0 }),
        nt.FileInfoClass.access => put(out, U32Info{ .value = accessMask(file.access) }),
        nt.FileInfoClass.name, nt.FileInfoClass.normalized_name => putName(out, file.path),
        nt.FileInfoClass.position => put(out, I64Info{ .value = @intCast(position) }),
        nt.FileInfoClass.mode => put(out, ModeInfo{ .mode = mode }),
        nt.FileInfoClass.alignment => put(out, U32Info{ .value = 0 }),
        nt.FileInfoClass.network_open => put(out, networkInfo(node)),
        nt.FileInfoClass.attribute_tag => put(out, extern struct { attributes: u32, tag: u32 }{ .attributes = attributes(node.kind), .tag = 0 }),
        nt.FileInfoClass.id => put(out, extern struct { volume: u64, id: [2]u64 }{ .volume = id_tag, .id = .{ id_tag | node.id, 0 } }),
        nt.FileInfoClass.all => all: {
            const All = extern struct {
                basic: nt.FILE_BASIC_INFORMATION,
                standard: nt.FILE_STANDARD_INFORMATION,
                internal: I64Info,
                ea: U32Info,
                access: U32Info,
                position: I64Info,
                mode: ModeInfo,
                alignment: U32Info,
            };
            const fixed: All = .{
                .basic = basicInfo(node),
                .standard = standard,
                .internal = .{ .value = @bitCast(id_tag | node.id) },
                .ea = .{ .value = 0 },
                .access = .{ .value = accessMask(file.access) },
                .position = .{ .value = @intCast(position) },
                .mode = .{ .mode = mode },
                .alignment = .{ .value = 0 },
            };
            const head = @offsetOf(All, "alignment") + @sizeOf(U32Info);
            if (out.len < head + 4) break :all .{ .INFO_LENGTH_MISMATCH, 0 };
            @memcpy(out[0..head], std.mem.asBytes(&fixed)[0..head]);
            const name = putName(out[head..], file.path);
            break :all .{ name[0], head + name[1] };
        },
        else => .{ .INVALID_INFO_CLASS, 0 },
    };
    iosb.u.Status = result[0];
    iosb.Information = result[1];
    return result[0];
}

fn accessMask(access: Vfs.Access) u32 {
    var mask: u32 = 0x00120080; // read control, synchronize, read attributes
    if (access.read) mask |= nt.FILE_READ_DATA;
    if (access.write) mask |= nt.FILE_WRITE_DATA;
    if (access.append) mask |= nt.FILE_APPEND_DATA;
    if (access.execute) mask |= nt.FILE_EXECUTE;
    if (access.delete) mask |= nt.DELETE;
    return mask;
}

pub fn setInfo(vfs: *Vfs, file: *File, iosb: *nt.IO_STATUS_BLOCK, buffer: [*]const u8, length: u32, class: u32) nt.NTSTATUS {
    const in = buffer[0..length];
    const node = file.node.?;
    const status: nt.NTSTATUS = switch (class) {
        nt.FileInfoClass.basic, nt.FileInfoClass.allocation, nt.FileInfoClass.mode => .SUCCESS,
        nt.FileInfoClass.position => pos: {
            if (in.len < 8) break :pos .INFO_LENGTH_MISMATCH;
            const v = std.mem.readInt(i64, in[0..8], .little);
            if (v < 0) break :pos .INVALID_PARAMETER;
            file.state.lock.lock();
            file.state.position = @intCast(v);
            file.state.lock.unlock();
            break :pos .SUCCESS;
        },
        nt.FileInfoClass.end_of_file => eof: {
            if (in.len < 8) break :eof .INFO_LENGTH_MISMATCH;
            if (file.directory) break :eof .INVALID_PARAMETER;
            if (!file.access.write) break :eof .ACCESS_DENIED;
            const v = std.mem.readInt(i64, in[0..8], .little);
            if (v < 0) break :eof .INVALID_PARAMETER;
            node.truncate(vfs.allocator, @intCast(v)) catch break :eof nt.STATUS_INSUFFICIENT_RESOURCES;
            break :eof .SUCCESS;
        },
        nt.FileInfoClass.disposition => d: {
            if (in.len < 1) break :d .INFO_LENGTH_MISMATCH;
            break :d markDelete(vfs, file, in[0] != 0, false);
        },
        nt.FileInfoClass.disposition_ex => d: {
            if (in.len < 4) break :d .INFO_LENGTH_MISMATCH;
            const flags = std.mem.readInt(u32, in[0..4], .little);
            break :d markDelete(vfs, file, flags & nt.FILE_DISPOSITION_DELETE != 0, flags & nt.FILE_DISPOSITION_POSIX_SEMANTICS != 0);
        },
        nt.FileInfoClass.rename, nt.FileInfoClass.rename_ex => rename(vfs, file, in, class == nt.FileInfoClass.rename_ex),
        nt.FileInfoClass.completion => c: {
            if (in.len < @sizeOf(nt.FILE_COMPLETION_INFORMATION)) break :c .INFO_LENGTH_MISMATCH;
            const info = std.mem.bytesToValue(nt.FILE_COMPLETION_INFORMATION, in[0..@sizeOf(nt.FILE_COMPLETION_INFORMATION)]);
            file.state.lock.lock();
            file.state.port = info.Port;
            file.state.port_key = info.Key;
            file.state.lock.unlock();
            break :c .SUCCESS;
        },
        nt.FileInfoClass.io_completion_notification => n: {
            if (in.len < 4) break :n .INFO_LENGTH_MISMATCH;
            const flags = std.mem.readInt(u32, in[0..4], .little);
            file.state.lock.lock();
            file.state.skip_port_on_success = flags & nt.FILE_SKIP_COMPLETION_PORT_ON_SUCCESS != 0;
            file.state.lock.unlock();
            break :n .SUCCESS;
        },
        else => .INVALID_INFO_CLASS,
    };
    iosb.u.Status = status;
    iosb.Information = 0;
    return status;
}

fn markDelete(vfs: *Vfs, file: *File, delete: bool, now: bool) nt.NTSTATUS {
    if (delete and !file.access.delete) return .ACCESS_DENIED;
    const node = file.node.?;
    if (delete and node.kind == .dir and vfs.store.hasChildren(node.key)) return nt.STATUS_DIRECTORY_NOT_EMPTY;
    if (delete and now) {
        vfs.store.unlink(node);
        return .SUCCESS;
    }
    file.state.lock.lock();
    file.state.delete_on_close = delete;
    file.state.lock.unlock();
    return .SUCCESS;
}

fn rename(vfs: *Vfs, file: *File, in: []const u8, ex: bool) nt.NTSTATUS {
    const head = @offsetOf(nt.FILE_RENAME_INFORMATION, "FileName");
    if (in.len < head) return .INFO_LENGTH_MISMATCH;
    const info: *align(1) const nt.FILE_RENAME_INFORMATION = @ptrCast(in.ptr);
    const name_len = info.FileNameLength;
    if (in.len < head + name_len) return .INFO_LENGTH_MISMATCH;
    const replace = if (ex) info.Flags & nt.FILE_RENAME_REPLACE_IF_EXISTS != 0 else (info.Flags & 0xFF) != 0;
    var wide: [names.max]u16 = undefined;
    const chars = name_len / 2;
    if (chars > wide.len) return .INVALID_PARAMETER;
    @memcpy(std.mem.sliceAsBytes(wide[0..chars]), in[head..][0 .. chars * 2]);
    var us = nt.UNICODE_STRING.from(wide[0..chars]);
    const oa: nt.OBJECT_ATTRIBUTES = .{ .Length = @sizeOf(nt.OBJECT_ATTRIBUTES), .RootDirectory = info.RootDirectory, .ObjectName = &us, .Attributes = 0, .SecurityDescriptor = null, .SecurityQualityOfService = null };
    var buf: [names.max]u8 = undefined;
    const target = names.resolve(vfs, &oa, false, &buf) orelse return .INVALID_PARAMETER;
    vfs.store.rename(file.node.?, target, replace) catch |err| return switch (err) {
        error.Exists => .OBJECT_NAME_COLLISION,
        error.NotFound => .OBJECT_NAME_NOT_FOUND,
        error.IsDirectory, error.NotADirectory => .ACCESS_DENIED,
        else => nt.STATUS_INSUFFICIENT_RESOURCES,
    };
    return .SUCCESS;
}

pub fn queryVolume(iosb: *nt.IO_STATUS_BLOCK, buffer: [*]u8, length: u32, class: u32) nt.NTSTATUS {
    const out = buffer[0..length];
    // Plenty of room, and nothing to say about it
    const units: i64 = 1 << 30;
    const result: struct { nt.NTSTATUS, usize } = switch (class) {
        nt.FsInfoClass.device => put(out, extern struct { device: u32, characteristics: u32 }{ .device = nt.FILE_DEVICE_DISK, .characteristics = 0 }),
        nt.FsInfoClass.size => put(out, extern struct { total: i64, available: i64, sectors: u32, bytes: u32 }{ .total = units, .available = units, .sectors = 8, .bytes = 512 }),
        nt.FsInfoClass.full_size => put(out, extern struct { total: i64, caller: i64, actual: i64, sectors: u32, bytes: u32 }{ .total = units, .caller = units, .actual = units, .sectors = 8, .bytes = 512 }),
        nt.FsInfoClass.volume => put(out, extern struct { created: i64, serial: u32, label_len: u32, objects: u8 }{ .created = 0, .serial = 0x7AF5, .label_len = 0, .objects = 0 }),
        nt.FsInfoClass.attribute => attr: {
            const name = std.unicode.utf8ToUtf16LeStringLiteral("NTFS");
            const Head = extern struct { attributes: u32, max_component: i32, name_len: u32 };
            const head: Head = .{ .attributes = 0x3, .max_component = 255, .name_len = name.len * 2 };
            if (out.len < @sizeOf(Head)) break :attr .{ .INFO_LENGTH_MISMATCH, 0 };
            @memcpy(out[0..@sizeOf(Head)], std.mem.asBytes(&head));
            const bytes = std.mem.sliceAsBytes(name);
            const fit = @min(bytes.len, out.len - @sizeOf(Head));
            @memcpy(out[@sizeOf(Head)..][0..fit], bytes[0..fit]);
            break :attr .{ if (fit < bytes.len) .BUFFER_OVERFLOW else .SUCCESS, @sizeOf(Head) + fit };
        },
        else => .{ .INVALID_INFO_CLASS, 0 },
    };
    iosb.u.Status = result[0];
    iosb.Information = result[1];
    return result[0];
}

/// A pagefile section with a copy of the bytes. Writes through it don't reach the file.
pub fn section(file: *File, original: *const nt.NtCreateSectionFn, out: *nt.HANDLE, oa: ?*nt.OBJECT_ATTRIBUTES, max_size: ?*i64, protect: u32, attributes_: u32) nt.NTSTATUS {
    if (attributes_ & nt.SEC_IMAGE != 0) return nt.STATUS_INVALID_IMAGE_FORMAT;
    if (file.directory) return nt.STATUS_INVALID_DEVICE_REQUEST;
    const node = file.node.?;
    const file_size = node.size();
    const wanted: u64 = if (max_size) |m| (if (m.* > 0) @intCast(m.*) else file_size) else file_size;
    if (wanted == 0) return nt.STATUS_MAPPED_FILE_SIZE_ZERO;
    const len = std.math.cast(usize, wanted) orelse return nt.STATUS_INSUFFICIENT_RESOURCES;
    var size: i64 = @intCast(wanted);
    const executable = protect & 0xF0 != 0;
    const status = original(out, nt.SECTION_ALL_ACCESS, oa, &size, if (executable) nt.PAGE_EXECUTE_READWRITE else nt.PAGE_READWRITE, nt.SEC_COMMIT, null);
    if (!nt.ok(status)) return status;
    const view = nt.MapViewOfFile(out.*, nt.FILE_MAP_WRITE, 0, 0, len) orelse return status;
    _ = node.read(0, view[0..len]);
    _ = nt.UnmapViewOfFile(view);
    return status;
}
