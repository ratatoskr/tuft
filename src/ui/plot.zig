//! ImPlot bindings. Each ImGui context gets its own plots, made on first use.
//! Data is f64. Positions are in plot units unless a name says pixels.

const std = @import("std");

const root = @import("root.zig");
const c = root.c;
const raw = root.raw;
const str = root.str;
const Vec2 = root.Vec2;
const Color = root.Color;

pub const Point = [2]f64;

pub const Range = extern struct {
    min: f64 = 0,
    max: f64 = 0,
};

/// Both axes' ranges.
pub const Limits = extern struct {
    x: Range = .{},
    y: Range = .{},
};

pub const Axis = enum(c_int) { x1, x2, x3, y1, y2, y3 };

pub const Cond = enum {
    /// Only the first time.
    once,
    /// Every frame, which locks it.
    always,
};

pub const Location = enum(c_int) {
    center = 0,
    north = 1,
    south = 2,
    west = 4,
    east = 8,
    north_west = 5,
    north_east = 9,
    south_west = 6,
    south_east = 10,
};

pub const Scale = enum(c_int) { linear, time, log10, sym_log };

pub const Marker = enum(c_int) {
    none = -2,
    /// The next one not used yet.
    auto = -1,
    circle,
    square,
    diamond,
    up,
    down,
    left,
    right,
    cross,
    plus,
    asterisk,
    vertical,
    horizontal,
};

/// The built in ones. `addColormap` gives the others.
pub const Colormap = enum(c_int) {
    deep,
    dark,
    pastel,
    paired,
    viridis,
    plasma,
    hot,
    cool,
    pink,
    jet,
    twilight,
    rd_bu,
    br_bg,
    pi_yg,
    spectral,
    greys,
    _,
};

/// Index into `Style.colors`.
pub const Col = enum(c_int) {
    frame_bg,
    plot_bg,
    plot_border,
    legend_bg,
    legend_border,
    legend_text,
    title_text,
    inlay_text,
    axis_text,
    axis_grid,
    axis_tick,
    axis_bg,
    axis_bg_hovered,
    axis_bg_active,
    selection,
    crosshairs,
};

/// For `bins`. Or pass a count.
pub const bin_sqrt: i32 = -1;
pub const bin_sturges: i32 = -2;
pub const bin_rice: i32 = -3;
pub const bin_scott: i32 = -4;

pub const Flags = bitpack struct(u32) {
    no_title: bool = false,
    no_legend: bool = false,
    no_mouse_text: bool = false,
    no_inputs: bool = false,
    no_menus: bool = false,
    no_box_select: bool = false,
    no_frame: bool = false,
    /// Same units per pixel on x and y.
    equal: bool = false,
    crosshairs: bool = false,
    _: u23 = 0,

    /// Just the plot area, for drawing on.
    pub const canvas_only: Flags = .{ .no_title = true, .no_legend = true, .no_menus = true, .no_box_select = true, .no_mouse_text = true };
};

pub const AxisFlags = bitpack struct(u32) {
    no_label: bool = false,
    no_grid_lines: bool = false,
    no_tick_marks: bool = false,
    no_tick_labels: bool = false,
    no_initial_fit: bool = false,
    no_menus: bool = false,
    no_side_switch: bool = false,
    no_highlight: bool = false,
    /// Ticks and labels on the right or top.
    opposite: bool = false,
    /// Grid lines over the data.
    foreground: bool = false,
    invert: bool = false,
    auto_fit: bool = false,
    /// Fits only to points in the other axis's range.
    range_fit: bool = false,
    pan_stretch: bool = false,
    lock_min: bool = false,
    lock_max: bool = false,
    tick_labels_inside: bool = false,
    _: u15 = 0,

    pub const lock: AxisFlags = .{ .lock_min = true, .lock_max = true };
    /// No label, grid, ticks or tick labels.
    pub const no_decorations: AxisFlags = .{ .no_label = true, .no_grid_lines = true, .no_tick_marks = true, .no_tick_labels = true };
};

pub const SubplotFlags = bitpack struct(u32) {
    no_title: bool = false,
    no_legend: bool = false,
    no_menus: bool = false,
    no_resize: bool = false,
    no_align: bool = false,
    /// One legend for all of them.
    share_items: bool = false,
    link_rows: bool = false,
    link_cols: bool = false,
    link_all_x: bool = false,
    link_all_y: bool = false,
    col_major: bool = false,
    _: u21 = 0,
};

pub const LegendFlags = bitpack struct(u32) {
    /// Clicking an entry doesn't hide it.
    no_buttons: bool = false,
    no_highlight_item: bool = false,
    no_highlight_axis: bool = false,
    no_menus: bool = false,
    outside: bool = false,
    horizontal: bool = false,
    sort: bool = false,
    reverse: bool = false,
    _: u24 = 0,
};

pub const MouseTextFlags = bitpack struct(u32) {
    no_aux_axes: bool = false,
    no_format: bool = false,
    show_always: bool = false,
    _: u29 = 0,
};

pub const DragFlags = bitpack struct(u32) {
    no_cursors: bool = false,
    no_fit: bool = false,
    no_inputs: bool = false,
    /// Draws a frame late, handy when you clamp it after.
    delayed: bool = false,
    no_move: bool = false,
    no_resize: bool = false,
    _: u26 = 0,
};

pub const ColormapScaleFlags = bitpack struct(u32) {
    no_label: bool = false,
    opposite: bool = false,
    invert: bool = false,
    _: u29 = 0,
};

