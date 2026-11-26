//! RWX pages for code we write, near a target or anywhere.

const std = @import("std");
const arch = @import("tuft_arch");
const sys = @import("tuft_sys");

pub const size = sys.memory.page_size;
pub const Slice = sys.memory.PageSlice;

/// Within `arch.near_range` of `target`, or null if there's no room.
pub const allocNear = sys.memory.allocNear;
pub const allocNearSpan = sys.memory.allocNearSpan;
pub const allocAny = sys.memory.allocAny;
pub const free = sys.memory.free;

/// For when nothing near `target` is free. Far pages for one module share a zone, so they reach each other.
pub fn allocFar(target: usize, len: usize) !Slice {
    if (arch.near_reaches_all) return allocAny(len);
    const key = zoneKey(target);
    if (zoneOf(key)) |at| {
        if (try allocNearSpan(at -| zone_span / 2, at +| zone_span / 2, len)) |page| return page;
    }
    const page = try allocAny(len);
    remember(key, @intFromPtr(page.ptr));
    return page;
}

/// Which far zone `target` gets. Its module's, or the 2GB it's in.
pub fn zoneKey(target: usize) usize {
    return (sys.module.containingBase(target) orelse target) & ~@as(usize, 0x7FFF_FFFF);
}

/// Half the reach either side, so any two pages in a zone reach each other.
const zone_span: usize = if (arch.near_reaches_all) 0 else arch.near_range;

const Zone = struct { key: usize, at: usize };
var zones: [32]Zone = @splat(.{ .key = 0, .at = 0 });
var zones_lock: sys.sync.RwLock = .{};

fn zoneOf(key: usize) ?usize {
    zones_lock.lockShared();
    defer zones_lock.unlockShared();
    for (zones) |z| if (z.at != 0 and z.key == key) return z.at;
    return null;
}

fn remember(key: usize, at: usize) void {
    zones_lock.lock();
    defer zones_lock.unlock();
    // A full table starts over, it only costs the next page a new zone
    const slot = for (&zones) |*z| {
        if (z.at == 0 or z.key == key) break z;
    } else &zones[0];
    slot.* = .{ .key = key, .at = at };
}

test "far pages for one module reach each other" {
    if (arch.near_reaches_all) return error.SkipZigTest;
    const base = sys.module.mainBase();
    const a = try allocFar(base, 64);
    defer free(a);
    const b = try allocFar(base + 0x100, 64);
    defer free(b);
    const from = @intFromPtr(a.ptr);
    const to = @intFromPtr(b.ptr);
    try std.testing.expect(arch.encodeNearJmp(from, to + b.len - 1) != null and arch.encodeNearJmp(to, from + a.len - 1) != null);
}

pub const Stats = sys.memory.PageStats;
pub const stats = sys.memory.pageStats;
