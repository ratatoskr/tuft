//! Mouse row selection, done once a frame since ImGui won't hover other rows while one is held.

const Drag = @This();

const ui = @import("tuft_ui");

dragging: bool = false,
pressed: ?struct { extend: bool } = null,

/// Call right after a row's `InvisibleButton`.
pub fn press(self: *Drag) void {
    if (ui.isItemHovered() and ui.isMouseClicked(.left)) {
        self.pressed = .{ .extend = ui.mods().shift };
    }
}

pub const Update = struct {
    row: usize,
    x: f32,
    /// False if shift was held, which extends instead.
    restart: bool,
};

/// Call after drawing the rows. `origin` is row 0's cursor position.
pub fn update(self: *Drag, origin: ui.Vec2, stride: f32, count: usize) ?Update {
    defer self.pressed = null;
    var restart = false;
    if (self.pressed) |p| {
        self.dragging = true;
        restart = !p.extend;
    }
    if (!self.dragging) return null;
    if (!ui.isMouseDown(.left)) {
        self.dragging = false;
        return null;
    }
    const mouse = ui.getMousePos();
    autoScroll(mouse[1], stride);
    return .{ .row = rowAt(mouse[1] - origin[1], stride, count), .x = mouse[0] - origin[0], .restart = restart };
}

pub fn rowAt(y: f32, stride: f32, count: usize) usize {
    if (count == 0 or y <= 0) return 0;
    const row: usize = @intFromFloat(y / stride);
    return @min(row, count - 1);
}

fn autoScroll(mouse_y: f32, stride: f32) void {
    const top = ui.getWindowPos()[1];
    const bottom = top + ui.getWindowHeight();
    const past = if (mouse_y < top) mouse_y - top else if (mouse_y > bottom) mouse_y - bottom else return;
    const step = @max(1, @min(10, @abs(past) / stride));
    const y = ui.getScrollY() + (if (past < 0) -step else step) * stride * 0.5;
    ui.setScrollY(@max(0, y));
}

test rowAt {
    const std = @import("std");
    try std.testing.expectEqual(0, rowAt(-50, 10, 5));
    try std.testing.expectEqual(2, rowAt(25, 10, 5));
    try std.testing.expectEqual(4, rowAt(500, 10, 5));
}
