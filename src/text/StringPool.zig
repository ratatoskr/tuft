//! Each distinct string kept once, till the pool goes, so what holds one can copy it as bytes and compare by address.
//! Not thread safe. Own one per user, so its strings go with it.

const std = @import("std");

const StringPool = @This();

arena: std.heap.ArenaAllocator,
set: std.StringHashMapUnmanaged(void) = .empty,

pub fn init(gpa: std.mem.Allocator) StringPool {
    return .{ .arena = .init(gpa) };
}

pub fn deinit(p: *StringPool) void {
    p.arena.deinit();
}

/// The pool's copy of `text`, made the first time.
pub fn keep(p: *StringPool, text: []const u8) error{OutOfMemory}![]const u8 {
    const a = p.arena.allocator();
    const gop = try p.set.getOrPut(a, text);
    if (gop.found_existing) return gop.key_ptr.*;
    gop.key_ptr.* = a.dupe(u8, text) catch |err| {
        _ = p.set.remove(text);
        return err;
    };
    return gop.key_ptr.*;
}

/// The pool's copy, if it has one.
pub fn get(p: *const StringPool, text: []const u8) ?[]const u8 {
    return p.set.getKey(text);
}

pub fn count(p: *const StringPool) usize {
    return p.set.count();
}

const testing = std.testing;

test "each string once, outliving what it was copied from" {
    var pool: StringPool = .init(testing.allocator);
    defer pool.deinit();
    var buf = "head".*;
    const a = try pool.keep(&buf);
    buf[0] = 'd';
    try testing.expectEqualStrings("head", a);
    try testing.expectEqual(a.ptr, (try pool.keep("head")).ptr);
    try testing.expectEqual(a.ptr, pool.get("head").?.ptr);
    try testing.expectEqual(null, pool.get("hand"));
    _ = try pool.keep("hand");
    try testing.expectEqual(2, pool.count());
}
