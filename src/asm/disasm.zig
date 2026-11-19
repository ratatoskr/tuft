//! Disassembly to Intel-syntax text. Never touches memory itself.

const std = @import("std");
const builtin = @import("builtin");

const zydis = @import("zydis");

const is64 = builtin.cpu.arch == .x86_64;
const machine_mode = if (is64) zydis.ZYDIS_MACHINE_MODE_LONG_64 else zydis.ZYDIS_MACHINE_MODE_LEGACY_32;
const stack_width = if (is64) zydis.ZYDIS_STACK_WIDTH_64 else zydis.ZYDIS_STACK_WIDTH_32;

pub const max_len = zydis.ZYDIS_MAX_INSTRUCTION_LENGTH;

/// How x64 RIP-relative operands show. Branches always show their target.
pub const Addresses = enum {
    /// `[0x7FF6A0002234]`
    absolute,
    /// `[rip+0x1234]`
    relative,
};

/// Which code to read it as. Native is what this was built for.
pub const Mode = enum { native, x86, x64 };

pub const Options = struct {
    addresses: Addresses = .absolute,
    mode: Mode = .native,
};

pub const Instruction = struct {
    len: u8,
    text_buf: [96]u8,
    ip_relative: ?usize = null,
    branch_target: ?usize = null,
    /// Counts hidden operands like a `pop`'s stack slot, not a `lea`'s.
    reads_memory: bool = false,
    writes_memory: bool = false,

    pub fn text(self: *const Instruction) [:0]const u8 {
        return std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&self.text_buf)), 0);
    }
};

/// Null if there isn't one or the bytes end too early.
pub fn decode(bytes: []const u8, address: usize) ?Instruction {
    return decodeWith(bytes, address, .{});
}

pub fn decodeWith(bytes: []const u8, address: usize, options: Options) ?Instruction {
    var decoder: zydis.ZydisDecoder = undefined;
    const mode: zydis.ZydisMachineMode = switch (options.mode) {
        .native => machine_mode,
        .x86 => zydis.ZYDIS_MACHINE_MODE_LEGACY_32,
        .x64 => zydis.ZYDIS_MACHINE_MODE_LONG_64,
    };
    const width: zydis.ZydisStackWidth = switch (options.mode) {
        .native => stack_width,
        .x86 => zydis.ZYDIS_STACK_WIDTH_32,
        .x64 => zydis.ZYDIS_STACK_WIDTH_64,
    };
    if (failed(zydis.ZydisDecoderInit(&decoder, mode, width))) return null;
    var insn: zydis.ZydisDecodedInstruction = undefined;
    var operands: [zydis.ZYDIS_MAX_OPERAND_COUNT]zydis.ZydisDecodedOperand = undefined;
    if (failed(zydis.ZydisDecoderDecodeFull(&decoder, bytes.ptr, bytes.len, &insn, &operands))) return null;

    var formatter: zydis.ZydisFormatter = undefined;
    if (failed(zydis.ZydisFormatterInit(&formatter, zydis.ZYDIS_FORMATTER_STYLE_INTEL))) return null;
    const properties = [_]struct { c_int, usize }{
        .{ zydis.ZYDIS_FORMATTER_PROP_FORCE_SIZE, 1 },
        .{ zydis.ZYDIS_FORMATTER_PROP_FORCE_RELATIVE_RIPREL, @intFromBool(options.addresses == .relative) },
        .{ zydis.ZYDIS_FORMATTER_PROP_ADDR_PADDING_ABSOLUTE, zydis.ZYDIS_PADDING_DISABLED },
        .{ zydis.ZYDIS_FORMATTER_PROP_ADDR_PADDING_RELATIVE, zydis.ZYDIS_PADDING_DISABLED },
        .{ zydis.ZYDIS_FORMATTER_PROP_DISP_PADDING, zydis.ZYDIS_PADDING_DISABLED },
        .{ zydis.ZYDIS_FORMATTER_PROP_IMM_PADDING, zydis.ZYDIS_PADDING_DISABLED },
        .{ zydis.ZYDIS_FORMATTER_PROP_HEX_UPPERCASE, 0 },
    };
    for (properties) |p| {
        if (failed(zydis.ZydisFormatterSetProperty(&formatter, @intCast(p[0]), p[1]))) return null;
    }
    var result: Instruction = .{ .len = insn.length, .text_buf = undefined };
    const status = zydis.ZydisFormatterFormatInstruction(&formatter, &insn, &operands, insn.operand_count_visible, @ptrCast(&result.text_buf), result.text_buf.len, address, null);
    if (failed(status)) return null;

    for (operands[0..insn.operand_count_visible]) |*op| {
        var target: u64 = undefined;
        const relative = switch (op.type) {
            zydis.ZYDIS_OPERAND_TYPE_MEMORY => op.unnamed_0.mem.base == zydis.ZYDIS_REGISTER_RIP or op.unnamed_0.mem.base == zydis.ZYDIS_REGISTER_EIP,
            zydis.ZYDIS_OPERAND_TYPE_IMMEDIATE => op.unnamed_0.imm.is_relative != 0,
            else => false,
        };
        if (!relative or failed(zydis.ZydisCalcAbsoluteAddress(&insn, op, address, &target))) continue;
        // Zydis works in 64 bits, so wrap to the target's width
        if (op.type == zydis.ZYDIS_OPERAND_TYPE_MEMORY) result.ip_relative = @truncate(target) else result.branch_target = @truncate(target);
    }
    for (operands[0..insn.operand_count]) |*op| {
        if (op.type != zydis.ZYDIS_OPERAND_TYPE_MEMORY or op.unnamed_0.mem.type == zydis.ZYDIS_MEMOP_TYPE_AGEN) continue;
        if (op.actions & zydis.ZYDIS_OPERAND_ACTION_MASK_READ != 0) result.reads_memory = true;
        if (op.actions & zydis.ZYDIS_OPERAND_ACTION_MASK_WRITE != 0) result.writes_memory = true;
    }
    return result;
}

