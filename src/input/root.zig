//! Platform-neutral keyboard and mouse input.

const std = @import("std");
const builtin = @import("builtin");

pub const Window = @import("Window.zig");
pub const Blocker = @import("Blocker.zig");
pub const Keybinds = @import("Keybinds.zig");
pub const Focus = @import("Focus.zig");
/// Controllers from every source, merged.
pub const Gamepads = @import("Gamepads.zig");
/// A `Gamepads` source.
pub const XInput = switch (builtin.os.tag) {
    .windows => @import("win/xinput.zig"),
    else => @compileError("Unsupported operating system"),
};
/// The IME for our text boxes in the game's window.
pub const Ime = switch (builtin.os.tag) {
    .windows => @import("win/ime.zig"),
    else => @compileError("Unsupported operating system"),
};

pub const native = switch (builtin.os.tag) {
    .windows => @import("win/input.zig"),
    else => @compileError("Unsupported operating system"),
};

/// Physical key, named for the US layout. Sided keys always report their side.
pub const Key = enum(u8) {
    tab,
    left,
    right,
    up,
    down,
    page_up,
    page_down,
    home,
    end,
    insert,
    delete,
    backspace,
    space,
    enter,
    escape,
    left_ctrl,
    left_shift,
    left_alt,
    left_super,
    right_ctrl,
    right_shift,
    right_alt,
    right_super,
    menu,
    @"0",
    @"1",
    @"2",
    @"3",
    @"4",
    @"5",
    @"6",
    @"7",
    @"8",
    @"9",
    a,
    b,
    c,
    d,
    e,
    f,
    g,
    h,
    i,
    j,
    k,
    l,
    m,
    n,
    o,
    p,
    q,
    r,
    s,
    t,
    u,
    v,
    w,
    x,
    y,
    z,
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
    f13,
    f14,
    f15,
    f16,
    f17,
    f18,
    f19,
    f20,
    f21,
    f22,
    f23,
    f24,
    apostrophe,
    comma,
    minus,
    period,
    slash,
    semicolon,
    equal,
    left_bracket,
    backslash,
    right_bracket,
    grave,
    caps_lock,
    scroll_lock,
    num_lock,
    print_screen,
    pause,
    keypad_0,
    keypad_1,
    keypad_2,
    keypad_3,
    keypad_4,
    keypad_5,
    keypad_6,
    keypad_7,
    keypad_8,
    keypad_9,
    keypad_decimal,
    keypad_divide,
    keypad_multiply,
    keypad_subtract,
    keypad_add,
    keypad_enter,
    browser_back,
    browser_forward,
    /// Extra key between left shift and Z on ISO keyboards.
    oem_102,
    // Controller buttons, by their Xbox names. `gamepad_a` is the bottom face button on any pad.
    gamepad_a,
    gamepad_b,
    gamepad_x,
    gamepad_y,
    gamepad_left_shoulder,
    gamepad_right_shoulder,
    gamepad_left_trigger,
    gamepad_right_trigger,
    gamepad_dpad_up,
    gamepad_dpad_down,
    gamepad_dpad_left,
    gamepad_dpad_right,
    gamepad_start,
    gamepad_back,
    gamepad_left_stick,
    gamepad_right_stick,
};

/// Controller buttons, in the same order as the `gamepad_` keys.
pub const PadButton = enum(u8) {
    a,
    b,
    x,
    y,
    left_shoulder,
    right_shoulder,
    left_trigger,
    right_trigger,
    dpad_up,
    dpad_down,
    dpad_left,
    dpad_right,
    start,
    back,
    left_stick,
    right_stick,

    pub fn key(self: PadButton) Key {
        return @fromBackingInt(@intCast(@backingInt(Key.gamepad_a) + @backingInt(self)));
    }

    /// Short, like "LB" or "Start".
    pub fn label(self: PadButton) []const u8 {
        return switch (self) {
            .a => "A",
            .b => "B",
            .x => "X",
            .y => "Y",
            .left_shoulder => "LB",
            .right_shoulder => "RB",
            .left_trigger => "LT",
            .right_trigger => "RT",
            .dpad_up => "D-pad Up",
            .dpad_down => "D-pad Down",
            .dpad_left => "D-pad Left",
            .dpad_right => "D-pad Right",
            .start => "Start",
            .back => "Back",
            .left_stick => "LS",
            .right_stick => "RS",
        };
    }

    /// Null for keyboard keys.
    pub fn of(k: Key) ?PadButton {
        const first = @backingInt(Key.gamepad_a);
        const value = @backingInt(k);
        if (value < first or value - first >= std.enums.values(PadButton).len) return null;
        return @fromBackingInt(@intCast(value - first));
    }
};

