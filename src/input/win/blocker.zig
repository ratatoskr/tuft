//! Windows backend for `Blocker`. Hides captured input from the APIs games poll.

const Win32 = @This();

const std = @import("std");
const tuft_arch = @import("tuft_arch");

const tuft_event = @import("tuft_event");
const tuft_window = @import("tuft_window");
const hook = @import("tuft_hook");
const memory = hook.memory;

const Blocker = @import("../Blocker.zig");
const Window = @import("../Window.zig");

const sys = @import("tuft_sys");
const win = sys.win;
const raw_input = @import("raw_input.zig");
const DInput = @import("dinput.zig");
const XInput = @import("xinput.zig");
const Held = @import("held.zig").Held;
const Device = @import("../root.zig").Device;
const Devices = @import("../root.zig").Devices;
const Channels = @import("../root.zig").Channels;
const PadButton = @import("../root.zig").PadButton;
const PadButtons = @import("../root.zig").PadButtons;

const log = std.log.scoped(.tuft_input);

const KeyStateFn = fn (vk: i32) callconv(.winapi) i16;
const KeyboardStateFn = fn (state: *[256]u8) callconv(.winapi) win.BOOL;
const GetCursorPosFn = fn (point: *win.POINT) callconv(.winapi) win.BOOL;
const SetCursorPosFn = fn (x: i32, y: i32) callconv(.winapi) win.BOOL;
const ClipCursorFn = fn (rect: ?*const win.RECT) callconv(.winapi) win.BOOL;
const RawInputDataFn = fn (handle: ?*anyopaque, command: u32, data: ?*anyopaque, size: *u32, header_size: u32) callconv(.winapi) u32;
const RawInputBufferFn = fn (data: ?[*]u8, size: *u32, header_size: u32) callconv(.winapi) u32;

allocator: std.mem.Allocator,
blocker: *Blocker,
/// Packed as x << 32 | y.
cursor: tuft_arch.atomic.Value(u64) = .init(0),
/// Re-applied on release.
clip_lock: SpinLock = .{},
game_clip: ?win.RECT = null,
/// From messages and GetRawInputBuffer.
held_lock: SpinLock = .{},
held: Held = .{},
raw_buffer: raw_input.Held = .{},
pending_buffer: raw_input.Held = .{},
/// Its address is the fake handle for fake WM_INPUT releases. Window thread only.
synthetic: [raw_input.max_record_size]u8 align(8) = @splat(0),
synthetic_len: u32 = 0,
/// Bitset by virtual-key code.
hidden_keys: [4]tuft_arch.atomic.Value(u64) = @splat(.init(0)),

get_async_key_state: ?*hook.TypedHook(KeyStateFn) = null,
get_key_state: ?*hook.TypedHook(KeyStateFn) = null,
get_keyboard_state: ?*hook.TypedHook(KeyboardStateFn) = null,
get_cursor_pos: ?*hook.TypedHook(GetCursorPosFn) = null,
set_cursor_pos: ?*hook.TypedHook(SetCursorPosFn) = null,
clip_cursor: ?*hook.TypedHook(ClipCursorFn) = null,
get_raw_input_buffer: ?*hook.TypedHook(RawInputBufferFn) = null,
get_raw_input_data: ?*hook.TypedHook(RawInputDataFn) = null,
/// Hooked once the game loads DirectInput 8.
dinput: std.atomic.Value(?*DInput) = .init(null),
dinput_wait: ?*sys.module.WhenLoaded = null,
/// One per XInput DLL, hooked as each loads.
xinput_waits: [XInput.dll_names.len]?*sys.module.WhenLoaded = @splat(null),
xinput_lock: SpinLock = .{},
/// Under `xinput_lock`. `XInputGetState` and `XInputGetStateEx` from each DLL.
xinput_state: [XInput.dll_names.len * 2]?*hook.TypedHook(XInput.GetStateFn) = @splat(null),
xinput_keystroke: [XInput.dll_names.len]?*hook.TypedHook(XInput.GetKeystrokeFn) = @splat(null),

const hook_fields = .{ "get_async_key_state", "get_key_state", "get_keyboard_state", "get_cursor_pos", "set_cursor_pos", "clip_cursor", "get_raw_input_buffer", "get_raw_input_data" };

