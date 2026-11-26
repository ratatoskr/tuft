//! Address to name and back, like `kernel32.dll+0x1234`.

const Symbols = @This();

const std = @import("std");

const Module = @import("root.zig").Module;
const Address = @import("root.zig").Address;
const Sig = @import("Sig.zig");

context: ?*anyopaque = null,
vtable: *const VTable,

pub const VTable = struct {
    resolve: ?*const fn (context: ?*anyopaque, name: []const u8) ?usize = null,
    /// Null if nothing named contains it.
    describe: ?*const fn (context: ?*anyopaque, address: usize, buf: []u8) ?[]const u8 = null,
    /// A module, or `module:section`.
    extent: ?*const fn (context: ?*anyopaque, name: []const u8) ?Extent = null,
    /// Finds `sig`, maybe from an earlier scan. `name` is what a new scan is logged as.
    scan: ?*const fn (context: ?*anyopaque, sig: Sig, name: []const u8) Address = null,
    /// Why a name it knows didn't resolve, written into `buf`. Null if it doesn't know it.
    why: ?*const fn (context: ?*anyopaque, name: []const u8, buf: []u8) ?Miss = null,
};

/// Why a known name isn't anywhere right now.
pub const Miss = struct {
    /// NotFound, Unreadable for a bad pointer on the way, or InvalidAddress for bad text.
    err: error{ NotFound, Unreadable, InvalidAddress },
    message: []const u8,
};

pub const Extent = struct { start: usize, len: usize };

pub const none: Symbols = .{ .vtable = &.{} };

/// Modules and their exports, like `kernel32.dll` and `kernel32.dll!Sleep`. Case-insensitive.
pub const local: Symbols = .{ .vtable = &.{ .resolve = localResolve, .describe = localDescribe, .extent = localExtent, .scan = localScan } };

pub fn resolve(self: Symbols, name: []const u8) ?usize {
    const f = self.vtable.resolve orelse return null;
    return f(self.context, name);
}

pub fn describe(self: Symbols, address: usize, buf: []u8) ?[]const u8 {
    const f = self.vtable.describe orelse return null;
    return f(self.context, address, buf);
}

pub fn extent(self: Symbols, name: []const u8) ?Extent {
    const f = self.vtable.extent orelse return null;
    return f(self.context, name);
}

/// Asked after `resolve` gives null.
pub fn why(self: Symbols, name: []const u8, buf: []u8) ?Miss {
    const f = self.vtable.why orelse return null;
    return f(self.context, name, buf);
}

pub fn scan(self: Symbols, sig: Sig, name: []const u8) Address {
    const f = self.vtable.scan orelse return .fail(error.NoScanner);
    return f(self.context, sig, name);
}

fn localScan(_: ?*anyopaque, sig: Sig, name: []const u8) Address {
    return sig.locate(name);
}

fn localExtent(_: ?*anyopaque, name: []const u8) ?Extent {
    const colon = std.mem.indexOfScalar(u8, name, ':');
    const module = Module.find(if (colon) |i| name[0..i] else name) catch return null;
    const range = (if (colon) |i| module.section(name[i + 1 ..]) else module.range()) catch return null;
    return .{ .start = range.start, .len = range.len };
}

fn localResolve(_: ?*anyopaque, name: []const u8) ?usize {
    if (std.mem.indexOfScalar(u8, name, '!')) |bang| {
        const module = Module.find(name[0..bang]) catch return null;
        return module.symbol(name[bang + 1 ..]).orNull();
    }
    const module = Module.find(name) catch return null;
    return module.base;
}

fn localDescribe(_: ?*anyopaque, address: usize, buf: []u8) ?[]const u8 {
    const module = Module.containing(address) catch return null;
    var name: [260]u8 = undefined;
    const module_name = module.name(&name) orelse return null;
    return std.fmt.bufPrint(buf, "{s}+0x{x}", .{ module_name, address - module.base }) catch null;
}

test "local names both ways" {
    const kernel32 = local.resolve("kernel32.dll").?;
    var buf: [64]u8 = undefined;
    try std.testing.expect(std.ascii.eqlIgnoreCase("kernel32.dll+0x10", local.describe(kernel32 + 0x10, &buf).?));
    try std.testing.expectEqual(null, local.describe(0x10, &buf));
    try std.testing.expectEqual(null, none.resolve("kernel32.dll"));
    try std.testing.expectEqual(null, none.describe(kernel32, &buf));
    const sleep = local.resolve("kernel32.dll!Sleep").?;
    try std.testing.expect(sleep > kernel32);
    try std.testing.expectEqual(null, local.resolve("kernel32.dll!NoSuchThing"));
}

test "local module spans" {
    const whole = local.extent("kernel32.dll").?;
    const text = local.extent("KERNEL32.dll:.text").?;
    try std.testing.expectEqual(local.resolve("kernel32.dll").?, whole.start);
    try std.testing.expect(text.start > whole.start and text.start + text.len <= whole.start + whole.len);
    try std.testing.expectEqual(null, local.extent("kernel32.dll:.nothing"));
    try std.testing.expectEqual(null, none.extent("kernel32.dll"));
}
