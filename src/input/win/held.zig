//! Tracks what a window thinks is held so we can release it when taking a device away.

const std = @import("std");

const win = @import("tuft_sys").win;
const raw_input = @import("raw_input.zig");
const Message = @import("tuft_window").Message;
const Device = @import("../root.zig").Device;
const Devices = std.EnumSet(Device);

const KeySet = std.StaticBitSet(256);

pub const Held = struct {
    /// By virtual-key code.
    keys: KeySet = .empty,
    /// So they get released as WM_SYSKEYUP.
    sys_keys: KeySet = .empty,
    /// Client coords like lParam.
    mouse_lparam: isize = 0,
    raw: raw_input.Held = .{},

    /// Call when a message is about to go to the window.
    pub fn observe(self: *Held, m: *const Message) void {
        switch (m.msg) {
            win.WM_INPUT => {
                var buf: [raw_input.max_record_size]u8 align(8) = undefined;
                if (raw_input.read(m.lparam, &buf)) |record| self.raw.observe(record);
            },
            win.WM_KEYDOWN, win.WM_SYSKEYDOWN => {
                const vk = m.wparam & 0xFF;
                self.keys.set(vk);
                self.sys_keys.setValue(vk, m.msg == win.WM_SYSKEYDOWN);
            },
            win.WM_KEYUP, win.WM_SYSKEYUP => self.keys.unset(m.wparam & 0xFF),
            win.WM_MOUSEMOVE => self.mouse_lparam = m.lparam,
            else => if (mouseButton(m.msg, m.wparam)) |b| {
                self.mouse_lparam = m.lparam;
                self.keys.setValue(b.vk, b.down);
            },
        }
    }

    /// Forgets what's held on `devices` and returns it for releasing.
    pub fn take(self: *Held, devices: Devices) Release {
        var release: Release = .{ .mouse_lparam = self.mouse_lparam };
        var it = self.keys.iterator(.{});
        while (it.next()) |vk| {
            if (!devices.contains(if (isMouseButton(@intCast(vk))) .mouse else .keyboard)) continue;
            release.keys.set(vk);
            release.sys_keys.setValue(vk, self.sys_keys.isSet(vk));
        }
        self.keys.setIntersection(release.keys.complement());
        self.raw.take(devices, &release.raw);
        return release;
    }
};

pub const Release = struct {
    keys: KeySet = .empty,
    sys_keys: KeySet = .empty,
    mouse_lparam: isize = 0,
    raw: raw_input.Held = .{},

    pub const Item = union(enum) {
        message: struct { msg: u32, wparam: usize, lparam: isize },
        /// Needs a handle that `GetRawInputData` resolves to this record.
        raw: []const u8,
    };

    pub fn isEmpty(self: *const Release) bool {
        return self.keys.count() == 0 and self.raw.isEmpty();
    }

    /// A `.raw` item points into `buf`.
    pub fn next(self: *Release, buf: *align(8) [raw_input.max_record_size]u8) ?Item {
        if (self.keys.findFirstSet()) |vk| {
            self.keys.unset(vk);
            if (buttonUp(@intCast(vk))) |up| return .{ .message = .{ .msg = up.msg, .wparam = up.wparam, .lparam = self.mouse_lparam } };
            const msg: u32 = if (self.sys_keys.isSet(vk)) win.WM_SYSKEYUP else win.WM_KEYUP;
            return .{ .message = .{ .msg = msg, .wparam = vk, .lparam = keyUpLparam(@intCast(vk)) } };
        }
        return .{ .raw = self.raw.nextRelease(buf) orelse return null };
    }
};

pub fn isMouseButton(vk: u8) bool {
    return switch (vk) {
        0x01, 0x02, 0x04, 0x05, 0x06 => true, // VK_LBUTTON, RBUTTON, MBUTTON, XBUTTON1, XBUTTON2
        else => false,
    };
}

