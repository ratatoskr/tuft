//! Window subclassing that's safe to remove even if someone subclassed on top.

const Subclass = @This();

const std = @import("std");

const sys = @import("tuft_sys");
const memory = @import("tuft_mem");
const Atomic = @import("tuft_arch").atomic.Value;
const api_window = @import("../root.zig");

const win = @import("tuft_sys").win;
const stub_ = @import("stub.zig");

const log = std.log.scoped(.tuft_window);

const Handle = api_window.Handle;
const Message = api_window.Message;
const Handler = api_window.Handler;

allocator: std.mem.Allocator,
window: Handle,
handler: Handler,
stub: usize,
/// Sees keys as the window's thread takes them off its queue, for games whose loop doesn't dispatch
/// them, like XNA's on WinForms. Null if it couldn't be hooked.
hook: ?win.HHOOK = null,
/// The last key the hook handed over and let through, so the window proc doesn't hand it over
/// again once it's dispatched. Window thread only.
queued: Queued = .{},

const Queued = struct {
    set: bool = false,
    msg: u32 = 0,
    wparam: usize = 0,
    lparam: isize = 0,
    time: u32 = 0,

    fn matches(q: *const Queued, msg: u32, wparam: usize, lparam: isize) bool {
        return q.set and q.msg == msg and q.wparam == wparam and q.lparam == lparam and
            @as(u32, @bitCast(win.GetMessageTime())) == q.time;
    }
};

const uninstall_timeout_ms = 2000;

/// What the queue hook looks windows up in. Few, since it's one subclass a game window.
var hooked: [8]Atomic(?*Subclass) = @splat(.init(null));
/// Queue hook calls under way, so uninstalling waits for them.
var hook_calls: Atomic(u32) = .init(0);

/// Handler runs on the window's thread.
pub fn install(allocator: std.mem.Allocator, hwnd: Handle, handler: Handler) !*Subclass {
    const user32 = sys.module.findBase("user32.dll") orelse return error.User32NotLoaded;
    const forward = sys.module.findExport(user32, "CallWindowProcW") orelse return error.User32NotLoaded;

    const original = win.GetWindowLongPtrW(hwnd, win.GWLP_WNDPROC);
    if (original == 0) return error.NoWindowProc;

    const self = try allocator.create(Subclass);
    errdefer allocator.destroy(self);

    // Leaked on purpose so the DLL can unload while others still point at the stub
    const page = try memory.pages.allocAny(stubSize());
    const stub = @intFromPtr(page.ptr);
    const template: [*]const u8 = @ptrCast(stub_.template.start);
    @memcpy(page[0..stubSize()], template[0..stubSize()]);

    self.* = .{ .allocator = allocator, .window = hwnd, .handler = handler, .stub = stub };
    slot(stub, .context).* = @intFromPtr(self);
    slot(stub, .original).* = @bitCast(original);
    slot(stub, .forward).* = forward;
    slot(stub, .handler).* = @intFromPtr(&handle);

    const previous = win.SetWindowLongPtrW(hwnd, win.GWLP_WNDPROC, @bitCast(stub));
    if (win.GetWindowLongPtrW(hwnd, win.GWLP_WNDPROC) != @as(isize, @bitCast(stub))) {
        memory.pages.free(page);
        return error.SubclassFailed;
    }
    // Someone subclassed between our read and write, so chain to them
    if (previous != original) @atomicStore(usize, slot(stub, .original), @bitCast(previous), .seq_cst);

    log.debug("Subclassed window 0x{x}", .{@intFromPtr(hwnd)});
    self.hookQueue();
    return self;
}

