//! Rows for a layout type laid over memory, one per field, element or gap.

const StructRows = @This();

const std = @import("std");

const mem = @import("tuft_mem");
const salamander = @import("salamander_schema");
const tuft_schema = @import("tuft_schema");

const Schema = salamander.Schema;
const Type = Schema.Ref;
const Ref = tuft_schema.Ref;
const Memory = mem.Memory;

pub const max_depth = 16;
pub const max_elements = 256;
/// Hex rows an opened gap shows at a time. The rest is another gap row.
pub const max_gap_rows = 1024;
/// Gaps bigger than this are one row, closed until opened.
const large_gap = 0x100;

allocator: std.mem.Allocator,
memory: Memory,
schema: *const Schema,
rows: *std.ArrayList(Row),
open: *const Open,
options: Options = .{},

pub const Options = struct {
    /// Hex rows for bytes no field covers.
    gaps: bool = true,
    /// The vtable row, and its slots when it's opened.
    vtables: bool = true,
    /// Struct elements of arrays start open.
    open_elements: bool = true,
    /// Past this many rows the rest isn't shown.
    max_rows: usize = 50_000,
};

pub const Row = struct {
    id: u64,
    parent: u64,
    depth: u8,
    kind: Kind,
    /// From the start of the struct or array it's in.
    offset: usize,
    address: ?usize = null,
    /// Elements have `index` instead.
    name: []const u8 = "",
    index: usize = 0,
    width: u16 = 0,
    /// Null for rows that aren't a value, like gaps.
    type: ?Type = null,
    size: usize = 0,
    owner: ?*const Schema.Type = null,
    ref: ?Ref = null,
    expandable: bool = false,
    expanded: bool = false,
    err: ?anyerror = null,
    function: ?*const Schema.Method = null,

    pub const Kind = enum { field, element, bits, vtable, slot, gap, more, static, function };

    pub fn isField(self: Row) bool {
        return self.kind == .field and self.owner != null;
    }
};

/// Rows toggled from how they start. Keyed by row id, so it survives rebuilds.
pub const Open = struct {
    toggled: std.AutoHashMapUnmanaged(u64, void) = .empty,

    pub fn deinit(self: *Open, gpa: std.mem.Allocator) void {
        self.toggled.deinit(gpa);
    }

    pub fn isOpen(self: *const Open, id: u64, default: bool) bool {
        return default != self.toggled.contains(id);
    }

    pub fn set(self: *Open, gpa: std.mem.Allocator, row: Row, open: bool) void {
        if (!row.expandable or row.expanded == open) return;
        if (self.toggled.contains(row.id)) {
            _ = self.toggled.remove(row.id);
        } else {
            self.toggled.put(gpa, row.id, {}) catch {};
        }
    }
};

pub fn idOf(parent: u64, tag: u8, name: []const u8, n: usize) u64 {
    var h = std.hash.Wyhash.init(parent);
    h.update(&.{tag});
    h.update(name);
    h.update(std.mem.asBytes(&n));
    return h.final();
}

pub fn fieldId(parent: u64, name: []const u8) u64 {
    return idOf(parent, 'f', name, 0);
}

pub fn add(self: *StructRows, row: Row) bool {
    if (self.rows.items.len >= self.options.max_rows) return false;
    self.rows.append(self.allocator, row) catch return false;
    return true;
}

const Member = struct {
    field: Schema.Field,
    owner: *const Schema.Type,

    fn before(_: void, a: Member, b: Member) bool {
        return a.field.offset < b.field.offset;
    }
};

/// Base first.
pub fn chainOf(schema: *const Schema, t: *const Schema.Type, out: *[max_depth]*const Schema.Type) []*const Schema.Type {
    var n: usize = 0;
    var at: ?*const Schema.Type = t;
    while (at) |cur| : (at = schema.baseOf(cur)) {
        if (n == out.len) break;
        out[n] = cur;
        n += 1;
    }
    std.mem.reverse(*const Schema.Type, out[0..n]);
    return out[0..n];
}

