//! A typed spot in memory, looked up by name at runtime in a `.sal` schema.

const Ref = @This();

const std = @import("std");

const Address = @import("tuft_mem").Address;
const Memory = @import("tuft_mem").Memory;
const Schema = @import("salamander_schema").Schema;
const Prim = Schema.Prim;
const Type = Schema.Ref;

schema: *const Schema,
type: Type,
address: Address,
/// Which bits of the int at `address` are ours, for bitfield members.
bits: ?Bits = null,

pub const Bits = struct {
    shift: u16,
    width: u16,
    backing: Prim,
};

pub const Value = union(enum) {
    int: i64,
    uint: u64,
    float: f64,
    bool: bool,
    pointer: u64,
    @"enum": Enum,

    pub const Enum = struct {
        value: i64,
        name: ?[]const u8 = null,
    };

    pub fn format(self: Value, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .int => |v| try w.print("{d}", .{v}),
            .uint => |v| try w.print("{d}", .{v}),
            .float => |v| try w.print("{d}", .{v}),
            .bool => |v| try w.print("{}", .{v}),
            .pointer => |v| try w.print("0x{x}", .{v}),
            .@"enum" => |e| if (e.name) |n| try w.print(".{s}", .{n}) else try w.print("{d}", .{e.value}),
        }
    }
};

const byte: Type = .{ .prim = .u8 };

pub fn at(schema: *const Schema, t: Type, address: anytype) Ref {
    return .{ .schema = schema, .type = t, .address = Address.from(address) };
}

/// A named type's, like `Player`.
pub fn of(schema: *const Schema, type_name: []const u8, address: anytype) Ref {
    return at(schema, .{ .named = type_name }, address);
}

fn failed(self: Ref, err: anyerror) Ref {
    return .{ .schema = self.schema, .type = self.type, .address = .{ .state = .{ .err = err }, .memory = self.address.memory } };
}

fn moved(self: Ref, t: Type, addr: usize) Ref {
    return .{ .schema = self.schema, .type = t, .address = .{ .state = .{ .ok = addr }, .memory = self.address.memory } };
}

/// Null for primitives, pointers and arrays.
pub fn named(self: Ref) ?*const Schema.Type {
    return switch (self.type) {
        .named => |n| self.schema.findType(n),
        else => null,
    };
}

/// A bitfield member's is its backing int's size.
pub fn size(self: Ref) error{Unsized}!usize {
    if (self.bits) |b| return b.backing.size(self.schema.pointer_size);
    return self.schema.sizeOf(self.type) orelse error.Unsized;
}

/// Also looks through pointers and into bitfields.
pub fn field(self: Ref, name: []const u8) Ref {
    if (self.bits != null) return self.failed(error.NotAStruct);
    const r = if (self.type == .pointer) self.deref() else self;
    const addr = r.address.unwrap() catch return r;
    const t = r.named() orelse return r.failed(error.NotAStruct);
    switch (t.kind) {
        .@"struct", .@"union" => {
            const f = self.schema.findField(t, name) orelse return r.failed(error.NoSuchField);
            return r.moved(sizedField(self.schema, t, f, r.address.memory, addr), addr + f.offset);
        },
        .bitfield => |bf| {
            const b = Schema.findBits(t, name) orelse return r.failed(error.NoSuchField);
            var out = r.moved(switch (b.type) {
                .bool => .{ .prim = .bool },
                .uint => .{ .prim = bf.backing },
                .@"enum" => |n| .{ .named = n },
            }, addr);
            out.bits = .{ .shift = b.bit, .width = b.bits, .backing = bf.backing };
            return out;
        },
        else => return r.failed(error.NotAStruct),
    }
}

/// A `T[count]` array is as long as `count` says now, read from the struct at `base`. Anything
/// else is as it's written. One whose count can't be read is empty.
pub fn sizedField(schema: *const Schema, in: *const Schema.Type, f: Schema.Field, memory: Memory, base: usize) Type {
    if (f.type != .array) return f.type;
    const a = f.type.array;
    const name = a.count orelse return f.type;
    const empty: Type = .{ .array = a.sized(0) };
    const count = schema.findField(in, name) orelse return empty;
    const p = if (count.type == .prim) count.type.prim else return empty;
    const n = p.size(schema.pointer_size);
    if (n > 8) return empty;
    var bytes: [8]u8 = @splat(0);
    memory.read(base + count.offset, bytes[0..n]) catch return empty;
    const raw = std.mem.readInt(u64, &bytes, .little);
    const len: u64 = if (p.isSigned()) @intCast(@max(signExtend(raw, n), 0)) else raw;
    return .{ .array = a.sized(@intCast(@min(len, max_count))) };
}

