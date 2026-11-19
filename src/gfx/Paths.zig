//! Every path at once, for when we don't know the game's API.

const Paths = @This();

const std = @import("std");

const sys = @import("tuft_sys");

const gfx = @import("root.zig");
const Frame = gfx.Frame;

const log = std.log.scoped(.tuft_gfx);

/// Null where we couldn't hook it.
const Hooks = struct {
    dxgi: ?*gfx.dxgi.PresentHook = null,
    d3d9: ?*gfx.d3d9.PresentHook = null,
    opengl: ?*gfx.opengl.PresentHook = null,
    vulkan: ?*gfx.vulkan.PresentHook = null,
};
pub const Kind = std.meta.FieldEnum(Hooks);

/// We hook each path once its DLL is loaded.
pub const dll_names: std.EnumArray(Kind, []const u8) = .init(.{
    .dxgi = "dxgi.dll",
    .d3d9 = "d3d9.dll",
    .opengl = "opengl32.dll",
    .vulkan = "vulkan-1.dll",
});
const no_owner = std.math.maxInt(u8);

pub const Options = struct {
    /// We got in before the game made any devices, so paths hook creation instead of probing.
    early: bool = false,
    /// What the game presents with, from a previous attach. Nobody probes.
    known: ?Known = null,
};

/// D3D9's device or DXGI's swap chain, ref held by the caller. Null for OpenGL and Vulkan.
pub const Known = struct {
    api: gfx.Api,
    object: ?*anyopaque,
};

pub fn kindOf(api: gfx.Api) ?Kind {
    return switch (api) {
        .d3d9 => .d3d9,
        .d3d10, .d3d11, .d3d12 => .dxgi,
        .opengl => .opengl,
        .vulkan => .vulkan,
        _ => null,
    };
}

allocator: std.mem.Allocator,
listener: gfx.Listener,
options: Options = .{},
/// True during `create`. A path whose DLL is already loaded might be in use, unless `early`.
creating: bool = true,
hooks: Hooks = .{},
relays: std.EnumArray(Kind, Relay),
/// The `Kind` whose reports reach the listener, or `no_owner`.
owner: std.atomic.Value(u8) = .init(no_owner),
/// A D3D9, OpenGL or Vulkan path presented. DXGI can't claim since drivers present through it.
claimed: std.atomic.Value(bool) = .init(false),
/// Held while putting hooks in or taking them out.
lock: sys.sync.RwLock = .{},
waits: std.EnumArray(Kind, ?*sys.module.WhenLoaded) = .initFill(null),
/// Set by `enable`, so paths hooked later get enabled right away. Guarded by `lock`.
enabled: bool = false,

/// Hooks each loaded path, disabled. `enable` starts the reports. Init `tuft_hook` first.
pub fn create(allocator: std.mem.Allocator, listener: gfx.Listener, options: Options) !*Paths {
    const self = try allocator.create(Paths);
    errdefer allocator.destroy(self);
    self.* = .{ .allocator = allocator, .listener = listener, .options = options, .relays = .initUndefined() };
    for (std.enums.values(Kind)) |kind| self.relays.set(kind, .{ .paths = self, .kind = kind });
    errdefer self.destroyHooks();

    if (options.known) |k| {
        log.info("Hooking the game's graphics: it presents through {t} (handed over)", .{k.api});
    } else log.info("Looking for the game's graphics API ({s})", .{if (options.early) "started with the game: before it renders" else "attaching: it may be rendering already"});
    for (std.enums.values(Kind)) |kind| {
        const name = dll_names.get(kind);
        self.waits.set(kind, sys.module.WhenLoaded.create(allocator, name, .{ .ctx = self.relays.getPtr(kind), .ready = Relay.dllReady }) catch |err| {
            log.warn("{t}: can't watch for {s} loading, so not hooking it: {t}", .{ kind, name, err });
            continue;
        });
        if (!self.waits.get(kind).?.fired()) log.info("{t}: {s} isn't loaded; hooking it if the game loads it", .{ kind, name });
    }
    self.creating = false;
    return self;
}

