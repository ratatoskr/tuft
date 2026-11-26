//! Polls controllers from every source on its own thread and reports changes. Only XInput so far.

const Gamepads = @This();

const std = @import("std");

const tuft_event = @import("tuft_event");
const tuft_sys = @import("tuft_sys");

const input = @import("root.zig");
const Blocker = @import("Blocker.zig");

const log = std.log.scoped(.tuft_input);

/// Across all sources.
pub const max_pads = 8;

/// One controller right now.
pub const State = struct {
    buttons: input.PadButtons = .{},
    axes: input.Axes = .{},
};

/// Reads controllers. Only the poll thread calls it.
pub const Source = struct {
    ctx: *anyopaque,
    /// Writes the connected controllers to `out` and returns how many.
    poll: *const fn (ctx: *anyopaque, out: []State) usize,
};

pub const Change = struct { key: input.Key, down: bool };

pub const Update = struct {
    /// Buttons that went down or up since the last poll.
    changes: []const Change,
    /// Every connected controller merged into one.
    merged: State,
    connected: bool,
    /// Sticks or triggers moved, or `connected` changed.
    axes_changed: bool,

    pub fn axes(self: *const Update) input.PadAxes {
        return .{ .connected = self.connected, .axes = self.merged.axes };
    }
};

pub const UpdateEvent = tuft_event.Event(fn (*const Update) void);

pub const Options = struct {
    /// Null means only `pollNow` polls, like in tests.
    interval_ms: ?u32 = 8,
};

allocator: std.mem.Allocator,
io: std.Io,
options: Options,
/// Poll thread, after a poll that changed something.
changed: UpdateEvent,
lock: tuft_sys.sync.RwLock = .{},
/// Under `lock`.
sources: std.ArrayList(Source) = .empty,
/// Under `lock`. What the last poll saw.
current: State = .{},
current_connected: bool = false,
thread: ?*anyopaque = null,
stopping: std.atomic.Value(bool) = .init(false),

pub fn create(allocator: std.mem.Allocator, io: std.Io, options: Options) !*Gamepads {
    const self = try allocator.create(Gamepads);
    errdefer allocator.destroy(self);
    self.* = .{ .allocator = allocator, .io = io, .options = options, .changed = .init(allocator) };
    errdefer self.changed.deinit();
    if (options.interval_ms != null) self.thread = try tuft_sys.thread.spawn(*Gamepads, run, self);
    return self;
}

/// Unsubscribe from `changed` and take the sources away after.
pub fn destroy(self: *Gamepads) void {
    self.stopping.store(true, .release);
    if (self.thread) |t| tuft_sys.thread.join(t);
    self.sources.deinit(self.allocator);
    self.changed.deinit();
    self.allocator.destroy(self);
}

/// Any thread. The source has to stay alive until removed.
pub fn addSource(self: *Gamepads, source: Source) !void {
    self.lock.lock();
    defer self.lock.unlock();
    try self.sources.append(self.allocator, source);
}

/// Waits out a poll using it.
pub fn removeSource(self: *Gamepads, ctx: *anyopaque) void {
    self.lock.lock();
    defer self.lock.unlock();
    for (self.sources.items, 0..) |s, i| {
        if (s.ctx == ctx) {
            _ = self.sources.orderedRemove(i);
            return;
        }
    }
}

/// Merged, as of the last poll. Any thread.
pub fn state(self: *Gamepads) State {
    self.lock.lockShared();
    defer self.lock.unlockShared();
    return self.current;
}

pub fn connected(self: *Gamepads) bool {
    self.lock.lockShared();
    defer self.lock.unlockShared();
    return self.current_connected;
}

fn run(self: *Gamepads) void {
    const interval = self.options.interval_ms.?;
    while (!self.stopping.load(.acquire)) {
        self.pollNow();
        tuft_sys.thread.sleepMs(interval);
    }
}

/// Polls every source and fires `changed` if anything did. Only for when there's no poll thread.
pub fn pollNow(self: *Gamepads) void {
    // Our own XInput hooks would hide the controllers from us otherwise
    const bypass = Blocker.Bypass.begin();
    defer bypass.end();

    var pads: [max_pads]State = undefined;
    var count: usize = 0;
    var merged: State = .{};
    var changes: [std.enums.values(input.PadButton).len]Change = undefined;
    var changed_count: usize = 0;
    var update: Update = undefined;
    {
        self.lock.lock();
        defer self.lock.unlock();
        for (self.sources.items) |s| {
            if (count == pads.len) break;
            count += @min(s.poll(s.ctx, pads[count..]), pads.len - count);
        }
        for (pads[0..count]) |p| merged = merge(merged, p);

        const was = self.current;
        const was_connected = self.current_connected;
        for (std.enums.values(input.PadButton)) |b| {
            const down = merged.buttons.has(b);
            if (down != was.buttons.has(b)) {
                changes[changed_count] = .{ .key = b.key(), .down = down };
                changed_count += 1;
            }
        }
        const now_connected = count != 0;
        update = .{
            .changes = changes[0..changed_count],
            .merged = merged,
            .connected = now_connected,
            .axes_changed = now_connected != was_connected or !merged.axes.eql(was.axes),
        };
        self.current = merged;
        self.current_connected = now_connected;
        if (now_connected != was_connected) log.debug("Controller {s}", .{if (now_connected) "connected" else "gone"});
    }
    if (update.changes.len != 0 or update.axes_changed) self.changed.fire(.{&update});
}

