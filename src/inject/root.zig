//! Injects a DLL into another process, even x64 into WoW64. Runs in a launcher.

const std = @import("std");
const builtin = @import("builtin");

const log = std.log.scoped(.tuft_inject);

const native = switch (builtin.os.tag) {
    .windows => @import("win/process.zig"),
    else => @compileError("tuft supports Windows only"),
};
const spawn_native = switch (builtin.os.tag) {
    .windows => @import("win/spawn.zig"),
    else => @compileError("tuft supports Windows only"),
};

pub const Arch = enum {
    x86,
    x64,

    pub fn bits(self: Arch) u8 {
        return switch (self) {
            .x86 => 32,
            .x64 => 64,
        };
    }
};

/// An x86 injector can't target an x64 process.
pub const self_arch: Arch = switch (builtin.cpu.arch) {
    .x86 => .x86,
    .x86_64 => .x64,
    else => @compileError("tuft supports x86 and x64 only"),
};

pub const Process = native.Process;

pub const currentPid = native.currentPid;
pub const findPid = native.findPid;
/// Any case.
pub const pidsNamed = native.pidsNamed;
pub const CallOptions = native.CallOptions;

pub const Processes = native.Processes;
pub const ProcessEntry = native.ProcessEntry;
pub const Modules = native.Modules;
pub const ModuleEntry = native.ModuleEntry;
/// Works even on elevated processes.
pub const queryImage = native.queryImage;
pub const Image = native.Image;
/// Services are in 0.
pub const sessionOf = native.sessionOf;
/// Pids with their own visible top-level window. Caller owns the result.
pub const windowedPids = native.windowedPids;
pub const sleepMs = native.sleepMs;

pub const SpawnOptions = spawn_native.SpawnOptions;
pub const Spawned = spawn_native.Spawned;
/// Can start suspended so we inject before it runs.
pub const spawn = spawn_native.spawn;

/// `error.ArchMismatch` for an x86 injector and x64 target. Waits for a just-started target to load kernel32.
pub fn injectInto(allocator: std.mem.Allocator, pid: u32, dll_path: []const u8) !void {
    return injectStarting(allocator, pid, dll_path, .{ .pause = false });
}

pub const WatchOptions = struct {
    interval_ms: u32 = 50,
    /// Null waits forever.
    timeout_ms: ?u32 = null,
    /// Also take one that's already running.
    running: bool = false,
    /// Keep the game suspended until the DLL loads.
    pause: bool = true,
    /// Wait for the loader to be up, in ms.
    ready_timeout_ms: u32 = 5000,
};

pub const Target = union(enum) {
    /// Any case.
    name: []const u8,
    /// Matches the game's own exe, not another of the same name.
    path: []const u8,
    /// Any exe in this folder or below, for store-launched games.
    folder: []const u8,
};

/// Returns the first process that starts after `init`, unless `options.running`.
pub const Watch = struct {
    target: Target,
    options: WatchOptions,
    /// Running at start, ignored, or checked and not in the folder.
    known_buf: [max_known]u32 = undefined,
    known_len: usize = 0,

    const max_known = 4096;

    pub fn init(target: Target, options: WatchOptions) !Watch {
        var self: Watch = .{ .target = target, .options = options };
        if (options.running) return self;
        switch (target) {
            .name => |name| self.known_len = (try pidsNamed(name, &self.known_buf)).len,
            .path => |path| self.known_len = (try pidsNamed(std.fs.path.basename(path), &self.known_buf)).len,
            .folder => {
                var processes = try Processes.init();
                defer processes.deinit();
                while (processes.next()) |p| self.know(p.pid);
            },
        }
        return self;
    }

    /// Like one that turned out not to be the game.
    pub fn ignore(self: *Watch, pid: u32) void {
        if (self.isKnown(pid)) return;
        if (self.known_len == self.known_buf.len) {
            // Forget the oldest, it's probably long gone
            std.mem.copyForwards(u32, self.known_buf[0 .. self.known_len - 1], self.known_buf[1..self.known_len]);
            self.known_len -= 1;
        }
        self.know(pid);
    }

    pub fn wait(self: *Watch) !u32 {
        const deadline = if (self.options.timeout_ms) |t| native.nowMs() + t else null;
        while (true) {
            if (try self.poll()) |pid| return pid;
            if (deadline) |d| if (native.nowMs() >= d) return error.Timeout;
            native.sleepMs(self.options.interval_ms);
        }
    }

    fn poll(self: *Watch) !?u32 {
        switch (self.target) {
            .name => |name| {
                var now_buf: [64]u32 = undefined;
                for (try pidsNamed(name, &now_buf)) |pid| {
                    if (!self.isKnown(pid)) return pid;
                }
                return null;
            },
            .path => |path| {
                var now_buf: [64]u32 = undefined;
                for (try pidsNamed(std.fs.path.basename(path), &now_buf)) |pid| {
                    if (self.isKnown(pid)) continue;
                    var path_buf: [4096]u8 = undefined;
                    const image = queryImage(pid, &path_buf) catch continue;
                    if (samePath(path, image.path)) return pid;
                    // Same name, different place
                    self.ignore(pid);
                }
                return null;
            },
            .folder => |dir| {
                // Forget gone pids so a reused pid for the game still counts
                var still: [max_known]u32 = undefined;
                var n: usize = 0;
                var processes = try Processes.init();
                defer processes.deinit();
                while (processes.next()) |p| {
                    if (!self.isKnown(p.pid)) {
                        var path_buf: [4096]u8 = undefined;
                        if (queryImage(p.pid, &path_buf)) |image| {
                            if (isWithin(dir, image.path)) return p.pid;
                        } else |_| {}
                    }
                    if (n < still.len) {
                        still[n] = p.pid;
                        n += 1;
                    }
                }
                @memcpy(self.known_buf[0..n], still[0..n]);
                self.known_len = n;
                return null;
            },
        }
    }

    fn isKnown(self: *const Watch, pid: u32) bool {
        return std.mem.indexOfScalar(u32, self.known_buf[0..self.known_len], pid) != null;
    }

    fn know(self: *Watch, pid: u32) void {
        if (self.known_len == self.known_buf.len) return;
        self.known_buf[self.known_len] = pid;
        self.known_len += 1;
    }
};

