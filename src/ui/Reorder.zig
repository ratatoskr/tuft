//! Reordering rows or bar tiles by drag, menu or keys. The view applies the move from `take`.
//! Each frame: `begin`, `item` after each widget, then `take`.

const Reorder = @This();

const std = @import("std");

const root = @import("root.zig");
const raw = root.raw;
const Chord = root.Chord;
const Commands = root.Commands;

/// Not ImGui's, so it can be freed without a context.
const allocator = std.heap.smp_allocator;

pub const Place = enum {
    /// Above it, or left of it along a bar.
    before,
    /// After it and what's in it.
    after,
    /// First in it.
    first,
    /// Last in it.
    into,
    /// Last of all, out of any group. The target's 0.
    end,
};

pub const Move = struct { dragged: u64, target: u64, place: Place };

pub const Step = enum {
    up,
    down,
    top,
    bottom,

    pub fn label(self: Step, horizontal: bool) [:0]const u8 {
        if (horizontal) return switch (self) {
            .up => "Move left",
            .down => "Move right",
            .top => "Move to start",
            .bottom => "Move to end",
        };
        return switch (self) {
            .up => "Move up",
            .down => "Move down",
            .top => "Move to top",
            .bottom => "Move to bottom",
        };
    }
};

pub const Item = struct {
    /// Not 0.
    id: u64,
    /// The group it's in, 0 at the top.
    parent: u64 = 0,
    /// Things can go in it.
    group: bool = false,
    /// Open, so what's in it is drawn right after it.
    open: bool = false,
    /// Shown while it's dragged.
    label: []const u8 = "",
};

pub const Keys = struct {
    up: ?Chord = null,
    down: ?Chord = null,
};

/// Drags only land in ones of the same kind.
kind: [:0]const u8,
/// Things only move among the ones next to them, never into or out of groups.
siblings_only: bool = false,
/// Along a bar, left to right, not down a list.
horizontal: bool = false,
pending: ?Move = null,
/// Right-clicked this frame, for `drawMenu`.
menu_asked: ?u64 = null,
menu_for: u64 = 0,
drawn: std.ArrayList(Drawn) = .empty,
/// Last frame's, which the menu and keys move among.
last: std.ArrayList(Drawn) = .empty,
/// Listed with `note` this frame, so `item` doesn't list them again.
noted: bool = false,

const Drawn = struct { id: u64, parent: u64 };
const Drag = extern struct { id: u64, parent: u64 };

pub fn deinit(self: *Reorder) void {
    self.drawn.deinit(allocator);
    self.last.deinit(allocator);
    self.pending = null;
}

pub fn begin(self: *Reorder) void {
    std.mem.swap(std.ArrayList(Drawn), &self.drawn, &self.last);
    self.drawn.clearRetainingCapacity();
    self.noted = false;
}

/// Lists an undrawn row so menu and keys move past it. Call for every one, in order, or none.
pub fn note(self: *Reorder, id: u64, parent: u64) void {
    self.noted = true;
    self.drawn.append(allocator, .{ .id = id, .parent = parent }) catch {};
}

/// Call after its widget, ideally one covering all of it.
pub fn item(self: *Reorder, it: Item) void {
    std.debug.assert(it.id != 0);
    if (!self.noted) self.drawn.append(allocator, .{ .id = it.id, .parent = it.parent }) catch {};
    if (root.isItemClicked(.right)) self.menu_asked = it.id;
    if (root.dragSource(self.kind, std.mem.asBytes(&Drag{ .id = it.id, .parent = it.parent }))) |source| {
        defer source.end();
        root.text("{s}", .{it.label});
    }
    const drop = root.dropTarget(self.kind) orelse return;
    const dragged = drop.as(Drag) orelse return;
    if (dragged.id == it.id) return;
    const min = root.getItemRectMin();
    const max = root.getItemRectMax();
    const axis: usize = @intFromBool(self.horizontal);
    const at = root.getMousePos()[axis] - min[axis];
    const place = placeAt(it, self.siblings_only, dragged.parent, at, max[axis] - min[axis]) orelse return;
    self.mark(min, max, place);
    if (drop.delivered) self.pending = .{ .dragged = dragged.id, .target = it.id, .place = place };
}

/// Where a drop `at` along something `length` long goes. Null if it can't go there.
pub fn placeAt(it: Item, siblings_only: bool, dragged_parent: u64, at: f32, length: f32) ?Place {
    if (siblings_only) {
        if (dragged_parent != it.parent) return null;
        return if (at < length * 0.5) .before else .after;
    }
    if (it.group and at > length * 0.25 and at < length * 0.75) return .into;
    if (at < length * 0.5) return .before;
    // What's drawn right after an open group is its first
    return if (it.group and it.open) .first else .after;
}

