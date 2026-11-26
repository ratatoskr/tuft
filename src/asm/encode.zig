//! One instruction to machine code with Zydis. Resolve names first.

const std = @import("std");

const zydis = @import("zydis");

const root = @import("root.zig");
const Instruction = root.Instruction;
const Register = root.Register;

pub const Encoded = struct {
    /// One instruction, or a far branch, which takes a few.
    bytes: [max_encoded]u8,
    len: u8,

    pub fn slice(self: *const Encoded) []const u8 {
        return self.bytes[0..self.len];
    }
};

/// A far `call` or `jcc` on x64.
const max_encoded = @max(root.max_len, 16);

pub const Options = struct {
    /// So a moving label can't shrink it.
    long_branch: bool = false,
};

/// After a register operand's size. Includes x87, FXSAVE and XSAVE areas.
const guessed_sizes = [_]u16{ 4, 8, 1, 2, 16, 32, 64, 10, 6, 0, 28, 14, 108, 94, 512, 576 };

pub fn encode(insn: *const Instruction, address: usize, options: Options) error{CannotEncode}!Encoded {
    return encodeMasked(insn, address, options) catch |err| (farBranch(insn, address) orelse err);
}

fn encodeMasked(insn: *const Instruction, address: usize, options: Options) error{CannotEncode}!Encoded {
    if (insn.mask) |mask| return encodeExact(&withMask(insn, mask), address, options);
    return encodeExact(insn, address, options) catch |err| {
        // EVEX instructions take the mask as the second operand, even k0
        if (insn.operand_count == 0 or insn.operand_count == root.max_operands) return err;
        return encodeExact(&withMask(insn, .named("k0")), address, options);
    };
}

/// An x64 `jmp`, `call` or `jcc` over 2 GB away, through the address stored right after it.
fn farBranch(insn: *const Instruction, address: usize) ?Encoded {
    if (!root.is64 or insn.far or insn.operand_count != 1 or insn.operands[0] != .imm) return null;
    const target = insn.operands[0].imm;
    if (target.name != null) return null;
    const name = insn.mnemonic.text();
    // jmp [rip+0], then the address
    const jmp = [_]u8{ 0xFF, 0x25, 0, 0, 0, 0 };
    var out: Encoded = .{ .bytes = undefined, .len = 0 };
    var at: usize = 0;
    if (std.mem.eql(u8, name, "jmp")) {
        @memcpy(out.bytes[0..jmp.len], &jmp);
        at = jmp.len;
    } else if (std.mem.eql(u8, name, "call")) {
        // call [rip+2] past a jmp over the address
        const call = [_]u8{ 0xFF, 0x15, 2, 0, 0, 0, 0xEB, 8 };
        @memcpy(out.bytes[0..call.len], &call);
        at = call.len;
    } else if (name[0] == 'j') {
        // The opposite short jcc skips the far jmp. A rel8 of 0 to read its opcode
        var short = insn.*;
        short.operands[0] = .{ .imm = .number(@bitCast(@as(u64, address +% 2))) };
        const e = encodeExact(&short, address, .{}) catch return null;
        if (e.len != 2 or e.bytes[0] & 0xF0 != 0x70) return null;
        out.bytes[0] = e.bytes[0] ^ 1;
        out.bytes[1] = jmp.len + 8;
        @memcpy(out.bytes[2..][0..jmp.len], &jmp);
        at = 2 + jmp.len;
    } else return null;
    std.mem.writeInt(u64, out.bytes[at..][0..8], @bitCast(target.offset), .little);
    out.len = @intCast(at + 8);
    return out;
}

fn withMask(insn: *const Instruction, mask: Register) Instruction {
    var out = insn.*;
    if (out.operand_count == root.max_operands) return out;
    var i: usize = out.operand_count;
    while (i > 1) : (i -= 1) out.operands[i] = out.operands[i - 1];
    out.operands[1] = .{ .reg = mask };
    out.operand_count += 1;
    return out;
}

