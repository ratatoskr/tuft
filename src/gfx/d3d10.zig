//! Minimal D3D10 bindings.

const std = @import("std");

const sys = @import("tuft_sys");

const window = @import("tuft_window");

const gfx = @import("root.zig");
const com = @import("com.zig");
const dxgi = @import("dxgi.zig");

const HRESULT = com.HRESULT;
const Guid = com.Guid;
const method = com.method;

pub const IID_ID3D10Device: Guid = .{
    .data1 = 0x9b7e4c0f,
    .data2 = 0x342c,
    .data3 = 0x4106,
    .data4 = .{ 0xa1, 0x9f, 0x4f, 0x27, 0x04, 0xf6, 0x89, 0xf0 },
};

pub const IID_ID3D10Texture2D: Guid = .{
    .data1 = 0x9b7e4c04,
    .data2 = 0x342c,
    .data3 = 0x4106,
    .data4 = .{ 0xa1, 0x9f, 0x4f, 0x27, 0x04, 0xf6, 0x89, 0xf0 },
};

/// Same layout as D3D11's.
pub const Texture2DDesc = @import("d3d11.zig").Texture2DDesc;
pub const MappedTexture2D = extern struct {
    data: ?*anyopaque = null,
    row_pitch: u32 = 0,
};

/// `ID3D10Texture2D` methods.
pub const texture = struct {
    pub fn desc(tex: *anyopaque) Texture2DDesc {
        var out: Texture2DDesc = undefined;
        method(tex, 12, fn (*anyopaque, *Texture2DDesc) callconv(.winapi) void)(tex, &out);
        return out;
    }

    /// Fails with `d3d11.still_drawing` if the GPU isn't done with it yet.
    pub fn mapNoWait(tex: *anyopaque, out: *MappedTexture2D) HRESULT {
        return method(tex, 10, fn (*anyopaque, u32, u32, u32, *MappedTexture2D) callconv(.winapi) HRESULT)(tex, 0, 1, 0x100000, out);
    }

    pub fn unmap(tex: *anyopaque) void {
        method(tex, 11, fn (*anyopaque, u32) callconv(.winapi) void)(tex, 0);
    }
};

pub const Device = opaque {
    /// Contents undefined. Caller owns the ref.
    pub fn createTexture2D(self: *Device, desc: *const Texture2DDesc) ?*anyopaque {
        var out: ?*anyopaque = null;
        const hr = method(self, 73, fn (*Device, *const Texture2DDesc, ?*const anyopaque, *?*anyopaque) callconv(.winapi) HRESULT)(self, desc, null, &out);
        return if (com.succeeded(hr)) out else null;
    }

    pub fn copyResource(self: *Device, dest: *anyopaque, src: *anyopaque) void {
        method(self, 33, fn (*Device, *anyopaque, *anyopaque) callconv(.winapi) void)(self, dest, src);
    }

    pub fn resolveSubresource(self: *Device, dest: *anyopaque, src: *anyopaque, format: u32) void {
        method(self, 38, fn (*Device, *anyopaque, u32, *anyopaque, u32, u32) callconv(.winapi) void)(self, dest, 0, src, 0, format);
    }

    pub fn setRenderTarget(self: *Device, target: *RenderTargetView) void {
        const targets = [_]?*RenderTargetView{target};
        method(self, 24, fn (*Device, u32, [*]const ?*RenderTargetView, ?*anyopaque) callconv(.winapi) void)(self, 1, &targets, null);
    }

    /// Holds refs until `SavedTargets.restore`.
    pub fn saveRenderTargets(self: *Device) SavedTargets {
        var saved: SavedTargets = .{};
        method(self, 56, fn (*Device, u32, [*]?*RenderTargetView, *?*anyopaque) callconv(.winapi) void)(self, saved.views.len, &saved.views, &saved.depth);
        return saved;
    }

    pub fn createRenderTargetView(self: *Device, resource: *anyopaque, out: *?*RenderTargetView) HRESULT {
        return method(self, 76, fn (*Device, *anyopaque, ?*const anyopaque, *?*RenderTargetView) callconv(.winapi) HRESULT)(self, resource, null, out);
    }
};

pub const SavedTargets = struct {
    views: [8]?*RenderTargetView = @splat(null),
    depth: ?*anyopaque = null,

    pub fn restore(self: *SavedTargets, device: *Device) void {
        method(device, 24, fn (*Device, u32, [*]const ?*RenderTargetView, ?*anyopaque) callconv(.winapi) void)(device, self.views.len, &self.views, self.depth);
        for (self.views) |v| if (v) |view| com.release(view);
        if (self.depth) |d| com.release(d);
        self.* = .{};
    }
};