/// Makes the last widget, like a row under the rest, put drops at the very end.
pub fn endTarget(self: *Reorder) void {
    if (self.siblings_only) return;
    const drop = root.dropTarget(self.kind) orelse return;
    const dragged = drop.as(Drag) orelse return;
    self.mark(root.getItemRectMin(), root.getItemRectMax(), .end);
    if (drop.delivered) self.pending = .{ .dragged = dragged.id, .target = 0, .place = .end };
}

/// Something's being dragged here.
pub fn dragging(self: *const Reorder) bool {
    return root.dragging(self.kind) != null;
}

fn mark(self: *const Reorder, min: root.Vec2, max: root.Vec2, place: Place) void {
    const lines = root.getWindowDrawList();
    lines.pushClipRectFullScreen();
    defer lines.popClipRect();
    const colour = root.getColorU32(.drag_drop_target);
    if (self.horizontal) switch (place) {
        .before => lines.addLine(min, .{ min[0], max[1] }, colour, 2),
        .after, .first => lines.addLine(.{ max[0], min[1] }, max, colour, 2),
        .into, .end => lines.addRect(min, max, colour, 0, 2),
    } else switch (place) {
        .before => lines.addLine(min, .{ max[0], min[1] }, colour, 2),
        .after, .first => lines.addLine(.{ min[0], max[1] }, max, colour, 2),
        .into, .end => lines.addRect(min, max, colour, 0, 2),
    }
}

/// `step` for `id`, among the ones next to it as last drawn. Null if it can't go that way.
pub fn moveOf(self: *const Reorder, id: u64, step: Step) ?Move {
    return stepAmong(self.last.items, id, step);
}

fn stepAmong(rows: []const Drawn, id: u64, step: Step) ?Move {
    const parent = for (rows) |d| {
        if (d.id == id) break d.parent;
    } else return null;
    var count: usize = 0;
    var at: usize = 0;
    for (rows) |d| if (d.parent == parent) {
        if (d.id == id) at = count;
        count += 1;
    };
    const to: usize, const place: Place = switch (step) {
        .up => if (at > 0) .{ at - 1, .before } else return null,
        .down => if (at + 1 < count) .{ at + 1, .after } else return null,
        .top => if (at > 0) .{ 0, .before } else return null,
        .bottom => if (at + 1 < count) .{ count - 1, .after } else return null,
    };
    var k: usize = 0;
    for (rows) |d| if (d.parent == parent) {
        if (k == to) return .{ .dragged = id, .target = d.id, .place = place };
        k += 1;
    };
    return null;
}

/// The moves, for a view's `Commands`, on `id`.
pub fn commands(self: *Reorder, menu: *Commands, id: ?u64, keys: Keys) void {
    inline for (comptime std.enums.values(Step)) |step| {
        const move = if (id) |i| self.moveOf(i, step) else null;
        const chord = switch (step) {
            .up => keys.up,
            .down => keys.down,
            .top, .bottom => null,
        };
        if (menu.item(.{ .label = step.label(self.horizontal), .chord = chord, .enabled = move != null })) self.pending = move;
    }
}

/// Right-click menu for views without `Commands`, outside tables. `extra` is null or has `items(id)`.
pub fn drawMenu(self: *Reorder, extra: anytype) bool {
    if (self.menu_asked) |id| {
        self.menu_for = id;
        root.openPopup(self.kind);
    }
    self.menu_asked = null;
    const popup = root.popup(self.kind) orelse return false;
    defer popup.end();
    if (@TypeOf(extra) != @TypeOf(null)) extra.items(self.menu_for);
    for (std.enums.values(Step)) |step| {
        const move = self.moveOf(self.menu_for, step);
        if (root.menuItem(step.label(self.horizontal), .{ .enabled = move != null })) self.pending = move;
    }
    return true;
}

/// The move asked for this frame, by a drop, the menu or a key.
pub fn take(self: *Reorder) ?Move {
    defer self.pending = null;
    return self.pending;
}

