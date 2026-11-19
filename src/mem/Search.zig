//! Cheat Engine style memory search.
//! Not thread-safe, but another thread can read `progress` and call `cancel`.

const Search = @This();

const std = @import("std");

const atomic = @import("tuft_arch").atomic;
const sys = @import("tuft_sys");

const Memory = @import("Memory.zig");
const pattern = @import("pattern.zig");
const values = @import("values.zig");

pub const Kind = values.Kind;

pub const Where = union(enum) {
    /// Has to be walkable.
    all: struct {
        writable_only: bool = false,
    },
    range: struct { start: usize, len: usize },
};

pub const Options = struct {
    /// Faster, with far fewer junk hits.
    aligned: bool = true,
    limit: usize = 1_000_000,
};

pub const Compare = enum {
    exact,
    changed,
    unchanged,
    increased,
    decreased,

    pub fn label(c: Compare) [:0]const u8 {
        return switch (c) {
            .exact => "Exact value",
            .changed => "Changed",
            .unchanged => "Unchanged",
            .increased => "Increased",
            .decreased => "Decreased",
        };
    }

    pub fn takesValue(c: Compare) bool {
        return c == .exact;
    }
};

pub const Error = values.Error || std.mem.Allocator.Error || error{
    CannotWalk,
    NothingSearched,
    NotComparable,
    LengthChanged,
    /// The hits are whatever it had so far.
    Cancelled,
};

/// Bytes, or hits when searching again. Any thread can read it.
pub const Progress = struct {
    // tuft_arch's, which has 64-bit atomics on x86 too
    done: atomic.Value(u64) = .init(0),
    total: atomic.Value(u64) = .init(0),

    /// 0 to 1.
    pub fn fraction(self: *const Progress) f32 {
        const total = self.total.load(.monotonic);
        if (total == 0) return 0;
        return @floatCast(@as(f64, @floatFromInt(self.done.load(.monotonic))) / @as(f64, @floatFromInt(total)));
    }
};

const block_len = 16 * 1024;

/// Fixed-size blocks so growing never copies, the arena can't free.
const Block = struct {
    addresses: [block_len]usize,
    values: []u8,
};

memory: Memory,
arena: std.heap.ArenaAllocator,
blocks: std.ArrayList(*Block) = .empty,
count: usize = 0,
/// More than `Options.limit` were found, the rest got dropped.
truncated: bool = false,
kind: ?Kind = null,
value_len: usize = 0,
progress: Progress = .{},
cancelled: std.atomic.Value(bool) = .init(false),

pub fn init(memory: Memory) Search {
    return .{ .memory = memory, .arena = .init(std.heap.page_allocator) };
}

pub fn deinit(self: *Search) void {
    self.arena.deinit();
}

pub fn reset(self: *Search) void {
    _ = self.arena.reset(.free_all);
    self.blocks = .empty;
    self.count = 0;
    self.truncated = false;
    self.kind = null;
    self.value_len = 0;
}

/// From another thread. The search returns `error.Cancelled`.
pub fn cancel(self: *Search) void {
    self.cancelled.store(true, .monotonic);
}

/// In address order.
pub fn address(self: *const Search, i: usize) usize {
    return self.blocks.items[i / block_len].addresses[i % block_len];
}

pub fn previous(self: *const Search, i: usize) []const u8 {
    const block = self.blocks.items[i / block_len];
    return block.values[(i % block_len) * self.value_len ..][0..self.value_len];
}

