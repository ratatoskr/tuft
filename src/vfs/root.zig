//! Sees every file the process opens, reads, writes and closes, and serves in-memory files.
//! Listeners run on the thread doing the I/O, so they can change or refuse it.
//! Paths are WTF-8 with forward slashes; devices and pipes keep NT names. Input takes either slash.
//! Handles opened before `init` aren't tracked, nor ignored threads or listeners' own I/O.

const Vfs = @This();

const std = @import("std");
const builtin = @import("builtin");

const sys = @import("tuft_sys");
const RwLock = sys.sync.RwLock;
const Event = @import("tuft_event").Event;
const atomic = @import("tuft_arch").atomic;

pub const paths = @import("paths.zig");
pub const Store = @import("Store.zig");

pub const native = switch (builtin.os.tag) {
    .windows => @import("win/root.zig"),
    else => @compileError("Unsupported operating system"),
};

pub const Access = bitpack struct(u8) {
    read: bool = false,
    write: bool = false,
    /// Appends only, like `FILE_APPEND_DATA` without write.
    append: bool = false,
    delete: bool = false,
    execute: bool = false,
    _: u3 = 0,
};

pub const Disposition = enum {
    /// Fails if missing.
    open,
    /// Fails if it exists.
    create,
    open_or_create,
    /// Empties it. Fails if missing.
    overwrite,
    /// Empties or makes it.
    overwrite_or_create,
    /// Replaces it, or makes it.
    supersede,

    pub fn creates(self: Disposition) bool {
        return self != .open and self != .overwrite;
    }
};

/// What a listener can make an open, read or write fail with.
pub const Denial = enum { access_denied, not_found, sharing_violation, write_protected };

pub const Kind = enum {
    real,
    /// Served from `Store`.
    virtual,
};

/// One open file. Duplicated handles share it, like the system's file objects.
pub const File = struct {
    id: u64,
    /// Where it really is.
    path: []const u8,
    /// What the game asked for, if a listener redirected it.
    requested: ?[]const u8,
    access: Access,
    kind: Kind,
    directory: bool,
    /// Who opened it.
    thread: u32,
    /// `sys.clock.nanos` at open.
    opened_ns: u64,
    stats: Stats = .{},

    refs: std.atomic.Value(u32) = .init(1),
    /// Live handles to it. Duplicates add one.
    handles: std.atomic.Value(u32) = .init(0),
    node: ?*Store.Node = null,
    /// Platform state, like a virtual file's position.
    state: native.FileState = .{},
    /// Where `path` and `requested` are kept, kept with it when it's reused, so opening doesn't allocate
    path_room: []u8 = &.{},
    requested_room: []u8 = &.{},
    /// On `Vfs.spare` once closed
    next_spare: ?*File = null,

    pub const Stats = struct {
        reads: atomic.Value(u64) = .init(0),
        writes: atomic.Value(u64) = .init(0),
        bytes_read: atomic.Value(u64) = .init(0),
        bytes_written: atomic.Value(u64) = .init(0),
        /// Reads still in flight when they returned, so their size isn't counted.
        pending: atomic.Value(u64) = .init(0),
    };

    pub fn retain(self: *File) void {
        _ = self.refs.fetchAdd(1, .monotonic);
    }

    /// Fires `closed` when the last one goes.
    pub fn release(self: *File, vfs: *Vfs) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        vfs.closed.fire(.{self});
        self.state.deinit(vfs, self);
        if (self.node) |n| vfs.store.release(n);
        vfs.spareFile(self);
    }

    fn free(self: *File, allocator: std.mem.Allocator) void {
        allocator.free(self.path_room);
        allocator.free(self.requested_room);
        allocator.destroy(self);
    }
};

/// `text` in `room`, grown if it's too small. Rounded up, so a slightly longer path fits next time.
fn keep(allocator: std.mem.Allocator, room: *[]u8, text: []const u8) ![]const u8 {
    if (room.len < text.len) {
        const grown = try allocator.alloc(u8, std.mem.alignForward(usize, @max(text.len, 128), 128));
        allocator.free(room.*);
        room.* = grown;
    }
    @memcpy(room.*[0..text.len], text);
    return room.*[0..text.len];
}

