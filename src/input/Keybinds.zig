//! Named actions bound to key chords. Matched on the window thread, handled on the render thread.

const Keybinds = @This();

const std = @import("std");
const tuft_arch = @import("tuft_arch");

const tuft_event = @import("tuft_event");
const tuft_sys = @import("tuft_sys");

const Blocker = @import("Blocker.zig");
const Window = @import("Window.zig");
const Gamepads = @import("Gamepads.zig");

const log = std.log.scoped(.tuft_input);

pub const Chord = @import("root.zig").Chord;
pub const Keys = @import("root.zig").Keys;
pub const Phase = enum { pressed, released };

pub const Trigger = struct { serial: u64, phase: Phase };
pub const TriggerEvent = tuft_event.Event(fn (Trigger) void);

pub const Action = struct {
    /// Unique, like `"wraith.toggle_overlay"`. Plugins use `"<plugin>.<name>"`.
    id: []const u8,
    name: []const u8,
    /// Any of them does it, like a key and a controller button.
    keys: Keys,
    /// Hide the key's messages and polling from the game. Raw input still sees it.
    consume: bool = true,
    /// Also matches while ImGui takes text input.
    while_typing: bool = false,
    /// A key that's held, like one to move with: it fires whatever modifiers are down too, and its
    /// key can be a modifier itself, like Shift. Its keys have no modifiers.
    held: bool = false,
};

pub const Error = error{
    OutOfMemory,
    AlreadyBound,
    InvalidChord,
};

const Queue = tuft_event.Mailbox(Trigger, 64);
const max_held = 16;

allocator: std.mem.Allocator,
blocker: *Blocker,
subscriptions: tuft_event.Scope,
/// On the render thread. `bind` subscribes to it.
triggered: TriggerEvent,
/// `bind`/`unbind` write, the window thread reads.
lock: tuft_sys.sync.RwLock = .{},
bindings: std.ArrayList(*Binding) = .empty,
next_serial: tuft_arch.atomic.Value(u64) = .init(1),
/// Goes up whenever a binding comes, goes or changes key, so a UI knows to look again.
changes: tuft_arch.atomic.Value(u32) = .init(0),
typing: std.atomic.Value(bool) = .init(false),
paused: tuft_arch.atomic.Value(bool) = .init(false),
queue: Queue = .{},
queue_overflowed: std.atomic.Value(bool) = .init(false),

// Window thread only
/// Keyed by the key that pressed them.
held: HeldList = .{},
/// Their repeats, chars and release get swallowed too.
consumed: std.EnumSet(@import("root.zig").Key) = .empty,
/// So swallow the chars it types.
eat_chars: bool = false,

// Gamepad poll thread only
pad_held: HeldList = .{},
pad_consumed: std.EnumSet(@import("root.zig").Key) = .empty,

// The window thread writes, any thread reads
/// What the window's messages say is down, by `Key` value.
keys_down: [8]tuft_arch.atomic.Value(u32) = @splat(.init(0)),
/// By `MouseButton` value.
buttons_down: tuft_arch.atomic.Value(u32) = .init(0),
/// The last mouse move's client coords, x in the low half.
mouse: tuft_arch.atomic.Value(u64) = .init(0),
mouse_seen: tuft_arch.atomic.Value(bool) = .init(false),

const Held = struct { key: @import("root.zig").Key, serial: u64 };
const HeldList = struct {
    items: [max_held]Held = undefined,
    len: usize = 0,
};

