//! Minimal D3D12 bindings. Struct returns go through a hidden out pointer.

const std = @import("std");

const sys = @import("tuft_sys");

const window = @import("tuft_window");

const gfx = @import("root.zig");
const com = @import("com.zig");
const dxgi = @import("dxgi.zig");

const HRESULT = com.HRESULT;
const Guid = com.Guid;
const method = com.method;

fn guid(comptime text: *const [36]u8) Guid {
    const hex = struct {
        fn parse(comptime T: type, comptime s: []const u8) T {
            return std.fmt.parseInt(T, s, 16) catch unreachable;
        }
    }.parse;
    var data4: [8]u8 = undefined;
    data4[0] = hex(u8, text[19..21]);
    data4[1] = hex(u8, text[21..23]);
    for (0..6) |i| data4[2 + i] = hex(u8, text[24 + i * 2 ..][0..2]);
    return .{ .data1 = hex(u32, text[0..8]), .data2 = hex(u16, text[9..13]), .data3 = hex(u16, text[14..18]), .data4 = data4 };
}

pub const IID_ID3D12Device = guid("189819f1-1db6-4b57-be54-1821339b85f7");
pub const IID_ID3D12CommandQueue = guid("0ec870a6-5d7e-4c22-8cfc-5baae07616ed");
pub const IID_ID3D12Resource = guid("696442be-a72e-4059-bc79-5b5c98040fad");
pub const IID_ID3D12GraphicsCommandList = guid("5b160d0f-ac1b-4185-8ba8-b3ae42a5a455");
pub const IID_ID3D12CommandAllocator = guid("6102dee4-af59-4b09-b999-b44d73f09b24");
pub const IID_ID3D12DescriptorHeap = guid("8efb471d-616c-4f49-90f7-127bb763fa51");
pub const IID_ID3D12Fence = guid("0a753dcf-c4d8-4b91-adf6-be5a60d95a76");
pub const IID_IDXGISwapChain3 = guid("94d99bdb-f1f8-4ab0-b236-7da0170edab1");
const IID_IDXGIFactory4 = guid("1bc6ea02-ef36-464f-bf0c-21ca39e5168a");
const IID_IDXGIAdapter = guid("2411e7e1-12ac-4ccf-bd14-9798e8534dc0");

pub const COMMAND_LIST_TYPE_DIRECT: u32 = 0;
pub const DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV: u32 = 0;
pub const DESCRIPTOR_HEAP_TYPE_RTV: u32 = 2;
pub const DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE: u32 = 1;
pub const RESOURCE_STATE_PRESENT: u32 = 0;
pub const RESOURCE_STATE_RENDER_TARGET: u32 = 4;
pub const RESOURCE_STATE_COPY_DEST: u32 = 0x400;
pub const RESOURCE_STATE_COPY_SOURCE: u32 = 0x800;
pub const HEAP_TYPE_READBACK: u32 = 3;

pub const ResourceDesc = extern struct {
    dimension: u32 = 0,
    alignment: u64 = 0,
    width: u64 = 0,
    height: u32 = 1,
    depth_or_array_size: u16 = 1,
    mip_levels: u16 = 1,
    format: u32 = 0,
    sample_count: u32 = 1,
    sample_quality: u32 = 0,
    layout: u32 = 0,
    flags: u32 = 0,

    pub fn buffer(size: u64) ResourceDesc {
        return .{ .dimension = 1, .width = size, .layout = 1 };
    }
};

pub const HeapProperties = extern struct {
    type: u32,
    cpu_page_property: u32 = 0,
    memory_pool_preference: u32 = 0,
    creation_node_mask: u32 = 0,
    visible_node_mask: u32 = 0,
};

pub const PlacedFootprint = extern struct {
    offset: u64 = 0,
    format: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    depth: u32 = 0,
    row_pitch: u32 = 0,
};

