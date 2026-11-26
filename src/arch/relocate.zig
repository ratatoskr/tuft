//! Moves a function's first instructions into a hook trampoline.

const std = @import("std");
const builtin = @import("builtin");

const arch = @import("root.zig");
const insn = @import("insn.zig");
const native = @import("native.zig").native;

const is64 = builtin.cpu.arch == .x86_64;

pub const max_stolen_bytes = 32;

pub const RelocateResult = struct {
    stolen_len: u8,
    trampoline_len: u16,
    original_bytes: [max_stolen_bytes]u8,
    /// Where the instruction that starts `n` bytes in lands in the trampoline. At `stolen_len`
    /// it's the jump back. Null inside an instruction.
    starts: [max_stolen_bytes + 1]?u16 = @splat(null),

    /// The trampoline offset just after the first `n` bytes. Null if that's inside an instruction.
    pub fn after(self: *const RelocateResult, n: usize) ?u16 {
        if (n > self.stolen_len) return null;
        return self.starts[n];
    }

    /// How long the first instruction is.
    pub fn firstLen(self: *const RelocateResult) u8 {
        for (1..@as(usize, self.stolen_len) + 1) |n| if (self.starts[n] != null) return @intCast(n);
        return self.stolen_len;
    }
};

pub const RelocateError = error{
    DisassemblyFailed,
    UnsupportedInstruction,
    BufferTooSmall,
    UnsupportedRelativeOperand,
    UnsupportedAddressSize,
    FunctionTooSmall,
};

