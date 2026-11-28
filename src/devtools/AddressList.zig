//! Cheat Engine style list of watched addresses, with groups, held values, typed entries and hotkeys.

const AddressList = @This();

const std = @import("std");

const ui = @import("tuft_ui");
const mem = @import("tuft_mem");
const salamander = @import("salamander_schema");
const Text = @import("tuft_text").Text;
const EditText = @import("tuft_text").EditText;
pub const Chord = @import("tuft_input").Chord;

const root = @import("root.zig");
const AddressBar = @import("AddressBar.zig");
const StructRows = @import("StructRows.zig");
const StructEdit = @import("StructEdit.zig");
const write = @import("write.zig");

const Memory = mem.Memory;
const Symbols = mem.Symbols;
const Claims = mem.Claims;
const Location = mem.Location;
const Kind = mem.values.Kind;
const max_len = mem.values.max_len;
const Schema = salamander.Schema;
const Type = Schema.Ref;
const Ref = @import("tuft_schema").Ref;
pub const Row = StructRows.Row;

pub const default_length = 16;
/// Counts read from memory past this are taken as garbage.
pub const max_count = 1_000_000;
/// Elements shown before the rest is a "more" row.
pub const max_shown = 1000;
/// A byte pattern is three chars per byte.
const max_text = max_len * 3;
const detail_height = 200;
const red: ui.Color = .{ 1, 0.4, 0.4, 1 };
const no_row = std.math.maxInt(u32);
const row_options: StructRows.Options = .{ .gaps = false, .vtables = false, .open_elements = false, .max_rows = 20_000 };
/// Bit entries are read and written as a layout bitfield member is, which needs a schema.
const bits_schema: Schema = .{};

allocator: std.mem.Allocator,
memory: Memory,
symbols: Symbols = .none,
claims: Claims = .none,
/// Where typed entries find their types. Set with `setSchemas`, and kept alive till the next call.
schemas: []const *const Schema = &.{},

/// In list order. A group is followed by its contents, one level deeper.
nodes: std.ArrayList(Node) = .empty,
picked: ui.Selection = .{},
next_key: u64 = 1,
/// What's drawn, built every frame by `build`.
visible: std.ArrayList(Shown) = .empty,
/// Rows inside typed entries and arrays, with the node each is in. Never saved.
rows: std.ArrayList(Row) = .empty,
row_nodes: std.ArrayList(u32) = .empty,
/// Which of `rows` are open. Not saved either.
open: StructRows.Open = .{},
/// Types the rows point at, parsed from their entries' text.
scratch: std.heap.ArenaAllocator.State = .{},
/// Types to pick from, first one wins. Names point into `schemas`, labels are ours.
type_names: std.ArrayList([]const u8) = .empty,
type_labels: std.ArrayList([:0]const u8) = .empty,
choices: std.ArrayList([:0]const u8) = .empty,
/// Key of the node or row whose value is being typed.
editing: ?u64 = null,
edit: Text(max_text) = .{},
focus_edit: bool = false,
problem: ?root.Problem = null,
dirty: bool = false,
/// Dragging and moving entries about.
reorder: ui.Reorder = .{ .kind = drag_kind },
/// Fields and elements held inside typed entries and arrays, and whole ones. Not saved.
holds: std.ArrayList(Hold) = .empty,
/// Typed since the edit started, so the choices are filtered by it.
edit_typed: bool = false,
/// Frames the edit box gets to take focus before leaving it ends the edit.
edit_grace: u8 = 0,
/// Choices that match what's typed, as indexes.
matches: std.ArrayList(u32) = .empty,
/// The picked entry's choices as `value: label` lines, NUL-terminated, for the details panel.
choices_text: []u8 = &.{},
choices_key: u64 = 0,
/// Which of the picked entry's hotkeys are picked, and whose they are.
hotkey_picked: ui.Selection = .{},
hotkeys_key: u64 = 0,
/// Starts listening for this one's keys next frame.
listen_hotkey: ?usize = null,

pub const Bits = struct {
    shift: u8 = 0,
    width: u8 = 1,
};

pub const Choice = struct {
    value: i64 = 0,
    label: []const u8 = "",
};

/// When a held value gets put back.
pub const Freeze = enum {
    always,
    /// Only if the game lowered it. If it went up that's kept, and held from then on.
    only_increase,
    only_decrease,

    pub fn label(self: Freeze) [:0]const u8 {
        return switch (self) {
            .always => "Put back any change",
            .only_increase => "Let it go up, not down",
            .only_decrease => "Let it go down, not up",
        };
    }
};

pub const Action = enum {
    toggle_hold,
    hold,
    release,
    set,
    increase,
    decrease,

    pub fn label(self: Action) [:0]const u8 {
        return switch (self) {
            .toggle_hold => "Hold or let go",
            .hold => "Hold",
            .release => "Let go",
            .set => "Set to",
            .increase => "Increase by",
            .decrease => "Decrease by",
        };
    }

    pub fn takesValue(self: Action) bool {
        return switch (self) {
            .set, .increase, .decrease => true,
            else => false,
        };
    }
};

pub const Hotkey = struct {
    chord: ?Chord = null,
    action: Action = .toggle_hold,
    /// For `set`, `increase` and `decrease`. A choice's label works for `set` too.
    value: []const u8 = "",
};

const NodeKey = struct {
    chord: ?Chord = null,
    action: Action = .toggle_hold,
    value: EditText = .{},
};

const OwnedChoices = struct {
    arena: std.heap.ArenaAllocator,
    items: []const Choice = &.{},
};

const Node = struct {
    /// Stays with it while it moves around the list.
    key: u64 = 0,
    name: EditText = .{},
    /// For code to find it by, like `player.health`.
    id: EditText = .{},
    address: EditText = .{},
    offsets: std.ArrayList(EditText) = .empty,
    kind: Kind = .four_bytes,
    length: u16 = default_length,
    /// A layout type's name. Then `kind` and `length` don't matter.
    type: EditText = .{},
    /// Empty if it's not an array.
    count: EditText = .{},
    depth: u8 = 0,
    group: bool = false,
    expanded: bool = true,
    hold: bool = false,
    held: [max_len]u8 = undefined,
    held_len: u16 = 0,
    /// Just these bits of its value, for plain ints.
    bits: ?Bits = null,
    /// Ours, freed with it. Moving a node moves them along.
    choices: ?*OwnedChoices = null,
    labels_only: bool = false,
    /// Another entry's choices, by its id.
    choices_from: EditText = .{},
    freeze: Freeze = .always,
    hotkeys: std.ArrayList(NodeKey) = .empty,

    fn size(self: *const Node) usize {
        return self.kind.size() orelse std.math.clamp(@as(usize, self.length), 1, max_len);
    }

    fn typed(self: *const Node) bool {
        return std.mem.trim(u8, self.type.get(), " ").len > 0;
    }

    fn array(self: *const Node) bool {
        return std.mem.trim(u8, self.count.get(), " ").len > 0;
    }

    /// A plain value, held on its own rather than through `holds`.
    fn primitive(self: *const Node) bool {
        return !self.group and !self.typed() and !self.array();
    }

    fn hasAddress(self: *const Node) bool {
        return std.mem.trim(u8, self.address.get(), " \t").len > 0;
    }
};

/// A value held inside a typed entry or array, found again from its entry every tick.
const Hold = struct {
    /// The entry's key.
    node: u64,
    /// Which element, if the entry's an array.
    index: ?usize = null,
    /// `Ref.path` steps from there, like `items[2].count` or `best.*.id`. Empty is all of it.
    path: Text(max_path) = .{},
    bytes: [max_len]u8 = undefined,
    len: u16 = 0,
};

const max_path = 160;
/// A module and offset, like `kai.exe+0x1234`.
const describe_len = std.fs.max_path_bytes + 32;

/// A line of the table, a node or one of `rows`.
const Shown = struct {
    node: u32,
    row: u32 = no_row,
    /// The key of the group a node's in, 0 at the top.
    parent: u64 = 0,
};

/// The saved part of an entry. Hand-edited files get made to fit.
pub const Item = struct {
    name: []const u8 = "",
    id: []const u8 = "",
    /// Starting with + or -, it's from the nearest group above it that has an address.
    address: []const u8 = "",
    offsets: []const []const u8 = &.{},
    kind: Kind = .four_bytes,
    length: u16 = default_length,
    /// A layout type's name, or empty for `kind`.
    type: []const u8 = "",
    /// Empty, a number, or where to read a u32 count from.
    count: []const u8 = "",
    depth: u8 = 0,
    group: bool = false,
    expanded: bool = true,
    /// Just these bits of its value. Only for byte, 2, 4 and 8 byte entries.
    bits: ?Bits = null,
    /// Labels for its values, shown in place of them.
    choices: []const Choice = &.{},
    /// Shows just the label, not the number too. Values not in the list still show as numbers.
    labels_only: bool = false,
    /// Uses another entry's choices, by its id.
    choices_from: []const u8 = "",
    /// How it's held. Holds aren't saved, but this is.
    freeze: Freeze = .always,
    hotkeys: []const Hotkey = &.{},
};

pub const Saved = struct {
    items: []const Item = &.{},
};

pub fn deinit(self: *AddressList) void {
    for (self.nodes.items) |*n| self.freeNode(n);
    self.nodes.deinit(self.allocator);
    self.visible.deinit(self.allocator);
    self.rows.deinit(self.allocator);
    self.row_nodes.deinit(self.allocator);
    self.open.deinit(self.allocator);
    self.scratch.promote(self.allocator).deinit();
    self.freeTypeNames();
    self.type_names.deinit(self.allocator);
    self.type_labels.deinit(self.allocator);
    self.choices.deinit(self.allocator);
    self.holds.deinit(self.allocator);
    self.picked.deinit();
    self.matches.deinit(self.allocator);
    self.allocator.free(self.choices_text);
    self.hotkey_picked.deinit();
    self.reorder.deinit();
}

/// Everything it owns. Nodes are moved about, never copied, so each is freed once.
fn freeNode(self: *AddressList, node: *Node) void {
    const gpa = self.allocator;
    self.freeChoices(node);
    for (node.offsets.items) |*o| o.deinit(gpa);
    node.offsets.deinit(gpa);
    for (node.hotkeys.items) |*h| h.value.deinit(gpa);
    node.hotkeys.deinit(gpa);
    inline for (.{ "name", "id", "address", "type", "count", "choices_from" }) |f| @field(node, f).deinit(gpa);
}

/// Out of memory, it keeps what it had.
fn setText(self: *AddressList, text: *EditText, value: []const u8) void {
    text.set(self.allocator, value) catch |err| self.fail("change it", err);
}

fn addOffset(self: *AddressList, node: *Node, text: []const u8) !void {
    var t: EditText = try .init(self.allocator, text);
    errdefer t.deinit(self.allocator);
    try node.offsets.append(self.allocator, t);
}

fn freeChoices(self: *AddressList, node: *Node) void {
    const owned = node.choices orelse return;
    owned.arena.deinit();
    self.allocator.destroy(owned);
    node.choices = null;
}

/// Empty takes them away.
fn setChoices(self: *AddressList, node: *Node, list: []const Choice) !void {
    self.freeChoices(node);
    if (list.len == 0) return;
    const owned = try self.allocator.create(OwnedChoices);
    owned.* = .{ .arena = .init(self.allocator) };
    errdefer {
        owned.arena.deinit();
        self.allocator.destroy(owned);
    }
    const a = owned.arena.allocator();
    const out = try a.alloc(Choice, list.len);
    for (list, out) |c, *d| d.* = .{ .value = c.value, .label = try a.dupe(u8, c.label) };
    owned.items = out;
    node.choices = owned;
}

const Labels = struct {
    items: []const Choice,
    only: bool,
};

/// Its own choices, or the ones of the entry it links to.
fn labelsOf(self: *const AddressList, node: *const Node) ?Labels {
    if (node.group) return null;
    if (node.choices) |c| return .{ .items = c.items, .only = node.labels_only };
    const link = std.mem.trim(u8, node.choices_from.get(), " ");
    if (link.len == 0) return null;
    for (self.nodes.items) |*n| {
        if (n == node or !std.mem.eql(u8, std.mem.trim(u8, n.id.get(), " "), link)) continue;
        const c = n.choices orelse return null;
        return .{ .items = c.items, .only = node.labels_only };
    }
    return null;
}

fn labelFor(list: []const Choice, value: i64) ?[]const u8 {
    for (list) |c| if (c.value == value) return c.label;
    return null;
}

/// The value text, with its label if it has one.
fn labelled(self: *const AddressList, node: *const Node, plain: []const u8, buf: []u8) []const u8 {
    const copied = buf[0..@min(plain.len, buf.len)];
    @memcpy(copied, plain[0..copied.len]);
    const labels = self.labelsOf(node) orelse return copied;
    const n = std.math.cast(i64, mem.values.parseInt(plain) catch return copied) orelse return copied;
    const label = labelFor(labels.items, n) orelse return copied;
    if (labels.only) return std.fmt.bufPrint(buf, "{s}", .{label}) catch copied;
    return std.fmt.bufPrint(buf, "{d}: {s}", .{ n, label }) catch copied;
}

/// A label typed in place of a value is its value. In `buf`.
fn unlabelled(self: *const AddressList, node: *const Node, text: []const u8, buf: []u8) []const u8 {
    const labels = self.labelsOf(node) orelse return text;
    const t = std.mem.trim(u8, text, " \t");
    for (labels.items) |c| {
        if (std.ascii.eqlIgnoreCase(c.label, t)) return std.fmt.bufPrint(buf, "{d}", .{c.value}) catch text;
    }
    return text;
}

/// As a layout bitfield member would be, or null if it's not a bit entry.
fn bitsOf(node: *const Node) ?Ref.Bits {
    const b = node.bits orelse return null;
    if (!node.primitive()) return null;
    const backing: Schema.Prim = switch (node.kind) {
        .byte => .u8,
        .two_bytes => .u16,
        .four_bytes => .u32,
        .eight_bytes => .u64,
        else => return null,
    };
    if (b.width == 0 or @as(usize, b.shift) + b.width > backing.size(8) * 8) return null;
    return .{ .shift = b.shift, .width = b.width, .backing = backing };
}

/// A bit entry as a bits row, to read, show and change it like a layout's.
fn bitRow(self: *const AddressList, node: *const Node, at: usize) ?Row {
    const b = bitsOf(node) orelse return null;
    const t: Type = .{ .prim = b.backing };
    const ref: Ref = .{ .schema = &bits_schema, .type = t, .address = mem.Address.fromMemory(self.memory, at), .bits = b };
    return .{ .id = seedOf(node), .parent = 0, .depth = node.depth, .kind = .bits, .offset = 0, .address = at, .name = node.name.get(), .index = b.shift, .width = b.width, .type = t, .size = b.backing.size(8), .ref = ref };
}

/// The layouts typed entries can use, earlier ones winning name clashes. `sources` labels each one.
/// Rows made from the old ones are dropped.
pub fn setSchemas(self: *AddressList, schemas: []const *const Schema, sources: []const []const u8) void {
    self.setSchemasFrom(schemas, sources, &.{});
}

/// Like `setSchemas`, but types before `from[i]` in schema `i`'s source aren't offered, only usable.
pub fn setSchemasFrom(self: *AddressList, schemas: []const *const Schema, sources: []const []const u8, from: []const usize) void {
    self.schemas = schemas;
    self.forgetRows();
    self.freeTypeNames();
    for (schemas, 0..) |s, i| {
        const source = if (i < sources.len) sources[i] else "";
        const first = if (i < from.len) from[i] else 0;
        for (s.types) |t| {
            if (t.nested or t.at < first or self.hasTypeName(t.name)) continue;
            switch (t.kind) {
                .@"error", .func => continue,
                else => {},
            }
            const label = (if (source.len > 0)
                std.fmt.allocPrintSentinel(self.allocator, "{s} ({s})", .{ t.name, source }, 0)
            else
                self.allocator.dupeSentinel(u8, t.name, 0)) catch return;
            self.type_labels.append(self.allocator, label) catch {
                self.allocator.free(label);
                return;
            };
            self.type_names.append(self.allocator, t.name) catch {
                self.allocator.free(self.type_labels.pop().?);
                return;
            };
        }
    }
}

