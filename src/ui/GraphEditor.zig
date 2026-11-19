//! ImGuizmo's node graph editor. Global state, so one thread at a time.

const std = @import("std");

const root = @import("root.zig");
const c = root.c;
const raw = root.raw;
const Vec2 = root.Vec2;

const rgba = root.rgba;

pub const Rect = extern struct {
    min: Vec2,
    max: Vec2,
};

/// The defaults are ImGuizmo's.
pub const Options = extern struct {
    /// Fractions of the editor.
    minimap: Rect = .{ .min = .{ 0.75, 0.8 }, .max = .{ 0.99, 0.99 } },
    background_color: u32 = rgba(40, 40, 40, 255),
    grid_color: u32 = rgba(0, 0, 0, 60),
    /// Every 10th line.
    grid_color2: u32 = rgba(0, 0, 0, 160),
    selected_node_border_color: u32 = rgba(255, 130, 30, 255),
    node_border_color: u32 = rgba(100, 100, 100, 0),
    quad_selection: u32 = rgba(255, 32, 32, 64),
    quad_selection_border: u32 = rgba(255, 32, 32, 255),
    /// For slots whose template gives no colour.
    default_slot_color: u32 = rgba(128, 128, 128, 255),
    frame_focus: u32 = rgba(64, 128, 255, 255),
    /// Pixels at zoom 1.
    line_thickness: f32 = 5,
    grid_size: f32 = 64,
    rounding: f32 = 3,
    /// Per mouse wheel notch.
    zoom_ratio: f32 = 0.1,
    /// Smaller is smoother.
    zoom_lerp_factor: f32 = 0.25,
    border_selection_thickness: f32 = 6,
    border_thickness: f32 = 6,
    node_slot_radius: f32 = 8,
    node_slot_hover_factor: f32 = 1.2,
    min_zoom: f32 = 0.2,
    max_zoom: f32 = 1.1,
    snap: f32 = 5,
    /// Straight lines with 45 degree bends, if not.
    display_links_as_curves: bool = true,
    allow_quad_selection: bool = true,
    render_grid: bool = true,
    draw_io_name_on_hover: bool = true,
};

comptime {
    std.debug.assert(@sizeOf(Options) == @sizeOf(c.ImGraphEditor_Options));
}

/// Keep one per editor, between frames.
pub const ViewState = extern struct {
    position: Vec2 = .{ 0, 0 },
    factor: f32 = 1,
    /// What `factor` is easing towards.
    factor_target: f32 = 1,
};

comptime {
    std.debug.assert(@sizeOf(ViewState) == @sizeOf(c.ImGraphEditor_ViewState));
}

pub const Template = struct {
    header_color: u32,
    background_color: u32,
    background_color_over: u32,
    /// At most 255.
    inputs: []const [*:0]const u8 = &.{},
    /// One per input, or empty for `Options.default_slot_color`.
    input_colors: []const u32 = &.{},
    outputs: []const [*:0]const u8 = &.{},
    output_colors: []const u32 = &.{},
};

pub const Node = struct {
    name: [*:0]const u8,
    template: usize,
    /// Unzoomed.
    rect: Rect,
    selected: bool = false,
};

/// Output to input, though ImGuizmo names them the other way.
pub const Link = extern struct {
    input_node: usize,
    input_slot: usize,
    output_node: usize,
    output_slot: usize,
};

comptime {
    std.debug.assert(@sizeOf(Link) == @sizeOf(c.ImGraphEditor_Link));
    std.debug.assert(@sizeOf(Rect) == @sizeOf(c.ImGuizmo_Rect));
}

/// `value` as a C struct laid out the same.
fn same(comptime T: type, value: anytype) T {
    return @as(*const T, @ptrCast(value)).*;
}

/// Moves the view to show these, once.
pub const Fit = enum(c_int) { none, all_nodes, selected_nodes };

pub const ShowOptions = struct {
    /// Off, it's drawn but can't be used.
    enabled: bool = true,
    /// Put back to `none` once done.
    fit: ?*Fit = null,
};

/// Fills the rest of the window. Names have to live until it returns.
pub fn show(graph: anytype, options: *const Options, view: *ViewState, how: ShowOptions) void {
    const T = @typeInfo(@TypeOf(graph)).pointer.child;
    var d = comptime delegate(T);
    d.User = @ptrCast(graph);
    raw("ImGraphEditor_Show")(&d, @ptrCast(options), @ptrCast(view), how.enabled, if (how.fit) |f| @ptrCast(f) else null);
}

/// Like when the graph's swapped for another.
pub fn clear() void {
    raw("ImGraphEditor_Clear")();
}

