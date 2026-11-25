//! Windows fibers. They swap the stack bounds the OS keeps per thread, so stack probes and exceptions work on
//! them. A fiber can be resumed on any thread, one at a time.

const std = @import("std");
const builtin = @import("builtin");

const FIBER_FLAG_FLOAT_SWITCH: u32 = 1;

extern "kernel32" fn CreateFiberEx(commit: usize, reserve: usize, flags: u32, start: *const fn (?*anyopaque) callconv(.winapi) void, param: ?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn DeleteFiber(fiber: *anyopaque) callconv(.winapi) void;
extern "kernel32" fn SwitchToFiber(fiber: *anyopaque) callconv(.winapi) void;
extern "kernel32" fn ConvertThreadToFiberEx(param: ?*anyopaque, flags: u32) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn ConvertFiberToThread() callconv(.winapi) std.os.windows.BOOL;
extern "kernel32" fn IsThreadAFiber() callconv(.winapi) std.os.windows.BOOL;

/// `Fiber.resumeHere` only makes a thread a fiber while one runs, so outside them this is false.
pub fn inFiber() bool {
    return IsThreadAFiber().toBool();
}

/// The running fiber, from the thread's TEB. Only meaningful when `IsThreadAFiber`.
fn currentFiber() *anyopaque {
    return switch (builtin.cpu.arch) {
        .x86_64 => asm volatile (
            \\.intel_syntax noprefix
            \\mov %[out:V], gs:[0x20]
            \\.att_syntax prefix
            : [out] "=r" (-> *anyopaque),
        ),
        .x86 => asm volatile (
            \\.intel_syntax noprefix
            \\mov %[out:V], fs:[0x10]
            \\.att_syntax prefix
            : [out] "=r" (-> *anyopaque),
        ),
        // x18 always holds the TEB on Windows ARM64
        .aarch64 => asm volatile ("ldr %[out], [x18, #0x20]"
            : [out] "=r" (-> *anyopaque),
        ),
        else => @compileError("fibers need x86, x86_64 or aarch64"),
    };
}

pub const Fiber = struct {
    handle: ?*anyopaque = null,
    /// Where `yield` goes back to. Set on each `resumeHere`.
    caller: ?*anyopaque = null,
    entry: *const fn (fiber: *Fiber) void,
    finished: bool = false,

    pub const Options = struct {
        /// Grows into this as needed.
        stack_size: usize = 1 << 20,
    };

    /// `entry` runs on the first `resumeHere`. `self` must not move.
    pub fn init(self: *Fiber, entry: *const fn (fiber: *Fiber) void, options: Options) error{FiberFailed}!void {
        self.* = .{ .entry = entry };
        self.handle = CreateFiberEx(0, options.stack_size, FIBER_FLAG_FLOAT_SWITCH, start, self) orelse return error.FiberFailed;
    }

    /// Not while it's running. A fiber that never finished just has its stack dropped, no `defer`s run.
    pub fn deinit(self: *Fiber) void {
        if (self.handle) |h| DeleteFiber(h);
        self.handle = null;
    }

    /// Runs it on this thread till it yields or finishes. The thread doesn't need to be a fiber already.
    pub fn resumeHere(self: *Fiber) void {
        std.debug.assert(!self.finished);
        const converted = !IsThreadAFiber().toBool();
        if (converted) _ = ConvertThreadToFiberEx(null, FIBER_FLAG_FLOAT_SWITCH) orelse return;
        defer if (converted) {
            _ = ConvertFiberToThread();
        };
        self.caller = currentFiber();
        SwitchToFiber(self.handle.?);
    }

    /// From inside it. Back to whoever resumed it, till it's resumed again, maybe on another thread.
    pub fn yield(self: *Fiber) void {
        SwitchToFiber(self.caller.?);
    }

    fn start(param: ?*anyopaque) callconv(.winapi) void {
        const self: *Fiber = @ptrCast(@alignCast(param.?));
        self.entry(self);
        self.finished = true;
        // Returning would end the thread
        while (true) SwitchToFiber(self.caller.?);
    }
};

const tests = struct {
    const testing = std.testing;

    const Counter = struct {
        fiber: Fiber = undefined,
        steps: u32 = 0,
        threads: [3]u32 = @splat(0),
        in_fiber: bool = false,

        fn run(f: *Fiber) void {
            const self: *Counter = @alignCast(@fieldParentPtr("fiber", f));
            for (0..3) |i| {
                self.threads[i] = std.Thread.getCurrentId();
                self.in_fiber = inFiber();
                self.steps += 1;
                f.yield();
            }
        }
    };

    test "yields and resumes" {
        var c: Counter = .{};
        try c.fiber.init(Counter.run, .{});
        defer c.fiber.deinit();
        try testing.expect(!inFiber());
        c.fiber.resumeHere();
        try testing.expectEqual(1, c.steps);
        try testing.expect(c.in_fiber);
        try testing.expect(!IsThreadAFiber().toBool());
        c.fiber.resumeHere();
        c.fiber.resumeHere();
        try testing.expectEqual(3, c.steps);
        try testing.expect(!c.fiber.finished);
        c.fiber.resumeHere();
        try testing.expect(c.fiber.finished);
    }

    test "moves between threads" {
        var c: Counter = .{};
        try c.fiber.init(Counter.run, .{});
        defer c.fiber.deinit();
        c.fiber.resumeHere();
        const Other = struct {
            fn go(f: *Fiber) void {
                f.resumeHere();
            }
        };
        const t = try std.Thread.spawn(.{}, Other.go, .{&c.fiber});
        t.join();
        c.fiber.resumeHere();
        try testing.expectEqual(std.Thread.getCurrentId(), c.threads[0]);
        try testing.expect(c.threads[1] != c.threads[0]);
        try testing.expectEqual(c.threads[0], c.threads[2]);
    }

    const Deep = struct {
        fiber: Fiber = undefined,
        sum: u64 = 0,

        // Big enough to need stack probes past the first committed page
        noinline fn use(self: *Deep) void {
            var big: [256 * 1024]u8 = undefined;
            for (&big, 0..) |*b, i| b.* = @truncate(i);
            std.mem.doNotOptimizeAway(&big);
            for (big) |b| self.sum += b;
        }

        fn run(f: *Fiber) void {
            const self: *Deep = @alignCast(@fieldParentPtr("fiber", f));
            self.use();
        }
    };

    test "stacks grow" {
        var d: Deep = .{};
        try d.fiber.init(Deep.run, .{});
        defer d.fiber.deinit();
        d.fiber.resumeHere();
        try testing.expect(d.fiber.finished);
        try testing.expect(d.sum > 0);
    }

    test "nested in another fiber" {
        const Outer = struct {
            fiber: Fiber = undefined,
            inner: Counter = .{},

            fn run(f: *Fiber) void {
                const self: *@This() = @alignCast(@fieldParentPtr("fiber", f));
                self.inner.fiber.resumeHere();
                f.yield();
                self.inner.fiber.resumeHere();
            }
        };
        var o: Outer = .{};
        try o.fiber.init(Outer.run, .{});
        defer o.fiber.deinit();
        try o.inner.fiber.init(Counter.run, .{});
        defer o.inner.fiber.deinit();
        o.fiber.resumeHere();
        try testing.expectEqual(1, o.inner.steps);
        o.fiber.resumeHere();
        try testing.expect(o.fiber.finished);
        try testing.expectEqual(2, o.inner.steps);
    }
};

test {
    _ = tests;
}
