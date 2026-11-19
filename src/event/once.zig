//! Run something once across threads.

const std = @import("std");
const meta = @import("tuft_arch").meta;

/// Late callers wait for the run to finish.
pub const RunOnce = struct {
    // 0 idle, 1 running, 2 finished
    state: std.atomic.Value(u8) = .init(0),

    /// The result if this thread ran it, else null. A failed run still counts.
    pub fn run(self: *RunOnce, comptime func: anytype) ?meta.fnInfo(func).return_type.? {
        if (self.state.load(.seq_cst) == 2) return null;

        if (self.state.cmpxchgStrong(0, 1, .seq_cst, .seq_cst) == null) {
            const result = func();
            self.state.store(2, .seq_cst);
            return result;
        }

        // Wait so nobody runs a follow-up before the first run is done
        while (self.state.load(.seq_cst) != 2) {
            std.Thread.yield() catch {};
        }

        return null;
    }
};

/// Runs `once` the first time and `followup` after.
pub const RunOnceOrFollowup = struct {
    state: RunOnce = .{},

    pub fn run(self: *RunOnceOrFollowup, comptime once: anytype, comptime followup: anytype) meta.fnInfo(once).return_type.? {
        meta.assertBaseReturnTypesMatch(once, followup);

        if (self.state.run(once)) |val| return val;

        return followup();
    }
};

const tests = struct {
    test "RunOnce" {
        const S = struct {
            var calls: u32 = 0;
            fn run() u32 {
                calls += 1;
                return calls;
            }
        };
        S.calls = 0;

        var guard: RunOnce = .{};
        try std.testing.expectEqual(@as(?u32, 1), guard.run(S.run));
        try std.testing.expectEqual(@as(?u32, null), guard.run(S.run));
        try std.testing.expectEqual(@as(?u32, null), guard.run(S.run));
        try std.testing.expectEqual(1, S.calls);
    }

    test "RunOnceOrFollowup" {
        const S = struct {
            var first: u32 = 0;
            var second: u32 = 0;
            fn once() void {
                first += 1;
            }
            fn followup() void {
                second += 1;
            }
        };
        S.first = 0;
        S.second = 0;

        var branch: RunOnceOrFollowup = .{};
        branch.run(S.once, S.followup);
        branch.run(S.once, S.followup);
        branch.run(S.once, S.followup);
        try std.testing.expectEqual(1, S.first);
        try std.testing.expectEqual(2, S.second);
    }
};

test {
    _ = tests;
}
