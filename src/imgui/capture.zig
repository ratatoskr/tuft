//! Copies of the game's frame from before and after ImGui draws. Pixels arrive a frame or so later.

const std = @import("std");

const gfx = @import("tuft_gfx");

pub const Point = enum(u8) {
    /// Just the game.
    before,
    /// With our drawing on top.
    after,
};

pub const Points = std.EnumSet(Point);

/// How the pixels are laid out. Images also keep the API's own format code.
pub const Format = enum(u8) {
    unknown,
    rgba8,
    bgra8,
    /// Alpha is junk.
    bgrx8,
    /// Packed in 32 bits from the low bits up. 10 red, 10 green, 10 blue, 2 alpha.
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

    pub fn fromDxgi(code: u32) Format {
        return switch (code) {
            27, 28, 29 => .rgba8,
            87, 90, 91 => .bgra8,
            88, 92, 93 => .bgrx8,
            23, 24 => .rgb10a2,
            9, 10 => .rgba16f,
            else => .unknown,
        };
    }

    pub fn fromVulkan(code: u32) Format {
        return switch (code) {
            37, 43 => .rgba8,
            44, 50 => .bgra8,
            64 => .rgb10a2,
            58 => .bgr10a2,
            97 => .rgba16f,
            else => .unknown,
        };
    }

    pub fn fromD3d9(code: u32) Format {
        return switch (code) {
            21 => .bgra8,
            22 => .bgrx8,
            31 => .rgb10a2,
            35 => .bgr10a2,
            32 => .rgba8,
            113 => .rgba16f,
            else => .unknown,
        };
    }
};

pub const Image = struct {
    point: Point,
    width: u32,
    height: u32,
    /// Bytes from one row to the next, top row first. Can be more than a row's pixels.
    pitch: u32,
    format: Format,
    /// `DXGI_FORMAT`, `VkFormat`, `D3DFORMAT` or the GL internal format, by API.
    native_format: u32,
    color_space: gfx.ColorSpace,
    /// Windows' SDR white on the game's display.
    sdr_white_nits: f32 = gfx.display.default_sdr_white_nits,
    /// Only valid during the call.
    pixels: []const u8,

    /// How many bytes `pixels` has, for rows `pitch` apart.
    pub fn size(width: u32, height: u32, pitch: u32, format: Format) usize {
        if (height == 0) return 0;
        return @as(usize, pitch) * (height - 1) + @as(usize, width) * format.bytesPerPixel();
    }
};

pub const Event = union(enum) {
    /// Copying started. Requests from now on get a later frame.
    started: Point,
    done: *const Image,
    /// Can't copy at this point, at least for now.
    failed: Point,
};

pub const Sink = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, event: Event) void,

    pub fn of(comptime T: type, ctx: *T, comptime func: fn (*T, Event) void) Sink {
        return .{ .ctx = ctx, .func = struct {
            fn call(c: *anyopaque, event: Event) void {
                func(@ptrCast(@alignCast(c)), event);
            }
        }.call };
    }
};

/// What's wanted and in flight. Render thread only.
pub const Captures = struct {
    sink: ?Sink = null,
    window: ?@import("tuft_window").Handle = null,
    wanted: Points = .empty,
    in_flight: Points = .empty,

    /// Backends check this at each point. A point still in flight waits for that one to land.
    pub fn want(self: *const Captures, point: Point) bool {
        return self.wanted.contains(point) and !self.in_flight.contains(point);
    }

    pub fn started(self: *Captures, point: Point) void {
        self.wanted.remove(point);
        self.in_flight.insert(point);
        self.send(.{ .started = point });
    }

    pub fn done(self: *Captures, image: *const Image) void {
        self.in_flight.remove(image.point);
        var result = image.*;
        if (result.color_space != .srgb) {
            if (self.window) |window| result.sdr_white_nits = gfx.display.of(window).sdr_white_nits;
        }
        self.send(.{ .done = &result });
    }

    pub fn failed(self: *Captures, point: Point) void {
        self.wanted.remove(point);
        self.in_flight.remove(point);
        self.send(.{ .failed = point });
    }

    /// Backends call this from `poll` for each point. Copies they dropped get taken again.
    pub fn check(self: *Captures, point: Point, busy: bool) bool {
        if (busy) return true;
        if (self.in_flight.contains(point)) {
            self.in_flight.remove(point);
            self.wanted.insert(point);
        }
        return false;
    }

    fn send(self: *Captures, event: Event) void {
        if (self.sink) |s| s.func(s.ctx, event);
    }
};

test "formats" {
    try std.testing.expectEqual(Format.bgra8, Format.fromDxgi(87));
    try std.testing.expectEqual(Format.rgba16f, Format.fromVulkan(97));
    try std.testing.expectEqual(Format.bgrx8, Format.fromD3d9(22));
    // The last row stops at its pixels
    try std.testing.expectEqual(@as(usize, 24 * 3 + 16), Image.size(2, 4, 24, .rgba16f));
}
