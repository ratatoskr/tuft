//! DLL load notifications. Already-loaded DLLs aren't reported.

const LoadWatch = @This();

const std = @import("std");

const win = @import("api.zig");

/// Names are only valid during the call.
pub const Module = struct {
    /// Like `dinput8.dll`.
    name: []const u16,
    path: []const u16,
    base: usize,
    size: usize,

    /// Case-insensitive, ASCII only.
    pub fn is(self: *const Module, name: []const u8) bool {
        if (self.name.len != name.len) return false;
        for (self.name, name) |w, c| {
            if (w > 0x7F or std.ascii.toLower(@intCast(w)) != std.ascii.toLower(c)) return false;
        }
        return true;
    }
};

pub const Listener = struct {
    ctx: ?*anyopaque,
    /// Inside the loader lock, so patch code but don't call in. True to also get `ready`.
    loaded: *const fn (ctx: ?*anyopaque, module: *const Module) bool,
    ready: ?*const fn (ctx: ?*anyopaque, module: *const Module) void = null,
};

/// Extras get dropped and logged.
const queue_len = 16;

const Pending = struct {
    path: [win.MAX_PATH:0]u16 = undefined,
    path_len: usize = 0,
    name_start: usize = 0,
    base: usize = 0,
    size: usize = 0,
};

allocator: std.mem.Allocator,
listener: Listener,
cookie: ?*anyopaque = null,
lock: std.atomic.Value(bool) = .init(false),
queue: [queue_len]Pending = @splat(.{}),
queued: usize = 0,
dropped: std.atomic.Value(u32) = .init(0),
wake: win.HANDLE,
stop: std.atomic.Value(bool) = .init(false),
thread: ?std.Thread = null,

const log = std.log.scoped(.tuft_sys);

pub fn create(allocator: std.mem.Allocator, listener: Listener) !*LoadWatch {
    const self = try allocator.create(LoadWatch);
    errdefer allocator.destroy(self);
    const wake = win.CreateEventW(null, .FALSE, .FALSE, null) orelse return error.CreateEventFailed;
    errdefer win.CloseHandle(wake);
    self.* = .{ .allocator = allocator, .listener = listener, .wake = wake };
    if (listener.ready != null) self.thread = try std.Thread.spawn(.{}, run, .{self});
    errdefer self.stopThread();
    if (win.LdrRegisterDllNotification(0, notified, self, &self.cookie) != .SUCCESS) return error.RegisterFailed;
    return self;
}

/// Waits for any `loaded` or `ready` that's running.
pub fn destroy(self: *LoadWatch) void {
    // Takes the loader lock, so no `loaded` is running after this
    if (self.cookie) |c| _ = win.LdrUnregisterDllNotification(c);
    self.stopThread();
    win.CloseHandle(self.wake);
    self.allocator.destroy(self);
}

fn stopThread(self: *LoadWatch) void {
    const t = self.thread orelse return;
    self.stop.store(true, .release);
    _ = win.SetEvent(self.wake);
    t.join();
    self.thread = null;
}

const LDR_DLL_NOTIFICATION_REASON_LOADED = 1;

fn notified(reason: u32, data: *const win.LDR_DLL_NOTIFICATION_DATA, ctx: ?*anyopaque) callconv(.winapi) void {
    if (reason != LDR_DLL_NOTIFICATION_REASON_LOADED) return;
    const self: *LoadWatch = @ptrCast(@alignCast(ctx.?));
    const module: Module = .{
        .name = data.BaseDllName.slice(),
        .path = data.FullDllName.slice(),
        .base = @intFromPtr(data.DllBase),
        .size = data.SizeOfImage,
    };
    if (!self.listener.loaded(self.listener.ctx, &module) or self.listener.ready == null) return;
    if (module.path.len > win.MAX_PATH) return;

    self.acquire();
    defer self.release();
    if (self.queued == queue_len) {
        _ = self.dropped.fetchAdd(1, .monotonic);
        return;
    }
    const p = &self.queue[self.queued];
    @memcpy(p.path[0..module.path.len], module.path);
    p.path[module.path.len] = 0;
    p.path_len = module.path.len;
    p.name_start = module.path.len - module.name.len;
    p.base = module.base;
    p.size = module.size;
    self.queued += 1;
    _ = win.SetEvent(self.wake);
}

