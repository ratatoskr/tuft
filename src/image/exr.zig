//! HDR frames as OpenEXR files. Only the one kind we need: scanlines of half-float B, G and R,
//! ZIP-compressed 16 lines at a time, with Rec.709 chromaticities.

const std = @import("std");
const flate = std.compress.flate;

const Linear = @import("root.zig").Linear;
const Error = @import("root.zig").Error;

/// Lines in each ZIP block.
const block_lines = 16;
/// EXR wants channels sorted by name.
const channels = [_][]const u8{ "B", "G", "R" };
const half_type: i32 = 1;
const zip_compression: u8 = 3;
const f16_max: f32 = 65504;

/// An EXR file of `linear` as it is, so 1 is 80 nits like scRGB. Free it with `gpa`.
pub fn encode(gpa: std.mem.Allocator, linear: Linear) Error![]u8 {
    const width = linear.width;
    const height = linear.height;
    if (width == 0 or height == 0 or width > std.math.maxInt(i32) or height > std.math.maxInt(i32)) return error.InvalidImage;
    const count = std.math.mul(usize, width, height) catch return error.InvalidImage;
    if (linear.pixels.len != count) return error.InvalidImage;

    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    writeHeader(&out.writer, width, height) catch return error.OutOfMemory;

    const blocks = (height + block_lines - 1) / block_lines;
    // The offset table's filled in once the blocks are written
    const table_at = out.written().len;
    out.writer.splatByteAll(0, blocks * 8) catch return error.OutOfMemory;

    const line_bytes = @as(usize, width) * channels.len * 2;
    const raw = try gpa.alloc(u8, line_bytes * block_lines);
    defer gpa.free(raw);
    const shuffled = try gpa.alloc(u8, raw.len);
    defer gpa.free(shuffled);
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    // Too big for the stack
    const compress = try gpa.create(flate.Compress);
    defer gpa.destroy(compress);
    var packed_out: std.Io.Writer.Allocating = try .initCapacity(gpa, raw.len + 64);
    defer packed_out.deinit();

    for (0..blocks) |b| {
        const first: u32 = @intCast(b * block_lines);
        const lines = @min(block_lines, height - first);
        const size = line_bytes * lines;
        fillBlock(raw[0..size], linear, first, lines);
        predict(raw[0..size], shuffled[0..size]);

        packed_out.clearRetainingCapacity();
        zlib(compress, &packed_out.writer, window, shuffled[0..size]) catch return error.OutOfMemory;
        // Readers take a block no smaller than it'd be raw as raw
        const data = if (packed_out.written().len < size) packed_out.written() else raw[0..size];

        const at: u64 = out.written().len;
        std.mem.writeInt(u64, out.written()[table_at + b * 8 ..][0..8], at, .little);
        const w = &out.writer;
        w.writeInt(i32, @intCast(first), .little) catch return error.OutOfMemory;
        w.writeInt(i32, @intCast(data.len), .little) catch return error.OutOfMemory;
        w.writeAll(data) catch return error.OutOfMemory;
    }
    return out.toOwnedSlice() catch error.OutOfMemory;
}

fn writeHeader(w: *std.Io.Writer, width: u32, height: u32) std.Io.Writer.Error!void {
    try w.writeAll(&.{ 0x76, 0x2f, 0x31, 0x01 });
    // Version 2, single part scanlines
    try w.writeInt(u32, 2, .little);

    try attribute(w, "channels", "chlist", channels.len * 18 + 1);
    for (channels) |name| {
        try w.writeAll(name);
        try w.writeByte(0);
        try w.writeInt(i32, half_type, .little);
        // pLinear and three reserved bytes
        try w.writeAll(&.{ 0, 0, 0, 0 });
        try w.writeInt(i32, 1, .little);
        try w.writeInt(i32, 1, .little);
    }
    try w.writeByte(0);

    // Rec.709 primaries and D65 white
    try attribute(w, "chromaticities", "chromaticities", 32);
    for ([_]f32{ 0.64, 0.33, 0.30, 0.60, 0.15, 0.06, 0.3127, 0.3290 }) |v| try float(w, v);

    try attribute(w, "compression", "compression", 1);
    try w.writeByte(zip_compression);
    for ([_][]const u8{ "dataWindow", "displayWindow" }) |name| {
        try attribute(w, name, "box2i", 16);
        for ([_]i32{ 0, 0, @intCast(width - 1), @intCast(height - 1) }) |v| try w.writeInt(i32, v, .little);
    }
    // Top line first
    try attribute(w, "lineOrder", "lineOrder", 1);
    try w.writeByte(0);
    try attribute(w, "pixelAspectRatio", "float", 4);
    try float(w, 1);
    try attribute(w, "screenWindowCenter", "v2f", 8);
    try float(w, 0);
    try float(w, 0);
    try attribute(w, "screenWindowWidth", "float", 4);
    try float(w, 1);
    try w.writeByte(0);
}

