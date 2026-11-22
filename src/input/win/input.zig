//! Windows input conversion.

const std = @import("std");

const input = @import("../root.zig");
const Key = input.Key;
const MouseButton = input.MouseButton;
const Event = input.Event;
const Channel = input.Channel;

const win = @import("tuft_sys").win;
const Message = @import("tuft_window").Message;

const HTCLIENT = 1;
const WHEEL_DELTA = 120.0;
const UNICODE_NOCHAR = 0xFFFF;

const VK_SHIFT = 0x10;
const VK_CONTROL = 0x11;
const VK_MENU = 0x12;
const VK_RETURN = 0x0D;
const VK_LWIN = 0x5B;
const VK_RWIN = 0x5C;
const scancode_right_shift = 0x36;

/// `.keypad_enter` shares Enter's, the extended flag tells them apart.
const vk_codes: std.EnumArray(Key, u8) = blk: {
    @setEvalBranchQuota(10_000);
    var t: std.EnumArray(Key, u8) = .initFill(0);
    for (0..26) |i| t.set(@field(Key, &[_]u8{'a' + i}), 'A' + i);
    for (0..10) |i| {
        t.set(@field(Key, &[_]u8{'0' + i}), '0' + i);
        t.set(@field(Key, std.fmt.comptimePrint("keypad_{d}", .{i})), 0x60 + i);
    }
    for (0..24) |i| t.set(@field(Key, std.fmt.comptimePrint("f{d}", .{i + 1})), 0x70 + i);
    for ([_]struct { Key, u8 }{
        .{ .tab, 0x09 },                   .{ .left, 0x25 },                   .{ .right, 0x27 },                 .{ .up, 0x26 },
        .{ .down, 0x28 },                  .{ .page_up, 0x21 },                .{ .page_down, 0x22 },             .{ .home, 0x24 },
        .{ .end, 0x23 },                   .{ .insert, 0x2D },                 .{ .delete, 0x2E },                .{ .backspace, 0x08 },
        .{ .space, 0x20 },                 .{ .enter, VK_RETURN },             .{ .escape, 0x1B },                .{ .left_ctrl, 0xA2 },
        .{ .left_shift, 0xA0 },            .{ .left_alt, 0xA4 },               .{ .left_super, VK_LWIN },         .{ .right_ctrl, 0xA3 },
        .{ .right_shift, 0xA1 },           .{ .right_alt, 0xA5 },              .{ .right_super, VK_RWIN },        .{ .menu, 0x5D },
        .{ .apostrophe, 0xDE },            .{ .comma, 0xBC },                  .{ .minus, 0xBD },                 .{ .period, 0xBE },
        .{ .slash, 0xBF },                 .{ .semicolon, 0xBA },              .{ .equal, 0xBB },                 .{ .left_bracket, 0xDB },
        .{ .backslash, 0xDC },             .{ .right_bracket, 0xDD },          .{ .grave, 0xC0 },                 .{ .caps_lock, 0x14 },
        .{ .scroll_lock, 0x91 },           .{ .num_lock, 0x90 },               .{ .print_screen, 0x2C },          .{ .pause, 0x13 },
        .{ .keypad_decimal, 0x6E },        .{ .keypad_divide, 0x6F },          .{ .keypad_multiply, 0x6A },       .{ .keypad_subtract, 0x6D },
        .{ .keypad_add, 0x6B },            .{ .keypad_enter, VK_RETURN },      .{ .browser_back, 0xA6 },          .{ .browser_forward, 0xA7 },
        .{ .oem_102, 0xE2 },
        // VK_GAMEPAD_*. Only for hiding and lookups, the poller reports these keys
                      .{ .gamepad_a, 0xC3 },              .{ .gamepad_b, 0xC4 },             .{ .gamepad_x, 0xC5 },
        .{ .gamepad_y, 0xC6 },             .{ .gamepad_right_shoulder, 0xC7 }, .{ .gamepad_left_shoulder, 0xC8 }, .{ .gamepad_left_trigger, 0xC9 },
        .{ .gamepad_right_trigger, 0xCA }, .{ .gamepad_dpad_up, 0xCB },        .{ .gamepad_dpad_down, 0xCC },     .{ .gamepad_dpad_left, 0xCD },
        .{ .gamepad_dpad_right, 0xCE },    .{ .gamepad_start, 0xCF },          .{ .gamepad_back, 0xD0 },          .{ .gamepad_left_stick, 0xD1 },
        .{ .gamepad_right_stick, 0xD2 },
    }) |entry| t.set(entry[0], entry[1]);
    for (std.enums.values(Key)) |key| {
        if (t.get(key) == 0) @compileError("no virtual-key code for ." ++ @tagName(key));
    }
    break :blk t;
};

