//! ImGui's D3D10 backend.

const D3d10 = @This();

const std = @import("std");

const gfx = @import("tuft_gfx");

const c = @import("../root.zig").c;

const com = gfx.com;
const d3d10 = gfx.d3d10;
const d3d11 = gfx.d3d11;
const Frame = gfx.Frame;
const hdr = @import("hdr.zig");
const capture = @import("../capture.zig");

device: *anyopaque,
/// Dropped before resizes and on detach.
target: ?*d3d10.RenderTargetView = null,
target_owner: ?*anyopaque = null,
output: hdr.Output = .{},
copies: [2]Copy = @splat(.{}),

/// A staging texture the GPU copies the back buffer into.
const Copy = struct {
    staging: ?*anyopaque = null,
    /// Multisampled back buffers get resolved into this first.
    resolve: ?*anyopaque = null,
    desc: d3d10.Texture2DDesc = undefined,
    busy: bool = false,
    color_space: gfx.ColorSpace = .srgb,

    fn release(self: *Copy) void {
        if (self.staging) |s| com.release(s);
        if (self.resolve) |r| com.release(r);
        self.* = .{};
    }

    fn take(self: *Copy, native: d3d10.Native, color_space: gfx.ColorSpace) bool {
        var buffer: ?*anyopaque = null;
        if (!com.succeeded(native.swap_chain.getBuffer(0, &d3d10.IID_ID3D10Texture2D, &buffer))) return false;
        defer com.release(buffer.?);
        const desc = d3d10.texture.desc(buffer.?);
        if (capture.Format.fromDxgi(desc.format) == .unknown) return false;
        if (self.staging == null or self.desc.width != desc.width or self.desc.height != desc.height or self.desc.format != desc.format or self.desc.sample_count != desc.sample_count) {
            self.release();
            self.desc = desc;
            self.staging = native.device.createTexture2D(&.{ .width = desc.width, .height = desc.height, .format = desc.format, .usage = d3d11.USAGE_STAGING, .cpu_access_flags = d3d11.CPU_ACCESS_READ }) orelse return false;
            if (desc.sample_count > 1) self.resolve = native.device.createTexture2D(&.{ .width = desc.width, .height = desc.height, .format = desc.format }) orelse return false;
        }
        if (self.resolve) |r| {
            native.device.resolveSubresource(r, buffer.?, desc.format);
            native.device.copyResource(self.staging.?, r);
        } else {
            native.device.copyResource(self.staging.?, buffer.?);
        }
        self.busy = true;
        self.color_space = color_space;
        return true;
    }

    /// False while the GPU's still at it.
    fn land(self: *Copy, point: capture.Point, captures: *capture.Captures) bool {
        var mapped: d3d10.MappedTexture2D = .{};
        const hr = d3d10.texture.mapNoWait(self.staging.?, &mapped);
        if (hr == d3d11.still_drawing) return false;
        self.busy = false;
        if (!com.succeeded(hr)) {
            captures.failed(point);
            return true;
        }
        defer d3d10.texture.unmap(self.staging.?);
        const format = capture.Format.fromDxgi(self.desc.format);
        const len = capture.Image.size(self.desc.width, self.desc.height, mapped.row_pitch, format);
        captures.done(&.{
            .point = point,
            .width = self.desc.width,
            .height = self.desc.height,
            .pitch = mapped.row_pitch,
            .format = format,
            .native_format = self.desc.format,
            .color_space = self.color_space,
            .pixels = @as([*]const u8, @ptrCast(mapped.data.?))[0..len],
        });
        return true;
    }
};

fn copyAt(self: *D3d10, native: d3d10.Native, frame: *const Frame, point: capture.Point, captures: *capture.Captures) void {
    if (!captures.want(point)) return;
    const copy = &self.copies[@backingInt(point)];
    if (copy.busy) return;
    if (copy.take(native, frame.color_space)) captures.started(point) else captures.failed(point);
}

pub fn poll(self: *D3d10, _: *const Frame, captures: *capture.Captures) void {
    for (&self.copies, 0..) |*copy, i| {
        if (captures.check(@fromBackingInt(@intCast(i)), copy.busy)) _ = copy.land(@fromBackingInt(@intCast(i)), captures);
    }
}

pub fn init(frame: *const Frame) error{BackendFailed}!D3d10 {
    if (!c.cImGui_ImplDX10_Init(@ptrCast(frame.device))) return error.BackendFailed;
    return .{ .device = frame.device };
}

pub fn deinit(self: *D3d10) void {
    self.releaseTarget();
    hdr.tuft_imgui_hdr_release();
    c.cImGui_ImplDX10_Shutdown();
}

pub fn matches(self: *const D3d10, frame: *const Frame) bool {
    return frame.api == .d3d10 and frame.device == self.device;
}

pub fn beginFrame(self: *D3d10, frame: *const Frame) bool {
    const native = d3d10.fromFrame(frame) orelse return false;
    _ = self.renderTarget(native) orelse return false;
    if (self.output.update(frame)) self.output.applyD3d();
    c.cImGui_ImplDX10_NewFrame();
    return true;
}

/// HDR shader for the game window only.
pub fn drawStarted(self: *D3d10) void {
    if (self.output.mode() != 0) hdr.drawFirst(hdr.d3d10_callback, null);
}

pub fn render(self: *D3d10, frame: *const Frame, draw_data: *c.ImDrawData, captures: *capture.Captures) void {
    const native = d3d10.fromFrame(frame) orelse return;
    const target = self.target orelse return;
    self.copyAt(native, frame, .before, captures);
    native.device.setRenderTarget(target);
    c.cImGui_ImplDX10_RenderDrawData(draw_data);
    self.copyAt(native, frame, .after, captures);
}

/// Puts the game's render targets back.
pub fn renderPlatformWindows(_: *D3d10, frame: *const Frame) void {
    const native = d3d10.fromFrame(frame) orelse return;
    var saved = native.device.saveRenderTargets();
    defer saved.restore(native.device);
    c.ImGui_RenderPlatformWindowsDefault();
}

pub fn releaseTarget(self: *D3d10) void {
    for (&self.copies) |*copy| copy.release();
    if (self.target) |t| com.release(t);
    self.target = null;
    self.target_owner = null;
}

fn renderTarget(self: *D3d10, native: d3d10.Native) ?*d3d10.RenderTargetView {
    if (self.target_owner != @as(*anyopaque, native.swap_chain)) self.releaseTarget();
    if (self.target) |t| return t;

    var buffer: ?*anyopaque = null;
    if (!com.succeeded(native.swap_chain.getBuffer(0, &d3d10.IID_ID3D10Texture2D, &buffer))) return null;
    defer com.release(buffer.?);

    var view: ?*d3d10.RenderTargetView = null;
    if (!com.succeeded(native.device.createRenderTargetView(buffer.?, &view))) return null;
    self.target = view;
    self.target_owner = native.swap_chain;
    return view;
}