/// Starts a new search, replacing the old one.
pub fn first(self: *Search, where: Where, kind: Kind, text: []const u8, options: Options) Error!void {
    var buf: [values.max_len]?u8 = undefined;
    const p = try values.parse(kind, text, &buf);
    self.reset();
    self.kind = kind;
    self.value_len = p.len;
    self.cancelled.store(false, .monotonic);
    self.progress.done.store(0, .monotonic);

    const alignment = if (options.aligned) kind.alignment() else 1;
    // Snapshot regions now so our own allocations aren't searched
    var list: std.ArrayList(Memory.Region) = .empty;
    const walked = self.memory.canWalk();
    switch (where) {
        .all => |all| {
            if (!walked) return error.CannotWalk;
            var it = self.regions(0, std.math.maxInt(usize), all.writable_only);
            while (it.next()) |r| try list.append(self.arena.allocator(), r);
        },
        .range => |r| if (walked) {
            var it = self.regions(r.start, r.start +| r.len, false);
            while (it.next()) |region| try list.append(self.arena.allocator(), region);
        } else {
            try list.append(self.arena.allocator(), .{ .start = r.start, .len = r.len, .writable = false, .executable = false });
        },
    }
    // Skip this thread's stack, its locals hold the value
    if (self.memory.isLocal()) try cutOut(&list, self.arena.allocator(), sys.thread.currentStack());
    var total: u64 = 0;
    for (list.items) |r| total += r.len;
    self.progress.total.store(total, .monotonic);
    for (list.items) |r| {
        try self.scan(r.start, r.len, p, alignment, options.limit, walked);
        if (self.truncated) break;
    }
}

/// Keeps hits where `compare` holds. Kept values become the next baseline.
pub fn next(self: *Search, compare: Compare, text: []const u8) Error!void {
    const kind = self.kind orelse return error.NothingSearched;
    var buf: [values.max_len]?u8 = undefined;
    const wanted: ?[]const ?u8 = if (compare.takesValue()) try values.parse(kind, text, &buf) else null;
    if (wanted) |w| if (w.len != self.value_len) return error.LengthChanged;
    if ((compare == .increased or compare == .decreased) and !kind.isNumber()) return error.NotComparable;
    const Test = struct {
        compare: Compare,
        kind: Kind,
        wanted: ?[]const ?u8,

        fn keep(t: @This(), now: []const u8, before: []const u8) bool {
            return switch (t.compare) {
                .exact => pattern.matches(now, t.wanted.?),
                .changed => !std.mem.eql(u8, now, before),
                .unchanged => std.mem.eql(u8, now, before),
                .increased => values.order(t.kind, now, before) == .gt,
                .decreased => values.order(t.kind, now, before) == .lt,
            };
        }
    };
    return self.narrow(Test{ .compare = compare, .kind = kind, .wanted = wanted }, Test.keep);
}

/// Like `next` with your own test of each hit's value now and before. Kept values become the next
/// baseline.
pub fn narrow(self: *Search, context: anytype, comptime keep: fn (@TypeOf(context), now: []const u8, before: []const u8) bool) Error!void {
    if (self.kind == null) return error.NothingSearched;
    self.cancelled.store(false, .monotonic);
    self.progress.done.store(0, .monotonic);
    self.progress.total.store(self.count, .monotonic);

    // Hits are in address order, so read a page at a time
    var page: Page = .{ .memory = self.memory };
    var kept: usize = 0;
    var i: usize = 0;
    while (i < self.count) : (i += 1) {
        if (i % 4096 == 0) {
            self.progress.done.store(i, .monotonic);
            if (self.cancelled.load(.monotonic)) {
                // Narrow what we got through, keep the rest as is
                while (i < self.count) : (i += 1) {
                    self.move(i, kept, self.previous(i));
                    kept += 1;
                }
                self.count = kept;
                return error.Cancelled;
            }
        }
        const at = self.address(i);
        // Freed or unreadable since. Drop it, never fault on it
        const now = page.read(at, self.value_len) orelse continue;
        if (!keep(context, now, self.previous(i))) continue;
        self.move(i, kept, now);
        kept += 1;
    }
    self.count = kept;
    self.progress.done.store(self.progress.total.load(.monotonic), .monotonic);
}

/// `to` is at or before `from`.
fn move(self: *Search, from: usize, to: usize, value: []const u8) void {
    const at = self.address(from);
    const block = self.blocks.items[to / block_len];
    block.addresses[to % block_len] = at;
    @memmove(block.values[(to % block_len) * self.value_len ..][0..self.value_len], value);
}

