//! Process-wide exception handlers, asked by priority until one handles it.

const std = @import("std");

const sys = @import("tuft_sys");
const tuft_event = @import("tuft_event");

pub const Exception = sys.exceptions.Exception;
pub const Kind = sys.exceptions.Kind;
pub const Fault = sys.exceptions.Fault;
pub const DebugRegisters = sys.exceptions.DebugRegisters;
pub const Action = sys.exceptions.Action;
pub const Event = tuft_event.Event(fn (*Exception) ?Action);
pub const Options = tuft_event.event.Options;
pub const Subscription = Event.Subscription;

const Vectored = sys.exceptions.Vectored(route);

var storage: Event = undefined;
var active: std.atomic.Value(?*Event) = .init(null);
/// Routes that might still be reading `active`. `deinit` waits them out before freeing it.
var in_flight: std.atomic.Value(u32) = .init(0);
var init_lock: sys.sync.RwLock = .{};
/// Outstanding `init`s.
var users: u32 = 0;

/// Each `init` needs a `deinit`. Subscriptions use the first caller's allocator.
pub fn init(allocator: std.mem.Allocator) !void {
    init_lock.lock();
    defer init_lock.unlock();
    if (users > 0) {
        users += 1;
        return;
    }
    storage = .init(allocator);
    active.store(&storage, .seq_cst);
    errdefer {
        active.store(null, .seq_cst);
        storage.deinit();
    }
    try Vectored.install(true);
    users = 1;
}

/// The last one removes the handler. Not from a handler, and subscriptions must be gone.
pub fn deinit() void {
    init_lock.lock();
    defer init_lock.unlock();
    if (users == 0) return;
    users -= 1;
    if (users > 0) return;
    Vectored.uninstall();
    active.store(null, .seq_cst);
    while (in_flight.load(.seq_cst) != 0) std.Thread.yield() catch {};
    storage.deinit();
}

/// Panics before `init`.
pub fn event() *Event {
    return active.load(.acquire) orelse @panic("tuft: exceptions used before tuft_hook.exceptions.init()");
}

/// `func` is `fn (ctx, *Exception) ?Action`, null passes. Lasts until `scope` is disposed.
/// Runs on the faulting thread, maybe holding a lock, so don't allocate or log.
pub fn subscribe(scope: *tuft_event.Scope, ctx: anytype, comptime func: anytype) !void {
    return event().subscribe(scope, ctx, func);
}

pub fn subscribeOpts(scope: *tuft_event.Scope, ctx: anytype, comptime func: anytype, options: Options) !void {
    return event().subscribeOpts(scope, ctx, func, options);
}

/// Lasts until you unsubscribe the result.
pub fn subscribeUnscoped(ctx: anytype, comptime func: anytype) !Subscription {
    return event().subscribeUnscoped(ctx, func);
}

pub fn subscribeUnscopedOpts(ctx: anytype, comptime func: anytype, options: Options) !Subscription {
    return event().subscribeUnscopedOpts(ctx, func, options);
}

fn route(e: *Exception) Action {
    _ = in_flight.fetchAdd(1, .seq_cst);
    defer _ = in_flight.fetchSub(1, .seq_cst);
    const ev = active.load(.seq_cst) orelse return .pass;
    return ev.fire(.{e}) orelse .pass;
}

const tests = struct {
    const testing = std.testing;

    const Probe = struct {
        name: u8,
        claim: bool,
        order: *std.ArrayList(u8),

        fn on(self: *Probe, e: *Exception) ?Action {
            if (e.kind != .breakpoint) return null;
            self.order.appendAssumeCapacity(self.name);
            if (!self.claim) return null;
            e.cpu.setIp(e.cpu.ip() + 1);
            return .handled;
        }
    };

    test "asked by priority" {
        try init(testing.allocator);
        defer deinit();

        var buf: [8]u8 = undefined;
        var order: std.ArrayList(u8) = .initBuffer(&buf);
        var low: Probe = .{ .name = 'l', .claim = true, .order = &order };
        var high: Probe = .{ .name = 'h', .claim = false, .order = &order };
        var never: Probe = .{ .name = 'n', .claim = true, .order = &order };

        var scope: tuft_event.Scope = .init(testing.allocator);
        defer scope.deinit();
        try subscribe(&scope, &low, Probe.on);
        try subscribeOpts(&scope, &high, Probe.on, .{ .priority = 10 });
        try subscribeOpts(&scope, &never, Probe.on, .{ .priority = -10 });

        @breakpoint();
        try testing.expectEqualStrings("hl", order.items);

        // Disposing the scope drops all three
        scope.dispose();
        order.clearRetainingCapacity();
        const only = try subscribeUnscoped(&never, Probe.on);
        defer only.unsubscribe();
        @breakpoint();
        try testing.expectEqualStrings("n", order.items);
    }

    test "init and deinit pair" {
        try init(testing.allocator);
        try init(testing.allocator);
        deinit();
        try testing.expect(Vectored.installed());
        deinit();
        try testing.expect(!Vectored.installed());
        deinit();
        try init(testing.allocator);
        deinit();
    }
};

test {
    _ = tests;
}