/// Any case, either slash.
fn isWithin(dir: []const u8, path: []const u8) bool {
    const d = std.mem.trimEnd(u8, dir, "\\/");
    if (path.len <= d.len) return false;
    return sameChars(d, path[0..d.len]) and (path[d.len] == '\\' or path[d.len] == '/');
}

fn samePath(a: []const u8, b: []const u8) bool {
    return a.len == b.len and sameChars(a, b);
}

fn sameChars(a: []const u8, b: []const u8) bool {
    for (a, b) |x, y| {
        const fx = if (x == '/') '\\' else std.ascii.toLower(x);
        const fy = if (y == '/') '\\' else std.ascii.toLower(y);
        if (fx != fy) return false;
    }
    return true;
}

pub fn waitForStart(name: []const u8, options: WatchOptions) !u32 {
    var watch = try Watch.init(.{ .name = name }, options);
    return watch.wait();
}

/// Waits for the loader, then injects. Resumes a paused target while it's not ready or loading stalls.
pub fn injectStarting(allocator: std.mem.Allocator, pid: u32, dll_path: []const u8, options: WatchOptions) !void {
    var target = try Process.open(pid);
    defer target.close();
    if (target.arch() != self_arch and self_arch == .x86) return error.ArchMismatch;

    var paused = false;
    defer if (paused) target.unpause();
    const started = native.nowMs();
    const deadline = started + options.ready_timeout_ms;
    while (true) {
        if (target.exited()) return error.ProcessExited;
        if (options.pause) {
            try target.pause();
            paused = true;
        }
        // Not up yet if its module list fails or has no kernel32
        if (target.findModuleNow("kernel32.dll")) |base| {
            log.debug("pid {d} is ready after {d} ms (kernel32.dll at 0x{x}){s}", .{ pid, native.nowMs() - started, base, if (paused) ", paused" else "" });
            break;
        } else |_| {}
        if (paused) {
            target.unpause();
            paused = false;
        }
        if (native.nowMs() >= deadline) {
            log.err("pid {d} didn't load kernel32.dll within {d} ms", .{ pid, options.ready_timeout_ms });
            return error.NotReady;
        }
        native.sleepMs(1);
    }
    try target.loadLibrary(allocator, dll_path, .{ .paused = if (paused) &paused else null });
}

/// `waitForStart`, then `injectStarting`.
pub fn watchAndInject(allocator: std.mem.Allocator, name: []const u8, dll_path: []const u8, options: WatchOptions) !u32 {
    const pid = try waitForStart(name, options);
    try injectStarting(allocator, pid, dll_path, options);
    return pid;
}

test {
    std.testing.refAllDecls(@This());
    _ = native;
    _ = spawn_native;
}

test "memory read and write" {
    var target = try Process.open(currentPid());
    defer target.close();
    const memory = target.memory();
    var value: u32 = 0x1234_5678;
    const at = @intFromPtr(&value);
    try std.testing.expectEqual(0x1234_5678, try memory.load(u32, at));
    try memory.store(u32, at, 0xCAFE);
    try std.testing.expectEqual(0xCAFE, @as(*volatile u32, &value).*);
    try std.testing.expectError(error.Unreadable, memory.load(u32, 0));
}

test "symbols" {
    var target = try Process.open(currentPid());
    defer target.close();
    const symbols = target.symbols();
    const kernel32 = symbols.resolve("kernel32.dll").?;
    try std.testing.expectEqual(@import("tuft_sys").module.findBase("kernel32.dll").?, kernel32);
    var buf: [64]u8 = undefined;
    try std.testing.expect(std.ascii.eqlIgnoreCase("kernel32.dll+0x10", symbols.describe(kernel32 + 0x10, &buf).?));
    // Not in any image
    var value: u32 = 0;
    try std.testing.expectEqual(null, symbols.describe(@intFromPtr(&value), &buf));
    try std.testing.expectEqual(null, symbols.resolve("not_loaded_zz.dll"));
}

test "listing processes and modules" {
    const pid = currentPid();
    var path_buf: [4096]u8 = undefined;
    const image = try queryImage(pid, &path_buf);
    try std.testing.expectEqual(self_arch, image.arch);

    var processes = try Processes.init();
    defer processes.deinit();
    const us = while (processes.next()) |p| {
        if (p.pid == pid) break p;
    } else return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(std.fs.path.basename(image.path), us.name);

    var modules = try Modules.init(pid);
    defer modules.deinit();
    const kernel32 = while (modules.next()) |m| {
        if (std.ascii.eqlIgnoreCase(m.name, "kernel32.dll")) break m;
    } else return error.TestUnexpectedResult;
    try std.testing.expect(kernel32.base != 0 and kernel32.size != 0);
    // Depends on how tests run, a CI service is in 0
    _ = try sessionOf(pid);
    // No windows on CI, but no pid should show up twice
    const windowed = try windowedPids(std.testing.allocator);
    defer std.testing.allocator.free(windowed);
    for (windowed, 0..) |p, i| try std.testing.expect(std.mem.indexOfScalar(u32, windowed[i + 1 ..], p) == null);
}
