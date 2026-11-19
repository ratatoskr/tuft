//! Instruction set basics, backed by `x64/` or `x86/`.

const std = @import("std");

const native = @import("native.zig").native;

pub const atomic = @import("atomic.zig");
pub const meta = @import("meta.zig");
pub const insn = @import("insn.zig");
pub const relocate = @import("relocate.zig");
/// Calls and detours for signatures only known while running, from salamander.
pub const dyn = @import("salamander_dyn");

pub const bits = native.bits;

pub const CpuContext = native.CpuContext;
pub const XmmReg = @import("xmm.zig").XmmReg;

pub const near_jmp_len = 5;
pub const max_jmp_len = native.max_jmp_len;
/// True if `rel32` reaches everywhere.
pub const near_reaches_all = native.near_reaches_all;
pub const near_range: usize = native.near_range;

/// Null if `to` is out of reach.
pub fn encodeNearJmp(from: usize, to: usize) ?[near_jmp_len]u8 {
    const rel32 = native.reach(from + near_jmp_len, to) orelse return null;
    var out: [near_jmp_len]u8 = .{ 0xE9, 0, 0, 0, 0 };
    std.mem.writeInt(i32, out[1..5], rel32, .little);
    return out;
}

/// Near jump if it reaches, else absolute.
pub const Jmp = struct {
    bytes: [max_jmp_len]u8,
    len: u8,

    pub fn slice(self: *const Jmp) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub fn encodeJmp(from: usize, to: usize) Jmp {
    var out: Jmp = .{ .bytes = @splat(0xCC), .len = near_jmp_len };
    if (encodeNearJmp(from, to)) |near| {
        out.bytes[0..near_jmp_len].* = near;
        return out;
    }
    const abs = native.encodeAbsJmp(to);
    out.bytes[0..abs.len].* = abs;
    out.len = abs.len;
    return out;
}

pub const abs_jmp_len = native.abs_jmp_len;

pub fn encodeAbsJmp(to: usize) [abs_jmp_len]u8 {
    return native.encodeAbsJmp(to);
}

/// How a stub finds a thread-local. `sys` fills this in.
pub const TlsSlot = struct {
    segment: Segment,
    array_offset: u32,
    index: u32,
    offset: u32,

    pub const Segment = enum { fs, gs };
};

pub const fn_stub_size = native.fn_stub_size;

/// Stores `value` in the thread-local at `tls`, then jumps to `entry`. `dest` must be where it runs.
pub fn writeFnStub(dest: *[fn_stub_size]u8, value: usize, tls: TlsSlot, entry: usize) void {
    native.writeFnStub(dest, value, tls, entry);
}

/// Gets the registers, which it can change. Returns where to resume.
pub const MidRouter = fn (context: usize, cpu: *CpuContext) callconv(.c) usize;

pub fn midStubSize() usize {
    return native.midStubSize();
}

/// Saves registers, calls `router` and jumps where it says.
pub fn writeMidStub(dest: []u8, context: usize, router: *const MidRouter) void {
    native.writeMidStub(dest, context, @intFromPtr(router));
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("xmm.zig");
    _ = native;
}

/// For `tests/arch.zig`.
pub const testing = native.tests;

const tests = struct {
    test "encodeJmp near or absolute" {
        const near = encodeJmp(0x1000, 0x2000);
        try std.testing.expectEqual(near_jmp_len, near.len);
        try std.testing.expectEqual(0xE9, near.bytes[0]);
        try std.testing.expectEqual(0x2000 - 0x1005, std.mem.readInt(i32, near.bytes[1..5], .little));

        const far = encodeJmp(0x1000, std.math.maxInt(usize) - 0x1000);
        try std.testing.expectEqual(if (near_reaches_all) near_jmp_len else abs_jmp_len, far.len);
    }
};

test {
    _ = tests;
}
