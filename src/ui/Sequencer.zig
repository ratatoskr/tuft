//! ImSequencer timeline. Global state, so one thread at a time.

const std = @import("std");

const root = @import("root.zig");
const c = root.c;
const raw = root.raw;

pub const Item = struct {
    start: *i32,
    end: *i32,
    /// Index into the item types, for `itemTypeName`.
    kind: usize = 0,
    /// Packed RGBA.
    color: u32 = 0xFFAA8080,
};

pub const Rect = struct {
    min: root.Vec2,
    max: root.Vec2,

    fn of(r: c.ImGuizmo_Rect) Rect {
        return .{ .min = .{ r.Min.x, r.Min.y }, .max = .{ r.Max.x, r.Max.y } };
    }
};

pub const CustomDraw = struct {
    draw_list: root.DrawList,
    rect: Rect,
    legend: Rect,
    clip: Rect,
    legend_clip: Rect,
};

pub const CustomDrawCompact = struct {
    draw_list: root.DrawList,
    rect: Rect,
    clip: Rect,
};

pub const Options = struct {
    edit_start_end: bool = false,
    change_frame: bool = false,
    /// Needs `add`.
    add: bool = false,
    /// Needs `delete`.
    delete: bool = false,
    /// Needs `copy` and `paste`.
    copy_paste: bool = false,

    pub const all: Options = .{ .edit_start_end = true, .change_frame = true, .add = true, .delete = true, .copy_paste = true };

    fn int(self: Options) c_int {
        var out: c_int = 0;
        if (self.edit_start_end) out |= c.ImSequencer_Options_EditStartEnd;
        if (self.change_frame) out |= c.ImSequencer_Options_ChangeFrame;
        if (self.add) out |= c.ImSequencer_Options_Add;
        if (self.delete) out |= c.ImSequencer_Options_Del;
        if (self.copy_paste) out |= c.ImSequencer_Options_CopyPaste;
        return out;
    }
};

/// Keep one per sequencer, between frames.
pub const State = struct {
    current_frame: i32 = 0,
    expanded: bool = true,
    selected: ?usize = null,
    /// Leftmost frame showing.
    first_frame: i32 = 0,
    focused: bool = false,
};

/// True when an item's picked this frame. Labels have to live until it returns.
pub fn draw(model: anytype, state: *State, options: Options) bool {
    const T = @typeInfo(@TypeOf(model)).pointer.child;
    const table = comptime interface(T);
    var it = table;
    it.User = @ptrCast(model);
    var selected: c_int = if (state.selected) |s| @intCast(s) else -1;
    const picked = raw("ImSequencer_Sequencer")(&it, &state.focused, &state.current_frame, &state.expanded, &selected, &state.first_frame, options.int());
    state.selected = if (selected >= 0) @intCast(selected) else null;
    return picked;
}

