//! In-memory files and the folders they imply.
//! Nodes are refcounted, so open handles keep a removed file's bytes until they close.

const Store = @This();

const std = @import("std");
const RwLock = @import("tuft_sys").sync.RwLock;

const paths = @import("paths.zig");
const native = @import("root.zig").native;

pub const Kind = enum { file, dir };

pub const Node = struct {
    refs: std.atomic.Value(u32) = .init(1),
    kind: Kind,
    /// Made for something under it, and goes away with its last child.
    implicit: bool,
    id: u64,
    // Store lock guards these, since renames and removes change them
    path: []u8,
    key: []u8,
    children: u32 = 0,
    linked: bool = true,
    /// Guards the rest.
    lock: RwLock = .{},
    data: std.ArrayList(u8) = .empty,
    /// NT time, 100ns since 1601.
    created: i64,
    modified: i64,

    pub fn retain(self: *Node) void {
        _ = self.refs.fetchAdd(1, .monotonic);
    }

    pub fn size(self: *Node) u64 {
        self.lock.lockShared();
        defer self.lock.unlockShared();
        return self.data.items.len;
    }

    /// How many bytes it copied.
    pub fn read(self: *Node, offset: u64, out: []u8) usize {
        self.lock.lockShared();
        defer self.lock.unlockShared();
        const len = self.data.items.len;
        if (offset >= len) return 0;
        const n = @min(out.len, len - @as(usize, @intCast(offset)));
        @memcpy(out[0..n], self.data.items[@intCast(offset)..][0..n]);
        return n;
    }

    /// Grows with zeros to reach `offset` first.
    pub fn write(self: *Node, allocator: std.mem.Allocator, offset: u64, bytes: []const u8) !void {
        self.lock.lock();
        defer self.lock.unlock();
        const end = std.math.cast(usize, offset + bytes.len) orelse return error.OutOfMemory;
        if (end > self.data.items.len) {
            const old = self.data.items.len;
            try self.data.resize(allocator, end);
            @memset(self.data.items[old..end], 0);
        }
        @memcpy(self.data.items[@intCast(offset)..end], bytes);
        self.modified = native.now();
    }

    pub fn truncate(self: *Node, allocator: std.mem.Allocator, len: u64) !void {
        self.lock.lock();
        defer self.lock.unlock();
        const n = std.math.cast(usize, len) orelse return error.OutOfMemory;
        const old = self.data.items.len;
        try self.data.resize(allocator, n);
        if (n > old) @memset(self.data.items[old..n], 0);
        self.modified = native.now();
    }

    pub fn times(self: *Node) struct { created: i64, modified: i64 } {
        self.lock.lockShared();
        defer self.lock.unlockShared();
        return .{ .created = self.created, .modified = self.modified };
    }
};

/// A copy of one child, for listings.
pub const Entry = struct {
    name: []u8,
    kind: Kind,
    id: u64,
    size: u64,
    created: i64,
    modified: i64,
};

/// A copy of one file, for tools.
pub const Info = struct {
    path: []u8,
    size: u64,
};

allocator: std.mem.Allocator,
lock: RwLock = .{},
nodes: std.StringHashMapUnmanaged(*Node) = .empty,
next_id: u64 = 1,

pub fn init(allocator: std.mem.Allocator) Store {
    return .{ .allocator = allocator };
}

/// Open handles can still hold nodes, and free them when they close.
pub fn deinit(self: *Store) void {
    var it = self.nodes.valueIterator();
    while (it.next()) |n| {
        n.*.linked = false;
        self.release(n.*);
    }
    self.nodes.deinit(self.allocator);
}

pub fn release(self: *Store, node: *Node) void {
    if (node.refs.fetchSub(1, .acq_rel) != 1) return;
    node.data.deinit(self.allocator);
    self.allocator.free(node.path);
    self.allocator.free(node.key);
    self.allocator.destroy(node);
}

/// Normalized path in, retained node out.
pub fn lookup(self: *Store, key: []const u8) ?*Node {
    self.lock.lockShared();
    defer self.lock.unlockShared();
    const node = self.nodes.get(key) orelse return null;
    node.retain();
    return node;
}

pub fn exists(self: *Store, key: []const u8) ?Kind {
    self.lock.lockShared();
    defer self.lock.unlockShared();
    const node = self.nodes.get(key) orelse return null;
    return node.kind;
}

/// Makes or replaces a file. `path` must be normalized.
pub fn put(self: *Store, path: []const u8, bytes: []const u8) !void {
    const node = try self.create(path, .file, true);
    defer self.release(node);
    node.lock.lock();
    defer node.lock.unlock();
    node.data.clearRetainingCapacity();
    try node.data.appendSlice(self.allocator, bytes);
    node.modified = native.now();
}

/// The node at `path`, made if missing. Retained.
pub fn create(self: *Store, path: []const u8, kind: Kind, replace: bool) !*Node {
    self.lock.lock();
    defer self.lock.unlock();
    return self.createLocked(path, kind, false, replace);
}

