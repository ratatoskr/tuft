//! DirectInput 8 support for `Blocker`.
//! Mice with a custom data layout get hidden entirely while their buttons are.

const DInput = @This();

const std = @import("std");

const hook = @import("tuft_hook");
const sys = @import("tuft_sys");
const win = sys.win;

const Win32 = @import("blocker.zig");
const Devices = @import("../root.zig").Devices;
const Channels = @import("../root.zig").Channels;

const log = std.log.scoped(.tuft_input);

const HRESULT = i32;

pub const Guid = extern struct {
    data1: u32,
    data2: u16,
    data3: u16,
    data4: [8]u8,
};

const IID_IDirectInput8A: Guid = .{ .data1 = 0xBF798030, .data2 = 0x483A, .data3 = 0x4DA2, .data4 = .{ 0xAA, 0x99, 0x5D, 0x64, 0xED, 0x36, 0x97, 0x00 } };
const IID_IDirectInput8W: Guid = .{ .data1 = 0xBF798031, .data2 = 0x483A, .data3 = 0x4DA2, .data4 = .{ 0xAA, 0x99, 0x5D, 0x64, 0xED, 0x36, 0x97, 0x00 } };
pub const GUID_SysMouse: Guid = .{ .data1 = 0x6F1D2B60, .data2 = 0xD5A0, .data3 = 0x11CF, .data4 = .{ 0xBF, 0xC7, 0x44, 0x45, 0x53, 0x54, 0x00, 0x00 } };
pub const GUID_SysKeyboard: Guid = .{ .data1 = 0x6F1D2B61, .data2 = 0xD5A0, .data3 = 0x11CF, .data4 = .{ 0xBF, 0xC7, 0x44, 0x45, 0x53, 0x54, 0x00, 0x00 } };
const DIRECTINPUT_VERSION = 0x0800;

pub const Device = opaque {};
pub const DirectInput = opaque {};

pub const DirectInput8CreateFn = fn (instance: usize, version: u32, iid: *const Guid, out: *?*DirectInput, outer: ?*anyopaque) callconv(.winapi) HRESULT;
pub const CreateDeviceFn = fn (self: *DirectInput, guid: *const Guid, out: *?*Device, outer: ?*anyopaque) callconv(.winapi) HRESULT;
const ReleaseFn = fn (self: *anyopaque) callconv(.winapi) u32;
const GetCapabilitiesFn = fn (self: *Device, caps: *DevCaps) callconv(.winapi) HRESULT;
pub const GetDeviceStateFn = fn (self: *Device, size: u32, data: ?*anyopaque) callconv(.winapi) HRESULT;
pub const GetDeviceDataFn = fn (self: *Device, object_size: u32, data: ?[*]u8, count: *u32, flags: u32) callconv(.winapi) HRESULT;

pub const release_index = 2;
pub const create_device_index = 3;
const get_capabilities_index = 3;
pub const get_device_state_index = 9;
pub const get_device_data_index = 10;

const DevCaps = extern struct {
    size: u32 = @sizeOf(DevCaps),
    flags: u32 = 0,
    dev_type: u32 = 0,
    axes: u32 = 0,
    buttons: u32 = 0,
    povs: u32 = 0,
    ff_sample_period: u32 = 0,
    ff_min_time_resolution: u32 = 0,
    firmware_revision: u32 = 0,
    hardware_revision: u32 = 0,
    ff_driver_version: u32 = 0,
};

const DIDGDD_PEEK = 1;

pub fn vtableEntry(object: *anyopaque, index: usize) usize {
    const vtable: *const [*]const usize = @ptrCast(@alignCast(object));
    return vtable.*[index];
}

fn method(comptime F: type, object: anytype, index: usize) *const F {
    return @ptrFromInt(vtableEntry(object, index));
}

pub const Kind = enum { mouse, keyboard, other };

fn kindOf(device: *Device) Kind {
    var caps: DevCaps = .{};
    if (method(GetCapabilitiesFn, device, get_capabilities_index)(device, &caps) < 0) return .other;
    return switch (caps.dev_type & 0xFF) {
        0x12, 0x02 => .mouse, // DI8DEVTYPE_MOUSE, DIDEVTYPE_MOUSE
        0x13, 0x03 => .keyboard, // DI8DEVTYPE_KEYBOARD, DIDEVTYPE_KEYBOARD
        else => .other,
    };
}

pub const Methods = struct {
    get_device_state: hook.set.Addresses = .{},
    get_device_data: hook.set.Addresses = .{},
};

