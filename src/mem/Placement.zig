//! Where code we put in a game goes, and the data it reads. Hooks, patches that don't fit in
//! place and plain allocations all come through here, so code always lands in reach of its data.
//!
//! Best first:
//! - `near`, a page a `jmp rel32` from the target reaches
//! - `cave`, padding in the target's module, writable while it's ours
//! - `far`, the module's far zone, jumped to through a 14-byte cave relay if there's one
//! - `anywhere`, jumped to absolutely
//!
//! Pages get shared, so data placed first leaves room beside it for the code that reads it. Data
//! and the code that reads it can also go in as one group, see `placeGroup`.

const Placement = @This();

const std = @import("std");
const arch = @import("tuft_arch");
const sys = @import("tuft_sys");

const pages = @import("pages.zig");
const caves = @import("caves.zig");
const Claims = @import("Claims.zig");

pub const Tier = enum { near, cave, far, anywhere };
pub const Tiers = std.EnumSet(Tier);

/// How the target gets to the code.
pub const Jump = enum {
    /// `jmp rel32`.
    near,
    /// `jmp rel32` to an absolute jump in a cave near the target.
    relay,
    /// An absolute jump, which takes more bytes at the target.
    absolute,
};

pub const Request = struct {
    /// Where the jump to the code is, or what the data's for. 0 is anywhere.
    target: usize = 0,
    /// Bytes of code.
    code: usize = 0,
    /// Bytes of data, after the code.
    data: usize = 0,
    data_align: usize = 16,
    /// Data placed before that the code reads, so it has to be in reach of it.
    reach: []const usize = &.{},
    /// More code near and cave spots have to reach, like other jumps to it or patches in place
    /// that read its data.
    points: []const usize = &.{},
    /// Code all over the target's module reads its data, so near spots try to reach all of it
    /// first. Always so for data on its own.
    wide: bool = false,
    /// Whether the target jumps to the code. Slot stubs don't.
    jump: bool = true,
};

/// One of the things `placeGroup` puts side by side.
pub const Part = struct {
    /// What jumps to it. 0 for data.
    target: usize = 0,
    len: usize,
    alignment: usize = 16,
};

pub const Group = struct {
    parts: []const Part,
    /// What it's for when no part jumps to it, like `Request.target`. 0 is its first reader.
    near: usize = 0,
    /// Data placed before that its code reads.
    reach: []const usize = &.{},
    /// Code that reads its data in place, which near and cave spots have to reach too.
    readers: []const usize = &.{},
};

/// Empty if it didn't ask for any.
code: []u8 = &.{},
data: []u8 = &.{},
tier: Tier,
jump: Jump = .near,
/// The cave a `.relay` jump goes through.
relay: usize = 0,
/// Code, or code and data together. Then data when it's in a cave of its own, then the relay.
held: [3]?*Arena = @splat(null),
linked: bool = false,

/// Tiers it may use. Tests narrow it to force one.
pub var tiers: Tiers = .full;
/// Whether far code may get a relay. Tests turn it off for an absolute jump.
pub var relays: bool = true;

/// `error.OutOfReach` if no tier it may use has room.
pub fn place(request: Request) !Placement {
    lock.lock();
    defer lock.unlock();
    return placeLocked(request);
}

/// Bytes `parts` take side by side.
pub fn groupSize(parts: []const Part) usize {
    var at: usize = 0;
    for (parts) |part| at = std.mem.alignForward(usize, at, part.alignment) + part.len;
    return at;
}

