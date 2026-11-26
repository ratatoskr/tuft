//! Subclasses the game window so we can see and eat its messages.

const Window = @This();

const std = @import("std");

const tuft_event = @import("tuft_event");
const tuft_window = @import("tuft_window");

const Blocker = @import("Blocker.zig");

const log = std.log.scoped(.tuft_input);

pub const Message = struct {
    /// Subscribers can change `wparam` and `lparam` for everyone after. `event` describes the original.
    raw: *tuft_window.Message,
    event: ?@import("root.zig").Event,
    /// Set even for messages with no `event`.
    channel: ?@import("root.zig").Channel,
};
pub const MessageEvent = tuft_event.Event(fn (*const Message) ?isize);

/// Highest runs first. Plugins at 0 only see what's left after input is hidden.
pub const Priority = struct {
    pub const keybinds = 1100;
    pub const overlay = 1000;
    pub const focus = 950;
    pub const hide = 900;
    pub const observe = std.math.minInt(i32);
};

allocator: std.mem.Allocator,
message: MessageEvent,
tasks: tuft_event.TaskQueue = .{},
subclass: ?*tuft_window.Subclass = null,
/// Any thread.
window: std.atomic.Value(?tuft_window.Handle) = .init(null),
/// Window thread only.
translator: @import("root.zig").Translator = .{},
install_failed: bool = false,
/// A task was still running when they closed, so it's never freed.
tasks_stuck: bool = false,
wake_message: u32,
io: std.Io,

/// Doesn't watch any window until `attach`.
pub fn create(allocator: std.mem.Allocator, io: std.Io) !*Window {
    const self = try allocator.create(Window);
    errdefer allocator.destroy(self);
    self.* = .{
        .allocator = allocator,
        .io = io,
        .message = .init(allocator),
        .wake_message = try tuft_window.registerMessage("tuft.input.window.tasks"),
    };
    errdefer self.message.deinit();
    self.tasks.wake = .{ .ctx = self, .func = wake };
    return self;
}

/// Drops pending tasks; `message` subscribers must be gone first. Leaks itself if a task or handler still runs after the waits.
pub fn destroy(self: *Window) void {
    self.closeTasks();
    const unhooked = if (self.subclass) |s| s.uninstall() else true;
    if (!unhooked or self.tasks_stuck) return;
    self.message.deinit();
    self.allocator.destroy(self);
}

/// Drops pending tasks and waits for running ones.
pub fn closeTasks(self: *Window) void {
    if (!self.tasks.closeAndWait(self.io, .fromMilliseconds(close_timeout_ms))) {
        self.tasks_stuck = true;
        log.err("Window tasks still running after {}ms", .{close_timeout_ms});
    }
}

const close_timeout_ms = 2000;

pub fn handle(self: *const Window) ?tuft_window.Handle {
    return self.window.load(.acquire);
}

/// Skips `message` subscribers.
pub fn callOriginal(self: *const Window, msg: u32, wparam: usize, lparam: isize) isize {
    const s = self.subclass orelse return 0;
    return s.callOriginal(msg, wparam, lparam);
}

/// Any thread. Only the first call does anything.
pub fn attach(self: *Window, window: tuft_window.Handle) void {
    if (self.subclass != null or self.install_failed) return;
    self.subclass = tuft_window.Subclass.install(self.allocator, window, .{ .ctx = self, .func = onMessage }) catch |err| {
        log.err("Couldn't subclass window 0x{x}: {t}", .{ @intFromPtr(window), err });
        self.install_failed = true;
        return;
    };
    self.tasks.setThread(tuft_window.threadOf(window));
    self.window.store(window, .release);
    // Run tasks posted before we knew the window
    _ = tuft_window.post(window, self.wake_message, 0, 0);
}

fn wake(ctx: *anyopaque) void {
    const self: *Window = @ptrCast(@alignCast(ctx));
    const window = self.window.load(.acquire) orelse {
        // Don't know it yet. The next post or attach retries
        self.tasks.wake_pending.store(false, .release);
        return;
    };
    if (!tuft_window.post(window, self.wake_message, 0, 0)) self.tasks.wake_pending.store(false, .release);
}

