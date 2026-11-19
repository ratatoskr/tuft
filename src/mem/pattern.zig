//! IDA-style signatures like `48 8B ?? C3`.

const std = @import("std");

/// `null` matches anything.
pub const Pattern = []const ?u8;

/// Bad signatures are compile errors.
pub fn parse(comptime signature: []const u8) Pattern {
    return comptime blk: {
        var buf: [signature.len]?u8 = undefined;
        const parsed = parseInto(signature, &buf) catch |err|
            @compileError("invalid signature \"" ++ signature ++ "\": " ++ @errorName(err));
        const final: [parsed.len]?u8 = parsed[0..parsed.len].*;
        break :blk &final;
    };
}

/// One entry per character is always enough.
pub fn parseInto(signature: []const u8, buf: []?u8) ![]?u8 {
    var i: usize = 0;
    var n: usize = 0;
    while (i < signature.len) {
        const c = signature[i];
        if (c == ' ') {
            i += 1;
            continue;
        }
        if (n == buf.len) return error.BufferTooSmall;

        if (c == '?') {
            i += 1;
            if (i < signature.len and signature[i] == '?') i += 1;
            buf[n] = null;
        } else {
            if (i + 1 >= signature.len) return error.InvalidSignature;
            buf[n] = std.fmt.parseInt(u8, signature[i..][0..2], 16) catch return error.InvalidSignature;
            i += 2;
        }
        n += 1;
    }
    if (n == 0) return error.EmptySignature;
    return buf[0..n];
}

pub fn find(hay: []const u8, p: Pattern, from: usize) ?usize {
    if (p.len == 0 or from > hay.len or p.len > hay.len - from) return null;

    // Jump between hits of a rare fixed byte, 00 and FF are everywhere
    var anchor: ?usize = null;
    for (p, 0..) |b, i| {
        const v = b orelse continue;
        if (anchor == null) anchor = i;
        if (v != 0x00 and v != 0xFF) {
            anchor = i;
            break;
        }
    }
    const a = anchor orelse return from;
    const anchor_byte = p[a].?;

    var pos = from;
    while (pos + p.len <= hay.len) {
        const hit = std.mem.indexOfScalarPos(u8, hay, pos + a, anchor_byte) orelse return null;
        const candidate = hit - a;
        if (candidate + p.len > hay.len) return null;
        if (matches(hay[candidate..][0..p.len], p)) return candidate;
        pos = candidate + 1;
    }
    return null;
}

/// `bytes` has to be as long as `p`.
pub fn matches(bytes: []const u8, p: Pattern) bool {
    for (p, bytes) |want, have| {
        if (want) |w| if (w != have) return false;
    }
    return true;
}

test "parse" {
    try std.testing.expectEqualSlices(?u8, &.{ 0x01, 0xFF, 0x0a }, parse("01 FF 0a"));
    try std.testing.expectEqualSlices(?u8, &.{ 0x48, null, null, 0xC3 }, parse("48 ?? ? C3"));
    try std.testing.expectEqualSlices(?u8, &.{ 0x0a, 0x0b, null }, parse("0a0b??"));
}

test "malformed signatures" {
    var buf: [16]?u8 = undefined;
    try std.testing.expectError(error.InvalidSignature, parseInto("01 02 0", &buf));
    try std.testing.expectError(error.InvalidSignature, parseInto("01 GG", &buf));
    try std.testing.expectError(error.InvalidSignature, parseInto("?1 02", &buf));
    try std.testing.expectError(error.EmptySignature, parseInto("   ", &buf));
    var tiny: [2]?u8 = undefined;
    try std.testing.expectError(error.BufferTooSmall, parseInto("01 02 03", &tiny));
}
