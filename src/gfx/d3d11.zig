//! Minimal D3D11 bindings.

const std = @import("std");

const sys = @import("tuft_sys");

const window = @import("tuft_window");

const gfx = @import("root.zig");
const com = @import("com.zig");
const dxgi = @import("dxgi.zig");

const HRESULT = com.HRESULT;
const Guid = com.Guid;
const method = com.method;

pub const IID_ID3D11Device: Guid = .{
    .data1 = 0xdb6f6ddb,
    .data2 = 0xac77,
    .data3 = 0x4e88,
    .data4 = .{ 0x82, 0x53, 0x81, 0x9d, 0xf9, 0xbb, 0xf1, 0x40 },
};

pub const IID_ID3D11Texture2D: Guid = .{
    .data1 = 0x6f15aaf2,
    .data2 = 0xd208,
    .data3 = 0x4e89,
    .data4 = .{ 0x9a, 0xb4, 0x48, 0x95, 0x35, 0xd3, 0x4f, 0x9c },
};

pub const Texture2DDesc = extern struct {
    width: u32,
    height: u32,
    mip_levels: u32 = 1,
    array_size: u32 = 1,
    format: u32,
    sample_count: u32 = 1,
    sample_quality: u32 = 0,
    usage: u32 = 0,
    bind_flags: u32 = 0,
    cpu_access_flags: u32 = 0,
    misc_flags: u32 = 0,
};
pub const USAGE_STAGING: u32 = 3;
pub const CPU_ACCESS_READ: u32 = 0x20000;
pub const MAP_READ: u32 = 1;
pub const MAP_FLAG_DO_NOT_WAIT: u32 = 0x100000;
/// `DXGI_ERROR_WAS_STILL_DRAWING`, from a map that didn't wait.
pub const still_drawing: HRESULT = @bitCast(@as(u32, 0x887A000A));

/// For an `ID3D11Texture2D`.
pub fn textureDesc(texture: *anyopaque) Texture2DDesc {
    var desc: Texture2DDesc = undefined;
    method(texture, 10, fn (*anyopaque, *Texture2DDesc) callconv(.winapi) void)(texture, &desc);
    return desc;
}

pub const MappedSubresource = extern struct {
    data: ?*anyopaque = null,
    row_pitch: u32 = 0,
    depth_pitch: u32 = 0,
};

pub const Device = opaque {
    /// Contents undefined. Caller owns the ref.
    pub fn createTexture2D(self: *Device, desc: *const Texture2DDesc) ?*anyopaque {
        var out: ?*anyopaque = null;
        const hr = method(self, 5, fn (*Device, *const Texture2DDesc, ?*const anyopaque, *?*anyopaque) callconv(.winapi) HRESULT)(self, desc, null, &out);
        return if (com.succeeded(hr)) out else null;
    }

    pub fn createRenderTargetView(self: *Device, resource: *anyopaque, out: *?*RenderTargetView) HRESULT {
        return method(self, 9, fn (*Device, *anyopaque, ?*const anyopaque, *?*RenderTargetView) callconv(.winapi) HRESULT)(self, resource, null, out);
    }

    /// Caller owns the ref.
    pub fn getImmediateContext(self: *Device) *DeviceContext {
        var context: ?*DeviceContext = null;
        method(self, 40, fn (*Device, *?*DeviceContext) callconv(.winapi) void)(self, &context);
        return context.?;
    }
};

pub const DeviceContext = opaque {
    pub fn map(self: *DeviceContext, resource: *anyopaque, map_type: u32) ?MappedSubresource {
        var out: MappedSubresource = .{};
        const hr = method(self, 14, fn (*DeviceContext, *anyopaque, u32, u32, u32, *MappedSubresource) callconv(.winapi) HRESULT)(self, resource, 0, map_type, 0, &out);
        return if (com.succeeded(hr)) out else null;
    }

    /// Fails with `still_drawing` if the GPU isn't done with it yet.
    pub fn mapNoWait(self: *DeviceContext, resource: *anyopaque, out: *MappedSubresource) HRESULT {
        return method(self, 14, fn (*DeviceContext, *anyopaque, u32, u32, u32, *MappedSubresource) callconv(.winapi) HRESULT)(self, resource, 0, MAP_READ, MAP_FLAG_DO_NOT_WAIT, out);
    }

    pub fn resolveSubresource(self: *DeviceContext, dest: *anyopaque, src: *anyopaque, format: u32) void {
        method(self, 57, fn (*DeviceContext, *anyopaque, u32, *anyopaque, u32, u32) callconv(.winapi) void)(self, dest, 0, src, 0, format);
    }

    pub fn unmap(self: *DeviceContext, resource: *anyopaque) void {
        method(self, 15, fn (*DeviceContext, *anyopaque, u32) callconv(.winapi) void)(self, resource, 0);
    }

    pub fn copyResource(self: *DeviceContext, dest: *anyopaque, src: *anyopaque) void {
        method(self, 47, fn (*DeviceContext, *anyopaque, *anyopaque) callconv(.winapi) void)(self, dest, src);
    }

    pub fn setRenderTarget(self: *DeviceContext, target: *RenderTargetView) void {
        const targets = [_]?*RenderTargetView{target};
        method(self, 33, fn (*DeviceContext, u32, [*]const ?*RenderTargetView, ?*anyopaque) callconv(.winapi) void)(self, 1, &targets, null);
    }

    pub fn clearRenderTarget(self: *DeviceContext, target: *RenderTargetView, color: [4]f32) void {
        method(self, 50, fn (*DeviceContext, *RenderTargetView, *const [4]f32) callconv(.winapi) void)(self, target, &color);
    }

    /// Holds refs until `SavedTargets.restore`.
    pub fn saveRenderTargets(self: *DeviceContext) SavedTargets {
        var saved: SavedTargets = .{};
        method(self, 89, fn (*DeviceContext, u32, [*]?*RenderTargetView, *?*anyopaque) callconv(.winapi) void)(self, saved.views.len, &saved.views, &saved.depth);
        return saved;
    }
};

