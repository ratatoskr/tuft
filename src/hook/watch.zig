//! Hardware watches on up to four addresses, process wide, via debug registers.

const std = @import("std");

const arch = @import("tuft_arch");
const sys = @import("tuft_sys");
const tuft_event = @import("tuft_event");

const exceptions = @import("exceptions.zig");

pub const max = 4;
pub const Slot = u2;

pub const Condition = enum {
    write,
    /// Reads or writes. The CPU can't watch for reads alone, so check the instruction.
    access,
    /// About to run. `len` has to be 1, and it runs once the hit's handled.
    execute,
};

pub const Watch = struct {
    address: usize,
    /// 1, 2, 4 or 8 on x64, with `address` aligned to it. `lengthFor` picks one.
    len: u8,
    on: Condition,
};

pub const Hit = struct {
    slot: Slot,
    watch: Watch,
    /// Its `ip` is the instruction after the one that hit. For `execute`, the one about to run.
    cpu: arch.CpuContext,
    thread_id: u32,
};

pub const Event = tuft_event.Event(fn (*const Hit) void);
pub const Options = tuft_event.event.Options;

/// Longest length up to `size` a watch at `address` can have.
pub fn lengthFor(address: usize, size: usize) u8 {
    const lengths = if (arch.bits == 64) [_]u8{ 8, 4, 2 } else [_]u8{ 4, 2 };
    for (lengths) |len| {
        if (size >= len and address % len == 0) return len;
    }
    return 1;
}

var lock: sys.sync.RwLock = .{};
var users: u32 = 0;
var hit_event: Event = undefined;
var subscription: exceptions.Subscription = undefined;
var watches: [max]?Watch = @splat(null);

// Read by the handler, which can't lock
/// What each slot watches, 0 if nothing.
var armed: [max]std.atomic.Value(usize) = @splat(.init(0));
/// `len` and `on` for each slot, packed by `pack`.
var shapes: [max]std.atomic.Value(u8) = @splat(.init(0));
/// DR7 as `apply` last set it.
var control_now: std.atomic.Value(usize) = .init(0);
/// Last address each slot watched, since a hit raised just before clearing can still arrive.
var last: [max]std.atomic.Value(usize) = @splat(.init(0));

/// Starts handling hits, through `exceptions`. Each `init` needs a `deinit`.
pub fn init(allocator: std.mem.Allocator) !void {
    lock.lock();
    defer lock.unlock();
    if (users > 0) {
        users += 1;
        return;
    }
    try exceptions.init(allocator);
    errdefer exceptions.deinit();
    hit_event = .init(allocator);
    errdefer hit_event.deinit();
    subscription = try exceptions.subscribeUnscoped(&hit_event, onException);
    users = 1;
}

/// The last one clears every watch. Hit subscriptions must be gone by then.
pub fn deinit() void {
    lock.lock();
    defer lock.unlock();
    if (users == 0) return;
    users -= 1;
    if (users > 0) return;
    watches = @splat(null);
    for (&armed) |*a| a.store(0, .release);
    apply() catch {};
    subscription.unsubscribe();
    hit_event.deinit();
    exceptions.deinit();
}

/// `func` is `fn (ctx, *const Hit) void`, run inside the exception. Lasts until `scope` is disposed.
pub fn subscribe(scope: *tuft_event.Scope, ctx: anytype, comptime func: anytype) !void {
    return events().subscribe(scope, ctx, func);
}

pub fn subscribeUnscoped(ctx: anytype, comptime func: anytype) !Event.Subscription {
    return events().subscribeUnscoped(ctx, func);
}

fn events() *Event {
    if (users == 0) @panic("tuft: watches used before tuft_hook.watch.init()");
    return &hit_event;
}

