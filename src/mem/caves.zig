//! Code caves, unused int3 padding or section slack in a module's code.

const std = @import("std");

const arch = @import("tuft_arch");

const Claims = @import("Claims.zig");
const Module = @import("root.zig").Module;
const pages = @import("pages.zig");

/// `min_len` free bytes within `arch.near_range` of `near`, or null.
pub fn findCodeCave(near: usize, min_len: usize) ?usize {
    return findCodeCaveWhere(near, min_len, null);
}

/// Turns down caves someone else is about to use, or ones out of reach of something.
pub const Filter = struct {
    context: ?*const anyopaque = null,
    accept: *const fn (context: ?*const anyopaque, at: usize, len: usize) bool,
};

/// Like `findCodeCave`, skipping any `filter` turns down.
pub fn findCodeCaveWhere(near: usize, min_len: usize, filter: ?Filter) ?usize {
    if (min_len == 0) return null;

    const module = Module.containing(near) catch return null;
    var it = module.sections() catch return null;

    // Pad up front, real instructions can end in 0xCC bytes
    const required_run = min_len + 8;

    var current = it.next();
    while (current) |sec| {
        const following = it.next();
        defer current = following;
        if (!sec.executable) continue;

        const bytes: [*]const u8 = @ptrFromInt(sec.start);

        // Skip NOP runs, compilers pad inside functions with them too
        var run_len: usize = 0;
        for (0..sec.len) |i| {
            run_len = if (bytes[i] == 0xCC) run_len + 1 else 0;
            if (run_len >= required_run) {
                const cave = sec.start + i + 1 - min_len;
                if (!isNear(cave, near)) continue;
                if (usable(cave, min_len, filter)) return cave;
                // Taken, so look for a whole new run after it
                run_len = 0;
            }
        }

        // Stop at the next section, images can align them tighter than a page
        const slack_start = sec.start + sec.len;
        var slack_end = std.mem.alignForward(usize, slack_start, pages.size);
        if (following) |next| slack_end = @min(slack_end, next.start);
        // Slack can hold a few, so step past ones that are taken
        var at = slack_start;
        while (at + min_len <= slack_end) : (at += 16) {
            if (isNear(at, near) and usable(at, min_len, filter)) return at;
        }
    }
    return null;
}

fn usable(at: usize, len: usize, filter: ?Filter) bool {
    if (Claims.local.first(at, len) != null) return false;
    const f = filter orelse return true;
    return f.accept(f.context, at, len);
}

fn isNear(a: usize, b: usize) bool {
    const dist = if (a >= b) a - b else b - a;
    return dist <= arch.near_range;
}

fn caveTarget(x: u32) callconv(.c) u32 {
    return x + 42;
}

test "padding and slack, skipping claims" {
    const testing = std.testing;
    const target = @intFromPtr(&caveTarget);
    const cave = findCodeCave(target, 14) orelse return error.SkipZigTest;
    try testing.expect(isNear(cave, target));
    for (@as([*]const u8, @ptrFromInt(cave))[0..14]) |b| try testing.expect(b == 0x00 or b == 0xCC);

    Claims.enable(testing.allocator);
    defer Claims.disable();
    try Claims.add(.{ .start = cave, .len = 14, .kind = .code, .id = 1 });
    if (findCodeCave(target, 14)) |other| {
        try testing.expect(other + 14 <= cave or other >= cave + 14);
    }
}
