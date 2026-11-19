//! Lets our text boxes use the IME in games that switch it off, and puts its windows at the caret.
//! While we've switched it on, the game's own `ImmAssociateContext` calls wait till we let go, like
//! `ClipCursor` does while the mouse is ours.

const Ime = @This();

const std = @import("std");

const hook = @import("tuft_hook");
const sys = @import("tuft_sys");
const win = sys.win;
const tuft_window = @import("tuft_window");

const Window = @import("../Window.zig");
const SpinLock = @import("blocker.zig").SpinLock;

const log = std.log.scoped(.tuft_input);

const AssociateFn = fn (hwnd: win.HWND, himc: ?win.HIMC) callconv(.winapi) ?win.HIMC;
const AssociateExFn = fn (hwnd: win.HWND, himc: ?win.HIMC, flags: u32) callconv(.winapi) win.BOOL;

/// The caret, in client coords of the window it's in.
pub const Placement = struct {
    x: i32,
    y: i32,
    line_height: i32,
};

/// What the game asked for while we held it.
const Request = union(enum) {
    context: ?win.HIMC,
    ex: struct { himc: ?win.HIMC, flags: u32 },
};

allocator: std.mem.Allocator,
window: *Window,
/// Any thread writes, the window thread applies.
lock: SpinLock = .{},
typing: bool = false,
placement: ?Placement = null,
queued: std.atomic.Value(bool) = .init(false),
/// We switched the game's IME on. Read by the hooks on any thread.
holding: std.atomic.Value(bool) = .init(false),
/// Under `lock`.
game_request: ?Request = null,
associate: ?*hook.TypedHook(AssociateFn) = null,
associate_ex: ?*hook.TypedHook(AssociateExFn) = null,
imm_wait: ?*sys.module.WhenLoaded = null,

pub fn create(allocator: std.mem.Allocator, window: *Window) !*Ime {
    const self = try allocator.create(Ime);
    self.* = .{ .allocator = allocator, .window = window };
    self.imm_wait = sys.module.WhenLoaded.create(allocator, "imm32.dll", .{ .ctx = self, .ready = hookImm }) catch |err| blk: {
        log.warn("Can't watch for imm32 loading: {t}", .{err});
        break :blk null;
    };
    return self;
}

/// Gives the game its IME back. Best done with `setTyping(false)` a frame before, since this
/// may not be on the window's thread and Windows may refuse. Waits a bit for a queued update, and
/// leaks itself if that never runs rather than leave it pointing at freed memory.
pub fn destroy(self: *Ime) void {
    if (self.imm_wait) |w| w.destroy();
    if (self.queued.load(.acquire)) {
        if (self.window.tasks.isCurrent()) {
            self.apply();
        } else {
            var waited: u32 = 0;
            while (self.queued.load(.acquire) and waited < destroy_wait_ms) : (waited += 1) win.Sleep(1);
        }
    }
    if (self.holding.load(.acquire)) self.letGo();
    if (self.associate) |h| h.destroy();
    if (self.associate_ex) |h| h.destroy();
    if (self.queued.load(.acquire)) return log.warn("IME update still queued at shutdown, leaving it", .{});
    self.allocator.destroy(self);
}

const destroy_wait_ms = 500;

/// On while one of our text boxes takes text. Any thread.
pub fn setTyping(self: *Ime, on: bool) void {
    {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.typing == on) return;
        self.typing = on;
    }
    self.queue();
}

/// Where the caret is in the game's window. Any thread.
pub fn place(self: *Ime, placement: Placement) void {
    {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.placement) |p| if (std.meta.eql(p, placement)) return;
        self.placement = placement;
    }
    self.queue();
}

fn queue(self: *Ime) void {
    if (self.queued.swap(true, .acq_rel)) return;
    self.window.tasks.post(self, apply) catch |err| {
        self.queued.store(false, .release);
        log.warn("Couldn't reach the game's window for the IME: {t}", .{err});
    };
}

/// Window thread.
fn apply(self: *Ime) void {
    self.queued.store(false, .release);
    const hwnd = self.window.handle() orelse return;
    const typing, const placement = blk: {
        self.lock.lock();
        defer self.lock.unlock();
        const p = self.placement;
        self.placement = null;
        break :blk .{ self.typing, p };
    };
    if (typing and !self.holding.load(.acquire)) {
        if (win.ImmGetContext(hwnd)) |himc| {
            // It's on already
            _ = win.ImmReleaseContext(hwnd, himc);
        } else {
            _ = self.associateEx(hwnd, null, win.IACE_DEFAULT);
            self.lock.lock();
            self.game_request = null;
            self.lock.unlock();
            self.holding.store(true, .release);
        }
    } else if (!typing and self.holding.load(.acquire)) {
        self.letGo();
    }
    if (typing) if (placement) |p| placeOn(hwnd, p);
}

/// Back to what the game last asked for, which was off when we took it.
fn letGo(self: *Ime) void {
    const hwnd = self.window.handle() orelse return;
    self.holding.store(false, .release);
    const request = blk: {
        self.lock.lock();
        defer self.lock.unlock();
        defer self.game_request = null;
        break :blk self.game_request orelse Request{ .context = null };
    };
    switch (request) {
        .context => |himc| _ = self.associateContext(hwnd, himc),
        .ex => |r| _ = self.associateEx(hwnd, r.himc, r.flags),
    }
}

