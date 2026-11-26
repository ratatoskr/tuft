//! Function, mid, slot and inject hooks, patches, plus exception handling.

const std = @import("std");

pub const Hook = @import("Hook.zig");
pub const Patch = @import("Patch.zig");
/// Data and the code that reads it, placed together.
pub const Batch = @import("Batch.zig");
pub const TypedHook = @import("typed_hook.zig").TypedHook;
pub const Timing = Hook.Timing;
pub const CpuContext = @import("tuft_arch").CpuContext;
pub const XmmReg = @import("tuft_arch").XmmReg;

pub const thunk = @import("thunk.zig");
/// Hooks every address of a method that lives in several places.
pub const set = @import("set.zig");
pub const registry = @import("registry.zig");
/// Exception handlers. Separate `init` since it installs a vectored handler.
pub const exceptions = @import("exceptions.zig");
/// "What writes this address", with the CPU's debug registers.
pub const watch = @import("watch.zig");
pub const Debugger = @import("Debugger.zig");
pub const meta = @import("tuft_arch").meta;

/// `tuft_mem`'s `Address`, `Module` and `Range`, but they hook themselves, like `address.createFn(T, cb, ctx)`.
pub const memory = @import("tuft_mem").With(struct {
    pub fn FnHook(comptime T: type) type {
        return *TypedHook(T);
    }
    pub const MidHook = *Hook;
    pub const createFn = Hook.createFn;
    pub const createMid = Hook.createMid;
    pub const createSlot = Hook.createSlot;
});

/// Hooks get allocated with `allocator`. Fine to call twice.
pub const init = registry.init;
/// Destroys every hook left, restoring their targets.
pub const deinit = registry.deinit;

test {
    std.testing.refAllDecls(@This());
    _ = @import("Timing.zig");
}

noinline fn addTarget(a: i32, b: i32) callconv(.c) i32 {
    var x = a;
    var y = b;
    asm volatile (""
        : [x] "+r" (x),
          [y] "+r" (y),
    );
    return x + y;
}

test "addresses hook themselves" {
    try registry.init(std.testing.allocator);
    defer registry.deinit();

    const AddFn = fn (i32, i32) callconv(.c) i32;
    const hook = try memory.Address.from(&addTarget).createFn(AddFn, struct {
        fn detour(h: *TypedHook(AddFn), a: i32, b: i32) i32 {
            return h.original()(a, b) * 10;
        }
    }.detour, {});
    defer hook.destroy();

    try hook.enable();
    try std.testing.expectEqual(50, addTarget(2, 3));
}

test "hooks claim their bytes" {
    const Claims = @import("tuft_mem").Claims;
    Claims.enable(std.testing.allocator);
    defer Claims.disable();
    try registry.init(std.testing.allocator);
    defer registry.deinit();

    const AddFn = fn (i32, i32) callconv(.c) i32;
    const h = try Hook.createFn(AddFn, &addTarget, struct {
        fn detour(self: *TypedHook(AddFn), a: i32, b: i32) i32 {
            return self.original()(a, b);
        }
    }.detour, {});
    const raw = h.toHook();
    var kai: Claims.Owner = .init("kai");
    raw.setOwner(&kai);

    // Disabled too, since it puts its saved bytes back when it goes
    const target = @intFromPtr(&addTarget);
    const claim = Claims.local.first(target, 1).?;
    try std.testing.expectEqual(Claims.Kind.hook, claim.kind);
    try std.testing.expectEqual(raw.hook_id, claim.id);
    try std.testing.expectEqual(&kai, claim.owner.?);
    try std.testing.expectEqualStrings("kai", claim.ownerName());
    try std.testing.expectEqual(raw.patchedRange().len, claim.len);
    const page = @intFromPtr(raw.place.code.ptr);
    try std.testing.expectEqual(raw.hook_id, Claims.local.first(page, 1).?.id);
    try std.testing.expectEqual(null, Claims.local.first(target + claim.len, 1));

    h.destroy();
    try std.testing.expectEqual(null, Claims.local.first(target, 1));
    try std.testing.expectEqual(null, Claims.local.first(page, 1));
}