/// Controller buttons left out, since window messages for them would double up the poller's.
const keys_by_vk: [256]?Key = blk: {
    @setEvalBranchQuota(10_000);
    var t: [256]?Key = @splat(null);
    for (std.enums.values(Key)) |key| {
        if (key != .keypad_enter and !input.isPad(key)) t[vk_codes.get(key)] = key;
    }
    break :blk t;
};

pub fn vkOf(key: Key) u8 {
    return vk_codes.get(key);
}

/// Generic Shift/Ctrl/Alt get a side, and extended Enter is the keypad's.
pub fn keyOf(wparam: usize, lparam: isize) ?Key {
    const vk: u8 = @truncate(wparam);
    const extended = lparam & (1 << 24) != 0;
    return switch (vk) {
        VK_SHIFT => if ((lparam >> 16) & 0xFF == scancode_right_shift) .right_shift else .left_shift,
        VK_CONTROL => if (extended) .right_ctrl else .left_ctrl,
        VK_MENU => if (extended) .right_alt else .left_alt,
        VK_RETURN => if (extended) .keypad_enter else .enter,
        else => keys_by_vk[vk],
    };
}

pub const Translator = struct {
    /// First half of a non-BMP character.
    high_surrogate: ?u16 = null,

    pub fn translate(self: *Translator, m: *const Message) ?Event {
        return switch (m.msg) {
            win.WM_KEYDOWN, win.WM_SYSKEYDOWN, win.WM_KEYUP, win.WM_SYSKEYUP => .{ .key = .{
                .key = keyOf(m.wparam, m.lparam) orelse return null,
                .down = m.msg == win.WM_KEYDOWN or m.msg == win.WM_SYSKEYDOWN,
                .repeat = (m.msg == win.WM_KEYDOWN or m.msg == win.WM_SYSKEYDOWN) and m.lparam & (1 << 30) != 0,
                .mods = mods(),
            } },
            win.WM_CHAR => self.utf16(@truncate(m.wparam)),
            win.WM_UNICHAR => if (m.wparam == UNICODE_NOCHAR) null else .{ .text = std.math.cast(u21, m.wparam) orelse return null },
            win.WM_MOUSEMOVE => .{ .mouse_move = point(m.lparam) },
            win.WM_LBUTTONDOWN, win.WM_LBUTTONDBLCLK => button(.left, true),
            win.WM_LBUTTONUP => button(.left, false),
            win.WM_RBUTTONDOWN, win.WM_RBUTTONDBLCLK => button(.right, true),
            win.WM_RBUTTONUP => button(.right, false),
            win.WM_MBUTTONDOWN, win.WM_MBUTTONDBLCLK => button(.middle, true),
            win.WM_MBUTTONUP => button(.middle, false),
            win.WM_XBUTTONDOWN, win.WM_XBUTTONDBLCLK, win.WM_XBUTTONUP => button(
                if ((m.wparam >> 16) & 0xFFFF == 1) .x1 else .x2,
                m.msg != win.WM_XBUTTONUP,
            ),
            win.WM_MOUSEWHEEL => .{ .wheel = .{ .y = wheelDelta(m.wparam) } },
            win.WM_MOUSEHWHEEL => .{ .wheel = .{ .x = wheelDelta(m.wparam) } },
            win.WM_MOUSELEAVE => .mouse_leave,
            win.WM_SETFOCUS => .{ .focus = true },
            win.WM_KILLFOCUS => .{ .focus = false },
            win.WM_SETCURSOR => if (m.lparam & 0xFFFF == HTCLIENT) .cursor else null,
            else => null,
        };
    }

    fn utf16(self: *Translator, unit: u16) ?Event {
        if (std.unicode.utf16IsHighSurrogate(unit)) {
            self.high_surrogate = unit;
            return null;
        }
        const high = self.high_surrogate;
        self.high_surrogate = null;
        if (std.unicode.utf16IsLowSurrogate(unit)) {
            const h = high orelse return null;
            return .{ .text = std.unicode.utf16DecodeSurrogatePair(&.{ h, unit }) catch return null };
        }
        return .{ .text = unit };
    }
};