fn interface(comptime T: type) c.ImSequencer_Interface {
    const S = struct {
        fn self(user: ?*anyopaque) *T {
            return @ptrCast(@alignCast(user.?));
        }
        fn index(i: c_int) usize {
            return @intCast(i);
        }
        fn frameMin(user: ?*anyopaque) callconv(.c) c_int {
            return self(user).frameMin();
        }
        fn frameMax(user: ?*anyopaque) callconv(.c) c_int {
            return self(user).frameMax();
        }
        fn itemCount(user: ?*anyopaque) callconv(.c) c_int {
            return @intCast(self(user).itemCount());
        }
        fn get(user: ?*anyopaque, i: c_int, start: [*c][*c]c_int, end: [*c][*c]c_int, kind: [*c]c_int, color: [*c]c_uint) callconv(.c) void {
            const item = self(user).item(index(i));
            if (start != null) start.* = item.start;
            if (end != null) end.* = item.end;
            if (kind != null) kind.* = @intCast(item.kind);
            if (color != null) color.* = item.color;
        }
        fn beginEdit(user: ?*anyopaque, i: c_int) callconv(.c) void {
            self(user).beginEdit(index(i));
        }
        fn endEdit(user: ?*anyopaque) callconv(.c) void {
            self(user).endEdit();
        }
        fn itemTypeCount(user: ?*anyopaque) callconv(.c) c_int {
            return @intCast(self(user).itemTypeCount());
        }
        fn itemTypeName(user: ?*anyopaque, i: c_int) callconv(.c) [*c]const u8 {
            return @ptrCast(self(user).itemTypeName(index(i)).ptr);
        }
        fn itemLabel(user: ?*anyopaque, i: c_int) callconv(.c) [*c]const u8 {
            return @ptrCast(self(user).itemLabel(index(i)).ptr);
        }
        fn add(user: ?*anyopaque, kind: c_int) callconv(.c) void {
            self(user).add(index(kind));
        }
        fn delete(user: ?*anyopaque, i: c_int) callconv(.c) void {
            self(user).delete(index(i));
        }
        fn duplicate(user: ?*anyopaque, i: c_int) callconv(.c) void {
            self(user).duplicate(index(i));
        }
        fn copy(user: ?*anyopaque) callconv(.c) void {
            self(user).copy();
        }
        fn paste(user: ?*anyopaque) callconv(.c) void {
            self(user).paste();
        }
        fn customHeight(user: ?*anyopaque, i: c_int) callconv(.c) usize {
            return @intFromFloat(@max(0, self(user).customHeight(index(i))));
        }
        fn doubleClick(user: ?*anyopaque, i: c_int) callconv(.c) void {
            self(user).doubleClick(index(i));
        }
        fn customDraw(user: ?*anyopaque, i: c_int, list: ?*c.ImDrawList, rect: c.ImGuizmo_Rect, legend: c.ImGuizmo_Rect, clip: c.ImGuizmo_Rect, legend_clip: c.ImGuizmo_Rect) callconv(.c) void {
            self(user).customDraw(index(i), .{ .draw_list = .{ .ptr = list.? }, .rect = .of(rect), .legend = .of(legend), .clip = .of(clip), .legend_clip = .of(legend_clip) });
        }
        fn customDrawCompact(user: ?*anyopaque, i: c_int, list: ?*c.ImDrawList, rect: c.ImGuizmo_Rect, clip: c.ImGuizmo_Rect) callconv(.c) void {
            self(user).customDrawCompact(index(i), .{ .draw_list = .{ .ptr = list.? }, .rect = .of(rect), .clip = .of(clip) });
        }
    };
    inline for (.{ "frameMin", "frameMax", "itemCount", "item" }) |name| {
        if (!@hasDecl(T, name)) @compileError(@typeName(T) ++ " needs `pub fn " ++ name ++ "` for the sequencer");
    }
    return .{
        .User = null,
        .GetFrameMin = S.frameMin,
        .GetFrameMax = S.frameMax,
        .GetItemCount = S.itemCount,
        .Get = S.get,
        .BeginEdit = if (@hasDecl(T, "beginEdit")) S.beginEdit else null,
        .EndEdit = if (@hasDecl(T, "endEdit")) S.endEdit else null,
        .GetItemTypeCount = if (@hasDecl(T, "itemTypeCount")) S.itemTypeCount else null,
        .GetItemTypeName = if (@hasDecl(T, "itemTypeName")) S.itemTypeName else null,
        .GetItemLabel = if (@hasDecl(T, "itemLabel")) S.itemLabel else null,
        .Add = if (@hasDecl(T, "add")) S.add else null,
        .Del = if (@hasDecl(T, "delete")) S.delete else null,
        .Duplicate = if (@hasDecl(T, "duplicate")) S.duplicate else null,
        .Copy = if (@hasDecl(T, "copy")) S.copy else null,
        .Paste = if (@hasDecl(T, "paste")) S.paste else null,
        .GetCustomHeight = if (@hasDecl(T, "customHeight")) S.customHeight else null,
        .DoubleClick = if (@hasDecl(T, "doubleClick")) S.doubleClick else null,
        .CustomDraw = if (@hasDecl(T, "customDraw")) S.customDraw else null,
        .CustomDrawCompact = if (@hasDecl(T, "customDrawCompact")) S.customDrawCompact else null,
    };
}
