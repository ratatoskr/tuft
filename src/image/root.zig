//! CPU RGBA8 images: decodes PNG, JPEG, BMP, TGA and GIF, converts captures, encodes PNG and EXR.
//! Slow, so keep it off the render thread. Needs only libc, so plugins can use it.

const std = @import("std");

/// An HDR frame as an EXR file, see `exr.zig`. Free it with the allocator given.
pub const encodeExr = @import("exr.zig").encode;

/// RGBA, 4 bytes a pixel, rows packed with the top one first.
pub const Image = struct {
    width: u32,
    height: u32,
    pixels: []u8,

    pub fn deinit(self: Image, gpa: std.mem.Allocator) void {
        gpa.free(self.pixels);
    }
};

pub const Error = error{
    OutOfMemory,
    /// Not an image we can read, or sizes that don't add up.
    InvalidImage,
    /// Wider or taller than `max_side`.
    TooBig,
    UnsupportedFormat,
    /// A capture had NaN or infinity in it.
    InvalidPixel,
    /// HDR to SDR got an exposure or SDR white it can't use.
    InvalidExposure,
};

/// Decoded files with bigger sides get refused, so a bad file can't ask for gigabytes.
pub const max_side = 16384;

/// Same names as `tuft_imgui.capture.Format` and the plugin API's `PixelFormat`.
pub const Format = enum(u8) {
    unknown,
    rgba8,
    bgra8,
    /// Alpha is junk.
    bgrx8,
    /// 32 bits. From the low bits up, 10 red, 10 green, 10 blue and 2 alpha.
    rgb10a2,
    /// Same with red and blue swapped.
    bgr10a2,
    /// Half floats.
    rgba16f,

    pub fn bytesPerPixel(self: Format) u32 {
        return switch (self) {
            .unknown => 0,
            .rgba16f => 8,
            else => 4,
        };
    }
};

pub const ColorSpace = enum(u8) {
    /// SDR, sRGB encoded.
    srgb,
    /// Linear Rec.709, 1 is 80 nits.
    scrgb,
    /// Rec.2020 with the PQ curve.
    hdr10,
};

/// Any thread.
pub fn decode(gpa: std.mem.Allocator, bytes: []const u8) Error!Image {
    if (bytes.len == 0 or bytes.len > std.math.maxInt(c_int)) return error.InvalidImage;
    var gpa_ = gpa;
    const hooks: Hooks = .of(&gpa_);

    var width: c_int = 0;
    var height: c_int = 0;
    if (tuft_image_info(&hooks, bytes.ptr, @intCast(bytes.len), &width, &height) == 0) return error.InvalidImage;
    if (width <= 0 or height <= 0) return error.InvalidImage;
    if (width > max_side or height > max_side) return error.TooBig;
    var failure: ?[*:0]const u8 = null;
    const decoded = tuft_image_decode(&hooks, bytes.ptr, @intCast(bytes.len), &width, &height, &failure) orelse {
        const reason = std.mem.span(failure orelse "");
        return if (std.mem.eql(u8, reason, "outofmem")) error.OutOfMemory else error.InvalidImage;
    };
    defer tuft_image_release(&hooks, decoded);
    const len = @as(usize, @intCast(width)) * @as(usize, @intCast(height)) * 4;
    return .{
        .width = @intCast(width),
        .height = @intCast(height),
        .pixels = try gpa.dupe(u8, decoded[0..len]),
    };
}

pub const RawFormat = enum { rgba8, bgra8, bgrx8 };

/// 8-bit pixels in rows `pitch` bytes apart (0 = packed). Alpha kept except `bgrx8`. HDR: use `fromCapture`.
pub fn fromRaw(gpa: std.mem.Allocator, width: u32, height: u32, format: RawFormat, pitch: u32, bytes: []const u8) Error!Image {
    if (width == 0 or height == 0) return error.InvalidImage;
    if (width > max_side or height > max_side) return error.TooBig;
    const row = @as(usize, width) * 4;
    const step: usize = if (pitch == 0) row else pitch;
    if (step < row or bytes.len < step * (height - 1) + row) return error.InvalidImage;
    const out = try gpa.alloc(u8, row * height);
    for (0..height) |y| {
        const src = bytes[y * step ..][0..row];
        const dst = out[y * row ..][0..row];
        switch (format) {
            .rgba8 => @memcpy(dst, src),
            .bgra8, .bgrx8 => for (0..width) |x| {
                const p = src[x * 4 ..][0..4];
                dst[x * 4 ..][0..4].* = .{ p[2], p[1], p[0], if (format == .bgrx8) 255 else p[3] };
            },
        }
    }
    return .{ .width = width, .height = height, .pixels = out };
}

