//! Multi-select for lists and tables, kept by your own row ids so it survives sorting.

const Selection = @This();

const std = @import("std");

const root = @import("root.zig");
const c = root.c;
const raw = root.raw;

/// Not ImGui's, so it can be freed without a context, from any thread.
const allocator = std.heap.smp_allocator;
/// Rows checked for ones that went away. Longer lists keep stale ids, which matches nothing.
const max_pruned = 1 << 16;

ids: std.AutoArrayHashMapUnmanaged(u64, void) = .empty,
/// Row with the keyboard cursor, or the last one clicked. Might not be selected.
current: ?u64 = null,
activated: bool = false,

pub fn deinit(self: *Selection) void {
    self.ids.deinit(allocator);
    self.* = .{};
}

pub fn contains(self: *const Selection, id: u64) bool {
    return self.ids.contains(id);
}

pub fn count(self: *const Selection) usize {
    return self.ids.count();
}

/// In no particular order.
pub fn keys(self: *const Selection) []const u64 {
    return self.ids.keys();
}

pub fn clear(self: *Selection) void {
    self.ids.clearRetainingCapacity();
}

pub fn only(self: *Selection, id: u64) void {
    self.clear();
    self.add(id);
    self.current = id;
}

pub fn add(self: *Selection, id: u64) void {
    self.ids.put(allocator, id, {}) catch {};
}

pub fn remove(self: *Selection, id: u64) void {
    _ = self.ids.swapRemove(id);
}

/// `current` if it's selected, else any selected one.
pub fn focused(self: *const Selection) ?u64 {
    if (self.current) |id| if (self.contains(id)) return id;
    const all = self.keys();
    return if (all.len > 0) all[0] else null;
}

/// `idOf` gives each row's id.
pub fn Rows(comptime T: type, comptime idOf: fn (*const T) u64) type {
    return struct {
        rows: []const T,

        pub fn id(self: @This(), i: usize) u64 {
            return idOf(&self.rows[i]);
        }
    };
}

/// For lists that don't move.
pub const Indices = struct {
    pub fn id(_: Indices, i: usize) u64 {
        return i;
    }
};

pub const Options = struct {
    single: bool = false,
};

/// `ids` gives each row's id by its index in the order shown.
pub fn begin(self: *Selection, row_count: usize, ids: anytype, options: Options) Scope(@TypeOf(ids)) {
    self.activated = false;
    self.prune(row_count, ids);
    var flags: c.ImGuiMultiSelectFlags = c.ImGuiMultiSelectFlags_ClearOnEscape;
    // ImGui counts a popup begun inside the list, like its right-click menu, as part of the list.
    // Clicks in it would land on the list's empty space and never reach the popup's items
    const popup = raw("ImGui_IsPopupOpen")(root.str(""), c.ImGuiPopupFlags_AnyPopupId | c.ImGuiPopupFlags_AnyPopupLevel);
    if (!popup) flags |= c.ImGuiMultiSelectFlags_ClearOnClickVoid | c.ImGuiMultiSelectFlags_BoxSelect1d;
    if (options.single) flags |= c.ImGuiMultiSelectFlags_SingleSelect;
    const ms = raw("ImGui_BeginMultiSelectEx")(flags, @intCast(self.count()), @intCast(row_count));
    self.apply(ms, ids, row_count);
    if (rowOf(ms.*.NavIdItem, row_count)) |i| self.current = ids.id(i);
    return .{ .selection = self, .ids = ids, .count = row_count, .range_from = rowOf(ms.*.RangeSrcItem, row_count) };
}

pub fn Scope(comptime Ids: type) type {
    return struct {
        selection: *Selection,
        ids: Ids,
        count: usize,
        range_from: ?usize,

        /// Give it to `Clipper.include` so it's drawn off screen, else the range gets lost.
        pub fn keep(self: *const @This()) ?usize {
            return self.range_from;
        }

        /// Spans the whole table row. True if it's selected.
        pub fn row(self: *@This(), i: usize, label: [:0]const u8) bool {
            const id = self.ids.id(i);
            raw("ImGui_SetNextItemSelectionUserData")(@intCast(i));
            const selected = self.selection.contains(id);
            _ = root.selectableWith(label, selected, .{ .span_columns = true, .double_click = true, .allow_overlap = true });
            if (root.isItemDoubleClicked()) {
                self.selection.activated = true;
                self.selection.current = id;
            }
            return selected;
        }

        pub fn end(self: *@This()) void {
            const ms = raw("ImGui_EndMultiSelect")();
            self.selection.apply(ms, self.ids, self.count);
        }
    };
}

fn rowOf(user_data: c.ImGuiSelectionUserData, row_count: usize) ?usize {
    if (user_data < 0) return null;
    const i: usize = @intCast(user_data);
    return if (i < row_count) i else null;
}

fn apply(self: *Selection, ms: *c.ImGuiMultiSelectIO, ids: anytype, row_count: usize) void {
    const requests = ms.*.Requests;
    if (requests.Size <= 0) return;
    for (requests.Data[0..@intCast(requests.Size)]) |req| switch (req.Type) {
        c.ImGuiSelectionRequestType_SetAll => {
            self.clear();
            if (req.Selected) for (0..row_count) |i| self.add(ids.id(i));
        },
        c.ImGuiSelectionRequestType_SetRange => {
            const first = rowOf(req.RangeFirstItem, row_count) orelse continue;
            const last = rowOf(req.RangeLastItem, row_count) orelse continue;
            for (@min(first, last)..@max(first, last) + 1) |i| {
                if (req.Selected) self.add(ids.id(i)) else self.remove(ids.id(i));
            }
            if (first == last and req.Selected) self.current = ids.id(first);
        },
        else => {},
    };
}

/// Drops ids no row has any more.
fn prune(self: *Selection, row_count: usize, ids: anytype) void {
    const n = self.count();
    if (n == 0 or row_count > max_pruned) return;
    var seen = std.DynamicBitSetUnmanaged.initEmpty(allocator, n) catch return;
    defer seen.deinit(allocator);
    for (0..row_count) |i| {
        if (self.ids.getIndex(ids.id(i))) |k| seen.set(k);
    }
    var k = n;
    while (k > 0) {
        k -= 1;
        if (!seen.isSet(k)) self.ids.swapRemoveAt(k);
    }
}
