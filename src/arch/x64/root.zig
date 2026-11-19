//! x64 backend.

const std = @import("std");

const arch = @import("../root.zig");

pub const bits = 64;
pub const CpuContext = @import("cpu_context.zig").CpuContext;

pub const near_reaches_all = false;
/// ~2GB minus 64kb, so 64kb-granular allocations stay in `rel32` reach.
pub const near_range: usize = 0x7FFF_0000;

/// `rel32` from `next_ip` to `target`, if it fits.
pub fn reach(next_ip: usize, target: usize) ?i32 {
    const diff: i128 = @as(i128, target) - @as(i128, next_ip);
    if (diff >= std.math.minInt(i32) and diff <= std.math.maxInt(i32)) return @intCast(diff);
    return null;
}

pub const abs_jmp_len = 14;
pub const max_jmp_len = abs_jmp_len;

/// `jmp [rip+0]` then abs64
pub fn encodeAbsJmp(to: usize) [14]u8 {
    var out: [14]u8 = .{ 0xFF, 0x25, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    std.mem.writeInt(u64, out[6..14], to, .little);
    return out;
}

/// `call [rip+2]`, `jmp +8`, abs64
pub fn encodeAbsCall(to: usize) [16]u8 {
    var out: [16]u8 = .{ 0xFF, 0x15, 0x02, 0, 0, 0, 0xEB, 0x08, 0, 0, 0, 0, 0, 0, 0, 0 };
    std.mem.writeInt(u64, out[8..16], to, .little);
    return out;
}

/// Inverted jcc over an absolute jump
pub fn encodeAbsJcc(cc: u8, to: usize) [16]u8 {
    var out: [16]u8 = undefined;
    out[0] = 0x70 | (cc ^ 1);
    out[1] = 0x0E;
    out[2..16].* = encodeAbsJmp(to);
    return out;
}

/// `jmp [cell_addr]` that keeps RAX and RSP intact.
pub fn encodeIndirectJmp(cell_addr: usize) [19]u8 {
    var out: [19]u8 = .{ 0x50, 0x48, 0xB8, 0, 0, 0, 0, 0, 0, 0, 0, 0x48, 0x8B, 0x00, 0x48, 0x87, 0x04, 0x24, 0xC3 };
    std.mem.writeInt(u64, out[3..11], cell_addr, .little);
    return out;
}

/// `call [cell_addr]` that keeps RAX and RSP intact.
pub fn encodeIndirectCall(cell_addr: usize) [26]u8 {
    var out: [26]u8 = undefined;
    out[0..7].* = .{ 0xE8, 0x02, 0, 0, 0, 0xEB, 0x13 };
    out[7..26].* = encodeIndirectJmp(cell_addr);
    return out;
}

pub const fn_stub_size = 47;

/// Only touches R10/R11, volatile and never args.
pub fn writeFnStub(dest: *[fn_stub_size]u8, value: usize, tls: arch.TlsSlot, entry: usize) void {
    std.debug.assert(tls.segment == .gs);
    dest[0..2].* = .{ 0x49, 0xBA };
    std.mem.writeInt(u64, dest[2..10], value, .little);
    dest[10..15].* = .{ 0x65, 0x4C, 0x8B, 0x1C, 0x25 };
    std.mem.writeInt(u32, dest[15..19], tls.array_offset, .little);
    dest[19..22].* = .{ 0x4D, 0x8B, 0x9B };
    std.mem.writeInt(u32, dest[22..26], tls.index * 8, .little);
    dest[26..29].* = .{ 0x4D, 0x89, 0x93 };
    std.mem.writeInt(u32, dest[29..33], tls.offset, .little);
    dest[33..47].* = encodeAbsJmp(entry);
}

// Module-level asm so it's always emitted. `writeMidStub` copies it
comptime {
    asm (
        \\.text
        \\.intel_syntax noprefix
        \\.global tuft_x64_mid_start
        \\.global tuft_x64_mid_slots
        \\.global tuft_x64_mid_end
        \\tuft_x64_mid_start:
        \\sub rsp, 8
        \\pushfq
        \\push rax; push rcx; push rdx; push rbx
        \\push rsp; push rbp; push rsi; push rdi
        \\push r8;  push r9;  push r10; push r11
        \\push r12; push r13; push r14; push r15
        \\sub rsp, 256
        \\movdqu [rsp + 0], xmm0;   movdqu [rsp + 16], xmm1
        \\movdqu [rsp + 32], xmm2;  movdqu [rsp + 48], xmm3
        \\movdqu [rsp + 64], xmm4;  movdqu [rsp + 80], xmm5
        \\movdqu [rsp + 96], xmm6;  movdqu [rsp + 112], xmm7
        \\movdqu [rsp + 128], xmm8; movdqu [rsp + 144], xmm9
        \\movdqu [rsp + 160], xmm10;movdqu [rsp + 176], xmm11
        \\movdqu [rsp + 192], xmm12;movdqu [rsp + 208], xmm13
        \\movdqu [rsp + 224], xmm14;movdqu [rsp + 240], xmm15

        // Saved RSP was taken after `sub rsp, 8` and 5 pushes, so fix it up
        \\add qword ptr [rsp + 344], 48
        \\mov rbp, rsp
        \\and rsp, -16
        \\sub rsp, 32
        \\lea rax, [rip + tuft_x64_mid_slots]
        \\mov rcx, [rax]            // context
        \\mov rdx, rbp              // cpu
        \\call [rax + 8]            // router
        \\mov rsp, rbp
        // The router gives back where to go, `rip` or the trampoline. It goes in `rip`'s slot for the `ret`
        \\mov [rsp + 392], rax
        \\movdqu xmm0, [rsp + 0];   movdqu xmm1, [rsp + 16]
        \\movdqu xmm2, [rsp + 32];  movdqu xmm3, [rsp + 48]
        \\movdqu xmm4, [rsp + 64];  movdqu xmm5, [rsp + 80]
        \\movdqu xmm6, [rsp + 96];  movdqu xmm7, [rsp + 112]
        \\movdqu xmm8, [rsp + 128]; movdqu xmm9, [rsp + 144]
        \\movdqu xmm10, [rsp + 160];movdqu xmm11, [rsp + 176]
        \\movdqu xmm12, [rsp + 192];movdqu xmm13, [rsp + 208]
        \\movdqu xmm14, [rsp + 224];movdqu xmm15, [rsp + 240]
        \\add rsp, 256
        \\pop r15; pop r14; pop r13; pop r12
        \\pop r11; pop r10; pop r9;  pop r8
        \\pop rdi; pop rsi; pop rbp; add rsp, 8
        \\pop rbx; pop rdx; pop rcx; pop rax
        \\popfq
        \\ret
        \\.p2align 3
        \\tuft_x64_mid_slots:
        \\.quad 0                   // context
        \\.quad 0                   // router
        \\tuft_x64_mid_end:
        \\.att_syntax prefix
    );
}

extern const tuft_x64_mid_start: anyopaque;
extern const tuft_x64_mid_slots: anyopaque;
extern const tuft_x64_mid_end: anyopaque;

pub fn midStubSize() usize {
    return @intFromPtr(&tuft_x64_mid_end) - @intFromPtr(&tuft_x64_mid_start);
}

pub fn writeMidStub(dest: []u8, context: usize, router: usize) void {
    const size = midStubSize();
    const template: [*]const u8 = @ptrCast(&tuft_x64_mid_start);
    @memcpy(dest[0..size], template[0..size]);
    const slots = @intFromPtr(&tuft_x64_mid_slots) - @intFromPtr(&tuft_x64_mid_start);
    std.mem.writeInt(u64, dest[slots..][0..8], context, .little);
    std.mem.writeInt(u64, dest[slots + 8 ..][0..8], router, .little);
}

/// For the arch tests.
pub const tests = struct {
    pub const changed_arg = 41;

    pub noinline fn returnFirstArg(a: u64) callconv(.c) u64 {
        var x = a;
        asm volatile (""
            : [x] "+r" (x),
        );
        return x;
    }

    pub fn firstArg(cpu: *const CpuContext) usize {
        return cpu.rcx;
    }

    pub fn changeFirstArg(cpu: *CpuContext) void {
        cpu.rcx = changed_arg;
    }
};
