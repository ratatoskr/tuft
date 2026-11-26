//! x64 registers for mid hooks and exceptions, laid out like the mid stub pushes them.

pub const CpuContext = extern struct {
    // 16 XMM registers, offsets 0..255
    xmm0: XmmReg,
    xmm1: XmmReg,
    xmm2: XmmReg,
    xmm3: XmmReg,
    xmm4: XmmReg,
    xmm5: XmmReg,
    xmm6: XmmReg,
    xmm7: XmmReg,
    xmm8: XmmReg,
    xmm9: XmmReg,
    xmm10: XmmReg,
    xmm11: XmmReg,
    xmm12: XmmReg,
    xmm13: XmmReg,
    xmm14: XmmReg,
    xmm15: XmmReg,

    // 16 GPRs and RFLAGS, offsets 256..391
    r15: u64,
    r14: u64,
    r13: u64,
    r12: u64,
    r11: u64,
    r10: u64,
    r9: u64,
    r8: u64,
    rdi: u64,
    rsi: u64,
    rbp: u64,
    rsp: u64,
    rbx: u64,
    rdx: u64,
    rcx: u64,
    rax: u64,
    rflags: u64,

    /// Where it runs next; a mid hook can change it. The stub's return slot, keeping the size 16-byte aligned.
    rip: u64,

    // zig fmt: off

    pub inline fn ip(self: CpuContext) usize { return self.rip; }
    pub inline fn setIp(self: *CpuContext, v: usize) void { self.rip = v; }

    pub inline fn eax(self: CpuContext) u32 { return @truncate(self.rax); }
    pub inline fn setEax(self: *CpuContext, v: u32) void { self.rax = v; }
    pub inline fn writeEax(self: *CpuContext, v: u32) void {  self.rax = (self.rax & 0xFFFFFFFF00000000) | v; }
    pub inline fn ax(self: CpuContext) u16 { return @truncate(self.rax); }
    pub inline fn setAx(self: *CpuContext, v: u16) void { self.rax = (self.rax & 0xFFFFFFFFFFFF0000) | v; }
    pub inline fn al(self: CpuContext) u8 { return @truncate(self.rax); }
    pub inline fn setAl(self: *CpuContext, v: u8) void { self.rax = (self.rax & 0xFFFFFFFFFFFFFF00) | v; }

    pub inline fn ecx(self: CpuContext) u32 { return @truncate(self.rcx); }
    pub inline fn setEcx(self: *CpuContext, v: u32) void { self.rcx = v; }
    pub inline fn writeEcx(self: *CpuContext, v: u32) void { self.rcx = (self.rcx & 0xFFFFFFFF00000000) | v; }
    pub inline fn cx(self: CpuContext) u16 { return @truncate(self.rcx); }
    pub inline fn setCx(self: *CpuContext, v: u16) void { self.rcx = (self.rcx & 0xFFFFFFFFFFFF0000) | v; }
    pub inline fn cl(self: CpuContext) u8 { return @truncate(self.rcx); }
    pub inline fn setCl(self: *CpuContext, v: u8) void { self.rcx = (self.rcx & 0xFFFFFFFFFFFFFF00) | v; }

    pub inline fn edx(self: CpuContext) u32 { return @truncate(self.rdx); }
    pub inline fn setEdx(self: *CpuContext, v: u32) void { self.rdx = v; }
    pub inline fn writeEdx(self: *CpuContext, v: u32) void { self.rdx = (self.rdx & 0xFFFFFFFF00000000) | v; }
    pub inline fn dx(self: CpuContext) u16 { return @truncate(self.rdx); }
    pub inline fn setDx(self: *CpuContext, v: u16) void { self.rdx = (self.rdx & 0xFFFFFFFFFFFF0000) | v; }
    pub inline fn dl(self: CpuContext) u8 { return @truncate(self.rdx); }
    pub inline fn setDl(self: *CpuContext, v: u8) void { self.rdx = (self.rdx & 0xFFFFFFFFFFFFFF00) | v; }

    pub inline fn ebx(self: CpuContext) u32 { return @truncate(self.rbx); }
    pub inline fn setEbx(self: *CpuContext, v: u32) void { self.rbx = v; }
    pub inline fn writeEbx(self: *CpuContext, v: u32) void { self.rbx = (self.rbx & 0xFFFFFFFF00000000) | v; }
    pub inline fn bx(self: CpuContext) u16 { return @truncate(self.rbx); }
    pub inline fn setBx(self: *CpuContext, v: u16) void { self.rbx = (self.rbx & 0xFFFFFFFFFFFF0000) | v; }
    pub inline fn bl(self: CpuContext) u8 { return @truncate(self.rbx); }
    pub inline fn setBl(self: *CpuContext, v: u8) void { self.rbx = (self.rbx & 0xFFFFFFFFFFFFFF00) | v; }

    pub inline fn esp(self: CpuContext) u32 { return @truncate(self.rsp); }
    pub inline fn setEsp(self: *CpuContext, v: u32) void { self.rsp = v; }
    pub inline fn writeEsp(self: *CpuContext, v: u32) void { self.rsp = (self.rsp & 0xFFFFFFFF00000000) | v; }
    pub inline fn sp(self: CpuContext) u16 { return @truncate(self.rsp); }
    pub inline fn setSp(self: *CpuContext, v: u16) void { self.rsp = (self.rsp & 0xFFFFFFFFFFFF0000) | v; }
    pub inline fn spl(self: CpuContext) u8 { return @truncate(self.rsp); }
    pub inline fn setSpl(self: *CpuContext, v: u8) void { self.rsp = (self.rsp & 0xFFFFFFFFFFFFFF00) | v; }

    pub inline fn ebp(self: CpuContext) u32 { return @truncate(self.rbp); }
    pub inline fn setEbp(self: *CpuContext, v: u32) void { self.rbp = v; }
    pub inline fn writeEbp(self: *CpuContext, v: u32) void { self.rbp = (self.rbp & 0xFFFFFFFF00000000) | v; }
    pub inline fn bp(self: CpuContext) u16 { return @truncate(self.rbp); }
    pub inline fn setBp(self: *CpuContext, v: u16) void { self.rbp = (self.rbp & 0xFFFFFFFFFFFF0000) | v; }
    pub inline fn bpl(self: CpuContext) u8 { return @truncate(self.rbp); }
    pub inline fn setBpl(self: *CpuContext, v: u8) void { self.rbp = (self.rbp & 0xFFFFFFFFFFFFFF00) | v; }

    pub inline fn esi(self: CpuContext) u32 { return @truncate(self.rsi); }
    pub inline fn setEsi(self: *CpuContext, v: u32) void { self.rsi = v; }
    pub inline fn writeEsi(self: *CpuContext, v: u32) void { self.rsi = (self.rsi & 0xFFFFFFFF00000000) | v; }
    pub inline fn si(self: CpuContext) u16 { return @truncate(self.rsi); }
    pub inline fn setSi(self: *CpuContext, v: u16) void { self.rsi = (self.rsi & 0xFFFFFFFFFFFF0000) | v; }
    pub inline fn sil(self: CpuContext) u8 { return @truncate(self.rsi); }
    pub inline fn setSil(self: *CpuContext, v: u8) void { self.rsi = (self.rsi & 0xFFFFFFFFFFFFFF00) | v; }

    pub inline fn edi(self: CpuContext) u32 { return @truncate(self.rdi); }
    pub inline fn setEdi(self: *CpuContext, v: u32) void { self.rdi = v; }
    pub inline fn writeEdi(self: *CpuContext, v: u32) void { self.rdi = (self.rdi & 0xFFFFFFFF00000000) | v; }
    pub inline fn di(self: CpuContext) u16 { return @truncate(self.rdi); }
    pub inline fn setDi(self: *CpuContext, v: u16) void { self.rdi = (self.rdi & 0xFFFFFFFFFFFF0000) | v; }
    pub inline fn dil(self: CpuContext) u8 { return @truncate(self.rdi); }
    pub inline fn setDil(self: *CpuContext, v: u8) void { self.rdi = (self.rdi & 0xFFFFFFFFFFFFFF00) | v; }

    pub inline fn r8d(self: CpuContext) u32 { return @truncate(self.r8); }
    pub inline fn setR8d(self: *CpuContext, v: u32) void { self.r8 = v; }
    pub inline fn writeR8d(self: *CpuContext, v: u32) void { self.r8 = (self.r8 & 0xFFFFFFFF00000000) | v; }
    pub inline fn r8w(self: CpuContext) u16 { return @truncate(self.r8); }
    pub inline fn setR8w(self: *CpuContext, v: u16) void { self.r8 = (self.r8 & 0xFFFFFFFFFFFF0000) | v; }
    pub inline fn r8b(self: CpuContext) u8 { return @truncate(self.r8); }
    pub inline fn setR8b(self: *CpuContext, v: u8) void { self.r8 = (self.r8 & 0xFFFFFFFFFFFFFF00) | v; }

    pub inline fn r9d(self: CpuContext) u32 { return @truncate(self.r9); }
    pub inline fn setR9d(self: *CpuContext, v: u32) void { self.r9 = v; }
    pub inline fn writeR9d(self: *CpuContext, v: u32) void { self.r9 = (self.r9 & 0xFFFFFFFF00000000) | v; }
    pub inline fn r9w(self: CpuContext) u16 { return @truncate(self.r9); }
    pub inline fn setR9w(self: *CpuContext, v: u16) void { self.r9 = (self.r9 & 0xFFFFFFFFFFFF0000) | v; }
    pub inline fn r9b(self: CpuContext) u8 { return @truncate(self.r9); }
    pub inline fn setR9b(self: *CpuContext, v: u8) void { self.r9 = (self.r9 & 0xFFFFFFFFFFFFFF00) | v; }

    pub inline fn r10d(self: CpuContext) u32 { return @truncate(self.r10); }
    pub inline fn setR10d(self: *CpuContext, v: u32) void { self.r10 = v; }
    pub inline fn writeR10d(self: *CpuContext, v: u32) void { self.r10 = (self.r10 & 0xFFFFFFFF00000000) | v; }
    pub inline fn r10w(self: CpuContext) u16 { return @truncate(self.r10); }
    pub inline fn setR10w(self: *CpuContext, v: u16) void { self.r10 = (self.r10 & 0xFFFFFFFFFFFF0000) | v; }
    pub inline fn r10b(self: CpuContext) u8 { return @truncate(self.r10); }
    pub inline fn setR10b(self: *CpuContext, v: u8) void { self.r10 = (self.r10 & 0xFFFFFFFFFFFFFF00) | v; }

    pub inline fn r11d(self: CpuContext) u32 { return @truncate(self.r11); }
    pub inline fn setR11d(self: *CpuContext, v: u32) void { self.r11 = v; }
    pub inline fn writeR11d(self: *CpuContext, v: u32) void { self.r11 = (self.r11 & 0xFFFFFFFF00000000) | v; }
    pub inline fn r11w(self: CpuContext) u16 { return @truncate(self.r11); }
    pub inline fn setR11w(self: *CpuContext, v: u16) void { self.r11 = (self.r11 & 0xFFFFFFFFFFFF0000) | v; }
    pub inline fn r11b(self: CpuContext) u8 { return @truncate(self.r11); }
    pub inline fn setR11b(self: *CpuContext, v: u8) void { self.r11 = (self.r11 & 0xFFFFFFFFFFFFFF00) | v; }

    pub inline fn r12d(self: CpuContext) u32 { return @truncate(self.r12); }
    pub inline fn setR12d(self: *CpuContext, v: u32) void { self.r12 = v; }
    pub inline fn writeR12d(self: *CpuContext, v: u32) void { self.r12 = (self.r12 & 0xFFFFFFFF00000000) | v; }
    pub inline fn r12w(self: CpuContext) u16 { return @truncate(self.r12); }
    pub inline fn setR12w(self: *CpuContext, v: u16) void { self.r12 = (self.r12 & 0xFFFFFFFFFFFF0000) | v; }
    pub inline fn r12b(self: CpuContext) u8 { return @truncate(self.r12); }
    pub inline fn setR12b(self: *CpuContext, v: u8) void { self.r12 = (self.r12 & 0xFFFFFFFFFFFFFF00) | v; }

    pub inline fn r13d(self: CpuContext) u32 { return @truncate(self.r13); }
    pub inline fn setR13d(self: *CpuContext, v: u32) void { self.r13 = v; }
    pub inline fn writeR13d(self: *CpuContext, v: u32) void { self.r13 = (self.r13 & 0xFFFFFFFF00000000) | v; }
    pub inline fn r13w(self: CpuContext) u16 { return @truncate(self.r13); }
    pub inline fn setR13w(self: *CpuContext, v: u16) void { self.r13 = (self.r13 & 0xFFFFFFFFFFFF0000) | v; }
    pub inline fn r13b(self: CpuContext) u8 { return @truncate(self.r13); }
    pub inline fn setR13b(self: *CpuContext, v: u8) void { self.r13 = (self.r13 & 0xFFFFFFFFFFFFFF00) | v; }

    pub inline fn r14d(self: CpuContext) u32 { return @truncate(self.r14); }
    pub inline fn setR14d(self: *CpuContext, v: u32) void { self.r14 = v; }
    pub inline fn writeR14d(self: *CpuContext, v: u32) void { self.r14 = (self.r14 & 0xFFFFFFFF00000000) | v; }
    pub inline fn r14w(self: CpuContext) u16 { return @truncate(self.r14); }
    pub inline fn setR14w(self: *CpuContext, v: u16) void { self.r14 = (self.r14 & 0xFFFFFFFFFFFF0000) | v; }
    pub inline fn r14b(self: CpuContext) u8 { return @truncate(self.r14); }
    pub inline fn setR14b(self: *CpuContext, v: u8) void { self.r14 = (self.r14 & 0xFFFFFFFFFFFFFF00) | v; }

    pub inline fn r15d(self: CpuContext) u32 { return @truncate(self.r15); }
    pub inline fn setR15d(self: *CpuContext, v: u32) void { self.r15 = v; }
    pub inline fn writeR15d(self: *CpuContext, v: u32) void { self.r15 = (self.r15 & 0xFFFFFFFF00000000) | v; }
    pub inline fn r15w(self: CpuContext) u16 { return @truncate(self.r15); }
    pub inline fn setR15w(self: *CpuContext, v: u16) void { self.r15 = (self.r15 & 0xFFFFFFFFFFFF0000) | v; }
    pub inline fn r15b(self: CpuContext) u8 { return @truncate(self.r15); }
    pub inline fn setR15b(self: *CpuContext, v: u8) void { self.r15 = (self.r15 & 0xFFFFFFFFFFFFFF00) | v; }

    // zig fmt: on
};