/// A count read as more than this is this.
pub const max_count = 1 << 20;

pub fn deref(self: Ref) Ref {
    if (self.bits != null) return self.failed(error.NotAPointer);
    const child: Type = switch (self.type) {
        .pointer => |c| c.*,
        .optional => |o| if (o.* == .pointer) o.pointer.* else return self.failed(error.NotAPointer),
        .prim => |p| if (p == .cstring) .{ .prim = .utf8 } else return self.failed(error.NotAPointer),
        else => return self.failed(error.NotAPointer),
    };
    const p = self.loadPointer(self.address.unwrap() catch return self) catch |err| return self.failed(err);
    if (p == 0) return self.failed(error.NullPointer);
    return self.moved(child, p);
}

/// On a pointer it's C's `p[i]`.
pub fn index(self: Ref, i: usize) Ref {
    if (self.bits != null) return self.failed(error.NotAnArray);
    switch (self.type) {
        .array => |a| {
            if (i >= a.len) return self.failed(error.OutOfBounds);
            const addr = self.address.unwrap() catch return self;
            return self.moved(a.child.*, addr + i * (self.schema.sizeOf(a.child.*) orelse return self.failed(error.Unsized)));
        },
        .pointer, .optional => {
            const first = self.deref();
            const addr = first.address.unwrap() catch return first;
            return self.moved(first.type, addr + i * (self.schema.sizeOf(first.type) orelse return self.failed(error.Unsized)));
        },
        else => return self.failed(error.NotAnArray),
    }
}

/// Like `target.pos.x`, `items[2].name` or `target.*`.
pub fn path(self: Ref, steps: []const u8) Ref {
    var r = self;
    var rest = steps;
    while (rest.len > 0) {
        switch (rest[0]) {
            '.' => rest = rest[1..],
            '[' => {
                const close = std.mem.indexOfScalar(u8, rest, ']') orelse return r.failed(error.InvalidPath);
                const i = parseInt(std.mem.trim(u8, rest[1..close], " ")) orelse return r.failed(error.InvalidPath);
                r = r.index(i);
                rest = rest[close + 1 ..];
            },
            '*' => {
                r = r.deref();
                rest = rest[1..];
            },
            else => {
                const end = std.mem.indexOfAny(u8, rest, ".[") orelse rest.len;
                r = r.field(rest[0..end]);
                rest = rest[end..];
            },
        }
    }
    return r;
}

pub fn vfunc(self: Ref, name: []const u8) Address {
    const r = if (self.type == .pointer) self.deref() else self;
    const addr = r.address.unwrap() catch return r.address;
    const t = r.named() orelse return r.failed(error.NotAStruct).address;
    // `[Virtual(n)]`'s `n`, from `t` or its bases
    const m = self.schema.methodOf(t, name) orelse return r.failed(error.NoSuchFunction).address;
    const i = m.method.virtual orelse return r.failed(error.NoSuchFunction).address;
    const vtable = r.loadPointer(addr) catch |err| return r.failed(err).address;
    const f = r.loadPointer(vtable + i * self.schema.pointer_size) catch |err| return r.failed(err).address;
    return r.moved(self.type, f).address;
}

