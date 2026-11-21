//! Keeps the game thinking it's active while one of our windows is, so it doesn't pause.

const Focus = @This();

const std = @import("std");

const hook = @import("tuft_hook");
const tuft_event = @import("tuft_event");
const tuft_window = @import("tuft_window");

const Window = @import("Window.zig");
const Blocker = @import("Blocker.zig");
const win = @import("tuft_sys").win;

const log = std.log.scoped(.tuft_input);

/// Any thread.
pub const Owns = struct {
    ctx: ?*anyopaque,
    func: *const fn (ctx: ?*anyopaque, window: tuft_window.Handle) bool,

    fn has(self: Owns, window: ?tuft_window.Handle) bool {
        return self.func(self.ctx, window orelse return false);
    }
};

const WindowFn = fn () callconv(.winapi) ?win.HWND;

const WM_ACTIVATE: u32 = 0x0006;
const WM_KILLFOCUS: u32 = 0x0008;
const WM_ACTIVATEAPP: u32 = 0x001C;
const WM_NCACTIVATE: u32 = 0x0086;
const WA_INACTIVE: usize = 0;

allocator: std.mem.Allocator,
window: *Window,
owns: Owns,
subscriptions: tuft_event.Scope,
/// Going by the messages we let through.
game_active: std.atomic.Value(bool) = .init(true),
get_foreground_window: ?*hook.TypedHook(WindowFn) = null,
get_active_window: ?*hook.TypedHook(WindowFn) = null,
get_focus: ?*hook.TypedHook(WindowFn) = null,

pub fn create(allocator: std.mem.Allocator, window: *Window, owns: Owns) !*Focus {
    const self = try allocator.create(Focus);
    errdefer allocator.destroy(self);
    self.* = .{ .allocator = allocator, .window = window, .owns = owns, .subscriptions = .init(allocator) };
    errdefer self.subscriptions.deinit();
    try window.message.subscribeOpts(&self.subscriptions, self, onMessage, .{ .priority = Window.Priority.focus });

    const user32 = try hook.memory.Module.find("user32.dll");
    self.get_foreground_window = self.hookExport(user32, "GetForegroundWindow", getForegroundWindow);
    self.get_active_window = self.hookExport(user32, "GetActiveWindow", getActiveWindow);
    self.get_focus = self.hookExport(user32, "GetFocus", getFocus);
    return self;
}

/// Waits for calls in flight.
pub fn destroy(self: *Focus) void {
    self.subscriptions.deinit();
    inline for (.{ "get_foreground_window", "get_active_window", "get_focus" }) |name| {
        if (@field(self, name)) |h| h.destroy();
    }
    self.allocator.destroy(self);
}

/// Call on our window's `WM_ACTIVATE` to wake a game that lost focus to another program.
/// Only sends `WM_ACTIVATEAPP` since `WM_ACTIVATE` would steal keyboard focus from ours.
pub fn ourWindowActivated(self: *Focus) void {
    const game = self.window.handle() orelse return;
    if (self.game_active.load(.acquire)) return;
    _ = tuft_window.post(game, WM_ACTIVATEAPP, 1, 0);
}

/// The real foreground window, not what our hook tells the game.
fn foreground(self: *const Focus) ?win.HWND {
    if (self.get_foreground_window) |h| return h.original()();
    return win.GetForegroundWindow();
}

fn onMessage(self: *Focus, m: *const Window.Message) ?isize {
    const raw = m.raw;
    switch (raw.msg) {
        WM_ACTIVATEAPP => {
            if (raw.wparam == 0 and self.owns.has(self.foreground())) return 0;
            self.game_active.store(raw.wparam != 0, .release);
        },
        // lParam is the window being activated
        WM_ACTIVATE => if (raw.wparam & 0xFFFF == WA_INACTIVE and self.owns.has(@ptrFromInt(@as(usize, @bitCast(raw.lparam))))) return 0,
        // True lets the deactivation happen, but the game doesn't repaint as inactive
        WM_NCACTIVATE => if (raw.wparam == 0 and self.owns.has(self.foreground())) return 1,
        // wParam is the window getting the focus
        WM_KILLFOCUS => if (self.owns.has(@ptrFromInt(raw.wparam))) return 0,
        else => {},
    }
    return null;
}

fn mapped(self: *Focus, real: ?win.HWND) ?win.HWND {
    if (Blocker.isBypassing() or !self.owns.has(real)) return real;
    // A window's own thread, like a file dialog's, gets the truth. Only the game's lied to
    if (tuft_window.threadOf(real.?) == win.GetCurrentThreadId()) return real;
    return self.window.handle() orelse real;
}

fn getForegroundWindow(self: *Focus, h: *hook.TypedHook(WindowFn)) ?win.HWND {
    return self.mapped(h.original()());
}

fn getActiveWindow(self: *Focus, h: *hook.TypedHook(WindowFn)) ?win.HWND {
    return self.mapped(h.original()());
}

fn getFocus(self: *Focus, h: *hook.TypedHook(WindowFn)) ?win.HWND {
    return self.mapped(h.original()());
}