fn onMessage(ctx: *anyopaque, raw: *const tuft_window.Message) ?isize {
    const self: *Window = @ptrCast(@alignCast(ctx));
    if (raw.msg == self.wake_message) {
        self.tasks.runPending();
        return 0;
    }
    const event = blk: {
        // Translating reads modifier state, which is hidden while the keyboard is captured
        const bypass = Blocker.Bypass.begin();
        defer bypass.end();
        break :blk self.translator.translate(raw);
    };
    var passed_on = raw.*;
    const message: Message = .{ .raw = &passed_on, .event = event, .channel = @import("root.zig").channelOf(raw) };
    if (self.message.fire(.{&message})) |result| return result;
    // Someone changed it, so the game gets the changed version
    if (passed_on.wparam != raw.wparam or passed_on.lparam != raw.lparam) return self.callOriginal(passed_on.msg, passed_on.wparam, passed_on.lparam);
    return null;
}

const tests = struct {
    const testing = std.testing;
    const hook = @import("tuft_hook");

    const MSG_CONSUMED = 0x0400 + 1;
    const MSG_OTHER = 0x0400 + 2;

    const Listener = struct {
        seen: u32 = 0,

        fn onMessage(self: *Listener, m: *const Message) ?isize {
            self.seen += 1;
            return if (m.raw.msg == MSG_CONSUMED) 42 else null;
        }
    };

    test "subclass and consume" {
        try hook.init(testing.allocator);
        defer hook.deinit();
        const hwnd = try tuft_window.createHidden();
        defer tuft_window.destroy(hwnd);

        const window = try Window.create(testing.allocator, testing.io);
        var scope = tuft_event.Scope.init(testing.allocator);
        var listener: Listener = .{};
        try window.message.subscribe(&scope, &listener, Listener.onMessage);

        try testing.expectEqual(null, window.handle());
        window.attach(hwnd);
        try testing.expectEqual(@as(?tuft_window.Handle, hwnd), window.handle());

        try testing.expectEqual(42, tuft_window.send(hwnd, MSG_CONSUMED, 0, 0));
        try testing.expectEqual(0, tuft_window.send(hwnd, MSG_OTHER, 0, 0));
        try testing.expectEqual(2, listener.seen);
        try testing.expectEqual(0, window.callOriginal(MSG_CONSUMED, 0, 0)); // bypasses subscribers
        try testing.expectEqual(2, listener.seen);

        scope.deinit();
        window.destroy();
        try testing.expectEqual(0, tuft_window.send(hwnd, MSG_CONSUMED, 0, 0));
        try testing.expectEqual(2, listener.seen);
    }

    test "tasks run on window thread" {
        try hook.init(testing.allocator);
        defer hook.deinit();
        const hwnd = try tuft_window.createHidden();
        defer tuft_window.destroy(hwnd);
        const window = try Window.create(testing.allocator, testing.io);
        defer window.destroy();

        const Task = struct {
            ran_on: ?std.Thread.Id = null,

            fn run(self: *@This()) void {
                self.ran_on = std.Thread.getCurrentId();
            }
        };
        var early: Task = .{};
        var late: Task = .{};
        try window.tasks.post(&early, Task.run); // before the window is known

        window.attach(hwnd);
        const poster = try std.Thread.spawn(.{}, struct {
            fn post(w: *Window, t: *Task) void {
                w.tasks.post(t, Task.run) catch unreachable;
            }
        }.post, .{ window, &late });
        poster.join();
        try testing.expectEqual(null, late.ran_on);

        tuft_window.pump();
        try testing.expectEqual(std.Thread.getCurrentId(), early.ran_on.?);
        try testing.expectEqual(std.Thread.getCurrentId(), late.ran_on.?);
    }
};

test {
    _ = tests;
}
