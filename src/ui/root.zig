//! Dear ImGui for Zig, for host and plugins. Only call inside a frame, on its thread.

const std = @import("std");

/// The dear_bindings C API.
pub const c = @import("tuft_imgui_c");

/// Built-against version. The host must match since struct layouts are shared.
pub const version: u32 = c.IMGUI_VERSION_NUM;

pub const Vec2 = [2]f32;
pub const Color = [4]f32;

/// Looks up a C API function by name, null if missing.
pub const Resolver = *const fn (name: []const u8) ?*const anyopaque;

var resolver: ?Resolver = null;
/// `bind` bumps this so older bindings get looked up again.
var generation: u32 = 0;

/// Call before anything else.
pub fn bind(r: ?Resolver) void {
    resolver = r;
    generation +%= 1;
}

pub fn isBound() bool {
    return resolver != null;
}

/// A C API function by name.
pub fn raw(comptime name: []const u8) *const @TypeOf(@field(c, name)) {
    const F = @TypeOf(@field(c, name));
    // Capturing `name` stops functions with the same type sharing a slot
    const Slot = struct {
        const function = name;
        var ptr: ?*const F = null;
        var gen: u32 = 0;
    };
    if (Slot.ptr) |p| {
        if (Slot.gen == generation) return p;
    }
    const r = resolver orelse @panic("ImGui used before the UI was bound");
    const p: *const F = @ptrCast(@alignCast(r(name) orelse @panic("ImGui function not available: " ++ name)));
    Slot.ptr = p;
    Slot.gen = generation;
    return p;
}

/// Like `raw` for a function that isn't in `c`, typed by hand. Null if the host doesn't have it.
pub fn rawOptional(comptime F: type, comptime name: []const u8) ?*const F {
    const Slot = struct {
        const function = name;
        var ptr: ?*const F = null;
        var gen: u32 = 0;
        var looked = false;
    };
    if (Slot.looked and Slot.gen == generation) return Slot.ptr;
    const r = resolver orelse return null;
    Slot.ptr = if (r(name)) |p| @ptrCast(@alignCast(p)) else null;
    Slot.gen = generation;
    Slot.looked = true;
    return Slot.ptr;
}

pub const WindowFlags = bitpack struct {
    no_title_bar: bool = false,
    no_resize: bool = false,
    no_move: bool = false,
    no_scrollbar: bool = false,
    no_collapse: bool = false,
    always_auto_resize: bool = false,
    no_background: bool = false,
    no_saved_settings: bool = false,
    no_inputs: bool = false,
    menu_bar: bool = false,
    horizontal_scrollbar: bool = false,
    no_focus_on_appearing: bool = false,
    no_nav: bool = false,
    no_docking: bool = false,
    /// A dot in the title or tab, without changing its id.
    unsaved_document: bool = false,
};

pub const Cond = enum { always, once, first_use_ever, appearing };

/// Sizes are unscaled.
pub const WindowOptions = struct {
    /// Shows a close button that clears this.
    open: ?*bool = null,
    flags: WindowFlags = .{},
    /// Starting size, clamped to the screen.
    size: ?Vec2 = null,
    size_cond: Cond = .first_use_ever,
    /// Resizable windows default to `default_min_size`.
    min_size: ?Vec2 = null,
    /// 0 means no limit that way.
    max_size: ?Vec2 = null,
};

pub const default_min_size: Vec2 = .{ 240, 120 };

/// Null when collapsed or clipped.
pub fn window(name: [:0]const u8, options: WindowOptions) ?WindowScope {
    const display = displaySize();
    if (options.size) |s| {
        // Bigger than the screen would put its edges and resize grip off screen
        const fitted: Vec2 = .{ @min(scaled(s[0]), display[0] * 0.9), @min(scaled(s[1]), display[1] * 0.9) };
        raw("ImGui_SetNextWindowSize")(vec2(fitted), cond(options.size_cond));
    }
    const auto = options.flags.always_auto_resize or options.flags.no_resize;
    const min: ?Vec2 = options.min_size orelse if (auto) null else default_min_size;
    if (min != null or options.max_size != null) {
        const lo = min orelse Vec2{ 0, 0 };
        const hi = options.max_size orelse Vec2{ 0, 0 };
        const max_x = if (hi[0] > 0) scaled(hi[0]) else std.math.floatMax(f32);
        const max_y = if (hi[1] > 0) scaled(hi[1]) else std.math.floatMax(f32);
        // Min beats a smaller screen's limit, or it could never be met
        raw("ImGui_SetNextWindowSizeConstraints")(
            .{ .x = @min(scaled(lo[0]), display[0]), .y = @min(scaled(lo[1]), display[1]) },
            .{ .x = @max(max_x, @min(scaled(lo[0]), display[0])), .y = @max(max_y, @min(scaled(lo[1]), display[1])) },
            null,
            null,
        );
    }
    if (raw("ImGui_Begin")(str(name), options.open, flags(c.ImGuiWindowFlags, "ImGuiWindowFlags_", options.flags))) return .{};
    raw("ImGui_End")();
    return null;
}

/// DPI times the user's overlay scale.
pub fn scale() f32 {
    const s = raw("ImGui_GetStyle")().*.FontScaleDpi;
    return if (s > 0) s else 1;
}

pub fn scaled(value: f32) f32 {
    return value * scale();
}

fn displaySize() Vec2 {
    const d = getDisplaySize();
    return .{ if (d[0] > 0) d[0] else std.math.floatMax(f32), if (d[1] > 0) d[1] else std.math.floatMax(f32) };
}

/// Pixels ImGui draws to, the game window in an overlay or the main viewport with viewports on.
/// Starts at `getMainViewportPos` in the screen pixels draw lists use. 0 before the first frame.
pub fn getDisplaySize() Vec2 {
    const d = raw("ImGui_GetIO")().*.DisplaySize;
    return .{ d.x, d.y };
}

/// Where `getDisplaySize`'s area starts in screen pixels. 0,0 unless viewports are on, as in a
/// workbench, where it's the main window's corner on the desktop.
pub fn getMainViewportPos() Vec2 {
    return fromVec2(raw("ImGui_GetMainViewport")().*.Pos);
}

pub const WindowScope = struct {
    pub fn end(_: WindowScope) void {
        raw("ImGui_End")();
    }
};

pub const ChildOptions = struct {
    border: bool = false,
    horizontal_scrollbar: bool = false,
};

/// Null when clipped. 0 size fills the rest, negative leaves that much free.
pub fn child(id_: [:0]const u8, size: Vec2, options: ChildOptions) ?Child {
    const child_flags: c.ImGuiChildFlags = if (options.border) c.ImGuiChildFlags_Borders else 0;
    const window_flags: c.ImGuiWindowFlags = if (options.horizontal_scrollbar) c.ImGuiWindowFlags_HorizontalScrollbar else 0;
    if (raw("ImGui_BeginChild")(str(id_), vec2(size), child_flags, window_flags)) return .{};
    raw("ImGui_EndChild")();
    return null;
}

pub const Child = struct {
    pub fn end(_: Child) void {
        raw("ImGui_EndChild")();
    }
};