/// Puts all of `group`'s parts side by side in one spot, so they all reach each other, with a
/// Placement each in `out`. Data parts get `data`, code parts `code` and a jump from their target.
/// Each one frees on its own, and the spot goes with the last. `error.OutOfReach` if no tier has
/// room for all of it.
pub fn placeGroup(group: Group, out: []Placement) !void {
    std.debug.assert(out.len == group.parts.len);
    if (group.parts.len == 0) return;
    var points: std.ArrayList(usize) = .empty;
    defer points.deinit(gpa);
    var first: usize = 0;
    var has_data = false;
    var alignment: usize = 16;
    for (group.parts) |part| {
        alignment = @max(alignment, part.alignment);
        if (part.target == 0) {
            has_data = true;
        } else if (first == 0) {
            first = part.target;
        } else try points.append(gpa, part.target);
    }
    try points.appendSlice(gpa, group.readers);
    const total = groupSize(group.parts);
    const has_code = first != 0;
    const for_data = if (group.near != 0 or group.readers.len == 0) group.near else group.readers[0];

    lock.lock();
    defer lock.unlock();
    const base = try placeLocked(.{
        .target = if (has_code) first else for_data,
        .code = if (has_code) total else 0,
        .data = if (has_code) 0 else total,
        .data_align = alignment,
        .reach = group.reach,
        .points = points.items,
        .wide = has_data,
        .jump = false,
    });
    const arena = base.held[0].?;
    const start = @intFromPtr(if (has_code) base.code.ptr else base.data.ptr);
    const jump: Jump = switch (base.tier) {
        .near, .cave => .near,
        .far, .anywhere => .absolute,
    };
    var at: usize = 0;
    for (group.parts, out) |part, *p| {
        at = std.mem.alignForward(usize, at, part.alignment);
        const bytes = bytesAt(start + at, part.len);
        p.* = .{ .tier = base.tier, .held = .{ arena, null, null } };
        if (part.target == 0) {
            p.data = bytes;
        } else {
            p.code = bytes;
            p.jump = jump;
        }
        at += part.len;
    }
    arena.refs += @intCast(group.parts.len - 1);
    if (base.tier != .far or !relays) return;
    for (group.parts, out) |part, *p| {
        if (part.target == 0) continue;
        const none: Span = .{};
        const relay = findCave(part.target, arch.abs_jmp_len, &none) orelse continue;
        p.held[2] = addCave(relay, arch.abs_jmp_len, true) catch |err| {
            for (out) |*o| o.drop();
            return err;
        };
        p.relay = relay;
        p.jump = .relay;
    }
}

fn placeLocked(request: Request) !Placement {
    for (std.enums.values(Tier)) |tier| {
        if (!tiers.contains(tier)) continue;
        const found = switch (tier) {
            .near => try placeNear(request),
            .cave => try placeCave(request),
            .far => try placeFar(request),
            .anywhere => try placeAnywhere(request),
        };
        if (found) |p| return p;
    }
    return error.OutOfReach;
}

/// Bytes at `target` that jump to `entry`, somewhere in the code. Fills in the relay.
pub fn link(self: *Placement, target: usize, entry: usize) !arch.Jmp {
    var out: arch.Jmp = .{ .bytes = @splat(0xCC), .len = arch.near_jmp_len };
    switch (self.jump) {
        .near => out.bytes[0..arch.near_jmp_len].* = arch.encodeNearJmp(target, entry) orelse return error.OutOfReach,
        .relay => {
            out.bytes[0..arch.near_jmp_len].* = arch.encodeNearJmp(target, self.relay) orelse return error.OutOfReach;
            try sys.memory.writeCode(self.relay, &arch.encodeAbsJmp(entry));
            self.linked = true;
        },
        .absolute => {
            out.bytes[0..arch.abs_jmp_len].* = arch.encodeAbsJmp(entry);
            out.len = arch.abs_jmp_len;
        },
    }
    return out;
}

/// How many bytes `link` writes at the target.
pub fn jumpLen(self: *const Placement) u8 {
    return if (self.jump == .absolute) arch.abs_jmp_len else arch.near_jmp_len;
}

/// Puts the relay cave back. Takes no locks, so it's fine with threads frozen. False if it
/// couldn't.
pub fn unlink(self: *Placement) bool {
    if (!self.linked) return true;
    self.linked = false;
    sys.memory.writeCode(self.relay, &self.held[2].?.what.relay) catch return false;
    return true;
}

/// Unlinks it too. Code there mustn't be running.
pub fn free(self: *Placement) void {
    _ = self.unlink();
    lock.lock();
    defer lock.unlock();
    self.drop();
}

fn drop(self: *Placement) void {
    for (self.held) |a| if (a) |arena| arena.drop();
    self.held = @splat(null);
}

/// Whether we placed something there, like data that code has to reach.
pub fn holds(addr: usize) bool {
    lock.lockShared();
    defer lock.unlockShared();
    for (arenas.items) |a| if (a.what != .relay and addr >= a.start and addr < a.start + a.len) return true;
    return false;
}