pub fn create(allocator: std.mem.Allocator, blocker: *Blocker) !*Win32 {
    const self = try allocator.create(Win32);
    self.* = .{ .allocator = allocator, .blocker = blocker };

    const user32 = try memory.Module.find("user32.dll");
    self.get_async_key_state = self.hookExport(KeyStateFn, user32, "GetAsyncKeyState", getAsyncKeyState);
    self.get_key_state = self.hookExport(KeyStateFn, user32, "GetKeyState", getKeyState);
    self.get_keyboard_state = self.hookExport(KeyboardStateFn, user32, "GetKeyboardState", getKeyboardState);
    self.get_cursor_pos = self.hookExport(GetCursorPosFn, user32, "GetCursorPos", getCursorPos);
    self.set_cursor_pos = self.hookExport(SetCursorPosFn, user32, "SetCursorPos", setCursorPos);
    self.clip_cursor = self.hookExport(ClipCursorFn, user32, "ClipCursor", clipCursor);
    self.get_raw_input_buffer = self.hookExport(RawInputBufferFn, user32, "GetRawInputBuffer", getRawInputBuffer);
    self.get_raw_input_data = self.hookExport(RawInputDataFn, user32, "GetRawInputData", getRawInputData);
    // Might not be loaded yet, like when injected at launch
    self.dinput_wait = sys.module.WhenLoaded.create(allocator, "dinput8.dll", .{ .ctx = self, .ready = hookDInput }) catch |err| blk: {
        log.warn("Can't watch for DirectInput 8 loading: {t}", .{err});
        break :blk null;
    };
    for (XInput.dll_names, &self.xinput_waits) |name, *wait| {
        wait.* = sys.module.WhenLoaded.create(allocator, name, .{ .ctx = self, .ready = hookXInput }) catch |err| blk: {
            log.warn("Can't watch for {s} loading: {t}", .{ name, err });
            break :blk null;
        };
    }
    return self;
}

/// Waits for calls in flight.
pub fn destroy(self: *Win32) void {
    if (self.dinput_wait) |w| w.destroy();
    for (self.xinput_waits) |wait| if (wait) |w| w.destroy();
    if (self.dinput.load(.acquire)) |d| d.destroy(self.allocator);
    for (self.xinput_state) |h| if (h) |x| x.destroy();
    for (self.xinput_keystroke) |h| if (h) |x| x.destroy();
    inline for (hook_fields) |name| {
        if (@field(self, name)) |h| h.destroy();
    }
    self.allocator.destroy(self);
}

pub fn captureChanged(self: *Win32, taken: Channels, returned: Channels) void {
    if (taken.contains(.mouse_motion)) {
        var point: win.POINT = .{};
        if (win.GetCursorPos(&point).toBool()) self.cursor.store(pack(point), .release);
        self.releaseClip();
    }
    if (returned.contains(.mouse_motion)) self.restoreClip();
}

/// Window thread. Fully hidden raw input goes to `DefWindowProc`, which frees it.
pub fn hideMessage(self: *Win32, m: *const tuft_window.Message) ?isize {
    if (m.msg != win.WM_INPUT) return null;
    const device = raw_input.deviceOf(m.lparam) orelse return null;
    if (!raw_input.hidesAll(device, self.blocker.hidden())) return null;
    return tuft_window.defaultProc(m);
}

/// Window thread, for a message hidden from the game. Alt+F4 still closes it, like `DefWindowProc` would.
/// IME messages go to `DefWindowProc` instead, so the IME keeps working for us and its text comes
/// back as chars.
pub fn swallowed(_: *Win32, m: *const tuft_window.Message) isize {
    if (@import("input.zig").isIme(m.msg)) return tuft_window.defaultProc(m);
    const alt_held = m.lparam & (1 << 29) != 0;
    const repeat = m.lparam & (1 << 30) != 0;
    if (m.msg != win.WM_SYSKEYDOWN or m.wparam != win.VK_F4 or !alt_held or repeat) return 0;
    _ = tuft_window.post(m.window, win.WM_SYSCOMMAND, win.SC_CLOSE, 0);
    return 0;
}

/// Window thread. Strips hidden bits, like held buttons on a mouse move, which SDL treats as presses.
pub fn stripMessage(self: *Win32, m: *tuft_window.Message) void {
    if (m.msg < win.WM_MOUSEMOVE or m.msg > win.WM_MOUSEHWHEEL) return;
    var hidden: usize = 0;
    if (self.blocker.hides(.mouse_buttons)) hidden |= win.MK_LBUTTON | win.MK_RBUTTON | win.MK_MBUTTON | win.MK_XBUTTON1 | win.MK_XBUTTON2;
    if (self.blocker.hides(.keyboard)) hidden |= win.MK_SHIFT | win.MK_CONTROL;
    m.wparam &= ~hidden;
}

