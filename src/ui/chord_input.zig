//! A button that takes the next key combo pressed, for picking keybinds.

const std = @import("std");

const input = @import("tuft_input");

const root = @import("root.zig");
const c = root.c;
const raw = root.raw;

pub const Options = struct {
    /// Starts listening, like from a menu command.
    listen: bool = false,
    /// Shown while it has no key.
    none: [:0]const u8 = "None",
    /// For a held key: it takes a modifier on its own, like Shift, and keys without modifiers.
    held: bool = false,
};

// Each ImGui context has its own thread, but tests make new ones
threadlocal var context: ?*c.ImGuiContext = null;
threadlocal var listening_id: c.ImGuiID = 0;
threadlocal var last_frame: c_int = -10;

fn sync() void {
    const now = raw("ImGui_GetCurrentContext")();
    if (now == context and raw("ImGui_GetFrameCount")() >= last_frame) return;
    context = now;
    listening_id = 0;
    last_frame = -10;
}

/// Click it, then press the keys. Escape or clicking elsewhere cancels. True when `chord` changed.
/// While it listens the host's keybinds are paused, so it can take keys they use.
pub fn chordInput(label: [:0]const u8, chord: *?input.Chord, options: Options) bool {
    sync();
    const id = raw("ImGui_GetID")(root.str(label));
    const frame = raw("ImGui_GetFrameCount")();
    // It stops if it wasn't drawn last frame
    if (listening_id == id and last_frame < frame - 1) listening_id = 0;
    if (options.listen) listening_id = id;

    var changed = false;
    var took = false;
    const was = listening_id == id;
    if (was) {
        last_frame = frame;
        root.captureKeyboard();
        if (root.rawOptional(fn () callconv(.c) void, "tuft_imgui_listen_keys")) |listen| listen();
        if (pressedKey(options.held)) |key| {
            listening_id = 0;
            took = true;
            if (key != .escape) {
                const m = root.mods();
                // Controller buttons and held keys take no modifiers
                const picked: input.Chord = if (input.isPad(key) or options.held) .{ .key = key } else .{ .key = key, .mods = .{ .ctrl = m.ctrl, .shift = m.shift, .alt = m.alt, .super = m.super } };
                changed = if (chord.*) |old| !old.eql(picked) else true;
                chord.* = picked;
            }
        }
    }
    const listening = listening_id == id;

    var text_buf: [64]u8 = undefined;
    const text: []const u8 = if (listening) "Press a key..." else if (chord.*) |ch| chordName(&text_buf, ch) else options.none;
    var button_buf: [256]u8 = undefined;
    const button_label = std.fmt.bufPrintSentinel(&button_buf, "{s}###{s}", .{ text, label }, 0) catch label;
    // Keys go to it, not to moving focus
    raw("ImGui_PushItemFlag")(c.ImGuiItemFlags_NoNav, was);
    const clicked = raw("ImGui_ButtonEx")(root.str(button_label), .{ .x = raw("ImGui_CalcItemWidth")(), .y = 0 });
    raw("ImGui_PopItemFlag")();
    if (listening) {
        root.tooltip("Escape cancels", .{});
        if (clicked or (raw("ImGui_IsMouseClicked")(c.ImGuiMouseButton_Left) and !root.isItemHovered())) listening_id = 0;
    } else if (clicked and !took) {
        listening_id = id;
        last_frame = frame;
    }

    const shown = label[0 .. std.mem.indexOf(u8, label, "##") orelse label.len];
    if (shown.len > 0) {
        raw("ImGui_SameLineEx")(0, raw("ImGui_GetStyle")().*.ItemInnerSpacing.x);
        root.text("{s}", .{shown});
    }
    return changed;
}

/// A chord input took keys this frame or last. Shortcuts should leave them alone.
pub fn listeningForKeys() bool {
    sync();
    return raw("ImGui_GetFrameCount")() - last_frame <= 1;
}

fn pressedKey(modifiers: bool) ?input.Key {
    for (std.enums.values(input.Key)) |key| {
        if (!modifiers and input.isModifier(key)) continue;
        if (raw("ImGui_IsKeyPressedEx")(imguiKey(key), false)) return key;
    }
    return null;
}

/// Like `Ctrl+Shift+F8`, with ImGui's key names, or a controller button like `LB`.
pub fn chordName(buf: []u8, chord: input.Chord) []const u8 {
    if (input.PadButton.of(chord.key)) |b| return b.label();
    const name = raw("ImGui_GetKeyName")(imguiKey(chord.key));
    const key: []const u8 = if (name != null) std.mem.span(@as([*:0]const u8, @ptrCast(name))) else @tagName(chord.key);
    const m = chord.mods;
    return std.fmt.bufPrint(buf, "{s}{s}{s}{s}{s}", .{
        if (m.ctrl) "Ctrl+" else "",
        if (m.shift) "Shift+" else "",
        if (m.alt) "Alt+" else "",
        if (m.super) "Super+" else "",
        key,
    }) catch @tagName(chord.key);
}

pub fn imguiKey(k: input.Key) c.ImGuiKey {
    return imgui_keys.get(k);
}

const imgui_keys: std.EnumArray(input.Key, c.ImGuiKey) = blk: {
    @setEvalBranchQuota(200_000);
    var t: std.EnumArray(input.Key, c.ImGuiKey) = undefined;
    for (std.enums.values(input.Key)) |k| t.set(k, @field(c, "ImGuiKey_" ++ imguiName(@tagName(k))));
    break :blk t;
};

fn imguiName(comptime name: []const u8) []const u8 {
    const renamed = std.StaticStringMap([]const u8).initComptime(.{
        .{ "left", "LeftArrow" },
        .{ "right", "RightArrow" },
        .{ "up", "UpArrow" },
        .{ "down", "DownArrow" },
        .{ "grave", "GraveAccent" },
        .{ "browser_back", "AppBack" },
        .{ "browser_forward", "AppForward" },
        .{ "gamepad_a", "GamepadFaceDown" },
        .{ "gamepad_b", "GamepadFaceRight" },
        .{ "gamepad_x", "GamepadFaceLeft" },
        .{ "gamepad_y", "GamepadFaceUp" },
        .{ "gamepad_left_shoulder", "GamepadL1" },
        .{ "gamepad_right_shoulder", "GamepadR1" },
        .{ "gamepad_left_trigger", "GamepadL2" },
        .{ "gamepad_right_trigger", "GamepadR2" },
        .{ "gamepad_left_stick", "GamepadL3" },
        .{ "gamepad_right_stick", "GamepadR3" },
    });
    return renamed.get(name) orelse root.pascalCase(name);
}

test "ImGui key names" {
    try std.testing.expectEqual(c.ImGuiKey_PageUp, imguiKey(.page_up));
    try std.testing.expectEqual(c.ImGuiKey_LeftArrow, imguiKey(.left));
    try std.testing.expectEqual(c.ImGuiKey_Keypad7, imguiKey(.keypad_7));
    try std.testing.expectEqual(c.ImGuiKey_0, imguiKey(.@"0"));
    try std.testing.expectEqual(c.ImGuiKey_Oem102, imguiKey(.oem_102));
    try std.testing.expectEqual(c.ImGuiKey_GamepadFaceDown, imguiKey(.gamepad_a));
    try std.testing.expectEqual(c.ImGuiKey_GamepadDpadLeft, imguiKey(.gamepad_dpad_left));
    try std.testing.expectEqual(c.ImGuiKey_GamepadStart, imguiKey(.gamepad_start));
    try std.testing.expectEqual(c.ImGuiKey_GamepadR3, imguiKey(.gamepad_right_stick));
}