fn approach(comptime kind: Kind, early: bool, known: bool) []const u8 {
    const PresentHook = PresentHookOf(kind);
    if (known and @hasDecl(PresentHook, "createFrom")) return "hooking the game's device, handed over";
    if (early and @hasDecl(PresentHook, "createEarly")) return "hooking the game's device creation";
    return switch (kind) {
        .d3d9, .dxgi => "probing with a throwaway device of our own for where Present is",
        .opengl => "hooking wglSwapBuffers",
        .vulkan => "hooking the Vulkan loader's present and swapchain calls",
    };
}

fn PresentHookOf(comptime kind: Kind) type {
    return @typeInfo(@typeInfo(@FieldType(Hooks, @tagName(kind))).optional.child).pointer.child;
}

pub fn enable(self: *Paths) !void {
    self.lock.lock();
    defer self.lock.unlock();
    self.enabled = true;
    inline for (comptime std.enums.values(Kind)) |kind| {
        if (@field(self.hooks, @tagName(kind))) |p| try p.enable();
    }
}

/// Hooks `kind` unless the game's path is settled or we're shutting down.
fn addPath(self: *Paths, comptime kind: Kind, base: usize) void {
    const name = dll_names.get(kind);
    if (self.claimed.load(.acquire)) {
        log.info("{t}: the game loaded {s}, but it presents through another API; not hooking it", .{ kind, name });
        return;
    }
    // A DLL loaded after us can't have a device we missed, and a known device rules out the others
    const early = self.options.early or self.options.known != null or !self.creating;
    const known_object: ?*anyopaque = if (self.options.known) |k| (if (kindOf(k.api) == kind) k.object else null) else null;
    var path_buf: [sys.win.MAX_PATH * 3]u8 = undefined;
    const path = sys.module.pathOf(base, &path_buf) orelse name;
    const whose: []const u8 = if (sys.module.inSystemDir(path)) "Windows'" else "not Windows': a wrapper or overlay?";
    log.info("{t}: {s} {s} ({s}); {s}", .{ kind, path, if (self.creating) "is loaded" else "was loaded by the game", whose, approach(kind, early, known_object != null) });

    const PresentHook = PresentHookOf(kind);
    const listener: gfx.Listener = .of(Relay, self.relays.getPtr(kind));
    const created = if (@hasDecl(PresentHook, "createFrom") and known_object != null)
        PresentHook.createFrom(self.allocator, listener, known_object.?)
    else if (@hasDecl(PresentHook, "createEarly") and early)
        PresentHook.createEarly(self.allocator, listener)
    else
        PresentHook.create(self.allocator, listener);
    const p = created catch |err| {
        switch (err) {
            error.NotInUse => log.info("{t}: not hooked: the game doesn't use it", .{kind}),
            else => log.warn("{t}: can't hook it: {t}", .{ kind, err }),
        }
        return;
    };
    const kept = blk: {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.claimed.load(.acquire)) break :blk false;
        @field(self.hooks, @tagName(kind)) = p;
        if (self.enabled) p.enable() catch |err| log.warn("Can't hook {t} presents: {t}", .{ kind, err });
        break :blk true;
    };
    if (!kept) p.destroy();
}

/// Releases tracked surfaces without `detach`, like `gfx.Listener` says.
pub fn destroy(self: *Paths) void {
    self.destroyHooks();
    self.allocator.destroy(self);
}

fn destroyHooks(self: *Paths) void {
    // No path gets added after this
    for (&self.waits.values) |*w| if (w.*) |x| {
        x.destroy();
        w.* = null;
    };
    self.destroyExcept(null);
}

pub fn hooked(self: *Paths, kind: Kind) bool {
    self.lock.lockShared();
    defer self.lock.unlockShared();
    return switch (kind) {
        inline else => |k| @field(self.hooks, @tagName(k)) != null,
    };
}

/// Waits for presents in flight.
fn destroyExcept(self: *Paths, keep: ?Kind) void {
    var taken: Hooks = .{};
    self.lock.lock();
    inline for (comptime std.enums.values(Kind)) |kind| {
        if (kind != keep) {
            @field(taken, @tagName(kind)) = @field(self.hooks, @tagName(kind));
            @field(self.hooks, @tagName(kind)) = null;
        }
    }
    self.lock.unlock();
    inline for (comptime std.enums.values(Kind)) |kind| {
        if (@field(taken, @tagName(kind))) |p| p.destroy();
    }
}

