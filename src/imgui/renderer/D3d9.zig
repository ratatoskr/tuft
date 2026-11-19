//! ImGui's D3D9 backend.
//! D3D9 can't reset while default-pool resources exist, so `releaseTarget` frees ImGui's.

const D3d9 = @This();

const std = @import("std");

const gfx = @import("tuft_gfx");

const c = @import("../root.zig").c;

const com = gfx.com;
const d3d9 = gfx.d3d9;
const Frame = gfx.Frame;
const capture = @import("../capture.zig");

device: *anyopaque,
/// Freed for a reset and need remaking.
invalidated: bool = false,
copies: [2]Copy = @splat(.{}),

/// The back buffer gets copied into `target` on the GPU, then read into `system` a frame later.
const Copy = struct {
    target: ?*d3d9.Surface = null,
    system: ?*d3d9.Surface = null,
    desc: d3d9.SurfaceDesc = .{},
    busy: bool = false,
    color_space: gfx.ColorSpace = .srgb,

    fn release(self: *Copy) void {
        if (self.target) |s| com.release(s);
        if (self.system) |s| com.release(s);
        self.* = .{};
    }

    fn take(self: *Copy, device: *d3d9.Device, back_buffer: *d3d9.Surface, color_space: gfx.ColorSpace) bool {
        const desc = back_buffer.getDesc() orelse return false;
        if (capture.Format.fromD3d9(desc.format) == .unknown) return false;
        if (self.target == null or self.desc.width != desc.width or self.desc.height != desc.height or self.desc.format != desc.format) {
            self.release();
            self.desc = desc;
            self.target = device.createRenderTarget(desc.width, desc.height, desc.format) orelse return false;
            self.system = device.createOffscreenPlainSurface(desc.width, desc.height, desc.format) orelse return false;
        }
        if (!com.succeeded(device.stretchRect(back_buffer, self.target.?))) return false;
        self.busy = true;
        self.color_space = color_space;
        return true;
    }

    fn land(self: *Copy, device: *d3d9.Device, point: capture.Point, captures: *capture.Captures) void {
        self.busy = false;
        if (!com.succeeded(device.getRenderTargetData(self.target.?, self.system.?))) return captures.failed(point);
        const locked = self.system.?.lockRect(d3d9.LOCK_READONLY) orelse return captures.failed(point);
        defer self.system.?.unlockRect();
        const format = capture.Format.fromD3d9(self.desc.format);
        const pitch: u32 = @intCast(locked.pitch);
        captures.done(&.{
            .point = point,
            .width = self.desc.width,
            .height = self.desc.height,
            .pitch = pitch,
            .format = format,
            .native_format = self.desc.format,
            .color_space = self.color_space,
            .pixels = locked.bits.?[0..capture.Image.size(self.desc.width, self.desc.height, pitch, format)],
        });
    }
};

fn copyAt(self: *D3d9, device: *d3d9.Device, back_buffer: *d3d9.Surface, frame: *const Frame, point: capture.Point, captures: *capture.Captures) void {
    if (!captures.want(point)) return;
    const copy = &self.copies[@backingInt(point)];
    if (copy.busy) return;
    if (copy.take(device, back_buffer, frame.color_space)) captures.started(point) else captures.failed(point);
}

/// Copies from last frame. The GPU's had a frame to get them done, so reading rarely waits.
pub fn poll(self: *D3d9, frame: *const Frame, captures: *capture.Captures) void {
    const native = d3d9.fromFrame(frame) orelse return;
    for (&self.copies, 0..) |*copy, i| {
        if (captures.check(@fromBackingInt(@intCast(i)), copy.busy)) copy.land(native.device, @fromBackingInt(@intCast(i)), captures);
    }
}

pub fn init(frame: *const Frame) error{BackendFailed}!D3d9 {
    if (!c.cImGui_ImplDX9_Init(@ptrCast(frame.device))) return error.BackendFailed;
    return .{ .device = frame.device };
}

pub fn deinit(self: *D3d9) void {
    for (&self.copies) |*copy| copy.release();
    c.cImGui_ImplDX9_Shutdown();
}

pub fn matches(self: *const D3d9, frame: *const Frame) bool {
    return frame.api == .d3d9 and frame.device == self.device;
}

pub fn beginFrame(self: *D3d9, frame: *const Frame) bool {
    const native = d3d9.fromFrame(frame) orelse return false;
    // Lost until the game resets it
    if (!com.succeeded(native.device.testCooperativeLevel())) return false;
    if (self.invalidated) {
        if (!c.cImGui_ImplDX9_CreateDeviceObjects()) return false;
        self.invalidated = false;
    }
    c.cImGui_ImplDX9_NewFrame();
    return true;
}

pub fn drawStarted(_: *D3d9) void {}

pub fn render(self: *D3d9, frame: *const Frame, draw_data: *c.ImDrawData, captures: *capture.Captures) void {
    const native = d3d9.fromFrame(frame) orelse return;
    const device = native.device;
    const back_buffer = device.getBackBuffer(0) orelse return;
    defer com.release(back_buffer);
    const saved = device.getRenderTarget(0);
    defer if (saved) |s| {
        _ = device.setRenderTarget(0, s);
        com.release(s);
    };
    _ = device.setRenderTarget(0, back_buffer);

    // The game's scene is over by the time it presents
    self.copyAt(device, back_buffer, frame, .before, captures);
    if (!com.succeeded(device.beginScene())) return;
    c.cImGui_ImplDX9_RenderDrawData(draw_data);
    _ = device.endScene();
    self.copyAt(device, back_buffer, frame, .after, captures);
}

/// The backend restores the render target itself.
pub fn renderPlatformWindows(_: *D3d9, _: *const Frame) void {
    c.ImGui_RenderPlatformWindowsDefault();
}

/// Call before a reset or when the device gets replaced.
pub fn releaseTarget(self: *D3d9) void {
    for (&self.copies) |*copy| copy.release();
    c.cImGui_ImplDX9_InvalidateDeviceObjects();
    self.invalidated = true;
}