/// The instruction ending at `ip`, found by voting. 32+ bytes of `code` is plenty.
pub fn before(code: []const u8, ip: usize) ?Instruction {
    const window = code[code.len -| 64..];
    // Index is how many bytes before `ip` it starts
    var votes: [max_len + 1]u16 = @splat(0);
    for (0..window.len) |from| {
        var at = from;
        var last = from;
        while (at < window.len) {
            last = at;
            at += length(window[at..]) orelse break;
        }
        if (at != window.len) continue;
        const back = window.len - last;
        if (back <= max_len) votes[back] += 1;
    }

    var best: ?Instruction = null;
    var best_score: u32 = 0;
    for (1..@as(usize, @min(max_len, window.len)) + 1) |back| {
        if (votes[back] == 0) continue;
        const insn = decode(window[window.len - back ..], ip -% back) orelse continue;
        if (insn.len != back) continue;
        const touches: u32 = @intFromBool(insn.reads_memory or insn.writes_memory);
        const score = (touches << 16) | votes[back];
        if (score > best_score) {
            best = insn;
            best_score = score;
        }
    }
    return best;
}

/// Cheaper than `decode`.
pub fn length(bytes: []const u8) ?u8 {
    var decoder: zydis.ZydisDecoder = undefined;
    if (failed(zydis.ZydisDecoderInit(&decoder, machine_mode, stack_width))) return null;
    var insn: zydis.ZydisDecodedInstruction = undefined;
    if (failed(zydis.ZydisDecoderDecodeInstruction(&decoder, null, bytes.ptr, bytes.len, &insn))) return null;
    return insn.length;
}

fn failed(status: zydis.ZyanStatus) bool {
    return (status & 0x80000000) != 0;
}