/// Saved order and folds for a view that doesn't own its order. Unmoved rows go after moved ones.
pub const Arrangement = struct {
    order: std.AutoArrayHashMapUnmanaged(u64, void) = .empty,
    folded: std.AutoArrayHashMapUnmanaged(u64, void) = .empty,
    /// Either changed, so it wants saving.
    changed: bool = false,

    pub fn deinit(self: *Arrangement) void {
        self.order.deinit(allocator);
        self.folded.deinit(allocator);
        self.* = .{};
    }

    /// As saved, from `orderIds` and `foldedIds`.
    pub fn load(self: *Arrangement, order: []const u64, folded: []const u64) void {
        self.order.clearRetainingCapacity();
        self.folded.clearRetainingCapacity();
        for (order) |id| self.order.put(allocator, id, {}) catch {};
        for (folded) |id| self.folded.put(allocator, id, {}) catch {};
        self.changed = false;
    }

    pub fn orderIds(self: *const Arrangement) []const u64 {
        return self.order.keys();
    }

    pub fn foldedIds(self: *const Arrangement) []const u64 {
        return self.folded.keys();
    }

    pub fn isFolded(self: *const Arrangement, id: u64) bool {
        return self.folded.contains(id);
    }

    pub fn setFolded(self: *Arrangement, id: u64, folded: bool) void {
        if (folded == self.isFolded(id)) return;
        if (folded) {
            self.folded.put(allocator, id, {}) catch return;
        } else _ = self.folded.orderedRemove(id);
        self.changed = true;
    }

    pub fn toggle(self: *Arrangement, id: u64) void {
        self.setFolded(id, !self.isFolded(id));
    }

    pub fn takeChanged(self: *Arrangement) bool {
        defer self.changed = false;
        return self.changed;
    }

    fn rank(self: *const Arrangement, id: u64) usize {
        return self.order.getIndex(id) orelse std.math.maxInt(usize);
    }

    /// Sorts depth-first `items`. `ctx` has `id(*const T) u64` and `depth(*const T) u32`.
    pub fn arrange(self: *const Arrangement, comptime T: type, items: []T, ctx: anytype) void {
        if (self.order.count() == 0 or items.len < 2) return;
        const scratch = allocator.alloc(T, items.len) catch return;
        defer allocator.free(scratch);
        self.sortRange(T, items, scratch, ctx);
    }

    const Span = struct { start: usize, end: usize, rank: usize };

    fn sortRange(self: *const Arrangement, comptime T: type, items: []T, scratch: []T, ctx: anytype) void {
        if (items.len == 0) return;
        var spans: std.ArrayList(Span) = .empty;
        defer spans.deinit(allocator);
        var i: usize = 0;
        while (i < items.len) {
            const end = spanEnd(T, items, i, ctx);
            spans.append(allocator, .{ .start = i, .end = end, .rank = self.rank(ctx.id(&items[i])) }) catch return;
            i = end;
        }
        std.mem.sort(Span, spans.items, {}, struct {
            fn lessThan(_: void, a: Span, b: Span) bool {
                return if (a.rank != b.rank) a.rank < b.rank else a.start < b.start;
            }
        }.lessThan);
        var at: usize = 0;
        for (spans.items) |s| {
            @memcpy(scratch[at..][0 .. s.end - s.start], items[s.start..s.end]);
            at += s.end - s.start;
        }
        @memcpy(items, scratch[0..items.len]);
        at = 0;
        for (spans.items) |s| {
            const len = s.end - s.start;
            self.sortRange(T, items[at + 1 .. at + len], scratch, ctx);
            at += len;
        }
    }

    fn spanEnd(comptime T: type, items: []const T, i: usize, ctx: anytype) usize {
        const depth = ctx.depth(&items[i]);
        var end = i + 1;
        while (end < items.len and ctx.depth(&items[end]) > depth) end += 1;
        return end;
    }

    fn parentOf(comptime T: type, items: []const T, i: usize, ctx: anytype) ?usize {
        const depth = ctx.depth(&items[i]);
        var j = i;
        while (j > 0) {
            j -= 1;
            if (ctx.depth(&items[j]) < depth) return j;
        }
        return null;
    }

    /// Only applies moves among siblings. True if it moved.
    pub fn apply(self: *Arrangement, comptime T: type, items: []const T, ctx: anytype, move: Move) bool {
        if (move.place != .before and move.place != .after) return false;
        var from: ?usize = null;
        var to: ?usize = null;
        for (items, 0..) |*it, i| {
            const id = ctx.id(it);
            if (id == move.dragged) from = i;
            if (id == move.target) to = i;
        }
        const f = from orelse return false;
        const t = to orelse return false;
        if (f == t) return false;
        const parent = parentOf(T, items, f, ctx);
        if (parent != parentOf(T, items, t, ctx)) return false;

        var ids: std.ArrayList(u64) = .empty;
        defer ids.deinit(allocator);
        const start = if (parent) |p| p + 1 else 0;
        const end = if (parent) |p| spanEnd(T, items, p, ctx) else items.len;
        var i = start;
        while (i < end) : (i = spanEnd(T, items, i, ctx)) {
            if (i != f) ids.append(allocator, ctx.id(&items[i])) catch return false;
        }
        const target_at = std.mem.indexOfScalar(u64, ids.items, move.target) orelse return false;
        ids.insert(allocator, if (move.place == .before) target_at else target_at + 1, move.dragged) catch return false;
        // Each to the end, so they're ranked in this order and after anything else
        for (ids.items) |id| _ = self.order.orderedRemove(id);
        for (ids.items) |id| self.order.put(allocator, id, {}) catch return false;
        self.changed = true;
        return true;
    }
};

