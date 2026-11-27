//! D3D9 bindings and present path.

const std = @import("std");

const hook = @import("tuft_hook");
const tuft_window = @import("tuft_window");

const gfx = @import("root.zig");
const com = @import("com.zig");
const Tracker = @import("tracker.zig").Tracker;
const hook_set = hook.set;
const HookSet = hook_set.HookSet;
const sys = @import("tuft_sys");

const log = std.log.scoped(.tuft_gfx);

const IID_IDirect3DDevice9Ex: com.Guid = .{ .data1 = 0xb18b10ce, .data2 = 0x2649, .data3 = 0x405a, .data4 = .{ 0x87, 0x0f, 0x95, 0xf7, 0x77, 0xd4, 0x31, 0x3a } };

const HRESULT = com.HRESULT;
const method = com.method;
const Hwnd = tuft_window.Handle;

pub const FMT_UNKNOWN: u32 = 0;
pub const SWAPEFFECT_DISCARD: u32 = 1;
pub const PRESENT_INTERVAL_IMMEDIATE: u32 = 0x80000000;
pub const BACKBUFFER_TYPE_MONO: u32 = 0;

const D3D_SDK_VERSION: u32 = 32;
const D3DADAPTER_DEFAULT: u32 = 0;
const D3DDEVTYPE_HAL: u32 = 1;
const D3DDEVTYPE_NULLREF: u32 = 4;
const D3DCREATE_FPU_PRESERVE: u32 = 0x2;
const D3DCREATE_SOFTWARE_VERTEXPROCESSING: u32 = 0x20;

pub const PresentParameters = extern struct {
    back_buffer_width: u32 = 0,
    back_buffer_height: u32 = 0,
    back_buffer_format: u32 = FMT_UNKNOWN,
    back_buffer_count: u32 = 0,
    multi_sample_type: u32 = 0,
    multi_sample_quality: u32 = 0,
    swap_effect: u32 = 0,
    device_window: ?Hwnd = null,
    windowed: i32 = 0,
    enable_auto_depth_stencil: i32 = 0,
    auto_depth_stencil_format: u32 = 0,
    flags: u32 = 0,
    fullscreen_refresh_rate: u32 = 0,
    presentation_interval: u32 = 0,
};

pub const CreationParameters = extern struct {
    adapter: u32 = 0,
    device_type: u32 = 0,
    focus_window: ?Hwnd = null,
    behavior_flags: u32 = 0,
};

pub const Rect = extern struct { left: i32, top: i32, right: i32, bottom: i32 };

pub const Direct3D = opaque {
    pub fn createDevice(self: *Direct3D, device_type: u32, focus: Hwnd, behavior: u32, params: *PresentParameters, out: *?*Device) HRESULT {
        return method(self, 16, fn (*Direct3D, u32, u32, Hwnd, u32, *PresentParameters, *?*Device) callconv(.winapi) HRESULT)(self, D3DADAPTER_DEFAULT, device_type, focus, behavior, params, out);
    }

    /// Ex only.
    pub fn createDeviceEx(self: *Direct3D, device_type: u32, focus: Hwnd, behavior: u32, params: *PresentParameters, out: *?*Device) HRESULT {
        return method(self, 20, fn (*Direct3D, u32, u32, Hwnd, u32, *PresentParameters, ?*anyopaque, *?*Device) callconv(.winapi) HRESULT)(self, D3DADAPTER_DEFAULT, device_type, focus, behavior, params, null, out);
    }
};