/// Null when clipped. Put `tabItem`s in it.
pub fn tabBar(id_: [:0]const u8) ?TabBar {
    if (raw("ImGui_BeginTabBar")(str(id_), 0)) return .{};
    return null;
}

pub const TabBar = struct {
    pub fn end(_: TabBar) void {
        raw("ImGui_EndTabBar")();
    }
};

pub const TabItemOptions = struct {
    /// Switch to it this frame.
    select: bool = false,
};

/// Non-null for the one showing.
pub fn tabItem(label: [:0]const u8, options: TabItemOptions) ?TabItem {
    const item_flags: c.ImGuiTabItemFlags = if (options.select) c.ImGuiTabItemFlags_SetSelected else 0;
    if (raw("ImGui_BeginTabItem")(str(label), null, item_flags)) return .{};
    return null;
}

pub const TabItem = struct {
    pub fn end(_: TabItem) void {
        raw("ImGui_EndTabItem")();
    }
};

/// Scopes widget IDs until `end`. Takes a string, int or pointer.
pub fn id(value: anytype) Id {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .int, .comptime_int => raw("ImGui_PushIDInt")(@intCast(value)),
        .pointer => |p| if (p.size == .slice or (p.size == .one and @typeInfo(p.child) == .array)) {
            const s: []const u8 = value;
            raw("ImGui_PushIDStr")(@ptrCast(s.ptr), @ptrCast(s.ptr + s.len));
        } else {
            raw("ImGui_PushIDPtr")(@ptrCast(value));
        },
        else => @compileError("ui.id takes a string, integer or pointer, not " ++ @typeName(T)),
    }
    return .{};
}

pub const Id = struct {
    pub fn end(_: Id) void {
        raw("ImGui_PopID")();
    }
};

/// Greys out and ignores input until `end`.
pub fn disabled(is_disabled: bool) Disabled {
    raw("ImGui_BeginDisabled")(is_disabled);
    return .{};
}

pub const Disabled = struct {
    pub fn end(_: Disabled) void {
        raw("ImGui_EndDisabled")();
    }
};

/// Null when closed.
pub fn treeNode(label: [:0]const u8) ?TreeNode {
    return if (raw("ImGui_TreeNode")(str(label))) .{} else null;
}

pub const TreeNode = struct {
    pub fn end(_: TreeNode) void {
        raw("ImGui_TreePop")();
    }
};

/// Hides what follows while collapsed. No `end`.
pub fn collapsingHeader(label: [:0]const u8, default_open: bool) bool {
    return raw("ImGui_CollapsingHeader")(str(label), if (default_open) c.ImGuiTreeNodeFlags_DefaultOpen else 0);
}

/// The window needs `.menu_bar`.
pub fn menuBar() ?MenuBar {
    return if (raw("ImGui_BeginMenuBar")()) .{} else null;
}

pub const MenuBar = struct {
    pub fn end(_: MenuBar) void {
        raw("ImGui_EndMenuBar")();
    }
};

/// The bar along the top of the screen.
pub fn mainMenuBar() ?MainMenuBar {
    return if (raw("ImGui_BeginMainMenuBar")()) .{} else null;
}

pub const MainMenuBar = struct {
    pub fn end(_: MainMenuBar) void {
        raw("ImGui_EndMainMenuBar")();
    }
};

/// Null while closed.
pub fn menu(label: [:0]const u8) ?Menu {
    return if (raw("ImGui_BeginMenu")(str(label))) .{} else null;
}

pub const Menu = struct {
    pub fn end(_: Menu) void {
        raw("ImGui_EndMenu")();
    }
};

pub const MenuItemOptions = struct {
    /// Display only, it doesn't bind anything.
    shortcut: ?[:0]const u8 = null,
    /// Check mark that toggles on click.
    checked: ?*bool = null,
    enabled: bool = true,
};

/// True if clicked.
pub fn menuItem(label: [:0]const u8, options: MenuItemOptions) bool {
    const shortcut_text: [*c]const c_char = if (options.shortcut) |s| str(s) else null;
    return raw("ImGui_MenuItemBoolPtr")(str(label), shortcut_text, options.checked, options.enabled);
}

pub const TableOptions = struct {
    borders: bool = false,
    row_background: bool = false,
    resizable: bool = false,
    /// Headers sort on click. Order rows yourself with `Table.sort`.
    sortable: bool = false,
    /// Null is ImGui's default.
    sizing: ?Sizing = null,
    /// Scroll sideways instead of squeezing columns.
    scroll_x: bool = false,
    /// Scrolls its own rows and keeps the header.
    scroll_y: bool = false,
    /// Left columns that stay put with `scroll_x`.
    frozen_columns: u8 = 0,
    /// Unscaled. 0 fills the rest of the window.
    height: f32 = 0,

    pub const Sizing = enum {
        fixed_fit,
        /// Shared in proportion to contents.
        stretch_prop,
        stretch_same,
    };
};

/// Null when clipped. Call `tableNextRow` and `tableNextColumn` before each cell.
pub fn table(id_: [:0]const u8, columns: u31, options: TableOptions) ?Table {
    var f: c.ImGuiTableFlags = 0;
    if (options.borders) f |= c.ImGuiTableFlags_Borders;
    if (options.row_background) f |= c.ImGuiTableFlags_RowBg;
    if (options.resizable) f |= c.ImGuiTableFlags_Resizable;
    if (options.sortable) f |= c.ImGuiTableFlags_Sortable | c.ImGuiTableFlags_SortTristate;
    if (options.scroll_x) f |= c.ImGuiTableFlags_ScrollX;
    if (options.scroll_y) f |= c.ImGuiTableFlags_ScrollY;
    if (options.sizing) |s| f |= switch (s) {
        .fixed_fit => c.ImGuiTableFlags_SizingFixedFit,
        .stretch_prop => c.ImGuiTableFlags_SizingStretchProp,
        .stretch_same => c.ImGuiTableFlags_SizingStretchSame,
    };
    const scrolls = options.scroll_x or options.scroll_y;
    const outer: c.ImVec2 = .{ .x = 0, .y = if (scrolls) scaled(options.height) else 0 };
    if (!raw("ImGui_BeginTableEx")(str(id_), columns, f, outer, 0)) return null;
    if (scrolls) raw("ImGui_TableSetupScrollFreeze")(if (options.scroll_x) options.frozen_columns else 0, if (options.scroll_y) 1 else 0);
    return .{};
}

