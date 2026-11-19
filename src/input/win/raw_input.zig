//! Reads, filters and writes raw input records. Offsets are for 64-bit processes.

const std = @import("std");

const win = @import("tuft_sys").win;
const input = @import("../root.zig");
const Device = input.Device;
const Channels = input.Channels;

pub const RIM_TYPEMOUSE: u32 = 0;
pub const RIM_TYPEKEYBOARD: u32 = 1;
pub const RID_HEADER: u32 = 0x1000_0005;
pub const RID_INPUT: u32 = 0x1000_0003;
pub const RI_KEY_BREAK: u16 = 0x01;
pub const RI_KEY_E0: u16 = 0x02;
pub const RI_KEY_E1: u16 = 0x04;
pub const header_size = 24;
pub const keyboard_size = 40;
pub const mouse_size = 48;
pub const max_record_size = mouse_size;
const failed = std.math.maxInt(u32);

pub const Header = extern struct {
    kind: u32,
    size: u32,
    device: ?*anyopaque,
    wparam: usize,
};

pub fn deviceOf(handle: isize) ?Device {
    var header: Header = undefined;
    var size: u32 = @sizeOf(Header);
    if (win.GetRawInputData(handleOf(handle), RID_HEADER, &header, &size, @sizeOf(Header)) == failed) return null;
    return kindDevice(header.kind);
}

/// Into `buf`, given its lParam.
pub fn read(handle: isize, buf: *align(8) [max_record_size]u8) ?[]const u8 {
    var size: u32 = buf.len;
    const len = win.GetRawInputData(handleOf(handle), RID_INPUT, buf, &size, header_size);
    if (len == failed or len < header_size) return null;
    return buf[0..len];
}

fn handleOf(handle: isize) ?*anyopaque {
    return @ptrFromInt(@as(usize, @bitCast(handle)));
}

fn kindDevice(kind: u32) ?Device {
    return switch (kind) {
        RIM_TYPEMOUSE => .mouse,
        RIM_TYPEKEYBOARD => .keyboard,
        else => null,
    };
}

pub const Records = struct {
    data: [*]u8,
    left: u32,
    offset: usize = 0,

    pub fn next(self: *Records) ?[]u8 {
        if (self.left == 0) return null;
        self.left -= 1;
        const len = std.mem.readInt(u32, self.data[self.offset + 4 ..][0..4], .little);
        defer self.offset = std.mem.alignForward(usize, self.offset + len, 8);
        return self.data[self.offset..][0..len];
    }
};

/// Whether hiding `hidden` leaves nothing, so we drop records instead of editing.
pub fn hidesAll(device: Device, hidden: Channels) bool {
    return switch (device) {
        .keyboard => hidden.contains(.keyboard),
        .mouse => hidden.contains(.mouse_buttons) and hidden.contains(.mouse_motion),
        // Controllers come over raw input as HID, which we don't read
        .gamepad => false,
    };
}

/// Other records are left alone.
pub fn strip(record: []u8, hidden: Channels) void {
    if (record.len < mouse_size or std.mem.readInt(u32, record[0..4], .little) != RIM_TYPEMOUSE) return;
    if (hidden.contains(.mouse_buttons)) @memset(record[28..36], 0); // usButtonFlags, usButtonData, ulRawButtons
    if (hidden.contains(.mouse_motion)) {
        // Zero movement, marked relative. An absolute record would jump to 0,0
        std.mem.writeInt(u16, record[24..26], 0, .little); // usFlags
        @memset(record[36..44], 0); // lLastX, lLastY
    }
}

/// Keeps records packed and aligned. Returns how many are left.
pub fn filter(data: [*]u8, count: u32, hidden: Channels) u32 {
    if (hidden.count() == 0) return count;
    var records: Records = .{ .data = data, .left = count };
    var write: usize = 0;
    var kept: u32 = 0;
    while (records.next()) |record| {
        if (kindDevice(std.mem.readInt(u32, record[0..4], .little))) |device| {
            if (hidesAll(device, hidden)) continue;
            strip(record, hidden);
        }
        if (write != @intFromPtr(record.ptr) - @intFromPtr(data)) std.mem.copyForwards(u8, data[write..][0..record.len], record);
        write = std.mem.alignForward(usize, write + record.len, 8);
        kept += 1;
    }
    return kept;
}