/// Keys from the window thread's queue, whether or not they're dispatched.
fn hookQueue(self: *Subclass) void {
    const slot_at = for (&hooked) |*h| {
        if (h.cmpxchgStrong(null, self, .acq_rel, .acquire) == null) break h;
    } else return log.debug("No room to hook window 0x{x}'s queue", .{@intFromPtr(self.window)});
    const thread = win.GetWindowThreadProcessId(self.window, null);
    self.hook = win.SetWindowsHookExW(win.WH_GETMESSAGE, &queueHook, null, thread);
    if (self.hook == null) {
        slot_at.store(null, .release);
        log.debug("Couldn't hook window 0x{x}'s queue, so keys it doesn't dispatch go unseen", .{@intFromPtr(self.window)});
    }
}

fn unhookQueue(self: *Subclass) bool {
    for (&hooked) |*h| _ = h.cmpxchgStrong(self, null, .acq_rel, .acquire);
    if (self.hook) |h| _ = win.UnhookWindowsHookEx(h);
    self.hook = null;
    var waited: u32 = 0;
    while (hook_calls.load(.seq_cst) != 0) : (waited += 1) {
        if (waited >= uninstall_timeout_ms) return false;
        sys.thread.sleepMs(1);
    }
    return true;
}

/// Keyboard messages, from a key going down to the characters it makes.
fn isKey(msg: u32) bool {
    return msg >= win.WM_KEYDOWN and msg <= win.WM_UNICHAR;
}

/// On the window's thread as it takes a message off its queue, before the game's loop does
/// anything with it. One that's eaten turns into `WM_NULL`.
fn queueHook(code: i32, wparam: usize, lparam: isize) callconv(.winapi) isize {
    _ = hook_calls.fetchAdd(1, .seq_cst);
    defer _ = hook_calls.fetchSub(1, .seq_cst);
    if (code == win.HC_ACTION and wparam == win.PM_REMOVE) {
        const m: *win.MSG = @ptrFromInt(@as(usize, @bitCast(lparam)));
        if (isKey(m.message)) if (m.hwnd) |hwnd| for (&hooked) |*h| {
            const self = h.load(.acquire) orelse continue;
            if (self.window == hwnd) {
                self.fromQueue(m);
                break;
            }
        };
    }
    return win.CallNextHookEx(null, code, wparam, lparam);
}

fn fromQueue(self: *Subclass, m: *win.MSG) void {
    // Uninstalling, so it only forwards
    if (@atomicLoad(usize, slot(self.stub, .handler), .seq_cst) == 0) return;
    const message: Message = .{ .window = self.window, .msg = m.message, .wparam = m.wParam, .lparam = m.lParam };
    if (self.handler.func(self.handler.ctx, &message) != null) {
        m.message = win.WM_NULL;
        self.queued.set = false;
        return;
    }
    self.queued = .{ .set = true, .msg = m.message, .wparam = m.wParam, .lparam = m.lParam, .time = m.time };
}

/// Puts the original back if nobody's on top. Frees once no handler call is running. False if one still
/// was after the wait, so it's leaked, and whatever its handler uses has to be too.
pub fn uninstall(self: *Subclass) bool {
    // Stub only forwards from now on
    @atomicStore(usize, slot(self.stub, .handler), 0, .seq_cst);
    const unhooked = self.unhookQueue();

    if (win.GetWindowLongPtrW(self.window, win.GWLP_WNDPROC) == @as(isize, @bitCast(self.stub))) {
        _ = win.SetWindowLongPtrW(self.window, win.GWLP_WNDPROC, @bitCast(slot(self.stub, .original).*));
    } else {
        log.warn("Window 0x{x} was subclassed after us; leaving our stub in place as a pass-through", .{@intFromPtr(self.window)});
    }

    const active = slot(self.stub, .active);
    var waited: u32 = 0;
    while (@atomicLoad(usize, active, .seq_cst) != 0) : (waited += 1) {
        if (waited >= uninstall_timeout_ms) {
            // The handler might still touch `self`, so leak it
            log.err("Window message handler still running after {}ms; leaking the subclass", .{uninstall_timeout_ms});
            return false;
        }
        sys.thread.sleepMs(1);
    }
    if (!unhooked) {
        log.err("Window queue hook still running after {}ms; leaking the subclass", .{uninstall_timeout_ms});
        return false;
    }
    self.allocator.destroy(self);
    return true;
}