/// True when one changed.
pub fn editOptions(options: *Options) bool {
    return raw("ImGraphEditor_EditOptions")(@ptrCast(options));
}

fn delegate(comptime T: type) c.ImGraphEditor_Delegate {
    const none = std.math.maxInt(usize);
    const S = struct {
        fn self(user: ?*anyopaque) *T {
            return @ptrCast(@alignCast(user.?));
        }
        fn allowedLink(user: ?*anyopaque, from: usize, to: usize) callconv(.c) bool {
            if (!@hasDecl(T, "allowedLink")) return true;
            return self(user).allowedLink(from, to);
        }
        fn selectNode(user: ?*anyopaque, i: usize, selected: bool) callconv(.c) void {
            self(user).selectNode(i, selected);
        }
        fn moveSelectedNodes(user: ?*anyopaque, delta: c.ImVec2) callconv(.c) void {
            self(user).moveSelectedNodes(.{ delta.x, delta.y });
        }
        fn addLink(user: ?*anyopaque, in_node: usize, in_slot: usize, out_node: usize, out_slot: usize) callconv(.c) void {
            self(user).addLink(.{ .input_node = in_node, .input_slot = in_slot, .output_node = out_node, .output_slot = out_slot });
        }
        fn delLink(user: ?*anyopaque, i: usize) callconv(.c) void {
            self(user).deleteLink(i);
        }
        fn customDraw(user: ?*anyopaque, list: ?*c.ImDrawList, rect: c.ImGuizmo_Rect, i: usize) callconv(.c) void {
            self(user).customDraw(.{ .ptr = list.? }, same(Rect, &rect), i);
        }
        fn rightClick(user: ?*anyopaque, i: usize, input: usize, output: usize) callconv(.c) void {
            self(user).rightClick(opt(i), opt(input), opt(output));
        }
        fn opt(i: usize) ?usize {
            return if (i == none) null else i;
        }
        fn templateCount(user: ?*anyopaque) callconv(.c) usize {
            return self(user).templateCount();
        }
        fn template(user: ?*anyopaque, i: usize, out: [*c]c.ImGraphEditor_Template) callconv(.c) void {
            const t: Template = self(user).template(i);
            out.* = .{
                .HeaderColor = t.header_color,
                .BackgroundColor = t.background_color,
                .BackgroundColorOver = t.background_color_over,
                .InputCount = @intCast(t.inputs.len),
                .InputNames = @ptrCast(@constCast(t.inputs.ptr)),
                .InputColors = if (t.input_colors.len > 0) @constCast(t.input_colors.ptr) else null,
                .OutputCount = @intCast(t.outputs.len),
                .OutputNames = @ptrCast(@constCast(t.outputs.ptr)),
                .OutputColors = if (t.output_colors.len > 0) @constCast(t.output_colors.ptr) else null,
            };
        }
        fn nodeCount(user: ?*anyopaque) callconv(.c) usize {
            return self(user).nodeCount();
        }
        fn node(user: ?*anyopaque, i: usize, out: [*c]c.ImGraphEditor_Node) callconv(.c) void {
            const n: Node = self(user).node(i);
            out.* = .{ .Name = @ptrCast(n.name), .TemplateIndex = n.template, .Rect = same(c.ImGuizmo_Rect, &n.rect), .Selected = n.selected };
        }
        fn linkCount(user: ?*anyopaque) callconv(.c) usize {
            return self(user).linkCount();
        }
        fn link(user: ?*anyopaque, i: usize, out: [*c]c.ImGraphEditor_Link) callconv(.c) void {
            const l: Link = self(user).link(i);
            out.* = same(c.ImGraphEditor_Link, &l);
        }
    };
    inline for (.{ "templateCount", "template", "nodeCount", "node", "linkCount", "link", "selectNode", "moveSelectedNodes", "addLink", "deleteLink" }) |name| {
        if (!@hasDecl(T, name)) @compileError(@typeName(T) ++ " needs `pub fn " ++ name ++ "` for the graph editor");
    }
    return .{
        .User = null,
        .AllowedLink = S.allowedLink,
        .SelectNode = S.selectNode,
        .MoveSelectedNodes = S.moveSelectedNodes,
        .AddLink = S.addLink,
        .DelLink = S.delLink,
        .CustomDraw = if (@hasDecl(T, "customDraw")) S.customDraw else null,
        .RightClick = if (@hasDecl(T, "rightClick")) S.rightClick else null,
        .GetTemplateCount = S.templateCount,
        .GetTemplate = S.template,
        .GetNodeCount = S.nodeCount,
        .GetNode = S.node,
        .GetLinkCount = S.linkCount,
        .GetLink = S.link,
    };
}