pub fn channelOf(m: *const Message) ?Channel {
    if (isIme(m.msg)) return .keyboard;
    return switch (m.msg) {
        win.WM_KEYDOWN...win.WM_UNICHAR => .keyboard,
        win.WM_MOUSEMOVE => .mouse_motion,
        win.WM_LBUTTONDOWN...win.WM_MOUSEHWHEEL => .mouse_buttons,
        else => null,
    };
}

const WM_IME_STARTCOMPOSITION = 0x010D;
const WM_IME_COMPOSITION = 0x010F;
const WM_IME_SETCONTEXT = 0x0281;
const WM_IME_KEYUP = 0x0291;

/// From `WM_IME_SETCONTEXT` to `WM_IME_KEYUP`, and the composition ones next to the key messages.
pub fn isIme(msg: u32) bool {
    return (msg >= WM_IME_STARTCOMPOSITION and msg <= WM_IME_COMPOSITION) or (msg >= WM_IME_SETCONTEXT and msg <= WM_IME_KEYUP);
}

pub fn handledResult(event: Event) isize {
    return switch (event) {
        .cursor => 1, // the cursor was set
        else => 0,
    };
}

pub fn isKeyDown(key: Key) bool {
    return win.GetAsyncKeyState(vkOf(key)) < 0;
}

pub fn isButtonDown(b: MouseButton) bool {
    const vk: i32 = switch (b) {
        .left => 0x01,
        .right => 0x02,
        .middle => 0x04,
        .x1 => 0x05,
        .x2 => 0x06,
    };
    return win.GetAsyncKeyState(vk) < 0;
}

pub fn cursorPosition(window: win.HWND) ?input.Point {
    var p: win.POINT = .{};
    if (!win.GetCursorPos(&p).toBool() or !win.ScreenToClient(window, &p).toBool()) return null;
    return .{ .x = p.x, .y = p.y };
}

pub fn screenCursorPosition() ?input.Point {
    var p: win.POINT = .{};
    if (!win.GetCursorPos(&p).toBool()) return null;
    return .{ .x = p.x, .y = p.y };
}

pub fn moveCursor(to: input.Point) void {
    _ = win.SetCursorPos(to.x, to.y);
}

pub fn clientCenter(window: win.HWND) ?input.Point {
    var r: win.RECT = .{};
    if (!win.GetClientRect(window, &r).toBool()) return null;
    var p: win.POINT = .{ .x = @divTrunc(r.left + r.right, 2), .y = @divTrunc(r.top + r.bottom, 2) };
    if (!win.ClientToScreen(window, &p).toBool()) return null;
    return .{ .x = p.x, .y = p.y };
}

pub fn hideCursor() void {
    _ = win.SetCursor(null);
}

pub fn cursorVisible() bool {
    var info: win.CURSORINFO = .{};
    if (!win.GetCursorInfo(&info).toBool()) return false;
    return info.flags & win.CURSOR_SHOWING != 0 and info.hCursor != null;
}

/// Message-queue state, not hardware.
fn mods() input.Mods {
    const held = struct {
        fn f(vk: i32) bool {
            return win.GetKeyState(vk) < 0;
        }
    }.f;
    return .{
        .ctrl = held(VK_CONTROL),
        .shift = held(VK_SHIFT),
        .alt = held(VK_MENU),
        .super = held(VK_LWIN) or held(VK_RWIN),
    };
}

fn point(lparam: isize) input.Point {
    const bits: usize = @bitCast(lparam);
    return .{
        .x = @as(i16, @bitCast(@as(u16, @truncate(bits)))),
        .y = @as(i16, @bitCast(@as(u16, @truncate(bits >> 16)))),
    };
}

fn button(b: MouseButton, down: bool) Event {
    return .{ .mouse_button = .{ .button = b, .down = down } };
}

fn wheelDelta(wparam: usize) f32 {
    const delta: i16 = @bitCast(@as(u16, @truncate(wparam >> 16)));
    return @as(f32, @floatFromInt(delta)) / WHEEL_DELTA;
}