/// How an item looks. Null colours come from the colormap.
pub const Spec = struct {
    line_color: ?Color = null,
    /// Pixels.
    line_weight: f32 = 1,
    fill_color: ?Color = null,
    fill_alpha: f32 = 1,
    marker: Marker = .none,
    /// Radius in pixels.
    marker_size: f32 = 4,
    /// Null uses the line colour.
    marker_line_color: ?Color = null,
    marker_fill_color: ?Color = null,
    /// Error bar whiskers and digital bar height, in pixels.
    size: f32 = 4,
    /// Where to start in the data, for ring buffers.
    offset: i32 = 0,
    no_legend: bool = false,
    no_fit: bool = false,
};

const auto_color: c.ImVec4 = .{ .x = 0, .y = 0, .z = 0, .w = -1 };

fn cSpec(s: Spec, item: u32) c.ImPlot_Spec {
    return .{
        .LineColor = colorOr(s.line_color),
        .LineColors = null,
        .LineWeight = s.line_weight,
        .FillColor = colorOr(s.fill_color),
        .FillColors = null,
        .FillAlpha = s.fill_alpha,
        .Marker = @backingInt(s.marker),
        .MarkerSize = s.marker_size,
        .MarkerSizes = null,
        .MarkerLineColor = colorOr(s.marker_line_color),
        .MarkerLineColors = null,
        .MarkerFillColor = colorOr(s.marker_fill_color),
        .MarkerFillColors = null,
        .Size = s.size,
        .Offset = s.offset,
        // Auto, so the size of a double
        .Stride = -1,
        .Flags = @bitCast(@as(u32, @intFromBool(s.no_legend)) | (@as(u32, @intFromBool(s.no_fit)) << 1) | item),
    };
}

/// An item's own flags start at bit 10, in the order of `names`.
fn itemFlags(options: anytype, comptime names: []const []const u8) u32 {
    var out: u32 = 0;
    inline for (names, 0..) |name, i| {
        if (@field(options, name)) out |= @as(u32, 1) << (10 + i);
    }
    return out;
}

fn colorOr(color: ?Color) c.ImVec4 {
    return if (color) |v| vec4(v) else auto_color;
}

// Plots

pub const PlotOptions = struct {
    /// Pixels, the whole frame. -1 fills, 0 takes the style's default.
    size: Vec2 = .{ -1, 0 },
    flags: Flags = .{},
};

/// Null when off screen. Title must be unique in the window; `##` hides it.
pub fn chart(title: [:0]const u8, options: PlotOptions) ?Chart {
    if (!raw("ImPlot_BeginPlot")(str(title), vec2(options.size), @bitCast(options.flags))) return null;
    return .{};
}

pub const Chart = struct {
    pub fn end(_: Chart) void {
        raw("ImPlot_EndPlot")();
    }
};

pub const SubplotOptions = struct {
    /// Pixels, the whole grid.
    size: Vec2 = .{ -1, 0 },
    flags: SubplotFlags = .{},
};

/// A grid to fill with `chart`s, row by row. Their titles don't need to be unique.
pub fn subplots(title: [:0]const u8, rows: u32, cols: u32, options: SubplotOptions) ?Subplots {
    if (!raw("ImPlot_BeginSubplots")(str(title), @intCast(@max(rows, 1)), @intCast(@max(cols, 1)), vec2(options.size), @bitCast(options.flags))) return null;
    return .{};
}

pub const Subplots = struct {
    pub fn end(_: Subplots) void {
        raw("ImPlot_EndSubplots")();
    }
};

/// Lines up the axes of the `chart`s in it.
pub fn aligned(group: [:0]const u8, vertical: bool) ?Aligned {
    if (!raw("ImPlot_BeginAlignedPlots")(str(group), vertical)) return null;
    return .{};
}

pub const Aligned = struct {
    pub fn end(_: Aligned) void {
        raw("ImPlot_EndAlignedPlots")();
    }
};

// Setup, first thing in a chart

/// Turns on x2, x3, y2 and y3. Null label for none.
pub fn setupAxis(axis: Axis, label: ?[:0]const u8, flags: AxisFlags) void {
    raw("ImPlot_SetupAxis")(@backingInt(axis), optStr(label), @bitCast(flags));
}

pub fn setupAxisLimits(axis: Axis, min: f64, max: f64, cond: Cond) void {
    raw("ImPlot_SetupAxisLimits")(@backingInt(axis), min, max, plotCond(cond));
}

/// printf style for a double, like `%.2f ms`. Default `%g`.
pub fn setupAxisFormat(axis: Axis, format: [:0]const u8) void {
    raw("ImPlot_SetupAxisFormat")(@backingInt(axis), str(format));
}

pub const max_labels = 256;

/// Ticks at `values`. `labels` must match them if given, up to `max_labels`.
pub fn setupAxisTicks(axis: Axis, values: []const f64, labels: ?[]const [:0]const u8, keep_default: bool) void {
    var buf: [max_labels][*c]const u8 = undefined;
    const n = if (labels) |l| @min(values.len, l.len, max_labels) else values.len;
    raw("ImPlot_SetupAxisTicks")(@backingInt(axis), values.ptr, @intCast(n), labelPtrs(labels, &buf), keep_default);
}

