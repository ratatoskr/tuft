//! Calls back once a DLL is loaded and initialized. The DLL gets pinned.

const WhenLoaded = @This();

const std = @import("std");

const win = @import("api.zig");
const module = @import("module.zig");
const LoadWatch = @import("loads.zig");

pub const Listener = struct {
    ctx: ?*anyopaque,
    ready: *const fn (ctx: ?*anyopaque, base: usize) void,
};

const State = enum(u8) { waiting, firing, done };

allocator: std.mem.Allocator,
/// ASCII, like `dinput8.dll`.
name: []const u8,
listener: Listener,
state: std.atomic.Value(State) = .init(.waiting),
/// Link in the hub's list.
next: ?*WhenLoaded = null,

/// May call `ready` before returning. `name` must outlive it.
pub fn create(allocator: std.mem.Allocator, name: []const u8, listener: Listener) !*WhenLoaded {
    const self = try allocator.create(WhenLoaded);
    errdefer allocator.destroy(self);
    self.* = .{ .allocator = allocator, .name = name, .listener = listener };
    try hub.add(allocator, self);
    // Check after joining so a load in between isn't missed
    if (module.findBase(name)) |base| self.fire(base);
    return self;
}

/// Waits for a running `ready`. Don't call from `ready`.
pub fn destroy(self: *WhenLoaded) void {
    hub.remove(self);
    // Nothing new can start now, let one in progress finish
    if (self.state.cmpxchgStrong(.waiting, .done, .acq_rel, .acquire)) |_| {
        while (self.state.load(.acquire) == .firing) win.Sleep(1);
    }
    self.allocator.destroy(self);
}

/// True once `ready` has been called or is running.
pub fn fired(self: *const WhenLoaded) bool {
    return self.state.load(.acquire) != .waiting;
}

fn fire(self: *WhenLoaded, base: usize) void {
    if (self.state.cmpxchgStrong(.waiting, .firing, .acq_rel, .acquire) != null) return;
    pin(base);
    self.listener.ready(self.listener.ctx, base);
    self.state.store(.done, .release);
}

fn nameIs(self: *const WhenLoaded, m: *const LoadWatch.Module) bool {
    return m.is(self.name);
}