pub const Held = struct {
    keys: std.StaticBitSet(256) = .empty,
    make_code: [256]u16 = @splat(0),
    key_flags: [256]u16 = @splat(0),
    /// Bit i means mouse button i is down.
    buttons: u8 = 0,

    /// Updates from a record about to go to the app.
    pub fn observe(self: *Held, record: []const u8) void {
        if (record.len < header_size) return;
        switch (std.mem.readInt(u32, record[0..4], .little)) {
            RIM_TYPEKEYBOARD => {
                if (record.len < keyboard_size) return;
                const make = std.mem.readInt(u16, record[24..26], .little);
                const flags = std.mem.readInt(u16, record[26..28], .little);
                const vk = std.mem.readInt(u16, record[30..32], .little);
                if (vk == 0 or vk >= 255) return;
                if (flags & RI_KEY_BREAK != 0) {
                    self.keys.unset(vk);
                } else {
                    self.keys.set(vk);
                    self.make_code[vk] = make;
                    self.key_flags[vk] = flags & (RI_KEY_E0 | RI_KEY_E1);
                }
            },
            RIM_TYPEMOUSE => {
                if (record.len < mouse_size) return;
                const button_flags = std.mem.readInt(u16, record[28..30], .little);
                for (0..5) |i| {
                    const bit: u8 = @as(u8, 1) << @intCast(i);
                    if (button_flags & (@as(u16, 1) << @intCast(2 * i)) != 0) self.buttons |= bit;
                    if (button_flags & (@as(u16, 1) << @intCast(2 * i + 1)) != 0) self.buttons &= ~bit;
                }
            },
            else => {},
        }
    }

    pub fn take(self: *Held, devices: std.EnumSet(Device), into: *Held) void {
        if (devices.contains(.keyboard)) {
            var it = self.keys.iterator(.{});
            while (it.next()) |vk| {
                into.keys.set(vk);
                into.make_code[vk] = self.make_code[vk];
                into.key_flags[vk] = self.key_flags[vk];
            }
            self.keys = .empty;
        }
        if (devices.contains(.mouse)) {
            into.buttons |= self.buttons;
            self.buttons = 0;
        }
    }

    pub fn isEmpty(self: *const Held) bool {
        return self.keys.count() == 0 and self.buttons == 0;
    }

    /// Null when there's nothing left.
    pub fn nextRelease(self: *Held, out: *align(8) [max_record_size]u8) ?[]const u8 {
        if (self.buttons != 0) {
            writeMouseUp(out[0..mouse_size], self.buttons);
            self.buttons = 0;
            return out[0..mouse_size];
        }
        const vk = self.keys.findFirstSet() orelse return null;
        self.keys.unset(vk);
        writeKeyUp(out[0..keyboard_size], @intCast(vk), self.make_code[vk], self.key_flags[vk]);
        return out[0..keyboard_size];
    }

    /// The rest stay held for the next read. Returns how many were added.
    pub fn appendReleases(self: *Held, buffer: []u8, used: usize) u32 {
        var offset = std.mem.alignForward(usize, used, 8);
        var added: u32 = 0;
        while (true) {
            const needed: usize = if (self.buttons != 0) mouse_size else if (self.keys.count() != 0) keyboard_size else break;
            if (offset + needed > buffer.len) break;
            var record: [max_record_size]u8 align(8) = undefined;
            const r = self.nextRelease(&record).?;
            @memcpy(buffer[offset..][0..r.len], r);
            offset = std.mem.alignForward(usize, offset + r.len, 8);
            added += 1;
        }
        return added;
    }
};

fn writeHeader(out: []u8, kind: u32) void {
    @memset(out, 0);
    std.mem.writeInt(u32, out[0..4], kind, .little);
    std.mem.writeInt(u32, out[4..8], @intCast(out.len), .little);
}

fn writeKeyUp(out: *[keyboard_size]u8, vk: u16, make: u16, flags: u16) void {
    writeHeader(out, RIM_TYPEKEYBOARD);
    std.mem.writeInt(u16, out[24..26], make, .little);
    std.mem.writeInt(u16, out[26..28], flags | RI_KEY_BREAK, .little);
    std.mem.writeInt(u16, out[30..32], vk, .little);
    std.mem.writeInt(u32, out[32..36], win.WM_KEYUP, .little);
}

fn writeMouseUp(out: *[mouse_size]u8, buttons: u8) void {
    writeHeader(out, RIM_TYPEMOUSE);
    var up: u16 = 0;
    for (0..5) |i| {
        if (buttons & (@as(u8, 1) << @intCast(i)) != 0) up |= @as(u16, 1) << @intCast(2 * i + 1);
    }
    std.mem.writeInt(u16, out[28..30], up, .little);
}

