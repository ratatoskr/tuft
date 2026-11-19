//! Text in fixed buffers, cut short if it doesn't fit.

const std = @import("std");

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

const tests = struct {
    const testing = std.testing;

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
}
