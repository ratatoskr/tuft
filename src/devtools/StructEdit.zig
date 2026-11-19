//! What gets typed into a `StructView`: changes to its `.sal` for Salamander's `edit`, and new values.

const StructEdit = @This();

const std = @import("std");

const ui = @import("tuft_ui");
const mem = @import("tuft_mem");
const salamander = @import("salamander_schema");
const Ref = @import("tuft_schema").Ref;
const Text = @import("tuft_text").Text;

const root = @import("root.zig");
const write = @import("write.zig");
const StructView = @import("StructView.zig");

const Schema = salamander.Schema;
const Change = salamander.edit.Change;
const Row = StructView.Row;

const max_text = 256;
const new_struct_size = 0x40;

editing: ?Editing = null,
input: Text(max_text) = .{},
focus: bool = false,
/// A row to pick once the changes make it.
select_next: ?u64 = null,
changes: [2]Change = undefined,
change_len: usize = 0,
change_text: [1024]u8 = undefined,
change_text_len: usize = 0,
/// Free to reuse once the changes have been taken and drawn past.
change_text_taken: bool = false,

pub const What = enum { value, type, name, define, new_struct, size };

pub const Editing = struct {
    row: u64,
    what: What,
};

/// What an edit needs from the view.
pub const Target = struct {
    schema: *const Schema,
    /// The struct shown.
    shown: []const u8,
    memory: mem.Memory,
    symbols: mem.Symbols,
    claims: mem.Claims,
    /// Set when it goes wrong, cleared once something changes.
    problem: *?root.Problem,

    fn fail(self: Target, comptime fmt: []const u8, args: anytype) void {
        self.problem.* = .init(fmt, args);
    }
};

/// What `row` is being edited for, if it is.
pub fn of(self: *const StructEdit, row: u64) ?What {
    const e = self.editing orelse return null;
    return if (e.row == row) e.what else null;
}

/// `value` is what it shows now, for `.value`.
pub fn start(self: *StructEdit, target: Target, row: Row, what: What, value: []const u8) void {
    var buf: [max_text]u8 = undefined;
    const initial: []const u8 = switch (what) {
        .value => value,
        .type => if (row.type) |t| std.fmt.bufPrint(&buf, "{f}", .{t}) catch "" else "",
        .name => row.name,
        .define => if (row.expandable)
            std.fmt.bufPrint(&buf, "[0x{X}] u32", .{row.offset}) catch ""
        else switch (row.size) {
            1 => "u8",
            2 => "u16",
            4 => "u32",
            8 => "u64",
            else => std.fmt.bufPrint(&buf, "u8[{d}]", .{row.size}) catch "",
        },
        .new_struct => freshName(target.schema, &buf),
        .size => std.fmt.bufPrint(&buf, "0x{X}", .{sizeOfType(target.schema, target.shown)}) catch "",
    };
    self.input.set(initial);
    self.editing = .{ .row = row.id, .what = what };
    self.focus = true;
}

/// The input box. Enter commits it.
pub fn draw(self: *StructEdit, target: Target, row: Row, what: What) void {
    if (self.focus) {
        ui.focusNext();
        self.focus = false;
    }
    ui.setNextItemWidth(if (what == .size) 100 else ui.fill);
    const hint: ?[:0]const u8 = switch (what) {
        .define => "type, or type and name. [0x10] first to put it there",
        .new_struct => "name of the new struct",
        else => null,
    };
    const entered = ui.inputTextWith("##edit", &self.input.buf, .{ .flags = .{ .enter_returns_true = true, .auto_select_all = true }, .tight = true, .hint = hint });
    if (entered) {
        self.editing = null;
        self.commit(target, row, what, std.mem.trim(u8, self.input.get(), " \t"));
    } else if (ui.isItemDeactivated()) {
        self.editing = null;
    }
}