/// Puts the composition and candidate windows at the caret. On the thread that made `hwnd`, since
/// IMM won't do it from any other.
pub fn placeOn(hwnd: win.HWND, p: Placement) void {
    const himc = win.ImmGetContext(hwnd) orelse return;
    defer _ = win.ImmReleaseContext(hwnd, himc);
    _ = win.ImmSetCompositionWindow(himc, &.{ .dwStyle = win.CFS_FORCE_POSITION, .ptCurrentPos = .{ .x = p.x, .y = p.y } });
    // Below the line, not over it
    _ = win.ImmSetCandidateWindow(himc, &.{
        .dwStyle = win.CFS_EXCLUDE,
        .ptCurrentPos = .{ .x = p.x, .y = p.y },
        .rcArea = .{ .left = p.x, .top = p.y, .right = p.x, .bottom = p.y + p.line_height },
    });
}

fn associateContext(self: *Ime, hwnd: win.HWND, himc: ?win.HIMC) ?win.HIMC {
    if (self.associate) |h| return h.original()(hwnd, himc);
    return win.ImmAssociateContext(hwnd, himc);
}

fn associateEx(self: *Ime, hwnd: win.HWND, himc: ?win.HIMC, flags: u32) win.BOOL {
    if (self.associate_ex) |h| return h.original()(hwnd, himc, flags);
    return win.ImmAssociateContextEx(hwnd, himc, flags);
}

fn isHeld(self: *const Ime, hwnd: win.HWND) bool {
    return self.holding.load(.acquire) and self.window.handle() == hwnd;
}

fn hookImm(ctx: ?*anyopaque, base: usize) void {
    const self: *Ime = @ptrCast(@alignCast(ctx.?));
    self.associate = hookAt(AssociateFn, self, sys.module.findExport(base, "ImmAssociateContext"), onAssociate);
    self.associate_ex = hookAt(AssociateExFn, self, sys.module.findExport(base, "ImmAssociateContextEx"), onAssociateEx);
}

fn hookAt(comptime T: type, self: *Ime, address: ?usize, comptime callback: anytype) ?*hook.TypedHook(T) {
    const h = hook.memory.Address.at(address orelse return null).createFn(T, callback, self) catch |err| {
        log.warn("Can't keep the IME on for the overlay: {t}", .{err});
        return null;
    };
    h.enable() catch |err| {
        log.warn("Can't keep the IME on for the overlay: {t}", .{err});
        h.destroy();
        return null;
    };
    return h;
}

/// Says the game had what it last asked for, which is nothing if it hasn't asked since we took it.
fn onAssociate(self: *Ime, h: *hook.TypedHook(AssociateFn), hwnd: win.HWND, himc: ?win.HIMC) ?win.HIMC {
    if (!self.isHeld(hwnd)) return h.original()(hwnd, himc);
    self.lock.lock();
    defer self.lock.unlock();
    const was: ?win.HIMC = if (self.game_request) |r| switch (r) {
        .context => |c| c,
        .ex => |e| e.himc,
    } else null;
    self.game_request = .{ .context = himc };
    return was;
}

fn onAssociateEx(self: *Ime, h: *hook.TypedHook(AssociateExFn), hwnd: win.HWND, himc: ?win.HIMC, flags: u32) win.BOOL {
    if (!self.isHeld(hwnd)) return h.original()(hwnd, himc, flags);
    self.lock.lock();
    defer self.lock.unlock();
    self.game_request = .{ .ex = .{ .himc = himc, .flags = flags } };
    return .TRUE;
}

const tests = struct {
    const testing = std.testing;
    const Rig = @import("../testing.zig");

    fn context(hwnd: win.HWND) ?win.HIMC {
        const himc = win.ImmGetContext(hwnd) orelse return null;
        _ = win.ImmReleaseContext(hwnd, himc);
        return himc;
    }

    test "switched back on for us, and the game's choice waits" {
        var rig: Rig = undefined;
        try rig.init();
        defer rig.deinit();
        const ime = try Ime.create(testing.allocator, rig.window);
        defer ime.destroy();
        const default = context(rig.hwnd) orelse return error.SkipZigTest; // no IMM here

        // The game switches it off for its window
        _ = win.ImmAssociateContext(rig.hwnd, null);
        try testing.expectEqual(null, context(rig.hwnd));

        ime.setTyping(true);
        ime.place(.{ .x = 10, .y = 20, .line_height = 16 });
        tuft_window.pump();
        try testing.expect(context(rig.hwnd) != null);

        // It tries again meanwhile, and thinks it worked
        try testing.expectEqual(null, win.ImmAssociateContext(rig.hwnd, null));
        try testing.expect(context(rig.hwnd) != null);

        ime.setTyping(false);
        tuft_window.pump();
        try testing.expectEqual(null, context(rig.hwnd));

        // With it on already, there's nothing to hold
        _ = win.ImmAssociateContext(rig.hwnd, default);
        ime.setTyping(true);
        tuft_window.pump();
        try testing.expect(!ime.holding.load(.acquire));
        ime.setTyping(false);
        tuft_window.pump();
        try testing.expectEqual(default, context(rig.hwnd).?);
    }
};

test {
    _ = tests;
}
