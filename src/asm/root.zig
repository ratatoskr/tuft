//! x86/x64 assembly and disassembly in Intel syntax.

const std = @import("std");
const builtin = @import("builtin");

const zydis = @import("zydis");
const Message = @import("tuft_text").Message;

pub const disasm = @import("disasm.zig");
pub const Block = @import("Block.zig");
const names = @import("names.zig");
const encoding = @import("encode.zig");
const parse = @import("parse.zig");

pub const is64 = builtin.cpu.arch == .x86_64;
pub const machine_mode = if (is64) zydis.ZYDIS_MACHINE_MODE_LONG_64 else zydis.ZYDIS_MACHINE_MODE_LEGACY_32;
pub const max_operands = zydis.ZYDIS_ENCODER_MAX_OPERANDS;
pub const max_len = disasm.max_len;

pub const Error = error{
    OutOfMemory,
    InvalidSyntax,
    UnknownMnemonic,
    /// Not a label and the resolver doesn't know it
    UnknownName,
    DuplicateLabel,
    CannotEncode,
    /// Like `db 300`
    ValueOutOfRange,
    /// Shouldn't happen
    LayoutDidNotSettle,
    /// AVX-512 broadcasts and rounding, for now
    Unsupported,
    /// Doesn't fit where it's going
    TooLong,
};

/// Line 0 means a Zig-built block.
pub const Diagnostic = struct {
    line: u32 = 0,
    text: Message(200) = .{},

    pub fn message(self: *const Diagnostic) []const u8 {
        return self.text.message();
    }

    pub fn set(self: ?*Diagnostic, line: u32, comptime fmt: []const u8, args: anytype) void {
        const d = self orelse return;
        d.line = line;
        d.text.print(fmt, args);
    }
};

/// Looks up names that aren't labels.
pub const Resolver = struct {
    context: ?*anyopaque = null,
    resolve: *const fn (context: ?*anyopaque, name: []const u8) ?usize,
};

pub const Register = struct {
    id: zydis.ZydisRegister,

    /// Checked at compile time.
    pub fn named(comptime name: []const u8) Register {
        return .{ .id = @field(zydis, "ZYDIS_REGISTER_" ++ upper(name)) };
    }

    pub fn parse(name: []const u8) ?Register {
        return .{ .id = @intCast(names.find(names.registers, name) orelse return null) };
    }

    pub fn bits(self: Register) u16 {
        return zydis.ZydisRegisterGetWidth(machine_mode, self.id);
    }

    pub fn text(self: Register) [:0]const u8 {
        return std.mem.span(@as([*:0]const u8, @ptrCast(zydis.ZydisRegisterGetString(self.id))));
    }

    pub fn eql(self: Register, other: Register) bool {
        return self.id == other.id;
    }
};

pub const Mnemonic = struct {
    id: zydis.ZydisMnemonic,

    /// Checked at compile time.
    pub fn named(comptime name: []const u8) Mnemonic {
        const id = comptime blk: {
            var buf: [32]u8 = undefined;
            const canonical = names.canonical(name, &buf) orelse @compileError("no mnemonic " ++ name);
            break :blk @field(zydis, "ZYDIS_MNEMONIC_" ++ upper(canonical));
        };
        return .{ .id = id };
    }

    pub fn parse(name: []const u8) ?Mnemonic {
        return .{ .id = @intCast(names.findMnemonic(name) orelse return null) };
    }

    pub fn text(self: Mnemonic) [:0]const u8 {
        return std.mem.span(@as([*:0]const u8, @ptrCast(zydis.ZydisMnemonicGetString(self.id))));
    }
};

/// Names get looked up when assembling.
pub const Value = struct {
    name: ?[]const u8 = null,
    offset: i64 = 0,

    pub fn number(n: i64) Value {
        return .{ .offset = n };
    }
};

pub const Mem = struct {
    /// In bytes. 0 means work it out.
    size: u16 = 0,
    segment: ?Register = null,
    base: ?Register = null,
    index: ?Register = null,
    scale: u8 = 1,
    disp: Value = .{},
};

pub const Operand = union(enum) {
    reg: Register,
    imm: Value,
    mem: Mem,
    /// Far jumps and calls on x86
    ptr: Pointer,

    pub const Pointer = struct { segment: u16, offset: u32 };
};

