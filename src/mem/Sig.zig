//! Code found by a byte pattern, then maybe moved from, like `sig("48 8B 05 ??", Rip)`.

const Sig = @This();

const std = @import("std");

const root = @import("root.zig");
const Module = root.Module;
const Address = root.Address;

const log = std.log.scoped(.tuft_mem);

/// Has to match exactly once, then `resolve` runs from the match.
pattern: []const u8,
resolve: []const Step = &.{},
/// Null is the game's exe.
module: ?[]const u8 = null,
/// Empty is the whole image.
section: []const u8 = ".text",

pub const max_len = 256;

/// In ZON it's `.rip`, `.follow`, `.rel32` or `.{ .offset = n }`.
pub const Step = union(enum) {
    offset: isize,
    /// Where the instruction here points, see `tuft_mem.Address.rip`.
    rip,
    /// Through a jmp or call here, for thunks.
    follow,
    /// Where the 32-bit relative offset here points, see `tuft_mem.Address.rel32`.
    rel32,
};

/// `name` is what the scan gets logged as. Scans every time, keep the result.
pub fn locate(self: Sig, name: []const u8) Address {
    const match = self.find(name);
    if (match.orNull() == null) return match;
    return self.from(name, match.orNull().?);
}

/// Just the match, before `resolve`.
pub fn find(self: Sig, name: []const u8) Address {
    const r = self.range() catch |err| return failed(name, err);
    var buf: [max_len]?u8 = undefined;
    const p = root.pattern.parseInto(self.pattern, &buf) catch |err| return failed(name, err);
    // The scan logs its own failures
    return r.scanPattern(name, p);
}

/// Where it's scanned.
pub fn range(self: Sig) !root.Range {
    const module = if (self.module) |m| try Module.find(m) else Module.main();
    return if (self.section.len == 0) module.range() else module.section(self.section);
}

/// Runs `resolve` from a match.
pub fn from(self: Sig, name: []const u8, match: usize) Address {
    var a: Address = .at(match);
    for (self.resolve) |step| a = switch (step) {
        .offset => |n| a.offset(n),
        .rip => a.rip(),
        .follow => a.follow(),
        .rel32 => a.rel32(),
    };
    _ = a.unwrap() catch |err| return failed(name, err);
    return a;
}

fn failed(name: []const u8, err: anyerror) Address {
    log.warn("{s}: {t}", .{ name, err });
    return .fail(err);
}

/// As `tuft_mem.Location` text, like `sig("48 8B 05 ??", Rip, Section(".text"))`.
pub fn format(self: Sig, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.print("sig(\"{s}\"", .{self.pattern});
    for (self.resolve) |step| switch (step) {
        .offset => |n| try w.print(", Offset({d})", .{n}),
        .rip => try w.writeAll(", Rip"),
        .follow => try w.writeAll(", Follow"),
        .rel32 => try w.writeAll(", Rel32"),
    };
    if (self.module) |m| try w.print(", Module(\"{s}\")", .{m});
    if (self.section.len > 0) try w.print(", Section(\"{s}\")", .{self.section});
    try w.writeByte(')');
}

test "as location text" {
    const s: Sig = .{ .pattern = "48 8B ??", .resolve = &.{ .rip, .{ .offset = -8 } }, .module = "kai.exe" };
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("sig(\"48 8B ??\", Rip, Offset(-8), Module(\"kai.exe\"), Section(\".text\"))", try std.fmt.bufPrint(&buf, "{f}", .{s}));
}