/// Skips the handler.
pub fn callOriginal(self: *const Subclass, msg: u32, wparam: usize, lparam: isize) isize {
    const original: isize = @bitCast(@atomicLoad(usize, slot(self.stub, .original), .seq_cst));
    return win.CallWindowProcW(original, self.window, msg, wparam, lparam);
}

/// Called from the stub. `result` gets the return value if eaten.
fn handle(hwnd: Handle, msg: u32, wparam: usize, lparam: isize, result: *isize, self: *Subclass) callconv(.winapi) bool {
    // The queue hook's had this one already
    if (isKey(msg) and self.queued.matches(msg, wparam, lparam)) {
        self.queued.set = false;
        return false;
    }
    const message: Message = .{ .window = hwnd, .msg = msg, .wparam = wparam, .lparam = lparam };
    const consumed = self.handler.func(self.handler.ctx, &message) orelse return false;
    result.* = consumed;
    return true;
}

fn slot(stub: usize, comptime s: stub_.Slot) *usize {
    const slots = @intFromPtr(stub_.template.slots) - @intFromPtr(stub_.template.start);
    return @ptrFromInt(stub + slots + @backingInt(s) * @sizeOf(usize));
}

fn stubSize() usize {
    return @intFromPtr(stub_.template.end) - @intFromPtr(stub_.template.start);
}