pub const SavedTargets = struct {
    views: [8]?*RenderTargetView = @splat(null),
    depth: ?*anyopaque = null,

    pub fn restore(self: *SavedTargets, context: *DeviceContext) void {
        method(context, 33, fn (*DeviceContext, u32, [*]const ?*RenderTargetView, ?*anyopaque) callconv(.winapi) void)(context, self.views.len, &self.views, self.depth);
        for (self.views) |v| if (v) |view| com.release(view);
        if (self.depth) |d| com.release(d);
        self.* = .{};
    }
};

pub const RenderTargetView = opaque {};

pub const Native = struct {
    swap_chain: *dxgi.SwapChain,
    device: *Device,
    context: *DeviceContext,
};

pub fn fromFrame(frame: *const gfx.Frame) ?Native {
    if (frame.api != .d3d11) return null;
    return .{
        .swap_chain = @ptrCast(frame.swap_chain),
        .device = @ptrCast(frame.device),
        .context = @ptrCast(frame.queue.?),
    };
}

/// Takes refs on both plus the immediate context until `releaseFrame`.
pub fn frameOf(swap_chain: *dxgi.SwapChain, device: *Device) !gfx.Frame {
    const hwnd = swap_chain.window() orelse return error.NoOutputWindow;
    com.addRef(swap_chain);
    com.addRef(device);
    return .{ .api = .d3d11, .window = hwnd, .swap_chain = swap_chain, .device = device, .queue = device.getImmediateContext() };
}

pub fn releaseFrame(frame: *const gfx.Frame) void {
    const native = fromFrame(frame).?;
    com.release(native.context);
    com.release(native.device);
    com.release(native.swap_chain);
}

const D3D_DRIVER_TYPE_HARDWARE: u32 = 1;
const D3D_DRIVER_TYPE_WARP: u32 = 5;
const D3D11_SDK_VERSION: u32 = 7;

/// Looked up at runtime so games don't all load d3d11.dll.
const D3D11CreateDeviceAndSwapChainFn = fn (
    adapter: ?*anyopaque,
    driver_type: u32,
    software: ?*anyopaque,
    flags: u32,
    feature_levels: ?[*]const u32,
    feature_level_count: u32,
    sdk_version: u32,
    desc: *const dxgi.SwapChainDesc,
    swap_chain: *?*dxgi.SwapChain,
    device: *?*Device,
    feature_level: ?*u32,
    context: *?*DeviceContext,
) callconv(.winapi) HRESULT;

/// Our own device and swap chain, for probing DXGI and tests.
pub const OwnedSwapChain = struct {
    hwnd: window.Handle,
    owns_window: bool,
    swap_chain: *dxgi.SwapChain,
    device: *Device,
    context: *DeviceContext,

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

        const create_fn = sys.module.lazyFn("d3d11.dll", "D3D11CreateDeviceAndSwapChain", D3D11CreateDeviceAndSwapChainFn) orelse return error.NoD3D11;
        for ([_]u32{ D3D_DRIVER_TYPE_HARDWARE, D3D_DRIVER_TYPE_WARP }) |driver_type| {
            var swap_chain: ?*dxgi.SwapChain = null;
            var device: ?*Device = null;
            var context: ?*DeviceContext = null;
            const hr = create_fn(null, driver_type, null, 0, null, 0, D3D11_SDK_VERSION, &desc, &swap_chain, &device, null, &context);
            if (com.succeeded(hr)) return .{ .hwnd = hwnd, .owns_window = false, .swap_chain = swap_chain.?, .device = device.?, .context = context.? };
        }
        return error.CreateDeviceFailed;
    }

    pub fn destroy(self: OwnedSwapChain) void {
        com.release(self.context);
        com.release(self.device);
        com.release(self.swap_chain);
        if (self.owns_window) window.destroy(self.hwnd);
    }

    /// Takes no refs, only valid while this lives.
    pub fn frame(self: OwnedSwapChain) gfx.Frame {
        return .{ .api = .d3d11, .window = self.hwnd, .swap_chain = self.swap_chain, .device = self.device, .queue = self.context };
    }
};

test "fromFrame types frames" {
    const owned = try OwnedSwapChain.create();
    defer owned.destroy();
    var frame = owned.frame();
    const native = fromFrame(&frame).?;
    try std.testing.expectEqual(owned.swap_chain, native.swap_chain);
    try std.testing.expectEqual(owned.context, native.context);
    try std.testing.expectEqual(@as(?window.Handle, owned.hwnd), native.swap_chain.window());

    frame.api = .vulkan;
    try std.testing.expectEqual(null, fromFrame(&frame));
}

test "frameOf refs until releaseFrame" {
    const owned = try OwnedSwapChain.create();
    defer owned.destroy();
    const frame = try frameOf(owned.swap_chain, owned.device);
    try std.testing.expectEqual(gfx.Api.d3d11, frame.api);
    try std.testing.expectEqual(@as(*anyopaque, owned.hwnd), frame.window);
    try std.testing.expectEqual(@as(?*anyopaque, owned.context), frame.queue);
    releaseFrame(&frame);
}