fn createLocked(self: *Store, path: []const u8, kind: Kind, implicit: bool, replace: bool) !*Node {
    var key_buf: [1024]u8 = undefined;
    const key = if (path.len <= key_buf.len) paths.key(&key_buf, path) else return error.PathTooLong;
    if (self.nodes.get(key)) |existing| {
        if (existing.kind != kind) return if (kind == .file) error.IsDirectory else error.NotADirectory;
        if (!replace and !implicit) return error.Exists;
        if (!implicit) existing.implicit = false;
        existing.retain();
        return existing;
    }

    const parent = if (paths.parent(path)) |p| try self.createLocked(p, .dir, true, true) else null;
    errdefer if (parent) |p| self.release(p);

    const node = try self.allocator.create(Node);
    errdefer self.allocator.destroy(node);
    const owned_path = try self.allocator.dupe(u8, path);
    errdefer self.allocator.free(owned_path);
    const owned_key = try self.allocator.dupe(u8, key);
    errdefer self.allocator.free(owned_key);
    const now = native.now();
    node.* = .{ .kind = kind, .implicit = implicit, .id = self.next_id, .path = owned_path, .key = owned_key, .created = now, .modified = now };
    try self.nodes.put(self.allocator, owned_key, node);
    self.next_id += 1;
    if (parent) |p| {
        p.children += 1;
        self.release(p);
    }
    node.retain();
    return node;
}

/// Removes the node and everything under it. False if there wasn't one.
pub fn remove(self: *Store, key: []const u8) bool {
    self.lock.lock();
    defer self.lock.unlock();
    const node = self.nodes.get(key) orelse return false;
    self.unlinkTree(node);
    return true;
}

/// Unless something replaced it meanwhile, like on delete-on-close.
pub fn unlink(self: *Store, node: *Node) void {
    self.lock.lock();
    defer self.lock.unlock();
    if (node.linked) self.unlinkTree(node);
}

fn unlinkTree(self: *Store, node: *Node) void {
    if (node.kind == .dir and node.children > 0) {
        var doomed: std.ArrayList(*Node) = .empty;
        defer doomed.deinit(self.allocator);
        var it = self.nodes.valueIterator();
        while (it.next()) |n| {
            if (isUnder(n.*.key, node.key)) doomed.append(self.allocator, n.*) catch {};
        }
        // Deepest first so parents see their children go
        std.mem.sort(*Node, doomed.items, {}, struct {
            fn deeper(_: void, a: *Node, b: *Node) bool {
                return a.key.len > b.key.len;
            }
        }.deeper);
        for (doomed.items) |n| self.unlinkOne(n, false);
    }
    self.unlinkOne(node, true);
}

fn unlinkOne(self: *Store, node: *Node, prune: bool) void {
    _ = self.nodes.remove(node.key);
    node.linked = false;
    if (paths.parent(node.path)) |p| {
        var key_buf: [1024]u8 = undefined;
        if (self.nodes.get(paths.key(&key_buf, p))) |parent| {
            parent.children -|= 1;
            if (prune and parent.implicit and parent.children == 0) self.unlinkOne(parent, true);
        }
    }
    self.release(node);
}

fn isUnder(key: []const u8, dir: []const u8) bool {
    if (key.len <= dir.len or !std.mem.startsWith(u8, key, dir)) return false;
    // Roots end in a slash already, like `c:/`
    return dir[dir.len - 1] == paths.sep or key[dir.len] == paths.sep;
}

/// Moves a file to `new_path`, which must be normalized.
pub fn rename(self: *Store, node: *Node, new_path: []const u8, replace: bool) !void {
    self.lock.lock();
    defer self.lock.unlock();
    if (!node.linked) return error.NotFound;
    if (node.kind == .dir) return error.IsDirectory;
    var key_buf: [1024]u8 = undefined;
    if (new_path.len > key_buf.len) return error.PathTooLong;
    const new_key = paths.key(&key_buf, new_path);
    if (std.mem.eql(u8, new_key, node.key)) return;
    if (self.nodes.get(new_key)) |existing| {
        if (!replace or existing.kind == .dir) return error.Exists;
        self.unlinkOne(existing, true);
    }
    const parent = if (paths.parent(new_path)) |p| try self.createLocked(p, .dir, true, true) else null;
    defer if (parent) |p| self.release(p);
    const owned_path = try self.allocator.dupe(u8, new_path);
    errdefer self.allocator.free(owned_path);
    const owned_key = try self.allocator.dupe(u8, new_key);
    errdefer self.allocator.free(owned_key);
    try self.nodes.ensureUnusedCapacity(self.allocator, 1);

    // Counted first so the unlink can't prune the new parent, if it's the old one
    if (parent) |p| p.children += 1;
    // Keeps it alive across the unlink, which drops the map's ref
    node.retain();
    self.unlinkOne(node, true);
    self.allocator.free(node.path);
    self.allocator.free(node.key);
    node.path = owned_path;
    node.key = owned_key;
    node.linked = true;
    self.nodes.putAssumeCapacity(owned_key, node);
}

