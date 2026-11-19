//! Loaded graphics DLLs and the wrappers among them.

const std = @import("std");

const sys = @import("tuft_sys");

/// Graphics API DLLs, plus names that layers load under.
pub const names = [_][]const u8{
    "ddraw.dll",      "d3d8.dll",      "d3d9.dll",      "d3d10.dll",      "d3d10_1.dll",
    "d3d10core.dll",  "d3d11.dll",     "d3d12.dll",     "dxgi.dll",       "opengl32.dll",
    "vulkan-1.dll",   "ReShade64.dll", "ReShade32.dll", "SpecialK64.dll", "SpecialK32.dll",
    "dxvk_d3d11.dll", "dxvk_dxgi.dll",
};

pub const Known = enum {
    dxvk,
    d3d8to9,
    dgvoodoo,
    reshade,
    special_k,
    wine,
    enb,

    /// Matched case-insensitively against the description and product name.
    const markers = [_]struct { Known, []const u8 }{
        .{ .dxvk, "dxvk" },
        .{ .d3d8to9, "d3d8to9" },
        .{ .dgvoodoo, "dgvoodoo" },
        .{ .reshade, "reshade" },
        .{ .special_k, "special k" },
        .{ .wine, "wine" },
        .{ .enb, "enbseries" },
    };

    fn of(info: *const sys.version.FileInfo) ?Known {
        for (markers) |m| {
            if (std.ascii.findIgnoreCase(info.description, m[1]) != null) return m[0];
            if (std.ascii.findIgnoreCase(info.product_name, m[1]) != null) return m[0];
        }
        return null;
    }
};

pub const Dll = struct {
    name: []const u8,
    path: []const u8,
    /// From the system folder, so Windows' own unless replaced there.
    system: bool,
    info: ?sys.version.FileInfo,
    known: ?Known,

    pub fn replaced(self: *const Dll) bool {
        return !self.system or self.known != null;
    }
};

pub const Report = struct {
    arena: std.heap.ArenaAllocator,
    dlls: []Dll,

    pub fn deinit(self: *Report) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// Like `"d3d8.dll"`.
    pub fn find(self: *const Report, name: []const u8) ?*const Dll {
        for (self.dlls) |*d| if (std.ascii.eqlIgnoreCase(d.name, name)) return d;
        return null;
    }

    pub fn has(self: *const Report, known: Known) bool {
        for (self.dlls) |*d| if (d.known == known) return true;
        return false;
    }
};

pub fn scan(allocator: std.mem.Allocator) !Report {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    var dlls: std.ArrayList(Dll) = .empty;
    for (names) |name| {
        const base = sys.module.findBase(name) orelse continue;
        var buf: [260 * 3]u8 = undefined;
        const path = try a.dupe(u8, sys.module.pathOf(base, &buf) orelse continue);
        var info = sys.version.fileInfo(a, path) catch null;
        try dlls.append(a, .{
            .name = name,
            .path = path,
            .system = sys.module.inSystemDir(path),
            .known = if (info) |*i| Known.of(i) else null,
            .info = info,
        });
    }
    return .{ .arena = arena, .dlls = try dlls.toOwnedSlice(a) };
}

test "finds loaded DLLs" {
    // Loads Windows' d3d9 if nothing has yet.
    _ = try sys.module.systemBase("d3d9.dll");
    var report = try scan(std.testing.allocator);
    defer report.deinit();
    const d3d9 = report.find("d3d9.dll").?;
    try std.testing.expect(d3d9.system);
    try std.testing.expect(!d3d9.replaced());
    try std.testing.expect(std.mem.find(u8, d3d9.info.?.company_name, "Microsoft") != null);
    try std.testing.expect(!report.has(.dxvk));
}

test "recognizes wrappers" {
    var info: sys.version.FileInfo = .{ .description = "d3d8to9 Wrapper", .product_name = "" };
    try std.testing.expectEqual(Known.d3d8to9, Known.of(&info).?);
    info = .{ .description = "", .product_name = "DXVK" };
    try std.testing.expectEqual(Known.dxvk, Known.of(&info).?);
    info = .{ .description = "Direct3D 9 Runtime", .product_name = "Microsoft® Windows® Operating System" };
    try std.testing.expectEqual(null, Known.of(&info));
}