fn hasTypeName(self: *const AddressList, name: []const u8) bool {
    for (self.type_names.items) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

fn freeTypeNames(self: *AddressList) void {
    for (self.type_labels.items) |n| self.allocator.free(n);
    self.type_labels.clearRetainingCapacity();
    self.type_names.clearRetainingCapacity();
}

/// Rows point at nodes by index, so they go when nodes move.
fn forgetRows(self: *AddressList) void {
    self.rows.clearRetainingCapacity();
    self.row_nodes.clearRetainingCapacity();
    self.visible.clearRetainingCapacity();
}

pub fn selectedIndex(self: *const AddressList) ?usize {
    const key = self.picked.focused() orelse return null;
    return self.indexOfKey(key);
}

/// Index into `rows` of the row picked last, if it's one of those.
pub fn selectedRow(self: *const AddressList) ?usize {
    const key = self.picked.focused() orelse return null;
    return self.rowOfKey(key);
}

pub fn select(self: *AddressList, i: usize) void {
    self.picked.only(self.nodes.items[i].key);
}

fn indexOfKey(self: *const AddressList, key: u64) ?usize {
    for (self.nodes.items, 0..) |*n, i| {
        if (n.key == key) return i;
    }
    return null;
}

fn rowOfKey(self: *const AddressList, key: u64) ?usize {
    for (self.rows.items, 0..) |r, k| {
        if (r.id == key) return k;
    }
    return null;
}

fn newKey(self: *AddressList) u64 {
    defer self.next_key += 1;
    return self.next_key;
}

/// Named by module when it's in one, so it's found again if the module moves.
pub fn addAddress(self: *AddressList, address: usize, kind: Kind, length: usize) !void {
    var node: Node = .{ .kind = kind };
    errdefer self.freeNode(&node);
    var buf: [describe_len]u8 = undefined;
    const expression = self.symbols.describe(address, &buf) orelse (std.fmt.bufPrint(&buf, "0x{x}", .{address}) catch "");
    try node.address.set(self.allocator, expression);
    if (length != 0) node.length = @intCast(@min(length, max_len));
    try self.insert(node);
}

pub fn addEmpty(self: *AddressList) !void {
    try self.insert(.{});
}

pub fn kindForLength(len: usize) Kind {
    return switch (len) {
        1 => .byte,
        2 => .two_bytes,
        4 => .four_bytes,
        8 => .eight_bytes,
        else => .bytes,
    };
}

pub fn addGroup(self: *AddressList, name: []const u8) !void {
    var node: Node = .{ .group = true };
    errdefer self.freeNode(&node);
    try node.name.set(self.allocator, name);
    try self.insert(node);
}

fn insert(self: *AddressList, node: Node) !void {
    var added = node;
    var at = self.nodes.items.len;
    added.depth = 0;
    added.key = self.newKey();
    if (self.selectedIndex()) |s| if (self.nodes.items[s].group) {
        const group = &self.nodes.items[s];
        group.expanded = true;
        added.depth = group.depth +| 1;
        at = self.subtreeEnd(s);
    };
    try self.insertAt(at, added);
}

fn insertAt(self: *AddressList, at: usize, node: Node) !void {
    self.forgetRows();
    try self.nodes.insert(self.allocator, at, node);
    self.picked.only(node.key);
    self.editing = null;
    self.dirty = true;
}

pub fn remove(self: *AddressList, i: usize) void {
    self.forgetRows();
    const end = self.subtreeEnd(i);
    for (self.nodes.items[i..end]) |*n| {
        self.picked.remove(n.key);
        self.dropHolds(n.key);
        self.freeNode(n);
    }
    for (0..end - i) |_| _ = self.nodes.orderedRemove(i);
    self.editing = null;
    self.dirty = true;
}

pub fn removePicked(self: *AddressList) void {
    // From the end, so removing one doesn't move the ones still to check
    var i = self.nodes.items.len;
    while (i > 0) {
        i -= 1;
        if (i < self.nodes.items.len and self.picked.contains(self.nodes.items[i].key)) self.remove(i);
    }
}

/// Does nothing if `target` isn't a group, or is `i` or inside it.
pub fn moveInto(self: *AddressList, i: usize, target: ?usize) !void {
    const end = self.subtreeEnd(i);
    if (target) |t| if (!self.nodes.items[t].group or (t >= i and t < end)) return;
    self.forgetRows();
    var bases = try self.relativeBases();
    defer bases.deinit(self.allocator);
    defer self.dropMoved(bases.items);
    const count = end - i;
    const moved = try self.allocator.dupe(Node, self.nodes.items[i..end]);
    defer self.allocator.free(moved);
    const old_base = moved[0].depth;
    const target_now = if (target) |t| (if (t > i) t - count else t) else null;

    for (0..count) |_| _ = self.nodes.orderedRemove(i);
    const new_base: u8 = if (target_now) |t| self.nodes.items[t].depth +| 1 else 0;
    const at = if (target_now) |t| self.subtreeEnd(t) else self.nodes.items.len;
    for (moved) |*n| n.depth = n.depth - old_base +| new_base;
    try self.nodes.insertSlice(self.allocator, at, moved);
    if (target_now) |t| self.nodes.items[t].expanded = true;
    self.picked.only(moved[0].key);
    self.editing = null;
    self.dirty = true;
}

pub const Place = ui.Reorder.Place;

/// Moves every picked entry if `dragged` is picked, else just it. `.after` a group skips its contents.
pub fn moveTo(self: *AddressList, dragged: u64, key: u64, place: Place) !void {
    const gpa = self.allocator;
    const nodes = self.nodes.items;
    const target = if (place == .end) null else (self.indexOfKey(key) orelse return);
    if ((place == .into or place == .first) and !nodes[target.?].group) return error.NotAGroup;

    var roots: std.ArrayList(usize) = .empty;
    defer roots.deinit(gpa);
    const whole_pick = self.picked.contains(dragged);
    var inside_until: usize = 0;
    for (nodes, 0..) |*n, i| {
        if (i < inside_until) continue;
        if (if (whole_pick) self.picked.contains(n.key) else n.key == dragged) {
            const end = self.subtreeEnd(i);
            if (target) |t| if (t >= i and t < end) {
                // Next to itself is where it is already, and into itself can't be
                if (t == i and place != .into and place != .first) continue;
                return;
            };
            try roots.append(gpa, i);
            inside_until = end;
        }
    }
    if (roots.items.len == 0) return;
    self.forgetRows();
    var bases = try self.relativeBases();
    defer bases.deinit(self.allocator);
    defer self.dropMoved(bases.items);

    var moved: std.ArrayList(Node) = .empty;
    defer moved.deinit(gpa);
    for (roots.items) |i| {
        const base = nodes[i].depth;
        for (nodes[i..self.subtreeEnd(i)]) |n| {
            var rebased = n;
            rebased.depth -= base;
            try moved.append(gpa, rebased);
        }
    }
    const target_key = if (target) |t| nodes[t].key else 0;
    var r = roots.items.len;
    while (r > 0) {
        r -= 1;
        const i = roots.items[r];
        const end = self.subtreeEnd(i);
        self.nodes.replaceRangeAssumeCapacity(i, end - i, &.{});
    }

    var at = self.nodes.items.len;
    var depth: u8 = 0;
    if (target != null) {
        const t = self.indexOfKey(target_key).?;
        const node = &self.nodes.items[t];
        switch (place) {
            .before => {
                at = t;
                depth = node.depth;
            },
            .after => {
                at = self.subtreeEnd(t);
                depth = node.depth;
            },
            .first => {
                node.expanded = true;
                at = t + 1;
                depth = node.depth +| 1;
            },
            .into => {
                node.expanded = true;
                at = self.subtreeEnd(t);
                depth = node.depth +| 1;
            },
            .end => unreachable,
        }
    }
    for (moved.items) |*n| n.depth +|= depth;
    try self.nodes.insertSlice(gpa, at, moved.items);
    self.editing = null;
    self.dirty = true;
}

/// Which group each relative entry is from, before a move.
const Based = struct { key: u64, group: u64 };

fn relativeBases(self: *const AddressList) !std.ArrayList(Based) {
    var out: std.ArrayList(Based) = .empty;
    for (self.nodes.items, 0..) |*n, i| {
        if (!isRelative(n.address.get())) continue;
        try out.append(self.allocator, .{ .key = n.key, .group = self.baseKey(i) });
    }
    return out;
}

fn baseKey(self: *const AddressList, i: usize) u64 {
    const g = self.baseGroup(i) orelse return 0;
    return self.nodes.items[g].key;
}

/// Relative entries now from another group are somewhere else, so what was held there goes.
fn dropMoved(self: *AddressList, before: []const Based) void {
    for (before) |b| {
        const i = self.indexOfKey(b.key) orelse continue;
        if (self.baseKey(i) == b.group) continue;
        self.nodes.items[i].hold = false;
        self.dropHolds(b.key);
    }
}

fn subtreeEnd(self: *const AddressList, i: usize) usize {
    const nodes = self.nodes.items;
    var end = i + 1;
    while (end < nodes.len and nodes[end].depth > nodes[i].depth) end += 1;
    return end;
}

fn parentOf(self: *const AddressList, i: usize) ?usize {
    const nodes = self.nodes.items;
    var j = i;
    while (j > 0) {
        j -= 1;
        if (nodes[j].depth < nodes[i].depth) return j;
    }
    return null;
}

/// The nearest group above `i` with an address, which + addresses in it are from.
fn baseGroup(self: *const AddressList, i: usize) ?usize {
    var p = self.parentOf(i);
    while (p) |g| : (p = self.parentOf(g)) {
        const n = &self.nodes.items[g];
        if (n.group and n.hasAddress()) return g;
    }
    return null;
}

/// Allocated in `arena`, which must outlive whatever uses it.
pub fn items(self: *const AddressList, arena: std.mem.Allocator) ![]Item {
    var out: std.ArrayList(Item) = .empty;
    for (self.nodes.items) |*n| try out.append(arena, try itemOf(arena, n, 0));
    return out.items;
}

/// Like `items`, but just what's picked and what's in picked groups. All of it if nothing is.
pub fn pickedItems(self: *const AddressList, arena: std.mem.Allocator) ![]Item {
    if (self.picked.count() == 0) return self.items(arena);
    var out: std.ArrayList(Item) = .empty;
    const nodes = self.nodes.items;
    var i: usize = 0;
    while (i < nodes.len) {
        if (!self.picked.contains(nodes[i].key)) {
            i += 1;
            continue;
        }
        const end = self.subtreeEnd(i);
        for (nodes[i..end]) |*n| try out.append(arena, try itemOf(arena, n, nodes[i].depth));
        i = end;
    }
    return out.items;
}

fn itemOf(arena: std.mem.Allocator, n: *const Node, base_depth: u8) !Item {
    const offsets = try arena.alloc([]const u8, n.offsets.items.len);
    for (offsets, n.offsets.items) |*dst, *src| dst.* = try arena.dupe(u8, src.get());
    const choices: []Choice = if (n.choices) |c| try arena.alloc(Choice, c.items.len) else &.{};
    if (n.choices) |c| for (choices, c.items) |*dst, src| {
        dst.* = .{ .value = src.value, .label = try arena.dupe(u8, src.label) };
    };
    const hotkeys = try arena.alloc(Hotkey, n.hotkeys.items.len);
    for (hotkeys, n.hotkeys.items) |*dst, *src| dst.* = .{ .chord = src.chord, .action = src.action, .value = try arena.dupe(u8, std.mem.trim(u8, src.value.get(), " ")) };
    return .{
        .name = try arena.dupe(u8, n.name.get()),
        .id = try arena.dupe(u8, n.id.get()),
        .address = try arena.dupe(u8, n.address.get()),
        .offsets = offsets,
        .kind = n.kind,
        .length = n.length,
        .type = try arena.dupe(u8, std.mem.trim(u8, n.type.get(), " ")),
        .count = try arena.dupe(u8, std.mem.trim(u8, n.count.get(), " ")),
        .depth = n.depth - base_depth,
        .group = n.group,
        .expanded = n.expanded,
        .bits = n.bits,
        .choices = choices,
        .labels_only = n.labels_only,
        .choices_from = try arena.dupe(u8, std.mem.trim(u8, n.choices_from.get(), " ")),
        .freeze = n.freeze,
        .hotkeys = hotkeys,
    };
}

/// Nothing is held.
pub fn load(self: *AddressList, saved: []const Item) !void {
    self.forgetRows();
    self.holds.clearRetainingCapacity();
    for (self.nodes.items) |*n| self.freeNode(n);
    self.nodes.clearRetainingCapacity();
    self.picked.clear();
    self.editing = null;
    self.problem = null;
    try self.append(saved);
    self.dirty = false;
}

pub fn append(self: *AddressList, saved: []const Item) !void {
    self.forgetRows();
    const first = self.nodes.items.len;
    for (saved) |item| {
        var node = try self.nodeOf(item);
        errdefer self.freeNode(&node);
        // Only groups have children, and nesting goes one level at a time
        if (self.nodes.items.len > first) {
            const last = self.nodes.items[self.nodes.items.len - 1];
            node.depth = @min(item.depth, if (last.group) last.depth +| 1 else last.depth);
        }
        try self.nodes.append(self.allocator, node);
    }
    self.dirty = true;
}

/// Like `addAddress`, into the picked group if it's one, and picked.
pub fn addItem(self: *AddressList, item: Item) !void {
    var node = try self.nodeOf(item);
    errdefer self.freeNode(&node);
    try self.insert(node);
}

fn nodeOf(self: *AddressList, item: Item) !Node {
    var node: Node = .{
        .key = self.newKey(),
        .kind = item.kind,
        .length = if (item.length == 0) default_length else item.length,
        .group = item.group,
        .expanded = item.expanded,
        .freeze = item.freeze,
    };
    errdefer self.freeNode(&node);
    const gpa = self.allocator;
    try node.name.set(gpa, item.name);
    try node.id.set(gpa, item.id);
    try node.address.set(gpa, item.address);
    for (item.offsets) |offset| try self.addOffset(&node, offset);
    for (item.hotkeys) |h| try self.appendHotkey(&node, h);
    if (!item.group) {
        try node.type.set(gpa, item.type);
        try node.count.set(gpa, item.count);
        node.bits = item.bits;
        node.labels_only = item.labels_only;
        try node.choices_from.set(gpa, item.choices_from);
        try self.setChoices(&node, item.choices);
    }
    return node;
}

/// Waits until nothing is being typed so names aren't saved a letter at a time.
pub fn takeDirty(self: *AddressList) bool {
    if (!self.dirty or ui.isAnyItemActive()) return false;
    self.dirty = false;
    return true;
}

fn isRelative(text: []const u8) bool {
    const t = std.mem.trimStart(u8, text, " \t");
    return t.len > 0 and (t[0] == '+' or t[0] == '-');
}

/// Where node `i` is now, from its group's address if it's relative.
fn resolve(self: *const AddressList, i: usize) anyerror!usize {
    return self.resolveWhy(i, null);
}

fn resolveWhy(self: *const AddressList, i: usize, problem: ?*Location.Problem) anyerror!usize {
    const node = &self.nodes.items[i];
    const base = if (isRelative(node.address.get())) try self.baseOf(i) else null;
    return resolveWith(self.memory, self.symbols, node.address.get(), node.offsets.items, base, problem);
}

/// Where + addresses in `i`'s group are from, if its group has an address.
fn baseOf(self: *const AddressList, i: usize) anyerror!?usize {
    const g = self.baseGroup(i) orelse return null;
    return try self.resolve(g);
}

/// Where a saved entry is now, following its pointers and its groups'. Any thread.
pub fn resolveItem(memory: Memory, symbols: Symbols, all: []const Item, i: usize) !usize {
    const item = all[i];
    var base: ?usize = null;
    if (isRelative(item.address)) if (itemBaseGroup(all, i)) |g| {
        base = try resolveItem(memory, symbols, all, g);
    };
    return resolveText(memory, symbols, item.address, item.offsets, base, null);
}

/// `address` is `tuft_mem.Location` text, from `base` if it starts with + or -, then pointer offsets.
pub fn resolveText(memory: Memory, symbols: Symbols, address: []const u8, offsets: []const []const u8, base: ?usize, problem: ?*Location.Problem) !usize {
    return resolveWith(memory, symbols, address, offsets, base, problem);
}

/// `offsets` as text, or a node's `EditText`s, so nothing's gathered first.
fn resolveWith(memory: Memory, symbols: Symbols, address: []const u8, offsets: anytype, base: ?usize, problem: ?*Location.Problem) !usize {
    var at = try Location.eval(address, .{ .symbols = symbols, .memory = memory, .base = base }, problem);
    for (offsets) |*offset| {
        const text: []const u8 = if (@TypeOf(offset.*) == EditText) offset.get() else offset.*;
        const pointer = memory.load(usize, at) catch return error.Unreadable;
        at = pointer +% @as(usize, @bitCast(try parseOffset(text)));
    }
    return at;
}

/// `16`, `0x10`, `-0x10`.
fn parseOffset(text: []const u8) !isize {
    return Location.parseOffset(text) catch error.InvalidOffset;
}

fn itemParent(all: []const Item, i: usize) ?usize {
    var j = i;
    while (j > 0) {
        j -= 1;
        if (all[j].depth < all[i].depth) return j;
    }
    return null;
}

fn itemBaseGroup(all: []const Item, i: usize) ?usize {
    var p = itemParent(all, i);
    while (p) |g| : (p = itemParent(all, g)) {
        if (all[g].group and std.mem.trim(u8, all[g].address, " \t").len > 0) return g;
    }
    return null;
}

/// Standalone location text for item `i`, like `[(game.exe+0x10)+0x8]+0x4`. In `arena`.
pub fn locationOf(all: []const Item, i: usize, arena: std.mem.Allocator) ![]const u8 {
    const item = all[i];
    const own = std.mem.trim(u8, item.address, " \t");
    if (own.len == 0) return error.NoAddress;
    var text: []const u8 = own;
    if (isRelative(own)) {
        if (itemBaseGroup(all, i)) |g| {
            text = try std.fmt.allocPrint(arena, "({s}){s}", .{ try locationOf(all, g, arena), own });
        } else if (own[0] == '+') return error.NotInGroup;
    }
    for (item.offsets) |o| {
        const offset = try parseOffset(o);
        text = if (offset < 0)
            try std.fmt.allocPrint(arena, "[{s}]-0x{x}", .{ text, @abs(offset) })
        else
            try std.fmt.allocPrint(arena, "[{s}]+0x{x}", .{ text, offset });
    }
    return text;
}

/// The first of `schemas` that knows `t`'s size.
fn schemaFor(schemas: []const *const Schema, t: Type) ?*const Schema {
    for (schemas) |s| if (s.sizeOf(t) != null) return s;
    return null;
}

/// How big one of `item` is, all of it for fixed arrays. 0 if that's not known.
pub fn sizeOfItem(item: Item, schemas: []const *const Schema) usize {
    if (item.group) return 0;
    const each: usize = if (item.type.len > 0) blk: {
        var typed: StructRows.Typed = .{};
        const t = typed.parse(item.type) orelse return 0;
        const s = schemaFor(schemas, t) orelse return 0;
        break :blk s.sizeOf(t) orelse return 0;
    } else item.kind.size() orelse std.math.clamp(@as(usize, item.length), 1, max_len);
    return switch (parseCount(item.count) catch return each) {
        .fixed => |n| each *| n,
        else => each,
    };
}

/// Like `u32`, `Player` or `Item[10]`. In `buf`.
/// In `arena`, or borrowed from `item`.
pub fn typeOfItem(arena: std.mem.Allocator, item: Item) error{OutOfMemory}![]const u8 {
    if (item.group) return "";
    const each = if (item.type.len > 0) item.type else @tagName(item.kind);
    if (item.count.len == 0) return each;
    return std.fmt.allocPrint(arena, "{s}[{s}]", .{ each, item.count });
}

/// A typed entry's type, and the schema it's in.
const Resolved = struct {
    schema: *const Schema,
    type: Type,
};

/// Parsed into `typed`, so it lasts as long as that does.
fn typeOf(self: *const AddressList, node: *const Node, typed: *StructRows.Typed) ?Resolved {
    const t = typed.parse(node.type.get()) orelse return null;
    return .{ .schema = schemaFor(self.schemas, t) orelse return null, .type = t };
}

fn schemaOf(self: *const AddressList, node: *const Node) ?*const Schema {
    var typed: StructRows.Typed = .{};
    return (self.typeOf(node, &typed) orelse return null).schema;
}

fn rowBuilder(self: *AddressList, schema: *const Schema) StructRows {
    return .{ .allocator = self.allocator, .memory = self.memory, .schema = schema, .rows = &self.rows, .open = &self.open, .options = row_options };
}

/// Row ids under a node start from this, so they last while it moves.
fn seedOf(node: *const Node) u64 {
    return StructRows.idOf(node.key, 'n', "", 0);
}

/// `10` or `0x10`, but not `+0x10`, which is where to read it.
fn fixedCount(text: []const u8) ?usize {
    if (isRelative(text)) return null;
    return Location.parseNumber(text);
}

/// What a count read from memory is. u32 unless it says, like `+0x54 as u16`.
pub const CountType = enum { u8, u16, u32, u64, i8, i16, i32, i64 };

fn IntOf(comptime t: CountType) type {
    return switch (t) {
        .u8 => u8,
        .u16 => u16,
        .u32 => u32,
        .u64 => u64,
        .i8 => i8,
        .i16 => i16,
        .i32 => i32,
        .i64 => i64,
    };
}

pub const Count = union(enum) {
    none,
    fixed: usize,
    /// Location text, and what's there.
    read: struct { at: []const u8, type: CountType = .u32 },
};

pub const CountError = error{ TypedFixedCount, UnknownCountType };

/// `10`, `0x10`, `+0x54` or `(table)+0x54 as u16`. Slices `text`.
pub fn parseCount(text: []const u8) CountError!Count {
    const t = std.mem.trim(u8, text, " \t");
    if (t.len == 0) return .none;
    var at = t;
    var as: ?CountType = null;
    if (std.mem.lastIndexOf(u8, t, " as ")) |split| {
        at = std.mem.trim(u8, t[0..split], " \t");
        as = std.meta.stringToEnum(CountType, std.mem.trim(u8, t[split + 4 ..], " \t")) orelse return error.UnknownCountType;
    }
    if (fixedCount(at)) |n| {
        if (as != null) return error.TypedFixedCount;
        return .{ .fixed = n };
    }
    return .{ .read = .{ .at = at, .type = as orelse .u32 } };
}

/// How many are in array `i`, read now if it's not a plain number.
pub fn countOf(self: *const AddressList, i: usize) anyerror!usize {
    const node = &self.nodes.items[i];
    const n: usize = switch (try parseCount(node.count.get())) {
        .none => 0,
        .fixed => |n| n,
        .read => |r| blk: {
            // Relative to the same place the entry's own address is
            const base = if (isRelative(r.at)) try self.baseOf(i) else null;
            const at = try Location.eval(r.at, .{ .symbols = self.symbols, .memory = self.memory, .base = base }, null);
            break :blk try self.readCount(at, r.type);
        },
    };
    if (n > max_count) return error.CountTooBig;
    return n;
}

fn readCount(self: *const AddressList, at: usize, as: CountType) !usize {
    const v: i128 = switch (as) {
        inline else => |t| self.memory.load(IntOf(t), at) catch return error.Unreadable,
    };
    if (v < 0) return error.NegativeCount;
    if (v > max_count) return error.CountTooBig;
    return @intCast(v);
}

/// What's wrong with a count, said plainly. In `buf`.
fn countProblem(node: *const Node, err: anyerror, buf: []u8) []const u8 {
    const text = std.mem.trim(u8, node.count.get(), " \t");
    const out = switch (err) {
        error.CountTooBig => std.fmt.bufPrint(buf, "Count is over {d}", .{max_count}),
        error.NegativeCount => std.fmt.bufPrint(buf, "Count is negative", .{}),
        error.TypedFixedCount => std.fmt.bufPrint(buf, "{s}: a fixed count doesn't need a type", .{text}),
        error.UnknownCountType => blk: {
            const split = std.mem.lastIndexOf(u8, text, " as ") orelse 0;
            break :blk std.fmt.bufPrint(buf, "{s} isn't a count type. It's u8, u16, u32, u64, i8, i16, i32 or i64", .{std.mem.trim(u8, text[@min(split + 4, text.len)..], " \t")});
        },
        else => std.fmt.bufPrint(buf, "Count: {t}", .{err}),
    };
    return out catch "Count can't be read";
}

/// Bytes in one of node `i`, or in each element if it's an array.
fn elementSize(self: *const AddressList, node: *const Node) anyerror!usize {
    if (!node.typed()) return node.size();
    var typed: StructRows.Typed = .{};
    const r = self.typeOf(node, &typed) orelse return error.UnknownType;
    const size = r.schema.sizeOf(r.type) orelse return error.Unsized;
    if (size == 0) return error.Unsized;
    return size;
}

/// A typed entry as a row, to show its value and whether it opens.
const Typed = struct {
    schema: *const Schema,
    row: Row,
};

/// Its type is parsed into `typed`.
fn typedRow(self: *AddressList, i: usize, at: usize, typed: *StructRows.Typed) ?Typed {
    const node = &self.nodes.items[i];
    if (!node.typed() or node.array()) return null;
    const r = self.typeOf(node, typed) orelse return null;
    const b = self.rowBuilder(r.schema);
    const row = b.prepare(.{ .id = seedOf(node), .parent = 0, .depth = node.depth, .kind = .field, .offset = 0, .address = at, .name = node.name.get(), .type = r.type });
    return .{ .schema = r.schema, .row = row };
}

fn opens(self: *AddressList, i: usize) bool {
    const node = &self.nodes.items[i];
    if (node.group or node.array()) return true;
    if (!node.typed()) return false;
    const at = self.resolve(i) catch return false;
    var typed: StructRows.Typed = .{};
    const t = self.typedRow(i, at, &typed) orelse return false;
    return t.row.expandable;
}

/// Works out what's drawn, open nodes and the rows inside open typed entries and arrays.
pub fn build(self: *AddressList) void {
    self.forgetRows();
    var arena = self.scratch.promote(self.allocator);
    _ = arena.reset(.retain_capacity);
    defer self.scratch = arena.state;
    // Contents of a folded group aren't drawn, but still held
    var folded: ?u8 = null;
    for (self.nodes.items, 0..) |*node, i| {
        if (folded) |depth| {
            if (node.depth > depth) continue;
            folded = null;
        }
        self.visible.append(self.allocator, .{ .node = @intCast(i) }) catch return;
        if (node.group and !node.expanded) folded = node.depth;
        if (node.group or !node.expanded or (!node.typed() and !node.array())) continue;
        const first = self.rows.items.len;
        self.addInside(i, arena.allocator());
        for (first..self.rows.items.len) |k| {
            self.row_nodes.append(self.allocator, @intCast(i)) catch return;
            self.visible.append(self.allocator, .{ .node = @intCast(i), .row = @intCast(k) }) catch return;
        }
    }
}

fn addInside(self: *AddressList, i: usize, arena: std.mem.Allocator) void {
    const node = &self.nodes.items[i];
    const at = self.resolve(i) catch return;
    const seed = seedOf(node);
    var parsed: ?Type = null;
    var schema: ?*const Schema = null;
    if (node.typed()) {
        const t = salamander.parseType(arena, std.mem.trim(u8, node.type.get(), " "), null) catch return;
        parsed = t;
        schema = schemaFor(self.schemas, t) orelse return;
    }
    const depth = node.depth +| 1;
    if (!node.array()) {
        var b = self.rowBuilder(schema.?);
        const row = b.prepare(.{ .id = seed, .parent = 0, .depth = node.depth, .kind = .field, .offset = 0, .address = at, .type = parsed });
        if (row.expandable) _ = b.addChildren(row);
        return;
    }
    const count = self.countOf(i) catch return;
    const each = self.elementSize(node) catch return;
    for (0..@min(count, max_shown)) |k| {
        const row: Row = .{ .id = StructRows.idOf(seed, 'e', "", k), .parent = seed, .depth = depth, .kind = .element, .offset = k * each, .address = at +% k * each, .index = k, .type = parsed, .size = each };
        if (schema) |s| {
            var b = self.rowBuilder(s);
            if (!b.addValue(row)) return;
        } else {
            self.rows.append(self.allocator, row) catch return;
        }
    }
    if (count > max_shown) {
        self.rows.append(self.allocator, .{ .id = StructRows.idOf(seed, 'm', "", 0), .parent = seed, .depth = depth, .kind = .more, .offset = max_shown * each, .index = count - max_shown }) catch {};
    }
}

pub const Target = struct {
    address: usize,
    len: usize,
    /// Valid until the list changes.
    name: []const u8,
};

pub fn selectedTarget(self: *const AddressList) ?Target {
    if (self.selectedRow()) |k| {
        const row = self.rows.items[k];
        const address = row.address orelse return null;
        if (row.kind == .more) return null;
        return .{ .address = address, .len = @max(row.size, 1), .name = self.nodes.items[self.row_nodes.items[k]].name.get() };
    }
    const i = self.selectedIndex() orelse return null;
    return self.targetOf(i);
}

pub fn targetOf(self: *const AddressList, i: usize) ?Target {
    if (i >= self.nodes.items.len) return null;
    const node = &self.nodes.items[i];
    if (node.group and !node.hasAddress()) return null;
    const at = self.resolve(i) catch return null;
    var len: usize = if (node.group) 1 else self.elementSize(node) catch 1;
    if (node.array()) len *|= self.countOf(i) catch 1;
    return .{ .address = at, .len = @max(len, 1), .name = node.name.get() };
}

/// If it's held, it's held at the new value.
pub fn setValue(self: *AddressList, i: usize, typed_text: []const u8) void {
    const node = &self.nodes.items[i];
    if (node.group or node.array()) return;
    const at = self.resolve(i) catch |err| {
        self.problem = .init("Can't tell where that is: {t}", .{err});
        return;
    };
    var number: [32]u8 = undefined;
    const text = self.unlabelled(node, typed_text, &number);
    if (node.typed()) {
        var typed: StructRows.Typed = .{};
        const t = self.typedRow(i, at, &typed) orelse return;
        StructEdit.setValue(self.editTarget(t.schema), t.row, text);
        if (self.problem == null) self.recapture(node.key, null, "");
        return;
    }
    if (self.bitRow(node, at)) |row| {
        StructEdit.setValue(self.editTarget(&bits_schema), row, text);
    } else {
        var buf: [max_len]u8 = undefined;
        const bytes = write.valueBytes(node.kind, text, &buf) catch |err| {
            self.problem = .init("Not a {s}: {t}", .{ node.kind.label(), err });
            return;
        };
        self.problem = write.store(self.memory, self.claims, at, bytes);
    }
    if (self.problem == null and node.hold) _ = self.captureNode(i);
}

/// Adds or takes away `by`, as an int if both are, else as floats.
fn stepValue(self: *AddressList, i: usize, by: []const u8, up: bool) void {
    const node = &self.nodes.items[i];
    if (!node.primitive()) return;
    const at = self.resolve(i) catch |err| {
        self.problem = .init("Can't tell where {s} is: {t}", .{ node.name.get(), err });
        return;
    };
    var now_buf: [max_text]u8 = undefined;
    const now = self.rawValue(i, at, &now_buf) orelse {
        self.problem = .init("Can't change {s}: it can't be read", .{node.name.get()});
        return;
    };
    var out: [64]u8 = undefined;
    const text = stepped(now, by, up, &out) catch {
        self.problem = .init("Can't change {s} by {s}", .{ node.name.get(), by });
        return;
    };
    self.setValue(i, text);
}

fn stepped(now: []const u8, by: []const u8, up: bool, buf: []u8) ![]const u8 {
    const delta = std.mem.trim(u8, by, " \t");
    if (mem.values.parseInt(now)) |n| {
        if (mem.values.parseInt(delta)) |d| return std.fmt.bufPrint(buf, "{d}", .{if (up) n +| d else n -| d}) else |_| {}
    } else |_| {}
    const n = try mem.values.parseFloat(f64, now);
    const d = try mem.values.parseFloat(f64, delta);
    return std.fmt.bufPrint(buf, "{d}", .{if (up) n + d else n - d});
}

fn editTarget(self: *AddressList, schema: *const Schema) StructEdit.Target {
    return .{ .schema = schema, .shown = "", .memory = self.memory, .symbols = self.symbols, .claims = self.claims, .problem = &self.problem };
}

/// For `rows[k]`. Elements of plain arrays are written like their entry is.
pub fn setRowValue(self: *AddressList, k: usize, text: []const u8) void {
    const row = self.rows.items[k];
    const node = &self.nodes.items[self.row_nodes.items[k]];
    const at = row.address orelse return;
    if (row.kind == .more) return;
    if (!node.typed()) {
        var buf: [max_len]u8 = undefined;
        const bytes = write.valueBytes(node.kind, text, &buf) catch |err| {
            self.problem = .init("Not a {s}: {t}", .{ node.kind.label(), err });
            return;
        };
        self.problem = write.store(self.memory, self.claims, at, bytes);
    } else {
        const schema = self.schemaOf(node) orelse return;
        StructEdit.setValue(self.editTarget(schema), row, text);
    }
    if (self.problem != null) return;
    const where = self.holdPathOf(k) orelse return;
    self.recapture(node.key, where.index, where.path.get());
}

fn captureNode(self: *AddressList, i: usize) bool {
    const node = &self.nodes.items[i];
    const at = self.resolve(i) catch return false;
    const len = node.size();
    self.memory.read(at, node.held[0..len]) catch return false;
    node.held_len = @intCast(len);
    return true;
}

/// For a group, everything in it. For a typed entry or array, all of it as one block.
pub fn setHeld(self: *AddressList, i: usize, on: bool) void {
    for (i..self.subtreeEnd(i)) |j| {
        const n = &self.nodes.items[j];
        if (n.group) continue;
        if (!n.primitive()) {
            if (!on) {
                self.dropHolds(n.key);
            } else if (j == i) {
                self.hold(n.key, null, "", true);
            } else if (self.fitsWhole(j)) {
                // Ones too big to hold whole are left out of their group's hold
                self.hold(n.key, null, "", false);
            }
            continue;
        }
        n.hold = on and self.captureNode(j);
        if (on and !n.hold) self.problem = .init("Can't hold {s}: it can't be read", .{n.name.get()});
    }
}

fn isHeld(self: *const AddressList, i: usize) bool {
    const nodes = self.nodes.items;
    if (nodes[i].primitive()) return nodes[i].hold;
    if (!nodes[i].group) return self.findHold(nodes[i].key, null, "") != null;
    var any = false;
    for (i + 1..self.subtreeEnd(i)) |j| {
        const n = &nodes[j];
        if (n.group) continue;
        if (n.primitive()) {
            if (!n.hold) return false;
        } else {
            if (!self.fitsWhole(j)) continue;
            if (self.findHold(n.key, null, "") == null) return false;
        }
        any = true;
    }
    return any;
}

/// Whether typed entry or array `i` is small enough to hold whole.
fn fitsWhole(self: *const AddressList, i: usize) bool {
    return switch (self.locate(self.nodes.items[i].key, null, "")) {
        .at => |spot| spot.len > 0 and spot.len <= max_len,
        else => false,
    };
}

/// Where a hold's value is this tick.
const Found = union(enum) {
    at: Spot,
    /// Can't be followed now, like a null pointer. Tried again next tick.
    skip,
    /// Its entry or type is gone, so the hold goes too.
    gone,
};

const Spot = struct {
    address: usize,
    len: usize,
    /// Only these bits of it are kept, for bitfield members.
    bits: ?Ref.Bits = null,

    fn mask(self: Spot, byte: usize) u8 {
        const b = self.bits orelse return 0xFF;
        if (byte >= 8) return 0;
        const ones: u64 = if (b.width >= 64) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(b.width)) - 1;
        const m = ones << @intCast(b.shift);
        return @truncate(m >> @intCast(byte * 8));
    }
};