fn attribute(w: *std.Io.Writer, name: []const u8, kind: []const u8, size: u32) std.Io.Writer.Error!void {
    try w.writeAll(name);
    try w.writeByte(0);
    try w.writeAll(kind);
    try w.writeByte(0);
    try w.writeInt(u32, size, .little);
}

fn float(w: *std.Io.Writer, v: f32) std.Io.Writer.Error!void {
    try w.writeInt(u32, @bitCast(v), .little);
}

/// Each line is all of B, then G, then R, as halves.
fn fillBlock(raw: []u8, linear: Linear, first: u32, lines: u32) void {
    const width = linear.width;
    var at: usize = 0;
    for (0..lines) |l| {
        const row = linear.pixels[(first + l) * @as(usize, width) ..][0..width];
        for (0..channels.len) |c| for (row) |pixel| {
            const v = std.math.clamp(pixel[2 - c], -f16_max, f16_max);
            std.mem.writeInt(u16, raw[at..][0..2], @bitCast(@as(f16, @floatCast(v))), .little);
            at += 2;
        };
    }
}

/// What EXR's ZIP does before deflating: even bytes then odd ones, each stored as the difference
/// from the one before plus 128.
fn predict(raw: []const u8, out: []u8) void {
    const half = (raw.len + 1) / 2;
    for (raw, 0..) |byte, i| out[if (i % 2 == 0) i / 2 else half + i / 2] = byte;
    var previous = out[0];
    for (out[1..]) |*t| {
        const now = t.*;
        t.* = now -% previous +% 128;
        previous = now;
    }
}

/// A zlib stream of its own, as each block is.
fn zlib(compress: *flate.Compress, w: *std.Io.Writer, window: []u8, data: []const u8) std.Io.Writer.Error!void {
    compress.* = try .init(w, window, .zlib, .level_4);
    try compress.writer.writeAll(data);
    try compress.finish();
}

const testing = std.testing;

