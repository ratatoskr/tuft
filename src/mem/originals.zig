//! Copies of code from before any hooks: an early snapshot and the file on disk. One provider per copy per DLL.

const std = @import("std");

const Memory = @import("Memory.zig");

/// Which copy of memory an address was worked out from.
pub const AddressSource = enum(u8) {
    /// Memory as it is now.
    live,
    /// Code copied early, before most hooks went in.
    snapshot,
    /// The module's file on disk, laid out like it's loaded.
    disk,

    /// Tried in this order.
    pub const order = [_]AddressSource{ .live, .snapshot, .disk };
};

/// Which copies a lookup may use, tried live first, then the snapshot, then disk.
pub const Sources = bitpack struct(u8) {
    live: bool = true,
    snapshot: bool = true,
    disk: bool = true,
    _pad: u5 = 0,

    pub const all: Sources = .{};
    pub const live_only: Sources = .{ .snapshot = false, .disk = false };

    pub fn only(source: AddressSource) Sources {
        var s: Sources = .{ .live = false, .snapshot = false, .disk = false };
        s.set(source, true);
        return s;
    }

    pub fn has(self: Sources, source: AddressSource) bool {
        return switch (source) {
            .live => self.live,
            .snapshot => self.snapshot,
            .disk => self.disk,
        };
    }

    pub fn set(self: *Sources, source: AddressSource, on: bool) void {
        switch (source) {
            .live => self.live = on,
            .snapshot => self.snapshot = on,
            .disk => self.disk = on,
        }
    }

    pub fn none(self: Sources) bool {
        return !self.live and !self.snapshot and !self.disk;
    }

    /// Like `Sources(Live, Disk)`.
    pub fn format(self: Sources, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeAll("Sources(");
        var first = true;
        for (AddressSource.order) |s| if (self.has(s)) {
            if (!first) try w.writeAll(", ");
            first = false;
            try w.writeAll(label(s));
        };
        try w.writeByte(')');
    }
};

/// As it's written in sigs, like `Disk`.
pub fn label(source: AddressSource) []const u8 {
    return switch (source) {
        .live => "Live",
        .snapshot => "Snapshot",
        .disk => "Disk",
    };
}

/// From how it's written in sigs, like `Disk`.
pub fn parseLabel(text: []const u8) ?AddressSource {
    for (AddressSource.order) |s| if (std.mem.eql(u8, text, label(s))) return s;
    return null;
}

/// The range has to sit in one copied section.
pub const Provider = *const fn (start: usize, len: usize) ?[*]const u8;

var providers: [2]std.atomic.Value(?Provider) = .{ .init(null), .init(null) };

fn slot(source: AddressSource) ?*std.atomic.Value(?Provider) {
    return switch (source) {
        .live => null,
        .snapshot => &providers[0],
        .disk => &providers[1],
    };
}

/// Returns the old one. Thread-safe. Live memory has none.
pub fn setProvider(source: AddressSource, new: ?Provider) ?Provider {
    const s = slot(source) orelse return null;
    return s.swap(new, .acq_rel);
}

/// `source`'s copy of `start..start+len`. Null for live memory, or if there's no copy of all of it.
pub fn find(source: AddressSource, start: usize, len: usize) ?[]const u8 {
    const s = slot(source) orelse return null;
    const p = s.load(.acquire) orelse return null;
    const copy = p(start, len) orelse return null;
    return copy[0..len];
}

/// The earliest copy there is, snapshot then disk.
pub fn earliest(start: usize, len: usize) ?[]const u8 {
    return find(.snapshot, start, len) orelse find(.disk, start, len);
}

/// `source`'s copy as read-only memory, for views. Null for live memory.
pub fn memory(source: AddressSource) ?Memory {
    return switch (source) {
        .live => null,
        .snapshot => .{ .vtable = &CopyMemory(.snapshot).vtable },
        .disk => .{ .vtable = &CopyMemory(.disk).vtable },
    };
}

fn CopyMemory(comptime source: AddressSource) type {
    return struct {
        const vtable: Memory.VTable = .{ .read = read, .direct = direct };

        fn read(_: ?*anyopaque, address: usize, out: []u8) Memory.Error!void {
            const copy = find(source, address, out.len) orelse return error.Unreadable;
            @memcpy(out, copy);
        }

        fn direct(_: ?*anyopaque, address: usize, len: usize) ?[]const u8 {
            return find(source, address, len);
        }
    };
}

test "sources" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Sources(Live, Disk)", try std.fmt.bufPrint(&buf, "{f}", .{Sources{ .snapshot = false }}));
    try std.testing.expect(Sources.only(.disk).has(.disk) and !Sources.only(.disk).has(.live));
    try std.testing.expectEqual(.snapshot, parseLabel("Snapshot").?);
    try std.testing.expectEqual(null, find(.live, 0, 1));
}

test "copies read as memory" {
    const Copy = struct {
        const bytes = [_]u8{ 1, 2, 3, 4 };
        fn provide(start: usize, len: usize) ?[*]const u8 {
            if (start < 0x1000 or start + len > 0x1000 + bytes.len) return null;
            return bytes[start - 0x1000 ..].ptr;
        }
    };
    const previous = setProvider(.disk, Copy.provide);
    defer _ = setProvider(.disk, previous);
    const disk = memory(.disk).?;
    try std.testing.expectEqual(0x0302, try disk.load(u16, 0x1001));
    try std.testing.expectError(error.Unreadable, disk.load(u32, 0x1002));
    try std.testing.expectError(error.Unwritable, disk.store(u8, 0x1000, 9));
    try std.testing.expectEqual(null, memory(.live));
}