pub const Prefixes = struct {
    lock: bool = false,
    rep: bool = false,
    repe: bool = false,
    repne: bool = false,
    xacquire: bool = false,
    xrelease: bool = false,
    bnd: bool = false,
    notrack: bool = false,
};

pub const Instruction = struct {
    mnemonic: Mnemonic,
    prefixes: Prefixes = .{},
    /// `retf` and far jmp/call
    far: bool = false,
    /// AVX-512 `{k1}`, plus `{z}`
    mask: ?Register = null,
    zeroing: bool = false,
    operands: [max_operands]Operand = undefined,
    operand_count: u8 = 0,

    pub fn ops(self: *const Instruction) []const Operand {
        return self.operands[0..self.operand_count];
    }
};

pub const Encoded = encoding.Encoded;

pub const Options = struct {
    /// Relative jumps and operands are based on it.
    address: usize,
    resolver: ?Resolver = null,
};

pub fn assemble(gpa: std.mem.Allocator, source: []const u8, options: Options, diagnostic: ?*Diagnostic) Error!Block.Code {
    var block: Block = .init(gpa);
    defer block.deinit();
    try block.parse(source, diagnostic);
    return block.assemble(gpa, options, diagnostic);
}

/// Like `assemble`, into `out`. Returns how many bytes.
pub fn assembleInto(gpa: std.mem.Allocator, source: []const u8, out: []u8, options: Options, diagnostic: ?*Diagnostic) Error!usize {
    var code = try assemble(gpa, source, options, diagnostic);
    defer code.deinit(gpa);
    if (code.bytes.len > out.len) {
        Diagnostic.set(diagnostic, 0, "{d} bytes, only room for {d}", .{ code.bytes.len, out.len });
        return error.TooLong;
    }
    @memcpy(out[0..code.bytes.len], code.bytes);
    return code.bytes.len;
}

/// No labels, names go to `options.resolver`.
pub fn assembleOne(text: []const u8, options: Options, diagnostic: ?*Diagnostic) Error!Encoded {
    var insn = try parse.instruction(text, diagnostic);
    try resolveNames(&insn, options.resolver, diagnostic);
    return encodeOrExplain(&insn, options.address, .{}, 1, text, diagnostic);
}

/// Must have no names left.
pub fn encode(insn: *const Instruction, address: usize) Error!Encoded {
    return encoding.encode(insn, address, .{});
}

/// What `expectAt` found instead.
pub const Mismatch = struct {
    /// Which instruction, from 0.
    index: usize = 0,
    want: Message(96) = .{},
    got: Message(96) = .{},

    pub fn expected(self: *const Mismatch) []const u8 {
        return self.want.message();
    }

    /// Empty if it doesn't disassemble.
    pub fn found(self: *const Mismatch) []const u8 {
        return self.got.message();
    }

    fn set(self: *Mismatch, index: usize, want: []const u8, got: []const u8) void {
        self.index = index;
        self.want.set(want);
        self.got.set(got);
    }
};

/// Whether `code` at `address` disassembles to `expected`, like `cmp ecx, eax; cmovl ax, cx`, in any encoding.
/// Returns its length, or null with `mismatch` saying what's there.
pub fn expectAt(gpa: std.mem.Allocator, expected: []const u8, code: []const u8, address: usize, resolver: ?Resolver, diagnostic: ?*Diagnostic, mismatch: *Mismatch) Error!?usize {
    var block: Block = .init(gpa);
    defer block.deinit();
    try block.parse(expected, diagnostic);
    var at: usize = 0;
    var index: usize = 0;
    for (block.items.items) |item| {
        var insn = switch (item.kind) {
            .instruction => |i| i,
            else => {
                Diagnostic.set(diagnostic, item.line, "expect only takes instructions", .{});
                return error.InvalidSyntax;
            },
        };
        try resolveNames(&insn, resolver, diagnostic);
        const encoded = try encodeOrExplain(&insn, address + at, .{}, item.line, null, diagnostic);
        const want = disasm.decode(encoded.slice(), address + at) orelse return error.CannotEncode;
        const got = if (at < code.len) disasm.decode(code[at..], address + at) else null;
        if (got == null or !std.mem.eql(u8, got.?.text(), want.text())) {
            mismatch.set(index, want.text(), if (got) |g| g.text() else "");
            return null;
        }
        at += got.?.len;
        index += 1;
    }
    if (index == 0) {
        Diagnostic.set(diagnostic, 1, "expect has no instructions", .{});
        return error.InvalidSyntax;
    }
    return at;
}