pub fn isPad(key: Key) bool {
    return PadButton.of(key) != null;
}

/// Controller buttons held together, one bit per `PadButton`.
pub const PadButtons = bitpack struct(u32) {
    a: bool = false,
    b: bool = false,
    x: bool = false,
    y: bool = false,
    left_shoulder: bool = false,
    right_shoulder: bool = false,
    left_trigger: bool = false,
    right_trigger: bool = false,
    dpad_up: bool = false,
    dpad_down: bool = false,
    dpad_left: bool = false,
    dpad_right: bool = false,
    start: bool = false,
    back: bool = false,
    left_stick: bool = false,
    right_stick: bool = false,
    _: u16 = 0,

    comptime {
        for (std.enums.values(PadButton), 0..) |b, i| {
            if (@bitOffsetOf(PadButtons, @tagName(b)) != i) @compileError("PadButtons is out of order with PadButton");
        }
    }

    pub fn bits(self: PadButtons) u32 {
        return @bitCast(self);
    }

    pub fn fromBits(value: u32) PadButtons {
        return @bitCast(value & 0xFFFF);
    }

    pub fn has(self: PadButtons, button: PadButton) bool {
        return self.bits() & bitOf(button) != 0;
    }

    pub fn with(self: PadButtons, button: PadButton, on: bool) PadButtons {
        return fromBits(if (on) self.bits() | bitOf(button) else self.bits() & ~bitOf(button));
    }

    pub fn eql(a: PadButtons, b: PadButtons) bool {
        return a.bits() == b.bits();
    }

    pub fn isEmpty(self: PadButtons) bool {
        return self.bits() == 0;
    }

    fn bitOf(button: PadButton) u32 {
        return @as(u32, 1) << @intCast(@backingInt(button));
    }
};

/// Sticks go -1 to 1 with up and right positive, triggers 0 to 1. No dead zone applied.
pub const Axes = struct {
    left_x: f32 = 0,
    left_y: f32 = 0,
    right_x: f32 = 0,
    right_y: f32 = 0,
    left_trigger: f32 = 0,
    right_trigger: f32 = 0,

    pub fn eql(a: Axes, b: Axes) bool {
        return std.meta.eql(a, b);
    }
};

/// Every connected controller merged into one.
pub const PadAxes = struct {
    connected: bool = false,
    axes: Axes = .{},
};

pub const MouseButton = enum(u8) { left, right, middle, x1, x2 };

/// Either side.
pub const Mods = bitpack struct(u8) {
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
    super: bool = false,
    _: u4 = 0,
};

pub fn isModifier(key: Key) bool {
    return switch (key) {
        .left_ctrl, .right_ctrl, .left_shift, .right_shift, .left_alt, .right_alt, .left_super, .right_super => true,
        else => false,
    };
}

/// A key with exactly these modifiers held. The key can't be a modifier, and controller buttons
/// take no modifiers.
pub const Chord = struct {
    key: Key,
    mods: Mods = .{},

    pub fn matches(self: Chord, key: Key, mods: Mods) bool {
        return self.key == key and self.mods.ctrl == mods.ctrl and self.mods.shift == mods.shift and
            self.mods.alt == mods.alt and self.mods.super == mods.super;
    }

    pub fn eql(a: Chord, b: Chord) bool {
        return a.matches(b.key, b.mods);
    }

    pub fn isValid(self: Chord) bool {
        if (isModifier(self.key)) return false;
        return !isPad(self.key) or self.matches(self.key, .{});
    }

    /// For a held key, which takes no modifiers but can be one, like Shift.
    pub fn isValidHeld(self: Chord) bool {
        return self.matches(self.key, .{});
    }

    /// Like `Ctrl+Shift+f8`.
    pub fn format(self: Chord, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.mods.ctrl) try writer.writeAll("Ctrl+");
        if (self.mods.shift) try writer.writeAll("Shift+");
        if (self.mods.alt) try writer.writeAll("Alt+");
        if (self.mods.super) try writer.writeAll("Super+");
        try writer.writeAll(@tagName(self.key));
    }
};