/// Follows `path` through the entry's type, the way the rows were built.
fn locate(self: *const AddressList, key: u64, index: ?usize, path: []const u8) Found {
    const i = self.indexOfKey(key) orelse return .gone;
    const node = &self.nodes.items[i];
    if (node.group or node.primitive()) return .gone;
    if (node.typed() and self.schemaOf(node) == null) return .gone;
    const at = self.resolve(i) catch return .skip;
    const each = self.elementSize(node) catch return .skip;
    var start = at;
    if (index) |n| {
        if (!node.array()) return .gone;
        start = at +% n *% each;
    } else if (node.array()) {
        if (path.len > 0) return .gone;
        const count = self.countOf(i) catch return .skip;
        return .{ .at = .{ .address = at, .len = each *| count } };
    }
    if (path.len == 0) return .{ .at = .{ .address = start, .len = each } };
    if (!node.typed()) return .gone;
    var typed: StructRows.Typed = .{};
    const r = self.typeOf(node, &typed).?;
    const schema = r.schema;
    const ref = Ref.at(schema, r.type, mem.Address.fromMemory(self.memory, start)).path(path);
    const address = ref.address.unwrap() catch |err| return if (err == error.NoSuchField) .gone else .skip;
    if (ref.bits) |b| return .{ .at = .{ .address = address, .len = b.backing.size(schema.pointer_size), .bits = b } };
    const len = schema.sizeOf(ref.type) orelse return .gone;
    return .{ .at = .{ .address = address, .len = len } };
}

fn findHold(self: *const AddressList, key: u64, index: ?usize, path: []const u8) ?usize {
    for (self.holds.items, 0..) |*h, k| {
        if (h.node == key and h.index == index and std.mem.eql(u8, h.path.get(), path)) return k;
    }
    return null;
}

/// Starts holding what's there now, or holds it at what's there now if it already was.
fn hold(self: *AddressList, key: u64, index: ?usize, path: []const u8, report: bool) void {
    if (path.len >= max_path) {
        if (report) self.cantHold(key, path, "it's too deep");
        return;
    }
    var h: Hold = .{ .node = key, .index = index };
    h.path.set(path);
    if (!self.capture(&h, report)) return;
    if (self.findHold(key, index, path)) |k| {
        self.holds.items[k] = h;
    } else {
        self.holds.append(self.allocator, h) catch {};
    }
}

fn capture(self: *AddressList, h: *Hold, report: bool) bool {
    const spot = switch (self.locate(h.node, h.index, h.path.get())) {
        .at => |spot| spot,
        else => {
            if (report) self.cantHold(h.node, h.path.get(), "it can't be read");
            return false;
        },
    };
    if (spot.len == 0 or spot.len > max_len) {
        if (report) {
            var buf: [96]u8 = undefined;
            self.cantHold(h.node, h.path.get(), std.fmt.bufPrint(&buf, "it's {d} bytes, too big to hold whole. Hold its fields instead", .{spot.len}) catch "it's too big");
        }
        return false;
    }
    self.memory.read(spot.address, h.bytes[0..spot.len]) catch {
        if (report) self.cantHold(h.node, h.path.get(), "it can't be read");
        return false;
    };
    h.len = @intCast(spot.len);
    return true;
}

fn cantHold(self: *AddressList, key: u64, path: []const u8, why: []const u8) void {
    const i = self.indexOfKey(key) orelse return;
    const name = self.nodes.items[i].name.get();
    const dot = if (path.len > 0 and path[0] != '[') "." else "";
    self.problem = .init("Can't hold {s}{s}{s}: {s}", .{ name, dot, path, why });
}

/// Holds at or under `path`, or covering it.
fn recapture(self: *AddressList, key: u64, index: ?usize, path: []const u8) void {
    for (self.holds.items) |*h| {
        if (h.node != key) continue;
        if (covers(h, index, path) or covers(&.{ .node = key, .index = index, .path = textOf(path) }, h.index, h.path.get())) _ = self.capture(h, false);
    }
}

fn textOf(path: []const u8) Text(max_path) {
    var t: Text(max_path) = .{};
    t.set(path);
    return t;
}

/// Whether `h` covers the value at `index` and `path`. Not through a pointer.
fn covers(h: *const Hold, index: ?usize, path: []const u8) bool {
    if (h.index) |n| {
        if (index != n) return false;
    } else if (index != null and h.path.get().len > 0) return false;
    const mine = h.path.get();
    if (!std.mem.startsWith(u8, path, mine)) return false;
    const rest = path[mine.len..];
    if (rest.len == 0) return true;
    if (mine.len > 0 and rest[0] != '.' and rest[0] != '[') return false;
    const step = if (rest[0] == '.') rest[1..] else rest;
    return !std.mem.startsWith(u8, step, "*");
}

/// Its own holds and every hold inside it.
fn dropHolds(self: *AddressList, key: u64) void {
    var k: usize = 0;
    while (k < self.holds.items.len) {
        if (self.holds.items[k].node == key) _ = self.holds.orderedRemove(k) else k += 1;
    }
}

/// Holds at `path` and inside it.
fn dropUnder(self: *AddressList, key: u64, index: ?usize, path: []const u8) void {
    const at: Hold = .{ .node = key, .index = index, .path = textOf(path) };
    var k: usize = 0;
    while (k < self.holds.items.len) {
        const h = &self.holds.items[k];
        if (h.node == key and covers(&at, h.index, h.path.get())) _ = self.holds.orderedRemove(k) else k += 1;
    }
}

/// Where a row is from its entry, for holds.
const HoldPath = struct {
    index: ?usize = null,
    path: Text(max_path) = .{},
};

