//! Image and text clipboard. Call from a worker, not a game's render thread.

const std = @import("std");
const native = @import("win/clipboard.zig");

pub const Image = struct {
    width: u32,
    height: u32,
    /// Packed sRGB RGBA8, top row first.
    pixels: []const u8,
};

/// Copies the pixels before returning. Replaces the clipboard on success.
pub fn setImage(io: std.Io, image: Image) !void {
    try validate(image);
    try native.setImage(io, image);
}

/// UTF-8. Replaces the clipboard on success.
pub const setText = native.setText;

/// UTF-8, or WTF-8 if it holds unpaired surrogates. Empty if there's no text. Caller frees.
pub const getText = native.getText;

pub fn validate(image: Image) error{InvalidImage}!void {
    if (image.width == 0 or image.height == 0 or
        image.width > std.math.maxInt(i32) or image.height > std.math.maxInt(i32))
        return error.InvalidImage;
    const count = std.math.mul(usize, image.width, image.height) catch return error.InvalidImage;
    const bytes = std.math.mul(usize, count, 4) catch return error.InvalidImage;
    if (bytes != image.pixels.len or bytes > std.math.maxInt(u32) - 124) return error.InvalidImage;
}

test "clipboard image dimensions and byte count" {
    try validate(.{ .width = 1, .height = 1, .pixels = &.{ 1, 2, 3, 255 } });
    try std.testing.expectError(error.InvalidImage, validate(.{ .width = 0, .height = 1, .pixels = &.{} }));
    try std.testing.expectError(error.InvalidImage, validate(.{ .width = 2, .height = 1, .pixels = &.{ 1, 2, 3, 4 } }));
    try std.testing.expectError(error.InvalidImage, validate(.{ .width = std.math.maxInt(u32), .height = 2, .pixels = &.{} }));
}

test {
    _ = native;
}
