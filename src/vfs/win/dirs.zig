//! Folder listings with virtual files merged in after real ones, shadowing same-named real files.
//! Only listings that finish right away are merged, which is how `FindFirstFile` and friends work.

const std = @import("std");

const Vfs = @import("../root.zig");
const File = Vfs.File;
const Store = Vfs.Store;
const paths = Vfs.paths;
const nt = @import("nt.zig");
const names = @import("names.zig");
const virtual = @import("virtual.zig");

/// Where each supported class keeps its fields.
const Layout = struct {
    name_len: usize,
    name: usize,
    /// Class 12 has none of the times and sizes.
    full: bool = true,
    ea: ?usize = null,
    short: ?usize = null,
    id: ?usize = null,
};

fn layoutOf(class: u32) ?Layout {
    return switch (class) {
        1 => .{ .name_len = 60, .name = 64 },
        2 => .{ .name_len = 60, .name = 68, .ea = 64 },
        3 => .{ .name_len = 60, .name = 94, .ea = 64, .short = 68 },
        12 => .{ .name_len = 8, .name = 12, .full = false },
        37 => .{ .name_len = 60, .name = 104, .ea = 64, .short = 68, .id = 96 },
        38 => .{ .name_len = 60, .name = 80, .ea = 64, .id = 72 },
        else => null,
    };
}

/// One handle's place in its listing.
pub const Listing = struct {
    /// Virtual children that match the pattern.
    entries: []Store.Entry,
    /// Folders the real listing already had.
    seen: []bool,
    next: usize = 0,
    /// "." and ".." still to go, for virtual folders.
    dots: u2 = 0,
    real_done: bool,
    returned_any: bool = false,

    pub fn destroy(self: *Listing, allocator: std.mem.Allocator) void {
        Store.freeEntries(allocator, self.entries);
        allocator.free(self.seen);
        allocator.destroy(self);
    }
};

/// Calls the real query, one way or the other.
pub const Query = struct {
    ctx: *const anyopaque,
    call: *const fn (ctx: *const anyopaque, restart: bool, pattern: ?*nt.UNICODE_STRING) nt.NTSTATUS,
    c: virtual.Completion,
    buffer: [*]u8,
    length: u32,
    class: u32,
    single: bool,
    restart: bool,
    pattern: ?*nt.UNICODE_STRING,
};

pub fn query(vfs: *Vfs, file: *File, q: Query) nt.NTSTATUS {
    const layout = layoutOf(q.class) orelse return if (file.kind == .real) q.call(q.ctx, q.restart, q.pattern) else .INVALID_INFO_CLASS;
    var key_buf: [names.max]u8 = undefined;
    const key = paths.key(&key_buf, file.path);

    file.state.lock.lock();
    // Unlocked before `complete`, which takes it too
    var held = true;
    defer if (held) file.state.lock.unlock();
    if (file.state.listing == null or q.restart) {
        if (file.state.listing) |l| l.destroy(vfs.allocator);
        file.state.listing = null;
        if (file.kind == .real and !vfs.store.hasChildren(key)) return q.call(q.ctx, q.restart, q.pattern);
        file.state.listing = start(vfs, key, file.kind == .virtual, q.pattern) catch return nt.STATUS_INSUFFICIENT_RESOURCES;
    }
    const listing = file.state.listing.?;

    var restart = q.restart;
    while (!listing.real_done) {
        const status = q.call(q.ctx, restart, q.pattern);
        restart = false;
        if (status == .PENDING) return status;
        if (status == .NO_MORE_FILES or status == nt.STATUS_NO_SUCH_FILE) {
            listing.real_done = true;
            break;
        }
        if (!nt.ok(status) or status == .BUFFER_OVERFLOW) return status;
        const used = hideShadowed(listing, layout, q.buffer, q.c.iosb.Information);
        if (used > 0) {
            q.c.iosb.Information = used;
            listing.returned_any = true;
            return status;
        }
    }

    const written = emit(listing, layout, q.buffer[0..q.length], q.single);
    if (written == 0) {
        const status: nt.NTSTATUS = if (!listing.returned_any) nt.STATUS_NO_SUCH_FILE else if (remaining(listing)) .BUFFER_OVERFLOW else .NO_MORE_FILES;
        q.c.iosb.u.Status = status;
        q.c.iosb.Information = 0;
        return status;
    }
    listing.returned_any = true;
    file.state.lock.unlock();
    held = false;
    return virtual.complete(file, q.c, .SUCCESS, written);
}

fn start(vfs: *Vfs, key: []const u8, virtual_only: bool, pattern: ?*nt.UNICODE_STRING) !*Listing {
    const all = try vfs.store.children(vfs.allocator, key);
    var kept: usize = 0;
    var upper: [names.max]u16 = undefined;
    const expr = upcase(pattern, &upper);
    for (all) |e| {
        if (matches(expr, e.name)) {
            all[kept] = e;
            kept += 1;
        } else vfs.allocator.free(e.name);
    }
    const entries = vfs.allocator.realloc(all, kept) catch all[0..kept];
    errdefer Store.freeEntries(vfs.allocator, entries);
    const seen = try vfs.allocator.alloc(bool, entries.len);
    @memset(seen, false);
    errdefer vfs.allocator.free(seen);
    const listing = try vfs.allocator.create(Listing);
    listing.* = .{ .entries = entries, .seen = seen, .real_done = virtual_only };
    if (virtual_only) {
        if (matches(expr, ".")) listing.dots |= 1;
        if (matches(expr, "..")) listing.dots |= 2;
    }
    return listing;
}

