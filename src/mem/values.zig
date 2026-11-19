//! Values as they sit in memory, little-endian like x86.

const std = @import("std");

const pattern = @import("pattern.zig");
const Pattern = pattern.Pattern;
const Location = @import("Location.zig");

pub const Kind = enum {
    byte,
    two_bytes,
    four_bytes,
    eight_bytes,
    float,
    double,
    text,
    text_utf16,
    bytes,

    pub fn label(kind: Kind) [:0]const u8 {
        return switch (kind) {
            .byte => "Byte",
            .two_bytes => "2 Bytes",
            .four_bytes => "4 Bytes",
            .eight_bytes => "8 Bytes",
            .float => "Float",
            .double => "Double",
            .text => "Text (UTF-8)",
            .text_utf16 => "Text (UTF-16)",
            .bytes => "Byte pattern",
        };
    }

    /// Null if it depends on the value.
    pub fn size(kind: Kind) ?usize {
        return switch (kind) {
            .byte => 1,
            .two_bytes => 2,
            .four_bytes, .float => 4,
            .eight_bytes, .double => 8,
            .text, .text_utf16, .bytes => null,
        };
    }

    pub fn isNumber(kind: Kind) bool {
        return kind.size() != null;
    }

    pub fn alignment(kind: Kind) usize {
        return kind.size() orelse 1;
    }
};

pub const max_len = 256;

pub const Error = error{
    InvalidValue,
    ValueOutOfRange,
    EmptyValue,
    ValueTooLong,
};

/// Numbers are decimal unless they start with 0x or end in h. `max_len` is plenty for `buf`.
pub fn parse(kind: Kind, text: []const u8, buf: []?u8) Error![]?u8 {
    const t = std.mem.trim(u8, text, " \t");
    if (t.len == 0) return error.EmptyValue;
    var bytes: [max_len]u8 = undefined;
    const raw: []const u8 = switch (kind) {
        .byte => try int(u8, t, &bytes),
        .two_bytes => try int(u16, t, &bytes),
        .four_bytes => try int(u32, t, &bytes),
        .eight_bytes => try int(u64, t, &bytes),
        .float => try float(f32, t, &bytes),
        .double => try float(f64, t, &bytes),
        .text => blk: {
            if (t.len > max_len) return error.ValueTooLong;
            break :blk t;
        },
        .text_utf16 => blk: {
            var wide: [max_len / 2]u16 = undefined;
            const wide_len = std.unicode.calcUtf16LeLen(t) catch return error.InvalidValue;
            if (wide_len > wide.len) return error.ValueTooLong;
            const n = std.unicode.utf8ToUtf16Le(&wide, t) catch return error.InvalidValue;
            for (wide[0..n], 0..) |w, i| std.mem.writeInt(u16, bytes[i * 2 ..][0..2], w, .little);
            break :blk bytes[0 .. n * 2];
        },
        .bytes => return pattern.parseInto(t, buf[0..@min(buf.len, max_len)]) catch |err| switch (err) {
            error.BufferTooSmall => error.ValueTooLong,
            error.EmptySignature => error.EmptyValue,
            else => error.InvalidValue,
        },
    };
    if (raw.len > buf.len) return error.ValueTooLong;
    for (raw, buf[0..raw.len]) |b, *out| out.* = b;
    return buf[0..raw.len];
}

/// Signed min to unsigned max.
fn int(comptime T: type, text: []const u8, out: *[max_len]u8) Error![]const u8 {
    const value = try parseInt(text);
    const Signed = @Int(.signed, @bitSizeOf(T));
    if (value < std.math.minInt(Signed) or value > std.math.maxInt(T)) return error.ValueOutOfRange;
    const bits: T = @truncate(@as(u128, @bitCast(value)));
    std.mem.writeInt(T, out[0..@sizeOf(T)], bits, .little);
    return out[0..@sizeOf(T)];
}

fn float(comptime T: type, text: []const u8, out: *[max_len]u8) Error![]const u8 {
    const value = try parseFloat(T, text);
    const Bits = @Int(.unsigned, @bitSizeOf(T));
    std.mem.writeInt(Bits, out[0..@sizeOf(T)], @bitCast(value), .little);
    return out[0..@sizeOf(T)];
}

