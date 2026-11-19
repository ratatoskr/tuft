//! x86/x64 instruction decoding with Zydis.

const std = @import("std");
const builtin = @import("builtin");

const zydis = @import("zydis");

const is64 = builtin.cpu.arch == .x86_64;

pub const DecodedInsn = struct {
    len: u8,
    /// Absolute target of an IP-relative branch or operand.
    rel_target: ?usize,
    disp_offset: u8,
    /// 0 if not IP-relative.
    disp_size: u8,
    branch: bool,
    /// Only legacy encodings have one, VEX and EVEX are `.other`.
    map: Map,
    opcode: u8,
    modrm: ?ModRm,
    /// x64 only.
    rex: ?Rex,

    pub const Map = enum { primary, @"0F", other };
    pub const ModRm = struct { mod: u2, reg: u3, rm: u3 };
    pub const Rex = struct { w: bool, r: bool, x: bool, b: bool };

    pub fn isIpRelativeOperand(self: *const DecodedInsn) bool {
        return self.rel_target != null and !self.branch;
    }

    pub fn is(self: *const DecodedInsn, map: Map, opcode: u8) bool {
        return self.map == map and self.opcode == opcode;
    }

    /// Any `call`: relative, through a register or memory, or far.
    pub fn isCall(self: *const DecodedInsn) bool {
        if (self.map != .primary) return false;
        return switch (self.opcode) {
            0xE8, 0x9A => true,
            0xFF => if (self.modrm) |m| m.reg == 2 or m.reg == 3 else false,
            else => false,
        };
    }
};

const Decoded = struct {
    insn: zydis.ZydisDecodedInstruction,
    operands: [zydis.ZYDIS_MAX_OPERAND_COUNT]zydis.ZydisDecodedOperand,
};

fn disassemble(addr: usize, out: *Decoded) error{DisassemblyFailed}!void {
    // Zydis stops at the instruction end, so max length is safe at a page end
    return disassembleBytes(@as([*]const u8, @ptrFromInt(addr))[0..zydis.ZYDIS_MAX_INSTRUCTION_LENGTH], out);
}

fn disassembleBytes(bytes: []const u8, out: *Decoded) error{DisassemblyFailed}!void {
    var decoder: zydis.ZydisDecoder = undefined;
    const mode = if (is64) zydis.ZYDIS_MACHINE_MODE_LONG_64 else zydis.ZYDIS_MACHINE_MODE_LEGACY_32;
    const stack = if (is64) zydis.ZYDIS_STACK_WIDTH_64 else zydis.ZYDIS_STACK_WIDTH_32;
    if (failed(zydis.ZydisDecoderInit(&decoder, mode, stack))) return error.DisassemblyFailed;
    const status = zydis.ZydisDecoderDecodeFull(&decoder, bytes.ptr, bytes.len, &out.insn, &out.operands);
    if (failed(status)) return error.DisassemblyFailed;
}

fn failed(status: zydis.ZyanStatus) bool {
    return (status & 0x80000000) != 0;
}

const Reference = struct {
    target: usize,
    kind: enum {
        branch,
        ip_relative,
        /// x64 with a 0x67 prefix, wraps at 4 GB
        eip_relative,
        /// `[disp]` with no base or index, moffs too
        absolute,
    },
    offset: u8,
    size: u8,
};

fn reference(d: *const Decoded, instruction: usize) ?Reference {
    const next = instruction + d.insn.length;
    for (d.operands[0..d.insn.operand_count]) |*op| {
        switch (op.type) {
            zydis.ZYDIS_OPERAND_TYPE_IMMEDIATE => {
                const imm = &op.unnamed_0.imm;
                if (imm.is_relative == 0) continue;
                return .{
                    .target = next +% signed(imm.value.s),
                    .kind = .branch,
                    .offset = imm.offset,
                    .size = imm.size / 8,
                };
            },
            zydis.ZYDIS_OPERAND_TYPE_MEMORY => {
                const mem = &op.unnamed_0.mem;
                var r: Reference = .{ .target = undefined, .kind = undefined, .offset = mem.disp.offset, .size = mem.disp.size / 8 };
                switch (mem.base) {
                    zydis.ZYDIS_REGISTER_RIP => {
                        r.kind = .ip_relative;
                        r.target = next +% signed(mem.disp.value);
                    },
                    zydis.ZYDIS_REGISTER_EIP => {
                        r.kind = .eip_relative;
                        r.target = @as(u32, @truncate(next +% signed(mem.disp.value)));
                    },
                    zydis.ZYDIS_REGISTER_NONE => {
                        if (mem.index != zydis.ZYDIS_REGISTER_NONE) continue;
                        r.kind = .absolute;
                        const disp: u64 = @bitCast(mem.disp.value);
                        r.target = switch (d.insn.address_width) {
                            16 => @as(u16, @truncate(disp)),
                            32 => @as(u32, @truncate(disp)),
                            else => @intCast(disp),
                        };
                    },
                    else => continue,
                }
                return r;
            },
            else => {},
        }
    }
    return null;
}

