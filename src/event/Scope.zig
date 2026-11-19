//! LIFO cleanup stack. Not thread-safe.

const Scope = @This();

const std = @import("std");

const Cleanup = struct {
    ctx: ?*anyopaque,
    run: *const fn (?*anyopaque) void,
};

allocator: std.mem.Allocator,
cleanups: std.ArrayList(Cleanup) = .empty,

pub fn init(allocator: std.mem.Allocator) Scope {
    return .{ .allocator = allocator };
}

/// Runs what's left, then frees. Fine to call twice.
pub fn deinit(self: *Scope) void {
    self.dispose();
    self.cleanups.deinit(self.allocator);
    self.cleanups = .empty;
}

/// If this fails the caller still owns the resource.
pub fn add(self: *Scope, ptr: anytype, comptime func: fn (@TypeOf(ptr)) void) !void {
    const Ptr = @TypeOf(ptr);
    if (@typeInfo(Ptr) != .pointer) @compileError("Scope.add expects a pointer, found " ++ @typeName(Ptr));

    const Wrap = struct {
        fn run(ctx: ?*anyopaque) void {
            func(@ptrCast(@alignCast(ctx.?)));
        }
    };
    try self.cleanups.append(self.allocator, .{ .ctx = @ptrCast(@constCast(ptr)), .run = Wrap.run });
}

/// So the next `n` `add`s can't fail.
pub fn reserve(self: *Scope, n: usize) !void {
    try self.cleanups.ensureUnusedCapacity(self.allocator, n);
}

/// If this fails the caller still owns the resource.
pub fn addFn(self: *Scope, comptime func: fn () void) !void {
    const Wrap = struct {
        fn run(_: ?*anyopaque) void {
            func();
        }
    };
    try self.cleanups.append(self.allocator, .{ .ctx = null, .run = Wrap.run });
}

pub fn count(self: *const Scope) usize {
    return self.cleanups.items.len;
}

/// Newest first. Reusable after.
pub fn dispose(self: *Scope) void {
    while (self.cleanups.pop()) |cleanup| cleanup.run(cleanup.ctx);
}

const tests = struct {
    test "dispose reverse once" {
        const Log = struct {
            var order: [4]u8 = undefined;
            var len: usize = 0;

            fn push(tag: *const u8) void {
                order[len] = tag.*;
                len += 1;
            }

            fn pushZ() void {
                order[len] = 'z';
                len += 1;
            }
        };
        Log.len = 0;

        var scope = Scope.init(std.testing.allocator);
        defer scope.deinit();

        const a: u8 = 'a';
        const b: u8 = 'b';
        try scope.add(&a, Log.push);
        try scope.addFn(Log.pushZ);
        try scope.add(&b, Log.push);
        try std.testing.expectEqual(3, scope.count());

        scope.dispose();
        scope.dispose();
        try std.testing.expectEqualStrings("bza", Log.order[0..Log.len]);
        try std.testing.expectEqual(0, scope.count());
    }

    test "reuse and deinit" {
        const Counter = struct {
            fn bump(n: *u32) void {
                n.* += 1;
            }
        };

        var runs: u32 = 0;
        var scope = Scope.init(std.testing.allocator);

        try scope.add(&runs, Counter.bump);
        scope.dispose();
        try std.testing.expectEqual(1, runs);

        try scope.add(&runs, Counter.bump);
        scope.deinit();
        try std.testing.expectEqual(2, runs);
    }

    test "failed add" {
        var buffer: [0]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buffer);
        var scope = Scope.init(fba.allocator());
        defer scope.deinit();

        var value: u8 = 0;
        const Noop = struct {
            fn run(_: *u8) void {}
        };
        try std.testing.expectError(error.OutOfMemory, scope.add(&value, Noop.run));
        try std.testing.expectEqual(0, scope.count());
    }
};

test {
    _ = tests;
}