/// Up to `max` chords that all do the same, like a key and a controller button. The first is
/// `key` and `mods`, so one chord written down, like `.{ .key = .f8 }` or a saved one, is a `Keys`
/// with just it.
pub const Keys = struct {
    key: Key,
    mods: Mods = .{},
    /// After the first, with no gaps.
    more: [max - 1]?Chord = @splat(null),

    pub const max = 4;

    pub fn one(chord: Chord) Keys {
        return .{ .key = chord.key, .mods = chord.mods };
    }

    /// Null for none. Repeats are dropped, and past `max` too.
    pub fn of(chords: []const Chord) ?Keys {
        if (chords.len == 0) return null;
        var out: Keys = .one(chords[0]);
        for (chords[1..]) |c| out = out.with(c);
        return out;
    }

    pub fn first(self: Keys) Chord {
        return .{ .key = self.key, .mods = self.mods };
    }

    pub fn count(self: Keys) usize {
        var n: usize = 1;
        for (self.more) |m| {
            if (m == null) break;
            n += 1;
        }
        return n;
    }

    pub fn get(self: Keys, i: usize) ?Chord {
        if (i == 0) return self.first();
        if (i > self.more.len) return null;
        return self.more[i - 1];
    }

    /// Into `buf`, in order.
    pub fn slice(self: Keys, buf: *[max]Chord) []Chord {
        const n = self.count();
        for (0..n) |i| buf[i] = self.get(i).?;
        return buf[0..n];
    }

    pub fn contains(self: Keys, chord: Chord) bool {
        for (0..self.count()) |i| if (self.get(i).?.eql(chord)) return true;
        return false;
    }

    /// With `chord` added at the end, unless it's there already or there's no room.
    pub fn with(self: Keys, chord: Chord) Keys {
        if (self.contains(chord)) return self;
        var out = self;
        for (&out.more) |*m| if (m.* == null) {
            m.* = chord;
            return out;
        };
        return out;
    }

    /// The one at `i` swapped for `chord`, or dropped if `chord` is there already.
    pub fn replaced(self: Keys, i: usize, chord: Chord) Keys {
        var buf: [max]Chord = undefined;
        const all = self.slice(&buf);
        if (i >= all.len) return self.with(chord);
        if (self.contains(chord)) return self.without(i) orelse self;
        all[i] = chord;
        return of(all).?;
    }

    /// Without the one at `i`. Null once there's none left.
    pub fn without(self: Keys, i: usize) ?Keys {
        var buf: [max]Chord = undefined;
        const all = self.slice(&buf);
        if (i >= all.len) return self;
        std.mem.copyForwards(Chord, all[i .. all.len - 1], all[i + 1 ..]);
        return of(all[0 .. all.len - 1]);
    }

    pub fn eql(a: Keys, b: Keys) bool {
        if (a.count() != b.count()) return false;
        for (0..a.count()) |i| if (!a.get(i).?.eql(b.get(i).?)) return false;
        return true;
    }

    /// Whether `key` with `mods` held is one of them. Held ones go by the key alone.
    pub fn matches(self: Keys, key: Key, mods: Mods, held: bool) bool {
        for (0..self.count()) |i| {
            const c = self.get(i).?;
            if (if (held) c.key == key else c.matches(key, mods)) return true;
        }
        return false;
    }

    pub fn isValid(self: Keys, held: bool) bool {
        for (0..self.count()) |i| {
            const c = self.get(i).?;
            if (!(if (held) c.isValidHeld() else c.isValid())) return false;
        }
        return true;
    }
};

test "chord match" {
    const chord: Chord = .{ .key = .f8, .mods = .{ .ctrl = true } };
    try std.testing.expect(chord.matches(.f8, .{ .ctrl = true }));
    try std.testing.expect(!chord.matches(.f8, .{}));
    try std.testing.expect(!chord.matches(.f8, .{ .ctrl = true, .shift = true }));
    try std.testing.expect(!chord.matches(.f9, .{ .ctrl = true }));
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("Ctrl+f8", try std.fmt.bufPrint(&buf, "{f}", .{chord}));
    try std.testing.expect(isModifier(.left_alt) and !isModifier(.f8));
}

test "controller chords" {
    try std.testing.expect((Chord{ .key = .gamepad_back }).isValid());
    try std.testing.expect(!(Chord{ .key = .gamepad_back, .mods = .{ .ctrl = true } }).isValid());
    try std.testing.expect(!(Chord{ .key = .left_ctrl }).isValid());
    try std.testing.expect((Chord{ .key = .f8, .mods = .{ .alt = true } }).isValid());
    try std.testing.expect((Chord{ .key = .left_shift }).isValidHeld());
    try std.testing.expect(!(Chord{ .key = .w, .mods = .{ .shift = true } }).isValidHeld());
}