fn signed(value: i64) usize {
    return @bitCast(@as(isize, @truncate(value)));
}

pub fn decode(instruction: usize) !DecodedInsn {
    var d: Decoded = undefined;
    try disassemble(instruction, &d);
    return described(&d, instruction);
}

/// Like `decode`, from a copy of the bytes at `address`, like code with a breakpoint's `int3` taken out.
pub fn decodeBytes(bytes: []const u8, address: usize) !DecodedInsn {
    var d: Decoded = undefined;
    try disassembleBytes(bytes, &d);
    return described(&d, address);
}

fn described(d: *Decoded, instruction: usize) !DecodedInsn {
    const z = &d.insn;
    const legacy = z.encoding == zydis.ZYDIS_INSTRUCTION_ENCODING_LEGACY;
    var out: DecodedInsn = .{
        .len = z.length,
        .rel_target = null,
        .disp_offset = 0,
        .disp_size = 0,
        .branch = false,
        .map = if (!legacy)
            .other
        else if (z.opcode_map == zydis.ZYDIS_OPCODE_MAP_DEFAULT)
            .primary
        else if (z.opcode_map == zydis.ZYDIS_OPCODE_MAP_0F)
            .@"0F"
        else
            .other,
        .opcode = z.opcode,
        .modrm = if ((z.attributes & zydis.ZYDIS_ATTRIB_HAS_MODRM) != 0)
            .{ .mod = @intCast(z.raw.modrm.mod), .reg = @intCast(z.raw.modrm.reg), .rm = @intCast(z.raw.modrm.rm) }
        else
            null,
        .rex = if ((z.attributes & zydis.ZYDIS_ATTRIB_HAS_REX) != 0) rex: {
            const rex = &z.raw.unnamed_0.rex;
            break :rex .{ .w = rex.W != 0, .r = rex.R != 0, .x = rex.X != 0, .b = rex.B != 0 };
        } else null,
    };

    if (reference(d, instruction)) |r| switch (r.kind) {
        .branch, .ip_relative => {
            out.rel_target = r.target;
            out.disp_offset = r.offset;
            out.disp_size = r.size;
            out.branch = r.kind == .branch;
        },
        // Relocating these would need the target below 4 GB
        .eip_relative => return error.UnsupportedRelativeOperand,
        .absolute => {},
    };
    return out;
}

/// Where an instruction's operand values sit and where it goes next, for signatures that leave
/// out what changes between builds.
pub const Layout = struct {
    len: u8,
    /// The displacement and immediates, in no particular order.
    fields: [3]Field = undefined,
    fields_len: u8 = 0,
    flow: Flow = .next,

    pub const Field = struct { offset: u8, len: u8 };
    pub const Flow = enum { next, call, jump, conditional, ret, trap };

    pub fn values(self: *const Layout) []const Field {
        return self.fields[0..self.fields_len];
    }

    fn add(self: *Layout, offset: u8, bits: u8) void {
        if (bits == 0) return;
        self.fields[self.fields_len] = .{ .offset = offset, .len = bits / 8 };
        self.fields_len += 1;
    }
};

pub fn layoutOf(bytes: []const u8) !Layout {
    var d: Decoded = undefined;
    try disassembleBytes(bytes, &d);
    const z = &d.insn;
    var out: Layout = .{ .len = z.length };
    out.add(z.raw.disp.offset, z.raw.disp.size);
    for (z.raw.imm) |imm| out.add(imm.offset, imm.size);
    const category = z.meta.category;
    out.flow = if (category == zydis.ZYDIS_CATEGORY_CALL)
        .call
    else if (category == zydis.ZYDIS_CATEGORY_UNCOND_BR)
        .jump
    else if (category == zydis.ZYDIS_CATEGORY_COND_BR)
        .conditional
    else if (category == zydis.ZYDIS_CATEGORY_RET)
        .ret
    else if (z.mnemonic == zydis.ZYDIS_MNEMONIC_INT3)
        .trap
    else
        .next;
    return out;
}