fn run(self: *LoadWatch) void {
    while (true) {
        _ = win.WaitForSingleObject(self.wake, win.INFINITE);
        if (self.stop.load(.acquire)) return;
        if (self.dropped.swap(0, .monotonic) != 0) log.warn("Too many DLLs loading at once; some weren't reported ready", .{});
        while (self.take()) |p| {
            // Waits for DllMain and keeps it loaded
            const handle = win.LoadLibraryW(&p.path) orelse continue;
            defer _ = win.FreeLibrary(handle);
            const module: Module = .{ .name = p.path[p.name_start..p.path_len], .path = p.path[0..p.path_len], .base = p.base, .size = p.size };
            self.listener.ready.?(self.listener.ctx, &module);
        }
    }
}

fn take(self: *LoadWatch) ?Pending {
    self.acquire();
    defer self.release();
    if (self.queued == 0) return null;
    const p = self.queue[0];
    std.mem.copyForwards(Pending, self.queue[0 .. self.queued - 1], self.queue[1..self.queued]);
    self.queued -= 1;
    return p;
}

fn acquire(self: *LoadWatch) void {
    while (self.lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
}

fn release(self: *LoadWatch) void {
    self.lock.store(false, .release);
}

const tests = struct {
    const testing = std.testing;

    const Seen = struct {
        target: []const u8,
        loaded_base: std.atomic.Value(usize) = .init(0),
        ready_base: std.atomic.Value(usize) = .init(0),
        ready_handle: std.atomic.Value(usize) = .init(0),

        fn loaded(ctx: ?*anyopaque, m: *const Module) bool {
            const self: *Seen = @ptrCast(@alignCast(ctx.?));
            if (!m.is(self.target)) return false;
            self.loaded_base.store(m.base, .release);
            return true;
        }

        fn ready(ctx: ?*anyopaque, m: *const Module) void {
            const self: *Seen = @ptrCast(@alignCast(ctx.?));
            var name: [64:0]u16 = undefined;
            @memcpy(name[0..m.name.len], m.name);
            name[m.name.len] = 0;
            self.ready_handle.store(@intFromPtr(win.GetModuleHandleW(&name)), .release);
            self.ready_base.store(m.base, .release);
        }
    };

    test "loaded then ready" {
        // One this process hasn't loaded
        const candidates = [_][:0]const u8{ "dinput8.dll", "xinput1_4.dll", "mscms.dll", "winmm.dll" };
        const target = for (candidates) |c| {
            var wide: [32:0]u16 = undefined;
            const n = std.unicode.utf8ToUtf16Le(&wide, c) catch unreachable;
            wide[n] = 0;
            if (win.GetModuleHandleW(&wide) == null) break c;
        } else return error.SkipZigTest;

        var seen: Seen = .{ .target = target };
        const watch = try create(testing.allocator, .{ .ctx = &seen, .loaded = Seen.loaded, .ready = Seen.ready });
        defer watch.destroy();

        var wide: [32:0]u16 = undefined;
        const n = try std.unicode.utf8ToUtf16Le(&wide, target);
        wide[n] = 0;
        const handle = win.LoadLibraryW(&wide) orelse return error.LoadFailed;
        defer _ = win.FreeLibrary(handle);

        try testing.expectEqual(@intFromPtr(handle), seen.loaded_base.load(.acquire));
        var waited: u32 = 0;
        while (seen.ready_base.load(.acquire) == 0 and waited < 2000) : (waited += 1) win.Sleep(1);
        try testing.expectEqual(@intFromPtr(handle), seen.ready_base.load(.acquire));
        try testing.expectEqual(@intFromPtr(handle), seen.ready_handle.load(.acquire));
    }

    test "case-insensitive names" {
        const name = std.unicode.utf8ToUtf16LeStringLiteral("DInput8.DLL");
        const m: Module = .{ .name = name, .path = name, .base = 0, .size = 0 };
        try testing.expect(m.is("dinput8.dll"));
        try testing.expect(!m.is("dinput.dll"));
    }
};

test {
    _ = tests;
}
