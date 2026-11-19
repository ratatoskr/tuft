const std = @import("std");

const RwLock = @import("root.zig").sync.RwLock;

/// A list behind a lock that tools copy out of, like what's hooked.
pub fn SharedList(comptime T: type) type {
    return struct {
        const Self = @This();

        lock: RwLock = .{},
        /// Hold `lock` to touch these.
        items: std.ArrayList(T) = .empty,

        /// Copies as many as fit into `out`, in list order. Returns how many there are, which can be more.
        pub fn snapshot(self: *Self, out: []T) usize {
            self.lock.lockShared();
            defer self.lock.unlockShared();
            const n = @min(out.len, self.items.items.len);
            @memcpy(out[0..n], self.items.items[0..n]);
            return self.items.items.len;
        }

        /// Like `snapshot`, with `copy` filling in each one.
        pub fn snapshotAs(self: *Self, comptime Out: type, out: []Out, comptime copy: fn (T, *Out) void) usize {
            self.lock.lockShared();
            defer self.lock.unlockShared();
            const n = @min(out.len, self.items.items.len);
            for (self.items.items[0..n], out[0..n]) |item, *o| copy(item, o);
            return self.items.items.len;
        }
    };
}

test "snapshots copy what fits" {
    const testing = std.testing;
    var list: SharedList(u32) = .{};
    defer list.items.deinit(testing.allocator);
    try list.items.appendSlice(testing.allocator, &.{ 1, 2, 3 });

    var out: [2]u32 = undefined;
    try testing.expectEqual(3, list.snapshot(&out));
    try testing.expectEqualSlices(u32, &.{ 1, 2 }, &out);

    var doubled: [4]u64 = undefined;
    const n = list.snapshotAs(u64, &doubled, struct {
        fn copy(item: u32, o: *u64) void {
            o.* = item * 2;
        }
    }.copy);
    try testing.expectEqualSlices(u64, &.{ 2, 4, 6 }, doubled[0..n]);
}