pub fn addStruct(self: *StructRows, t: *const Schema.Type, at: ?usize, depth: u8, parent: u64) void {
    const schema = self.schema;
    const ps = schema.pointer_size;
    const is_union = t.kind == .@"union";
    var chain_buf: [max_depth]*const Schema.Type = undefined;
    const chain = chainOf(schema, t, &chain_buf);

    var members: std.ArrayList(Member) = .empty;
    defer members.deinit(self.allocator);
    var has_vtable = false;
    for (chain) |c| switch (c.kind) {
        .@"struct", .@"union" => |s| {
            for (s.fields) |f| members.append(self.allocator, .{ .field = f, .owner = c }) catch return;
            for (s.methods) |m| if (m.virtual != null) {
                has_vtable = true;
            };
            if (tuft_schema.sigs.find(c.annotations, null, "VirtualTable") != null) has_vtable = true;
        },
        else => {},
    };
    if (!is_union) std.sort.insertion(Member, members.items, {}, Member.before);

    var cursor: usize = 0;
    if (self.options.vtables and has_vtable and !is_union and (members.items.len == 0 or members.items[0].field.offset >= ps)) {
        const id = idOf(parent, 'v', "", 0);
        const open = self.open.isOpen(id, false);
        if (!self.add(.{ .id = id, .parent = parent, .depth = depth, .kind = .vtable, .offset = 0, .address = at, .name = "vtable", .size = ps, .owner = t, .expandable = true, .expanded = open })) return;
        if (open) self.addSlots(chain, at, depth + 1, id);
        cursor = ps;
    }
    for (members.items) |m| {
        const f = m.field;
        if (self.options.gaps and !is_union and f.offset > cursor) {
            if (!self.addGap(t, at, cursor, f.offset, depth, parent)) return;
        }
        const address = if (at) |a| a + f.offset else null;
        // A `T[count]` array, as long as its count says now
        const ty = if (at) |a| Ref.sizedField(schema, m.owner, f, self.memory, a) else f.type;
        if (!self.addValue(.{ .id = fieldId(parent, f.name), .parent = parent, .depth = depth, .kind = .field, .offset = f.offset, .address = address, .name = f.name, .type = ty, .owner = m.owner })) return;
        const size = schema.sizeOf(f.type) orelse 0;
        cursor = @max(cursor, f.offset + size);
    }
    if (self.options.gaps and !is_union) {
        const size = if (t.size == Schema.Type.auto) cursor else t.size;
        if (size > cursor) _ = self.addGap(t, at, cursor, size, depth, parent);
    }
}

/// A big gap is a single row until it's opened, then hex a page at a time.
fn addGap(self: *StructRows, owner: *const Schema.Type, at: ?usize, start: usize, end: usize, depth: u8, parent: u64) bool {
    const ps = self.schema.pointer_size;
    var offset = start;
    while (end - offset > large_gap) {
        const id = idOf(parent, 'G', "", offset);
        const open = self.open.isOpen(id, false);
        if (!self.add(.{ .id = id, .parent = parent, .depth = depth, .kind = .gap, .offset = offset, .address = if (at) |a| a + offset else null, .size = end - offset, .owner = owner, .expandable = true, .expanded = open })) return false;
        if (!open) return true;
        const page_end = @min(end, (offset / ps + max_gap_rows) * ps);
        if (!self.addHex(owner, at, offset, page_end, depth + 1, parent)) return false;
        offset = page_end;
    }
    return self.addHex(owner, at, offset, end, depth, parent);
}

/// Pointer-sized hex rows, parented to the struct even in a big gap so new fields are found again.
fn addHex(self: *StructRows, owner: *const Schema.Type, at: ?usize, start: usize, end: usize, depth: u8, parent: u64) bool {
    const ps = self.schema.pointer_size;
    var offset = start;
    while (offset < end) {
        const step = @min(end, (offset / ps + 1) * ps);
        if (!self.add(.{ .id = idOf(parent, 'g', "", offset), .parent = parent, .depth = depth, .kind = .gap, .offset = offset, .address = if (at) |a| a + offset else null, .size = step - offset, .owner = owner })) return false;
        offset = step;
    }
    return true;
}

fn addSlots(self: *StructRows, chain: []const *const Schema.Type, at: ?usize, depth: u8, parent: u64) void {
    const ps = self.schema.pointer_size;
    const vtable: ?usize = if (at) |a| readPointer(self.memory, a, ps) else null;
    var slots: std.ArrayList(*const Schema.Method) = .empty;
    defer slots.deinit(self.allocator);
    for (chain) |c| switch (c.kind) {
        .@"struct" => |s| for (s.methods) |*m| if (m.virtual != null) slots.append(self.allocator, m) catch return,
        else => {},
    };
    std.sort.insertion(*const Schema.Method, slots.items, {}, struct {
        fn before(_: void, a: *const Schema.Method, b: *const Schema.Method) bool {
            return a.virtual.? < b.virtual.?;
        }
    }.before);
    for (slots.items) |m| {
        const index = m.virtual.?;
        const address = if (vtable) |v| (if (v == 0) null else v + index * ps) else null;
        if (!self.add(.{ .id = idOf(parent, 's', m.name, index), .parent = parent, .depth = depth, .kind = .slot, .offset = index * ps, .address = address, .name = m.name, .index = index, .size = ps })) return;
    }
}

