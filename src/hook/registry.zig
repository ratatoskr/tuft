const std = @import("std");
const arch = @import("tuft_arch");
const sys = @import("tuft_sys");
const Claims = @import("tuft_mem").Claims;
const Text = @import("tuft_text").Text;
const Owner = @import("tuft_event").Owner;
const Hook = @import("Hook.zig");
const Patch = @import("Patch.zig");
const thunk = @import("thunk.zig");

pub const INVALID_HOOK_ID: u64 = 0;

var next_id: arch.atomic.Value(u64) = .init(42);

/// Its lock guards everything here.
var hooks: sys.sync.SharedList(*Hook) = .{};
const rwlock = &hooks.lock;
var patches: std.ArrayList(*Patch) = .empty;
var global_allocator: ?std.mem.Allocator = null;

pub fn init(alloc: std.mem.Allocator) !void {
    rwlock.lock();
    defer rwlock.unlock();
    if (global_allocator != null) return;

    try thunk.init();
    global_allocator = alloc;
}

pub fn allocator() std.mem.Allocator {
    return global_allocator orelse @panic("tuft: hooks used before tuft_hook.init()");
}

/// After `init`, so patches can be made.
pub fn ready() bool {
    return global_allocator != null;
}

pub fn register(hook: *Hook) !void {
    rwlock.lock();
    defer rwlock.unlock();

    // Overlapping hooks would relocate each other's patches and restore stale bytes on disable
    const new_range = hook.patchedRange();
    if (overlapsAny(new_range)) return error.AlreadyHooked;

    if (hook.hook_id == INVALID_HOOK_ID)
        hook.hook_id = assignNextId();

    try hooks.items.append(allocator(), hook);
    claim(hook) catch |err| {
        Claims.remove(.hook, hook.hook_id);
        _ = hooks.items.pop();
        return err;
    };
}

/// Claims every byte `hook` touches until destroyed, since it restores saved bytes on the way out.
fn claim(hook: *const Hook) !void {
    const placed = hook.placedRanges();
    for ([_]sys.thread.CodeRange{ hook.patchedRange(), placed[1], placed[0] }) |p| {
        var c: Claims.Claim = .{ .start = p.start, .len = p.len, .kind = .hook, .id = hook.hook_id };
        c.setOwner(hook.owner);
        try Claims.add(c);
    }
}

fn overlapsAny(new_range: sys.thread.CodeRange) bool {
    const hit = struct {
        fn f(a: sys.thread.CodeRange, b: sys.thread.CodeRange) bool {
            return a.start < b.start + b.len and b.start < a.start + a.len;
        }
    }.f;
    for (hooks.items.items) |other| if (hit(other.patchedRange(), new_range)) return true;
    for (patches.items) |p| if (hit(p.range(), new_range)) return true;
    return false;
}

pub fn registerPatch(patch: *Patch) !void {
    rwlock.lock();
    defer rwlock.unlock();
    if (overlapsAny(patch.range())) return error.AlreadyHooked;
    patch.id = assignNextId();
    try patches.append(allocator(), patch);
    var c: Claims.Claim = .{ .start = patch.address, .len = patch.bytes.len, .kind = .patch, .id = patch.id };
    c.setOwner(patch.owner);
    Claims.add(c) catch |err| {
        _ = patches.pop();
        return err;
    };
}

pub fn unregisterPatch(patch: *Patch) void {
    if (patch.id == INVALID_HOOK_ID) return;
    rwlock.lock();
    defer rwlock.unlock();
    for (patches.items, 0..) |p, i| if (p == patch) {
        _ = patches.swapRemove(i);
        break;
    };
    Claims.remove(.patch, patch.id);
}

pub fn unregister(hook: *Hook) void {
    if (hook.hook_id == INVALID_HOOK_ID)
        return;

    rwlock.lock();
    defer rwlock.unlock();

    if (hook.hook_id != INVALID_HOOK_ID) {
        for (hooks.items.items, 0..) |h, i| if (h == hook) {
            _ = hooks.items.swapRemove(i);
            break;
        };
        Claims.remove(.hook, hook.hook_id);
    }
}

/// A copy of a hook for tools. It may be destroyed after.
pub const Info = struct {
    id: u64,
    target: usize,
    kind: Hook.Kind,
    mode: Hook.Mode,
    state: Hook.State,
    /// Bytes overwritten at `target`. For a slot hook, the pointer.
    patch_len: u8,
    /// See `Hook.timing`.
    timing: Hook.Timing.Figures,
    /// Callbacks running now.
    active: u32,
    /// Null means the host. Compare it, don't follow it, it may be gone.
    owner: ?*const Owner,
    /// Owner's name, copied.
    owner_name: Text(32),

    pub fn ownerName(self: *const Info) []const u8 {
        return self.owner_name.get();
    }

    fn of(h: *Hook, out: *Info) void {
        out.* = .{
            .id = h.hook_id,
            .target = h.target_addr,
            .kind = h.kind(),
            .mode = h.mode,
            .state = h.state,
            .patch_len = h.patch_len,
            .timing = h.timing.figures(),
            .active = h.active_calls.load(.monotonic),
            .owner = h.owner,
            // A hook's owner outlives it. Closing the owner destroys the hook
            .owner_name = .init(if (h.owner) |o| o.name else ""),
        };
    }
};

/// Oldest first. Returns the count.
pub fn snapshot(out: []Info) usize {
    const n = @min(hooks.snapshotAs(Info, out, Info.of), out.len);
    std.mem.sort(Info, out[0..n], {}, struct {
        fn lessThan(_: void, a: Info, b: Info) bool {
            return a.id < b.id;
        }
    }.lessThan);
    return n;
}

pub fn resetTimings() void {
    rwlock.lockShared();
    defer rwlock.unlockShared();
    for (hooks.items.items) |h| h.timing.reset();
}

pub fn deinit() void {
    rwlock.lock();
    defer rwlock.unlock();
    if (global_allocator == null) return;
    const alloc = global_allocator.?;

    cleanupAllHooks();
    for (patches.items) |p| {
        Claims.remove(.patch, p.id);
        p.id = INVALID_HOOK_ID;
        p.destroy();
    }

    hooks.items.deinit(alloc);
    hooks.items = .empty;
    patches.deinit(alloc);
    patches = .empty;

    global_allocator = null;
}

fn cleanupAllHooks() void {
    while (hooks.items.pop()) |hook| {
        hook.hook_id = INVALID_HOOK_ID;
        hook.destroy();
    }
}

fn assignNextId() u64 {
    return next_id.fetchAdd(1, .seq_cst);
}
