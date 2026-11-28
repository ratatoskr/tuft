//! Text in fixed buffers, cut short if it doesn't fit, and pools that keep each string once.

const std = @import("std");

pub const StringPool = @import("StringPool.zig");

/// A short message, like what went wrong. Extern so ABI structs can hold one.
pub fn Message(comptime capacity: usize) type {
    return extern struct {
        const Self = @This();

        len: u32 = 0,
        buf: [capacity]u8 = undefined,

        pub fn init(comptime fmt: []const u8, args: anytype) Self {
            var m: Self = .{};
            m.print(fmt, args);
            return m;
        }

        pub fn print(self: *Self, comptime fmt: []const u8, args: anytype) void {
            var w: std.Io.Writer = .fixed(&self.buf);
            w.print(fmt, args) catch {};
            self.len = @intCast(w.end);
        }

        pub fn set(self: *Self, s: []const u8) void {
            const n = @min(s.len, capacity);
            @memcpy(self.buf[0..n], s[0..n]);
            self.len = @intCast(n);
        }

        pub fn message(self: *const Self) []const u8 {
            return self.buf[0..@min(self.len, capacity)];
        }
    };
}

/// Zero-terminated text, like an input box's.
pub fn Text(comptime capacity: usize) type {
    return struct {
        const Self = @This();

        buf: [capacity:0]u8 = @splat(0),

        pub fn init(s: []const u8) Self {
            var t: Self = .{};
            t.set(s);
            return t;
        }

        pub fn set(self: *Self, s: []const u8) void {
            const n = @min(s.len, capacity);
            @memcpy(self.buf[0..n], s[0..n]);
            self.buf[n] = 0;
        }

        pub fn get(self: *const Self) [:0]const u8 {
            return std.mem.sliceTo(&self.buf, 0);
        }

        pub fn len(self: *const Self) usize {
            return self.get().len;
        }
    };
}

/// Zero-terminated text with no limit, which grows as it's set or typed into. Owns its buffer, so it's
/// moved, not copied; `clone` for a second one.
pub const EditText = struct {
    /// The text, a 0, then room. Empty till something's set.
    buf: []u8 = &.{},
    len: usize = 0,

    pub fn init(gpa: std.mem.Allocator, s: []const u8) error{OutOfMemory}!EditText {
        var t: EditText = .{};
        try t.set(gpa, s);
        return t;
    }

    pub fn deinit(self: *EditText, gpa: std.mem.Allocator) void {
        gpa.free(self.buf);
        self.* = .{};
    }

    pub fn clone(self: *const EditText, gpa: std.mem.Allocator) error{OutOfMemory}!EditText {
        return init(gpa, self.get());
    }

    pub fn get(self: *const EditText) [:0]const u8 {
        if (self.buf.len == 0) return "";
        return self.buf[0..self.len :0];
    }

    /// Only allocates past the room it has.
    pub fn set(self: *EditText, gpa: std.mem.Allocator, s: []const u8) error{OutOfMemory}!void {
        try self.reserve(gpa, s.len + 1);
        @memcpy(self.buf[0..s.len], s);
        self.buf[s.len] = 0;
        self.len = s.len;
    }

    /// Room for `size` bytes, its 0 included.
    pub fn reserve(self: *EditText, gpa: std.mem.Allocator, size: usize) error{OutOfMemory}!void {
        if (size <= self.buf.len) return;
        const grown = @max(size, self.buf.len * 2, 16);
        if (self.buf.len == 0) {
            self.buf = try gpa.alloc(u8, grown);
            self.buf[0] = 0;
        } else {
            self.buf = try gpa.realloc(self.buf, grown);
        }
    }

    /// After something wrote into `buf` itself, like an input box.
    pub fn sync(self: *EditText) void {
        self.len = std.mem.indexOfScalar(u8, self.buf, 0) orelse self.buf.len;
    }
};

const tests = struct {
    const testing = std.testing;

    test "edit text grows, and only past its room" {
        var t: EditText = .{};
        defer t.deinit(testing.allocator);
        try testing.expectEqualStrings("", t.get());
        const long: [100]u8 = @splat('x');
        try t.set(testing.allocator, &long);
        try testing.expectEqualStrings(&long, t.get());
        const room = t.buf.ptr;
        try t.set(testing.allocator, "short");
        try testing.expectEqualStrings("short", t.get());
        try testing.expectEqual(room, t.buf.ptr);
        // Typed into directly
        @memcpy(t.buf[0..3], "abc");
        t.buf[3] = 0;
        t.sync();
        try testing.expectEqualStrings("abc", t.get());
        var copy = try t.clone(testing.allocator);
        defer copy.deinit(testing.allocator);
        try testing.expectEqualStrings("abc", copy.get());
    }

    test "message prints, sets and cuts short" {
        var m: Message(8) = .init("{d} apples", .{3});
        try testing.expectEqualStrings("3 apples", m.message());
        m.print("{s}", .{"far too long"});
        try testing.expectEqualStrings("far too ", m.message());
        m.set("hi");
        try testing.expectEqualStrings("hi", m.message());
        m.set("0123456789");
        try testing.expectEqualStrings("01234567", m.message());
    }

    test "text sets, gets and cuts short" {
        var t: Text(4) = .init("abcdef");
        try testing.expectEqualStrings("abcd", t.get());
        t.set("x");
        try testing.expectEqualStrings("x", t.get());
        try testing.expectEqual(1, t.len());
        try testing.expectEqual(0, t.buf[1]);
    }
};

test {
    _ = tests;
    _ = StringPool;
}