pub fn findMethods() !Methods {
    const dinput8 = try sys.module.systemBase("dinput8.dll");
    const create_address = sys.module.findExport(dinput8, "DirectInput8Create") orelse return error.MissingExport;
    const create_fn: *const DirectInput8CreateFn = @ptrFromInt(create_address);
    var methods: Methods = .{};
    for ([_]*const Guid{ &IID_IDirectInput8A, &IID_IDirectInput8W }) |iid| {
        var di: ?*DirectInput = null;
        if (create_fn(sys.module.mainBase(), DIRECTINPUT_VERSION, iid, &di, null) < 0) continue;
        defer _ = method(ReleaseFn, di.?, release_index)(di.?);
        for ([_]*const Guid{ &GUID_SysMouse, &GUID_SysKeyboard }) |guid| {
            var device: ?*Device = null;
            if (method(CreateDeviceFn, di.?, create_device_index)(di.?, guid, &device, null) < 0) continue;
            defer _ = method(ReleaseFn, device.?, release_index)(device.?);
            methods.get_device_state.add(vtableEntry(device.?, get_device_state_index));
            methods.get_device_data.add(vtableEntry(device.?, get_device_data_index));
        }
    }
    if (methods.get_device_state.len == 0) return error.CreateDeviceFailed;
    return methods;
}

owner: *Win32,
state_hooks: hook.set.HookSet(GetDeviceStateFn) = .{},
data_hooks: hook.set.HookSet(GetDeviceDataFn) = .{},
/// Plus releases waiting for its next read.
lock: Win32.SpinLock = .{},
held: Held = .{},
pending: Held = .{},

/// Mouse buttons by `DIMOFS_BUTTON` index, keys by DIK code.
pub const Held = struct {
    buttons: std.StaticBitSet(8) = .empty,
    keys: std.StaticBitSet(256) = .empty,

    fn take(self: *Held, devices: Devices, into: *Held) void {
        if (devices.contains(.mouse)) {
            into.buttons.setUnion(self.buttons);
            self.buttons = .empty;
        }
        if (devices.contains(.keyboard)) {
            into.keys.setUnion(self.keys);
            self.keys = .empty;
        }
    }
};

/// Hooks come back enabled.
pub fn create(allocator: std.mem.Allocator, owner: *Win32) !*DInput {
    const methods = try findMethods();
    const self = try allocator.create(DInput);
    errdefer allocator.destroy(self);
    self.* = .{ .owner = owner };
    errdefer self.destroyHooks();
    try self.state_hooks.create(&methods.get_device_state, getDeviceState, self);
    try self.data_hooks.create(&methods.get_device_data, getDeviceData, self);
    try self.state_hooks.enable();
    try self.data_hooks.enable();
    return self;
}

/// Waits for calls in flight.
pub fn destroy(self: *DInput, allocator: std.mem.Allocator) void {
    self.destroyHooks();
    allocator.destroy(self);
}

fn destroyHooks(self: *DInput) void {
    self.state_hooks.destroy();
    self.data_hooks.destroy();
}

/// Whether `device`'s methods are where they were on the probe devices.
pub fn covers(self: *const DInput, device: *Device) bool {
    return self.state_hooks.covers(vtableEntry(device, get_device_state_index)) and
        self.data_hooks.covers(vtableEntry(device, get_device_data_index));
}

/// Released on its next `GetDeviceData`.
pub fn release(self: *DInput, devices: Devices) void {
    self.lock.lock();
    defer self.lock.unlock();
    self.held.take(devices, &self.pending);
}

const Hidden = struct {
    channels: Channels,
    owner: *const Win32,

    fn key(self: Hidden, dik: u8) bool {
        if (self.channels.contains(.keyboard)) return true;
        if (!self.owner.anyKeyHidden() or @import("../Blocker.zig").isBypassing()) return false;
        const scan: u32 = (dik & 0x7F) | (if (dik & 0x80 != 0) @as(u32, 0xE000) else 0);
        const vk = win.MapVirtualKeyW(scan, 3); // MAPVK_VSC_TO_VK_EX
        return vk != 0 and vk < 256 and self.owner.isVkHidden(@intCast(vk));
    }

    fn none(self: Hidden) bool {
        return self.channels.count() == 0 and !self.owner.anyKeyHidden();
    }
};

fn hiddenNow(self: *const DInput) Hidden {
    return .{ .channels = self.owner.blocker.hidden(), .owner = self.owner };
}

// Hooks

fn getDeviceState(self: *DInput, h: *hook.TypedHook(GetDeviceStateFn), device: *Device, size: u32, data: ?*anyopaque) HRESULT {
    const result = h.original()(device, size, data);
    if (result < 0) return result;
    const out = data orelse return result;
    const hidden = self.hiddenNow();
    if (hidden.none()) return result;
    stripState(kindOf(device), @as([*]u8, @ptrCast(out))[0..size], hidden);
    return result;
}