pub const Device = opaque {
    pub const reset_index = 16;
    pub const present_index = 17;
    pub const present_ex_index = 121;
    pub const reset_ex_index = 132;

    pub const ResetFn = fn (*Device, *PresentParameters) callconv(.winapi) HRESULT;
    pub const PresentFn = fn (*Device, ?*const Rect, ?*const Rect, ?Hwnd, ?*const anyopaque) callconv(.winapi) HRESULT;
    pub const PresentExFn = fn (*Device, ?*const Rect, ?*const Rect, ?Hwnd, ?*const anyopaque, u32) callconv(.winapi) HRESULT;
    pub const ResetExFn = fn (*Device, *PresentParameters, ?*anyopaque) callconv(.winapi) HRESULT;

    pub fn testCooperativeLevel(self: *Device) HRESULT {
        return method(self, 3, fn (*Device) callconv(.winapi) HRESULT)(self);
    }

    pub fn getCreationParameters(self: *Device, out: *CreationParameters) HRESULT {
        return method(self, 9, fn (*Device, *CreationParameters) callconv(.winapi) HRESULT)(self, out);
    }

    /// 0 is the implicit one. Comes back with a ref.
    pub fn getSwapChain(self: *Device, index: u32) ?*SwapChain {
        var out: ?*SwapChain = null;
        const hr = method(self, 14, fn (*Device, u32, *?*SwapChain) callconv(.winapi) HRESULT)(self, index, &out);
        return if (com.succeeded(hr)) out else null;
    }

    pub fn reset(self: *Device, params: *PresentParameters) HRESULT {
        return method(self, reset_index, ResetFn)(self, params);
    }

    pub fn present(self: *Device) HRESULT {
        return method(self, present_index, PresentFn)(self, null, null, null, null);
    }

    /// Ex only.
    pub fn presentEx(self: *Device, flags: u32) HRESULT {
        return method(self, present_ex_index, PresentExFn)(self, null, null, null, null, flags);
    }

    /// From the implicit swap chain. Comes back with a ref.
    pub fn getBackBuffer(self: *Device, index: u32) ?*Surface {
        var out: ?*Surface = null;
        const hr = method(self, 18, fn (*Device, u32, u32, u32, *?*Surface) callconv(.winapi) HRESULT)(self, 0, index, BACKBUFFER_TYPE_MONO, &out);
        return if (com.succeeded(hr)) out else null;
    }

    /// Comes back with a ref.
    pub fn createRenderTarget(self: *Device, width: u32, height: u32, format: u32) ?*Surface {
        var out: ?*Surface = null;
        const hr = method(self, 28, fn (*Device, u32, u32, u32, u32, u32, i32, *?*Surface, ?*anyopaque) callconv(.winapi) HRESULT)(self, width, height, format, 0, 0, 0, &out, null);
        return if (com.succeeded(hr)) out else null;
    }

    /// In system memory, for `getRenderTargetData`. Comes back with a ref.
    pub fn createOffscreenPlainSurface(self: *Device, width: u32, height: u32, format: u32) ?*Surface {
        var out: ?*Surface = null;
        const hr = method(self, 36, fn (*Device, u32, u32, u32, u32, *?*Surface, ?*anyopaque) callconv(.winapi) HRESULT)(self, width, height, format, POOL_SYSTEMMEM, &out, null);
        return if (com.succeeded(hr)) out else null;
    }

    /// Waits for the GPU to finish drawing `src`.
    pub fn getRenderTargetData(self: *Device, src: *Surface, dest: *Surface) HRESULT {
        return method(self, 32, fn (*Device, *Surface, *Surface) callconv(.winapi) HRESULT)(self, src, dest);
    }

    /// Whole surfaces. Also resolves multisampling.
    pub fn stretchRect(self: *Device, src: *Surface, dest: *Surface) HRESULT {
        return method(self, 34, fn (*Device, *Surface, ?*const Rect, *Surface, ?*const Rect, u32) callconv(.winapi) HRESULT)(self, src, null, dest, null, TEXF_NONE);
    }

    pub fn setRenderTarget(self: *Device, index: u32, surface: ?*Surface) HRESULT {
        return method(self, 37, fn (*Device, u32, ?*Surface) callconv(.winapi) HRESULT)(self, index, surface);
    }

    /// Comes back with a ref. Null if nothing's bound there.
    pub fn getRenderTarget(self: *Device, index: u32) ?*Surface {
        var out: ?*Surface = null;
        const hr = method(self, 38, fn (*Device, u32, *?*Surface) callconv(.winapi) HRESULT)(self, index, &out);
        return if (com.succeeded(hr)) out else null;
    }

    pub fn beginScene(self: *Device) HRESULT {
        return method(self, 41, fn (*Device) callconv(.winapi) HRESULT)(self);
    }

    pub fn endScene(self: *Device) HRESULT {
        return method(self, 42, fn (*Device) callconv(.winapi) HRESULT)(self);
    }

    /// The implicit swap chain's window, else the focus window.
    pub fn window(self: *Device) ?Hwnd {
        if (self.getSwapChain(0)) |swap_chain| {
            defer com.release(swap_chain);
            var params: PresentParameters = .{};
            if (com.succeeded(swap_chain.getPresentParameters(&params))) {
                if (params.device_window) |w| return w;
            }
        }
        var creation: CreationParameters = .{};
        if (!com.succeeded(self.getCreationParameters(&creation))) return null;
        return creation.focus_window;
    }
};

pub const SwapChain = opaque {
    pub fn getPresentParameters(self: *SwapChain, out: *PresentParameters) HRESULT {
        return method(self, 9, fn (*SwapChain, *PresentParameters) callconv(.winapi) HRESULT)(self, out);
    }
};

pub const POOL_SYSTEMMEM: u32 = 2;
const TEXF_NONE: u32 = 0;
pub const LOCK_READONLY: u32 = 0x10;

pub const SurfaceDesc = extern struct {
    format: u32 = 0,
    type: u32 = 0,
    usage: u32 = 0,
    pool: u32 = 0,
    multi_sample_type: u32 = 0,
    multi_sample_quality: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
};

pub const LockedRect = extern struct {
    pitch: i32 = 0,
    bits: ?[*]const u8 = null,
};

