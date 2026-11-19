const std = @import("std");
const builtin = @import("builtin");
const zwin = std.os.windows;

const sys = @import("../root.zig");

const win = @import("api.zig");
const memory = @import("memory.zig");

const CodeRange = sys.thread.CodeRange;
const Avoid = sys.thread.Avoid;

pub fn sleepMs(ms: u32) void {
    win.Sleep(ms);
}

/// A thread running `func(ctx)`. Unlike `std.Thread.spawn` this works from game threads that
/// have an activation context.
pub fn spawn(comptime Ctx: type, comptime func: fn (Ctx) void, ctx: Ctx) !*anyopaque {
    const Start = struct {
        fn run(param: ?*anyopaque) callconv(.winapi) win.DWORD {
            const c: Ctx = @ptrCast(@alignCast(param.?));
            func(c);
            return 0;
        }
    };
    return win.CreateThread(null, 0, Start.run, @ptrCast(ctx), 0, null) orelse error.SystemResources;
}

/// Waits for it to finish and lets go of it.
pub fn join(thread: *anyopaque) void {
    _ = win.WaitForSingleObject(thread, win.INFINITE);
    win.CloseHandle(thread);
}

pub fn tickMs() u64 {
    return win.GetTickCount64();
}

pub fn currentStack() sys.thread.CodeRange {
    var low: usize = 0;
    var high: usize = 0;
    win.GetCurrentThreadStackLimits(&low, &high);
    return .{ .start = low, .len = high - low };
}

const Context = switch (builtin.cpu.arch) {
    .x86_64 => struct {
        const control: win.DWORD = 0x0010_0001; // CONTEXT_AMD64 | CONTEXT_CONTROL
        const integer: win.DWORD = 0x0010_0002; // CONTEXT_AMD64 | CONTEXT_INTEGER
        const debug: win.DWORD = 0x0010_0010; // CONTEXT_AMD64 | CONTEXT_DEBUG_REGISTERS
        const registers = .{ "Rax", "Rcx", "Rdx", "Rbx", "Rbp", "Rsi", "Rdi", "R8", "R9", "R10", "R11", "R12", "R13", "R14", "R15" };
    },
    .x86 => struct {
        const control: win.DWORD = 0x0001_0001; // CONTEXT_i386 | CONTEXT_CONTROL
        const integer: win.DWORD = 0x0001_0002; // CONTEXT_i386 | CONTEXT_INTEGER
        const debug: win.DWORD = 0x0001_0010; // CONTEXT_i386 | CONTEXT_DEBUG_REGISTERS
        const registers = .{ "Eax", "Ecx", "Edx", "Ebx", "Ebp", "Esi", "Edi" };
    },
    else => @compileError("Unsupported architecture"),
};

/// Threads that have them already are skipped. Returns how many changed.
pub fn setDebugRegisters(address: [4]usize, control: usize) !usize {
    const current_tid = zwin.GetCurrentThreadId();
    const access = win.THREAD_SUSPEND_RESUME | win.THREAD_GET_CONTEXT | win.THREAD_SET_CONTEXT | win.THREAD_QUERY_LIMITED_INFORMATION;
    var changed: usize = 0;

    if (setDebugOn(win.GetCurrentThread(), false, address, control)) changed += 1;

    var cursor: ?win.HANDLE = null;
    defer if (cursor) |h| win.CloseHandle(h);
    while (true) {
        var next: ?win.HANDLE = null;
        const status = win.NtGetNextThread(zwin.GetCurrentProcess(), cursor, access, 0, 0, &next);
        if (cursor) |h| win.CloseHandle(h);
        cursor = null;
        if (status == .NO_MORE_ENTRIES) break;
        if (status != .SUCCESS) return error.Unexpected;
        cursor = next.?;
        if (win.GetThreadId(cursor.?) == current_tid) continue;
        if (setDebugOn(cursor.?, true, address, control)) changed += 1;
    }
    return changed;
}

