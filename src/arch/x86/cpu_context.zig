//! x86 registers for mid hooks and exceptions. Changing `esp` in a mid hook does nothing.

const XmmReg = @import("../xmm.zig").XmmReg;

pub const CpuContext = extern struct {
    xmm0: XmmReg,
    xmm1: XmmReg,
    xmm2: XmmReg,
    xmm3: XmmReg,
    xmm4: XmmReg,
    xmm5: XmmReg,
    xmm6: XmmReg,
    xmm7: XmmReg,

    edi: u32,
    esi: u32,
    ebp: u32,
    esp: u32,
    ebx: u32,
    edx: u32,
    ecx: u32,
    eax: u32,
    eflags: u32,
    /// Where it runs next. A mid hook can change it to carry on somewhere else instead of the original code.
    /// The mid stub's return slot.
    eip: u32,

    // zig fmt: off

    pub inline fn ip(self: CpuContext) usize { return self.eip; }
    pub inline fn setIp(self: *CpuContext, v: usize) void { self.eip = @intCast(v); }

    pub inline fn ax(self: CpuContext) u16 { return @truncate(self.eax); }
    pub inline fn setAx(self: *CpuContext, v: u16) void { self.eax = (self.eax & 0xFFFF0000) | v; }
    pub inline fn al(self: CpuContext) u8 { return @truncate(self.eax); }
    pub inline fn setAl(self: *CpuContext, v: u8) void { self.eax = (self.eax & 0xFFFFFF00) | v; }
    pub inline fn ah(self: CpuContext) u8 { return @truncate(self.eax >> 8); }
    pub inline fn setAh(self: *CpuContext, v: u8) void { self.eax = (self.eax & 0xFFFF00FF) | (@as(u32, v) << 8); }

    pub inline fn cx(self: CpuContext) u16 { return @truncate(self.ecx); }
    pub inline fn setCx(self: *CpuContext, v: u16) void { self.ecx = (self.ecx & 0xFFFF0000) | v; }
    pub inline fn cl(self: CpuContext) u8 { return @truncate(self.ecx); }
    pub inline fn setCl(self: *CpuContext, v: u8) void { self.ecx = (self.ecx & 0xFFFFFF00) | v; }
    pub inline fn ch(self: CpuContext) u8 { return @truncate(self.ecx >> 8); }
    pub inline fn setCh(self: *CpuContext, v: u8) void { self.ecx = (self.ecx & 0xFFFF00FF) | (@as(u32, v) << 8); }

    pub inline fn dx(self: CpuContext) u16 { return @truncate(self.edx); }
    pub inline fn setDx(self: *CpuContext, v: u16) void { self.edx = (self.edx & 0xFFFF0000) | v; }
    pub inline fn dl(self: CpuContext) u8 { return @truncate(self.edx); }
    pub inline fn setDl(self: *CpuContext, v: u8) void { self.edx = (self.edx & 0xFFFFFF00) | v; }
    pub inline fn dh(self: CpuContext) u8 { return @truncate(self.edx >> 8); }
    pub inline fn setDh(self: *CpuContext, v: u8) void { self.edx = (self.edx & 0xFFFF00FF) | (@as(u32, v) << 8); }

    pub inline fn bx(self: CpuContext) u16 { return @truncate(self.ebx); }
    pub inline fn setBx(self: *CpuContext, v: u16) void { self.ebx = (self.ebx & 0xFFFF0000) | v; }
    pub inline fn bl(self: CpuContext) u8 { return @truncate(self.ebx); }
    pub inline fn setBl(self: *CpuContext, v: u8) void { self.ebx = (self.ebx & 0xFFFFFF00) | v; }
    pub inline fn bh(self: CpuContext) u8 { return @truncate(self.ebx >> 8); }
    pub inline fn setBh(self: *CpuContext, v: u8) void { self.ebx = (self.ebx & 0xFFFF00FF) | (@as(u32, v) << 8); }

    pub inline fn sp(self: CpuContext) u16 { return @truncate(self.esp); }
    pub inline fn bp(self: CpuContext) u16 { return @truncate(self.ebp); }
    pub inline fn setBp(self: *CpuContext, v: u16) void { self.ebp = (self.ebp & 0xFFFF0000) | v; }
    pub inline fn si(self: CpuContext) u16 { return @truncate(self.esi); }
    pub inline fn setSi(self: *CpuContext, v: u16) void { self.esi = (self.esi & 0xFFFF0000) | v; }
    pub inline fn di(self: CpuContext) u16 { return @truncate(self.edi); }
    pub inline fn setDi(self: *CpuContext, v: u16) void { self.edi = (self.edi & 0xFFFF0000) | v; }

    // zig fmt: on
};

const tests = struct {
    const std = @import("std");

    test "sub-registers" {
        var cpu = std.mem.zeroes(CpuContext);
        cpu.eax = 0x1122_3344;
        try std.testing.expectEqual(0x3344, cpu.ax());
        try std.testing.expectEqual(0x44, cpu.al());
        try std.testing.expectEqual(0x33, cpu.ah());
        cpu.setAh(0xAB);
        try std.testing.expectEqual(0x1122_AB44, cpu.eax);
        cpu.setAx(0xBEEF);
        try std.testing.expectEqual(0x1122_BEEF, cpu.eax);
        cpu.setDl(0x01);
        try std.testing.expectEqual(0x01, cpu.edx);
    }

    test "pushad layout" {
        try std.testing.expectEqual(128, @offsetOf(CpuContext, "edi"));
        try std.testing.expectEqual(140, @offsetOf(CpuContext, "esp"));
        try std.testing.expectEqual(156, @offsetOf(CpuContext, "eax"));
        try std.testing.expectEqual(160, @offsetOf(CpuContext, "eflags"));
        // The stub writes the resume address here
        try std.testing.expectEqual(164, @offsetOf(CpuContext, "eip"));
    }
};

test {
    _ = tests;
}
