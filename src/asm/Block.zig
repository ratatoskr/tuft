//! Instructions, labels and data assembled together, so labels work before they're defined.

const Block = @This();

const std = @import("std");

const root = @import("root.zig");
const parser = @import("parse.zig");
const encoding = @import("encode.zig");
const Diagnostic = root.Diagnostic;
const Error = root.Error;
const Instruction = root.Instruction;
const Value = root.Value;

/// Owns copies of names and data.
arena: std.heap.ArenaAllocator,
items: std.ArrayList(Item) = .empty,

pub const Item = struct {
    /// From 1, 0 if from Zig.
    line: u32 = 0,
    kind: Kind,
};

pub const Kind = union(enum) {
    instruction: Instruction,
    label: []const u8,
    data: Data,
};

pub const Data = struct {
    /// 1 (`db`), 2, 4 or 8 (`dq`).
    unit: u8,
    values: []const Datum,
};

pub const Datum = union(enum) {
    value: Value,
    /// `float` at unit 4, `double` at 8
    float: f64,
    /// `db` only
    text: []const u8,
};

pub const Code = struct {
    address: usize,
    bytes: []u8,
    labels: []Label,

    pub const Label = struct { name: []const u8, address: usize };

    pub fn deinit(self: *Code, gpa: std.mem.Allocator) void {
        for (self.labels) |l| gpa.free(l.name);
        gpa.free(self.labels);
        gpa.free(self.bytes);
        self.* = undefined;
    }

    pub fn labelAddress(self: *const Code, name: []const u8) ?usize {
        for (self.labels) |l| {
            if (std.mem.eql(u8, l.name, name)) return l.address;
        }
        return null;
    }
};

pub fn init(gpa: std.mem.Allocator) Block {
    return .{ .arena = .init(gpa) };
}

pub fn deinit(self: *Block) void {
    self.arena.deinit();
    self.* = undefined;
}

pub fn emit(self: *Block, mnemonic: anytype, operands: anytype) Error!void {
    try self.add(.{ .kind = .{ .instruction = root.instruction(mnemonic, operands) } });
}

pub fn label(self: *Block, name: []const u8) Error!void {
    try self.add(.{ .kind = .{ .label = name } });
}

pub fn data(self: *Block, unit: u8, values: []const Datum) Error!void {
    try self.add(.{ .kind = .{ .data = .{ .unit = unit, .values = values } } });
}

/// Copies its names and data.
pub fn add(self: *Block, item: Item) Error!void {
    const a = self.arena.allocator();
    var copy = item;
    switch (copy.kind) {
        .instruction => |*insn| for (insn.operands[0..insn.operand_count]) |*op| switch (op.*) {
            .reg, .ptr => {},
            .imm => |*v| try own(a, v),
            .mem => |*m| try own(a, &m.disp),
        },
        .label => |*name| name.* = try a.dupe(u8, name.*),
        .data => |*d| {
            const values = try a.dupe(Datum, d.values);
            for (values) |*v| switch (v.*) {
                .value => |*value| try own(a, value),
                .float => {},
                .text => |*t| t.* = try a.dupe(u8, t.*),
            };
            d.values = values;
        },
    }
    try self.items.append(a, copy);
}

fn own(a: std.mem.Allocator, v: *Value) !void {
    if (v.name) |n| v.name = try a.dupe(u8, n);
}

pub fn parse(self: *Block, source: []const u8, diagnostic: ?*Diagnostic) Error!void {
    var scratch: std.heap.ArenaAllocator = .init(self.arena.child_allocator);
    defer scratch.deinit();
    var lines = std.mem.splitScalar(u8, source, '\n');
    var number: u32 = 0;
    while (lines.next()) |text| {
        number += 1;
        var statements: parser.Statements = .of(text);
        while (statements.next()) |statement| {
            const l = try parser.line(statement, number, scratch.allocator(), diagnostic);
            if (l.label) |name| try self.add(.{ .line = number, .kind = .{ .label = name } });
            if (l.item) |kind| try self.add(.{ .line = number, .kind = kind });
        }
    }
}

const max_passes = 32;

pub fn assemble(self: *const Block, gpa: std.mem.Allocator, options: root.Options, diagnostic: ?*Diagnostic) Error!Code {
    const items = self.items.items;
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const a = scratch.allocator();

    var layout: Layout = .{
        .items = items,
        .sizes = try a.alloc(usize, items.len),
        .addresses = try a.alloc(usize, items.len),
        .long = try a.alloc(bool, items.len),
        .options = options,
        .diagnostic = diagnostic,
    };
    @memset(layout.sizes, 0);
    @memset(layout.long, false);
    for (items) |item| {
        const name = switch (item.kind) {
            .label => |n| n,
            else => continue,
        };
        const entry = try layout.labels.getOrPut(a, name);
        if (entry.found_existing) {
            Diagnostic.set(diagnostic, item.line, "`{s}` is defined twice", .{name});
            return error.DuplicateLabel;
        }
    }

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    for (0..max_passes) |pass| {
        out.clearRetainingCapacity();
        if (!try layout.pass(gpa, a, &out, pass)) {
            var code: Code = .{ .address = options.address, .bytes = &.{}, .labels = &.{} };
            errdefer code.deinit(gpa);
            code.labels = try gpa.alloc(Code.Label, layout.labels.count());
            var it = layout.labels.iterator();
            var i: usize = 0;
            errdefer for (code.labels[0..i]) |l| gpa.free(l.name);
            while (it.next()) |entry| : (i += 1) {
                code.labels[i] = .{ .name = try gpa.dupe(u8, entry.key_ptr.*), .address = entry.value_ptr.* };
            }
            code.bytes = try out.toOwnedSlice(gpa);
            return code;
        }
    }
    Diagnostic.set(diagnostic, 0, "the labels never settled", .{});
    return error.LayoutDidNotSettle;
}

