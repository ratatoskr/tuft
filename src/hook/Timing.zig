//! Hook callback call counts and timings. Safe from any thread.

const Timing = @This();

const atomic = @import("tuft_arch").atomic;

calls: u64 = 0,
total_ns: u64 = 0,
max_ns: u64 = 0,
last_ns: u64 = 0,

pub const Figures = struct {
    calls: u64 = 0,
    total_ns: u64 = 0,
    max_ns: u64 = 0,
    last_ns: u64 = 0,
};

pub fn record(self: *Timing, ns: u64) void {
    _ = atomic.rmw(u64, &self.calls, .Add, 1, .monotonic);
    _ = atomic.rmw(u64, &self.total_ns, .Add, ns, .monotonic);
    atomic.store(u64, &self.last_ns, ns, .monotonic);
    _ = atomic.rmw(u64, &self.max_ns, .Max, ns, .monotonic);
}

pub fn figures(self: *const Timing) Figures {
    return .{
        .calls = atomic.load(u64, &self.calls, .monotonic),
        .total_ns = atomic.load(u64, &self.total_ns, .monotonic),
        .max_ns = atomic.load(u64, &self.max_ns, .monotonic),
        .last_ns = atomic.load(u64, &self.last_ns, .monotonic),
    };
}

pub fn reset(self: *Timing) void {
    atomic.store(u64, &self.calls, 0, .monotonic);
    atomic.store(u64, &self.total_ns, 0, .monotonic);
    atomic.store(u64, &self.max_ns, 0, .monotonic);
    atomic.store(u64, &self.last_ns, 0, .monotonic);
}

test "accumulates and resets" {
    const std = @import("std");
    var t: Timing = .{};
    t.record(5);
    t.record(20);
    t.record(10);
    const f = t.figures();
    try std.testing.expectEqual(3, f.calls);
    try std.testing.expectEqual(35, f.total_ns);
    try std.testing.expectEqual(20, f.max_ns);
    try std.testing.expectEqual(10, f.last_ns);
    t.reset();
    try std.testing.expectEqual(0, t.figures().calls);
}