/// Null for rows that can't be held, like "more".
fn holdPathOf(self: *const AddressList, k: usize) ?HoldPath {
    const row = self.rows.items[k];
    if (row.kind == .more or row.address == null) return null;
    const node = &self.nodes.items[self.row_nodes.items[k]];
    const seed = seedOf(node);
    var chain: [StructRows.max_depth + 1]usize = undefined;
    chain[0] = k;
    var n: usize = 1;
    while (n < chain.len) : (n += 1) chain[n] = self.parentRow(chain[n - 1]) orelse break;

    var out: HoldPath = .{};
    var buf: [max_path]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var first = true;
    // A typed entry that's a pointer opens into what it points at
    var typed: StructRows.Typed = .{};
    var deref = node.typed() and !node.array() and if (typed.parse(node.type.get())) |t| StructRows.isPointer(t) else false;
    var j = n;
    while (j > 0) {
        j -= 1;
        const r = self.rows.items[chain[j]];
        if (r.kind == .element and r.parent == seed and node.array()) {
            out.index = r.index;
            deref = if (r.type) |t| StructRows.isPointer(t) else false;
            continue;
        }
        if (deref) {
            w.writeAll(if (first) "*" else ".*") catch return null;
            first = false;
        }
        switch (r.kind) {
            .element => w.print("[{d}]", .{r.index}) catch return null,
            else => w.print("{s}{s}", .{ if (first) "" else ".", r.name }) catch return null,
        }
        first = false;
        deref = if (r.type) |t| StructRows.isPointer(t) else false;
    }
    if (w.buffered().len >= max_path) return null;
    out.path.set(w.buffered());
    return out;
}

const RowHeld = enum { no, yes, covered };

fn rowHeld(self: *const AddressList, k: usize) RowHeld {
    const where = self.holdPathOf(k) orelse return .no;
    const key = self.nodes.items[self.row_nodes.items[k]].key;
    if (self.findHold(key, where.index, where.path.get()) != null) return .yes;
    for (self.holds.items) |*h| {
        if (h.node == key and covers(h, where.index, where.path.get())) return .covered;
    }
    return .no;
}

pub fn setRowHeld(self: *AddressList, k: usize, on: bool) void {
    const where = self.holdPathOf(k) orelse return;
    const key = self.nodes.items[self.row_nodes.items[k]].key;
    if (on) self.hold(key, where.index, where.path.get(), true) else self.dropUnder(key, where.index, where.path.get());
}

/// Call every frame, drawn or not.
pub fn enforce(self: *AddressList) void {
    for (self.nodes.items, 0..) |*n, i| {
        if (!n.hold) continue;
        const at = self.resolve(i) catch continue;
        self.putBack(.{ .address = at, .len = n.held_len, .bits = bitsOf(n) }, n.held[0..n.held_len], n.kind, n.freeze);
    }
    var k: usize = 0;
    while (k < self.holds.items.len) {
        const h = &self.holds.items[k];
        switch (self.locate(h.node, h.index, h.path.get())) {
            .gone => {
                _ = self.holds.orderedRemove(k);
                continue;
            },
            .skip => {},
            .at => |spot| if (spot.len == h.len) self.putBack(spot, h.bytes[0..h.len], null, .always),
        }
        k += 1;
    }
}

/// Puts `held` back where it's changed, only its held bits. A change `freeze` allows is kept and held.
fn putBack(self: *AddressList, spot: Spot, held: []u8, kind: ?Kind, freeze: Freeze) void {
    var current: [max_len]u8 = undefined;
    const len = held.len;
    self.memory.read(spot.address, current[0..len]) catch return;
    var wanted: [max_len]u8 = undefined;
    for (0..len) |b| {
        const m = spot.mask(b);
        wanted[b] = (current[b] & ~m) | (held[b] & m);
    }
    if (std.mem.eql(u8, current[0..len], wanted[0..len])) return;
    if (allowed(spot, kind, current[0..len], held, freeze)) {
        @memcpy(held, current[0..len]);
        return;
    }
    if (write.store(self.memory, self.claims, spot.address, wanted[0..len])) |problem| self.problem = problem;
}

fn allowed(spot: Spot, kind: ?Kind, now: []const u8, held: []const u8, freeze: Freeze) bool {
    if (freeze == .always) return false;
    const order = if (spot.bits) |b|
        std.math.order(bitsValue(now, b), bitsValue(held, b))
    else
        mem.values.order(kind orelse return false, now, held) orelse return false;
    return order == if (freeze == .only_increase) std.math.Order.gt else std.math.Order.lt;
}

fn bitsValue(bytes: []const u8, b: Ref.Bits) u64 {
    var raw: u64 = 0;
    for (bytes[0..@min(bytes.len, 8)], 0..) |x, k| raw |= @as(u64, x) << @intCast(k * 8);
    const ones: u64 = if (b.width >= 64) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(b.width)) - 1;
    return (raw >> @intCast(b.shift)) & ones;
}

/// A hotkey to bind, from `boundHotkeys`.
pub const Bound = struct {
    /// The entry's key, and which of its hotkeys.
    node: u64,
    index: u8,
    chord: Chord,
    /// Like `Mira: set 999999`.
    label: []const u8,
    /// The entry's name, like `Mira`.
    entry: []const u8,
    /// What it does, like `set 999999`.
    does: []const u8,
    /// The entry's id, else its name, to keep a rebind under.
    owner: []const u8,
};

/// Every hotkey that has keys, in `arena`.
pub fn boundHotkeys(self: *const AddressList, arena: std.mem.Allocator) ![]Bound {
    var out: std.ArrayList(Bound) = .empty;
    for (self.nodes.items) |*n| {
        for (n.hotkeys.items, 0..) |*h, k| {
            const chord = h.chord orelse continue;
            const name = n.name.get();
            const id = std.mem.trim(u8, n.id.get(), " ");
            const entry = if (name.len > 0) name else "(no description)";
            var label_text: std.Io.Writer.Allocating = .init(arena);
            writeHotkeyLabel(&label_text.writer, entry, h.action, h.value.get()) catch return error.OutOfMemory;
            const label = label_text.written();
            const does = if (std.mem.startsWith(u8, label, entry) and label.len > entry.len + 2) label[entry.len + 2 ..] else label;
            try out.append(arena, .{
                .node = n.key,
                .index = @intCast(k),
                .chord = chord,
                .label = label,
                .entry = try arena.dupe(u8, entry),
                .does = does,
                .owner = try arena.dupe(u8, if (id.len > 0) id else name),
            });
        }
    }
    return out.items;
}

/// Like `Mira: set 999999` or `Mira: hold`. In `buf`, cut short for showing.
pub fn hotkeyLabel(buf: []u8, name: []const u8, action: Action, value: []const u8) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    writeHotkeyLabel(&w, name, action, value) catch {};
    return w.buffered();
}

pub fn writeHotkeyLabel(w: *std.Io.Writer, name: []const u8, action: Action, value: []const u8) std.Io.Writer.Error!void {
    const v = std.mem.trim(u8, value, " ");
    switch (action) {
        .toggle_hold => try w.print("{s}: hold or let go", .{name}),
        .hold => try w.print("{s}: hold", .{name}),
        .release => try w.print("{s}: let go", .{name}),
        .set => try w.print("{s}: set {s}", .{ name, v }),
        .increase => try w.print("{s}: increase by {s}", .{ name, v }),
        .decrease => try w.print("{s}: decrease by {s}", .{ name, v }),
    }
}

/// Does what entry `node`'s hotkey `index` does, like its keys were pressed.
pub fn pressHotkey(self: *AddressList, node: u64, index: usize) void {
    const i = self.indexOfKey(node) orelse return;
    const n = &self.nodes.items[i];
    if (index >= n.hotkeys.items.len) return;
    const h = n.hotkeys.items[index];
    self.act(i, h.action, h.value.get());
}

/// On a group, holding is like its checkbox, and values are set on the plain entries in it.
pub fn act(self: *AddressList, i: usize, action: Action, value: []const u8) void {
    switch (action) {
        .toggle_hold => self.setHeld(i, !self.isHeld(i)),
        .hold => if (!self.isHeld(i)) self.setHeld(i, true),
        .release => self.setHeld(i, false),
        .set, .increase, .decrease => for (i..self.subtreeEnd(i)) |j| {
            const n = &self.nodes.items[j];
            if (n.group or (j != i and !n.primitive())) continue;
            if (action == .set) self.setValue(j, value) else self.stepValue(j, value, action == .increase);
        },
    }
}

/// Held values are restored by `enforce`, not here, since that runs undrawn too.
pub fn draw(self: *AddressList) void {
    if (self.problem) |*p| ui.textColored(red, "{s}", .{p.message()});
    self.drawTable(@max(ui.getContentRegionAvail()[1] - detail_height, 80));
    self.applyMove();
    const panel = ui.child("details", .{ 0, 0 }, .{ .border = true }) orelse return;
    defer panel.end();
    _ = self.drawEntry();
    var menu = ui.commands("address_entry", .{});
    defer menu.end();
    self.entryCommands(&menu);
}

pub fn drawList(self: *AddressList) void {
    if (self.problem) |*p| ui.textColored(red, "{s}", .{p.message()});
    self.drawTable(0);
    self.applyMove();
}

pub fn activated(self: *const AddressList) bool {
    return self.picked.activated;
}

fn canEditNode(self: *AddressList, i: usize) bool {
    const node = &self.nodes.items[i];
    if (node.primitive()) return true;
    if (node.group or node.array()) return false;
    const at = self.resolve(i) catch return false;
    var typed: StructRows.Typed = .{};
    const t = self.typedRow(i, at, &typed) orelse return false;
    return StructRows.canEditValue(t.row);
}

fn canEditRow(self: *const AddressList, k: usize) bool {
    const row = self.rows.items[k];
    if (row.kind == .more or row.address == null) return false;
    if (row.type == null) return true;
    return StructRows.canEditValue(row);
}

/// Begin it right after `draw`, with `.activated = activated()`.
pub fn commands(self: *AddressList, menu: *ui.Commands) void {
    const keys = &root.keys;
    const any = self.picked.count() > 0;
    const one = self.selectedIndex();
    const row = self.selectedRow();
    const value = if (one) |i| self.canEditNode(i) else if (row) |k| self.canEditRow(k) else false;
    if (menu.item(.{ .label = "Change value", .chord = keys.edit, .enabled = value, .default = true, .tooltip = "Type a new one in place (Enter or a double-click does too)" })) {
        if (one) |i| self.startEdit(i) else self.startRowEdit(row.?);
    }
    const held = self.allPickedHeld();
    if (menu.item(.{ .label = if (held) "Let go" else "Hold", .chord = keys.hold, .enabled = any, .tooltip = "Keep the value as it is now: put it back whenever the game changes it" })) {
        for (self.nodes.items, 0..) |*n, i| {
            if (self.picked.contains(n.key)) self.setHeld(i, !held);
        }
        for (self.rows.items, 0..) |r, k| {
            if (self.picked.contains(r.id)) self.setRowHeld(k, !held);
        }
    }
    menu.separator();
    if (menu.item(.{ .label = "New entry", .chord = keys.new_entry, .tooltip = "In the selected group if there is one" })) self.addEmpty() catch |err| self.fail("add", err);
    if (menu.item(.{ .label = "New group", .chord = keys.new_group })) self.addGroup("New group") catch |err| self.fail("add", err);
    const addable = if (row) |k| self.rows.items[k].kind == .field or self.rows.items[k].kind == .element else false;
    if (menu.item(.{ .label = "Add as entry", .chord = keys.add_to_list, .enabled = addable, .tooltip = "An entry of its own, next to the one it's in. From the group's address if it has one" })) {
        self.addRow(row.?) catch |err| self.fail("add it", err);
    }
    menu.separator();
    if (menu.item(.{ .label = "Copy", .chord = keys.copy, .enabled = any, .tooltip = "Description, address, type and value, one entry per line" })) self.copy(false);
    if (menu.item(.{ .label = "Copy address", .chord = keys.copy_address, .enabled = any, .tooltip = "Where each one is right now" })) self.copy(true);
    if (menu.item(.{ .label = "Paste", .chord = keys.paste, .tooltip = "Add an entry for each address on the clipboard, one per line" })) {
        if (ui.getClipboard()) |text| _ = self.paste(text);
    }
    menu.separator();
    if (menu.item(.{ .label = "Delete", .chord = keys.delete, .enabled = any, .tooltip = "And what's in picked groups" })) self.removePicked();
    menu.separator();
    const focused = if (self.picked.focused()) |key| if (self.indexOfKey(key) != null) key else null else null;
    self.reorder.commands(menu, focused, .{ .up = keys.move_up, .down = keys.move_down });
}

fn allPickedHeld(self: *const AddressList) bool {
    var any = false;
    for (self.nodes.items, 0..) |*n, i| {
        if (!self.picked.contains(n.key)) continue;
        if (!self.isHeld(i)) return false;
        any = true;
    }
    for (self.rows.items, 0..) |r, k| {
        if (!self.picked.contains(r.id) or self.holdPathOf(k) == null) continue;
        if (self.rowHeld(k) == .no) return false;
        any = true;
    }
    return any;
}

pub fn startEdit(self: *AddressList, i: usize) void {
    const node = &self.nodes.items[i];
    if (node.group or node.array()) return;
    var text: [max_text]u8 = undefined;
    const where = self.resolve(i);
    const shown: []const u8 = if (where) |at| self.rawValue(i, at, &text) orelse "" else |_| "";
    self.edit.set(shown);
    self.editing = node.key;
    self.focus_edit = true;
    self.edit_typed = false;
}

pub fn startRowEdit(self: *AddressList, k: usize) void {
    var text: [max_text]u8 = undefined;
    self.edit.set(self.rowValue(k, &text));
    self.editing = self.rows.items[k].id;
    self.focus_edit = true;
    self.edit_typed = false;
}

/// What a node's Value column shows, null if it can't be read.
fn nodeValue(self: *AddressList, i: usize, at: usize, buf: []u8) ?[]const u8 {
    var raw: [max_text]u8 = undefined;
    const plain = self.rawValue(i, at, &raw) orelse return null;
    return self.labelled(&self.nodes.items[i], plain, buf);
}

/// Without its label.
fn rawValue(self: *AddressList, i: usize, at: usize, buf: []u8) ?[]const u8 {
    const node = &self.nodes.items[i];
    if (node.typed()) {
        var typed: StructRows.Typed = .{};
        const t = self.typedRow(i, at, &typed) orelse return null;
        return StructRows.valueText(self.memory, t.schema, t.row, buf);
    }
    if (self.bitRow(node, at)) |row| {
        const text = StructRows.valueText(self.memory, &bits_schema, row, buf);
        // Errors come out as their names
        _ = mem.values.parseInt(text) catch return null;
        return text;
    }
    return self.primText(node, at, buf);
}

fn primText(self: *const AddressList, node: *const Node, at: usize, buf: []u8) ?[]const u8 {
    var bytes: [max_len]u8 = undefined;
    const len = node.size();
    self.memory.read(at, bytes[0..len]) catch return null;
    return mem.values.format(node.kind, bytes[0..len], buf);
}

fn rowValue(self: *const AddressList, k: usize, buf: []u8) []const u8 {
    const row = self.rows.items[k];
    const node = &self.nodes.items[self.row_nodes.items[k]];
    if (row.kind == .more) return "";
    if (row.type == null) return self.primText(node, row.address orelse return "", buf) orelse "??";
    const schema = self.schemaOf(node) orelse return "";
    return StructRows.valueText(self.memory, schema, row, buf);
}

fn parentRow(self: *const AddressList, k: usize) ?usize {
    const parent = self.rows.items[k].parent;
    var j = k;
    while (j > 0) {
        j -= 1;
        if (self.rows.items[j].id == parent) return j;
    }
    return null;
}

/// Like `Player.items[3].count`, from the entry it's in.
/// In `buf`, cut short for showing.
fn rowPath(self: *const AddressList, k: usize, buf: []u8) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    self.writeRowPath(&w, k) catch {};
    return w.buffered();
}

/// Like `bag.items[1].weight`.
fn writeRowPath(self: *const AddressList, w: *std.Io.Writer, k: usize) std.Io.Writer.Error!void {
    const node = &self.nodes.items[self.row_nodes.items[k]];
    var chain: [StructRows.max_depth + 1]usize = undefined;
    chain[0] = k;
    var n: usize = 1;
    while (n < chain.len) : (n += 1) chain[n] = self.parentRow(chain[n - 1]) orelse break;
    try w.writeAll(node.name.get());
    var j = n;
    while (j > 0) {
        j -= 1;
        const r = self.rows.items[chain[j]];
        switch (r.kind) {
            .element => try w.print("[{d}]", .{r.index}),
            else => try w.print(".{s}", .{r.name}),
        }
    }
}

/// Whether getting to `rows[k]` goes through a pointer, so it's not a fixed offset from its entry.
fn throughPointer(self: *const AddressList, k: usize) bool {
    var at = k;
    while (self.parentRow(at)) |p| : (at = p) {
        if (self.rows.items[p].type) |t| if (StructRows.isPointer(t)) return true;
    }
    return false;
}

/// `rows[k]` as an entry of its own, after the one it's in.
pub fn addRow(self: *AddressList, k: usize) !void {
    const row = self.rows.items[k];
    const i: usize = self.row_nodes.items[k];
    const owner = self.nodes.items[i];
    const address = row.address orelse return error.NoAddress;
    var node: Node = .{ .key = self.newKey(), .depth = owner.depth };
    errdefer self.freeNode(&node);
    const gpa = self.allocator;
    {
        var path: std.Io.Writer.Allocating = .init(gpa);
        defer path.deinit();
        self.writeRowPath(&path.writer, k) catch return error.OutOfMemory;
        try node.name.set(gpa, path.written());
    }

    var buf: [describe_len]u8 = undefined;
    const base = if (self.baseGroup(i) != null) self.baseOf(i) catch null else null;
    if (base != null and owner.offsets.items.len == 0 and !self.throughPointer(k)) {
        const b = base.?;
        const text = if (address >= b) std.fmt.bufPrint(&buf, "+0x{x}", .{address - b}) else std.fmt.bufPrint(&buf, "-0x{x}", .{b - address});
        try node.address.set(gpa, text catch "");
    } else {
        const text = self.symbols.describe(address, &buf) orelse (std.fmt.bufPrint(&buf, "0x{x}", .{address}) catch "");
        try node.address.set(gpa, text);
    }

    if (row.type) |t| {
        const schema = self.schemaOf(&owner) orelse return error.UnknownType;
        const plain = row.kind == .bits or StructRows.isPointer(t) or switch (t) {
            .prim => true,
            .array => StructRows.isText(t),
            else => false,
        };
        if (plain) {
            node.kind = StructRows.kindOf(schema, row);
            if (row.kind == .bits) node.bits = .{ .shift = @intCast(row.index), .width = @intCast(row.width) };
            if (node.kind.size() == null) node.length = @intCast(std.math.clamp(row.size, 1, max_len));
        } else {
            const text = try std.fmt.allocPrint(gpa, "{f}", .{t});
            defer gpa.free(text);
            try node.type.set(gpa, text);
        }
    } else {
        node.kind = owner.kind;
        node.length = owner.length;
    }
    try self.insertAt(self.subtreeEnd(i), node);
}

/// `description, address, type, value` split by tabs, or just addresses.
fn copy(self: *AddressList, addresses_only: bool) void {
    var out: std.Io.Writer.Allocating = .init(self.allocator);
    defer out.deinit();
    const w = &out.writer;
    var lines: usize = 0;
    for (self.nodes.items, 0..) |*n, i| {
        if (self.picked.contains(n.key)) {
            self.copyNode(w, i, addresses_only, &lines) catch return;
        }
        for (self.row_nodes.items, 0..) |owner, k| {
            if (owner != i or !self.picked.contains(self.rows.items[k].id)) continue;
            self.copyRow(w, k, addresses_only, &lines) catch return;
        }
    }
    if (lines == 0) return;
    w.writeByte(0) catch return;
    const written = out.written();
    ui.setClipboard(written[0 .. written.len - 1 :0]);
}