pub const Surface = opaque {
    pub fn getDesc(self: *Surface) ?SurfaceDesc {
        var out: SurfaceDesc = .{};
        const hr = method(self, 12, fn (*Surface, *SurfaceDesc) callconv(.winapi) HRESULT)(self, &out);
        return if (com.succeeded(hr)) out else null;
    }

    pub fn lockRect(self: *Surface, flags: u32) ?LockedRect {
        var out: LockedRect = .{};
        const hr = method(self, 13, fn (*Surface, *LockedRect, ?*const Rect, u32) callconv(.winapi) HRESULT)(self, &out, null, flags);
        return if (com.succeeded(hr)) out else null;
    }

    pub fn unlockRect(self: *Surface) void {
        _ = method(self, 14, fn (*Surface) callconv(.winapi) HRESULT)(self);
    }
};

pub const Native = struct {
    device: *Device,
    /// The implicit swap chain.
    swap_chain: *SwapChain,
};

pub fn fromFrame(frame: *const gfx.Frame) ?Native {
    if (frame.api != .d3d9) return null;
    return .{ .device = @ptrCast(frame.device), .swap_chain = @ptrCast(frame.swap_chain) };
}

/// Holds refs on the device and its implicit swap chain until `releaseFrame`.
pub fn frameOf(device: *Device) !gfx.Frame {
    const hwnd = device.window() orelse return error.NoOutputWindow;
    const swap_chain = device.getSwapChain(0) orelse return error.NoSwapChain;
    com.addRef(device);
    return .{ .api = .d3d9, .window = hwnd, .swap_chain = swap_chain, .device = device };
}

pub fn releaseFrame(frame: *const gfx.Frame) void {
    const native = fromFrame(frame).?;
    com.release(native.swap_chain);
    com.release(native.device);
}

// Looked up at runtime so games don't all load d3d9.dll
const Direct3DCreate9Fn = fn (sdk_version: u32) callconv(.winapi) ?*Direct3D;
const Direct3DCreate9ExFn = fn (sdk_version: u32, out: *?*Direct3D) callconv(.winapi) HRESULT;

pub const OwnedDevice = struct {
    hwnd: Hwnd,
    owns_window: bool,
    d3d: *Direct3D,
    device: *Device,
    ex: bool,

    pub const Options = struct {
        ex: bool = false,
        /// Null means the loaded `d3d9.dll`, or Windows' if none.
        module: ?usize = null,
    };

    pub fn create(options: Options) !OwnedDevice {
        const hwnd = try tuft_window.createHidden();
        errdefer tuft_window.destroy(hwnd);
        var owned = try createOn(hwnd, options);
        owned.owns_window = true;
        return owned;
    }

    pub fn createOn(hwnd: Hwnd, options: Options) !OwnedDevice {
        var d3d: ?*Direct3D = null;
        if (options.ex) {
            const create9ex: *const Direct3DCreate9ExFn = if (options.module) |m| @ptrFromInt(sys.module.findExport(m, "Direct3DCreate9Ex") orelse return error.CreateDirect3DFailed) else sys.module.lazyFn("d3d9.dll", "Direct3DCreate9Ex", Direct3DCreate9ExFn) orelse return error.CreateDirect3DFailed;
            if (!com.succeeded(create9ex(D3D_SDK_VERSION, &d3d))) return error.CreateDirect3DFailed;
        } else {
            const create9: *const Direct3DCreate9Fn = if (options.module) |m| @ptrFromInt(sys.module.findExport(m, "Direct3DCreate9") orelse return error.CreateDirect3DFailed) else sys.module.lazyFn("d3d9.dll", "Direct3DCreate9", Direct3DCreate9Fn) orelse return error.CreateDirect3DFailed;
            d3d = create9(D3D_SDK_VERSION) orelse return error.CreateDirect3DFailed;
        }
        errdefer com.release(d3d.?);

        for ([_]u32{ D3DDEVTYPE_HAL, D3DDEVTYPE_NULLREF }) |device_type| {
            var params = presentParameters(hwnd, 64, 64);
            var device: ?*Device = null;
            const behavior = D3DCREATE_SOFTWARE_VERTEXPROCESSING | D3DCREATE_FPU_PRESERVE;
            const hr = if (options.ex)
                d3d.?.createDeviceEx(device_type, hwnd, behavior, &params, &device)
            else
                d3d.?.createDevice(device_type, hwnd, behavior, &params, &device);
            if (com.succeeded(hr)) return .{ .hwnd = hwnd, .owns_window = false, .d3d = d3d.?, .device = device.?, .ex = options.ex };
        }
        return error.CreateDeviceFailed;
    }

    pub fn destroy(self: OwnedDevice) void {
        com.release(self.device);
        com.release(self.d3d);
        if (self.owns_window) tuft_window.destroy(self.hwnd);
    }

    pub fn present(self: OwnedDevice) HRESULT {
        return self.device.present();
    }

    pub fn reset(self: OwnedDevice, width: u32, height: u32) HRESULT {
        var params = presentParameters(self.hwnd, width, height);
        return self.device.reset(&params);
    }

    fn presentParameters(hwnd: Hwnd, width: u32, height: u32) PresentParameters {
        return .{
            .back_buffer_width = width,
            .back_buffer_height = height,
            .back_buffer_count = 1,
            .swap_effect = SWAPEFFECT_DISCARD,
            .device_window = hwnd,
            .windowed = 1,
            .presentation_interval = PRESENT_INTERVAL_IMMEDIATE,
        };
    }
};