/// A frame as linear light, before it's made SDR or written as HDR.
pub const Linear = struct {
    width: u32,
    height: u32,
    /// Linear Rec.709. As in scRGB, 1 means 80 nits for HDR captures.
    pixels: [][3]f32,
    /// It came from an HDR frame.
    hdr: bool = false,
    /// SDR white on the display it came from, in nits.
    sdr_white_nits: f32 = 200,

    pub fn deinit(self: Linear, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
    }

    pub const SdrOptions = struct {
        /// In stops, for HDR only.
        exposure: f32 = 0,
    };

    /// Opaque sRGB RGBA8. HDR is scaled so SDR white is 1, exposed, then highlights rolled off with one
    /// curve for all channels so they don't clip separately and shift color.
    pub fn sdr(self: Linear, allocator: std.mem.Allocator, options: SdrOptions) Error!Image {
        const white = self.sdr_white_nits;
        const exposure = options.exposure;
        if (self.hdr and (!std.math.isFinite(white) or white <= 0 or
            !std.math.isFinite(exposure) or @abs(exposure) > 10)) return error.InvalidExposure;
        const scale: f32 = if (self.hdr) 80 / white * @exp2(exposure) else 1;
        if (!std.math.isFinite(scale)) return error.InvalidExposure;
        var peak: f32 = 1;
        if (self.hdr) for (self.pixels) |pixel| {
            for (pixel) |c| peak = @max(peak, @max(0, c) * scale);
        };
        if (!std.math.isFinite(peak)) return error.InvalidExposure;
        const out = try allocator.alloc(u8, self.pixels.len * 4);
        for (self.pixels, 0..) |pixel, i| {
            const brightest = @max(0, @max(pixel[0], @max(pixel[1], pixel[2]))) * scale;
            const compression = if (self.hdr and brightest > 0) (1 + brightest / peak / peak) / (1 + brightest) else 1;
            for (pixel, 0..) |c, channel| {
                const value = @max(0, c) * scale * compression;
                const encoded = encodeSrgb(std.math.clamp(value, 0, 1));
                out[i * 4 + channel] = @intFromFloat(@round(encoded * 255));
            }
            out[i * 4 + 3] = 255;
        }
        return .{ .width = self.width, .height = self.height, .pixels = out };
    }
};

