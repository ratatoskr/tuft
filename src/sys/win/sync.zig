const std = @import("std");

const win = @import("api.zig");

/// One `set` lets one `wait` through. Waiting needs almost no stack.
pub const Signal = struct {
    handle: win.HANDLE,

    pub fn init() !Signal {
        return .{ .handle = win.CreateEventW(null, .FALSE, .FALSE, null) orelse return error.SystemResources };
    }

    pub fn deinit(self: Signal) void {
        win.CloseHandle(self.handle);
    }

    pub fn set(self: Signal) void {
        _ = win.SetEvent(self.handle);
    }

    /// False if it timed out. Null waits for good.
    pub fn wait(self: Signal, timeout_ms: ?u32) bool {
        return win.WaitForSingleObject(self.handle, timeout_ms orelse 0xFFFF_FFFF) == 0;
    }
};

/// Slim reader/writer lock.
pub const RwLock = struct {
    inner: win.SRWLOCK = .{},

    pub fn lock(self: *RwLock) void {
        win.AcquireSRWLockExclusive(&self.inner);
    }

    pub fn unlock(self: *RwLock) void {
        win.ReleaseSRWLockExclusive(&self.inner);
    }

    pub fn lockShared(self: *RwLock) void {
        win.AcquireSRWLockShared(&self.inner);
    }

    pub fn unlockShared(self: *RwLock) void {
        win.ReleaseSRWLockShared(&self.inner);
    }

    /// Never waits. False if someone has it exclusively.
    pub fn tryLockShared(self: *RwLock) bool {
        return win.TryAcquireSRWLockShared(&self.inner) != 0;
    }
};

const tests = struct {
    test "Signal lets one wait through per set" {
        const s = try Signal.init();
        defer s.deinit();
        try std.testing.expect(!s.wait(0));
        s.set();
        try std.testing.expect(s.wait(0));
        try std.testing.expect(!s.wait(1));
    }

    test "RwLock readers and writer" {
        var lock = RwLock{};
        var readers_inside = std.atomic.Value(u32).init(0);
        var both_entered = std.atomic.Value(bool).init(false);

        // Take the exclusive lock first so the readers have to block
        lock.lock();

        const ReaderCtx = struct {
            lock: *RwLock,
            readers_inside: *std.atomic.Value(u32),
            both_entered: *std.atomic.Value(bool),
        };

        var ctx = ReaderCtx{
            .lock = &lock,
            .readers_inside = &readers_inside,
            .both_entered = &both_entered,
        };

        const readerFn = struct {
            fn run(c: *ReaderCtx) void {
                c.lock.lockShared();
                defer c.lock.unlockShared();

                // Second reader in at the same time means it worked
                if (c.readers_inside.fetchAdd(1, .acq_rel) + 1 == 2) {
                    c.both_entered.store(true, .release);
                }

                while (!c.both_entered.load(.acquire)) {
                    std.atomic.spinLoopHint();
                }
            }
        }.run;

        const t1 = try std.Thread.spawn(.{}, readerFn, .{&ctx});
        const t2 = try std.Thread.spawn(.{}, readerFn, .{&ctx});

        try std.testing.io.sleep(.fromMilliseconds(2), .awake);
        try std.testing.expectEqual(0, readers_inside.load(.acquire));

        // Both readers have to get in together or it deadlocks
        lock.unlock();

        t1.join();
        t2.join();

        try std.testing.expect(both_entered.load(.acquire));
    }
};

test {
    _ = tests;
}