/// `count` ticks evenly from `min` to `max`.
pub fn setupAxisTicksRange(axis: Axis, min: f64, max: f64, count: u32, labels: ?[]const [:0]const u8, keep_default: bool) void {
    var buf: [max_labels][*c]const u8 = undefined;
    const n = if (labels) |l| @min(count, l.len, max_labels) else count;
    raw("ImPlot_SetupAxisTicksRange")(@backingInt(axis), min, max, @intCast(n), labelPtrs(labels, &buf), keep_default);
}

pub fn setupAxisScale(axis: Axis, scale: Scale) void {
    raw("ImPlot_SetupAxisScale")(@backingInt(axis), @backingInt(scale));
}

/// How far it can pan.
pub fn setupAxisLimitsConstraints(axis: Axis, min: f64, max: f64) void {
    raw("ImPlot_SetupAxisLimitsConstraints")(@backingInt(axis), min, max);
}

/// How much of the axis it can show, smallest and biggest.
pub fn setupAxisZoomConstraints(axis: Axis, min: f64, max: f64) void {
    raw("ImPlot_SetupAxisZoomConstraints")(@backingInt(axis), min, max);
}

/// x1 and y1 at once.
pub fn setupAxes(x_label: ?[:0]const u8, y_label: ?[:0]const u8, x_flags: AxisFlags, y_flags: AxisFlags) void {
    raw("ImPlot_SetupAxes")(optStr(x_label), optStr(y_label), @bitCast(x_flags), @bitCast(y_flags));
}

pub fn setupAxesLimits(x_min: f64, x_max: f64, y_min: f64, y_max: f64, cond: Cond) void {
    raw("ImPlot_SetupAxesLimits")(x_min, x_max, y_min, y_max, plotCond(cond));
}

pub fn setupLegend(location: Location, flags: LegendFlags) void {
    raw("ImPlot_SetupLegend")(@backingInt(location), @bitCast(flags));
}

/// Where the mouse position shows. Default south east.
pub fn setupMouseText(location: Location, flags: MouseTextFlags) void {
    raw("ImPlot_SetupMouseText")(@backingInt(location), @bitCast(flags));
}

/// Optional. Plotting does it anyway.
pub fn setupFinish() void {
    raw("ImPlot_SetupFinish")();
}

// Before a chart, like from a button

pub fn setNextAxisLimits(axis: Axis, min: f64, max: f64, cond: Cond) void {
    raw("ImPlot_SetNextAxisLimits")(@backingInt(axis), min, max, plotCond(cond));
}

pub fn setNextAxisToFit(axis: Axis) void {
    raw("ImPlot_SetNextAxisToFit")(@backingInt(axis));
}

pub fn setNextAxesLimits(x_min: f64, x_max: f64, y_min: f64, y_max: f64, cond: Cond) void {
    raw("ImPlot_SetNextAxesLimits")(x_min, x_max, y_min, y_max, plotCond(cond));
}

pub fn setNextAxesToFit() void {
    raw("ImPlot_SetNextAxesToFit")();
}

// Items. Labels show in the legend unless they start with `##`

pub const LineOptions = struct {
    /// Null spaces them `x_scale` apart from `x_start`.
    xs: ?[]const f64 = null,
    x_scale: f64 = 1,
    x_start: f64 = 0,
    /// Every two points is its own line.
    segments: bool = false,
    /// Joins the last to the first.
    loop: bool = false,
    skip_nan: bool = false,
    no_clip: bool = false,
    /// Fills down to 0.
    shaded: bool = false,
};

pub fn line(label: [:0]const u8, ys: []const f64, options: LineOptions, spec: Spec) void {
    const s = cSpec(spec, itemFlags(options, &.{ "segments", "loop", "skip_nan", "no_clip", "shaded" }));
    raw("ImPlot_PlotLine")(str(label), xsOf(options.xs), ys.ptr, countOf(options.xs, ys), options.x_scale, options.x_start, &s);
}

pub const ScatterOptions = struct {
    xs: ?[]const f64 = null,
    x_scale: f64 = 1,
    x_start: f64 = 0,
    no_clip: bool = false,
};

/// Circles unless `spec.marker` says otherwise.
pub fn scatter(label: [:0]const u8, ys: []const f64, options: ScatterOptions, spec: Spec) void {
    const s = cSpec(spec, itemFlags(options, &.{"no_clip"}));
    raw("ImPlot_PlotScatter")(str(label), xsOf(options.xs), ys.ptr, countOf(options.xs, ys), options.x_scale, options.x_start, &s);
}

pub const SpacedOptions = struct {
    xs: ?[]const f64 = null,
    x_scale: f64 = 1,
    x_start: f64 = 0,
};

/// Circles sized in plot units.
pub fn bubbles(label: [:0]const u8, ys: []const f64, sizes: []const f64, options: SpacedOptions, spec: Spec) void {
    const s = cSpec(spec, 0);
    const n = @min(countOf(options.xs, ys), sizes.len);
    raw("ImPlot_PlotBubbles")(str(label), xsOf(options.xs), ys.ptr, sizes.ptr, @intCast(n), options.x_scale, options.x_start, &s);
}

pub const PolygonOptions = struct {
    /// Slower, for shapes that aren't convex.
    concave: bool = false,
};

pub fn polygon(label: [:0]const u8, xs: []const f64, ys: []const f64, options: PolygonOptions, spec: Spec) void {
    const s = cSpec(spec, itemFlags(options, &.{"concave"}));
    raw("ImPlot_PlotPolygon")(str(label), xs.ptr, ys.ptr, @intCast(@min(xs.len, ys.len)), &s);
}

