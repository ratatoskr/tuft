//! Makes the shortest unique signature at an address, or at code pointing to it via `Rip`.
//! Immediates and displacements are wildcards, since they change between builds.

const std = @import("std");

const tuft_arch = @import("tuft_arch");
const insn = tuft_arch.insn;
const Atomic = tuft_arch.atomic.Value;

const pattern = @import("pattern.zig");
const Sig = @import("Sig.zig");
const scans = @import("scans.zig");
const Memory = @import("Memory.zig");
const Module = @import("root.zig").Module;
const originals = @import("originals.zig");

const is64 = @sizeOf(usize) == 8;

pub const Options = struct {
    /// Shorter ones match by chance after an update.
    min_len: usize = 3,
    /// Longest it tries, since longer ones break sooner.
    max_len: usize = 256,
    /// Code pointing at it to try. Past that, the first ones found.
    max_refs: usize = 2000,
    cancel: ?*const Atomic(bool) = null,
    /// Places tried so far, for showing progress.
    progress: ?*Atomic(u32) = null,
};

pub const Found = struct {
    /// Null bytes are wildcards.
    pattern: []const ?u8,
    /// Where it matches.
    at: usize,
    /// Empty when it's at the address itself.
    resolve: []const Sig.Step,
    /// The address and the code pointing at it.
    places: usize,
};

/// Past this many matches a pattern's rescanned once it's longer, rather than kept.
const max_hits = 4096;

/// `code` is a module's code as it sits at `base`. Null if nothing unique fits.
pub fn make(arena: std.mem.Allocator, code: []const u8, base: usize, target: usize, options: Options) !?Found {
    const refs = try references(arena, code, base, target, options);
    var starts: std.ArrayList(usize) = .empty;
    if (target >= base and target - base < code.len) try starts.append(arena, target - base);
    for (refs) |r| try starts.append(arena, r - base);

    var counts: [256]u32 = @splat(0);
    for (code) |b| counts[b] +|= 1;
    var hits: std.ArrayList(usize) = .empty;
    var best: ?Found = null;
    const buf = try arena.alloc(?u8, options.max_len);
    for (starts.items) |start| {
        if (cancelled(options)) return error.Canceled;
        if (options.progress) |p| _ = p.fetchAdd(1, .monotonic);
        const limit = if (best) |b| b.pattern.len else options.max_len + 1;
        const len = try grow(arena, code, &counts, start, options, limit, buf, &hits) orelse continue;
        const direct = base + start == target;
        best = .{
            .pattern = try arena.dupe(?u8, buf[0..len]),
            .at = base + start,
            .resolve = if (direct) &.{} else &.{.rip},
            .places = starts.items.len,
        };
        // Nothing beats the shortest possible
        if (len == options.min_len) break;
    }
    return best;
}

/// Code that points at `target`, in order. Skips conditional branches, they're rarely wanted.
pub fn references(arena: std.mem.Allocator, code: []const u8, base: usize, target: usize, options: Options) ![]usize {
    var out: std.ArrayList(usize) = .empty;
    if (code.len < 5) return out.items;
    var q: usize = 1;
    while (q + 4 <= code.len) : (q += 1) {
        if (q % (1 << 16) == 0 and cancelled(options)) return error.Canceled;
        const field = std.mem.readInt(u32, code[q..][0..4], .little);
        const rel: usize = @bitCast(@as(isize, @as(i32, @bitCast(field))));
        const after = base + q + 4;
        // Immediates can sit after the field
        const hit = after +% rel == target or after + 1 +% rel == target or after + 2 +% rel == target or
            after + 4 +% rel == target or (!is64 and field == target);
        if (!hit) continue;
        const start = startOf(code, base, q, target) orelse continue;
        if (out.items.len > 0 and out.items[out.items.len - 1] == base + start) continue;
        try out.append(arena, base + start);
        if (out.items.len >= options.max_refs) break;
    }
    return out.items;
}

