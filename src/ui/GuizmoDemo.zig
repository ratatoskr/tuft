//! Demo windows for ImGuizmo's widgets, like `showDemoWindow`. Call `deinit` when done.

const GuizmoDemo = @This();

const std = @import("std");

const ui = @import("root.zig");
const gizmo = @import("gizmo.zig");
const Sequencer = @import("Sequencer.zig");
const GraphEditor = @import("GraphEditor.zig");
const VectorEditor = @import("VectorEditor.zig");

gizmo_open: bool = false,
sequencer_open: bool = false,
graph_open: bool = false,
vector_open: bool = false,

scene: Scene = .{},
clips: Clips = .{},
timeline: Sequencer.State = .{ .current_frame = 100 },
graph: Graph = .{},
graph_view: GraphEditor.ViewState = .{},
graph_options: GraphEditor.Options = .{},
fit: GraphEditor.Fit = .all_nodes,
vector: ?Vector = null,
vector_tool: usize = 1,
vector_transform: VectorEditor.Transform = .{},

pub fn menuItems(self: *GuizmoDemo) void {
    _ = ui.menuItem("Gizmo demo", .{ .checked = &self.gizmo_open });
    _ = ui.menuItem("Sequencer demo", .{ .checked = &self.sequencer_open });
    _ = ui.menuItem("Graph editor demo", .{ .checked = &self.graph_open });
    _ = ui.menuItem("Vector editor demo", .{ .checked = &self.vector_open });
}

/// Once a frame, on the thread drawing it.
pub fn draw(self: *GuizmoDemo) void {
    if (self.gizmo_open) self.drawGizmo();
    if (self.sequencer_open) self.drawSequencer();
    if (self.graph_open) self.drawGraph();
    if (self.vector_open) self.drawVector() else self.freeVector();
}

pub fn deinit(self: *GuizmoDemo) void {
    self.freeVector();
}

const operations = [_][:0]const u8{ "Translate", "Rotate", "Scale", "Universal", "Bounds" };
const modes = [_][:0]const u8{ "Local", "World" };

const Scene = struct {
    cubes: [3]gizmo.Matrix = .{ at(-2, 0, 0), at(0, 0, 0), at(2, 0, 1) },
    picked: usize = 1,
    view: ?gizmo.Matrix = null,
    operation: usize = 0,
    mode: usize = 1,
    snap: bool = false,
    /// Over the scene last frame, so dragging there doesn't move the window.
    hovered: bool = false,

    fn at(x: f32, y: f32, z: f32) gizmo.Matrix {
        var m = gizmo.identity;
        m[12] = x;
        m[13] = y;
        m[14] = z;
        return m;
    }
};

const camera_distance = 8;

fn drawGizmo(self: *GuizmoDemo) void {
    const s = &self.scene;
    gizmo.beginFrame();
    const win = ui.window("Gizmo demo", .{ .open = &self.gizmo_open, .size = .{ 720, 560 }, .flags = .{ .no_move = s.hovered } }) orelse return;
    defer win.end();

    _ = ui.combo("Operation", &s.operation, &operations);
    _ = ui.combo("Mode", &s.mode, &modes);
    _ = ui.checkbox("Snap", &s.snap);
    ui.sameLine();
    var picked: i32 = @intCast(s.picked);
    if (ui.slider("Cube", &picked, 0, s.cubes.len - 1)) s.picked = @intCast(picked);
    const model = &s.cubes[s.picked];
    var parts = gizmo.decompose(model);
    var edited = ui.raw("ImGui_DragFloat3")(ui.str("Translation"), &parts.translation);
    edited = ui.raw("ImGui_DragFloat3")(ui.str("Rotation"), &parts.rotation) or edited;
    edited = ui.raw("ImGui_DragFloat3")(ui.str("Scale"), &parts.scale) or edited;
    if (edited) model.* = gizmo.recompose(parts);
    ui.textDisabled("Drag the handles. Drag the cube in the corner to turn the camera", .{});

    const pos = ui.getCursorScreenPos();
    const size = ui.getContentRegionAvailPixels();
    if (size[0] < 10 or size[1] < 10) return;
    if (s.view == null) s.view = lookAt(.{ 5, 4, camera_distance - 2 }, .{ 0, 0, 0 });
    const v = &s.view.?;
    const projection = perspective(45, size[0] / size[1], 0.1, 100);

    gizmo.setDrawList(null);
    gizmo.setRect(pos, size);
    gizmo.drawGrid(v, &projection, &gizmo.identity, 10);
    gizmo.drawCubes(v, &projection, &s.cubes);
    const operation: gizmo.Operation = switch (s.operation) {
        0 => .translate,
        1 => .rotate,
        2 => .scale,
        3 => .universal,
        else => .{ .bounds = true },
    };
    const snap: [3]f32 = switch (s.operation) {
        1 => .{ 15, 15, 15 },
        2 => .{ 0.1, 0.1, 0.1 },
        else => .{ 0.5, 0.5, 0.5 },
    };
    const bounds: [6]f32 = .{ -0.5, -0.5, -0.5, 0.5, 0.5, 0.5 };
    _ = gizmo.manipulate(v, &projection, operation, @fromBackingInt(@intCast(s.mode)), model, .{
        .snap = if (s.snap) &snap else null,
        .local_bounds = if (operation.bounds) &bounds else null,
    });
    const cube = 128;
    gizmo.viewManipulate(v, camera_distance, .{ pos[0] + size[0] - cube, pos[1] }, .{ cube, cube }, 0x10101010);

    const mouse = ui.getMousePos();
    s.hovered = mouse[0] >= pos[0] and mouse[1] >= pos[1] and mouse[0] < pos[0] + size[0] and mouse[1] < pos[1] + size[1];
}

