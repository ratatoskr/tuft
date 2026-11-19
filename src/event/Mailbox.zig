//! Fixed-size queue. Any thread pushes without allocating, one thread drains.

const std = @import("std");

pub fn Mailbox(comptime T: type, comptime capacity_: usize) type {
    return struct {
        const Self = @This();

        pub const capacity = capacity_;
        pub const PushError = error{ QueueFull, Closed };

        lock: std.atomic.Value(bool) = .init(false),
        items: [capacity]T = undefined,
        len: usize = 0,
        closed: bool = false,

        pub fn push(self: *Self, item: T) PushError!void {
            self.acquire();
            defer self.release();
            if (self.closed) return error.Closed;
            if (self.len == capacity) return error.QueueFull;
            self.items[self.len] = item;
            self.len += 1;
        }

        /// Replaces the newest item if `item` supersedes it.
        pub fn pushCoalesced(self: *Self, item: T, comptime supersedes: fn (newer: T, older: T) bool) PushError!void {
            self.acquire();
            defer self.release();
            if (self.closed) return error.Closed;
            if (self.len > 0 and supersedes(item, self.items[self.len - 1])) {
                self.items[self.len - 1] = item;
                return;
            }
            if (self.len == capacity) return error.QueueFull;
            self.items[self.len] = item;
            self.len += 1;
        }

        /// Oldest first.
        pub fn drain(self: *Self, out: *[capacity]T) []T {
            self.acquire();
            defer self.release();
            const n = self.len;
            @memcpy(out[0..n], self.items[0..n]);
            self.len = 0;
            return out[0..n];
        }

        /// Refuses more pushes and drops what's queued. Returns how many.
        pub fn close(self: *Self) usize {
            self.acquire();
            defer self.release();
            const dropped = self.len;
            self.len = 0;
            self.closed = true;
            return dropped;
        }

        fn acquire(self: *Self) void {
            while (self.lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
        }

        fn release(self: *Self) void {
            self.lock.store(false, .release);
        }
    };
}

test "push, drain, full, closed" {
    var box: Mailbox(u32, 3) = .{};
    var out: [3]u32 = undefined;

    try box.push(1);
    try box.push(2);
    try box.push(3);
    try std.testing.expectError(error.QueueFull, box.push(4));
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 3 }, box.drain(&out));
    try std.testing.expectEqual(0, box.drain(&out).len);

    try box.push(5);
    try std.testing.expectEqual(1, box.close());
    try std.testing.expectError(error.Closed, box.push(6));
    try std.testing.expectEqual(0, box.drain(&out).len);
}

test "pushCoalesced" {
    const sameTens = struct {
        fn f(newer: u32, older: u32) bool {
            return newer / 10 == older / 10;
        }
    }.f;
    var box: Mailbox(u32, 2) = .{};
    var out: [2]u32 = undefined;

    try box.pushCoalesced(11, sameTens);
    try box.pushCoalesced(12, sameTens);
    try box.pushCoalesced(21, sameTens);
    try box.pushCoalesced(23, sameTens); // full, but replaces 21
    try std.testing.expectError(error.QueueFull, box.pushCoalesced(31, sameTens));
    try std.testing.expectEqualSlices(u32, &.{ 12, 23 }, box.drain(&out));
}

test "concurrent producers" {
    const Box = Mailbox(u32, 4096);
    var box: Box = .{};
    const per_thread = 1000;

    const producer = struct {
        fn run(b: *Box, base: u32) void {
            for (0..per_thread) |i| b.push(base + @as(u32, @intCast(i))) catch unreachable;
        }
    }.run;

    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*t, i| t.* = try std.Thread.spawn(.{}, producer, .{ &box, @as(u32, @intCast(i)) * per_thread });
    for (threads) |t| t.join();

    var out: [Box.capacity]u32 = undefined;
    const items = box.drain(&out);
    try std.testing.expectEqual(4 * per_thread, items.len);
    var seen = std.StaticBitSet(4 * per_thread).empty;
    for (items) |v| seen.set(v);
    try std.testing.expectEqual(4 * per_thread, seen.count());
}