fn copyNode(self: *AddressList, w: *std.Io.Writer, i: usize, addresses_only: bool, lines: *usize) !void {
    const n = &self.nodes.items[i];
    const where = self.resolve(i) catch null;
    if (addresses_only) {
        if (n.group and where == null) return;
        if (lines.* > 0) try w.writeByte('\n');
        if (where) |at| try w.print("0x{x}", .{at}) else try w.writeAll("??");
        lines.* += 1;
        return;
    }
    if (lines.* > 0) try w.writeByte('\n');
    lines.* += 1;
    try w.writeAll(n.name.get());
    if (n.group) return;
    try w.print("\t{s}", .{n.address.get()});
    for (n.offsets.items) |*o| try w.print(" [{s}]", .{o.get()});
    var text: [max_text]u8 = undefined;
    const value: []const u8 = if (n.array()) "" else if (where) |at| self.nodeValue(i, at, &text) orelse "??" else "??";
    var type_buf: [160]u8 = undefined;
    try w.print("\t{s}\t{s}", .{ typeLabel(n, &type_buf), value });
}

fn copyRow(self: *AddressList, w: *std.Io.Writer, k: usize, addresses_only: bool, lines: *usize) !void {
    const row = self.rows.items[k];
    if (row.kind == .more) return;
    if (lines.* > 0) try w.writeByte('\n');
    lines.* += 1;
    if (addresses_only) {
        if (row.address) |at| try w.print("0x{x}", .{at}) else try w.writeAll("??");
        return;
    }
    var text: [max_text]u8 = undefined;
    const node = &self.nodes.items[self.row_nodes.items[k]];
    var type_buf: [128]u8 = undefined;
    try self.writeRowPath(w, k);
    try w.print("\t0x{x}\t{s}\t{s}", .{ row.address orelse 0, rowType(row, node, &type_buf), self.rowValue(k, &text) });
}

/// Like `Player*`, or the entry's kind for rows of plain arrays. In `buf`.
fn rowType(row: Row, node: *const Node, buf: []u8) []const u8 {
    const t = row.type orelse return node.kind.label();
    return std.fmt.bufPrint(buf, "{f}", .{t}) catch "";
}

/// Like `4 Bytes`, `4 Bytes, bits 2..3`, `Player` or `Item[+0x54]`.
fn typeLabel(node: *const Node, buf: []u8) []const u8 {
    if (node.group) return "";
    if (bitsOf(node)) |b| {
        const first = b.shift;
        const last = b.shift + b.width - 1;
        const out = if (b.width == 1) std.fmt.bufPrint(buf, "{s}, bit {d}", .{ node.kind.label(), first }) else std.fmt.bufPrint(buf, "{s}, bits {d}..{d}", .{ node.kind.label(), first, last });
        return out catch node.kind.label();
    }
    const each: []const u8 = if (node.typed()) std.mem.trim(u8, node.type.get(), " ") else node.kind.label();
    if (!node.array()) return each;
    return std.fmt.bufPrint(buf, "{s}[{s}]", .{ each, std.mem.trim(u8, node.count.get(), " ") }) catch each;
}

/// Returns how many were added.
pub fn paste(self: *AddressList, text: []const u8) usize {
    var added: usize = 0;
    var lines = std.mem.tokenizeAny(u8, text, "\r\n");
    while (lines.next()) |line| {
        var node: Node = .{};
        var found = false;
        var fields = std.mem.tokenizeScalar(u8, line, '\t');
        while (fields.next()) |raw_field| {
            const field = std.mem.trim(u8, raw_field, " ");
            if (field.len == 0) continue;
            if (!found) {
                // `copy` writes pointer offsets after the address, as ` [x]`
                const expression = std.mem.trim(u8, field[0 .. std.mem.indexOf(u8, field, " [") orelse field.len], " ");
                if (AddressBar.parseAddress(self.symbols, expression)) |_| {
                    self.setText(&node.address, expression);
                    var offsets = std.mem.tokenizeAny(u8, field[expression.len..], " []");
                    while (offsets.next()) |o| self.addOffset(&node, o) catch break;
                    found = true;
                } else |_| self.setText(&node.name, field);
                continue;
            }
            for (std.enums.values(Kind)) |k| {
                if (std.mem.eql(u8, k.label(), field)) node.kind = k;
            }
        }
        if (!found) {
            self.freeNode(&node);
            continue;
        }
        self.insert(node) catch |err| {
            self.freeNode(&node);
            self.fail("paste", err);
            break;
        };
        added += 1;
    }
    if (added == 0) self.problem = .init("Nothing to paste: no addresses on the clipboard", .{});
    return added;
}

fn fail(self: *AddressList, what: []const u8, err: anyerror) void {
    self.problem = .init("Couldn't {s}: {t}", .{ what, err });
}

fn drawTable(self: *AddressList, height: f32) void {
    const table = ui.table("addresses", 5, .{ .borders = true, .row_background = true, .resizable = true, .sizing = .stretch_prop, .scroll_y = true, .height = height }) orelse return;
    defer table.end();
    ui.tableColumnWith("Hold", .{ .fixed = true, .width = 40 });
    ui.tableColumnWith("Description", .{ .stretch = true, .width = 3 });
    ui.tableColumnWith("Address", .{ .fixed = true, .width = 150 });
    ui.tableColumnWith("Type", .{ .fixed = true, .width = 100 });
    ui.tableColumnWith("Value", .{ .stretch = true, .width = 2 });
    ui.tableHeaders();

    self.build();
    self.noteRows();
    {
        var picking = self.picked.begin(self.visible.items.len, Visible{ .list = self }, .{});
        defer picking.end();
        var lines = ui.clip(self.visible.items.len);
        lines.include(picking.keep());
        while (lines.next()) |line| {
            // Drawing can change the list, so stop and pick it up next frame
            if (line >= self.visible.items.len) continue;
            const shown = self.visible.items[line];
            if (shown.node >= self.nodes.items.len) continue;
            if (shown.row == no_row) {
                self.drawRow(&picking, line, shown, &self.nodes.items[shown.node]);
            } else if (shown.row < self.rows.items.len) {
                self.drawInside(&picking, line, shown.row);
            }
        }
    }
    if (self.reorder.dragging()) self.drawDropEnd();
}

const drag_kind = "tuft.address_list";

/// Every node row, with its group, so moves go past ones scrolled off.
fn noteRows(self: *AddressList) void {
    self.reorder.begin();
    var parents: [256]u64 = undefined;
    for (self.visible.items) |*shown| {
        if (shown.row != no_row) continue;
        const node = &self.nodes.items[shown.node];
        shown.parent = if (node.depth == 0) 0 else parents[node.depth - 1];
        parents[node.depth] = node.key;
        self.reorder.note(node.key, shown.parent);
    }
}

fn applyMove(self: *AddressList) void {
    const move = self.reorder.take() orelse return;
    self.moveTo(move.dragged, move.target, move.place) catch |err| self.fail("move it", err);
}

fn dragAndDrop(self: *AddressList, node: *const Node, parent: u64) void {
    const count = if (self.picked.contains(node.key)) self.picked.count() else 1;
    const name = node.name.get();
    var buf: [32]u8 = undefined;
    const label = if (count > 1) std.fmt.bufPrint(&buf, "{d} entries", .{count}) catch "" else if (name.len == 0) "(no description)" else name;
    self.reorder.item(.{ .id = node.key, .parent = parent, .group = node.group, .open = node.group and node.expanded, .label = label });
}

fn drawDropEnd(self: *AddressList) void {
    ui.tableNextRow();
    _ = ui.tableNextColumn();
    _ = ui.selectableWith("##drop_end", false, .{ .span_columns = true, .allow_overlap = true });
    self.reorder.endTarget();
    _ = ui.tableNextColumn();
    ui.textDisabled("Drop here to put it at the end, out of any group", .{});
}

const Visible = struct {
    list: *const AddressList,

    pub fn id(self: Visible, line: usize) u64 {
        const shown = self.list.visible.items[line];
        if (shown.row != no_row) return self.list.rows.items[shown.row].id;
        return self.list.nodes.items[shown.node].key;
    }
};

fn drawRow(self: *AddressList, picking: anytype, line: usize, shown: Shown, node: *Node) void {
    const i: usize = shown.node;
    const scope = ui.id(@as(i32, @bitCast(@as(u32, @truncate(node.key)))));
    defer scope.end();
    ui.tableNextRow();

    _ = ui.tableNextColumn();
    // The whole row picks it, the checkbox on top still gets its clicks
    _ = picking.row(line, "##row");
    self.dragAndDrop(node, shown.parent);
    ui.sameLine();
    var held = self.isHeld(i);
    if (ui.checkbox("##hold", &held)) self.setHeld(i, held);
    ui.tooltip("{s}", .{if (node.group)
        "Keep everything in this group as it is now"
    else if (node.primitive())
        "Keep this value as it is now: put it back whenever the game changes it"
    else
        "Keep all of it as it is now: put it back whenever the game changes it"});

    _ = ui.tableNextColumn();
    const indented = node.depth > 0;
    if (indented) ui.indent(@as(f32, @floatFromInt(node.depth)) * 14);
    defer if (indented) ui.unindent(@as(f32, @floatFromInt(node.depth)) * 14);
    if (self.opens(i)) {
        if (ui.Outline.arrow(node.expanded)) {
            node.expanded = !node.expanded;
            self.dirty = true;
        }
    } else ui.Outline.noArrow();
    const name = node.name.get();
    if (name.len == 0) ui.textDisabled("(no description)", .{}) else ui.text("{s}", .{name});
    const id = node.id.get();
    if (id.len > 0) {
        ui.sameLine();
        ui.textDisabled("{s}", .{id});
    }
    if (node.group and !node.hasAddress()) return;

    const where = self.resolve(i);
    _ = ui.tableNextColumn();
    if (where) |at| {
        ui.text("0x{x}", .{at});
        var buf: [128]u8 = undefined;
        if (self.symbols.describe(at, &buf)) |described| ui.tooltip("{s}", .{described});
    } else |err| {
        ui.textColored(red, "{t}", .{err});
        var problem: Location.Problem = .{};
        _ = self.resolveWhy(i, &problem) catch {};
        if (problem.message().len > 0) ui.tooltip("{s}", .{problem.message()});
    }
    if (node.group) return;
    _ = ui.tableNextColumn();
    var type_buf: [160]u8 = undefined;
    ui.text("{s}", .{typeLabel(node, &type_buf)});
    _ = ui.tableNextColumn();
    if (node.typed() and self.schemaOf(node) == null) {
        ui.textColored(red, "no layout type {s}", .{std.mem.trim(u8, node.type.get(), " ")});
        return;
    }
    if (node.array()) {
        if (self.countOf(i)) |n| {
            ui.textDisabled("{d} {s}", .{ n, if (n == 1) "item" else "items" });
        } else |err| {
            var buf: [160]u8 = undefined;
            ui.textColored(red, "{s}", .{countProblem(node, err, &buf)});
        }
        return;
    }
    self.drawValue(i, node, where);
}

fn drawValue(self: *AddressList, i: usize, node: *Node, where: anyerror!usize) void {
    if (self.editing == node.key) {
        if (self.drawEditBox(self.labelsOf(node))) self.setValue(i, self.edit.get());
        return;
    }
    var text: [max_text]u8 = undefined;
    const shown: ?[]const u8 = if (where) |at| self.nodeValue(i, at, &text) else |_| null;
    ui.text("{s}", .{shown orelse "??"});
}

/// True once Enter is pressed or a choice is picked.
fn drawEditBox(self: *AddressList, labels: ?Labels) bool {
    if (self.focus_edit) {
        ui.focusNext();
        self.focus_edit = false;
        self.edit_grace = 2;
    }
    var before: [max_text]u8 = undefined;
    const old = before[0..self.edit.get().len];
    @memcpy(old, self.edit.get());
    ui.setNextItemWidth(if (labels != null) -24 else ui.fill);
    const entered = ui.inputTextWith("##edit", &self.edit.buf, .{ .flags = .{ .enter_returns_true = true, .auto_select_all = true }, .tight = true });
    const active = ui.isItemActive();
    const deactivated = ui.isItemDeactivated();
    if (!std.mem.eql(u8, old, self.edit.get())) self.edit_typed = true;
    if (entered) {
        self.editing = null;
        return true;
    }
    const l = labels orelse {
        if (deactivated) self.editing = null;
        return false;
    };
    ui.sameLine();
    var open = false;
    if (ui.comboBegin("##choices", "", .{ .no_preview = true, .large = true })) |combo| {
        defer combo.end();
        open = true;
        if (self.drawChoiceList(l)) |picked| {
            var buf: [32]u8 = undefined;
            self.edit.set(std.fmt.bufPrint(&buf, "{d}", .{picked.value}) catch "");
            self.editing = null;
            return true;
        }
    }
    if (self.edit_grace > 0) {
        self.edit_grace -= 1;
    } else if (!active and !open and !ui.isItemHovered()) {
        self.editing = null;
    }
    return false;
}

/// The ones matching what's typed. Returns the one clicked.
fn drawChoiceList(self: *AddressList, labels: Labels) ?Choice {
    const filter = if (self.edit_typed) std.mem.trim(u8, self.edit.get(), " ") else "";
    self.matches.clearRetainingCapacity();
    for (labels.items, 0..) |c, k| {
        if (!choiceMatches(c, filter)) continue;
        self.matches.append(self.allocator, @intCast(k)) catch break;
    }
    if (self.matches.items.len == 0) ui.textDisabled("Nothing matches {s}", .{filter});
    var picked: ?Choice = null;
    var lines = ui.clip(self.matches.items.len);
    while (lines.next()) |line| {
        const c = labels.items[self.matches.items[line]];
        const scope = ui.id(@as(i32, @intCast(line)));
        defer scope.end();
        var buf: [160]u8 = undefined;
        const text = std.fmt.bufPrintSentinel(&buf, "{d}: {s}", .{ c.value, c.label }, 0) catch "?";
        if (ui.selectable(text, false)) picked = c;
    }
    return picked;
}

/// Its label has `filter` in it, or its value starts with it.
fn choiceMatches(c: Choice, filter: []const u8) bool {
    if (filter.len == 0) return true;
    if (std.ascii.findIgnoreCase(c.label, filter) != null) return true;
    var buf: [24]u8 = undefined;
    const value = std.fmt.bufPrint(&buf, "{d}", .{c.value}) catch return false;
    return std.mem.startsWith(u8, value, filter);
}

/// A field or element of a typed entry or array.
fn drawInside(self: *AddressList, picking: anytype, line: usize, k: usize) void {
    const row = self.rows.items[k];
    const node = &self.nodes.items[self.row_nodes.items[k]];
    const scope = ui.id(@as(i32, @bitCast(@as(u32, @truncate(row.id)))));
    defer scope.end();
    ui.tableNextRow();

    _ = ui.tableNextColumn();
    _ = picking.row(line, "##row");
    if (row.kind != .more and row.address != null) {
        ui.sameLine();
        const state = self.rowHeld(k);
        var held = state != .no;
        {
            const disabled = ui.disabled(state == .covered);
            defer disabled.end();
            if (ui.checkbox("##hold", &held)) self.setRowHeld(k, held);
        }
        ui.tooltip("{s}", .{if (state == .covered) "Held with what it's in" else "Keep this value as it is now: put it back whenever the game changes it"});
    }

    _ = ui.tableNextColumn();
    const indent = @as(f32, @floatFromInt(row.depth)) * 14;
    if (row.depth > 0) ui.indent(indent);
    defer if (row.depth > 0) ui.unindent(indent);
    if (row.expandable) {
        if (ui.Outline.arrow(row.expanded)) self.open.set(self.allocator, row, !row.expanded);
    } else ui.Outline.noArrow();
    switch (row.kind) {
        .element => ui.text("[{d}]", .{row.index}),
        .more => {
            ui.textDisabled("{d} more", .{row.index});
            return;
        },
        else => ui.text("{s}", .{row.name}),
    }

    _ = ui.tableNextColumn();
    if (row.address) |at| {
        if (row.kind == .bits) ui.textDisabled("0x{x}", .{at}) else ui.text("0x{x}", .{at});
    }
    _ = ui.tableNextColumn();
    switch (row.kind) {
        .bits => {
            var type_buf: [128]u8 = undefined;
            const t = rowType(row, node, &type_buf);
            if (row.width == 1) ui.text("{s} bit {d}", .{ t, row.index }) else ui.text("{s} {d}..{d}", .{ t, row.index, row.index + row.width - 1 });
        },
        else => {
            var type_buf: [128]u8 = undefined;
            ui.text("{s}", .{rowType(row, node, &type_buf)});
        },
    }
    _ = ui.tableNextColumn();
    if (self.editing == row.id) {
        if (self.drawEditBox(null)) self.setRowValue(k, self.edit.get());
        return;
    }
    var text: [max_text]u8 = undefined;
    ui.text("{s}", .{self.rowValue(k, &text)});
}

pub fn drawEntry(self: *AddressList) bool {
    if (self.selectedRow()) |k| {
        self.drawRowInfo(k);
        return true;
    }
    const i = self.selectedIndex() orelse {
        ui.textDisabled("Pick an entry to change it. Right-click for more", .{});
        return false;
    };
    const node = &self.nodes.items[i];
    ui.setNextItemWidth(ui.fill);
    if (ui.inputTextGrow("##name", &node.name, self.allocator, .{ .hint = "Description" })) self.dirty = true;
    if (self.drawGroupChoice(i)) return true;

    const in_based = self.baseGroup(i) != null;
    const address_hint: [:0]const u8 = if (node.group)
        (if (in_based) "Address. Optional, +0x10 is from the group it's in. Makes + addresses inside it relative to here" else "Address. Optional. Makes + addresses inside it relative to here")
    else if (in_based)
        "Address: +0x10 from the group's, or kai.exe+0x1234"
    else
        "Address: 0x7FF6A0001000 or kai.exe+0x1234";
    ui.setNextItemWidth(ui.fill);
    if (ui.inputTextGrow("##address", &node.address, self.allocator, .{ .hint = address_hint })) self.changedWhere(node);
    ui.setNextItemWidth(ui.fill);
    if (ui.inputTextGrow("##id", &node.id, self.allocator, .{ .hint = if (node.group) "Id for code, like player" else "Id for code, like player.health" })) self.dirty = true;
    if (!node.group) self.drawType(node);
    if (!node.group) self.drawBits(node);

    ui.separatorText("Pointer offsets");
    var removed: ?usize = null;
    for (node.offsets.items, 0..) |*offset, k| {
        const scope = ui.id(@as(i32, @intCast(k)));
        defer scope.end();
        ui.setNextItemWidth(110);
        if (ui.inputTextGrow("##offset", offset, self.allocator, .{ .hint = "0x10" })) self.changedWhere(node);
        ui.sameLine();
        if (ui.smallButton("x")) removed = k;
    }
    if (removed) |k| {
        var gone = node.offsets.orderedRemove(k);
        gone.deinit(self.allocator);
        self.changedWhere(node);
    }
    if (ui.button("Add offset")) {
        if (node.offsets.append(self.allocator, .{})) |_| self.changedWhere(node) else |err| self.fail("add an offset", err);
    }
    ui.tooltip("Follow another pointer", .{});
    ui.sameLine();
    if (node.group and !node.hasAddress()) {
        ui.textDisabled("Just a folder", .{});
    } else {
        var problem: Location.Problem = .{};
        if (self.resolveWhy(i, &problem)) |at| {
            ui.textDisabled("Resolves to 0x{x}", .{at});
        } else |err| {
            if (problem.message().len > 0) ui.textColored(red, "{s}", .{problem.message()}) else ui.textColored(red, "{t}", .{err});
        }
    }
    if (node.primitive()) {
        ui.separatorText("Holding");
        var mode: usize = @backingInt(node.freeze);
        ui.setNextItemWidth(220);
        if (ui.combo("##freeze", &mode, &freeze_labels)) {
            node.freeze = @fromBackingInt(@intCast(mode));
            self.dirty = true;
        }
        ui.tooltip("What happens when the game changes it while it's held", .{});
        self.drawChoices(node);
    }
    self.drawHotkeys(node);
    return true;
}

