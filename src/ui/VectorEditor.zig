//! ImVectorEditor bezier path editor. Global state, so one thread at a time.

const std = @import("std");

const root = @import("root.zig");
const c = root.c;
const raw = root.raw;
const Vec2 = root.Vec2;

pub const Tool = enum(c_int) { select, pen };

pub const HitPart = enum(c_int) { none, anchor, handle_in, handle_out, _ };

pub const HandleMode = enum(c_int) { corner, mirrored, aligned, free };

pub const Shape = enum(c_int) { circle, square, diamond };

/// For `Delegate.beginEdit`, like for undo.
pub const EditKind = enum(c_int) {
    move_anchor,
    move_handle,
    add_anchor,
    delete_anchor,
    add_handle,
    delete_handle,
    change_point_mode,
    path_operation,
    _,
};

pub const Anchor = extern struct {
    position: Vec2 = .{ 0, 0 },
    /// Relative to `position`.
    handle_in: Vec2 = .{ 0, 0 },
    handle_out: Vec2 = .{ 0, 0 },
    has_handle_in: bool = false,
    has_handle_out: bool = false,
    handle_mode: HandleMode = .corner,

    /// True if it changed.
    pub fn makeCorner(self: *Anchor) bool {
        return raw("ImVectorEditor_MakeCorner")(@ptrCast(self));
    }

    /// Lengths their own.
    pub fn makeAligned(self: *Anchor) bool {
        return raw("ImVectorEditor_MakeAligned")(@ptrCast(self));
    }

    /// Same length.
    pub fn makeMirrored(self: *Anchor) bool {
        return raw("ImVectorEditor_MakeMirrored")(@ptrCast(self));
    }

    pub fn addHandles(self: *Anchor, length: f32) bool {
        return raw("ImVectorEditor_AddHandles")(@ptrCast(self), length);
    }

    pub fn deleteHandles(self: *Anchor) bool {
        return raw("ImVectorEditor_DeleteHandles")(@ptrCast(self));
    }
};

comptime {
    std.debug.assert(@sizeOf(Anchor) == @sizeOf(c.ImVectorEditor_Anchor));
}

/// Its own move, turn and scale, then the canvas's pan and zoom.
pub const Transform = extern struct {
    pan: Vec2 = .{ 0, 0 },
    zoom: f32 = 1,
    object_pivot: Vec2 = .{ 0, 0 },
    object_translation: Vec2 = .{ 0, 0 },
    object_rotation_radians: f32 = 0,
    object_scale: Vec2 = .{ 1, 1 },

    pub fn localToCanvas(self: *const Transform, local: Vec2) Vec2 {
        var out: c.ImVec2 = undefined;
        raw("ImVectorEditor_LocalToCanvas")(@ptrCast(self), .{ .x = local[0], .y = local[1] }, &out);
        return .{ out.x, out.y };
    }

    pub fn canvasToLocal(self: *const Transform, canvas: Vec2) Vec2 {
        var out: c.ImVec2 = undefined;
        raw("ImVectorEditor_CanvasToLocal")(@ptrCast(self), .{ .x = canvas[0], .y = canvas[1] }, &out);
        return .{ out.x, out.y };
    }
};

comptime {
    std.debug.assert(@sizeOf(Transform) == @sizeOf(c.ImVectorEditor_Transform));
}

const rgba = root.rgba;

/// Colours are packed RGBA, sizes are pixels. The defaults are ImGuizmo's.
pub const Style = extern struct {
    background_color: u32 = rgba(31, 34, 42, 255),
    grid_color: u32 = rgba(255, 255, 255, 22),
    path_color: u32 = rgba(245, 245, 245, 255),
    preview_color: u32 = rgba(245, 245, 245, 120),
    anchor_color: u32 = rgba(255, 255, 255, 255),
    anchor_selected_color: u32 = rgba(255, 190, 84, 255),
    handle_color: u32 = rgba(112, 174, 255, 255),
    handle_line_color: u32 = rgba(112, 174, 255, 130),
    close_target_color: u32 = rgba(120, 240, 160, 255),
    path_thickness: f32 = 2,
    handle_line_thickness: f32 = 1,
    anchor_radius: f32 = 5,
    handle_radius: f32 = 3.5,
    anchor_shape: Shape = .square,
    handle_shape: Shape = .circle,
    hit_radius: f32 = 9,
    grid_step: f32 = 32,
};

comptime {
    std.debug.assert(@sizeOf(Style) == @sizeOf(c.ImVectorEditor_Style));
}

/// Told when an edit starts and ends, like for undo.
pub const Delegate = struct {
    ctx: *anyopaque,
    begin_edit: ?*const fn (ctx: *anyopaque, kind: EditKind, anchor: ?usize) void = null,
    end_edit: ?*const fn (ctx: *anyopaque) void = null,
};

pub const Config = struct {
    /// Pixels. 0 wide takes the window's width.
    canvas_size: Vec2 = .{ 0, 360 },
    tool: Tool = .pen,
    transform: Transform = .{},
    style: Style = .{},
    delegate: ?Delegate = null,
    show_grid: bool = true,
    /// Delete, Escape and the like while it's hovered or in use.
    allow_keyboard_shortcuts: bool = true,
    read_only: bool = false,
};