/// Window thread.
pub fn observe(self: *Win32, m: *const tuft_window.Message) void {
    self.held_lock.lock();
    defer self.held_lock.unlock();
    self.held.observe(m);
}

/// Window thread.
pub fn release(self: *Win32, devices: Devices, window: *Window) void {
    if (self.dinput.load(.acquire)) |d| d.release(devices);
    var pending = blk: {
        self.held_lock.lock();
        defer self.held_lock.unlock();
        self.raw_buffer.take(devices, &self.pending_buffer);
        break :blk self.held.take(devices);
    };

    // Send outside the lock, since the game's handlers call back into our hooks
    var buf: [raw_input.max_record_size]u8 align(8) = undefined;
    while (pending.next(&buf)) |item| switch (item) {
        .message => |m| _ = window.callOriginal(m.msg, m.wparam, m.lparam),
        .raw => |record| {
            @memcpy(self.synthetic[0..record.len], record);
            self.synthetic_len = @intCast(record.len);
            _ = window.callOriginal(win.WM_INPUT, 0, @bitCast(self.syntheticHandle()));
            self.synthetic_len = 0;
        },
    };
}

fn hookDInput(ctx: ?*anyopaque, _: usize) void {
    const self: *Win32 = @ptrCast(@alignCast(ctx.?));
    const d = DInput.create(self.allocator, self) catch |err| {
        log.warn("Can't hide DirectInput 8 from the game: {t}", .{err});
        return;
    };
    self.dinput.store(d, .release);
    log.debug("Hiding DirectInput 8 from the game too", .{});
}

/// The loader's thread, once per DLL. Some DLLs forward to another's code, which only gets one hook.
fn hookXInput(ctx: ?*anyopaque, base: usize) void {
    const self: *Win32 = @ptrCast(@alignCast(ctx.?));
    self.xinput_lock.lock();
    defer self.xinput_lock.unlock();
    const targets = [_]?usize{ sys.module.findExport(base, "XInputGetState"), sys.module.findOrdinal(base, XInput.get_state_ex_ordinal) };
    for (targets) |target| {
        const address = target orelse continue;
        if (self.xinputHooked(address)) continue;
        const slot = for (&self.xinput_state) |*s| {
            if (s.* == null) break s;
        } else return;
        slot.* = hookAt(XInput.GetStateFn, self, address, xinputGetState) catch |err| {
            log.warn("Can't hide controllers from the game: {t}", .{err});
            continue;
        };
    }
    const keystroke = sys.module.findExport(base, "XInputGetKeystroke") orelse return;
    for (self.xinput_keystroke) |h| if (h) |x| if (x.toConstHook().target_addr == keystroke) return;
    const slot = for (&self.xinput_keystroke) |*s| {
        if (s.* == null) break s;
    } else return;
    slot.* = hookAt(XInput.GetKeystrokeFn, self, keystroke, xinputGetKeystroke) catch |err| blk: {
        log.warn("Can't hide controller keystrokes from the game: {t}", .{err});
        break :blk null;
    };
}

/// Under `xinput_lock`.
fn xinputHooked(self: *const Win32, address: usize) bool {
    for (self.xinput_state) |h| if (h) |x| if (x.toConstHook().target_addr == address) return true;
    return false;
}

fn hookExport(self: *Win32, comptime T: type, module: memory.Module, comptime name: [:0]const u8, comptime callback: anytype) ?*hook.TypedHook(T) {
    const h = createHook(T, self, module, name, callback) catch |err| {
        log.warn("Can't hide {s} from the game: {t}", .{ name, err });
        return null;
    };
    return h;
}

fn createHook(comptime T: type, self: *Win32, module: memory.Module, comptime name: [:0]const u8, comptime callback: anytype) !*hook.TypedHook(T) {
    const h = try module.symbol(name).createFn(T, callback, self);
    errdefer h.destroy();
    try h.enable();
    return h;
}

fn hookAt(comptime T: type, self: *Win32, address: usize, comptime callback: anytype) !*hook.TypedHook(T) {
    const h = try memory.Address.at(address).createFn(T, callback, self);
    errdefer h.destroy();
    try h.enable();
    return h;
}

