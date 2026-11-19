//! XInput, as a `Gamepads.Source`, plus what `Blocker` needs to hide controllers from the game.

const XInput = @This();

const std = @import("std");

const sys = @import("tuft_sys");
const win = sys.win;

const input = @import("../root.zig");
const PadButton = input.PadButton;
const PadButtons = input.PadButtons;
const Gamepads = @import("../Gamepads.zig");

pub const Gamepad = extern struct {
    buttons: u16 = 0,
    left_trigger: u8 = 0,
    right_trigger: u8 = 0,
    thumb_lx: i16 = 0,
    thumb_ly: i16 = 0,
    thumb_rx: i16 = 0,
    thumb_ry: i16 = 0,
};

pub const State = extern struct {
    packet: u32 = 0,
    gamepad: Gamepad = .{},
};

pub const Keystroke = extern struct {
    virtual_key: u16,
    unicode: u16,
    flags: u16,
    user_index: u8,
    hid_code: u8,
};

pub const GetStateFn = fn (user_index: u32, state: *State) callconv(.winapi) u32;
pub const GetKeystrokeFn = fn (user_index: u32, reserved: u32, keystroke: *Keystroke) callconv(.winapi) u32;

pub const success: u32 = 0;
pub const not_connected: u32 = 1167;
/// `ERROR_EMPTY`, no keystroke waiting.
pub const empty: u32 = 4306;

/// Every DLL games get XInput from, newest first.
pub const dll_names = [_][]const u8{ "xinput1_4.dll", "xinput1_3.dll", "xinput9_1_0.dll", "xinput1_2.dll", "xinput1_1.dll", "xinputuap.dll" };
/// `XInputGetStateEx`, which has no name. It's `XInputGetState` plus the Guide button.
pub const get_state_ex_ordinal = 100;

/// `XINPUT_GAMEPAD_*`. Triggers are analog, so they have no bit.
pub const button_bits: std.EnumArray(PadButton, u16) = .init(.{
    .a = 0x1000,
    .b = 0x2000,
    .x = 0x4000,
    .y = 0x8000,
    .left_shoulder = 0x0100,
    .right_shoulder = 0x0200,
    .left_trigger = 0,
    .right_trigger = 0,
    .dpad_up = 0x0001,
    .dpad_down = 0x0002,
    .dpad_left = 0x0004,
    .dpad_right = 0x0008,
    .start = 0x0010,
    .back = 0x0020,
    .left_stick = 0x0040,
    .right_stick = 0x0080,
});
/// `XINPUT_GAMEPAD_TRIGGER_THRESHOLD`, where a trigger counts as pressed.
pub const trigger_threshold = 30;

const slots = 4;
/// Asking about an empty slot is slow, so they only get asked this often.
const rescan_ms = 1000;

get_state: *const GetStateFn,
/// Poll thread only.
connected: [slots]bool = @splat(false),
next_scan_ms: u64 = 0,

/// Error if no XInput DLL loads.
pub fn create(allocator: std.mem.Allocator) !*XInput {
    const get_state = for (dll_names) |name| {
        const base = sys.module.systemBase(name) catch continue;
        if (sys.module.findExport(base, "XInputGetState")) |address| break address;
    } else return error.NoXInput;
    const self = try allocator.create(XInput);
    self.* = .{ .get_state = @ptrFromInt(get_state) };
    return self;
}

/// Remove its source first.
pub fn destroy(self: *XInput, allocator: std.mem.Allocator) void {
    allocator.destroy(self);
}

pub fn source(self: *XInput) Gamepads.Source {
    return .{ .ctx = self, .poll = poll };
}

fn poll(ctx: *anyopaque, out: []Gamepads.State) usize {
    const self: *XInput = @ptrCast(@alignCast(ctx));
    const now = win.GetTickCount64();
    const rescan = now >= self.next_scan_ms;
    if (rescan) self.next_scan_ms = now + rescan_ms;
    var count: usize = 0;
    for (&self.connected, 0..) |*connected, slot| {
        if (!connected.* and !rescan) continue;
        var state: State = .{};
        connected.* = self.get_state(@intCast(slot), &state) == success;
        if (!connected.* or count == out.len) continue;
        out[count] = stateOf(state.gamepad);
        count += 1;
    }
    return count;
}

