//! Demo windows for ImPlot. ImPlot's own, and one made with `plot` to try the bindings.

const PlotDemo = @This();

const std = @import("std");

const ui = @import("root.zig");
const plot = @import("plot.zig");

implot_open: bool = false,
open: bool = false,

time: f64 = 0,
/// When the next sample is due. Fixed rate, so it doesn't depend on the frame rate.
next_sample: f64 = 0,
/// Ring buffer, `head` is the oldest. Holds more than `span` seconds.
history: [2][history_len]f64 = .{ @splat(0), @splat(0) },
times: [history_len]f64 = @splat(0),
head: usize = 0,
len: usize = 0,
paused: bool = false,

point: plot.Point = .{ 0.5, 0.6 },
line_x: f64 = 0.25,
line_y: f64 = 0.3,
box: plot.Limits = .{ .x = .{ .min = 0.6, .max = 0.9 }, .y = .{ .min = 0.1, .max = 0.4 } },
hovered: plot.DragState = .{},

colormap: plot.Colormap = .viridis,
samples: ?[1000]f64 = null,

pub fn menuItems(self: *PlotDemo) void {
    _ = ui.menuItem("ImPlot demo", .{ .checked = &self.implot_open });
    _ = ui.menuItem("Plot demo", .{ .checked = &self.open });
}

/// Once a frame, on the thread drawing it.
pub fn draw(self: *PlotDemo) void {
    if (self.implot_open) plot.showDemoWindow(&self.implot_open);
    if (self.open) self.drawDemo();
}

fn drawDemo(self: *PlotDemo) void {
    const win = ui.window("Plot demo", .{ .open = &self.open, .size = .{ 760, 600 } }) orelse return;
    defer win.end();
    const tabs = ui.tabBar("tabs") orelse return;
    defer tabs.end();
    if (ui.tabItem("Live", .{})) |tab| {
        defer tab.end();
        self.drawLive();
    }
    if (ui.tabItem("Bars", .{})) |tab| {
        defer tab.end();
        drawBars();
    }
    if (ui.tabItem("Heatmap", .{})) |tab| {
        defer tab.end();
        self.drawHeatmap();
    }
    if (ui.tabItem("Drag", .{})) |tab| {
        defer tab.end();
        self.drawDrag();
    }
    if (ui.tabItem("Histogram", .{})) |tab| {
        defer tab.end();
        self.drawHistogram();
    }
}

const span = 10;
const sample_rate = 100;
const history_len = (span + 2) * sample_rate;

fn drawLive(self: *PlotDemo) void {
    if (!self.paused) self.advance();
    _ = ui.checkbox("Paused", &self.paused);
    ui.sameLine();
    ui.textDisabled("Scroll to zoom, drag to pan, right drag to box zoom, double click to fit", .{});

    plot.setNextAxisLimits(.x1, self.time - span, self.time, .always);
    const c = plot.chart("Signals", .{ .size = .{ -1, -1 } }) orelse return;
    defer c.end();
    plot.setupAxes("Time (s)", null, .{}, .{});
    plot.setupAxisLimits(.y1, -1.5, 1.5, .once);
    plot.setupLegend(.north_west, .{});
    // The ring buffer starts at `head`, so `offset` makes it read in order
    const at: i32 = @intCast(if (self.len < self.times.len) 0 else self.head);
    const n = self.len;
    plot.line("Sine", self.history[0][0..n], .{ .xs = self.times[0..n] }, .{ .offset = at });
    plot.line("Noisy", self.history[1][0..n], .{ .xs = self.times[0..n], .shaded = true }, .{ .offset = at, .fill_alpha = 0.25 });
    if (n > 0) {
        const last = (self.head + self.len - 1) % self.times.len;
        plot.tagY(self.history[0][last], plot.colormapColor(0, null), null);
    }
}

fn advance(self: *PlotDemo) void {
    self.time += ui.getIO().DeltaTime;
    // After a long hitch, skip ahead instead of filling the whole gap
    if (self.time - self.next_sample > span) self.next_sample = self.time - span;
    while (self.next_sample <= self.time) : (self.next_sample += 1.0 / @as(f64, sample_rate)) {
        self.sample(self.next_sample);
    }
}

fn sample(self: *PlotDemo, t: f64) void {
    const i = (self.head + self.len) % self.times.len;
    self.times[i] = t;
    self.history[0][i] = @sin(t * 2);
    self.history[1][i] = 0.5 * @sin(t * 7) + 0.2 * @cos(t * 23);
    if (self.len < self.times.len) self.len += 1 else self.head = (self.head + 1) % self.times.len;
}