const Emitter = struct {
    buf: []u8,
    base: usize,
    len: usize = 0,

    fn write(self: *Emitter, bytes: []const u8) RelocateError!void {
        if (self.len + bytes.len > self.buf.len) return error.BufferTooSmall;
        @memcpy(self.buf[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }

    fn addr(self: *const Emitter) usize {
        return self.base + self.len;
    }
};

const Branch = union(enum) {
    jmp,
    call,
    jcc: u8,

    fn rel32Len(self: Branch) usize {
        return if (self == .jcc) 6 else 5;
    }

    fn writeRel32(self: Branch, out: *Emitter, rel32: i32) RelocateError!void {
        switch (self) {
            .jmp => try out.write(&[_]u8{0xE9}),
            .call => try out.write(&[_]u8{0xE8}),
            .jcc => |cc| try out.write(&[_]u8{ 0x0F, 0x80 | cc }),
        }
        try out.write(std.mem.asBytes(&rel32));
    }

    /// rel32 if it reaches `to`, else an absolute form.
    fn writeTo(self: Branch, out: *Emitter, to: usize) RelocateError!void {
        if (native.reach(out.addr() + self.rel32Len(), to)) |rel32| return self.writeRel32(out, rel32);
        if (native.near_reaches_all) unreachable;
        switch (self) {
            .jmp => try out.write(&native.encodeAbsJmp(to)),
            .call => try out.write(&native.encodeAbsCall(to)),
            .jcc => |cc| try out.write(&native.encodeAbsJcc(cc, to)),
        }
    }

    fn fromRelative(d: insn.DecodedInsn) RelocateError!Branch {
        const op = d.opcode;
        if (d.map == .primary) {
            if (op == 0xEB or op == 0xE9) return .jmp;
            if (op == 0xE8) return .call;
            if (op >= 0x70 and op <= 0x7F) return .{ .jcc = op & 0x0F };
        }
        if (d.map == .@"0F" and op >= 0x80 and op <= 0x8F) return .{ .jcc = op & 0x0F };
        // LOOP and JECXZ have no rel32 form
        return error.UnsupportedInstruction;
    }

    /// `jmp/call [rip+disp32]`, x64 only.
    fn fromRipIndirect(d: insn.DecodedInsn) ?Branch {
        if (!d.isIpRelativeOperand() or !d.is(.primary, 0xFF)) return null;
        return switch (d.modrm.?.reg) {
            2 => .call,
            4 => .jmp,
            else => null,
        };
    }
};

/// Relocates at least `min_patch_len` bytes, then jumps back.
pub fn buildTrampoline(
    target_addr: usize,
    min_patch_len: u8,
    trampoline_base: usize,
    trampoline_buf: []u8,
) RelocateError!RelocateResult {
    var result = RelocateResult{
        .stolen_len = 0,
        .trampoline_len = 0,
        .original_bytes = std.mem.zeroes([max_stolen_bytes]u8),
    };

    var decoded: [max_stolen_bytes]insn.DecodedInsn = undefined;
    var count: usize = 0;

    while (result.stolen_len < min_patch_len) {
        const cur_addr = target_addr + result.stolen_len;
        var d = try insn.decode(cur_addr);

        // `jmp [rip+0]` has an inline abs64 after it, so steal those 8 bytes too
        if (Branch.fromRipIndirect(d)) |b| {
            const disp: *align(1) const i32 = @ptrFromInt(cur_addr + d.disp_offset);
            if (b == .jmp and d.disp_offset + 4 == d.len and disp.* == 0) d.len += 8;
        }

        if (result.stolen_len + d.len > max_stolen_bytes) return error.BufferTooSmall;
        decoded[count] = d;
        count += 1;
        result.stolen_len += d.len;

        // Past an unconditional exit may be another hook's code, so don't overwrite it
        if (result.stolen_len < min_patch_len and isTerminator(d)) return error.FunctionTooSmall;
    }

    const src: [*]const u8 = @ptrFromInt(target_addr);
    @memcpy(result.original_bytes[0..result.stolen_len], src[0..result.stolen_len]);
    const stolen_end = target_addr + result.stolen_len;

    var out = Emitter{ .buf = trampoline_buf, .base = trampoline_base };

    // Inner branches get patched once we know where everything landed
    const Fixup = struct { rel32_at: usize, src_target: usize };
    var fixups: [max_stolen_bytes]Fixup = undefined;
    var fixup_count: usize = 0;
    var dst_of_src: [max_stolen_bytes]?usize = @splat(null);

    var src_offset: usize = 0;
    for (decoded[0..count]) |d| {
        const bytes = src[src_offset..][0..d.len];
        dst_of_src[src_offset] = out.len;
        result.starts[src_offset] = @intCast(out.len);
        src_offset += d.len;

        const target = d.rel_target orelse {
            try out.write(bytes);
            continue;
        };

        if (d.branch) {
            const branch = try Branch.fromRelative(d);
            if (target >= target_addr and target < stolen_end) {
                try branch.writeRel32(&out, 0);
                fixups[fixup_count] = .{ .rel32_at = out.len - 4, .src_target = target - target_addr };
                fixup_count += 1;
            } else {
                try branch.writeTo(&out, target);
            }
            continue;
        }

        // Anything left is an x64 RIP-relative operand
        if (!is64) unreachable;
        try relocateRipOperand(&out, d, bytes, target, target_addr, stolen_end, result.original_bytes[0..result.stolen_len]);
    }

    for (fixups[0..fixup_count]) |f| {
        // Can't branch into the middle of a stolen instruction
        const dst = dst_of_src[f.src_target] orelse return error.UnsupportedInstruction;
        std.mem.writeInt(i32, trampoline_buf[f.rel32_at..][0..4], native.reach(f.rel32_at + 4, dst).?, .little);
    }

    result.starts[result.stolen_len] = @intCast(out.len);
    try (Branch{ .jmp = {} }).writeTo(&out, stolen_end);

    result.trampoline_len = @intCast(out.len);
    return result;
}

/// x64 only. Re-targets `[rip+disp32]` for the trampoline.
fn relocateRipOperand(out: *Emitter, d: insn.DecodedInsn, bytes: []const u8, target: usize, target_addr: usize, stolen_end: usize, original: []const u8) RelocateError!void {
    if (Branch.fromRipIndirect(d)) |branch| {
        if (target < stolen_end and target + 8 > target_addr) {
            // The pointer cell gets overwritten by our patch, so read it now
            if (target < target_addr or target + 8 > stolen_end) return error.UnsupportedInstruction;
            const cell = original[target - target_addr ..][0..8];
            return branch.writeTo(out, @intCast(std.mem.readInt(u64, cell, .little)));
        }
        if (native.reach(out.addr() + d.len, target) == null) {
            return switch (branch) {
                .call => out.write(&native.encodeIndirectCall(target)),
                else => out.write(&native.encodeIndirectJmp(target)),
            };
        }
        // Near, so just patch disp32
    }

    if (native.reach(out.addr() + d.len, target)) |disp32| {
        const at = out.len;
        try out.write(bytes);
        std.mem.writeInt(i32, out.buf[at + d.disp_offset ..][0..4], disp32, .little);
    } else {
        try writeFarRipOperand(out, d, bytes, target);
    }
}

/// x64 only. Rewrites `op [rip+disp32]` through a scratch register.
fn writeFarRipOperand(out: *Emitter, d: insn.DecodedInsn, bytes: []const u8, target: usize) RelocateError!void {
    // push/pop [mem] move RSP, which the scratch push/pop would break
    if ((d.is(.primary, 0xFF) and d.modrm.?.reg == 6) or d.is(.primary, 0x8F)) return error.UnsupportedInstruction;
    const escape = escapeOf(bytes);
    // REX2 keeps its B bits beside others it'd take more care to rewrite
    if (escape) |e| if (e.kind == .rex2) return error.UnsupportedInstruction;
    const scratch = pickScratch(d, if (escape) |e| e.vvvv(bytes) else null) orelse return error.UnsupportedInstruction;

    var movabs: [10]u8 = .{ 0x48, 0xB8 + scratch, 0, 0, 0, 0, 0, 0, 0, 0 };
    std.mem.writeInt(u64, movabs[2..10], target, .little);
    try out.write(&[_]u8{0x50 + scratch});
    try out.write(&movabs);

    // REX.B cleared so rm=scratch doesn't become r8..r11
    const modrm_idx = d.disp_offset - 1;
    const start = out.len;
    try out.write(bytes[0..modrm_idx]);
    if (escape) |e| {
        // VEX and EVEX keep B and X inverted, so set is none. 2-byte VEX has neither, and none's implied
        if (e.kind != .vex2) out.buf[start + e.at + 1] |= 0x60;
    } else if (d.rex != null) {
        for (out.buf[start..out.len]) |*b| {
            if ((b.* & 0xF0) == 0x40) {
                b.* &= ~@as(u8, 1);
                break;
            }
        }
    }

    // rm=scratch instead of [rip+disp32]. Any trailing immediate stays
    try out.write(&[_]u8{(@as(u8, d.modrm.?.reg) << 3) | scratch});
    try out.write(bytes[d.disp_offset + 4 ..]);
    try out.write(&[_]u8{0x58 + scratch});
}

/// x64 only. RAX, RCX, RDX or RBX, skipping any the instruction uses. `vvvv` is a VEX or EVEX
/// operand register, which can be a general one, like BMI's. Unused, it reads as RAX, which is
/// skipped all the same, as there's no telling.
fn pickScratch(d: insn.DecodedInsn, vvvv: ?u4) ?u8 {
    var used = [4]bool{ false, false, false, false };
    if (vvvv) |v| if (v < 4) {
        used[v] = true;
    };
    const reg = d.modrm.?.reg;
    const rex_r = if (d.rex) |rex| rex.r else false;
    if (!rex_r and reg < 4) used[reg] = true;
    switch (d.map) {
        .primary => switch (d.opcode) {
            // mul/imul/div/idiv use RDX:RAX
            0xF6, 0xF7 => if (reg >= 4) {
                used[0] = true;
                used[2] = true;
            },
            // shifts by CL
            0xD2, 0xD3 => used[1] = true,
            else => {},
        },
        .@"0F" => switch (d.opcode) {
            0xA5, 0xAD => used[1] = true, // shld/shrd by CL
            0xB0, 0xB1 => used[0] = true, // cmpxchg uses RAX
            0xC7 => return null, // cmpxchg8b/16b use RDX:RAX and RCX:RBX
            else => {},
        },
        .other => {},
    }
    for (used, 0..) |u, i| {
        if (!u) return @intCast(i);
    }
    return null;
}

/// A VEX, EVEX or REX2 escape after the legacy prefixes.
const Escape = struct {
    kind: enum { vex2, vex3, evex, rex2 },
    /// Where its first byte is.
    at: usize,

    /// The register its `vvvv` names, which it keeps inverted. Null for REX2, which has none.
    fn vvvv(self: Escape, bytes: []const u8) ?u4 {
        const field: u8 = switch (self.kind) {
            .vex2 => bytes[self.at + 1],
            .vex3 => bytes[self.at + 2],
            .evex => bytes[self.at + 2],
            .rex2 => return null,
        };
        return @intCast(~(field >> 3) & 0xF);
    }
};

/// x64 only, where C4, C5 and 62 are always escapes.
fn escapeOf(bytes: []const u8) ?Escape {
    for (bytes, 0..) |b, i| {
        switch (b) {
            0x26, 0x2E, 0x36, 0x3E, 0x64, 0x65, 0x66, 0x67, 0xF0, 0xF2, 0xF3 => continue,
            0xC5 => return .{ .kind = .vex2, .at = i },
            0xC4 => return .{ .kind = .vex3, .at = i },
            0x62 => return .{ .kind = .evex, .at = i },
            0xD5 => return .{ .kind = .rex2, .at = i },
            else => return null,
        }
    }
    return null;
}

fn isTerminator(d: insn.DecodedInsn) bool {
    return switch (d.map) {
        .primary => switch (d.opcode) {
            0xC2, 0xC3, 0xCA, 0xCB, 0xCC, 0xE9, 0xEB => true,
            0xFF => d.modrm.?.reg == 4 or d.modrm.?.reg == 5,
            else => false,
        },
        .@"0F" => d.opcode == 0x0B,
        .other => false,
    };
}

const tests = struct {
    const testing = std.testing;
    /// Too far from anything a test runs at to reach with a disp32.
    const far = 0x7FF0_0000_0000;

    /// `code`, which reads `[rip+disp32]`, as though it reads `far`, through a scratch register.
    fn rewrite(code: []const u8, buf: []u8) ![]const u8 {
        const d = try insn.decodeBytes(code, @intFromPtr(code.ptr));
        var out: Emitter = .{ .buf = buf, .base = @intFromPtr(buf.ptr) };
        try writeFarRipOperand(&out, d, code, far);
        return buf[0..out.len];
    }

    fn expectThrough(scratch: u8, op: []const u8, got: []const u8) !void {
        try testing.expectEqual(0x50 + scratch, got[0]);
        try testing.expectEqualSlices(u8, &.{ 0x48, 0xB8 + scratch }, got[1..3]);
        try testing.expectEqual(far, std.mem.readInt(u64, got[3..11], .little));
        try testing.expectEqualSlices(u8, op, got[11 .. got.len - 1]);
        try testing.expectEqual(0x58 + scratch, got[got.len - 1]);
    }

    test "far RIP-relative 2-byte VEX goes through a scratch register" {
        if (!is64) return error.SkipZigTest;
        var buf: [64]u8 = undefined;
        // vmovss xmm0, [rip+0x10], as the game's slow rate update opens with. RAX shares xmm0's
        // number, so it's skipped
        try expectThrough(1, &.{ 0xC5, 0xFA, 0x10, 0x01 }, try rewrite(&.{ 0xC5, 0xFA, 0x10, 0x05, 0x10, 0, 0, 0 }, &buf));
    }

    test "far RIP-relative 3-byte VEX clears its inverted B" {
        if (!is64) return error.SkipZigTest;
        var buf: [64]u8 = undefined;
        // vmovaps xmm1, [rip+0x10] with B set, which RIP-relative ignores but [rdx] wouldn't. An
        // unused vvvv reads as RAX, so that's skipped too
        try expectThrough(2, &.{ 0xC4, 0xE1, 0x78, 0x28, 0x0A }, try rewrite(&.{ 0xC4, 0xC1, 0x78, 0x28, 0x0D, 0x10, 0, 0, 0 }, &buf));
    }

    test "far RIP-relative EVEX clears its inverted B and X" {
        if (!is64) return error.SkipZigTest;
        var buf: [64]u8 = undefined;
        // vmovups zmm2, [rip+0x10], with B and X set
        try expectThrough(1, &.{ 0x62, 0xF1, 0x7C, 0x48, 0x10, 0x11 }, try rewrite(&.{ 0x62, 0x91, 0x7C, 0x48, 0x10, 0x15, 0x10, 0, 0, 0 }, &buf));
    }

    test "far RIP-relative VEX skips the general register vvvv names" {
        if (!is64) return error.SkipZigTest;
        var buf: [64]u8 = undefined;
        // andn eax, ecx, [rip+0x10]: reg is eax and vvvv ecx, so rdx it is
        try expectThrough(2, &.{ 0xC4, 0xE2, 0x70, 0xF2, 0x02 }, try rewrite(&.{ 0xC4, 0xE2, 0x70, 0xF2, 0x05, 0x10, 0, 0, 0 }, &buf));
    }
};

test {
    _ = tests;
}
