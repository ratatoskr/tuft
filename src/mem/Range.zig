//! A span of memory to signature scan.

const std = @import("std");

const sys = @import("tuft_sys");
const log = std.log.scoped(.tuft_mem);
const addr_digits = std.fmt.comptimePrint("{d}", .{@sizeOf(usize) * 2});

const address = @import("Address.zig");
const pattern = @import("pattern.zig");
const scans = @import("scans.zig");
const originals = @import("originals.zig");
const Memory = @import("Memory.zig");
const Pattern = pattern.Pattern;
const AddressSource = originals.AddressSource;

/// Chunk size when memory can't be scanned in place.
const chunk_len = 16 * 1024;
const page_len = 4096;

pub fn Generic(comptime Hooks: type) type {
    return struct {
        const Range = @This();
        const Address = address.Generic(Hooks);

        start: usize,
        len: usize,
        memory: Memory = .local,
        /// Which copy gets scanned, see `from`.
        source: AddressSource = .live,

        pub fn fromSlice(slice: []const u8) Range {
            return .{ .start = @intFromPtr(slice.ptr), .len = slice.len };
        }

        pub fn end(self: Range) usize {
            return self.start + self.len;
        }

        pub fn contains(self: Range, addr: usize) bool {
            return addr >= self.start and addr - self.start < self.len;
        }

        /// Scans another copy of the code, so code that's hooked now is still found. What's found
        /// is where it is in live memory. Local memory only.
        pub fn from(self: Range, source: AddressSource) Range {
            var copy = self;
            copy.source = source;
            return copy;
        }

        /// The snapshot from before most hooks.
        pub fn original(self: Range) Range {
            return self.from(.snapshot);
        }

        /// Null means read in chunks.
        fn whole(self: Range) !?[]const u8 {
            if (self.source != .live) {
                if (!self.memory.isLocal()) return error.NoOriginalCopy;
                return originals.find(self.source, self.start, self.len) orelse error.NoOriginalCopy;
            }
            return self.memory.direct(self.start, self.len);
        }

        /// A second match is `error.PatternNotUnique`, loose signatures can drift after updates.
        pub fn scan(self: Range, name: []const u8, comptime signature: []const u8) Address {
            return self.scanPattern(name, pattern.parse(signature));
        }

        /// Takes the first match even if there are more.
        pub fn scanFirst(self: Range, name: []const u8, comptime signature: []const u8) Address {
            return self.run(name, pattern.parse(signature), false);
        }

        pub fn scanPattern(self: Range, name: []const u8, p: Pattern) Address {
            return self.run(name, p, true);
        }

        /// Takes the first match even if there are more.
        pub fn scanPatternFirst(self: Range, name: []const u8, p: Pattern) Address {
            return self.run(name, p, false);
        }

        /// Returns how many. Not reported.
        pub fn findAll(self: Range, p: Pattern, out: []usize) !usize {
            const hay = try self.whole();
            var n: usize = 0;
            var next: usize = 0;
            while (n < out.len) {
                const hit = try self.find(hay, p, next) orelse break;
                out[n] = hit;
                n += 1;
                next = hit - self.start + 1;
            }
            return n;
        }

        fn run(self: Range, name: []const u8, p: Pattern, unique: bool) Address {
            const started = sys.clock.nanos();
            var outcome: scans.Outcome = .not_found;
            var found: usize = 0;
            self.search(p, unique, &outcome, &found) catch |err| {
                log.warn("{s}: {t}", .{ name, err });
                return self.result(err);
            };
            var text: [768]u8 = undefined;
            scans.report(&.{
                .name = name,
                .pattern = scans.format(p, &text),
                .start = self.start,
                .len = self.len,
                .source = self.source,
                .first_match = !unique,
                .outcome = outcome,
                .address = found,
                .ns = sys.clock.nanos() -| started,
            });
            return switch (outcome) {
                .found => blk: {
                    log.info("{s}: 0x{x:0>" ++ addr_digits ++ "}", .{ name, found });
                    break :blk self.result(found);
                },
                .not_found => blk: {
                    log.warn("{s}: signature not found", .{name});
                    break :blk self.result(error.PatternNotFound);
                },
                .not_unique => blk: {
                    log.warn("{s}: signature matches more than once", .{name});
                    break :blk self.result(error.PatternNotUnique);
                },
            };
        }

        fn result(self: Range, value: anyerror!usize) Address {
            return Address.fromMemory(self.memory, value).withSource(self.source);
        }

        fn search(self: Range, p: Pattern, unique: bool, outcome: *scans.Outcome, found: *usize) !void {
            const hay = try self.whole();
            const first = try self.find(hay, p, 0) orelse return;
            found.* = first;
            outcome.* = if (unique and try self.find(hay, p, first - self.start + 1) != null) .not_unique else .found;
        }

        fn find(self: Range, hay: ?[]const u8, p: Pattern, skip: usize) !?usize {
            if (hay) |h| return if (pattern.find(h, p, skip)) |i| self.start + i else null;
            if (p.len == 0) return null;
            if (p.len > chunk_len) return error.PatternTooLong;
            var buf: [chunk_len]u8 = undefined;
            var at = skip;
            var tried = false;
            var any = false;
            while (at < self.len and self.len - at >= p.len) {
                const n = @min(buf.len, self.len - at);
                tried = true;
                if (self.memory.read(self.start + at, buf[0..n])) |_| {
                    any = true;
                    if (pattern.find(buf[0..n], p, 0)) |i| return self.start + at + i;
                } else |_| {
                    if (self.findInPages(&buf, at, n, p, &any)) |hit| return hit;
                }
                if (at + n == self.len) break;
                // Overlap chunks so a match across the boundary shows up in the next one
                at += n - (p.len - 1);
            }
            if (tried and !any) return error.Unreadable;
            return null;
        }

        /// A chunk that didn't read whole, a page at a time. Modules can have pages that can't be
        /// read, and a match can't be in one anyway.
        fn findInPages(self: Range, buf: *[chunk_len]u8, at: usize, n: usize, p: Pattern, any: *bool) ?usize {
            var readable: ?usize = null;
            var off: usize = 0;
            while (off < n) {
                const addr = self.start + at + off;
                const piece = @min(n - off, page_len - addr % page_len);
                const ok = if (self.memory.read(addr, buf[off..][0..piece])) |_| true else |_| false;
                if (ok) {
                    any.* = true;
                    if (readable == null) readable = off;
                }
                if (!ok or off + piece == n) if (readable) |s| {
                    const e = if (ok) off + piece else off;
                    if (pattern.find(buf[s..e], p, 0)) |i| return self.start + at + s + i;
                    readable = null;
                };
                off += piece;
            }
            return null;
        }
    };
}