/// Freed by `unbind`.
pub const Binding = struct {
    keybinds: *Keybinds,
    serial: u64,
    id: []u8,
    name: []u8,
    keys: Keys,
    consume: bool,
    while_typing: bool,
    held: bool,
    ctx: ?*anyopaque,
    call: *const fn (ctx: ?*anyopaque, phase: Phase) void,
    subscription: TriggerEvent.Subscription = undefined,
    /// Its keys that are down, so two held at once press it once and release it once. Render thread.
    downs: u8 = 0,

    fn onTrigger(self: *Binding, trigger: Trigger) void {
        if (trigger.serial != self.serial) return;
        switch (trigger.phase) {
            .pressed => {
                self.downs +|= 1;
                if (self.downs == 1) self.call(self.ctx, .pressed);
            },
            .released => {
                if (self.downs == 0) return;
                self.downs -= 1;
                if (self.downs == 0) self.call(self.ctx, .released);
            },
        }
    }

    /// Whether `key` with `mods` held sets it off.
    fn matches(self: *const Binding, key: @import("root.zig").Key, mods: @import("root.zig").Mods) bool {
        return self.keys.matches(key, mods, self.held);
    }

    /// Waits for its handler if it's running on another thread.
    pub fn unbind(self: *Binding) void {
        const k = self.keybinds;
        k.remove(self);
        self.subscription.unsubscribe();
        k.allocator.free(self.id);
        k.allocator.free(self.name);
        k.allocator.destroy(self);
    }

    /// Counts from the next press. Any thread.
    pub fn rebind(self: *Binding, keys: Keys) error{InvalidChord}!void {
        if (!keys.isValid(self.held)) return error.InvalidChord;
        const k = self.keybinds;
        k.lock.lock();
        defer k.lock.unlock();
        for (k.bindings.items) |other| {
            if (other == self) continue;
            for (0..keys.count()) |i| {
                const chord = keys.get(i).?;
                if (other.keys.contains(chord)) log.warn("{s} and {s} are both bound to {f}", .{ other.id, self.id, chord });
            }
        }
        self.keys = keys;
        _ = k.changes.fetchAdd(1, .release);
    }
};

pub fn create(allocator: std.mem.Allocator, window: *Window, blocker: *Blocker) !*Keybinds {
    const self = try allocator.create(Keybinds);
    errdefer allocator.destroy(self);
    self.* = .{ .allocator = allocator, .blocker = blocker, .subscriptions = .init(allocator), .triggered = .init(allocator) };
    errdefer {
        self.subscriptions.deinit();
        self.triggered.deinit();
    }

    try window.message.subscribeOpts(&self.subscriptions, self, onMessage, .{ .priority = Window.Priority.keybinds });
    return self;
}

/// Call once every binding is gone, and before `gamepads` goes.
pub fn destroy(self: *Keybinds) void {
    self.subscriptions.deinit();
    _ = self.queue.close();
    var it = self.consumed.iterator();
    while (it.next()) |key| self.blocker.hideKey(key, false);
    var pad_it = self.pad_consumed.iterator();
    while (pad_it.next()) |key| self.blocker.hideKey(key, false);
    if (self.bindings.items.len != 0) log.err("{d} keybinding(s) still bound at shutdown", .{self.bindings.items.len});
    self.bindings.deinit(self.allocator);
    self.triggered.deinit();
    self.allocator.destroy(self);
}

/// While typing only `while_typing` bindings match. Any thread.
pub fn setTyping(self: *Keybinds, on: bool) void {
    self.typing.store(on, .release);
}

/// Nothing matches while paused, like when a key is being picked for one. Any thread.
pub fn setPaused(self: *Keybinds, on: bool) void {
    self.paused.store(on, .release);
}

/// Controller buttons match too, on the poll thread. `gamepads` has to outlive this.
pub fn attachGamepads(self: *Keybinds, gamepads: *Gamepads) !void {
    try gamepads.changed.subscribeOpts(&self.subscriptions, self, onPad, .{ .priority = Window.Priority.keybinds });
}

/// `func(ctx)` runs on press, or `func(ctx, phase)` on press and release. Render thread.
pub fn bind(self: *Keybinds, scope: *tuft_event.Scope, action: Action, ctx: anytype, comptime func: anytype) Error!void {
    const binding = try self.bindUnscoped(action, ctx, func);
    scope.add(binding, Binding.unbind) catch |err| {
        binding.unbind();
        return err;
    };
}

/// Lasts until you unbind it.
pub fn bindUnscoped(self: *Keybinds, action: Action, ctx: anytype, comptime func: anytype) Error!*Binding {
    const Ctx = @TypeOf(ctx);
    if (@typeInfo(Ctx) != .pointer) @compileError("Keybind context must be a pointer, found " ++ @typeName(Ctx));
    const params = @import("tuft_arch").meta.fnInfo(@TypeOf(func)).param_types;
    if (params.len != 1 and !(params.len == 2 and params[1].? == Phase)) {
        @compileError("A keybind handler is fn (ctx) void (on press) or fn (ctx, Keybinds.Phase) void");
    }

    const Thunk = struct {
        fn call(raw: ?*anyopaque, phase: Phase) void {
            const typed: Ctx = @ptrCast(@alignCast(raw.?));
            if (params.len == 2) {
                func(typed, phase);
            } else if (phase == .pressed) {
                func(typed);
            }
        }
    };
    return self.bindRaw(action, @ptrCast(@constCast(ctx)), Thunk.call);
}