pub const StairsOptions = struct {
    xs: ?[]const f64 = null,
    x_scale: f64 = 1,
    x_start: f64 = 0,
    /// Each step holds its value to the left instead.
    pre_step: bool = false,
    shaded: bool = false,
};

pub fn stairs(label: [:0]const u8, ys: []const f64, options: StairsOptions, spec: Spec) void {
    const s = cSpec(spec, itemFlags(options, &.{ "pre_step", "shaded" }));
    raw("ImPlot_PlotStairs")(str(label), xsOf(options.xs), ys.ptr, countOf(options.xs, ys), options.x_scale, options.x_start, &s);
}

pub const ShadedOptions = struct {
    xs: ?[]const f64 = null,
    x_scale: f64 = 1,
    x_start: f64 = 0,
    /// Fills to these instead of `y_ref`.
    ys2: ?[]const f64 = null,
    /// Can be infinite.
    y_ref: f64 = 0,
};

/// Fills between `ys` and `y_ref`, or `ys2`.
pub fn shaded(label: [:0]const u8, ys: []const f64, options: ShadedOptions, spec: Spec) void {
    const s = cSpec(spec, 0);
    var n = countOf(options.xs, ys);
    if (options.ys2) |b| n = @min(n, @as(c_int, @intCast(b.len)));
    raw("ImPlot_PlotShaded")(str(label), xsOf(options.xs), ys.ptr, xsOf(options.ys2), n, options.y_ref, options.x_scale, options.x_start, &s);
}

pub const BarsOptions = struct {
    /// Null puts them at `shift`, `shift + 1` and on.
    xs: ?[]const f64 = null,
    /// Plot units.
    bar_size: f64 = 0.67,
    shift: f64 = 0,
    horizontal: bool = false,
};

pub fn bars(label: [:0]const u8, values: []const f64, options: BarsOptions, spec: Spec) void {
    const s = cSpec(spec, itemFlags(options, &.{"horizontal"}));
    raw("ImPlot_PlotBars")(str(label), xsOf(options.xs), values.ptr, countOf(options.xs, values), options.bar_size, options.shift, &s);
}

pub const BarGroupsOptions = struct {
    /// Plot units.
    group_size: f64 = 0.67,
    shift: f64 = 0,
    horizontal: bool = false,
    stacked: bool = false,
};

/// One item per label. `values` is a row of `groups` for each, one after the other.
pub fn barGroups(labels: []const [:0]const u8, values: []const f64, groups: u32, options: BarGroupsOptions, spec: Spec) void {
    if (groups == 0) return;
    var buf: [max_labels][*c]const u8 = undefined;
    const items = @min(labels.len, max_labels, values.len / groups);
    const s = cSpec(spec, itemFlags(options, &.{ "horizontal", "stacked" }));
    raw("ImPlot_PlotBarGroups")(labelPtrs(labels, &buf), values.ptr, @intCast(items), @intCast(groups), options.group_size, options.shift, &s);
}

pub const ErrorBarsOptions = struct {
    /// Null makes `errors` go both ways, otherwise they're the negative side.
    positive: ?[]const f64 = null,
    horizontal: bool = false,
};

pub fn errorBars(label: [:0]const u8, xs: []const f64, ys: []const f64, errors: []const f64, options: ErrorBarsOptions, spec: Spec) void {
    const s = cSpec(spec, itemFlags(options, &.{"horizontal"}));
    var n = @min(xs.len, ys.len, errors.len);
    if (options.positive) |p| n = @min(n, p.len);
    raw("ImPlot_PlotErrorBars")(str(label), xs.ptr, ys.ptr, errors.ptr, xsOf(options.positive), @intCast(n), &s);
}

pub const StemsOptions = struct {
    xs: ?[]const f64 = null,
    x_scale: f64 = 1,
    x_start: f64 = 0,
    /// Where the stems start.
    ref: f64 = 0,
    horizontal: bool = false,
};

pub fn stems(label: [:0]const u8, ys: []const f64, options: StemsOptions, spec: Spec) void {
    const s = cSpec(spec, itemFlags(options, &.{"horizontal"}));
    raw("ImPlot_PlotStems")(str(label), xsOf(options.xs), ys.ptr, countOf(options.xs, ys), options.ref, options.x_scale, options.x_start, &s);
}

pub const InfLinesOptions = struct {
    horizontal: bool = false,
};

/// Lines right across the plot at each value.
pub fn infLines(label: [:0]const u8, values: []const f64, options: InfLinesOptions, spec: Spec) void {
    const s = cSpec(spec, itemFlags(options, &.{"horizontal"}));
    raw("ImPlot_PlotInfLines")(str(label), values.ptr, @intCast(values.len), &s);
}

pub const PieChartOptions = struct {
    /// printf style for each slice's value. Null for none.
    label_format: ?[:0]const u8 = "%.1f",
    /// Degrees, where the first slice starts.
    angle0: f64 = 90,
    /// Always a full circle.
    normalize: bool = false,
    ignore_hidden: bool = false,
    /// Pulls out the slice whose legend entry is hovered.
    exploding: bool = false,
    no_slice_border: bool = false,
};