/// Null if it doesn't point at static memory or a branch target.
pub fn toStaticAddress(instruction: usize) !?usize {
    return try getAddressCore(.absolute, instruction);
}

/// From the start of the instruction.
pub fn toInstructionDelta(instruction: usize) !?isize {
    const res = try getAddressCore(.start_of_insn, instruction) orelse return null;
    return @bitCast(res);
}

/// From the next instruction, what the CPU adds. Use when re-encoding branches.
pub fn toHardwareOffset(instruction: usize) !?isize {
    const res = try getAddressCore(.end_of_insn, instruction) orelse return null;
    return @bitCast(res);
}

/// Returns `address` if it isn't a relative jmp, call or jcc.
pub fn resolveControlFlowTarget(address: usize) !usize {
    var d: Decoded = undefined;
    disassemble(address, &d) catch return address;
    const r = reference(&d, address) orelse return address;
    return if (r.kind == .branch) r.target else address;
}

/// Copy this many bytes for the `...Of` functions.
pub const max_len = zydis.ZYDIS_MAX_INSTRUCTION_LENGTH;

/// For bytes copied from `address`, like from another process.
pub fn toStaticAddressOf(bytes: []const u8, address: usize) !?usize {
    var d: Decoded = undefined;
    try disassembleBytes(bytes, &d);
    return (reference(&d, address) orelse return null).target;
}

pub fn resolveControlFlowTargetOf(bytes: []const u8, address: usize) usize {
    var d: Decoded = undefined;
    disassembleBytes(bytes, &d) catch return address;
    const r = reference(&d, address) orelse return address;
    return if (r.kind == .branch) r.target else address;
}

fn getAddressCore(comptime ref: ReferencePoint, instruction: usize) !?usize {
    var d: Decoded = undefined;
    try disassemble(instruction, &d);
    const target_addr = (reference(&d, instruction) orelse return null).target;

    return switch (ref) {
        .absolute => target_addr,
        .start_of_insn => target_addr -% instruction,
        .end_of_insn => target_addr -% (instruction + d.insn.length),
    };
}

const ReferencePoint = enum {
    absolute,
    start_of_insn,
    end_of_insn,
};