fn bindRaw(self: *Keybinds, action: Action, ctx: ?*anyopaque, call: *const fn (?*anyopaque, Phase) void) Error!*Binding {
    if (!action.keys.isValid(action.held)) return error.InvalidChord;

    const binding = try self.allocator.create(Binding);
    errdefer self.allocator.destroy(binding);
    const id = try self.allocator.dupe(u8, action.id);
    errdefer self.allocator.free(id);
    const name = try self.allocator.dupe(u8, action.name);
    errdefer self.allocator.free(name);
    binding.* = .{
        .keybinds = self,
        .serial = self.next_serial.fetchAdd(1, .monotonic),
        .id = id,
        .name = name,
        .keys = action.keys,
        .consume = action.consume,
        .while_typing = action.while_typing,
        .held = action.held,
        .ctx = ctx,
        .call = call,
    };
    binding.subscription = try self.triggered.subscribeUnscoped(binding, Binding.onTrigger);
    errdefer binding.subscription.unsubscribe();

    self.lock.lock();
    defer self.lock.unlock();
    for (self.bindings.items) |other| {
        if (std.mem.eql(u8, other.id, id)) return error.AlreadyBound;
        for (0..action.keys.count()) |i| {
            const chord = action.keys.get(i).?;
            if (other.keys.contains(chord)) log.warn("{s} and {s} are both bound to {f}", .{ other.id, id, chord });
        }
    }
    try self.bindings.append(self.allocator, binding);
    _ = self.changes.fetchAdd(1, .release);
    return binding;
}

/// Bindings on the same key, which all fire. Free with `freeClashes`.
pub const Clash = struct {
    chord: Chord,
    /// Two or more, in the order they were bound.
    ids: []const []const u8,
};

/// Any thread.
pub fn clashesAlloc(self: *Keybinds, allocator: std.mem.Allocator) ![]Clash {
    var out: std.ArrayList(Clash) = .empty;
    errdefer freeClashes(allocator, out.items);
    defer out.deinit(allocator);
    self.lock.lockShared();
    defer self.lock.unlockShared();
    const all = self.bindings.items;
    var seen: std.ArrayList(Chord) = .empty;
    defer seen.deinit(allocator);
    for (all) |b| for (0..b.keys.count()) |k| {
        const chord = b.keys.get(k).?;
        // Each key once, at its first binding
        if (for (seen.items) |s| {
            if (s.eql(chord)) break true;
        } else false) continue;
        try seen.append(allocator, chord);
        var ids: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (ids.items) |id| allocator.free(id);
            ids.deinit(allocator);
        }
        for (all) |other| {
            if (other.keys.contains(chord)) try ids.append(allocator, try allocator.dupe(u8, other.id));
        }
        if (ids.items.len < 2) {
            for (ids.items) |id| allocator.free(id);
            ids.deinit(allocator);
            continue;
        }
        const owned = try ids.toOwnedSlice(allocator);
        out.append(allocator, .{ .chord = chord, .ids = owned }) catch |err| {
            for (owned) |id| allocator.free(id);
            allocator.free(owned);
            return err;
        };
    };
    return out.toOwnedSlice(allocator);
}

pub fn freeClashes(allocator: std.mem.Allocator, clashes: []const Clash) void {
    for (clashes) |c| {
        for (c.ids) |id| allocator.free(id);
        allocator.free(c.ids);
    }
    allocator.free(clashes);
}

pub fn countPrefix(self: *Keybinds, prefix: []const u8) usize {
    self.lock.lockShared();
    defer self.lock.unlockShared();
    var n: usize = 0;
    for (self.bindings.items) |b| {
        if (std.mem.startsWith(u8, b.id, prefix)) n += 1;
    }
    return n;
}