/// `D3D12_TEXTURE_COPY_LOCATION`. A subresource index goes in `footprint.offset`'s low bits.
pub const CopyLocation = extern struct {
    resource: *Resource,
    type: u32,
    footprint: PlacedFootprint = .{},

    pub fn subresource(resource: *Resource, index: u32) CopyLocation {
        return .{ .resource = resource, .type = 0, .footprint = .{ .offset = index } };
    }

    pub fn placed(resource: *Resource, footprint: PlacedFootprint) CopyLocation {
        return .{ .resource = resource, .type = 1, .footprint = footprint };
    }
};
const RESOURCE_BARRIER_ALL_SUBRESOURCES: u32 = 0xffff_ffff;

pub const CpuDescriptorHandle = extern struct { ptr: usize };
pub const GpuDescriptorHandle = extern struct { ptr: u64 };

pub const CommandQueueDesc = extern struct {
    type: u32 = COMMAND_LIST_TYPE_DIRECT,
    priority: i32 = 0,
    flags: u32 = 0,
    node_mask: u32 = 0,
};

pub const DescriptorHeapDesc = extern struct {
    type: u32,
    num_descriptors: u32,
    flags: u32 = 0,
    node_mask: u32 = 0,
};

/// Transition variant of `D3D12_RESOURCE_BARRIER`, the biggest union member.
pub const TransitionBarrier = extern struct {
    type: u32 = 0, // D3D12_RESOURCE_BARRIER_TYPE_TRANSITION
    flags: u32 = 0,
    resource: *Resource,
    subresource: u32 = RESOURCE_BARRIER_ALL_SUBRESOURCES,
    before: u32,
    after: u32,
};

pub const Device = opaque {
    pub fn createCommandQueue(self: *Device, desc: *const CommandQueueDesc) !*CommandQueue {
        var out: ?*CommandQueue = null;
        try check(method(self, 8, fn (*Device, *const CommandQueueDesc, *const Guid, *?*CommandQueue) callconv(.winapi) HRESULT)(self, desc, &IID_ID3D12CommandQueue, &out));
        return out.?;
    }

    pub fn createCommandAllocator(self: *Device, list_type: u32) !*CommandAllocator {
        var out: ?*CommandAllocator = null;
        try check(method(self, 9, fn (*Device, u32, *const Guid, *?*CommandAllocator) callconv(.winapi) HRESULT)(self, list_type, &IID_ID3D12CommandAllocator, &out));
        return out.?;
    }

    /// Comes back open. `close` it after recording.
    pub fn createCommandList(self: *Device, list_type: u32, allocator: *CommandAllocator) !*GraphicsCommandList {
        var out: ?*GraphicsCommandList = null;
        try check(method(self, 12, fn (*Device, u32, u32, *CommandAllocator, ?*anyopaque, *const Guid, *?*GraphicsCommandList) callconv(.winapi) HRESULT)(self, 0, list_type, allocator, null, &IID_ID3D12GraphicsCommandList, &out));
        return out.?;
    }

    pub fn createDescriptorHeap(self: *Device, desc: *const DescriptorHeapDesc) !*DescriptorHeap {
        var out: ?*DescriptorHeap = null;
        try check(method(self, 14, fn (*Device, *const DescriptorHeapDesc, *const Guid, *?*DescriptorHeap) callconv(.winapi) HRESULT)(self, desc, &IID_ID3D12DescriptorHeap, &out));
        return out.?;
    }

    pub fn descriptorIncrement(self: *Device, heap_type: u32) u32 {
        return method(self, 15, fn (*Device, u32) callconv(.winapi) u32)(self, heap_type);
    }

    pub fn createRenderTargetView(self: *Device, resource: *Resource, dest: CpuDescriptorHandle) void {
        method(self, 20, fn (*Device, *Resource, ?*const anyopaque, CpuDescriptorHandle) callconv(.winapi) void)(self, resource, null, dest);
    }

    pub fn createCommittedResource(self: *Device, heap: *const HeapProperties, desc: *const ResourceDesc, state: u32) !*Resource {
        var out: ?*Resource = null;
        try check(method(self, 27, fn (*Device, *const HeapProperties, u32, *const ResourceDesc, u32, ?*const anyopaque, *const Guid, *?*Resource) callconv(.winapi) HRESULT)(self, heap, 0, desc, state, null, &IID_ID3D12Resource, &out));
        return out.?;
    }

    /// For subresource 0. Returns the total size.
    pub fn copyableFootprint(self: *Device, desc: *const ResourceDesc, out: *PlacedFootprint) u64 {
        var total: u64 = 0;
        method(self, 38, fn (*Device, *const ResourceDesc, u32, u32, u64, *PlacedFootprint, ?*u32, ?*u64, *u64) callconv(.winapi) void)(self, desc, 0, 1, 0, out, null, null, &total);
        return total;
    }

    pub fn createFence(self: *Device, initial: u64) !*Fence {
        var out: ?*Fence = null;
        try check(method(self, 36, fn (*Device, u64, u32, *const Guid, *?*Fence) callconv(.winapi) HRESULT)(self, initial, 0, &IID_ID3D12Fence, &out));
        return out.?;
    }
};

