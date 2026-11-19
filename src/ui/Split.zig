//! Two child windows with a draggable bar. Call both halves every frame, in order.

const Split = @This();

const std = @import("std");

const root = @import("root.zig");
const c = root.c;
const raw = root.raw;

pub const Direction = enum {
    across,
    down,
};

direction: Direction = .across,
/// How much of the room the first part gets, 0 to 1.
ratio: f32 = 0.5,
/// Unscaled. Dragging won't make either part smaller, if there's room.
min: f32 = 40,
/// In pixels, set by `first`.
origin: c.ImVec2 = .{ .x = 0, .y = 0 },
first_size: f32 = 0,
length: f32 = 0,
total: f32 = 0,

/// Unscaled.
const bar = 4;

pub fn first(self: *Split, id: [:0]const u8) ?root.Child {
    const avail = raw("ImGui_GetContentRegionAvail")();
    self.origin = raw("ImGui_GetCursorScreenPos")();
    const across = self.direction == .across;
    const total = @max(0, (if (across) avail.x else avail.y) - root.scaled(bar));
    self.total = total;
    self.length = if (across) avail.y else avail.x;
    const min = root.scaled(self.min);
    self.first_size = @round(if (total > 2 * min) std.math.clamp(self.ratio * total, min, total - min) else self.ratio * total);
    return root.child(id, if (across) .{ self.first_size, self.length } else .{ self.length, self.first_size }, .{});
}

pub fn second(self: *Split, id: [:0]const u8) ?root.Child {
    const across = self.direction == .across;
    const thick = root.scaled(bar);
    const at: c.ImVec2 = if (across)
        .{ .x = self.origin.x + self.first_size, .y = self.origin.y }
    else
        .{ .x = self.origin.x, .y = self.origin.y + self.first_size };
    raw("ImGui_SetCursorScreenPos")(at);
    const size: c.ImVec2 = if (across) .{ .x = thick, .y = self.length } else .{ .x = self.length, .y = thick };
    _ = raw("ImGui_InvisibleButton")(root.str("##split"), size, 0);
    const active = raw("ImGui_IsItemActive")();
    if (active or raw("ImGui_IsItemHovered")(0)) {
        raw("ImGui_SetMouseCursor")(if (across) c.ImGuiMouseCursor_ResizeEW else c.ImGuiMouseCursor_ResizeNS);
        const colour = raw("ImGui_GetColorU32")(if (active) c.ImGuiCol_SeparatorActive else c.ImGuiCol_SeparatorHovered);
        raw("ImDrawList_AddRectFilled")(raw("ImGui_GetWindowDrawList")(), at, .{ .x = at.x + size.x, .y = at.y + size.y }, colour);
    }
    if (active) {
        const delta = raw("ImGui_GetIO")().*.MouseDelta;
        if (self.total > 0) self.ratio = std.math.clamp(self.ratio + (if (across) delta.x else delta.y) / self.total, 0, 1);
    }
    raw("ImGui_SetCursorScreenPos")(if (across)
        .{ .x = at.x + thick, .y = at.y }
    else
        .{ .x = at.x, .y = at.y + thick });
    return root.child(id, if (across) .{ 0, self.length } else .{ self.length, 0 }, .{});
}