test "a list of keys" {
    const shift: Chord = .{ .key = .left_shift };
    const rb: Chord = .{ .key = .gamepad_right_shoulder };
    var keys: Keys = .one(shift);
    keys = keys.with(rb).with(rb);
    try std.testing.expectEqual(2, keys.count());
    try std.testing.expect(keys.matches(.gamepad_right_shoulder, .{}, true));
    try std.testing.expect(keys.matches(.left_shift, .{ .shift = true }, true));
    try std.testing.expect(!keys.matches(.left_shift, .{ .shift = true }, false));
    try std.testing.expect(keys.isValid(true) and !keys.isValid(false));

    // Taking the first moves the rest up
    const left = keys.without(0).?;
    try std.testing.expect(left.first().eql(rb) and left.count() == 1);
    try std.testing.expectEqual(null, left.without(0));
    try std.testing.expect(keys.replaced(1, .{ .key = .f8 }).get(1).?.eql(.{ .key = .f8 }));
    // A repeat is dropped rather than kept twice
    try std.testing.expectEqual(1, keys.replaced(1, shift).count());
    try std.testing.expect(Keys.of(&.{ shift, rb }).?.eql(keys));

    // One chord saved before reads as a list of one
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const saved = try std.zon.parse.fromSlice(Keys, .{ .gpa = std.testing.allocator, .arena = arena.allocator(), .source = ".{ .key = .f8, .mods = .{ .ctrl = true } }", .diagnostics = &diagnostics });
    try std.testing.expect(saved.eql(.one(.{ .key = .f8, .mods = .{ .ctrl = true } })));
}

test "pad buttons" {
    try std.testing.expectEqual(Key.gamepad_a, PadButton.a.key());
    try std.testing.expectEqual(Key.gamepad_right_stick, PadButton.right_stick.key());
    try std.testing.expectEqual(PadButton.dpad_left, PadButton.of(.gamepad_dpad_left).?);
    try std.testing.expectEqual(null, PadButton.of(.oem_102));
    const held = (PadButtons{}).with(.start, true).with(.a, true).with(.a, false);
    try std.testing.expect(held.has(.start) and !held.has(.a));
    try std.testing.expect(held.eql(.{ .start = true }));
}

pub const Point = extern struct { x: i32, y: i32 };

pub const Device = enum { keyboard, mouse, gamepad };
pub const Devices = std.EnumSet(Device);

/// Lets us hide part of a device, like clicks but not the cursor.
pub const Channel = enum {
    keyboard,
    mouse_buttons,
    mouse_motion,
    gamepad,
};
pub const Channels = std.EnumSet(Channel);

pub const Event = union(enum) {
    key: struct {
        key: Key,
        down: bool,
        repeat: bool = false,
        mods: Mods = .{},
    },
    text: u21,
    mouse_move: Point,
    mouse_button: struct { button: MouseButton, down: bool },
    /// In notches. `y > 0` scrolls up, `x > 0` scrolls right.
    wheel: struct { x: f32 = 0, y: f32 = 0 },
    mouse_leave,
    focus: bool,
    cursor,
    gamepad_axes: PadAxes,

    pub fn device(self: Event) ?Device {
        return switch (self) {
            .key => |k| if (isPad(k.key)) .gamepad else .keyboard,
            .text => .keyboard,
            .mouse_move, .mouse_button, .wheel => .mouse,
            .gamepad_axes => .gamepad,
            .mouse_leave, .focus, .cursor => null,
        };
    }
};

pub const Translator = native.Translator;

pub const channelOf = native.channelOf;
pub const isImeMessage = native.isIme;

pub const handledResult = native.handledResult;

pub const isKeyDown = native.isKeyDown;
pub const isButtonDown = native.isButtonDown;
pub const cursorPosition = native.cursorPosition;
pub const screenCursorPosition = native.screenCursorPosition;
pub const moveCursor = native.moveCursor;
pub const clientCenter = native.clientCenter;
pub const hideCursor = native.hideCursor;
pub const cursorVisible = native.cursorVisible;

test {
    _ = Window;
    _ = Blocker;
    _ = Keybinds;
    _ = Focus;
    _ = Gamepads;
    _ = XInput;
    _ = Ime;
    _ = @import("win/held.zig");
    _ = @import("win/raw_input.zig");
    std.testing.refAllDecls(@This());
}