pub fn setKeyHidden(self: *Win32, key: @import("../root.zig").Key, hide: bool) void {
    const vk = @import("input.zig").vkOf(key);
    const bit = @as(u64, 1) << @intCast(vk % 64);
    if (hide) {
        _ = self.hidden_keys[vk / 64].fetchOr(bit, .acq_rel);
    } else {
        _ = self.hidden_keys[vk / 64].fetchAnd(~bit, .acq_rel);
    }
}

pub fn isKeyHidden(self: *const Win32, key: @import("../root.zig").Key) bool {
    return self.vkHidden(@import("input.zig").vkOf(key));
}

pub fn anyKeyHidden(self: *const Win32) bool {
    for (&self.hidden_keys) |*bits| if (bits.load(.acquire) != 0) return true;
    return false;
}

pub fn isVkHidden(self: *const Win32, vk: u8) bool {
    return self.vkHidden(vk);
}

fn vkHidden(self: *const Win32, vk: u8) bool {
    return self.hidden_keys[vk / 64].load(.acquire) & (@as(u64, 1) << @intCast(vk % 64)) != 0;
}

fn hidesKey(self: *const Win32, vk: i32) bool {
    const low: u8 = @truncate(@as(u32, @bitCast(vk)));
    const channel: @import("../root.zig").Channel = if (@import("held.zig").isMouseButton(low))
        .mouse_buttons
    else if (vk >= 0 and vk <= 255 and isPadVk(low)) .gamepad else .keyboard;
    if (self.blocker.hides(channel)) return true;
    if (vk < 0 or vk > 255 or Blocker.isBypassing()) return false;
    return self.vkHidden(@intCast(vk));
}

fn isPadVk(vk: u8) bool {
    const input = @import("input.zig");
    return vk >= input.vkOf(.gamepad_a) and vk <= input.vkOf(.gamepad_right_stick);
}

/// Buttons whose keys are hidden on their own, like a consumed keybind.
fn hiddenPadButtons(self: *const Win32) PadButtons {
    var hidden: PadButtons = .{};
    if (!self.anyKeyHidden()) return hidden;
    for (std.enums.values(PadButton)) |b| {
        if (self.vkHidden(@import("input.zig").vkOf(b.key()))) hidden = hidden.with(b, true);
    }
    return hidden;
}

// Hooks

fn getAsyncKeyState(self: *Win32, h: *hook.TypedHook(KeyStateFn), vk: i32) i16 {
    if (self.hidesKey(vk)) return 0;
    return h.original()(vk);
}

fn getKeyState(self: *Win32, h: *hook.TypedHook(KeyStateFn), vk: i32) i16 {
    if (self.hidesKey(vk)) return 0;
    return h.original()(vk);
}

fn getKeyboardState(self: *Win32, h: *hook.TypedHook(KeyboardStateFn), state: *[256]u8) win.BOOL {
    const ok = h.original()(state);
    if (ok.toBool()) {
        for (state, 0..) |*key, vk| {
            if (self.hidesKey(@intCast(vk))) key.* = 0;
        }
    }
    return ok;
}

fn getCursorPos(self: *Win32, h: *hook.TypedHook(GetCursorPosFn), point: *win.POINT) win.BOOL {
    if (self.blocker.hides(.mouse_motion)) {
        point.* = unpack(self.cursor.load(.acquire));
        return .TRUE;
    }
    return h.original()(point);
}

fn setCursorPos(self: *Win32, h: *hook.TypedHook(SetCursorPosFn), x: i32, y: i32) win.BOOL {
    if (self.blocker.hides(.mouse_motion)) return .TRUE;
    return h.original()(x, y);
}

fn clipCursor(self: *Win32, h: *hook.TypedHook(ClipCursorFn), rect: ?*const win.RECT) win.BOOL {
    if (self.blocker.hides(.mouse_motion)) {
        // Apply it when the overlay lets go
        self.clip_lock.lock();
        defer self.clip_lock.unlock();
        self.game_clip = if (rect) |r| r.* else null;
        return .TRUE;
    }
    return h.original()(rect);
}

/// Hidden controllers stay connected but sit at rest, so games don't show a "reconnect" prompt.
fn xinputGetState(self: *Win32, h: *hook.TypedHook(XInput.GetStateFn), user_index: u32, state: *XInput.State) u32 {
    const result = h.original()(user_index, state);
    if (result != XInput.success or Blocker.isBypassing()) return result;
    if (self.blocker.hides(.gamepad)) {
        state.gamepad = .{};
    } else {
        XInput.strip(&state.gamepad, self.hiddenPadButtons());
    }
    return result;
}

