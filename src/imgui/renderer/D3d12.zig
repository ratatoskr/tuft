//! ImGui's D3D12 backend, drawn on the queue the game presents on.
//! On the heap since ImGui keeps a pointer to it for SRV allocations.

const D3d12 = @This();

const std = @import("std");

const gfx = @import("tuft_gfx");

const c = @import("../root.zig").c;

const com = gfx.com;
const d3d12 = gfx.d3d12;
const dxgi = gfx.dxgi;
const Frame = gfx.Frame;
const hdr = @import("hdr.zig");
const capture = @import("../capture.zig");

const max_buffers = 16;
/// Also the viewport swap chains' buffer count; more breaks some games' DXGI, like Visions of Mana's.
/// `render` waits to stay within it, since the game's swap chain may have more.
const frames_in_flight = 3;
const srv_capacity = 64;

state: *State,

const State = struct {
    device: *d3d12.Device,
    queue: *d3d12.CommandQueue,
    format: u32,
    srv_heap: *d3d12.DescriptorHeap,
    srv_increment: u32,
    srv_used: std.StaticBitSet(srv_capacity) = .empty,
    rtv_heap: *d3d12.DescriptorHeap,
    rtv_increment: u32,
    fence: *d3d12.Fence,
    fence_value: u64 = 0,
    list: *d3d12.GraphicsCommandList,
    allocators: [max_buffers]?*d3d12.CommandAllocator = @splat(null),
    /// Plus the fence value of the last frame drawn into each.
    buffers: [max_buffers]?*d3d12.Resource = @splat(null),
    buffer_fences: [max_buffers]u64 = @splat(0),
    buffer_count: u32 = 0,
    /// The fence values of the last few draws, in the order ImGui reuses its buffers.
    draw_fences: [frames_in_flight]u64 = @splat(0),
    draw_at: u32 = 0,
    target_owner: ?*anyopaque = null,
    output: hdr.Output = .{},
    copies: [2]Copy = @splat(.{}),

    fn create(native: d3d12.Native, format: u32) !*State {
        const device = native.device;
        const srv_heap = try device.createDescriptorHeap(&.{
            .type = d3d12.DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV,
            .num_descriptors = srv_capacity,
            .flags = d3d12.DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE,
        });
        errdefer com.release(srv_heap);
        const rtv_heap = try device.createDescriptorHeap(&.{ .type = d3d12.DESCRIPTOR_HEAP_TYPE_RTV, .num_descriptors = max_buffers });
        errdefer com.release(rtv_heap);
        const fence = try device.createFence(0);
        errdefer com.release(fence);
        const first_allocator = try device.createCommandAllocator(d3d12.COMMAND_LIST_TYPE_DIRECT);
        errdefer com.release(first_allocator);
        const list = try device.createCommandList(d3d12.COMMAND_LIST_TYPE_DIRECT, first_allocator);
        errdefer com.release(list);
        if (!com.succeeded(list.close())) return error.D3d12CallFailed;

        const self = try std.heap.page_allocator.create(State);
        com.addRef(device);
        com.addRef(native.queue);
        self.* = .{
            .device = device,
            .queue = native.queue,
            .format = format,
            .srv_heap = srv_heap,
            .srv_increment = device.descriptorIncrement(d3d12.DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV),
            .rtv_heap = rtv_heap,
            .rtv_increment = device.descriptorIncrement(d3d12.DESCRIPTOR_HEAP_TYPE_RTV),
            .fence = fence,
            .list = list,
        };
        self.allocators[0] = first_allocator;
        return self;
    }

    fn destroy(self: *State) void {
        self.waitIdle();
        self.releaseTargets();
        for (self.allocators) |a| if (a) |allocator| com.release(allocator);
        com.release(self.list);
        com.release(self.fence);
        com.release(self.rtv_heap);
        com.release(self.srv_heap);
        com.release(self.queue);
        com.release(self.device);
        std.heap.page_allocator.destroy(self);
    }

    fn waitIdle(self: *State) void {
        self.fence_value += 1;
        if (com.succeeded(self.queue.signal(self.fence, self.fence_value))) self.fence.wait(self.fence_value);
    }

    fn rtv(self: *const State, index: u32) d3d12.CpuDescriptorHandle {
        return .{ .ptr = self.rtv_heap.cpuStart().ptr + @as(usize, index) * self.rtv_increment };
    }

    fn loadTargets(self: *State, swap_chain: *dxgi.SwapChain) !void {
        var desc: dxgi.SwapChainDesc = .{};
        if (!com.succeeded(swap_chain.getDesc(&desc))) return error.D3d12CallFailed;
        const count = @min(desc.buffer_count, max_buffers);
        errdefer self.releaseTargets();
        for (0..count) |i| {
            const index: u32 = @intCast(i);
            const buffer = d3d12.backBuffer(swap_chain, index) orelse return error.NoBackBuffer;
            self.buffers[i] = buffer;
            self.buffer_count = index + 1;
            self.device.createRenderTargetView(buffer, self.rtv(index));
            if (self.allocators[i] == null) self.allocators[i] = try self.device.createCommandAllocator(d3d12.COMMAND_LIST_TYPE_DIRECT);
        }
        self.target_owner = swap_chain;
    }

    /// Waits for the GPU first.
    fn releaseTargets(self: *State) void {
        if (self.buffer_count == 0) return;
        self.waitIdle();
        for (&self.copies) |*copy| copy.release();
        for (self.buffers[0..self.buffer_count]) |*b| {
            if (b.*) |buffer| com.release(buffer);
            b.* = null;
        }
        self.buffer_count = 0;
        self.target_owner = null;
    }

    fn allocSrv(info: [*c]c.ImGui_ImplDX12_InitInfo, cpu: [*c]c.D3D12_CPU_DESCRIPTOR_HANDLE, gpu: [*c]c.D3D12_GPU_DESCRIPTOR_HANDLE) callconv(.c) void {
        const self: *State = @ptrCast(@alignCast(info.*.UserData));
        var free = self.srv_used;
        free.toggleAll();
        // Out of descriptors. ImGui fails that texture instead of overwriting one in use
        const index = free.findFirstSet() orelse {
            cpu.* = .{ .ptr = 0 };
            gpu.* = .{ .ptr = 0 };
            return;
        };
        self.srv_used.set(index);
        cpu.* = .{ .ptr = self.srv_heap.cpuStart().ptr + index * self.srv_increment };
        gpu.* = .{ .ptr = self.srv_heap.gpuStart().ptr + index * self.srv_increment };
    }

    fn freeSrv(info: [*c]c.ImGui_ImplDX12_InitInfo, cpu: c.D3D12_CPU_DESCRIPTOR_HANDLE, _: c.D3D12_GPU_DESCRIPTOR_HANDLE) callconv(.c) void {
        const self: *State = @ptrCast(@alignCast(info.*.UserData));
        const start = self.srv_heap.cpuStart().ptr;
        if (cpu.ptr < start) return;
        const index = (cpu.ptr - start) / self.srv_increment;
        if (index < srv_capacity) self.srv_used.unset(index);
    }
};