/// `kind` presented first among the game-only paths, so it's the game's.
fn claim(self: *Paths, kind: Kind) void {
    if (self.claimed.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) return;
    log.info("The game presents through {t}: unhooking the other paths", .{kind});
    // Other paths' surfaces get detached once unhooked, when none of their presents are in flight
    const previous = self.owner.swap(@backingInt(kind), .acq_rel);
    var gone: ?Frame = null;
    if (previous != no_owner and previous != @backingInt(kind)) {
        gone = self.trackedFrame(@fromBackingInt(@intCast(previous)));
    }
    self.destroyExcept(kind);
    if (gone) |*f| self.listener.detach(self.listener.ctx, f);
}

fn trackedFrame(self: *Paths, kind: Kind) ?Frame {
    self.lock.lockShared();
    defer self.lock.unlockShared();
    return switch (kind) {
        inline else => |k| if (@field(self.hooks, @tagName(k))) |p| p.tracker.frame else null,
    };
}

/// One per path. Passes reports on while it's the owner.
const Relay = struct {
    paths: *Paths,
    kind: Kind,

    fn dllReady(ctx: ?*anyopaque, base: usize) void {
        const self: *Relay = @ptrCast(@alignCast(ctx.?));
        switch (self.kind) {
            inline else => |k| self.paths.addPath(k, base),
        }
    }

    fn owns(self: *Relay) bool {
        return self.paths.owner.load(.acquire) == @backingInt(self.kind);
    }

    pub fn onAttach(self: *Relay, f: *const Frame) void {
        const p = self.paths;
        const kind: u8 = @backingInt(self.kind);
        if (p.owner.cmpxchgStrong(no_owner, kind, .acq_rel, .acquire)) |current| {
            if (current != kind) {
                log.info("Ignoring a {t} surface: the game presents through {t}", .{ f.api, @as(Kind, @fromBackingInt(@intCast(current))) });
                return;
            }
        }
        p.listener.attach(p.listener.ctx, f);
    }
    pub fn onFrame(self: *Relay, f: *const Frame) void {
        if (self.owns()) self.paths.listener.frame(self.paths.listener.ctx, f);
    }
    pub fn onResize(self: *Relay, f: *const Frame) void {
        if (self.owns()) self.paths.listener.resize(self.paths.listener.ctx, f);
    }
    pub fn onDetach(self: *Relay, f: *const Frame) void {
        if (!self.owns()) return;
        self.paths.listener.detach(self.paths.listener.ctx, f);
        self.paths.owner.store(no_owner, .release);
    }
    /// D3D9, OpenGL and Vulkan presents are always the game's.
    pub fn onPresented(self: *Relay) void {
        if (self.kind == .dxgi or self.paths.claimed.load(.acquire)) return;
        self.paths.claim(self.kind);
    }
};

