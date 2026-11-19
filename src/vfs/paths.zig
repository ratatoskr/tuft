//! Paths as the VFS keeps them. WTF-8 with forward slashes, like `C:/Game/data.pak`.
//! Keys fold ASCII case, since that's what file systems usually ignore.

const std = @import("std");

/// What normalized paths use. Input can have either.
pub const sep = '/';

/// Cleans up a path someone gave us, like `c:\game\.\mods\..\data.pak`.
/// Takes `C:/...`, UNC `//server/share/...`, `\\?\` and `\??\` prefixes, and `/Device/...`.
pub fn normalize(out: []u8, input: []const u8) error{ RelativePath, PathTooLong }![]u8 {
    var in = input;
    for ([_][]const u8{ "\\\\?\\UNC\\", "//?/UNC/", "\\??\\UNC\\" }) |p| {
        if (std.mem.startsWith(u8, in, p)) return finish(out, "//", in[p.len..]);
    }
    for ([_][]const u8{ "\\\\?\\", "//?/", "\\??\\", "\\\\.\\", "//./" }) |p| {
        if (std.mem.startsWith(u8, in, p)) {
            in = in[p.len..];
            break;
        }
    }
    if (in.len >= 2 and isSep(in[0]) and isSep(in[1])) return finish(out, "//", in[2..]);
    if (in.len >= 2 and std.ascii.isAlphabetic(in[0]) and in[1] == ':') {
        if (in.len > 2 and !isSep(in[2])) return error.RelativePath;
        const drive = [_]u8{ std.ascii.toUpper(in[0]), ':' };
        return finish(out, &drive, in[2..]);
    }
    if (in.len > 0 and isSep(in[0])) return finish(out, "", in);
    return error.RelativePath;
}

pub fn isSep(c: u8) bool {
    return c == '\\' or c == '/';
}

/// `prefix` plus each part of `rest`, with `.` and `..` resolved.
fn finish(out: []u8, prefix: []const u8, rest: []const u8) error{PathTooLong}![]u8 {
    if (prefix.len > out.len) return error.PathTooLong;
    @memcpy(out[0..prefix.len], prefix);
    var len = prefix.len;
    // UNC can't go above `//server/share`
    const unc = std.mem.eql(u8, prefix, "//");
    var root_parts: usize = if (unc) 2 else 0;
    var floor = len;
    var parts = std.mem.tokenizeAny(u8, rest, "\\/");
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..") and root_parts == 0) {
            const keep = std.mem.lastIndexOfScalar(u8, out[floor..len], sep) orelse 0;
            len = floor + keep;
            continue;
        }
        const gap: usize = if (len == 2 and unc) 0 else 1;
        if (len + gap + part.len > out.len) return error.PathTooLong;
        if (gap == 1) out[len] = sep;
        @memcpy(out[len + gap ..][0..part.len], part);
        len += gap + part.len;
        if (root_parts > 0) {
            root_parts -= 1;
            if (root_parts == 0) floor = len;
        }
    }
    // Drive roots keep their slash, like `C:/`
    if (len == prefix.len and !unc) {
        if (len == out.len) return error.PathTooLong;
        out[len] = sep;
        len += 1;
    }
    return out[0..len];
}

/// Lowercases ASCII into `out`, which can be `path`.
pub fn key(out: []u8, path: []const u8) []u8 {
    for (path, out[0..path.len]) |c, *o| o.* = std.ascii.toLower(c);
    return out[0..path.len];
}

/// Null for a root, like `C:/` or `//server/share`.
pub fn parent(path: []const u8) ?[]const u8 {
    if (isRoot(path)) return null;
    const i = std.mem.lastIndexOfScalar(u8, path, sep) orelse return null;
    // `C:/a` goes to `C:/`
    if (i == 2 and path[1] == ':') return path[0..3];
    if (i == 0) return null;
    return path[0..i];
}

pub fn name(path: []const u8) []const u8 {
    const i = std.mem.lastIndexOfScalar(u8, path, sep) orelse return path;
    return path[i + 1 ..];
}

pub fn isRoot(path: []const u8) bool {
    if (path.len == 3 and path[1] == ':' and path[2] == sep) return true;
    if (std.mem.startsWith(u8, path, "//")) return std.mem.count(u8, path[2..], "/") <= 1;
    return false;
}

const testing = std.testing;

fn expectNormal(expected: []const u8, input: []const u8) !void {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings(expected, try normalize(&buf, input));
}

test "normalizes" {
    try expectNormal("C:/Game/data.pak", "c:\\Game\\.\\mods\\..\\data.pak");
    try expectNormal("C:/Game/data.pak", "c:/Game/data.pak");
    try expectNormal("C:/Game/data.pak", "\\\\?\\C:\\Game\\data.pak");
    try expectNormal("C:/Game/data.pak", "\\??\\C:\\Game\\\\data.pak\\");
    try expectNormal("C:/", "C:\\");
    try expectNormal("C:/", "C:/../..");
    try expectNormal("//server/share/a", "\\\\server\\share\\..\\a");
    try expectNormal("//server/share/a", "\\\\?\\UNC\\server\\share\\a");
    try expectNormal("/Device/Afd", "\\Device\\Afd");
    var buf: [8]u8 = undefined;
    try testing.expectError(error.RelativePath, normalize(&buf, "data.pak"));
    try testing.expectError(error.RelativePath, normalize(&buf, "C:data.pak"));
    try testing.expectError(error.PathTooLong, normalize(&buf, "C:/too/long/path"));
}

test "parents and names" {
    try testing.expectEqualStrings("C:/Game", parent("C:/Game/a.pak").?);
    try testing.expectEqualStrings("C:/", parent("C:/Game").?);
    try testing.expectEqual(null, parent("C:/"));
    try testing.expectEqual(null, parent("//server/share"));
    try testing.expectEqualStrings("//server/share", parent("//server/share/a").?);
    try testing.expectEqualStrings("/Device", parent("/Device/Afd").?);
    try testing.expectEqualStrings("a.pak", name("C:/Game/a.pak"));
}
