//! A module's code as its file on disk has it, laid out where it's loaded, with its relocations
//! done for where it is. For finding code that was hooked before any snapshot was taken. Reading the
//! file is up to the caller, so this does no I/O.

const DiskImage = @This();

const std = @import("std");

const originals = @import("originals.zig");
const CodeSnapshot = @import("CodeSnapshot.zig");

const log = std.log.scoped(.tuft_mem);

const Section = CodeSnapshot.Section;

allocator: std.mem.Allocator,
sections: std.ArrayList(Section) = .empty,
previous: ?originals.Provider = null,
installed: bool = false,

var current: std.atomic.Value(?*const DiskImage) = .init(null);

pub const Error = error{ NotAnImage, Truncated, OutOfMemory };

const scn_code: u32 = 0x20;
const scn_execute: u32 = 0x2000_0000;
const reloc_dir = 5;
const rel_highlow = 3;
const rel_dir64 = 10;

/// `file` is the module's file, loaded at `base`. Only its code sections are kept, the same ones
/// `CodeSnapshot` copies.
pub fn fromFile(allocator: std.mem.Allocator, file: []const u8, base: usize) Error!DiskImage {
    var self: DiskImage = .{ .allocator = allocator };
    errdefer self.deinit();
    const pe = try Headers.read(file);
    for (0..pe.section_count) |i| {
        const h = try pe.section(file, i);
        if (h.characteristics & (scn_code | scn_execute) == 0 or h.virtual_size == 0) continue;
        const copy = try allocator.alloc(u8, h.virtual_size);
        errdefer allocator.free(copy);
        @memset(copy, 0);
        const raw_len = @min(h.raw_size, h.virtual_size);
        if (h.raw_offset > file.len or raw_len > file.len - h.raw_offset) return error.Truncated;
        @memcpy(copy[0..raw_len], file[h.raw_offset..][0..raw_len]);
        var s: Section = .{ .start = base + h.rva, .copy = copy, .name_buf = h.name, .name_len = 0 };
        s.name_len = @intCast(std.mem.indexOfScalar(u8, &h.name, 0) orelse h.name.len);
        try self.sections.append(allocator, s);
    }
    self.relocate(file, pe, base);
    return self;
}

pub fn deinit(self: *DiskImage) void {
    self.uninstall();
    for (self.sections.items) |s| self.allocator.free(s.copy);
    self.sections.deinit(self.allocator);
    self.sections = .empty;
}

pub fn size(self: *const DiskImage) usize {
    var total: usize = 0;
    for (self.sections.items) |s| total += s.copy.len;
    return total;
}

/// Only if one section covers all of it.
pub fn find(self: *const DiskImage, start: usize, len: usize) ?[*]const u8 {
    for (self.sections.items) |s| {
        if (start >= s.start and start - s.start <= s.copy.len and len <= s.copy.len - (start - s.start)) {
            return s.copy[start - s.start ..].ptr;
        }
    }
    return null;
}

/// Don't move it until `uninstall`.
pub fn install(self: *DiskImage) void {
    if (self.installed) return;
    current.store(self, .release);
    self.previous = originals.setProvider(.disk, provide);
    self.installed = true;
}

pub fn uninstall(self: *DiskImage) void {
    if (!self.installed) return;
    _ = originals.setProvider(.disk, self.previous);
    _ = current.cmpxchgStrong(self, null, .acq_rel, .acquire);
    self.installed = false;
}

fn provide(start: usize, len: usize) ?[*]const u8 {
    const image = current.load(.acquire) orelse return null;
    return image.find(start, len);
}

/// Absolute addresses in the code were written for the image's preferred base, so they move by
/// however far it is from where it loaded.
fn relocate(self: *DiskImage, file: []const u8, pe: Headers, base: usize) void {
    const delta = base -% pe.image_base;
    if (delta == 0) return;
    const dir = pe.directory(file, reloc_dir) orelse return;
    var at = pe.fileOffset(file, dir.rva) orelse return;
    const end = @min(file.len, at + dir.size);
    while (at + 8 <= end) {
        const page = std.mem.readInt(u32, file[at..][0..4], .little);
        const block = std.mem.readInt(u32, file[at + 4 ..][0..4], .little);
        if (block < 8 or at + block > end) break;
        var e = at + 8;
        while (e + 2 <= at + block) : (e += 2) {
            const entry = std.mem.readInt(u16, file[e..][0..2], .little);
            const kind = entry >> 12;
            const where = base + page + (entry & 0xFFF);
            switch (kind) {
                rel_dir64 => self.add(u64, where, delta),
                rel_highlow => self.add(u32, where, delta),
                else => {},
            }
        }
        at += block;
    }
}

fn add(self: *DiskImage, comptime T: type, where: usize, delta: usize) void {
    const ptr = self.find(where, @sizeOf(T)) orelse return;
    const bytes: *[@sizeOf(T)]u8 = @constCast(ptr[0..@sizeOf(T)]);
    const old = std.mem.readInt(T, bytes, .little);
    std.mem.writeInt(T, bytes, old +% @as(T, @truncate(delta)), .little);
}

