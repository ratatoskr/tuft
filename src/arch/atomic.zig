//! Atomics wider than native, via `lock cmpxchg8b` on x86.

const std = @import("std");
const builtin = @import("builtin");

const AtomicOrder = std.builtin.AtomicOrder;
const AtomicRmwOp = std.builtin.AtomicRmwOp;

pub const native_bits = switch (builtin.cpu.arch) {
    .x86 => 32,
    else => 64,
};

fn isWide(comptime T: type) bool {
    return @bitSizeOf(T) > native_bits;
}

fn Bits(comptime T: type) type {
    if (@bitSizeOf(T) != 64) @compileError("Wide atomics are only implemented for 64-bit types, not " ++ @typeName(T));
    return u64;
}

pub fn Value(comptime T: type) type {
    if (comptime !isWide(T)) return std.atomic.Value(T);
    return extern struct {
        raw: T align(8),

        const Self = @This();

        pub fn init(value: T) Self {
            return .{ .raw = value };
        }

        pub fn load(self: *const Self, comptime order: AtomicOrder) T {
            return atomic.load(T, &self.raw, order);
        }

        pub fn store(self: *Self, value: T, comptime order: AtomicOrder) void {
            atomic.store(T, &self.raw, value, order);
        }

        pub fn swap(self: *Self, value: T, comptime order: AtomicOrder) T {
            return rmw(T, &self.raw, .Xchg, value, order);
        }

        pub fn cmpxchgStrong(self: *Self, expected: T, new: T, comptime success: AtomicOrder, comptime failure: AtomicOrder) ?T {
            return cmpxchg(T, &self.raw, expected, new, success, failure);
        }

        pub fn cmpxchgWeak(self: *Self, expected: T, new: T, comptime success: AtomicOrder, comptime failure: AtomicOrder) ?T {
            return cmpxchg(T, &self.raw, expected, new, success, failure);
        }

        pub fn fetchAdd(self: *Self, operand: T, comptime order: AtomicOrder) T {
            return rmw(T, &self.raw, .Add, operand, order);
        }

        pub fn fetchSub(self: *Self, operand: T, comptime order: AtomicOrder) T {
            return rmw(T, &self.raw, .Sub, operand, order);
        }

        pub fn fetchOr(self: *Self, operand: T, comptime order: AtomicOrder) T {
            return rmw(T, &self.raw, .Or, operand, order);
        }

        pub fn fetchAnd(self: *Self, operand: T, comptime order: AtomicOrder) T {
            return rmw(T, &self.raw, .And, operand, order);
        }

        pub fn fetchMax(self: *Self, operand: T, comptime order: AtomicOrder) T {
            return rmw(T, &self.raw, .Max, operand, order);
        }

        pub fn fetchMin(self: *Self, operand: T, comptime order: AtomicOrder) T {
            return rmw(T, &self.raw, .Min, operand, order);
        }
    };
}

const atomic = @This();

pub fn load(comptime T: type, ptr: *const T, comptime order: AtomicOrder) T {
    if (comptime !isWide(T)) return @atomicLoad(T, ptr, order);
    // A cmpxchg of 0 with 0 reads without changing it
    const p: *Bits(T) = @ptrCast(@constCast(ptr));
    return @bitCast(cas(p, 0, 0));
}

pub fn store(comptime T: type, ptr: *T, value: T, comptime order: AtomicOrder) void {
    if (comptime !isWide(T)) return @atomicStore(T, ptr, value, order);
    _ = rmw(T, ptr, .Xchg, value, order);
}