const tests = struct {
    const testing = std.testing;

    test "where drops go" {
        const group: Reorder.Item = .{ .id = 2, .group = true, .open = true };
        try testing.expectEqual(.before, placeAt(group, false, 0, 1, 20));
        try testing.expectEqual(.into, placeAt(group, false, 0, 10, 20));
        try testing.expectEqual(.first, placeAt(group, false, 0, 19, 20));
        try testing.expectEqual(.after, placeAt(.{ .id = 3 }, false, 0, 19, 20));
        // Next to its own only
        try testing.expectEqual(.after, placeAt(group, true, 0, 10, 20));
        try testing.expectEqual(null, placeAt(group, true, 7, 10, 20));
    }

    test "moves among the rows next to it" {
        const rows: []const Drawn = &.{
            .{ .id = 1, .parent = 0 },
            .{ .id = 2, .parent = 1 },
            .{ .id = 3, .parent = 1 },
            .{ .id = 4, .parent = 1 },
            .{ .id = 5, .parent = 0 },
        };
        try testing.expectEqual(Move{ .dragged = 3, .target = 2, .place = .before }, stepAmong(rows, 3, .up).?);
        try testing.expectEqual(Move{ .dragged = 3, .target = 4, .place = .after }, stepAmong(rows, 3, .down).?);
        try testing.expectEqual(Move{ .dragged = 4, .target = 2, .place = .before }, stepAmong(rows, 4, .top).?);
        try testing.expectEqual(Move{ .dragged = 1, .target = 5, .place = .after }, stepAmong(rows, 1, .bottom).?);
        try testing.expectEqual(null, stepAmong(rows, 2, .up));
        try testing.expectEqual(null, stepAmong(rows, 5, .down));
        try testing.expectEqual(null, stepAmong(rows, 9, .up));
    }

    const Entry = struct { id: u64, depth: u32 };
    const Ctx = struct {
        fn id(_: Ctx, it: *const Entry) u64 {
            return it.id;
        }
        fn depth(_: Ctx, it: *const Entry) u32 {
            return it.depth;
        }
    };

    fn ids(items: []const Entry, out: []u64) []const u64 {
        for (items, 0..) |it, i| out[i] = it.id;
        return out[0..items.len];
    }

    test "an arrangement sorts each group and takes what's in them along" {
        var a: Arrangement = .{};
        defer a.deinit();
        var items = [_]Entry{
            .{ .id = 1, .depth = 0 },
            .{ .id = 11, .depth = 1 },
            .{ .id = 12, .depth = 1 },
            .{ .id = 121, .depth = 2 },
            .{ .id = 2, .depth = 0 },
            .{ .id = 3, .depth = 0 },
        };
        var buf: [8]u64 = undefined;
        // Unmoved, it's as it comes
        a.arrange(Entry, &items, Ctx{});
        try testing.expectEqualSlices(u64, &.{ 1, 11, 12, 121, 2, 3 }, ids(&items, &buf));

        try testing.expect(a.apply(Entry, &items, Ctx{}, .{ .dragged = 3, .target = 1, .place = .before }));
        try testing.expect(a.apply(Entry, &items, Ctx{}, .{ .dragged = 11, .target = 12, .place = .after }));
        // Not into another group
        try testing.expect(!a.apply(Entry, &items, Ctx{}, .{ .dragged = 2, .target = 11, .place = .before }));
        try testing.expect(a.takeChanged());
        a.arrange(Entry, &items, Ctx{});
        try testing.expectEqualSlices(u64, &.{ 3, 1, 12, 121, 11, 2 }, ids(&items, &buf));

        // Saved and loaded, with something new that goes after
        var saved: [8]u64 = undefined;
        const order = saved[0..a.orderIds().len];
        @memcpy(order, a.orderIds());
        a.load(order, &.{1});
        try testing.expect(a.isFolded(1));
        var more = [_]Entry{
            .{ .id = 4, .depth = 0 },
            .{ .id = 1, .depth = 0 },
            .{ .id = 11, .depth = 1 },
            .{ .id = 12, .depth = 1 },
            .{ .id = 2, .depth = 0 },
            .{ .id = 3, .depth = 0 },
        };
        a.arrange(Entry, &more, Ctx{});
        try testing.expectEqualSlices(u64, &.{ 3, 1, 12, 11, 2, 4 }, ids(&more, &buf));
    }
};

test {
    _ = tests;
}
