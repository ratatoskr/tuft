//! Feeds `tuft_input` events to ImGui.

const std = @import("std");

const input = @import("tuft_input");

const c = @import("root.zig").c;

pub fn feed(io: *c.ImGuiIO, event: input.Event) void {
    switch (event) {
        .key => |k| {
            if (input.isPad(k.key)) {
                // Triggers are analog to ImGui, so they come with the axes
                if (k.key == .gamepad_left_trigger or k.key == .gamepad_right_trigger) return;
                return c.ImGuiIO_AddKeyEvent(io, key(k.key), k.down);
            }
            c.ImGuiIO_AddKeyEvent(io, c.ImGuiMod_Ctrl, k.mods.ctrl);
            c.ImGuiIO_AddKeyEvent(io, c.ImGuiMod_Shift, k.mods.shift);
            c.ImGuiIO_AddKeyEvent(io, c.ImGuiMod_Alt, k.mods.alt);
            c.ImGuiIO_AddKeyEvent(io, c.ImGuiMod_Super, k.mods.super);
            c.ImGuiIO_AddKeyEvent(io, key(k.key), k.down);
        },
        .text => |ch| c.ImGuiIO_AddInputCharacter(io, ch),
        .mouse_move => |p| c.ImGuiIO_AddMousePosEvent(io, @floatFromInt(p.x), @floatFromInt(p.y)),
        .mouse_button => |b| c.ImGuiIO_AddMouseButtonEvent(io, button(b.button), b.down),
        // ImGui scrolls left for positive x
        .wheel => |w| c.ImGuiIO_AddMouseWheelEvent(io, -w.x, w.y),
        .mouse_leave => c.ImGuiIO_AddMousePosEvent(io, -std.math.floatMax(f32), -std.math.floatMax(f32)),
        .focus => |focused| c.ImGuiIO_AddFocusEvent(io, focused),
        .cursor => {},
        .gamepad_axes => |p| gamepadAxes(io, p),
    }
}

/// XInput's own dead zones, as fractions of full travel.
const stick_dead_zone = 7849.0 / 32767.0;
const trigger_dead_zone = 30.0 / 255.0;
/// Past this much an analog key counts as down.
const analog_down = 0.1;

fn gamepadAxes(io: *c.ImGuiIO, pads: input.PadAxes) void {
    if (pads.connected) {
        io.*.BackendFlags |= c.ImGuiBackendFlags_HasGamepad;
    } else {
        io.*.BackendFlags &= ~@as(c_int, c.ImGuiBackendFlags_HasGamepad);
    }
    const a = pads.axes;
    analog(io, c.ImGuiKey_GamepadL2, a.left_trigger, trigger_dead_zone);
    analog(io, c.ImGuiKey_GamepadR2, a.right_trigger, trigger_dead_zone);
    analog(io, c.ImGuiKey_GamepadLStickLeft, -a.left_x, stick_dead_zone);
    analog(io, c.ImGuiKey_GamepadLStickRight, a.left_x, stick_dead_zone);
    analog(io, c.ImGuiKey_GamepadLStickUp, a.left_y, stick_dead_zone);
    analog(io, c.ImGuiKey_GamepadLStickDown, -a.left_y, stick_dead_zone);
    analog(io, c.ImGuiKey_GamepadRStickLeft, -a.right_x, stick_dead_zone);
    analog(io, c.ImGuiKey_GamepadRStickRight, a.right_x, stick_dead_zone);
    analog(io, c.ImGuiKey_GamepadRStickUp, a.right_y, stick_dead_zone);
    analog(io, c.ImGuiKey_GamepadRStickDown, -a.right_y, stick_dead_zone);
}

fn analog(io: *c.ImGuiIO, k: c.ImGuiKey, value: f32, dead_zone: f32) void {
    const v = std.math.clamp((value - dead_zone) / (1 - dead_zone), 0, 1);
    c.ImGuiIO_AddKeyAnalogEvent(io, k, v > analog_down, v);
}

pub fn button(b: input.MouseButton) c_int {
    return switch (b) {
        .left => c.ImGuiMouseButton_Left,
        .right => c.ImGuiMouseButton_Right,
        .middle => c.ImGuiMouseButton_Middle,
        .x1 => 3,
        .x2 => 4,
    };
}

pub const key = @import("tuft_ui").imguiKey;
