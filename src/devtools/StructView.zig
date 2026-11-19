//! ReClass style struct view, mapped to live memory and editable.

const StructView = @This();

const std = @import("std");

const ui = @import("tuft_ui");
const mem = @import("tuft_mem");
const salamander = @import("salamander_schema");
const sigs = @import("tuft_schema").sigs;

const root = @import("root.zig");
const AddressBar = @import("AddressBar.zig");
const StructEdit = @import("StructEdit.zig");
const StructRows = @import("StructRows.zig");

const Schema = salamander.Schema;
const Change = salamander.edit.Change;
const Sig = mem.Sig;
const Memory = mem.Memory;
const Symbols = mem.Symbols;
const Claims = mem.Claims;

pub const max_depth = StructRows.max_depth;
const max_gap_rows = StructRows.max_gap_rows;
const max_text = 256;
const red: ui.Color = .{ 1, 0.4, 0.4, 1 };

allocator: std.mem.Allocator,
memory: Memory = .local,
symbols: Symbols = .none,
claims: Claims = .none,
/// Off for text that isn't ours to change, like a plugin's.
editable: bool = true,
schema: ?*const Schema = null,
/// Null leaves statics and functions unfound.
find: ?*const fn (sig: Sig, label: []const u8) anyerror!usize = null,
/// Keyed by signature so it's kept while the text changes around it.
found: std.AutoHashMapUnmanaged(u64, Found) = .empty,
/// Null shows just the layout.
address: ?usize = null,
mapping: Mapping = .auto,
/// As `Type.name`.
follow_buf: [128]u8 = undefined,
follow_len: usize = 0,
unmapped: ?anyerror = null,
bar: AddressBar = .{},
shown: usize = 0,
type_names: std.ArrayList([:0]const u8) = .empty,
picked: ui.Selection = .{},
open: StructRows.Open = .{},
rows: std.ArrayList(Row) = .empty,
edit: StructEdit = .{},
problem: ?root.Problem = null,

pub const Found = union(enum) {
    ok: usize,
    err: anyerror,
};

pub const Mapping = enum {
    /// Like `[Sig(...)] static Player* instance`, once it's found.
    auto,
    address,
    none,
    static,
};

pub const Row = StructRows.Row;

pub fn deinit(self: *StructView) void {
    self.freeNames();
    self.type_names.deinit(self.allocator);
    self.open.deinit(self.allocator);
    self.rows.deinit(self.allocator);
    self.found.deinit(self.allocator);
    self.picked.deinit();
}

/// Call after every parse. Keeps showing the same struct if it's still there.
pub fn setSchema(self: *StructView, schema: ?*const Schema) void {
    const before: ?[]const u8 = if (self.shownName()) |n| self.allocator.dupe(u8, n) catch null else null;
    defer if (before) |b| self.allocator.free(b);
    self.schema = schema;
    self.rows.clearRetainingCapacity();
    self.freeNames();
    self.shown = 0;
    const s = schema orelse return;
    for (s.types) |t| {
        if (t.nested) continue;
        switch (t.kind) {
            .@"struct", .@"union" => {},
            else => continue,
        }
        const name = self.allocator.dupeSentinel(u8, t.name, 0) catch break;
        self.type_names.append(self.allocator, name) catch {
            self.allocator.free(name);
            break;
        };
    }
    if (before) |b| _ = self.show(b);
}

fn freeNames(self: *StructView) void {
    for (self.type_names.items) |n| self.allocator.free(n);
    self.type_names.clearRetainingCapacity();
}

pub fn show(self: *StructView, name: []const u8) bool {
    for (self.type_names.items, 0..) |n, i| if (std.mem.eql(u8, n, name)) {
        self.shown = i;
        return true;
    };
    return false;
}

pub fn shownName(self: *const StructView) ?[]const u8 {
    return if (self.shown < self.type_names.items.len) self.type_names.items[self.shown] else null;
}

pub fn goTo(self: *StructView, address: ?usize) void {
    self.address = address;
    self.mapping = if (address != null) .address else .none;
    if (address) |a| self.bar.visit(a);
}

/// Follows the static as it changes.
pub fn follow(self: *StructView, owner: []const u8, name: []const u8) void {
    self.setFollow(owner, name);
    self.mapping = .static;
}

fn setFollow(self: *StructView, owner: []const u8, name: []const u8) void {
    const text = std.fmt.bufPrint(&self.follow_buf, "{s}.{s}", .{ owner, name }) catch "";
    self.follow_len = text.len;
}

pub fn following(self: *const StructView) ?[]const u8 {
    if (self.mapping != .auto and self.mapping != .static) return null;
    return if (self.follow_len == 0) null else self.follow_buf[0..self.follow_len];
}