pub const CommandQueue = opaque {
    /// Caller owns the ref.
    pub fn getDevice(self: *CommandQueue) ?*Device {
        var out: ?*Device = null;
        const hr = method(self, 7, fn (*CommandQueue, *const Guid, *?*Device) callconv(.winapi) HRESULT)(self, &IID_ID3D12Device, &out);
        return if (com.succeeded(hr)) out else null;
    }

    pub fn executeCommandList(self: *CommandQueue, list: *GraphicsCommandList) void {
        const lists = [_]*GraphicsCommandList{list};
        method(self, 10, fn (*CommandQueue, u32, [*]const *GraphicsCommandList) callconv(.winapi) void)(self, 1, &lists);
    }

    pub fn signal(self: *CommandQueue, fence: *Fence, value: u64) HRESULT {
        return method(self, 14, fn (*CommandQueue, *Fence, u64) callconv(.winapi) HRESULT)(self, fence, value);
    }

    pub fn getDesc(self: *CommandQueue) CommandQueueDesc {
        var desc: CommandQueueDesc = .{};
        _ = method(self, 18, fn (*CommandQueue, *CommandQueueDesc) callconv(.winapi) *CommandQueueDesc)(self, &desc);
        return desc;
    }
};

pub const CommandAllocator = opaque {
    pub fn reset(self: *CommandAllocator) HRESULT {
        return method(self, 8, fn (*CommandAllocator) callconv(.winapi) HRESULT)(self);
    }
};

pub const GraphicsCommandList = opaque {
    pub fn close(self: *GraphicsCommandList) HRESULT {
        return method(self, 9, fn (*GraphicsCommandList) callconv(.winapi) HRESULT)(self);
    }

    pub fn reset(self: *GraphicsCommandList, allocator: *CommandAllocator) HRESULT {
        return method(self, 10, fn (*GraphicsCommandList, *CommandAllocator, ?*anyopaque) callconv(.winapi) HRESULT)(self, allocator, null);
    }

    pub fn transition(self: *GraphicsCommandList, resource: *Resource, before: u32, after: u32) void {
        const barrier: TransitionBarrier = .{ .resource = resource, .before = before, .after = after };
        method(self, 26, fn (*GraphicsCommandList, u32, *const TransitionBarrier) callconv(.winapi) void)(self, 1, &barrier);
    }

    pub fn copyTextureRegion(self: *GraphicsCommandList, dest: *const CopyLocation, src: *const CopyLocation) void {
        method(self, 16, fn (*GraphicsCommandList, *const CopyLocation, u32, u32, u32, *const CopyLocation, ?*const anyopaque) callconv(.winapi) void)(self, dest, 0, 0, 0, src, null);
    }

    pub fn setDescriptorHeap(self: *GraphicsCommandList, heap: *DescriptorHeap) void {
        const heaps = [_]*DescriptorHeap{heap};
        method(self, 28, fn (*GraphicsCommandList, u32, [*]const *DescriptorHeap) callconv(.winapi) void)(self, 1, &heaps);
    }

    pub fn setRenderTarget(self: *GraphicsCommandList, target: CpuDescriptorHandle) void {
        const targets = [_]CpuDescriptorHandle{target};
        method(self, 46, fn (*GraphicsCommandList, u32, [*]const CpuDescriptorHandle, i32, ?*const CpuDescriptorHandle) callconv(.winapi) void)(self, 1, &targets, 0, null);
    }
};

