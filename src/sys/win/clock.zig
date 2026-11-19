//! Performance counter in nanoseconds.

const std = @import("std");

const arch = @import("tuft_arch");

const win = @import("api.zig");

var frequency: arch.atomic.Value(u64) = .init(0);

pub fn nanos() u64 {
    var counter: i64 = 0;
    _ = win.QueryPerformanceCounter(&counter);
    var freq = frequency.load(.monotonic);
    if (freq == 0) {
        var f: i64 = 0;
        _ = win.QueryPerformanceFrequency(&f);
        freq = @intCast(f);
        frequency.store(freq, .monotonic);
    }
    return @intCast(@as(u128, @intCast(counter)) * std.time.ns_per_s / freq);
}

test "clock moves forward" {
    const a = nanos();
    std.Thread.yield() catch {};
    try std.testing.expect(nanos() >= a);
}