pub fn encodeOrExplain(insn: *const Instruction, address: usize, options: encoding.Options, line: u32, text: ?[]const u8, diagnostic: ?*Diagnostic) Error!Encoded {
    return encoding.encode(insn, address, options) catch |err| {
        if (text) |t| {
            Diagnostic.set(diagnostic, line, "can't encode `{s}`", .{std.mem.trim(u8, t, " \t\r")});
        } else {
            Diagnostic.set(diagnostic, line, "can't encode {s} with those operands", .{insn.mnemonic.text()});
        }
        return err;
    };
}

fn resolveNames(insn: *Instruction, resolver: ?Resolver, diagnostic: ?*Diagnostic) Error!void {
    for (insn.operands[0..insn.operand_count]) |*op| {
        const v: *Value = switch (op.*) {
            .reg, .ptr => continue,
            .imm => |*v| v,
            .mem => |*m| &m.disp,
        };
        const name = v.name orelse continue;
        const r = resolver orelse return parse.unknownName(diagnostic, 1, name);
        const address = r.resolve(r.context, name) orelse return parse.unknownName(diagnostic, 1, name);
        v.* = .{ .offset = @as(i64, @bitCast(@as(u64, address))) +% v.offset };
    }
}

/// `operands` is a tuple of registers, numbers, `ref`s and `mem`s.
pub fn instruction(mnemonic: anytype, operands: anytype) Instruction {
    var insn: Instruction = .{ .mnemonic = Mnemonic.named(@tagName(mnemonic)) };
    const fields = @typeInfo(@TypeOf(operands)).@"struct".field_names;
    if (fields.len > max_operands) @compileError("too many operands");
    inline for (fields, 0..) |field, i| insn.operands[i] = operand(@field(operands, field));
    insn.operand_count = fields.len;
    return insn;
}

/// Every field is optional. `disp` can be a `ref`.
pub fn mem(spec: anytype) Operand {
    const S = @TypeOf(spec);
    var m: Mem = .{};
    if (@hasField(S, "size")) m.size = spec.size;
    if (@hasField(S, "segment")) m.segment = register(spec.segment);
    if (@hasField(S, "base")) m.base = register(spec.base);
    if (@hasField(S, "index")) m.index = register(spec.index);
    if (@hasField(S, "scale")) m.scale = spec.scale;
    if (@hasField(S, "disp")) m.disp = value(spec.disp);
    return .{ .mem = m };
}

pub fn ref(name: []const u8) Value {
    return .{ .name = name };
}

pub fn refOffset(name: []const u8, offset: i64) Value {
    return .{ .name = name, .offset = offset };
}

pub fn operand(x: anytype) Operand {
    const T = @TypeOf(x);
    if (T == Operand) return x;
    if (T == Register) return .{ .reg = x };
    if (T == Mem) return .{ .mem = x };
    if (T == Value) return .{ .imm = x };
    return switch (@typeInfo(T)) {
        .enum_literal => .{ .reg = Register.named(@tagName(x)) },
        .int, .comptime_int => .{ .imm = value(x) },
        else => @compileError("an operand is a register, number, `ref` or `mem`, not " ++ @typeName(T)),
    };
}

fn register(x: anytype) Register {
    if (@TypeOf(x) == Register) return x;
    return Register.named(@tagName(x));
}

fn value(x: anytype) Value {
    const T = @TypeOf(x);
    if (T == Value) return x;
    if (T == comptime_int) {
        return .{ .offset = if (x > std.math.maxInt(i64)) @bitCast(@as(u64, x)) else x };
    }
    const info = @typeInfo(T).int;
    if (info.signedness == .unsigned and info.bits == 64) return .{ .offset = @bitCast(x) };
    return .{ .offset = @intCast(x) };
}

fn upper(comptime s: []const u8) []const u8 {
    return comptime blk: {
        var buf: [s.len]u8 = undefined;
        _ = std.ascii.upperString(&buf, s);
        const final = buf;
        break :blk &final;
    };
}

test {
    _ = disasm;
    _ = names;
    _ = encoding;
    _ = parse;
    _ = Block;
    _ = @import("tests.zig");
}