const freeze_labels = root.labels(Freeze, Freeze.label);
const action_labels = root.labels(Action, Action.label);

fn drawBits(self: *AddressList, node: *Node) void {
    if (node.typed() or node.array()) return;
    const total: i32 = switch (node.kind) {
        .byte => 8,
        .two_bytes => 16,
        .four_bytes => 32,
        .eight_bytes => 64,
        else => return,
    };
    var bit: i32 = if (node.bits) |b| b.shift else 0;
    var width: i32 = if (node.bits) |b| b.width else 0;
    ui.setNextItemWidth(80);
    const moved = ui.drag("Bit##bit", &bit, 0.1);
    ui.tooltip("The lowest of its bits, from 0", .{});
    ui.sameLine();
    ui.setNextItemWidth(80);
    const resized = ui.drag("Width##width", &width, 0.1);
    ui.tooltip("How many bits it is. 0 is all of it", .{});
    if (!moved and !resized) return;
    bit = std.math.clamp(bit, 0, total - 1);
    width = std.math.clamp(width, 0, total - bit);
    node.bits = if (width == 0) null else .{ .shift = @intCast(bit), .width = @intCast(width) };
    self.changedWhere(node);
}

fn drawChoices(self: *AddressList, node: *Node) void {
    ui.separatorText("Choices");
    if (ui.checkbox("Only the label", &node.labels_only)) self.dirty = true;
    ui.tooltip("Show just the label, not the number too. Numbers that aren't in the list still show", .{});
    ui.sameLine();
    ui.setNextItemWidth(ui.fill);
    if (ui.inputTextGrow("##choices_from", &node.choices_from, self.allocator, .{ .hint = "Or another entry's, by its id" })) self.dirty = true;
    if (self.choices_key != node.key) self.fillChoicesText(node);
    if (self.choices_text.len == 0) return;
    ui.textDisabled("One per line, like 0: Off", .{});
    ui.setNextItemWidth(ui.fill);
    if (ui.inputTextMultiline("##choices", self.choices_text, .{ 0, 120 }, .{})) self.readChoicesText(node);
}

/// `node`'s choices into the box.
fn fillChoicesText(self: *AddressList, node: *const Node) void {
    var out: std.Io.Writer.Allocating = .init(self.allocator);
    defer out.deinit();
    if (node.choices) |c| for (c.items) |ch| out.writer.print("{d}: {s}\n", .{ ch.value, ch.label }) catch return;
    self.choices_key = node.key;
    self.roomForChoices(out.written());
}

/// A box with `text` in it and plenty of room to type more.
fn roomForChoices(self: *AddressList, text: []const u8) void {
    const buf = self.allocator.alloc(u8, text.len * 2 + 4096) catch return;
    @memcpy(buf[0..text.len], text);
    buf[text.len] = 0;
    self.allocator.free(self.choices_text);
    self.choices_text = buf;
}

fn readChoicesText(self: *AddressList, node: *Node) void {
    const text = std.mem.sliceTo(self.choices_text, 0);
    var list: std.ArrayList(Choice) = .empty;
    defer list.deinit(self.allocator);
    var lines = std.mem.tokenizeAny(u8, text, "\r\n");
    while (lines.next()) |line| {
        const c = parseChoice(line) orelse continue;
        list.append(self.allocator, c) catch return;
    }
    self.setChoices(node, list.items) catch |err| self.fail("change the choices", err);
    self.dirty = true;
    if (text.len + 1024 > self.choices_text.len) self.roomForChoices(text);
}

/// `0: Off`, or null if it's not one.
pub fn parseChoice(line: []const u8) ?Choice {
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return null;
    const value = mem.values.parseInt(std.mem.trim(u8, line[0..colon], " \t")) catch return null;
    return .{ .value = std.math.cast(i64, value) orelse return null, .label = std.mem.trim(u8, line[colon + 1 ..], " \t") };
}

fn drawHotkeys(self: *AddressList, node: *Node) void {
    ui.separatorText("Hotkeys");
    if (self.hotkeys_key != node.key) {
        self.hotkey_picked.clear();
        self.hotkeys_key = node.key;
    }
    defer self.listen_hotkey = null;
    if (node.hotkeys.items.len == 0) {
        ui.textDisabled("None yet. Right-click here to add one", .{});
        return;
    }
    const table = ui.table("hotkeys", 3, .{ .borders = true, .sizing = .stretch_prop }) orelse return;
    defer table.end();
    ui.tableColumnWith("Keys", .{ .fixed = true, .width = 150 });
    ui.tableColumnWith("Does", .{ .fixed = true, .width = 130 });
    ui.tableColumnWith("Value", .{ .stretch = true, .width = 1 });
    ui.tableHeaders();
    var picking = self.hotkey_picked.begin(node.hotkeys.items.len, ui.Selection.Indices{}, .{});
    defer picking.end();
    for (node.hotkeys.items, 0..) |*h, k| {
        const scope = ui.id(@as(i32, @intCast(k)));
        defer scope.end();
        ui.tableNextRow();
        _ = ui.tableNextColumn();
        _ = picking.row(k, "##hotkey");
        ui.sameLine();
        ui.setNextItemWidth(ui.fill);
        if (ui.chordInput("##chord", &h.chord, .{ .listen = self.listen_hotkey == k, .none = "No keys" })) self.dirty = true;
        _ = ui.tableNextColumn();
        var action: usize = @backingInt(h.action);
        ui.setNextItemWidth(ui.fill);
        if (ui.combo("##action", &action, &action_labels)) {
            h.action = @fromBackingInt(@intCast(action));
            self.dirty = true;
        }
        _ = ui.tableNextColumn();
        if (!h.action.takesValue()) continue;
        ui.setNextItemWidth(ui.fill);
        if (ui.inputTextGrow("##value", &h.value, self.allocator, .{ .hint = "A number, or a choice for Set to" })) self.dirty = true;
    }
}

/// For the details panel. Begin it right after `drawEntry`.
pub fn entryCommands(self: *AddressList, menu: *ui.Commands) void {
    const i = self.selectedIndex();
    const node: ?*Node = if (i) |n| &self.nodes.items[n] else null;
    if (menu.item(.{ .label = "Add hotkey", .enabled = node != null, .tooltip = "Then press its keys. Bound in the game's keybinds, so they work with the workbench closed" })) self.addHotkey(i.?, .{});
    const picked = if (node) |n| self.pickedHotkey(n) else null;
    if (menu.item(.{ .label = "Remove hotkey", .enabled = picked != null })) self.removeHotkey(i.?, picked.?);
}

/// Listens for its keys if it has none.
pub fn addHotkey(self: *AddressList, i: usize, hotkey: Hotkey) void {
    const node = &self.nodes.items[i];
    const k = node.hotkeys.items.len;
    self.appendHotkey(node, hotkey) catch |err| return self.fail("add a hotkey", err);
    self.hotkeys_key = node.key;
    self.hotkey_picked.only(k);
    if (hotkey.chord == null) self.listen_hotkey = k;
    self.dirty = true;
}

fn appendHotkey(self: *AddressList, node: *Node, hotkey: Hotkey) !void {
    var value: EditText = try .init(self.allocator, hotkey.value);
    errdefer value.deinit(self.allocator);
    try node.hotkeys.append(self.allocator, .{ .chord = hotkey.chord, .action = hotkey.action, .value = value });
}

pub fn removeHotkey(self: *AddressList, i: usize, k: usize) void {
    const node = &self.nodes.items[i];
    if (k >= node.hotkeys.items.len) return;
    var gone = node.hotkeys.orderedRemove(k);
    gone.value.deinit(self.allocator);
    self.hotkey_picked.clear();
    self.dirty = true;
}

fn pickedHotkey(self: *const AddressList, node: *const Node) ?usize {
    if (self.hotkeys_key != node.key) return null;
    const k = self.hotkey_picked.focused() orelse return null;
    return if (k < node.hotkeys.items.len) @intCast(k) else null;
}

/// Where it is moved, so what was held there isn't put back.
fn changedWhere(self: *AddressList, node: *Node) void {
    node.hold = false;
    self.dropHolds(node.key);
    self.dirty = true;
}

fn drawType(self: *AddressList, node: *Node) void {
    self.choices.clearRetainingCapacity();
    self.choices.appendSlice(self.allocator, &kind_labels) catch return;
    self.choices.appendSlice(self.allocator, self.type_labels.items) catch return;
    const type_text = std.mem.trim(u8, node.type.get(), " ");
    var current: usize = @backingInt(node.kind);
    if (type_text.len > 0) {
        current = for (self.type_names.items, 0..) |n, k| {
            if (std.mem.eql(u8, n, type_text)) break kind_labels.len + k;
        } else blk: {
            // One the layouts don't have, kept till another is picked
            self.choices.append(self.allocator, node.type.get()) catch return;
            break :blk self.choices.items.len - 1;
        };
    }
    ui.setNextItemWidth(150);
    if (ui.combo("##kind", &current, self.choices.items)) {
        if (current < kind_labels.len) {
            node.kind = @fromBackingInt(@intCast(current));
            self.setText(&node.type, "");
        } else if (current < kind_labels.len + self.type_names.items.len) {
            self.setText(&node.type, self.type_names.items[current - kind_labels.len]);
        }
        self.changedWhere(node);
    }
    ui.tooltip("A value, or a type from the project's layouts", .{});
    if (!node.typed() and node.kind.size() == null) {
        ui.sameLine();
        ui.setNextItemWidth(100);
        var length: i32 = node.length;
        if (ui.drag("##length", &length, 0.5)) {
            node.length = @intCast(std.math.clamp(length, 1, max_len));
            self.changedWhere(node);
        }
        ui.sameLine();
        ui.text("bytes", .{});
    }
    ui.sameLine();
    ui.setNextItemWidth(ui.fill);
    if (ui.inputTextGrow("##count", &node.count, self.allocator, .{ .hint = "Blank, 10, or +0x54 to read it (as u16 for other sizes)" })) self.changedWhere(node);
    ui.tooltip("Makes it an array. A number, or where to read the count from. That's 4 bytes unless it ends in as u8, as u16, as u64 or a signed one like as i32", .{});
}

/// What a row inside a typed entry or array is, read only.
fn drawRowInfo(self: *AddressList, k: usize) void {
    const row = self.rows.items[k];
    const node = &self.nodes.items[self.row_nodes.items[k]];
    var path: [128]u8 = undefined;
    ui.text("{s}", .{self.rowPath(k, &path)});
    ui.textDisabled("Inside {s}. Right-click to add it as an entry of its own", .{node.name.get()});
    if (row.address) |at| ui.textDisabled("At 0x{x}", .{at});
    var type_buf: [128]u8 = undefined;
    if (row.kind != .more) ui.textDisabled("Type {s}, {d} bytes", .{ rowType(row, node, &type_buf), row.size });
}

/// True if it moved, which makes what we drew from stale.
fn drawGroupChoice(self: *AddressList, i: usize) bool {
    const max_groups = 64;
    var names: [max_groups + 1][:0]const u8 = undefined;
    var targets: [max_groups + 1]?usize = undefined;
    names[0] = "(top level)";
    targets[0] = null;
    var count: usize = 1;
    var current: usize = 0;
    const parent = self.parentOf(i);
    const end = self.subtreeEnd(i);
    for (self.nodes.items, 0..) |*g, at| {
        if (!g.group or (at >= i and at < end) or count == names.len) continue;
        if (parent == at) current = count;
        const name = g.name.get();
        names[count] = if (name.len == 0) "(unnamed group)" else name;
        targets[count] = at;
        count += 1;
    }
    ui.setNextItemWidth(220);
    if (!ui.combo("In group##group", &current, names[0..count])) return false;
    self.moveInto(i, targets[current]) catch |err| self.fail("move it", err);
    return true;
}

const kind_labels = root.labels(Kind, Kind.label);

