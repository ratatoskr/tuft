//! Hides input from the game while the overlay is using it.

const Blocker = @This();

const std = @import("std");
const builtin = @import("builtin");

const tuft_event = @import("tuft_event");

const Window = @import("Window.zig");

const log = std.log.scoped(.tuft_input);

pub const Device = @import("root.zig").Device;
pub const Devices = @import("root.zig").Devices;
pub const Channel = @import("root.zig").Channel;
pub const Channels = @import("root.zig").Channels;
pub const MouseButton = @import("root.zig").MouseButton;

pub const Backend = switch (builtin.os.tag) {
    .windows => @import("win/blocker.zig"),
    else => @compileError("Unsupported operating system"),
};

threadlocal var bypassing: bool = false;

allocator: std.mem.Allocator,
window: *Window,
backend: *Backend,
subscriptions: tuft_event.Scope,
captured_bits: std.atomic.Value(u8) = .init(0),
/// Devices the next release task lets go of.
pending_release: std.atomic.Value(u8) = .init(0),
/// Mouse buttons whose presses are hidden from the game, by `MouseButton` bit, see `consumeButtons`.
consume_buttons: std.atomic.Value(u8) = .init(0),
/// Ones pressed while consumed, hidden till they're let go. The window thread writes.
consumed_buttons: std.atomic.Value(u8) = .init(0),
consume_wheel: std.atomic.Value(bool) = .init(false),

/// Failed hooks get logged and skipped. Nothing is hidden until `capture`.
pub fn create(allocator: std.mem.Allocator, window: *Window) !*Blocker {
    const self = try allocator.create(Blocker);
    errdefer allocator.destroy(self);
    self.* = .{ .allocator = allocator, .window = window, .backend = undefined, .subscriptions = .init(allocator) };
    errdefer self.subscriptions.deinit();

    self.backend = try Backend.create(allocator, self);
    errdefer self.backend.destroy();
    try window.message.subscribeOpts(&self.subscriptions, self, hide, .{ .priority = Window.Priority.hide });
    try window.message.subscribeOpts(&self.subscriptions, self, observe, .{ .priority = Window.Priority.observe });
    return self;
}

/// Call after `window.closeTasks()` since a release task may be queued.
pub fn destroy(self: *Blocker) void {
    self.subscriptions.deinit();
    self.capture(.empty);
    self.backend.destroy();
    self.allocator.destroy(self);
}

/// Takes `channels` from the game and gives back the rest. Any thread.
pub fn capture(self: *Blocker, channels: Channels) void {
    const before: Channels = .{ .bits = .{ .mask = @intCast(self.captured_bits.swap(channels.bits.mask, .acq_rel)) } };
    const taken = channels.differenceWith(before);
    const returned = before.differenceWith(channels);
    if (taken.count() == 0 and returned.count() == 0) return;

    var b = Bypass.begin();
    defer b.end();
    self.backend.captureChanged(taken, returned);

    // Release whatever the game was holding on a device it can't see anymore
    var release: Devices = .empty;
    if (taken.contains(.keyboard)) release.insert(.keyboard);
    if (taken.contains(.mouse_buttons)) release.insert(.mouse);
    if (release.count() != 0) self.requestRelease(release);
}

pub fn captured(self: *const Blocker) Channels {
    return .{ .bits = .{ .mask = @intCast(self.captured_bits.load(.acquire)) } };
}

/// Hides `key` from game polling for a press the game never got. Any thread.
pub fn hideKey(self: *Blocker, key: @import("root.zig").Key, hide_it: bool) void {
    self.backend.setKeyHidden(key, hide_it);
}

pub fn isKeyHidden(self: *const Blocker, key: @import("root.zig").Key) bool {
    return self.backend.isKeyHidden(key);
}

/// Hides presses of these `MouseButton` bits from the game, each till released. Any thread.
pub fn consumeButtons(self: *Blocker, buttons: u8) void {
    self.consume_buttons.store(buttons, .release);
}