pub fn commit(self: *StructEdit, target: Target, row: Row, what: What, text: []const u8) void {
    const schema = target.schema;
    switch (what) {
        .value => setValue(target, row, text),
        .type => {
            var buf: [max_text]u8 = undefined;
            const was = if (row.type) |t| std.fmt.bufPrint(&buf, "{f}", .{t}) catch "" else "";
            if (text.len == 0 or std.mem.eql(u8, text, was)) return;
            self.emit(target, .{ .retype = .{ .owner = self.keep(row.owner.?.name), .field = self.keep(row.name), .type = self.keep(text) } });
        },
        .name => {
            if (std.mem.eql(u8, text, row.name)) return;
            if (!isName(text)) return target.fail("'{s}' isn't a name. Letters, digits and _", .{text});
            self.emit(target, .{ .rename = .{ .owner = self.keep(row.owner.?.name), .field = self.keep(row.name), .name = self.keep(text) } });
            self.select_next = StructView.fieldId(row.parent, text);
        },
        .define => {
            var rest = text;
            var offset = row.offset;
            if (std.mem.startsWith(u8, rest, "[")) {
                const close = std.mem.indexOfScalar(u8, rest, ']') orelse return target.fail("No ] after the offset", .{});
                offset = parseInt(std.mem.trim(u8, rest[1..close], " ")) orelse return target.fail("'{s}' isn't an offset", .{rest[1..close]});
                if (offset < row.offset or offset >= row.offset + row.size) {
                    return target.fail("0x{X} isn't in this gap, 0x{X}..0x{X}", .{ offset, row.offset, row.offset + row.size });
                }
                rest = std.mem.trim(u8, rest[close + 1 ..], " \t");
            }
            if (rest.len == 0) return;
            var type_text = rest;
            var name = self.keepPrint("unk_{X}", .{offset});
            if (std.mem.lastIndexOfAny(u8, rest, " \t")) |space| {
                type_text = std.mem.trim(u8, rest[0..space], " \t");
                name = self.keep(rest[space + 1 ..]);
            }
            if (!isName(name)) return target.fail("'{s}' isn't a name. Letters, digits and _", .{name});
            const owner = ownerAt(schema, row.owner.?, offset);
            self.emit(target, .{ .define = .{ .owner = self.keep(owner.name), .offset = offset, .type = self.keep(type_text), .name = name } });
            self.select_next = StructView.fieldId(row.parent, name);
        },
        .new_struct => {
            if (!isName(text)) return target.fail("'{s}' isn't a name. Letters, digits and _", .{text});
            if (schema.findType(text) != null) return target.fail("There's a {s} already", .{text});
            const name = self.keep(text);
            const pointer = self.keepPrint("{s}*", .{name});
            self.emit(target, .{ .add_struct = .{ .name = name, .size = new_struct_size } });
            if (row.kind == .gap) {
                const owner = ownerAt(schema, row.owner.?, row.offset);
                const field = self.keepPrint("unk_{X}", .{row.offset});
                self.emit(target, .{ .define = .{ .owner = self.keep(owner.name), .offset = row.offset, .type = pointer, .name = field } });
                self.select_next = StructView.fieldId(row.parent, field);
            } else {
                self.emit(target, .{ .retype = .{ .owner = self.keep(row.owner.?.name), .field = self.keep(row.name), .type = pointer } });
            }
        },
        .size => {
            const size = parseInt(text) orelse return target.fail("'{s}' isn't a size", .{text});
            self.emit(target, .{ .size = .{ .owner = self.keep(target.shown), .size = size } });
        },
    }
}

/// Its bytes become a gap.
pub fn remove(self: *StructEdit, target: Target, row: Row) void {
    self.emit(target, .{ .remove = .{ .owner = self.keep(row.owner.?.name), .field = self.keep(row.name) } });
}

/// Good until the next `draw`.
pub fn takeChanges(self: *StructEdit) []const Change {
    defer self.change_len = 0;
    self.change_text_taken = true;
    return self.changes[0..self.change_len];
}

fn emit(self: *StructEdit, target: Target, change: Change) void {
    if (self.change_len == self.changes.len) return;
    target.problem.* = null;
    self.changes[self.change_len] = change;
    self.change_len += 1;
}

