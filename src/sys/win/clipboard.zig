const std = @import("std");
const win = @import("api.zig");
const clipboard = @import("../clipboard.zig");

const header_size = 124;

pub fn setImage(io: std.Io, image: clipboard.Image) !void {
    try io.checkCancel();
    const memory = win.GlobalAlloc(win.GMEM_MOVEABLE, header_size + image.pixels.len) orelse return error.OutOfMemory;
    var transferred = false;
    defer if (!transferred) {
        _ = win.GlobalFree(memory);
    };
    const data: [*]u8 = @ptrCast(win.GlobalLock(memory) orelse return error.ClipboardFailed);
    fillDib(data[0 .. header_size + image.pixels.len], image);
    _ = win.GlobalUnlock(memory);

    const opened = try open(io);
    defer opened.close();
    try io.checkCancel();
    if (!win.EmptyClipboard().toBool()) return error.ClipboardFailed;
    if (win.SetClipboardData(win.CF_DIBV5, memory) == null) return error.ClipboardFailed;
    transferred = true;
}

pub fn setText(io: std.Io, text: []const u8) !void {
    try io.checkCancel();
    const len = std.unicode.calcUtf16LeLen(text) catch return error.InvalidUtf8;
    const memory = win.GlobalAlloc(win.GMEM_MOVEABLE, (len + 1) * 2) orelse return error.OutOfMemory;
    var transferred = false;
    defer if (!transferred) {
        _ = win.GlobalFree(memory);
    };
    const data: [*]u16 = @ptrCast(@alignCast(win.GlobalLock(memory) orelse return error.ClipboardFailed));
    const n = std.unicode.utf8ToUtf16Le(data[0..len], text) catch unreachable;
    data[n] = 0;
    _ = win.GlobalUnlock(memory);

    const opened = try open(io);
    defer opened.close();
    if (!win.EmptyClipboard().toBool()) return error.ClipboardFailed;
    if (win.SetClipboardData(win.CF_UNICODETEXT, memory) == null) return error.ClipboardFailed;
    transferred = true;
}

/// Empty if there's no text on it.
pub fn getText(io: std.Io, allocator: std.mem.Allocator) ![]u8 {
    try io.checkCancel();
    const opened = try open(io);
    defer opened.close();
    const memory = win.GetClipboardData(win.CF_UNICODETEXT) orelse return allocator.dupe(u8, "");
    const data: [*]const u16 = @ptrCast(@alignCast(win.GlobalLock(memory) orelse return error.ClipboardFailed));
    defer _ = win.GlobalUnlock(memory);
    const units = data[0 .. win.GlobalSize(memory) / 2];
    const end = std.mem.indexOfScalar(u16, units, 0) orelse units.len;
    return std.unicode.wtf16LeToWtf8Alloc(allocator, units[0..end]);
}

const Opened = struct {
    owner: win.HWND,

    fn close(self: Opened) void {
        _ = win.CloseClipboard();
        _ = win.DestroyWindow(self.owner);
    }
};

fn open(io: std.Io) !Opened {
    // EmptyClipboard needs a real owner for SetClipboardData to work
    const owner = win.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("STATIC"),
        std.unicode.utf8ToUtf16LeStringLiteral("tuft"),
        win.WS_OVERLAPPEDWINDOW,
        0,
        0,
        64,
        64,
        null,
        null,
        null,
        null,
    ) orelse return error.CreateWindowFailed;
    errdefer _ = win.DestroyWindow(owner);
    var attempt: usize = 0;
    while (!win.OpenClipboard(owner).toBool()) : (attempt += 1) {
        if (attempt == 9) return error.ClipboardBusy;
        try io.sleep(.fromMilliseconds(10), .awake);
    }
    return .{ .owner = owner };
}

fn fillDib(data: []u8, image: clipboard.Image) void {
    @memset(data[0..header_size], 0);
    std.mem.writeInt(u32, data[0..4], header_size, .little);
    std.mem.writeInt(i32, data[4..8], @intCast(image.width), .little);
    std.mem.writeInt(i32, data[8..12], -@as(i32, @intCast(image.height)), .little);
    std.mem.writeInt(u16, data[12..14], 1, .little);
    std.mem.writeInt(u16, data[14..16], 32, .little);
    std.mem.writeInt(u32, data[16..20], 3, .little); // BI_BITFIELDS
    std.mem.writeInt(u32, data[20..24], @intCast(image.pixels.len), .little);
    std.mem.writeInt(u32, data[40..44], 0x00ff0000, .little);
    std.mem.writeInt(u32, data[44..48], 0x0000ff00, .little);
    std.mem.writeInt(u32, data[48..52], 0x000000ff, .little);
    std.mem.writeInt(u32, data[52..56], 0xff000000, .little);
    std.mem.writeInt(u32, data[56..60], 0x73524742, .little); // LCS_sRGB
    std.mem.writeInt(u32, data[108..112], 4, .little); // LCS_GM_IMAGES
    var i: usize = 0;
    while (i < image.pixels.len) : (i += 4) {
        @memcpy(data[header_size + i ..][0..4], &[_]u8{ image.pixels[i + 2], image.pixels[i + 1], image.pixels[i], image.pixels[i + 3] });
    }
}

test "DIB has top-down BGRA pixels and sRGB masks" {
    var data: [header_size + 8]u8 = undefined;
    fillDib(&data, .{ .width = 1, .height = 2, .pixels = &.{ 255, 0, 0, 9, 0, 0, 255, 7 } });
    try std.testing.expectEqual(-2, std.mem.readInt(i32, data[8..12], .little));
    try std.testing.expectEqual(0x00ff0000, std.mem.readInt(u32, data[40..44], .little));
    try std.testing.expectEqual(0x73524742, std.mem.readInt(u32, data[56..60], .little));
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 255, 9, 255, 0, 0, 7 }, data[header_size..]);
}