pub fn hasChildren(self: *Store, dir_key: []const u8) bool {
    self.lock.lockShared();
    defer self.lock.unlockShared();
    const node = self.nodes.get(dir_key) orelse return false;
    return node.kind == .dir and node.children > 0;
}

/// Made with `putDir`, so new files in it are virtual too.
pub fn isExplicitDir(self: *Store, key: []const u8) bool {
    self.lock.lockShared();
    defer self.lock.unlockShared();
    const node = self.nodes.get(key) orelse return false;
    return node.kind == .dir and !node.implicit;
}

/// Copies of what's directly in `dir_key`. Free with `freeEntries`.
pub fn children(self: *Store, allocator: std.mem.Allocator, dir_key: []const u8) ![]Entry {
    self.lock.lockShared();
    defer self.lock.unlockShared();
    var out: std.ArrayList(Entry) = .empty;
    errdefer freeEntries(allocator, out.items);
    errdefer out.deinit(allocator);
    var it = self.nodes.valueIterator();
    while (it.next()) |n| {
        const node = n.*;
        const parent = paths.parent(node.key) orelse continue;
        if (!std.mem.eql(u8, parent, dir_key)) continue;
        const name = try allocator.dupe(u8, paths.name(node.path));
        errdefer allocator.free(name);
        const t = node.times();
        try out.append(allocator, .{ .name = name, .kind = node.kind, .id = node.id, .size = node.size(), .created = t.created, .modified = t.modified });
    }
    return out.toOwnedSlice(allocator);
}

pub fn freeEntries(allocator: std.mem.Allocator, entries: []Entry) void {
    for (entries) |e| allocator.free(e.name);
    allocator.free(entries);
}

/// Every file, sorted by path. Free with `freeInfos`.
pub fn files(self: *Store, allocator: std.mem.Allocator) ![]Info {
    self.lock.lockShared();
    defer self.lock.unlockShared();
    var out: std.ArrayList(Info) = .empty;
    errdefer freeInfos(allocator, out.items);
    errdefer out.deinit(allocator);
    var it = self.nodes.valueIterator();
    while (it.next()) |n| {
        if (n.*.kind != .file) continue;
        const path = try allocator.dupe(u8, n.*.path);
        errdefer allocator.free(path);
        try out.append(allocator, .{ .path = path, .size = n.*.size() });
    }
    std.mem.sort(Info, out.items, {}, struct {
        fn less(_: void, a: Info, b: Info) bool {
            return std.ascii.lessThanIgnoreCase(a.path, b.path);
        }
    }.less);
    return out.toOwnedSlice(allocator);
}

pub fn freeInfos(allocator: std.mem.Allocator, infos: []Info) void {
    for (infos) |i| allocator.free(i.path);
    allocator.free(infos);
}

const testing = std.testing;

test "files imply their folders" {
    var store: Store = .init(testing.allocator);
    defer store.deinit();
    try store.put("C:/Game/mods/a.pak", "hi");
    try testing.expectEqual(Kind.dir, store.exists("c:/game/mods").?);
    try testing.expectEqual(Kind.dir, store.exists("c:/").?);
    try testing.expect(store.hasChildren("c:/game"));

    const kids = try store.children(testing.allocator, "c:/game/mods");
    defer freeEntries(testing.allocator, kids);
    try testing.expectEqual(1, kids.len);
    try testing.expectEqualStrings("a.pak", kids[0].name);
    try testing.expectEqual(2, kids[0].size);

    try testing.expect(store.remove("c:/game/mods/a.pak"));
    try testing.expectEqual(null, store.exists("c:/game"));
    try testing.expectEqual(null, store.exists("c:/"));
}

test "removed nodes live while held" {
    var store: Store = .init(testing.allocator);
    defer store.deinit();
    try store.put("C:/a.txt", "hello");
    const node = store.lookup("c:/a.txt").?;
    defer store.release(node);
    try testing.expect(store.remove("c:/a.txt"));
    var buf: [8]u8 = undefined;
    try testing.expectEqualStrings("ello", buf[0..node.read(1, &buf)]);
}

test "renames and folder removal" {
    var store: Store = .init(testing.allocator);
    defer store.deinit();
    try store.put("C:/x/a.txt", "a");
    try store.put("C:/x/y/b.txt", "b");
    const node = store.lookup("c:/x/a.txt").?;
    defer store.release(node);
    try store.rename(node, "C:/z/c.txt", false);
    try testing.expectEqual(null, store.exists("c:/x/a.txt"));
    try testing.expectEqualStrings("C:/z/c.txt", node.path);

    try testing.expect(store.remove("c:/x"));
    try testing.expectEqual(null, store.exists("c:/x/y/b.txt"));
    const all = try store.files(testing.allocator);
    defer freeInfos(testing.allocator, all);
    try testing.expectEqual(1, all.len);
}
