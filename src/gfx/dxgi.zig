//! DXGI bindings and the present path for D3D10, D3D11 and D3D12.

const std = @import("std");

const hook = @import("tuft_hook");
const tuft_window = @import("tuft_window");
const sys = @import("tuft_sys");

const gfx = @import("root.zig");
const com = @import("com.zig");
const d3d10 = @import("d3d10.zig");
const d3d11 = @import("d3d11.zig");
const d3d12 = @import("d3d12.zig");
const Tracker = @import("tracker.zig").Tracker;
const HookSet = hook.set.HookSet;

const log = std.log.scoped(.tuft_gfx);

const HRESULT = com.HRESULT;
const Guid = com.Guid;
const method = com.method;

pub const FORMAT_R8G8B8A8_UNORM: u32 = 28;
pub const USAGE_RENDER_TARGET_OUTPUT: u32 = 0x20;

pub const ModeDesc = extern struct {
    width: u32 = 0,
    height: u32 = 0,
    refresh_numerator: u32 = 0,
    refresh_denominator: u32 = 0,
    format: u32 = 0,
    scanline_ordering: u32 = 0,
    scaling: u32 = 0,
};

pub const SwapChainDesc = extern struct {
    buffer_desc: ModeDesc = .{},
    sample_count: u32 = 0,
    sample_quality: u32 = 0,
    buffer_usage: u32 = 0,
    buffer_count: u32 = 0,
    output_window: ?tuft_window.Handle = null,
    windowed: i32 = 0,
    swap_effect: u32 = 0,
    flags: u32 = 0,
};

pub const SwapChain = opaque {
    pub const present_index = 8;
    pub const resize_buffers_index = 13;

    pub const PresentFn = fn (*SwapChain, sync_interval: u32, flags: u32) callconv(.winapi) HRESULT;
    pub const ResizeBuffersFn = fn (*SwapChain, buffer_count: u32, width: u32, height: u32, format: u32, flags: u32) callconv(.winapi) HRESULT;

    pub fn present(self: *SwapChain, sync_interval: u32, flags: u32) HRESULT {
        return method(self, present_index, PresentFn)(self, sync_interval, flags);
    }

    pub fn resizeBuffers(self: *SwapChain, buffer_count: u32, width: u32, height: u32, format: u32, flags: u32) HRESULT {
        return method(self, resize_buffers_index, ResizeBuffersFn)(self, buffer_count, width, height, format, flags);
    }

    pub fn getBuffer(self: *SwapChain, index: u32, iid: *const Guid, out: *?*anyopaque) HRESULT {
        return method(self, 9, fn (*SwapChain, u32, *const Guid, *?*anyopaque) callconv(.winapi) HRESULT)(self, index, iid, out);
    }

    /// Device as interface `iid` with a ref, or null.
    pub fn getDevice(self: *SwapChain, iid: *const Guid) ?*anyopaque {
        var out: ?*anyopaque = null;
        const hr = method(self, 7, fn (*SwapChain, *const Guid, *?*anyopaque) callconv(.winapi) HRESULT)(self, iid, &out);
        return if (com.succeeded(hr)) out else null;
    }

    pub fn getDesc(self: *SwapChain, desc: *SwapChainDesc) HRESULT {
        return method(self, 12, fn (*SwapChain, *SwapChainDesc) callconv(.winapi) HRESULT)(self, desc);
    }

    pub fn window(self: *SwapChain) ?tuft_window.Handle {
        var desc: SwapChainDesc = .{};
        if (!com.succeeded(self.getDesc(&desc))) return null;
        return desc.output_window;
    }
};

/// D3D10 is checked first since its devices are `ID3D11Device`s too.
pub fn apiOf(swap_chain: *SwapChain) ?gfx.Api {
    if (swap_chain.getDevice(&d3d12.IID_ID3D12Device)) |d| {
        com.release(d);
        return .d3d12;
    }
    if (swap_chain.getDevice(&d3d10.IID_ID3D10Device)) |d| {
        com.release(d);
        return .d3d10;
    }
    if (swap_chain.getDevice(&d3d11.IID_ID3D11Device)) |d| {
        com.release(d);
        return .d3d11;
    }
    return null;
}

/// `Present1` and `ResizeBuffers1`, newer entry points D3D12 games use.
pub const Present1Fn = fn (*SwapChain, sync_interval: u32, flags: u32, params: ?*const anyopaque) callconv(.winapi) HRESULT;
pub const ResizeBuffers1Fn = fn (*SwapChain, buffer_count: u32, width: u32, height: u32, format: u32, flags: u32, node_masks: ?[*]const u32, queues: ?[*]const ?*anyopaque) callconv(.winapi) HRESULT;
pub const SetColorSpace1Fn = fn (*SwapChain, color_space: u32) callconv(.winapi) HRESULT;
const present1_index = 22;
const set_color_space1_index = 38;
const resize_buffers1_index = 39;

