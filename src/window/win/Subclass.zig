//! Window subclassing that's safe to remove even if someone subclassed on top.

const Subclass = @This();

const std = @import("std");

const sys = @import("tuft_sys");
const memory = @import("tuft_mem");
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

const uninstall_timeout_ms = 2000;

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
    return self;
}

/// Puts the original back if nobody's on top. Frees once no handler call is running. False if one still
/// was after the wait, so it's leaked, and whatever its handler uses has to be too.
pub fn uninstall(self: *Subclass) bool {
    // Stub only forwards from now on
    @atomicStore(usize, slot(self.stub, .handler), 0, .seq_cst);

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