fn drawBars() void {
    const labels = [_][:0]const u8{ "Mon", "Tue", "Wed", "Thu", "Fri" };
    const positions = [_]f64{ 0, 1, 2, 3, 4 };
    const fruit = [_][:0]const u8{ "Apples", "Pears", "Plums" };
    const sold = [_]f64{
        8,  12, 5,  9,  14,
        4,  6,  11, 7,  3,
        10, 2,  6,  12, 8,
    };
    {
        const c = plot.chart("Fruit sold", .{ .size = .{ -1, 260 } }) orelse return;
        defer c.end();
        plot.setupAxisTicks(.x1, &positions, &labels, false);
        plot.setupAxes(null, "Crates", .{ .auto_fit = true }, .{ .auto_fit = true });
        plot.barGroups(&fruit, &sold, labels.len, .{}, .{});
    }
    const pie = [_]f64{ 0.42, 0.3, 0.18, 0.1 };
    const slices = [_][:0]const u8{ "Gold", "Wood", "Stone", "Food" };
    const c = plot.chart("##pie", .{ .size = .{ 260, 260 }, .flags = .{ .equal = true, .no_mouse_text = true } }) orelse return;
    defer c.end();
    plot.setupAxes(null, null, plot.AxisFlags.no_decorations, plot.AxisFlags.no_decorations);
    plot.setupAxesLimits(0, 1, 0, 1, .always);
    plot.pieChart(&slices, &pie, 0.5, 0.5, 0.4, .{ .label_format = "%.2f", .exploding = true }, .{});
}

fn drawHeatmap(self: *PlotDemo) void {
    const size = 12;
    var values: [size * size]f64 = undefined;
    for (0..size) |row| for (0..size) |col| {
        const x = @as(f64, @floatFromInt(col)) / size - 0.5;
        const y = @as(f64, @floatFromInt(row)) / size - 0.5;
        values[row * size + col] = @cos(x * 8) * @sin(y * 8) + @sin(self.time);
    };
    if (plot.colormapButton(plot.colormapName(self.colormap), .{ .size = .{ 200, 0 }, .colormap = self.colormap })) {
        self.colormap = @fromBackingInt(@mod(@backingInt(self.colormap) + 1, plot.colormapCount()));
    }
    ui.sameLine();
    ui.textDisabled("Click for the next colormap", .{});
    const cm = plot.withColormap(self.colormap);
    defer cm.end();
    {
        const c = plot.chart("##heat", .{ .size = .{ 400, 400 }, .flags = .{ .no_legend = true, .no_mouse_text = true } }) orelse return;
        defer c.end();
        plot.setupAxes(null, null, plot.AxisFlags.no_decorations, plot.AxisFlags.no_decorations);
        plot.heatmap("heat", &values, size, size, .{ .scale_min = -2, .scale_max = 2, .label_format = null }, .{});
    }
    ui.sameLine();
    plot.colormapScale("##scale", -2, 2, .{ .size = .{ 60, 400 } });
}

fn drawDrag(self: *PlotDemo) void {
    ui.text("Point {d:.2}, {d:.2}   line x {d:.2}   line y {d:.2}", .{ self.point[0], self.point[1], self.line_x, self.line_y });
    if (self.hovered.hovered) {
        ui.sameLine();
        ui.textColored(.{ 0.4, 1, 0.4, 1 }, "over the point", .{});
    }
    const c = plot.chart("##drag", .{ .size = .{ -1, -1 } }) orelse return;
    defer c.end();
    plot.setupAxesLimits(0, 1, 0, 1, .once);
    _ = plot.dragLineX(0, &self.line_x, .{ .color = .{ 1, 0.5, 0, 1 }, .size = 2 });
    _ = plot.dragLineY(1, &self.line_y, .{ .color = .{ 0, 0.6, 1, 1 }, .size = 2 });
    _ = plot.dragRect(2, &self.box, .{ .color = .{ 1, 0, 1, 1 } });
    _ = plot.dragPoint(3, &self.point, .{ .size = 6, .state = &self.hovered });
    plot.annotation(self.point[0], self.point[1], "Drag me", .{ .color = .{ 0.2, 0.2, 0.2, 0.8 }, .offset = .{ 12, -12 }, .clamp = true });
    plot.tagX(self.line_x, .{ 1, 0.5, 0, 1 }, null);
    plot.tagY(self.line_y, .{ 0, 0.6, 1, 1 }, "y");
}

fn drawHistogram(self: *PlotDemo) void {
    if (self.samples == null) {
        var rng: std.Random.DefaultPrng = .init(1);
        var out: [1000]f64 = undefined;
        for (&out) |*v| v.* = rng.random().floatNorm(f64);
        self.samples = out;
    }
    const samples = &self.samples.?;
    const c = plot.chart("Normal samples", .{ .size = .{ -1, -1 } }) orelse return;
    defer c.end();
    plot.setupAxes(null, null, .{ .auto_fit = true }, .{ .auto_fit = true });
    _ = plot.histogram("Samples", samples, .{ .bins = 40, .density = true }, .{ .fill_alpha = 0.5 });
    var xs: [100]f64 = undefined;
    var ys: [100]f64 = undefined;
    for (&xs, &ys, 0..) |*x, *y, i| {
        x.* = -4 + 8 * @as(f64, @floatFromInt(i)) / 99;
        y.* = @exp(-x.* * x.* / 2) / @sqrt(2 * std.math.pi);
    }
    plot.line("Expected", &ys, .{ .xs = &xs }, .{ .line_weight = 2 });
}