fn getDeviceData(self: *DInput, h: *hook.TypedHook(GetDeviceDataFn), device: *Device, object_size: u32, data: ?[*]u8, count: *u32, flags: u32) HRESULT {
    const capacity = count.*;
    const result = h.original()(device, object_size, data, count, flags);
    if (result < 0 or object_size < event_size) return result;
    const buffer = data orelse return result;
    const kind = kindOf(device);
    if (kind == .other) return result;

    const events = buffer[0 .. @as(usize, capacity) * object_size];
    var kept = filterEvents(kind, events, object_size, count.*, self.hiddenNow());

    self.lock.lock();
    defer self.lock.unlock();
    for (0..kept) |i| observe(&self.held, kind, events[i * object_size ..][0..event_size]);
    if (flags & DIDGDD_PEEK == 0) kept = appendReleases(&self.pending, kind, events, object_size, kept, capacity);
    count.* = kept;
    return result;
}

// Filtering, on the game's buffers

/// X, Y and the wheel as i32s, then 4 or 8 buttons.
const mouse_wheel = 8;
const mouse_buttons = 12;

pub fn stripState(kind: Kind, state: []u8, hidden: Hidden) void {
    switch (kind) {
        .mouse => {
            const standard = state.len == 16 or state.len == 20;
            if (!standard) {
                if (hidden.channels.contains(.mouse_buttons)) @memset(state, 0);
                return;
            }
            if (hidden.channels.contains(.mouse_motion)) @memset(state[0..mouse_wheel], 0);
            if (hidden.channels.contains(.mouse_buttons)) @memset(state[mouse_wheel..], 0);
        },
        .keyboard => {
            if (state.len != 256) {
                if (hidden.channels.contains(.keyboard)) @memset(state, 0);
                return;
            }
            for (state, 0..) |*key, dik| {
                if (key.* != 0 and hidden.key(@intCast(dik))) key.* = 0;
            }
        },
        .other => {},
    }
}

/// Offset, data, time stamp and sequence. `uAppData` may follow.
const event_size = 16;

fn eventField(event: []const u8, index: usize) u32 {
    return std.mem.readInt(u32, event[index * 4 ..][0..4], .little);
}

fn hidesEvent(kind: Kind, offset: u32, hidden: Hidden) bool {
    return switch (kind) {
        .mouse => if (offset < mouse_wheel)
            hidden.channels.contains(.mouse_motion)
        else
            hidden.channels.contains(.mouse_buttons),
        .keyboard => offset < 256 and hidden.key(@intCast(offset)),
        .other => false,
    };
}

/// Keeps the rest in order. Returns how many are left.
pub fn filterEvents(kind: Kind, events: []u8, object_size: u32, count: u32, hidden: Hidden) u32 {
    if (hidden.none()) return count;
    var kept: u32 = 0;
    for (0..count) |i| {
        const event = events[i * object_size ..][0..object_size];
        if (hidesEvent(kind, eventField(event, 0), hidden)) continue;
        if (kept != i) @memmove(events[kept * object_size ..][0..object_size], event);
        kept += 1;
    }
    return kept;
}

fn observe(held: *Held, kind: Kind, event: []const u8) void {
    const offset = eventField(event, 0);
    const down = eventField(event, 1) & 0x80 != 0;
    switch (kind) {
        .mouse => if (offset >= mouse_buttons and offset < mouse_buttons + 8) held.buttons.setValue(offset - mouse_buttons, down),
        .keyboard => if (offset < 256) held.keys.setValue(offset, down),
        .other => {},
    }
}

/// Adds up events for `pending` as room allows. Returns the new count.
pub fn appendReleases(pending: *Held, kind: Kind, events: []u8, object_size: u32, count: u32, capacity: u32) u32 {
    var n = count;
    const sequence = if (count != 0) eventField(events[(count - 1) * object_size ..], 3) else 0;
    const time: u32 = @truncate(win.GetTickCount64());
    switch (kind) {
        .mouse => while (n < capacity) {
            const button = pending.buttons.toggleFirstSet() orelse break;
            writeEvent(events[n * object_size ..][0..object_size], @intCast(mouse_buttons + button), time, sequence);
            n += 1;
        },
        .keyboard => while (n < capacity) {
            const key = pending.keys.toggleFirstSet() orelse break;
            writeEvent(events[n * object_size ..][0..object_size], @intCast(key), time, sequence);
            n += 1;
        },
        .other => {},
    }
    return n;
}

fn writeEvent(event: []u8, offset: u32, time: u32, sequence: u32) void {
    @memset(event, 0);
    std.mem.writeInt(u32, event[0..4], offset, .little);
    std.mem.writeInt(u32, event[8..12], time, .little);
    std.mem.writeInt(u32, event[12..16], sequence, .little);
}