pub const FORMAT_R16G16B16A16_FLOAT: u32 = 10;
pub const FORMAT_R10G10B10A2_UNORM: u32 = 24;
pub const COLOR_SPACE_RGB_FULL_G22_NONE_P709: u32 = 0;
pub const COLOR_SPACE_RGB_FULL_G10_NONE_P709: u32 = 1;
pub const COLOR_SPACE_RGB_FULL_G2084_NONE_P2020: u32 = 12;
const IID_IDXGIFactory1: Guid = .{ .data1 = 0x770aae78, .data2 = 0xf26f, .data3 = 0x4dba, .data4 = .{ 0xa8, 0x29, 0x25, 0x3c, 0x83, 0xd1, 0xb3, 0x87 } };
const IID_IDXGIFactory2: Guid = .{ .data1 = 0x50c83a1c, .data2 = 0xe072, .data3 = 0x4c48, .data4 = .{ 0x87, 0xb0, 0x36, 0x30, 0xfa, 0x36, 0xa6, 0xd0 } };
const IID_IDXGISwapChain1: Guid = .{ .data1 = 0x790a45f7, .data2 = 0x0d42, .data3 = 0x4876, .data4 = .{ 0x98, 0x3a, 0x0a, 0x55, 0xcf, 0xe6, 0xf4, 0xaa } };

pub const SwapChainMethods = struct {
    present: usize,
    resize_buffers: usize,
    /// Needs `IDXGISwapChain1`/`3`, so Windows 8/10 and up.
    present1: ?usize = null,
    resize_buffers1: ?usize = null,
    set_color_space1: ?usize = null,
};

/// Every DXGI swap chain is the same class, so these work for all.
pub fn findSwapChainMethods() !SwapChainMethods {
    const probe = try d3d11.OwnedSwapChain.create();
    defer probe.destroy();
    var methods: SwapChainMethods = .{
        .present = com.vtableEntry(probe.swap_chain, SwapChain.present_index),
        .resize_buffers = com.vtableEntry(probe.swap_chain, SwapChain.resize_buffers_index),
    };
    if (com.query(probe.swap_chain, &IID_IDXGISwapChain1)) |sc1| {
        defer com.release(sc1);
        methods.present1 = com.vtableEntry(sc1, present1_index);
    }
    if (com.query(probe.swap_chain, &d3d12.IID_IDXGISwapChain3)) |sc3| {
        defer com.release(sc3);
        methods.resize_buffers1 = com.vtableEntry(sc3, resize_buffers1_index);
        methods.set_color_space1 = com.vtableEntry(sc3, set_color_space1_index);
    }
    return methods;
}

/// Nesting depth on this thread, so `Present1` into `Present` reports once.
threadlocal var present_depth: u32 = 0;
threadlocal var resize_depth: u32 = 0;

