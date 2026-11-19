const std = @import("std");
const Hook = @import("Hook.zig");

/// Typed wrapper around a raw Hook.
pub fn TypedHook(comptime T: type) type {
    const FuncPtrType = if (@typeInfo(T) == .@"fn") *const T else T;

    return opaque {
        pub const OriginalFn = FuncPtrType;

        pub fn fromHook(hook: *Hook) *@This() {
            return @ptrCast(hook);
        }

        pub fn toHook(self: *@This()) *Hook {
            return @ptrCast(@alignCast(self));
        }

        pub fn toConstHook(self: *const @This()) *const Hook {
            return @ptrCast(@alignCast(self));
        }

        pub fn enable(self: *@This()) !void {
            try self.toHook().enable();
        }

        pub fn disable(self: *@This()) !void {
            try self.toHook().disable();
        }

        pub fn destroy(self: *@This()) void {
            self.toHook().destroy();
        }

        pub fn original(self: *const @This()) FuncPtrType {
            return self.toConstHook().original(FuncPtrType);
        }
    };
}

const tests = struct {
    const registry = @import("registry.zig");

    // `noinline` plus an asm barrier, or optimized builds reuse the pre-hook result
    noinline fn subTarget(a: i32, b: i32) callconv(.c) i32 {
        var x = a;
        var y = b;
        asm volatile (""
            : [x] "+r" (x),
              [y] "+r" (y),
        );
        return x - y;
    }

    test "normalizes fn types" {
        const BareFn = fn (i32, i32) callconv(.c) i32;
        const PtrFn = *const fn (i32, i32) callconv(.c) i32;

        try std.testing.expectEqual(PtrFn, TypedHook(BareFn).OriginalFn);
        try std.testing.expectEqual(PtrFn, TypedHook(PtrFn).OriginalFn);
    }

    test "round-trips pointers" {
        try registry.init(std.testing.allocator);
        defer registry.deinit();

        const SubFn = fn (i32, i32) callconv(.c) i32;

        const typed = try Hook.createFn(SubFn, @intFromPtr(&subTarget), struct {
            fn detour(a: i32, b: i32) callconv(.c) i32 {
                return a - b;
            }
        }.detour, {});
        defer typed.destroy();

        const raw: *Hook = typed.toHook();
        const const_raw: *const Hook = typed.toConstHook();
        const back_to_typed: *TypedHook(SubFn) = TypedHook(SubFn).fromHook(raw);

        try std.testing.expectEqual(@intFromPtr(typed), @intFromPtr(raw));
        try std.testing.expectEqual(@intFromPtr(typed), @intFromPtr(const_raw));
        try std.testing.expectEqual(@intFromPtr(typed), @intFromPtr(back_to_typed));
    }

    test "enable, call, disable, destroy" {
        try registry.init(std.testing.allocator);
        defer registry.deinit();

        const SubFn = fn (i32, i32) callconv(.c) i32;

        try std.testing.expectEqual(7, subTarget(10, 3));

        const typed = try Hook.createFn(SubFn, @intFromPtr(&subTarget), struct {
            fn detour(hook: *TypedHook(SubFn), a: i32, b: i32) callconv(.c) i32 {
                return hook.original()(a, b) + 100;
            }
        }.detour, {});
        defer typed.destroy();

        try typed.enable();
        try std.testing.expectEqual(107, subTarget(10, 3));

        try typed.disable();
        try std.testing.expectEqual(7, subTarget(10, 3));
    }
};

test {
    _ = tests;
}