/// A slice per label, centred on `x`, `y`.
pub fn pieChart(labels: []const [:0]const u8, values: []const f64, x: f64, y: f64, radius: f64, options: PieChartOptions, spec: Spec) void {
    var buf: [max_labels][*c]const u8 = undefined;
    const n = @min(labels.len, values.len, max_labels);
    const s = cSpec(spec, itemFlags(options, &.{ "normalize", "ignore_hidden", "exploding", "no_slice_border" }));
    raw("ImPlot_PlotPieChart")(labelPtrs(labels, &buf), values.ptr, @intCast(n), x, y, radius, optStr(options.label_format), options.angle0, &s);
}

pub const HeatmapOptions = struct {
    /// Both 0 takes them from the data.
    scale_min: f64 = 0,
    scale_max: f64 = 0,
    /// printf style for each cell. Null for none.
    label_format: ?[:0]const u8 = "%.1f",
    bounds_min: Point = .{ 0, 0 },
    bounds_max: Point = .{ 1, 1 },
    col_major: bool = false,
};

/// `values` is `rows` rows of `cols`, coloured by the colormap.
pub fn heatmap(label: [:0]const u8, values: []const f64, rows: u32, cols: u32, options: HeatmapOptions, spec: Spec) void {
    if (@as(u64, rows) * cols > values.len) return;
    const s = cSpec(spec, itemFlags(options, &.{"col_major"}));
    raw("ImPlot_PlotHeatmap")(str(label), values.ptr, @intCast(rows), @intCast(cols), options.scale_min, options.scale_max, optStr(options.label_format), point(options.bounds_min), point(options.bounds_max), &s);
}

pub const HistogramOptions = struct {
    /// A count, or one of the `bin_` ones.
    bins: i32 = bin_sturges,
    /// Multiplies the counts.
    bar_scale: f64 = 1,
    /// Null covers all the data.
    range: ?Range = null,
    horizontal: bool = false,
    cumulative: bool = false,
    /// Counts add up to 1.
    density: bool = false,
    no_outliers: bool = false,
};

/// The biggest bin's count.
pub fn histogram(label: [:0]const u8, values: []const f64, options: HistogramOptions, spec: Spec) f64 {
    const s = cSpec(spec, itemFlags(options, &.{ "horizontal", "cumulative", "density", "no_outliers" }));
    const r = options.range orelse Range{};
    return raw("ImPlot_PlotHistogram")(str(label), values.ptr, @intCast(values.len), options.bins, options.bar_scale, .{ .Min = r.min, .Max = r.max }, &s);
}

pub const Histogram2dOptions = struct {
    x_bins: i32 = bin_sturges,
    y_bins: i32 = bin_sturges,
    /// Null covers all the data.
    range: ?Limits = null,
    density: bool = false,
    no_outliers: bool = false,
    col_major: bool = false,
};

/// A heatmap of how many points land in each bin. Gives the biggest count.
pub fn histogram2d(label: [:0]const u8, xs: []const f64, ys: []const f64, options: Histogram2dOptions, spec: Spec) f64 {
    const flags = itemFlags(options, &.{ "density", "no_outliers", "col_major" }) << 2;
    const s = cSpec(spec, flags);
    const r = options.range orelse Limits{};
    const range: c.ImPlot_Rect = .{ .X = .{ .Min = r.x.min, .Max = r.x.max }, .Y = .{ .Min = r.y.min, .Max = r.y.max } };
    return raw("ImPlot_PlotHistogram2D")(str(label), xs.ptr, ys.ptr, @intCast(@min(xs.len, ys.len)), options.x_bins, options.y_bins, range, &s);
}

/// On and off signals stacked along the bottom, they don't move with y.
pub fn digital(label: [:0]const u8, xs: []const f64, ys: []const f64, spec: Spec) void {
    const s = cSpec(spec, 0);
    raw("ImPlot_PlotDigital")(str(label), xs.ptr, ys.ptr, @intCast(@min(xs.len, ys.len)), &s);
}

pub const TextOptions = struct {
    /// Pixels.
    offset: Vec2 = .{ 0, 0 },
    vertical: bool = false,
};

/// Text centred on a point.
pub fn text(content: [:0]const u8, x: f64, y: f64, options: TextOptions, spec: Spec) void {
    const s = cSpec(spec, itemFlags(options, &.{"vertical"}));
    raw("ImPlot_PlotText")(str(content), x, y, vec2(options.offset), &s);
}

/// Just a legend entry.
pub fn dummy(label: [:0]const u8, spec: Spec) void {
    const s = cSpec(spec, 0);
    raw("ImPlot_PlotDummy")(str(label), &s);
}

// Tools

pub const DragState = struct {
    clicked: bool = false,
    hovered: bool = false,
    held: bool = false,
};

pub const DragOptions = struct {
    color: Color = .{ 0, 0.9, 0, 1 },
    /// Pixels, the point's radius or the line's thickness.
    size: f32 = 4,
    flags: DragFlags = .{},
    /// Gets how the mouse is on it.
    state: ?*DragState = null,
};

/// A point you can drag, `id` unique in the chart. True when it moved.
pub fn dragPoint(id: i32, at: *Point, options: DragOptions) bool {
    var st: DragState = .{};
    defer if (options.state) |out| {
        out.* = st;
    };
    return raw("ImPlot_DragPoint")(id, &at[0], &at[1], vec4(options.color), options.size, @bitCast(options.flags), &st.clicked, &st.hovered, &st.held);
}

/// An up and down line you drag along x.
pub fn dragLineX(id: i32, x: *f64, options: DragOptions) bool {
    var st: DragState = .{};
    defer if (options.state) |out| {
        out.* = st;
    };
    return raw("ImPlot_DragLineX")(id, x, vec4(options.color), options.size, @bitCast(options.flags), &st.clicked, &st.hovered, &st.held);
}