/// Like `-5`, `16`, `0x10` or `10h`, see `Location.parseNumber`.
pub fn parseInt(text: []const u8) Error!i128 {
    var t = std.mem.trim(u8, text, " \t");
    if (t.len == 0) return error.EmptyValue;
    const negative = t[0] == '-';
    if (negative or t[0] == '+') t = t[1..];
    const magnitude = Location.parseUnsigned(u127, t) catch |err| return switch (err) {
        error.Overflow => error.ValueOutOfRange,
        error.InvalidCharacter => error.InvalidValue,
    };
    return if (negative) -@as(i128, magnitude) else magnitude;
}

pub fn parseFloat(comptime T: type, text: []const u8) Error!T {
    const t = std.mem.trim(u8, text, " \t");
    if (t.len == 0) return error.EmptyValue;
    return std.fmt.parseFloat(T, t) catch error.InvalidValue;
}

/// `true`, `false`, `1` or `0`.
pub fn parseBool(text: []const u8) Error!bool {
    const t = std.mem.trim(u8, text, " \t");
    if (t.len == 0) return error.EmptyValue;
    if (std.mem.eql(u8, t, "true") or std.mem.eql(u8, t, "1")) return true;
    if (std.mem.eql(u8, t, "false") or std.mem.eql(u8, t, "0")) return false;
    return error.InvalidValue;
}

/// Ints are signed, except a byte. Unprintable text shows as `.`.
pub fn format(kind: Kind, bytes: []const u8, buf: []u8) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    write(kind, bytes, &w) catch {};
    return w.buffered();
}

fn write(kind: Kind, bytes: []const u8, w: *std.Io.Writer) !void {
    switch (kind) {
        .byte => try w.print("{d}", .{bytes[0]}),
        .two_bytes => try w.print("{d}", .{std.mem.readInt(i16, bytes[0..2], .little)}),
        .four_bytes => try w.print("{d}", .{std.mem.readInt(i32, bytes[0..4], .little)}),
        .eight_bytes => try w.print("{d}", .{std.mem.readInt(i64, bytes[0..8], .little)}),
        .float => try w.print("{d}", .{@as(f32, @bitCast(std.mem.readInt(u32, bytes[0..4], .little)))}),
        .double => try w.print("{d}", .{@as(f64, @bitCast(std.mem.readInt(u64, bytes[0..8], .little)))}),
        .text => for (bytes) |b| try w.writeByte(if (std.ascii.isPrint(b)) b else '.'),
        .text_utf16 => {
            var i: usize = 0;
            while (i + 1 < bytes.len) : (i += 2) {
                const unit = std.mem.readInt(u16, bytes[i..][0..2], .little);
                try w.writeByte(if (unit < 0x80 and std.ascii.isPrint(@intCast(unit))) @intCast(unit) else '.');
            }
        },
        .bytes => for (bytes, 0..) |b, i| {
            if (i != 0) try w.writeByte(' ');
            try w.print("{X:0>2}", .{b});
        },
    }
}

/// Ints are signed, except a byte. Null for non-numbers or NaN.
pub fn order(kind: Kind, a: []const u8, b: []const u8) ?std.math.Order {
    return switch (kind) {
        .byte => std.math.order(a[0], b[0]),
        .two_bytes => std.math.order(std.mem.readInt(i16, a[0..2], .little), std.mem.readInt(i16, b[0..2], .little)),
        .four_bytes => std.math.order(std.mem.readInt(i32, a[0..4], .little), std.mem.readInt(i32, b[0..4], .little)),
        .eight_bytes => std.math.order(std.mem.readInt(i64, a[0..8], .little), std.mem.readInt(i64, b[0..8], .little)),
        .float => floatOrder(f32, a, b),
        .double => floatOrder(f64, a, b),
        .text, .text_utf16, .bytes => null,
    };
}

fn floatOrder(comptime T: type, a: []const u8, b: []const u8) ?std.math.Order {
    const Bits = @Int(.unsigned, @bitSizeOf(T));
    const x: T = @bitCast(std.mem.readInt(Bits, a[0..@sizeOf(T)], .little));
    const y: T = @bitCast(std.mem.readInt(Bits, b[0..@sizeOf(T)], .little));
    if (std.math.isNan(x) or std.math.isNan(y)) return null;
    return std.math.order(x, y);
}