/// Reads back what `encode` writes, the way the format says to, for checking it.
const Read = struct {
    width: u32,
    height: u32,
    /// B, G, R a line at a time, as `fillBlock` lays them out.
    halves: []f16,

    fn deinit(self: Read) void {
        testing.allocator.free(self.halves);
    }

    fn of(file: []const u8) !Read {
        var r: std.Io.Reader = .fixed(file);
        try testing.expectEqualSlices(u8, &.{ 0x76, 0x2f, 0x31, 0x01 }, try r.takeArray(4));
        try testing.expectEqual(2, try r.takeInt(u32, .little));
        var window: [4]i32 = undefined;
        var seen: usize = 0;
        while (true) {
            const name = try r.takeSentinel(0);
            if (name.len == 0) break;
            const kind = try r.takeSentinel(0);
            const size = try r.takeInt(u32, .little);
            const value = try r.take(size);
            seen += 1;
            if (std.mem.eql(u8, name, "compression")) try testing.expectEqual(zip_compression, value[0]);
            if (std.mem.eql(u8, name, "dataWindow")) {
                try testing.expectEqualStrings("box2i", kind);
                for (&window, 0..) |*v, i| v.* = std.mem.readInt(i32, value[i * 4 ..][0..4], .little);
            }
            if (std.mem.eql(u8, name, "channels")) try testing.expectEqualSlices(u8, "B\x00\x01\x00\x00\x00", value[0..6]);
        }
        // channels, chromaticities, compression, two windows, lineOrder, aspect, centre and width
        try testing.expectEqual(9, seen);
        const width: u32 = @intCast(window[2] - window[0] + 1);
        const height: u32 = @intCast(window[3] - window[1] + 1);
        const blocks = (height + block_lines - 1) / block_lines;
        const line = width * channels.len;
        const halves = try testing.allocator.alloc(f16, line * height);
        errdefer testing.allocator.free(halves);
        for (0..blocks) |b| {
            const at = std.mem.readInt(u64, file[r.seek + b * 8 ..][0..8], .little);
            var chunk: std.Io.Reader = .fixed(file[@intCast(at)..]);
            const first: u32 = @intCast(try chunk.takeInt(i32, .little));
            try testing.expectEqual(b * block_lines, first);
            const size = try chunk.takeInt(i32, .little);
            const lines = @min(block_lines, height - first);
            const want = line * 2 * lines;
            const raw = try testing.allocator.alloc(u8, want);
            defer testing.allocator.free(raw);
            const data = try chunk.take(@intCast(size));
            if (data.len == want) @memcpy(raw, data) else try unzip(data, raw);
            for (0..want / 2) |i| halves[first * line + i] = @bitCast(std.mem.readInt(u16, raw[i * 2 ..][0..2], .little));
        }
        return .{ .width = width, .height = height, .halves = halves };
    }

    fn unzip(data: []const u8, raw: []u8) !void {
        var in: std.Io.Reader = .fixed(data);
        var window: [flate.max_window_len]u8 = undefined;
        var decompress: flate.Decompress = .init(&in, .zlib, &window);
        const shuffled = try testing.allocator.alloc(u8, raw.len);
        defer testing.allocator.free(shuffled);
        try decompress.reader.readSliceAll(shuffled);
        for (1..shuffled.len) |i| shuffled[i] = shuffled[i] +% shuffled[i - 1] -% 128;
        const half = (raw.len + 1) / 2;
        for (raw, 0..) |*byte, i| byte.* = shuffled[if (i % 2 == 0) i / 2 else half + i / 2];
    }
};

test "an HDR frame reads back as halves, a block of 16 lines at a time" {
    // Over a block, so the last one's short, and odd sized
    const width = 5;
    const height = 21;
    var pixels: [width * height][3]f32 = undefined;
    for (&pixels, 0..) |*p, i| {
        const f: f32 = @floatFromInt(i);
        p.* = .{ f / 10, -f / 100, f * 3 };
    }
    // Brighter than a half can be gets clamped
    pixels[7] = .{ 1e9, -1e9, 0.5 };
    const file = try encode(testing.allocator, .{ .width = width, .height = height, .pixels = &pixels, .hdr = true });
    defer testing.allocator.free(file);

    const read = try Read.of(file);
    defer read.deinit();
    try testing.expectEqual(width, read.width);
    try testing.expectEqual(height, read.height);
    for (pixels, 0..) |p, i| {
        const y = i / width;
        const x = i % width;
        for (0..3) |c| {
            const got: f32 = read.halves[y * width * 3 + c * width + x];
            const want: f32 = @floatCast(@as(f16, @floatCast(std.math.clamp(p[2 - c], -f16_max, f16_max))));
            try testing.expectEqual(want, got);
        }
    }
}

test "a flat frame squeezes down, and one that won't is kept raw" {
    var flat: [64 * 16][3]f32 = @splat(.{ 1, 1, 1 });
    const small = try encode(testing.allocator, .{ .width = 64, .height = 16, .pixels = &flat });
    defer testing.allocator.free(small);
    try testing.expect(small.len < 64 * 16 * 6 / 4);
    const read = try Read.of(small);
    defer read.deinit();
    for (read.halves) |h| try testing.expectEqual(1, h);

    // One pixel's too little for deflate to win
    var one = [_][3]f32{.{ 0.25, 2, 4 }};
    const tiny = try encode(testing.allocator, .{ .width = 1, .height = 1, .pixels = &one });
    defer testing.allocator.free(tiny);
    const back = try Read.of(tiny);
    defer back.deinit();
    try testing.expectEqualSlices(f16, &.{ 4, 2, 0.25 }, back.halves);
}

test "sizes that don't add up are refused" {
    var one = [_][3]f32{.{ 0, 0, 0 }};
    try testing.expectError(error.InvalidImage, encode(testing.allocator, .{ .width = 2, .height = 1, .pixels = &one }));
    try testing.expectError(error.InvalidImage, encode(testing.allocator, .{ .width = 0, .height = 1, .pixels = &.{} }));
}
