//! Our own device and surface for each API, for tests.

const std = @import("std");

const tuft_window = @import("tuft_window");

const com = @import("com.zig");
const d3d9 = @import("d3d9.zig");
const d3d10 = @import("d3d10.zig");
const d3d11 = @import("d3d11.zig");
const d3d12 = @import("d3d12.zig");
const opengl = @import("opengl.zig");
const vulkan = @import("vulkan.zig");

pub const OwnedSurface = union(enum) {
    d3d11: d3d11.OwnedSwapChain,
    d3d10: d3d10.OwnedSwapChain,
    d3d12: d3d12.OwnedSwapChain,
    d3d9: d3d9.OwnedDevice,
    opengl: opengl.OwnedContext,
    vulkan: *vulkan.OwnedSwapchain,

    pub const Kind = std.meta.Tag(OwnedSurface);

    pub const Options = struct {
        /// Vulkan only. Makes an scRGB HDR swapchain.
        hdr: bool = false,
    };

    /// `error.Unavailable` means no API, GPU or color space, so tests skip.
    pub fn create(kind: Kind, options: Options) !OwnedSurface {
        return switch (kind) {
            .d3d11 => .{ .d3d11 = try d3d11.OwnedSwapChain.create() },
            .d3d10 => .{ .d3d10 = try d3d10.OwnedSwapChain.create() },
            .d3d12 => .{ .d3d12 = try d3d12.OwnedSwapChain.create() },
            .d3d9 => .{ .d3d9 = try d3d9.OwnedDevice.create(.{}) },
            .opengl => .{ .opengl = opengl.OwnedContext.create() catch |err| return switch (err) {
                error.NoPixelFormat, error.CreateContextFailed, error.MakeCurrentFailed => error.Unavailable,
                else => err,
            } },
            .vulkan => .{ .vulkan = vulkan.OwnedSwapchain.create(.{
                .color_space = if (options.hdr) vulkan.color_space_extended_srgb_linear else vulkan.color_space_srgb_nonlinear,
            }) catch |err| return switch (err) {
                error.NoVulkan, error.NoVulkanDevice, error.VulkanCallFailed, error.MissingVulkanFunction, error.UnsupportedColorSpace => error.Unavailable,
                else => err,
            } },
        };
    }

    pub fn destroy(self: OwnedSurface) void {
        switch (self) {
            inline else => |s| s.destroy(),
        }
    }

    pub fn window(self: OwnedSurface) tuft_window.Handle {
        return switch (self) {
            inline else => |s| s.hwnd,
        };
    }

    /// Goes through whatever hooked its present.
    pub fn present(self: OwnedSurface) void {
        switch (self) {
            inline .d3d11, .d3d10 => |s| _ = s.swap_chain.present(0, 0),
            .d3d12 => |s| _ = s.present(),
            .d3d9 => |s| _ = s.present(),
            .opengl => |s| _ = s.swap(),
            .vulkan => |s| _ = s.present() catch 0,
        }
    }

    /// False if it failed, like when something still holds the old buffers.
    pub fn resize(self: OwnedSurface, width: u32, height: u32) bool {
        const size: tuft_window.Size = .{ .width = width, .height = height };
        const hr = switch (self) {
            inline .d3d11, .d3d10 => |s| s.swap_chain.resizeBuffers(0, width, height, 0, 0),
            .d3d12 => |s| blk: {
                // Like a game, nothing of ours can be in flight on the old buffers
                s.waitIdle();
                break :blk s.swap_chain.resizeBuffers(0, width, height, 0, 0);
            },
            .d3d9 => |s| s.reset(width, height),
            .opengl => |s| @as(i32, if (tuft_window.setSize(s.hwnd, size)) 0 else -1),
            .vulkan => |s| blk: {
                if (!tuft_window.setSize(s.hwnd, size)) break :blk @as(i32, -1);
                s.makeSwapchain() catch break :blk @as(i32, -1);
                break :blk @as(i32, 0);
            },
        };
        return com.succeeded(hr);
    }
};

test "present and resize" {
    inline for (comptime std.enums.values(OwnedSurface.Kind)) |kind| {
        if (OwnedSurface.create(kind, .{})) |surface| {
            defer surface.destroy();
            surface.present();
            try std.testing.expect(surface.resize(128, 96));
            surface.present();
        } else |err| if (err != error.Unavailable) return err;
    }
}