pub const DescriptorHeap = opaque {
    pub fn cpuStart(self: *DescriptorHeap) CpuDescriptorHandle {
        var out: CpuDescriptorHandle = undefined;
        _ = method(self, 9, fn (*DescriptorHeap, *CpuDescriptorHandle) callconv(.winapi) *CpuDescriptorHandle)(self, &out);
        return out;
    }

    pub fn gpuStart(self: *DescriptorHeap) GpuDescriptorHandle {
        var out: GpuDescriptorHandle = undefined;
        _ = method(self, 10, fn (*DescriptorHeap, *GpuDescriptorHandle) callconv(.winapi) *GpuDescriptorHandle)(self, &out);
        return out;
    }
};

pub const Fence = opaque {
    pub fn completedValue(self: *Fence) u64 {
        return method(self, 8, fn (*Fence) callconv(.winapi) u64)(self);
    }

    pub fn wait(self: *Fence, value: u64) void {
        if (self.completedValue() >= value) return;
        // No event handle, so the call itself blocks
        _ = method(self, 9, fn (*Fence, u64, ?*anyopaque) callconv(.winapi) HRESULT)(self, value, null);
    }
};

pub const Resource = opaque {
    pub fn getDesc(self: *Resource) ResourceDesc {
        var out: ResourceDesc = .{};
        _ = method(self, 10, fn (*Resource, *ResourceDesc) callconv(.winapi) *ResourceDesc)(self, &out);
        return out;
    }

    /// Reads it all.
    pub fn map(self: *Resource) ?[*]const u8 {
        var out: ?*anyopaque = null;
        const hr = method(self, 8, fn (*Resource, u32, ?*const anyopaque, *?*anyopaque) callconv(.winapi) HRESULT)(self, 0, null, &out);
        return if (com.succeeded(hr)) @ptrCast(out) else null;
    }

    /// Wrote nothing.
    pub fn unmap(self: *Resource) void {
        const nothing = [2]usize{ 0, 0 };
        method(self, 9, fn (*Resource, u32, ?*const [2]usize) callconv(.winapi) void)(self, 0, &nothing);
    }
};

/// D3D12 swap chains are always `IDXGISwapChain3`.
pub fn currentBackBufferIndex(swap_chain: *dxgi.SwapChain) u32 {
    return method(swap_chain, 36, fn (*dxgi.SwapChain) callconv(.winapi) u32)(swap_chain);
}

/// Caller owns the ref.
pub fn backBuffer(swap_chain: *dxgi.SwapChain, index: u32) ?*Resource {
    var out: ?*anyopaque = null;
    if (!com.succeeded(swap_chain.getBuffer(index, &IID_ID3D12Resource, &out))) return null;
    return @ptrCast(out);
}

fn check(hr: HRESULT) !void {
    if (!com.succeeded(hr)) return error.D3d12CallFailed;
}

pub const Native = struct {
    /// An `IDXGISwapChain3`.
    swap_chain: *dxgi.SwapChain,
    device: *Device,
    queue: *CommandQueue,
};

pub fn fromFrame(frame: *const gfx.Frame) ?Native {
    if (frame.api != .d3d12) return null;
    return .{ .swap_chain = @ptrCast(frame.swap_chain), .device = @ptrCast(frame.device), .queue = @ptrCast(frame.queue.?) };
}

/// Takes refs on both plus the queue's device until `releaseFrame`.
pub fn frameOf(swap_chain: *dxgi.SwapChain, queue: *CommandQueue) !gfx.Frame {
    const hwnd = swap_chain.window() orelse return error.NoOutputWindow;
    // Every D3D12 swap chain is an `IDXGISwapChain3`
    const swap_chain3 = com.query(swap_chain, &IID_IDXGISwapChain3) orelse return error.NotSwapChain3;
    com.release(swap_chain3);
    if (swap_chain3 != @as(*anyopaque, swap_chain)) return error.NotSwapChain3;

    const device = queue.getDevice() orelse return error.NoDevice;
    com.addRef(swap_chain);
    com.addRef(queue);
    return .{ .api = .d3d12, .window = hwnd, .swap_chain = swap_chain, .device = device, .queue = queue };
}

