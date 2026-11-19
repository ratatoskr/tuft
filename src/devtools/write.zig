//! Writes typed values to memory without touching claimed bytes.

const std = @import("std");

const mem = @import("tuft_mem");

const root = @import("root.zig");

const Kind = mem.values.Kind;

/// Like `mem.values.parse` but no wildcards, there'd be nothing to write.
pub fn valueBytes(kind: Kind, text: []const u8, out: *[mem.values.max_len]u8) mem.values.Error![]const u8 {
    var parsed: [mem.values.max_len]?u8 = undefined;
    const p = try mem.values.parse(kind, text, &parsed);
    for (p, out[0..p.len]) |b, *o| o.* = b orelse return error.InvalidValue;
    return out[0..p.len];
}

/// Null if written, else why not.
pub fn store(memory: mem.Memory, claims: mem.Claims, address: usize, bytes: []const u8) ?root.Problem {
    if (claims.first(address, bytes.len)) |claim| return root.claimed(address, &claim);
    memory.write(address, bytes) catch |err| return .init("Couldn't write there: {t}", .{err});
    return null;
}

const tests = struct {
    const testing = std.testing;

    test "typed value bytes" {
        var buf: [mem.values.max_len]u8 = undefined;
        try testing.expectEqualSlices(u8, &.{ 0xFE, 0xFF }, try valueBytes(.two_bytes, "-2", &buf));
        try testing.expectEqualSlices(u8, "Hi", try valueBytes(.text, "Hi", &buf));
        try testing.expectEqualSlices(u8, &.{ 0x48, 0xC3 }, try valueBytes(.bytes, "48 C3", &buf));
        try testing.expectError(error.InvalidValue, valueBytes(.bytes, "48 ?? C3", &buf));
        try testing.expectError(error.ValueOutOfRange, valueBytes(.byte, "256", &buf));
    }

    test "store and refusals" {
        var bytes: [4]u8 = @splat(0);
        try testing.expectEqual(null, store(.local, .none, @intFromPtr(&bytes), &.{ 1, 2 }));
        try testing.expectEqualSlices(u8, &.{ 1, 2, 0, 0 }, &bytes);
        try testing.expectEqualStrings("Couldn't write there: Unwritable", store(.local, .none, 0, &.{1}).?.message());

        const Held = struct {
            fn find(_: ?*anyopaque, start: usize, len: usize, out: []mem.Claims.Claim) usize {
                const claim: mem.Claims.Claim = .{ .start = 0x2002, .len = 5, .kind = .hook, .id = 7 };
                if (!claim.overlaps(start, len) or out.len == 0) return 0;
                out[0] = claim;
                return 1;
            }
        };
        const held: mem.Claims = .{ .vtable = &.{ .find = Held.find } };
        try testing.expectEqualStrings("0x2000 is hook 7's: remove that before changing it", store(.local, held, 0x2000, &.{ 1, 2, 3, 4 }).?.message());
    }
};

test {
    _ = tests;
}