const XmmReg = @import("../xmm.zig").XmmReg;

const tests = struct {
    const std = @import("std");

    test "layout matches the mid stub" {
        try std.testing.expectEqual(256, @offsetOf(CpuContext, "r15"));
        try std.testing.expectEqual(384, @offsetOf(CpuContext, "rflags"));
        // The stub writes the resume address here
        try std.testing.expectEqual(392, @offsetOf(CpuContext, "rip"));
        try std.testing.expectEqual(400, @sizeOf(CpuContext));
    }

    test "sub-registers" {
        var cpu = std.mem.zeroes(CpuContext);

        const pattern: u64 = 0xFFFF_FFFF_FFFF_FFFF;

        // 32-bit set zero-extends
        inline for (.{
            .{ .get = CpuContext.eax, .set = CpuContext.setEax, .field = "rax" },
            .{ .get = CpuContext.ecx, .set = CpuContext.setEcx, .field = "rcx" },
            .{ .get = CpuContext.edx, .set = CpuContext.setEdx, .field = "rdx" },
            .{ .get = CpuContext.ebx, .set = CpuContext.setEbx, .field = "rbx" },
            .{ .get = CpuContext.esp, .set = CpuContext.setEsp, .field = "rsp" },
            .{ .get = CpuContext.ebp, .set = CpuContext.setEbp, .field = "rbp" },
            .{ .get = CpuContext.esi, .set = CpuContext.setEsi, .field = "rsi" },
            .{ .get = CpuContext.edi, .set = CpuContext.setEdi, .field = "rdi" },
            .{ .get = CpuContext.r8d, .set = CpuContext.setR8d, .field = "r8" },
            .{ .get = CpuContext.r9d, .set = CpuContext.setR9d, .field = "r9" },
            .{ .get = CpuContext.r10d, .set = CpuContext.setR10d, .field = "r10" },
            .{ .get = CpuContext.r11d, .set = CpuContext.setR11d, .field = "r11" },
            .{ .get = CpuContext.r12d, .set = CpuContext.setR12d, .field = "r12" },
            .{ .get = CpuContext.r13d, .set = CpuContext.setR13d, .field = "r13" },
            .{ .get = CpuContext.r14d, .set = CpuContext.setR14d, .field = "r14" },
            .{ .get = CpuContext.r15d, .set = CpuContext.setR15d, .field = "r15" },
        }) |reg| {
            @field(cpu, reg.field) = pattern;
            reg.set(&cpu, 0x11223344);
            try std.testing.expectEqual(@as(u32, 0x11223344), reg.get(cpu));

            try std.testing.expectEqual(@as(u64, 0x0000_0000_1122_3344), @field(cpu, reg.field));
        }

        // 32-bit write keeps the upper bits
        inline for (.{
            .{ .get = CpuContext.eax, .set = CpuContext.writeEax, .field = "rax" },
            .{ .get = CpuContext.ecx, .set = CpuContext.writeEcx, .field = "rcx" },
            .{ .get = CpuContext.edx, .set = CpuContext.writeEdx, .field = "rdx" },
            .{ .get = CpuContext.ebx, .set = CpuContext.writeEbx, .field = "rbx" },
            .{ .get = CpuContext.esp, .set = CpuContext.writeEsp, .field = "rsp" },
            .{ .get = CpuContext.ebp, .set = CpuContext.writeEbp, .field = "rbp" },
            .{ .get = CpuContext.esi, .set = CpuContext.writeEsi, .field = "rsi" },
            .{ .get = CpuContext.edi, .set = CpuContext.writeEdi, .field = "rdi" },
            .{ .get = CpuContext.r8d, .set = CpuContext.writeR8d, .field = "r8" },
            .{ .get = CpuContext.r9d, .set = CpuContext.writeR9d, .field = "r9" },
            .{ .get = CpuContext.r10d, .set = CpuContext.writeR10d, .field = "r10" },
            .{ .get = CpuContext.r11d, .set = CpuContext.writeR11d, .field = "r11" },
            .{ .get = CpuContext.r12d, .set = CpuContext.writeR12d, .field = "r12" },
            .{ .get = CpuContext.r13d, .set = CpuContext.writeR13d, .field = "r13" },
            .{ .get = CpuContext.r14d, .set = CpuContext.writeR14d, .field = "r14" },
            .{ .get = CpuContext.r15d, .set = CpuContext.writeR15d, .field = "r15" },
        }) |reg| {
            @field(cpu, reg.field) = 0xAABB_CCDD_EEEE_FFFF;
            reg.set(&cpu, 0x11223344);
            try std.testing.expectEqual(@as(u32, 0x11223344), reg.get(cpu));
            try std.testing.expectEqual(@as(u64, 0xAABB_CCDD_1122_3344), @field(cpu, reg.field));
        }

        // 16-bit
        inline for (.{
            .{ .get = CpuContext.ax, .set = CpuContext.setAx, .field = "rax" },
            .{ .get = CpuContext.cx, .set = CpuContext.setCx, .field = "rcx" },
            .{ .get = CpuContext.dx, .set = CpuContext.setDx, .field = "rdx" },
            .{ .get = CpuContext.bx, .set = CpuContext.setBx, .field = "rbx" },
            .{ .get = CpuContext.sp, .set = CpuContext.setSp, .field = "rsp" },
            .{ .get = CpuContext.bp, .set = CpuContext.setBp, .field = "rbp" },
            .{ .get = CpuContext.si, .set = CpuContext.setSi, .field = "rsi" },
            .{ .get = CpuContext.di, .set = CpuContext.setDi, .field = "rdi" },
            .{ .get = CpuContext.r8w, .set = CpuContext.setR8w, .field = "r8" },
            .{ .get = CpuContext.r9w, .set = CpuContext.setR9w, .field = "r9" },
            .{ .get = CpuContext.r10w, .set = CpuContext.setR10w, .field = "r10" },
            .{ .get = CpuContext.r11w, .set = CpuContext.setR11w, .field = "r11" },
            .{ .get = CpuContext.r12w, .set = CpuContext.setR12w, .field = "r12" },
            .{ .get = CpuContext.r13w, .set = CpuContext.setR13w, .field = "r13" },
            .{ .get = CpuContext.r14w, .set = CpuContext.setR14w, .field = "r14" },
            .{ .get = CpuContext.r15w, .set = CpuContext.setR15w, .field = "r15" },
        }) |reg| {
            @field(cpu, reg.field) = pattern;
            reg.set(&cpu, 0xAAAA);
            try std.testing.expectEqual(@as(u16, 0xAAAA), reg.get(cpu));

            try std.testing.expectEqual(@as(u64, 0xFFFF_FFFF_FFFF_AAAA), @field(cpu, reg.field));
        }

        // 8-bit
        inline for (.{
            .{ .get = CpuContext.al, .set = CpuContext.setAl, .field = "rax" },
            .{ .get = CpuContext.cl, .set = CpuContext.setCl, .field = "rcx" },
            .{ .get = CpuContext.dl, .set = CpuContext.setDl, .field = "rdx" },
            .{ .get = CpuContext.bl, .set = CpuContext.setBl, .field = "rbx" },
            .{ .get = CpuContext.spl, .set = CpuContext.setSpl, .field = "rsp" },
            .{ .get = CpuContext.bpl, .set = CpuContext.setBpl, .field = "rbp" },
            .{ .get = CpuContext.sil, .set = CpuContext.setSil, .field = "rsi" },
            .{ .get = CpuContext.dil, .set = CpuContext.setDil, .field = "rdi" },
            .{ .get = CpuContext.r8b, .set = CpuContext.setR8b, .field = "r8" },
            .{ .get = CpuContext.r9b, .set = CpuContext.setR9b, .field = "r9" },
            .{ .get = CpuContext.r10b, .set = CpuContext.setR10b, .field = "r10" },
            .{ .get = CpuContext.r11b, .set = CpuContext.setR11b, .field = "r11" },
            .{ .get = CpuContext.r12b, .set = CpuContext.setR12b, .field = "r12" },
            .{ .get = CpuContext.r13b, .set = CpuContext.setR13b, .field = "r13" },
            .{ .get = CpuContext.r14b, .set = CpuContext.setR14b, .field = "r14" },
            .{ .get = CpuContext.r15b, .set = CpuContext.setR15b, .field = "r15" },
        }) |reg| {
            @field(cpu, reg.field) = pattern;
            reg.set(&cpu, 0xBB);
            try std.testing.expectEqual(0xBB, reg.get(cpu));

            try std.testing.expectEqual(0xFFFF_FFFF_FFFF_FFBB, @field(cpu, reg.field));
        }
    }
};

test {
    _ = tests;
}