/// Before an open. Listeners can redirect or refuse it.
pub const OpenRequest = struct {
    /// The redirected path, after a listener calls `redirect`.
    path: []const u8,
    requested: []const u8,
    access: Access,
    disposition: Disposition,
    /// True for folders only, false for files only, null for either.
    directory: ?bool,
    thread: u32,
    /// Only checking it's there, like `GetFileAttributes`. No handle comes of it.
    query: bool = false,
    /// The loader is opening a DLL and holds its lock. Don't wait on other threads here.
    loader: bool = false,
    denied: ?Denial = null,
    redirect_buf: []u8,

    /// Opens `path` instead, which can be a virtual file. Later listeners see the new path.
    pub fn redirect(self: *OpenRequest, path: []const u8) !void {
        self.path = try paths.normalize(self.redirect_buf, path);
    }

    pub fn deny(self: *OpenRequest, why: Denial) void {
        self.denied = why;
    }
};

/// After a read. Listeners can change `data`, which is what the game gets.
pub const Read = struct {
    file: *const File,
    /// Null when it reads from the current position of a real file.
    offset: ?u64,
    /// What it got. Empty while `pending`.
    data: []u8,
    requested: usize,
    /// Still in flight, finishing later. Only real files do this.
    pending: bool,
};

/// Before a write. Listeners can refuse it.
pub const Write = struct {
    file: *const File,
    /// Null when it writes at the current position of a real file.
    offset: ?u64,
    data: []const u8,
    denied: ?Denial = null,

    pub fn deny(self: *Write, why: Denial) void {
        self.denied = why;
    }
};

/// A copy of one open file, for tools.
pub const Snapshot = struct {
    id: u64,
    path: []u8,
    requested: ?[]u8,
    access: Access,
    kind: Kind,
    directory: bool,
    thread: u32,
    opened_ns: u64,
    handles: u32,
    reads: u64,
    writes: u64,
    bytes_read: u64,
    bytes_written: u64,
    pending: u64,
};

allocator: std.mem.Allocator,
store: Store,
/// Handle to its file. Each entry holds a ref.
table: std.AutoHashMapUnmanaged(usize, *File) = .empty,
table_lock: RwLock = .{},
next_id: atomic.Value(u64) = .init(1),
/// Closed files kept for the next opens, with their paths' room, so the game opening files doesn't allocate
spare: ?*File = null,
spare_count: usize = 0,
spare_lock: sys.sync.Mutex = .{},
hooks: native.Hooks = .{},

/// Before each open. Call `redirect` or `deny` on the request.
open: Event(fn (*OpenRequest) void),
/// After a successful open.
opened: Event(fn (*const File) void),
/// After a failed one, with the system's status, like an `NTSTATUS`.
open_failed: Event(fn (*const OpenRequest, u32) void),
read: Event(fn (*Read) void),
write: Event(fn (*Write) void),
/// When the last handle closes.
closed: Event(fn (*const File) void),

var instance: std.atomic.Value(?*Vfs) = .init(null);

/// Hooks the system's file calls. One per process.
pub fn init(allocator: std.mem.Allocator) !*Vfs {
    const self = try allocator.create(Vfs);
    errdefer allocator.destroy(self);
    self.* = .{
        .allocator = allocator,
        .store = .init(allocator),
        .open = .init(allocator),
        .opened = .init(allocator),
        .open_failed = .init(allocator),
        .read = .init(allocator),
        .write = .init(allocator),
        .closed = .init(allocator),
    };
    if (instance.cmpxchgStrong(null, self, .acq_rel, .acquire) != null) return error.AlreadyInitialized;
    errdefer instance.store(null, .release);
    try self.hooks.install(self);
    return self;
}