pub const RenderTargetView = opaque {};

pub const Native = struct {
    swap_chain: *dxgi.SwapChain,
    device: *Device,
};

pub fn fromFrame(frame: *const gfx.Frame) ?Native {
    if (frame.api != .d3d10) return null;
    return .{ .swap_chain = @ptrCast(frame.swap_chain), .device = @ptrCast(frame.device) };
}

/// Takes refs on both until `releaseFrame`.
pub fn frameOf(swap_chain: *dxgi.SwapChain, device: *Device) !gfx.Frame {
    const hwnd = swap_chain.window() orelse return error.NoOutputWindow;
    com.addRef(swap_chain);
    com.addRef(device);
    return .{ .api = .d3d10, .window = hwnd, .swap_chain = swap_chain, .device = device };
}

pub fn releaseFrame(frame: *const gfx.Frame) void {
    const native = fromFrame(frame).?;
    com.release(native.device);
    com.release(native.swap_chain);
}

const D3D10_DRIVER_TYPE_HARDWARE: u32 = 0;
const D3D10_DRIVER_TYPE_WARP: u32 = 5;
const D3D10_SDK_VERSION: u32 = 29;

/// Looked up at runtime so games don't all load d3d10.dll.
const D3D10CreateDeviceAndSwapChainFn = fn (
    adapter: ?*anyopaque,
    driver_type: u32,
    software: ?*anyopaque,
    flags: u32,
    sdk_version: u32,
    desc: *const dxgi.SwapChainDesc,
    swap_chain: *?*dxgi.SwapChain,
    device: *?*Device,
) callconv(.winapi) HRESULT;

/// Our own device and swap chain, for tests.
pub const OwnedSwapChain = struct {
    hwnd: window.Handle,
    owns_window: bool,
    swap_chain: *dxgi.SwapChain,
    device: *Device,

    pub fn create() !OwnedSwapChain {
        const hwnd = try window.createHidden();
        errdefer window.destroy(hwnd);
        var owned = try createOn(hwnd);
        owned.owns_window = true;
        return owned;
    }

    pub fn createOn(hwnd: window.Handle) !OwnedSwapChain {
        const desc: dxgi.SwapChainDesc = .{
            .buffer_desc = .{ .width = 64, .height = 64, .format = dxgi.FORMAT_R8G8B8A8_UNORM },
            .sample_count = 1,
            .buffer_usage = dxgi.USAGE_RENDER_TARGET_OUTPUT,
            .buffer_count = 1,
            .output_window = hwnd,
            .windowed = 1,
        };

        const create_fn = sys.module.lazyFn("d3d10.dll", "D3D10CreateDeviceAndSwapChain", D3D10CreateDeviceAndSwapChainFn) orelse return error.NoD3D10;
        for ([_]u32{ D3D10_DRIVER_TYPE_HARDWARE, D3D10_DRIVER_TYPE_WARP }) |driver_type| {
            var swap_chain: ?*dxgi.SwapChain = null;
            var device: ?*Device = null;
            const hr = create_fn(null, driver_type, null, 0, D3D10_SDK_VERSION, &desc, &swap_chain, &device);
            if (com.succeeded(hr)) return .{ .hwnd = hwnd, .owns_window = false, .swap_chain = swap_chain.?, .device = device.? };
        }
        return error.CreateDeviceFailed;
    }

    pub fn destroy(self: OwnedSwapChain) void {
        com.release(self.device);
        com.release(self.swap_chain);
        if (self.owns_window) window.destroy(self.hwnd);
    }
};

test "frameOf refs until releaseFrame" {
    const owned = try OwnedSwapChain.create();
    defer owned.destroy();
    const frame = try frameOf(owned.swap_chain, owned.device);
    try std.testing.expectEqual(gfx.Api.d3d10, frame.api);
    try std.testing.expectEqual(@as(*anyopaque, owned.hwnd), frame.window);
    try std.testing.expectEqual(null, frame.queue);
    const native = fromFrame(&frame).?;
    try std.testing.expectEqual(owned.device, native.device);
    try std.testing.expectEqual(gfx.Api.d3d10, dxgi.apiOf(owned.swap_chain).?);
    releaseFrame(&frame);

    var other = frame;
    other.api = .d3d11;
    try std.testing.expectEqual(null, fromFrame(&other));
}