const tests = struct {
    const testing = std.testing;
    const hook = @import("tuft_hook");

    const Recorder = struct {
        attaches: u32 = 0,
        frames: u32 = 0,
        resizes: u32 = 0,
        detaches: u32 = 0,
        last: ?Frame = null,

        pub fn onAttach(self: *Recorder, f: *const Frame) void {
            self.attaches += 1;
            self.last = f.*;
        }
        pub fn onFrame(self: *Recorder, f: *const Frame) void {
            self.frames += 1;
            self.last = f.*;
        }
        pub fn onResize(self: *Recorder, _: *const Frame) void {
            self.resizes += 1;
        }
        pub fn onDetach(self: *Recorder, _: *const Frame) void {
            self.detaches += 1;
        }
    };

    fn quiet() std.log.Level {
        const saved = testing.log_level;
        testing.log_level = .err;
        return saved;
    }

    test "hooks late-loaded DLL" {
        if (sys.module.findBase("vulkan-1.dll") != null) return error.SkipZigTest;
        const saved = quiet();
        defer testing.log_level = saved;
        try hook.init(testing.allocator);
        defer hook.deinit();

        var recorder: Recorder = .{};
        const paths = try Paths.create(testing.allocator, .of(Recorder, &recorder), .{});
        defer paths.destroy();
        try paths.enable();
        try testing.expect(!paths.hooked(.vulkan));

        const handle = sys.win.LoadLibraryW(std.unicode.utf8ToUtf16LeStringLiteral("vulkan-1.dll")) orelse return error.SkipZigTest;
        defer _ = sys.win.FreeLibrary(handle);
        var waited: u32 = 0;
        while (!paths.hooked(.vulkan) and waited < 5000) : (waited += 1) sys.win.Sleep(1);
        try testing.expect(paths.hooked(.vulkan));
    }

    test "reports reach listener" {
        const saved = quiet();
        defer testing.log_level = saved;
        try hook.init(testing.allocator);
        defer hook.deinit();

        const owned = try gfx.d3d11.OwnedSwapChain.create();
        defer owned.destroy();
        var recorder: Recorder = .{};
        const paths = try Paths.create(testing.allocator, .of(Recorder, &recorder), .{});
        try paths.enable();

        _ = owned.swap_chain.present(0, 0);
        _ = owned.swap_chain.present(0, 0);
        try testing.expectEqual(1, recorder.attaches);
        try testing.expectEqual(2, recorder.frames);
        try testing.expectEqual(gfx.Api.d3d11, recorder.last.?.api);
        try testing.expectEqual(@as(*anyopaque, owned.swap_chain), recorder.last.?.swap_chain);

        try testing.expect(gfx.com.succeeded(owned.swap_chain.resizeBuffers(0, 128, 96, 0, 0)));
        try testing.expectEqual(1, recorder.resizes);

        paths.destroy();
        _ = owned.swap_chain.present(0, 0);
        try testing.expectEqual(2, recorder.frames);
    }

    test "ignores other paths once claimed" {
        const saved = quiet();
        defer testing.log_level = saved;
        try hook.init(testing.allocator);
        defer hook.deinit();

        const device = try gfx.d3d9.OwnedDevice.create(.{});
        defer device.destroy();
        const swap_chain = try gfx.d3d11.OwnedSwapChain.create();
        defer swap_chain.destroy();
        var recorder: Recorder = .{};
        const paths = try Paths.create(testing.allocator, .of(Recorder, &recorder), .{});
        defer paths.destroy();
        try paths.enable();

        _ = device.present();
        try testing.expectEqual(1, recorder.attaches);
        try testing.expectEqual(gfx.Api.d3d9, recorder.last.?.api);
        try testing.expectEqual(@as(*anyopaque, device.device), recorder.last.?.device);

        _ = swap_chain.swap_chain.present(0, 0);
        try testing.expectEqual(1, recorder.attaches);
        try testing.expectEqual(1, recorder.frames);

        try testing.expect(gfx.com.succeeded(device.reset(128, 96)));
        try testing.expectEqual(1, recorder.resizes);
        _ = device.present();
        try testing.expectEqual(2, recorder.frames);
    }

    test "non-DXGI present wins" {
        const saved = quiet();
        defer testing.log_level = saved;
        try hook.init(testing.allocator);
        defer hook.deinit();

        // Like a driver would, presenting the game's OpenGL through DXGI
        const swap_chain = try gfx.d3d11.OwnedSwapChain.create();
        defer swap_chain.destroy();
        const context = try gfx.opengl.OwnedContext.create();
        defer context.destroy();
        var recorder: Recorder = .{};
        const paths = try Paths.create(testing.allocator, .of(Recorder, &recorder), .{});
        defer paths.destroy();
        try paths.enable();

        _ = swap_chain.swap_chain.present(0, 0);
        try testing.expectEqual(gfx.Api.d3d11, recorder.last.?.api);

        _ = context.swap();
        try testing.expectEqual(1, recorder.detaches);
        try testing.expect(!paths.hooked(.dxgi));
        try testing.expectEqual(2, recorder.attaches);
        try testing.expectEqual(gfx.Api.opengl, recorder.last.?.api);

        const frames = recorder.frames;
        _ = swap_chain.swap_chain.present(0, 0);
        try testing.expectEqual(frames, recorder.frames);
        _ = context.swap();
        try testing.expectEqual(frames + 1, recorder.frames);
    }
};

test {
    _ = tests;
}