/// A page or a cave things get carved from. It goes when the last thing in it does.
const Arena = struct {
    start: usize,
    len: usize,
    used: usize = 0,
    refs: u32 = 0,
    tier: Tier,
    /// A far page's zone, see `pages.zoneKey`.
    zone: usize = 0,
    what: union(enum) {
        page: pages.Slice,
        /// Made writable, with what was there.
        cave: struct { saved: []u8, was: sys.memory.Protection = .read_execute },
        /// What was there before the jump. Written with `writeCode`, so it stays as it was.
        relay: [arch.abs_jmp_len]u8,
    },

    fn take(self: *Arena, len: usize, alignment: usize) ?usize {
        const at = std.mem.alignForward(usize, self.start + self.used, alignment);
        if (at + len > self.start + self.len) return null;
        self.used = at + len - self.start;
        self.refs += 1;
        return at;
    }

    fn drop(self: *Arena) void {
        self.refs -= 1;
        if (self.refs == 0) self.release();
    }

    fn holdsAny(self: *const Arena, list: []const usize) bool {
        for (list) |at| if (at >= self.start and at < self.start + self.len) return true;
        return false;
    }

    fn overlaps(self: *const Arena, at: usize, len: usize) bool {
        return self.start < at + len and at < self.start + self.len;
    }

    fn release(self: *Arena) void {
        for (arenas.items, 0..) |a, i| if (a == self) {
            _ = arenas.swapRemove(i);
            break;
        };
        switch (self.what) {
            .page => |p| pages.free(p),
            .cave => |c| {
                @memcpy(@as([*]u8, @ptrFromInt(self.start))[0..self.len], c.saved);
                restoreProtection(self.start, self.len, c.was);
                Claims.remove(.code, claimId(self.start));
                gpa.free(c.saved);
            },
            .relay => Claims.remove(.code, claimId(self.start)),
        }
        gpa.destroy(self);
    }
};

const gpa = std.heap.smp_allocator;
var lock: sys.sync.RwLock = .{};
var arenas: std.ArrayList(*Arena) = .empty;

/// Caves are padding, so only small things go in one.
const max_cave = 1024;

/// What a spot has to be in rel32 reach of, all of it.
const Span = struct {
    lo: usize = std.math.maxInt(usize),
    hi: usize = 0,

    fn add(self: *Span, at: usize) void {
        self.lo = @min(self.lo, at);
        self.hi = @max(self.hi, at);
    }

    fn empty(self: Span) bool {
        return self.hi < self.lo;
    }

    fn reachedBy(self: Span, start: usize, len: usize) bool {
        if (arch.near_reaches_all or self.empty()) return true;
        const end = start + len;
        return close(start, self.lo) and close(start, self.hi) and close(end, self.lo) and close(end, self.hi);
    }

    fn close(a: usize, b: usize) bool {
        return (if (a > b) a - b else b - a) < arch.near_range;
    }

    fn page(self: Span, len: usize) !?pages.Slice {
        return pages.allocNearSpan(self.lo, self.hi +| 1, len);
    }
};

fn reachSpan(r: Request) Span {
    var span: Span = .{};
    for (r.reach) |at| span.add(at);
    return span;
}

/// Its reach, the target and its points.
fn targetSpan(r: Request) Span {
    var span = reachSpan(r);
    span.add(r.target);
    for (r.points) |at| span.add(at);
    return span;
}

/// Data near a module's base is often read by code much further in.
fn imageSpan(r: Request) ?Span {
    const base = sys.module.containingBase(r.target) orelse return null;
    const size = sys.module.imageSize(base) catch return null;
    var span = targetSpan(r);
    span.add(base);
    span.add(base + size);
    return span;
}

fn wide(r: Request) bool {
    return r.code == 0 or r.wide;
}

const Layout = struct { total: usize, data_at: usize, alignment: usize };

fn layoutOf(r: Request) Layout {
    const data_at = if (r.data == 0) r.code else std.mem.alignForward(usize, r.code, r.data_align);
    return .{ .total = @max(data_at + r.data, 1), .data_at = data_at, .alignment = @max(16, r.data_align) };
}

fn bytesAt(at: usize, len: usize) []u8 {
    if (len == 0) return &.{};
    return @as([*]u8, @ptrFromInt(at))[0..len];
}

/// Code then data at `at`.
fn together(r: Request, at: usize, arena: *Arena, tier: Tier) Placement {
    const layout = layoutOf(r);
    return .{ .code = bytesAt(at, r.code), .data = bytesAt(at + layout.data_at, r.data), .tier = tier, .held = .{ arena, null, null } };
}

