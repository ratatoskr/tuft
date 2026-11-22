//! A lock that hands itself straight to the longest waiter when it's let go of, so nobody can cut in
//! ahead and whoever waits can be anything: a thread, a parked fiber, a promise. Threads wait on an
//! event with `lock`. Anything else brings its own `Waiter` to `lockOr`. Not reentrant.

const Mutex = @This();

const std = @import("std");
const atomic = @import("tuft_arch").atomic;

const native = @import("win/root.zig");

held: atomic.Value(bool) = .init(false),
/// Under `guard`. Only waiters while `held`, so letting go always has someone to hand it to or not.
head: ?*Waiter = null,
tail: ?*Waiter = null,
guard: atomic.Value(bool) = .init(false),

pub const Waiter = struct {
    /// Called once the lock's yours, from the thread that let go of it. Keep it short.
    wake: *const fn (w: *Waiter) void,
    next: ?*Waiter = null,
};

pub fn tryLock(self: *Mutex) bool {
    return self.held.cmpxchgStrong(false, true, .acquire, .monotonic) == null;
}

/// True if it's yours now. Otherwise `w` waits in line and `w.wake` runs once it's yours. `w` has to
/// stay put till then, or till `cancel` takes it out.
pub fn lockOr(self: *Mutex, w: *Waiter) bool {
    self.acquireGuard();
    defer self.releaseGuard();
    if (self.tryLock()) return true;
    w.next = null;
    if (self.tail) |t| t.next = w else self.head = w;
    self.tail = w;
    return false;
}

/// Takes `w` out of line. False if it wasn't in it, which means the lock's been handed to it, and
/// `wake` runs or ran for it. Then it's `w`'s to let go of.
pub fn cancel(self: *Mutex, w: *Waiter) bool {
    self.acquireGuard();
    defer self.releaseGuard();
    var prev: ?*Waiter = null;
    var at = self.head;
    while (at) |cur| : ({
        prev = cur;
        at = cur.next;
    }) {
        if (cur != w) continue;
        if (prev) |p| p.next = cur.next else self.head = cur.next;
        if (self.tail == cur) self.tail = prev;
        return true;
    }
    return false;
}

/// Hands it to the longest waiter, if there's one.
pub fn unlock(self: *Mutex) void {
    const next = blk: {
        self.acquireGuard();
        defer self.releaseGuard();
        const w = self.head orelse {
            self.held.store(false, .release);
            return;
        };
        self.head = w.next;
        if (self.head == null) self.tail = null;
        break :blk w;
    };
    // Still held, now by `next`
    next.wake(next);
}

/// Blocks this thread till it's yours. Spins a little first, since it's usually let go of quickly.
pub fn lock(self: *Mutex) void {
    for (0..64) |_| {
        if (self.tryLock()) return;
        std.atomic.spinLoopHint();
    }
    var w: ThreadWaiter = .{ .signal = native.sync.Signal.init() catch return self.lockSpinning() };
    defer w.signal.deinit();
    if (self.lockOr(&w.waiter)) return;
    while (!w.handed.load(.acquire)) _ = w.signal.wait(null);
}

/// Without an event to wait on.
fn lockSpinning(self: *Mutex) void {
    while (!self.tryLock()) native.thread.sleepMs(0);
}

const ThreadWaiter = struct {
    waiter: Waiter = .{ .wake = wake },
    signal: native.sync.Signal,
    handed: atomic.Value(bool) = .init(false),

    fn wake(w: *Waiter) void {
        const self: *ThreadWaiter = @alignCast(@fieldParentPtr("waiter", w));
        self.handed.store(true, .release);
        self.signal.set();
    }
};

fn acquireGuard(self: *Mutex) void {
    while (self.guard.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
}

fn releaseGuard(self: *Mutex) void {
    self.guard.store(false, .release);
}

const testing = std.testing;

test "threads take turns" {
    var m: Mutex = .{};
    var count: u32 = 0;
    const Adder = struct {
        fn run(lock_: *Mutex, n: *u32) void {
            for (0..20_000) |_| {
                lock_.lock();
                n.* += 1;
                lock_.unlock();
            }
        }
    };
    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Adder.run, .{ &m, &count });
    for (threads) |t| t.join();
    try testing.expectEqual(80_000, count);
    try testing.expect(!m.held.load(.acquire));
}

test "letting go hands it to the longest waiter" {
    const Line = struct {
        var order: [3]u8 = undefined;
        var n: usize = 0;

        const Mine = struct {
            waiter: Waiter = .{ .wake = woke },
            id: u8,

            fn woke(w: *Waiter) void {
                const self: *Mine = @alignCast(@fieldParentPtr("waiter", w));
                order[n] = self.id;
                n += 1;
            }
        };
    };
    var m: Mutex = .{};
    try testing.expect(m.tryLock());
    var a: Line.Mine = .{ .id = 'a' };
    var b: Line.Mine = .{ .id = 'b' };
    var c: Line.Mine = .{ .id = 'c' };
    try testing.expect(!m.lockOr(&a.waiter));
    try testing.expect(!m.lockOr(&b.waiter));
    try testing.expect(!m.lockOr(&c.waiter));
    // b gives up
    try testing.expect(m.cancel(&b.waiter));
    m.unlock();
    // a has it, and nobody can cut in
    try testing.expect(!m.tryLock());
    try testing.expect(!m.cancel(&a.waiter));
    m.unlock();
    m.unlock();
    try testing.expectEqualSlices(u8, "ac", Line.order[0..Line.n]);
    try testing.expect(m.tryLock());
    m.unlock();
}