pub const Table = struct {
    pub fn end(_: Table) void {
        raw("ImGui_EndTable")();
    }

    /// `Column` is an enum with one value per column. Call after `tableHeaders`.
    pub fn sortedBy(_: Table, comptime Column: type) ?Sort(Column) {
        std.debug.assert(raw("ImGui_TableGetColumnCount")() == @typeInfo(Column).@"enum".field_names.len);
        const specs = raw("ImGui_TableGetSortSpecs")();
        if (specs == null or specs.*.SpecsCount == 0) return null;
        const spec = specs.*.Specs[0];
        return .{
            .column = @fromBackingInt(@intCast(spec.ColumnIndex)),
            .descending = spec.SortDirection == c.ImGuiSortDirection_Descending,
        };
    }

    /// `order` compares by column, ascending. A null column means the table's own order.
    pub fn sort(
        self: Table,
        comptime Column: type,
        comptime T: type,
        rows: []T,
        context: anytype,
        comptime order: fn (@TypeOf(context), ?Column, T, T) std.math.Order,
    ) void {
        const Context = struct {
            inner: @TypeOf(context),
            by: ?Sort(Column),

            fn lessThan(ctx: @This(), a: T, b: T) bool {
                if (ctx.by) |by| {
                    const o = order(ctx.inner, by.column, a, b);
                    if (o != .eq) return o == @as(std.math.Order, if (by.descending) .gt else .lt);
                }
                return order(ctx.inner, null, a, b) == .lt;
            }
        };
        std.mem.sort(T, rows, Context{ .inner = context, .by = self.sortedBy(Column) }, Context.lessThan);
    }
};

pub fn Sort(comptime Column: type) type {
    return struct {
        column: Column,
        descending: bool,
    };
}

pub fn tableColumn(label: [:0]const u8) void {
    raw("ImGui_TableSetupColumn")(str(label), 0);
}

pub const ColumnOptions = struct {
    /// Fits its contents, or `width`.
    fixed: bool = false,
    /// `width` is its weight, 0 for default.
    stretch: bool = false,
    /// Unscaled width if fixed, weight if stretched.
    width: f32 = 0,
    no_sort: bool = false,
};

pub fn tableColumnWith(label: [:0]const u8, options: ColumnOptions) void {
    var f: c.ImGuiTableColumnFlags = 0;
    var width = options.width;
    if (options.fixed) {
        f |= c.ImGuiTableColumnFlags_WidthFixed;
        width = scaled(width);
    }
    if (options.stretch) {
        f |= c.ImGuiTableColumnFlags_WidthStretch;
        // Proportional sizing with no other stretch column gives 0 / 0 and NaN widths
        if (width == 0) width = 1;
    }
    if (options.no_sort) f |= c.ImGuiTableColumnFlags_NoSort;
    raw("ImGui_TableSetupColumnEx")(str(label), f, width, 0);
}

pub fn tableHeaders() void {
    raw("ImGui_TableHeadersRow")();
}

pub fn tableNextRow() void {
    raw("ImGui_TableNextRow")();
}

/// False if it's clipped.
pub fn tableNextColumn() bool {
    return raw("ImGui_TableNextColumn")();
}

/// Only draws on-screen rows. Rows must be one line high, run it to the end.
pub fn clip(count: usize) Clipper {
    return .{ .count = count };
}

pub const Clipper = struct {
    count: usize,
    inner: c.ImGuiListClipper = std.mem.zeroes(c.ImGuiListClipper),
    row: usize = 0,
    end: usize = 0,
    started: bool = false,
    kept: ?usize = null,

    /// Draws row `index` even off screen. Call before the first `next`.
    pub fn include(self: *Clipper, index: ?usize) void {
        self.kept = index;
    }

    pub fn next(self: *Clipper) ?usize {
        // Begin here, not in `clip`. ImGui keeps a pointer to the clipper so it can't move after
        if (!self.started) {
            self.started = true;
            raw("ImGuiListClipper_Begin")(&self.inner, @intCast(self.count), -1);
            if (self.kept) |k| if (k < self.count) raw("ImGuiListClipper_IncludeItemByIndex")(&self.inner, @intCast(k));
        }
        while (self.row >= self.end) {
            if (!raw("ImGuiListClipper_Step")(&self.inner)) return null; // ends the clipper
            self.row = @intCast(self.inner.DisplayStart);
            self.end = @intCast(self.inner.DisplayEnd);
        }
        defer self.row += 1;
        return self.row;
    }
};

pub fn text(comptime fmt: []const u8, args: anytype) void {
    const s = format(fmt, args);
    raw("ImGui_TextUnformattedEx")(str(s), @ptrCast(s.ptr + s.len));
}

pub fn textDisabled(comptime fmt: []const u8, args: anytype) void {
    raw("ImGui_TextDisabledUnformatted")(str(format(fmt, args)));
}

pub fn textColored(color: Color, comptime fmt: []const u8, args: anytype) void {
    raw("ImGui_TextColoredUnformatted")(vec4(color), str(format(fmt, args)));
}

pub fn textWrapped(comptime fmt: []const u8, args: anytype) void {
    raw("ImGui_TextWrappedUnformatted")(str(format(fmt, args)));
}

/// Value on the left, `label` on the right.
pub fn labelText(label: [:0]const u8, comptime fmt: []const u8, args: anytype) void {
    raw("ImGui_LabelTextUnformatted")(str(label), str(format(fmt, args)));
}

pub fn bulletText(comptime fmt: []const u8, args: anytype) void {
    raw("ImGui_BulletTextUnformatted")(str(format(fmt, args)));
}

/// Tooltip for the previous widget while hovered.
pub fn tooltip(comptime fmt: []const u8, args: anytype) void {
    raw("ImGui_SetItemTooltipUnformatted")(str(format(fmt, args)));
}

// The bool widgets return true if changed or clicked this frame.

pub fn button(label: [:0]const u8) bool {
    return raw("ImGui_Button")(str(label));
}

/// No frame padding, so it fits in a line of text.
pub fn smallButton(label: [:0]const u8) bool {
    return raw("ImGui_SmallButton")(str(label));
}

pub fn buttonSized(label: [:0]const u8, size: Vec2) bool {
    return raw("ImGui_ButtonEx")(str(label), vec2(size));
}

/// Just an icon, like `icons.x ++ "##clear"`. Square and as tall as an input, so it lines up
/// with one. The tip shows on hover, if there is one.
pub fn iconButton(label: [:0]const u8, tip: []const u8) bool {
    const h = frameHeight();
    const visible = label[0 .. std.mem.indexOf(u8, label, "##") orelse label.len];
    const padding = raw("ImGui_GetStyle")().*.FramePadding.x * 2;
    const w = @max(h, calcTextSize(visible)[0] + padding);
    const clicked = buttonSized(label, .{ w, h });
    if (tip.len > 0) tooltip("{s}", .{tip});
    return clicked;
}

/// Of a button or input, in pixels.
pub fn frameHeight() f32 {
    return raw("ImGui_GetFrameHeight")();
}

/// Moves text down to sit in line with buttons and inputs on the same line.
pub fn alignTextToFramePadding() void {
    raw("ImGui_AlignTextToFramePadding")();
}

pub fn checkbox(label: [:0]const u8, value: *bool) bool {
    return raw("ImGui_Checkbox")(str(label), value);
}

/// A clickable line, like in a list.
pub fn selectable(label: [:0]const u8, selected: bool) bool {
    return raw("ImGui_SelectableEx")(str(label), selected, 0, vec2(.{ 0, 0 }));
}

pub const SelectableOptions = struct {
    /// Covers the whole table row.
    span_columns: bool = false,
    /// Also true on a double-click's second click.
    double_click: bool = false,
    /// Widgets drawn over it still get clicks.
    allow_overlap: bool = false,
};