/// Starts watching on every thread. Anything else using debug registers loses them.
pub fn add(w: Watch) !Slot {
    switch (w.len) {
        1, 2, 4 => {},
        8 => if (arch.bits != 64) return error.InvalidLength,
        else => return error.InvalidLength,
    }
    if (w.address % w.len != 0) return error.Misaligned;
    if (w.on == .execute and w.len != 1) return error.InvalidLength;

    lock.lock();
    defer lock.unlock();
    if (users == 0) return error.NotInitialized;
    const slot: Slot = for (watches, 0..) |existing, i| {
        if (existing == null) break @intCast(i);
    } else return error.NoFreeSlot;

    watches[slot] = w;
    shapes[slot].store(pack(w), .release);
    last[slot].store(w.address, .release);
    armed[slot].store(w.address, .release);
    apply() catch |err| {
        watches[slot] = null;
        armed[slot].store(0, .release);
        apply() catch {};
        return err;
    };
    return slot;
}

/// Fine if it's not watching anything.
pub fn remove(slot: Slot) void {
    lock.lock();
    defer lock.unlock();
    if (watches[slot] == null) return;
    watches[slot] = null;
    armed[slot].store(0, .release);
    apply() catch {};
}

pub fn get(slot: Slot) ?Watch {
    lock.lockShared();
    defer lock.unlockShared();
    return watches[slot];
}

/// Call every second or so to catch threads started since. Cheap when nothing's new.
pub fn refresh() void {
    lock.lock();
    defer lock.unlock();
    if (users == 0) return;
    for (watches) |w| {
        if (w != null) break;
    } else return;
    apply() catch {};
}

/// Hold `lock`.
fn apply() !void {
    var address: [max]usize = @splat(0);
    var control: usize = 0;
    for (watches, 0..) |maybe, i| {
        const w = maybe orelse continue;
        address[i] = w.address;
        const rw: usize = switch (w.on) {
            .execute => 0b00,
            .write => 0b01,
            .access => 0b11,
        };
        const len: usize = if (w.on == .execute) 0b00 else switch (w.len) {
            1 => 0b00,
            2 => 0b01,
            8 => 0b10,
            else => 0b11,
        };
        control |= @as(usize, 1) << @intCast(i * 2);
        control |= (rw | (len << 2)) << @intCast(16 + i * 4);
    }
    control_now.store(control, .release);
    _ = try sys.thread.setDebugRegisters(address, control);
}

/// What every thread's debug registers should hold right now.
pub const Registers = struct { address: [max]usize, control: usize };

/// A thread kept waiting resumes with its old registers, so put these in its `Exception.debug`.
pub fn registers() Registers {
    var r: Registers = .{ .address = undefined, .control = control_now.load(.acquire) };
    for (&r.address, &armed) |*a, *now| a.* = now.load(.acquire);
    return r;
}

fn pack(w: Watch) u8 {
    return w.len | (@as(u8, @backingInt(w.on)) << 4);
}

fn unpack(address: usize, shape: u8) Watch {
    return .{ .address = address, .len = shape & 0xF, .on = @fromBackingInt(@intCast(shape >> 4)) };
}

/// Set when the trap flag fired, not us.
const single_step_bit: usize = 1 << 14;

fn onException(ev: *Event, e: *exceptions.Exception) ?exceptions.Action {
    if (e.kind != .single_step) return null;
    var ours: usize = 0;
    for (0..max) |i| {
        const bit = @as(usize, 1) << @intCast(i);
        if (e.debug.status & bit == 0) continue;
        const at = e.debug.address[i];
        if (at == 0 or at != last[i].load(.acquire)) continue;
        ours |= bit;
        if (armed[i].load(.acquire) != at) continue;
        const hit: Hit = .{
            .slot = @intCast(i),
            .watch = unpack(at, shapes[i].load(.acquire)),
            .cpu = e.cpu,
            .thread_id = std.Thread.getCurrentId(),
        };
        // Or it'd hit again as soon as it resumes
        if (hit.watch.on == .execute) e.skipBreakpointOnce();
        ev.fire(.{&hit});
    }
    if (ours == 0) return null;
    e.debug.status &= ~ours;
    // Watches may have changed since this thread's registers were read
    const now = registers();
    e.debug.address = now.address;
    e.debug.control = now.control;
    // A trap flag step at the same time is someone else's
    if (e.debug.status & single_step_bit != 0) return null;
    return .handled;
}