/// The DXGI path. Init `tuft_hook` first.
/// D3D12 needs the present queue, which DXGI won't say, so we hook `ExecuteCommandLists` for it.
pub const PresentHook = struct {
    const PresentFn = SwapChain.PresentFn;
    const ResizeBuffersFn = SwapChain.ResizeBuffersFn;

    allocator: std.mem.Allocator,
    present_hooks: HookSet(PresentFn) = .{},
    resize_hooks: HookSet(ResizeBuffersFn) = .{},
    present1_hooks: HookSet(Present1Fn) = .{},
    resize1_hooks: HookSet(ResizeBuffers1Fn) = .{},
    color_space_hooks: HookSet(SetColorSpace1Fn) = .{},
    /// For `createEarly`.
    create_hooks: HookSet(CreateSwapChainFn) = .{},
    create_hwnd_hooks: HookSet(CreateSwapChainForHwndFn) = .{},
    /// Held while adding hooks from game threads and while enabling them.
    lock: sys.sync.RwLock = .{},
    enabled: bool = false,
    /// Latest few color spaces games set.
    color_spaces: [8]struct { swap_chain: ?*SwapChain = null, color_space: u32 = 0 } = @splat(.{}),
    color_spaces_next: usize = 0,
    /// `gfx.color_space_hint`'s version as of the last present that looked. Render thread.
    hint_version: u32 = 0,
    /// D3D12 only.
    execute_hooks: HookSet(ExecuteCommandListsFn) = .{},
    execute_hook_failed: bool = false,
    /// Direct queue the game last submitted on. We hold a ref.
    queue: ?*d3d12.CommandQueue = null,
    queue_lock: sys.sync.RwLock = .{},
    tracker: Tracker(Source),

    const CreateSwapChainFn = fn (factory: *anyopaque, device: *anyopaque, desc: *SwapChainDesc, out: *?*SwapChain) callconv(.winapi) HRESULT;
    const CreateSwapChainForHwndFn = fn (factory: *anyopaque, device: *anyopaque, window: tuft_window.Handle, desc: *const anyopaque, fullscreen: ?*const anyopaque, output: ?*anyopaque, out: *?*SwapChain) callconv(.winapi) HRESULT;
    const create_swap_chain_index = 10;
    const create_swap_chain_for_hwnd_index = 15;
    const CreateDXGIFactory1Fn = fn (iid: *const Guid, out: *?*anyopaque) callconv(.winapi) HRESULT;

    /// Hooks start disabled.
    pub fn create(allocator: std.mem.Allocator, listener: gfx.Listener) !*PresentHook {
        const methods = try findSwapChainMethods();
        const self = try init(allocator, listener);
        errdefer self.destroy();
        _ = try self.present_hooks.add(methods.present, onPresent, self);
        _ = try self.resize_hooks.add(methods.resize_buffers, onResizeBuffers, self);
        if (methods.present1) |a| _ = try self.present1_hooks.add(a, onPresent1, self);
        if (methods.resize_buffers1) |a| _ = try self.resize1_hooks.add(a, onResizeBuffers1, self);
        if (methods.set_color_space1) |a| _ = try self.color_space_hooks.add(a, onSetColorSpace1, self);
        return self;
    }

    /// Makes no swap chains of its own, since overlays could mistake them for the game's.
    pub fn createEarly(allocator: std.mem.Allocator, listener: gfx.Listener) !*PresentHook {
        const dxgi = sys.module.findBase("dxgi.dll") orelse return error.NotInUse;
        const create_factory: *const CreateDXGIFactory1Fn = @ptrFromInt(sys.module.findExport(dxgi, "CreateDXGIFactory1") orelse return error.NoCreateDXGIFactory1);
        var factory: ?*anyopaque = null;
        if (!com.succeeded(create_factory(&IID_IDXGIFactory1, &factory))) return error.CreateFactoryFailed;
        defer com.release(factory.?);

        const self = try init(allocator, listener);
        errdefer self.destroy();
        const create_address = com.vtableEntry(factory.?, create_swap_chain_index);
        _ = try self.create_hooks.add(create_address, onCreateSwapChain, self);
        var hwnd_address: ?usize = null;
        if (com.query(factory.?, &IID_IDXGIFactory2)) |factory2| {
            defer com.release(factory2);
            hwnd_address = com.vtableEntry(factory2, create_swap_chain_for_hwnd_index);
            _ = try self.create_hwnd_hooks.add(hwnd_address.?, onCreateSwapChainForHwnd, self);
        }
        log.info("dxgi: waiting for the game to make a swap chain (CreateSwapChain{s} hooked)", .{if (hwnd_address != null) ", CreateSwapChainForHwnd" else ""});
        return self;
    }

    /// `createEarly`, plus hooks the known game swap chain `object` right away.
    pub fn createFrom(allocator: std.mem.Allocator, listener: gfx.Listener, object: *anyopaque) !*PresentHook {
        const self = try createEarly(allocator, listener);
        log.info("dxgi: hooking the game's swap chain 0x{x}, handed over", .{@intFromPtr(object)});
        self.watchSwapChain(@ptrCast(object));
        return self;
    }

    fn init(allocator: std.mem.Allocator, listener: gfx.Listener) !*PresentHook {
        const self = try allocator.create(PresentHook);
        self.* = .{ .allocator = allocator, .tracker = .{ .listener = listener, .source = .{ .present = self } } };
        return self;
    }

    pub fn enable(self: *PresentHook) !void {
        self.lock.lock();
        defer self.lock.unlock();
        self.enabled = true;
        try self.create_hooks.enable();
        try self.create_hwnd_hooks.enable();
        try self.resize_hooks.enable();
        try self.resize1_hooks.enable();
        try self.color_space_hooks.enable();
        try self.present_hooks.enable();
        try self.present1_hooks.enable();
    }

    fn onCreateSwapChain(self: *PresentHook, h: *hook.TypedHook(CreateSwapChainFn), factory: *anyopaque, device: *anyopaque, desc: *SwapChainDesc, out: *?*SwapChain) HRESULT {
        const hr = h.original()(factory, device, desc, out);
        self.created("CreateSwapChain", hr, out.*);
        return hr;
    }

    fn onCreateSwapChainForHwnd(self: *PresentHook, h: *hook.TypedHook(CreateSwapChainForHwndFn), factory: *anyopaque, device: *anyopaque, window: tuft_window.Handle, desc: *const anyopaque, fullscreen: ?*const anyopaque, output: ?*anyopaque, out: *?*SwapChain) HRESULT {
        const hr = h.original()(factory, device, window, desc, fullscreen, output, out);
        if (!com.succeeded(hr)) describeFailed(device, window, @ptrCast(@alignCast(desc)), fullscreen != null);
        self.created("CreateSwapChainForHwnd", hr, out.*);
        return hr;
    }

    /// What was asked for, since the error alone never says which part it didn't like.
    fn describeFailed(device: *anyopaque, window: tuft_window.Handle, desc: *const d3d12.SwapChainDesc1, fullscreen: bool) void {
        // A D3D12 swap chain is made on a queue, and only a direct one will do
        const queue_type: ?u32 = if (com.query(device, &d3d12.IID_ID3D12CommandQueue)) |q| blk: {
            defer com.release(q);
            break :blk @as(*d3d12.CommandQueue, @ptrCast(q)).getDesc().type;
        } else null;
        log.info("dxgi: it asked for {d}x{d}, format {d}, {d} buffers, swap effect {d}, scaling {d}, alpha mode {d}, flags 0x{x}, samples {d}, usage 0x{x}{s}, on {s} (queue type {?d}), window 0x{x}", .{
            desc.width,                             desc.height,                                             desc.format, desc.buffer_count,   desc.swap_effect,
            desc.scaling,                           desc.alpha_mode,                                         desc.flags,  desc.sample_count,   desc.buffer_usage,
            if (fullscreen) ", fullscreen" else "", if (queue_type != null) "a D3D12 queue" else "a device", queue_type,  @intFromPtr(window),
        });
    }

    fn created(self: *PresentHook, comptime name: []const u8, hr: HRESULT, swap_chain: ?*SwapChain) void {
        if (!com.succeeded(hr)) return log.info("dxgi: the game's " ++ name ++ " failed (0x{x})", .{@as(u32, @bitCast(hr))});
        const sc = swap_chain orelse return;
        var desc: SwapChainDesc = .{};
        _ = sc.getDesc(&desc);
        const api: []const u8 = if (apiOf(sc)) |a| @tagName(a) else "unknown API";
        log.info("dxgi: the game made a swap chain ({s} " ++ name ++ ", {d}x{d}, format {d}, window 0x{x}); hooking its Present and ResizeBuffers", .{
            api, desc.buffer_desc.width, desc.buffer_desc.height, desc.buffer_desc.format, @intFromPtr(desc.output_window),
        });
        self.watchSwapChain(sc);
    }

    fn watchSwapChain(self: *PresentHook, swap_chain: *SwapChain) void {
        self.lock.lock();
        defer self.lock.unlock();
        self.addLocked(ResizeBuffersFn, &self.resize_hooks, com.vtableEntry(swap_chain, SwapChain.resize_buffers_index), onResizeBuffers, "ResizeBuffers");
        self.addLocked(PresentFn, &self.present_hooks, com.vtableEntry(swap_chain, SwapChain.present_index), onPresent, "Present");
        if (com.query(swap_chain, &IID_IDXGISwapChain1)) |sc1| {
            defer com.release(sc1);
            self.addLocked(Present1Fn, &self.present1_hooks, com.vtableEntry(sc1, present1_index), onPresent1, "Present1");
        }
        if (com.query(swap_chain, &d3d12.IID_IDXGISwapChain3)) |sc3| {
            defer com.release(sc3);
            self.addLocked(ResizeBuffers1Fn, &self.resize1_hooks, com.vtableEntry(sc3, resize_buffers1_index), onResizeBuffers1, "ResizeBuffers1");
            self.addLocked(SetColorSpace1Fn, &self.color_space_hooks, com.vtableEntry(sc3, set_color_space1_index), onSetColorSpace1, "SetColorSpace1");
        }
    }

    /// Skips already hooked addresses. Enabled if the path is.
    fn addLocked(self: *PresentHook, comptime F: type, set: *HookSet(F), address: usize, comptime callback: anytype, comptime name: []const u8) void {
        const added = set.add(address, callback, self) catch |err| return log.warn("Couldn't hook the game's " ++ name ++ " at 0x{x}: {t}", .{ address, err });
        const h = added orelse return;
        if (self.enabled) set.enableHook(h) catch |err| return log.warn("Couldn't hook the game's " ++ name ++ " at 0x{x}: {t}", .{ address, err });
        log.debug("Hooked the game's " ++ name ++ " at 0x{x}", .{address});
    }

    /// Unhooks, waiting for presents in flight.
    pub fn destroy(self: *PresentHook) void {
        self.destroyHooks();
        self.tracker.deinit();
        if (self.queue) |q| com.release(q);
        self.allocator.destroy(self);
    }

    fn destroyHooks(self: *PresentHook) void {
        // Creation hooks first, since their calls in flight might add the others
        self.create_hooks.destroy();
        self.create_hwnd_hooks.destroy();
        self.present_hooks.destroy();
        self.present1_hooks.destroy();
        self.resize_hooks.destroy();
        self.resize1_hooks.destroy();
        self.color_space_hooks.destroy();
        self.execute_hooks.destroy();
    }

    fn onPresent(self: *PresentHook, h: *hook.TypedHook(PresentFn), swap_chain: *SwapChain, sync_interval: u32, flags: u32) HRESULT {
        self.beginPresent(swap_chain);
        defer present_depth -= 1;
        return h.original()(swap_chain, sync_interval, flags);
    }

    fn onPresent1(self: *PresentHook, h: *hook.TypedHook(Present1Fn), swap_chain: *SwapChain, sync_interval: u32, flags: u32, params: ?*const anyopaque) HRESULT {
        self.beginPresent(swap_chain);
        defer present_depth -= 1;
        return h.original()(swap_chain, sync_interval, flags, params);
    }

    fn beginPresent(self: *PresentHook, swap_chain: *SwapChain) void {
        present_depth += 1;
        if (present_depth != 1) return;
        self.tracker.presented();
        // Before the frame goes out, so it's drawn with the new one
        const hint = gfx.color_space_hint.version();
        if (hint != self.hint_version) {
            self.hint_version = hint;
            if (self.tracker.current(swap_chain)) |f| f.color_space = self.colorSpaceOf(swap_chain);
        }
        self.tracker.present(swap_chain);
    }

    fn onResizeBuffers(self: *PresentHook, h: *hook.TypedHook(ResizeBuffersFn), swap_chain: *SwapChain, buffer_count: u32, width: u32, height: u32, format: u32, flags: u32) HRESULT {
        self.beginResize(swap_chain);
        defer self.endResize(swap_chain);
        return h.original()(swap_chain, buffer_count, width, height, format, flags);
    }

    fn onResizeBuffers1(self: *PresentHook, h: *hook.TypedHook(ResizeBuffers1Fn), swap_chain: *SwapChain, buffer_count: u32, width: u32, height: u32, format: u32, flags: u32, node_masks: ?[*]const u32, queues: ?[*]const ?*anyopaque) HRESULT {
        self.beginResize(swap_chain);
        defer self.endResize(swap_chain);
        return h.original()(swap_chain, buffer_count, width, height, format, flags, node_masks, queues);
    }

    fn beginResize(self: *PresentHook, swap_chain: *SwapChain) void {
        resize_depth += 1;
        if (resize_depth == 1) self.tracker.resize(swap_chain);
    }

    /// The format might have changed, to or from HDR.
    fn endResize(self: *PresentHook, swap_chain: *SwapChain) void {
        resize_depth -= 1;
        if (resize_depth != 0) return;
        if (self.tracker.current(swap_chain)) |f| f.color_space = self.colorSpaceOf(swap_chain);
    }

    fn onSetColorSpace1(self: *PresentHook, h: *hook.TypedHook(SetColorSpace1Fn), swap_chain: *SwapChain, color_space: u32) HRESULT {
        const hr = h.original()(swap_chain, color_space);
        if (com.succeeded(hr)) {
            self.recordColorSpace(swap_chain, color_space);
            if (self.tracker.current(swap_chain)) |f| f.color_space = self.colorSpaceOf(swap_chain);
        }
        return hr;
    }

    fn recordColorSpace(self: *PresentHook, swap_chain: *SwapChain, color_space: u32) void {
        const slot = for (&self.color_spaces) |*s| {
            if (s.swap_chain == swap_chain) break s;
        } else blk: {
            const s = &self.color_spaces[self.color_spaces_next];
            self.color_spaces_next = (self.color_spaces_next + 1) % self.color_spaces.len;
            break :blk s;
        };
        slot.* = .{ .swap_chain = swap_chain, .color_space = color_space };
    }

    /// What the game set, else what its plugin says, else SDR. Only FP16 implies HDR, since many games
    /// draw SDR into 10 bits. HDR10 joined late shows as SDR till the game sets its color space again.
    fn colorSpaceOf(self: *PresentHook, swap_chain: *SwapChain) gfx.ColorSpace {
        var desc: SwapChainDesc = .{};
        if (!com.succeeded(swap_chain.getDesc(&desc))) return .srgb;
        const set: ?u32 = for (self.color_spaces) |s| {
            if (s.swap_chain == swap_chain) break s.color_space;
        } else null;
        return switch (desc.buffer_desc.format) {
            FORMAT_R16G16B16A16_FLOAT => .scrgb,
            FORMAT_R10G10B10A2_UNORM => if (set) |cs|
                (if (cs == COLOR_SPACE_RGB_FULL_G2084_NONE_P2020) .hdr10 else .srgb)
            else if (gfx.color_space_hint.get() == .hdr10) .hdr10 else .srgb,
            else => .srgb,
        };
    }

    const ExecuteCommandListsFn = fn (*d3d12.CommandQueue, count: u32, lists: [*]const *anyopaque) callconv(.winapi) void;

    fn onExecuteCommandLists(self: *PresentHook, h: *hook.TypedHook(ExecuteCommandListsFn), queue: *d3d12.CommandQueue, count: u32, lists: [*]const *anyopaque) void {
        if (@atomicLoad(?*d3d12.CommandQueue, &self.queue, .acquire) != queue and queue.getDesc().type == d3d12.COMMAND_LIST_TYPE_DIRECT) {
            self.queue_lock.lock();
            defer self.queue_lock.unlock();
            if (self.queue != queue) {
                com.addRef(queue);
                if (self.queue) |old| com.release(old);
                @atomicStore(?*d3d12.CommandQueue, &self.queue, queue, .release);
            }
        }
        h.original()(queue, count, lists);
    }

    /// With a ref. `error.NotReady` until the game has submitted on one.
    fn queueFor(self: *PresentHook, device: *d3d12.Device) !*d3d12.CommandQueue {
        if (self.execute_hooks.len == 0) {
            if (self.execute_hook_failed) return error.CantFindQueue;
            self.hookExecute(device) catch |err| {
                self.execute_hook_failed = true;
                return err;
            };
            return error.NotReady;
        }
        self.queue_lock.lockShared();
        defer self.queue_lock.unlockShared();
        const queue = self.queue orelse return error.NotReady;
        const queue_device = queue.getDevice() orelse return error.NotReady;
        com.release(queue_device);
        if (queue_device != device) return error.NotReady;
        com.addRef(queue);
        return queue;
    }

    fn hookExecute(self: *PresentHook, device: *d3d12.Device) !void {
        const probe = try device.createCommandQueue(&.{});
        const address = com.vtableEntry(probe, 10);
        com.release(probe);
        errdefer self.execute_hooks.destroy();
        _ = try self.execute_hooks.add(address, onExecuteCommandLists, self);
        try self.execute_hooks.enable();
    }

    const Source = struct {
        pub const Key = *SwapChain;
        pub const noun = "swap chain";

        present: ?*PresentHook = null,

        pub fn keyOf(f: *const gfx.Frame) Key {
            return @ptrCast(f.swap_chain);
        }

        pub fn windowOf(_: Source, swap_chain: Key) ?*anyopaque {
            return swap_chain.window();
        }

        pub fn attach(source: Source, swap_chain: Key) !gfx.Frame {
            var frame = try frameFor(source, swap_chain);
            frame.color_space = source.present.?.colorSpaceOf(swap_chain);
            return frame;
        }

        fn frameFor(source: Source, swap_chain: Key) !gfx.Frame {
            const api = apiOf(swap_chain) orelse return error.UnknownApi;
            return switch (api) {
                .d3d10 => blk: {
                    const device: *d3d10.Device = @ptrCast(swap_chain.getDevice(&d3d10.IID_ID3D10Device).?);
                    defer com.release(device);
                    break :blk try d3d10.frameOf(swap_chain, device);
                },
                .d3d11 => blk: {
                    const device: *d3d11.Device = @ptrCast(swap_chain.getDevice(&d3d11.IID_ID3D11Device).?);
                    defer com.release(device);
                    break :blk try d3d11.frameOf(swap_chain, device);
                },
                .d3d12 => blk: {
                    const device: *d3d12.Device = @ptrCast(swap_chain.getDevice(&d3d12.IID_ID3D12Device).?);
                    defer com.release(device);
                    const queue = try source.present.?.queueFor(device);
                    defer com.release(queue);
                    break :blk try d3d12.frameOf(swap_chain, queue);
                },
                else => error.UnknownApi,
            };
        }

        pub fn release(f: *const gfx.Frame) void {
            switch (f.api) {
                .d3d10 => d3d10.releaseFrame(f),
                .d3d11 => d3d11.releaseFrame(f),
                .d3d12 => d3d12.releaseFrame(f),
                else => unreachable,
            }
        }
    };
};