/// A readback buffer the back buffer gets copied into on our command list.
const Copy = struct {
    readback: ?*d3d12.Resource = null,
    size: u64 = 0,
    footprint: d3d12.PlacedFootprint = .{},
    width: u32 = 0,
    height: u32 = 0,
    /// Done once the fence gets here.
    fence_value: u64 = 0,
    busy: bool = false,
    color_space: gfx.ColorSpace = .srgb,

    fn release(self: *Copy) void {
        if (self.readback) |r| com.release(r);
        self.* = .{};
    }

    /// Room for `buffer`, false if it can't be copied.
    fn prepare(self: *Copy, device: *d3d12.Device, buffer: *d3d12.Resource) bool {
        const desc = buffer.getDesc();
        if (capture.Format.fromDxgi(desc.format) == .unknown or desc.sample_count > 1) return false;
        var footprint: d3d12.PlacedFootprint = .{};
        const size = device.copyableFootprint(&desc, &footprint);
        if (size == 0 or size == std.math.maxInt(u64)) return false;
        if (self.readback == null or self.size < size) {
            self.release();
            self.readback = device.createCommittedResource(&.{ .type = d3d12.HEAP_TYPE_READBACK }, &.buffer(size), d3d12.RESOURCE_STATE_COPY_DEST) catch return false;
            self.size = size;
        }
        self.footprint = footprint;
        self.width = @intCast(desc.width);
        self.height = desc.height;
        return true;
    }

    fn record(self: *Copy, list: *d3d12.GraphicsCommandList, buffer: *d3d12.Resource) void {
        list.copyTextureRegion(&.placed(self.readback.?, self.footprint), &.subresource(buffer, 0));
    }

    fn land(self: *Copy, fence: *d3d12.Fence, point: capture.Point, captures: *capture.Captures) void {
        if (fence.completedValue() < self.fence_value) return;
        self.busy = false;
        const readback = self.readback.?;
        const data = readback.map() orelse return captures.failed(point);
        defer readback.unmap();
        const format = capture.Format.fromDxgi(self.footprint.format);
        const pitch = self.footprint.row_pitch;
        captures.done(&.{
            .point = point,
            .width = self.width,
            .height = self.height,
            .pitch = pitch,
            .format = format,
            .native_format = self.footprint.format,
            .color_space = self.color_space,
            .pixels = data[@intCast(self.footprint.offset)..][0..capture.Image.size(self.width, self.height, pitch, format)],
        });
    }
};

