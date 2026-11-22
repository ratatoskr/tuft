//! ImGuizmo bindings. Global state, so one thread at a time.

const std = @import("std");

const root = @import("root.zig");
const c = root.c;
const raw = root.raw;
const Vec2 = root.Vec2;
const math = @import("tuft_math");
const Vec3 = math.Vec3;

/// Row-major for row vectors, like ImGuizmo wants.
pub const Matrix = math.Mat4;

pub const identity: Matrix = .identity;

/// Mix them, or use the sets below.
pub const Operation = bitpack struct(u32) {
    translate_x: bool = false,
    translate_y: bool = false,
    translate_z: bool = false,
    rotate_x: bool = false,
    rotate_y: bool = false,
    rotate_z: bool = false,
    rotate_screen: bool = false,
    scale_x: bool = false,
    scale_y: bool = false,
    scale_z: bool = false,
    bounds: bool = false,
    scale_xu: bool = false,
    scale_yu: bool = false,
    scale_zu: bool = false,
    _: u18 = 0,

    pub const translate: Operation = .{ .translate_x = true, .translate_y = true, .translate_z = true };
    pub const rotate: Operation = .{ .rotate_x = true, .rotate_y = true, .rotate_z = true, .rotate_screen = true };
    pub const scale: Operation = .{ .scale_x = true, .scale_y = true, .scale_z = true };
    /// Scale handles that sit with the others in `universal`.
    pub const scale_universal: Operation = .{ .scale_xu = true, .scale_yu = true, .scale_zu = true };
    pub const universal: Operation = translate.with(rotate).with(scale_universal);

    pub fn with(a: Operation, b: Operation) Operation {
        return @bitCast(@as(u32, @bitCast(a)) | @as(u32, @bitCast(b)));
    }

    fn int(self: Operation) c_uint {
        return @as(u32, @bitCast(self));
    }
};

/// The object's own axes, or the world's.
pub const Mode = enum(c_int) { local, world };

pub const MoveType = enum(c_int) {
    none,
    move_x,
    move_y,
    move_z,
    move_yz,
    move_zx,
    move_xy,
    move_screen,
    rotate_x,
    rotate_y,
    rotate_z,
    rotate_screen,
    scale_x,
    scale_y,
    scale_z,
    scale_xyz,
    _,
};

/// Index into `Style.colors`.
pub const Color = enum {
    direction_x,
    direction_y,
    direction_z,
    plane_x,
    plane_y,
    plane_z,
    selection,
    inactive,
    translation_line,
    scale_line,
    rotation_using_border,
    rotation_using_fill,
    hatched_axis_lines,
    text,
    text_shadow,
};

pub const Style = extern struct {
    translation_line_thickness: f32,
    translation_line_arrow_size: f32,
    rotation_line_thickness: f32,
    rotation_outer_line_thickness: f32,
    scale_line_thickness: f32,
    scale_line_circle_size: f32,
    hatched_axis_line_thickness: f32,
    center_circle_size: f32,
    colors: [@typeInfo(Color).@"enum".field_names.len]root.Color,

    pub fn color(self: *Style, which: Color) *root.Color {
        return &self.colors[@backingInt(which)];
    }
};

comptime {
    std.debug.assert(@sizeOf(Style) == @sizeOf(c.ImGuizmo_Style));
}

/// Change it in place, it's kept.
pub fn style() *Style {
    return @ptrCast(raw("ImGuizmo_GetStyle")());
}

/// Once a frame, before anything else here.
pub fn beginFrame() void {
    raw("ImGuizmo_BeginFrame")();
}

/// Null means the current window's.
pub fn setDrawList(list: ?root.DrawList) void {
    raw("ImGuizmo_SetDrawlist")(if (list) |l| l.ptr else @ptrCast(raw("ImGui_GetWindowDrawList")()));
}

/// In pixels.
pub fn setRect(pos: Vec2, size: Vec2) void {
    raw("ImGuizmo_SetRect")(pos[0], pos[1], size[0], size[1]);
}

pub fn setOrthographic(on: bool) void {
    raw("ImGuizmo_SetOrthographic")(on);
}

/// Off, they're drawn greyed out and can't be dragged.
pub fn enable(on: bool) void {
    raw("ImGuizmo_Enable")(on);
}

pub const ManipulateOptions = struct {
    /// Gets what this frame's drag did, on its own.
    delta: ?*Matrix = null,
    /// Units for translate, degrees for rotate, factor for scale. Only x counts for the last two.
    snap: ?*const Vec3 = null,
    /// Min and max corners of a box around the object, for `bounds`.
    local_bounds: ?*const [2]Vec3 = null,
    bounds_snap: ?*const Vec3 = null,
};

/// True when `matrix` changed.
pub fn manipulate(view: *const Matrix, projection: *const Matrix, operation: Operation, mode: Mode, matrix: *Matrix, options: ManipulateOptions) bool {
    return raw("ImGuizmo_Manipulate")(
        floats(view),
        floats(projection),
        operation.int(),
        @backingInt(mode),
        floats(matrix),
        if (options.delta) |d| floats(d) else null,
        if (options.snap) |s| floats(s) else null,
        if (options.local_bounds) |b| floats(b) else null,
        if (options.bounds_snap) |s| floats(s) else null,
    );
}

/// Camera cube. `length` is the camera's distance, `background` packed RGBA.
pub fn viewManipulate(view: *Matrix, length: f32, pos: Vec2, size: Vec2, background: u32) void {
    raw("ImGuizmo_ViewManipulate")(floats(view), length, vec2(pos), vec2(size), background);
}

pub fn isOver() bool {
    return raw("ImGuizmo_IsOver")();
}