/// Buttons from either, and each axis from whichever is pushed further.
pub fn merge(a: State, b: State) State {
    var out: State = .{ .buttons = .fromBits(a.buttons.bits() | b.buttons.bits()) };
    inline for (@typeInfo(input.Axes).@"struct".field_names) |name| {
        const x = @field(a.axes, name);
        const y = @field(b.axes, name);
        @field(out.axes, name) = if (@abs(y) > @abs(x)) y else x;
    }
    return out;
}

const tests = struct {
    const testing = std.testing;

    const Fake = struct {
        pads: [2]?State = .{ null, null },

        fn source(self: *Fake) Source {
            return .{ .ctx = self, .poll = poll };
        }

        fn poll(ctx: *anyopaque, out: []State) usize {
            const self: *Fake = @ptrCast(@alignCast(ctx));
            var n: usize = 0;
            for (self.pads) |p| if (p) |s| {
                if (n == out.len) break;
                out[n] = s;
                n += 1;
            };
            return n;
        }
    };

    const Recorder = struct {
        changes: std.ArrayList(Change) = .empty,
        axes: ?input.PadAxes = null,
        fires: u32 = 0,

        fn onUpdate(self: *Recorder, update: *const Update) void {
            self.fires += 1;
            self.changes.appendSlice(testing.allocator, update.changes) catch unreachable;
            if (update.axes_changed) self.axes = update.axes();
        }
    };

    test "presses, releases and merging pads" {
        const pads = try Gamepads.create(testing.allocator, testing.io, .{ .interval_ms = null });
        defer pads.destroy();
        var fake: Fake = .{};
        try pads.addSource(fake.source());
        var scope = tuft_event.Scope.init(testing.allocator);
        defer scope.deinit();
        var rec: Recorder = .{};
        defer rec.changes.deinit(testing.allocator);
        try pads.changed.subscribe(&scope, &rec, Recorder.onUpdate);

        pads.pollNow();
        try testing.expectEqual(0, rec.fires); // nothing connected, nothing changed

        fake.pads[0] = .{ .buttons = .{ .a = true }, .axes = .{ .left_x = 0.5 } };
        fake.pads[1] = .{ .buttons = .{ .start = true }, .axes = .{ .left_x = -0.75, .right_trigger = 1 } };
        pads.pollNow();
        try testing.expectEqualSlices(Change, &.{ .{ .key = .gamepad_a, .down = true }, .{ .key = .gamepad_start, .down = true } }, rec.changes.items);
        try testing.expect(rec.axes.?.connected);
        try testing.expectEqual(@as(f32, -0.75), rec.axes.?.axes.left_x);
        try testing.expectEqual(@as(f32, 1), rec.axes.?.axes.right_trigger);
        try testing.expect(pads.state().buttons.eql(.{ .a = true, .start = true }));

        pads.pollNow();
        try testing.expectEqual(1, rec.fires); // same again is quiet

        rec.changes.clearRetainingCapacity();
        fake.pads = .{ null, null };
        pads.pollNow();
        try testing.expectEqualSlices(Change, &.{ .{ .key = .gamepad_a, .down = false }, .{ .key = .gamepad_start, .down = false } }, rec.changes.items);
        try testing.expect(!rec.axes.?.connected);
        try testing.expect(!pads.connected());
    }

    test "poll thread" {
        const pads = try Gamepads.create(testing.allocator, testing.io, .{ .interval_ms = 1 });
        defer pads.destroy();
        var fake: Fake = .{ .pads = .{ .{ .buttons = .{ .back = true } }, null } };
        try pads.addSource(fake.source());
        var tries: u32 = 0;
        while (!pads.state().buttons.has(.back) and tries < 1000) : (tries += 1) try testing.io.sleep(.fromMilliseconds(1), .awake);
        try testing.expect(pads.connected());
        pads.removeSource(&fake);
    }
};

test {
    _ = tests;
}