fn hookExport(self: *Focus, module: hook.memory.Module, comptime name: [:0]const u8, comptime callback: anytype) ?*hook.TypedHook(WindowFn) {
    const h = module.symbol(name).createFn(WindowFn, callback, self) catch |err| {
        log.warn("Can't keep {s} on the game: {t}", .{ name, err });
        return null;
    };
    h.enable() catch |err| {
        log.warn("Can't keep {s} on the game: {t}", .{ name, err });
        h.destroy();
        return null;
    };
    return h;
}

const tests = struct {
    const testing = std.testing;
    const Rig = @import("testing.zig");

    const Ours = struct {
        var window: ?tuft_window.Handle = null;
        fn owns(_: ?*anyopaque, w: tuft_window.Handle) bool {
            return w == window;
        }
    };

    test "hides focus loss to ours" {
        var rig: Rig = undefined;
        try rig.init();
        defer rig.deinit();
        const ours = try tuft_window.createHidden();
        defer tuft_window.destroy(ours);
        const other = try tuft_window.createHidden();
        defer tuft_window.destroy(other);
        Ours.window = ours;
        const focus = try Focus.create(testing.allocator, rig.window, .{ .ctx = null, .func = Ours.owns });
        defer focus.destroy();

        _ = rig.send(WM_ACTIVATE, WA_INACTIVE, @bitCast(@intFromPtr(ours)));
        _ = rig.send(WM_KILLFOCUS, @intFromPtr(ours), 0);
        try testing.expectEqual(0, Rig.game.count(WM_ACTIVATE));
        try testing.expectEqual(0, Rig.game.count(WM_KILLFOCUS));

        _ = rig.send(WM_ACTIVATE, WA_INACTIVE, @bitCast(@intFromPtr(other)));
        _ = rig.send(WM_KILLFOCUS, @intFromPtr(other), 0);
        try testing.expectEqual(1, Rig.game.count(WM_ACTIVATE));
        try testing.expectEqual(1, Rig.game.count(WM_KILLFOCUS));
    }

    test "polling sees game window" {
        var rig: Rig = undefined;
        try rig.init();
        defer rig.deinit();
        // On a thread of its own, like an app window or a file dialog
        var other: OtherThread = .{};
        try other.start();
        defer other.stop();
        const ours = other.hwnd.?;
        Ours.window = ours;
        const focus = try Focus.create(testing.allocator, rig.window, .{ .ctx = null, .func = Ours.owns });
        defer focus.destroy();

        try testing.expectEqual(@as(?win.HWND, rig.hwnd), focus.mapped(ours));
        try testing.expectEqual(@as(?win.HWND, null), focus.mapped(null));
        {
            const bypass = Blocker.Bypass.begin();
            defer bypass.end();
            try testing.expectEqual(@as(?win.HWND, ours), focus.mapped(ours));
        }

        // Its own thread gets the truth, or a dialog would go looking at the game's window
        const mine = try tuft_window.createHidden();
        defer tuft_window.destroy(mine);
        Ours.window = mine;
        try testing.expectEqual(@as(?win.HWND, mine), focus.mapped(mine));
    }

    /// A hidden window made and kept on another thread.
    const OtherThread = struct {
        hwnd: ?win.HWND = null,
        done: @import("tuft_arch").atomic.Value(bool) = .init(false),
        made: @import("tuft_arch").atomic.Value(bool) = .init(false),
        thread: ?std.Thread = null,

        fn start(self: *OtherThread) !void {
            self.thread = try std.Thread.spawn(.{}, run, .{self});
            while (!self.made.load(.acquire)) std.Thread.yield() catch {};
            if (self.hwnd == null) return error.CreateWindowFailed;
        }

        fn stop(self: *OtherThread) void {
            self.done.store(true, .release);
            self.thread.?.join();
        }

        fn run(self: *OtherThread) void {
            self.hwnd = tuft_window.createHidden() catch null;
            self.made.store(true, .release);
            while (!self.done.load(.acquire)) {
                tuft_window.pump();
                std.Thread.yield() catch {};
            }
            if (self.hwnd) |h| tuft_window.destroy(h);
        }
    };

    test "wakes inactive game" {
        var rig: Rig = undefined;
        try rig.init();
        defer rig.deinit();
        Ours.window = null;
        const focus = try Focus.create(testing.allocator, rig.window, .{ .ctx = null, .func = Ours.owns });
        defer focus.destroy();

        focus.ourWindowActivated();
        tuft_window.pump();
        try testing.expectEqual(0, Rig.game.count(WM_ACTIVATEAPP));

        _ = rig.send(WM_ACTIVATEAPP, 0, 0); // another program took the focus
        try testing.expectEqual(1, Rig.game.count(WM_ACTIVATEAPP));
        focus.ourWindowActivated();
        tuft_window.pump();
        try testing.expectEqual(2, Rig.game.count(WM_ACTIVATEAPP));
        try testing.expectEqual(1, Rig.game.lastWparam(WM_ACTIVATEAPP));
        try testing.expect(focus.game_active.load(.acquire));
    }
};

test {
    _ = tests;
}