/// They share one `LoadWatch` thread, so a slow `ready` holds up the others.
const Hub = struct {
    lock: std.atomic.Value(bool) = .init(false),
    head: ?*WhenLoaded = null,
    watch: ?*LoadWatch = null,
    /// It frees itself with this.
    allocator: ?std.mem.Allocator = null,

    fn acquire(self: *Hub) void {
        while (self.lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    }

    fn release(self: *Hub) void {
        self.lock.store(false, .release);
    }

    fn add(self: *Hub, allocator: std.mem.Allocator, w: *WhenLoaded) !void {
        // Outside the lock since it spawns a thread. If two race, one wins
        if (self.watchNeeded()) {
            const watch = try LoadWatch.create(allocator, .{ .ctx = self, .loaded = loaded, .ready = ready });
            self.acquire();
            if (self.watch == null) {
                self.watch = watch;
                self.allocator = allocator;
                w.next = self.head;
                self.head = w;
                self.release();
                return;
            }
            self.release();
            watch.destroy();
        }
        self.acquire();
        defer self.release();
        w.next = self.head;
        self.head = w;
    }

    fn watchNeeded(self: *Hub) bool {
        self.acquire();
        defer self.release();
        return self.watch == null;
    }

    fn remove(self: *Hub, w: *WhenLoaded) void {
        const last_watch = blk: {
            self.acquire();
            defer self.release();
            var link = &self.head;
            while (link.*) |node| : (link = &node.next) {
                if (node == w) {
                    link.* = node.next;
                    break;
                }
            }
            if (self.head != null) break :blk null;
            const watch = self.watch;
            self.watch = null;
            break :blk watch;
        };
        // Outside the lock, it waits for its thread which might be in `ready`
        if (last_watch) |watch| watch.destroy();
    }

    /// Inside the loader. True if anyone's waiting for this DLL.
    fn loaded(ctx: ?*anyopaque, m: *const LoadWatch.Module) bool {
        const self: *Hub = @ptrCast(@alignCast(ctx.?));
        self.acquire();
        defer self.release();
        var node = self.head;
        while (node) |w| : (node = w.next) {
            if (!w.fired() and w.nameIs(m)) return true;
        }
        return false;
    }

    fn ready(ctx: ?*anyopaque, m: *const LoadWatch.Module) void {
        const self: *Hub = @ptrCast(@alignCast(ctx.?));
        // Claim under the lock so `destroy` waits, then fire outside it
        var claimed: [16]*WhenLoaded = undefined;
        var n: usize = 0;
        {
            self.acquire();
            defer self.release();
            var node = self.head;
            while (node) |w| : (node = w.next) {
                if (n == claimed.len) break;
                if (!w.nameIs(m)) continue;
                if (w.state.cmpxchgStrong(.waiting, .firing, .acq_rel, .acquire) != null) continue;
                claimed[n] = w;
                n += 1;
            }
        }
        if (n != 0) pin(m.base);
        for (claimed[0..n]) |w| {
            w.listener.ready(w.listener.ctx, m.base);
            w.state.store(.done, .release);
        }
    }
};

var hub: Hub = .{};

fn pin(base: usize) void {
    var handle: ?win.HINSTANCE = null;
    _ = win.GetModuleHandleExW(win.GET_MODULE_HANDLE_EX_FLAG_PIN | win.GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS, @ptrFromInt(base), &handle);
}

const tests = struct {
    const testing = std.testing;

    const Count = struct {
        calls: std.atomic.Value(u32) = .init(0),
        base: std.atomic.Value(usize) = .init(0),

        fn ready(ctx: ?*anyopaque, base: usize) void {
            const self: *Count = @ptrCast(@alignCast(ctx.?));
            self.base.store(base, .release);
            _ = self.calls.fetchAdd(1, .acq_rel);
        }
    };

    test "already loaded fires now" {
        var count: Count = .{};
        const w = try create(testing.allocator, "kernel32.dll", .{ .ctx = &count, .ready = Count.ready });
        defer w.destroy();
        try testing.expectEqual(1, count.calls.load(.acquire));
        try testing.expectEqual(module.findBase("kernel32.dll").?, count.base.load(.acquire));
    }

    test "later load fires once each" {
        const candidates = [_][]const u8{ "xinput1_4.dll", "mscms.dll", "hid.dll", "winmm.dll" };
        const target = for (candidates) |c| {
            if (module.findBase(c) == null) break c;
        } else return error.SkipZigTest;

        var a: Count = .{};
        var b: Count = .{};
        const wa = try create(testing.allocator, target, .{ .ctx = &a, .ready = Count.ready });
        defer wa.destroy();
        const wb = try create(testing.allocator, target, .{ .ctx = &b, .ready = Count.ready });
        defer wb.destroy();
        try testing.expectEqual(0, a.calls.load(.acquire));

        var wide: [32:0]u16 = undefined;
        const n = try std.unicode.utf8ToUtf16Le(&wide, target);
        wide[n] = 0;
        const handle = win.LoadLibraryW(&wide) orelse return error.LoadFailed;
        defer _ = win.FreeLibrary(handle);

        var waited: u32 = 0;
        while ((a.calls.load(.acquire) == 0 or b.calls.load(.acquire) == 0) and waited < 2000) : (waited += 1) win.Sleep(1);
        try testing.expectEqual(1, a.calls.load(.acquire));
        try testing.expectEqual(1, b.calls.load(.acquire));
        try testing.expectEqual(@intFromPtr(handle), a.base.load(.acquire));
        try testing.expect(wa.fired());

        // Loading it again doesn't fire again
        const again = win.LoadLibraryW(&wide) orelse return error.LoadFailed;
        _ = win.FreeLibrary(again);
        win.Sleep(20);
        try testing.expectEqual(1, a.calls.load(.acquire));
    }

    test "destroyed before load" {
        var count: Count = .{};
        const w = try create(testing.allocator, "tuft_no_such_dll.dll", .{ .ctx = &count, .ready = Count.ready });
        try testing.expect(!w.fired());
        w.destroy();
        try testing.expectEqual(0, count.calls.load(.acquire));
    }
};

test {
    _ = tests;
}