/// Slow, so only when asked, like on Ctrl+Enter.
pub fn findSignatures(self: *StructView) void {
    const find = self.find orelse return self.fail("Signatures can't be looked for here", .{});
    const schema = self.schema orelse return;
    self.found.clearRetainingCapacity();
    var tally: Tally = .{};
    for (schema.statics) |s| self.lookFor(find, s.annotations, s.name, &tally);
    for (schema.functions) |f| self.lookFor(find, f.annotations, f.name, &tally);
    for (schema.types) |t| switch (t.kind) {
        .@"struct" => |s| {
            var label: [128]u8 = undefined;
            for (s.statics) |st| self.lookFor(find, st.annotations, std.fmt.bufPrint(&label, "{s}.{s}", .{ t.name, st.name }) catch st.name, &tally);
            for (s.methods) |m| self.lookFor(find, m.annotations, std.fmt.bufPrint(&label, "{s}.{s}", .{ t.name, m.name }) catch m.name, &tally);
        },
        else => {},
    };
    self.problem = if (tally.missing == 0) null else .init("{d} of {d} signatures weren't found, like {s}", .{ tally.missing, tally.total, tally.first[0..tally.first_len] });
}

const Tally = struct {
    total: usize = 0,
    missing: usize = 0,
    first: [128]u8 = undefined,
    first_len: usize = 0,
};

fn lookFor(self: *StructView, find: anytype, annotations: []const Schema.Annotation, label: []const u8, tally: *Tally) void {
    var steps: [sigs.max_steps]Sig.Step = undefined;
    const sig = (sigs.of(annotations, null, "Sig", &steps) catch return) orelse return;
    const key = sigKey(sig);
    if (self.found.contains(key)) return;
    tally.total += 1;
    const result: Found = if (find(sig, label)) |a| .{ .ok = a } else |err| .{ .err = err };
    self.found.put(self.allocator, key, result) catch {};
    if (result == .err) {
        if (tally.missing == 0) {
            const written = std.fmt.bufPrint(&tally.first, "{s}: {t}", .{ label, result.err }) catch tally.first[0..0];
            tally.first_len = written.len;
        }
        tally.missing += 1;
    }
}

pub fn scanHere(sig: Sig, label: []const u8) anyerror!usize {
    return sig.locate(label).unwrap();
}

fn sigKey(sig: Sig) u64 {
    var h = std.hash.Wyhash.init(0);
    h.update(sig.pattern);
    h.update(&.{0});
    h.update(sig.module orelse "");
    h.update(&.{0});
    h.update(sig.section);
    for (sig.resolve) |step| {
        h.update(&.{@backingInt(step)});
        if (step == .offset) h.update(std.mem.asBytes(&step.offset));
    }
    return h.final();
}

/// Where the `[Sig]` in `annotations` found. `error.NotLookedFor` until `findSignatures`.
fn located(self: *const StructView, annotations: []const Schema.Annotation) anyerror!usize {
    var steps: [sigs.max_steps]Sig.Step = undefined;
    const sig = try sigs.of(annotations, null, "Sig", &steps) orelse return error.NoSignature;
    return switch (self.found.get(sigKey(sig)) orelse return error.NotLookedFor) {
        .ok => |a| a,
        .err => |err| err,
    };
}

/// Good until the next `draw`.
pub fn takeChanges(self: *StructView) []const Change {
    return self.edit.takeChanges();
}

pub fn fail(self: *StructView, comptime fmt: []const u8, args: anytype) void {
    self.problem = .init(fmt, args);
}

pub fn activated(self: *const StructView) bool {
    return self.picked.activated;
}

fn selectedRow(self: *const StructView) ?Row {
    const id = self.picked.focused() orelse return null;
    for (self.rows.items) |r| if (r.id == id) return r;
    return null;
}

pub const Selected = struct {
    address: usize,
    size: usize,
    kind: mem.values.Kind,
    target: ?usize,
};

pub fn selected(self: *const StructView) ?Selected {
    const row = self.selectedRow() orelse return null;
    const address = row.address orelse return null;
    const schema = self.schema orelse return null;
    var shown = row;
    // A big gap's start, not all of it
    if (row.kind == .gap and row.expandable) shown.size = schema.pointer_size;
    return .{
        .address = address,
        .size = @max(shown.size, 1),
        .kind = kindOf(schema, shown),
        .target = self.pointerOf(row),
    };
}

const idOf = StructRows.idOf;
pub const fieldId = StructRows.fieldId;
const chainOf = StructRows.chainOf;
const namedStruct = StructRows.namedStruct;
const isPointer = StructRows.isPointer;
const kindOf = StructRows.kindOf;

fn setOpen(self: *StructView, row: Row, open: bool) void {
    self.open.set(self.allocator, row, open);
}

fn rowBuilder(self: *StructView, schema: *const Schema) StructRows {
    return .{ .allocator = self.allocator, .memory = self.memory, .schema = schema, .rows = &self.rows, .open = &self.open };
}

fn readPointer(self: *const StructView, address: usize, ps: u8) ?usize {
    return StructRows.readPointer(self.memory, address, ps);
}