fn encodeExact(insn: *const Instruction, address: usize, options: Options) error{CannotEncode}!Encoded {
    var request = std.mem.zeroes(zydis.ZydisEncoderRequest);
    request.machine_mode = root.machine_mode;
    request.mnemonic = insn.mnemonic.id;
    request.operand_count = insn.operand_count;
    request.prefixes = prefixBits(insn.prefixes);
    if (insn.far) request.branch_type = zydis.ZYDIS_BRANCH_TYPE_FAR;
    request.evex.zeroing_mask = @intFromBool(insn.zeroing);
    // Never a 0x67 prefix for a shorter form
    request.address_size_hint = if (root.is64) zydis.ZYDIS_ADDRESS_SIZE_HINT_64 else zydis.ZYDIS_ADDRESS_SIZE_HINT_32;

    var mem_index: ?usize = null;
    var explicit_rip = false;
    var register_size: u16 = 0;
    for (insn.ops(), 0..) |op, i| {
        const out = &request.operands[i];
        switch (op) {
            .reg => |r| {
                out.type = zydis.ZYDIS_OPERAND_TYPE_REGISTER;
                out.reg.value = r.id;
                if (register_size == 0) register_size = r.bits() / 8;
            },
            .imm => |v| {
                if (v.name != null) return error.CannotEncode;
                out.type = zydis.ZYDIS_OPERAND_TYPE_IMMEDIATE;
                out.imm.s = v.offset;
            },
            .mem => |m| {
                if (m.disp.name != null) return error.CannotEncode;
                out.type = zydis.ZYDIS_OPERAND_TYPE_MEMORY;
                out.mem.base = if (m.base) |r| r.id else zydis.ZYDIS_REGISTER_NONE;
                out.mem.index = if (m.index) |r| r.id else zydis.ZYDIS_REGISTER_NONE;
                out.mem.scale = if (m.index != null) m.scale else 0;
                // x86 addresses wrap at 4 GB and Zydis wants them as signed 32 bits
                out.mem.displacement = if (root.is64) m.disp.offset else @as(i32, @truncate(m.disp.offset));
                out.mem.size = m.size;
                if (m.segment) |s| request.prefixes |= segmentBit(s) orelse return error.CannotEncode;
                if (m.base) |b| explicit_rip = root.is64 and b.eql(.named("rip"));
                mem_index = i;
            },
            .ptr => |p| {
                out.type = zydis.ZYDIS_OPERAND_TYPE_POINTER;
                out.ptr.segment = p.segment;
                out.ptr.offset = p.offset;
            },
        }
    }

    // Zydis wants exact operands, so try options in order and the first that encodes wins
    var sizes_buf: [guessed_sizes.len + 1]u16 = undefined;
    const sizes: []const u16 = sizes: {
        const i = mem_index orelse break :sizes &.{0};
        const m = insn.operands[i].mem;
        if (m.size != 0) break :sizes &.{m.size};
        var n: usize = 0;
        if (register_size != 0) {
            sizes_buf[0] = register_size;
            n = 1;
        }
        for (guessed_sizes) |s| {
            if (s == register_size) continue;
            sizes_buf[n] = s;
            n += 1;
        }
        break :sizes sizes_buf[0..n];
    };
    const ip_relative: []const bool = if (root.is64 and mem_index != null and isAbsolute(insn.operands[mem_index.?].mem)) &.{ true, false } else &.{false};
    const reps: []const u64 = if (insn.prefixes.rep) &.{ zydis.ZYDIS_ATTRIB_HAS_REP, zydis.ZYDIS_ATTRIB_HAS_REPE } else &.{0};
    const Width = @FieldType(zydis.ZydisEncoderRequest, "branch_width");
    const widths: []const Width = if (options.long_branch) &.{ zydis.ZYDIS_BRANCH_WIDTH_32, zydis.ZYDIS_BRANCH_WIDTH_NONE } else &.{zydis.ZYDIS_BRANCH_WIDTH_NONE};

    for (widths) |width| for (reps) |rep| for (ip_relative) |rip| for (sizes) |size| for ([_]bool{ false, true }) |reinterpret| {
        var attempt = request;
        attempt.branch_width = width;
        if (rep != 0) attempt.prefixes = (request.prefixes & ~@as(u64, zydis.ZYDIS_ATTRIB_HAS_REP)) | rep;
        if (mem_index) |i| {
            attempt.operands[i].mem.size = size;
            if (rip) attempt.operands[i].mem.base = zydis.ZYDIS_REGISTER_RIP;
        }
        if (reinterpret) {
            // Zydis wants the 32-bit immediate signed, like `cmp eax, 0xC0000034`
            const bytes = if (register_size != 0) register_size else if (size != 0) size else if (root.is64) 0 else 4;
            if (!signExtendImmediates(&attempt, insn, bytes)) continue;
        }
        var out: Encoded = .{ .bytes = undefined, .len = 0 };
        var len: usize = out.bytes.len;
        // Absolute mode. An explicit `[rip+x]` is already relative
        const status = if (explicit_rip)
            zydis.ZydisEncoderEncodeInstruction(&attempt, &out.bytes, &len)
        else
            zydis.ZydisEncoderEncodeInstructionAbsolute(&attempt, &out.bytes, &len, address);
        if ((status & 0x80000000) == 0) {
            out.len = @intCast(len);
            keepXchg(insn, &out);
            return out;
        }
    };
    return error.CannotEncode;
}

