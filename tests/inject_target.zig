//! Tiny idle process for injection tests.

const std = @import("std");

pub fn main() void {
    var remaining: usize = 3000;
    while (remaining > 0) : (remaining -= 1) {
        std.Thread.yield() catch {};
        var i: u64 = 0;
        while (i < 200_000) : (i += 1) std.mem.doNotOptimizeAway(i);
    }
}