fn build(self: *StructView) void {
    self.rows.clearRetainingCapacity();
    const schema = self.schema orelse return;
    const name = self.shownName() orelse return;
    const t = schema.findType(name) orelse return;
    self.map(schema, t);
    self.addSignatures(schema, t);
    var rows = self.rowBuilder(schema);
    rows.addStruct(t, self.address, 0, 0);
}

fn map(self: *StructView, schema: *const Schema, t: *const Schema.Type) void {
    self.unmapped = null;
    const static: *const Schema.Static = switch (self.mapping) {
        .address, .none => return,
        .auto => ownInstance(schema, t) orelse {
            self.follow_len = 0;
            self.address = null;
            return;
        },
        .static => static: {
            const text = self.follow_buf[0..self.follow_len];
            const dot = std.mem.indexOfScalar(u8, text, '.') orelse return self.unmap(error.NoSuchStatic);
            const owner = schema.findType(text[0..dot]) orelse return self.unmap(error.NoSuchStatic);
            break :static (schema.staticOf(owner, text[dot + 1 ..]) orelse return self.unmap(error.NoSuchStatic)).static;
        },
    };
    if (self.mapping == .auto) self.setFollow(t.name, static.name);
    const at = self.located(static.annotations) catch |err| return self.unmap(err);
    if (isPointer(static.type)) {
        const p = self.readPointer(at, schema.pointer_size) orelse return self.unmap(error.Unreadable);
        if (p == 0) return self.unmap(error.NullPointer);
        self.address = p;
        return;
    }
    self.address = at;
}

fn unmap(self: *StructView, err: anyerror) void {
    self.address = null;
    self.unmapped = err;
}

/// `t`'s own static that's one of it or points at one, like `instance`.
fn ownInstance(schema: *const Schema, t: *const Schema.Type) ?*const Schema.Static {
    const s = switch (t.kind) {
        .@"struct" => |s| s,
        else => return null,
    };
    for (s.statics) |*st| {
        const target = StructRows.pointee(schema, st.type) orelse namedStruct(schema, st.type);
        if (target == t) return st;
    }
    return null;
}

fn addSignatures(self: *StructView, schema: *const Schema, t: *const Schema.Type) void {
    var rows = self.rowBuilder(schema);
    var chain_buf: [max_depth]*const Schema.Type = undefined;
    for (chainOf(schema, t, &chain_buf)) |c| {
        const s = switch (c.kind) {
            .@"struct" => |s| s,
            else => continue,
        };
        for (s.statics) |st| {
            const row: Row = .{ .id = idOf(0, 'S', st.name, 0), .parent = 0, .depth = 0, .kind = .static, .offset = 0, .name = st.name, .type = st.type, .owner = c };
            if (self.located(st.annotations)) |at| {
                var found = row;
                found.address = at;
                if (!rows.addValue(found)) return;
            } else |err| {
                var missing = row;
                missing.err = err;
                if (!rows.add(missing)) return;
            }
        }
        for (s.methods) |*f| {
            if (f.virtual != null or sigs.find(f.annotations, null, "Sig") == null) continue;
            var row: Row = .{ .id = idOf(0, 'F', f.name, 0), .parent = 0, .depth = 0, .kind = .function, .offset = 0, .name = f.name, .owner = c, .function = f };
            if (self.located(f.annotations)) |at| row.address = at else |err| row.err = err;
            if (!rows.add(row)) return;
        }
    }
}

fn pointerOf(self: *const StructView, row: Row) ?usize {
    const schema = self.schema orelse return null;
    const ps = schema.pointer_size;
    const address = row.address orelse return null;
    switch (row.kind) {
        .vtable, .slot => return self.readPointer(address, ps),
        .gap => return if (row.size == ps and address % ps == 0) self.readPointer(address, ps) else null,
        .function => return address,
        .field, .element, .static => {
            if (!isPointer(row.type orelse return null)) return null;
            return self.readPointer(address, ps);
        },
        .bits, .more => return null,
    }
}

pub fn draw(self: *StructView) void {
    self.bar.symbols = self.symbols;
    if (self.problem) |*p| ui.textColored(red, "{s}", .{p.message()});
    const schema = self.schema orelse {
        ui.textDisabled("No types", .{});
        return;
    };
    if (self.type_names.items.len == 0) {
        ui.textDisabled("No structs to show. Write one, like struct Player {{ f32 health; }}", .{});
        return;
    }
    self.drawHeader(schema);
    if (self.bar.draw()) |a| self.goTo(a);
    if (self.bar.problem) |err| if (err == error.NoAddress) {
        self.bar.problem = null;
        self.goTo(null);
    };

    self.build();
    if (self.edit.select_next) |id| for (self.rows.items) |r| if (r.id == id) {
        self.picked.only(id);
        self.edit.select_next = null;
        break;
    };
    self.drawTable();
}