fn formatOf(swap_chain: *dxgi.SwapChain) ?u32 {
    var desc: dxgi.SwapChainDesc = .{};
    if (!com.succeeded(swap_chain.getDesc(&desc))) return null;
    return desc.buffer_desc.format;
}

pub fn init(frame: *const Frame) error{BackendFailed}!D3d12 {
    const native = d3d12.fromFrame(frame) orelse return error.BackendFailed;
    const format = formatOf(native.swap_chain) orelse return error.BackendFailed;
    const state = State.create(native, format) catch return error.BackendFailed;
    errdefer state.destroy();

    var info: c.ImGui_ImplDX12_InitInfo = std.mem.zeroes(c.ImGui_ImplDX12_InitInfo);
    info.Device = @ptrCast(native.device);
    info.CommandQueue = @ptrCast(native.queue);
    info.NumFramesInFlight = frames_in_flight;
    info.RTVFormat = dxgi.FORMAT_R8G8B8A8_UNORM;
    info.UserData = state;
    info.SrvDescriptorHeap = @ptrCast(state.srv_heap);
    info.SrvDescriptorAllocFn = State.allocSrv;
    info.SrvDescriptorFreeFn = State.freeSrv;
    if (!c.cImGui_ImplDX12_Init(&info)) return error.BackendFailed;
    return .{ .state = state };
}

pub fn deinit(self: *D3d12) void {
    self.state.waitIdle();
    c.cImGui_ImplDX12_Shutdown();
    hdr.tuft_imgui_hdr_release();
    self.state.destroy();
}

pub fn matches(self: *const D3d12, frame: *const Frame) bool {
    const native = d3d12.fromFrame(frame) orelse return false;
    const s = self.state;
    return native.device == s.device and native.queue == s.queue and formatOf(native.swap_chain) == s.format;
}

pub fn beginFrame(self: *D3d12, frame: *const Frame) bool {
    const native = d3d12.fromFrame(frame) orelse return false;
    const s = self.state;
    if (s.target_owner != @as(*anyopaque, native.swap_chain)) {
        s.releaseTargets();
        s.loadTargets(native.swap_chain) catch return false;
    }
    if (s.output.update(frame)) {
        s.waitIdle(); // the game window's pipeline may be in use
        s.output.applyD3d();
    }
    c.cImGui_ImplDX12_NewFrame();
    return true;
}

