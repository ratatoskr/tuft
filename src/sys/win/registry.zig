const std = @import("std");

const win = @import("api.zig");
const registry = @import("../root.zig").registry;

pub const Key = struct {
    handle: win.HKEY,

    pub fn open(root: registry.Root, path: []const u8, view: registry.View) !?Key {
        var wide: [512:0]u16 = undefined;
        const n = std.unicode.wtf8ToWtf16Le(&wide, path) catch return error.BadPath;
        wide[n] = 0;
        const root_key = switch (root) {
            .current_user => win.HKEY_CURRENT_USER,
            .local_machine => win.HKEY_LOCAL_MACHINE,
        };
        const access = win.KEY_READ | @as(win.DWORD, if (view == .x86) win.KEY_WOW64_32KEY else 0);
        var handle: ?win.HKEY = null;
        return switch (win.RegOpenKeyExW(root_key, &wide, 0, access, &handle)) {
            win.ERROR_SUCCESS => .{ .handle = handle.? },
            // Missing or not ours to read
            else => null,
        };
    }

    pub fn close(self: Key) void {
        _ = win.RegCloseKey(self.handle);
    }

    pub fn stringAlloc(self: Key, allocator: std.mem.Allocator, name: []const u8) !?[]u8 {
        var name_w: [256:0]u16 = undefined;
        const n = std.unicode.wtf8ToWtf16Le(&name_w, name) catch return error.BadName;
        name_w[n] = 0;
        var kind: win.DWORD = 0;
        var size: win.DWORD = 0;
        if (win.RegQueryValueExW(self.handle, &name_w, null, &kind, null, &size) != win.ERROR_SUCCESS) return null;
        if (kind != win.REG_SZ and kind != win.REG_EXPAND_SZ) return null;
        const data = try allocator.alloc(u16, size / 2 + 1);
        defer allocator.free(data);
        var got: win.DWORD = @intCast(data.len * 2);
        if (win.RegQueryValueExW(self.handle, &name_w, null, null, @ptrCast(data.ptr), &got) != win.ERROR_SUCCESS) return null;
        // May or may not include the terminator
        const text = std.mem.sliceTo(data[0 .. got / 2], 0);
        const utf8 = try allocator.alloc(u8, std.unicode.calcWtf8Len(text));
        return utf8[0..std.unicode.wtf16LeToWtf8(utf8, text)];
    }

    /// Null if it's missing or not a DWORD.
    pub fn dword(self: Key, name: []const u8) !?u32 {
        var name_w: [256:0]u16 = undefined;
        const n = std.unicode.wtf8ToWtf16Le(&name_w, name) catch return error.BadName;
        name_w[n] = 0;
        var kind: win.DWORD = 0;
        var value: u32 = 0;
        var size: win.DWORD = @sizeOf(u32);
        if (win.RegQueryValueExW(self.handle, &name_w, null, &kind, @ptrCast(&value), &size) != win.ERROR_SUCCESS) return null;
        return if (kind == win.REG_DWORD and size == @sizeOf(u32)) value else null;
    }

    pub fn subkeysAlloc(self: Key, allocator: std.mem.Allocator) ![]const []const u8 {
        var names: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (names.items) |name| allocator.free(name);
            names.deinit(allocator);
        }
        var index: win.DWORD = 0;
        while (true) : (index += 1) {
            // Key names are at most 255 characters
            var name: [256]u16 = undefined;
            var len: win.DWORD = name.len;
            switch (win.RegEnumKeyExW(self.handle, index, &name, &len, null, null, null, null)) {
                win.ERROR_SUCCESS => {},
                win.ERROR_NO_MORE_ITEMS => break,
                else => return error.RegistryReadFailed,
            }
            const utf8 = try allocator.alloc(u8, std.unicode.calcWtf8Len(name[0..len]));
            errdefer allocator.free(utf8);
            try names.append(allocator, utf8[0..std.unicode.wtf16LeToWtf8(utf8, name[0..len])]);
        }
        return names.toOwnedSlice(allocator);
    }
};

test "keys, strings and missing values" {
    const a = std.testing.allocator;
    const key = (try Key.open(.local_machine, "SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion", .native)).?;
    defer key.close();
    const product = (try key.stringAlloc(a, "ProductName")).?;
    defer a.free(product);
    try std.testing.expect(std.mem.startsWith(u8, product, "Windows"));
    try std.testing.expectEqual(null, try key.stringAlloc(a, "NoSuchValueZz"));
    // A string isn't a DWORD
    try std.testing.expectEqual(null, try key.dword("ProductName"));
    try std.testing.expect(try key.dword("CurrentMajorVersionNumber") != null);

    const software = (try Key.open(.local_machine, "SOFTWARE", .native)).?;
    defer software.close();
    const subkeys = try software.subkeysAlloc(a);
    defer registry.free(a, subkeys);
    for (subkeys) |name| {
        if (std.ascii.eqlIgnoreCase(name, "Microsoft")) break;
    } else return error.TestUnexpectedResult;

    try std.testing.expectEqual(null, try Key.open(.current_user, "Software\\NoSuchKeyZz", .native));
}