const Filter = struct {
    cave: bool = false,
    tier: ?Tier = null,
    zone: ?usize = null,
};

/// Room in something we already hold that reaches `span`. Beside the data it reads first.
fn reuse(r: Request, span: Span, filter: Filter) ?struct { *Arena, usize } {
    const layout = layoutOf(r);
    for ([_]bool{ true, false }) |beside| for (arenas.items) |a| {
        if (a.what == .relay or (a.what == .cave) != filter.cave) continue;
        if (filter.tier) |t| if (a.tier != t) continue;
        if (filter.zone) |z| if (a.zone != z) continue;
        if (beside != a.holdsAny(r.reach) or !span.reachedBy(a.start, a.len)) continue;
        if (a.take(layout.total, layout.alignment)) |at| return .{ a, at };
    };
    return null;
}

fn addPage(page: pages.Slice, tier: Tier, zone: usize) !*Arena {
    errdefer pages.free(page);
    const arena = try gpa.create(Arena);
    errdefer gpa.destroy(arena);
    arena.* = .{ .start = @intFromPtr(page.ptr), .len = page.len, .tier = tier, .zone = zone, .what = .{ .page = page } };
    try arenas.append(gpa, arena);
    return arena;
}

/// Engine claims have the top bit set, so they don't clash with someone's own `.code` claims.
fn claimId(at: usize) u64 {
    return @as(u64, at) | (1 << 63);
}

fn addCave(at: usize, len: usize, relay: bool) !*Arena {
    const arena = try gpa.create(Arena);
    errdefer gpa.destroy(arena);
    const there: [*]const u8 = @ptrFromInt(at);
    if (relay) {
        arena.* = .{ .start = at, .len = len, .refs = 1, .tier = .far, .what = .{ .relay = there[0..arch.abs_jmp_len].* } };
    } else {
        const saved = try gpa.dupe(u8, there[0..len]);
        errdefer gpa.free(saved);
        arena.* = .{ .start = at, .len = len, .tier = .cave, .what = .{ .cave = .{ .saved = saved } } };
        arena.what.cave.was = try makeWritable(at, len);
    }
    errdefer if (!relay) restoreProtection(at, len, arena.what.cave.was);
    try arenas.append(gpa, arena);
    Claims.add(.{ .start = at, .len = len, .kind = .code, .id = claimId(at) }) catch {};
    return arena;
}

/// Protection is per page, so a page another of our caves made writable stays as it is.
fn makeWritable(at: usize, len: usize) !sys.memory.Protection {
    var was: ?sys.memory.Protection = null;
    var page = std.mem.alignBackward(usize, at, pages.size);
    while (page < at + len) : (page += pages.size) {
        if (writableOn(page)) |other| {
            was = was orelse other;
            continue;
        }
        const old = try sys.memory.protect(page, pages.size, .read_write_execute);
        was = was orelse old;
    }
    return was.?;
}

/// Pages none of our other caves are on.
fn restoreProtection(at: usize, len: usize, was: sys.memory.Protection) void {
    var page = std.mem.alignBackward(usize, at, pages.size);
    while (page < at + len) : (page += pages.size) {
        if (writableOn(page) == null) _ = sys.memory.protect(page, pages.size, was) catch {};
    }
}

fn writableOn(page: usize) ?sys.memory.Protection {
    for (arenas.items) |a| if (a.what == .cave and a.overlaps(page, pages.size)) return a.what.cave.was;
    return null;
}

fn findCave(near: usize, len: usize, span: *const Span) ?usize {
    return caves.findCodeCaveWhere(near, len, .{ .context = span, .accept = struct {
        fn accept(context: ?*const anyopaque, at: usize, n: usize) bool {
            const s: *const Span = @ptrCast(@alignCast(context.?));
            if (!s.reachedBy(at, n)) return false;
            for (arenas.items) |a| if (a.overlaps(at, n)) return false;
            return true;
        }
    }.accept });
}

fn placeNear(r: Request) !?Placement {
    if (r.target == 0) return null;
    if (wide(r)) if (imageSpan(r)) |span| if (try nearPage(r, span)) |p| return p;
    return nearPage(r, targetSpan(r));
}

fn nearPage(r: Request, span: Span) !?Placement {
    const layout = layoutOf(r);
    if (reuse(r, span, .{})) |t| return together(r, t[1], t[0], .near);
    const page = (try span.page(layout.total)) orelse return null;
    const arena = try addPage(page, .near, 0);
    return together(r, arena.take(layout.total, layout.alignment).?, arena, .near);
}