/// Where the instruction holding a 4-byte field at `q` starts, if it points at `target`.
fn startOf(code: []const u8, base: usize, q: usize, target: usize) ?usize {
    var back: usize = 1;
    while (back <= @min(q, insn.max_len - 4)) : (back += 1) {
        const s = q - back;
        if (!pointsAt(code, base, s, back, target)) continue;
        // Take its prefixes too, like REX.W. Branches have none, so a byte before one isn't theirs
        const flow = (insn.layoutOf(code[s..@min(code.len, s + insn.max_len)]) catch unreachable).flow;
        if (flow == .call or flow == .jump) return s;
        var start = s;
        if (is64 and start > 0 and code[start - 1] & 0xF0 == 0x40 and pointsAt(code, base, start - 1, q - start + 1, target)) start -= 1;
        while (start > 0 and isLegacyPrefix(code[start - 1]) and pointsAt(code, base, start - 1, q - start + 1, target)) start -= 1;
        return start;
    }
    return null;
}

fn pointsAt(code: []const u8, base: usize, s: usize, field_offset: usize, target: usize) bool {
    const bytes = code[s..@min(code.len, s + insn.max_len)];
    const layout = insn.layoutOf(bytes) catch return false;
    if (layout.flow == .conditional) return false;
    const has_field = for (layout.values()) |f| {
        if (f.offset == field_offset and f.len == 4) break true;
    } else false;
    if (!has_field) return false;
    const to = insn.toStaticAddressOf(bytes, base + s) catch return false;
    return to == target;
}

fn isLegacyPrefix(b: u8) bool {
    return switch (b) {
        0x66, 0x67, 0xF0, 0xF2, 0xF3, 0x2E, 0x36, 0x3E, 0x26, 0x64, 0x65 => true,
        else => false,
    };
}

/// Adds instructions from `start` till the pattern's unique. Null at `limit`, a function end or bad code.
fn grow(arena: std.mem.Allocator, code: []const u8, counts: *const [256]u32, start: usize, options: Options, limit: usize, buf: []?u8, hits: *std.ArrayList(usize)) !?usize {
    var n: usize = 0;
    var pos = start;
    var have_hits = false;
    while (true) {
        if (cancelled(options)) return error.Canceled;
        const bytes = code[pos..@min(code.len, pos + insn.max_len)];
        if (bytes.len == 0) return null;
        const layout = insn.layoutOf(bytes) catch return null;
        if (layout.flow == .trap or n + layout.len > buf.len) return null;
        for (bytes[0..layout.len], 0..) |b, i| buf[n + i] = b;
        for (layout.values()) |f| @memset(buf[n + f.offset ..][0..f.len], null);
        n += layout.len;
        pos += layout.len;

        var len = n;
        while (len > 0 and buf[len - 1] == null) len -= 1;
        if (len >= limit) return null;
        if (len >= options.min_len) {
            const p = buf[0..len];
            if (have_hits) {
                var kept: usize = 0;
                for (hits.items) |h| {
                    if (h + len <= code.len and pattern.matches(code[h..][0..len], p)) {
                        hits.items[kept] = h;
                        kept += 1;
                    }
                }
                hits.items.len = kept;
            } else have_hits = try collect(arena, code, counts, p, hits);
            if (have_hits and hits.items.len == 1) return len;
        }
        if (layout.flow == .ret) return null;
    }
}

/// False if there are too many to keep. Jumps on the rarest fixed byte, since code is full of E8 and 48.
fn collect(arena: std.mem.Allocator, code: []const u8, counts: *const [256]u32, p: pattern.Pattern, hits: *std.ArrayList(usize)) !bool {
    hits.clearRetainingCapacity();
    var anchor: usize = 0;
    for (p, 0..) |b, i| {
        const v = b orelse continue;
        if (p[anchor] == null or counts[v] < counts[p[anchor].?]) anchor = i;
    }
    const byte = p[anchor] orelse return false;
    var pos = anchor;
    while (std.mem.indexOfScalarPos(u8, code, pos, byte)) |hit| {
        pos = hit + 1;
        const i = hit - anchor;
        if (i + p.len > code.len) break;
        if (!pattern.matches(code[i..][0..p.len], p)) continue;
        if (hits.items.len == max_hits) return false;
        try hits.append(arena, i);
    }
    return true;
}