/// The row and, if it's open, what's in it.
pub fn addValue(self: *StructRows, base: Row) bool {
    const row = self.prepare(base);
    if (!self.add(row)) return false;
    if (!row.expanded) return true;
    return self.addChildren(row);
}

/// Fills in its size, `ref` and whether it opens, without adding it.
pub fn prepare(self: *const StructRows, base: Row) Row {
    const schema = self.schema;
    var row = base;
    const ty = row.type orelse return row;
    row.size = schema.sizeOf(ty) orelse 0;
    if (row.address) |a| row.ref = Ref.at(schema, ty, mem.Address.fromMemory(self.memory, a));
    switch (ty) {
        .named => |n| if (schema.findType(n)) |t| switch (t.kind) {
            .@"struct", .@"union" => {
                row.expandable = true;
                // A static struct would push the struct shown down, so it starts closed
                const default = switch (row.kind) {
                    .static => false,
                    .element => self.options.open_elements,
                    else => true,
                };
                row.expanded = self.open.isOpen(row.id, default);
            },
            .bitfield => {
                row.expandable = true;
                row.expanded = self.open.isOpen(row.id, false);
            },
            else => {},
        },
        .array => |a| if (!isTextUnit(a.child.*)) {
            row.expandable = a.len > 0;
            row.expanded = self.open.isOpen(row.id, false);
        },
        .pointer, .optional => if (row.ref != null and pointee(schema, ty) != null) {
            row.expandable = true;
            row.expanded = self.open.isOpen(row.id, false);
        },
        else => {},
    }
    return row;
}

/// What's in a row from `prepare`, a level deeper.
pub fn addChildren(self: *StructRows, row: Row) bool {
    if (row.depth + 1 >= max_depth) return true;
    const schema = self.schema;
    const depth = row.depth + 1;
    switch (row.type orelse return true) {
        .named => |n| {
            const t = schema.findType(n) orelse return true;
            switch (t.kind) {
                .bitfield => |bf| for (bf.members) |b| {
                    const bits_ref = if (row.ref) |r| r.field(b.name) else null;
                    if (!self.add(.{ .id = idOf(row.id, 'b', b.name, 0), .parent = row.id, .depth = depth, .kind = .bits, .offset = 0, .address = row.address, .name = b.name, .index = b.bit, .width = b.bits, .type = memberType(b, bf.backing), .size = row.size, .ref = bits_ref })) return false;
                },
                .@"struct", .@"union" => self.addStruct(t, row.address, depth, row.id),
                else => {},
            }
        },
        .array => |a| {
            const each = schema.sizeOf(a.child.*) orelse 0;
            for (0..@min(a.len, max_elements)) |i| {
                const address = if (row.address) |at| at + i * each else null;
                if (!self.addValue(.{ .id = idOf(row.id, 'e', "", i), .parent = row.id, .depth = depth, .kind = .element, .offset = i * each, .address = address, .index = i, .type = a.child.* })) return false;
            }
            if (a.len > max_elements) {
                if (!self.add(.{ .id = idOf(row.id, 'm', "", 0), .parent = row.id, .depth = depth, .kind = .more, .offset = max_elements * each, .index = a.len - max_elements })) return false;
            }
        },
        .pointer, .optional => {
            const t = pointee(schema, row.type.?) orelse return true;
            const ref = row.ref orelse return true;
            const target = ref.deref().address.unwrap() catch return true;
            self.addStruct(t, target, depth, row.id);
        },
        else => {},
    }
    return true;
}

/// What a bitfield member reads as.
pub fn memberType(b: Schema.Bits, backing: Schema.Prim) Type {
    return switch (b.type) {
        .bool => .{ .prim = .bool },
        .uint => .{ .prim = backing },
        .@"enum" => |n| .{ .named = n },
    };
}

pub fn namedStruct(schema: *const Schema, t: Type) ?*const Schema.Type {
    const found = schema.findType(if (t == .named) t.named else return null) orelse return null;
    return switch (found.kind) {
        .@"struct", .@"union" => found,
        else => null,
    };
}

/// The struct a pointer points at.
pub fn pointee(schema: *const Schema, t: Type) ?*const Schema.Type {
    return switch (t) {
        .pointer => |c| namedStruct(schema, c.*),
        .optional => |o| if (o.* == .pointer) namedStruct(schema, o.pointer.*) else null,
        else => null,
    };
}