/// Own pipeline for the game's format unless ImGui's 8-bit SDR one fits.
pub fn drawStarted(self: *D3d12) void {
    const s = self.state;
    if (s.output.mode() != 0 or s.format != dxgi.FORMAT_R8G8B8A8_UNORM) hdr.drawFirst(hdr.d3d12_callback, @ptrFromInt(s.format));
}

pub fn render(self: *D3d12, frame: *const Frame, draw_data: *c.ImDrawData, captures: *capture.Captures) void {
    const native = d3d12.fromFrame(frame) orelse return;
    const s = self.state;
    const index = d3d12.currentBackBufferIndex(native.swap_chain);
    if (index >= s.buffer_count) return;

    // GPU has to be done with this buffer before we reuse its allocator
    s.fence.wait(s.buffer_fences[index]);
    const allocator = s.allocators[index].?;
    if (!com.succeeded(allocator.reset())) return;
    if (!com.succeeded(s.list.reset(allocator))) return;

    const buffer = s.buffers[index].?;
    var taking = capture.Points.empty;
    for ([_]capture.Point{ .before, .after }) |point| {
        const copy = &s.copies[@backingInt(point)];
        if (!captures.want(point) or copy.busy) continue;
        if (copy.prepare(s.device, buffer)) taking.insert(point) else captures.failed(point);
    }

    if (taking.contains(.before)) {
        s.list.transition(buffer, d3d12.RESOURCE_STATE_PRESENT, d3d12.RESOURCE_STATE_COPY_SOURCE);
        s.copies[0].record(s.list, buffer);
        s.list.transition(buffer, d3d12.RESOURCE_STATE_COPY_SOURCE, d3d12.RESOURCE_STATE_RENDER_TARGET);
    } else {
        s.list.transition(buffer, d3d12.RESOURCE_STATE_PRESENT, d3d12.RESOURCE_STATE_RENDER_TARGET);
    }
    s.list.setRenderTarget(s.rtv(index));
    s.list.setDescriptorHeap(s.srv_heap);
    // ImGui's about to reuse the buffers it drew from `frames_in_flight` draws ago
    const slot = s.draw_at;
    s.fence.wait(s.draw_fences[slot]);
    c.cImGui_ImplDX12_RenderDrawData(draw_data, @ptrCast(s.list));
    s.draw_at = (slot + 1) % frames_in_flight;
    if (taking.contains(.after)) {
        s.list.transition(buffer, d3d12.RESOURCE_STATE_RENDER_TARGET, d3d12.RESOURCE_STATE_COPY_SOURCE);
        s.copies[1].record(s.list, buffer);
        s.list.transition(buffer, d3d12.RESOURCE_STATE_COPY_SOURCE, d3d12.RESOURCE_STATE_PRESENT);
    } else {
        s.list.transition(buffer, d3d12.RESOURCE_STATE_RENDER_TARGET, d3d12.RESOURCE_STATE_PRESENT);
    }
    if (!com.succeeded(s.list.close())) return;

    s.queue.executeCommandList(s.list);
    s.fence_value += 1;
    if (!com.succeeded(s.queue.signal(s.fence, s.fence_value))) return;
    s.buffer_fences[index] = s.fence_value;
    s.draw_fences[slot] = s.fence_value;
    var it = taking.iterator();
    while (it.next()) |point| {
        const copy = &s.copies[@backingInt(point)];
        copy.busy = true;
        copy.fence_value = s.fence_value;
        copy.color_space = frame.color_space;
        captures.started(point);
    }
}

pub fn poll(self: *D3d12, _: *const Frame, captures: *capture.Captures) void {
    const s = self.state;
    for (&s.copies, 0..) |*copy, i| {
        if (captures.check(@fromBackingInt(@intCast(i)), copy.busy)) copy.land(s.fence, @fromBackingInt(@intCast(i)), captures);
    }
}

/// The backend records and submits these on the queue itself.
pub fn renderPlatformWindows(_: *D3d12, _: *const Frame) void {
    c.ImGui_RenderPlatformWindowsDefault();
}

/// Waits for the GPU and drops the back buffers.
pub fn releaseTarget(self: *D3d12) void {
    self.state.releaseTargets();
}