const tests = struct {
    const testing = std.testing;

    fn event(buf: []u8, offset: u32, data: u32, sequence: u32) void {
        @memset(buf, 0);
        std.mem.writeInt(u32, buf[0..4], offset, .little);
        std.mem.writeInt(u32, buf[4..8], data, .little);
        std.mem.writeInt(u32, buf[12..16], sequence, .little);
    }

    fn hiding(owner: *Win32, channels: Channels) Hidden {
        return .{ .channels = channels, .owner = owner };
    }

    test "mouse state idle" {
        var owner: Win32 = undefined;
        owner.hidden_keys = @splat(.init(0));
        const full: [20]u8 = @splat(0x7F);
        var state = full;
        stripState(.mouse, &state, hiding(&owner, .initOne(.mouse_buttons)));
        try testing.expectEqualSlices(u8, full[0..8], state[0..8]); // X, Y
        try testing.expectEqualSlices(u8, &@as([12]u8, @splat(0)), state[8..]); // wheel, buttons
        state = full;
        stripState(.mouse, &state, hiding(&owner, .initOne(.mouse_motion)));
        try testing.expectEqualSlices(u8, &@as([8]u8, @splat(0)), state[0..8]);
        try testing.expectEqualSlices(u8, full[8..], state[8..]);
    }

    test "keyboard state up" {
        var owner: Win32 = undefined;
        owner.hidden_keys = @splat(.init(0));
        var state: [256]u8 = @splat(0x80);
        stripState(.keyboard, &state, hiding(&owner, .initOne(.keyboard)));
        try testing.expectEqualSlices(u8, &@as([256]u8, @splat(0)), &state);

        owner.setKeyHidden(.a, true);
        state = @splat(0x80);
        stripState(.keyboard, &state, hiding(&owner, .empty));
        const dik_a = 0x1E;
        const dik_s = 0x1F;
        try testing.expectEqual(0, state[dik_a]);
        try testing.expectEqual(0x80, state[dik_s]);
    }

    test "buffered reads filtered" {
        var owner: Win32 = undefined;
        owner.hidden_keys = @splat(.init(0));
        const size = 24; // with uAppData, as on x64
        var events: [4 * size]u8 = undefined;
        event(events[0..size], 0, 5, 1); // X
        event(events[size..][0..size], mouse_buttons, 0x80, 2); // left down
        event(events[2 * size ..][0..size], mouse_wheel, 120, 3); // wheel

        var held: Held = .{};
        try testing.expectEqual(3, filterEvents(.mouse, &events, size, 3, hiding(&owner, .empty)));
        for (0..3) |i| observe(&held, .mouse, events[i * size ..][0..size]);
        try testing.expect(held.buttons.isSet(0));

        // Only the movement is left, then the held button gets released
        const kept = filterEvents(.mouse, &events, size, 3, hiding(&owner, .initOne(.mouse_buttons)));
        try testing.expectEqual(1, kept);
        try testing.expectEqual(0, eventField(events[0..size], 0));
        var pending: Held = .{};
        held.take(.initOne(.mouse), &pending);
        try testing.expectEqual(2, appendReleases(&pending, .mouse, &events, size, kept, 4));
        try testing.expectEqual(mouse_buttons, eventField(events[size..][0..size], 0));
        try testing.expectEqual(0, eventField(events[size..][0..size], 1)); // up
        try testing.expectEqual(1, eventField(events[size..][0..size], 3)); // in sequence
        try testing.expectEqual(0, pending.buttons.count());
    }

    test "all devices hooked" {
        try hook.init(testing.allocator);
        defer hook.deinit();
        var owner: Win32 = undefined;
        owner.hidden_keys = @splat(.init(0));
        const self = try create(testing.allocator, &owner);
        defer self.destroy(testing.allocator);

        const dinput8 = try sys.module.systemBase("dinput8.dll");
        const create_fn: *const DirectInput8CreateFn = @ptrFromInt(sys.module.findExport(dinput8, "DirectInput8Create").?);
        var di: ?*DirectInput = null;
        try testing.expect(create_fn(sys.module.mainBase(), DIRECTINPUT_VERSION, &IID_IDirectInput8A, &di, null) >= 0);
        defer _ = method(ReleaseFn, di.?, release_index)(di.?);
        var device: ?*Device = null;
        try testing.expect(method(CreateDeviceFn, di.?, create_device_index)(di.?, &GUID_SysMouse, &device, null) >= 0);
        defer _ = method(ReleaseFn, device.?, release_index)(device.?);

        try testing.expect(self.covers(device.?));
        try testing.expectEqual(Kind.mouse, kindOf(device.?));
    }
};

test {
    _ = tests;
}
