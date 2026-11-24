//! Code found by a byte pattern, then maybe moved from, like `sig("48 8B 05 ??", Rip)`.

const Sig = @This();

const std = @import("std");

const root = @import("root.zig");
const Module = root.Module;
const Address = root.Address;
const originals = @import("originals.zig");
const AddressSource = originals.AddressSource;
const Sources = originals.Sources;

const log = std.log.scoped(.tuft_mem);

/// Has to match exactly once, unless `first_match`, then `resolve` runs from the match.
pattern: []const u8,
resolve: []const Step = &.{},
/// Null is the game's exe.
module: ?[]const u8 = null,
/// Empty is the whole image.
section: []const u8 = ".text",
/// Takes the first match even if there are more, `FirstMatch` in text.
first_match: bool = false,
/// Which copies it may be found in, `Sources(Live, Disk)` in text. Null leaves it to whoever looks.
sources: ?Sources = null,

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

/// `name` is what the scan gets logged as. Scans every time, keep the result. Tries every copy
/// the sig allows.
pub fn locate(self: Sig, name: []const u8) Address {
    return self.locateWith(name, .all);
}

/// Live memory first, then each copy `allowed` has, unless the sig says which itself. Stops at a
/// match, or at more than one, since that means it's too loose rather than hooked.
pub fn locateWith(self: Sig, name: []const u8, allowed: Sources) Address {
    const use = self.sources orelse allowed;
    var last: ?Address = null;
    for (AddressSource.order) |source| {
        if (!use.has(source)) continue;
        const match = self.findIn(name, source);
        const at = match.unwrap() catch |err| switch (err) {
            error.PatternNotUnique => return match,
            // A copy that isn't there says less than a miss somewhere else
            error.NoOriginalCopy => {
                if (last == null) last = match;
                continue;
            },
            else => {
                last = match;
                continue;
            },
        };
        return self.fromIn(name, at, source);
    }
    return last orelse .fail(error.PatternNotFound);
}

/// Just the match, before `resolve`, in live memory.
pub fn find(self: Sig, name: []const u8) Address {
    return self.findIn(name, .live);
}

/// Just the match, before `resolve`, in one copy. The copies only have code, so ones of the whole
/// image look in `.text` there.
pub fn findIn(self: Sig, name: []const u8, source: AddressSource) Address {
    const r = (if (source != .live and self.section.len == 0) self.codeRange() else self.range()) catch |err| return failed(name, err);
    var buf: [max_len]?u8 = undefined;
    const p = root.pattern.parseInto(self.pattern, &buf) catch |err| return failed(name, err);
    // The scan logs its own failures
    const copy = r.from(source);
    return if (self.first_match) copy.scanPatternFirst(name, p) else copy.scanPattern(name, p);
}

/// Where it's scanned.
pub fn range(self: Sig) !root.Range {
    const module = if (self.module) |m| try Module.find(m) else Module.main();
    return if (self.section.len == 0) module.range() else module.section(self.section);
}

fn codeRange(self: Sig) !root.Range {
    const module = if (self.module) |m| try Module.find(m) else Module.main();
    return module.text();
}

/// Runs `resolve` from a match in live memory.
pub fn from(self: Sig, name: []const u8, match: usize) Address {
    return self.fromIn(name, match, .live);
}

/// Runs `resolve` from a match, reading code from the copy it was found in.
pub fn fromIn(self: Sig, name: []const u8, match: usize, source: AddressSource) Address {
    var a: Address = Address.at(match).withSource(source);
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

/// As `tuft_mem.Location` text, like `sig("48 8B 05 ??", FirstMatch, Rip, Section(".text"))`.
pub fn format(self: Sig, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.print("sig(\"{s}\"", .{self.pattern});
    if (self.first_match) try w.writeAll(", FirstMatch");
    for (self.resolve) |step| switch (step) {
        .offset => |n| try w.print(", Offset({d})", .{n}),
        .rip => try w.writeAll(", Rip"),
        .follow => try w.writeAll(", Follow"),
        .rel32 => try w.writeAll(", Rel32"),
    };
    if (self.sources) |s| try w.print(", {f}", .{s});
    if (self.module) |m| try w.print(", Module(\"{s}\")", .{m});
    if (self.section.len > 0) try w.print(", Section(\"{s}\")", .{self.section});
    try w.writeByte(')');
}

test "as location text" {
    const s: Sig = .{ .pattern = "48 8B ??", .resolve = &.{ .rip, .{ .offset = -8 } }, .module = "kai.exe" };
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("sig(\"48 8B ??\", Rip, Offset(-8), Module(\"kai.exe\"), Section(\".text\"))", try std.fmt.bufPrint(&buf, "{f}", .{s}));
    const more: Sig = .{ .pattern = "90", .first_match = true, .sources = .{ .snapshot = false }, .section = "" };
    try std.testing.expectEqualStrings("sig(\"90\", FirstMatch, Sources(Live, Disk))", try std.fmt.bufPrint(&buf, "{f}", .{more}));
}

test "falls through the copies" {
    const saved = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = saved;
    const text = try Module.main().text();
    // A pattern from live code, put in a fake disk copy somewhere else in .text
    const Copies = struct {
        var buf: []u8 = &.{};
        var start: usize = 0;
        fn provide(s: usize, len: usize) ?[*]const u8 {
            if (s < start or s + len > start + buf.len) return null;
            return buf[s - start ..].ptr;
        }
    };
    const copy = try std.testing.allocator.dupe(u8, @as([*]const u8, @ptrFromInt(text.start))[0..text.len]);
    defer std.testing.allocator.free(copy);
    Copies.buf = copy;
    Copies.start = text.start;
    const marker = [_]u8{ 0xF1, 0xE2, 0xD3, 0xC4, 0xB5, 0xA6, 0x97, 0x88, 0x79, 0x6A, 0x5B, 0x4C, 0x3D };
    const at = copy.len / 3;
    @memcpy(copy[at..][0..marker.len], &marker);
    const previous = originals.setProvider(.disk, Copies.provide);
    defer _ = originals.setProvider(.disk, previous);

    const sig: Sig = .{ .pattern = "F1 E2 D3 C4 B5 A6 97 88 79 6A 5B 4C 3D" };
    const found = sig.locate("marker");
    try std.testing.expectEqual(text.start + at, try found.unwrap());
    try std.testing.expectEqual(.disk, found.source);
    try std.testing.expectError(error.PatternNotFound, sig.locateWith("marker", .live_only).unwrap());
    // The sig's own say wins
    const live_only: Sig = .{ .pattern = sig.pattern, .sources = .live_only };
    try std.testing.expectError(error.PatternNotFound, live_only.locate("marker").unwrap());

    // More than once stops there, unless it takes the first
    @memcpy(copy[at + 64 ..][0..marker.len], &marker);
    try std.testing.expectError(error.PatternNotUnique, sig.locate("marker").unwrap());
    const first: Sig = .{ .pattern = sig.pattern, .first_match = true };
    try std.testing.expectEqual(text.start + at, try first.locate("marker").unwrap());
}
