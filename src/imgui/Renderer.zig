//! Draws ImGui into the game's frame with the backend for the frame's API.

const Renderer = @This();

const std = @import("std");

const gfx = @import("tuft_gfx");

const c = @import("root.zig").c;
const capture = @import("capture.zig");
pub const D3d11 = @import("renderer/D3d11.zig");
pub const D3d9 = @import("renderer/D3d9.zig");
pub const D3d10 = @import("renderer/D3d10.zig");
pub const D3d12 = @import("renderer/D3d12.zig");
pub const OpenGl = @import("renderer/OpenGl.zig");
pub const Vulkan = @import("renderer/Vulkan.zig");

const Frame = gfx.Frame;

backend: union(enum) {
    d3d11: D3d11,
    d3d9: D3d9,
    d3d10: D3d10,
    d3d12: D3d12,
    opengl: OpenGl,
    vulkan: Vulkan,
},

pub const Error = error{ UnsupportedApi, BackendFailed };

pub fn init(frame: *const Frame) Error!Renderer {
    return switch (frame.api) {
        .d3d11 => .{ .backend = .{ .d3d11 = try D3d11.init(frame) } },
        .d3d9 => .{ .backend = .{ .d3d9 = try D3d9.init(frame) } },
        .d3d10 => .{ .backend = .{ .d3d10 = try D3d10.init(frame) } },
        .d3d12 => .{ .backend = .{ .d3d12 = try D3d12.init(frame) } },
        .opengl => .{ .backend = .{ .opengl = try OpenGl.init(frame) } },
        .vulkan => .{ .backend = .{ .vulkan = try Vulkan.init(frame) } },
        else => error.UnsupportedApi,
    };
}

pub fn deinit(self: *Renderer) void {
    switch (self.backend) {
        inline else => |*b| b.deinit(),
    }
}

pub fn matches(self: *const Renderer, frame: *const Frame) bool {
    return switch (self.backend) {
        inline else => |*b| b.matches(frame),
    };
}

pub fn beginFrame(self: *Renderer, frame: *const Frame) bool {
    return switch (self.backend) {
        inline else => |*b| b.beginFrame(frame),
    };
}

pub fn drawStarted(self: *Renderer) void {
    switch (self.backend) {
        inline else => |*b| b.drawStarted(),
    }
}

/// Copies the wanted capture points around ImGui's drawing.
pub fn render(self: *Renderer, frame: *const Frame, draw_data: *c.ImDrawData, captures: *capture.Captures) void {
    switch (self.backend) {
        inline else => |*b| b.render(frame, draw_data, captures),
    }
}

/// Hands over copies the GPU is done with.
pub fn poll(self: *Renderer, frame: *const Frame, captures: *capture.Captures) void {
    if (captures.in_flight.count() == 0) return;
    switch (self.backend) {
        inline else => |*b| b.poll(frame, captures),
    }
}

/// Call after `ImGui_UpdatePlatformWindows`.
pub fn renderPlatformWindows(self: *Renderer, frame: *const Frame) void {
    switch (self.backend) {
        inline else => |*b| b.renderPlatformWindows(frame),
    }
}

/// Decided up front since ImGui's backends set up for it on start.
pub fn viewportsFor(frame: *const Frame) bool {
    return switch (frame.api) {
        .vulkan => Vulkan.viewportsFor(frame),
        else => true,
    };
}

pub fn releaseTarget(self: *Renderer) void {
    switch (self.backend) {
        inline else => |*b| b.releaseTarget(),
    }
}
