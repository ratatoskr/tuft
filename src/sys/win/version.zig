//! A file's version resource.

const std = @import("std");

const win = @import("api.zig");

/// `major.minor.patch.build`
pub const Version = struct {
    major: u16,
    minor: u16,
    patch: u16,
    build: u16,

    fn of(ms: u32, ls: u32) Version {
        return .{ .major = @truncate(ms >> 16), .minor = @truncate(ms), .patch = @truncate(ls >> 16), .build = @truncate(ls) };
    }

    pub fn format(self: Version, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{d}.{d}.{d}.{d}", .{ self.major, self.minor, self.patch, self.build });
    }
};

pub const Versions = struct {
    file: Version,
    product: Version,
};

/// Missing strings are empty. `deinit` it.
pub const FileInfo = struct {
    versions: ?Versions = null,
    /// Like "DXVK".
    description: []const u8 = "",
    product_name: []const u8 = "",
    company_name: []const u8 = "",

    pub fn deinit(self: *FileInfo, allocator: std.mem.Allocator) void {
        inline for (.{ "description", "product_name", "company_name" }) |name| allocator.free(@field(self, name));
        self.* = undefined;
    }
};

/// Null if there's no version resource, which plenty of games lack.
pub fn fileInfo(allocator: std.mem.Allocator, path: []const u8) !?FileInfo {
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(allocator, path);
    defer allocator.free(wide);

    const size = win.GetFileVersionInfoSizeW(wide.ptr, null);
    if (size == 0) return null;
    const data = try allocator.alignedAlloc(u8, .of(u32), size);
    defer allocator.free(data);
    if (!win.GetFileVersionInfoW(wide.ptr, 0, size, data.ptr).toBool()) return null;

    var info: FileInfo = .{};
    errdefer info.deinit(allocator);
    var fixed: ?*anyopaque = null;
    var len: u32 = 0;
    if (win.VerQueryValueW(data.ptr, std.unicode.utf8ToUtf16LeStringLiteral("\\"), &fixed, &len).toBool() and fixed != null and len >= @sizeOf(win.VS_FIXEDFILEINFO)) {
        const f: *align(1) const win.VS_FIXEDFILEINFO = @ptrCast(fixed.?);
        if (f.dwSignature == win.VS_FFI_SIGNATURE) info.versions = .{
            .file = .of(f.dwFileVersionMS, f.dwFileVersionLS),
            .product = .of(f.dwProductVersionMS, f.dwProductVersionLS),
        };
    }

    // Strings live under the first listed language, else US English Unicode
    var lang: u32 = 0x0409_04B0;
    var translation: ?*anyopaque = null;
    if (win.VerQueryValueW(data.ptr, std.unicode.utf8ToUtf16LeStringLiteral("\\VarFileInfo\\Translation"), &translation, &len).toBool() and translation != null and len >= 4) {
        const pair: *align(1) const [2]u16 = @ptrCast(translation.?);
        lang = (@as(u32, pair[0]) << 16) | pair[1];
    }
    info.description = try stringOf(allocator, data, lang, "FileDescription");
    info.product_name = try stringOf(allocator, data, lang, "ProductName");
    info.company_name = try stringOf(allocator, data, lang, "CompanyName");
    return info;
}

/// Empty if it's missing.
fn stringOf(allocator: std.mem.Allocator, data: []align(4) const u8, lang: u32, comptime key: []const u8) ![]const u8 {
    var path_buf: [64]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "\\StringFileInfo\\{x:0>8}\\" ++ key, .{lang}) catch unreachable;
    var wide_buf: [64:0]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&wide_buf, path) catch unreachable;
    wide_buf[n] = 0;

    var value: ?*anyopaque = null;
    var len: u32 = 0;
    if (!win.VerQueryValueW(data.ptr, wide_buf[0..n :0], &value, &len).toBool() or value == null or len == 0) return allocator.dupe(u8, "");
    const chars: [*]align(1) const u16 = @ptrCast(value.?);
    // `len` is in characters and includes the terminator
    var end: usize = len;
    while (end > 0 and chars[end - 1] == 0) end -= 1;
    const copy = try allocator.alloc(u16, end);
    defer allocator.free(copy);
    for (0..end) |i| copy[i] = chars[i];
    return std.unicode.utf16LeToUtf8Alloc(allocator, copy);
}

test "system DLL version" {
    const allocator = std.testing.allocator;
    var dir: [win.MAX_PATH]u16 = undefined;
    const dir_len = win.GetSystemDirectoryW(&dir, dir.len);
    const system = try std.unicode.utf16LeToUtf8Alloc(allocator, dir[0..dir_len]);
    defer allocator.free(system);
    const path = try std.fs.path.join(allocator, &.{ system, "kernel32.dll" });
    defer allocator.free(path);

    var info = (try fileInfo(allocator, path)).?;
    defer info.deinit(allocator);
    try std.testing.expect(info.versions.?.file.major >= 6);
    try std.testing.expect(std.mem.indexOf(u8, info.product_name, "Windows") != null);
    try std.testing.expect(std.mem.indexOf(u8, info.company_name, "Microsoft") != null);
    try std.testing.expect(info.description.len > 0);
}