/// Structs, unions and arrays have no value. Walk their fields instead.
pub fn load(self: Ref) !Value {
    const addr = try self.address.unwrap();
    const ps = self.schema.pointer_size;
    if (self.bits) |b| {
        const raw = try self.readUint(addr, b.backing.size(ps));
        const v = (raw >> @intCast(b.shift)) & mask(b.width);
        if (self.type == .prim and self.type.prim == .bool) return .{ .bool = v != 0 };
        if (self.named()) |t| return .{ .@"enum" = .{ .value = @intCast(v), .name = Schema.enumName(t, v) } };
        return .{ .uint = v };
    }
    switch (self.type) {
        .prim => |p| return self.loadPrim(addr, p),
        .pointer, .optional => {
            if (!isPointer(self.type)) return error.NotAValue;
            return .{ .pointer = try self.readUint(addr, ps) };
        },
        .named => |n| {
            const t = self.schema.findType(n) orelse return error.UnknownType;
            switch (t.kind) {
                .@"enum" => |e| {
                    const v = switch (try self.loadPrim(addr, e.backing)) {
                        .int => |i| i,
                        .uint => |u| std.math.cast(i64, u) orelse return error.Overflow,
                        else => unreachable,
                    };
                    return .{ .@"enum" = .{ .value = v, .name = Schema.enumName(t, v) } };
                },
                .bitfield => |b| return .{ .uint = try self.readUint(addr, b.backing.size(ps)) },
                else => return error.NotAValue,
            }
        },
        else => return error.NotAValue,
    }
}

fn loadPrim(self: Ref, addr: usize, p: Prim) !Value {
    const n = p.size(self.schema.pointer_size);
    if (n > 8) return error.NotAValue;
    const raw = try self.readUint(addr, n);
    return switch (p) {
        .f32 => .{ .float = @as(f32, @bitCast(@as(u32, @truncate(raw)))) },
        .f64 => .{ .float = @bitCast(raw) },
        .bool => .{ .bool = raw != 0 },
        .cstring => .{ .pointer = raw },
        .void => error.NotAValue,
        else => if (p.isSigned()) .{ .int = signExtend(raw, n) } else .{ .uint = raw },
    };
}

/// Ints that don't fit give `error.Overflow`.
pub fn store(self: Ref, value: Value) !void {
    const addr = try self.address.unwrap();
    const ps = self.schema.pointer_size;
    if (self.bits) |b| {
        const n = b.backing.size(ps);
        const v: u64 = if (self.type == .prim and self.type.prim == .bool)
            @intFromBool(try asBool(value))
        else
            std.math.cast(u64, try asInt(value)) orelse return error.Overflow;
        if (v > mask(b.width)) return error.Overflow;
        const raw = try self.readUint(addr, n);
        const m = mask(b.width) << @intCast(b.shift);
        return self.writeUint(addr, n, (raw & ~m) | (v << @intCast(b.shift)));
    }
    switch (self.type) {
        .prim => |p| return self.storePrim(addr, p, value),
        .pointer, .optional => {
            if (!isPointer(self.type)) return error.NotAValue;
            const p = std.math.cast(u64, try asInt(value)) orelse return error.Overflow;
            if (ps < 8 and p >> @intCast(ps * 8) != 0) return error.Overflow;
            return self.writeUint(addr, ps, p);
        },
        .named => |n| {
            const t = self.schema.findType(n) orelse return error.UnknownType;
            return switch (t.kind) {
                .@"enum" => |e| self.storePrim(addr, e.backing, .{ .int = std.math.cast(i64, try asInt(value)) orelse return error.Overflow }),
                .bitfield => |b| self.storePrim(addr, b.backing, value),
                else => error.NotAValue,
            };
        },
        else => return error.NotAValue,
    }
}

fn storePrim(self: Ref, addr: usize, p: Prim, value: Value) !void {
    const n = p.size(self.schema.pointer_size);
    if (n > 8) return error.NotAValue;
    const raw: u64 = switch (p) {
        .f32 => @as(u32, @bitCast(@as(f32, @floatCast(try asFloat(value))))),
        .f64 => @bitCast(try asFloat(value)),
        .bool => @intFromBool(try asBool(value)),
        .void => return error.NotAValue,
        else => raw: {
            const v = try asInt(value);
            const bits: u7 = @intCast(n * 8);
            if (p.isSigned()) {
                const half = @as(i128, 1) << @intCast(bits - 1);
                if (v < -half or v >= half) return error.Overflow;
            } else if (v < 0 or v >= @as(i128, 1) << bits) return error.Overflow;
            break :raw @truncate(@as(u128, @bitCast(v)));
        },
    };
    return self.writeUint(addr, n, raw);
}