fn remove(self: *Keybinds, binding: *Binding) void {
    self.lock.lock();
    defer self.lock.unlock();
    for (self.bindings.items, 0..) |b, i| {
        if (b == binding) {
            // Keeps the order, which clashes are listed in
            _ = self.bindings.orderedRemove(i);
            _ = self.changes.fetchAdd(1, .release);
            return;
        }
    }
}

// Window thread

fn onMessage(self: *Keybinds, m: *const Window.Message) ?isize {
    const event = m.event orelse {
        // Other char messages from a consumed press, like system and dead keys
        if (self.eat_chars and m.channel == .keyboard and !@import("root.zig").isImeMessage(m.raw.msg)) return 0;
        return null;
    };
    self.track(event);
    switch (event) {
        .key => |k| return if (self.onKey(k.key, k.down, k.repeat, k.mods)) @import("root.zig").handledResult(event) else null,
        .text => if (self.eat_chars) return @import("root.zig").handledResult(event),
        .focus => |focused| if (!focused) self.releaseAll(),
        else => {},
    }
    return null;
}

/// True if we swallow the key message.
fn onKey(self: *Keybinds, key: @import("root.zig").Key, down: bool, repeat: bool, mods: @import("root.zig").Mods) bool {
    if (!down) {
        self.eat_chars = false;
        self.release(&self.held, key);
        if (!self.consumed.contains(key)) return false;
        self.consumed.remove(key);
        self.blocker.hideKey(key, false);
        return true;
    }

    // A consumed key stays consumed until released, repeats included
    if (self.consumed.contains(key)) {
        self.eat_chars = true;
        return true;
    }
    self.eat_chars = false;
    if (repeat or self.paused.load(.acquire)) return false;

    var consume = false;
    {
        self.lock.lockShared();
        defer self.lock.unlockShared();
        const typing = self.typing.load(.acquire);
        for (self.bindings.items) |b| {
            if (!b.matches(key, mods) or (typing and !b.while_typing)) continue;
            self.press(&self.held, key, b.serial);
            consume = consume or b.consume;
        }
    }
    if (!consume) return false;
    self.consumed.insert(key);
    self.blocker.hideKey(key, true);
    self.eat_chars = true;
    return true;
}

/// Poll thread. Typing doesn't stop these, since a controller can't type.
fn onPad(self: *Keybinds, update: *const Gamepads.Update) void {
    for (update.changes) |change| {
        const key = change.key;
        setBit(&self.keys_down[@backingInt(key) / 32], @backingInt(key) % 32, change.down);
        if (!change.down) {
            self.release(&self.pad_held, key);
            if (self.pad_consumed.contains(key)) {
                self.pad_consumed.remove(key);
                self.blocker.hideKey(key, false);
            }
            continue;
        }
        if (self.paused.load(.acquire)) continue;
        var consume = false;
        {
            self.lock.lockShared();
            defer self.lock.unlockShared();
            for (self.bindings.items) |b| {
                if (!b.matches(key, .{})) continue;
                self.press(&self.pad_held, key, b.serial);
                consume = consume or b.consume;
            }
        }
        if (!consume) continue;
        self.pad_consumed.insert(key);
        self.blocker.hideKey(key, true);
    }
}

fn press(self: *Keybinds, list: *HeldList, key: @import("root.zig").Key, serial: u64) void {
    self.queueTrigger(.{ .serial = serial, .phase = .pressed });
    if (list.len == max_held) return; // we just won't report its release
    list.items[list.len] = .{ .key = key, .serial = serial };
    list.len += 1;
}

fn release(self: *Keybinds, list: *HeldList, key: @import("root.zig").Key) void {
    var i: usize = 0;
    while (i < list.len) {
        if (list.items[i].key != key) {
            i += 1;
            continue;
        }
        self.queueTrigger(.{ .serial = list.items[i].serial, .phase = .released });
        list.len -= 1;
        list.items[i] = list.items[list.len];
    }
}

/// Focus moved away so the releases won't come. Report them now. Controllers keep going.
fn releaseAll(self: *Keybinds) void {
    for (self.held.items[0..self.held.len]) |h| self.queueTrigger(.{ .serial = h.serial, .phase = .released });
    self.held.len = 0;
    var it = self.consumed.iterator();
    while (it.next()) |key| self.blocker.hideKey(key, false);
    self.consumed = .empty;
    self.eat_chars = false;
}

