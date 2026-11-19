//! Who owns which bytes. Opt-in, nothing blocks writes.

const Claims = @This();

const std = @import("std");

const sys = @import("tuft_sys");
const Text = @import("tuft_text").Text;
pub const Owner = @import("tuft_event").Owner;

context: ?*anyopaque = null,
vtable: *const VTable,

pub const VTable = struct {
    /// Oldest first. Returns how many.
    find: *const fn (context: ?*anyopaque, start: usize, len: usize, out: []Claim) usize,
};

pub const Kind = enum(u8) {
    /// Patched bytes, the cave relay jump and the stub page.
    hook,
    /// Bytes changed by hand that get put back later.
    patch,
    /// Code someone put there, like a filled code cave.
    code,
    _,
};

pub const Claim = struct {
    start: usize,
    len: usize,
    kind: Kind,
    /// All claims for one thing share it.
    id: u64,
    /// Null is the host. Don't deref it, a copy can outlive its owner.
    owner: ?*const Owner = null,
    /// Up to 32 bytes.
    owner_name: Text(32) = .{},

    pub fn ownerName(self: *const Claim) []const u8 {
        return self.owner_name.get();
    }

    pub fn setOwner(self: *Claim, owner: ?*const Owner) void {
        self.owner = owner;
        self.owner_name.set(if (owner) |o| o.name else "");
    }

    pub fn overlaps(self: *const Claim, start: usize, len: usize) bool {
        return self.start < start + len and start < self.start + self.len;
    }

    /// `kai's hook 43`, or `hook 43` with no owner.
    pub fn format(self: *const Claim, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const owner_name = self.ownerName();
        if (owner_name.len != 0) try w.print("{s}'s ", .{owner_name});
        try w.print("{s} {d}", .{ std.enums.tagName(Kind, self.kind) orelse "claim", self.id });
    }
};

pub const none: Claims = .{ .vtable = &.{ .find = noneFind } };

/// Empty until `enable`.
pub const local: Claims = .{ .vtable = &.{ .find = localFind } };

pub fn find(self: Claims, start: usize, len: usize, out: []Claim) []Claim {
    return out[0..self.vtable.find(self.context, start, len, out)];
}

pub fn first(self: Claims, start: usize, len: usize) ?Claim {
    var out: [1]Claim = undefined;
    return if (self.find(start, len, &out).len != 0) out[0] else null;
}

fn noneFind(_: ?*anyopaque, _: usize, _: usize, _: []Claim) usize {
    return 0;
}

var list: sys.sync.SharedList(Claim) = .{};
const lock = &list.lock;
const claims = &list.items;
var allocator: ?std.mem.Allocator = null;
var watch: Owner.Watch(*u8, .{ .released = ownerReleased }) = .{};
var listener: u8 = 0;

/// Anything added before is lost. Claims go when their owner is released.
pub fn enable(gpa: std.mem.Allocator) void {
    {
        lock.lock();
        defer lock.unlock();
        if (allocator != null) return;
        allocator = gpa;
    }
    // Without this, claims stick around until removed by kind and id
    watch.subscribe(&listener) catch {};
}

pub fn disable() void {
    watch.deinit();
    lock.lock();
    defer lock.unlock();
    const gpa = allocator orelse return;
    claims.deinit(gpa);
    claims.* = .empty;
    allocator = null;
}

fn ownerReleased(_: *u8, owner: *Owner) void {
    removeOwner(owner);
}

pub fn removeOwner(owner: *const Owner) void {
    lock.lock();
    defer lock.unlock();
    var i: usize = 0;
    while (i < claims.items.len) {
        if (claims.items[i].owner == owner) _ = claims.orderedRemove(i) else i += 1;
    }
}

/// Does nothing until `enable`.
pub fn add(claim: Claim) std.mem.Allocator.Error!void {
    if (claim.len == 0) return;
    lock.lock();
    defer lock.unlock();
    const gpa = allocator orelse return;
    try claims.append(gpa, claim);
}

pub fn remove(kind: Kind, id: u64) void {
    lock.lock();
    defer lock.unlock();
    var i: usize = 0;
    while (i < claims.items.len) {
        const c = &claims.items[i];
        if (c.kind == kind and c.id == id) _ = claims.orderedRemove(i) else i += 1;
    }
}

pub fn setOwner(kind: Kind, id: u64, owner: ?*const Owner) void {
    lock.lock();
    defer lock.unlock();
    for (claims.items) |*c| {
        if (c.kind == kind and c.id == id) c.setOwner(owner);
    }
}

/// Returns the total, which can be more than fit.
pub fn snapshot(out: []Claim) usize {
    return list.snapshot(out);
}

fn localFind(_: ?*anyopaque, start_at: usize, len: usize, out: []Claim) usize {
    lock.lockShared();
    defer lock.unlockShared();
    var n: usize = 0;
    for (claims.items) |*c| {
        if (n == out.len) break;
        if (!c.overlaps(start_at, len)) continue;
        out[n] = c.*;
        n += 1;
    }
    return n;
}

test "kept once enabled" {
    const testing = std.testing;
    try add(.{ .start = 0x1000, .len = 4, .kind = .patch, .id = 1 });
    try testing.expectEqual(null, local.first(0x1000, 1));

    enable(testing.allocator);
    defer disable();
    try add(.{ .start = 0x1000, .len = 5, .kind = .hook, .id = 7 });
    try add(.{ .start = 0x2000, .len = 0x1000, .kind = .hook, .id = 7 });
    try add(.{ .start = 0x1004, .len = 2, .kind = .patch, .id = 7 });
    var kai: Owner = .init("kai");
    setOwner(.hook, 7, &kai);

    var out: [4]Claim = undefined;
    try testing.expectEqual(2, local.find(0x1003, 2, &out).len);
    try testing.expectEqual(null, local.first(0x1006, 0x10));
    try testing.expectEqual(null, local.first(0xFF0, 0x10));
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("kai's hook 7", try std.fmt.bufPrint(&buf, "{f}", .{local.first(0x2FFF, 1).?}));
    try testing.expectEqualStrings("patch 7", try std.fmt.bufPrint(&buf, "{f}", .{local.first(0x1005, 1).?}));

    remove(.hook, 7);
    try testing.expectEqual(Kind.patch, local.first(0x1000, 0x2000).?.kind);
    try testing.expectEqual(null, none.first(0x1004, 1));
    try testing.expectEqual(1, snapshot(&out));
    try testing.expectEqual(0x1004, out[0].start);
}

test "released owner's claims go" {
    const testing = std.testing;
    enable(testing.allocator);
    defer disable();
    var kai: Owner = .init("kai");
    var c: Claim = .{ .start = 0x1000, .len = 4, .kind = .patch, .id = 1 };
    c.setOwner(&kai);
    try add(c);
    try add(.{ .start = 0x2000, .len = 4, .kind = .patch, .id = 2 });

    kai.release();
    var out: [4]Claim = undefined;
    try testing.expectEqual(1, snapshot(&out));
    try testing.expectEqual(0x2000, out[0].start);
}