const tests = struct {
    const testing = std.testing;

    test "Intel syntax and lengths" {
        const xor = decode(&.{ 0x31, 0xC0, 0xC3 }, 0x1000).?;
        try testing.expectEqual(2, xor.len);
        try testing.expectEqualStrings("xor eax, eax", xor.text());
        try testing.expectEqualStrings("ret", decode(&.{0xC3}, 0x1000).?.text());
        try testing.expectEqual(2, length(&.{ 0x31, 0xC0, 0xC3 }));
    }

    test "branch targets" {
        // jmp +2
        const jmp = decode(&.{ 0xEB, 0x02 }, 0x1000).?;
        try testing.expectEqualStrings("jmp 0x1004", jmp.text());
        try testing.expectEqual(0x1004, jmp.branch_target);
        try testing.expectEqual(null, jmp.ip_relative);
        try testing.expectEqualStrings("mov eax, 0x1", decode(&.{ 0xB8, 0x01, 0x00, 0x00, 0x00 }, 0x1000).?.text());
    }

    test "RIP-relative operands" {
        if (!is64) return error.SkipZigTest;
        // mov eax, [rip+0x10]
        const bytes = [_]u8{ 0x8B, 0x05, 0x10, 0x00, 0x00, 0x00 };
        const absolute = decode(&bytes, 0x7FF6_0000_1000).?;
        try testing.expectEqualStrings("mov eax, dword ptr [0x7ff600001016]", absolute.text());
        try testing.expectEqual(0x7FF6_0000_1016, absolute.ip_relative);
        const relative = decodeWith(&bytes, 0x7FF6_0000_1000, .{ .addresses = .relative }).?;
        try testing.expectEqualStrings("mov eax, dword ptr [rip+0x10]", relative.text());
        try testing.expectEqual(0x7FF6_0000_1016, relative.ip_relative);
    }

    test "cut-off and invalid" {
        try testing.expectEqual(null, decode(&.{ 0xE8, 0x01 }, 0x1000)); // call rel32, short
        try testing.expectEqual(null, length(&.{ 0xE8, 0x01 }));
        try testing.expectEqual(null, decode(&.{}, 0x1000));
        try testing.expectEqual(null, length(&.{ 0x0F, 0xFF })); // ud0 without its ModR/M
    }

    test "another mode than ours" {
        // 0x40 is inc eax on x86 and a REX prefix on x64
        const bytes = [_]u8{ 0x40, 0x89, 0xC8 };
        try testing.expectEqualStrings("inc eax", decodeWith(&bytes, 0x1000, .{ .mode = .x86 }).?.text());
        try testing.expectEqualStrings("mov eax, ecx", decodeWith(&bytes, 0x1000, .{ .mode = .x64 }).?.text());
    }

    test "memory loads and stores" {
        const load = decode(&.{ 0x8B, 0x01 }, 0x1000).?; // mov eax, [rcx]
        try testing.expect(load.reads_memory and !load.writes_memory);
        const store = decode(&.{ 0x89, 0x01 }, 0x1000).?; // mov [rcx], eax
        try testing.expect(!store.reads_memory and store.writes_memory);
        const add = decode(&.{ 0x83, 0x01, 0x01 }, 0x1000).?; // add dword ptr [rcx], 1
        try testing.expect(add.reads_memory and add.writes_memory);
        const lea = decode(&.{ 0x8D, 0x41, 0x10 }, 0x1000).?; // lea eax, [rcx+0x10]
        try testing.expect(!lea.reads_memory and !lea.writes_memory);
    }

    test "instruction before an address" {
        const code = [_]u8{
            0x53, // push rbx (ebx)
            0x83, 0xEC, 0x20, // sub esp, 0x20
            0xB8, 0x00, 0x00, 0x00, 0x48, // mov eax, 0x48000000. The 0x48 is a REX on x64
            0x89, 0x01, // mov [rcx], eax
        };
        const ip = 0x1000 + code.len;
        const store = before(&code, ip).?;
        try testing.expectEqual(2, store.len);
        try testing.expect(store.writes_memory);

        const tail = [_]u8{ 0xB8, 0x01, 0x00, 0x00, 0x00, 0x89, 0x41, 0x10 }; // mov eax, 1. mov [rcx+0x10], eax
        const field = before(&tail, 0x2000).?;
        try testing.expectEqual(3, field.len);
        try testing.expect(std.mem.endsWith(u8, field.text(), "+0x10], eax"));
        try testing.expectEqual(null, before(&.{}, 0x2000));

        var long: [64]u8 = @splat(0xCC);
        long[61..64].* = .{ 0x89, 0x41, 0x10 };
        try testing.expectEqual(3, before(&long, 0x3000).?.len);
    }
};

test {
    _ = tests;
}