fn drawHeader(self: *StructView, schema: *const Schema) void {
    ui.setNextItemWidth(200);
    // Another struct gets its own instance, not the last one's
    if (ui.combo("##type", &self.shown, self.type_names.items) and self.mapping == .static) self.mapping = .auto;
    ui.tooltip("Struct to show", .{});
    ui.sameLine();
    const t = schema.findType(self.shownName() orelse return) orelse return;
    const size = if (t.size == Schema.Type.auto) 0 else t.size;
    if (self.edit.editing) |e| if (e.what == .size) {
        ui.text("Size", .{});
        ui.sameLine();
        self.drawEdit(.{ .id = 0, .parent = 0, .depth = 0, .kind = .more, .offset = 0, .owner = t }, .size);
        return;
    };
    ui.textDisabled("Size 0x{X}", .{size});
    ui.sameLine();
    if (self.following()) |name| {
        if (self.unmapped) |err| switch (err) {
            error.NotLookedFor => ui.textDisabled("Ctrl+Enter finds {s}, to see live values", .{name}),
            error.NullPointer => ui.textDisabled("{s} is null for now", .{name}),
            else => ui.textColored(red, "{s}: {t}", .{ name, err }),
        } else ui.textDisabled("Through {s}", .{name});
    } else if (self.address == null) {
        ui.textDisabled("Not mapped. Type an address to see live values", .{});
    }
}

const Ids = struct {
    view: *const StructView,

    pub fn id(self: Ids, i: usize) u64 {
        return self.view.rows.items[i].id;
    }
};

fn drawTable(self: *StructView) void {
    const mono = ui.monospace();
    defer mono.end();
    {
        const table = ui.table("struct", 5, .{ .row_background = true, .resizable = true, .sizing = .stretch_prop, .scroll_y = true }) orelse return;
        defer table.end();
        ui.tableColumnWith("Offset", .{ .fixed = true, .width = 50 });
        ui.tableColumnWith("Address", .{ .fixed = true, .width = 130 });
        ui.tableColumnWith("Name", .{ .stretch = true, .width = 2 });
        ui.tableColumnWith("Type", .{ .stretch = true, .width = 1.5 });
        ui.tableColumnWith("Value", .{ .stretch = true, .width = 3 });
        ui.tableHeaders();

        var picking = self.picked.begin(self.rows.items.len, Ids{ .view = self }, .{});
        defer picking.end();
        var rows = ui.clip(self.rows.items.len);
        rows.include(picking.keep());
        while (rows.next()) |i| self.drawRow(&picking, i, self.rows.items[i]);
    }
}

fn drawRow(self: *StructView, picking: anytype, i: usize, row: Row) void {
    const scope = ui.id(@as(i32, @bitCast(@as(u32, @truncate(row.id)))));
    defer scope.end();
    ui.tableNextRow();
    const editing = self.edit.of(row.id);

    _ = ui.tableNextColumn();
    _ = picking.row(i, "##row");
    ui.sameLine();
    switch (row.kind) {
        .bits => if (row.width == 1) ui.textDisabled("bit {d}", .{row.index}) else ui.textDisabled("{d}..{d}", .{ row.index, row.index + row.width - 1 }),
        .more => {},
        .static => ui.textDisabled("static", .{}),
        .function => ui.textDisabled("fn", .{}),
        else => ui.textDisabled("{X:0>4}", .{row.offset}),
    }

    _ = ui.tableNextColumn();
    if (row.err) |err| {
        if (err == error.NotLookedFor) ui.textDisabled("Ctrl+Enter", .{}) else ui.textColored(red, "{t}", .{err});
        if (err == error.NotLookedFor) ui.tooltip("Finds every signature", .{});
    } else if (row.address) |a| if (row.kind != .bits) ui.textDisabled("{X}", .{a});

    _ = ui.tableNextColumn();
    const indent = ui.scaled(12) * @as(f32, @floatFromInt(row.depth));
    if (row.depth > 0) ui.indent(indent);
    defer if (row.depth > 0) ui.unindent(indent);
    if (row.expandable) {
        if (ui.smallButton(if (row.expanded) "-" else "+")) self.setOpen(row, !row.expanded);
        ui.sameLine();
    }
    if (editing == .name) {
        self.drawEdit(row, .name);
    } else switch (row.kind) {
        .element => ui.text("[{d}]", .{row.index}),
        .gap => if (row.expandable)
            ui.textDisabled("{X:0>4}..{X:0>4} not laid out", .{ row.offset, row.offset + row.size })
        else
            ui.textDisabled("{d} bytes", .{row.size}),
        .more => ui.textDisabled("{d} more", .{row.index}),
        .slot => ui.text("{s}", .{row.name}),
        else => ui.text("{s}", .{row.name}),
    }

    _ = ui.tableNextColumn();
    if (editing != null and (editing == .type or editing == .define or editing == .new_struct)) {
        self.drawEdit(row, editing.?);
    } else {
        drawType(row);
    }

    _ = ui.tableNextColumn();
    if (editing == .value) {
        self.drawEdit(row, .value);
        return;
    }
    var buf: [max_text]u8 = undefined;
    const value = self.valueText(row, &buf);
    if (row.kind == .gap) ui.textDisabled("{s}", .{value}) else ui.text("{s}", .{value});
    if (self.pointerOf(row)) |p| {
        var name: [128]u8 = undefined;
        if (p != 0) if (self.symbols.describe(p, &name)) |described| {
            ui.sameLine();
            ui.textDisabled("{s}", .{described});
        };
    }
}

