//! Signature scan reporting, one recorder per DLL.

const std = @import("std");
const atomic = @import("tuft_arch").atomic;

const pattern = @import("pattern.zig");
const AddressSource = @import("originals.zig").AddressSource;

pub const Outcome = enum(u8) {
    found,
    not_found,
    not_unique,
};

/// Only valid during the recorder call.
pub const Record = struct {
    name: []const u8,
    pattern: []const u8,
    start: usize,
    len: usize,
    /// Which copy was scanned.
    source: AddressSource = .live,
    /// Took the first of several matches.
    first_match: bool = false,
    outcome: Outcome,
    address: usize = 0,
    ns: u64,
};

pub const Recorder = *const fn (record: *const Record) void;

var recorder: std.atomic.Value(?Recorder) = .init(null);

/// Returns the old recorder. Thread-safe.
pub fn setRecorder(new: ?Recorder) ?Recorder {
    return recorder.swap(new, .acq_rel);
}

pub fn report(record: *const Record) void {
    if (recorder.load(.acquire)) |r| r(record);
}

/// Where a scan matched before, and in which copy.
pub const Hit = struct {
    at: usize,
    source: AddressSource = .live,
};

/// Remembers where scans matched, so the next run checks that spot before scanning. Local memory only.
pub const Cache = struct {
    /// `pattern` as `format` gives it.
    lookup: *const fn (start: usize, len: usize, pattern: []const u8, first_match: bool) ?Hit,
    /// Null forgets it.
    remember: *const fn (start: usize, len: usize, pattern: []const u8, first_match: bool, hit: ?Hit) void,
};

var cache: atomic.Value(?*const Cache) = .init(null);

/// Returns the old cache. Thread-safe.
pub fn setCache(new: ?*const Cache) ?*const Cache {
    return cache.swap(new, .acq_rel);
}

pub fn cached(start: usize, len: usize, text: []const u8, first_match: bool) ?Hit {
    const c = cache.load(.acquire) orelse return null;
    return c.lookup(start, len, text, first_match);
}

pub fn remember(start: usize, len: usize, text: []const u8, first_match: bool, hit: ?Hit) void {
    if (cache.load(.acquire)) |c| c.remember(start, len, text, first_match, hit);
}

/// Freed with `gpa.free`.
pub fn formatAlloc(gpa: std.mem.Allocator, p: pattern.Pattern) error{OutOfMemory}![]u8 {
    const buf = try gpa.alloc(u8, if (p.len == 0) 0 else p.len * 3 - 1);
    return @constCast(format(p, buf));
}

/// Cut short if it doesn't fit.
pub fn format(p: pattern.Pattern, buf: []u8) []const u8 {
    var writer: std.Io.Writer = .fixed(buf);
    for (p, 0..) |b, i| {
        if (i != 0) writer.writeByte(' ') catch break;
        if (b) |v| writer.print("{X:0>2}", .{v}) catch break else writer.writeAll("??") catch break;
    }
    return writer.buffered();
}

test "format" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("48 ?? 0A C3", format(pattern.parse("48 ?? 0a C3"), &buf));
}

test "recorder replacement" {
    const Seen = struct {
        var count: u32 = 0;
        fn record(_: *const Record) void {
            count += 1;
        }
    };
    const previous = setRecorder(Seen.record);
    defer _ = setRecorder(previous);

    const r: Record = .{ .name = "n", .pattern = "90", .start = 0, .len = 1, .outcome = .not_found, .ns = 0 };
    report(&r);
    try std.testing.expectEqual(1, Seen.count);
    _ = setRecorder(null);
    report(&r);
    try std.testing.expectEqual(1, Seen.count);
}
