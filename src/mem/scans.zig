//! Signature scan reporting, one recorder per DLL.

const std = @import("std");

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