/// Hidden keystrokes get read and dropped, so they don't all come out when we let go.
fn xinputGetKeystroke(self: *Win32, h: *hook.TypedHook(XInput.GetKeystrokeFn), user_index: u32, reserved: u32, keystroke: *XInput.Keystroke) u32 {
    for (0..max_dropped_keystrokes) |_| {
        const result = h.original()(user_index, reserved, keystroke);
        if (result != XInput.success or Blocker.isBypassing() or !self.keystrokeHidden(keystroke.virtual_key)) return result;
    }
    return XInput.empty;
}

const max_dropped_keystrokes = 64;

fn keystrokeHidden(self: *const Win32, vk: u16) bool {
    if (self.blocker.hides(.gamepad)) return true;
    const button = XInput.buttonOfKeystroke(vk) orelse return false;
    return self.vkHidden(@import("input.zig").vkOf(button.key()));
}

fn getRawInputBuffer(self: *Win32, h: *hook.TypedHook(RawInputBufferFn), data: ?[*]u8, size: *u32, header_size: u32) u32 {
    const count = h.original()(data, size, header_size);
    const buffer = data orelse return count;
    if (count == std.math.maxInt(u32)) return count;

    const kept = raw_input.filter(buffer, count, self.blocker.hidden());

    self.held_lock.lock();
    defer self.held_lock.unlock();
    var records: raw_input.Records = .{ .data = buffer, .left = kept };
    while (records.next()) |record| self.raw_buffer.observe(record);
    return kept + self.pending_buffer.appendReleases(buffer[0..size.*], records.offset);
}

fn getRawInputData(self: *Win32, h: *hook.TypedHook(RawInputDataFn), handle: ?*anyopaque, command: u32, data: ?*anyopaque, size: *u32, header_size: u32) u32 {
    if (@intFromPtr(handle) != self.syntheticHandle() or self.synthetic_len == 0) {
        const len = h.original()(handle, command, data, size, header_size);
        if (command == raw_input.RID_INPUT and len != std.math.maxInt(u32) and data != null) {
            raw_input.strip(@as([*]u8, @ptrCast(data.?))[0..len], self.blocker.hidden());
        }
        return len;
    }
    const len: u32 = if (command == raw_input.RID_HEADER) raw_input.header_size else self.synthetic_len;
    const out = data orelse {
        size.* = len;
        return 0;
    };
    if (size.* < len) {
        size.* = len;
        return std.math.maxInt(u32);
    }
    @memcpy(@as([*]u8, @ptrCast(out))[0..len], self.synthetic[0..len]);
    return len;
}

// Cursor clip

fn releaseClip(self: *Win32) void {
    const original = (self.clip_cursor orelse return).original();
    self.clip_lock.lock();
    defer self.clip_lock.unlock();
    var rect: win.RECT = .{};
    self.game_clip = if (win.GetClipCursor(&rect).toBool()) rect else null;
    _ = original(null);
}

fn restoreClip(self: *Win32) void {
    const original = (self.clip_cursor orelse return).original();
    self.clip_lock.lock();
    defer self.clip_lock.unlock();
    if (self.game_clip) |*rect| _ = original(rect) else _ = original(null);
}

fn syntheticHandle(self: *const Win32) usize {
    return @intFromPtr(&self.synthetic);
}

fn pack(point: win.POINT) u64 {
    return (@as(u64, @as(u32, @bitCast(point.x))) << 32) | @as(u32, @bitCast(point.y));
}

fn unpack(value: u64) win.POINT {
    return .{ .x = @bitCast(@as(u32, @truncate(value >> 32))), .y = @bitCast(@as(u32, @truncate(value))) };
}