/// A capture's pixels as linear light. `capture` needs `width`, `height`, `pitch`, `format`,
/// `color_space`, `sdr_white_nits` and `pixels`, like `tuft_imgui.capture.Image`.
pub fn linearFromCapture(allocator: std.mem.Allocator, capture: anytype) Error!Linear {
    const format = formatOf(capture.format);
    const space = spaceOf(capture.color_space);
    const width: u32 = capture.width;
    const height: u32 = capture.height;
    const pitch: u32 = capture.pitch;
    const bytes_in: []const u8 = capture.pixels;
    const bpp: usize = switch (format) {
        .unknown => return error.UnsupportedFormat,
        else => format.bytesPerPixel(),
    };
    if (width == 0 or height == 0 or
        width > std.math.maxInt(i32) / 4 or height > std.math.maxInt(i32)) return error.InvalidImage;
    const row = std.math.mul(usize, width, bpp) catch return error.InvalidImage;
    if (pitch < row) return error.InvalidImage;
    const preceding = std.math.mul(usize, pitch, height - 1) catch return error.InvalidImage;
    const size = std.math.add(usize, preceding, row) catch return error.InvalidImage;
    if (bytes_in.len < size) return error.InvalidImage;
    const count = std.math.mul(usize, width, height) catch return error.InvalidImage;
    const pixels = try allocator.alloc([3]f32, count);
    errdefer allocator.free(pixels);
    for (0..height) |y| {
        for (0..width) |x| {
            const bytes = bytes_in[y * pitch + x * bpp ..][0..bpp];
            var rgb: [3]f32 = switch (format) {
                .rgba8 => .{ unit(bytes[0], 255), unit(bytes[1], 255), unit(bytes[2], 255) },
                .bgra8, .bgrx8 => .{ unit(bytes[2], 255), unit(bytes[1], 255), unit(bytes[0], 255) },
                .rgb10a2, .bgr10a2 => blk: {
                    const word = std.mem.readInt(u32, bytes[0..4], .little);
                    const first = unit(word & 1023, 1023);
                    const last = unit((word >> 20) & 1023, 1023);
                    break :blk .{
                        if (format == .rgb10a2) first else last,
                        unit((word >> 10) & 1023, 1023),
                        if (format == .rgb10a2) last else first,
                    };
                },
                .rgba16f => blk: {
                    var values: [3]f32 = undefined;
                    for (&values, 0..) |*v, c| v.* = @floatCast(@as(f16, @bitCast(std.mem.readInt(u16, bytes[c * 2 ..][0..2], .little))));
                    break :blk values;
                },
                .unknown => unreachable,
            };
            for (rgb) |c| if (!std.math.isFinite(c)) return error.InvalidPixel;
            switch (space) {
                .srgb => if (bpp == 4 and format != .rgb10a2 and format != .bgr10a2) {
                    // Same values as `decodeSrgb`, looked up
                    for (&rgb) |*c| c.* = srgb_decoded[@intFromFloat(@round(c.* * 255))];
                } else for (&rgb) |*c| {
                    c.* = decodeSrgb(c.*);
                },
                .scrgb => {},
                .hdr10 => {
                    for (&rgb) |*c| c.* = pqNits(c.*) / 80;
                    const r = rgb[0];
                    const g = rgb[1];
                    const b = rgb[2];
                    rgb = .{
                        1.660491 * r - 0.587641 * g - 0.072850 * b,
                        -0.124550 * r + 1.132900 * g - 0.008349 * b,
                        -0.018151 * r - 0.100579 * g + 1.118730 * b,
                    };
                },
            }
            for (rgb) |c| if (!std.math.isFinite(c)) return error.InvalidPixel;
            pixels[y * width + x] = rgb;
        }
    }
    return .{
        .width = width,
        .height = height,
        .pixels = pixels,
        .hdr = space != .srgb,
        .sdr_white_nits = capture.sdr_white_nits,
    };
}

/// A frame capture as opaque SDR RGBA8, see `Linear.sdr`.
pub fn fromCapture(allocator: std.mem.Allocator, capture: anytype, options: Linear.SdrOptions) Error!Image {
    const linear = try linearFromCapture(allocator, capture);
    defer linear.deinit(allocator);
    return linear.sdr(allocator, options);
}

/// A PNG file. Free it with `gpa`.
pub fn encodePng(gpa: std.mem.Allocator, image: Image) Error![]u8 {
    if (image.width == 0 or image.height == 0 or image.width > std.math.maxInt(i32) / 4 or image.height > std.math.maxInt(i32))
        return error.InvalidImage;
    const count = std.math.mul(usize, image.width, image.height) catch return error.InvalidImage;
    const bytes = std.math.mul(usize, count, 4) catch return error.InvalidImage;
    if (image.pixels.len != bytes or bytes > std.math.maxInt(i32) - image.height) return error.InvalidImage;
    var gpa_ = gpa;
    const hooks: Hooks = .of(&gpa_);

    var out: Output = .{ .gpa = gpa };
    const stride: c_int = @intCast(image.width * 4);
    if (tuft_image_png(&hooks, Output.write, &out, @intCast(image.width), @intCast(image.height), image.pixels.ptr, stride) == 0 or out.bytes == null) {
        if (out.bytes) |b| gpa.free(b);
        return error.OutOfMemory;
    }
    return out.bytes.?;
}

const Output = struct {
    gpa: std.mem.Allocator,
    bytes: ?[]u8 = null,

    fn write(context: ?*anyopaque, data: ?*anyopaque, size: c_int) callconv(.c) void {
        const self: *Output = @ptrCast(@alignCast(context.?));
        if (self.bytes != null or size <= 0) return;
        const from: [*]const u8 = @ptrCast(data orelse return);
        self.bytes = self.gpa.dupe(u8, from[0..@intCast(size)]) catch null;
    }
};

fn formatOf(value: anytype) Format {
    const T = @TypeOf(value);
    inline for (comptime std.enums.values(Format)) |f| {
        if (@hasField(T, @tagName(f)) and value == @field(T, @tagName(f))) return f;
    }
    return .unknown;
}

/// Anything it doesn't know is SDR.
fn spaceOf(value: anytype) ColorSpace {
    const T = @TypeOf(value);
    inline for (.{ ColorSpace.scrgb, ColorSpace.hdr10 }) |s| {
        if (@hasField(T, @tagName(s)) and value == @field(T, @tagName(s))) return s;
    }
    return .srgb;
}