const tests = struct {
    const testing = std.testing;

    fn at(code: []const u8) usize {
        return @intFromPtr(code.ptr);
    }

    test "layout of operand values and flow" {
        // mov dword ptr [rcx+0x48], 0x1337: disp8 then imm32, same bytes on x86 and x64
        const mov = try layoutOf(&.{ 0xC7, 0x41, 0x48, 0x37, 0x13, 0x00, 0x00 });
        try testing.expectEqual(7, mov.len);
        try testing.expectEqual(.next, mov.flow);
        var masked: [7]bool = @splat(false);
        for (mov.values()) |f| for (f.offset..f.offset + f.len) |i| {
            masked[i] = true;
        };
        try testing.expectEqualSlices(bool, &.{ false, false, true, true, true, true, true }, &masked);

        try testing.expectEqual(.call, (try layoutOf(&.{ 0xE8, 0, 0, 0, 0 })).flow);
        try testing.expectEqual(.conditional, (try layoutOf(&.{ 0x74, 0x01 })).flow);
        try testing.expectEqual(.jump, (try layoutOf(&.{ 0xEB, 0x01 })).flow);
        try testing.expectEqual(.ret, (try layoutOf(&.{0xC3})).flow);
        try testing.expectEqual(.trap, (try layoutOf(&.{0xCC})).flow);
        try testing.expectEqual(0, (try layoutOf(&.{ 0x31, 0xC0 })).fields_len);
    }

    test "short forward jump" {
        // jz +1, nop, ret
        const code = [_]u8{ 0x74, 0x01, 0x90, 0xC3 };
        const base = at(&code);
        try testing.expectEqual(3, (try toInstructionDelta(base)).?);
        try testing.expectEqual(1, (try toHardwareOffset(base)).?);

        const d = try decode(base);
        try testing.expectEqual(2, d.len);
        try testing.expectEqual(base + 3, d.rel_target);
        try testing.expectEqual(1, d.disp_offset);
        try testing.expectEqual(1, d.disp_size);
        try testing.expect(!d.isIpRelativeOperand());
    }

    test "short backward jump" {
        // nop, jz -3, ret
        const code = [_]u8{ 0x90, 0x74, 0xFD, 0xC3 };
        const base = at(&code) + 1;
        try testing.expectEqual(-1, (try toInstructionDelta(base)).?);
        try testing.expectEqual(-3, (try toHardwareOffset(base)).?);
    }

    test "near call" {
        // call +1, nop, ret
        const code = [_]u8{ 0xE8, 0x01, 0x00, 0x00, 0x00, 0x90, 0xC3 };
        const base = at(&code);
        const d = try decode(base);
        try testing.expectEqual(5, d.len);
        try testing.expectEqual(base + 6, d.rel_target);
        try testing.expectEqual(1, d.disp_offset);
        try testing.expectEqual(4, d.disp_size);
        try testing.expectEqual(base + 6, try resolveControlFlowTarget(base));
    }

    test "no memory references" {
        // xor eax, eax, mov eax, 0x1337
        const code = [_]u8{ 0x31, 0xC0, 0xB8, 0x37, 0x13, 0x00, 0x00 };
        const base = at(&code);
        try testing.expectEqual(null, try toStaticAddress(base));
        const d = try decode(base);
        try testing.expectEqual(2, d.len);
        try testing.expectEqual(null, d.rel_target);
        try testing.expectEqual(base + 2, try resolveControlFlowTarget(base + 2));
    }

    test "x64 RIP-relative operands" {
        if (!is64) return error.SkipZigTest;
        // mov rax, [rip + 5]
        const mov = [_]u8{ 0x48, 0x8B, 0x05, 0x05, 0x00, 0x00, 0x00 };
        const d = try decode(at(&mov));
        try testing.expectEqual(7, d.len);
        try testing.expectEqual(at(&mov) + 12, d.rel_target);
        try testing.expectEqual(3, d.disp_offset);
        try testing.expect(d.isIpRelativeOperand());

        // cmp dword ptr [rip + 8], 0x2A
        const cmp = [_]u8{ 0x83, 0x3D, 0x08, 0x00, 0x00, 0x00, 0x2A };
        const c = try decode(at(&cmp));
        try testing.expectEqual(at(&cmp) + 15, c.rel_target);
        try testing.expectEqual(2, c.disp_offset);
    }

    test "x64 moffs move" {
        if (!is64) return error.SkipZigTest;
        // mov rax, [0x1122334455667788]
        const code = [_]u8{ 0x48, 0xA1, 0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11 };
        try testing.expectEqual(0x1122334455667788, (try toStaticAddress(at(&code))).?);
    }

    test "x86 absolute operands" {
        if (is64) return error.SkipZigTest;
        // mov eax, [0x12345678]
        const modrm = [_]u8{ 0x8B, 0x05, 0x78, 0x56, 0x34, 0x12 };
        const d = try decode(at(&modrm));
        try testing.expectEqual(6, d.len);
        try testing.expectEqual(null, d.rel_target);
        try testing.expectEqual(0x12345678, (try toStaticAddress(at(&modrm))).?);

        // mov eax, moffs32
        const moffs = [_]u8{ 0xA1, 0x78, 0x56, 0x34, 0x12 };
        try testing.expectEqual(0x12345678, (try toStaticAddress(at(&moffs))).?);
    }

    test "VEX lengths and LES/LDS" {
        const vex = [_]struct { code: []const u8, len: u8 }{
            .{ .code = &.{ 0xC5, 0xF8, 0x28, 0xC1 }, .len = 4 }, // vmovaps xmm0, xmm1
            .{ .code = &.{ 0xC5, 0xFC, 0x58, 0x45, 0x08 }, .len = 5 }, // vaddps ymm0, ymm0, [ebp/rbp + 8]
            .{ .code = &.{ 0xC4, 0xE3, 0x79, 0x0F, 0xC1, 0x04 }, .len = 6 }, // vpalignr xmm0, xmm0, xmm1, 4
        };
        for (vex) |c| try testing.expectEqual(c.len, (try decode(at(c.code))).len);

        if (!is64) {
            const lds = [_]u8{ 0xC5, 0x06 }; // lds eax, [esi]
            try testing.expectEqual(2, (try decode(at(&lds))).len);
        }
    }

    test "x86 targets wrap" {
        if (is64) return error.SkipZigTest;
        // jmp rel32 to 0x10
        var code = [_]u8{ 0xE9, 0, 0, 0, 0 };
        const base = at(&code);
        std.mem.writeInt(u32, code[1..5], @as(u32, 0x10) -% @as(u32, @intCast(base + 5)), .little);
        try testing.expectEqual(0x10, (try decode(base)).rel_target);
    }
};

test {
    _ = tests;
}