pub fn stateOf(pad: Gamepad) Gamepads.State {
    var buttons: PadButtons = .{};
    for (std.enums.values(PadButton)) |b| {
        const bit = button_bits.get(b);
        if (bit != 0) buttons = buttons.with(b, pad.buttons & bit != 0);
    }
    buttons = buttons.with(.left_trigger, pad.left_trigger > trigger_threshold);
    buttons = buttons.with(.right_trigger, pad.right_trigger > trigger_threshold);
    return .{ .buttons = buttons, .axes = .{
        .left_x = stick(pad.thumb_lx),
        .left_y = stick(pad.thumb_ly),
        .right_x = stick(pad.thumb_rx),
        .right_y = stick(pad.thumb_ry),
        .left_trigger = @as(f32, @floatFromInt(pad.left_trigger)) / 255,
        .right_trigger = @as(f32, @floatFromInt(pad.right_trigger)) / 255,
    } };
}

fn stick(value: i16) f32 {
    return @max(-1, @as(f32, @floatFromInt(value)) / 32767);
}

/// Hidden buttons come out up, and hidden triggers at rest.
pub fn strip(pad: *Gamepad, hidden: PadButtons) void {
    for (std.enums.values(PadButton)) |b| {
        if (!hidden.has(b)) continue;
        switch (b) {
            .left_trigger => pad.left_trigger = 0,
            .right_trigger => pad.right_trigger = 0,
            else => pad.buttons &= ~button_bits.get(b),
        }
    }
}

/// `VK_PAD_*` from `XInputGetKeystroke`. Stick directions have no button, so they're null.
pub fn buttonOfKeystroke(vk: u16) ?PadButton {
    return switch (vk) {
        0x5800 => .a,
        0x5801 => .b,
        0x5802 => .x,
        0x5803 => .y,
        0x5804 => .right_shoulder,
        0x5805 => .left_shoulder,
        0x5806 => .left_trigger,
        0x5807 => .right_trigger,
        0x5810 => .dpad_up,
        0x5811 => .dpad_down,
        0x5812 => .dpad_left,
        0x5813 => .dpad_right,
        0x5814 => .start,
        0x5815 => .back,
        0x5816 => .left_stick,
        0x5817 => .right_stick,
        else => null,
    };
}

const tests = struct {
    const testing = std.testing;

    test "state conversion" {
        const s = stateOf(.{ .buttons = 0x1000 | 0x0010 | 0x0002, .left_trigger = 255, .right_trigger = 10, .thumb_lx = -32768, .thumb_ry = 32767 });
        try testing.expect(s.buttons.eql(.{ .a = true, .start = true, .dpad_down = true, .left_trigger = true }));
        try testing.expectEqual(@as(f32, -1), s.axes.left_x);
        try testing.expectEqual(@as(f32, 1), s.axes.right_y);
        try testing.expectEqual(@as(f32, 1), s.axes.left_trigger);
        try testing.expect(s.axes.right_trigger > 0 and s.axes.right_trigger < 0.1);
    }

    test "strip" {
        var pad: Gamepad = .{ .buttons = 0x1000 | 0x0020, .left_trigger = 200, .right_trigger = 200 };
        strip(&pad, .{ .back = true, .left_trigger = true });
        try testing.expectEqual(@as(u16, 0x1000), pad.buttons);
        try testing.expectEqual(@as(u8, 0), pad.left_trigger);
        try testing.expectEqual(@as(u8, 200), pad.right_trigger);
        try testing.expectEqual(PadButton.back, buttonOfKeystroke(0x5815).?);
        try testing.expectEqual(null, buttonOfKeystroke(0x5820));
    }

    test "polls without a controller" {
        const x = XInput.create(testing.allocator) catch return error.SkipZigTest;
        defer x.destroy(testing.allocator);
        var out: [Gamepads.max_pads]Gamepads.State = undefined;
        _ = poll(x, &out);
        // Only a rescan asks empty slots
        const before = x.next_scan_ms;
        _ = poll(x, &out);
        try testing.expectEqual(before, x.next_scan_ms);
    }
};

test {
    _ = tests;
}