pub fn releaseFrame(frame: *const gfx.Frame) void {
    const native = fromFrame(frame).?;
    com.release(native.queue);
    com.release(native.device);
    com.release(native.swap_chain);
}

const D3D_FEATURE_LEVEL_11_0: u32 = 0xb000;
const DXGI_SWAP_EFFECT_FLIP_DISCARD: u32 = 4;

// Looked up at runtime so games don't all load d3d12.dll and dxgi.dll
const D3D12CreateDeviceFn = fn (adapter: ?*anyopaque, min_feature_level: u32, riid: *const Guid, out: *?*anyopaque) callconv(.winapi) HRESULT;
const CreateDXGIFactory1Fn = fn (riid: *const Guid, out: *?*anyopaque) callconv(.winapi) HRESULT;

const SwapChainDesc1 = extern struct {
    width: u32,
    height: u32,
    format: u32,
    stereo: i32 = 0,
    sample_count: u32 = 1,
    sample_quality: u32 = 0,
    buffer_usage: u32 = dxgi.USAGE_RENDER_TARGET_OUTPUT,
    buffer_count: u32,
    scaling: u32 = 0,
    swap_effect: u32 = DXGI_SWAP_EFFECT_FLIP_DISCARD,
    alpha_mode: u32 = 0,
    flags: u32 = 0,
};

/// Our own device, queue and flip-model swap chain, for tests.
pub const OwnedSwapChain = struct {
    pub const buffer_count = 3;

    hwnd: window.Handle,
    owns_window: bool,
    device: *Device,
    queue: *CommandQueue,
    /// An `IDXGISwapChain3`.
    swap_chain: *dxgi.SwapChain,
    /// Empty list submitted before each present, like a game's frame.
    allocator: *CommandAllocator,
    list: *GraphicsCommandList,

    pub fn create() !OwnedSwapChain {
        const hwnd = try window.createHidden();
        errdefer window.destroy(hwnd);
        var owned = try createOn(hwnd);
        owned.owns_window = true;
        return owned;
    }

    pub fn createOn(hwnd: window.Handle) !OwnedSwapChain {
        const CreateDXGIFactory1 = sys.module.lazyFn("dxgi.dll", "CreateDXGIFactory1", CreateDXGIFactory1Fn) orelse return error.NoDxgi;
        const D3D12CreateDevice = sys.module.lazyFn("d3d12.dll", "D3D12CreateDevice", D3D12CreateDeviceFn) orelse return error.NoD3D12;
        var factory: ?*anyopaque = null;
        try check(CreateDXGIFactory1(&IID_IDXGIFactory4, &factory));
        defer com.release(factory.?);

        // The GPU, or WARP if that fails
        var device: ?*anyopaque = null;
        if (!com.succeeded(D3D12CreateDevice(null, D3D_FEATURE_LEVEL_11_0, &IID_ID3D12Device, &device))) {
            var warp: ?*anyopaque = null;
            try check(method(factory.?, 27, fn (*anyopaque, *const Guid, *?*anyopaque) callconv(.winapi) HRESULT)(factory.?, &IID_IDXGIAdapter, &warp));
            defer com.release(warp.?);
            try check(D3D12CreateDevice(warp, D3D_FEATURE_LEVEL_11_0, &IID_ID3D12Device, &device));
        }
        const d: *Device = @ptrCast(device.?);
        errdefer com.release(d);

        const queue = try d.createCommandQueue(&.{});
        errdefer com.release(queue);

        const desc: SwapChainDesc1 = .{ .width = 64, .height = 64, .format = dxgi.FORMAT_R8G8B8A8_UNORM, .buffer_count = buffer_count };
        var swap_chain: ?*dxgi.SwapChain = null;
        const create_fn = fn (*anyopaque, *CommandQueue, window.Handle, *const SwapChainDesc1, ?*const anyopaque, ?*anyopaque, *?*dxgi.SwapChain) callconv(.winapi) HRESULT;
        try check(method(factory.?, 15, create_fn)(factory.?, queue, hwnd, &desc, null, null, &swap_chain));
        errdefer com.release(swap_chain.?);

        const allocator = try d.createCommandAllocator(COMMAND_LIST_TYPE_DIRECT);
        errdefer com.release(allocator);
        const list = try d.createCommandList(COMMAND_LIST_TYPE_DIRECT, allocator);
        _ = list.close();
        return .{ .hwnd = hwnd, .owns_window = false, .device = d, .queue = queue, .swap_chain = swap_chain.?, .allocator = allocator, .list = list };
    }

    pub fn submit(self: OwnedSwapChain) void {
        self.queue.executeCommandList(self.list);
    }

    pub fn present(self: OwnedSwapChain) HRESULT {
        self.submit();
        return self.swap_chain.present(0, 0);
    }

    pub fn waitIdle(self: OwnedSwapChain) void {
        const fence = self.device.createFence(0) catch return;
        defer com.release(fence);
        if (com.succeeded(self.queue.signal(fence, 1))) fence.wait(1);
    }

    pub fn destroy(self: OwnedSwapChain) void {
        // Nothing of ours can be in flight when we release
        self.waitIdle();
        com.release(self.list);
        com.release(self.allocator);
        com.release(self.swap_chain);
        com.release(self.queue);
        com.release(self.device);
        if (self.owns_window) window.destroy(self.hwnd);
    }
};