/// A side to side line you drag along y.
pub fn dragLineY(id: i32, y: *f64, options: DragOptions) bool {
    var st: DragState = .{};
    defer if (options.state) |out| {
        out.* = st;
    };
    return raw("ImPlot_DragLineY")(id, y, vec4(options.color), options.size, @bitCast(options.flags), &st.clicked, &st.hovered, &st.held);
}

/// `size` isn't used.
pub fn dragRect(id: i32, rect: *Limits, options: DragOptions) bool {
    var st: DragState = .{};
    defer if (options.state) |out| {
        out.* = st;
    };
    return raw("ImPlot_DragRect")(id, &rect.x.min, &rect.y.min, &rect.x.max, &rect.y.max, vec4(options.color), @bitCast(options.flags), &st.clicked, &st.hovered, &st.held);
}

pub const AnnotationOptions = struct {
    /// Its background. Clear means plain text.
    color: Color = .{ 0, 0, 0, 0 },
    /// Pixels.
    offset: Vec2 = .{ 0, 0 },
    /// Keeps it inside the plot.
    clamp: bool = false,
};

/// A label at a point.
pub fn annotation(x: f64, y: f64, content: [:0]const u8, options: AnnotationOptions) void {
    raw("ImPlot_Annotation")(x, y, vec4(options.color), vec2(options.offset), options.clamp, str(content));
}

/// A label on the x axis. Null text shows the value.
pub fn tagX(x: f64, color: Color, content: ?[:0]const u8) void {
    raw("ImPlot_TagX")(x, vec4(color), optStr(content));
}

pub fn tagY(y: f64, color: Color, content: ?[:0]const u8) void {
    raw("ImPlot_TagY")(y, vec4(color), optStr(content));
}

// Inside a chart

/// The axis the next items use. Turn it on with `setupAxis` first.
pub fn setAxis(axis: Axis) void {
    raw("ImPlot_SetAxis")(@backingInt(axis));
}

pub fn setAxes(x: Axis, y: Axis) void {
    raw("ImPlot_SetAxes")(@backingInt(x), @backingInt(y));
}

/// Null axes are the current ones.
pub fn pixelsToPlot(pixels: Vec2, x: ?Axis, y: ?Axis) Point {
    return fromPoint(raw("ImPlot_PixelsToPlot")(vec2(pixels), axisOr(x), axisOr(y)));
}

pub fn plotToPixels(at: Point, x: ?Axis, y: ?Axis) Vec2 {
    const v = raw("ImPlot_PlotToPixels")(point(at), axisOr(x), axisOr(y));
    return .{ v.x, v.y };
}

/// Top left of the plot area, in pixels.
pub fn plotPos() Vec2 {
    const v = raw("ImPlot_GetPlotPos")();
    return .{ v.x, v.y };
}

pub fn plotSize() Vec2 {
    const v = raw("ImPlot_GetPlotSize")();
    return .{ v.x, v.y };
}

pub fn mousePos(x: ?Axis, y: ?Axis) Point {
    return fromPoint(raw("ImPlot_GetPlotMousePos")(axisOr(x), axisOr(y)));
}

/// What's in view.
pub fn limits(x: ?Axis, y: ?Axis) Limits {
    return fromRect(raw("ImPlot_GetPlotLimits")(axisOr(x), axisOr(y)));
}

pub fn isPlotHovered() bool {
    return raw("ImPlot_IsPlotHovered")();
}

pub fn isAxisHovered(axis: Axis) bool {
    return raw("ImPlot_IsAxisHovered")(@backingInt(axis));
}

pub fn isSubplotsHovered() bool {
    return raw("ImPlot_IsSubplotsHovered")();
}

/// A box was dragged out with the right mouse button.
pub fn isPlotSelected() bool {
    return raw("ImPlot_IsPlotSelected")();
}

pub fn selection(x: ?Axis, y: ?Axis) Limits {
    return fromRect(raw("ImPlot_GetPlotSelection")(axisOr(x), axisOr(y)));
}

pub fn cancelSelection() void {
    raw("ImPlot_CancelPlotSelection")();
}

/// Before the item. `once` lets the user show it again.
pub fn hideNextItem(hidden: bool, cond: Cond) void {
    raw("ImPlot_HideNextItem")(hidden, plotCond(cond));
}

pub fn isLegendEntryHovered(label: [:0]const u8) bool {
    return raw("ImPlot_IsLegendEntryHovered")(str(label));
}

/// A popup for an item's legend entry, null when it's closed. Put it after the item.
pub fn legendPopup(label: [:0]const u8, button: root.MouseButton) ?LegendPopup {
    if (!raw("ImPlot_BeginLegendPopup")(str(label), @backingInt(button))) return null;
    return .{};
}

pub const LegendPopup = struct {
    pub fn end(_: LegendPopup) void {
        raw("ImPlot_EndLegendPopup")();
    }
};

/// The last item's colour, for matching other things to it.
pub fn lastItemColor() Color {
    return fromVec4(raw("ImPlot_GetLastItemColor")());
}

/// Draws in the plot, in pixels. Use `clipRect` to keep it inside.
pub fn drawList() root.DrawList {
    return .{ .ptr = @ptrCast(raw("ImPlot_GetPlotDrawList")()) };
}