fn mouseButton(msg: u32, wparam: usize) ?struct { vk: u8, down: bool } {
    const x: u8 = if ((wparam >> 16) & 0xFFFF == 1) 0x05 else 0x06;
    return switch (msg) {
        win.WM_LBUTTONDOWN, win.WM_LBUTTONDBLCLK => .{ .vk = 0x01, .down = true },
        win.WM_LBUTTONUP => .{ .vk = 0x01, .down = false },
        win.WM_RBUTTONDOWN, win.WM_RBUTTONDBLCLK => .{ .vk = 0x02, .down = true },
        win.WM_RBUTTONUP => .{ .vk = 0x02, .down = false },
        win.WM_MBUTTONDOWN, win.WM_MBUTTONDBLCLK => .{ .vk = 0x04, .down = true },
        win.WM_MBUTTONUP => .{ .vk = 0x04, .down = false },
        win.WM_XBUTTONDOWN, win.WM_XBUTTONDBLCLK => .{ .vk = x, .down = true },
        win.WM_XBUTTONUP => .{ .vk = x, .down = false },
        else => null,
    };
}

fn buttonUp(vk: u8) ?struct { msg: u32, wparam: usize } {
    return switch (vk) {
        0x01 => .{ .msg = win.WM_LBUTTONUP, .wparam = 0 },
        0x02 => .{ .msg = win.WM_RBUTTONUP, .wparam = 0 },
        0x04 => .{ .msg = win.WM_MBUTTONUP, .wparam = 0 },
        0x05 => .{ .msg = win.WM_XBUTTONUP, .wparam = 1 << 16 },
        0x06 => .{ .msg = win.WM_XBUTTONUP, .wparam = 2 << 16 },
        else => null,
    };
}

/// Repeat 1, scan code, extended flag, was down, now up.
fn keyUpLparam(vk: u8) isize {
    const scan = win.MapVirtualKeyW(vk, 4); // MAPVK_VK_TO_VSC_EX
    var lparam: u32 = 1 | ((scan & 0xFF) << 16) | (1 << 30) | (1 << 31);
    if (scan & 0xFF00 == 0xE000) lparam |= 1 << 24;
    return @bitCast(@as(usize, lparam));
}

const tests = struct {
    const testing = std.testing;

    fn observe(held: *Held, msg: u32, wparam: usize, lparam: isize) void {
        held.observe(&.{ .window = undefined, .msg = msg, .wparam = wparam, .lparam = lparam });
    }

    test "releases held per device" {
        var held: Held = .{};
        observe(&held, win.WM_KEYDOWN, 'W', 0);
        observe(&held, win.WM_SYSKEYDOWN, 0x12, 0);
        observe(&held, win.WM_KEYDOWN, 'Q', 0);
        observe(&held, win.WM_KEYUP, 'Q', 0);
        observe(&held, win.WM_RBUTTONDOWN, 0, 0x0014_000A);
        held.raw.keys.set('A');
        held.raw.make_code['A'] = 0x1E;

        var buf: [raw_input.max_record_size]u8 align(8) = undefined;
        var kb = held.take(.initOne(.keyboard));
        const alt = kb.next(&buf).?.message;
        try testing.expectEqual(win.WM_SYSKEYUP, alt.msg);
        try testing.expectEqual(0x12, alt.wparam);
        const w = kb.next(&buf).?.message;
        try testing.expectEqual(win.WM_KEYUP, w.msg);
        try testing.expectEqual('W', w.wparam);
        const bits: usize = @bitCast(w.lparam);
        try testing.expect(bits & (1 << 31) != 0 and bits & (1 << 30) != 0);
        const raw = kb.next(&buf).?.raw;
        try testing.expectEqual('A', std.mem.readInt(u16, raw[30..32], .little));
        try testing.expectEqual(null, kb.next(&buf));

        var mouse = held.take(.initOne(.mouse));
        const right = mouse.next(&buf).?.message;
        try testing.expectEqual(win.WM_RBUTTONUP, right.msg);
        try testing.expectEqual(0x0014_000A, right.lparam);
        try testing.expectEqual(null, mouse.next(&buf));

        var rest = held.take(.full);
        try testing.expect(rest.isEmpty());
    }
};

test {
    _ = tests;
}
