//! Work handed to one thread, like the game window's. Posting never allocates or blocks.

const TaskQueue = @This();

const std = @import("std");

const Mailbox = @import("Mailbox.zig").Mailbox;

const log = std.log.scoped(.tuft_event);

pub const capacity = 256;
pub const PostError = Mailbox(Task, capacity).PushError;

/// Called at most once between drains to get the owning thread to run the queue.
pub const Wake = struct {
    ctx: *anyopaque,
    func: *const fn (*anyopaque) void,
};

const Task = struct {
    ctx: *anyopaque,
    run: *const fn (*anyopaque) void,
};

tasks: Mailbox(Task, capacity) = .{},
/// 0 until we know it.
thread_id: std.atomic.Value(std.Thread.Id) = .init(0),
/// Null for queues drained on a schedule, like every frame.
wake: ?Wake = null,
wake_pending: std.atomic.Value(bool) = .init(false),
/// Can nest if a task runs the queue again.
running: std.atomic.Value(u32) = .init(0),

pub fn post(self: *TaskQueue, ptr: anytype, comptime func: fn (@TypeOf(ptr)) void) PostError!void {
    const Ptr = @TypeOf(ptr);
    if (@typeInfo(Ptr) != .pointer) @compileError("TaskQueue.post expects a pointer, found " ++ @typeName(Ptr));

    const Wrap = struct {
        fn run(ctx: *anyopaque) void {
            func(@ptrCast(@alignCast(ctx)));
        }
    };
    try self.tasks.push(.{ .ctx = @ptrCast(@constCast(ptr)), .run = Wrap.run });
    if (self.wake) |w| {
        if (!self.wake_pending.swap(true, .acq_rel)) w.func(w.ctx);
    }
}

/// False until we know the thread.
pub fn isCurrent(self: *const TaskQueue) bool {
    const id = self.thread_id.load(.acquire);
    return id != 0 and id == std.Thread.getCurrentId();
}

/// So `isCurrent` works before the first `runPending`.
pub fn setThread(self: *TaskQueue, id: std.Thread.Id) void {
    self.thread_id.store(id, .release);
}

/// Owning thread only.
pub fn runPending(self: *TaskQueue) void {
    // seq_cst pairs with `closeAndWait`, so a round sees close or gets waited for
    _ = self.running.fetchAdd(1, .seq_cst);
    defer _ = self.running.fetchSub(1, .release);
    self.thread_id.store(std.Thread.getCurrentId(), .release);
    // Clear first so a post during these tasks wakes us again
    self.wake_pending.store(false, .release);
    var pending: [capacity]Task = undefined;
    for (self.tasks.drain(&pending)) |task| task.run(task.ctx);
}

/// Drops the queue and refuses new posts.
pub fn close(self: *TaskQueue) void {
    const dropped = self.tasks.close();
    if (dropped != 0) log.warn("Dropped {} queued tasks that never got to run", .{dropped});
}

/// False on timeout. Doesn't wait on the owning thread.
pub fn closeAndWait(self: *TaskQueue, io: std.Io, timeout: std.Io.Duration) bool {
    self.close();
    if (self.isCurrent()) return true;
    const deadline = std.Io.Clock.awake.now(io).addDuration(timeout);
    while (self.running.load(.seq_cst) != 0) {
        if (std.Io.Clock.awake.now(io).compare(.gte, deadline)) return false;
        io.sleep(.fromMilliseconds(1), .awake) catch return false;
    }
    return true;
}

const tests = struct {
    const testing = std.testing;

    const Counter = struct {
        values: [8]u32 = undefined,
        len: usize = 0,
        on_owner: bool = true,
        queue: *TaskQueue = undefined,

        fn add(self: *Counter, v: u32) void {
            self.values[self.len] = v;
            self.len += 1;
            if (!self.queue.isCurrent()) self.on_owner = false;
        }

        fn one(self: *Counter) void {
            self.add(1);
        }

        fn two(self: *Counter) void {
            self.add(2);
        }
    };

    test "tasks run in order" {
        var queue: TaskQueue = .{};
        var counter: Counter = .{ .queue = &queue };

        try testing.expect(!queue.isCurrent());
        const poster = try std.Thread.spawn(.{}, struct {
            fn run(q: *TaskQueue, c: *Counter) void {
                q.post(c, Counter.one) catch unreachable;
                q.post(c, Counter.two) catch unreachable;
            }
        }.run, .{ &queue, &counter });
        poster.join();

        try testing.expectEqual(0, counter.len);
        queue.runPending();
        try testing.expectEqualSlices(u32, &.{ 1, 2 }, counter.values[0..counter.len]);
        try testing.expect(counter.on_owner);
        try testing.expect(queue.isCurrent());

        queue.runPending();
        try testing.expectEqual(2, counter.len);
    }

    test "wake once per batch" {
        const Waker = struct {
            var wakes: u32 = 0;
            fn wake(_: *anyopaque) void {
                wakes += 1;
            }
        };
        var dummy: u8 = 0;
        var queue: TaskQueue = .{ .wake = .{ .ctx = &dummy, .func = Waker.wake } };
        var counter: Counter = .{ .queue = &queue };

        try queue.post(&counter, Counter.one);
        try queue.post(&counter, Counter.two);
        try testing.expectEqual(1, Waker.wakes);

        queue.runPending();
        try queue.post(&counter, Counter.one);
        try testing.expectEqual(2, Waker.wakes);
    }

    test "full or closed" {
        const saved = std.testing.log_level;
        std.testing.log_level = .err;
        defer std.testing.log_level = saved;

        var queue: TaskQueue = .{};
        var counter: Counter = .{ .queue = &queue };

        for (0..capacity) |_| try queue.post(&counter, Counter.one);
        try testing.expectError(error.QueueFull, queue.post(&counter, Counter.one));

        queue.close();
        try testing.expectError(error.Closed, queue.post(&counter, Counter.one));
        queue.runPending();
        try testing.expectEqual(0, counter.len);
    }

    test "closeAndWait waits" {
        const Slow = struct {
            started: std.atomic.Value(bool) = .init(false),
            done: std.atomic.Value(bool) = .init(false),

            fn run(self: *@This()) void {
                self.started.store(true, .release);
                testing.io.sleep(.fromMilliseconds(50), .awake) catch {};
                self.done.store(true, .release);
            }
        };
        var queue: TaskQueue = .{};
        var slow: Slow = .{};
        try queue.post(&slow, Slow.run);
        const owner = try std.Thread.spawn(.{}, TaskQueue.runPending, .{&queue});
        defer owner.join();

        while (!slow.started.load(.acquire)) try std.Thread.yield();
        try testing.expect(queue.closeAndWait(testing.io, .fromSeconds(5)));
        try testing.expect(slow.done.load(.acquire));
    }
};

test {
    _ = tests;
}