const Headers = struct {
    section_count: usize,
    sections_at: usize,
    image_base: usize,
    dirs_at: usize,
    dir_count: usize,

    const SectionHeader = struct {
        name: [8]u8,
        virtual_size: u32,
        rva: u32,
        raw_size: u32,
        raw_offset: u32,
        characteristics: u32,
    };

    fn read(file: []const u8) Error!Headers {
        if (file.len < 0x40 or !std.mem.eql(u8, file[0..2], "MZ")) return error.NotAnImage;
        const nt = std.mem.readInt(u32, file[0x3C..][0..4], .little);
        if (nt > file.len or file.len - nt < 24 or !std.mem.eql(u8, file[nt..][0..4], "PE\x00\x00")) return error.NotAnImage;
        const count = std.mem.readInt(u16, file[nt + 6 ..][0..2], .little);
        const opt_size = std.mem.readInt(u16, file[nt + 20 ..][0..2], .little);
        const opt = nt + 24;
        if (opt + opt_size > file.len) return error.Truncated;
        const magic = std.mem.readInt(u16, file[opt..][0..2], .little);
        const pe64 = switch (magic) {
            0x20B => true,
            0x10B => false,
            else => return error.NotAnImage,
        };
        const image_base: usize = if (pe64)
            @truncate(std.mem.readInt(u64, file[opt + 24 ..][0..8], .little))
        else
            std.mem.readInt(u32, file[opt + 28 ..][0..4], .little);
        const dirs_field: usize = if (pe64) 108 else 92;
        const dir_count = std.mem.readInt(u32, file[opt + dirs_field ..][0..4], .little);
        return .{
            .section_count = count,
            .sections_at = opt + opt_size,
            .image_base = image_base,
            .dirs_at = opt + dirs_field + 4,
            .dir_count = dir_count,
        };
    }

    fn section(self: Headers, file: []const u8, i: usize) Error!SectionHeader {
        const at = self.sections_at + i * 40;
        if (at + 40 > file.len) return error.Truncated;
        const h = file[at..][0..40];
        return .{
            .name = h[0..8].*,
            .virtual_size = std.mem.readInt(u32, h[8..12], .little),
            .rva = std.mem.readInt(u32, h[12..16], .little),
            .raw_size = std.mem.readInt(u32, h[16..20], .little),
            .raw_offset = std.mem.readInt(u32, h[20..24], .little),
            .characteristics = std.mem.readInt(u32, h[36..40], .little),
        };
    }

    fn directory(self: Headers, file: []const u8, index: usize) ?struct { rva: u32, size: u32 } {
        if (index >= self.dir_count) return null;
        const at = self.dirs_at + index * 8;
        if (at + 8 > file.len) return null;
        const rva = std.mem.readInt(u32, file[at..][0..4], .little);
        const len = std.mem.readInt(u32, file[at + 4 ..][0..4], .little);
        return if (rva == 0 or len == 0) null else .{ .rva = rva, .size = len };
    }

    /// Where an RVA's bytes are in the file.
    fn fileOffset(self: Headers, file: []const u8, rva: u32) ?usize {
        for (0..self.section_count) |i| {
            const h = self.section(file, i) catch return null;
            const len = @max(h.virtual_size, h.raw_size);
            if (rva >= h.rva and rva - h.rva < len) {
                const off = h.raw_offset + (rva - h.rva);
                return if (off < file.len) off else null;
            }
        }
        return null;
    }
};

test "laid out like it's loaded" {
    const saved = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = saved;
    const root = @import("root.zig");
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const main = root.Module.main();
    var path_buf: [1024]u8 = undefined;
    const path = main.path(&path_buf).?;
    const file = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
    defer gpa.free(file);

    var image = try fromFile(gpa, file, main.base);
    defer image.deinit();
    const text = try main.text();
    const copy = image.find(text.start, text.len).?[0..text.len];
    // Nothing in a test hooks its own code, so with relocations done it's the same as live
    const live = @as([*]const u8, @ptrFromInt(text.start))[0..text.len];
    var differ: usize = 0;
    for (copy, live) |a, b| differ += @intFromBool(a != b);
    try std.testing.expectEqual(0, differ);

    image.install();
    defer image.uninstall();
    const Range = @import("Range.zig").Generic(@import("Address.zig").NoHooks);
    const range: Range = .{ .start = text.start, .len = text.len };
    try std.testing.expect(originals.find(.disk, text.start, 16) != null);
    try std.testing.expectEqual(text.start, try range.from(.disk).scanPatternFirst("start", root.pattern.parse("??")).unwrap());

    try std.testing.expectError(error.NotAnImage, fromFile(gpa, "not a PE file at all, nope, really not at all, no MZ in front", main.base));
}