pub fn selectableWith(label: [:0]const u8, selected: bool, options: SelectableOptions) bool {
    var f: c.ImGuiSelectableFlags = 0;
    if (options.span_columns) f |= c.ImGuiSelectableFlags_SpanAllColumns;
    if (options.double_click) f |= c.ImGuiSelectableFlags_AllowDoubleClick;
    if (options.allow_overlap) f |= c.ImGuiSelectableFlags_AllowOverlap;
    return raw("ImGui_SelectableEx")(str(label), selected, f, vec2(.{ 0, 0 }));
}

/// For an `f32` or `i32`.
pub fn slider(label: [:0]const u8, value: anytype, min: std.meta.Child(@TypeOf(value)), max: std.meta.Child(@TypeOf(value))) bool {
    return switch (std.meta.Child(@TypeOf(value))) {
        f32 => raw("ImGui_SliderFloat")(str(label), value, min, max),
        i32 => raw("ImGui_SliderInt")(str(label), value, min, max),
        else => |T| @compileError("ui.slider takes *f32 or *i32, not *" ++ @typeName(T)),
    };
}

/// Drag box for an `f32` or `i32`. Double-click to type.
pub fn drag(label: [:0]const u8, value: anytype, speed: f32) bool {
    return switch (std.meta.Child(@TypeOf(value))) {
        f32 => raw("ImGui_DragFloatEx")(str(label), value, speed, 0, 0, str("%.3f"), 0),
        i32 => raw("ImGui_DragIntEx")(str(label), value, speed, 0, 0, str("%d"), 0),
        else => |T| @compileError("ui.drag takes *f32 or *i32, not *" ++ @typeName(T)),
    };
}

/// Edits `buffer` in place, null-terminated inside it.
pub fn inputText(label: [:0]const u8, buffer: []u8) bool {
    std.debug.assert(buffer.len > 0);
    return raw("ImGui_InputText")(str(label), @ptrCast(buffer.ptr), buffer.len, 0);
}

/// Greyed-out `hint` while empty.
pub fn inputTextHint(label: [:0]const u8, hint: [:0]const u8, buffer: []u8) bool {
    std.debug.assert(buffer.len > 0);
    return raw("ImGui_InputTextWithHint")(str(label), str(hint), @ptrCast(buffer.ptr), buffer.len, 0);
}

pub const InputTextFlags = bitpack struct {
    /// Only true when Enter lets go of the field.
    enter_returns_true: bool = false,
    auto_select_all: bool = false,
    chars_hexadecimal: bool = false,
    chars_uppercase: bool = false,
    chars_no_blank: bool = false,
    read_only: bool = false,
};

pub const InputTextOptions = struct {
    flags: InputTextFlags = .{},
    /// No frame padding, so it's one text line tall.
    tight: bool = false,
    /// Greyed out while empty.
    hint: ?[:0]const u8 = null,
};

pub fn inputTextWith(label: [:0]const u8, buffer: []u8, options: InputTextOptions) bool {
    std.debug.assert(buffer.len > 0);
    if (options.tight) raw("ImGui_PushStyleVarY")(c.ImGuiStyleVar_FramePadding, 0);
    defer if (options.tight) raw("ImGui_PopStyleVar")();
    const f = flags(c.ImGuiInputTextFlags, "ImGuiInputTextFlags_", options.flags);
    if (options.hint) |h| return raw("ImGui_InputTextWithHint")(str(label), str(h), @ptrCast(buffer.ptr), buffer.len, f);
    return raw("ImGui_InputText")(str(label), @ptrCast(buffer.ptr), buffer.len, f);
}

/// Enter adds a line. With `enter_returns_true`, Ctrl+Enter returns true.
pub fn inputTextMultiline(label: [:0]const u8, buffer: []u8, size: Vec2, input_flags: InputTextFlags) bool {
    std.debug.assert(buffer.len > 0);
    return raw("ImGui_InputTextMultilineEx")(str(label), @ptrCast(buffer.ptr), buffer.len, vec2(size), flags(c.ImGuiInputTextFlags, "ImGuiInputTextFlags_", input_flags), null, null);
}

/// Shows `hint` greyed while it's empty, like an example, gone as soon as anything's typed.
pub fn inputTextMultilineHint(label: [:0]const u8, buffer: []u8, size: Vec2, input_flags: InputTextFlags, hint: []const u8) bool {
    const changed = inputTextMultiline(label, buffer, size, input_flags);
    if (buffer[0] != 0 or hint.len == 0) return changed;
    const min = raw("ImGui_GetItemRectMin")();
    const max = raw("ImGui_GetItemRectMax")();
    const pad = raw("ImGui_GetStyle")().*.FramePadding;
    const list = raw("ImGui_GetWindowDrawList")();
    raw("ImDrawList_PushClipRect")(list, min, max, true);
    defer raw("ImDrawList_PopClipRect")(list);
    const at: c.ImVec2 = .{ .x = min.x + pad.x, .y = min.y + pad.y };
    raw("ImDrawList_AddTextEx")(list, at, raw("ImGui_GetColorU32")(c.ImGuiCol_TextDisabled), @ptrCast(hint.ptr), @ptrCast(hint.ptr + hint.len));
    return changed;
}

/// Read-only text you can select and copy. `id_` must be unique in scope.
pub fn copyableText(id_: [:0]const u8, comptime fmt: []const u8, args: anytype) void {
    copyableTextWidth(id_, fill, fmt, args);
}

/// `width` works like in `setNextItemWidth`.
pub fn copyableTextWidth(id_: [:0]const u8, width: f32, comptime fmt: []const u8, args: anytype) void {
    const value = format(fmt, args);
    raw("ImGui_PushStyleColor")(c.ImGuiCol_FrameBg, 0);
    raw("ImGui_PushStyleVarImVec2")(c.ImGuiStyleVar_FramePadding, .{ .x = 0, .y = 0 });
    defer {
        raw("ImGui_PopStyleVar")();
        raw("ImGui_PopStyleColor")();
    }
    setNextItemWidth(width);
    // Read-only, so ImGui never writes to it despite the @constCast
    _ = raw("ImGui_InputText")(str(id_), @ptrCast(@constCast(value.ptr)), value.len + 1, c.ImGuiInputTextFlags_ReadOnly | c.ImGuiInputTextFlags_AutoSelectAll);
    if (isItemHovered()) {
        // `value` already lives in tooltip's buffer, so pass it straight to ImGui
        if (raw("ImGui_CalcTextSize")(str(value)).x > raw("ImGui_GetItemRectSize")().x) raw("ImGui_SetItemTooltipUnformatted")(str(value));
    }
}

pub fn setClipboard(value: [:0]const u8) void {
    raw("ImGui_SetClipboardText")(str(value));
}

/// Good until the next clipboard call.
pub fn getClipboard() ?[:0]const u8 {
    const got = raw("ImGui_GetClipboardText")();
    if (got == null) return null;
    return std.mem.span(@as([*:0]const u8, @ptrCast(got)));
}