fn drawType(row: Row) void {
    switch (row.kind) {
        .vtable => ui.textDisabled("vtable", .{}),
        .slot => ui.textDisabled("slot {d}", .{row.index}),
        .gap => if (row.expandable) ui.textDisabled("0x{X} bytes", .{row.size}),
        .more => {},
        .function => {
            var buf: [max_text]u8 = undefined;
            ui.text("{s}", .{signatureText(row.function.?, &buf)});
        },
        else => if (row.type) |t| ui.text("{f}", .{t}),
    }
}

/// Like `u32 (u32 amount)`.
fn signatureText(f: *const Schema.Method, buf: []u8) []const u8 {
    const sig = f.signature;
    var w: std.Io.Writer = .fixed(buf);
    if (f.static) w.writeAll("static ") catch {};
    w.print("{f} (", .{sig.ret}) catch {};
    for (sig.params, 0..) |p, i| {
        if (i > 0) w.writeAll(", ") catch {};
        w.print("{f}", .{p.type}) catch {};
        if (p.name.len > 0) w.print(" {s}", .{p.name}) catch {};
    }
    w.writeAll(")") catch {};
    return w.buffered();
}

fn valueText(self: *const StructView, row: Row, buf: []u8) []const u8 {
    const schema = self.schema orelse return "";
    return StructRows.valueText(self.memory, schema, row, buf);
}

fn canEditValue(_: *const StructView, row: Row) bool {
    return StructRows.canEditValue(row);
}

fn drawEdit(self: *StructView, row: Row, what: StructEdit.What) void {
    self.edit.draw(self.editTarget() orelse return, row, what);
}

/// What `StructEdit` needs. Null without a struct shown.
fn editTarget(self: *StructView) ?StructEdit.Target {
    return .{
        .schema = self.schema orelse return null,
        .shown = self.shownName() orelse return null,
        .memory = self.memory,
        .symbols = self.symbols,
        .claims = self.claims,
        .problem = &self.problem,
    };
}

/// Begin it right after `draw`, with `.activated = activated()`.
pub fn commands(self: *StructView, menu: *ui.Commands) void {
    const keys = &root.keys;
    const row = self.selectedRow();
    const any = self.picked.count() > 0;
    const value = if (row) |r| self.canEditValue(r) else false;
    const can_change = self.editable and self.schema != null;
    const gap = if (row) |r| r.kind == .gap else false;
    const field = if (row) |r| r.isField() else false;
    const expandable = if (row) |r| r.expandable else false;
    const expanded = if (row) |r| r.expanded else false;

    if (menu.item(.{ .label = "Change value", .chord = keys.edit, .enabled = value and !gap, .default = true, .tooltip = "Type a new one in place" })) self.startEdit(row.?, .value);
    if (menu.item(.{ .label = "Define field", .chord = keys.new_entry, .enabled = can_change and gap, .default = true, .tooltip = "Make this gap a field. Type its type, and a name if you like" })) self.startEdit(row.?, .define);
    if (menu.item(.{ .label = "Change bytes", .enabled = value and gap, .tooltip = "Type hex bytes over them" })) self.startEdit(row.?, .value);
    if (menu.item(.{ .label = "Open", .chord = keys.expand, .enabled = expandable and !expanded, .default = true })) self.setOpen(row.?, true);
    if (menu.item(.{ .label = "Close", .chord = keys.collapse, .enabled = expandable and expanded, .default = true })) self.setOpen(row.?, false);
    menu.separator();
    if (menu.item(.{ .label = "Change type", .enabled = can_change and field, .tooltip = "Fields after it stay where they are" })) self.startEdit(row.?, .type);
    if (menu.item(.{ .label = "Rename", .enabled = can_change and field })) self.startEdit(row.?, .name);
    const pointer = field and row.?.type != null and isPointer(row.?.type.?);
    if (menu.item(.{ .label = "New struct", .enabled = can_change and (gap or pointer), .tooltip = "Makes an empty struct, and a pointer to it here" })) self.startEdit(row.?, .new_struct);
    if (menu.item(.{ .label = "Set size", .enabled = can_change, .tooltip = "Of the struct shown" })) self.startEdit(.{ .id = 0, .parent = 0, .depth = 0, .kind = .more, .offset = 0 }, .size);
    if (menu.item(.{ .label = "Delete field", .chord = keys.delete, .enabled = can_change and field, .tooltip = "Its bytes become a gap. Fields after it stay where they are" })) {
        if (self.editTarget()) |t| self.edit.remove(t, row.?);
    }
    menu.separator();
    if (menu.item(.{ .label = "Find signatures", .chord = keys.run, .enabled = self.find != null and self.schema != null, .tooltip = "Scans for every [Sig], statics and functions. Kept until the next time" })) self.findSignatures();
    const mappable = if (row) |r| r.kind == .static and r.err == null and self.staticTarget(r) != null else false;
    if (menu.item(.{ .label = "Map through this", .enabled = mappable, .tooltip = "Lays out what it points at, following it as it changes" })) {
        const r = row.?;
        const target = self.staticTarget(r).?;
        self.follow(r.owner.?.name, r.name);
        _ = self.show(target.name);
    }
    menu.separator();
    if (menu.item(.{ .label = "Copy", .chord = keys.copy, .enabled = any, .tooltip = "Offset, name, type and value, one row per line" })) self.copy(false);
    if (menu.item(.{ .label = "Copy address", .chord = keys.copy_address, .enabled = any and self.address != null })) self.copy(true);
}