/// True if it changed them.
fn setDebugOn(thread: win.HANDLE, suspend_it: bool, address: [4]usize, control: usize) bool {
    var ctx: zwin.CONTEXT align(16) = std.mem.zeroes(zwin.CONTEXT);
    ctx.ContextFlags = Context.debug;
    // Debug registers only change when someone sets them, so a running thread reads fine
    if (win.GetThreadContext(thread, &ctx) == zwin.BOOL.FALSE) return false;
    const now = [_]usize{ @intCast(ctx.Dr0), @intCast(ctx.Dr1), @intCast(ctx.Dr2), @intCast(ctx.Dr3) };
    // Enable bits plus each slot's condition and length. Bit 10 always reads as 1
    const meaningful: usize = 0xFFFF_00FF;
    if (std.mem.eql(usize, &now, &address) and @as(usize, @intCast(ctx.Dr7)) & meaningful == control & meaningful) return false;

    if (suspend_it and win.SuspendThread(thread) == std.math.maxInt(win.DWORD)) return false;
    defer if (suspend_it) {
        _ = win.ResumeThread(thread);
    };
    ctx.ContextFlags = Context.debug;
    ctx.Dr0 = @intCast(address[0]);
    ctx.Dr1 = @intCast(address[1]);
    ctx.Dr2 = @intCast(address[2]);
    ctx.Dr3 = @intCast(address[3]);
    ctx.Dr6 = 0;
    ctx.Dr7 = @intCast(control);
    return win.SetThreadContext(thread, &ctx) != zwin.BOOL.FALSE;
}

const freeze_attempts = 20;

/// From the last freeze, to size the next one.
var last_thread_count: std.atomic.Value(usize) = .init(32);

/// Never allocates or locks while threads are suspended since they may hold the heap lock.
pub fn freezeThreads(allocator: std.mem.Allocator, avoid: Avoid) !ThreadFreezeGuard {
    var capacity = last_thread_count.load(.monotonic) + 16;
    var attempt: usize = 1;
    while (true) {
        const guard = freezeThreadsOnce(allocator, avoid, capacity) catch |err| switch (err) {
            error.OutOfRoom => {
                capacity *= 2;
                continue;
            },
            error.ThreadCollision => {
                if (attempt == freeze_attempts) return err;
                attempt += 1;
                win.Sleep(1);
                continue;
            },
            else => return err,
        };
        last_thread_count.store(guard.count(), .monotonic);
        return guard;
    }
}

fn freezeThreadsOnce(allocator: std.mem.Allocator, avoid: Avoid, capacity: usize) !ThreadFreezeGuard {
    var guard = ThreadFreezeGuard{
        .allocator = allocator,
        .handles = try .initCapacity(allocator, capacity),
    };
    errdefer guard.deinit();

    const current_tid = zwin.GetCurrentThreadId();
    var access = win.THREAD_SUSPEND_RESUME | win.THREAD_GET_CONTEXT | win.THREAD_QUERY_LIMITED_INFORMATION;
    if (avoid.keep != null) access |= win.THREAD_QUERY_INFORMATION;

    // Faster than a Toolhelp snapshot. Each handle is the cursor for the next call
    var cursor: ?win.HANDLE = null;
    var cursor_kept = false;
    defer if (cursor) |h| if (!cursor_kept) win.CloseHandle(h);

    while (true) {
        var next: ?win.HANDLE = null;
        const status = win.NtGetNextThread(zwin.GetCurrentProcess(), cursor, access, 0, 0, &next);
        if (cursor) |h| if (!cursor_kept) win.CloseHandle(h);
        cursor = null;
        if (status == .NO_MORE_ENTRIES) break;
        if (status != .SUCCESS) return error.Unexpected;

        const h_thread = next.?;
        cursor = h_thread;
        cursor_kept = false;
        const tid = win.GetThreadId(h_thread);
        if (tid == current_tid) continue;
        if (avoid.keep) |keep| {
            if (keep.func(keep.ctx, .{ .id = tid, .start = startOf(h_thread) })) continue;
        }

        // Out of room, retry with more space
        if (guard.handles.items.len == guard.handles.capacity) return error.OutOfRoom;

        guard.handles.appendAssumeCapacity(h_thread);
        guard.frozen += 1;
        cursor_kept = true;
    }

    // Pick kept threads before suspending any, the filter can need the loader lock
    // Ones that won't suspend go to the end, closed in deinit. Closing now could block on a lock a frozen thread holds
    guard.suspended = true;
    var i: usize = 0;
    while (i < guard.frozen) {
        if (win.SuspendThread(guard.handles.items[i]) == std.math.maxInt(win.DWORD)) {
            guard.frozen -= 1;
            std.mem.swap(win.HANDLE, &guard.handles.items[i], &guard.handles.items[guard.frozen]);
            continue;
        }
        i += 1;
    }

    // Check after suspending them all, since waiting per thread would serialize them
    const owner = if (avoid.loader_lock) loaderLockOwner() else 0;
    for (guard.handles.items[0..guard.frozen]) |h_thread| {
        // errdefer resumes everything so the caller can retry
        if (owner != 0 and win.GetThreadId(h_thread) == owner) return error.ThreadCollision;
        // Also waits for the suspend to land
        var ctx: zwin.CONTEXT align(16) = std.mem.zeroes(zwin.CONTEXT);
        ctx.ContextFlags = if (avoid.referenced.len != 0) Context.control | Context.integer else Context.control;
        if (win.GetThreadContext(h_thread, &ctx) == zwin.BOOL.FALSE) continue;
        if (inAny(avoid.executing, ctx.getRegs().ip)) return error.ThreadCollision;
        if (avoid.referenced.len != 0) {
            inline for (Context.registers) |name| {
                if (inAny(avoid.referenced, @field(ctx, name))) return error.ThreadCollision;
            }
        }
    }
    return guard;
}