const tests = struct {
    const testing = std.testing;

    fn bytesOf(p: []const ?u8) [16]u8 {
        var out: [16]u8 = @splat(0);
        for (p, 0..) |b, i| out[i] = b.?;
        return out;
    }

    test "numbers parse" {
        var buf: [max_len]?u8 = undefined;
        try testing.expectEqualSlices(?u8, &.{ 0x39, 0x30, 0, 0 }, try parse(.four_bytes, "12345", &buf));
        try testing.expectEqualSlices(?u8, &.{ 0xFF, 0xFF }, try parse(.two_bytes, "-1", &buf));
        try testing.expectEqualSlices(?u8, &.{ 0xFF, 0xFF }, try parse(.two_bytes, "0xFFFF", &buf));
        try testing.expectEqualSlices(?u8, &.{0x80}, try parse(.byte, " -128 ", &buf));
        try testing.expectError(error.ValueOutOfRange, parse(.byte, "256", &buf));
        try testing.expectError(error.ValueOutOfRange, parse(.two_bytes, "-32769", &buf));
        try testing.expectError(error.InvalidValue, parse(.four_bytes, "12x", &buf));
        try testing.expectError(error.EmptyValue, parse(.four_bytes, "  ", &buf));
        // Decimal unless it starts with 0x or ends in h
        try testing.expectEqual(0x10, try parseInt("0x10"));
        try testing.expectEqual(-0x1F, try parseInt("-1Fh"));
        try testing.expectEqual(-10, try parseInt(" -10 "));
        try testing.expectError(error.InvalidValue, parseInt("1F"));
        try testing.expectError(error.InvalidValue, parseInt("0o7"));
        try testing.expectEqual(true, try parseBool("1"));
        try testing.expectError(error.InvalidValue, parseBool("yes"));

        const f = try parse(.float, "1.5", &buf);
        try testing.expectEqual(@as(u32, @bitCast(@as(f32, 1.5))), std.mem.readInt(u32, bytesOf(f)[0..4], .little));
        try testing.expectEqual(8, (try parse(.double, "-2.25", &buf)).len);
    }

    test "text and patterns parse" {
        var buf: [max_len]?u8 = undefined;
        try testing.expectEqualSlices(?u8, &.{ 'H', 'i' }, try parse(.text, "Hi", &buf));
        try testing.expectEqualSlices(?u8, &.{ 'H', 0, 'i', 0 }, try parse(.text_utf16, "Hi", &buf));
        try testing.expectEqualSlices(?u8, &.{ 0x48, null, 0xC3 }, try parse(.bytes, "48 ?? C3", &buf));
        try testing.expectError(error.InvalidValue, parse(.bytes, "4G", &buf));
        const long: [max_len + 1]u8 = @splat('a');
        try testing.expectError(error.ValueTooLong, parse(.text, &long, &buf));
    }

    test "format and order" {
        var buf: [64]u8 = undefined;
        const minus_two = [_]u8{ 0xFE, 0xFF, 0xFF, 0xFF };
        const three = [_]u8{ 3, 0, 0, 0 };
        try testing.expectEqualStrings("-2", format(.four_bytes, &minus_two, &buf));
        try testing.expectEqualStrings("254", format(.byte, &minus_two, &buf));
        try testing.expectEqualStrings("1.5", format(.float, std.mem.asBytes(&@as(f32, 1.5)), &buf));
        try testing.expectEqualStrings("H.i", format(.text, "H\x01i", &buf));
        try testing.expectEqualStrings("Hi", format(.text_utf16, &.{ 'H', 0, 'i', 0 }, &buf));
        try testing.expectEqualStrings("48 0A", format(.bytes, &.{ 0x48, 0x0A }, &buf));

        // Signed, so -2 is less than 3. Unsigned it'd be more
        try testing.expectEqual(.lt, order(.four_bytes, &minus_two, &three).?);
        try testing.expectEqual(.gt, order(.byte, &minus_two, &three).?);
        try testing.expectEqual(null, order(.text, "a", "b"));
        const nan = std.math.nan(f32);
        try testing.expectEqual(null, order(.float, std.mem.asBytes(&nan), std.mem.asBytes(&@as(f32, 1))));
    }
};

test {
    _ = tests;
}