/// Returns the previous value.
pub fn rmw(comptime T: type, ptr: *T, comptime op: AtomicRmwOp, operand: T, comptime order: AtomicOrder) T {
    if (comptime !isWide(T)) return @atomicRmw(T, ptr, op, operand, order);
    const p: *Bits(T) = @ptrCast(ptr);
    // A torn first read is fine, the cmpxchg just fails
    var old: T = @bitCast(@as(*volatile Bits(T), p).*);
    while (true) {
        const new: T = switch (op) {
            .Xchg => operand,
            .Add => old +% operand,
            .Sub => old -% operand,
            .And => old & operand,
            .Nand => ~(old & operand),
            .Or => old | operand,
            .Xor => old ^ operand,
            .Max => @max(old, operand),
            .Min => @min(old, operand),
        };
        const seen: T = @bitCast(cas(p, @bitCast(old), @bitCast(new)));
        if (seen == old) return old;
        old = seen;
    }
}

/// Null on success, else the value found.
pub fn cmpxchg(comptime T: type, ptr: *T, expected: T, new: T, comptime success: AtomicOrder, comptime failure: AtomicOrder) ?T {
    if (comptime !isWide(T)) return @cmpxchgStrong(T, ptr, expected, new, success, failure);
    const seen: T = @bitCast(cas(@ptrCast(ptr), @bitCast(expected), @bitCast(new)));
    return if (seen == expected) null else seen;
}

/// `lock cmpxchg8b`. Returns what `*ptr` held.
inline fn cas(ptr: *u64, expected: u64, new: u64) u64 {
    if (builtin.cpu.arch != .x86) @compileError("Wide atomics are only needed on x86");
    var lo: u32 = @truncate(expected);
    var hi: u32 = @truncate(expected >> 32);
    asm volatile (
        \\.intel_syntax noprefix
        \\lock cmpxchg8b qword ptr [%[ptr:V]]
        \\.att_syntax prefix
        : [lo] "+{eax}" (lo),
          [hi] "+{edx}" (hi),
        : [ptr] "{esi}" (ptr),
          [new_lo] "{ebx}" (@as(u32, @truncate(new))),
          [new_hi] "{ecx}" (@as(u32, @truncate(new >> 32))),
        : .{ .memory = true, .cc = true });
    return (@as(u64, hi) << 32) | lo;
}

const tests = struct {
    const testing = std.testing;

    test "Value(u64) full width ops" {
        var v: Value(u64) = .init(0xFFFF_FFFF);
        try testing.expectEqual(0xFFFF_FFFF, v.fetchAdd(1, .monotonic));
        try testing.expectEqual(0x1_0000_0000, v.load(.monotonic));
        v.store(0x1234_5678_9ABC_DEF0, .release);
        try testing.expectEqual(0x1234_5678_9ABC_DEF0, v.fetchOr(1, .acq_rel));
        try testing.expectEqual(0x1234_5678_9ABC_DEF1, v.fetchSub(0x1234_5678_0000_0000, .monotonic));
        try testing.expectEqual(0x9ABC_DEF1, v.fetchMax(5, .monotonic));
        try testing.expectEqual(null, v.cmpxchgStrong(0x9ABC_DEF1, 7, .seq_cst, .seq_cst));
        try testing.expectEqual(7, v.cmpxchgStrong(0, 8, .seq_cst, .seq_cst));
        try testing.expectEqual(7, v.swap(9, .seq_cst));
    }

    test "free functions on fields" {
        var x: u64 = 1 << 40;
        _ = rmw(u64, &x, .Add, 1, .monotonic);
        try testing.expectEqual((1 << 40) + 1, load(u64, &x, .monotonic));
        store(u64, &x, 3, .monotonic);
        try testing.expectEqual(3, x);
    }

    test "concurrent increments" {
        var v: Value(u64) = .init(0);
        const per_thread = 20_000;
        const Worker = struct {
            fn run(value: *Value(u64)) void {
                for (0..per_thread) |_| _ = value.fetchAdd((1 << 32) | 1, .monotonic);
            }
        };
        var threads: [4]std.Thread = undefined;
        for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Worker.run, .{&v});
        for (threads) |t| t.join();
        const n: u64 = threads.len * per_thread;
        try testing.expectEqual((n << 32) | n, v.load(.monotonic));
    }
};

test {
    _ = tests;
}