/// One cave for both if there's one, else two in reach of each other.
fn placeCave(r: Request) !?Placement {
    if (r.target == 0 or sys.module.containingBase(r.target) == null) return null;
    const layout = layoutOf(r);
    if (layout.total > max_cave) return null;
    const span = if (wide(r)) imageSpan(r) orelse targetSpan(r) else targetSpan(r);
    if (reuse(r, span, .{ .cave = true })) |t| return together(r, t[1], t[0], .cave);
    if (try newCave(r.target, layout.total, layout.alignment, span)) |t| return together(r, t[1], t[0], .cave);
    if (r.code == 0 or r.data == 0) return null;

    const code = (try newCave(r.target, r.code, 16, span)) orelse return null;
    var p: Placement = .{ .code = bytesAt(code[1], r.code), .tier = .cave, .held = .{ code[0], null, null } };
    errdefer p.drop();
    var near_code: Span = .{};
    near_code.add(code[1]);
    near_code.add(code[1] + r.code);
    const data = (try newCave(r.target, r.data, r.data_align, near_code)) orelse {
        p.drop();
        return null;
    };
    p.held[1] = data[0];
    p.data = bytesAt(data[1], r.data);
    return p;
}

fn newCave(near: usize, len: usize, alignment: usize, span: Span) !?struct { *Arena, usize } {
    const room = len + alignment - 1;
    const at = findCave(near, room, &span) orelse return null;
    const arena = try addCave(at, room, false);
    return .{ arena, arena.take(len, alignment).? };
}

fn placeFar(r: Request) !?Placement {
    if (r.target == 0) return null;
    var p = (try pageFor(r, .far, pages.zoneKey(r.target))) orelse return null;
    errdefer p.drop();
    if (r.code == 0 or !r.jump) return p;
    p.jump = .absolute;
    if (!relays) return p;
    const none: Span = .{};
    const at = findCave(r.target, arch.abs_jmp_len, &none) orelse return p;
    p.held[2] = try addCave(at, arch.abs_jmp_len, true);
    p.relay = at;
    p.jump = .relay;
    return p;
}

fn placeAnywhere(r: Request) !?Placement {
    var p = (try pageFor(r, .anywhere, 0)) orelse return null;
    if (r.code > 0 and r.jump and r.target != 0) p.jump = .absolute;
    return p;
}

/// A page in reach of its data, else in its zone.
fn pageFor(r: Request, tier: Tier, zone: usize) !?Placement {
    const layout = layoutOf(r);
    const span = reachSpan(r);
    const filter: Filter = if (span.empty()) .{ .tier = tier, .zone = zone } else .{};
    if (reuse(r, span, filter)) |t| return together(r, t[1], t[0], tier);
    const page = if (!span.empty())
        (try span.page(layout.total)) orelse return null
    else if (tier == .far)
        try pages.allocFar(r.target, layout.total)
    else
        try pages.allocAny(layout.total);
    const arena = try addPage(page, tier, zone);
    return together(r, arena.take(layout.total, layout.alignment).?, arena, tier);
}