fn add(self: *Search, at: usize, value: []const u8) Error!void {
    if (self.count % block_len == 0 and self.count / block_len == self.blocks.items.len) {
        const a = self.arena.allocator();
        const block = try a.create(Block);
        block.values = try a.alloc(u8, block_len * self.value_len);
        try self.blocks.append(a, block);
    }
    const block = self.blocks.items[self.count / block_len];
    block.addresses[self.count % block_len] = at;
    @memcpy(block.values[(self.count % block_len) * self.value_len ..][0..self.value_len], value);
    self.count += 1;
}

const chunk_len = 64 * 1024;

/// Unreadable chunks get skipped since memory can vanish mid-search.
fn scan(self: *Search, start: usize, len: usize, p: pattern.Pattern, alignment: usize, limit: usize, in_region: bool) Error!void {
    // An aligned whole number with no rare byte for the matcher to jump on, like 0 or -1
    const whole: ?u64 = if (alignment == p.len and alignment > 1 and !hasRareByte(p)) wholeValue(p) else null;
    var buf: [chunk_len]u8 = undefined;
    var at: usize = 0;
    while (at < len and len - at >= p.len) {
        if (self.cancelled.load(.monotonic)) return error.Cancelled;
        const n = @min(buf.len, len - at);
        const last = at + n == len;
        // Overlap with the next chunk so matches across the boundary get found there
        const step = if (last) n else n - (p.len - 1);
        defer {
            _ = self.progress.done.fetchAdd(step, .monotonic);
            at += step;
        }
        const chunk = buf[0..n];
        (if (in_region) self.memory.readInRegion(start + at, chunk) else self.memory.read(start + at, chunk)) catch continue;
        const base = start + at;
        if (whole) |w| {
            const full = switch (p.len) {
                2 => try self.addAligned(u16, chunk, base, @intCast(w), limit),
                4 => try self.addAligned(u32, chunk, base, @intCast(w), limit),
                8 => try self.addAligned(u64, chunk, base, w, limit),
                else => unreachable,
            };
            if (full) return;
            if (last) break;
            continue;
        }
        var pos: usize = 0;
        while (pattern.find(chunk, p, pos)) |i| : (pos = i + 1) {
            const hit = base + i;
            if (hit % alignment != 0) continue;
            if (try self.addHit(hit, chunk[i..][0..p.len], limit)) return;
        }
        if (last) break;
    }
    // Leftover too short to hold the value
    _ = self.progress.done.fetchAdd(len - @min(at, len), .monotonic);
}

/// No early exit so it vectorizes. True once the limit's hit.
fn addAligned(self: *Search, comptime T: type, chunk: []const u8, base: usize, want: T, limit: usize) Error!bool {
    const size = @sizeOf(T);
    const group = 64 / size;
    var i = (size - base % size) % size;
    while (i + 64 <= chunk.len) : (i += 64) {
        const words = std.mem.bytesAsSlice(T, chunk[i..][0..64]);
        var any = false;
        for (words) |word| any = any or (std.mem.littleToNative(T, word) == want);
        if (!any) continue;
        for (0..group) |k| {
            const at = i + k * size;
            if (std.mem.readInt(T, chunk[at..][0..size], .little) != want) continue;
            if (try self.addHit(base + at, chunk[at..][0..size], limit)) return true;
        }
    }
    while (i + size <= chunk.len) : (i += size) {
        if (std.mem.readInt(T, chunk[i..][0..size], .little) != want) continue;
        if (try self.addHit(base + i, chunk[i..][0..size], limit)) return true;
    }
    return false;
}

/// True if `p` has a fixed byte other than 00 or FF.
fn hasRareByte(p: pattern.Pattern) bool {
    for (p) |b| if (b) |v| if (v != 0x00 and v != 0xFF) return true;
    return false;
}

/// Only for 2, 4 or 8 bytes with no wildcards.
fn wholeValue(p: pattern.Pattern) ?u64 {
    if (p.len != 2 and p.len != 4 and p.len != 8) return null;
    var v: u64 = 0;
    for (p, 0..) |b, i| v |= @as(u64, b orelse return null) << @intCast(i * 8);
    return v;
}

/// True once the limit's hit.
fn addHit(self: *Search, at: usize, value: []const u8, limit: usize) Error!bool {
    if (self.count == limit) {
        self.truncated = true;
        return true;
    }
    try self.add(at, value);
    return false;
}