/// `selected` is an index into `items`.
pub fn combo(label: [:0]const u8, selected: *usize, items: []const [:0]const u8) bool {
    const preview: [:0]const u8 = if (selected.* < items.len) items[selected.*] else "";
    if (!raw("ImGui_BeginCombo")(str(label), str(preview), 0)) return false;
    defer raw("ImGui_EndCombo")();
    var changed = false;
    for (items, 0..) |item, i| {
        const scope = id(@as(i32, @intCast(i)));
        defer scope.end();
        if (selectable(item, i == selected.*)) {
            changed = selected.* != i;
            selected.* = i;
        }
    }
    return changed;
}

pub const ComboOptions = struct {
    /// Just the arrow, like next to a text box.
    no_preview: bool = false,
    /// Room for more items before it scrolls.
    large: bool = false,
};

/// Null while it's closed. Put your own items in it, like `selectable`s, then `end` it.
pub fn comboBegin(label: [:0]const u8, preview: [:0]const u8, options: ComboOptions) ?Combo {
    var f: c.ImGuiComboFlags = 0;
    if (options.no_preview) f |= c.ImGuiComboFlags_NoPreview;
    if (options.large) f |= c.ImGuiComboFlags_HeightLarge;
    if (raw("ImGui_BeginCombo")(str(label), str(preview), f)) return .{};
    return null;
}

pub const Combo = struct {
    pub fn end(_: Combo) void {
        raw("ImGui_EndCombo")();
    }
};

pub fn colorEdit(label: [:0]const u8, color: *Color) bool {
    return raw("ImGui_ColorEdit4")(str(label), color, 0);
}

pub fn separator() void {
    raw("ImGui_Separator")();
}

pub fn separatorText(label: [:0]const u8) void {
    raw("ImGui_SeparatorText")(str(label));
}

pub fn sameLine() void {
    raw("ImGui_SameLine")();
}

pub fn spacing() void {
    raw("ImGui_Spacing")();
}

/// Unscaled. Negative leaves room on the right, `fill` takes the rest.
pub fn setNextItemWidth(width: f32) void {
    raw("ImGui_SetNextItemWidth")(if (width < 0 and width != fill) -scaled(-width) else if (width > 0) scaled(width) else width);
}

pub const fill: f32 = -std.math.floatMin(f32);

/// Unscaled, same as `setNextItemWidth`.
pub fn getContentRegionAvail() Vec2 {
    const avail = raw("ImGui_GetContentRegionAvail")();
    const s = scale();
    return .{ avail.x / s, avail.y / s };
}

/// Current style's spacing, unscaled.
pub const Style = struct {
    window_padding: Vec2,
    frame_padding: Vec2,
    cell_padding: Vec2,
    /// Between widgets and lines.
    item_spacing: Vec2,
    /// Inside a widget, like between a slider and its label.
    item_inner_spacing: Vec2,
};

pub fn getStyle() Style {
    const style = raw("ImGui_GetStyle")();
    const s = scale();
    return .{
        .window_padding = unscaled(style.*.WindowPadding, s),
        .frame_padding = unscaled(style.*.FramePadding, s),
        .cell_padding = unscaled(style.*.CellPadding, s),
        .item_spacing = unscaled(style.*.ItemSpacing, s),
        .item_inner_spacing = unscaled(style.*.ItemInnerSpacing, s),
    };
}

fn unscaled(v: c.ImVec2, s: f32) Vec2 {
    return .{ v.x / s, v.y / s };
}

/// Previous widget is under the mouse.
pub fn isItemHovered() bool {
    return raw("ImGui_IsItemHovered")(0);
}

/// Previous widget was double-clicked this frame.
pub fn isItemDoubleClicked() bool {
    return isItemHovered() and raw("ImGui_IsMouseDoubleClicked")(c.ImGuiMouseButton_Left);
}

/// For a text field that's Enter, Escape or clicking away.
pub fn isItemDeactivated() bool {
    return raw("ImGui_IsItemDeactivated")();
}

/// Like a text field being typed in or a button held.
pub fn isItemActive() bool {
    return raw("ImGui_IsItemActive")();
}

/// Previous widget's value changed this frame, like typing in a text field.
pub fn isItemEdited() bool {
    return raw("ImGui_IsItemEdited")();
}

pub fn isAnyItemActive() bool {
    return raw("ImGui_IsAnyItemActive")();
}

/// Unscaled. `unindent` the same amount.
pub fn indent(width: f32) void {
    raw("ImGui_IndentEx")(scaled(width));
}

pub fn unindent(width: f32) void {
    raw("ImGui_UnindentEx")(scaled(width));
}

/// Gives keyboard focus to the next widget.
pub fn focusNext() void {
    raw("ImGui_SetKeyboardFocusHere")();
}

pub fn isWindowFocused() bool {
    return raw("ImGui_IsWindowFocused")(0);
}

/// Previous widget is on screen.
pub fn isItemVisible() bool {
    return raw("ImGui_IsItemVisible")();
}

/// Drags the previous widget carrying `payload`. Null unless dragging, then draw and `end`.
pub fn dragSource(kind: [:0]const u8, payload: []const u8) ?DragSource {
    std.debug.assert(payload.len <= max_payload);
    if (!raw("ImGui_BeginDragDropSource")(0)) return null;
    _ = raw("ImGui_SetDragDropPayload")(str(kind), payload.ptr, payload.len, c.ImGuiCond_Always);
    return .{};
}

pub const DragSource = struct {
    pub fn end(_: DragSource) void {
        raw("ImGui_EndDragDropSource")();
    }
};

pub const Drop = struct {
    bytes: [max_payload]u8 = undefined,
    len: u8 = 0,
    /// Dropped this frame, else just hovering.
    delivered: bool,

    pub fn payload(self: *const Drop) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn as(self: *const Drop, comptime T: type) ?T {
        if (self.len != @sizeOf(T)) return null;
        return std.mem.bytesToValue(T, self.payload());
    }
};

/// Enough for an id or two.
pub const max_payload = 64;

/// Draws no highlight, draw where it'd go yourself.
pub fn dropTarget(kind: [:0]const u8) ?Drop {
    if (!raw("ImGui_BeginDragDropTarget")()) return null;
    // Ending it wipes a delivered payload, so it's copied out first
    defer raw("ImGui_EndDragDropTarget")();
    const accept = c.ImGuiDragDropFlags_AcceptBeforeDelivery | c.ImGuiDragDropFlags_AcceptNoDrawDefaultRect;
    const p = raw("ImGui_AcceptDragDropPayload")(str(kind), accept) orelse return null;
    const bytes = payloadBytes(p);
    var drop: Drop = .{ .delivered = p.*.Delivery, .len = @intCast(@min(bytes.len, max_payload)) };
    @memcpy(drop.bytes[0..drop.len], bytes[0..drop.len]);
    return drop;
}

/// What's being dragged if it's a `kind`, wherever the mouse is.
pub fn dragging(kind: [:0]const u8) ?[]const u8 {
    const p = raw("ImGui_GetDragDropPayload")() orelse return null;
    const data_type: [*:0]const u8 = @ptrCast(&p.*.DataType);
    if (!std.mem.eql(u8, std.mem.span(data_type), kind)) return null;
    return payloadBytes(p);
}

