//! Who stuff belongs to, like a plugin or script. Systems clean up on its lifecycle.
//! It has a Salamander owner too, which tables made for it check before every call. Closing this
//! closes and drains that, so calls through them stop before anything else lets go.

const Owner = @This();

const std = @import("std");

const sync = @import("tuft_sys").sync;
const rt = @import("salamander_runtime");
const Event = @import("event.zig").Event;

/// Borrowed, so it has to outlive the owner.
name: []const u8,
lock: sync.RwLock = .{},
state: State = .open,
/// Its Salamander owner, made the first time it's asked for. Never held with `lock`.
sal_lock: sync.RwLock = .{},
sal: ?*rt.Owner = null,

pub const State = enum { open, closed, released };

pub const Use = enum {
    /// Calls into the owner's code, like a hook. Only while open.
    calls,
    /// Kept for the owner, like a timing. Until released.
    data,
};

pub const Lifecycle = Event(fn (owner: *Owner) void);

/// Stop calling the owner's code and wait for calls in flight.
pub var closing: Lifecycle = .init(std.heap.page_allocator);
/// Its code stopped, free what was kept for it.
pub var released: Lifecycle = .init(std.heap.page_allocator);

/// How a system listens. Subscribes on the first `lease`.
pub fn Watch(comptime Ctx: type, comptime on: struct {
    closing: ?fn (Ctx, *Owner) void = null,
    released: ?fn (Ctx, *Owner) void = null,
}) type {
    return struct {
        const Self = @This();

        /// Never hold with a lease or the system's locks. Subscribing can wait on handlers that take those.
        lock: sync.RwLock = .{},
        on_closing: ?Lifecycle.Subscription = null,
        on_released: ?Lifecycle.Subscription = null,
        subscribed: bool = false,

        /// Null if the owner's past `use` or subscribing failed.
        pub fn lease(self: *Self, ctx: Ctx, owner: *Owner, use: Use) ?Lease {
            self.subscribe(ctx) catch return null;
            return owner.lease(use);
        }

        pub fn subscribe(self: *Self, ctx: Ctx) !void {
            self.lock.lock();
            defer self.lock.unlock();
            if (self.subscribed) return;
            if (on.closing) |f| self.on_closing = try closing.subscribeUnscoped(ctx, f);
            errdefer if (self.on_closing) |s| s.unsubscribe();
            if (on.released) |f| self.on_released = try released.subscribeUnscoped(ctx, f);
            self.subscribed = true;
        }

        /// After this the handlers aren't running and won't be called.
        pub fn deinit(self: *Self) void {
            self.lock.lock();
            defer self.lock.unlock();
            if (self.on_closing) |s| s.unsubscribe();
            if (self.on_released) |s| s.unsubscribe();
            self.on_closing = null;
            self.on_released = null;
            self.subscribed = false;
        }
    };
}

pub fn init(name: []const u8) Owner {
    return .{ .name = name };
}

/// `end` it once the thing is recorded.
pub const Lease = struct {
    owner: *Owner,

    pub fn end(self: Lease) void {
        self.owner.lock.unlockShared();
    }
};

/// Null if the owner's past `use`.
pub fn lease(self: *Owner, use: Use) ?Lease {
    self.lock.lockShared();
    const allowed = switch (use) {
        .calls => self.state == .open,
        .data => self.state != .released,
    };
    if (!allowed) {
        self.lock.unlockShared();
        return null;
    }
    return .{ .owner = self };
}

pub fn isOpen(self: *Owner) bool {
    self.lock.lockShared();
    defer self.lock.unlockShared();
    return self.state == .open;
}

/// Its Salamander owner, for tables made for it. It's the host's, so it outlives this, and tables
/// pointing at it stay safe to call. Null once it's closed, or out of memory.
pub fn salamander(self: *Owner) ?*rt.Owner {
    self.sal_lock.lock();
    defer self.sal_lock.unlock();
    if (self.sal) |s| return if (s.isOpen()) s else null;
    if (!self.isOpen()) return null;
    self.sal = rt.host().owner(self.name) catch return null;
    return self.sal;
}

/// Its Salamander owner if it has one, without making one.
pub fn salamanderMade(self: *Owner) ?*rt.Owner {
    self.sal_lock.lockShared();
    defer self.sal_lock.unlockShared();
    return self.sal;
}