fn queueTrigger(self: *Keybinds, trigger: Trigger) void {
    self.queue.push(trigger) catch self.queue_overflowed.store(true, .monotonic);
}

fn track(self: *Keybinds, event: @import("root.zig").Event) void {
    switch (event) {
        .key => |k| setBit(&self.keys_down[@backingInt(k.key) / 32], @backingInt(k.key) % 32, k.down),
        .mouse_button => |b| setBit(&self.buttons_down, @backingInt(b.button), b.down),
        .mouse_move => |p| {
            self.mouse.store(packPoint(p), .release);
            self.mouse_seen.store(true, .release);
        },
        .focus => |focused| if (!focused) {
            // Controllers don't go through the window, so they keep their state
            for (std.enums.values(@import("root.zig").Key)) |key| {
                if (!@import("root.zig").isPad(key)) setBit(&self.keys_down[@backingInt(key) / 32], @backingInt(key) % 32, false);
            }
            self.buttons_down.store(0, .release);
        },
        else => {},
    }
}

fn setBit(word: *tuft_arch.atomic.Value(u32), bit: u32, on: bool) void {
    const mask = @as(u32, 1) << @intCast(bit);
    if (on) _ = word.fetchOr(mask, .acq_rel) else _ = word.fetchAnd(~mask, .acq_rel);
}

fn packPoint(p: @import("root.zig").Point) u64 {
    return (@as(u64, @as(u32, @bitCast(p.y))) << 32) | @as(u32, @bitCast(p.x));
}

// Any thread

/// Held now, going by the window's messages. Focus loss lets go of everything.
pub fn isDown(self: *const Keybinds, key: @import("root.zig").Key) bool {
    const bit = @backingInt(key);
    return self.keys_down[bit / 32].load(.acquire) & (@as(u32, 1) << @intCast(bit % 32)) != 0;
}

pub fn isButtonDown(self: *const Keybinds, button: @import("root.zig").MouseButton) bool {
    return self.buttons_down.load(.acquire) & (@as(u32, 1) << @intCast(@backingInt(button))) != 0;
}

/// Client coords from the last mouse move the window got. Null before one.
pub fn mousePos(self: *const Keybinds) ?@import("root.zig").Point {
    if (!self.mouse_seen.load(.acquire)) return null;
    const p = self.mouse.load(.acquire);
    return .{ .x = @bitCast(@as(u32, @truncate(p))), .y = @bitCast(@as(u32, @truncate(p >> 32))) };
}

// Render thread

/// Call at the start of each frame on the drawing thread.
pub fn deliver(self: *Keybinds) void {
    if (self.queue_overflowed.swap(false, .monotonic)) log.warn("Keybind queue full; dropped presses", .{});
    var pending: [Queue.capacity]Trigger = undefined;
    for (self.queue.drain(&pending)) |trigger| self.triggered.fire(.{trigger});
}

