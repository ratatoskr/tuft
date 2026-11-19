//! Turns what NT calls get into our paths, like `\??\C:\a` or a root handle plus `b\c`.

const std = @import("std");

const Vfs = @import("../root.zig");
const paths = Vfs.paths;
const nt = @import("nt.zig");

/// Longest path we track, in WTF-8 bytes. Longer ones go untracked.
pub const max = 2048;

const Device = struct {
    /// Like `\Device\HarddiskVolume3`.
    name: [96]u8 = undefined,
    len: usize = 0,
    letter: u8 = 0,
};

/// Drive letters by their device, so root handles' names map back. Filled by `init`.
var devices: [26]Device = @splat(.{});
var device_count: usize = 0;

pub fn init() void {
    device_count = 0;
    const drives = nt.GetLogicalDrives();
    for (0..26) |i| {
        if (drives & (@as(u32, 1) << @intCast(i)) == 0) continue;
        const drive = [_:0]u16{ 'A' + @as(u16, @intCast(i)), ':' };
        var target: [256]u16 = undefined;
        const n = nt.QueryDosDeviceW(&drive, &target, target.len);
        if (n == 0) continue;
        const first = std.mem.sliceTo(target[0..n], 0);
        const d = &devices[device_count];
        if (std.unicode.calcWtf8Len(first) > d.name.len) continue;
        d.len = std.unicode.wtf16LeToWtf8(&d.name, first);
        d.letter = 'A' + @as(u8, @intCast(i));
        device_count += 1;
    }
}

/// The path `oa` names, or null if it doesn't fit or has no name.
pub fn resolve(vfs: *Vfs, oa: *const nt.OBJECT_ATTRIBUTES, by_id: bool, out: *[max]u8) ?[]u8 {
    const name = if (oa.ObjectName) |n| n.slice() else &.{};
    const root = oa.RootDirectory orelse {
        if (by_id) return null;
        return fromNt(name, out);
    };
    var len = (rootPath(vfs, root, out) orelse return null).len;
    if (by_id) {
        const tag = "/(by id)";
        if (len + tag.len > out.len) return null;
        @memcpy(out[len..][0..tag.len], tag);
        return out[0 .. len + tag.len];
    }
    if (name.len == 0) return out[0..len];
    if (out[len - 1] != paths.sep) {
        if (len == out.len) return null;
        out[len] = paths.sep;
        len += 1;
    }
    if (std.unicode.calcWtf8Len(name) > out.len - len) return null;
    len += std.unicode.wtf16LeToWtf8(out[len..], name);
    return trim(out[0..len]);
}

fn rootPath(vfs: *Vfs, root: nt.HANDLE, out: *[max]u8) ?[]u8 {
    if (vfs.lookup(@intFromPtr(root))) |f| {
        defer f.release(vfs);
        if (f.path.len > out.len) return null;
        @memcpy(out[0..f.path.len], f.path);
        return out[0..f.path.len];
    }
    // Opened before us, like the current directory usually is
    var buf: [1024]u16 align(8) = undefined;
    var got: u32 = 0;
    if (!nt.ok(nt.NtQueryObject(root, nt.ObjectNameInformation, &buf, @sizeOf(@TypeOf(buf)), &got))) return null;
    const us: *const nt.UNICODE_STRING = @ptrCast(&buf);
    return fromNt(us.slice(), out);
}

/// `\??\C:\a` to `C:\a`, `\Device\HarddiskVolume3\a` to `C:\a`, and so on.
pub fn fromNt(name: []const u16, out: *[max]u8) ?[]u8 {
    if (std.unicode.calcWtf8Len(name) > out.len) return null;
    var len = std.unicode.wtf16LeToWtf8(out, name);
    const Swap = struct { from: []const u8, to: []const u8 };
    const swaps = [_]Swap{
        .{ .from = "\\??\\UNC\\", .to = "\\\\" },
        .{ .from = "\\GLOBAL??\\UNC\\", .to = "\\\\" },
        .{ .from = "\\Device\\Mup\\", .to = "\\\\" },
        .{ .from = "\\??\\", .to = "" },
        .{ .from = "\\GLOBAL??\\", .to = "" },
        .{ .from = "\\DosDevices\\", .to = "" },
    };
    for (swaps) |s| {
        if (std.ascii.startsWithIgnoreCase(out[0..len], s.from)) {
            len = replacePrefix(out, len, s.from.len, s.to);
            return trim(out[0..len]);
        }
    }
    for (devices[0..device_count]) |*d| {
        const dev = d.name[0..d.len];
        if (!std.ascii.startsWithIgnoreCase(out[0..len], dev)) continue;
        if (len > dev.len and out[dev.len] != '\\') continue;
        len = replacePrefix(out, len, dev.len, &.{ d.letter, ':' });
        if (len == 2) {
            out[2] = paths.sep;
            len = 3;
        }
        return trim(out[0..len]);
    }
    return trim(out[0..len]);
}