/// Waits for in-flight registrations first, then for calls through its Salamander tables. Never from
/// inside one of those calls. Fine to call twice.
pub fn close(self: *Owner) void {
    if (!self.advance(.closed)) return;
    if (self.salamanderMade()) |s| s.drain();
    closing.fire(.{self});
}

/// Closes first if needed. Its code must have stopped. Fine to call twice.
pub fn release(self: *Owner) void {
    self.close();
    if (!self.advance(.released)) return;
    released.fire(.{self});
}

/// Moves to `to` if that's further along. Waits for leases.
fn advance(self: *Owner, to: State) bool {
    self.lock.lock();
    defer self.lock.unlock();
    if (@backingInt(self.state) >= @backingInt(to)) return false;
    self.state = to;
    return true;
}

const tests = struct {
    const testing = std.testing;

    const Listener = struct {
        closed: ?*Owner = null,
        released: ?*Owner = null,
        closes: u32 = 0,
        releases: u32 = 0,
        calls_while_closing: bool = true,
        data_while_closing: bool = false,

        fn onClosing(self: *Listener, owner: *Owner) void {
            self.closed = owner;
            self.closes += 1;
            if (owner.lease(.calls)) |l| l.end() else self.calls_while_closing = false;
            if (owner.lease(.data)) |l| {
                l.end();
                self.data_while_closing = true;
            }
        }

        fn onReleased(self: *Listener, owner: *Owner) void {
            self.released = owner;
            self.releases += 1;
        }
    };

    test "close and release order" {
        var listener: Listener = .{};
        const a = try closing.subscribeUnscoped(&listener, Listener.onClosing);
        defer a.unsubscribe();
        const b = try released.subscribeUnscoped(&listener, Listener.onReleased);
        defer b.unsubscribe();

        var owner: Owner = .init("kai");
        const open_lease = owner.lease(.calls).?;
        open_lease.end();

        owner.close();
        owner.close();
        try testing.expectEqual(&owner, listener.closed.?);
        try testing.expectEqual(1, listener.closes);
        try testing.expect(!listener.calls_while_closing);
        try testing.expect(listener.data_while_closing);
        try testing.expectEqual(null, listener.released);
        try testing.expect(!owner.isOpen());

        owner.release();
        owner.release();
        try testing.expectEqual(&owner, listener.released.?);
        try testing.expectEqual(1, listener.releases);
        try testing.expectEqual(null, owner.lease(.data));
    }

    test "release closes first" {
        var listener: Listener = .{};
        const a = try closing.subscribeUnscoped(&listener, Listener.onClosing);
        defer a.unsubscribe();
        const b = try released.subscribeUnscoped(&listener, Listener.onReleased);
        defer b.unsubscribe();

        var owner: Owner = .init("script");
        owner.release();
        try testing.expectEqual(1, listener.closes);
        try testing.expectEqual(1, listener.releases);
    }

    test "salamander owner closes with it" {
        var owner: Owner = .init("sal");
        try testing.expectEqual(null, owner.salamanderMade());
        const s = owner.salamander().?;
        try testing.expectEqual(s, owner.salamander().?);
        try testing.expect(s.enter());
        s.leave();
        owner.release();
        try testing.expect(!s.isOpen());
        try testing.expectEqual(null, owner.salamander());

        // Too late to make one once it's closed
        var late: Owner = .init("late");
        late.close();
        try testing.expectEqual(null, late.salamander());
    }

    test "watch lifecycle" {
        var listener: Listener = .{};
        var watch: Watch(*Listener, .{ .released = Listener.onReleased }) = .{};
        var first: Owner = .init("first");
        first.release(); // watch isn't subscribed yet, so not heard
        try testing.expectEqual(0, listener.releases);

        var owner: Owner = .init("kai");
        const l = watch.lease(&listener, &owner, .calls).?;
        l.end();
        owner.release();
        try testing.expectEqual(&owner, listener.released.?);
        try testing.expectEqual(0, listener.closes); // only asked for `released`
        try testing.expectEqual(null, watch.lease(&listener, &owner, .data));

        watch.deinit();
        var later: Owner = .init("later");
        later.release();
        try testing.expectEqual(1, listener.releases);

        // It can start again, like `Claims.enable` after `disable`
        var again: Owner = .init("again");
        const l2 = watch.lease(&listener, &again, .calls).?;
        l2.end();
        again.release();
        try testing.expectEqual(2, listener.releases);
        watch.deinit();
    }
};

test {
    _ = tests;
}