const tests = struct {
    const testing = std.testing;
    const builtin = @import("builtin");

    noinline fn target(a: u32) callconv(.c) u32 {
        var x = a;
        asm volatile (""
            : [x] "+r" (x),
        );
        return x + 1;
    }

    noinline fn otherTarget(a: u32) callconv(.c) u32 {
        var x = a;
        asm volatile (""
            : [x] "+r" (x),
        );
        return x + 2;
    }

    fn only(tier: Tier) void {
        tiers = .initOne(tier);
    }

    fn reset() void {
        tiers = .full;
        relays = true;
    }

    fn reaches(a: usize, b: usize) bool {
        const s: Span = .{ .lo = b, .hi = b };
        return s.reachedBy(a, 1);
    }

    /// `mov eax, [rip+data]` then `ret`, on x64. A plain `mov eax, [data]` on x86.
    fn writeReader(code: []u8, data: usize) void {
        const at = @intFromPtr(code.ptr);
        if (builtin.cpu.arch == .x86_64) {
            const rel: i32 = @intCast(@as(isize, @bitCast(data -% (at + 6))));
            code[0..2].* = .{ 0x8B, 0x05 };
            std.mem.writeInt(i32, code[2..6], rel, .little);
            code[6] = 0xC3;
        } else {
            code[0] = 0xA1;
            std.mem.writeInt(u32, code[1..5], @intCast(data), .little);
            code[5] = 0xC3;
        }
    }

    test "code and its data reach each other in every tier" {
        defer reset();
        const at = @intFromPtr(&target);
        for (std.enums.values(Tier), 0..) |tier, i| {
            only(tier);
            var p = place(.{ .target = at, .code = 16, .data = 4 }) catch |err| {
                // The test exe might have no padding to spare
                if (tier == .cave and err == error.OutOfReach) continue;
                return err;
            };
            defer p.free();
            try testing.expectEqual(tier, p.tier);
            const data = @intFromPtr(p.data.ptr);
            try testing.expect(reaches(@intFromPtr(p.code.ptr), data));
            try testing.expect(holds(data));
            switch (tier) {
                .near, .cave => try testing.expectEqual(Jump.near, p.jump),
                .far => try testing.expect(p.jump != .near),
                .anywhere => try testing.expectEqual(Jump.absolute, p.jump),
            }
            if (tier == .near or tier == .cave) try testing.expect(reaches(@intFromPtr(p.code.ptr), at));

            std.mem.writeInt(u32, p.data[0..4], 0x1234 + @as(u32, @intCast(i)), .little);
            writeReader(p.code, data);
            const read: *const fn () callconv(.c) u32 = @ptrCast(p.code.ptr);
            try testing.expectEqual(0x1234 + @as(u32, @intCast(i)), read());
        }
    }

    test "data on its own near a module reaches all of it" {
        if (arch.near_reaches_all) return error.SkipZigTest;
        defer reset();
        only(.near);
        const base = sys.module.mainBase();
        const image = try sys.module.imageSize(base);
        var p = try place(.{ .target = base, .data = 64 });
        defer p.free();
        const at = @intFromPtr(p.data.ptr);
        for ([_]usize{ base, base + image - 8 }) |from| try testing.expect(reaches(from, at) and reaches(from, at + 63));
    }

    test "a group's parts land together, in reach of each other and their targets, in every tier" {
        defer reset();
        const at = @intFromPtr(&target);
        const other = @intFromPtr(&otherTarget);
        for (std.enums.values(Tier)) |tier| {
            only(tier);
            var out: [3]Placement = undefined;
            const parts = [_]Part{ .{ .len = 8, .alignment = 8 }, .{ .target = at, .len = 32 }, .{ .target = other, .len = 48 } };
            placeGroup(.{ .parts = &parts }, &out) catch |err| {
                // The test exe might have no padding to spare
                if (tier == .cave and err == error.OutOfReach) continue;
                return err;
            };
            defer for (&out) |*p| p.free();
            const data = @intFromPtr(out[0].data.ptr);
            try testing.expect(holds(data));
            for (out[1..], [_]usize{ at, other }) |p, from| {
                try testing.expectEqual(tier, p.tier);
                try testing.expectEqual(out[0].held[0], p.held[0]);
                try testing.expect(reaches(@intFromPtr(p.code.ptr), data));
                switch (tier) {
                    .near, .cave => {
                        try testing.expectEqual(Jump.near, p.jump);
                        try testing.expect(reaches(@intFromPtr(p.code.ptr), from));
                    },
                    .far => try testing.expect(p.jump != .near),
                    .anywhere => try testing.expectEqual(Jump.absolute, p.jump),
                }
            }
            std.mem.writeInt(u32, out[0].data[0..4], 77, .little);
            writeReader(out[2].code, data);
            const read: *const fn () callconv(.c) u32 = @ptrCast(out[2].code.ptr);
            try testing.expectEqual(77, read());
        }
    }

    test "a group too big for a cave goes far as one" {
        defer reset();
        tiers = .initMany(&.{ .cave, .far });
        const at = @intFromPtr(&target);
        var out: [2]Placement = undefined;
        const parts = [_]Part{ .{ .len = 600 }, .{ .target = at, .len = 600 } };
        try placeGroup(.{ .parts = &parts }, &out);
        defer for (&out) |*p| p.free();
        try testing.expectEqual(Tier.far, out[1].tier);
        try testing.expect(reaches(@intFromPtr(out[1].code.ptr), @intFromPtr(out[0].data.ptr) + 599));
    }

    test "a group's cave goes back when its last part does" {
        defer reset();
        only(.cave);
        const at = @intFromPtr(&target);
        var out: [2]Placement = undefined;
        const parts = [_]Part{ .{ .len = 16 }, .{ .target = at, .len = 16 } };
        placeGroup(.{ .parts = &parts }, &out) catch return error.SkipZigTest;
        const arena = out[0].held[0].?;
        const start = arena.start;
        const before = try testing.allocator.dupe(u8, arena.what.cave.saved);
        defer testing.allocator.free(before);
        const data = @intFromPtr(out[0].data.ptr);
        @memset(out[0].data, 0x5A);
        @memset(out[1].code, 0xCC);
        out[0].free();
        try testing.expect(holds(data));
        out[1].free();
        try testing.expect(!holds(data));
        try testing.expectEqualSlices(u8, before, @as([*]const u8, @ptrFromInt(start))[0..before.len]);
    }

    test "code placed after its data lands in reach of it" {
        defer reset();
        const at = @intFromPtr(&target);
        for ([_]Tier{ .near, .far, .anywhere }) |tier| {
            only(tier);
            var data = try place(.{ .target = if (tier == .anywhere) 0 else at, .data = 8 });
            defer data.free();
            const where = @intFromPtr(data.data.ptr);
            var code = try place(.{ .target = at, .code = 32, .reach = &.{where} });
            defer code.free();
            try testing.expect(reaches(@intFromPtr(code.code.ptr), where));
            // Beside it, in the room its page had left
            try testing.expectEqual(data.held[0], code.held[0]);
        }
    }

    test "far code goes through a relay, or jumps absolutely" {
        defer reset();
        const at = @intFromPtr(&target);
        only(.far);
        {
            var p = try place(.{ .target = at, .code = 16 });
            defer p.free();
            if (p.jump != .relay) return error.SkipZigTest;
            try testing.expect(reaches(p.relay, at));
            const before = @as(*const [arch.abs_jmp_len]u8, @ptrFromInt(p.relay)).*;
            const jmp = try p.link(at, @intFromPtr(p.code.ptr));
            try testing.expectEqual(arch.near_jmp_len, jmp.len);
            try testing.expectEqualSlices(u8, &arch.encodeAbsJmp(@intFromPtr(p.code.ptr)), @as(*const [arch.abs_jmp_len]u8, @ptrFromInt(p.relay)));
            try testing.expect(p.unlink());
            try testing.expectEqualSlices(u8, &before, @as(*const [arch.abs_jmp_len]u8, @ptrFromInt(p.relay)));
        }
        relays = false;
        var p = try place(.{ .target = at, .code = 16 });
        defer p.free();
        try testing.expectEqual(Jump.absolute, p.jump);
        try testing.expectEqual(arch.abs_jmp_len, (try p.link(at, @intFromPtr(p.code.ptr))).len);
    }

    test "caves are claimed, writable while ours, and put back" {
        defer reset();
        Claims.enable(testing.allocator);
        defer Claims.disable();
        only(.cave);
        const at = @intFromPtr(&target);
        var p = place(.{ .target = at, .data = 16 }) catch return error.SkipZigTest;
        const data = @intFromPtr(p.data.ptr);
        const arena = p.held[0].?;
        const start = arena.start;
        const before = try testing.allocator.dupe(u8, arena.what.cave.saved);
        defer testing.allocator.free(before);
        try testing.expect(Claims.local.first(data, 16) != null);
        try testing.expect(sys.memory.regionFrom(data).?.writable);
        @memset(p.data, 0x5A);

        // Nobody else gets it, and more of ours doesn't overlap it
        if (caves.findCodeCave(at, 16)) |other| try testing.expect(other + 16 <= start or other >= start + before.len);
        if (place(.{ .target = at, .data = 16 })) |placed| {
            var second = placed;
            const second_at = @intFromPtr(second.data.ptr);
            try testing.expect(second_at + 16 <= data or second_at >= data + 16);
            second.free();
        } else |_| {}

        p.free();
        try testing.expectEqualSlices(u8, before, @as([*]const u8, @ptrFromInt(start))[0..before.len]);
        try testing.expect(Claims.local.first(start, before.len) == null);
        try testing.expect(!sys.memory.regionFrom(data).?.writable);
        try testing.expect(!holds(data));
    }
};

test {
    _ = tests;
}