fn payloadBytes(p: *const c.ImGuiPayload) []const u8 {
    if (p.*.Data == null or p.*.DataSize <= 0) return &.{};
    const data: [*]const u8 = @ptrCast(p.*.Data);
    return data[0..@intCast(p.*.DataSize)];
}

pub const MouseButton = enum(c.ImGuiMouseButton) {
    left = c.ImGuiMouseButton_Left,
    right = c.ImGuiMouseButton_Right,
    middle = c.ImGuiMouseButton_Middle,
    _,
};

pub fn isMouseDown(which: MouseButton) bool {
    return raw("ImGui_IsMouseDown")(@backingInt(which));
}

/// Went down this frame.
pub fn isMouseClicked(which: MouseButton) bool {
    return raw("ImGui_IsMouseClicked")(@backingInt(which));
}

/// For unnamed keys use `@enumFromInt(c.ImGuiKey_F5)`.
pub const Key = enum(c.ImGuiKey) {
    left = c.ImGuiKey_LeftArrow,
    right = c.ImGuiKey_RightArrow,
    up = c.ImGuiKey_UpArrow,
    down = c.ImGuiKey_DownArrow,
    page_up = c.ImGuiKey_PageUp,
    page_down = c.ImGuiKey_PageDown,
    home = c.ImGuiKey_Home,
    end = c.ImGuiKey_End,
    enter = c.ImGuiKey_Enter,
    keypad_enter = c.ImGuiKey_KeypadEnter,
    escape = c.ImGuiKey_Escape,
    tab = c.ImGuiKey_Tab,
    backspace = c.ImGuiKey_Backspace,
    delete = c.ImGuiKey_Delete,
    space = c.ImGuiKey_Space,
    insert = c.ImGuiKey_Insert,
    a = c.ImGuiKey_A,
    b = c.ImGuiKey_B,
    c = c.ImGuiKey_C,
    d = c.ImGuiKey_D,
    e = c.ImGuiKey_E,
    f = c.ImGuiKey_F,
    g = c.ImGuiKey_G,
    i = c.ImGuiKey_I,
    l = c.ImGuiKey_L,
    n = c.ImGuiKey_N,
    o = c.ImGuiKey_O,
    r = c.ImGuiKey_R,
    s = c.ImGuiKey_S,
    v = c.ImGuiKey_V,
    w = c.ImGuiKey_W,
    x = c.ImGuiKey_X,
    z = c.ImGuiKey_Z,
    f2 = c.ImGuiKey_F2,
    f5 = c.ImGuiKey_F5,
    f6 = c.ImGuiKey_F6,
    f7 = c.ImGuiKey_F7,
    f8 = c.ImGuiKey_F8,
    f9 = c.ImGuiKey_F9,
    f10 = c.ImGuiKey_F10,
    f11 = c.ImGuiKey_F11,
    _,
};

/// A key with exactly these modifiers, like Ctrl+Shift+C.
pub const Chord = struct {
    key: Key,
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,

    pub fn imgui(self: Chord) c.ImGuiKeyChord {
        var chord: c.ImGuiKeyChord = @intCast(@backingInt(self.key));
        if (self.ctrl) chord |= c.ImGuiMod_Ctrl;
        if (self.shift) chord |= c.ImGuiMod_Shift;
        if (self.alt) chord |= c.ImGuiMod_Alt;
        return chord;
    }

    /// Down this frame or repeating, with exactly its modifiers.
    pub fn pressed(self: Chord) bool {
        return raw("ImGui_IsKeyChordPressed")(self.imgui());
    }

    /// Like `Ctrl+Shift+C`.
    pub fn format(self: Chord, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.ctrl) try writer.writeAll("Ctrl+");
        if (self.shift) try writer.writeAll("Shift+");
        if (self.alt) try writer.writeAll("Alt+");
        const name = raw("ImGui_GetKeyName")(@backingInt(self.key));
        try writer.writeAll(if (name != null) std.mem.span(@as([*:0]const u8, @ptrCast(name))) else "?");
    }
};

pub const Selection = @import("Selection.zig");
pub const Commands = @import("Commands.zig");
pub const commands = Commands.begin;
pub const Confirm = @import("Confirm.zig");
pub const Split = @import("Split.zig");
/// ImGuizmo widgets, from the host's ImGui.
pub const gizmo = @import("gizmo.zig");
pub const Sequencer = @import("Sequencer.zig");
pub const GraphEditor = @import("GraphEditor.zig");
pub const VectorEditor = @import("VectorEditor.zig");
pub const GuizmoDemo = @import("GuizmoDemo.zig");
/// ImPlot charts, from the host's ImGui.
pub const plot = @import("plot.zig");
pub const PlotDemo = @import("PlotDemo.zig");
pub const Toasts = @import("Toasts.zig");
const chord_input = @import("chord_input.zig");
pub const chordInput = chord_input.chordInput;
pub const ChordInputOptions = chord_input.Options;
pub const listeningForKeys = chord_input.listeningForKeys;
pub const chordName = chord_input.chordName;
/// ImGui's key for a `tuft_input` key.
pub const imguiKey = chord_input.imguiKey;

/// With `repeat`, held keys count while repeating.
pub fn isKeyPressed(key: Key, repeat: bool) bool {
    return raw("ImGui_IsKeyPressedEx")(@backingInt(key), repeat);
}

/// Claims `key` for this window, innermost wins. Claim every frame, it kicks in next frame.
pub fn shortcut(key: Key) bool {
    return raw("ImGui_Shortcut")(@backingInt(key), c.ImGuiInputFlags_RouteFocused);
}

pub const Mods = struct { ctrl: bool, shift: bool, alt: bool, super: bool };

pub fn mods() Mods {
    const io = raw("ImGui_GetIO")();
    return .{ .ctrl = io.*.KeyCtrl, .shift = io.*.KeyShift, .alt = io.*.KeyAlt, .super = io.*.KeySuper };
}

/// A focused text field eats them itself.
pub fn typed() []const c.ImWchar {
    const queue = raw("ImGui_GetIO")().*.InputQueueCharacters;
    if (queue.Size <= 0) return &.{};
    return queue.Data[0..@intCast(queue.Size)];
}

/// Keeps keys from the game. Call every frame you need it, it kicks in next frame.
pub fn captureKeyboard() void {
    raw("ImGui_SetNextFrameWantCaptureKeyboard")(true);
}

/// Per-frame state and settings, like `DeltaTime`.
pub fn getIO() *c.ImGuiIO {
    return @ptrCast(raw("ImGui_GetIO")());
}

/// Running ImGui's version. `version` is what we built against.
pub fn getVersion() [:0]const u8 {
    return std.mem.span(@as([*:0]const u8, @ptrCast(raw("ImGui_GetVersion")())));
}

/// Also brings it to the front.
pub fn setWindowFocus() void {
    raw("ImGui_SetWindowFocus")();
}

/// Also brings it to the front.
pub fn setNextWindowFocus() void {
    raw("ImGui_SetNextWindowFocus")();
}

pub fn setNextWindowCollapsed(collapsed: bool, when: Cond) void {
    raw("ImGui_SetNextWindowCollapsed")(collapsed, cond(when));
}

