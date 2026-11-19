//! x86 backend. WoW64 on Windows 10/11, so SSE2 and `cmpxchg8b` exist.

const std = @import("std");

const arch = @import("../root.zig");

pub const bits = 32;
pub const CpuContext = @import("cpu_context.zig").CpuContext;

/// `rel32` wraps, so it reaches everywhere.
pub const near_reaches_all = true;
pub const near_range: usize = std.math.maxInt(usize);

pub fn reach(next_ip: usize, target: usize) ?i32 {
    return @bitCast(target -% next_ip);
}

pub const abs_jmp_len = 6;
pub const max_jmp_len = abs_jmp_len;

/// `push to`, `ret`
pub fn encodeAbsJmp(to: usize) [6]u8 {
    var out: [6]u8 = .{ 0x68, 0, 0, 0, 0, 0xC3 };
    std.mem.writeInt(u32, out[1..5], to, .little);
    return out;
}

pub const fn_stub_size = 27;

/// Only touches EAX, volatile and never an arg.
pub fn writeFnStub(dest: *[fn_stub_size]u8, value: usize, tls: arch.TlsSlot, entry: usize) void {
    std.debug.assert(tls.segment == .fs);
    dest[0..2].* = .{ 0x64, 0xA1 };
    std.mem.writeInt(u32, dest[2..6], tls.array_offset, .little);
    dest[6..8].* = .{ 0x8B, 0x80 };
    std.mem.writeInt(u32, dest[8..12], tls.index * 4, .little);
    dest[12..14].* = .{ 0xC7, 0x80 };
    std.mem.writeInt(u32, dest[14..18], tls.offset, .little);
    std.mem.writeInt(u32, dest[18..22], value, .little);
    dest[22..27].* = arch.encodeNearJmp(@intFromPtr(dest) + 22, entry).?;
}

// No EIP-relative addressing, so the mid stub finds its slots with call/pop

// x86 COFF adds a leading underscore
comptime {
    asm (
        \\.text
        \\.intel_syntax noprefix
        \\.global _tuft_x86_mid_start
        \\.global _tuft_x86_mid_slots
        \\.global _tuft_x86_mid_end
        \\_tuft_x86_mid_start:
        \\sub esp, 4
        \\pushfd
        \\pushad
        \\sub esp, 128
        \\movdqu [esp + 0], xmm0;   movdqu [esp + 16], xmm1
        \\movdqu [esp + 32], xmm2;  movdqu [esp + 48], xmm3
        \\movdqu [esp + 64], xmm4;  movdqu [esp + 80], xmm5
        \\movdqu [esp + 96], xmm6;  movdqu [esp + 112], xmm7

        // pushad's ESP was taken after `sub esp, 4` and pushfd, so fix it up
        \\add dword ptr [esp + 140], 8
        \\mov ebp, esp
        \\and esp, -16
        \\call .Ltuft_x86_mid_pc
        \\.Ltuft_x86_mid_pc:
        \\pop eax
        \\push ebp                  // cpu
        // Intel syntax won't take a label difference in a memory operand
        \\.att_syntax prefix
        \\pushl (_tuft_x86_mid_slots - .Ltuft_x86_mid_pc)(%eax)       // context
        \\calll *(_tuft_x86_mid_slots - .Ltuft_x86_mid_pc + 4)(%eax)  // router
        \\.intel_syntax noprefix
        \\mov esp, ebp
        // The router gives back where to go, `eip` or the trampoline. It goes in `eip`'s slot for the `ret`
        \\mov [esp + 164], eax
        \\movdqu xmm0, [esp + 0];   movdqu xmm1, [esp + 16]
        \\movdqu xmm2, [esp + 32];  movdqu xmm3, [esp + 48]
        \\movdqu xmm4, [esp + 64];  movdqu xmm5, [esp + 80]
        \\movdqu xmm6, [esp + 96];  movdqu xmm7, [esp + 112]
        \\add esp, 128

        // popad skips the saved ESP
        \\popad
        \\popfd
        \\ret
        \\.p2align 2
        \\_tuft_x86_mid_slots:
        \\.long 0                   // context
        \\.long 0                   // router
        \\_tuft_x86_mid_end:
        \\.att_syntax prefix
    );
}

extern const tuft_x86_mid_start: anyopaque;
extern const tuft_x86_mid_slots: anyopaque;
extern const tuft_x86_mid_end: anyopaque;

pub fn midStubSize() usize {
    return @intFromPtr(&tuft_x86_mid_end) - @intFromPtr(&tuft_x86_mid_start);
}

pub fn writeMidStub(dest: []u8, context: usize, router: usize) void {
    const size = midStubSize();
    const template: [*]const u8 = @ptrCast(&tuft_x86_mid_start);
    @memcpy(dest[0..size], template[0..size]);
    const slots = @intFromPtr(&tuft_x86_mid_slots) - @intFromPtr(&tuft_x86_mid_start);
    std.mem.writeInt(u32, dest[slots..][0..4], context, .little);
    std.mem.writeInt(u32, dest[slots + 4 ..][0..4], router, .little);
}

/// For the arch tests.
pub const tests = struct {
    pub const changed_arg = 41;

    pub noinline fn returnFirstArg(a: u32) callconv(.c) u32 {
        var x = a;
        asm volatile (""
            : [x] "+r" (x),
        );
        return x;
    }

    /// cdecl's first arg is just above the return address.
    pub fn firstArg(cpu: *const CpuContext) usize {
        return @as(*const u32, @ptrFromInt(cpu.esp + 4)).*;
    }

    pub fn changeFirstArg(cpu: *CpuContext) void {
        const arg: *u32 = @ptrFromInt(cpu.esp + 4);
        arg.* = changed_arg;
    }
};