fn staticTarget(self: *const StructView, row: Row) ?*const Schema.Type {
    const schema = self.schema orelse return null;
    const t = row.type orelse return null;
    return StructRows.pointee(schema, t) orelse namedStruct(schema, t);
}

fn startEdit(self: *StructView, row: Row, what: StructEdit.What) void {
    const t = self.editTarget() orelse return;
    var buf: [max_text]u8 = undefined;
    self.edit.start(t, row, what, if (what == .value) self.valueText(row, &buf) else "");
}

/// `offset, name, type, value` split by tabs, or just addresses.
fn copy(self: *StructView, addresses_only: bool) void {
    var out: std.Io.Writer.Allocating = .init(self.allocator);
    defer out.deinit();
    const w = &out.writer;
    var lines: usize = 0;
    for (self.rows.items) |r| {
        if (!self.picked.contains(r.id)) continue;
        if (addresses_only and r.address == null) continue;
        if (lines > 0) w.writeByte('\n') catch return;
        lines += 1;
        if (addresses_only) {
            w.print("0x{x}", .{r.address.?}) catch return;
            continue;
        }
        var buf: [max_text]u8 = undefined;
        const name = switch (r.kind) {
            .element => std.fmt.bufPrint(&buf, "[{d}]", .{r.index}) catch "",
            .gap => "",
            else => r.name,
        };
        w.print("0x{X}\t{s}\t", .{ r.offset, name }) catch return;
        if (r.type) |t| w.print("{f}", .{t}) catch return;
        var value: [max_text]u8 = undefined;
        w.print("\t{s}", .{self.valueText(r, &value)}) catch return;
    }
    if (lines == 0) return;
    w.writeByte(0) catch return;
    const written = out.written();
    ui.setClipboard(written[0 .. written.len - 1 :0]);
}