/// Hides the wheel from the game. Any thread.
pub fn consumeWheel(self: *Blocker, on: bool) void {
    self.consume_wheel.store(on, .release);
}

pub fn buttonBit(button: MouseButton) u8 {
    return @as(u8, 1) << @intCast(@backingInt(button));
}

/// Buttons hidden on their own right now, pressed while consumed or about to be. Any thread.
pub fn hiddenButtons(self: *const Blocker) u8 {
    if (bypassing) return 0;
    return self.consume_buttons.load(.acquire) | self.consumed_buttons.load(.acquire);
}

pub fn hidesWheel(self: *const Blocker) bool {
    return !bypassing and (self.consume_wheel.load(.acquire) or self.captured().contains(.mouse_buttons));
}

pub fn isBypassing() bool {
    return bypassing;
}

/// The current thread counts as the game unless it's bypassing.
pub fn hides(self: *const Blocker, channel: Channel) bool {
    return !bypassing and self.captured().contains(channel);
}

pub fn hidden(self: *const Blocker) Channels {
    return if (bypassing) .empty else self.captured();
}

/// Lets the current thread see real input until `end`. Nestable.
pub const Bypass = struct {
    was: bool,

    pub fn begin() Bypass {
        defer bypassing = true;
        return .{ .was = bypassing };
    }

    pub fn end(self: Bypass) void {
        bypassing = self.was;
    }
};

fn hide(self: *Blocker, m: *const Window.Message) ?isize {
    if (m.channel) |channel| {
        if (self.hides(channel)) return self.backend.swallowed(m.raw);
        if (self.consumes(m)) return self.backend.swallowed(m.raw);
        // Pass it on, minus anything for hidden channels
        self.backend.stripMessage(m.raw);
        return null;
    }
    return self.backend.hideMessage(m.raw);
}

/// A consumed button's press, its release, or the wheel while it's consumed. Window thread.
fn consumes(self: *Blocker, m: *const Window.Message) bool {
    if (bypassing) return false;
    const event = m.event orelse return false;
    switch (event) {
        .wheel => return self.consume_wheel.load(.acquire),
        .mouse_button => |b| {
            const bit = buttonBit(b.button);
            const consumed = self.consumed_buttons.load(.acquire);
            if (b.down) {
                if (consumed & bit != 0) return true;
                if (self.consume_buttons.load(.acquire) & bit == 0) return false;
                self.consumed_buttons.store(consumed | bit, .release);
                self.backend.setButtonHidden(b.button, true);
                return true;
            }
            if (consumed & bit == 0) return false;
            self.consumed_buttons.store(consumed & ~bit, .release);
            self.backend.setButtonHidden(b.button, false);
            return true;
        },
        else => return false,
    }
}

fn observe(self: *Blocker, m: *const Window.Message) ?isize {
    // The releases won't come once it's lost focus
    if (m.event) |event| if (event == .focus and !event.focus) self.releaseConsumed();
    self.backend.observe(m.raw);
    return null;
}

fn releaseConsumed(self: *Blocker) void {
    const consumed = self.consumed_buttons.swap(0, .acq_rel);
    for (std.enums.values(MouseButton)) |b| {
        if (consumed & buttonBit(b) != 0) self.backend.setButtonHidden(b, false);
    }
}

fn requestRelease(self: *Blocker, devices: Devices) void {
    // Requests before the release task runs get merged into it
    if (self.pending_release.fetchOr(toBits(devices), .acq_rel) != 0) return;
    self.window.tasks.post(self, releaseHeld) catch |err| {
        log.warn("Couldn't schedule releasing held input: {t}", .{err});
        _ = self.pending_release.swap(0, .acq_rel);
    };
}

/// Window thread.
fn releaseHeld(self: *Blocker) void {
    const devices = fromBits(self.pending_release.swap(0, .acq_rel));
    self.backend.release(devices, self.window);
}

fn toBits(devices: Devices) u8 {
    return devices.bits.mask;
}

fn fromBits(bits: u8) Devices {
    return .{ .bits = .{ .mask = @intCast(bits) } };
}