/// For short critical sections inside game hooks. No allocation, no OS waits.
pub const SpinLock = struct {
    locked: std.atomic.Value(bool) = .init(false),

    pub fn lock(self: *SpinLock) void {
        while (self.locked.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    }

    pub fn unlock(self: *SpinLock) void {
        self.locked.store(false, .release);
    }
};

const tests = struct {
    const testing = std.testing;
    const Rig = @import("../testing.zig");

    const VK_LBUTTON = 0x01;
    const VK_A = 0x41;

    /// Real state, or up if `hidden`.
    fn expectKeys(rig: *Rig, hidden: Channels) !void {
        const backend = rig.blocker.backend;
        var real: [256]u8 = undefined;
        var seen: [256]u8 = undefined;
        // Real key state can change between calls, so retry for a steady read
        for (0..10) |_| {
            _ = backend.get_keyboard_state.?.original()(&real);
            _ = win.GetKeyboardState(&seen);
            var again: [256]u8 = undefined;
            _ = backend.get_keyboard_state.?.original()(&again);
            if (std.mem.eql(u8, &real, &again)) break;
        }
        for ([_]i32{ VK_A, VK_LBUTTON }) |vk| {
            const channel: @import("../root.zig").Channel = if (vk == VK_LBUTTON) .mouse_buttons else .keyboard;
            const i: usize = @intCast(vk);
            if (hidden.contains(channel)) {
                try testing.expectEqual(0, seen[i]);
                try testing.expectEqual(0, win.GetKeyState(vk));
                try testing.expectEqual(0, win.GetAsyncKeyState(vk));
            } else {
                try testing.expectEqual(real[i], seen[i]);
                try testing.expectEqual(backend.get_key_state.?.original()(vk), win.GetKeyState(vk));
            }
        }
    }

    test "dinput hooked on load" {
        // Only meaningful if nothing in this process has loaded it yet
        if (sys.module.findBase("dinput8.dll") != null) return error.SkipZigTest;
        var rig: Rig = undefined;
        try rig.init();
        defer rig.deinit();
        const backend = rig.blocker.backend;
        try testing.expectEqual(null, backend.dinput.load(.acquire));

        const handle = win.LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("dinput8.dll")) orelse return error.LoadFailed;
        defer _ = win.FreeLibrary(handle);
        var waited: u32 = 0;
        while (backend.dinput.load(.acquire) == null and waited < 2000) : (waited += 1) win.Sleep(1);
        try testing.expect(backend.dinput.load(.acquire) != null);
    }

    test "polled state hidden" {
        if (!@import("build_options").real_input) return error.SkipZigTest; // reads the real keyboard state
        var rig: Rig = undefined;
        try rig.init();
        defer rig.deinit();
        rig.present(); // attaches

        // Best effort. Checks pass either way
        var state: [256]u8 = @splat(0);
        state[VK_A] = 0x80;
        state[VK_LBUTTON] = 0x80;
        _ = win.SetKeyboardState(&state);
        defer {
            const cleared: [256]u8 = @splat(0);
            _ = win.SetKeyboardState(&cleared);
        }

        try expectKeys(&rig, .empty);
        rig.blocker.capture(.initOne(.keyboard));
        try expectKeys(&rig, .initOne(.keyboard));
        rig.blocker.capture(.initOne(.mouse_buttons));
        try expectKeys(&rig, .initOne(.mouse_buttons));
        {
            const bypass = Blocker.Bypass.begin();
            defer bypass.end();
            try expectKeys(&rig, .empty);
        }
        rig.blocker.capture(.empty);
        try expectKeys(&rig, .empty);
    }

    test "single hidden key" {
        if (!@import("build_options").real_input) return error.SkipZigTest; // reads the real keyboard state
        var rig: Rig = undefined;
        try rig.init();
        defer rig.deinit();

        const VK_B = 0x42;
        var state: [256]u8 = @splat(0);
        state[VK_A] = 0x80;
        state[VK_B] = 0x80;
        _ = win.SetKeyboardState(&state);
        defer {
            const cleared: [256]u8 = @splat(0);
            _ = win.SetKeyboardState(&cleared);
        }

        rig.blocker.hideKey(.a, true);
        var seen: [256]u8 = undefined;
        _ = win.GetKeyboardState(&seen);
        try testing.expectEqual(0, seen[VK_A]);
        try testing.expectEqual(0, win.GetKeyState(VK_A));
        try testing.expectEqual(0x80, seen[VK_B] & 0x80);
        try testing.expect(win.GetKeyState(VK_B) < 0);
        {
            const bypass = Blocker.Bypass.begin();
            defer bypass.end();
            try testing.expect(win.GetKeyState(VK_A) < 0);
        }

        rig.blocker.hideKey(.a, false);
        try testing.expect(win.GetKeyState(VK_A) < 0);
    }

    test "cursor frozen" {
        var rig: Rig = undefined;
        try rig.init();
        defer rig.deinit();
        rig.present(); // attaches

        var start: win.POINT = .{};
        _ = win.GetCursorPos(&start);
        rig.blocker.capture(.initOne(.mouse_motion));
        defer rig.blocker.capture(.empty);

        var seen: win.POINT = .{};
        try testing.expect(win.GetCursorPos(&seen).toBool());
        try testing.expectEqual(start, seen);
        try testing.expect(win.SetCursorPos(start.x + 40, start.y + 40).toBool());

        const bypass = Blocker.Bypass.begin();
        defer bypass.end();
        var actual: win.POINT = .{};
        _ = win.GetCursorPos(&actual);
        try testing.expectEqual(start, actual);
    }

    test "cursor clip lifted" {
        if (!@import("build_options").real_input) return error.SkipZigTest; // clips the real cursor
        var rig: Rig = undefined;
        try rig.init();
        defer rig.deinit();
        rig.present(); // attaches

        var unclipped: win.RECT = .{};
        _ = win.GetClipCursor(&unclipped);
        defer _ = win.ClipCursor(null);

        rig.blocker.capture(.initOne(.mouse_motion));
        const wanted: win.RECT = .{ .left = unclipped.left + 10, .top = unclipped.top + 10, .right = unclipped.left + 300, .bottom = unclipped.top + 300 };
        try testing.expect(win.ClipCursor(&wanted).toBool());
        var now: win.RECT = .{};
        _ = win.GetClipCursor(&now);
        try testing.expectEqual(unclipped, now);

        rig.blocker.capture(.empty);
        _ = win.GetClipCursor(&now);
        try testing.expectEqual(wanted, now);
    }

    test "messages hidden and released" {
        var rig: Rig = undefined;
        try rig.init();
        defer rig.deinit();
        rig.present(); // attaches

        _ = rig.send(win.WM_KEYDOWN, 'W', 0x0011_0001);
        try testing.expectEqual(1, Rig.game.count(win.WM_KEYDOWN));

        rig.blocker.capture(.initOne(.mouse_buttons));
        tuft_window.pump();
        try testing.expectEqual(0, Rig.game.count(win.WM_KEYUP)); // the keyboard wasn't taken

        rig.blocker.capture(.full);
        _ = rig.send(win.WM_KEYDOWN, 'Q', 0x0010_0001);
        try testing.expectEqual(1, Rig.game.count(win.WM_KEYDOWN)); // hidden
        try testing.expectEqual(0, Rig.game.count(win.WM_KEYUP)); // the release runs on the window thread
        tuft_window.pump();
        try testing.expectEqual(1, Rig.game.count(win.WM_KEYUP));
        try testing.expectEqual('W', Rig.game.lastWparam(win.WM_KEYUP));

        // Released only once
        rig.blocker.capture(.empty);
        rig.blocker.capture(.full);
        tuft_window.pump();
        try testing.expectEqual(1, Rig.game.count(win.WM_KEYUP));
    }

    test "alt f4 still closes while hidden" {
        var rig: Rig = undefined;
        try rig.init();
        defer rig.deinit();
        rig.present(); // attaches
        rig.blocker.capture(.full);
        defer rig.blocker.capture(.empty);

        const alt: isize = 1 << 29;
        const f4_scan: isize = 0x003E_0001;
        // A repeat and plain F4 don't count
        _ = rig.send(win.WM_SYSKEYDOWN, win.VK_F4, alt | f4_scan | (1 << 30));
        _ = rig.send(win.WM_KEYDOWN, win.VK_F4, f4_scan);
        var msg: win.MSG = .{};
        try testing.expect(!win.PeekMessageW(&msg, rig.hwnd, win.WM_SYSCOMMAND, win.WM_SYSCOMMAND, win.PM_REMOVE).toBool());

        _ = rig.send(win.WM_SYSKEYDOWN, win.VK_F4, alt | f4_scan);
        try testing.expectEqual(0, Rig.game.count(win.WM_SYSKEYDOWN));
        // Taken off the queue, or the window would really close
        try testing.expect(win.PeekMessageW(&msg, rig.hwnd, win.WM_SYSCOMMAND, win.WM_SYSCOMMAND, win.PM_REMOVE).toBool());
        try testing.expectEqual(win.SC_CLOSE, msg.wParam);
    }

    test "buttons only capture" {
        var rig: Rig = undefined;
        try rig.init();
        defer rig.deinit();
        rig.present(); // attaches

        _ = rig.send(win.WM_RBUTTONDOWN, 0, 0x0014_000A);
        try testing.expectEqual(1, Rig.game.count(win.WM_RBUTTONDOWN));

        var start: win.POINT = .{};
        _ = win.GetCursorPos(&start);
        rig.blocker.capture(.initOne(.mouse_buttons));
        defer rig.blocker.capture(.empty);

        _ = rig.send(win.WM_LBUTTONDOWN, 1, 0x0014_000A);
        _ = rig.send(win.WM_MOUSEWHEEL, 120 << 16, 0x0014_000A);
        // Held buttons on moves are hidden too, SDL turns them into presses. Shift stays
        _ = rig.send(win.WM_MOUSEMOVE, win.MK_LBUTTON | win.MK_XBUTTON1 | win.MK_SHIFT, 0x0015_000B);
        try testing.expectEqual(0, Rig.game.count(win.WM_LBUTTONDOWN));
        try testing.expectEqual(0, Rig.game.count(win.WM_MOUSEWHEEL));
        try testing.expectEqual(1, Rig.game.count(win.WM_MOUSEMOVE));
        try testing.expectEqual(win.MK_SHIFT, Rig.game.lastWparam(win.WM_MOUSEMOVE));

        rig.blocker.capture(Channels.initMany(&.{ .mouse_buttons, .keyboard }));
        _ = rig.send(win.WM_MOUSEMOVE, win.MK_RBUTTON | win.MK_CONTROL, 0x0016_000C);
        try testing.expectEqual(0, Rig.game.lastWparam(win.WM_MOUSEMOVE));
        rig.blocker.capture(.initOne(.mouse_buttons));

        tuft_window.pump();
        try testing.expectEqual(1, Rig.game.count(win.WM_RBUTTONUP));

        // This moves the real cursor
        if (!@import("build_options").real_input) return;
        try testing.expect(win.SetCursorPos(start.x + 1, start.y).toBool());
        defer _ = win.SetCursorPos(start.x, start.y);
        var seen: win.POINT = .{};
        _ = win.GetCursorPos(&seen);
        var real: win.POINT = .{};
        _ = rig.blocker.backend.get_cursor_pos.?.original()(&real);
        try testing.expectEqual(real, seen);
    }

    test "IME skips the game while the keyboard's ours" {
        var rig: Rig = undefined;
        try rig.init();
        defer rig.deinit();
        rig.present();
        const WM_IME_SETCONTEXT = 0x0281;
        const WM_IME_STARTCOMPOSITION = 0x010D;

        rig.blocker.capture(.initOne(.keyboard));
        _ = rig.send(WM_IME_SETCONTEXT, 1, 0);
        _ = rig.send(WM_IME_STARTCOMPOSITION, 0, 0);
        try testing.expectEqual(0, Rig.game.count(WM_IME_SETCONTEXT));
        try testing.expectEqual(0, Rig.game.count(WM_IME_STARTCOMPOSITION));

        rig.blocker.capture(.empty);
        _ = rig.send(WM_IME_SETCONTEXT, 1, 0);
        try testing.expectEqual(1, Rig.game.count(WM_IME_SETCONTEXT));
    }

    test "controllers hidden through XInput" {
        var rig: Rig = undefined;
        try rig.init();
        defer rig.deinit();
        // Loading it is what hooks it
        const x = XInput.create(testing.allocator) catch return error.SkipZigTest;
        defer x.destroy(testing.allocator);
        const backend = rig.blocker.backend;
        // If loading it was new, the hook goes in on the load watch's thread just after
        var waited: u32 = 0;
        while (waited < 2000) : (waited += 1) {
            backend.xinput_lock.lock();
            const hooked = backend.xinput_state[0] != null;
            backend.xinput_lock.unlock();
            if (hooked) break;
            win.Sleep(1);
        }
        try testing.expect(backend.xinput_state[0] != null);

        rig.blocker.capture(.initOne(.gamepad));
        defer rig.blocker.capture(.empty);
        var state: XInput.State = .{};
        const result = x.get_state(0, &state);
        // Without a controller plugged in this only checks the hook passes the result on
        if (result == XInput.success) try testing.expectEqual(XInput.Gamepad{}, state.gamepad);
        try testing.expect(backend.keystrokeHidden(0x5800));

        rig.blocker.capture(.empty);
        rig.blocker.hideKey(.gamepad_back, true);
        defer rig.blocker.hideKey(.gamepad_back, false);
        try testing.expect(backend.keystrokeHidden(0x5815));
        try testing.expect(!backend.keystrokeHidden(0x5800));
        try testing.expect(backend.hiddenPadButtons().eql(.{ .back = true }));
        try testing.expect(!backend.hidesKey(XInputVkA));
        rig.blocker.capture(.initOne(.gamepad));
        try testing.expect(backend.hidesKey(XInputVkA));
    }

    const XInputVkA = 0xC3;
};

test {
    _ = tests;
    _ = DInput;
}