const tests = struct {
    const testing = std.testing;

    fn record(buf: []u8, offset: usize, kind: u32, len: u32, fill: u8) usize {
        std.mem.writeInt(u32, buf[offset..][0..4], kind, .little);
        std.mem.writeInt(u32, buf[offset + 4 ..][0..4], len, .little);
        @memset(buf[offset + 8 .. offset + len], fill);
        return std.mem.alignForward(usize, offset + len, 8);
    }

    test "filter compacts" {
        var buf: [256]u8 = @splat(0);
        var off: usize = 0;
        off = record(&buf, off, RIM_TYPEMOUSE, 48, 0xA1);
        off = record(&buf, off, RIM_TYPEKEYBOARD, 36, 0xB2);
        off = record(&buf, off, RIM_TYPEMOUSE, 48, 0xA3);

        var copy = buf;
        try testing.expectEqual(3, filter(&copy, 3, .empty));

        copy = buf;
        try testing.expectEqual(1, filter(&copy, 3, .initMany(&.{ .mouse_buttons, .mouse_motion })));
        try testing.expectEqual(RIM_TYPEKEYBOARD, std.mem.readInt(u32, copy[0..4], .little));
        try testing.expectEqual(0xB2, copy[35]);

        copy = buf;
        try testing.expectEqual(2, filter(&copy, 3, .initOne(.keyboard)));
        try testing.expectEqual(0xA1, copy[47]);
        try testing.expectEqual(RIM_TYPEMOUSE, std.mem.readInt(u32, copy[48..52], .little));
        try testing.expectEqual(0xA3, copy[95]);
    }

    test "strip clicks only" {
        var buf: [256]u8 = @splat(0);
        _ = record(&buf, 0, RIM_TYPEMOUSE, 48, 0xA1);
        _ = record(&buf, 48, RIM_TYPEKEYBOARD, 40, 0xB2);

        try testing.expectEqual(2, filter(&buf, 2, .initOne(.mouse_buttons)));
        try testing.expectEqualSlices(u8, &@as([8]u8, @splat(0)), buf[28..36]); // buttons, wheel
        try testing.expectEqualSlices(u8, &@as([8]u8, @splat(0xA1)), buf[36..44]); // movement
        try testing.expectEqual(0xB2, buf[48 + 39]); // keyboard untouched

        strip(buf[0..48], .initOne(.mouse_motion));
        try testing.expectEqualSlices(u8, &@as([8]u8, @splat(0)), buf[36..44]);
    }

    test "held and release records" {
        var held: Held = .{};
        var r: [max_record_size]u8 align(8) = undefined;
        writeHeader(r[0..keyboard_size], RIM_TYPEKEYBOARD);
        std.mem.writeInt(u16, r[24..26], 0x1E, .little);
        std.mem.writeInt(u16, r[26..28], RI_KEY_E0, .little);
        std.mem.writeInt(u16, r[30..32], 'A', .little);
        held.observe(r[0..keyboard_size]);
        writeHeader(r[0..mouse_size], RIM_TYPEMOUSE);
        std.mem.writeInt(u16, r[28..30], 0x0001 | 0x0004, .little); // left and right down
        held.observe(r[0..mouse_size]);
        std.mem.writeInt(u16, r[28..30], 0x0008, .little); // right up
        held.observe(r[0..mouse_size]);
        try testing.expect(held.keys.isSet('A') and held.buttons == 0b001);

        var release: Held = .{};
        held.take(.initOne(.keyboard), &release);
        try testing.expect(held.keys.count() == 0 and held.buttons == 0b001);

        const up = release.nextRelease(&r).?;
        try testing.expectEqual(keyboard_size, up.len);
        try testing.expectEqual('A', std.mem.readInt(u16, up[30..32], .little));
        try testing.expectEqual(0x1E, std.mem.readInt(u16, up[24..26], .little));
        try testing.expectEqual(RI_KEY_E0 | RI_KEY_BREAK, std.mem.readInt(u16, up[26..28], .little));
        try testing.expectEqual(null, release.nextRelease(&r));
    }

    test "appendReleases partial" {
        var pending: Held = .{};
        pending.keys.set('S');
        pending.keys.set('W');
        pending.make_code['W'] = 0x11;
        pending.buttons = 0b001;

        var buf: [128]u8 = @splat(0xEE);
        // The game's records used 30 bytes, so ours start at 32
        try testing.expectEqual(2, pending.appendReleases(&buf, 30));
        try testing.expectEqual(RIM_TYPEMOUSE, std.mem.readInt(u32, buf[32..36], .little));
        try testing.expectEqual(0x0002, std.mem.readInt(u16, buf[60..62], .little)); // left button up
        try testing.expectEqual(RIM_TYPEKEYBOARD, std.mem.readInt(u32, buf[80..84], .little));
        try testing.expectEqual('S', std.mem.readInt(u16, buf[110..112], .little));

        try testing.expect(pending.keys.isSet('W') and !pending.keys.isSet('S') and pending.buttons == 0);
        try testing.expectEqual(1, pending.appendReleases(&buf, 0));
        try testing.expectEqual('W', std.mem.readInt(u16, buf[30..32], .little));
        try testing.expectEqual(0x11, std.mem.readInt(u16, buf[24..26], .little));
        try testing.expect(pending.isEmpty());
    }
};

test {
    _ = tests;
}