const tests = struct {
    const testing = std.testing;

    test "finds swap chain methods" {
        const methods = try findSwapChainMethods();
        const base = sys.module.findBase("dxgi.dll").?;
        for ([_]usize{ methods.present, methods.resize_buffers, methods.present1.?, methods.resize_buffers1.? }) |address| {
            try testing.expectEqual(base, sys.module.containingBase(address).?);
        }

        const twelve = try d3d12.OwnedSwapChain.create();
        defer twelve.destroy();
        try testing.expectEqual(methods.present, com.vtableEntry(twelve.swap_chain, SwapChain.present_index));
        try testing.expectEqual(methods.resize_buffers, com.vtableEntry(twelve.swap_chain, SwapChain.resize_buffers_index));
        try testing.expectEqual(methods.present1.?, com.vtableEntry(twelve.swap_chain, present1_index));
        try testing.expectEqual(methods.resize_buffers1.?, com.vtableEntry(twelve.swap_chain, resize_buffers1_index));
    }

    test "early finds game swap chains" {
        const saved = testing.log_level;
        testing.log_level = .err;
        defer testing.log_level = saved;
        try hook.init(testing.allocator);
        defer hook.deinit();
        _ = try sys.module.systemBase("dxgi.dll");

        var recorder: Recorder = .{};
        const present = try PresentHook.createEarly(testing.allocator, .of(Recorder, &recorder));
        defer present.destroy();
        try present.enable();
        try testing.expectEqual(0, present.present_hooks.len);

        // D3D11CreateDeviceAndSwapChain, which goes through D3D11's own factory
        const eleven = try d3d11.OwnedSwapChain.create();
        defer eleven.destroy();
        try testing.expect(present.present_hooks.len != 0);
        _ = eleven.swap_chain.present(0, 0);
        try testing.expectEqual(1, recorder.attaches);
        try testing.expectEqual(gfx.Api.d3d11, recorder.last.?.api);

        // CreateSwapChainForHwnd, so there's Present1 and ResizeBuffers1 to hook
        const twelve = try d3d12.OwnedSwapChain.create();
        defer twelve.destroy();
        try testing.expect(present.present1_hooks.len != 0);
        try testing.expect(present.resize1_hooks.len != 0);

        // Seen made, so 10 bits is still SDR till the game sets HDR10, even on an HDR display
        twelve.waitIdle();
        try testing.expect(com.succeeded(twelve.swap_chain.resizeBuffers(0, 0, 0, FORMAT_R10G10B10A2_UNORM, 0)));
        _ = twelve.present();
        _ = twelve.present();
        try testing.expectEqual(gfx.ColorSpace.srgb, recorder.last.?.color_space);
    }

    test "hooks a known swap chain" {
        const saved = testing.log_level;
        testing.log_level = .err;
        defer testing.log_level = saved;
        try hook.init(testing.allocator);
        defer hook.deinit();

        const eleven = try d3d11.OwnedSwapChain.create();
        defer eleven.destroy();
        var recorder: Recorder = .{};
        const present = try PresentHook.createFrom(testing.allocator, .of(Recorder, &recorder), eleven.swap_chain);
        defer present.destroy();
        try present.enable();
        _ = eleven.swap_chain.present(0, 0);
        try testing.expectEqual(1, recorder.attaches);
        try testing.expectEqual(@as(*anyopaque, eleven.swap_chain), recorder.last.?.swap_chain);
    }

    test "color space follows format" {
        const saved = testing.log_level;
        testing.log_level = .err;
        defer testing.log_level = saved;
        try hook.init(testing.allocator);
        defer hook.deinit();

        const owned = try d3d12.OwnedSwapChain.create();
        defer owned.destroy();
        var recorder: Recorder = .{};
        const present = try PresentHook.create(testing.allocator, .of(Recorder, &recorder));
        defer present.destroy();
        try present.enable();
        _ = owned.present();
        _ = owned.present();
        try testing.expectEqual(gfx.ColorSpace.srgb, recorder.last.?.color_space);

        // scRGB is shown linear
        owned.waitIdle();
        try testing.expect(com.succeeded(owned.swap_chain.resizeBuffers(0, 0, 0, FORMAT_R16G16B16A16_FLOAT, 0)));
        _ = owned.present();
        try testing.expectEqual(gfx.ColorSpace.scrgb, recorder.last.?.color_space);

        // 10 bits we didn't see made is SDR, unless the game's plugin says it's HDR10
        owned.waitIdle();
        try testing.expect(com.succeeded(owned.swap_chain.resizeBuffers(0, 0, 0, FORMAT_R10G10B10A2_UNORM, 0)));
        _ = owned.present();
        try testing.expectEqual(gfx.ColorSpace.srgb, recorder.last.?.color_space);
        gfx.color_space_hint.set(.hdr10);
        defer gfx.color_space_hint.set(null);
        _ = owned.present();
        try testing.expectEqual(gfx.ColorSpace.hdr10, recorder.last.?.color_space);
        gfx.color_space_hint.set(null);
        _ = owned.present();
        try testing.expectEqual(gfx.ColorSpace.srgb, recorder.last.?.color_space);

        // HDR10 the game sets, if the display supports it
        const set = method(owned.swap_chain, set_color_space1_index, SetColorSpace1Fn);
        if (com.succeeded(set(owned.swap_chain, COLOR_SPACE_RGB_FULL_G2084_NONE_P2020))) {
            _ = owned.present();
            try testing.expectEqual(gfx.ColorSpace.hdr10, recorder.last.?.color_space);
        }
        try testing.expect(com.succeeded(set(owned.swap_chain, COLOR_SPACE_RGB_FULL_G22_NONE_P709)));
        _ = owned.present();
        try testing.expectEqual(gfx.ColorSpace.srgb, recorder.last.?.color_space);
    }

    test "apiOf tells APIs apart" {
        const eleven = try d3d11.OwnedSwapChain.create();
        defer eleven.destroy();
        try testing.expectEqual(gfx.Api.d3d11, apiOf(eleven.swap_chain));
        const ten = try d3d10.OwnedSwapChain.create();
        defer ten.destroy();
        try testing.expectEqual(gfx.Api.d3d10, apiOf(ten.swap_chain));
        const twelve = try d3d12.OwnedSwapChain.create();
        defer twelve.destroy();
        try testing.expectEqual(gfx.Api.d3d12, apiOf(twelve.swap_chain));
    }

    test "attaches D3D12 swap chains" {
        const saved = testing.log_level;
        testing.log_level = .err;
        defer testing.log_level = saved;
        try hook.init(testing.allocator);
        defer hook.deinit();

        const owned = try d3d12.OwnedSwapChain.create();
        defer owned.destroy();
        var recorder: Recorder = .{};
        const present = try PresentHook.create(testing.allocator, .of(Recorder, &recorder));
        defer present.destroy();
        try present.enable();

        // First present adds the queue hook, then submissions give the queue away
        _ = owned.present();
        try testing.expectEqual(0, recorder.attaches);
        _ = owned.present();
        // DXGI_PRESENT_PARAMETERS with nothing dirty and nothing scrolled
        const params: extern struct { dirty_count: u32 = 0, dirty: ?*anyopaque = null, scroll: ?*anyopaque = null, offset: ?*anyopaque = null } = .{};
        owned.submit();
        _ = method(owned.swap_chain, present1_index, Present1Fn)(owned.swap_chain, 0, 0, &params);
        try testing.expectEqual(1, recorder.attaches);
        try testing.expectEqual(2, recorder.frames);
        const frame = recorder.last.?;
        try testing.expectEqual(gfx.Api.d3d12, frame.api);
        try testing.expectEqual(@as(*anyopaque, owned.device), frame.device);
        try testing.expectEqual(@as(?*anyopaque, owned.queue), frame.queue);

        // Like a game, nothing in flight on the old buffers
        owned.waitIdle();
        const count = d3d12.OwnedSwapChain.buffer_count;
        const node_masks: [count]u32 = @splat(1);
        const queues: [count]?*anyopaque = @splat(owned.queue);
        try testing.expect(com.succeeded(method(owned.swap_chain, resize_buffers1_index, ResizeBuffers1Fn)(owned.swap_chain, count, 128, 96, 0, 0, &node_masks, &queues)));
        try testing.expectEqual(1, recorder.resizes);
        owned.waitIdle();
        try testing.expect(com.succeeded(owned.swap_chain.resizeBuffers(0, 64, 64, 0, 0)));
        try testing.expectEqual(2, recorder.resizes);
    }

    test "attaches D3D10 swap chains" {
        const saved = testing.log_level;
        testing.log_level = .err;
        defer testing.log_level = saved;
        try hook.init(testing.allocator);
        defer hook.deinit();

        const first = try d3d10.OwnedSwapChain.create();
        defer first.destroy();
        var recorder: Recorder = .{};
        const present = try PresentHook.create(testing.allocator, .of(Recorder, &recorder));
        defer present.destroy();
        try present.enable();

        _ = first.swap_chain.present(0, 0);
        _ = first.swap_chain.present(0, 0);
        try testing.expectEqual(1, recorder.attaches);
        try testing.expectEqual(2, recorder.frames);
        const frame = recorder.last.?;
        try testing.expectEqual(gfx.Api.d3d10, frame.api);
        try testing.expectEqual(@as(*anyopaque, first.device), frame.device);
        try testing.expect(d3d10.fromFrame(&frame) != null);

        try testing.expect(com.succeeded(first.swap_chain.resizeBuffers(0, 128, 96, 0, 0)));
        try testing.expectEqual(1, recorder.resizes);

        const replacement = try d3d11.OwnedSwapChain.createOn(first.hwnd);
        defer replacement.destroy();
        _ = replacement.swap_chain.present(0, 0);
        try testing.expectEqual(1, recorder.detaches);
        try testing.expectEqual(gfx.Api.d3d11, recorder.last.?.api);
    }

    const Recorder = struct {
        attaches: u32 = 0,
        frames: u32 = 0,
        resizes: u32 = 0,
        detaches: u32 = 0,
        last: ?gfx.Frame = null,

        pub fn onAttach(self: *Recorder, f: *const gfx.Frame) void {
            self.attaches += 1;
            self.last = f.*;
        }
        pub fn onFrame(self: *Recorder, f: *const gfx.Frame) void {
            self.frames += 1;
            self.last = f.*;
        }
        pub fn onResize(self: *Recorder, _: *const gfx.Frame) void {
            self.resizes += 1;
        }
        pub fn onDetach(self: *Recorder, _: *const gfx.Frame) void {
            self.detaches += 1;
        }
    };

    test "reports frames and resizes" {
        try hook.init(testing.allocator);
        defer hook.deinit();

        const owned = try d3d11.OwnedSwapChain.create();
        defer owned.destroy();

        var recorder: Recorder = .{};
        const present = try PresentHook.create(testing.allocator, .of(Recorder, &recorder));
        try present.enable();

        _ = owned.swap_chain.present(0, 0);
        _ = owned.swap_chain.present(0, 0);
        try testing.expectEqual(1, recorder.attaches);
        try testing.expectEqual(2, recorder.frames);
        const frame = recorder.last.?;
        try testing.expectEqual(gfx.Api.d3d11, frame.api);
        try testing.expectEqual(@as(*anyopaque, owned.hwnd), frame.window);
        try testing.expectEqual(@as(*anyopaque, owned.swap_chain), frame.swap_chain);
        try testing.expectEqual(@as(*anyopaque, owned.device), frame.device);
        try testing.expect(d3d11.fromFrame(&frame) != null);

        try testing.expect(com.succeeded(owned.swap_chain.resizeBuffers(0, 128, 96, 0, 0)));
        try testing.expectEqual(1, recorder.resizes);

        present.destroy();
        _ = owned.swap_chain.present(0, 0); // unhooked, nothing reaches us
        try testing.expectEqual(2, recorder.frames);
    }

    test "ignores our own windows" {
        const saved = testing.log_level;
        testing.log_level = .err;
        defer testing.log_level = saved;
        try hook.init(testing.allocator);
        defer hook.deinit();

        const ours = try d3d11.OwnedSwapChain.create();
        defer ours.destroy();
        gfx.own_windows.add(ours.hwnd);
        defer gfx.own_windows.remove(ours.hwnd);
        const game = try d3d11.OwnedSwapChain.create();
        defer game.destroy();
        var recorder: Recorder = .{};
        const present = try PresentHook.create(testing.allocator, .of(Recorder, &recorder));
        defer present.destroy();
        try present.enable();

        _ = ours.swap_chain.present(0, 0);
        try testing.expectEqual(0, recorder.attaches);
        _ = game.swap_chain.present(0, 0);
        try testing.expectEqual(1, recorder.attaches);
        try testing.expectEqual(@as(*anyopaque, game.swap_chain), recorder.last.?.swap_chain);
    }

    test "replacement detaches old" {
        const saved = testing.log_level;
        testing.log_level = .err;
        defer testing.log_level = saved;
        try hook.init(testing.allocator);
        defer hook.deinit();

        const first = try d3d11.OwnedSwapChain.create();
        defer first.destroy();
        var recorder: Recorder = .{};
        const present = try PresentHook.create(testing.allocator, .of(Recorder, &recorder));
        defer present.destroy();
        try present.enable();

        _ = first.swap_chain.present(0, 0);
        try testing.expectEqual(1, recorder.attaches);

        const replacement = try d3d11.OwnedSwapChain.createOn(first.hwnd);
        defer replacement.destroy();
        _ = replacement.swap_chain.present(0, 0);
        try testing.expectEqual(1, recorder.detaches);
        try testing.expectEqual(2, recorder.attaches);
        try testing.expectEqual(@as(*anyopaque, replacement.swap_chain), recorder.last.?.swap_chain);

        const elsewhere = try d3d11.OwnedSwapChain.create();
        defer elsewhere.destroy();
        const frames = recorder.frames;
        _ = elsewhere.swap_chain.present(0, 0);
        try testing.expectEqual(frames, recorder.frames);
        try testing.expectEqual(2, recorder.attaches);
    }
};

test {
    _ = tests;
}
