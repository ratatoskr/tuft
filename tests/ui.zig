//! tuft_ui and tuft_devtools on headless ImGui frames.

const std = @import("std");

const ui = @import("tuft_ui");
const devtools = @import("tuft_devtools");
const Memory = @import("tuft_mem").Memory;
const tuft_imgui = @import("tuft_imgui");
const c = tuft_imgui.c;

fn bind() void {
    ui.bind(tuft_imgui.lookup);
}

const tests = struct {
    const testing = std.testing;

    // No renderer, so frame tests run without a GPU
    const headless = tuft_imgui.headless;

    /// Two frames, since new windows stay hidden on their first.
    fn render(draw: anytype) !void {
        return renderFrames(2, draw);
    }

    fn renderFrames(frames: usize, draw: anytype) !void {
        const context = c.ImGui_CreateContext(null) orelse return error.CreateContextFailed;
        defer c.ImGui_DestroyContext(context);
        const io = c.ImGui_GetIO();
        io.*.IniFilename = null; // don't write imgui.ini
        io.*.DisplaySize = .{ .x = 640, .y = 480 };
        io.*.DeltaTime = 1.0 / 60.0;
        headless.init();

        for (0..frames) |_| {
            c.ImGui_NewFrame();
            headless.textures();
            try draw.run();
            c.ImGui_Render();
        }
    }

    test "split drag and tabs" {
        bind();
        const S = struct {
            var split: ui.Split = .{};
            var frames: usize = 0;
            var widths: [2]f32 = .{ 0, 0 };
            var start_width: f32 = 0;
            var shown: ?u8 = null;

            fn run() !void {
                const io = c.ImGui_GetIO();
                const bar_x = split.origin.x + split.first_size + 2;
                const bar_y = split.origin.y + 20;
                switch (frames) {
                    2 => {
                        start_width = widths[0];
                        c.ImGuiIO_AddMousePosEvent(io, bar_x, bar_y);
                    },
                    3 => c.ImGuiIO_AddMouseButtonEvent(io, 0, true),
                    4 => c.ImGuiIO_AddMousePosEvent(io, bar_x + 40, bar_y),
                    5 => c.ImGuiIO_AddMouseButtonEvent(io, 0, false),
                    else => {},
                }
                c.ImGui_SetNextWindowPos(.{ .x = 0, .y = 0 }, c.ImGuiCond_Always);
                if (ui.window("split", .{ .size = .{ 400, 300 } })) |win| {
                    defer win.end();
                    if (ui.tabBar("tabs")) |bar| {
                        defer bar.end();
                        if (ui.tabItem("One", .{})) |tab| {
                            defer tab.end();
                            shown = 0;
                            if (split.first("left")) |part| {
                                defer part.end();
                                widths[0] = c.ImGui_GetWindowWidth();
                            }
                            if (split.second("right")) |part| {
                                defer part.end();
                                widths[1] = c.ImGui_GetWindowWidth();
                            }
                        }
                        if (ui.tabItem("Two", .{ .select = frames == 7 })) |tab| {
                            defer tab.end();
                            shown = 1;
                        }
                    }
                }
                frames += 1;
            }
        };
        try renderFrames(10, S);
        try testing.expect(S.split.ratio > 0.5);
        try testing.expectApproxEqAbs(S.start_width + 40, S.widths[0], 2);
        try testing.expect(S.widths[1] > 0);
        try testing.expectEqual(1, S.shown);
    }

    test "chord input takes keys" {
        bind();
        const S = struct {
            var frames: usize = 0;
            var chord: ?@import("tuft_input").Chord = null;
            var changes: usize = 0;
            var paused: [10]bool = @splat(false);

            fn run() !void {
                const io = c.ImGui_GetIO();
                switch (frames) {
                    2 => c.ImGuiIO_AddKeyEvent(io, c.ImGuiMod_Ctrl, true),
                    3 => c.ImGuiIO_AddKeyEvent(io, c.ImGuiKey_F8, true),
                    4 => {
                        c.ImGuiIO_AddKeyEvent(io, c.ImGuiKey_F8, false);
                        c.ImGuiIO_AddKeyEvent(io, c.ImGuiMod_Ctrl, false);
                    },
                    // Listening again, then cancelled
                    7 => c.ImGuiIO_AddKeyEvent(io, c.ImGuiKey_Escape, true),
                    8 => c.ImGuiIO_AddKeyEvent(io, c.ImGuiKey_Escape, false),
                    else => {},
                }
                if (ui.window("keys", .{ .size = .{ 300, 200 } })) |win| {
                    defer win.end();
                    if (ui.chordInput("Key", &chord, .{ .listen = frames == 1 or frames == 6 })) changes += 1;
                }
                paused[frames] = tuft_imgui.takeListening();
                frames += 1;
            }
        };
        try renderFrames(10, S);
        try testing.expectEqual(1, S.changes);
        try testing.expectEqual(.f8, S.chord.?.key);
        try testing.expect(S.chord.?.mods.ctrl and !S.chord.?.mods.shift);
        // Keys added in a frame land in the next one
        try testing.expectEqualSlices(bool, &.{ false, true, true, true, true, false, true, true, true, false }, &S.paused);
    }

    test "chord input starts on click" {
        bind();
        const S = struct {
            var frames: usize = 0;
            var chord: ?@import("tuft_input").Chord = .{ .key = .f10 };
            var center: c.ImVec2 = .{ .x = 0, .y = 0 };
            var listening_at: ?usize = null;

            fn run() !void {
                const io = c.ImGui_GetIO();
                switch (frames) {
                    2 => c.ImGuiIO_AddMousePosEvent(io, center.x, center.y),
                    3 => c.ImGuiIO_AddMouseButtonEvent(io, 0, true),
                    4 => c.ImGuiIO_AddMouseButtonEvent(io, 0, false),
                    8 => c.ImGuiIO_AddKeyEvent(io, c.ImGuiKey_F7, true),
                    9 => c.ImGuiIO_AddKeyEvent(io, c.ImGuiKey_F7, false),
                    else => {},
                }
                if (ui.window("click", .{ .size = .{ 300, 200 } })) |win| {
                    defer win.end();
                    _ = ui.chordInput("##key", &chord, .{});
                    const min = c.ImGui_GetItemRectMin();
                    const max = c.ImGui_GetItemRectMax();
                    center = .{ .x = (min.x + max.x) / 2, .y = (min.y + max.y) / 2 };
                }
                if (tuft_imgui.takeListening() and listening_at == null) listening_at = frames;
                frames += 1;
            }
        };
        try renderFrames(12, S);
        // Still listening a few frames on, then takes F7
        try testing.expect(S.listening_at != null);
        try testing.expectEqual(.f7, S.chord.?.key);
    }

    test "toasts stay on top and close on click" {
        bind();
        const S = struct {
            var frames: usize = 0;
            var toasts: ui.Toasts = .{};
            var id: ui.Toasts.Id = 0;
            var gone_at: ?usize = null;

            fn run() !void {
                const io = c.ImGui_GetIO();
                switch (frames) {
                    0 => id = toasts.push(.{ .kind = .success, .title = "Saved", .text = "It worked", .seconds = 0 }),
                    // Inside the bottom right toast
                    3 => c.ImGuiIO_AddMousePosEvent(io, 604, 454),
                    5 => c.ImGuiIO_AddMouseButtonEvent(io, 0, true),
                    6 => c.ImGuiIO_AddMouseButtonEvent(io, 0, false),
                    else => {},
                }
                // Raised every frame, right under the toast
                c.ImGui_SetNextWindowPos(.{ .x = 200, .y = 200 }, c.ImGuiCond_Always);
                c.ImGui_SetNextWindowFocus();
                if (ui.window("under", .{ .size = .{ 440, 280 } })) |win| win.end();
                toasts.draw(.{});
                if (frames == 4) try testing.expect(toasts.update(id, .{ .kind = .success, .title = "Saved", .seconds = 0 }));
                if (gone_at == null and toasts.count() == 0) gone_at = frames;
                frames += 1;
            }
        };
        try renderFrames(60, S);
        // Fades out after the click instead of vanishing
        try testing.expect(S.gone_at.? > 10);
        try testing.expect(!S.toasts.update(S.id, .{}));
    }

    test "toasts time out" {
        bind();
        const S = struct {
            var frames: usize = 0;
            var toasts: ui.Toasts = .{};
            var counts: [2]usize = .{ 0, 0 };

            fn run() !void {
                if (frames == 0) _ = toasts.push(.{ .text = "Quick", .seconds = 0.25 });
                toasts.draw(.{ .corner = .top_left });
                if (frames == 5) counts[0] = toasts.count();
                frames += 1;
                counts[1] = toasts.count();
            }
        };
        try renderFrames(30, S);
        try testing.expectEqual([2]usize{ 1, 0 }, S.counts);
    }

    test "gizmo drag" {
        bind();
        const gizmo = ui.gizmo;
        const S = struct {
            var frames: usize = 0;
            var model: gizmo.Matrix = gizmo.identity;
            var hovered: gizmo.MoveType = .none;
            var changed = false;
            // Camera 5 back from the origin, looking at it
            const view: gizmo.Matrix = .translation(.init(0, 0, -5));
            const projection: gizmo.Matrix = blk: {
                const f = 1.0 / @tan(std.math.degreesToRadians(30.0));
                const n = 0.1;
                const far = 100.0;
                break :blk .{ .m = .{ f, 0, 0, 0, 0, f, 0, 0, 0, 0, (far + n) / (n - far), -1, 0, 0, 2 * far * n / (n - far), 0 } };
            };

            fn run() !void {
                const io = c.ImGui_GetIO();
                switch (frames) {
                    2 => c.ImGuiIO_AddMousePosEvent(io, 200, 200),
                    4 => c.ImGuiIO_AddMouseButtonEvent(io, 0, true),
                    5 => c.ImGuiIO_AddMousePosEvent(io, 220, 200),
                    6 => c.ImGuiIO_AddMousePosEvent(io, 240, 200),
                    8 => c.ImGuiIO_AddMouseButtonEvent(io, 0, false),
                    else => {},
                }
                gizmo.beginFrame();
                c.ImGui_SetNextWindowPos(.{ .x = 0, .y = 0 }, c.ImGuiCond_Always);
                if (ui.window("scene", .{ .size = .{ 400, 400 }, .flags = .{ .no_move = true, .no_resize = true } })) |win| {
                    defer win.end();
                    gizmo.setDrawList(null);
                    gizmo.setRect(.{ 0, 0 }, .{ 400, 400 });
                    if (gizmo.manipulate(&view, &projection, .translate, .world, &model, .{})) changed = true;
                    if (frames == 3) hovered = gizmo.hoveredMoveType();
                }
                frames += 1;
            }
        };
        try renderFrames(10, S);
        try testing.expectEqual(.move_screen, S.hovered);
        try testing.expect(S.changed);
        // Moved right on screen, so +x in the world
        const moved = S.model.getTranslation();
        try testing.expect(moved.x > 0.1);
        try testing.expectApproxEqAbs(0, moved.y, 0.01);
        const parts = gizmo.decompose(&S.model);
        try testing.expectApproxEqAbs(moved.x, parts.translation.x, 0.001);
        try testing.expect(S.model.approxEql(gizmo.recompose(parts), 0.0001));
    }

    test "sequencer, graph and pen" {
        bind();
        const S = struct {
            var frames: usize = 0;
            var origin: ui.Vec2 = .{ 0, 0 };

            const Clips = struct {
                starts: [2]i32 = .{ 10, 50 },
                ends: [2]i32 = .{ 30, 80 },
                labels_asked: usize = 0,
                pub fn frameMin(_: *Clips) i32 {
                    return 0;
                }
                pub fn frameMax(_: *Clips) i32 {
                    return 100;
                }
                pub fn itemCount(_: *Clips) usize {
                    return 2;
                }
                pub fn item(self: *Clips, i: usize) ui.Sequencer.Item {
                    return .{ .start = &self.starts[i], .end = &self.ends[i] };
                }
                pub fn itemLabel(self: *Clips, i: usize) [:0]const u8 {
                    self.labels_asked += 1;
                    return if (i == 0) "first" else "second";
                }
            };
            var clips: Clips = .{};
            var sequence: ui.Sequencer.State = .{};

            fn run() !void {
                const io = c.ImGui_GetIO();
                // Row 0 is under the 20 high header. Frame 20 is 200 past the 200 wide legend
                const x = origin[0] + 200 + 20 * 10;
                const y = origin[1] + 20 + 10;
                switch (frames) {
                    2 => c.ImGuiIO_AddMousePosEvent(io, x, y),
                    3 => c.ImGuiIO_AddMouseButtonEvent(io, 0, true),
                    4 => c.ImGuiIO_AddMousePosEvent(io, x + 15, y),
                    5 => c.ImGuiIO_AddMousePosEvent(io, x + 30, y),
                    6 => c.ImGuiIO_AddMouseButtonEvent(io, 0, false),
                    else => {},
                }
                c.ImGui_SetNextWindowPos(.{ .x = 0, .y = 0 }, c.ImGuiCond_Always);
                if (ui.window("timeline", .{ .size = .{ 600, 200 }, .flags = .{ .no_move = true, .no_resize = true } })) |win| {
                    defer win.end();
                    origin = ui.getCursorScreenPos();
                    _ = ui.Sequencer.draw(&clips, &sequence, .{ .edit_start_end = true, .change_frame = true });
                }
                frames += 1;
            }
        };
        try renderFrames(9, S);
        try testing.expect(S.clips.labels_asked > 0);
        try testing.expectEqual(0, S.sequence.selected);
        try testing.expectEqual(13, S.clips.starts[0]);
        try testing.expectEqual(33, S.clips.ends[0]);
        try testing.expectEqual(50, S.clips.starts[1]);

        const G = struct {
            var frames: usize = 0;
            var origin: ui.Vec2 = .{ 0, 0 };
            const GraphEditor = ui.GraphEditor;

            const Graph = struct {
                selected: [2]bool = .{ false, false },
                const names = [_][*:0]const u8{"in"};
                pub fn templateCount(_: *Graph) usize {
                    return 1;
                }
                pub fn template(_: *Graph, _: usize) GraphEditor.Template {
                    return .{ .header_color = 0xFF808080, .background_color = 0xFF303030, .background_color_over = 0xFF404040, .inputs = &names, .outputs = &names };
                }
                pub fn nodeCount(_: *Graph) usize {
                    return 2;
                }
                pub fn node(self: *Graph, i: usize) GraphEditor.Node {
                    const x: f32 = if (i == 0) 40 else 260;
                    return .{ .name = if (i == 0) "a" else "b", .template = 0, .rect = .{ .min = .{ x, 40 }, .max = .{ x + 120, 120 } }, .selected = self.selected[i] };
                }
                pub fn linkCount(_: *Graph) usize {
                    return 1;
                }
                pub fn link(_: *Graph, _: usize) GraphEditor.Link {
                    return .{ .input_node = 0, .input_slot = 0, .output_node = 1, .output_slot = 0 };
                }
                pub fn selectNode(self: *Graph, i: usize, on: bool) void {
                    self.selected[i] = on;
                }
                pub fn moveSelectedNodes(_: *Graph, _: ui.Vec2) void {}
                pub fn addLink(_: *Graph, _: GraphEditor.Link) void {}
                pub fn deleteLink(_: *Graph, _: usize) void {}
            };
            var graph: Graph = .{};
            var view_state: GraphEditor.ViewState = .{};

            fn run() !void {
                const io = c.ImGui_GetIO();
                switch (frames) {
                    2 => c.ImGuiIO_AddMousePosEvent(io, origin[0] + 300, origin[1] + 90),
                    3 => c.ImGuiIO_AddMouseButtonEvent(io, 0, true),
                    4 => c.ImGuiIO_AddMouseButtonEvent(io, 0, false),
                    else => {},
                }
                c.ImGui_SetNextWindowPos(.{ .x = 0, .y = 0 }, c.ImGuiCond_Always);
                if (ui.window("graph", .{ .size = .{ 600, 400 }, .flags = .{ .no_move = true, .no_resize = true } })) |win| {
                    defer win.end();
                    origin = ui.getCursorScreenPos();
                    GraphEditor.show(&graph, &.{}, &view_state, .{});
                }
                frames += 1;
            }
        };
        try renderFrames(7, G);
        try testing.expect(!G.graph.selected[0]);
        try testing.expect(G.graph.selected[1]);

        const V = struct {
            var frames: usize = 0;
            var origin: ui.Vec2 = .{ 0, 0 };
            var path: ui.VectorEditor.Path = undefined;
            var editor: ui.VectorEditor.Editor = undefined;
            var changed = false;
            var edits: usize = 0;
            var last_kind: ?ui.VectorEditor.EditKind = null;

            fn beginEdit(_: *anyopaque, kind: ui.VectorEditor.EditKind, _: ?usize) void {
                edits += 1;
                last_kind = kind;
            }

            fn run() !void {
                const io = c.ImGui_GetIO();
                switch (frames) {
                    2 => c.ImGuiIO_AddMousePosEvent(io, origin[0] + 100, origin[1] + 60),
                    3 => c.ImGuiIO_AddMouseButtonEvent(io, 0, true),
                    4 => c.ImGuiIO_AddMouseButtonEvent(io, 0, false),
                    else => {},
                }
                c.ImGui_SetNextWindowPos(.{ .x = 0, .y = 0 }, c.ImGuiCond_Always);
                if (ui.window("vector", .{ .size = .{ 400, 300 }, .flags = .{ .no_move = true, .no_resize = true } })) |win| {
                    defer win.end();
                    origin = ui.getCursorScreenPos();
                    const result = editor.draw("shape", &path, .{
                        .canvas_size = .{ 300, 200 },
                        .tool = .pen,
                        .delegate = .{ .ctx = &frames, .begin_edit = beginEdit },
                    });
                    if (result.changed) changed = true;
                }
                frames += 1;
            }
        };
        V.path = try .init();
        defer V.path.deinit();
        V.editor = try .init();
        defer V.editor.deinit();
        try renderFrames(7, V);
        const anchors = V.path.anchors();
        try testing.expectEqual(1, anchors.len);
        try testing.expectApproxEqAbs(100, anchors[0].position[0], 1);
        try testing.expectApproxEqAbs(60, anchors[0].position[1], 1);
        try testing.expect(V.changed);
        try testing.expect(V.edits >= 1);
        try testing.expectEqual(.add_anchor, V.last_kind);

        try V.path.setAnchors(&.{ .{ .position = .{ 1, 2 } }, .{ .position = .{ 3, 4 } } });
        V.path.reverse();
        try testing.expectEqual(3, V.path.anchors()[0].position[0]);
        try testing.expect(V.path.anchors()[0].addHandles(10));
        try testing.expect(V.path.anchors()[0].has_handle_out);
    }

    test "plot drag point" {
        bind();
        const plot = ui.plot;
        const S = struct {
            var frames: usize = 0;
            var point: plot.Point = .{ 0.5, 0.5 };
            var at: ui.Vec2 = .{ 0, 0 };
            var state: plot.DragState = .{};
            var hovered = false;
            var moved = false;
            var view: plot.Limits = .{};
            var round_trip: plot.Point = .{ 0, 0 };

            fn run() !void {
                const io = c.ImGui_GetIO();
                switch (frames) {
                    2 => c.ImGuiIO_AddMousePosEvent(io, at[0], at[1]),
                    4 => c.ImGuiIO_AddMouseButtonEvent(io, 0, true),
                    5 => c.ImGuiIO_AddMousePosEvent(io, at[0] + 40, at[1]),
                    6 => c.ImGuiIO_AddMousePosEvent(io, at[0] + 80, at[1]),
                    8 => c.ImGuiIO_AddMouseButtonEvent(io, 0, false),
                    else => {},
                }
                c.ImGui_SetNextWindowPos(.{ .x = 0, .y = 0 }, c.ImGuiCond_Always);
                if (ui.window("plot", .{ .size = .{ 400, 400 }, .flags = .{ .no_move = true, .no_resize = true } })) |win| {
                    defer win.end();
                    if (plot.chart("##p", .{ .size = .{ -1, -1 } })) |chart| {
                        defer chart.end();
                        plot.setupAxesLimits(0, 1, 0, 1, .always);
                        const xs = [_]f64{ 0, 1 };
                        plot.line("line", &xs, .{ .xs = &xs }, .{ .marker = .circle });
                        if (plot.dragPoint(0, &point, .{ .state = &state })) moved = true;
                        if (state.hovered) hovered = true;
                        if (frames < 2) at = plot.plotToPixels(point, null, null);
                        view = plot.limits(null, null);
                        round_trip = plot.pixelsToPlot(plot.plotToPixels(.{ 0.25, 0.75 }, null, null), null, null);
                    }
                }
                frames += 1;
            }
        };
        try renderFrames(10, S);
        try testing.expect(S.hovered);
        try testing.expect(S.moved);
        // Dragged right, so x grew and y stayed
        try testing.expect(S.point[0] > 0.6);
        try testing.expectApproxEqAbs(0.5, S.point[1], 0.01);
        try testing.expectEqual(0, S.view.x.min);
        try testing.expectEqual(1, S.view.y.max);
        try testing.expectApproxEqAbs(0.25, S.round_trip[0], 0.01);
        try testing.expectApproxEqAbs(0.75, S.round_trip[1], 0.01);
    }

    test "plot state per imgui context" {
        bind();
        const plot = ui.plot;
        const a = c.ImGui_CreateContext(null) orelse return error.CreateContextFailed;
        defer c.ImGui_DestroyContext(a);
        const b = c.ImGui_CreateContext(null) orelse return error.CreateContextFailed;

        c.ImGui_SetCurrentContext(a);
        plot.style().minor_alpha = 0.9;
        const custom = plot.addColormap("ours", &.{ .{ 1, 0, 0, 1 }, .{ 0, 0, 1, 1 } }, false);
        try testing.expectEqual(custom, plot.colormapIndex("ours").?);
        try testing.expectEqualStrings("ours", plot.colormapName(custom));

        c.ImGui_SetCurrentContext(b);
        try testing.expectEqual(0.25, plot.style().minor_alpha);
        try testing.expectEqual(null, plot.colormapIndex("ours"));
        // Freed with its ImGui context, then made fresh for a new one
        c.ImGui_DestroyContext(b);
        const fresh = c.ImGui_CreateContext(null) orelse return error.CreateContextFailed;
        defer c.ImGui_DestroyContext(fresh);
        c.ImGui_SetCurrentContext(fresh);
        try testing.expectEqual(0.25, plot.style().minor_alpha);

        c.ImGui_SetCurrentContext(a);
        try testing.expectEqual(0.9, plot.style().minor_alpha);
    }

    test "plot demos" {
        bind();
        const S = struct {
            var demos: ui.PlotDemo = .{ .implot_open = true, .open = true };
            var frames: usize = 0;
            fn run() !void {
                // A fast frame rate still fills the whole visible span
                c.ImGui_GetIO().*.DeltaTime = if (frames < 2) 1.0 / 60.0 else 1.0 / 240.0;
                demos.draw();
                frames += 1;
            }
        };
        try renderFrames(4 + 240 * 13, S);
        const d = &S.demos;
        try testing.expect(d.len == d.times.len);
        try testing.expect(d.times[d.head] <= d.time - 10);
    }

    test "demos free path" {
        bind();
        const S = struct {
            var demos: ui.GuizmoDemo = .{ .gizmo_open = true, .sequencer_open = true, .graph_open = true, .vector_open = true };
            var frames: usize = 0;
            fn run() !void {
                if (frames == 4) {
                    try testing.expect(demos.vector != null);
                    demos.vector_open = false;
                }
                demos.draw();
                frames += 1;
            }
        };
        try renderFrames(6, S);
        try testing.expectEqual(null, S.demos.vector);
        try testing.expect(S.demos.graph.link_len == 3);
        S.demos.deinit();
    }

    test "gizmo defaults" {
        bind();
        var graph: c.ImGraphEditor_Options = undefined;
        c.ImGraphEditor_DefaultOptions(&graph);
        const ours: ui.GraphEditor.Options = .{};
        try testing.expectEqualSlices(u8, std.mem.asBytes(&graph), std.mem.asBytes(&ours));

        var vector: c.ImVectorEditor_Config = undefined;
        c.ImVectorEditor_DefaultConfig(&vector);
        const config: ui.VectorEditor.Config = .{};
        try testing.expectEqual(@as(c_int, @backingInt(config.tool)), vector.Tool);
        try testing.expectEqual(config.canvas_size, .{ vector.CanvasSize.x, vector.CanvasSize.y });
        try testing.expectEqualSlices(u8, std.mem.asBytes(&vector.Style), std.mem.asBytes(&config.style));
        try testing.expectEqualSlices(u8, std.mem.asBytes(&vector.Transform), std.mem.asBytes(&config.transform));
        try testing.expectEqual(config.show_grid, vector.ShowGrid);
        try testing.expectEqual(config.allow_keyboard_shortcuts, vector.AllowKeyboardShortcuts);
    }

    test "clicked view keeps keyboard" {
        bind();
        try renderFrames(8, struct {
            var view: devtools.AsmView = .{ .memory = .{ .vtable = &.{ .read = read } } };
            var hex: devtools.HexView = .{ .memory = .{ .vtable = &.{ .read = read } } };
            var inspector: devtools.Inspector = .{ .memory = .{ .vtable = &.{ .read = read } } };
            var frames: usize = 0;

            fn read(_: ?*anyopaque, _: usize, out: []u8) Memory.Error!void {
                @memset(out, 0x90);
            }

            fn run() !void {
                const io = c.ImGui_GetIO();
                switch (frames) {
                    0 => {
                        view.goTo(0x1000_0000);
                        hex.goTo(0x1000_0000, 1);
                    },
                    // Nothing's focused yet, so the keyboard belongs to the game
                    2 => try testing.expect(!io.*.WantCaptureKeyboard),
                    3 => {
                        c.ImGuiIO_AddMousePosEvent(io, 100, 100);
                        c.ImGuiIO_AddMouseButtonEvent(io, 0, true);
                    },
                    4 => c.ImGuiIO_AddMouseButtonEvent(io, 0, false),
                    // No widget active but still ours because the view says so
                    7 => try testing.expect(io.*.WantCaptureKeyboard),
                    else => {},
                }
                c.ImGui_SetNextWindowPos(.{ .x = 0, .y = 0 }, c.ImGuiCond_Always);
                if (ui.window("keys", .{ .size = .{ 500, 300 } })) |win| {
                    defer win.end();
                    view.draw("code", .{ 0, 150 });
                    hex.draw("bytes", .{ 0, 0 });
                }
                // Next to it, not on top, so the click hits the view
                c.ImGui_SetNextWindowPos(.{ .x = 520, .y = 0 }, c.ImGuiCond_Always);
                if (ui.window("inspect", .{ .size = .{ 300, 300 } })) |win| {
                    defer win.end();
                    _ = inspector.draw(hex.selection());
                }
                frames += 1;
            }
        });
    }

    test "search view" {
        bind();
        try renderFrames(4, struct {
            const base: usize = 0x2000_0000;
            var bytes: [64]u8 align(4) = @splat(0);
            var view: devtools.SearchView = .{ .memory = .{ .vtable = &.{ .read = read, .region_from = regionFrom } } };
            var frames: usize = 0;

            fn read(_: ?*anyopaque, at: usize, out: []u8) Memory.Error!void {
                if (at < base or at + out.len > base + bytes.len) return error.Unreadable;
                @memcpy(out, bytes[at - base ..][0..out.len]);
            }

            fn regionFrom(_: ?*anyopaque, at: usize) ?Memory.Region {
                if (at >= base + bytes.len) return null;
                return .{ .start = base, .len = bytes.len, .writable = true, .executable = false };
            }

            fn run() !void {
                switch (frames) {
                    0 => {
                        std.mem.writeInt(u32, bytes[8..12], 77, .little);
                        std.mem.writeInt(u32, bytes[40..44], 77, .little);
                        _ = try std.fmt.bufPrintSentinel(&view.value, "77", .{}, 0);
                        view.start(.first);
                        while (view.running.load(.acquire)) try testing.io.sleep(.fromMilliseconds(1), .awake);
                    },
                    3 => {
                        try testing.expectEqual(null, view.problem);
                        try testing.expectEqual(2, view.search.?.count);
                        try testing.expectEqual(base + 40, view.search.?.address(1));
                        view.deinit();
                    },
                    else => {},
                }
                c.ImGui_SetNextWindowPos(.{ .x = 0, .y = 0 }, c.ImGuiCond_Always);
                if (ui.window("search", .{ .size = .{ 600, 400 } })) |win| {
                    defer win.end();
                    view.draw();
                }
                frames += 1;
            }
        });
    }

    test "table and address list clicks" {
        bind();
        try renderFrames(20, struct {
            const Row = struct { id: u64 };
            fn idOf(r: *const Row) u64 {
                return r.id;
            }
            const rows = [_]Row{ .{ .id = 7 }, .{ .id = 8 }, .{ .id = 9 } };
            var picked: ui.Selection = .{};
            var at: [rows.len][2]f32 = undefined;
            var value: u32 = 1;
            var list: devtools.AddressList = .{ .allocator = undefined, .memory = .local, .symbols = .local };
            var list_at: [2]f32 = undefined;
            var frames: usize = 0;

            fn run() !void {
                const io = c.ImGui_GetIO();
                switch (frames) {
                    0 => {
                        list.allocator = testing.allocator;
                        try list.addAddress(@intFromPtr(&value), .four_bytes, 0);
                        try list.addAddress(@intFromPtr(&value), .four_bytes, 0);
                        list.picked.clear();
                    },
                    2 => c.ImGuiIO_AddMousePosEvent(io, at[1][0] + 40, at[1][1] + 4),
                    3 => c.ImGuiIO_AddMouseButtonEvent(io, 0, true),
                    // Held a few frames and drifting a pixel, like a real click
                    5 => c.ImGuiIO_AddMousePosEvent(io, at[1][0] + 41, at[1][1] + 5),
                    8 => c.ImGuiIO_AddMouseButtonEvent(io, 0, false),
                    10 => {
                        try testing.expect(picked.contains(8));
                        try testing.expectEqual(1, picked.count());
                    },
                    // On the description, not the checkbox
                    11 => c.ImGuiIO_AddMousePosEvent(io, list_at[0] + 120, list_at[1] + 4),
                    12 => c.ImGuiIO_AddMouseButtonEvent(io, 0, true),
                    16 => c.ImGuiIO_AddMouseButtonEvent(io, 0, false),
                    18 => {
                        try testing.expectEqual(1, list.picked.count());
                        try testing.expectEqual(1, list.selectedIndex().?);
                    },
                    19 => {
                        picked.deinit();
                        list.deinit();
                    },
                    else => {},
                }
                c.ImGui_SetNextWindowPos(.{ .x = 0, .y = 0 }, c.ImGuiCond_Always);
                if (ui.window("table", .{ .size = .{ 400, 200 } })) |win| {
                    defer win.end();
                    if (ui.table("rows", 3, .{ .borders = true, .row_background = true, .resizable = true, .sortable = true, .sizing = .fixed_fit, .scroll_x = true, .scroll_y = true, .frozen_columns = 1 })) |table| {
                        defer table.end();
                        inline for (.{ "A", "B", "C" }) |l| ui.tableColumn(l);
                        ui.tableHeaders();
                        var scope = picked.begin(rows.len, ui.Selection.Rows(Row, idOf){ .rows = &rows }, .{});
                        for (rows, 0..) |r, i| {
                            const id = ui.id(@as(i32, @intCast(i)));
                            defer id.end();
                            ui.tableNextRow();
                            _ = ui.tableNextColumn();
                            at[i] = ui.getCursorScreenPos();
                            _ = scope.row(i, ui.format("wraith", .{}));
                            _ = ui.tableNextColumn();
                            ui.text("b {d}", .{r.id});
                            _ = ui.tableNextColumn();
                            ui.text("c", .{});
                        }
                        scope.end();
                    }
                }
                c.ImGui_SetNextWindowPos(.{ .x = 0, .y = 220 }, c.ImGuiCond_Always);
                if (ui.window("list", .{ .size = .{ 600, 400 } })) |win| {
                    defer win.end();
                    if (frames < 19) {
                        list.draw();
                        list_at = .{ 0, 220 + 30 + 2 * ui.getTextLineHeightWithSpacing() + 8 };
                    }
                }
                frames += 1;
            }
        });
    }

    test "row picking and commands" {
        bind();
        try renderFrames(30, struct {
            const Row = struct { id: u64 };
            fn idOf(r: *const Row) u64 {
                return r.id;
            }
            // Ids aren't indices, like after sorting
            const rows = [_]Row{ .{ .id = 50 }, .{ .id = 40 }, .{ .id = 30 }, .{ .id = 20 }, .{ .id = 10 } };
            var picked: ui.Selection = .{};
            var at: [rows.len][2]f32 = undefined;
            var copies: usize = 0;
            var popup = false;
            var frames: usize = 0;

            fn move(io: *c.ImGuiIO, row: usize) void {
                c.ImGuiIO_AddMousePosEvent(io, at[row][0] + 20, at[row][1] + 4);
            }

            fn run() !void {
                const io = c.ImGui_GetIO();
                // Overlappable rows only take a click once hovered a frame
                switch (frames) {
                    1 => move(io, 0),
                    2 => c.ImGuiIO_AddMouseButtonEvent(io, 0, true),
                    3 => c.ImGuiIO_AddMouseButtonEvent(io, 0, false),
                    4 => c.ImGuiIO_AddKeyEvent(io, c.ImGuiMod_Shift, true),
                    5 => move(io, 2),
                    6 => c.ImGuiIO_AddMouseButtonEvent(io, 0, true),
                    7 => c.ImGuiIO_AddMouseButtonEvent(io, 0, false),
                    8 => c.ImGuiIO_AddKeyEvent(io, c.ImGuiMod_Shift, false),
                    10 => {
                        try testing.expectEqual(3, picked.count());
                        for ([_]u64{ 50, 40, 30 }) |id| try testing.expect(picked.contains(id));
                        c.ImGuiIO_AddKeyEvent(io, c.ImGuiMod_Ctrl, true);
                    },
                    11 => c.ImGuiIO_AddKeyEvent(io, c.ImGuiKey_C, true),
                    12 => c.ImGuiIO_AddKeyEvent(io, c.ImGuiKey_C, false),
                    13 => c.ImGuiIO_AddKeyEvent(io, c.ImGuiMod_Ctrl, false),
                    15 => {
                        try testing.expectEqual(1, copies);
                        move(io, 3);
                    },
                    16 => c.ImGuiIO_AddMouseButtonEvent(io, 1, true),
                    17 => c.ImGuiIO_AddMouseButtonEvent(io, 1, false),
                    19 => {
                        try testing.expect(popup);
                        try testing.expectEqual(1, picked.count());
                        try testing.expect(picked.contains(20));
                        try testing.expectEqual(20, picked.focused().?);
                        c.ImGuiIO_AddMousePosEvent(io, at[3][0] + 40, at[3][1] + 18);
                    },
                    20 => c.ImGuiIO_AddMouseButtonEvent(io, 0, true),
                    23 => c.ImGuiIO_AddMouseButtonEvent(io, 0, false),
                    25 => try testing.expectEqual(2, copies),
                    26 => try testing.expect(!popup),
                    else => {},
                }
                c.ImGui_SetNextWindowPos(.{ .x = 0, .y = 0 }, c.ImGuiCond_Always);
                if (ui.window("list", .{ .size = .{ 400, 300 } })) |win| {
                    defer win.end();
                    if (ui.table("rows", 1, .{ .scroll_y = true })) |table| {
                        defer table.end();
                        var scope = picked.begin(rows.len, ui.Selection.Rows(Row, idOf){ .rows = &rows }, .{});
                        for (rows, 0..) |r, i| {
                            ui.tableNextRow();
                            _ = ui.tableNextColumn();
                            at[i] = ui.getCursorScreenPos();
                            _ = scope.row(i, ui.format("row {d}", .{r.id}));
                        }
                        scope.end();
                    }
                    // After the table, not in it, or its items can't be clicked
                    var menu = ui.commands("rows", .{ .activated = picked.activated });
                    defer menu.end();
                    popup = menu.popup;
                    if (menu.item(.{ .label = "Copy", .chord = .{ .key = .c, .ctrl = true }, .enabled = picked.count() > 0 })) copies += 1;
                    menu.separator();
                    _ = menu.item(.{ .label = "Never", .enabled = false });
                    if (frames == 27) try testing.expect(ui.Commands.menuItems());
                }
                if (frames == 28) {
                    ui.Commands.forget();
                    picked.deinit();
                }
                frames += 1;
            }
        });
    }

    test "commands under a child, after a separator" {
        bind();
        try renderFrames(30, struct {
            const Row = struct { id: u64 };
            fn idOf(r: *const Row) u64 {
                return r.id;
            }
            const rows = [_]Row{ .{ .id = 1 }, .{ .id = 2 }, .{ .id = 3 } };
            var picked: ui.Selection = .{};
            var cleared: usize = 0;
            var popup = false;
            var clear_at: ?[2]f32 = null;
            var frames: usize = 0;

            fn run() !void {
                const io = c.ImGui_GetIO();
                switch (frames) {
                    2 => c.ImGuiIO_AddMousePosEvent(io, 100, 60),
                    4 => c.ImGuiIO_AddMouseButtonEvent(io, 1, true),
                    5 => c.ImGuiIO_AddMouseButtonEvent(io, 1, false),
                    8 => {
                        try testing.expect(popup);
                        const at = clear_at orelse return error.NoClearItem;
                        c.ImGuiIO_AddMousePosEvent(io, at[0] + 10, at[1] + 4);
                    },
                    10 => c.ImGuiIO_AddMouseButtonEvent(io, 0, true),
                    12 => c.ImGuiIO_AddMouseButtonEvent(io, 0, false),
                    16 => {
                        try testing.expectEqual(1, cleared);
                        try testing.expect(!popup);
                    },
                    else => {},
                }
                c.ImGui_SetNextWindowPos(.{ .x = 0, .y = 0 }, c.ImGuiCond_Always);
                if (ui.window("log", .{ .size = .{ 400, 300 } })) |win| {
                    defer win.end();
                    // Like the workbench's Log panel, which begins its menu inside the list's child
                    if (ui.child("lines", .{ 0, 0 }, .{ .border = true })) |child| {
                        defer child.end();
                        var scope = picked.begin(rows.len, ui.Selection.Rows(Row, idOf){ .rows = &rows }, .{});
                        var clip = ui.clip(rows.len);
                        clip.include(scope.keep());
                        while (clip.next()) |i| _ = scope.row(i, ui.format("line {d}", .{rows[i].id}));
                        scope.end();
                        var menu = ui.commands("lines", .{});
                        defer menu.end();
                        popup = menu.popup;
                        _ = menu.item(.{ .label = "Copy", .chord = .{ .key = .c, .ctrl = true }, .enabled = picked.count() > 0 });
                        menu.separator();
                        if (menu.item(.{ .label = "Clear", .tooltip = "Forget them" })) cleared += 1;
                        if (menu.popup) clear_at = ui.getItemRectMin();
                    }
                }
                if (frames == 28) {
                    ui.Commands.forget();
                    picked.deinit();
                }
                frames += 1;
            }
        });
    }

    test "row drag and drop" {
        bind();
        try renderFrames(14, struct {
            const Row = struct { id: u64 };
            fn idOf(r: *const Row) u64 {
                return r.id;
            }
            const rows = [_]Row{ .{ .id = 50 }, .{ .id = 40 }, .{ .id = 30 } };
            var picked: ui.Selection = .{};
            var at: [rows.len][2]f32 = undefined;
            var hovered: ?[2]u64 = null;
            var dropped: ?[2]u64 = null;
            var frames: usize = 0;

            fn move(io: *c.ImGuiIO, row: usize, down: f32) void {
                c.ImGuiIO_AddMousePosEvent(io, at[row][0] + 20, at[row][1] + down);
            }

            fn run() !void {
                const io = c.ImGui_GetIO();
                switch (frames) {
                    1 => move(io, 0, 4),
                    2 => c.ImGuiIO_AddMouseButtonEvent(io, 0, true),
                    // Past the drag threshold, then over the last row
                    4 => move(io, 0, 14),
                    5 => move(io, 1, 4),
                    6 => move(io, 2, 4),
                    8 => {
                        try testing.expectEqual([2]u64{ 50, 30 }, hovered.?);
                        try testing.expectEqual(null, dropped);
                        c.ImGuiIO_AddMouseButtonEvent(io, 0, false);
                    },
                    10 => {
                        try testing.expectEqual([2]u64{ 50, 30 }, dropped.?);
                        try testing.expect(ui.dragging("test.row") == null);
                    },
                    12 => picked.deinit(),
                    else => {},
                }
                c.ImGui_SetNextWindowPos(.{ .x = 0, .y = 0 }, c.ImGuiCond_Always);
                if (ui.window("drag", .{ .size = .{ 400, 300 } })) |win| {
                    defer win.end();
                    if (ui.table("rows", 1, .{})) |table| {
                        defer table.end();
                        var scope = picked.begin(rows.len, ui.Selection.Rows(Row, idOf){ .rows = &rows }, .{});
                        for (rows, 0..) |r, i| {
                            ui.tableNextRow();
                            _ = ui.tableNextColumn();
                            at[i] = ui.getCursorScreenPos();
                            _ = scope.row(i, ui.format("row {d}", .{r.id}));
                            if (ui.dragSource("test.row", std.mem.asBytes(&r.id))) |source| {
                                defer source.end();
                                ui.text("row {d}", .{r.id});
                            }
                            if (ui.dropTarget("test.row")) |drop| {
                                const pair: [2]u64 = .{ drop.as(u64).?, r.id };
                                if (drop.delivered) dropped = pair else hovered = pair;
                            }
                        }
                        scope.end();
                    }
                }
                frames += 1;
            }
        });
    }

    test "address list" {
        bind();
        try renderFrames(4, struct {
            var value: u32 align(4) = 5;
            var list: devtools.AddressList = .{ .allocator = undefined, .memory = .local, .symbols = .local };
            var frames: usize = 0;

            fn run() !void {
                switch (frames) {
                    0 => {
                        list.allocator = testing.allocator;
                        try list.addGroup("Player");
                        try list.addAddress(@intFromPtr(&value), .four_bytes, 0);
                        try list.addAddress(0x10, .text, 0); // nowhere, shows ??
                        list.select(1);
                        list.setHeld(1, true);
                        value = 9;
                    },
                    3 => {
                        try testing.expectEqual(5, value);
                        try testing.expect(list.dirty);
                        list.deinit();
                    },
                    else => {},
                }
                c.ImGui_SetNextWindowPos(.{ .x = 0, .y = 0 }, c.ImGuiCond_Always);
                if (ui.window("addresses", .{ .size = .{ 600, 480 } })) |win| {
                    defer win.end();
                    if (frames < 3) {
                        list.enforce();
                        list.draw();
                    }
                }
                frames += 1;
            }
        });
    }

    test "focus and arrows" {
        bind();
        try renderFrames(12, struct {
            var hex: devtools.HexView = .{ .memory = .{ .vtable = &.{ .read = read } } };
            var code: devtools.AsmView = .{ .memory = .{ .vtable = &.{ .read = read } } };
            var frames: usize = 0;

            // All nops, so every byte is an instruction
            fn read(_: ?*anyopaque, _: usize, out: []u8) Memory.Error!void {
                @memset(out, 0x90);
            }

            fn press(io: *c.ImGuiIO, down: bool) void {
                c.ImGuiIO_AddKeyEvent(io, c.ImGuiKey_DownArrow, down);
            }

            fn run() !void {
                const io = c.ImGui_GetIO();
                switch (frames) {
                    // Once both windows are up. A new window grabs focus itself
                    0 => code.goTo(0x2000_0000),
                    2 => {
                        try testing.expect(!io.*.WantCaptureKeyboard);
                        hex.goTo(0x1000_0000, 1);
                        hex.focus();
                    },
                    4 => {
                        try testing.expect(io.*.WantCaptureKeyboard);
                        press(io, true);
                    },
                    5 => press(io, false),
                    7 => {
                        try testing.expectEqual(0x1000_0000 + devtools.HexView.bytes_per_row, hex.cursor);
                        try testing.expectEqual(0x2000_0000, code.cursor.address);
                        code.focus();
                    },
                    9 => press(io, true),
                    10 => press(io, false),
                    11 => {
                        try testing.expectEqual(0x2000_0001, code.cursor.address);
                        try testing.expectEqual(0x1000_0000 + devtools.HexView.bytes_per_row, hex.cursor);
                    },
                    else => {},
                }
                c.ImGui_SetNextWindowPos(.{ .x = 0, .y = 0 }, c.ImGuiCond_Always);
                if (ui.window("hex", .{ .size = .{ 300, 300 } })) |win| {
                    defer win.end();
                    hex.draw("bytes", .{ 0, 0 });
                }
                c.ImGui_SetNextWindowPos(.{ .x = 320, .y = 0 }, c.ImGuiCond_Always);
                if (ui.window("code", .{ .size = .{ 300, 300 } })) |win| {
                    defer win.end();
                    code.draw("code", .{ 0, 0 });
                }
                frames += 1;
            }
        });
    }

    test "hex typing and asm edit" {
        bind();
        try renderFrames(12, struct {
            // Five `mov eax, 1`s with nothing around them
            const at: usize = 0x1000_0000;
            var bytes: [25]u8 = @bitCast(@as([5][5]u8, @splat(.{ 0xB8, 0x01, 0x00, 0x00, 0x00 })));
            const memory: Memory = .{ .vtable = &.{ .read = read, .write = write } };
            var hex: devtools.HexView = .{ .memory = memory };
            var code: devtools.AsmView = .{ .memory = memory };
            var frames: usize = 0;

            fn read(_: ?*anyopaque, address: usize, out: []u8) Memory.Error!void {
                if (address < at or address + out.len > at + bytes.len) return error.Unreadable;
                @memcpy(out, bytes[address - at ..][0..out.len]);
            }

            fn write(_: ?*anyopaque, address: usize, in: []const u8) Memory.Error!void {
                if (address < at or address + in.len > at + bytes.len) return error.Unwritable;
                @memcpy(bytes[address - at ..][0..in.len], in);
            }

            fn key(io: *c.ImGuiIO, k: c.ImGuiKey, down: bool) void {
                c.ImGuiIO_AddKeyEvent(io, k, down);
            }

            fn run() !void {
                const io = c.ImGui_GetIO();
                switch (frames) {
                    0 => {
                        hex.goTo(at + 1, 1);
                        code.goTo(at + 5);
                    },
                    2 => hex.focus(),
                    4 => for ("c3") |ch| c.ImGuiIO_AddInputCharacter(io, ch),
                    // Input queued in one frame gets drawn in the next
                    6 => {
                        try testing.expectEqual(0xC3, bytes[1]);
                        try testing.expectEqual(at + 2, hex.cursor);
                        code.focus();
                    },
                    8 => key(io, c.ImGuiKey_Enter, true),
                    9 => key(io, c.ImGuiKey_Enter, false),
                    // Text is selected, so typing replaces it
                    11 => {
                        try testing.expectEqual(at + 5, code.editing.?.address);
                        for ("nop") |ch| c.ImGuiIO_AddInputCharacter(io, ch);
                    },
                    13 => key(io, c.ImGuiKey_Enter, true),
                    14 => key(io, c.ImGuiKey_Enter, false),
                    16 => {
                        try testing.expectEqual(null, code.editing);
                        try testing.expectEqual(null, code.problem);
                        try testing.expectEqualSlices(u8, &.{ 0x90, 0x90, 0x90, 0x90, 0x90, 0xB8 }, bytes[5..11]);
                        try testing.expectEqual(at + 10, code.cursor.address);
                    },
                    else => {},
                }
                c.ImGui_SetNextWindowPos(.{ .x = 0, .y = 0 }, c.ImGuiCond_Always);
                if (ui.window("hex", .{ .size = .{ 300, 300 } })) |win| {
                    defer win.end();
                    hex.draw("bytes", .{ 0, 0 });
                }
                c.ImGui_SetNextWindowPos(.{ .x = 320, .y = 0 }, c.ImGuiCond_Always);
                if (ui.window("code", .{ .size = .{ 300, 300 } })) |win| {
                    defer win.end();
                    code.draw("code", .{ 0, 0 });
                }
                frames += 1;
            }
        });
    }

    test "Escape cancels innermost" {
        bind();
        try renderFrames(34, struct {
            var hex: devtools.HexView = .{ .memory = .{ .vtable = &.{ .read = read } } };
            var code: devtools.AsmView = .{ .memory = .{ .vtable = &.{ .read = read } } };
            var frames: usize = 0;
            /// `wraith_ui.WindowSystem` closes windows on it.
            var escaped: ?usize = null;

            fn read(_: ?*anyopaque, _: usize, out: []u8) Memory.Error!void {
                @memset(out, 0x90);
            }

            fn key(io: *c.ImGuiIO, k: c.ImGuiKey, frame: usize, first: usize) void {
                if (frame == first) c.ImGuiIO_AddKeyEvent(io, k, true);
                if (frame == first + 1) c.ImGuiIO_AddKeyEvent(io, k, false);
            }

            fn run() !void {
                const io = c.ImGui_GetIO();
                switch (frames) {
                    0 => {
                        hex.goTo(0x1000_0000, 1);
                        code.goTo(0x2000_0000);
                    },
                    2 => hex.focus(),
                    4 => c.ImGuiIO_AddInputCharacter(io, 'c'),
                    8 => {
                        try testing.expectEqual(0x0C, hex.nibble);
                        try testing.expectEqual(null, escaped);
                    },
                    11 => {
                        try testing.expectEqual(null, hex.nibble);
                        try testing.expectEqual(null, escaped);
                    },
                    15 => {
                        try testing.expect(escaped != null);
                        escaped = null;
                        code.focus();
                    },
                    20 => try testing.expect(code.editing != null),
                    26 => {
                        try testing.expectEqual(null, code.editing);
                        try testing.expectEqual(null, escaped);
                    },
                    33 => try testing.expect(escaped != null),
                    else => {},
                }
                key(io, c.ImGuiKey_Escape, frames, 9);
                key(io, c.ImGuiKey_Escape, frames, 13);
                key(io, c.ImGuiKey_Enter, frames, 17);
                key(io, c.ImGuiKey_Escape, frames, 23);
                key(io, c.ImGuiKey_Escape, frames, 30);

                c.ImGui_SetNextWindowPos(.{ .x = 0, .y = 0 }, c.ImGuiCond_Always);
                if (ui.window("views", .{ .size = .{ 600, 400 } })) |win| {
                    defer win.end();
                    hex.draw("bytes", .{ 0, 180 });
                    code.draw("code", .{ 0, 0 });
                    if (ui.shortcut(.escape) and escaped == null) escaped = frames;
                }
                frames += 1;
            }
        });
    }

    fn dragAcross(comptime View: type) !void {
        bind();
        try renderFrames(8, struct {
            var view: View = .{ .memory = .{ .vtable = &.{ .read = read } } };
            var frames: usize = 0;

            fn read(_: ?*anyopaque, _: usize, out: []u8) Memory.Error!void {
                @memset(out, 0x90);
            }

            fn run() !void {
                const io = c.ImGui_GetIO();
                const stride = c.ImGui_GetTextLineHeightWithSpacing();
                switch (frames) {
                    0 => if (View == devtools.HexView) view.goTo(0x1000_0000, 1) else view.goTo(0x1000_0000),
                    2 => {
                        c.ImGuiIO_AddMousePosEvent(io, 200, 80);
                        c.ImGuiIO_AddMouseButtonEvent(io, 0, true);
                    },
                    3 => c.ImGuiIO_AddMousePosEvent(io, 200, 80 + 5 * stride),
                    5 => c.ImGuiIO_AddMouseButtonEvent(io, 0, false),
                    7 => {
                        const s = view.selection().?;
                        // Nops are one byte each. Hex view rows are 16
                        const per_row: usize = if (View == devtools.HexView) devtools.HexView.bytes_per_row else 1;
                        try testing.expect(s.len > 4 * per_row);
                        try testing.expect(s.len < 7 * per_row);
                    },
                    else => {},
                }
                c.ImGui_SetNextWindowPos(.{ .x = 0, .y = 0 }, c.ImGuiCond_Always);
                if (ui.window("drag", .{ .size = .{ 600, 400 } })) |win| {
                    defer win.end();
                    view.draw("view", .{ 0, 0 });
                }
                frames += 1;
            }
        });
    }

    test "hex drag select" {
        try dragAcross(devtools.HexView);
    }

    test "disasm drag select" {
        try dragAcross(devtools.AsmView);
    }

    test "headless frame and version" {
        try render(struct {
            fn run() !void {
                _ = c.ImGui_Begin(ui.str("tuft"), null, 0);
                c.ImGui_TextUnformatted(ui.str("hello"));
                c.ImGui_End();
            }
        });
        const version: [*:0]const u8 = @ptrCast(c.ImGui_GetVersion());
        try testing.expectEqualStrings("1.93.1", std.mem.span(version));
    }

    test "wrapper via lookup" {
        bind();
        try render(struct {
            var enabled = true;
            var amount: f32 = 0.5;
            var choice: usize = 0;
            var name: [32]u8 = @splat(0);

            fn run() !void {
                if (ui.window("wrapper", .{ .flags = .{ .menu_bar = true }, .size = .{ 300, 200 } })) |win| {
                    defer win.end();
                    if (ui.menuBar()) |bar| {
                        defer bar.end();
                        if (ui.menu("File")) |m| {
                            defer m.end();
                            _ = ui.menuItem("Quit", .{ .shortcut = "Alt+F4" });
                        }
                    }
                    ui.text("{d} items", .{3});
                    ui.textDisabled("disabled", .{});
                    _ = ui.checkbox("enabled", &enabled);
                    _ = ui.slider("amount", &amount, 0, 1);
                    _ = ui.combo("choice", &choice, &.{ "a", "b" });
                    _ = ui.inputText("name", &name);
                    ui.copyableText("##copy", "C:\\some\\path {d}", .{42});
                    {
                        const scope = ui.id("row");
                        defer scope.end();
                        _ = ui.button("go");
                    }
                    if (ui.table("t", 2, .{ .borders = true })) |t| {
                        defer t.end();
                        ui.tableColumn("A");
                        ui.tableColumn("B");
                        ui.tableHeaders();
                        ui.tableNextRow();
                        _ = ui.tableNextColumn();
                        ui.text("1", .{});
                    }
                }
            }
        });
    }

    test "unscaled window sizes" {
        bind();
        try render(struct {
            var size: c.ImVec2 = .{ .x = 0, .y = 0 };

            fn run() !void {
                c.ImGui_GetStyle().*.FontScaleDpi = 2;
                defer c.ImGui_GetStyle().*.FontScaleDpi = 1;
                if (ui.window("sized", .{ .size = .{ 100, 50 }, .min_size = .{ 150, 80 }, .max_size = .{ 200, 0 } })) |win| {
                    defer win.end();
                    size = c.ImGui_GetWindowSize();
                    if (ui.table("scrolling", 3, .{ .sizing = .fixed_fit, .scroll_x = true, .scroll_y = true, .frozen_columns = 1 })) |t| {
                        defer t.end();
                        ui.tableColumn("A");
                        ui.tableColumnWith("B", .{ .fixed = true, .width = 40 });
                        ui.tableColumnWith("C", .{ .stretch = true });
                        ui.tableHeaders();
                    }
                }
                try testing.expectEqual(300, size.x);
                try testing.expectEqual(160, size.y);
            }
        });
    }

    test "table starts unsorted" {
        bind();
        try render(struct {
            const Column = enum { a, b };

            // Default order is largest first. Sorting by a column is smallest first
            fn order(_: void, column: ?Column, a: i32, b: i32) std.math.Order {
                return if (column == null) std.math.order(b, a) else std.math.order(a, b);
            }

            fn run() !void {
                if (ui.window("sortable", .{})) |win| {
                    defer win.end();
                    if (ui.table("t", 2, .{ .sortable = true })) |t| {
                        defer t.end();
                        ui.tableColumn("A");
                        ui.tableColumnWith("B", .{ .no_sort = true });
                        ui.tableHeaders();
                        try testing.expectEqual(null, t.sortedBy(Column));
                        var rows = [_]i32{ 2, 1, 3 };
                        t.sort(Column, i32, &rows, {}, order);
                        try testing.expectEqualSlices(i32, &.{ 3, 2, 1 }, &rows);
                    }
                }
            }
        });
    }

    test "wrapped table too small" {
        bind();
        try render(struct {
            fn run() !void {
                c.ImGui_SetNextWindowSize(.{ .x = 57, .y = 57 }, c.ImGuiCond_Always);
                if (ui.window("tiny", .{})) |win| {
                    defer win.end();
                    if (ui.table("env", 2, .{ .sizing = .stretch_prop })) |t| {
                        defer t.end();
                        ui.tableColumnWith("name", .{ .fixed = true, .width = 130 });
                        ui.tableColumnWith("value", .{ .stretch = true });
                        ui.tableNextRow();
                        _ = ui.tableNextColumn();
                        ui.textDisabled("Path", .{});
                        _ = ui.tableNextColumn();
                        ui.textWrapped("C:\\a\\long\\path\\without\\spaces\\to\\somewhere", .{});
                    }
                }
            }
        });
    }

    test "hex view jumps" {
        bind();
        try renderFrames(24, struct {
            const targets = [_]usize{ 0x1000_0007, 0x2000_001F, 0x1000_0007, 0x17, 0x3000_0003, 0x27, 0x4000_000F, 0x1000_0007 };
            var view: devtools.HexView = .{ .memory = .{ .vtable = &.{ .read = read } } };
            var frames: usize = 0;

            fn read(_: ?*anyopaque, _: usize, out: []u8) Memory.Error!void {
                @memset(out, 0xAB);
            }

            fn run() !void {
                const target = targets[frames / 3];
                if (frames % 3 == 0) view.goTo(target, 4);
                if (frames == 12) {
                    c.ImGui_StyleColorsDark(null);
                    c.ImGui_GetStyle().*.ItemSpacing.y = 9;
                    c.ImGuiStyle_ScaleAllSizes(c.ImGui_GetStyle(), 1.5);
                    c.ImGui_GetStyle().*.FontScaleMain = 1.5;
                }
                if (ui.window("hex", .{ .size = .{ 500, 300 } })) |win| {
                    defer win.end();
                    view.draw("bytes", .{ 0, 0 });
                    if (view.drawn != null) {
                        try testing.expect(view.isDrawn(target));
                        try testing.expectEqual(null, view.scroll_to);
                    }
                }
                if (frames % 3 == 2) {
                    try testing.expect(view.isDrawn(target));
                    try testing.expectEqual(null, view.scroll_to);
                    try testing.expectEqual(target, view.selection().?.start);
                    if (target > 1 << 20) try testing.expect(!view.isDrawn(view.shown.start));
                }
                frames += 1;
            }
        });
    }

    test "hex view scrolls" {
        bind();
        try renderFrames(9, struct {
            const start: usize = 0x1000_0000;
            const len: usize = (1 << 20) + 7;
            const targets = [_]usize{ start + len / 2, start + len - 1, start };
            var view: devtools.HexView = .{ .memory = .{ .vtable = &.{ .read = read } }, .shown = .{ .start = start, .len = len } };
            var frames: usize = 0;

            fn read(_: ?*anyopaque, _: usize, out: []u8) Memory.Error!void {
                @memset(out, 0xAB);
            }

            fn run() !void {
                const target = targets[frames / 3];
                if (frames % 3 == 0) view.scroll_to = target;
                if (ui.window("hex bounds", .{ .size = .{ 500, 300 } })) |win| {
                    defer win.end();
                    view.draw("bytes", .{ 0, 0 });
                    if (view.drawn != null) try testing.expect(view.isDrawn(target));
                }
                if (frames % 3 == 2) {
                    try testing.expect(view.isDrawn(target));
                    try testing.expectEqual(null, view.scroll_to);
                }
                frames += 1;
            }
        });
    }

    test "disasm settles" {
        bind();
        try renderFrames(12, struct {
            const targets = [_]usize{ 0x1000_0000, 0x2000_0013, 0x1000_0000 };
            var view: devtools.AsmView = .{ .memory = .{ .vtable = &.{ .read = read } } };
            var frames: usize = 0;
            var settled_top: usize = 0;

            // All nops, so every byte is an instruction
            fn read(_: ?*anyopaque, _: usize, out: []u8) Memory.Error!void {
                @memset(out, 0x90);
            }

            fn run() !void {
                const target = targets[frames / 4];
                if (frames % 4 == 0) view.goTo(target);
                if (ui.window("code", .{ .size = .{ 500, 300 } })) |win| {
                    defer win.end();
                    view.draw("code", .{ 0, 0 });
                }
                switch (frames % 4) {
                    0 => {},
                    1 => settled_top = view.top,
                    // Re-decoding around the top row each frame doesn't move it
                    else => {
                        try testing.expectEqual(target - 4, view.top);
                        try testing.expectEqual(settled_top, view.top);
                        try testing.expect(!view.moved);
                        try testing.expectEqual(devtools.AsmView.margin, view.top_index);
                        try testing.expectEqual(@import("tuft_mem").Range{ .start = target, .len = 1, .memory = view.memory }, view.selection().?);
                    },
                }
                frames += 1;
            }
        });
    }

    test "struct view defines field" {
        bind();
        const salamander = @import("salamander_schema");
        try renderFrames(14, struct {
            const source = "struct Player {\n    u32 id;\n    [0x8] f32 health;\n}\n";
            var player: [0x10]u8 align(8) = @splat(0);
            var view: devtools.StructView = .{ .allocator = undefined, .symbols = .local };
            var parsed: ?salamander.Parsed = null;
            var reparsed: ?salamander.Parsed = null;
            var text: ?[:0]u8 = null;
            var frames: usize = 0;

            fn enter(down: bool) void {
                c.ImGuiIO_AddKeyEvent(c.ImGui_GetIO(), c.ImGuiKey_Enter, down);
            }

            fn run() !void {
                switch (frames) {
                    0 => {
                        view.allocator = testing.allocator;
                        parsed = try salamander.parse(testing.allocator, source, .{}, null);
                        view.setSchema(&parsed.?.schema);
                        view.goTo(@intFromPtr(&player));
                    },
                    3 => {
                        for (view.rows.items) |r| if (r.kind == .gap) view.picked.only(r.id);
                        enter(true);
                    },
                    4 => enter(false),
                    5 => try testing.expectEqual(.define, view.edit.editing.?.what),
                    8 => enter(true),
                    9 => enter(false),
                    12 => {
                        try testing.expectEqualStrings("struct Player {\n    u32 id;\n    [0x4] u32 unk_4;\n    [0x8] f32 health;\n}\n", text.?);
                        try testing.expectEqual(@intFromPtr(&player) + 4, view.selected().?.address);
                        try testing.expectEqual(.four_bytes, view.selected().?.kind);
                        view.deinit();
                        reparsed.?.deinit();
                        parsed.?.deinit();
                        testing.allocator.free(text.?);
                    },
                    else => {},
                }
                c.ImGui_SetNextWindowPos(.{ .x = 0, .y = 0 }, c.ImGuiCond_Always);
                if (ui.window("struct", .{ .size = .{ 600, 400 } })) |win| {
                    defer win.end();
                    if (frames < 12) {
                        view.draw();
                        var menu = ui.commands("struct", .{ .activated = view.activated() });
                        defer menu.end();
                        view.commands(&menu);
                        const changes = view.takeChanges();
                        if (changes.len > 0) {
                            try testing.expectEqualStrings("u32", changes[0].define.type);
                            text = try salamander.edit.apply(testing.allocator, source, changes, .{});
                            reparsed = try salamander.parse(testing.allocator, text.?, .{}, null);
                            view.setSchema(&reparsed.?.schema);
                        }
                    }
                }
                frames += 1;
            }
        });
    }
};

test {
    _ = tests;
}