const tests = struct {
    const testing = std.testing;
    const api = @import("tuft_sys").win;
    const Rig = @import("testing.zig");

    const VK_F8 = 0x77;
    const VK_F9 = 0x78;
    const VK_A = 0x41;
    const key_up_flags: isize = @bitCast(@as(usize, 0xC000_0001));

    const Recorder = struct {
        presses: u32 = 0,
        releases: u32 = 0,

        fn onPhase(self: *Recorder, phase: Phase) void {
            switch (phase) {
                .pressed => self.presses += 1,
                .released => self.releases += 1,
            }
        }

        fn onPress(self: *Recorder) void {
            self.presses += 1;
        }
    };

    test "consumed binding hides key" {
        if (!@import("build_options").real_input) return error.SkipZigTest; // reads the real keyboard state
        var rig: Rig = undefined;
        try rig.init();
        defer rig.deinit();
        rig.present(); // attaches

        var rec: Recorder = .{};
        try rig.keybinds.bind(&rig.scope, .{ .id = "test.f8", .name = "F8", .keys = .{ .key = .f8 } }, &rec, Recorder.onPhase);

        try testing.expectEqual(0, rig.send(api.WM_KEYDOWN, VK_F8, 1));
        try testing.expectEqual(0, rec.presses); // delivered with the next frame
        try testing.expect(rig.blocker.isKeyHidden(.f8));
        rig.present();
        try testing.expectEqual(1, rec.presses);

        // Repeats, chars and release get swallowed too, and a repeat doesn't fire again
        _ = rig.send(api.WM_KEYDOWN, VK_F8, 1 | (1 << 30));
        _ = rig.send(api.WM_CHAR, 'x', 1);
        _ = rig.send(api.WM_KEYUP, VK_F8, key_up_flags);
        rig.present();
        try testing.expectEqual(1, rec.presses);
        try testing.expectEqual(1, rec.releases);
        try testing.expectEqual(0, Rig.game.count(api.WM_KEYDOWN));
        try testing.expectEqual(0, Rig.game.count(api.WM_CHAR));
        try testing.expectEqual(0, Rig.game.count(api.WM_KEYUP));
        try testing.expect(!rig.blocker.isKeyHidden(.f8));

        // Other keys go through
        _ = rig.send(api.WM_KEYDOWN, VK_A, 1);
        _ = rig.send(api.WM_CHAR, 'a', 1);
        try testing.expectEqual(1, Rig.game.count(api.WM_KEYDOWN));
        try testing.expectEqual(1, Rig.game.count(api.WM_CHAR));
    }

    test "unconsumed and typing" {
        if (!@import("build_options").real_input) return error.SkipZigTest; // reads the real keyboard state
        var rig: Rig = undefined;
        try rig.init();
        defer rig.deinit();
        rig.present();

        var shared: Recorder = .{};
        var typed: Recorder = .{};
        try rig.keybinds.bind(&rig.scope, .{ .id = "test.f8", .name = "F8", .keys = .{ .key = .f8 }, .consume = false }, &shared, Recorder.onPress);
        try rig.keybinds.bind(&rig.scope, .{ .id = "test.f9", .name = "F9", .keys = .{ .key = .f9 }, .while_typing = true }, &typed, Recorder.onPress);

        _ = rig.send(api.WM_KEYDOWN, VK_F8, 1);
        try testing.expectEqual(1, Rig.game.count(api.WM_KEYDOWN));
        _ = rig.send(api.WM_KEYUP, VK_F8, key_up_flags);
        rig.present();
        try testing.expectEqual(1, shared.presses);

        rig.keybinds.setTyping(true);
        _ = rig.send(api.WM_KEYDOWN, VK_F8, 1);
        _ = rig.send(api.WM_KEYUP, VK_F8, key_up_flags);
        _ = rig.send(api.WM_KEYDOWN, VK_F9, 1);
        _ = rig.send(api.WM_KEYUP, VK_F9, key_up_flags);
        rig.present();
        try testing.expectEqual(1, shared.presses);
        try testing.expectEqual(1, typed.presses);
    }

    test "held keys fire whatever else is down, and can be modifiers" {
        var rig: Rig = undefined;
        try rig.init();
        defer rig.deinit();
        rig.present();

        var fast: Recorder = .{};
        var ahead: Recorder = .{};
        try rig.keybinds.bind(&rig.scope, .{ .id = "test.fast", .name = "Fast", .keys = .{ .key = .left_shift }, .held = true, .consume = false }, &fast, Recorder.onPhase);
        try rig.keybinds.bind(&rig.scope, .{ .id = "test.ahead", .name = "Ahead", .keys = .{ .key = .w }, .held = true, .consume = false }, &ahead, Recorder.onPhase);
        try testing.expectError(error.InvalidChord, rig.keybinds.bind(&rig.scope, .{ .id = "test.shift_w", .name = "Shift W", .keys = .{ .key = .w, .mods = .{ .shift = true } }, .held = true }, &ahead, Recorder.onPhase));

        // Shift, then W while it's down
        _ = rig.send(api.WM_KEYDOWN, 0x10, 1 | (0x2A << 16));
        _ = rig.send(api.WM_KEYDOWN, 'W', 1);
        _ = rig.send(api.WM_KEYUP, 'W', key_up_flags);
        _ = rig.send(api.WM_KEYUP, 0x10, key_up_flags | (0x2A << 16));
        rig.present();
        try testing.expectEqual(1, fast.presses);
        try testing.expectEqual(1, fast.releases);
        try testing.expectEqual(1, ahead.presses);
        try testing.expectEqual(1, ahead.releases);
    }

    test "two keys on one binding press it once, till both let go" {
        var rig: Rig = undefined;
        try rig.init();
        defer rig.deinit();
        rig.present();

        var ahead: Recorder = .{};
        const keys = Keys.one(.{ .key = .w }).with(.{ .key = .up });
        try rig.keybinds.bind(&rig.scope, .{ .id = "test.ahead", .name = "Ahead", .keys = keys, .held = true, .consume = false }, &ahead, Recorder.onPhase);

        _ = rig.send(api.WM_KEYDOWN, 'W', 1);
        _ = rig.send(api.WM_KEYDOWN, 0x26, 1);
        _ = rig.send(api.WM_KEYUP, 'W', key_up_flags);
        rig.present();
        try testing.expectEqual(1, ahead.presses);
        try testing.expectEqual(0, ahead.releases);
        _ = rig.send(api.WM_KEYUP, 0x26, key_up_flags);
        rig.present();
        try testing.expectEqual(1, ahead.releases);
    }

    test "bind errors and unbind" {
        if (!@import("build_options").real_input) return error.SkipZigTest; // reads the real keyboard state
        var rig: Rig = undefined;
        try rig.init();
        defer rig.deinit();
        rig.present();

        var rec: Recorder = .{};
        const binding = try rig.keybinds.bindUnscoped(.{ .id = "test.f8", .name = "F8", .keys = .{ .key = .f8 } }, &rec, Recorder.onPress);
        try testing.expectError(error.AlreadyBound, rig.keybinds.bindUnscoped(.{ .id = "test.f8", .name = "again", .keys = .{ .key = .f9 } }, &rec, Recorder.onPress));
        try testing.expectError(error.InvalidChord, rig.keybinds.bindUnscoped(.{ .id = "test.shift", .name = "Shift", .keys = .{ .key = .left_shift } }, &rec, Recorder.onPress));

        _ = rig.send(api.WM_KEYDOWN, VK_F8, 1);
        binding.unbind(); // before its press is delivered
        rig.present();
        try testing.expectEqual(0, rec.presses);
        _ = rig.send(api.WM_KEYUP, VK_F8, key_up_flags);

        _ = rig.send(api.WM_KEYDOWN, VK_F8, 1);
        try testing.expectEqual(1, Rig.game.count(api.WM_KEYDOWN));
    }

    test "controller buttons" {
        const Fake = struct {
            state: ?Gamepads.State = null,

            fn poll(ctx: *anyopaque, out: []Gamepads.State) usize {
                const self: *@This() = @ptrCast(@alignCast(ctx));
                out[0] = self.state orelse return 0;
                return 1;
            }
        };
        // Made first so it goes last, after the keybinds let go of it
        const pads = try Gamepads.create(testing.allocator, testing.io, .{ .interval_ms = null });
        defer pads.destroy();
        var fake: Fake = .{};
        try pads.addSource(.{ .ctx = &fake, .poll = Fake.poll });
        var rig: Rig = undefined;
        try rig.init();
        defer rig.deinit();
        try rig.keybinds.attachGamepads(pads);

        var rec: Recorder = .{};
        try rig.keybinds.bind(&rig.scope, .{ .id = "test.back", .name = "Back", .keys = .{ .key = .gamepad_back } }, &rec, Recorder.onPhase);
        try testing.expectError(error.InvalidChord, rig.keybinds.bind(&rig.scope, .{ .id = "test.ctrl_a", .name = "Ctrl+A", .keys = .{ .key = .gamepad_a, .mods = .{ .ctrl = true } } }, &rec, Recorder.onPhase));

        fake.state = .{ .buttons = .{ .back = true, .a = true } };
        pads.pollNow();
        rig.present();
        try testing.expectEqual(1, rec.presses);
        try testing.expect(rig.keybinds.isDown(.gamepad_back) and rig.keybinds.isDown(.gamepad_a));
        try testing.expect(rig.blocker.isKeyHidden(.gamepad_back));
        try testing.expect(!rig.blocker.isKeyHidden(.gamepad_a));

        // Window focus going doesn't let go of controller buttons
        _ = rig.send(api.WM_KILLFOCUS, 0, 0);
        try testing.expect(rig.keybinds.isDown(.gamepad_back));

        fake.state = null; // unplugged
        pads.pollNow();
        rig.present();
        try testing.expectEqual(1, rec.releases);
        try testing.expect(!rig.keybinds.isDown(.gamepad_back));
        try testing.expect(!rig.blocker.isKeyHidden(.gamepad_back));
    }

    test "clashes" {
        var rig: Rig = undefined;
        try rig.init();
        defer rig.deinit();
        var rec: Recorder = .{};
        const before = rig.keybinds.changes.load(.acquire);
        try rig.keybinds.bind(&rig.scope, .{ .id = "a.f8", .name = "A", .keys = .{ .key = .f8 } }, &rec, Recorder.onPress);
        try rig.keybinds.bind(&rig.scope, .{ .id = "b.f9", .name = "B", .keys = .{ .key = .f9 } }, &rec, Recorder.onPress);
        const c = try rig.keybinds.bindUnscoped(.{ .id = "c.f8", .name = "C", .keys = .{ .key = .f8 } }, &rec, Recorder.onPress);
        // Ctrl+F8 is a different key
        try rig.keybinds.bind(&rig.scope, .{ .id = "d.ctrl_f8", .name = "D", .keys = .{ .key = .f8, .mods = .{ .ctrl = true } } }, &rec, Recorder.onPress);
        try testing.expect(rig.keybinds.changes.load(.acquire) > before);

        const clashes = try rig.keybinds.clashesAlloc(testing.allocator);
        defer freeClashes(testing.allocator, clashes);
        try testing.expectEqual(1, clashes.len);
        try testing.expectEqual(.f8, clashes[0].chord.key);
        try testing.expectEqual(2, clashes[0].ids.len);
        try testing.expectEqualStrings("a.f8", clashes[0].ids[0]);
        try testing.expectEqualStrings("c.f8", clashes[0].ids[1]);

        try c.rebind(.{ .key = .f10 });
        const after = try rig.keybinds.clashesAlloc(testing.allocator);
        defer freeClashes(testing.allocator, after);
        try testing.expectEqual(0, after.len);
        c.unbind();
    }

    test "focus loss releases held" {
        if (!@import("build_options").real_input) return error.SkipZigTest; // reads the real keyboard state
        var rig: Rig = undefined;
        try rig.init();
        defer rig.deinit();
        rig.present();

        var rec: Recorder = .{};
        try rig.keybinds.bind(&rig.scope, .{ .id = "test.f8", .name = "F8", .keys = .{ .key = .f8 } }, &rec, Recorder.onPhase);
        _ = rig.send(api.WM_KEYDOWN, VK_F8, 1);
        _ = rig.send(api.WM_KILLFOCUS, 0, 0);
        rig.present();
        try testing.expectEqual(1, rec.presses);
        try testing.expectEqual(1, rec.releases);
        try testing.expect(!rig.blocker.isKeyHidden(.f8));

        _ = rig.send(api.WM_KEYDOWN, VK_F8, 1);
        rig.present();
        try testing.expectEqual(2, rec.presses);
        _ = rig.send(api.WM_KEYUP, VK_F8, key_up_flags);
    }

    test "what's held and where the mouse is" {
        var rig: Rig = undefined;
        try rig.init();
        defer rig.deinit();
        rig.present();

        try testing.expect(!rig.keybinds.isDown(.a));
        try testing.expectEqual(null, rig.keybinds.mousePos());
        _ = rig.send(api.WM_KEYDOWN, VK_A, 1);
        _ = rig.send(api.WM_LBUTTONDOWN, 1, 0);
        _ = rig.send(api.WM_MOUSEMOVE, 0, (20 << 16) | 0xFFFE);
        try testing.expect(rig.keybinds.isDown(.a) and !rig.keybinds.isDown(.b));
        try testing.expect(rig.keybinds.isButtonDown(.left) and !rig.keybinds.isButtonDown(.right));
        try testing.expectEqual(@import("root.zig").Point{ .x = -2, .y = 20 }, rig.keybinds.mousePos().?);
        _ = rig.send(api.WM_KEYUP, VK_A, key_up_flags);
        try testing.expect(!rig.keybinds.isDown(.a));
        _ = rig.send(api.WM_KILLFOCUS, 0, 0);
        try testing.expect(!rig.keybinds.isButtonDown(.left));
    }
};

test {
    _ = tests;
}