/// Read off throwaway devices from Windows' d3d9.dll. A method can live at several addresses.
/// Compat shims give some devices their own `Reset`, so `PresentHook` hooks those on attach.
pub const DeviceMethods = struct {
    present: Addresses = .{},
    reset: Addresses = .{},
    present_ex: Addresses = .{},
    reset_ex: Addresses = .{},

    pub const Addresses = hook_set.Addresses;
};

pub fn findDeviceMethods() !DeviceMethods {
    const d3d9 = try sys.module.systemBase("d3d9.dll");
    var methods: DeviceMethods = .{};
    for ([_]bool{ false, true }) |ex| {
        const probe = OwnedDevice.create(.{ .ex = ex, .module = d3d9 }) catch continue;
        defer probe.destroy();
        methods.present.add(com.vtableEntry(probe.device, Device.present_index));
        methods.reset.add(com.vtableEntry(probe.device, Device.reset_index));
        if (ex) {
            methods.present_ex.add(com.vtableEntry(probe.device, Device.present_ex_index));
            methods.reset_ex.add(com.vtableEntry(probe.device, Device.reset_ex_index));
        }
    }
    if (methods.present.len == 0) return error.CreateDeviceFailed;
    return methods;
}

/// Nesting depth on this thread, so calls through other hooks report once.
threadlocal var present_depth: u32 = 0;
threadlocal var reset_depth: u32 = 0;
/// Set while `PresentHook.probePresent` makes its throwaway, so creation hooks don't take it for the game's.
threadlocal var probing = false;