const tests = struct {
    const testing = std.testing;
    const MSG_CONSUMED = win.WM_USER + 1;
    const MSG_OTHER = win.WM_USER + 2;

    const Counter = struct {
        seen: u32 = 0,
        last_wparam: usize = 0,

        fn consume(ctx: *anyopaque, m: *const Message) ?isize {
            const self: *Counter = @ptrCast(@alignCast(ctx));
            self.seen += 1;
            self.last_wparam = m.wparam;
            return if (m.msg == MSG_CONSUMED) 42 else null;
        }
    };

    test "install and uninstall" {
        const hwnd = try api_window.createHidden();
        defer api_window.destroy(hwnd);
        const original = win.GetWindowLongPtrW(hwnd, win.GWLP_WNDPROC);

        var counter: Counter = .{};
        const subclass = try install(testing.allocator, hwnd, .{ .ctx = &counter, .func = Counter.consume });
        const stub: isize = @bitCast(subclass.stub);
        try testing.expectEqual(42, api_window.send(hwnd, MSG_CONSUMED, 7, 0));
        try testing.expectEqual(7, counter.last_wparam);
        try testing.expectEqual(0, api_window.send(hwnd, MSG_OTHER, 0, 0));
        try testing.expectEqual(2, counter.seen);
        try testing.expectEqual(0, subclass.callOriginal(MSG_CONSUMED, 0, 0)); // skips the handler
        try testing.expectEqual(2, counter.seen);

        try std.testing.expect(subclass.uninstall());
        const restored = win.GetWindowLongPtrW(hwnd, win.GWLP_WNDPROC);
        try testing.expect(restored != stub);
        // 32-bit user32 may report a system class's proc through another thunk
        if (@sizeOf(usize) == 8) try testing.expectEqual(original, restored);
        try testing.expectEqual(0, api_window.send(hwnd, MSG_CONSUMED, 0, 0));
        try testing.expectEqual(2, counter.seen);
    }

    test "two windows" {
        const a = try api_window.createHidden();
        defer api_window.destroy(a);
        const b = try api_window.createHidden();
        defer api_window.destroy(b);

        var counter_a: Counter = .{};
        var counter_b: Counter = .{};
        const sub_a = try install(testing.allocator, a, .{ .ctx = &counter_a, .func = Counter.consume });
        defer _ = sub_a.uninstall();
        const sub_b = try install(testing.allocator, b, .{ .ctx = &counter_b, .func = Counter.consume });
        defer _ = sub_b.uninstall();

        _ = api_window.send(a, MSG_OTHER, 0, 0);
        _ = api_window.send(b, MSG_OTHER, 0, 0);
        _ = api_window.send(b, MSG_OTHER, 0, 0);
        try testing.expectEqual(1, counter_a.seen);
        try testing.expectEqual(2, counter_b.seen);
    }

    const Keys = struct {
        downs: u32 = 0,

        /// Eats Q, lets the rest through.
        fn see(ctx: *anyopaque, m: *const Message) ?isize {
            const self: *Keys = @ptrCast(@alignCast(ctx));
            if (m.msg != win.WM_KEYDOWN) return null;
            self.downs += 1;
            return if (m.wparam == 'Q') 0 else null;
        }
    };

    /// Takes the next key for `hwnd` off the queue, like a game's loop.
    fn take(hwnd: Handle) win.MSG {
        var m: win.MSG = .{};
        _ = win.PeekMessageW(&m, hwnd, win.WM_KEYDOWN, win.WM_UNICHAR, win.PM_REMOVE);
        return m;
    }

    test "keys the game's loop never dispatches, like XNA's" {
        const hwnd = try api_window.createHidden();
        defer api_window.destroy(hwnd);
        var keys: Keys = .{};
        const subclass = try install(testing.allocator, hwnd, .{ .ctx = &keys, .func = Keys.see });
        defer _ = subclass.uninstall();
        if (subclass.hook == null) return error.SkipZigTest;

        // Taken but not dispatched still counts
        _ = win.PostMessageW(hwnd, win.WM_KEYDOWN, 'W', 1);
        try testing.expectEqual(win.WM_KEYDOWN, take(hwnd).message);
        try testing.expectEqual(1, keys.downs);

        // Eaten, so the game's loop gets nothing
        _ = win.PostMessageW(hwnd, win.WM_KEYDOWN, 'Q', 1);
        try testing.expectEqual(win.WM_NULL, take(hwnd).message);
        try testing.expectEqual(2, keys.downs);

        // Dispatched after, it's not handed over twice
        _ = win.PostMessageW(hwnd, win.WM_KEYDOWN, 'E', 1);
        const m = take(hwnd);
        _ = win.DispatchMessageW(&m);
        try testing.expectEqual(3, keys.downs);

        // Sent straight to the window, it never was on the queue
        _ = api_window.send(hwnd, win.WM_KEYDOWN, 'E', 1);
        try testing.expectEqual(4, keys.downs);
    }

    var overlay_prev: isize = 0;

    fn overlayProc(hwnd: Handle, msg: u32, wparam: usize, lparam: isize) callconv(.winapi) isize {
        return win.CallWindowProcW(overlay_prev, hwnd, msg, wparam, lparam);
    }

    test "uninstall under another subclass" {
        const saved = testing.log_level;
        testing.log_level = .err;
        defer testing.log_level = saved;

        const hwnd = try api_window.createHidden();
        defer api_window.destroy(hwnd);

        var counter: Counter = .{};
        const subclass = try install(testing.allocator, hwnd, .{ .ctx = &counter, .func = Counter.consume });
        // An overlay subclasses on top of us
        overlay_prev = win.SetWindowLongPtrW(hwnd, win.GWLP_WNDPROC, @bitCast(@intFromPtr(&overlayProc)));
        try testing.expectEqual(42, api_window.send(hwnd, MSG_CONSUMED, 0, 0));

        try std.testing.expect(subclass.uninstall());
        try testing.expectEqual(@as(isize, @bitCast(@intFromPtr(&overlayProc))), win.GetWindowLongPtrW(hwnd, win.GWLP_WNDPROC));
        // Overlay -> our pass-through stub -> original. Not eaten anymore, but still works
        try testing.expectEqual(0, api_window.send(hwnd, MSG_CONSUMED, 0, 0));
        try testing.expectEqual(1, counter.seen);
    }
};

test {
    _ = tests;
}
