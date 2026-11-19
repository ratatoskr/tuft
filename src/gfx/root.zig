//! Hooks a game's rendering at every present, whatever the API.

const std = @import("std");

pub const com = @import("com.zig");
pub const dxgi = @import("dxgi.zig");
pub const d3d10 = @import("d3d10.zig");
pub const d3d11 = @import("d3d11.zig");
pub const d3d12 = @import("d3d12.zig");
pub const opengl = @import("opengl.zig");
pub const vulkan = @import("vulkan.zig");
pub const d3d9 = @import("d3d9.zig");
pub const Tracker = @import("tracker.zig").Tracker;
pub const Paths = @import("Paths.zig");
pub const display = @import("display.zig");
pub const dlls = @import("dlls.zig");
pub const OwnedSurface = @import("owned.zig").OwnedSurface;

/// Our windows presenting through game APIs, which paths never attach to. Any thread.
pub const own_windows = struct {
    var slots: [16]std.atomic.Value(usize) = @splat(.init(0));

    pub fn add(window: *anyopaque) void {
        for (&slots) |*slot| if (slot.cmpxchgStrong(0, @intFromPtr(window), .acq_rel, .acquire) == null) return;
    }

    pub fn remove(window: *anyopaque) void {
        for (&slots) |*slot| _ = slot.cmpxchgStrong(@intFromPtr(window), 0, .acq_rel, .acquire);
    }

    pub fn contains(window: *anyopaque) bool {
        for (&slots) |*slot| if (slot.load(.acquire) == @intFromPtr(window)) return true;
        return false;
    }
};

pub const Api = enum(u32) {
    d3d9 = 1,
    d3d10 = 2,
    d3d11 = 3,
    d3d12 = 4,
    vulkan = 5,
    opengl = 6,
    _,
};

/// Native handles of a presenting surface, by API. C-compatible so it crosses DLLs.
///   api      swap_chain            device                queue
///   d3d9     IDirect3DSwapChain9   IDirect3DDevice9      -          (the implicit swap chain)
///   d3d10    IDXGISwapChain        ID3D10Device          -
///   d3d11    IDXGISwapChain        ID3D11Device          ID3D11DeviceContext (immediate)
///   d3d12    IDXGISwapChain3       ID3D12Device          ID3D12CommandQueue
///   vulkan   vulkan.Swapchain      VkDevice              VkQueue
///   opengl   HDC (latest swap)     HGLRC                 -
pub const Frame = extern struct {
    api: Api,
    /// `HWND` on Windows.
    window: *anyopaque,
    swap_chain: *anyopaque,
    device: *anyopaque,
    queue: ?*anyopaque = null,
    /// What image values mean. Kept current since a game can switch.
    color_space: ColorSpace = .srgb,
};

pub const ColorSpace = enum(u32) {
    /// SDR, sRGB-encoded. 1.0 is the display's white.
    srgb = 0,
    /// HDR, linear 16-bit float, Rec.709 primaries. 1.0 is 80 nits, and values can go outside 0..1.
    scrgb = 1,
    /// HDR10, Rec.2020 primaries with the PQ curve (ST.2084). 1.0 is 10000 nits.
    hdr10 = 2,
    _,
};

/// What a path reports, all on the game's render thread.
/// Release what you took on `resize` and `detach`. Destroying a path skips `detach`.
pub const Listener = struct {
    ctx: *anyopaque,
    attach: *const fn (ctx: *anyopaque, frame: *const Frame) void,
    frame: *const fn (ctx: *anyopaque, frame: *const Frame) void,
    resize: *const fn (ctx: *anyopaque, frame: *const Frame) void,
    detach: *const fn (ctx: *anyopaque, frame: *const Frame) void,
    presented: ?*const fn (ctx: *anyopaque) void = null,

    /// Calls `T`'s `onAttach`, `onFrame`, `onResize`, `onDetach`, and `onPresented` if it has one.
    pub fn of(comptime T: type, ctx: *T) Listener {
        const Thunks = struct {
            fn attach(c: *anyopaque, f: *const Frame) void {
                T.onAttach(@ptrCast(@alignCast(c)), f);
            }
            fn frame(c: *anyopaque, f: *const Frame) void {
                T.onFrame(@ptrCast(@alignCast(c)), f);
            }
            fn resize(c: *anyopaque, f: *const Frame) void {
                T.onResize(@ptrCast(@alignCast(c)), f);
            }
            fn detach(c: *anyopaque, f: *const Frame) void {
                T.onDetach(@ptrCast(@alignCast(c)), f);
            }
            fn presented(c: *anyopaque) void {
                T.onPresented(@ptrCast(@alignCast(c)));
            }
        };
        return .{
            .ctx = ctx,
            .attach = Thunks.attach,
            .frame = Thunks.frame,
            .resize = Thunks.resize,
            .detach = Thunks.detach,
            .presented = if (@hasDecl(T, "onPresented")) Thunks.presented else null,
        };
    }
};

test {
    std.testing.refAllDecls(@This());
    _ = Paths;
    _ = @import("owned.zig");
}