const tests = struct {
    const testing = std.testing;
    const test_options: salamander.Options = .{ .any_namespace = true };

    const source =
        \\enum State : u8 { Idle = 0, Running = 2 }
        \\struct Base {
        \\    [Virtual(0)] void Update();
        \\    [0x8] u32 id;
        \\}
        \\struct Player : Base {
        \\    [0x10] f32 health;
        \\    State state;
        \\    [0x18] utf8[8] name;
        \\    Player* target;
        \\    f32[3] pos;
        \\}
        \\
    ;

    fn setValue(view: *StructView, row: Row, text: []const u8) void {
        view.edit.commit(view.editTarget().?, row, .value, text);
    }

    fn rowNamed(view: *const StructView, name: []const u8) ?Row {
        for (view.rows.items) |r| if (std.mem.eql(u8, r.name, name)) return r;
        return null;
    }

    test "rows and gaps" {
        var parsed = try salamander.parse(testing.allocator, source, .{ .pointer_size = 8, .any_namespace = true }, null);
        defer parsed.deinit();
        var view: StructView = .{ .allocator = testing.allocator };
        defer view.deinit();
        view.setSchema(&parsed.schema);
        try testing.expect(view.show("Player"));
        view.build();
        var kinds: [16]Row.Kind = undefined;
        var n: usize = 0;
        for (view.rows.items) |r| {
            kinds[n] = r.kind;
            n += 1;
        }
        // vtable, id, gap after id, health, state, gap, name, target, pos, and padding to 8
        try testing.expectEqualSlices(Row.Kind, &.{ .vtable, .field, .gap, .field, .field, .gap, .field, .field, .field, .gap }, kinds[0..n]);
        try testing.expectEqual(0x14, rowNamed(&view, "state").?.offset);
        try testing.expectEqualStrings("Base", rowNamed(&view, "id").?.owner.?.name);

        view.setOpen(rowNamed(&view, "pos").?, true);
        view.setOpen(view.rows.items[0], true);
        view.build();
        try testing.expectEqualStrings("Update", view.rows.items[1].name);
        var elements: usize = 0;
        for (view.rows.items) |r| elements += @intFromBool(r.kind == .element);
        try testing.expectEqual(3, elements);
        try testing.expect(!rowNamed(&view, "target").?.expandable);
    }

    test "mapped values" {
        var parsed = try salamander.parse(testing.allocator, source, test_options, null);
        defer parsed.deinit();
        var view: StructView = .{ .allocator = testing.allocator };
        defer view.deinit();
        view.setSchema(&parsed.schema);
        _ = view.show("Player");

        const vtable = [_]usize{0x1234};
        var other: [0x40]u8 align(8) = @splat(0);
        var player: [0x40]u8 align(8) = @splat(0);
        std.mem.writeInt(usize, player[0..@sizeOf(usize)], @intFromPtr(&vtable), .little);
        std.mem.writeInt(u32, player[0x8..0xC], 7, .little);
        std.mem.writeInt(u32, player[0x10..0x14], @bitCast(@as(f32, 87.5)), .little);
        player[0x14] = 2;
        @memcpy(player[0x18..0x1D], "Kaiju");
        std.mem.writeInt(usize, player[0x20..][0..@sizeOf(usize)], @intFromPtr(&other), .little);
        std.mem.writeInt(u32, other[0x8..0xC], 99, .little);
        view.goTo(@intFromPtr(&player));
        view.build();

        var buf: [max_text]u8 = undefined;
        try testing.expectEqualStrings("87.5", view.valueText(rowNamed(&view, "health").?, &buf));
        try testing.expectEqualStrings(".Running", view.valueText(rowNamed(&view, "state").?, &buf));
        try testing.expectEqualStrings("\"Kaiju\"", view.valueText(rowNamed(&view, "name").?, &buf));

        view.setOpen(rowNamed(&view, "target").?, true);
        view.setOpen(view.rows.items[0], true);
        view.build();
        try testing.expectEqualStrings("0x1234", view.valueText(view.rows.items[1], &buf));
        var ids: usize = 0;
        for (view.rows.items) |r| if (std.mem.eql(u8, r.name, "id")) {
            ids += 1;
            if (r.depth == 1) try testing.expectEqualStrings("99", view.valueText(r, &buf));
        };
        try testing.expectEqual(2, ids);

        setValue(&view, rowNamed(&view, "health").?, "12.25");
        try testing.expectEqual(@as(f32, 12.25), @as(f32, @bitCast(std.mem.readInt(u32, player[0x10..0x14], .little))));
        setValue(&view, rowNamed(&view, "state").?, "Idle");
        try testing.expectEqual(0, player[0x14]);
        setValue(&view, rowNamed(&view, "id").?, "0x10");
        try testing.expectEqual(0x10, std.mem.readInt(u32, player[0x8..0xC], .little));
        try testing.expectEqual(null, view.problem);
        // Decimal unless it starts with 0x or ends in h
        setValue(&view, rowNamed(&view, "id").?, "1Fh");
        try testing.expectEqual(0x1F, std.mem.readInt(u32, player[0x8..0xC], .little));
        setValue(&view, rowNamed(&view, "id").?, "10");
        try testing.expectEqual(10, std.mem.readInt(u32, player[0x8..0xC], .little));
        setValue(&view, rowNamed(&view, "id").?, "1F");
        try testing.expectEqualStrings("'1F' isn't a uint", view.problem.?.message());
        try testing.expectEqual(10, std.mem.readInt(u32, player[0x8..0xC], .little));
        view.problem = null;
        var gap: ?Row = null;
        for (view.rows.items) |r| if (r.kind == .gap and r.depth == 0 and r.offset == 0xC) {
            gap = r;
        };
        setValue(&view, gap.?, "AA BB");
        try testing.expectEqualSlices(u8, &.{ 0xAA, 0xBB }, player[0xC..0xE]);
    }

    test "type changes" {
        var parsed = try salamander.parse(testing.allocator, source, test_options, null);
        defer parsed.deinit();
        var view: StructView = .{ .allocator = testing.allocator };
        defer view.deinit();
        view.setSchema(&parsed.schema);
        _ = view.show("Player");
        view.build();

        var gap: ?Row = null;
        for (view.rows.items) |r| if (r.kind == .gap and r.offset == 0xC) {
            gap = r;
        };
        view.edit.commit(view.editTarget().?, gap.?, .define, "i32 level");
        view.edit.commit(view.editTarget().?, rowNamed(&view, "health").?, .name, "hp");
        const changes = view.takeChanges();
        try testing.expectEqual(2, changes.len);
        // 0xC is past Base's end, so it's Player's
        try testing.expectEqualStrings("Player", changes[0].define.owner);
        try testing.expectEqual(0xC, changes[0].define.offset);
        try testing.expectEqualStrings("i32", changes[0].define.type);
        try testing.expectEqualStrings("level", changes[0].define.name);
        try testing.expectEqualStrings("hp", changes[1].rename.name);

        const text = try salamander.edit.apply(testing.allocator, source, changes, .{ .parse = test_options });
        defer testing.allocator.free(text);
        var again = try salamander.parse(testing.allocator, text, test_options, null);
        defer again.deinit();
        view.setSchema(&again.schema);
        view.build();
        try testing.expectEqual(0xC, rowNamed(&view, "level").?.offset);
        try testing.expectEqual(0x10, rowNamed(&view, "hp").?.offset);

        view.edit.commit(view.editTarget().?, rowNamed(&view, "target").?, .new_struct, "Enemy");
        const made = view.takeChanges();
        try testing.expectEqual(2, made.len);
        try testing.expectEqualStrings("Enemy", made[0].add_struct.name);
        try testing.expectEqualStrings("Enemy*", made[1].retype.type);
        const with_enemy = try salamander.edit.apply(testing.allocator, text, made, .{ .parse = test_options });
        defer testing.allocator.free(with_enemy);
        try testing.expect(std.mem.indexOf(u8, with_enemy, "Enemy* target;") != null);
    }

    const game_state =
        \\struct GameStateManager {
        \\    [game.Sig("48 8B 0D ?? ?? ?? ?? 3D", Rip)] static GameStateManager* instance;
        \\
        \\    [0x297990] u32 mira;
        \\
        \\    [game.Sig("E8 ?? ?? ?? ?? 48 8B 0D ?? ?? ?? ?? F3 0F 10 36", Rip)] u32 spendMira(u32 amount);
        \\}
        \\
    ;

    const Game = struct {
        var instance: usize = 0;
        var scans: usize = 0;

        fn find(sig: Sig, _: []const u8) anyerror!usize {
            scans += 1;
            if (std.mem.startsWith(u8, sig.pattern, "48 8B 0D")) return @intFromPtr(&instance);
            if (std.mem.startsWith(u8, sig.pattern, "E8")) return 0x1234;
            return error.NotFound;
        }
    };

    test "signatures and instance" {
        var parsed = try salamander.parse(testing.allocator, game_state, test_options, null);
        defer parsed.deinit();
        const gsm = try testing.allocator.alignedAlloc(u8, .of(u32), 0x297994);
        defer testing.allocator.free(gsm);
        std.mem.writeInt(u32, gsm[0x297990..][0..4], 5000, .little);
        Game.instance = @intFromPtr(gsm.ptr);
        Game.scans = 0;

        var view: StructView = .{ .allocator = testing.allocator, .find = Game.find };
        defer view.deinit();
        view.setSchema(&parsed.schema);
        view.build();
        try testing.expectEqual(0, Game.scans);
        try testing.expectEqual(error.NotLookedFor, rowNamed(&view, "instance").?.err.?);
        try testing.expectEqual(null, view.address);
        try testing.expectEqualStrings("GameStateManager.instance", view.following().?);

        view.findSignatures();
        view.build();
        try testing.expectEqual(2, Game.scans);
        try testing.expectEqual(@intFromPtr(gsm.ptr), view.address);
        try testing.expectEqual(0x1234, rowNamed(&view, "spendMira").?.address);
        var buf: [max_text]u8 = undefined;
        try testing.expectEqualStrings("u32 (u32 amount)", signatureText(rowNamed(&view, "spendMira").?.function.?, &buf));
        try testing.expectEqualStrings("5000", view.valueText(rowNamed(&view, "mira").?, &buf));
        // instance, spendMira, the gap before mira, mira
        try testing.expectEqual(4, view.rows.items.len);
        const gap = view.rows.items[2];
        try testing.expect(gap.kind == .gap and gap.expandable and !gap.expanded);
        try testing.expectEqual(0x297990, gap.size);

        var again = try salamander.parse(testing.allocator, game_state, test_options, null);
        defer again.deinit();
        view.setSchema(&again.schema);
        Game.instance = 0;
        view.build();
        try testing.expectEqual(2, Game.scans);
        try testing.expectEqual(error.NullPointer, view.unmapped.?);
        Game.instance = @intFromPtr(gsm.ptr);

        view.setOpen(gap, true);
        view.build();
        var hex: usize = 0;
        var big: usize = 0;
        for (view.rows.items) |r| if (r.kind == .gap) {
            if (r.expandable) big += 1 else hex += 1;
        };
        try testing.expectEqual(max_gap_rows, hex);
        try testing.expectEqual(2, big);

        view.edit.commit(view.editTarget().?, gap, .define, "[0x100] f32 speed");
        const changes = view.takeChanges();
        try testing.expectEqual(0x100, changes[0].define.offset);
        try testing.expectEqualStrings("speed", changes[0].define.name);
        view.edit.commit(view.editTarget().?, gap, .define, "[0x300000] f32 far");
        try testing.expectEqual(0, view.takeChanges().len);
        try testing.expect(std.mem.indexOf(u8, view.problem.?.message(), "isn't in this gap") != null);
    }
};

test {
    _ = tests;
}