/// Draws while `open` and clears it when closed.
pub fn showDemoWindow(open: *bool) void {
    raw("ImGui_ShowDemoWindow")(open);
}

pub fn showMetricsWindow(open: *bool) void {
    raw("ImGui_ShowMetricsWindow")(open);
}

pub fn showIdStackToolWindow(open: *bool) void {
    raw("ImGui_ShowIDStackToolWindowEx")(open);
}

pub fn showDebugLogWindow(open: *bool) void {
    raw("ImGui_ShowDebugLogWindow")(open);
}

// Raw pixels, for widgets that lay themselves out and draw with a `DrawList`.

/// Previous widget's top left, on screen.
pub fn getItemRectMin() Vec2 {
    return fromVec2(raw("ImGui_GetItemRectMin")());
}

/// Previous widget's bottom right, on screen.
pub fn getItemRectMax() Vec2 {
    return fromVec2(raw("ImGui_GetItemRectMax")());
}

pub fn getCursorScreenPos() Vec2 {
    return fromVec2(raw("ImGui_GetCursorScreenPos")());
}

pub fn getMousePos() Vec2 {
    return fromVec2(raw("ImGui_GetMousePos")());
}

pub fn getWindowPos() Vec2 {
    return fromVec2(raw("ImGui_GetWindowPos")());
}

pub fn getWindowHeight() f32 {
    return raw("ImGui_GetWindowHeight")();
}

/// `getContentRegionAvail` in pixels.
pub fn getContentRegionAvailPixels() Vec2 {
    return fromVec2(raw("ImGui_GetContentRegionAvail")());
}

/// `setNextItemWidth` in pixels.
pub fn setNextItemWidthPixels(width: f32) void {
    raw("ImGui_SetNextItemWidth")(width);
}

pub const ImageFit = enum {
    /// Exactly `size`. With one side 0 that side keeps the image's shape, with both 0 it's the image's own size.
    stretch,
    /// As big as fits in `size` keeping its shape. 0 either way means the space left.
    contain,
    /// As wide as the space left keeping its shape, but no taller than `size[1]` if that's set.
    width,
};

/// Sizes are in pixels, not scaled, like images are.
pub const ImageOptions = struct {
    size: Vec2 = .{ 0, 0 },
    fit: ImageFit = .stretch,
    /// Multiplies its colors.
    tint: Color = .{ 1, 1, 1, 1 },
};

/// How big an image `pixels` big gets drawn, with `avail` the space left.
pub fn imageSize(pixels: Vec2, options: ImageOptions, avail: Vec2) Vec2 {
    if (!(pixels[0] > 0 and pixels[1] > 0)) return .{ 0, 0 };
    const aspect = pixels[1] / pixels[0];
    const size = options.size;
    const out: Vec2 = switch (options.fit) {
        .stretch => if (size[0] <= 0 and size[1] <= 0)
            pixels
        else if (size[0] <= 0)
            .{ size[1] / aspect, size[1] }
        else if (size[1] <= 0)
            .{ size[0], size[0] * aspect }
        else
            size,
        .contain => blk: {
            const box: Vec2 = .{ if (size[0] > 0) size[0] else avail[0], if (size[1] > 0) size[1] else avail[1] };
            const s = @min(box[0] / pixels[0], box[1] / pixels[1]);
            break :blk .{ pixels[0] * s, pixels[1] * s };
        },
        .width => if (size[1] > 0 and avail[0] * aspect > size[1]) .{ size[1] / aspect, size[1] } else .{ avail[0], avail[0] * aspect },
    };
    return .{ @max(out[0], 0), @max(out[1], 0) };
}

/// Draws a texture that's `pixels` big. Get `texture` from the host's images each frame.
pub fn image(texture: c.ImTextureRef, pixels: Vec2, options: ImageOptions) void {
    const size = imageSize(pixels, options, getContentRegionAvailPixels());
    raw("ImGui_ImageWithBgEx")(texture, vec2(size), .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 1 }, .{ .x = 0, .y = 0, .z = 0, .w = 0 }, vec4(options.tint));
}

test imageSize {
    const px: Vec2 = .{ 200, 100 };
    try std.testing.expectEqual(px, imageSize(px, .{}, .{ 50, 50 }));
    try std.testing.expectEqual(Vec2{ 100, 50 }, imageSize(px, .{ .size = .{ 100, 0 } }, .{ 0, 0 }));
    try std.testing.expectEqual(Vec2{ 40, 20 }, imageSize(px, .{ .fit = .contain, .size = .{ 40, 40 } }, .{ 0, 0 }));
    try std.testing.expectEqual(Vec2{ 300, 150 }, imageSize(px, .{ .fit = .width }, .{ 300, 9 }));
    try std.testing.expectEqual(Vec2{ 120, 60 }, imageSize(px, .{ .fit = .width, .size = .{ 0, 60 } }, .{ 300, 9 }));
    try std.testing.expectEqual(Vec2{ 0, 0 }, imageSize(.{ 0, 10 }, .{}, .{ 1, 1 }));
}

/// 0 offset means right after the previous widget, negative spacing uses the style's.
pub fn sameLineWith(offset: f32, spacing_: f32) void {
    raw("ImGui_SameLineEx")(offset, spacing_);
}

pub fn calcTextSize(text_: []const u8) Vec2 {
    return fromVec2(raw("ImGui_CalcTextSizeEx")(@ptrCast(text_.ptr), @ptrCast(text_.ptr + text_.len), false, -1));
}

pub fn getTextLineHeight() f32 {
    return raw("ImGui_GetTextLineHeight")();
}

pub fn getTextLineHeightWithSpacing() f32 {
    return raw("ImGui_GetTextLineHeightWithSpacing")();
}

pub fn getScrollY() f32 {
    return raw("ImGui_GetScrollY")();
}

pub fn getScrollMaxY() f32 {
    return raw("ImGui_GetScrollMaxY")();
}

pub fn setScrollY(y: f32) void {
    raw("ImGui_SetScrollY")(y);
}

/// 0 is top, 0.5 middle, 1 bottom.
pub fn setScrollHereY(ratio: f32) void {
    raw("ImGui_SetScrollHereY")(ratio);
}

/// 0 on an axis means figure it out.
pub fn setNextWindowContentSize(size: Vec2) void {
    raw("ImGui_SetNextWindowContentSize")(vec2(size));
}

/// Negative on an axis leaves it alone.
pub fn setNextWindowScroll(scroll: Vec2) void {
    raw("ImGui_SetNextWindowScroll")(vec2(scroll));
}

/// Takes the mouse but draws nothing.
pub fn invisibleButton(id_: [:0]const u8, size: Vec2) bool {
    return raw("ImGui_InvisibleButton")(str(id_), vec2(size), 0);
}

/// For unnamed ones use `@enumFromInt(c.ImGuiCol_Border)`.
pub const Col = enum(c.ImGuiCol) {
    text = c.ImGuiCol_Text,
    text_disabled = c.ImGuiCol_TextDisabled,
    text_selected_bg = c.ImGuiCol_TextSelectedBg,
    header_hovered = c.ImGuiCol_HeaderHovered,
    frame_bg_active = c.ImGuiCol_FrameBgActive,
    plot_histogram = c.ImGuiCol_PlotHistogram,
    drag_drop_target = c.ImGuiCol_DragDropTarget,
    _,
};

