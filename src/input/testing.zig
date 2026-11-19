//! Test rig with a hidden fake game window.

const Rig = @This();

const std = @import("std");
const testing = std.testing;

const hook = @import("tuft_hook");
const tuft_event = @import("tuft_event");
const tuft_window = @import("tuft_window");

const Window = @import("Window.zig");
const Blocker = @import("Blocker.zig");
const Keybinds = @import("Keybinds.zig");
const win = @import("tuft_sys").win;

hwnd: win.HWND,
window: *Window,
blocker: *Blocker,
keybinds: *Keybinds,
/// Disposed first.
scope: tuft_event.Scope,
saved_log: std.log.Level,

pub fn init(self: *Rig) !void {
    self.saved_log = testing.log_level;
    testing.log_level = .err;
    errdefer testing.log_level = self.saved_log;
    try hook.init(testing.allocator);
    errdefer hook.deinit();

    self.hwnd = try tuft_window.createHidden();
    errdefer tuft_window.destroy(self.hwnd);
    game.install(self.hwnd);
    errdefer game.uninstall(self.hwnd);

    self.window = try Window.create(testing.allocator, testing.io);
    errdefer self.window.destroy();
    self.blocker = try Blocker.create(testing.allocator, self.window);
    errdefer {
        self.window.closeTasks();
        self.blocker.destroy();
    }
    self.keybinds = try Keybinds.create(testing.allocator, self.window, self.blocker);
    errdefer self.keybinds.destroy();
    self.scope = .init(testing.allocator);
    self.window.attach(self.hwnd);
}

pub fn deinit(self: *Rig) void {
    self.scope.deinit();
    self.keybinds.destroy();
    self.window.closeTasks();
    self.blocker.destroy();
    self.window.destroy();
    game.uninstall(self.hwnd);
    tuft_window.destroy(self.hwnd);
    hook.deinit();
    testing.log_level = self.saved_log;
}

/// Fakes a frame so keybinds get delivered.
pub fn present(self: *Rig) void {
    self.keybinds.deliver();
}

pub fn send(self: *Rig, msg: u32, wparam: usize, lparam: isize) isize {
    return tuft_window.send(self.hwnd, msg, wparam, lparam);
}

/// Records what reached its window proc.
pub const game = struct {
    var prev: isize = 0;
    var counts: [0x400]u32 = @splat(0);
    var last_wparams: [0x400]usize = @splat(0);

    pub fn count(msg: u32) u32 {
        return counts[msg];
    }

    pub fn lastWparam(msg: u32) usize {
        return last_wparams[msg];
    }

    fn install(window: win.HWND) void {
        counts = @splat(0);
        last_wparams = @splat(0);
        prev = win.SetWindowLongPtrW(window, win.GWLP_WNDPROC, @bitCast(@intFromPtr(&proc)));
    }

    fn uninstall(window: win.HWND) void {
        _ = win.SetWindowLongPtrW(window, win.GWLP_WNDPROC, prev);
    }

    fn proc(window: win.HWND, msg: u32, wparam: usize, lparam: isize) callconv(.winapi) isize {
        if (msg < counts.len) {
            counts[msg] += 1;
            last_wparams[msg] = wparam;
        }
        return win.CallWindowProcW(prev, window, msg, wparam, lparam);
    }
};