pub fn isOverOperation(operation: Operation) bool {
    return raw("ImGuizmo_IsOverOperation")(operation.int());
}

/// `position` is world space.
pub fn isOverPoint(position: Vec3, radius: f32) bool {
    var p = position;
    return raw("ImGuizmo_IsOverPoint")(floats(&p), radius);
}

pub fn isUsing() bool {
    return raw("ImGuizmo_IsUsing")();
}

pub fn isUsingAny() bool {
    return raw("ImGuizmo_IsUsingAny")();
}

pub fn isUsingViewManipulate() bool {
    return raw("ImGuizmo_IsUsingViewManipulate")();
}

pub fn isViewManipulateHovered() bool {
    return raw("ImGuizmo_IsViewManipulateHovered")();
}

pub fn activeMoveType() MoveType {
    return @fromBackingInt(@intCast(raw("ImGuizmo_GetActiveMoveType")()));
}

pub fn hoveredMoveType() MoveType {
    return @fromBackingInt(@intCast(raw("ImGuizmo_GetHoveredMoveType")()));
}

pub const Components = struct {
    translation: Vec3 = .zero,
    /// Degrees.
    rotation: Vec3 = .zero,
    scale: Vec3 = .one,
};

pub fn decompose(matrix: *const Matrix) Components {
    var out: Components = .{};
    raw("ImGuizmo_DecomposeMatrixToComponents")(floats(matrix), floats(&out.translation), floats(&out.rotation), floats(&out.scale));
    return out;
}

pub fn recompose(parts: Components) Matrix {
    var out: Matrix = undefined;
    raw("ImGuizmo_RecomposeMatrixFromComponents")(floats(&parts.translation), floats(&parts.rotation), floats(&parts.scale), floats(&out));
    return out;
}

pub fn drawGrid(view: *const Matrix, projection: *const Matrix, matrix: *const Matrix, size: f32) void {
    raw("ImGuizmo_DrawGrid")(floats(view), floats(projection), floats(matrix), size);
}

/// For trying it out.
pub fn drawCubes(view: *const Matrix, projection: *const Matrix, matrices: []const Matrix) void {
    raw("ImGuizmo_DrawCubes")(floats(view), floats(projection), @ptrCast(@constCast(matrices.ptr)), @intCast(matrices.len));
}

pub fn drawAxes(view: *const Matrix, projection: *const Matrix, matrices: []const Matrix) void {
    raw("ImGuizmo_DrawAxes")(floats(view), floats(projection), @ptrCast(@constCast(matrices.ptr)), @intCast(matrices.len));
}

/// Like `ui.id`, for more than one in a window.
pub fn id(value: anytype) Id {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .int, .comptime_int => raw("ImGuizmo_PushIDInt")(@intCast(value)),
        .pointer => |p| if (p.size == .one and @typeInfo(p.child) == .array and @typeInfo(p.child).array.sentinel() == 0) {
            raw("ImGuizmo_PushIDStr")(@ptrCast(value));
        } else if (p.size == .slice and p.sentinel() == 0) {
            raw("ImGuizmo_PushIDStr")(@ptrCast(value.ptr));
        } else {
            raw("ImGuizmo_PushIDPtr")(@ptrCast(value));
        },
        else => @compileError("gizmo.id takes a string, integer or pointer, not " ++ @typeName(T)),
    }
    return .{};
}

pub const Id = struct {
    pub fn end(_: Id) void {
        raw("ImGuizmo_PopID")();
    }
};

/// Fraction of the view's height. Default 0.1.
pub fn setSize(value: f32) void {
    raw("ImGuizmo_SetGizmoSizeClipSpace")(value);
}

/// On by default.
pub fn allowAxisFlip(on: bool) void {
    raw("ImGuizmo_AllowAxisFlip")(on);
}

/// Hides an axis once it's this close to pointing at the camera.
pub fn setAxisLimit(value: f32) void {
    raw("ImGuizmo_SetAxisLimit")(value);
}

pub fn setAxisMask(x: bool, y: bool, z: bool) void {
    raw("ImGuizmo_SetAxisMask")(x, y, z);
}

/// Hides a plane once it's this close to edge on.
pub fn setPlaneLimit(value: f32) void {
    raw("ImGuizmo_SetPlaneLimit")(value);
}

pub const Ray = struct {
    origin: math.Vec4,
    direction: math.Vec4,
};

/// For picking. `rect` is the view's, in pixels.
pub fn mouseRay(view: *const Matrix, projection: *const Matrix, mouse: Vec2, rect_pos: Vec2, rect_size: Vec2) Ray {
    var ray: Ray = undefined;
    raw("ImGuizmo_ComputeMouseRay")(view, projection, vec2(mouse), vec2(rect_pos), vec2(rect_size), floats(&ray.origin), floats(&ray.direction));
    return ray;
}

/// ImGuizmo takes plain `float*`, mutable even where it only reads.
fn floats(p: anytype) [*c]f32 {
    return @ptrCast(@constCast(p));
}

fn vec2(v: Vec2) c.ImVec2 {
    return .{ .x = v[0], .y = v[1] };
}

test "operations match" {
    try std.testing.expectEqual(c.ImGuizmo_Operation_ScaleZU, @as(u32, @bitCast(Operation{ .scale_zu = true })));
    try std.testing.expectEqual(c.ImGuizmo_Operation_TranslateX | c.ImGuizmo_Operation_TranslateY | c.ImGuizmo_Operation_TranslateZ, Operation.translate.int());
    try std.testing.expectEqual(c.ImGuizmo_Color_COUNT, @typeInfo(Color).@"enum".field_names.len);
}