fn replacePrefix(out: []u8, len: usize, old: usize, new: []const u8) usize {
    // Only ever shrinks
    std.debug.assert(new.len <= old);
    std.mem.copyForwards(u8, out[new.len..], out[old..len]);
    @memcpy(out[0..new.len], new);
    return len - old + new.len;
}

/// Swaps in our slashes and drops a trailing one, except a drive root's.
fn trim(path: []u8) []u8 {
    std.mem.replaceScalar(u8, path, '\\', paths.sep);
    if (path.len > 1 and path[path.len - 1] == paths.sep and !paths.isRoot(path)) return path[0 .. path.len - 1];
    return path;
}

/// Our path as an NT name, like `\??\C:\a`, for redirects.
pub fn toNt(path: []const u8, out: []u16) ?[]u16 {
    var len: usize = 0;
    var rest = path;
    const prefix: []const u8 = if (std.mem.startsWith(u8, path, "//")) blk: {
        rest = path[2..];
        break :blk "\\??\\UNC\\";
    } else if (path.len >= 2 and path[1] == ':') "\\??\\" else "";
    if (len + prefix.len > out.len) return null;
    for (prefix) |c| {
        out[len] = c;
        len += 1;
    }
    const need = std.unicode.calcWtf16LeLen(rest) catch return null;
    if (len + need > out.len) return null;
    const n = std.unicode.wtf8ToWtf16Le(out[len..], rest) catch return null;
    std.mem.replaceScalar(u16, out[len..][0..n], paths.sep, '\\');
    return out[0 .. len + n];
}

/// The path as the system shows it in names, like `\Game\a.pak` for `C:/Game/a.pak`.
/// Still has our slashes, so swap them on the way out.
pub fn volumeRelative(path: []const u8) []const u8 {
    if (path.len >= 2 and path[1] == ':') return path[2..];
    if (std.mem.startsWith(u8, path, "//")) return path[1..];
    return path;
}

const testing = std.testing;

fn expectFromNt(expected: []const u8, name: []const u8) !void {
    var wide: [256]u16 = undefined;
    const n = try std.unicode.wtf8ToWtf16Le(&wide, name);
    var out: [max]u8 = undefined;
    try testing.expectEqualStrings(expected, fromNt(wide[0..n], &out).?);
}

test "maps NT names" {
    init();
    try expectFromNt("C:/Game/a.pak", "\\??\\C:\\Game\\a.pak");
    try expectFromNt("C:/", "\\??\\C:\\");
    try expectFromNt("//srv/share/a", "\\??\\UNC\\srv\\share\\a");
    try expectFromNt("/Device/Afd/Endpoint", "\\Device\\Afd\\Endpoint");

    // The system drive's device maps back to its letter
    var target: [256]u16 = undefined;
    const drive = [_:0]u16{ 'C', ':' };
    const n = nt.QueryDosDeviceW(&drive, &target, target.len);
    if (n == 0) return;
    var dev: [256]u8 = undefined;
    const len = std.unicode.wtf16LeToWtf8(&dev, std.mem.sliceTo(target[0..n], 0));
    var buf: [300]u8 = undefined;
    try expectFromNt("C:/Windows", try std.fmt.bufPrint(&buf, "{s}\\Windows", .{dev[0..len]}));
}

test "makes NT names" {
    var out: [64]u16 = undefined;
    var back: [max]u8 = undefined;
    var wide: [64]u16 = undefined;
    const n = try std.unicode.wtf8ToWtf16Le(&wide, "\\??\\C:\\a\\b");
    try testing.expectEqualSlices(u16, wide[0..n], toNt("C:/a/b", &out).?);
    for ([_][]const u8{ "C:/a/b", "//srv/share/x", "/Device/Null" }) |p| {
        try testing.expectEqualStrings(p, fromNt(toNt(p, &out).?, &back).?);
    }
}