const tests = struct {
    const testing = std.testing;

    const Seen = struct {
        count: std.atomic.Value(u32) = .init(0),
        last: ?Hit = null,

        fn on(self: *Seen, hit: *const Hit) void {
            _ = self.count.fetchAdd(1, .monotonic);
            self.last = hit.*;
        }
    };

    var value: u32 align(8) = 0;

    test "reports writes and accesses" {
        try init(testing.allocator);
        defer deinit();
        var seen: Seen = .{};
        const sub = try subscribeUnscoped(&seen, Seen.on);
        defer sub.unsubscribe();

        const target: *volatile u32 = &value;
        const slot = try add(.{ .address = @intFromPtr(&value), .len = 4, .on = .write });
        _ = target.*; // reads don't count
        try testing.expectEqual(0, seen.count.load(.monotonic));
        target.* = 1;
        try testing.expectEqual(1, seen.count.load(.monotonic));
        const hit = seen.last.?;
        try testing.expectEqual(slot, hit.slot);
        try testing.expectEqual(Watch{ .address = @intFromPtr(&value), .len = 4, .on = .write }, hit.watch);
        try testing.expectEqual(std.Thread.getCurrentId(), hit.thread_id);
        remove(slot);
        target.* = 2;
        try testing.expectEqual(1, seen.count.load(.monotonic));

        const any = try add(.{ .address = @intFromPtr(&value), .len = 4, .on = .access });
        defer remove(any);
        _ = target.*;
        try testing.expectEqual(2, seen.count.load(.monotonic));
    }

    noinline fn ran(x: u32) u32 {
        return x +% 7;
    }

    test "execute watch" {
        try init(testing.allocator);
        defer deinit();
        var seen: Seen = .{};
        const sub = try subscribeUnscoped(&seen, Seen.on);
        defer sub.unsubscribe();
        try testing.expectError(error.InvalidLength, add(.{ .address = @intFromPtr(&ran), .len = 2, .on = .execute }));
        const slot = try add(.{ .address = @intFromPtr(&ran), .len = 1, .on = .execute });
        defer remove(slot);
        try testing.expectEqual(8, ran(1));
        try testing.expectEqual(9, ran(2));
        try testing.expectEqual(2, seen.count.load(.monotonic));
        try testing.expectEqual(@intFromPtr(&ran), seen.last.?.cpu.ip());
    }

    test "slots and lengths" {
        try init(testing.allocator);
        defer deinit();
        var words: [5]u64 = undefined;
        var slots: [max]Slot = undefined;
        for (&slots, 0..) |*s, i| s.* = try add(.{ .address = @intFromPtr(&words[i]), .len = 4, .on = .write });
        try testing.expectError(error.NoFreeSlot, add(.{ .address = @intFromPtr(&words[4]), .len = 4, .on = .write }));
        for (slots) |s| remove(s);
        try testing.expectError(error.Misaligned, add(.{ .address = @intFromPtr(&words[0]) + 1, .len = 2, .on = .write }));
        try testing.expectError(error.InvalidLength, add(.{ .address = @intFromPtr(&words[0]), .len = 3, .on = .write }));

        try testing.expectEqual(4, lengthFor(0x1004, 8));
        try testing.expectEqual(1, lengthFor(0x1001, 4));
        try testing.expectEqual(2, lengthFor(0x1002, 3));
        try testing.expectEqual(if (arch.bits == 64) 8 else 4, lengthFor(0x1000, 16));
    }
};

test {
    _ = tests;
}