pub fn isTextUnit(t: Type) bool {
    return switch (t) {
        .prim => |p| p == .utf8 or p == .utf16,
        else => false,
    };
}

pub fn isText(t: Type) bool {
    return switch (t) {
        .array => |a| isTextUnit(a.child.*),
        .pointer => |c| isTextUnit(c.*),
        .optional => |o| o.* == .pointer and isTextUnit(o.pointer.*),
        .prim => |p| p == .cstring,
        else => false,
    };
}

pub fn isPointer(t: Type) bool {
    return switch (t) {
        .pointer => true,
        .optional => |o| o.* == .pointer,
        .prim => |p| p == .cstring,
        else => false,
    };
}

/// Room to parse a type typed in, like `Player*[4]`, without an arena. Don't move it once used.
pub const Typed = struct {
    buf: [1024]u8 = undefined,
    fba: std.heap.FixedBufferAllocator = undefined,

    /// Null if it isn't one.
    pub fn parse(self: *Typed, text: []const u8) ?Type {
        const trimmed = std.mem.trim(u8, text, " ");
        if (trimmed.len == 0) return null;
        self.fba = .init(&self.buf);
        return salamander.parseType(self.fba.allocator(), trimmed, null) catch null;
    }
};

pub fn readPointer(memory: Memory, address: usize, ps: u8) ?usize {
    var bytes: [8]u8 = @splat(0);
    memory.read(address, bytes[0..ps]) catch return null;
    return std.math.cast(usize, std.mem.readInt(u64, &bytes, .little));
}

/// How Cheat Engine would show it.
pub fn kindOf(schema: *const Schema, row: Row) mem.values.Kind {
    const bySize: mem.values.Kind = switch (row.size) {
        1 => .byte,
        2 => .two_bytes,
        4 => .four_bytes,
        8 => .eight_bytes,
        else => .bytes,
    };
    if (row.kind != .field and row.kind != .element and row.kind != .static) return bySize;
    const t = row.type orelse return bySize;
    if (isPointer(t)) return if (schema.pointer_size == 8) .eight_bytes else .four_bytes;
    return switch (t) {
        .prim => |p| switch (p) {
            .f32 => .float,
            .f64 => .double,
            else => bySize,
        },
        .array => |a| switch (a.child.*) {
            .prim => |p| if (p == .utf8) .text else if (p == .utf16) .text_utf16 else .bytes,
            else => .bytes,
        },
        else => bySize,
    };
}

/// What the Value column shows.
pub fn valueText(memory: Memory, schema: *const Schema, row: Row, buf: []u8) []const u8 {
    const address = row.address orelse return "";
    switch (row.kind) {
        .more, .function => return "",
        .vtable, .slot => {
            const p = readPointer(memory, address, schema.pointer_size) orelse return "??";
            return std.fmt.bufPrint(buf, "0x{x}", .{p}) catch "";
        },
        .gap => {
            if (row.expandable) return "";
            var bytes: [16]u8 = undefined;
            const n = @min(row.size, bytes.len);
            memory.read(address, bytes[0..n]) catch return "??";
            var w: std.Io.Writer = .fixed(buf);
            for (bytes[0..n], 0..) |b, i| w.print("{s}{X:0>2}", .{ if (i == 0) "" else " ", b }) catch break;
            if (row.size > n) w.writeAll(" ..") catch {};
            return w.buffered();
        },
        .field, .element, .bits, .static => {
            const ref = row.ref orelse return "";
            if (row.kind != .bits and row.type != null and isText(row.type.?)) {
                var text: [254]u8 = undefined;
                const room = @min(text.len, buf.len -| 2);
                const got = ref.text(text[0..room]) catch |err| return std.fmt.bufPrint(buf, "{t}", .{err}) catch "";
                return std.fmt.bufPrint(buf, "\"{s}\"", .{got}) catch "";
            }
            const v = ref.load() catch |err| return if (err == error.NotAValue) "" else std.fmt.bufPrint(buf, "{t}", .{err}) catch "";
            return std.fmt.bufPrint(buf, "{f}", .{v}) catch "";
        },
    }
}

/// Fields and elements that hold a value, so it can be changed.
pub fn canEditValue(row: Row) bool {
    if (row.address == null) return false;
    return switch (row.kind) {
        .gap => !row.expandable,
        .field, .element, .bits, .static => if (row.ref) |r| (if (r.load()) |_| true else |_| false) else false,
        else => false,
    };
}
