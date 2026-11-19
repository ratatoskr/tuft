const std = @import("std");
const thread = @import("thread.zig");
const native = @import("win/module.zig");

pub const Section = struct {
    name_buf: [8]u8,
    name_len: u8,
    start: usize,
    len: usize,
    executable: bool,
    readable: bool,
    writable: bool,

    pub fn name(self: *const Section) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    pub fn range(self: *const Section) thread.CodeRange {
        return .{ .start = self.start, .len = self.len };
    }
};

pub const mainBase = native.mainBase;
pub const findBase = native.findBase;
pub const containingBase = native.containingBase;
pub const nameOf = native.nameOf;
pub const pathOf = native.pathOf;
pub const imageSize = native.imageSize;
/// The exe's entry point or the DLL's DllMain.
pub const entryPoint = native.entryPoint;
pub const sections = native.sections;
pub const SectionIterator = native.SectionIterator;

pub fn section(base: usize, name: []const u8) !?Section {
    var it = try sections(base);
    while (it.next()) |s| {
        if (std.mem.eql(u8, s.name(), name)) return s;
    }
    return null;
}

/// In System32 or SysWOW64.
pub const inSystemDir = native.inSystemDir;
/// Includes subfolders, such as DriverStore.
pub const inSystemTree = native.inSystemTree;
/// Load notices, inside the loader lock or after init.
pub const LoadWatch = @import("win/loads.zig");
/// Calls back when loaded, or now if already loaded.
pub const WhenLoaded = @import("win/when_loaded.zig");
/// Resolves on use. Linking doesn't load the DLL.
pub const lazyFn = native.lazyFn;
/// Follows forwarders.
pub const findExport = native.findExport;
/// For exports with no name. Follows forwarders.
pub const findOrdinal = native.findOrdinal;
/// Pair with `unload`.
pub const load = native.load;
/// Waits up to 5 seconds for the DLL's threads to exit.
pub const unload = native.unload;
/// Real system DLL, not a proxy. Stays loaded.
pub const systemBase = native.systemBase;
/// The module tuft is linked into.
pub const selfBase = native.selfBase;
