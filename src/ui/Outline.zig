//! Rows drawn like a tree, that fold and drag about with a `Reorder`: an address list's groups, a
//! page's sections and what's in them.

const std = @import("std");

const root = @import("root.zig");
const raw = root.raw;
const c = root.c;
const Reorder = root.Reorder;

pub const Look = enum {
    /// Nothing in it to open.
    leaf,
    /// An arrow that opens it.
    folds,
    /// A bar across the row, like a section's heading.
    heading,
};

/// The row's label, as a tree node across the whole row so it drags from anywhere other widgets
/// aren't. In a table, draw what's left of it first and the rest after. `it.open` is what it
/// shows. True if it was clicked open or shut.
pub fn node(reorder: *Reorder, it: Reorder.Item, look: Look) bool {
    var flags: c.ImGuiTreeNodeFlags = c.ImGuiTreeNodeFlags_SpanAllColumns | c.ImGuiTreeNodeFlags_AllowOverlap |
        c.ImGuiTreeNodeFlags_FramePadding | c.ImGuiTreeNodeFlags_NoTreePushOnOpen;
    switch (look) {
        .leaf => flags |= c.ImGuiTreeNodeFlags_Leaf,
        .folds => {},
        .heading => flags |= c.ImGuiTreeNodeFlags_Framed | c.ImGuiTreeNodeFlags_LabelSpanAllColumns,
    }
    raw("ImGui_SetNextItemOpen")(it.open, c.ImGuiCond_Always);
    const open = raw("ImGui_TreeNodeEx")(root.str(root.format("{s}###node", .{it.label})), flags);
    reorder.item(it);
    return look != .leaf and open != it.open;
}

/// Just the arrow, the same as `node`'s, for rows whose label is drawn some other way, like ones
/// picked with a `Selection`. Put the label after it on the same line. True if it was clicked.
pub fn arrow(open: bool) bool {
    raw("ImGui_SetNextItemOpen")(open, c.ImGuiCond_Always);
    const now = raw("ImGui_TreeNodeEx")("##fold", c.ImGuiTreeNodeFlags_NoTreePushOnOpen | c.ImGuiTreeNodeFlags_FramePadding);
    root.sameLineWith(0, 0);
    return now != open;
}

/// Room for an arrow, so labels without one line up with ones that have one.
pub fn noArrow() void {
    root.alignTextToFramePadding();
    raw("ImGui_Dummy")(.{ .x = raw("ImGui_GetTreeNodeToLabelSpacing")(), .y = root.frameHeight() });
    root.sameLineWith(0, 0);
}

/// For what an open row shows under it, lined up with its label so it reads as part of it. `end`
/// it after.
pub fn inside() Inside {
    const by = raw("ImGui_GetTreeNodeToLabelSpacing")();
    raw("ImGui_IndentEx")(by);
    return .{ .by = by };
}

pub const Inside = struct {
    by: f32,

    pub fn end(self: Inside) void {
        raw("ImGui_UnindentEx")(self.by);
    }
};
