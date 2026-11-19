//! Memory to read and write, this process or anything implementing `VTable`.

const Memory = @This();

const std = @import("std");

const sys = @import("tuft_sys");

context: ?*anyopaque = null,
vtable: *const VTable,

pub const Error = error{
    Unreadable,
    Unwritable,
};

pub const VTable = struct {
    /// All of `out`, or none of it on error.
    read: *const fn (context: ?*anyopaque, address: usize, out: []u8) Error!void,
    /// Null if the memory can't be written.
    write: ?*const fn (context: ?*anyopaque, address: usize, bytes: []const u8) Error!void = null,
    /// In place, or null. Optional, lets scans skip copying.
    direct: ?*const fn (context: ?*anyopaque, address: usize, len: usize) ?[]const u8 = null,
    /// Optional, lets a search cover everything.
    region_from: ?*const fn (context: ?*anyopaque, address: usize) ?Region = null,
    /// `read` without page checks, for big reads. Optional.
    read_in_region: ?*const fn (context: ?*anyopaque, address: usize, out: []u8) Error!void = null,
};

pub const Region = sys.memory.Region;

/// Writes ignore page protection and flush the instruction cache.
pub const local: Memory = .{ .vtable = &.{
    .read = localRead,
    .write = localWrite,
    .direct = localDirect,
    .region_from = localRegionFrom,
    .read_in_region = localReadInRegion,
} };

pub fn isLocal(self: Memory) bool {
    return self.vtable == local.vtable;
}

pub fn read(self: Memory, address: usize, out: []u8) Error!void {
    return self.vtable.read(self.context, address, out);
}

pub fn write(self: Memory, address: usize, bytes: []const u8) Error!void {
    const f = self.vtable.write orelse return error.Unwritable;
    return f(self.context, address, bytes);
}

/// Null past the last one, or if it can't be walked.
pub fn regionFrom(self: Memory, address: usize) ?Region {
    const f = self.vtable.region_from orelse return null;
    return f(self.context, address);
}

/// Faster when the memory can skip re-checking.
pub fn readInRegion(self: Memory, address: usize, out: []u8) Error!void {
    const f = self.vtable.read_in_region orelse return self.read(address, out);
    return f(self.context, address, out);
}

pub fn canWalk(self: Memory) bool {
    return self.vtable.region_from != null;
}

/// Only good until the memory changes or gets unmapped.
pub fn direct(self: Memory, address: usize, len: usize) ?[]const u8 {
    const f = self.vtable.direct orelse return null;
    return f(self.context, address, len);
}

/// Unaligned is fine.
pub fn load(self: Memory, comptime T: type, address: usize) Error!T {
    var value: T = undefined;
    try self.read(address, std.mem.asBytes(&value));
    return value;
}

/// Unaligned is fine.
pub fn store(self: Memory, comptime T: type, address: usize, value: T) Error!void {
    return self.write(address, std.mem.asBytes(&value));
}

fn localRead(_: ?*anyopaque, address: usize, out: []u8) Error!void {
    // Check first so we never touch guard pages. Then read safely, since it could vanish meanwhile
    if (!sys.memory.isReadable(address, out.len)) return error.Unreadable;
    if (!sys.memory.readSafe(address, out)) return error.Unreadable;
}

// VirtualQuery gets slow on big regions, too slow to do per chunk
fn localReadInRegion(_: ?*anyopaque, address: usize, out: []u8) Error!void {
    if (!sys.memory.readSafe(address, out)) return error.Unreadable;
}

fn localRegionFrom(_: ?*anyopaque, address: usize) ?Region {
    return sys.memory.regionFrom(address);
}

fn localWrite(_: ?*anyopaque, address: usize, bytes: []const u8) Error!void {
    // Only mapped pages. Changing protection on anything else fails
    if (!sys.memory.isReadable(address, bytes.len)) return error.Unwritable;
    sys.memory.writeCode(address, bytes) catch return error.Unwritable;
}

fn localDirect(_: ?*anyopaque, address: usize, len: usize) ?[]const u8 {
    if (!sys.memory.isReadable(address, len)) return null;
    return @as([*]const u8, @ptrFromInt(address))[0..len];
}

const tests = struct {
    const testing = std.testing;

    test "local reads and writes" {
        var bytes: [12]u8 align(4) = @splat(0);
        const at = @intFromPtr(&bytes);
        const memory: Memory = .local;
        try memory.store(f32, at + 1, 1.5);
        try testing.expectEqual(1.5, try memory.load(f32, at + 1));
        try memory.store(u32, at + 8, 0xDEADBEEF);
        try testing.expectEqual(0xDEADBEEF, std.mem.readInt(u32, bytes[8..12], .little));
        try testing.expectError(error.Unreadable, memory.load(u32, 0));
        try testing.expectError(error.Unwritable, memory.store(u32, 0, 1));
    }

    test "local writes read-only pages" {
        const page = try sys.memory.allocAny(16);
        defer sys.memory.free(page);
        _ = try sys.memory.protect(@intFromPtr(page.ptr), page.len, .read);
        const memory: Memory = .local;
        try memory.store(u16, @intFromPtr(page.ptr), 0x1234);
        try testing.expectEqual(0x1234, try memory.load(u16, @intFromPtr(page.ptr)));
    }

    test "no write function" {
        const Fake = struct {
            fn read(_: ?*anyopaque, _: usize, out: []u8) Error!void {
                @memset(out, 0xAB);
            }
        };
        const memory: Memory = .{ .vtable = &.{ .read = Fake.read } };
        try testing.expectEqual(0xABAB, try memory.load(u16, 0x1000));
        try testing.expectError(error.Unwritable, memory.store(u16, 0x1000, 1));
    }
};

test {
    _ = tests;
}