/// Unhooks. Virtual files still open in the game stop working.
pub fn deinit(self: *Vfs) void {
    self.hooks.uninstall();
    instance.store(null, .release);
    var it = self.table.valueIterator();
    while (it.next()) |f| f.*.release(self);
    self.table.deinit(self.allocator);
    while (self.spare) |f| {
        self.spare = f.next_spare;
        f.free(self.allocator);
    }
    self.store.deinit();
    self.open.deinit();
    self.opened.deinit();
    self.open_failed.deinit();
    self.read.deinit();
    self.write.deinit();
    self.closed.deinit();
    self.allocator.destroy(self);
}

pub fn get() ?*Vfs {
    return instance.load(.acquire);
}

threadlocal var ignored: bool = false;
threadlocal var bypass_depth: u32 = 0;

/// For our own worker threads, like a log writer. Their I/O goes straight through, forever.
pub fn ignoreThread() void {
    ignored = true;
}

/// This thread's I/O goes straight through until `endBypass`. Nests.
pub fn beginBypass() void {
    bypass_depth += 1;
}

pub fn endBypass() void {
    bypass_depth -= 1;
}

/// False while bypassed or ignored, or inside our own hooks.
pub fn active() bool {
    return !ignored and bypass_depth == 0;
}

// Files

/// Serves `bytes` at `path`, replacing any file there. It shadows a real one.
pub fn put(self: *Vfs, path: []const u8, bytes: []const u8) !void {
    var buf: [1024]u8 = undefined;
    try self.store.put(try paths.normalize(&buf, path), bytes);
}

/// A virtual folder, so the game can list and create files in it.
pub fn putDir(self: *Vfs, path: []const u8) !void {
    var buf: [1024]u8 = undefined;
    const node = try self.store.create(try paths.normalize(&buf, path), .dir, true);
    self.store.release(node);
}

/// Removes a virtual file or folder, and everything in it. Open handles keep working.
pub fn remove(self: *Vfs, path: []const u8) bool {
    var buf: [1024]u8 = undefined;
    const p = paths.normalize(&buf, path) catch return false;
    return self.store.remove(paths.key(p, p));
}

/// A copy of a virtual file's bytes.
pub fn contents(self: *Vfs, allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    var buf: [1024]u8 = undefined;
    const p = try paths.normalize(&buf, path);
    const node = self.store.lookup(paths.key(p, p)) orelse return null;
    defer self.store.release(node);
    if (node.kind != .file) return error.IsDirectory;
    node.lock.lockShared();
    defer node.lock.unlockShared();
    return try allocator.dupe(u8, node.data.items);
}

pub fn exists(self: *Vfs, path: []const u8) ?Store.Kind {
    var buf: [1024]u8 = undefined;
    const p = paths.normalize(&buf, path) catch return null;
    return self.store.exists(paths.key(p, p));
}

// Handles

/// Adds a handle for `file`, taking one ref.
pub fn track(self: *Vfs, handle: usize, file: *File) void {
    _ = file.handles.fetchAdd(1, .monotonic);
    self.table_lock.lock();
    const old = self.table.fetchPut(self.allocator, handle, file) catch {
        self.table_lock.unlock();
        _ = file.handles.fetchSub(1, .monotonic);
        file.release(self);
        return;
    };
    self.table_lock.unlock();
    // Closed some way we didn't see, and the system reused the value
    if (old) |o| {
        _ = o.value.handles.fetchSub(1, .monotonic);
        o.value.release(self);
    }
}

/// Retained, or null if we don't know the handle.
pub fn lookup(self: *Vfs, handle: usize) ?*File {
    self.table_lock.lockShared();
    defer self.table_lock.unlockShared();
    const f = self.table.get(handle) orelse return null;
    f.retain();
    return f;
}

/// Removes the handle and hands over its ref.
pub fn untrack(self: *Vfs, handle: usize) ?*File {
    self.table_lock.lock();
    defer self.table_lock.unlock();
    const kv = self.table.fetchRemove(handle) orelse return null;
    _ = kv.value.handles.fetchSub(1, .monotonic);
    return kv.value;
}