test "frameOf refs until releaseFrame" {
    const owned = try OwnedSwapChain.create();
    defer owned.destroy();
    try std.testing.expectEqual(gfx.Api.d3d12, dxgi.apiOf(owned.swap_chain).?);
    try std.testing.expectEqual(COMMAND_LIST_TYPE_DIRECT, owned.queue.getDesc().type);

    const frame = try frameOf(owned.swap_chain, owned.queue);
    try std.testing.expectEqual(gfx.Api.d3d12, frame.api);
    try std.testing.expectEqual(@as(*anyopaque, owned.hwnd), frame.window);
    const native = fromFrame(&frame).?;
    try std.testing.expectEqual(owned.device, native.device);
    try std.testing.expectEqual(owned.queue, native.queue);
    try std.testing.expect(currentBackBufferIndex(native.swap_chain) < OwnedSwapChain.buffer_count);
    releaseFrame(&frame);
}

test "drawing into the back buffer" {
    const owned = try OwnedSwapChain.create();
    defer owned.destroy();

    const rtv_heap = try owned.device.createDescriptorHeap(&.{ .type = DESCRIPTOR_HEAP_TYPE_RTV, .num_descriptors = 1 });
    defer com.release(rtv_heap);
    const allocator = try owned.device.createCommandAllocator(COMMAND_LIST_TYPE_DIRECT);
    defer com.release(allocator);
    const list = try owned.device.createCommandList(COMMAND_LIST_TYPE_DIRECT, allocator);
    defer com.release(list);
    const fence = try owned.device.createFence(0);
    defer com.release(fence);

    const index = currentBackBufferIndex(owned.swap_chain);
    const buffer = backBuffer(owned.swap_chain, index).?;
    defer com.release(buffer);
    owned.device.createRenderTargetView(buffer, rtv_heap.cpuStart());

    list.transition(buffer, RESOURCE_STATE_PRESENT, RESOURCE_STATE_RENDER_TARGET);
    list.setRenderTarget(rtv_heap.cpuStart());
    list.transition(buffer, RESOURCE_STATE_RENDER_TARGET, RESOURCE_STATE_PRESENT);
    try std.testing.expect(com.succeeded(list.close()));
    owned.queue.executeCommandList(list);
    try std.testing.expect(com.succeeded(owned.queue.signal(fence, 1)));
    fence.wait(1);
    try std.testing.expectEqual(1, fence.completedValue());
    try std.testing.expect(com.succeeded(owned.swap_chain.present(0, 0)));
}