/// The D3D9 path. Init `tuft_hook` first.
pub const PresentHook = struct {
    allocator: std.mem.Allocator,
    present_hooks: HookSet(Device.PresentFn) = .{},
    present_ex_hooks: HookSet(Device.PresentExFn) = .{},
    reset_hooks: HookSet(Device.ResetFn) = .{},
    reset_ex_hooks: HookSet(Device.ResetExFn) = .{},
    tracker: Tracker(Source),
    /// Last device whose own resets we checked.
    checked_device: ?*Device = null,
    /// For `createEarly`.
    create9_hooks: HookSet(Create9Fn) = .{},
    create9ex_hooks: HookSet(Create9ExFn) = .{},
    create_device_hooks: HookSet(CreateDeviceFn) = .{},
    create_device_ex_hooks: HookSet(CreateDeviceExFn) = .{},
    /// Held while adding hooks from game threads and while enabling them.
    lock: sys.sync.RwLock = .{},
    enabled: bool = false,

    const Create9Fn = fn (sdk_version: u32) callconv(.winapi) ?*Direct3D;
    const Create9ExFn = fn (sdk_version: u32, out: *?*Direct3D) callconv(.winapi) HRESULT;
    const CreateDeviceFn = fn (*Direct3D, u32, u32, ?Hwnd, u32, *PresentParameters, *?*Device) callconv(.winapi) HRESULT;
    const CreateDeviceExFn = fn (*Direct3D, u32, u32, ?Hwnd, u32, *PresentParameters, ?*anyopaque, *?*Device) callconv(.winapi) HRESULT;
    const create_device_index = 16;
    const create_device_ex_index = 20;

    /// Hooks start disabled.
    pub fn create(allocator: std.mem.Allocator, listener: gfx.Listener) !*PresentHook {
        const methods = try findDeviceMethods();

        const self = try allocator.create(PresentHook);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .tracker = .{ .listener = listener } };
        errdefer self.destroyHooks();

        try self.present_hooks.create(&methods.present, onPresent, self);
        try self.present_ex_hooks.create(&methods.present_ex, onPresentEx, self);
        try self.reset_hooks.create(&methods.reset, onReset, self);
        try self.reset_ex_hooks.create(&methods.reset_ex, onResetEx, self);
        return self;
    }

    /// Makes no devices of its own, since overlays could mistake them for the game's.
    pub fn createEarly(allocator: std.mem.Allocator, listener: gfx.Listener) !*PresentHook {
        const d3d9 = sys.module.findBase("d3d9.dll") orelse return error.NotInUse;
        const self = try allocator.create(PresentHook);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .tracker = .{ .listener = listener } };
        errdefer self.destroyHooks();

        const create9 = sys.module.findExport(d3d9, "Direct3DCreate9") orelse return error.NoDirect3DCreate9;
        _ = try self.create9_hooks.add(create9, onCreate9, self);
        // Not every wrapper has it
        const create9ex = sys.module.findExport(d3d9, "Direct3DCreate9Ex");
        if (create9ex) |a| _ = try self.create9ex_hooks.add(a, onCreate9Ex, self);
        log.info("d3d9: waiting for the game to call Direct3DCreate9{s} (hooked at 0x{x})", .{ if (create9ex != null) " or Direct3DCreate9Ex" else "", create9 });
        return self;
    }

    /// `createEarly`, plus hooks the known game device `object` right away.
    pub fn createFrom(allocator: std.mem.Allocator, listener: gfx.Listener, object: *anyopaque) !*PresentHook {
        const self = try createEarly(allocator, listener);
        log.info("d3d9: hooking the game's device 0x{x}, handed over", .{@intFromPtr(object)});
        self.watchDevice(@ptrCast(object));
        return self;
    }

    /// Whether Present is hooked, from the game's device or `probePresent`.
    pub fn watching(self: *PresentHook) bool {
        self.lock.lockShared();
        defer self.lock.unlockShared();
        return self.present_hooks.len + self.present_ex_hooks.len != 0;
    }

    /// Hooks Present where a throwaway device has it, for a game device made before `createEarly`.
    pub fn probePresent(self: *PresentHook) !void {
        probing = true;
        const methods = findDeviceMethods();
        probing = false;
        const m = try methods;
        self.lock.lock();
        defer self.lock.unlock();
        for (m.reset.slice()) |a| self.addLocked(Device.ResetFn, &self.reset_hooks, a, onReset, "Reset");
        for (m.reset_ex.slice()) |a| self.addLocked(Device.ResetExFn, &self.reset_ex_hooks, a, onResetEx, "ResetEx");
        for (m.present.slice()) |a| self.addLocked(Device.PresentFn, &self.present_hooks, a, onPresent, "Present");
        for (m.present_ex.slice()) |a| self.addLocked(Device.PresentExFn, &self.present_ex_hooks, a, onPresentEx, "PresentEx");
    }

    pub fn enable(self: *PresentHook) !void {
        self.lock.lock();
        defer self.lock.unlock();
        self.enabled = true;
        try self.create9_hooks.enable();
        try self.create9ex_hooks.enable();
        try self.create_device_hooks.enable();
        try self.create_device_ex_hooks.enable();
        try self.reset_hooks.enable();
        try self.reset_ex_hooks.enable();
        try self.present_hooks.enable();
        try self.present_ex_hooks.enable();
    }

    /// Unhooks, waiting for presents in flight.
    pub fn destroy(self: *PresentHook) void {
        self.destroyHooks();
        self.tracker.deinit();
        self.allocator.destroy(self);
    }

    fn destroyHooks(self: *PresentHook) void {
        // Same order they add each other in, so once one's gone nothing can add to the next
        self.create9_hooks.destroy();
        self.create9ex_hooks.destroy();
        self.create_device_hooks.destroy();
        self.create_device_ex_hooks.destroy();
        self.present_hooks.destroy();
        self.present_ex_hooks.destroy();
        self.reset_hooks.destroy();
        self.reset_ex_hooks.destroy();
    }
    fn onCreate9(self: *PresentHook, h: *hook.TypedHook(Create9Fn), sdk_version: u32) ?*Direct3D {
        if (probing) return h.original()(sdk_version);
        const d3d = h.original()(sdk_version) orelse {
            log.info("d3d9: the game's Direct3DCreate9 failed", .{});
            return null;
        };
        log.info("d3d9: the game called Direct3DCreate9; waiting for it to make a device", .{});
        self.watchDirect3D(d3d, false);
        return d3d;
    }

    fn onCreate9Ex(self: *PresentHook, h: *hook.TypedHook(Create9ExFn), sdk_version: u32, out: *?*Direct3D) HRESULT {
        const hr = h.original()(sdk_version, out);
        if (probing) return hr;
        if (com.succeeded(hr)) if (out.*) |d3d| {
            log.info("d3d9: the game called Direct3DCreate9Ex; waiting for it to make a device", .{});
            self.watchDirect3D(d3d, true);
            return hr;
        };
        log.info("d3d9: the game's Direct3DCreate9Ex failed (0x{x})", .{@as(u32, @bitCast(hr))});
        return hr;
    }

    fn onCreateDevice(self: *PresentHook, h: *hook.TypedHook(CreateDeviceFn), d3d: *Direct3D, adapter: u32, device_type: u32, focus: ?Hwnd, behavior: u32, params: *PresentParameters, out: *?*Device) HRESULT {
        const hr = h.original()(d3d, adapter, device_type, focus, behavior, params, out);
        if (probing) return hr;
        logCreated("CreateDevice", hr, device_type, focus, params);
        if (com.succeeded(hr)) if (out.*) |device| self.watchDevice(device);
        return hr;
    }

    fn onCreateDeviceEx(self: *PresentHook, h: *hook.TypedHook(CreateDeviceExFn), d3d: *Direct3D, adapter: u32, device_type: u32, focus: ?Hwnd, behavior: u32, params: *PresentParameters, mode: ?*anyopaque, out: *?*Device) HRESULT {
        const hr = h.original()(d3d, adapter, device_type, focus, behavior, params, mode, out);
        if (probing) return hr;
        logCreated("CreateDeviceEx", hr, device_type, focus, params);
        if (com.succeeded(hr)) if (out.*) |device| self.watchDevice(device);
        return hr;
    }

    fn logCreated(comptime name: []const u8, hr: HRESULT, device_type: u32, focus: ?Hwnd, params: *const PresentParameters) void {
        const type_name = switch (device_type) {
            1 => "HAL",
            2 => "reference",
            3 => "software",
            4 => "null reference",
            else => "unknown type",
        };
        if (!com.succeeded(hr)) return log.info("d3d9: the game's " ++ name ++ " ({s}) failed (0x{x})", .{ type_name, @as(u32, @bitCast(hr)) });
        const window = params.device_window orelse focus;
        log.info("d3d9: the game made a device ({s} " ++ name ++ ", {d}x{d}, {s}, window 0x{x}); hooking its Present and Reset", .{
            type_name,                                              params.back_buffer_width, params.back_buffer_height,
            if (params.windowed != 0) "windowed" else "fullscreen", @intFromPtr(window),
        });
    }

    fn watchDirect3D(self: *PresentHook, d3d: *Direct3D, ex: bool) void {
        self.lock.lock();
        defer self.lock.unlock();
        self.addLocked(CreateDeviceFn, &self.create_device_hooks, com.vtableEntry(d3d, create_device_index), onCreateDevice, "CreateDevice");
        if (ex) self.addLocked(CreateDeviceExFn, &self.create_device_ex_hooks, com.vtableEntry(d3d, create_device_ex_index), onCreateDeviceEx, "CreateDeviceEx");
    }

    fn watchDevice(self: *PresentHook, device: *Device) void {
        self.lock.lock();
        defer self.lock.unlock();
        self.addLocked(Device.ResetFn, &self.reset_hooks, com.vtableEntry(device, Device.reset_index), onReset, "Reset");
        self.addLocked(Device.PresentFn, &self.present_hooks, com.vtableEntry(device, Device.present_index), onPresent, "Present");
        const ex = com.query(device, &IID_IDirect3DDevice9Ex) orelse return;
        com.release(ex);
        self.addLocked(Device.ResetExFn, &self.reset_ex_hooks, com.vtableEntry(device, Device.reset_ex_index), onResetEx, "ResetEx");
        self.addLocked(Device.PresentExFn, &self.present_ex_hooks, com.vtableEntry(device, Device.present_ex_index), onPresentEx, "PresentEx");
    }

    /// Skips already hooked addresses. Enabled if the path is.
    fn addLocked(self: *PresentHook, comptime F: type, set: *HookSet(F), address: usize, comptime callback: anytype, comptime name: []const u8) void {
        const added = set.add(address, callback, self) catch |err| return log.warn("Couldn't hook the game's " ++ name ++ " at 0x{x}: {t}", .{ address, err });
        const h = added orelse return;
        if (self.enabled) set.enableHook(h) catch |err| return log.warn("Couldn't hook the game's " ++ name ++ " at 0x{x}: {t}", .{ address, err });
        log.debug("Hooked the game's " ++ name ++ " at 0x{x}", .{address});
    }

    fn onPresent(self: *PresentHook, h: *hook.TypedHook(Device.PresentFn), device: *Device, src: ?*const Rect, dst: ?*const Rect, override: ?Hwnd, dirty: ?*const anyopaque) HRESULT {
        self.beginPresent(device);
        defer present_depth -= 1;
        return h.original()(device, src, dst, override, dirty);
    }

    fn onPresentEx(self: *PresentHook, h: *hook.TypedHook(Device.PresentExFn), device: *Device, src: ?*const Rect, dst: ?*const Rect, override: ?Hwnd, dirty: ?*const anyopaque, flags: u32) HRESULT {
        self.beginPresent(device);
        defer present_depth -= 1;
        return h.original()(device, src, dst, override, dirty, flags);
    }

    fn beginPresent(self: *PresentHook, device: *Device) void {
        present_depth += 1;
        if (present_depth != 1) return;
        self.tracker.presented();
        self.tracker.present(device);
        if (self.checked_device != device and self.tracker.current(device) != null) {
            self.checked_device = device;
            self.hookResetsOf(device);
        }
    }

    /// Hooks the device's own shimmed resets. Not presents, since `destroy` waits on those first.
    fn hookResetsOf(self: *PresentHook, device: *Device) void {
        self.lock.lock();
        defer self.lock.unlock();
        const reset = com.vtableEntry(device, Device.reset_index);
        if (self.reset_hooks.add(reset, onReset, self)) |added| {
            if (added) |h| if (self.enabled) enableLate(&self.reset_hooks, h, reset);
        } else |err| log.warn("Couldn't hook the device's Reset at 0x{x}: {t}", .{ reset, err });

        const ex = com.query(device, &IID_IDirect3DDevice9Ex) orelse return;
        com.release(ex);
        const reset_ex = com.vtableEntry(device, Device.reset_ex_index);
        if (self.reset_ex_hooks.add(reset_ex, onResetEx, self)) |added| {
            if (added) |h| if (self.enabled) enableLate(&self.reset_ex_hooks, h, reset_ex);
        } else |err| log.warn("Couldn't hook the device's ResetEx at 0x{x}: {t}", .{ reset_ex, err });
    }

    fn enableLate(set: anytype, h: anytype, address: usize) void {
        set.enableHook(h) catch |err| return log.warn("Couldn't hook the device's reset at 0x{x}: {t}", .{ address, err });
        log.debug("Hooked the device's own reset at 0x{x} (a compatibility shim's?)", .{address});
    }

    fn onReset(self: *PresentHook, h: *hook.TypedHook(Device.ResetFn), device: *Device, params: *PresentParameters) HRESULT {
        self.beginReset(device);
        defer self.endReset(device);
        return h.original()(device, params);
    }

    fn onResetEx(self: *PresentHook, h: *hook.TypedHook(Device.ResetExFn), device: *Device, params: *PresentParameters, mode: ?*anyopaque) HRESULT {
        self.beginReset(device);
        defer self.endReset(device);
        return h.original()(device, params, mode);
    }

    fn beginReset(self: *PresentHook, device: *Device) void {
        reset_depth += 1;
        if (reset_depth == 1) self.tracker.resize(device);
    }

    /// A reset might have replaced the implicit swap chain or moved it to another window.
    fn endReset(self: *PresentHook, device: *Device) void {
        reset_depth -= 1;
        if (reset_depth != 0) return;
        const f = self.tracker.current(device) orelse return;
        if (device.window()) |w| f.window = w;
        const swap_chain = device.getSwapChain(0) orelse return;
        com.release(@as(*SwapChain, @ptrCast(f.swap_chain)));
        f.swap_chain = swap_chain;
    }

    const Source = struct {
        pub const Key = *Device;
        pub const noun = "device";

        pub fn keyOf(f: *const gfx.Frame) Key {
            return @ptrCast(f.device);
        }

        pub fn windowOf(_: Source, device: Key) ?*anyopaque {
            return device.window();
        }

        pub fn attach(_: Source, device: Key) !gfx.Frame {
            return frameOf(device);
        }
        pub const release = releaseFrame;
    };
};