/// Clips drawing to the plot area until `end`.
pub fn clipRect(expand: f32) ClipRect {
    raw("ImPlot_PushPlotClipRect")(expand);
    return .{};
}

pub const ClipRect = struct {
    pub fn end(_: ClipRect) void {
        raw("ImPlot_PopPlotClipRect")();
    }
};

/// A legend style colour square, inline like text.
pub fn itemIcon(color: Color) void {
    raw("ImPlot_ItemIcon")(vec4(color));
}

pub fn colormapIcon(cmap: Colormap) void {
    raw("ImPlot_ColormapIcon")(@backingInt(cmap));
}

// Style

pub const Style = extern struct {
    /// Used for a 0 size.
    plot_default_size: Vec2,
    plot_min_size: Vec2,
    plot_border_size: f32,
    minor_alpha: f32,
    major_tick_len: Vec2,
    minor_tick_len: Vec2,
    major_tick_size: Vec2,
    minor_tick_size: Vec2,
    major_grid_size: Vec2,
    minor_grid_size: Vec2,
    plot_padding: Vec2,
    label_padding: Vec2,
    legend_padding: Vec2,
    legend_inner_padding: Vec2,
    legend_spacing: Vec2,
    mouse_pos_padding: Vec2,
    annotation_padding: Vec2,
    /// Extra room when fitting, as a fraction.
    fit_padding: Vec2,
    digital_padding: f32,
    digital_spacing: f32,
    /// A w of -1 means auto.
    colors: [@typeInfo(Col).@"enum".field_names.len]Color,
    colormap: Colormap,
    use_local_time: bool,
    use_iso8601: bool,
    use_24_hour_clock: bool,

    pub fn color(self: *Style, which: Col) *Color {
        return &self.colors[@intCast(@backingInt(which))];
    }
};

comptime {
    std.debug.assert(@sizeOf(Style) == @sizeOf(c.ImPlot_Style));
    std.debug.assert(@offsetOf(Style, "colormap") == @offsetOf(c.ImPlot_Style, "Colormap"));
}

/// The current ImGui context's. Change it in place, it's kept.
pub fn style() *Style {
    return @ptrCast(raw("ImPlot_GetStyle")());
}

pub const Theme = enum {
    /// Follows ImGui's colours.
    auto,
    classic,
    dark,
    light,
};

pub fn styleColors(theme: Theme) void {
    switch (theme) {
        .auto => raw("ImPlot_StyleColorsAuto")(),
        .classic => raw("ImPlot_StyleColorsClassic")(),
        .dark => raw("ImPlot_StyleColorsDark")(),
        .light => raw("ImPlot_StyleColorsLight")(),
    }
}

/// Uses `color` for `col` until `end`.
pub fn withColor(col: Col, color: Color) StyleColor {
    raw("ImPlot_PushStyleColor")(@backingInt(col), vec4(color));
    return .{};
}

pub const StyleColor = struct {
    pub fn end(_: StyleColor) void {
        raw("ImPlot_PopStyleColor")(1);
    }
};

// Colormaps. Null means the current one

/// Qualitative ones are separate colours, not a gradient. Names must be new.
pub fn addColormap(name: [:0]const u8, colors: []const Color, qualitative: bool) Colormap {
    return @fromBackingInt(raw("ImPlot_AddColormap")(str(name), @ptrCast(colors.ptr), @intCast(colors.len), qualitative));
}

pub fn colormapCount() i32 {
    return raw("ImPlot_GetColormapCount")();
}

pub fn colormapName(cmap: Colormap) [:0]const u8 {
    const name = raw("ImPlot_GetColormapName")(@backingInt(cmap));
    return if (name != null) std.mem.span(@as([*:0]const u8, @ptrCast(name))) else "";
}

pub fn colormapIndex(name: [:0]const u8) ?Colormap {
    const i = raw("ImPlot_GetColormapIndex")(str(name));
    return if (i < 0) null else @fromBackingInt(i);
}

/// The items in it use `cmap` until `end`.
pub fn withColormap(cmap: Colormap) ColormapScope {
    raw("ImPlot_PushColormap")(@backingInt(cmap));
    return .{};
}

pub const ColormapScope = struct {
    pub fn end(_: ColormapScope) void {
        raw("ImPlot_PopColormap")(1);
    }
};

/// Takes it, so the next item gets the one after.
pub fn nextColormapColor() Color {
    return fromVec4(raw("ImPlot_NextColormapColor")());
}

pub fn colormapSize(cmap: ?Colormap) i32 {
    return raw("ImPlot_GetColormapSize")(cmapOr(cmap));
}

/// Wraps around.
pub fn colormapColor(index: i32, cmap: ?Colormap) Color {
    return fromVec4(raw("ImPlot_GetColormapColor")(index, cmapOr(cmap)));
}

/// `t` from 0 to 1.
pub fn sampleColormap(t: f32, cmap: ?Colormap) Color {
    return fromVec4(raw("ImPlot_SampleColormap")(t, cmapOr(cmap)));
}

pub const ColormapScaleOptions = struct {
    /// Pixels. 0 takes the default.
    size: Vec2 = .{ 0, 0 },
    format: [:0]const u8 = "%g",
    flags: ColormapScaleFlags = .{},
    colormap: ?Colormap = null,
};

/// A colour bar with an axis, like next to a heatmap.
pub fn colormapScale(label: [:0]const u8, min: f64, max: f64, options: ColormapScaleOptions) void {
    raw("ImPlot_ColormapScale")(str(label), min, max, vec2(options.size), str(options.format), @bitCast(options.flags), cmapOr(options.colormap));
}