test "chunked scans" {
    const saved = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = saved;
    const Remote = struct {
        // Not our memory, only readable through `read`
        const base: usize = 0x5000_0000;
        var bytes: [chunk_len * 2 + 100]u8 = @splat(0);

        fn read(_: ?*anyopaque, at: usize, out: []u8) Memory.Error!void {
            if (at < base or at + out.len > base + bytes.len) return error.Unreadable;
            @memcpy(out, bytes[at - base ..][0..out.len]);
        }
    };
    // One across the end of the first chunk, one in the last bytes
    const straddle = chunk_len - 2;
    @memcpy(Remote.bytes[straddle..][0..5], &[_]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 0x42 });
    @memcpy(Remote.bytes[Remote.bytes.len - 4 ..], &[_]u8{ 0xCA, 0xFE, 0xBA, 0xBE });

    const memory: Memory = .{ .vtable = &.{ .read = Remote.read } };
    const Range = Generic(address.NoHooks);
    const range: Range = .{ .start = Remote.base, .len = Remote.bytes.len, .memory = memory };
    const found = range.scan("straddle", "DE AD ?? EF 42");
    try std.testing.expectEqual(Remote.base + straddle, try found.unwrap());
    // The found address reads the same memory
    try std.testing.expectEqual(0xEFBEADDE, try found.load(u32));
    try std.testing.expectEqual(Remote.base + Remote.bytes.len - 4, try range.scan("end", "CA FE BA BE").unwrap());
    try std.testing.expectError(error.PatternNotFound, range.scan("none", "11 22 33").unwrap());

    // A page that can't be read is skipped, so the rest is still searched
    const past: Range = .{ .start = Remote.base, .len = Remote.bytes.len + 1, .memory = memory };
    try std.testing.expectEqual(Remote.base + straddle, try past.scan("past", "DE AD ?? EF 42").unwrap());
    try std.testing.expectError(error.PatternNotFound, past.scan("past", "11 22 33").unwrap());
    // Nothing readable at all still says so
    const gone: Range = .{ .start = Remote.base - 0x10000, .len = 0x100, .memory = memory };
    try std.testing.expectError(error.Unreadable, gone.scan("gone", "CA FE").unwrap());
}