fn keep(self: *StructEdit, text: []const u8) []const u8 {
    return self.keepPrint("{s}", .{text});
}

fn keepPrint(self: *StructEdit, comptime fmt: []const u8, args: anytype) []const u8 {
    if (self.change_text_taken) {
        self.change_text_taken = false;
        self.change_text_len = 0;
    }
    const out = std.fmt.bufPrint(self.change_text[self.change_text_len..], fmt, args) catch return "";
    self.change_text_len += out.len;
    return out;
}

fn freshName(schema: *const Schema, buf: []u8) []const u8 {
    var n: usize = 1;
    while (true) : (n += 1) {
        const name = std.fmt.bufPrint(buf, "Struct{d}", .{n}) catch return "Struct";
        if (schema.findType(name) == null) return name;
    }
}

/// A base's, if it's inside the base.
fn ownerAt(schema: *const Schema, t: *const Schema.Type, offset: usize) *const Schema.Type {
    var cur = t;
    for (0..StructView.max_depth) |_| {
        const base = schema.baseOf(cur) orelse break;
        if (offset >= base.size) break;
        cur = base;
    }
    return cur;
}

/// What `commit` does for `.value`. `target.shown` isn't needed.
pub fn setValue(target: Target, row: Row, text: []const u8) void {
    const address = row.address orelse return;
    if (row.kind == .gap) {
        var buf: [mem.values.max_len]u8 = undefined;
        const bytes = write.valueBytes(.bytes, text, &buf) catch |err| return target.fail("Couldn't change it: {t}", .{err});
        target.problem.* = write.store(target.memory, target.claims, address, bytes[0..@min(bytes.len, row.size)]);
        return;
    }
    const ref = row.ref orelse return;
    const current = ref.load() catch |err| return target.fail("Couldn't read it: {t}", .{err});
    const v = parseValue(target, ref, current, text) catch return target.fail("'{s}' isn't a {s}", .{ text, @tagName(current) });
    if (target.claims.first(address, @max(row.size, 1))) |claim| {
        target.problem.* = root.claimed(address, &claim);
        return;
    }
    ref.store(v) catch |err| return target.fail("Couldn't change it: {t}", .{err});
    target.problem.* = null;
}

/// Numbers go through `mem.values`, pointers through `mem.Location`.
fn parseValue(target: Target, ref: Ref, current: Ref.Value, text: []const u8) !Ref.Value {
    switch (current) {
        .float => return .{ .float = try mem.values.parseFloat(f64, text) },
        .bool => return .{ .bool = try mem.values.parseBool(text) },
        .pointer => return .{ .pointer = try mem.Location.eval(text, .{ .symbols = target.symbols, .memory = target.memory }, null) },
        .@"enum" => {
            const name = if (std.mem.startsWith(u8, text, ".")) text[1..] else text;
            if (ref.named()) |t| if (Schema.enumValue(t, name)) |v| return .{ .int = std.math.cast(i64, v) orelse return error.Overflow };
            return intValue(text);
        },
        .int, .uint => return intValue(text),
    }
}

fn intValue(text: []const u8) !Ref.Value {
    const v = try mem.values.parseInt(text);
    if (v < 0) return .{ .int = std.math.cast(i64, v) orelse return error.Overflow };
    return .{ .uint = std.math.cast(u64, v) orelse return error.Overflow };
}

fn sizeOfType(schema: *const Schema, name: []const u8) usize {
    const t = schema.findType(name) orelse return 0;
    return if (t.size == Schema.Type.auto) 0 else t.size;
}

/// Letters, digits and _, not starting with a digit.
pub fn isName(text: []const u8) bool {
    if (text.len == 0 or std.ascii.isDigit(text[0])) return false;
    for (text) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    return true;
}

/// Decimal, or hex with `0x`.
pub fn parseInt(text: []const u8) ?usize {
    if (std.mem.startsWith(u8, text, "0x") or std.mem.startsWith(u8, text, "0X"))
        return std.fmt.parseInt(usize, text[2..], 16) catch null;
    return std.fmt.parseInt(usize, text, 10) catch null;
}