const tests = struct {
    const testing = std.testing;

    fn msg(id: u32, wparam: usize, lparam: isize) Message {
        return .{ .window = undefined, .msg = id, .wparam = wparam, .lparam = lparam };
    }

    fn translate(id: u32, wparam: usize, lparam: isize) ?Event {
        var t: Translator = .{};
        return t.translate(&msg(id, wparam, lparam));
    }

    test "key codes round trip" {
        for (std.enums.values(Key)) |key| {
            const extended: isize = if (key == .keypad_enter) 1 << 24 else 0;
            if (input.isPad(key)) {
                try testing.expectEqual(null, keyOf(vkOf(key), extended));
                continue;
            }
            try testing.expectEqual(key, keyOf(vkOf(key), extended).?);
        }
    }

    test "sided modifiers and Enter" {
        try testing.expectEqual(.left_shift, keyOf(VK_SHIFT, 0x2A << 16).?);
        try testing.expectEqual(.right_shift, keyOf(VK_SHIFT, 0x36 << 16).?);
        try testing.expectEqual(.left_ctrl, keyOf(VK_CONTROL, 0).?);
        try testing.expectEqual(.right_ctrl, keyOf(VK_CONTROL, 1 << 24).?);
        try testing.expectEqual(.right_alt, keyOf(VK_MENU, 1 << 24).?);
        try testing.expectEqual(.enter, keyOf(VK_RETURN, 0).?);
        try testing.expectEqual(.keypad_enter, keyOf(VK_RETURN, 1 << 24).?);
        try testing.expectEqual(null, keyOf(0xFF, 0));
    }

    test "key messages" {
        const down = translate(win.WM_KEYDOWN, 0x2D, 1).?.key;
        try testing.expectEqual(.insert, down.key);
        try testing.expect(down.down and !down.repeat);
        try testing.expect(translate(win.WM_KEYDOWN, 0x2D, 1 | (1 << 30)).?.key.repeat);
        const up = translate(win.WM_SYSKEYUP, 'F', 0).?.key;
        try testing.expectEqual(.f, up.key);
        try testing.expect(!up.down and !up.repeat);
    }

    test "surrogate pairs" {
        try testing.expectEqual(Event{ .text = 'é' }, translate(win.WM_CHAR, 'é', 0).?);
        var t: Translator = .{};
        try testing.expectEqual(null, t.translate(&msg(win.WM_CHAR, 0xD83D, 0)));
        try testing.expectEqual(Event{ .text = 0x1F600 }, t.translate(&msg(win.WM_CHAR, 0xDE00, 0)).?);
        try testing.expectEqual(null, t.translate(&msg(win.WM_CHAR, 0xDE00, 0))); // stray second half
        try testing.expectEqual(null, translate(win.WM_UNICHAR, UNICODE_NOCHAR, 0));
    }

    test "mouse messages" {
        try testing.expectEqual(Event{ .mouse_move = .{ .x = -2, .y = 300 } }, translate(win.WM_MOUSEMOVE, 0, (300 << 16) | 0xFFFE).?);
        try testing.expectEqual(button(.left, true), translate(win.WM_LBUTTONDBLCLK, 0, 0).?);
        try testing.expectEqual(button(.x2, false), translate(win.WM_XBUTTONUP, 2 << 16, 0).?);
        try testing.expectEqual(Event{ .wheel = .{ .y = -1 } }, translate(win.WM_MOUSEWHEEL, 0xFF88 << 16, 0).?);
        try testing.expectEqual(Event{ .wheel = .{ .x = 0.5 } }, translate(win.WM_MOUSEHWHEEL, 60 << 16, 0).?);
        try testing.expectEqual(Event.cursor, translate(win.WM_SETCURSOR, 0, HTCLIENT).?);
        try testing.expectEqual(null, translate(win.WM_SETCURSOR, 0, 2)); // over the caption
    }

    test "channels" {
        try testing.expectEqual(.keyboard, channelOf(&msg(win.WM_DEADCHAR, 0, 0)).?);
        try testing.expectEqual(.mouse_motion, channelOf(&msg(win.WM_MOUSEMOVE, 0, 0)).?);
        try testing.expectEqual(.mouse_buttons, channelOf(&msg(win.WM_XBUTTONDBLCLK, 0, 0)).?);
        try testing.expectEqual(.mouse_buttons, channelOf(&msg(win.WM_MOUSEHWHEEL, 0, 0)).?);
        try testing.expectEqual(.keyboard, channelOf(&msg(WM_IME_COMPOSITION, 0, 0)).?);
        try testing.expectEqual(.keyboard, channelOf(&msg(WM_IME_SETCONTEXT, 1, 0)).?);
        try testing.expectEqual(null, channelOf(&msg(0x0292, 0, 0)));
        try testing.expectEqual(null, channelOf(&msg(win.WM_SETFOCUS, 0, 0)));
    }
};

test {
    _ = tests;
}