fn perspective(fov_degrees: f32, aspect: f32, near: f32, far: f32) gizmo.Matrix {
    const f = 1 / @tan(std.math.degreesToRadians(fov_degrees) / 2);
    return .{ f / aspect, 0, 0, 0, 0, f, 0, 0, 0, 0, (far + near) / (near - far), -1, 0, 0, 2 * far * near / (near - far), 0 };
}

fn lookAt(eye: @Vector(3, f32), target: @Vector(3, f32)) gizmo.Matrix {
    const z = normalize(eye - target);
    const x = normalize(cross(.{ 0, 1, 0 }, z));
    const y = cross(z, x);
    return .{
        x[0],         y[0],         z[0],         0,
        x[1],         y[1],         z[1],         0,
        x[2],         y[2],         z[2],         0,
        -dot(x, eye), -dot(y, eye), -dot(z, eye), 1,
    };
}

fn dot(a: @Vector(3, f32), b: @Vector(3, f32)) f32 {
    return @reduce(.Add, a * b);
}

fn cross(a: @Vector(3, f32), b: @Vector(3, f32)) @Vector(3, f32) {
    return .{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
}

fn normalize(a: @Vector(3, f32)) @Vector(3, f32) {
    return a / @as(@Vector(3, f32), @splat(@sqrt(dot(a, a))));
}

const Clips = struct {
    const Clip = struct { kind: usize, start: i32, end: i32 };
    const kinds = [_][:0]const u8{ "Camera", "Music", "ScreenEffect", "FadeIn", "Animation" };
    const colors = [_]u32{ 0xFFAA8080, 0xFF80AA80, 0xFF8080AA, 0xFFAAAA80, 0xFFAA80AA };

    items: [16]Clip = undefined,
    len: usize = 0,

    fn seed(self: *Clips) void {
        for ([_]Clip{
            .{ .kind = 0, .start = 10, .end = 30 },
            .{ .kind = 1, .start = 20, .end = 230 },
            .{ .kind = 3, .start = 12, .end = 60 },
            .{ .kind = 2, .start = 61, .end = 90 },
            .{ .kind = 4, .start = 90, .end = 99 },
        }) |clip| self.add2(clip);
    }

    fn add2(self: *Clips, clip: Clip) void {
        if (self.len == self.items.len) return;
        self.items[self.len] = clip;
        self.len += 1;
    }

    pub fn frameMin(_: *Clips) i32 {
        return -100;
    }
    pub fn frameMax(_: *Clips) i32 {
        return 1000;
    }
    pub fn itemCount(self: *Clips) usize {
        return self.len;
    }
    pub fn item(self: *Clips, i: usize) Sequencer.Item {
        const clip = &self.items[i];
        return .{ .start = &clip.start, .end = &clip.end, .kind = clip.kind, .color = colors[clip.kind] };
    }
    pub fn itemLabel(self: *Clips, i: usize) [:0]const u8 {
        return kinds[self.items[i].kind];
    }
    pub fn itemTypeCount(_: *Clips) usize {
        return kinds.len;
    }
    pub fn itemTypeName(_: *Clips, kind: usize) [:0]const u8 {
        return kinds[kind];
    }
    pub fn add(self: *Clips, kind: usize) void {
        self.add2(.{ .kind = kind, .start = 0, .end = 10 });
    }
    pub fn delete(self: *Clips, i: usize) void {
        std.mem.copyForwards(Clip, self.items[i .. self.len - 1], self.items[i + 1 .. self.len]);
        self.len -= 1;
    }
    pub fn duplicate(self: *Clips, i: usize) void {
        self.add2(self.items[i]);
    }
};

fn drawSequencer(self: *GuizmoDemo) void {
    if (self.clips.len == 0) self.clips.seed();
    const win = ui.window("Sequencer demo", .{ .open = &self.sequencer_open, .size = .{ 760, 320 } }) orelse return;
    defer win.end();
    ui.setNextItemWidth(120);
    _ = ui.drag("Frame", &self.timeline.current_frame, 1);
    ui.sameLine();
    if (self.timeline.selected) |i| {
        ui.text("Picked: {s} {d} to {d}", .{ Clips.kinds[self.clips.items[i].kind], self.clips.items[i].start, self.clips.items[i].end });
    } else ui.textDisabled("Click a bar to pick it. Drag bars and their ends, or the frame along the top", .{});
    _ = Sequencer.draw(&self.clips, &self.timeline, .{ .edit_start_end = true, .change_frame = true, .add = true, .delete = true });
}

const Graph = struct {
    const Node = struct { name: [*:0]const u8, template: usize, rect: GraphEditor.Rect, selected: bool = false };

    const one = [_][*:0]const u8{"Out"};
    const two = [_][*:0]const u8{ "A", "B" };
    const input = [_][*:0]const u8{"In"};
    const templates = [_]GraphEditor.Template{
        .{ .header_color = ui.rgba(160, 160, 180, 255), .background_color = ui.rgba(100, 100, 140, 255), .background_color_over = ui.rgba(110, 110, 150, 255), .outputs = &one },
        .{ .header_color = ui.rgba(180, 160, 160, 255), .background_color = ui.rgba(140, 100, 100, 255), .background_color_over = ui.rgba(150, 110, 110, 255), .inputs = &two, .outputs = &one },
        .{ .header_color = ui.rgba(160, 180, 160, 255), .background_color = ui.rgba(100, 140, 100, 255), .background_color_over = ui.rgba(110, 150, 110, 255), .inputs = &input },
    };

    nodes: [4]Node = .{
        .{ .name = "Colour", .template = 0, .rect = rect(10, 10) },
        .{ .name = "Noise", .template = 0, .rect = rect(10, 200) },
        .{ .name = "Blend", .template = 1, .rect = rect(260, 100) },
        .{ .name = "Output", .template = 2, .rect = rect(500, 120) },
    },
    links: [32]GraphEditor.Link = undefined,
    link_len: usize = 0,
    seeded: bool = false,

    fn rect(x: f32, y: f32) GraphEditor.Rect {
        return .{ .min = .{ x, y }, .max = .{ x + 180, y + 120 } };
    }

    pub fn templateCount(_: *Graph) usize {
        return templates.len;
    }
    pub fn template(_: *Graph, i: usize) GraphEditor.Template {
        return templates[i];
    }
    pub fn nodeCount(self: *Graph) usize {
        return self.nodes.len;
    }
    pub fn node(self: *Graph, i: usize) GraphEditor.Node {
        const n = self.nodes[i];
        return .{ .name = n.name, .template = n.template, .rect = n.rect, .selected = n.selected };
    }
    pub fn linkCount(self: *Graph) usize {
        return self.link_len;
    }
    pub fn link(self: *Graph, i: usize) GraphEditor.Link {
        return self.links[i];
    }
    pub fn selectNode(self: *Graph, i: usize, on: bool) void {
        self.nodes[i].selected = on;
    }
    pub fn moveSelectedNodes(self: *Graph, delta: ui.Vec2) void {
        for (&self.nodes) |*n| if (n.selected) {
            n.rect.min[0] += delta[0];
            n.rect.min[1] += delta[1];
            n.rect.max[0] += delta[0];
            n.rect.max[1] += delta[1];
        };
    }
    pub fn addLink(self: *Graph, l: GraphEditor.Link) void {
        if (self.link_len == self.links.len) return;
        self.links[self.link_len] = l;
        self.link_len += 1;
    }
    pub fn deleteLink(self: *Graph, i: usize) void {
        std.mem.copyForwards(GraphEditor.Link, self.links[i .. self.link_len - 1], self.links[i + 1 .. self.link_len]);
        self.link_len -= 1;
    }
};

fn drawGraph(self: *GuizmoDemo) void {
    const g = &self.graph;
    if (!g.seeded) {
        g.seeded = true;
        g.addLink(.{ .input_node = 0, .input_slot = 0, .output_node = 2, .output_slot = 0 });
        g.addLink(.{ .input_node = 1, .input_slot = 0, .output_node = 2, .output_slot = 1 });
        g.addLink(.{ .input_node = 2, .input_slot = 0, .output_node = 3, .output_slot = 0 });
    }
    const win = ui.window("Graph editor demo", .{ .open = &self.graph_open, .size = .{ 800, 520 } }) orelse return;
    defer win.end();
    if (ui.button("Fit all")) self.fit = .all_nodes;
    ui.sameLine();
    if (ui.button("Fit selected")) self.fit = .selected_nodes;
    ui.sameLine();
    ui.textDisabled("Drag from a slot to link. Wheel zooms, middle drag pans", .{});
    if (ui.collapsingHeader("Options", false)) _ = GraphEditor.editOptions(&self.graph_options);
    GraphEditor.show(g, &self.graph_options, &self.graph_view, .{ .fit = &self.fit });
}

const Vector = struct {
    path: VectorEditor.Path,
    editor: VectorEditor.Editor,
};

const tools = [_][:0]const u8{ "Select", "Pen" };

fn drawVector(self: *GuizmoDemo) void {
    const win = ui.window("Vector editor demo", .{ .open = &self.vector_open, .size = .{ 640, 520 } }) orelse return;
    defer win.end();
    const v = self.makeVector() orelse {
        ui.textColored(.{ 1, 0.4, 0.4, 1 }, "Out of memory", .{});
        return;
    };
    _ = ui.combo("Tool", &self.vector_tool, &tools);
    ui.sameLine();
    if (ui.button("Clear")) {
        v.path.clear();
        v.editor.clearSelection();
    }
    ui.sameLine();
    if (ui.button("Reverse")) v.path.reverse();
    ui.text("{d} anchor(s), {s}", .{ v.path.anchors().len, if (v.path.isClosed()) "closed" else "open" });
    ui.textDisabled("Pen: click to add, drag for handles, click the first to close, Enter to finish", .{});

    const result = v.editor.draw("path", &v.path, .{
        .canvas_size = .{ 0, ui.getContentRegionAvailPixels()[1] },
        .tool = @fromBackingInt(@intCast(self.vector_tool)),
        .transform = self.vector_transform,
    });
    // Follow its pan and zoom, keeping the point under the mouse still
    const t = &self.vector_transform;
    t.pan[0] += result.view_pan_delta[0];
    t.pan[1] += result.view_pan_delta[1];
    if (result.view_zoom_factor != 1) {
        const at = result.view_zoom_center_canvas;
        t.zoom *= result.view_zoom_factor;
        t.pan = .{ at[0] - (at[0] - t.pan[0]) * result.view_zoom_factor, at[1] - (at[1] - t.pan[1]) * result.view_zoom_factor };
    }
}

fn makeVector(self: *GuizmoDemo) ?*Vector {
    if (self.vector) |*v| return v;
    var path = VectorEditor.Path.init() catch return null;
    const editor = VectorEditor.Editor.init() catch {
        path.deinit();
        return null;
    };
    self.vector = .{ .path = path, .editor = editor };
    return &self.vector.?;
}

fn freeVector(self: *GuizmoDemo) void {
    if (self.vector) |*v| {
        v.path.deinit();
        v.editor.deinit();
        self.vector = null;
    }
}
