pub const XmmReg = extern union {
    u128: u128,
    f32x4: [4]f32,
    f64x2: [2]f64,
    u32x4: [4]u32,
    u64x2: [2]u64,

    pub fn scalarF32(self: XmmReg) f32 {
        return self.f32x4[0];
    }

    pub fn setScalarF32(self: *XmmReg, val: f32) void {
        self.f32x4[0] = val;
    }

    pub fn scalarF64(self: XmmReg) f64 {
        return self.f64x2[0];
    }

    pub fn setScalarF64(self: *XmmReg, val: f64) void {
        self.f64x2[0] = val;
    }
};

const tests = struct {
    const std = @import("std");

    test "XmmReg scalar lanes" {
        var reg = std.mem.zeroes(XmmReg);

        reg.u128 = 0xFFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF;
        reg.setScalarF32(123.45);
        try std.testing.expectApproxEqAbs(123.45, reg.scalarF32(), 0.00001);

        try std.testing.expectEqual(0xFFFF_FFFF, reg.u32x4[1]);
        try std.testing.expectEqual(0xFFFF_FFFF, reg.u32x4[2]);
        try std.testing.expectEqual(0xFFFF_FFFF, reg.u32x4[3]);

        reg.u128 = 0xFFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF_FFFF;
        reg.setScalarF64(987.654321);
        try std.testing.expectApproxEqAbs(987.654321, reg.scalarF64(), 0.0000001);

        try std.testing.expectEqual(0xFFFF_FFFF_FFFF_FFFF, reg.u64x2[1]);
    }
};

test {
    _ = tests;
}