/// Uppercased for `RtlIsNameInExpression`. Null matches everything.
fn upcase(pattern: ?*nt.UNICODE_STRING, out: []u16) ?nt.UNICODE_STRING {
    const p = pattern orelse return null;
    const s = p.slice();
    if (s.len == 0 or s.len > out.len) return null;
    if (s.len == 1 and s[0] == '*') return null;
    for (s, out[0..s.len]) |c, *o| o.* = nt.RtlUpcaseUnicodeChar(c);
    return nt.UNICODE_STRING.from(out[0..s.len]);
}

fn matches(expr: ?nt.UNICODE_STRING, name: []const u8) bool {
    const e = expr orelse return true;
    var wide: [names.max]u16 = undefined;
    const n = std.unicode.wtf8ToWtf16Le(&wide, name) catch return false;
    const us = nt.UNICODE_STRING.from(wide[0..n]);
    return nt.RtlIsNameInExpression(&e, &us, 1, null) != 0;
}

fn remaining(listing: *const Listing) bool {
    if (listing.dots != 0) return true;
    for (listing.entries[listing.next..], listing.seen[listing.next..]) |_, s| {
        if (!s) return true;
    }
    return false;
}

/// Drops real entries a virtual file replaces, and notes real folders we'd repeat. Returns the bytes left.
fn hideShadowed(listing: *Listing, layout: Layout, buffer: [*]u8, used: usize) usize {
    var read: usize = 0;
    var write: usize = 0;
    var last: ?usize = null;
    while (read < used) {
        const next = std.mem.readInt(u32, buffer[read..][0..4], .little);
        const len = if (next != 0) next else used - read;
        const name_bytes = std.mem.readInt(u32, buffer[read + layout.name_len ..][0..4], .little);
        const name: []align(1) const u16 = @ptrCast(buffer[read + layout.name ..][0 .. name_bytes & ~@as(u32, 1)]);
        if (!shadowed(listing, name)) {
            if (write != read) std.mem.copyForwards(u8, buffer[write..][0..len], buffer[read..][0..len]);
            std.mem.writeInt(u32, buffer[write..][0..4], @intCast(len), .little);
            last = write;
            write += len;
        }
        if (next == 0) break;
        read += next;
    }
    if (last) |l| {
        std.mem.writeInt(u32, buffer[l..][0..4], 0, .little);
        // The last entry needn't be padded
        return write;
    }
    return 0;
}

fn shadowed(listing: *Listing, name: []align(1) const u16) bool {
    var buf: [names.max]u8 = undefined;
    if (name.len > buf.len / 3) return false;
    var copy: [names.max / 3]u16 = undefined;
    for (name, copy[0..name.len]) |c, *o| o.* = c;
    const n = std.unicode.wtf16LeToWtf8(&buf, copy[0..name.len]);
    for (listing.entries, listing.seen) |e, *s| {
        if (!std.ascii.eqlIgnoreCase(e.name, buf[0..n])) continue;
        if (e.kind == .file) return true;
        s.* = true;
        return false;
    }
    return false;
}

/// Writes what fits of the virtual entries. Returns the bytes used.
fn emit(listing: *Listing, layout: Layout, out: []u8, single: bool) usize {
    var used: usize = 0;
    var last: ?usize = null;
    while (true) {
        var dot_name: ?[]const u8 = null;
        var entry: ?Store.Entry = null;
        if (listing.dots & 1 != 0) {
            dot_name = ".";
        } else if (listing.dots & 2 != 0) {
            dot_name = "..";
        } else {
            while (listing.next < listing.entries.len and listing.seen[listing.next]) listing.next += 1;
            if (listing.next == listing.entries.len) break;
            entry = listing.entries[listing.next];
        }
        const name = dot_name orelse entry.?.name;
        const at = std.mem.alignForward(usize, used, 8);
        const len = writeEntry(layout, out[@min(at, out.len)..], name, entry) orelse break;
        if (last) |l| std.mem.writeInt(u32, out[l..][0..4], @intCast(at - l), .little);
        last = at;
        used = at + len;
        if (dot_name) |d| {
            listing.dots &= if (d.len == 1) 2 else 1;
        } else listing.next += 1;
        if (single) break;
    }
    return used;
}

fn writeEntry(layout: Layout, out: []u8, name: []const u8, entry: ?Store.Entry) ?usize {
    var wide: [names.max]u16 = undefined;
    const n = std.unicode.wtf8ToWtf16Le(&wide, name) catch return null;
    const name_bytes = std.mem.sliceAsBytes(wide[0..n]);
    const len = layout.name + name_bytes.len;
    if (out.len < len) return null;
    @memset(out[0..layout.name], 0);
    if (layout.full) {
        const kind: Store.Kind = if (entry) |e| e.kind else .dir;
        const created: i64 = if (entry) |e| e.created else 0;
        const modified: i64 = if (entry) |e| e.modified else 0;
        const size: u64 = if (entry) |e| e.size else 0;
        std.mem.writeInt(i64, out[8..16], created, .little);
        std.mem.writeInt(i64, out[16..24], modified, .little);
        std.mem.writeInt(i64, out[24..32], modified, .little);
        std.mem.writeInt(i64, out[32..40], modified, .little);
        std.mem.writeInt(i64, out[40..48], @intCast(size), .little);
        std.mem.writeInt(i64, out[48..56], virtual.allocationSize(size), .little);
        std.mem.writeInt(u32, out[56..60], virtual.attributes(kind), .little);
    }
    std.mem.writeInt(u32, out[layout.name_len..][0..4], @intCast(name_bytes.len), .little);
    if (layout.id) |at| {
        const id: u64 = if (entry) |e| (0x7AF5 << 48) | e.id else 0;
        std.mem.writeInt(u64, out[at..][0..8], id, .little);
    }
    @memcpy(out[layout.name..][0..name_bytes.len], name_bytes);
    return len;
}
