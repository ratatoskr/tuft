//! Draws ImGui into a game's frames. All on the render thread.

const Host = @This();

const std = @import("std");

const gfx = @import("tuft_gfx");
const tuft_input = @import("tuft_input");
const tuft_window = @import("tuft_window");
const ui = @import("tuft_ui");

const c = @import("root.zig").c;
const Renderer = @import("Renderer.zig");
const capture = @import("capture.zig");
const Win32 = @import("Win32.zig");

const log = std.log.scoped(.tuft_imgui);

pub const Options = struct {
    /// Lets ImGui windows be dragged out of the game, if the renderer can draw them.
    viewports: bool = false,
    /// Null drops it.
    viewport_input: ?Win32.Sink = null,
    /// An icon resource in this module, for windows dragged out of the game.
    viewport_icon: ?[]const u8 = null,
    /// Runs on the first frame with the context current.
    setup: ?Setup = null,
    /// Gets frame captures, on the render thread.
    capture_sink: ?capture.Sink = null,
    /// Switches the IME on for text boxes in the game's window and places it. Null leaves the IME
    /// as the game set it.
    ime: ?*tuft_input.Ime = null,
};

pub const Setup = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, frame: *const gfx.Frame) void,
};

pub const Error = error{ CreateContextFailed, UnsupportedApi, BackendFailed };

options: Options,
allocator: std.mem.Allocator,
context: ?*c.ImGuiContext = null,
renderer: ?Renderer = null,
platform: ?*Win32 = null,
/// The game's, as of the last frame.
game_window: ?tuft_window.Handle = null,
captures: capture.Captures = .{},
/// Drawn over everything at the end of each frame. Push from any thread. Needs tuft_ui bound.
toasts: ui.Toasts = .{},

pub fn init(allocator: std.mem.Allocator, options: Options) Host {
    return .{ .options = options, .allocator = allocator, .captures = .{ .sink = options.capture_sink } };
}

/// Copies the next frame drawn at `point`. Render thread.
pub fn requestCapture(self: *Host, point: capture.Point) void {
    self.captures.wanted.insert(point);
}

/// Outside windows go first, while the renderer can still free their swap chains.
pub fn deinit(self: *Host) void {
    self.stopIme();
    const context = self.context orelse return;
    c.ImGui_SetCurrentContext(context);
    if (self.renderer) |*r| {
        r.deinit();
    } else if (self.platform != null) {
        c.ImGui_DestroyPlatformWindows();
    }
    if (self.platform) |p| p.destroy();
    c.ImGui_DestroyContext(context);
    self.* = undefined;
}

/// Makes the context and renderer as needed and makes the context current.
pub fn prepare(self: *Host, frame: *const gfx.Frame, monitors_changed: bool) Error!void {
    if (self.context == null) {
        const context = c.ImGui_CreateContext(null) orelse return error.CreateContextFailed;
        self.context = context;
        c.ImGui_SetCurrentContext(context);
        if (self.options.setup) |s| s.func(s.ctx, frame);
        if (self.options.viewports) {
            self.platform = Win32.create(self.allocator, frame.window, self.options.viewport_input orelse ignored, self.options.viewport_icon) catch |err| blk: {
                log.warn("ImGui windows can't leave the game: {t}", .{err});
                break :blk null;
            };
            if (self.platform != null) c.ImGui_GetIO().*.ConfigFlags |= c.ImGuiConfigFlags_ViewportsEnable;
        }
    }
    c.ImGui_SetCurrentContext(self.context);
    self.game_window = frame.window;
    const pio = c.ImGui_GetPlatformIO();
    pio.*.Platform_SetImeDataFn = setImeData;
    pio.*.Platform_ImeUserData = self;

    if (self.renderer) |*r| {
        if (!r.matches(frame)) {
            r.deinit();
            self.renderer = null;
        }
    }
    if (self.renderer == null) {
        // Windows stay in the game if the renderer can't draw them anywhere else
        if (self.platform != null and !Renderer.viewportsFor(frame)) {
            log.info("ImGui windows stay inside the game with {t} here", .{frame.api});
            self.stopViewports();
        }
        self.renderer = try Renderer.init(frame);
    }
    if (self.platform) |p| p.newFrame(c.ImGui_GetIO(), monitors_changed);
}

/// False means nothing to draw into. Call after `prepare` and feeding input.
pub fn beginFrame(self: *Host, frame: *const gfx.Frame, delta_time: f32) bool {
    const renderer = &(self.renderer orelse return false);
    self.captures.window = frame.window;
    renderer.poll(frame, &self.captures);
    if (!renderer.beginFrame(frame)) return false;
    const io = c.ImGui_GetIO();
    const size = tuft_window.clientSize(frame.window);
    io.*.DisplaySize = .{ .x = @floatFromInt(size.width), .y = @floatFromInt(size.height) };
    io.*.DeltaTime = @max(delta_time, 1e-6); // ImGui asserts on zero
    c.ImGui_NewFrame();
    renderer.drawStarted();
    return true;
}

/// Only after a `beginFrame` that returned true.
pub fn endFrame(self: *Host, frame: *const gfx.Frame) void {
    const renderer = &self.renderer.?;
    if (ui.isBound()) self.toasts.draw(.{});
    c.ImGui_Render();
    renderer.render(frame, c.ImGui_GetDrawData(), &self.captures);
    if (self.platform) |p| {
        p.endFrame();
        renderer.renderPlatformWindows(frame);
    }
}

/// Call before the surface gets resized or replaced.
pub fn releaseTarget(self: *Host) void {
    if (self.renderer) |*r| r.releaseTarget();
}

/// Closes the outside windows for good but keeps the renderer, like on unload.
pub fn stopViewports(self: *Host) void {
    self.options.viewports = false;
    const p = self.platform orelse return;
    c.ImGui_SetCurrentContext(self.context);
    p.destroy();
    self.platform = null;
}

var nobody: u8 = 0;
const ignored: Win32.Sink = .{ .ctx = &nobody, .func = struct {
    fn func(_: *anyopaque, _: Win32.Input) void {}
}.func };

/// ImGui calls it at the end of a frame when the caret moves or text input starts or stops. The
/// render thread can't touch the IME, so this hands it to the windows' threads.
fn setImeData(_: ?*c.ImGuiContext, viewport: ?*c.ImGuiViewport, data: ?*c.ImGuiPlatformImeData) callconv(.c) void {
    const self: *Host = @ptrCast(@alignCast(c.ImGui_GetPlatformIO().*.Platform_ImeUserData orelse return));
    const vp = viewport orelse return;
    const d = (data orelse return).*;
    const placement: tuft_input.Ime.Placement = .{
        .x = @intFromFloat(d.InputPos.x - vp.*.Pos.x),
        .y = @intFromFloat(d.InputPos.y - vp.*.Pos.y),
        .line_height = @intFromFloat(d.InputLineHeight),
    };
    const hwnd = vp.*.PlatformHandleRaw;
    const in_game = hwnd == null or hwnd == self.game_window;
    if (!in_game) {
        if (self.platform) |p| if (d.WantVisible) p.placeIme(@ptrCast(hwnd.?), placement);
    }
    const ime = self.options.ime orelse return;
    ime.setTyping(d.WantTextInput and in_game);
    if (in_game and d.WantVisible) ime.place(placement);
}

/// Before the context goes, so a text box still taking text doesn't keep the IME on.
fn stopIme(self: *Host) void {
    if (self.options.ime) |ime| ime.setTyping(false);
}