pub fn newFile(self: *Vfs, path: []const u8, requested: ?[]const u8, options: struct {
    access: Access,
    kind: Kind,
    directory: bool,
    node: ?*Store.Node = null,
}) !*File {
    const file = self.takeSpare() orelse made: {
        const f = try self.allocator.create(File);
        f.path_room = &.{};
        f.requested_room = &.{};
        break :made f;
    };
    var path_room = file.path_room;
    var requested_room = file.requested_room;
    // Kept, rooms and all, for the next
    errdefer {
        file.path_room = path_room;
        file.requested_room = requested_room;
        self.spareFile(file);
    }
    const owned_path = try keep(self.allocator, &path_room, path);
    const owned_requested = if (requested) |r| try keep(self.allocator, &requested_room, r) else null;
    file.* = .{
        .id = self.next_id.fetchAdd(1, .monotonic),
        .path = owned_path,
        .requested = owned_requested,
        .path_room = path_room,
        .requested_room = requested_room,
        .access = options.access,
        .kind = options.kind,
        .directory = options.directory,
        .thread = native.threadId(),
        .opened_ns = sys.clock.nanos(),
        .node = options.node,
    };
    if (options.node) |n| n.retain();
    return file;
}

/// Most closed files kept for reuse.
const max_spare = 64;

fn takeSpare(self: *Vfs) ?*File {
    self.spare_lock.lock();
    defer self.spare_lock.unlock();
    const f = self.spare orelse return null;
    self.spare = f.next_spare;
    self.spare_count -= 1;
    return f;
}

/// Kept for the next open, or freed past `max_spare`.
fn spareFile(self: *Vfs, f: *File) void {
    self.spare_lock.lock();
    if (self.spare_count < max_spare) {
        f.next_spare = self.spare;
        self.spare = f;
        self.spare_count += 1;
        self.spare_lock.unlock();
        return;
    }
    self.spare_lock.unlock();
    f.free(self.allocator);
}

/// Copies of every open file, oldest first. Free with `freeSnapshots`.
pub fn openFiles(self: *Vfs, allocator: std.mem.Allocator) ![]Snapshot {
    var seen: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer seen.deinit(allocator);
    var out: std.ArrayList(Snapshot) = .empty;
    errdefer freeSnapshots(allocator, out.items);
    errdefer out.deinit(allocator);

    self.table_lock.lockShared();
    defer self.table_lock.unlockShared();
    var it = self.table.valueIterator();
    while (it.next()) |fp| {
        const f = fp.*;
        if ((try seen.getOrPut(allocator, f.id)).found_existing) continue;
        const path = try allocator.dupe(u8, f.path);
        errdefer allocator.free(path);
        const requested = if (f.requested) |r| try allocator.dupe(u8, r) else null;
        errdefer if (requested) |r| allocator.free(r);
        try out.append(allocator, .{
            .id = f.id,
            .path = path,
            .requested = requested,
            .access = f.access,
            .kind = f.kind,
            .directory = f.directory,
            .thread = f.thread,
            .opened_ns = f.opened_ns,
            .handles = f.handles.load(.monotonic),
            .reads = f.stats.reads.load(.monotonic),
            .writes = f.stats.writes.load(.monotonic),
            .bytes_read = f.stats.bytes_read.load(.monotonic),
            .bytes_written = f.stats.bytes_written.load(.monotonic),
            .pending = f.stats.pending.load(.monotonic),
        });
    }
    std.mem.sort(Snapshot, out.items, {}, struct {
        fn older(_: void, a: Snapshot, b: Snapshot) bool {
            return a.id < b.id;
        }
    }.older);
    return out.toOwnedSlice(allocator);
}

pub fn freeSnapshots(allocator: std.mem.Allocator, snapshots: []Snapshot) void {
    for (snapshots) |s| {
        allocator.free(s.path);
        if (s.requested) |r| allocator.free(r);
    }
    allocator.free(snapshots);
}

test {
    std.testing.refAllDecls(@This());
    _ = paths;
    _ = Store;
    _ = native;
}