fn cancelled(options: Options) bool {
    const c = options.cancel orelse return false;
    return c.load(.monotonic);
}

pub const Made = struct {
    sig: Sig,
    found: Found,
};

/// For this process. Scans the module's `.text`, the copy from before any hooks if there is one.
pub fn forAddress(arena: std.mem.Allocator, target: usize, options: Options) !?Made {
    const module = try Module.containing(target);
    const text = try module.text();
    const code = originals.earliest(text.start, text.len) orelse
        Memory.local.direct(text.start, text.len) orelse return error.Unreadable;
    const found = try make(arena, code, text.start, target, options) orelse return null;

    var name_buf: [260]u8 = undefined;
    const main = module.base == Module.main().base;
    const name = if (main) null else try arena.dupe(u8, module.name(&name_buf) orelse return error.ModuleNotFound);
    return .{
        .sig = .{
            .pattern = try scans.formatAlloc(arena, found.pattern),
            .resolve = found.resolve,
            .module = name,
        },
        .found = found,
    };
}

pub const format = scans.format;
pub const formatAlloc = scans.formatAlloc;

const tests = struct {
    const testing = std.testing;

    // Operand values are wildcards, so only opcodes and registers tell these apart
    const base: usize = 0x1000_0000;

    fn code() [64]u8 {
        var c: [64]u8 = @splat(0xCC);
        const parts = [_][]const u8{
            // 0: mov eax, 1 ; ret  (common, matches below too)
            &.{ 0xB8, 0x01, 0x00, 0x00, 0x00, 0xC3 },
            // 6: call 0x20 ; ret
            &.{ 0xE8, 0x15, 0x00, 0x00, 0x00, 0xC3 },
            // 12: mov eax, 2 ; ret
            &.{ 0xB8, 0x02, 0x00, 0x00, 0x00, 0xC3 },
        };
        var at: usize = 0;
        for (parts) |p| {
            @memcpy(c[at..][0..p.len], p);
            at += p.len;
        }
        // 32: the target, shaped like the first, so only the call to it is unique
        @memcpy(c[32..][0..6], &[_]u8{ 0xB8, 0x05, 0x00, 0x00, 0x00, 0xC3 });
        return c;
    }

    test "finds the call to code that isn't unique" {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const c = code();
        const target = base + 32;
        const refs = try references(arena.allocator(), &c, base, target, .{});
        try testing.expectEqualSlices(usize, &.{base + 6}, refs);

        const found = (try make(arena.allocator(), &c, base, target, .{})).?;
        var buf: [64]u8 = undefined;
        try testing.expectEqualStrings("E8 ?? ?? ?? ?? C3", format(found.pattern, &buf));
        try testing.expectEqual(base + 6, found.at);
        try testing.expectEqualSlices(Sig.Step, &.{.rip}, found.resolve);
        try testing.expectEqual(2, found.places);
    }

    test "the address itself when it's unique" {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        var c = code();
        // xor eax, eax ; ret at the target
        @memcpy(c[32..][0..3], &[_]u8{ 0x31, 0xC0, 0xC3 });
        const found = (try make(arena.allocator(), &c, base, base + 32, .{ .min_len = 2 })).?;
        var buf: [64]u8 = undefined;
        try testing.expectEqualStrings("31 C0", format(found.pattern, &buf));
        try testing.expectEqual(0, found.resolve.len);
    }

    test "nothing unique" {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const c = code();
        // The first mov, nothing calls it and it matches the others
        try testing.expectEqual(null, try make(arena.allocator(), &c, base, base, .{}));
    }

    test "this process" {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const target = @intFromPtr(&uniqueCode);
        const made = (try forAddress(arena.allocator(), target, .{})).?;
        // Found where it says, and the sig gets back to it
        try testing.expectEqual(target, try made.sig.locate("made").unwrap());
    }

    /// Never called.
    fn uniqueCode() callconv(.naked) void {
        asm volatile (
            \\.intel_syntax noprefix
            \\xor eax, eax
            \\mov ecx, 0x51611A7E
            \\imul ecx, ecx, 0x2B
            \\ret
            \\.att_syntax prefix
        );
    }
};

test {
    _ = tests;
}