fn startOf(thread: win.HANDLE) usize {
    var start: usize = 0;
    const status = win.NtQueryInformationThread(thread, win.ThreadQuerySetWin32StartAddress, &start, @sizeOf(usize), null);
    return if (status == .SUCCESS) start else 0;
}

/// 0 if none.
fn loaderLockOwner() u32 {
    const owner = @intFromPtr(zwin.peb().LoaderLock.OwningThread);
    return @truncate(owner);
}

fn inAny(ranges: []const CodeRange, addr: usize) bool {
    for (ranges) |range| {
        if (range.contains(addr)) return true;
    }
    return false;
}

pub const ThreadFreezeGuard = struct {
    allocator: std.mem.Allocator,
    handles: std.ArrayList(win.HANDLE),
    /// The first `frozen` handles are the threads to suspend, the rest just get closed.
    frozen: usize = 0,
    suspended: bool = false,

    /// Resumes them all before closing any. Closing can be hooked and need a lock a frozen thread holds.
    pub fn deinit(self: *ThreadFreezeGuard) void {
        if (self.suspended) for (self.handles.items[0..self.frozen]) |h| {
            _ = win.ResumeThread(h);
        };
        for (self.handles.items) |h| win.CloseHandle(h);
        self.handles.deinit(self.allocator);
    }

    pub fn count(self: *const ThreadFreezeGuard) usize {
        return self.frozen;
    }
};