test "scan matching" {
    const saved = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = saved;
    const mem = [_]u8{ 0xD3, 0xEF, 0x44, 0x98, 0x99, 0x11, 0xFF, 0x0D, 0xC0, 0xEE, 0x36, 0xEE, 0x99, 0x22, 0xFF, 0x21 };
    const Range = Generic(address.NoHooks);
    const range = Range.fromSlice(&mem);
    const base = range.start;

    try std.testing.expectEqual(base + 8, try range.scan("a", "C0 EE 36 EE").unwrap());
    try std.testing.expectEqual(base, try range.scan("b", "D3 EF").unwrap());
    try std.testing.expectEqual(base + 14, try range.scan("c", "FF 21").unwrap());
    try std.testing.expectEqual(base + 2, try range.scan("d", "?? 98").unwrap());
    try std.testing.expectError(error.PatternNotFound, range.scan("e", "FF FF FF").unwrap());
    try std.testing.expectError(error.PatternNotUnique, range.scan("f", "99 ?? FF").unwrap());
    try std.testing.expectEqual(base + 4, try range.scanFirst("g", "99 ?? FF").unwrap());
    try std.testing.expectError(error.PatternNotFound, Range.fromSlice(mem[0..2]).scan("h", "D3 EF 44").unwrap());

    var all: [4]usize = undefined;
    const n = try range.findAll(pattern.parse("99 ?? FF"), &all);
    try std.testing.expectEqualSlices(usize, &.{ base + 4, base + 12 }, all[0..n]);
}

test "original scans" {
    const saved = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = saved;
    const Copies = struct {
        // Live bytes got "hooked" after the copy was taken
        var live = [_]u8{ 0xE9, 0x00, 0x00, 0x00, 0x00, 0xC3 };
        const before = [_]u8{ 0x48, 0x89, 0x5C, 0x24, 0x08, 0xC3 };

        fn provide(start: usize, len: usize) ?[*]const u8 {
            const live_start = @intFromPtr(&live);
            if (start < live_start or start + len > live_start + live.len) return null;
            return before[start - live_start ..].ptr;
        }
    };
    const Range = Generic(address.NoHooks);
    const range = Range.fromSlice(&Copies.live);
    try std.testing.expectError(error.NoOriginalCopy, range.original().scan("prologue", "48 89 5C 24").unwrap());

    const previous = originals.setProvider(.snapshot, Copies.provide);
    defer _ = originals.setProvider(.snapshot, previous);
    try std.testing.expectError(error.PatternNotFound, range.scan("prologue", "48 89 5C 24").unwrap());
    const found = range.original().scan("prologue", "48 89 5C 24");
    try std.testing.expectEqual(range.start, try found.unwrap());
    try std.testing.expectEqual(.snapshot, found.source);
    // Steps read the copy it was found in, not the hooked live code
    try std.testing.expectEqual(range.start +% 5 +% 0x08245C89, try found.offset(1).rel32().unwrap());
}

test "scans are reported" {
    const saved = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = saved;
    const Seen = struct {
        var last: scans.Outcome = .found;
        var found: usize = 0;
        var name_buf: [16]u8 = undefined;
        var name_len: usize = 0;
        var pattern_buf: [32]u8 = undefined;
        var pattern_len: usize = 0;

        fn record(r: *const scans.Record) void {
            last = r.outcome;
            found = r.address;
            @memcpy(name_buf[0..r.name.len], r.name);
            name_len = r.name.len;
            @memcpy(pattern_buf[0..r.pattern.len], r.pattern);
            pattern_len = r.pattern.len;
        }
    };
    const previous = scans.setRecorder(Seen.record);
    defer _ = scans.setRecorder(previous);

    const mem = [_]u8{ 0x90, 0xC3, 0x90, 0xC3 };
    const range = Generic(address.NoHooks).fromSlice(&mem);
    _ = range.scan("ret", "C3 90");
    try std.testing.expectEqual(.found, Seen.last);
    try std.testing.expectEqual(range.start + 1, Seen.found);
    try std.testing.expectEqualStrings("ret", Seen.name_buf[0..Seen.name_len]);
    try std.testing.expectEqualStrings("C3 90", Seen.pattern_buf[0..Seen.pattern_len]);
    _ = range.scan("twice", "90 C3");
    try std.testing.expectEqual(.not_unique, Seen.last);
}
