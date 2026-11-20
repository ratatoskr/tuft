//! Fake game for tests that draws ImGui through `Host`.

const Game = @This();

const std = @import("std");
const testing = std.testing;

const hook = @import("tuft_hook");
const gfx = @import("tuft_gfx");
const tuft_window = @import("tuft_window");

const c = @import("root.zig").c;
const Host = @import("Host.zig");
const Win32 = @import("Win32.zig");

pub const Api = gfx.OwnedSurface.Kind;

pub const Options = struct {
    api: Api = .d3d11,
    viewports: bool = false,
    /// Vulkan only. Skips the test without an HDR swapchain.
    hdr: bool = false,
    capture_sink: ?@import("capture.zig").Sink = null,
};

const Path = union(enum) {
    dxgi: *gfx.dxgi.PresentHook,
    d3d9: *gfx.d3d9.PresentHook,
    opengl: *gfx.opengl.PresentHook,
    vulkan: *gfx.vulkan.PresentHook,

    fn destroy(self: Path) void {
        switch (self) {
            inline else => |p| p.destroy(),
        }
    }
};

pub const Hooks = struct {
    ctx: *anyopaque,
    draw: ?*const fn (ctx: *anyopaque) void = null,
    after: ?*const fn (ctx: *anyopaque, frame: *const gfx.Frame) void = null,

    pub fn of(comptime T: type, ctx: *T) Hooks {
        const Thunks = struct {
            fn draw(p: *anyopaque) void {
                T.draw(@ptrCast(@alignCast(p)));
            }
            fn after(p: *anyopaque, frame: *const gfx.Frame) void {
                T.after(@ptrCast(@alignCast(p)), frame);
            }
        };
        return .{
            .ctx = ctx,
            .draw = if (@hasDecl(T, "draw")) Thunks.draw else null,
            .after = if (@hasDecl(T, "after")) Thunks.after else null,
        };
    }
};

options: Options,
surface: gfx.OwnedSurface,
hwnd: tuft_window.Handle,
path: Path,
host: Host,
hooks: ?Hooks = null,
frames: u32 = 0,
viewport_wheels: u32 = 0,

/// Skips the test if the API isn't there.
pub fn init(self: *Game, options: Options) !void {
    const saved_log = testing.log_level;
    testing.log_level = .err;
    defer testing.log_level = saved_log;

    try hook.init(testing.allocator);
    errdefer hook.deinit();
    self.* = .{
        .options = options,
        .surface = gfx.OwnedSurface.create(options.api, .{ .hdr = options.hdr }) catch |err| return switch (err) {
            error.Unavailable => error.SkipZigTest,
            else => err,
        },
        .hwnd = undefined,
        .path = undefined,
        .host = .init(testing.allocator, .{
            .viewports = options.viewports,
            .viewport_input = .{ .ctx = self, .func = onViewportInput },
            .setup = .{ .ctx = self, .func = setup },
            .capture_sink = options.capture_sink,
        }),
    };
    errdefer self.surface.destroy();
    self.hwnd = self.surface.window();

    const listener: gfx.Listener = .of(Game, self);
    self.path = switch (options.api) {
        .d3d11, .d3d10, .d3d12 => .{ .dxgi = try gfx.dxgi.PresentHook.create(testing.allocator, listener) },
        .d3d9 => .{ .d3d9 = try gfx.d3d9.PresentHook.create(testing.allocator, listener) },
        .opengl => .{ .opengl = try gfx.opengl.PresentHook.create(testing.allocator, listener) },
        .vulkan => .{ .vulkan = gfx.vulkan.PresentHook.create(testing.allocator, listener) catch |err| return switch (err) {
            error.NoVulkan, error.NoVulkanDevice, error.NotInUse => error.SkipZigTest,
            else => err,
        } },
    };
    errdefer self.path.destroy();

    switch (self.path) {
        inline else => |p| try p.enable(),
    }
    // D3D12 needs the queue and Vulkan remakes its swapchain, so present once first
    if (options.api == .d3d12 or options.api == .vulkan) self.present();
}

pub fn deinit(self: *Game) void {
    self.host.deinit();
    self.path.destroy();
    self.surface.destroy();
    hook.deinit();
}

pub fn present(self: *Game) void {
    self.surface.present();
}

pub fn resize(self: *Game, width: u32, height: u32) bool {
    return self.surface.resize(width, height);
}

pub fn stopViewports(self: *Game) void {
    self.host.stopViewports();
}

fn setup(_: *anyopaque, _: *const gfx.Frame) void {
    const io = c.ImGui_GetIO();
    io.*.IniFilename = null;
    io.*.ConfigErrorRecoveryEnableAssert = false;
}

// gfx.Listener
pub fn onAttach(_: *Game, _: *const gfx.Frame) void {}

pub fn onFrame(self: *Game, frame: *const gfx.Frame) void {
    self.host.prepare(frame, false) catch return;
    if (!self.host.beginFrame(frame, 1.0 / 60.0)) return;
    if (self.hooks) |h| if (h.draw) |draw| draw(h.ctx);
    self.host.endFrame(frame);
    self.frames += 1;
    if (self.hooks) |h| if (h.after) |after| after(h.ctx, frame);
}

pub fn onResize(self: *Game, _: *const gfx.Frame) void {
    self.host.releaseTarget();
}

pub fn onDetach(self: *Game, _: *const gfx.Frame) void {
    self.host.releaseTarget();
}

fn onViewportInput(ctx: *anyopaque, input: Win32.Input) void {
    const self: *Game = @ptrCast(@alignCast(ctx));
    switch (input) {
        .message => |m| if (m.msg == WM_MOUSEWHEEL) {
            self.viewport_wheels += 1;
        },
        .mouse_left => {},
    }
}

pub const WM_MOUSEWHEEL: u32 = 0x020A;

pub fn str(comptime s: [:0]const u8) [*c]const u8 {
    return @ptrCast(s.ptr);
}