const Layout = struct {
    items: []const Item,
    sizes: []usize,
    addresses: []usize,
    /// Jumps lengthened earlier stay long so they can't shrink back
    long: []bool,
    labels: std.StringHashMapUnmanaged(usize) = .empty,
    /// So we only ask once per name
    resolved: std.StringHashMapUnmanaged(usize) = .empty,
    options: root.Options,
    diagnostic: ?*Diagnostic,

    /// Lays out and encodes. True if a size changed and we need another pass.
    fn pass(self: *Layout, gpa: std.mem.Allocator, a: std.mem.Allocator, out: *std.ArrayList(u8), number: usize) Error!bool {
        var at = self.options.address;
        for (self.items, self.sizes, self.addresses) |item, size, *address| {
            address.* = at;
            at +%= size;
            if (item.kind == .label) self.labels.putAssumeCapacity(item.kind.label, address.*);
        }

        var changed = false;
        for (self.items, 0..) |item, i| {
            const before = out.items.len;
            switch (item.kind) {
                .label => {},
                .instruction => |insn| {
                    var resolved = insn;
                    const named = try self.resolveInstruction(a, &resolved, item.line);
                    var encoded = try root.encodeOrExplain(&resolved, self.addresses[i], .{ .long_branch = self.long[i] }, item.line, null, self.diagnostic);
                    if (number > 0 and named and encoded.len < self.sizes[i] and !self.long[i]) {
                        self.long[i] = true;
                        encoded = encoding.encode(&resolved, self.addresses[i], .{ .long_branch = true }) catch encoded;
                    }
                    try out.appendSlice(gpa, encoded.slice());
                },
                .data => |d| try self.writeData(gpa, a, out, d, item.line),
            }
            const size = out.items.len - before;
            if (size != self.sizes[i]) changed = true;
            self.sizes[i] = size;
        }
        return changed;
    }

    /// Replaces names with addresses. True if it had any.
    fn resolveInstruction(self: *Layout, a: std.mem.Allocator, insn: *Instruction, line: u32) Error!bool {
        var named = false;
        for (insn.operands[0..insn.operand_count]) |*op| {
            const v: *Value = switch (op.*) {
                .reg, .ptr => continue,
                .imm => |*v| v,
                .mem => |*m| &m.disp,
            };
            if (v.name == null) continue;
            v.* = .{ .offset = try self.resolve(a, v.*, line) };
            named = true;
        }
        return named;
    }

    fn resolve(self: *Layout, a: std.mem.Allocator, v: Value, line: u32) Error!i64 {
        const name = v.name orelse return v.offset;
        const address = self.labels.get(name) orelse self.resolved.get(name) orelse found: {
            const r = self.options.resolver orelse break :found null;
            const address = r.resolve(r.context, name) orelse break :found null;
            try self.resolved.put(a, name, address);
            break :found address;
        } orelse return parser.unknownName(self.diagnostic, line, name);
        return @as(i64, @bitCast(@as(u64, address))) +% v.offset;
    }

    fn writeData(self: *Layout, gpa: std.mem.Allocator, a: std.mem.Allocator, out: *std.ArrayList(u8), d: Data, line: u32) Error!void {
        for (d.values) |datum| switch (datum) {
            .text => |t| try out.appendSlice(gpa, t),
            .float => |f| switch (d.unit) {
                4 => try out.appendSlice(gpa, std.mem.asBytes(&std.mem.nativeToLittle(u32, @bitCast(@as(f32, @floatCast(f)))))),
                8 => try out.appendSlice(gpa, std.mem.asBytes(&std.mem.nativeToLittle(u64, @bitCast(f)))),
                else => {
                    Diagnostic.set(self.diagnostic, line, "floats only go in `dd` or `dq`", .{});
                    return error.InvalidSyntax;
                },
            },
            .value => |v| {
                const n = try self.resolve(a, v, line);
                const bits: u7 = @intCast(d.unit * 8);
                // Has to fit as signed or unsigned
                if (bits < 64 and (n >= @as(i64, 1) << @intCast(bits) or n < -(@as(i64, 1) << @intCast(bits - 1)))) {
                    Diagnostic.set(self.diagnostic, line, "{d} doesn't fit in {d} bytes", .{ n, d.unit });
                    return error.ValueOutOfRange;
                }
                var bytes: [8]u8 = undefined;
                std.mem.writeInt(u64, &bytes, @bitCast(n), .little);
                try out.appendSlice(gpa, bytes[0..d.unit]);
            },
        };
    }
};