/// With the style's alpha, packed for a `DrawList`.
pub fn getColorU32(col: Col) u32 {
    return raw("ImGui_GetColorU32")(@backingInt(col));
}

/// ImGui's `IM_COL32`.
pub fn rgba(r: u8, g: u8, b: u8, a: u8) u32 {
    return (@as(u32, a) << 24) | (@as(u32, b) << 16) | (@as(u32, g) << 8) | r;
}

/// Screen coordinates.
pub const DrawList = struct {
    ptr: *c.ImDrawList,

    pub fn addText(self: DrawList, pos: Vec2, colour: u32, text_: []const u8) void {
        raw("ImDrawList_AddTextEx")(self.ptr, vec2(pos), colour, @ptrCast(text_.ptr), @ptrCast(text_.ptr + text_.len));
    }

    pub fn addRectFilled(self: DrawList, min: Vec2, max: Vec2, colour: u32) void {
        raw("ImDrawList_AddRectFilled")(self.ptr, vec2(min), vec2(max), colour);
    }

    pub fn addCircleFilled(self: DrawList, centre: Vec2, radius: f32, colour: u32) void {
        raw("ImDrawList_AddCircleFilled")(self.ptr, vec2(centre), radius, colour, 0);
    }

    /// Just the ring.
    pub fn addCircle(self: DrawList, centre: Vec2, radius: f32, colour: u32, thickness: f32) void {
        raw("ImDrawList_AddCircleEx")(self.ptr, vec2(centre), radius, colour, 0, thickness, 0);
    }

    pub fn addLine(self: DrawList, from: Vec2, to: Vec2, colour: u32, thickness: f32) void {
        raw("ImDrawList_AddLineEx")(self.ptr, vec2(from), vec2(to), colour, thickness, 0);
    }

    /// Just the outline.
    pub fn addRect(self: DrawList, min: Vec2, max: Vec2, colour: u32, rounding: f32, thickness: f32) void {
        raw("ImDrawList_AddRectEx")(self.ptr, vec2(min), vec2(max), colour, rounding, thickness, 0);
    }

    /// Draws past the current clip until `popClipRect`.
    pub fn pushClipRectFullScreen(self: DrawList) void {
        raw("ImDrawList_PushClipRectFullScreen")(self.ptr);
    }

    pub fn popClipRect(self: DrawList) void {
        raw("ImDrawList_PopClipRect")(self.ptr);
    }
};

pub fn getWindowDrawList() DrawList {
    return .{ .ptr = @ptrCast(raw("ImGui_GetWindowDrawList")()) };
}

/// Fonts a host loaded. Each UI thread has its own ImGui, so its own fonts.
pub const Fonts = struct {
    /// Fixed width, for hex and code.
    mono: ?*c.ImFont = null,
    bold: ?*c.ImFont = null,
};

threadlocal var fonts: Fonts = .{};

/// Hosts set them once they've added them to ImGui.
pub fn setFonts(set: Fonts) void {
    fonts = set;
}

/// Until `end`, if there is one.
pub fn monospace() FontScope {
    return pushFont(fonts.mono);
}

/// Until `end`, if there is one.
pub fn bold() FontScope {
    return pushFont(fonts.bold);
}

pub const FontScope = struct {
    pushed: bool,

    pub fn end(self: FontScope) void {
        if (self.pushed) raw("ImGui_PopFont")();
    }
};

fn pushFont(font: ?*c.ImFont) FontScope {
    const f = font orelse return .{ .pushed = false };
    // Left over from a context that's gone, like after a host restarts its UI
    if (!inAtlas(f)) return .{ .pushed = false };
    raw("ImGui_PushFontFloat")(f, 0);
    return .{ .pushed = true };
}

fn inAtlas(font: *c.ImFont) bool {
    const atlas = getIO().Fonts orelse return false;
    const list = atlas.*.Fonts;
    if (list.Size <= 0) return false;
    for (list.Data[0..@intCast(list.Size)]) |f| if (f == font) return true;
    return false;
}

pub fn str(s: [:0]const u8) [*c]const c_char {
    return @ptrCast(s.ptr);
}

fn vec2(v: Vec2) c.ImVec2 {
    return .{ .x = v[0], .y = v[1] };
}

fn fromVec2(v: c.ImVec2) Vec2 {
    return .{ v.x, v.y };
}

fn vec4(v: Color) c.ImVec4 {
    return .{ .x = v[0], .y = v[1], .z = v[2], .w = v[3] };
}

fn cond(value: Cond) c.ImGuiCond {
    return switch (value) {
        .always => c.ImGuiCond_Always,
        .once => c.ImGuiCond_Once,
        .first_use_ever => c.ImGuiCond_FirstUseEver,
        .appearing => c.ImGuiCond_Appearing,
    };
}

/// Field `no_title_bar` maps to `<prefix>NoTitleBar`.
fn flags(comptime T: type, comptime prefix: []const u8, value: anytype) T {
    var result: T = 0;
    inline for (@typeInfo(@TypeOf(value)).@"struct".field_names) |name| {
        if (@field(value, name)) result |= @field(c, prefix ++ pascalCase(name));
    }
    return result;
}

pub fn pascalCase(comptime name: []const u8) []const u8 {
    return comptime blk: {
        var out: []const u8 = "";
        var upper = true;
        for (name) |ch| {
            if (ch == '_') {
                upper = true;
                continue;
            }
            out = out ++ &[_]u8{if (upper) std.ascii.toUpper(ch) else ch};
            upper = false;
        }
        break :blk out;
    };
}

threadlocal var format_buffer: [4096]u8 = undefined;

/// Per-thread buffer good until the next call. Cut off with "..." if it doesn't fit.
pub fn format(comptime fmt: []const u8, args: anytype) [:0]const u8 {
    if (comptime @typeInfo(@TypeOf(args)).@"struct".field_names.len == 0 and std.mem.indexOfAny(u8, fmt, "{}") == null) {
        return fmt ++ "";
    }
    const buf = &format_buffer;
    var writer: std.Io.Writer = .fixed(buf[0 .. buf.len - 1]);
    writer.print(fmt, args) catch {
        const marker = "...";
        @memcpy(buf[buf.len - 1 - marker.len .. buf.len - 1], marker);
        writer.end = buf.len - 1;
    };
    buf[writer.end] = 0;
    return buf[0..writer.end :0];
}

test format {
    try std.testing.expectEqualStrings("plain", format("plain", .{}));
    try std.testing.expectEqualStrings("7 spends", format("{d} spends", .{7}));
    const xs: [5000]u8 = @splat('x');
    const long = format("{s}", .{&xs});
    try std.testing.expectEqual(format_buffer.len - 1, long.len);
    try std.testing.expect(std.mem.endsWith(u8, long, "..."));
}

test pascalCase {
    try std.testing.expectEqualStrings("NoTitleBar", pascalCase("no_title_bar"));
}

test {
    _ = Toasts;
    _ = chord_input;
    _ = plot;
}