/// `87 C0`, not `90`. On x64 `nop` keeps RAX's upper half but `xchg eax, eax` clears it.
fn keepXchg(insn: *const Instruction, out: *Encoded) void {
    if (insn.mnemonic.id != zydis.ZYDIS_MNEMONIC_XCHG or insn.operand_count != 2) return;
    const a = insn.operands[0];
    const b = insn.operands[1];
    if (a != .reg or b != .reg or !a.reg.eql(b.reg)) return;
    if (out.len == 0 or out.bytes[out.len - 1] != 0x90) return;
    const bytes: []const u8 = switch (a.reg.bits()) {
        16 => &.{ 0x66, 0x87, 0xC0 },
        32 => &.{ 0x87, 0xC0 },
        64 => &.{ 0x48, 0x87, 0xC0 },
        else => return,
    };
    @memcpy(out.bytes[0..bytes.len], bytes);
    out.len = @intCast(bytes.len);
}

/// Like `[0x1234]` or `[label]`.
fn isAbsolute(m: root.Mem) bool {
    return m.base == null and m.index == null and m.segment == null;
}

/// Reads unsigned-only immediates as signed. False if there were none.
fn signExtendImmediates(request: *zydis.ZydisEncoderRequest, insn: *const Instruction, bytes: u16) bool {
    if (bytes == 0 or bytes >= 8) return false;
    const bits: u6 = @intCast(bytes * 8);
    var changed = false;
    for (insn.ops(), 0..) |op, i| {
        if (op != .imm) continue;
        const v = op.imm.offset;
        if (v < (@as(i64, 1) << (bits - 1)) or v >= (@as(i64, 1) << bits)) continue;
        request.operands[i].imm.s = v - (@as(i64, 1) << bits);
        changed = true;
    }
    return changed;
}

fn prefixBits(p: root.Prefixes) u64 {
    var bits: u64 = 0;
    if (p.lock) bits |= zydis.ZYDIS_ATTRIB_HAS_LOCK;
    if (p.rep) bits |= zydis.ZYDIS_ATTRIB_HAS_REP;
    if (p.repe) bits |= zydis.ZYDIS_ATTRIB_HAS_REPE;
    if (p.repne) bits |= zydis.ZYDIS_ATTRIB_HAS_REPNE;
    if (p.xacquire) bits |= zydis.ZYDIS_ATTRIB_HAS_XACQUIRE;
    if (p.xrelease) bits |= zydis.ZYDIS_ATTRIB_HAS_XRELEASE;
    if (p.bnd) bits |= zydis.ZYDIS_ATTRIB_HAS_BND;
    if (p.notrack) bits |= zydis.ZYDIS_ATTRIB_HAS_NOTRACK;
    return bits;
}

fn segmentBit(r: Register) ?u64 {
    const segments = .{
        .{ "cs", zydis.ZYDIS_ATTRIB_HAS_SEGMENT_CS }, .{ "ss", zydis.ZYDIS_ATTRIB_HAS_SEGMENT_SS },
        .{ "ds", zydis.ZYDIS_ATTRIB_HAS_SEGMENT_DS }, .{ "es", zydis.ZYDIS_ATTRIB_HAS_SEGMENT_ES },
        .{ "fs", zydis.ZYDIS_ATTRIB_HAS_SEGMENT_FS }, .{ "gs", zydis.ZYDIS_ATTRIB_HAS_SEGMENT_GS },
    };
    inline for (segments) |s| {
        if (r.eql(.named(s[0]))) return s[1];
    }
    return null;
}