fn cutOut(list: *std.ArrayList(Memory.Region), gpa: std.mem.Allocator, hole: sys.thread.CodeRange) !void {
    const hole_end = hole.start + hole.len;
    var i: usize = 0;
    while (i < list.items.len) {
        const r = list.items[i];
        const r_end = r.start + r.len;
        if (r_end <= hole.start or r.start >= hole_end) {
            i += 1;
            continue;
        }
        _ = list.orderedRemove(i);
        if (hole_end < r_end) {
            var after = r;
            after.start = hole_end;
            after.len = r_end - hole_end;
            try list.insert(gpa, i, after);
        }
        if (r.start < hole.start) {
            var before = r;
            before.len = hole.start - r.start;
            try list.insert(gpa, i, before);
            i += 1;
        }
        if (hole_end < r_end) i += 1;
    }
}

const Regions = struct {
    memory: Memory,
    writable_only: bool,
    at: usize,
    end: usize,

    fn next(self: *Regions) ?Memory.Region {
        while (self.at < self.end) {
            var r = self.memory.regionFrom(self.at) orelse return null;
            if (r.start >= self.end) return null;
            const r_end = r.start +| r.len;
            self.at = r_end;
            if (self.writable_only and !r.writable) continue;
            r.len = @min(r_end, self.end) - r.start;
            return r;
        }
        return null;
    }
};

fn regions(self: *Search, start: usize, end: usize, writable_only: bool) Regions {
    return .{ .memory = self.memory, .writable_only = writable_only, .at = start, .end = end };
}

/// Reads hit values for `next` without touching anything that could fault or trip a guard page.
const Page = struct {
    memory: Memory,
    /// Empty means none yet.
    region_start: usize = 0,
    region_end: usize = 0,
    base: usize = 0,
    len: usize = 0,
    bytes: [4096 + values.max_len]u8 = undefined,

    /// Null if they can't be read right now.
    fn read(self: *Page, at: usize, len: usize) ?[]const u8 {
        if (at >= self.base and at + len <= self.base + self.len) return self.bytes[at - self.base ..][0..len];
        // Unwalkable memory gets checked on every read instead
        if (!self.memory.canWalk()) {
            self.len = 0;
            self.memory.read(at, self.bytes[0..len]) catch return null;
            return self.bytes[0..len];
        }
        if (at < self.region_start or at >= self.region_end) {
            const r = self.memory.regionFrom(at) orelse return null;
            self.region_start = r.start;
            self.region_end = r.start +| r.len;
            if (at < r.start) return null; // not readable anymore
        }
        // Runs into the next region, which might not be readable, so do a checked read
        if (at + len > self.region_end) {
            self.len = 0;
            self.memory.read(at, self.bytes[0..len]) catch return null;
            return self.bytes[0..len];
        }
        // Read to the end of `at`'s page or region, but at least the value
        const want = @max(len, @min(4096 - at % 4096, self.region_end - at));
        self.memory.readInRegion(at, self.bytes[0..want]) catch {
            self.len = 0;
            return null;
        };
        self.base = at;
        self.len = want;
        return self.bytes[0..len];
    }
};

