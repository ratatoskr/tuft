const std = @import("std");

const win = @import("api.zig");
const sync = @import("sync.zig");
const thread = @import("thread.zig");
const sound = @import("../sound.zig");

const SND_ASYNC: u32 = 0x0001;
const SND_NODEFAULT: u32 = 0x0002;
const SND_MEMORY: u32 = 0x0004;
const SND_ALIAS: u32 = 0x0001_0000;

extern "winmm" fn PlaySoundW(sound: ?*const anyopaque, module: ?*anyopaque, flags: u32) callconv(.winapi) win.BOOL;

const Request = union(enum) {
    wav: []u8,
    system: sound.System,
    stop,
};

pub const Player = struct {
    allocator: std.mem.Allocator,
    wake: sync.Signal,
    lock: sync.RwLock = .{},
    /// Under `lock`. Only the newest matters, since a new sound stops the last anyway.
    pending: ?Request = null,
    stopping: std.atomic.Value(bool) = .init(false),
    thread: *anyopaque = undefined,
    /// Its thread only. The system reads it while it plays, so it's freed once the next starts.
    playing: ?[]u8 = null,

    pub fn create(allocator: std.mem.Allocator) !*Player {
        const self = try allocator.create(Player);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .wake = try sync.Signal.init() };
        errdefer self.wake.deinit();
        self.thread = try thread.spawn(*Player, run, self);
        return self;
    }

    /// Stops what's playing.
    pub fn destroy(self: *Player) void {
        self.stopping.store(true, .release);
        self.wake.set();
        thread.join(self.thread);
        self.dropPending();
        self.wake.deinit();
        self.allocator.destroy(self);
    }

    /// Copies `wav`. Any thread.
    pub fn play(self: *Player, wav: []const u8) error{ InvalidSound, OutOfMemory }!void {
        if (!sound.isWav(wav)) return error.InvalidSound;
        self.post(.{ .wav = try self.allocator.dupe(u8, wav) });
    }

    /// Any thread.
    pub fn playSystem(self: *Player, which: sound.System) void {
        self.post(.{ .system = which });
    }

    /// Any thread.
    pub fn stop(self: *Player) void {
        self.post(.stop);
    }

    fn post(self: *Player, request: Request) void {
        {
            self.lock.lock();
            defer self.lock.unlock();
            self.freeRequest(self.pending);
            self.pending = request;
        }
        self.wake.set();
    }

    fn dropPending(self: *Player) void {
        self.lock.lock();
        defer self.lock.unlock();
        self.freeRequest(self.pending);
        self.pending = null;
    }

    fn freeRequest(self: *Player, request: ?Request) void {
        if (request) |r| switch (r) {
            .wav => |w| self.allocator.free(w),
            else => {},
        };
    }

    fn run(self: *Player) void {
        while (true) {
            _ = self.wake.wait(null);
            if (self.stopping.load(.acquire)) break;
            const request = blk: {
                self.lock.lock();
                defer self.lock.unlock();
                defer self.pending = null;
                break :blk self.pending orelse continue;
            };
            self.start(request);
        }
        self.start(.stop);
    }

    /// Its thread. Once the new one's started the old copy isn't being read anymore.
    fn start(self: *Player, request: Request) void {
        var now: ?[]u8 = null;
        switch (request) {
            .wav => |w| {
                if (PlaySoundW(w.ptr, null, SND_MEMORY | SND_ASYNC | SND_NODEFAULT).toBool()) now = w else self.allocator.free(w);
            },
            .system => |which| _ = PlaySoundW(aliasOf(which), null, SND_ALIAS | SND_ASYNC | SND_NODEFAULT),
            .stop => _ = PlaySoundW(null, null, 0),
        }
        if (self.playing) |old| self.allocator.free(old);
        self.playing = now;
    }
};

fn aliasOf(which: sound.System) [*:0]const u16 {
    const L = std.unicode.utf8ToUtf16LeStringLiteral;
    return switch (which) {
        .default => L("SystemDefault"),
        .info => L("SystemAsterisk"),
        .warning => L("SystemExclamation"),
        .@"error" => L("SystemHand"),
        .question => L("SystemQuestion"),
        .notification => L("SystemNotification"),
    };
}