pub const ColormapSliderOptions = struct {
    format: [:0]const u8 = "",
    colormap: ?Colormap = null,
};

/// `t` from 0 to 1.
pub fn colormapSlider(label: [:0]const u8, t: *f32, options: ColormapSliderOptions) bool {
    return raw("ImPlot_ColormapSlider")(str(label), t, null, str(options.format), cmapOr(options.colormap));
}

pub const ColormapButtonOptions = struct {
    /// Pixels. 0 takes the default.
    size: Vec2 = .{ 0, 0 },
    colormap: ?Colormap = null,
};

pub fn colormapButton(label: [:0]const u8, options: ColormapButtonOptions) bool {
    return raw("ImPlot_ColormapButton")(str(label), vec2(options.size), cmapOr(options.colormap));
}

/// Items keep their colours between frames, this forgets them. Null for every chart.
pub fn bustColorCache(title: ?[:0]const u8) void {
    raw("ImPlot_BustColorCache")(optStr(title));
}

// Demo and tools

/// ImPlot's own demo of everything. Draws while `open` and clears it when closed.
pub fn showDemoWindow(open: *bool) void {
    raw("ImPlot_ShowDemoWindow")(open);
}

pub fn showMetricsWindow(open: *bool) void {
    raw("ImPlot_ShowMetricsWindow")(open);
}

/// Inline, in a window of yours.
pub fn showStyleEditor() void {
    raw("ImPlot_ShowStyleEditor")();
}

pub fn showUserGuide() void {
    raw("ImPlot_ShowUserGuide")();
}

pub fn showStyleSelector(label: [:0]const u8) bool {
    return raw("ImPlot_ShowStyleSelector")(str(label));
}

pub fn showColormapSelector(label: [:0]const u8) bool {
    return raw("ImPlot_ShowColormapSelector")(str(label));
}

pub fn showInputMapSelector(label: [:0]const u8) bool {
    return raw("ImPlot_ShowInputMapSelector")(str(label));
}

fn plotCond(value: Cond) c_int {
    return switch (value) {
        .once => c.ImGuiCond_Once,
        .always => c.ImGuiCond_Always,
    };
}

fn axisOr(axis: ?Axis) c_int {
    return if (axis) |a| @backingInt(a) else -1;
}

fn cmapOr(cmap: ?Colormap) c_int {
    return if (cmap) |m| @backingInt(m) else -1;
}

fn optStr(s: ?[:0]const u8) [*c]const u8 {
    return if (s) |v| str(v) else null;
}

fn xsOf(xs: ?[]const f64) [*c]const f64 {
    return if (xs) |v| v.ptr else null;
}

fn countOf(xs: ?[]const f64, ys: []const f64) c_int {
    const n = if (xs) |v| @min(v.len, ys.len) else ys.len;
    return @intCast(@min(n, std.math.maxInt(c_int)));
}

fn labelPtrs(labels: ?[]const [:0]const u8, buf: *[max_labels][*c]const u8) [*c]const [*c]const u8 {
    const l = labels orelse return null;
    const n = @min(l.len, max_labels);
    for (l[0..n], buf[0..n]) |s, *p| p.* = str(s);
    return buf;
}

fn point(p: Point) c.ImPlot_Point {
    return .{ .x = p[0], .y = p[1] };
}

fn fromPoint(p: c.ImPlot_Point) Point {
    return .{ p.x, p.y };
}

fn fromRect(r: c.ImPlot_Rect) Limits {
    return .{ .x = .{ .min = r.X.Min, .max = r.X.Max }, .y = .{ .min = r.Y.Min, .max = r.Y.Max } };
}

fn vec2(v: Vec2) c.ImVec2 {
    return .{ .x = v[0], .y = v[1] };
}

fn vec4(v: Color) c.ImVec4 {
    return .{ .x = v[0], .y = v[1], .z = v[2], .w = v[3] };
}

fn fromVec4(v: c.ImPlot_Vec4) Color {
    return .{ v.x, v.y, v.z, v.w };
}

test "flags match" {
    try std.testing.expectEqual(c.ImPlot_Col_COUNT, @typeInfo(Col).@"enum".field_names.len);
    try std.testing.expectEqual(c.ImPlot_Marker_COUNT, @typeInfo(Marker).@"enum".field_names.len - 2);
    try std.testing.expectEqual(c.ImPlot_Axis_COUNT, @typeInfo(Axis).@"enum".field_names.len);
    try std.testing.expectEqual(@as(u32, 1 << 8), @as(u32, @bitCast(Flags{ .crosshairs = true })));
    try std.testing.expectEqual(@as(u32, 1 << 16), @as(u32, @bitCast(AxisFlags{ .tick_labels_inside = true })));
    try std.testing.expectEqual(@as(u32, 1 << 10), @as(u32, @bitCast(SubplotFlags{ .col_major = true })));
    try std.testing.expectEqual(@as(u32, (1 << 11) | (1 << 14)), itemFlags(LineOptions{ .loop = true, .shaded = true }, &.{ "segments", "loop", "skip_nan", "no_clip", "shaded" }));
    const s = cSpec(.{ .no_fit = true }, 1 << 10);
    try std.testing.expectEqual(@as(c_int, 2 | (1 << 10)), s.Flags);
    try std.testing.expectEqual(@as(f32, -1), s.LineColor.w);
}