/// UTF-8 into `buf`, cut short. Works on `utf8`/`utf16` arrays and string pointers.
pub fn text(self: Ref, buf: []u8) ![]const u8 {
    if (self.bits != null) return error.NotText;
    const addr = try self.address.unwrap();
    var start = addr;
    var limit: usize = std.math.maxInt(usize);
    const unit: Type = switch (self.type) {
        .array => |a| unit: {
            limit = a.len;
            break :unit a.child.*;
        },
        .pointer, .optional, .prim => unit: {
            if (self.type == .prim and self.type.prim != .cstring) return error.NotText;
            const c = self.deref();
            if (c.address.state == .err) return c.address.state.err;
            start = c.address.state.ok;
            break :unit c.type;
        },
        else => return error.NotText,
    };
    const wide = switch (unit) {
        .prim => |p| switch (p) {
            .utf8 => false,
            .utf16 => true,
            else => return error.NotText,
        },
        else => return error.NotText,
    };

    var len: usize = 0;
    var pending_high: ?u16 = null;
    var i: usize = 0;
    while (i < limit and len < buf.len) : (i += 1) {
        if (!wide) {
            const c: u8 = @intCast(try self.readUint(start + i, 1));
            if (c == 0) break;
            buf[len] = c;
            len += 1;
            continue;
        }
        const u: u16 = @intCast(try self.readUint(start + i * 2, 2));
        if (u == 0) break;
        var cp: u21 = u;
        if (std.unicode.utf16IsHighSurrogate(u)) {
            pending_high = u;
            continue;
        }
        if (std.unicode.utf16IsLowSurrogate(u)) {
            cp = if (pending_high) |h| std.unicode.utf16DecodeSurrogatePair(&.{ h, u }) catch 0xFFFD else 0xFFFD;
        } else if (pending_high != null) {
            cp = 0xFFFD;
        }
        pending_high = null;
        var enc: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &enc) catch std.unicode.utf8Encode(0xFFFD, &enc) catch unreachable;
        if (len + n > buf.len) break;
        @memcpy(buf[len..][0..n], enc[0..n]);
        len += n;
    }
    return buf[0..len];
}

fn loadPointer(self: Ref, addr: usize) !usize {
    return std.math.cast(usize, try self.readUint(addr, self.schema.pointer_size)) orelse error.InvalidAddress;
}

fn readUint(self: Ref, addr: usize, n: usize) !u64 {
    var bytes: [8]u8 = @splat(0);
    self.address.memory.read(addr, bytes[0..n]) catch return error.InvalidPointer;
    return std.mem.readInt(u64, &bytes, .little);
}

fn writeUint(self: Ref, addr: usize, n: usize, value: u64) !void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    self.address.memory.write(addr, bytes[0..n]) catch return error.InvalidPointer;
}

fn mask(width: u16) u64 {
    return if (width >= 64) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(width)) - 1;
}

fn signExtend(raw: u64, n: usize) i64 {
    const shift: u6 = @intCast(64 - n * 8);
    return @as(i64, @bitCast(raw << shift)) >> shift;
}

fn asInt(value: Value) !i128 {
    return switch (value) {
        .int => |v| v,
        .uint => |v| v,
        .pointer => |v| v,
        .bool => |v| @intFromBool(v),
        .@"enum" => |e| e.value,
        .float => error.TypeMismatch,
    };
}

fn asFloat(value: Value) !f64 {
    return switch (value) {
        .float => |v| v,
        .int => |v| @floatFromInt(v),
        .uint => |v| @floatFromInt(v),
        else => error.TypeMismatch,
    };
}

fn asBool(value: Value) !bool {
    return switch (value) {
        .bool => |v| v,
        .int, .uint => (try asInt(value)) != 0,
        else => error.TypeMismatch,
    };
}

/// A thin pointer, plain or optional.
fn isPointer(t: Type) bool {
    return t == .pointer or (t == .optional and t.optional.* == .pointer);
}

/// Decimal, or hex with `0x`.
fn parseInt(digits: []const u8) ?usize {
    if (std.mem.startsWith(u8, digits, "0x") or std.mem.startsWith(u8, digits, "0X"))
        return std.fmt.parseInt(usize, digits[2..], 16) catch null;
    return std.fmt.parseInt(usize, digits, 10) catch null;
}