const tests = struct {
    const testing = std.testing;

    fn range(bytes: []const u8) Where {
        return .{ .range = .{ .start = @intFromPtr(bytes.ptr), .len = bytes.len } };
    }

    test "first search" {
        // Off this thread's stack, since that isn't searched
        const mem = try testing.allocator.alignedAlloc(u8, .@"8", 64);
        defer testing.allocator.free(mem);
        @memset(mem, 0);
        std.mem.writeInt(u32, mem[8..12], 100, .little);
        std.mem.writeInt(u32, mem[32..36], 100, .little);
        std.mem.writeInt(u32, mem[49..53], 100, .little); // unaligned
        var search: Search = .init(.local);
        defer search.deinit();

        try search.first(range(mem), .four_bytes, "100", .{});
        try testing.expectEqual(2, search.count);
        try testing.expectEqual(@intFromPtr(mem.ptr) + 8, search.address(0));
        try testing.expectEqual(@intFromPtr(mem.ptr) + 32, search.address(1));
        try testing.expectEqualSlices(u8, &.{ 100, 0, 0, 0 }, search.previous(1));

        try search.first(range(mem), .four_bytes, "100", .{ .aligned = false });
        try testing.expectEqual(3, search.count);
        try search.first(range(mem), .four_bytes, "100", .{ .limit = 1 });
        try testing.expectEqual(1, search.count);
        try testing.expect(search.truncated);
    }

    test "next narrows hits" {
        const values_ = try testing.allocator.alloc(i32, 4);
        defer testing.allocator.free(values_);
        @memset(values_, 50);
        const bytes = std.mem.sliceAsBytes(values_);
        var search: Search = .init(.local);
        defer search.deinit();
        try search.first(range(bytes), .four_bytes, "50", .{});
        try testing.expectEqual(4, search.count);

        values_[1] = 40;
        values_[2] = 60;
        values_[3] = 60;
        try search.next(.changed, "");
        try testing.expectEqual(3, search.count);
        try search.next(.unchanged, "");
        try testing.expectEqual(3, search.count);
        values_[2] = 70;
        values_[3] = -5;
        try search.next(.increased, "");
        try testing.expectEqual(1, search.count);
        try testing.expectEqual(@intFromPtr(&values_[2]), search.address(0));
        try testing.expectEqualSlices(u8, std.mem.asBytes(&@as(i32, 70)), search.previous(0));

        try search.first(range(bytes), .four_bytes, "-5", .{});
        try testing.expectEqual(1, search.count);
        values_[3] = 12;
        try search.next(.exact, "12");
        try testing.expectEqual(1, search.count);
        try search.next(.exact, "13");
        try testing.expectEqual(0, search.count);
    }

    test "narrow with your own test" {
        const values_ = try testing.allocator.alloc(u32, 3);
        defer testing.allocator.free(values_);
        @memset(values_, 7);
        var search: Search = .init(.local);
        defer search.deinit();
        try search.first(range(std.mem.sliceAsBytes(values_)), .four_bytes, "7", .{});
        values_[0] = 0x9000_0000;
        values_[2] = 3;
        const Above = struct {
            fn keep(min: u32, now: []const u8, _: []const u8) bool {
                return std.mem.readInt(u32, now[0..4], .little) > min;
            }
        };
        // Unsigned, which `.increased` doesn't do for 4 bytes
        try search.narrow(@as(u32, 5), Above.keep);
        try testing.expectEqual(2, search.count);
        try testing.expectEqual(@intFromPtr(&values_[0]), search.address(0));
    }

    test "skips its own stack" {
        var local: u32 = 0x2468ACE1;
        std.mem.doNotOptimizeAway(&local);
        var search: Search = .init(.local);
        defer search.deinit();
        try search.first(.{ .all = .{ .writable_only = true } }, .four_bytes, "0x2468ACE1", .{});
        const stack = sys.thread.currentStack();
        for (0..search.count) |i| try testing.expect(!stack.contains(search.address(i)));
    }

    test "hole splits regions" {
        var list: std.ArrayList(Memory.Region) = .empty;
        defer list.deinit(testing.allocator);
        try list.appendSlice(testing.allocator, &.{
            .{ .start = 0x1000, .len = 0x1000, .writable = true, .executable = false },
            .{ .start = 0x3000, .len = 0x3000, .writable = true, .executable = false },
            .{ .start = 0x8000, .len = 0x1000, .writable = true, .executable = false },
        });
        try cutOut(&list, testing.allocator, .{ .start = 0x4000, .len = 0x1000 });
        try testing.expectEqual(4, list.items.len);
        try testing.expectEqual(0x3000, list.items[1].start);
        try testing.expectEqual(0x1000, list.items[1].len);
        try testing.expectEqual(0x5000, list.items[2].start);
        try testing.expectEqual(0x1000, list.items[2].len);
        try cutOut(&list, testing.allocator, .{ .start = 0x8000, .len = 0x1000 });
        try testing.expectEqual(3, list.items.len);
    }

    test "gone hits don't fault" {
        const kept = try sys.memory.allocAny(sys.memory.page_size);
        defer sys.memory.free(kept);
        const freed = try sys.memory.allocAny(sys.memory.page_size);
        std.mem.writeInt(u32, kept[0..4], 0x0BADF00D, .little);
        std.mem.writeInt(u32, freed[0..4], 0x0BADF00D, .little);
        std.mem.writeInt(u32, freed[64..68], 0x0BADF00D, .little);
        var search: Search = .init(.local);
        defer search.deinit();
        try search.first(.{ .all = .{ .writable_only = true } }, .four_bytes, "0x0BADF00D", .{});
        var ours: usize = 0;
        for (0..search.count) |i| {
            const at = search.address(i);
            if (at == @intFromPtr(kept.ptr) or at == @intFromPtr(freed.ptr) or at == @intFromPtr(freed.ptr) + 64) ours += 1;
        }
        try testing.expectEqual(3, ours);

        // The game freed what held two of them
        sys.memory.free(freed);
        try search.next(.unchanged, "");
        var still_kept = false;
        for (0..search.count) |i| {
            const at = search.address(i);
            try testing.expect(at != @intFromPtr(freed.ptr) and at != @intFromPtr(freed.ptr) + 64);
            if (at == @intFromPtr(kept.ptr)) still_kept = true;
        }
        try testing.expect(still_kept);
    }

    test "text and byte patterns" {
        const text = "a sword, a shield, a Sword";
        var search: Search = .init(.local);
        defer search.deinit();
        try search.first(range(text), .text, "sword", .{});
        try testing.expectEqual(1, search.count);
        try search.first(range(text), .bytes, "53 ?? 6F", .{});
        try testing.expectEqual(1, search.count);
        try testing.expectEqual(@intFromPtr(text) + 21, search.address(0));
        try testing.expectError(error.NotComparable, search.next(.increased, ""));
        var fresh: Search = .init(.local);
        defer fresh.deinit();
        try testing.expectError(error.NothingSearched, fresh.next(.changed, ""));
    }

    test "all of memory" {
        // A value unlikely to be elsewhere, repeated more than a block's worth
        const n = block_len + 10;
        const marks = try testing.allocator.alloc(u64, n);
        defer testing.allocator.free(marks);
        @memset(marks, 0x7A11_5EED_C0FF_EE42);
        var search: Search = .init(.local);
        defer search.deinit();

        try search.first(.{ .all = .{ .writable_only = true } }, .eight_bytes, "0x7A115EEDC0FFEE42", .{});
        // All of ours. There can be others, like copies of this test's constants
        var ours: usize = 0;
        for (0..search.count) |i| {
            const at = search.address(i);
            if (at >= @intFromPtr(marks.ptr) and at < @intFromPtr(marks.ptr) + n * 8) ours += 1;
        }
        try testing.expectEqual(n, ours);
        try testing.expectEqual(search.progress.total.load(.monotonic), search.progress.done.load(.monotonic));

        // Read-only memory gets skipped when asked, so the constant in the exe's data isn't hit
        const ro = sysRegionOf(&constant).?;
        try testing.expect(!ro.writable);
        for (0..search.count) |i| try testing.expect(!(search.address(i) >= ro.start and search.address(i) < ro.start + ro.len));
    }

    const constant: u64 = 0x7A11_5EED_C0FF_EE42;

    fn sysRegionOf(ptr: *const u64) ?Memory.Region {
        return Memory.local.regionFrom(@intFromPtr(ptr));
    }

    test "cancel from another thread" {
        var search: Search = .init(.local);
        defer search.deinit();
        // Cancel once it's going. Searching for every zero byte takes a while
        const Canceller = struct {
            fn run(s: *Search) void {
                while (s.progress.done.load(.monotonic) == 0) std.atomic.spinLoopHint();
                s.cancel();
            }
        };
        const t = try std.Thread.spawn(.{}, Canceller.run, .{&search});
        defer t.join();
        try testing.expectError(error.Cancelled, search.first(.{ .all = .{} }, .byte, "0", .{ .aligned = false, .limit = std.math.maxInt(usize) }));
    }
};

test {
    _ = tests;
}