const tests = struct {
    const testing = std.testing;

    fn list() AddressList {
        return .{ .allocator = testing.allocator, .memory = .local, .symbols = .local };
    }

    fn setAddress(self: *AddressList, i: usize, address: usize) void {
        var buf: [32]u8 = undefined;
        self.nodes.items[i].address.set(self.allocator, std.fmt.bufPrint(&buf, "0x{x}", .{address}) catch unreachable) catch unreachable;
    }

    fn setOffsets(node: *Node, offsets: []const []const u8) void {
        for (node.offsets.items) |*o| o.deinit(testing.allocator);
        node.offsets.clearRetainingCapacity();
        for (offsets) |o| node.offsets.append(testing.allocator, EditText.init(testing.allocator, o) catch unreachable) catch unreachable;
    }

    test "pointer chains" {
        var target: u32 align(8) = 77;
        var inner: [2]usize = .{ @intFromPtr(&target) - 0x10, 0 };
        var outer: usize = @intFromPtr(&inner) - 0x8;
        var nothing: usize = 0;
        var l = list();
        defer l.deinit();
        try l.addEmpty();
        setAddress(&l, 0, @intFromPtr(&outer));
        const node = &l.nodes.items[0];

        try testing.expectEqual(@intFromPtr(&outer), try l.resolve(0));
        setOffsets(node, &.{"8"});
        try testing.expectEqual(@intFromPtr(&inner), try l.resolve(0));
        setOffsets(node, &.{ "8", "0x10" });
        try testing.expectEqual(@intFromPtr(&target), try l.resolve(0));
        l.select(0);
        const selected = l.selectedTarget().?;
        try testing.expectEqual(@intFromPtr(&target), selected.address);
        try testing.expectEqual(4, selected.len);
        setOffsets(node, &.{"-0x8"});
        try testing.expectEqual(@intFromPtr(&inner) - 0x10, try l.resolve(0));
        setOffsets(node, &.{"nope"});
        try testing.expectError(error.InvalidOffset, l.resolve(0));

        setAddress(&l, 0, @intFromPtr(&nothing));
        setOffsets(node, &.{ "0", "0" });
        try testing.expectError(error.Unreadable, l.resolve(0));
    }

    test "set and hold values" {
        var value: u32 align(4) = 5;
        var l = list();
        defer l.deinit();
        try l.addAddress(@intFromPtr(&value), .four_bytes, 0);
        l.setValue(0, "100");
        try testing.expectEqual(null, l.problem);
        try testing.expectEqual(100, value);

        l.setHeld(0, true);
        value = 1;
        l.enforce();
        try testing.expectEqual(100, value);
        l.setValue(0, "7");
        value = 1;
        l.enforce();
        try testing.expectEqual(7, value);

        l.setHeld(0, false);
        value = 1;
        l.enforce();
        try testing.expectEqual(1, value);

        l.setValue(0, "x");
        try testing.expectEqualStrings("Not a 4 Bytes: InvalidValue", l.problem.?.message());
    }

    test "groups" {
        var a: u8 = 1;
        var b: u8 = 2;
        var l = list();
        defer l.deinit();
        try l.addGroup("Player");
        try l.addAddress(@intFromPtr(&a), .byte, 0);
        l.select(0);
        try l.addAddress(@intFromPtr(&b), .byte, 0);
        l.select(0);
        try l.addGroup("Inner");
        try testing.expectEqual(4, l.nodes.items.len);
        try testing.expectEqual(1, l.nodes.items[1].depth);
        try testing.expectEqual(1, l.nodes.items[3].depth);

        l.setHeld(0, true);
        try testing.expect(l.isHeld(0));
        a = 9;
        b = 9;
        l.enforce();
        try testing.expectEqual(1, a);
        try testing.expectEqual(2, b);

        try l.moveInto(2, 3);
        try testing.expectEqual(2, l.nodes.items[3].depth);
        try l.moveInto(l.selectedIndex().?, null);
        try testing.expectEqual(0, l.nodes.items[l.selectedIndex().?].depth);
        try l.moveInto(0, 2);
        try testing.expectEqual(0, l.nodes.items[0].depth);

        l.remove(0);
        try testing.expectEqual(1, l.nodes.items.len);
    }

    fn names(l: *const AddressList, out: []u8) []const u8 {
        var w: std.Io.Writer = .fixed(out);
        for (l.nodes.items) |*n| w.print("{d}{s} ", .{ n.depth, n.name.get() }) catch unreachable;
        return w.buffered();
    }

    fn named(l: *const AddressList, name: []const u8) u64 {
        for (l.nodes.items) |*n| if (std.mem.eql(u8, n.name.get(), name)) return n.key;
        unreachable;
    }

    test "drag and drop moves" {
        var l = list();
        defer l.deinit();
        var buf: [128]u8 = undefined;
        try l.load(&.{
            .{ .name = "G", .group = true },
            .{ .name = "a", .depth = 1 },
            .{ .name = "b", .depth = 1 },
            .{ .name = "c" },
            .{ .name = "d" },
        });

        try l.moveTo(named(&l, "d"), named(&l, "a"), .before);
        try testing.expectEqualStrings("0G 1d 1a 1b 0c ", names(&l, &buf));
        try l.moveTo(named(&l, "c"), named(&l, "G"), .first);
        try testing.expectEqualStrings("0G 1c 1d 1a 1b ", names(&l, &buf));
        // After a group is after what's in it
        try l.moveTo(named(&l, "c"), named(&l, "G"), .after);
        try testing.expectEqualStrings("0G 1d 1a 1b 0c ", names(&l, &buf));
        try l.moveTo(named(&l, "c"), named(&l, "G"), .first);
        l.picked.clear();
        l.picked.add(named(&l, "b"));
        l.picked.add(named(&l, "d"));
        try l.moveTo(named(&l, "b"), 0, .end);
        try testing.expectEqualStrings("0G 1c 1a 0d 0b ", names(&l, &buf));
        l.picked.clear();
        try l.load(&.{
            .{ .name = "G", .group = true },
            .{ .name = "a", .depth = 1 },
            .{ .name = "H", .group = true },
            .{ .name = "x", .depth = 1 },
        });
        try l.moveTo(named(&l, "G"), named(&l, "H"), .into);
        try testing.expectEqualStrings("0H 1x 1G 2a ", names(&l, &buf));
        try l.moveTo(named(&l, "G"), named(&l, "G"), .into);
        try l.moveTo(named(&l, "G"), named(&l, "a"), .before);
        try testing.expectEqualStrings("0H 1x 1G 2a ", names(&l, &buf));
        try testing.expectError(error.NotAGroup, l.moveTo(named(&l, "G"), named(&l, "x"), .into));
        try testing.expectEqualStrings("0H 1x 1G 2a ", names(&l, &buf));
    }

    test "picked items take their groups' contents" {
        var l = list();
        defer l.deinit();
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        try l.load(&.{
            .{ .name = "H", .group = true },
            .{ .name = "G", .depth = 1, .group = true },
            .{ .name = "a", .depth = 2 },
            .{ .name = "b" },
        });
        try testing.expectEqual(4, (try l.pickedItems(arena.allocator())).len);
        l.picked.add(named(&l, "G"));
        l.picked.add(named(&l, "a"));
        l.picked.add(named(&l, "b"));
        const got = try l.pickedItems(arena.allocator());
        try testing.expectEqual(3, got.len);
        try testing.expectEqualStrings("G", got[0].name);
        try testing.expectEqual(0, got[0].depth);
        try testing.expectEqual(1, got[1].depth);
        try testing.expectEqualStrings("b", got[2].name);
    }

    test "paste and delete" {
        var a: u32 = 1;
        var l = list();
        defer l.deinit();
        var buf: [256]u8 = undefined;
        const text = try std.fmt.bufPrint(&buf, "Health\t0x{x} [10]\t2 Bytes\t5\n0x{x}\nnot an address", .{ @intFromPtr(&a), @intFromPtr(&a) });
        try testing.expectEqual(2, l.paste(text));
        try testing.expectEqualStrings("Health", l.nodes.items[0].name.get());
        try testing.expectEqual(1, l.nodes.items[0].offsets.items.len);
        try testing.expectEqualStrings("10", l.nodes.items[0].offsets.items[0].get());
        try testing.expectEqual(.two_bytes, l.nodes.items[0].kind);
        try testing.expectEqual(@intFromPtr(&a), l.targetOf(1).?.address);

        try l.addGroup("Kept");
        l.picked.clear();
        l.picked.add(l.nodes.items[0].key);
        l.picked.add(l.nodes.items[1].key);
        l.removePicked();
        try testing.expectEqual(1, l.nodes.items.len);
        try testing.expect(l.nodes.items[0].group);
    }

    test "save and load" {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        var l = list();
        defer l.deinit();
        try l.addGroup("Player");
        try l.addAddress(0x1000, .float, 0);
        setOffsets(&l.nodes.items[1], &.{ "10", "-0x4" });
        l.nodes.items[1].hold = true;

        var back = list();
        defer back.deinit();
        try back.load(try l.items(arena.allocator()));
        try testing.expectEqual(2, back.nodes.items.len);
        try testing.expectEqualStrings("0x1000", back.nodes.items[1].address.get());
        try testing.expectEqual(.float, back.nodes.items[1].kind);
        try testing.expectEqual(2, back.nodes.items[1].offsets.items.len);
        try testing.expectEqualStrings("-0x4", back.nodes.items[1].offsets.items[1].get());
        try testing.expect(!back.nodes.items[1].hold);

        try back.load(&.{ .{ .name = "a", .depth = 3 }, .{ .name = "b", .depth = 2, .address = "0x1" } });
        try testing.expectEqual(0, back.nodes.items[0].depth);
        try testing.expectEqual(0, back.nodes.items[1].depth);

        try back.append(&.{.{ .name = "more", .depth = 4 }});
        try testing.expectEqual(3, back.nodes.items.len);
        try testing.expectEqual(0, back.nodes.items[2].depth);
    }

    test "save and load types, counts and group addresses" {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var l = list();
        defer l.deinit();
        try l.load(&.{
            .{ .name = "Bag", .group = true, .address = "game.exe+0x10", .offsets = &.{"8"}, .id = "bag" },
            .{ .name = "items", .depth = 1, .address = "+0x8", .type = "Item", .count = "+0x4" },
            .{ .name = "ids", .depth = 1, .address = "+0x40", .kind = .two_bytes, .count = "10" },
        });
        var out: std.Io.Writer.Allocating = .init(a);
        try std.zon.stringify.serialize(Saved{ .items = try l.items(a) }, .{}, &out.writer);
        const text = try a.dupeSentinel(u8, out.written(), 0);
        var diagnostics: std.zon.parse.Diagnostics = undefined;
        const saved = try std.zon.parse.fromSlice(Saved, .{ .gpa = a, .arena = a, .source = text, .diagnostics = &diagnostics, .ignore_unknown_fields = true });

        var back = list();
        defer back.deinit();
        try back.load(saved.items);
        const got = try back.items(a);
        try testing.expectEqual(3, got.len);
        try testing.expectEqualStrings("game.exe+0x10", got[0].address);
        try testing.expectEqualStrings("8", got[0].offsets[0]);
        try testing.expectEqualStrings("bag", got[0].id);
        try testing.expectEqualStrings("Item", got[1].type);
        try testing.expectEqualStrings("+0x4", got[1].count);
        try testing.expectEqual(1, got[1].depth);
        try testing.expectEqual(.two_bytes, got[2].kind);
        try testing.expectEqualStrings("10", got[2].count);

        // Files from before still load
        const old = try std.zon.parse.fromSlice(Saved, .{ .gpa = a, .arena = a, .source = ".{ .items = .{ .{ .name = \"a\", .address = \"0x1\", .kind = .float } } }", .diagnostics = &diagnostics, .ignore_unknown_fields = true });
        try testing.expectEqualStrings("", old.items[0].type);
        try testing.expectEqualStrings("", old.items[0].count);
    }

    fn hex(arena: std.mem.Allocator, address: usize) []const u8 {
        return std.fmt.allocPrint(arena, "0x{x}", .{address}) catch unreachable;
    }

    test "as many offsets as it takes, and text of any length" {
        var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        // Points at itself, so every offset of 0 lands back on it
        var loop: usize = undefined;
        loop = @intFromPtr(&loop);
        const offsets: [20][]const u8 = @splat("0");
        const name: [500]u8 = @splat('n');
        var l = list();
        defer l.deinit();
        try l.load(&.{.{ .name = &name, .address = hex(a, @intFromPtr(&loop)), .offsets = &offsets }});
        try testing.expectEqual(20, l.nodes.items[0].offsets.items.len);
        try testing.expectEqual(@intFromPtr(&loop), try l.resolve(0));
        const saved = try l.items(a);
        try testing.expectEqual(20, saved[0].offsets.len);
        try testing.expectEqualStrings(&name, saved[0].name);
    }

    test "relative addresses" {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var data: [0x40]u8 align(8) = @splat(0);
        var other: [0x10]u8 align(8) = @splat(0);
        var pointer: usize = @intFromPtr(&data) - 8;
        std.mem.writeInt(usize, data[0x20..][0..@sizeOf(usize)], @intFromPtr(&other), .little);
        var l = list();
        defer l.deinit();
        try l.load(&.{
            .{ .name = "G", .group = true, .address = hex(a, @intFromPtr(&pointer)), .offsets = &.{"8"} },
            .{ .name = "hp", .depth = 1, .address = "+0x10" },
            .{ .name = "folder", .depth = 1, .group = true },
            .{ .name = "inner", .depth = 2, .group = true, .address = "+0x20", .offsets = &.{"0"} },
            .{ .name = "x", .depth = 3, .address = "+4" },
            .{ .name = "back", .depth = 3, .address = "-4" },
            .{ .name = "lost", .address = "+4" },
            .{ .name = "negative", .address = "-4" },
        });
        try testing.expectEqual(@intFromPtr(&data), l.targetOf(0).?.address);
        try testing.expectEqual(@intFromPtr(&data) + 0x10, l.targetOf(1).?.address);
        try testing.expectEqual(null, l.targetOf(2));
        try testing.expectEqual(@intFromPtr(&other), l.targetOf(3).?.address);
        try testing.expectEqual(@intFromPtr(&other) + 4, l.targetOf(4).?.address);
        try testing.expectEqual(@intFromPtr(&other) - 4, l.targetOf(5).?.address);
        try testing.expectEqual(null, l.targetOf(6));
        var problem: Location.Problem = .{};
        try testing.expectError(error.InvalidAddress, l.resolveWhy(6, &problem));
        try testing.expectEqualStrings("+4 is relative, so it has to be in a group with an address", problem.message());
        try testing.expectEqual(0 -% @as(usize, 4), try l.resolve(7));

        // Saved items and their location text get to the same places
        const saved = try l.items(a);
        try testing.expectEqual(@intFromPtr(&other) + 4, try resolveItem(.local, .local, saved, 4));
        for ([_]usize{ 0, 1, 3, 4, 5 }) |i| {
            const text = try locationOf(saved, i, a);
            try testing.expectEqual(l.targetOf(i).?.address, try Location.eval(text, .{ .symbols = .local, .memory = .local }, null));
        }
        try testing.expectError(error.NotInGroup, locationOf(saved, 6, a));
        try testing.expectError(error.NoAddress, locationOf(saved, 2, a));
    }

    test "location text" {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const all: []const Item = &.{
            .{ .name = "G", .group = true, .address = "game+0x10", .offsets = &.{"8"} },
            .{ .name = "hp", .depth = 1, .address = "+0x10" },
            .{ .name = "inner", .depth = 1, .group = true, .address = "+0x20", .offsets = &.{ "0", "-0x4" } },
            .{ .name = "x", .depth = 2, .address = "+4", .offsets = &.{"16"} },
            .{ .name = "plain", .address = " 0x1000 " },
            .{ .name = "negative", .address = "-4" },
        };
        try testing.expectEqualStrings("[game+0x10]+0x8", try locationOf(all, 0, a));
        try testing.expectEqualStrings("([game+0x10]+0x8)+0x10", try locationOf(all, 1, a));
        try testing.expectEqualStrings("[([[([game+0x10]+0x8)+0x20]+0x0]-0x4)+4]+0x10", try locationOf(all, 3, a));
        try testing.expectEqualStrings("0x1000", try locationOf(all, 4, a));
        try testing.expectEqualStrings("-4", try locationOf(all, 5, a));
        try testing.expectEqualStrings("Item[+0x4]", try typeOfItem(a, .{ .type = "Item", .count = "+0x4" }));
        try testing.expectEqualStrings("two_bytes", try typeOfItem(a, .{ .kind = .two_bytes }));
        try testing.expectEqual(20, sizeOfItem(.{ .kind = .two_bytes, .count = "10" }, &.{}));
    }

    fn rowsOf(l: *const AddressList, node: usize) usize {
        var n: usize = 0;
        for (l.row_nodes.items) |owner| n += @intFromBool(owner == node);
        return n;
    }

    fn rowIn(l: *const AddressList, node: usize, name: []const u8, depth: u8) usize {
        for (l.rows.items, l.row_nodes.items, 0..) |r, owner, k| {
            if (owner == node and r.depth == depth and std.mem.eql(u8, r.name, name)) return k;
        }
        unreachable;
    }

    fn elementIn(l: *const AddressList, node: usize, index: usize, depth: u8) usize {
        for (l.rows.items, l.row_nodes.items, 0..) |r, owner, k| {
            if (owner == node and r.depth == depth and r.kind == .element and r.index == index) return k;
        }
        unreachable;
    }

    test "arrays" {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var values: [5]u32 = .{ 1, 2, 3, 4, 5 };
        var header: [2]u32 = .{ 0, 3 };
        var l = list();
        defer l.deinit();
        const at = hex(a, @intFromPtr(&values));
        try l.load(&.{
            .{ .name = "G", .group = true, .address = hex(a, @intFromPtr(&header)) },
            .{ .name = "fixed", .depth = 1, .address = at, .count = "0x4" },
            .{ .name = "read", .depth = 1, .address = at, .count = "+4" },
            .{ .name = "big", .depth = 1, .address = at, .kind = .byte, .count = "2000" },
            .{ .name = "huge", .depth = 1, .address = at, .count = "2000000" },
            .{ .name = "unreadable", .depth = 1, .address = at, .count = "(8)" },
        });
        try testing.expectEqual(4, try l.countOf(1));
        try testing.expectEqual(3, try l.countOf(2));
        header[1] = 5;
        try testing.expectEqual(5, try l.countOf(2));
        try testing.expectError(error.CountTooBig, l.countOf(4));
        try testing.expectError(error.Unreadable, l.countOf(5));
        try testing.expectEqual(4 * 4, l.targetOf(1).?.len);

        l.build();
        try testing.expectEqual(4, rowsOf(&l, 1));
        try testing.expectEqual(5, rowsOf(&l, 2));
        try testing.expectEqual(max_shown + 1, rowsOf(&l, 3));
        try testing.expectEqual(0, rowsOf(&l, 4));
        const more = l.rows.items[l.rows.items.len - 1];
        try testing.expect(more.kind == .more and more.index == 2000 - max_shown);
        var buf: [max_text]u8 = undefined;
        const third = elementIn(&l, 1, 2, 2);
        try testing.expectEqualStrings("3", l.rowValue(third, &buf));
        try testing.expectEqual(@intFromPtr(&values[2]), l.rows.items[third].address.?);
        l.setRowValue(elementIn(&l, 1, 1, 2), "20");
        try testing.expectEqual(20, values[1]);
        var type_buf: [64]u8 = undefined;
        try testing.expectEqualStrings("4 Bytes[0x4]", typeLabel(&l.nodes.items[1], &type_buf));

        // Arrays and their elements aren't held
        l.setHeld(1, true);
        try testing.expect(!l.nodes.items[1].hold);
        l.nodes.items[1].expanded = false;
        l.build();
        try testing.expectEqual(0, rowsOf(&l, 1));
    }

    const hold_layout =
        \\struct Item {
        \\    u32 id;
        \\    [0x8] f32 weight;
        \\}
        \\bitfield Flags : u8 {
        \\    bool on;
        \\    [Bit(4)] bool hot;
        \\}
        \\struct Bag {
        \\    u32 count;
        \\    [0x4] Flags flags;
        \\    [0x8] Item[2] items;
        \\    [0x20] Item* best;
        \\}
        \\[Size(0x200)]
        \\struct Big {
        \\    u32 x;
        \\}
        \\
    ;

    fn heldPath(l: *const AddressList, k: usize) []const u8 {
        return l.holds.items[k].path.get();
    }

    test "holding fields and elements" {
        var parsed = try salamander.parse(testing.allocator, hold_layout, .{}, null);
        defer parsed.deinit();
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var bag: [0x40]u8 align(8) = @splat(0);
        var first: [0x10]u8 align(8) = @splat(0);
        var second: [0x10]u8 align(8) = @splat(0);
        std.mem.writeInt(u32, bag[0..4], 3, .little);
        std.mem.writeInt(u32, bag[0x1C..0x20], @bitCast(@as(f32, 2.5)), .little);
        std.mem.writeInt(usize, bag[0x20..][0..@sizeOf(usize)], @intFromPtr(&first), .little);
        std.mem.writeInt(u32, first[0..4], 5, .little);
        std.mem.writeInt(u32, second[0..4], 7, .little);
        bag[4] = 0x10;

        var l = list();
        defer l.deinit();
        try l.load(&.{
            .{ .name = "bag", .address = hex(a, @intFromPtr(&bag)), .type = "Bag" },
            .{ .name = "items", .address = hex(a, @intFromPtr(&bag) + 8), .type = "Item", .count = "2" },
        });
        l.setSchemas(&.{&parsed.schema}, &.{});
        l.build();
        l.setRowHeld(rowIn(&l, 0, "count", 1), true);
        l.open.set(testing.allocator, l.rows.items[elementIn(&l, 1, 1, 1)], true);
        l.open.set(testing.allocator, l.rows.items[rowIn(&l, 0, "best", 1)], true);
        l.open.set(testing.allocator, l.rows.items[rowIn(&l, 0, "flags", 1)], true);
        l.build();
        l.setRowHeld(rowIn(&l, 1, "weight", 2), true);
        l.setRowHeld(rowIn(&l, 0, "id", 2), true);
        l.setRowHeld(rowIn(&l, 0, "hot", 2), true);
        try testing.expectEqual(null, l.problem);
        try testing.expectEqual(4, l.holds.items.len);
        try testing.expectEqualStrings("count", heldPath(&l, 0));
        try testing.expectEqual(1, l.holds.items[1].index.?);
        try testing.expectEqualStrings("weight", heldPath(&l, 1));
        try testing.expectEqualStrings("best.*.id", heldPath(&l, 2));
        try testing.expectEqualStrings("flags.hot", heldPath(&l, 3));
        try testing.expectEqual(.yes, l.rowHeld(rowIn(&l, 1, "weight", 2)));

        // Closed and not drawn, still put back
        l.nodes.items[0].expanded = false;
        l.nodes.items[1].expanded = false;
        l.build();
        try testing.expectEqual(0, l.rows.items.len);
        std.mem.writeInt(u32, bag[0..4], 9, .little);
        std.mem.writeInt(u32, bag[0x1C..0x20], @bitCast(@as(f32, 1)), .little);
        bag[4] = 0x01;
        l.enforce();
        try testing.expectEqual(3, std.mem.readInt(u32, bag[0..4], .little));
        try testing.expectEqual(@as(f32, 2.5), @as(f32, @bitCast(std.mem.readInt(u32, bag[0x1C..0x20], .little))));
        // Only its own bit is kept, the other one's left as the game set it
        try testing.expectEqual(0x11, bag[4]);

        // It follows the pointer to whatever it points at now
        std.mem.writeInt(usize, bag[0x20..][0..@sizeOf(usize)], @intFromPtr(&second), .little);
        l.enforce();
        try testing.expectEqual(5, std.mem.readInt(u32, second[0..4], .little));
        std.mem.writeInt(usize, bag[0x20..][0..@sizeOf(usize)], 0, .little);
        l.enforce();
        try testing.expectEqual(4, l.holds.items.len);

        // A changed value is what's held from then on
        l.nodes.items[1].expanded = true;
        l.build();
        l.setRowValue(rowIn(&l, 1, "weight", 2), "4.5");
        std.mem.writeInt(u32, bag[0x1C..0x20], 0, .little);
        l.enforce();
        try testing.expectEqual(@as(f32, 4.5), @as(f32, @bitCast(std.mem.readInt(u32, bag[0x1C..0x20], .little))));

        // An element held whole holds its fields too
        l.setRowHeld(elementIn(&l, 1, 0, 1), true);
        l.open.set(testing.allocator, l.rows.items[elementIn(&l, 1, 0, 1)], true);
        l.build();
        try testing.expectEqual(.covered, l.rowHeld(rowIn(&l, 1, "id", 2)));
        l.setRowHeld(elementIn(&l, 1, 0, 1), false);
        try testing.expectEqual(.no, l.rowHeld(rowIn(&l, 1, "id", 2)));

        // Deleting an entry lets go of what was held in it
        l.remove(0);
        try testing.expectEqual(1, l.holds.items.len);
        try testing.expectEqualStrings("weight", heldPath(&l, 0));
        l.setHeld(0, false);
        try testing.expectEqual(0, l.holds.items.len);
    }

    test "holding a typed entry whole" {
        var parsed = try salamander.parse(testing.allocator, hold_layout, .{}, null);
        defer parsed.deinit();
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var item: [0x10]u8 align(8) = @splat(0);
        std.mem.writeInt(u32, item[0..4], 5, .little);
        var big: [0x200]u8 align(8) = @splat(0);
        var l = list();
        defer l.deinit();
        try l.load(&.{
            .{ .name = "G", .group = true },
            .{ .name = "item", .depth = 1, .address = hex(a, @intFromPtr(&item)), .type = "Item" },
            .{ .name = "big", .depth = 1, .address = hex(a, @intFromPtr(&big)), .type = "Big" },
        });
        l.setSchemas(&.{&parsed.schema}, &.{});
        l.setHeld(1, true);
        try testing.expect(l.isHeld(1));
        try testing.expectEqual(0xC, l.holds.items[0].len);
        std.mem.writeInt(u32, item[0..4], 1, .little);
        std.mem.writeInt(u32, item[8..12], 1, .little);
        l.enforce();
        try testing.expectEqual(5, std.mem.readInt(u32, item[0..4], .little));
        try testing.expectEqual(0, std.mem.readInt(u32, item[8..12], .little));
        l.build();
        try testing.expectEqual(.covered, l.rowHeld(rowIn(&l, 1, "id", 2)));

        // Too big to hold whole, so it says so, and its group leaves it out
        l.setHeld(2, true);
        try testing.expectEqualStrings("Can't hold big: it's 512 bytes, too big to hold whole. Hold its fields instead", l.problem.?.message());
        try testing.expect(l.isHeld(0));
        l.setHeld(0, false);
        try testing.expectEqual(0, l.holds.items.len);
        l.problem = null;
        l.setHeld(0, true);
        try testing.expectEqual(null, l.problem);
        try testing.expectEqual(1, l.holds.items.len);

        // Retyping it lets go
        try l.nodes.items[1].type.set(testing.allocator, "Bag");
        l.changedWhere(&l.nodes.items[1]);
        try testing.expectEqual(0, l.holds.items.len);
    }

    test "typed counts" {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var header: [16]u8 align(8) = @splat(0);
        header[0] = 3;
        std.mem.writeInt(u16, header[2..4], 4, .little);
        std.mem.writeInt(u64, header[8..16], 5, .little);
        var values: [8]u32 = @splat(0);
        const at = hex(a, @intFromPtr(&values));
        var l = list();
        defer l.deinit();
        try l.load(&.{
            .{ .name = "G", .group = true, .address = hex(a, @intFromPtr(&header)) },
            .{ .name = "a", .depth = 1, .address = at, .count = "+0 as u8" },
            .{ .name = "b", .depth = 1, .address = at, .count = "+2 as u16" },
            .{ .name = "c", .depth = 1, .address = at, .count = " +8 as u64 " },
            .{ .name = "d", .depth = 1, .address = at, .count = "+8" },
            .{ .name = "e", .depth = 1, .address = at, .count = "+8 as i64" },
            .{ .name = "f", .depth = 1, .address = at, .count = "10 as u16" },
            .{ .name = "g", .depth = 1, .address = at, .count = "+0 as u12" },
        });
        try testing.expectEqual(3, try l.countOf(1));
        try testing.expectEqual(4, try l.countOf(2));
        try testing.expectEqual(5, try l.countOf(3));
        try testing.expectEqual(5, try l.countOf(4));
        std.mem.writeInt(i64, header[8..16], -2, .little);
        try testing.expectError(error.NegativeCount, l.countOf(5));
        try testing.expectError(error.CountTooBig, l.countOf(3));
        try testing.expectError(error.TypedFixedCount, l.countOf(6));
        try testing.expectError(error.UnknownCountType, l.countOf(7));

        var buf: [160]u8 = undefined;
        try testing.expectEqualStrings("Count is negative", countProblem(&l.nodes.items[5], error.NegativeCount, &buf));
        try testing.expectEqualStrings("10 as u16: a fixed count doesn't need a type", countProblem(&l.nodes.items[6], error.TypedFixedCount, &buf));
        try testing.expectEqualStrings("u12 isn't a count type. It's u8, u16, u32, u64, i8, i16, i32 or i64", countProblem(&l.nodes.items[7], error.UnknownCountType, &buf));
        var type_buf: [64]u8 = undefined;
        try testing.expectEqualStrings("4 Bytes[+2 as u16]", typeLabel(&l.nodes.items[2], &type_buf));
        try testing.expectEqualStrings("Item[+0x54 as u16]", try typeOfItem(arena.allocator(), .{ .type = "Item", .count = "+0x54 as u16" }));
        try testing.expectEqual(4, sizeOfItem(.{ .count = "+0x54 as u16" }, &.{}));
        try testing.expectEqual(4, sizeOfItem(.{ .count = "10 as u16" }, &.{}));

        // Names find them the same way, the count doesn't change where they are
        const saved = try l.items(a);
        try testing.expectEqualStrings(try locationOf(saved, 2, a), try locationOf(saved, 4, a));
    }

    test "types from more than one layout" {
        var project = try salamander.parse(testing.allocator, "struct Item { u32 id; }\n", .{}, null);
        defer project.deinit();
        var plugin = try salamander.parse(testing.allocator, "struct Item { u64 id; u64 more; }\nstruct Thing { u32 x; }\n", .{}, null);
        defer plugin.deinit();
        var l = list();
        defer l.deinit();
        l.setSchemas(&.{ &project.schema, &plugin.schema }, &.{ "", "kai" });
        try testing.expectEqual(2, l.type_names.items.len);
        try testing.expectEqualStrings("Item", l.type_labels.items[0]);
        try testing.expectEqualStrings("Thing (kai)", l.type_labels.items[1]);
        try testing.expectEqualStrings("Thing", l.type_names.items[1]);
        // The project's wins
        try testing.expectEqual(4, sizeOfItem(.{ .type = "Item" }, l.schemas));
        try testing.expectEqual(4, sizeOfItem(.{ .type = "Thing" }, l.schemas));
    }

    const bag_layout =
        \\struct Item {
        \\    u32 id;
        \\    [0x8] f32 weight;
        \\}
        \\struct Bag {
        \\    u32 count;
        \\    [0x8] Item[2] items;
        \\    [0x20] Item* best;
        \\}
        \\
    ;

    test "layout entries" {
        var parsed = try salamander.parse(testing.allocator, bag_layout, .{}, null);
        defer parsed.deinit();
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var bag: [0x40]u8 align(8) = @splat(0);
        std.mem.writeInt(u32, bag[0..4], 2, .little);
        std.mem.writeInt(u32, bag[0x8..0xC], 11, .little);
        std.mem.writeInt(u32, bag[0x1C..0x20], @bitCast(@as(f32, 2.5)), .little);
        std.mem.writeInt(usize, bag[0x20..][0..@sizeOf(usize)], @intFromPtr(&bag) + 0x14, .little);

        var l = list();
        defer l.deinit();
        try l.load(&.{
            .{ .name = "G", .group = true, .address = hex(a, @intFromPtr(&bag)) },
            .{ .name = "bag", .depth = 1, .address = "+0", .type = "Bag", .id = "bag" },
            .{ .name = "items", .depth = 1, .address = "+8", .type = "Item", .count = "+0" },
            .{ .name = "nope", .depth = 1, .address = "+0", .type = "Missing" },
        });
        l.build();
        try testing.expectEqual(0, rowsOf(&l, 1));
        l.setSchemas(&.{&parsed.schema}, &.{});
        try testing.expectEqual(2, l.type_names.items.len);
        l.build();
        try testing.expectEqual(3, rowsOf(&l, 1));
        try testing.expectEqual(2, rowsOf(&l, 2));
        try testing.expectEqual(0, rowsOf(&l, 3));
        try testing.expect(!l.opens(3));
        try testing.expect(l.opens(1));
        var buf: [max_text]u8 = undefined;
        try testing.expectEqualStrings("2", l.rowValue(rowIn(&l, 1, "count", 2), &buf));
        try testing.expectEqual(2 * 0xC, l.targetOf(2).?.len);

        l.open.set(testing.allocator, l.rows.items[rowIn(&l, 1, "items", 2)], true);
        l.build();
        l.open.set(testing.allocator, l.rows.items[elementIn(&l, 1, 1, 3)], true);
        l.build();
        const weight = rowIn(&l, 1, "weight", 4);
        try testing.expectEqualStrings("2.5", l.rowValue(weight, &buf));
        var path: [128]u8 = undefined;
        try testing.expectEqualStrings("bag.items[1].weight", l.rowPath(weight, &path));

        l.setRowValue(rowIn(&l, 1, "count", 2), "5");
        try testing.expectEqual(5, std.mem.readInt(u32, bag[0..4], .little));
        try testing.expectEqual(null, l.problem);

        try l.addRow(weight);
        const added = &l.nodes.items[2];
        try testing.expectEqualStrings("bag.items[1].weight", added.name.get());
        try testing.expectEqualStrings("+0x1c", added.address.get());
        try testing.expectEqual(.float, added.kind);
        try testing.expect(!added.typed());
        try testing.expectEqual(1, added.depth);
        try testing.expectEqual(@intFromPtr(&bag) + 0x1C, l.targetOf(2).?.address);

        // Through a pointer it's not a fixed offset, so it's where it is now
        l.build();
        l.open.set(testing.allocator, l.rows.items[rowIn(&l, 1, "best", 2)], true);
        l.build();
        try l.addRow(rowIn(&l, 1, "id", 3));
        try testing.expect(l.nodes.items[2].address.get()[0] != '+');
        try testing.expectEqual(@intFromPtr(&bag) + 0x14, l.targetOf(2).?.address);

        // A struct element stays a typed entry
        l.build();
        try l.addRow(elementIn(&l, 4, 0, 2));
        const element = &l.nodes.items[5];
        try testing.expectEqualStrings("Item", element.type.get());
        try testing.expectEqualStrings("+0x8", element.address.get());
    }

    fn shown(l: *AddressList, i: usize, buf: []u8) []const u8 {
        return l.nodeValue(i, l.resolve(i) catch unreachable, buf) orelse "??";
    }

    test "bit entries" {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        var value: u32 = 0b1000_0101;
        var l = list();
        defer l.deinit();
        try l.load(&.{.{ .name = "state", .address = hex(arena.allocator(), @intFromPtr(&value)), .bits = .{ .shift = 2, .width = 2 } }});
        var buf: [max_text]u8 = undefined;
        try testing.expectEqualStrings("1", shown(&l, 0, &buf));
        var type_buf: [64]u8 = undefined;
        try testing.expectEqualStrings("4 Bytes, bits 2..3", typeLabel(&l.nodes.items[0], &type_buf));

        l.setValue(0, "3");
        try testing.expectEqual(null, l.problem);
        try testing.expectEqual(0b1000_1101, value);
        l.setValue(0, "4");
        try testing.expect(l.problem != null);
        try testing.expectEqual(0b1000_1101, value);
        l.problem = null;

        // Only its own bits are put back
        l.setHeld(0, true);
        value = 0b0000_0010;
        l.enforce();
        try testing.expectEqual(0b0000_1110, value);
    }

    test "choices, labels only and links" {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var values: [3]u32 = .{ 1, 1, 5 };
        var flags: u8 = 0b10;
        var l = list();
        defer l.deinit();
        const off_on: []const Choice = &.{ .{ .value = 0, .label = "Off" }, .{ .value = 1, .label = "On" } };
        try l.load(&.{
            .{ .name = "a", .id = "mode", .address = hex(a, @intFromPtr(&values[0])), .choices = off_on },
            .{ .name = "b", .address = hex(a, @intFromPtr(&values[1])), .choices_from = "mode", .labels_only = true },
            .{ .name = "c", .address = hex(a, @intFromPtr(&values[2])), .choices_from = "mode", .labels_only = true },
            .{ .name = "bit", .address = hex(a, @intFromPtr(&flags)), .kind = .byte, .bits = .{ .shift = 1, .width = 1 }, .choices = off_on, .labels_only = true },
        });
        var buf: [max_text]u8 = undefined;
        try testing.expectEqualStrings("1: On", shown(&l, 0, &buf));
        try testing.expectEqualStrings("On", shown(&l, 1, &buf));
        // Not in the list, so it's the number
        try testing.expectEqualStrings("5", shown(&l, 2, &buf));
        try testing.expectEqualStrings("On", shown(&l, 3, &buf));

        l.setValue(1, "off");
        try testing.expectEqual(0, values[1]);
        l.setValue(3, "Off");
        try testing.expectEqual(0, flags);
        l.setValue(0, "7");
        try testing.expectEqual(7, values[0]);
        const parsed = parseChoice(" 2 :  Two words ").?;
        try testing.expectEqual(2, parsed.value);
        try testing.expectEqualStrings("Two words", parsed.label);
        try testing.expectEqual(null, parseChoice("no colon"));
        try testing.expect(choiceMatches(.{ .value = 12, .label = "Tear Balm" }, "balm"));
        try testing.expect(choiceMatches(.{ .value = 12, .label = "Tear Balm" }, "1"));
        try testing.expect(!choiceMatches(.{ .value = 12, .label = "Tear Balm" }, "2"));
    }

    test "freeze modes" {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var values: [3]i32 = .{ 10, 10, 10 };
        var l = list();
        defer l.deinit();
        try l.load(&.{
            .{ .name = "always", .address = hex(a, @intFromPtr(&values[0])) },
            .{ .name = "up", .address = hex(a, @intFromPtr(&values[1])), .freeze = .only_increase },
            .{ .name = "down", .address = hex(a, @intFromPtr(&values[2])), .freeze = .only_decrease },
        });
        for (0..3) |i| l.setHeld(i, true);
        values = .{ 5, 5, 5 };
        l.enforce();
        try testing.expectEqual([3]i32{ 10, 10, 5 }, values);
        values = .{ 20, 20, 20 };
        l.enforce();
        try testing.expectEqual([3]i32{ 10, 20, 5 }, values);
        // What it was let go to is what's held now
        values = .{ 1, 1, 1 };
        l.enforce();
        try testing.expectEqual([3]i32{ 10, 20, 1 }, values);
    }

    test "hotkeys" {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var money: u32 = 5;
        var speed: f32 = 1;
        var mode: u8 = 0;
        var l = list();
        defer l.deinit();
        try l.load(&.{
            .{ .name = "Mira", .id = "mira", .address = hex(a, @intFromPtr(&money)), .hotkeys = &.{
                .{ .chord = .{ .key = .f1 }, .action = .set, .value = "999999" },
                .{ .chord = .{ .key = .f2 }, .action = .increase, .value = "10" },
                .{ .chord = .{ .key = .f3 }, .action = .decrease, .value = "4" },
                .{ .action = .toggle_hold },
            } },
            .{ .name = "G", .group = true, .hotkeys = &.{.{ .chord = .{ .key = .f4, .mods = .{ .ctrl = true } } }} },
            .{ .name = "speed", .depth = 1, .address = hex(a, @intFromPtr(&speed)), .kind = .float, .hotkeys = &.{.{ .chord = .{ .key = .f5 }, .action = .increase, .value = "0.5" }} },
            .{ .name = "mode", .depth = 1, .address = hex(a, @intFromPtr(&mode)), .kind = .byte, .choices = &.{.{ .value = 2, .label = "Fast" }}, .hotkeys = &.{.{ .chord = .{ .key = .f6 }, .action = .set, .value = "fast" }} },
        });
        const bound = try l.boundHotkeys(a);
        try testing.expectEqual(6, bound.len);
        try testing.expectEqualStrings("Mira: set 999999", bound[0].label);
        try testing.expectEqualStrings("mira", bound[0].owner);
        try testing.expectEqualStrings("G: hold or let go", bound[3].label);
        try testing.expectEqualStrings("speed", bound[4].owner);

        const mira = l.nodes.items[0].key;
        l.pressHotkey(mira, 0);
        try testing.expectEqual(999999, money);
        l.pressHotkey(mira, 1);
        l.pressHotkey(mira, 2);
        try testing.expectEqual(1000005, money);
        l.pressHotkey(bound[4].node, 0);
        try testing.expectEqual(1.5, speed);
        l.pressHotkey(bound[5].node, 0);
        try testing.expectEqual(2, mode);
        try testing.expectEqual(null, l.problem);

        // Holding a group holds what's in it
        l.pressHotkey(bound[3].node, 0);
        try testing.expect(l.isHeld(1));
        speed = 9;
        l.enforce();
        try testing.expectEqual(1.5, speed);
        l.act(1, .release, "");
        try testing.expect(!l.isHeld(1));

        l.pressHotkey(mira, 3);
        try testing.expect(l.isHeld(0));
        l.act(0, .hold, "");
        try testing.expect(l.isHeld(0));
        l.pressHotkey(mira, 3);
        try testing.expect(!l.isHeld(0));
        l.pressHotkey(mira, 9);
        l.pressHotkey(12345, 0);

        l.removeHotkey(0, 0);
        try testing.expectEqual(3, l.nodes.items[0].hotkeys.items.len);
        try testing.expectEqual(.increase, l.nodes.items[0].hotkeys.items[0].action);
    }

    test "save and load bits, choices and hotkeys" {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var l = list();
        defer l.deinit();
        try l.load(&.{
            .{ .name = "state", .id = "state", .address = "0x10", .bits = .{ .shift = 6, .width = 2 }, .choices = &.{ .{ .value = 0, .label = "Off" }, .{ .value = -1, .label = "All" } }, .labels_only = true, .freeze = .only_decrease, .hotkeys = &.{.{ .chord = .{ .key = .f8, .mods = .{ .shift = true } }, .action = .set, .value = "1" }} },
            .{ .name = "linked", .address = "0x20", .choices_from = "state" },
        });
        var out: std.Io.Writer.Allocating = .init(a);
        try std.zon.stringify.serialize(Saved{ .items = try l.items(a) }, .{}, &out.writer);
        var diagnostics: std.zon.parse.Diagnostics = undefined;
        const saved = try std.zon.parse.fromSlice(Saved, .{ .gpa = a, .arena = a, .source = try a.dupeSentinel(u8, out.written(), 0), .diagnostics = &diagnostics, .ignore_unknown_fields = true });
        var back = list();
        defer back.deinit();
        try back.load(saved.items);
        const got = try back.items(a);
        try testing.expectEqual(Bits{ .shift = 6, .width = 2 }, got[0].bits.?);
        try testing.expectEqual(2, got[0].choices.len);
        try testing.expectEqual(-1, got[0].choices[1].value);
        try testing.expectEqualStrings("All", got[0].choices[1].label);
        try testing.expect(got[0].labels_only);
        try testing.expectEqual(.only_decrease, got[0].freeze);
        try testing.expectEqual(.set, got[0].hotkeys[0].action);
        try testing.expectEqualStrings("1", got[0].hotkeys[0].value);
        try testing.expect(got[0].hotkeys[0].chord.?.eql(.{ .key = .f8, .mods = .{ .shift = true } }));
        try testing.expectEqualStrings("state", got[1].choices_from);
        try testing.expectEqual(null, got[1].bits);

        // Files from before have none of it
        const old = try std.zon.parse.fromSlice(Saved, .{ .gpa = a, .arena = a, .source = ".{ .items = .{ .{ .name = \"a\", .address = \"0x1\", .kind = .byte, .depth = 0, .group = false, .expanded = true } } }", .diagnostics = &diagnostics, .ignore_unknown_fields = true });
        try back.load(old.items);
        const plain = (try back.items(a))[0];
        try testing.expectEqual(null, plain.bits);
        try testing.expectEqual(0, plain.choices.len);
        try testing.expectEqual(.always, plain.freeze);
        try testing.expectEqual(0, plain.hotkeys.len);
    }

    test "module names" {
        var l = list();
        defer l.deinit();
        const kernel32 = Symbols.local.resolve("kernel32.dll").?;
        try l.addAddress(kernel32 + 0x10, .byte, 0);
        const described = l.nodes.items[0].address.get();
        try testing.expect(std.ascii.eqlIgnoreCase("kernel32.dll+0x10", described));
        try testing.expectEqual(kernel32 + 0x10, try l.resolve(0));
    }
};

test {
    _ = tests;
}
