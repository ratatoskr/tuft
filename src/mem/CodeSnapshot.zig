//! Copies of a module's code sections from before any hooks.

const CodeSnapshot = @This();

const std = @import("std");

const root = @import("root.zig");
const originals = @import("originals.zig");

const log = std.log.scoped(.tuft_mem);

pub const Section = struct {
    start: usize,
    copy: []u8,
    name_buf: [8]u8,
    name_len: u8,

    pub fn name(self: *const Section) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};

allocator: std.mem.Allocator,
sections: std.ArrayList(Section) = .empty,
previous: ?originals.Provider = null,
installed: bool = false,

/// So a plain function can answer `originals`.
var current: std.atomic.Value(?*const CodeSnapshot) = .init(null);

/// Sections that can't be read or allocated get skipped and logged.
pub fn take(allocator: std.mem.Allocator, base: usize) !CodeSnapshot {
    var self: CodeSnapshot = .{ .allocator = allocator };
    errdefer self.deinit();
    var it = try (root.Module{ .base = base }).sections();
    while (it.next()) |s| {
        if (!s.executable or s.len == 0) continue;
        if (!root.isReadable(s.start, s.len)) {
            log.warn("Not copying section {s}: it isn't readable", .{s.name()});
            continue;
        }
        const copy = allocator.alloc(u8, s.len) catch {
            log.warn("Not enough memory to copy section {s}", .{s.name()});
            continue;
        };
        @memcpy(copy, @as([*]const u8, @ptrFromInt(s.start))[0..s.len]);
        self.sections.append(allocator, .{ .start = s.start, .copy = copy, .name_buf = s.name_buf, .name_len = s.name_len }) catch |err| {
            allocator.free(copy);
            return err;
        };
    }
    return self;
}

pub fn deinit(self: *CodeSnapshot) void {
    self.uninstall();
    for (self.sections.items) |s| self.allocator.free(s.copy);
    self.sections.deinit(self.allocator);
    self.sections = .empty;
}

pub fn size(self: *const CodeSnapshot) usize {
    var total: usize = 0;
    for (self.sections.items) |s| total += s.copy.len;
    return total;
}

/// Only if one section covers all of it.
pub fn find(self: *const CodeSnapshot, start: usize, len: usize) ?[*]const u8 {
    for (self.sections.items) |s| {
        if (start >= s.start and start - s.start <= s.copy.len and len <= s.copy.len - (start - s.start)) {
            return s.copy[start - s.start ..].ptr;
        }
    }
    return null;
}

/// Don't move it until `uninstall`.
pub fn install(self: *CodeSnapshot) void {
    if (self.installed) return;
    current.store(self, .release);
    self.previous = originals.setProvider(provide);
    self.installed = true;
}

pub fn uninstall(self: *CodeSnapshot) void {
    if (!self.installed) return;
    _ = originals.setProvider(self.previous);
    _ = current.cmpxchgStrong(self, null, .acq_rel, .acquire);
    self.installed = false;
}

fn provide(start: usize, len: usize) ?[*]const u8 {
    const snapshot = current.load(.acquire) orelse return null;
    return snapshot.find(start, len);
}

test "original scans read the copy" {
    const saved = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = saved;

    const Range = @import("Range.zig").Generic(@import("Address.zig").NoHooks);
    const text_section = try root.Module.main().text();

    var snapshot = try take(std.testing.allocator, root.Module.main().base);
    defer snapshot.deinit();
    try std.testing.expect(snapshot.sections.items.len > 0);
    try std.testing.expect(snapshot.size() >= text_section.len);
    try std.testing.expect(snapshot.find(text_section.start, text_section.len) != null);
    try std.testing.expectEqual(null, snapshot.find(text_section.start, text_section.len + 1));

    snapshot.install();
    // Fake a hook by changing the copy, since the code is read-only
    const copy = snapshot.sections.items[0];
    const offset = copy.copy.len / 2;
    const marker = [_]u8{ 0xF1, 0xE2, 0xD3, 0xC4, 0xB5, 0xA6, 0x97, 0x88, 0x79, 0x6A, 0x5B, 0x4C };
    @memcpy(copy.copy[offset..][0..marker.len], &marker);
    const range: Range = .{ .start = copy.start, .len = copy.copy.len };
    const signature = "F1 E2 D3 C4 B5 A6 97 88 79 6A 5B 4C";
    try std.testing.expectEqual(copy.start + offset, try range.original().scan("marker", signature).unwrap());
    try std.testing.expectError(error.PatternNotFound, range.scan("marker", signature).unwrap());

    snapshot.uninstall();
    try std.testing.expectError(error.NoOriginalCopy, range.original().scan("marker", signature).unwrap());
}