fn unit(value: anytype, max: f32) f32 {
    return @as(f32, @floatFromInt(value)) / max;
}

fn decodeSrgb(c: f32) f32 {
    return if (c <= 0.04045) c / 12.92 else std.math.pow(f32, (c + 0.055) / 1.055, 2.4);
}

const srgb_decoded: [256]f32 = blk: {
    @setEvalBranchQuota(100_000);
    var table: [256]f32 = undefined;
    for (&table, 0..) |*t, i| t.* = decodeSrgb(unit(i, 255));
    break :blk table;
};

fn encodeSrgb(c: f32) f32 {
    return if (c <= 0.0031308) c * 12.92 else 1.055 * std.math.pow(f32, c, 1.0 / 2.4) - 0.055;
}

fn pqNits(c: f32) f32 {
    const p = std.math.pow(f32, std.math.clamp(c, 0, 1), 1.0 / 78.84375);
    return 10000 * std.math.pow(f32, @max(p - 0.8359375, 0) / (18.8515625 - 18.6875 * p), 1.0 / 0.1593017578125);
}

/// stb.c's allocator and asserts. `context` is a `*std.mem.Allocator`.
const Hooks = extern struct {
    context: *anyopaque,
    alloc: *const fn (context: *anyopaque, size: usize) callconv(.c) ?*anyopaque = allocBlock,
    realloc: *const fn (context: *anyopaque, ptr: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque = reallocBlock,
    free: *const fn (context: *anyopaque, ptr: ?*anyopaque) callconv(.c) void = freeBlock,
    assert_failed: *const fn (expr: [*:0]const u8) callconv(.c) void = assertFailed,

    fn of(gpa: *std.mem.Allocator) Hooks {
        return .{ .context = gpa };
    }

    /// Each block remembers its size just before what stb gets.
    const header = 16;

    fn allocatorOf(context: *anyopaque) *std.mem.Allocator {
        return @ptrCast(@alignCast(context));
    }

    fn blockOf(ptr: *anyopaque) []align(header) u8 {
        const base: [*]align(header) u8 = @alignCast(@as([*]u8, @ptrCast(ptr)) - header);
        const total = std.mem.bytesToValue(usize, base[0..@sizeOf(usize)]);
        return base[0..total];
    }

    fn allocBlock(context: *anyopaque, size: usize) callconv(.c) ?*anyopaque {
        const total = std.math.add(usize, size, header) catch return null;
        const block = allocatorOf(context).alignedAlloc(u8, .fromByteUnits(header), total) catch return null;
        block[0..@sizeOf(usize)].* = std.mem.toBytes(total);
        return block.ptr + header;
    }

    fn reallocBlock(context: *anyopaque, ptr: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque {
        const old = ptr orelse return allocBlock(context, size);
        const total = std.math.add(usize, size, header) catch return null;
        const block = allocatorOf(context).realloc(blockOf(old), total) catch return null;
        block[0..@sizeOf(usize)].* = std.mem.toBytes(total);
        return block.ptr + header;
    }

    fn freeBlock(context: *anyopaque, ptr: ?*anyopaque) callconv(.c) void {
        allocatorOf(context).free(blockOf(ptr orelse return));
    }

    fn assertFailed(expr: [*:0]const u8) callconv(.c) void {
        std.debug.panic("stb assertion failed: {s}", .{expr});
    }
};

extern fn tuft_image_info(hooks: *const Hooks, bytes: [*]const u8, len: c_int, width: *c_int, height: *c_int) c_int;
extern fn tuft_image_decode(hooks: *const Hooks, bytes: [*]const u8, len: c_int, width: *c_int, height: *c_int, failure: *?[*:0]const u8) ?[*]u8;
extern fn tuft_image_release(hooks: *const Hooks, pixels: ?*anyopaque) void;
extern fn tuft_image_png(
    hooks: *const Hooks,
    write: *const fn (context: ?*anyopaque, data: ?*anyopaque, size: c_int) callconv(.c) void,
    context: ?*anyopaque,
    width: c_int,
    height: c_int,
    rgba: [*]const u8,
    stride: c_int,
) c_int;

const tests = struct {
    const testing = std.testing;

    const Capture = struct {
        width: u32,
        height: u32,
        pitch: u32,
        format: Format,
        color_space: ColorSpace = .srgb,
        sdr_white_nits: f32 = 200,
        pixels: []const u8,
    };

    test "png round trip" {
        var pixels = [_]u8{ 255, 0, 0, 255, 0, 255, 0, 128, 0, 0, 255, 0, 10, 20, 30, 255 };
        const png = try encodePng(testing.allocator, .{ .width = 2, .height = 2, .pixels = &pixels });
        defer testing.allocator.free(png);
        try testing.expectEqualSlices(u8, "\x89PNG", png[0..4]);
        const back = try decode(testing.allocator, png);
        defer back.deinit(testing.allocator);
        try testing.expectEqual(2, back.width);
        try testing.expectEqual(2, back.height);
        try testing.expectEqualSlices(u8, &pixels, back.pixels);
        try testing.expectError(error.InvalidImage, encodePng(testing.allocator, .{ .width = 2, .height = 2, .pixels = pixels[0..8] }));
    }

    test "bmp and tga come out RGBA" {
        // 1x1 24-bit BMP, blue then green then red
        const bmp = [_]u8{ 'B', 'M', 58, 0, 0, 0, 0, 0, 0, 0, 54, 0, 0, 0, 40, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 24, 0, 0, 0, 0, 0, 4, 0, 0, 0 } ++ @as([16]u8, @splat(0)) ++ [_]u8{ 30, 20, 10, 0 };
        const a = try decode(testing.allocator, &bmp);
        defer a.deinit(testing.allocator);
        try testing.expectEqualSlices(u8, &.{ 10, 20, 30, 255 }, a.pixels);

        // 1x1 uncompressed 32-bit TGA, BGRA
        const tga = [_]u8{ 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 1, 0, 32, 8, 3, 2, 1, 4 };
        const b = try decode(testing.allocator, &tga);
        defer b.deinit(testing.allocator);
        try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, b.pixels);
    }

    test "junk and huge sizes are refused" {
        try testing.expectError(error.InvalidImage, decode(testing.allocator, "not an image at all"));
        try testing.expectError(error.InvalidImage, decode(testing.allocator, ""));
        // A PNG claiming 20000 by 1, with an empty IDAT since that's where stb stops looking
        var png = [_]u8{ 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 13, 'I', 'H', 'D', 'R', 0, 0, 0x4e, 0x20, 0, 0, 0, 1, 8, 6, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 'I', 'D', 'A', 'T' };
        std.mem.writeInt(u32, png[29..33], std.hash.Crc32.hash(png[12..29]), .big);
        try testing.expectError(error.TooBig, decode(testing.allocator, &png));
    }

    test "raw pixels" {
        const bgrx = [_]u8{ 3, 2, 1, 0, 6, 5, 4, 99, 0xEE, 0xEE, 0xEE, 0xEE };
        // Two rows of one pixel, 8 bytes apart
        const a = try fromRaw(testing.allocator, 1, 2, .bgrx8, 8, &bgrx);
        defer a.deinit(testing.allocator);
        try testing.expectEqualSlices(u8, &.{ 1, 2, 3, 255, 0xEE, 0xEE, 0xEE, 255 }, a.pixels);
        const b = try fromRaw(testing.allocator, 1, 1, .bgra8, 0, bgrx[4..8]);
        defer b.deinit(testing.allocator);
        try testing.expectEqualSlices(u8, &.{ 4, 5, 6, 99 }, b.pixels);
        try testing.expectError(error.InvalidImage, fromRaw(testing.allocator, 2, 2, .rgba8, 0, &bgrx));
    }

    test "padded BGRA rows become opaque SDR without changing colors" {
        const bytes = [_]u8{ 0, 0, 255, 0, 88, 88, 88, 88, 255, 128, 0, 9 };
        const linear = try linearFromCapture(testing.allocator, Capture{ .width = 1, .height = 2, .pitch = 8, .format = .bgrx8, .pixels = &bytes });
        defer linear.deinit(testing.allocator);
        const rgba = try linear.sdr(testing.allocator, .{ .exposure = std.math.nan(f32) });
        defer rgba.deinit(testing.allocator);
        try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255, 0, 128, 255, 255 }, rgba.pixels);
        // Every 8-bit value survives the trip through linear
        var all: [256 * 4]u8 = undefined;
        for (0..256) |i| all[i * 4 ..][0..4].* = .{ @intCast(i), @intCast(i), @intCast(i), 255 };
        const same = try fromCapture(testing.allocator, Capture{ .width = 256, .height = 1, .pitch = 1024, .format = .rgba8, .pixels = &all }, .{});
        defer same.deinit(testing.allocator);
        try testing.expectEqualSlices(u8, &all, same.pixels);
    }

    test "packed ten-bit channels and PQ reference luminance" {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, 1023 | (512 << 10), .little);
        inline for (.{ Format.rgb10a2, Format.bgr10a2 }) |format| {
            const linear = try linearFromCapture(testing.allocator, Capture{ .width = 1, .height = 1, .pitch = 4, .format = format, .color_space = .scrgb, .pixels = &bytes });
            defer linear.deinit(testing.allocator);
            try testing.expectApproxEqAbs(@as(f32, 512.0 / 1023.0), linear.pixels[0][1], 0.00001);
            try testing.expectEqual(@as(f32, 1), linear.pixels[0][if (format == .rgb10a2) 0 else 2]);
        }
        try testing.expectApproxEqAbs(@as(f32, 100), pqNits(0.5080784), 0.01);
        try testing.expectApproxEqAbs(@as(f32, 1000), pqNits(0.7518271), 0.1);
        std.mem.writeInt(u32, &bytes, 1023, .little);
        const primary = try linearFromCapture(testing.allocator, Capture{ .width = 1, .height = 1, .pitch = 4, .format = .rgb10a2, .color_space = .hdr10, .pixels = &bytes });
        defer primary.deinit(testing.allocator);
        try testing.expectApproxEqAbs(@as(f32, 207.5614), primary.pixels[0][0], 0.001);
        try testing.expectApproxEqAbs(@as(f32, -15.5688), primary.pixels[0][1], 0.001);
    }

    test "HDR keeps negative values and highlights, and SDR compresses them" {
        var bytes: [24]u8 = undefined;
        const values = [_]f16{ -0.5, 0.5, 2.5, 1, 2.5, 2.5, 2.5, 1, 25, 25, 25, 1 };
        for (values, 0..) |v, i| std.mem.writeInt(u16, bytes[i * 2 ..][0..2], @bitCast(v), .little);
        var linear = try linearFromCapture(testing.allocator, Capture{ .width = 3, .height = 1, .pitch = 24, .format = .rgba16f, .color_space = .scrgb, .pixels = &bytes });
        defer linear.deinit(testing.allocator);
        try testing.expect(linear.hdr);
        try testing.expectEqual(@as(f32, -0.5), linear.pixels[0][0]);
        try testing.expectEqual(@as(f32, 25), linear.pixels[2][2]);
        try testing.expectError(error.InvalidExposure, linear.sdr(testing.allocator, .{ .exposure = std.math.nan(f32) }));
        const rgba = try linear.sdr(testing.allocator, .{});
        defer rgba.deinit(testing.allocator);
        try testing.expectEqual(@as(u8, 0), rgba.pixels[0]);
        try testing.expect(rgba.pixels[4] > 128 and rgba.pixels[4] < rgba.pixels[8]);
        try testing.expectEqual(@as(u8, 255), rgba.pixels[8]);
        const darker = try linear.sdr(testing.allocator, .{ .exposure = -2 });
        defer darker.deinit(testing.allocator);
        try testing.expect(darker.pixels[4] < rgba.pixels[4]);
        linear.sdr_white_nits = 0;
        try testing.expectError(error.InvalidExposure, linear.sdr(testing.allocator, .{}));
    }

    test "bad capture input is rejected before reading pixels" {
        var bytes: [8]u8 = @splat(0);
        try testing.expectError(error.UnsupportedFormat, linearFromCapture(testing.allocator, Capture{ .width = 1, .height = 1, .pitch = 4, .format = .unknown, .pixels = &bytes }));
        try testing.expectError(error.InvalidImage, linearFromCapture(testing.allocator, Capture{ .width = 2, .height = 1, .pitch = 4, .format = .rgba16f, .pixels = &bytes }));
        try testing.expectError(error.InvalidImage, linearFromCapture(testing.allocator, Capture{ .width = 2, .height = 2, .pitch = 8, .format = .rgba8, .pixels = &bytes }));
        std.mem.writeInt(u16, bytes[0..2], 0x7c00, .little);
        try testing.expectError(error.InvalidPixel, linearFromCapture(testing.allocator, Capture{ .width = 1, .height = 1, .pitch = 8, .format = .rgba16f, .color_space = .scrgb, .pixels = &bytes }));
    }
};

test {
    _ = tests;
    _ = @import("exr.zig");
}