pub const Result = extern struct {
    changed: bool,
    /// Closed by the pen, or Enter.
    committed: bool,
    canceled: bool,
    path_closed: bool,
    hovered: bool,
    active: bool,
    wants_mouse_capture: bool,
    wants_keyboard_capture: bool,
    /// Add it to `Transform.pan` to follow.
    view_pan_delta: Vec2,
    /// Multiply `Transform.zoom` by it to follow.
    view_zoom_center_canvas: Vec2,
    view_zoom_factor: f32,
};

comptime {
    std.debug.assert(@sizeOf(Result) == @sizeOf(c.ImVectorEditor_Result));
}

pub const Path = struct {
    handle: *c.ImVectorEditor_Path,

    pub fn init() error{OutOfMemory}!Path {
        return .{ .handle = raw("ImVectorEditor_Path_Create")() orelse return error.OutOfMemory };
    }

    pub fn deinit(self: *Path) void {
        raw("ImVectorEditor_Path_Destroy")(self.handle);
        self.* = undefined;
    }

    /// Editable in place. Good until the path next changes.
    pub fn anchors(self: Path) []Anchor {
        const len = raw("ImVectorEditor_Path_Len")(self.handle);
        if (len == 0) return &.{};
        const ptr: [*]Anchor = @ptrCast(raw("ImVectorEditor_Path_Anchors")(self.handle));
        return ptr[0..len];
    }

    /// Left as it was if out of memory.
    pub fn setAnchors(self: Path, list: []const Anchor) error{OutOfMemory}!void {
        if (!raw("ImVectorEditor_Path_Set")(self.handle, @ptrCast(list.ptr), list.len)) return error.OutOfMemory;
    }

    pub fn isClosed(self: Path) bool {
        return raw("ImVectorEditor_Path_IsClosed")(self.handle);
    }

    pub fn setClosed(self: Path, closed: bool) void {
        raw("ImVectorEditor_Path_SetClosed")(self.handle, closed);
    }

    pub fn clear(self: Path) void {
        raw("ImVectorEditor_Path_Clear")(self.handle);
    }

    pub fn reverse(self: Path) void {
        raw("ImVectorEditor_Path_Reverse")(self.handle);
    }
};

pub const Editor = struct {
    handle: *c.ImVectorEditor_Editor,

    pub fn init() error{OutOfMemory}!Editor {
        return .{ .handle = raw("ImVectorEditor_Editor_Create")() orelse return error.OutOfMemory };
    }

    pub fn deinit(self: *Editor) void {
        raw("ImVectorEditor_Editor_Destroy")(self.handle);
        self.* = undefined;
    }

    pub fn draw(self: Editor, id: [:0]const u8, path: *Path, config: Config) Result {
        const Thunks = struct {
            fn begin(user: ?*anyopaque, kind: c_int, anchor: c_int) callconv(.c) void {
                const d: *const Delegate = @ptrCast(@alignCast(user.?));
                if (d.begin_edit) |f| f(d.ctx, @fromBackingInt(@intCast(kind)), if (anchor >= 0) @intCast(anchor) else null);
            }
            fn end(user: ?*anyopaque) callconv(.c) void {
                const d: *const Delegate = @ptrCast(@alignCast(user.?));
                if (d.end_edit) |f| f(d.ctx);
            }
        };
        var delegate: c.ImVectorEditor_Delegate = undefined;
        if (config.delegate) |*d| delegate = .{ .User = @constCast(d), .BeginEdit = Thunks.begin, .EndEdit = Thunks.end };
        const cfg: c.ImVectorEditor_Config = .{
            .CanvasSize = .{ .x = config.canvas_size[0], .y = config.canvas_size[1] },
            .Tool = @backingInt(config.tool),
            .Transform = @as(*const c.ImVectorEditor_Transform, @ptrCast(&config.transform)).*,
            .Style = @as(*const c.ImVectorEditor_Style, @ptrCast(&config.style)).*,
            .Delegate = if (config.delegate != null) &delegate else null,
            .ShowGrid = config.show_grid,
            .AllowKeyboardShortcuts = config.allow_keyboard_shortcuts,
            .ReadOnly = config.read_only,
        };
        var out: Result = undefined;
        raw("ImVectorEditor_Editor_Draw")(self.handle, root.str(id), path.handle, &cfg, @ptrCast(&out));
        return out;
    }

    pub fn clearSelection(self: Editor) void {
        raw("ImVectorEditor_Editor_ClearSelection")(self.handle);
    }

    pub fn selectedAnchor(self: Editor) ?usize {
        const i = raw("ImVectorEditor_Editor_GetSelectedAnchor")(self.handle);
        return if (i >= 0) @intCast(i) else null;
    }

    pub fn selectedCount(self: Editor) usize {
        return @intCast(raw("ImVectorEditor_Editor_GetSelectedAnchorCount")(self.handle));
    }

    pub fn selectedPart(self: Editor) HitPart {
        return @fromBackingInt(@intCast(raw("ImVectorEditor_Editor_GetSelectedPart")(self.handle)));
    }
};