const tests = struct {
    const testing = std.testing;

    test "finds every Present" {
        const methods = try findDeviceMethods();
        for ([_]*const DeviceMethods.Addresses{ &methods.present, &methods.reset, &methods.present_ex, &methods.reset_ex }) |set| {
            try testing.expect(set.len > 0);
            for (set.slice()) |address| try testing.expect(sys.module.containingBase(address) != null);
        }

        // Resets aren't checked, a shim may give a device its own
        for ([_]bool{ false, true }) |ex| {
            const owned = try OwnedDevice.create(.{ .ex = ex });
            defer owned.destroy();
            const has = std.mem.indexOfScalar;
            try testing.expect(has(usize, methods.present.slice(), com.vtableEntry(owned.device, Device.present_index)) != null);
            if (ex) try testing.expect(has(usize, methods.present_ex.slice(), com.vtableEntry(owned.device, Device.present_ex_index)) != null);
        }
    }

    test "frameOf refs until releaseFrame" {
        const owned = try OwnedDevice.create(.{});
        defer owned.destroy();
        const frame = try frameOf(owned.device);
        try testing.expectEqual(gfx.Api.d3d9, frame.api);
        try testing.expectEqual(@as(*anyopaque, owned.hwnd), frame.window);
        try testing.expectEqual(@as(*anyopaque, owned.device), frame.device);
        try testing.expectEqual(null, frame.queue);
        const native = fromFrame(&frame).?;
        try testing.expectEqual(owned.device, native.device);
        releaseFrame(&frame);
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

    fn quiet() std.log.Level {
        const saved = testing.log_level;
        testing.log_level = .err;
        return saved;
    }

    test "reports presents and resets" {
        const saved = quiet();
        defer testing.log_level = saved;
        try hook.init(testing.allocator);
        defer hook.deinit();

        for ([_]bool{ false, true }) |ex| {
            const owned = try OwnedDevice.create(.{ .ex = ex });
            defer owned.destroy();

            var recorder: Recorder = .{};
            const present = try PresentHook.create(testing.allocator, .of(Recorder, &recorder));
            try present.enable();

            try testing.expect(com.succeeded(owned.present()));
            if (ex) {
                try testing.expect(com.succeeded(owned.device.presentEx(0)));
            } else {
                try testing.expect(com.succeeded(owned.present()));
            }
            try testing.expectEqual(1, recorder.attaches);
            try testing.expectEqual(2, recorder.frames);
            const frame = recorder.last.?;
            try testing.expectEqual(gfx.Api.d3d9, frame.api);
            try testing.expectEqual(@as(*anyopaque, owned.hwnd), frame.window);
            try testing.expectEqual(@as(*anyopaque, owned.device), frame.device);

            // Fails with D3DERR_INVALIDCALL if anything still holds a default-pool resource
            try testing.expect(com.succeeded(owned.reset(128, 96)));
            try testing.expectEqual(1, recorder.resizes);
            try testing.expect(com.succeeded(owned.present()));
            try testing.expectEqual(3, recorder.frames);

            present.destroy();
            _ = owned.present(); // unhooked, nothing reaches us
            try testing.expectEqual(3, recorder.frames);
        }
    }

    test "early finds game devices" {
        const saved = quiet();
        defer testing.log_level = saved;
        try hook.init(testing.allocator);
        defer hook.deinit();
        _ = try sys.module.systemBase("d3d9.dll");

        for ([_]bool{ false, true }) |ex| {
            var recorder: Recorder = .{};
            const present = try PresentHook.createEarly(testing.allocator, .of(Recorder, &recorder));
            defer present.destroy();
            try present.enable();
            try testing.expectEqual(0, present.present_hooks.len);

            // Like the game would, through the d3d9.dll it loaded
            const owned = try OwnedDevice.create(.{ .ex = ex });
            defer owned.destroy();
            try testing.expect(present.present_hooks.len != 0);
            if (ex) try testing.expect(present.present_ex_hooks.len != 0);

            try testing.expect(com.succeeded(if (ex) owned.device.presentEx(0) else owned.present()));
            try testing.expectEqual(1, recorder.attaches);
            try testing.expectEqual(@as(*anyopaque, owned.device), recorder.last.?.device);

            try testing.expect(com.succeeded(owned.reset(128, 96)));
            try testing.expectEqual(1, recorder.resizes);
        }
    }

    test "hooks a known device" {
        const saved = quiet();
        defer testing.log_level = saved;
        try hook.init(testing.allocator);
        defer hook.deinit();

        const owned = try OwnedDevice.create(.{});
        defer owned.destroy();
        var recorder: Recorder = .{};
        const present = try PresentHook.createFrom(testing.allocator, .of(Recorder, &recorder), owned.device);
        defer present.destroy();
        try present.enable();
        try testing.expect(com.succeeded(owned.present()));
        try testing.expectEqual(1, recorder.attaches);
        try testing.expectEqual(@as(*anyopaque, owned.device), recorder.last.?.device);
    }

    test "shimmed Reset is reported" {
        const saved = quiet();
        defer testing.log_level = saved;
        try hook.init(testing.allocator);
        defer hook.deinit();

        const owned = try OwnedDevice.create(.{});
        defer owned.destroy();
        var recorder: Recorder = .{};
        const present = try PresentHook.create(testing.allocator, .of(Recorder, &recorder));
        defer present.destroy();
        try present.enable();

        // Vtable copy with a fake shim Reset the probes never saw
        const Shim = struct {
            var resets: u32 = 0;
            noinline fn reset(device: *Device, params: *PresentParameters) callconv(.winapi) HRESULT {
                var d = device;
                asm volatile (""
                    : [d] "+r" (d),
                );
                _ = params;
                resets += 1;
                return 0;
            }
        };
        const real_vtable: *const [Device.reset_ex_index + 1]usize = @ptrCast(@as(*const [*]const usize, @ptrCast(@alignCast(owned.device))).*);
        var shimmed = real_vtable.*;
        shimmed[Device.reset_index] = @intFromPtr(&Shim.reset);
        const vtable_slot: *usize = @ptrCast(@alignCast(owned.device));
        const saved_vtable = vtable_slot.*;
        vtable_slot.* = @intFromPtr(&shimmed);
        defer vtable_slot.* = saved_vtable;

        _ = owned.present(); // attaches, and hooks its own Reset
        var params = OwnedDevice.presentParameters(owned.hwnd, 128, 96);
        _ = owned.device.reset(&params);
        try testing.expectEqual(1, Shim.resets);
        try testing.expectEqual(1, recorder.resizes);
    }

    test "replacement device detaches old" {
        const saved = quiet();
        defer testing.log_level = saved;
        try hook.init(testing.allocator);
        defer hook.deinit();

        const first = try OwnedDevice.create(.{});
        defer first.destroy();
        var recorder: Recorder = .{};
        const present = try PresentHook.create(testing.allocator, .of(Recorder, &recorder));
        defer present.destroy();
        try present.enable();

        _ = first.present();
        try testing.expectEqual(1, recorder.attaches);

        const replacement = try OwnedDevice.createOn(first.hwnd, .{});
        defer replacement.destroy();
        _ = replacement.present();
        try testing.expectEqual(1, recorder.detaches);
        try testing.expectEqual(2, recorder.attaches);
        try testing.expectEqual(@as(*anyopaque, replacement.device), recorder.last.?.device);

        const elsewhere = try OwnedDevice.create(.{});
        defer elsewhere.destroy();
        const frames = recorder.frames;
        _ = elsewhere.present();
        try testing.expectEqual(frames, recorder.frames);
        try testing.expectEqual(2, recorder.attaches);
    }
};

test {
    _ = tests;
}