const tests = struct {
    fn dummyTargetFunction(x: u32) callconv(.c) u32 {
        return x + 42;
    }

    test "freeze and resume" {
        const WorkerCtx = struct {
            ready: std.atomic.Value(bool) = .init(false),
            stop: std.atomic.Value(bool) = .init(false),
            ticks: std.atomic.Value(u32) = .init(0),
        };

        var ctx = WorkerCtx{};
        const thread = try std.Thread.spawn(.{}, struct {
            fn run(c: *WorkerCtx) void {
                c.ready.store(true, .release);
                while (!c.stop.load(.acquire)) {
                    _ = c.ticks.fetchAdd(1, .monotonic);
                    std.atomic.spinLoopHint();
                }
            }
        }.run, .{&ctx});
        defer {
            ctx.stop.store(true, .release);
            thread.join();
        }

        while (!ctx.ready.load(.acquire)) std.atomic.spinLoopHint();

        // Guard an unrelated address so there's no collision
        const dummy_guard = @intFromPtr(&dummyTargetFunction);
        {
            var guard = try freezeThreads(std.testing.allocator, .{ .executing = &.{.{ .start = dummy_guard, .len = 16 }} });
            defer guard.deinit();

            try std.testing.expect(guard.count() >= 1);

            // Worker is frozen while we hold the guard
            const snapshot_a = ctx.ticks.load(.monotonic);
            try std.testing.io.sleep(.fromMilliseconds(2), .awake);
            const snapshot_b = ctx.ticks.load(.monotonic);
            try std.testing.expectEqual(snapshot_a, snapshot_b);
        }

        // Runs again after deinit, which might take a bit
        const after_resume = ctx.ticks.load(.monotonic);
        try eventually(struct {
            fn resumed(c: *const @TypeOf(ctx), before: u64) bool {
                return c.ticks.load(.monotonic) != before;
            }
        }.resumed, .{ &ctx, after_resume });
    }

    /// Up to two seconds, since a busy machine can be slow.
    fn eventually(check: anytype, args: anytype) !void {
        for (0..2000) |_| {
            if (@call(.auto, check, args)) return;
            try std.testing.io.sleep(.fromMilliseconds(1), .awake);
        }
        return error.TimedOut;
    }

    /// Retries for up to two seconds.
    fn expectCollision(options: Avoid) !void {
        for (0..2000) |_| {
            if (freezeThreads(std.testing.allocator, options)) |guard_value| {
                var guard = guard_value;
                guard.deinit();
            } else |err| {
                if (err == error.ThreadCollision) return;
                return err;
            }
            try std.testing.io.sleep(.fromMilliseconds(1), .awake);
        }
        return error.TestExpectedError;
    }

    test "grows room for more threads" {
        const Idle = struct {
            fn run(stop: *std.atomic.Value(bool)) void {
                while (!stop.load(.acquire)) win.Sleep(1);
            }
        };
        var stop: std.atomic.Value(bool) = .init(false);
        var threads: [40]std.Thread = undefined;
        for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Idle.run, .{&stop});
        defer {
            stop.store(true, .release);
            for (threads) |t| t.join();
        }

        last_thread_count.store(0, .monotonic);
        var guard = try freezeThreads(std.testing.allocator, .{});
        defer guard.deinit();
        try std.testing.expect(guard.count() >= threads.len);
        try std.testing.expectEqual(guard.count(), last_thread_count.load(.monotonic));
    }

    test "keeps threads it's told to" {
        const Spinner = struct {
            ticks: std.atomic.Value(u32) = .init(0),
            stop: std.atomic.Value(bool) = .init(false),
            id: std.atomic.Value(u32) = .init(0),

            fn run(self: *@This()) void {
                self.id.store(std.Thread.getCurrentId(), .release);
                while (!self.stop.load(.acquire)) _ = self.ticks.fetchAdd(1, .monotonic);
            }

            fn keep(ctx: ?*anyopaque, info: sys.thread.Info) bool {
                const self: *@This() = @ptrCast(@alignCast(ctx.?));
                return info.id == self.id.load(.acquire) and info.start != 0;
            }
        };
        var spinner: Spinner = .{};
        const thread = try std.Thread.spawn(.{}, Spinner.run, .{&spinner});
        defer {
            spinner.stop.store(true, .release);
            thread.join();
        }
        while (spinner.id.load(.acquire) == 0) std.atomic.spinLoopHint();

        var guard = try freezeThreads(std.testing.allocator, .{ .keep = .{ .ctx = &spinner, .func = Spinner.keep }, .loader_lock = true });
        defer guard.deinit();
        const before = spinner.ticks.load(.monotonic);
        try eventually(struct {
            fn moved(s: *const Spinner, b: u32) bool {
                return s.ticks.load(.monotonic) != b;
            }
        }.moved, .{ &spinner, before });
    }

    test "keep filters run before suspending" {
        const Spinner = struct {
            id: std.atomic.Value(u32) = .init(0),
            ticks: std.atomic.Value(u32) = .init(0),
            stop: std.atomic.Value(bool) = .init(false),

            fn run(self: *@This()) void {
                self.id.store(std.Thread.getCurrentId(), .release);
                while (!self.stop.load(.acquire)) _ = self.ticks.fetchAdd(1, .monotonic);
            }
        };
        const Filter = struct {
            workers: *[2]Spinner,
            checked: u32 = 0,
            stalled: bool = false,

            fn keep(ctx: ?*anyopaque, info: sys.thread.Info) bool {
                const self: *@This() = @ptrCast(@alignCast(ctx.?));
                if (info.id != self.workers[0].id.load(.acquire) and info.id != self.workers[1].id.load(.acquire)) return true;
                self.checked += 1;
                const a = self.workers[0].ticks.load(.acquire);
                const b = self.workers[1].ticks.load(.acquire);
                for (0..100) |_| {
                    if (self.workers[0].ticks.load(.acquire) != a and self.workers[1].ticks.load(.acquire) != b) return false;
                    win.Sleep(1);
                }
                self.stalled = true;
                return false;
            }
        };
        var workers: [2]Spinner = .{ .{}, .{} };
        const first = try std.Thread.spawn(.{}, Spinner.run, .{&workers[0]});
        defer {
            workers[0].stop.store(true, .release);
            first.join();
        }
        const second = try std.Thread.spawn(.{}, Spinner.run, .{&workers[1]});
        defer {
            workers[1].stop.store(true, .release);
            second.join();
        }
        while (workers[0].id.load(.acquire) == 0 or workers[1].id.load(.acquire) == 0) win.Sleep(1);

        var filter: Filter = .{ .workers = &workers };
        var guard = try freezeThreads(std.testing.allocator, .{ .keep = .{ .ctx = &filter, .func = Filter.keep } });
        guard.deinit();
        try std.testing.expectEqual(2, filter.checked);
        try std.testing.expect(!filter.stalled);
    }

    test "collision in executing range" {
        // `jmp $` spins in this page until we patch it to `ret`
        const page = try memory.allocAny(64);
        defer memory.free(page);
        page[0..2].* = .{ 0xEB, 0xFE };

        const spin: *const fn () callconv(.c) void = @ptrCast(page.ptr);
        const thread = try std.Thread.spawn(.{}, struct {
            fn run(f: *const fn () callconv(.c) void) void {
                f();
            }
        }.run, .{spin});
        defer {
            page[0] = 0xC3;
            thread.join();
        }
        const range = CodeRange{ .start = @intFromPtr(page.ptr), .len = page.len };
        try expectCollision(.{ .executing = &.{range} });

        // An unrelated range still freezes fine
        var guard = try freezeThreads(std.testing.allocator, .{ .executing = &.{.{ .start = @intFromPtr(&dummyTargetFunction), .len = 16 }} });
        guard.deinit();
    }

    /// Keeps `p` in a callee-saved register until `stop`.
    fn holdInRegister(p: usize, stop: *const bool) void {
        switch (builtin.cpu.arch) {
            .x86_64 => asm volatile (
                \\.intel_syntax noprefix
                \\1:
                \\  pause
                \\  cmp byte ptr [%[stop:V]], 0
                \\  je 1b
                \\.att_syntax prefix
                :
                : [ptr] "{r12}" (p),
                  [stop] "r" (stop),
                : .{ .memory = true }),
            .x86 => asm volatile (
                \\.intel_syntax noprefix
                \\1:
                \\  pause
                \\  cmp byte ptr [%[stop:V]], 0
                \\  je 1b
                \\.att_syntax prefix
                :
                : [ptr] "{esi}" (p),
                  [stop] "r" (stop),
                : .{ .memory = true }),
            else => unreachable,
        }
    }

    test "collision on referenced pointer" {
        var target: [64]u8 = undefined;
        const range = CodeRange{ .start = @intFromPtr(&target), .len = target.len };
        var stop = std.atomic.Value(bool).init(false);
        var ready = std.atomic.Value(bool).init(false);

        const thread = try std.Thread.spawn(.{}, struct {
            fn run(p: usize, s: *std.atomic.Value(bool), r: *std.atomic.Value(bool)) void {
                r.store(true, .release);
                holdInRegister(p, &s.raw);
            }
        }.run, .{ range.start + 8, &stop, &ready });
        defer {
            stop.store(true, .release);
            thread.join();
        }
        while (!ready.load(.acquire)) std.atomic.spinLoopHint();
        try expectCollision(.{ .referenced = &.{range} });
        // `executing` alone doesn't check registers
        var guard = try freezeThreads(std.testing.allocator, .{ .executing = &.{range} });
        guard.deinit();
    }
};

test {
    _ = tests;
}

test "current stack holds locals" {
    var local: u32 = 7;
    const stack = currentStack();
    try std.testing.expect(stack.contains(@intFromPtr(&local)));
    std.mem.doNotOptimizeAway(&local);
}
