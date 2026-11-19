//! Vulkan bindings and present path, for attaching to a running game.

const std = @import("std");

const hook = @import("tuft_hook");
const sys = @import("tuft_sys");
const win = sys.win;
const tuft_window = @import("tuft_window");

const gfx = @import("root.zig");
const Tracker = @import("tracker.zig").Tracker;
const hook_set = hook.set;
const HookSet = hook_set.HookSet;
const Addresses = hook_set.Addresses;

const log = std.log.scoped(.tuft_gfx);

pub const Result = i32;
pub const success: Result = 0;
pub const suboptimal: Result = 1000001003;
pub const error_out_of_date: Result = -1000001004;

pub const Bool32 = u32;
pub const Instance = *opaque {};
pub const PhysicalDevice = *opaque {};
pub const Device = *opaque {};
pub const Queue = *opaque {};
pub const CommandBuffer = *opaque {};
/// Non-dispatchable handles are 64-bit, even in 32-bit processes.
pub const SurfaceKHR = u64;
pub const SwapchainKHR = u64;
pub const Semaphore = u64;
pub const Fence = u64;
pub const Image = u64;
pub const CommandPool = u64;
pub const null_handle: u64 = 0;

pub const api_version_1_1: u32 = (1 << 22) | (1 << 12);
pub const queue_graphics_bit: u32 = 0x1;
pub const physical_device_type_discrete: u32 = 2;
pub const image_usage_color_attachment_bit: u32 = 0x10;
pub const image_layout_undefined: u32 = 0;
pub const image_layout_present_src: u32 = 1000001002;
pub const pipeline_stage_color_attachment_output_bit: u32 = 0x400;
pub const pipeline_stage_bottom_of_pipe_bit: u32 = 0x2000;
pub const image_aspect_color_bit: u32 = 0x1;
pub const queue_family_ignored: u32 = 0xffff_ffff;
pub const format_b8g8r8a8_unorm: u32 = 44;
pub const format_r16g16b16a16_sfloat: u32 = 97;
pub const color_space_srgb_nonlinear: u32 = 0;
pub const color_space_extended_srgb_linear: u32 = 1000104002;
pub const color_space_hdr10_st2084: u32 = 1000104008;
const present_mode_fifo: u32 = 2;
const composite_alpha_opaque_bit: u32 = 0x1;
const fence_create_signaled_bit: u32 = 0x1;
const command_pool_reset_command_buffer_bit: u32 = 0x2;
const command_buffer_usage_one_time_submit_bit: u32 = 0x1;

pub const Extent2D = extern struct { width: u32 = 0, height: u32 = 0 };
pub const Extent3D = extern struct { width: u32 = 0, height: u32 = 0, depth: u32 = 0 };

pub const ApplicationInfo = extern struct {
    s_type: u32 = 0,
    p_next: ?*const anyopaque = null,
    application_name: ?[*:0]const u8 = null,
    application_version: u32 = 0,
    engine_name: ?[*:0]const u8 = null,
    engine_version: u32 = 0,
    api_version: u32 = api_version_1_1,
};

pub const InstanceCreateInfo = extern struct {
    s_type: u32 = 1,
    p_next: ?*const anyopaque = null,
    flags: u32 = 0,
    application_info: ?*const ApplicationInfo = null,
    enabled_layer_count: u32 = 0,
    enabled_layer_names: ?[*]const [*:0]const u8 = null,
    enabled_extension_count: u32 = 0,
    enabled_extension_names: ?[*]const [*:0]const u8 = null,
};

pub const DeviceQueueCreateInfo = extern struct {
    s_type: u32 = 2,
    p_next: ?*const anyopaque = null,
    flags: u32 = 0,
    queue_family_index: u32,
    queue_count: u32 = 1,
    queue_priorities: [*]const f32,
};

pub const DeviceCreateInfo = extern struct {
    s_type: u32 = 3,
    p_next: ?*const anyopaque = null,
    flags: u32 = 0,
    queue_create_info_count: u32 = 1,
    queue_create_infos: [*]const DeviceQueueCreateInfo,
    enabled_layer_count: u32 = 0,
    enabled_layer_names: ?[*]const [*:0]const u8 = null,
    enabled_extension_count: u32 = 0,
    enabled_extension_names: ?[*]const [*:0]const u8 = null,
    enabled_features: ?*const anyopaque = null,
};

pub const QueueFamilyProperties = extern struct {
    queue_flags: u32 = 0,
    queue_count: u32 = 0,
    timestamp_valid_bits: u32 = 0,
    min_image_transfer_granularity: Extent3D = .{},
};

/// Start of `VkPhysicalDeviceProperties`, read from a buffer big enough for all of it.
pub const PhysicalDevicePropertiesHead = extern struct {
    api_version: u32,
    driver_version: u32,
    vendor_id: u32,
    device_id: u32,
    device_type: u32,
    device_name: [256]u8,
};
const physical_device_properties_size = 1024;

pub const Win32SurfaceCreateInfoKHR = extern struct {
    s_type: u32 = 1000009000,
    p_next: ?*const anyopaque = null,
    flags: u32 = 0,
    hinstance: ?*anyopaque = null,
    hwnd: tuft_window.Handle,
};

pub const SurfaceCapabilitiesKHR = extern struct {
    min_image_count: u32 = 0,
    max_image_count: u32 = 0,
    current_extent: Extent2D = .{},
    min_image_extent: Extent2D = .{},
    max_image_extent: Extent2D = .{},
    max_image_array_layers: u32 = 0,
    supported_transforms: u32 = 0,
    current_transform: u32 = 0,
    supported_composite_alpha: u32 = 0,
    supported_usage_flags: u32 = 0,
};

pub const image_usage_transfer_src: u32 = 0x1;

const SurfaceUsage = struct { surface: SurfaceKHR = null_handle, flags: u32 = 0 };

pub const SurfaceFormatKHR = extern struct { format: u32 = 0, color_space: u32 = 0 };

pub const SwapchainCreateInfoKHR = extern struct {
    s_type: u32 = 1000001000,
    p_next: ?*const anyopaque = null,
    flags: u32 = 0,
    surface: SurfaceKHR,
    min_image_count: u32,
    image_format: u32,
    image_color_space: u32,
    image_extent: Extent2D,
    image_array_layers: u32 = 1,
    image_usage: u32,
    image_sharing_mode: u32 = 0,
    queue_family_index_count: u32 = 0,
    queue_family_indices: ?[*]const u32 = null,
    pre_transform: u32,
    composite_alpha: u32,
    present_mode: u32,
    clipped: Bool32 = 1,
    old_swapchain: SwapchainKHR = null_handle,
};

pub const PresentInfoKHR = extern struct {
    s_type: u32 = 1000001001,
    p_next: ?*const anyopaque = null,
    wait_semaphore_count: u32 = 0,
    wait_semaphores: ?[*]const Semaphore = null,
    swapchain_count: u32,
    swapchains: [*]const SwapchainKHR,
    image_indices: [*]const u32,
    results: ?[*]Result = null,
};

pub const AcquireNextImageInfoKHR = extern struct {
    s_type: u32 = 1000060010,
    p_next: ?*const anyopaque = null,
    swapchain: SwapchainKHR,
    timeout: u64,
    semaphore: Semaphore,
    fence: Fence,
    device_mask: u32,
};

pub const SubmitInfo = extern struct {
    s_type: u32 = 4,
    p_next: ?*const anyopaque = null,
    wait_semaphore_count: u32 = 0,
    wait_semaphores: ?[*]const Semaphore = null,
    wait_dst_stage_mask: ?[*]const u32 = null,
    command_buffer_count: u32 = 0,
    command_buffers: ?[*]const CommandBuffer = null,
    signal_semaphore_count: u32 = 0,
    signal_semaphores: ?[*]const Semaphore = null,
};

pub const SemaphoreCreateInfo = extern struct { s_type: u32 = 9, p_next: ?*const anyopaque = null, flags: u32 = 0 };
pub const FenceCreateInfo = extern struct { s_type: u32 = 8, p_next: ?*const anyopaque = null, flags: u32 = 0 };

pub const CommandPoolCreateInfo = extern struct {
    s_type: u32 = 39,
    p_next: ?*const anyopaque = null,
    flags: u32 = 0,
    queue_family_index: u32,
};

pub const CommandBufferAllocateInfo = extern struct {
    s_type: u32 = 40,
    p_next: ?*const anyopaque = null,
    command_pool: CommandPool,
    level: u32 = 0,
    command_buffer_count: u32 = 1,
};

pub const CommandBufferBeginInfo = extern struct {
    s_type: u32 = 42,
    p_next: ?*const anyopaque = null,
    flags: u32 = 0,
    inheritance_info: ?*const anyopaque = null,
};

pub const ImageSubresourceRange = extern struct {
    aspect_mask: u32 = image_aspect_color_bit,
    base_mip_level: u32 = 0,
    level_count: u32 = 1,
    base_array_layer: u32 = 0,
    layer_count: u32 = 1,
};

pub const ImageMemoryBarrier = extern struct {
    s_type: u32 = 45,
    p_next: ?*const anyopaque = null,
    src_access_mask: u32 = 0,
    dst_access_mask: u32 = 0,
    old_layout: u32,
    new_layout: u32,
    src_queue_family_index: u32 = queue_family_ignored,
    dst_queue_family_index: u32 = queue_family_ignored,
    image: Image,
    subresource_range: ImageSubresourceRange = .{},
};

// `VKAPI_CALL` is stdcall on 32-bit Windows, so `.winapi`

const Alloc = ?*const anyopaque;
const VoidFn = fn () callconv(.winapi) void;
pub const GetInstanceProcAddrFn = fn (?Instance, [*:0]const u8) callconv(.winapi) ?*const VoidFn;
pub const GetDeviceProcAddrFn = fn (Device, [*:0]const u8) callconv(.winapi) ?*const VoidFn;

pub const QueuePresentFn = fn (Queue, *const PresentInfoKHR) callconv(.winapi) Result;
pub const AcquireNextImageFn = fn (Device, SwapchainKHR, u64, Semaphore, Fence, *u32) callconv(.winapi) Result;
pub const AcquireNextImage2Fn = fn (Device, *const AcquireNextImageInfoKHR, *u32) callconv(.winapi) Result;
pub const CreateSwapchainFn = fn (Device, *const SwapchainCreateInfoKHR, Alloc, *SwapchainKHR) callconv(.winapi) Result;
pub const DestroySwapchainFn = fn (Device, SwapchainKHR, Alloc) callconv(.winapi) void;
pub const GetSurfaceCapabilitiesFn = fn (PhysicalDevice, SurfaceKHR, *SurfaceCapabilitiesKHR) callconv(.winapi) Result;
pub const GetSurfaceCapabilities2Fn = fn (PhysicalDevice, *const anyopaque, *anyopaque) callconv(.winapi) Result;
pub const GetSwapchainImagesFn = fn (Device, SwapchainKHR, *u32, ?[*]Image) callconv(.winapi) Result;

/// Instance-level functions we call, named as in Vulkan.
const InstanceFns = struct {
    vkDestroyInstance: *const fn (Instance, Alloc) callconv(.winapi) void,
    vkEnumeratePhysicalDevices: *const fn (Instance, *u32, ?[*]PhysicalDevice) callconv(.winapi) Result,
    vkGetPhysicalDeviceProperties: *const fn (PhysicalDevice, *anyopaque) callconv(.winapi) void,
    vkGetPhysicalDeviceQueueFamilyProperties: *const fn (PhysicalDevice, *u32, ?[*]QueueFamilyProperties) callconv(.winapi) void,
    vkCreateDevice: *const fn (PhysicalDevice, *const DeviceCreateInfo, Alloc, *?Device) callconv(.winapi) Result,
    vkCreateWin32SurfaceKHR: *const fn (Instance, *const Win32SurfaceCreateInfoKHR, Alloc, *SurfaceKHR) callconv(.winapi) Result,
    vkDestroySurfaceKHR: *const fn (Instance, SurfaceKHR, Alloc) callconv(.winapi) void,
    vkGetPhysicalDeviceSurfaceSupportKHR: *const fn (PhysicalDevice, u32, SurfaceKHR, *Bool32) callconv(.winapi) Result,
    vkGetPhysicalDeviceSurfaceCapabilitiesKHR: *const fn (PhysicalDevice, SurfaceKHR, *SurfaceCapabilitiesKHR) callconv(.winapi) Result,
    vkGetPhysicalDeviceSurfaceFormatsKHR: *const fn (PhysicalDevice, SurfaceKHR, *u32, ?[*]SurfaceFormatKHR) callconv(.winapi) Result,
};

const DeviceFns = struct {
    vkDestroyDevice: *const fn (Device, Alloc) callconv(.winapi) void,
    vkGetDeviceQueue: *const fn (Device, u32, u32, *?Queue) callconv(.winapi) void,
    vkDeviceWaitIdle: *const fn (Device) callconv(.winapi) Result,
    vkCreateSwapchainKHR: *const CreateSwapchainFn,
    vkDestroySwapchainKHR: *const DestroySwapchainFn,
    vkGetSwapchainImagesKHR: *const GetSwapchainImagesFn,
    vkAcquireNextImageKHR: *const AcquireNextImageFn,
    vkQueuePresentKHR: *const QueuePresentFn,
    vkQueueSubmit: *const fn (Queue, u32, ?[*]const SubmitInfo, Fence) callconv(.winapi) Result,
    vkCreateSemaphore: *const fn (Device, *const SemaphoreCreateInfo, Alloc, *Semaphore) callconv(.winapi) Result,
    vkDestroySemaphore: *const fn (Device, Semaphore, Alloc) callconv(.winapi) void,
    vkCreateFence: *const fn (Device, *const FenceCreateInfo, Alloc, *Fence) callconv(.winapi) Result,
    vkDestroyFence: *const fn (Device, Fence, Alloc) callconv(.winapi) void,
    vkWaitForFences: *const fn (Device, u32, [*]const Fence, Bool32, u64) callconv(.winapi) Result,
    vkResetFences: *const fn (Device, u32, [*]const Fence) callconv(.winapi) Result,
    vkCreateCommandPool: *const fn (Device, *const CommandPoolCreateInfo, Alloc, *CommandPool) callconv(.winapi) Result,
    vkDestroyCommandPool: *const fn (Device, CommandPool, Alloc) callconv(.winapi) void,
    vkAllocateCommandBuffers: *const fn (Device, *const CommandBufferAllocateInfo, [*]CommandBuffer) callconv(.winapi) Result,
    vkBeginCommandBuffer: *const fn (CommandBuffer, *const CommandBufferBeginInfo) callconv(.winapi) Result,
    vkEndCommandBuffer: *const fn (CommandBuffer) callconv(.winapi) Result,
    vkCmdPipelineBarrier: *const fn (CommandBuffer, u32, u32, u32, u32, ?*const anyopaque, u32, ?*const anyopaque, u32, ?[*]const ImageMemoryBarrier) callconv(.winapi) void,
};

const Loader = struct {
    get_instance_proc_addr: *const GetInstanceProcAddrFn,
    get_device_proc_addr: *const GetDeviceProcAddrFn,
};

var loader: ?Loader = null;

/// The game's `vulkan-1.dll`, or Windows' if none is loaded.
fn load() !Loader {
    if (loader) |l| return l;
    const base = sys.module.findBase("vulkan-1.dll") orelse (sys.module.systemBase("vulkan-1.dll") catch return error.NoVulkan);
    const l: Loader = .{
        .get_instance_proc_addr = @ptrFromInt(sys.module.findExport(base, "vkGetInstanceProcAddr") orelse return error.NoVulkan),
        .get_device_proc_addr = @ptrFromInt(sys.module.findExport(base, "vkGetDeviceProcAddr") orelse return error.NoVulkan),
    };
    loader = l;
    return l;
}

/// Null `instance` for a global function.
pub fn instanceProc(comptime F: type, instance: ?Instance, name: [*:0]const u8) ?*const F {
    const l = load() catch return null;
    return @ptrCast(l.get_instance_proc_addr(instance, name) orelse return null);
}

/// Through `device`'s layers to the driver.
pub fn deviceProc(comptime F: type, device: Device, name: [*:0]const u8) ?*const F {
    const l = load() catch return null;
    return @ptrCast(l.get_device_proc_addr(device, name) orelse return null);
}

fn loadFns(comptime T: type, comptime getter: anytype, handle: anytype) !T {
    var fns: T = undefined;
    const info = @typeInfo(T).@"struct";
    inline for (info.field_names, info.field_types) |name, Field| {
        const F = @typeInfo(Field).pointer.child;
        @field(fns, name) = getter(F, handle, name) orelse {
            log.debug("Vulkan function {s} not available", .{name});
            return error.MissingVulkanFunction;
        };
    }
    return fns;
}

fn check(result: Result) !void {
    if (result < 0) return error.VulkanCallFailed;
}

/// Rarely intercepted by layers, so they point into the driver and identify the GPU.
const signature_names = [_][:0]const u8{ "vkCreateSampler", "vkCreateImageView", "vkCreateBuffer", "vkCmdDraw" };
const max_gpus = 8;

/// Our own instance, kept while hooked, plus the GPUs and functions to hook.
pub const Probe = struct {
    instance: Instance,
    fns: InstanceFns,
    gpus: [max_gpus]Gpu = undefined,
    gpu_count: usize = 0,
    present: Addresses = .{},
    acquire: Addresses = .{},
    acquire2: Addresses = .{},
    create_swapchain: Addresses = .{},
    destroy_swapchain: Addresses = .{},

    pub const Gpu = struct {
        device: PhysicalDevice,
        device_type: u32,
        vendor_id: u32,
        device_id: u32,
        graphics_family: u32,
        signature: [signature_names.len]usize,
    };

    pub fn create() !Probe {
        const create_instance = instanceProc(fn (*const InstanceCreateInfo, Alloc, *?Instance) callconv(.winapi) Result, null, "vkCreateInstance") orelse return error.NoVulkan;
        const app: ApplicationInfo = .{ .application_name = "tuft probe" };
        const extensions = [_][*:0]const u8{ "VK_KHR_surface", "VK_KHR_win32_surface" };
        var instance: ?Instance = null;
        // The loader alone can't make one, like on a machine with no GPU driver
        check(create_instance(&.{ .application_info = &app, .enabled_extension_count = extensions.len, .enabled_extension_names = &extensions }, null, &instance)) catch return error.NoVulkan;
        var self: Probe = .{ .instance = instance.?, .fns = undefined };
        self.fns = loadFns(InstanceFns, instanceProc, instance) catch |err| {
            if (instanceProc(fn (Instance, Alloc) callconv(.winapi) void, instance, "vkDestroyInstance")) |destroy_instance| destroy_instance(instance.?, null);
            return err;
        };
        errdefer self.destroy();

        var devices: [max_gpus]PhysicalDevice = undefined;
        var count: u32 = devices.len;
        if (self.fns.vkEnumeratePhysicalDevices(self.instance, &count, &devices) < 0) count = 0;
        for (devices[0..count]) |physical| self.probeGpu(physical) catch |err| log.debug("Couldn't probe a Vulkan GPU: {t}", .{err});
        if (self.gpu_count == 0) return error.NoVulkanDevice;
        return self;
    }

    pub fn destroy(self: *Probe) void {
        self.fns.vkDestroyInstance(self.instance, null);
    }

    fn probeGpu(self: *Probe, physical: PhysicalDevice) !void {
        const family = graphicsFamily(self.fns, physical) orelse return error.NoGraphicsQueue;
        var props: [physical_device_properties_size]u8 align(8) = undefined;
        self.fns.vkGetPhysicalDeviceProperties(physical, &props);
        const head: *const PhysicalDevicePropertiesHead = @ptrCast(&props);

        const priority: f32 = 1;
        const queue: DeviceQueueCreateInfo = .{ .queue_family_index = family, .queue_priorities = @ptrCast(&priority) };
        const extensions = [_][*:0]const u8{"VK_KHR_swapchain"};
        var device: ?Device = null;
        try check(self.fns.vkCreateDevice(physical, &.{ .queue_create_infos = @ptrCast(&queue), .enabled_extension_count = extensions.len, .enabled_extension_names = &extensions }, null, &device));
        defer if (deviceProc(fn (Device, Alloc) callconv(.winapi) void, device.?, "vkDestroyDevice")) |destroy_device| destroy_device(device.?, null);

        const at = struct {
            fn at(d: Device, name: [*:0]const u8) usize {
                return @intFromPtr(deviceProc(VoidFn, d, name) orelse return 0);
            }
        }.at;
        inline for (.{
            .{ &self.present, "vkQueuePresentKHR" },
            .{ &self.acquire, "vkAcquireNextImageKHR" },
            .{ &self.acquire2, "vkAcquireNextImage2KHR" },
            .{ &self.create_swapchain, "vkCreateSwapchainKHR" },
            .{ &self.destroy_swapchain, "vkDestroySwapchainKHR" },
        }) |method| {
            const address = at(device.?, method[1]);
            if (address != 0) method[0].add(address);
        }

        if (self.gpu_count == max_gpus) return;
        var gpu: Gpu = .{ .device = physical, .device_type = head.device_type, .vendor_id = head.vendor_id, .device_id = head.device_id, .graphics_family = family, .signature = undefined };
        for (signature_names, &gpu.signature) |name, *s| s.* = at(device.?, name);
        self.gpus[self.gpu_count] = gpu;
        self.gpu_count += 1;
        log.debug("Vulkan GPU: {s}", .{std.mem.sliceTo(&head.device_name, 0)});
    }

    /// Our handle for `device`'s GPU, matched by driver functions, else a discrete one.
    pub fn gpuFor(self: *const Probe, device: Device) *const Gpu {
        var signature: [signature_names.len]usize = undefined;
        for (signature_names, &signature) |name, *s| s.* = if (deviceProc(VoidFn, device, name)) |p| @intFromPtr(p) else 0;
        var best: *const Gpu = &self.gpus[0];
        var best_score: i32 = -1;
        for (self.gpus[0..self.gpu_count]) |*gpu| {
            var score: i32 = 0;
            for (signature, gpu.signature) |a, b| {
                if (a != 0 and a == b) score += 2;
            }
            if (gpu.device_type == physical_device_type_discrete) score += 1;
            if (score > best_score) {
                best = gpu;
                best_score = score;
            }
        }
        return best;
    }
};

// Loader records behind a game's handles, from Vulkan-Loader's loader_common.h
const LoaderInstance = extern struct { dispatch: ?*anyopaque, magic: u64 };
const LoaderPhysicalDevice = extern struct { dispatch: ?*anyopaque, instance: ?Instance, magic: u64 };
const loader_instance_magic: u64 = 0x10ADED010110ADED;
const loader_physical_device_magic: u64 = 0x10ADED020210ADED;

/// The game's instance for `physical`, if the loader's records look like we expect.
fn loaderInstanceOf(physical: PhysicalDevice) ?Instance {
    if (@intFromPtr(physical) % @alignOf(LoaderPhysicalDevice) != 0) return null;
    const p: *const LoaderPhysicalDevice = @ptrCast(@alignCast(physical));
    if (p.magic != loader_physical_device_magic) return null;
    const instance = p.instance orelse return null;
    if (@intFromPtr(instance) % @alignOf(LoaderInstance) != 0) return null;
    const i: *const LoaderInstance = @ptrCast(@alignCast(instance));
    return if (i.magic == loader_instance_magic) instance else null;
}

fn graphicsFamily(fns: InstanceFns, physical: PhysicalDevice) ?u32 {
    var families: [16]QueueFamilyProperties = undefined;
    var count: u32 = families.len;
    fns.vkGetPhysicalDeviceQueueFamilyProperties(physical, &count, &families);
    for (families[0..count], 0..) |f, i| {
        if (f.queue_flags & queue_graphics_bit != 0) return @intCast(i);
    }
    return null;
}

/// One of the game's swapchains. It's the frame's `swap_chain`.
pub const Swapchain = struct {
    handle: SwapchainKHR,
    device: Device,
    /// Made while hooked, else we don't know its format and size.
    known: bool = false,
    format: u32 = 0,
    color_space: u32 = 0,
    extent: Extent2D = .{},
    min_image_count: u32 = 0,
    image_count: u32 = 0,
    window: ?tuft_window.Handle = null,
    /// Ours unless `games_instance`. Ours are only for queries, never mixed with the game's objects.
    instance: ?Instance = null,
    physical_device: ?PhysicalDevice = null,
    games_instance: bool = false,
    queue_family: u32 = 0,

    /// The image presented and the semaphores it waits on.
    image_index: u32 = 0,
    wait_semaphores: []const Semaphore = &.{},
    /// Set by a listener whose work waits on `wait_semaphores`. The present then waits on this.
    signal: Semaphore = null_handle,

    recreate_requests: u8 = 0,
    /// Its images can be copied from, for frame captures.
    copyable: bool = false,

    pub fn colorSpace(self: *const Swapchain) gfx.ColorSpace {
        return switch (self.color_space) {
            color_space_extended_srgb_linear => .scrgb,
            color_space_hdr10_st2084 => .hdr10,
            else => .srgb,
        };
    }

    pub fn images(self: *const Swapchain, out: []Image) ![]Image {
        const get = deviceProc(GetSwapchainImagesFn, self.device, "vkGetSwapchainImagesKHR") orelse return error.MissingVulkanFunction;
        var count: u32 = @intCast(out.len);
        const result = get(self.device, self.handle, &count, out.ptr);
        if (result < 0) return error.VulkanCallFailed;
        return out[0..count];
    }
};

pub const Native = struct {
    swapchain: *Swapchain,
    device: Device,
    queue: Queue,
};

pub fn fromFrame(frame: *const gfx.Frame) ?Native {
    if (frame.api != .vulkan) return null;
    return .{ .swapchain = @ptrCast(@alignCast(frame.swap_chain)), .device = @ptrCast(frame.device), .queue = @ptrCast(frame.queue.?) };
}

/// Our process's top-level window with a client area of `extent`. Prefers a visible one.
fn windowFor(extent: Extent2D) ?tuft_window.Handle {
    const Search = struct {
        extent: Extent2D,
        pid: u32,
        visible: ?tuft_window.Handle = null,
        hidden: ?tuft_window.Handle = null,

        fn visit(hwnd: tuft_window.Handle, param: isize) callconv(.winapi) win.BOOL {
            const self: *@This() = @ptrFromInt(@as(usize, @bitCast(param)));
            var pid: u32 = 0;
            _ = win.GetWindowThreadProcessId(hwnd, &pid);
            if (pid != self.pid) return .TRUE;
            const size = tuft_window.clientSize(hwnd);
            if (size.width != self.extent.width or size.height != self.extent.height) return .TRUE;
            if (win.IsWindowVisible(hwnd).toBool()) {
                self.visible = hwnd;
                return .FALSE;
            }
            if (self.hidden == null) self.hidden = hwnd;
            return .TRUE;
        }
    };
    var search: Search = .{ .extent = extent, .pid = win.GetCurrentProcessId() };
    _ = win.EnumWindows(Search.visit, @bitCast(@intFromPtr(&search)));
    return search.visible orelse search.hidden;
}

/// Times we tell a pre-hook swapchain it's out of date before giving up.
const max_recreate_requests = 3;

/// Nesting depth on this thread, so a layer calling into the driver reports once.
threadlocal var present_depth: u32 = 0;

/// The Vulkan path. Init `tuft_hook` first.
pub const PresentHook = struct {
    allocator: std.mem.Allocator,
    probe: Probe,
    present_hooks: HookSet(QueuePresentFn) = .{},
    acquire_hooks: HookSet(AcquireNextImageFn) = .{},
    acquire2_hooks: HookSet(AcquireNextImage2Fn) = .{},
    create_hooks: HookSet(CreateSwapchainFn) = .{},
    destroy_hooks: HookSet(DestroySwapchainFn) = .{},
    caps_hooks: HookSet(GetSurfaceCapabilitiesFn) = .{},
    caps2_hooks: HookSet(GetSurfaceCapabilities2Fn) = .{},
    swapchains: std.AutoHashMapUnmanaged(SwapchainKHR, *Swapchain) = .empty,
    lock: sys.sync.RwLock = .{},
    /// The game's instance and GPUs, set by `learn`.
    game_instance: ?Instance = null,
    game_gpus: [max_gpus]PhysicalDevice = undefined,
    game_gpu_count: usize = 0,
    game_lock: sys.sync.RwLock = .{},
    /// What the game's surfaces allow their images to be used for, newest last. Under `game_lock`.
    surface_usages: [8]SurfaceUsage = @splat(.{}),
    surface_usage_next: usize = 0,
    tracker: Tracker(Source),

    /// Hooks start disabled. `error.NotInUse` if the game hasn't loaded Vulkan.
    pub fn create(allocator: std.mem.Allocator, listener: gfx.Listener) !*PresentHook {
        if (sys.module.findBase("vulkan-1.dll") == null) return error.NotInUse;
        var probe = try Probe.create();
        errdefer probe.destroy();
        if (probe.present.len == 0 or probe.create_swapchain.len == 0 or probe.destroy_swapchain.len == 0 or probe.acquire.len == 0) {
            return error.MissingVulkanFunction;
        }

        const self = try allocator.create(PresentHook);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .probe = probe, .tracker = .{ .listener = listener } };
        errdefer self.destroyHooks();
        try self.present_hooks.create(&probe.present, onPresent, self);
        try self.acquire_hooks.create(&probe.acquire, onAcquire, self);
        try self.acquire2_hooks.create(&probe.acquire2, onAcquire2, self);
        try self.create_hooks.create(&probe.create_swapchain, onCreateSwapchain, self);
        try self.destroy_hooks.create(&probe.destroy_swapchain, onDestroySwapchain, self);
        // Hooked in the loader, so the GPU handle the game passes is the loader's
        const vulkan_dll = sys.module.findBase("vulkan-1.dll").?;
        if (sys.module.findExport(vulkan_dll, "vkGetPhysicalDeviceSurfaceCapabilitiesKHR")) |address| _ = try self.caps_hooks.add(address, onSurfaceCapabilities, self);
        if (sys.module.findExport(vulkan_dll, "vkGetPhysicalDeviceSurfaceCapabilities2KHR")) |address| _ = try self.caps2_hooks.add(address, onSurfaceCapabilities2, self);
        return self;
    }

    pub fn enable(self: *PresentHook) !void {
        try self.create_hooks.enable();
        try self.destroy_hooks.enable();
        try self.caps_hooks.enable();
        try self.caps2_hooks.enable();
        try self.acquire_hooks.enable();
        try self.acquire2_hooks.enable();
        try self.present_hooks.enable();
    }

    /// Unhooks, waiting for calls in flight.
    pub fn destroy(self: *PresentHook) void {
        self.destroyHooks();
        self.tracker.deinit();
        var it = self.swapchains.valueIterator();
        while (it.next()) |s| self.allocator.destroy(s.*);
        self.swapchains.deinit(self.allocator);
        self.probe.destroy();
        self.allocator.destroy(self);
    }

    fn destroyHooks(self: *PresentHook) void {
        self.present_hooks.destroy();
        self.acquire_hooks.destroy();
        self.acquire2_hooks.destroy();
        self.create_hooks.destroy();
        self.destroy_hooks.destroy();
        self.caps_hooks.destroy();
        self.caps2_hooks.destroy();
    }

    fn find(self: *PresentHook, handle: SwapchainKHR) ?*Swapchain {
        self.lock.lockShared();
        defer self.lock.unlockShared();
        return self.swapchains.get(handle);
    }

    fn record(self: *PresentHook, device: Device, handle: SwapchainKHR) ?*Swapchain {
        if (self.find(handle)) |s| return s;
        self.lock.lock();
        defer self.lock.unlock();
        const entry = self.swapchains.getOrPut(self.allocator, handle) catch return null;
        if (!entry.found_existing) {
            const s = self.allocator.create(Swapchain) catch {
                self.swapchains.removeByPtr(entry.key_ptr);
                return null;
            };
            const gpu = self.probe.gpuFor(device);
            s.* = .{ .handle = handle, .device = device, .instance = self.probe.instance, .physical_device = gpu.device, .queue_family = gpu.graphics_family };
            if (self.gameGpu(gpu)) |game| {
                s.instance = game.instance;
                s.physical_device = game.device;
                s.games_instance = true;
            }
            entry.value_ptr.* = s;
        }
        return entry.value_ptr.*;
    }

    fn onCreateSwapchain(self: *PresentHook, h: *hook.TypedHook(CreateSwapchainFn), device: Device, info: *const SwapchainCreateInfoKHR, alloc: Alloc, out: *SwapchainKHR) Result {
        // Frame captures copy out of the images. Only asked for when the surface allows it
        var with_copy = info.*;
        if (self.surfaceUsage(info.surface) & image_usage_transfer_src != 0) with_copy.image_usage |= image_usage_transfer_src;
        const result = h.original()(device, &with_copy, alloc, out);
        if (result != success) {
            log.warn("vkCreateSwapchainKHR failed ({d}): {d}x{d}, format {d}, replacing 0x{x}", .{ result, info.image_extent.width, info.image_extent.height, info.image_format, info.old_swapchain });
            return result;
        }
        log.debug("Vulkan swapchain 0x{x}: {d}x{d}, format {d}, replacing 0x{x}", .{ out.*, info.image_extent.width, info.image_extent.height, info.image_format, info.old_swapchain });
        const s = self.record(device, out.*) orelse return result;
        s.known = true;
        s.copyable = with_copy.image_usage & image_usage_transfer_src != 0;
        s.format = info.image_format;
        s.color_space = info.image_color_space;
        s.extent = info.image_extent;
        s.min_image_count = info.min_image_count;
        if (deviceProc(GetSwapchainImagesFn, device, "vkGetSwapchainImagesKHR")) |get| {
            var count: u32 = 0;
            if (get(device, out.*, &count, null) >= 0) s.image_count = count;
        }
        s.window = windowFor(s.extent);
        return result;
    }

    /// Learns the game's instance from a GPU handle it got.
    fn learn(self: *PresentHook, physical: PhysicalDevice) void {
        const instance = loaderInstanceOf(physical) orelse return;
        if (instance == self.probe.instance) return; // our own queries, or ImGui's
        self.game_lock.lock();
        defer self.game_lock.unlock();
        if (self.game_instance != instance) {
            self.game_instance = instance;
            self.game_gpu_count = 0;
        }
        if (std.mem.indexOfScalar(PhysicalDevice, self.game_gpus[0..self.game_gpu_count], physical) != null) return;
        if (self.game_gpu_count == max_gpus) return;
        self.game_gpus[self.game_gpu_count] = physical;
        self.game_gpu_count += 1;
    }

    fn gameGpu(self: *PresentHook, ours: *const Probe.Gpu) ?struct { instance: Instance, device: PhysicalDevice } {
        self.game_lock.lockShared();
        const instance = self.game_instance;
        var gpus: [max_gpus]PhysicalDevice = undefined;
        const count = self.game_gpu_count;
        @memcpy(gpus[0..count], self.game_gpus[0..count]);
        self.game_lock.unlockShared();

        const get_properties = instanceProc(fn (PhysicalDevice, *anyopaque) callconv(.winapi) void, instance orelse return null, "vkGetPhysicalDeviceProperties") orelse return null;
        for (gpus[0..count]) |gpu| {
            var props: [physical_device_properties_size]u8 align(8) = undefined;
            get_properties(gpu, &props);
            const head: *const PhysicalDevicePropertiesHead = @ptrCast(&props);
            if (head.vendor_id == ours.vendor_id and head.device_id == ours.device_id) return .{ .instance = instance.?, .device = gpu };
        }
        return null;
    }

    fn onSurfaceCapabilities(self: *PresentHook, h: *hook.TypedHook(GetSurfaceCapabilitiesFn), physical: PhysicalDevice, surface: SurfaceKHR, caps: *SurfaceCapabilitiesKHR) Result {
        self.learn(physical);
        const result = h.original()(physical, surface, caps);
        if (result == success) self.noteSurfaceUsage(surface, caps.supported_usage_flags);
        return result;
    }

    fn onSurfaceCapabilities2(self: *PresentHook, h: *hook.TypedHook(GetSurfaceCapabilities2Fn), physical: PhysicalDevice, info: *const anyopaque, caps: *anyopaque) Result {
        self.learn(physical);
        const result = h.original()(physical, info, caps);
        // Both start with sType and pNext, then the surface and the caps
        if (result == success) {
            const surface = @as(*const extern struct { s_type: u32, p_next: ?*const anyopaque, surface: SurfaceKHR }, @ptrCast(@alignCast(info))).surface;
            const inner = @as(*const extern struct { s_type: u32, p_next: ?*anyopaque, caps: SurfaceCapabilitiesKHR }, @ptrCast(@alignCast(caps))).caps;
            self.noteSurfaceUsage(surface, inner.supported_usage_flags);
        }
        return result;
    }

    fn noteSurfaceUsage(self: *PresentHook, surface: SurfaceKHR, flags: u32) void {
        self.game_lock.lock();
        defer self.game_lock.unlock();
        for (&self.surface_usages) |*u| if (u.surface == surface) {
            u.flags = flags;
            return;
        };
        self.surface_usages[self.surface_usage_next] = .{ .surface = surface, .flags = flags };
        self.surface_usage_next = (self.surface_usage_next + 1) % self.surface_usages.len;
    }

    /// 0 if the game never asked.
    fn surfaceUsage(self: *PresentHook, surface: SurfaceKHR) u32 {
        self.game_lock.lockShared();
        defer self.game_lock.unlockShared();
        for (self.surface_usages) |u| if (u.surface == surface) return u.flags;
        return 0;
    }

    fn onDestroySwapchain(self: *PresentHook, h: *hook.TypedHook(DestroySwapchainFn), device: Device, handle: SwapchainKHR, alloc: Alloc) void {
        // Whoever draws into it lets go of the images first
        if (self.find(handle)) |s| {
            self.tracker.remove(s);
            self.lock.lock();
            _ = self.swapchains.remove(handle);
            self.lock.unlock();
            self.allocator.destroy(s);
        }
        h.original()(device, handle, alloc);
    }

    fn onAcquire(self: *PresentHook, h: *hook.TypedHook(AcquireNextImageFn), device: Device, handle: SwapchainKHR, timeout: u64, semaphore: Semaphore, fence: Fence, index: *u32) Result {
        if (handle != null_handle) _ = self.record(device, handle);
        return h.original()(device, handle, timeout, semaphore, fence, index);
    }

    fn onAcquire2(self: *PresentHook, h: *hook.TypedHook(AcquireNextImage2Fn), device: Device, info: *const AcquireNextImageInfoKHR, index: *u32) Result {
        if (info.swapchain != null_handle) _ = self.record(device, info.swapchain);
        return h.original()(device, info, index);
    }

    fn onPresent(self: *PresentHook, h: *hook.TypedHook(QueuePresentFn), queue: Queue, info: *const PresentInfoKHR) Result {
        present_depth += 1;
        defer present_depth -= 1;
        if (present_depth != 1) return h.original()(queue, info);
        self.tracker.presented();

        var recreate = false;
        var signal: Semaphore = null_handle;
        self.tracker.source.queue = queue;
        for (info.swapchains[0..info.swapchain_count], info.image_indices[0..info.swapchain_count]) |handle, index| {
            const s = self.find(handle) orelse continue;
            if (!s.known) {
                if (s.recreate_requests < max_recreate_requests) {
                    s.recreate_requests += 1;
                    recreate = true;
                    if (s.recreate_requests == 1) log.info("Asking the game to remake Vulkan swapchain 0x{x} (made before we hooked)", .{handle});
                } else if (s.recreate_requests == max_recreate_requests) {
                    s.recreate_requests += 1;
                    log.warn("The game didn't remake Vulkan swapchain 0x{x}: can't draw on it", .{handle});
                }
                continue;
            }
            s.image_index = index;
            s.wait_semaphores = if (info.wait_semaphores) |w| w[0..info.wait_semaphore_count] else &.{};
            s.signal = null_handle;
            if (self.tracker.current(s)) |f| f.queue = queue;
            self.tracker.present(s);
            if (s.signal != null_handle) signal = s.signal;
            s.signal = null_handle;
        }

        const result = if (signal != null_handle) blk: {
            var changed = info.*;
            changed.wait_semaphore_count = 1;
            changed.wait_semaphores = @ptrCast(&signal);
            break :blk h.original()(queue, &changed);
        } else h.original()(queue, info);
        // It got presented, so as far as the game knows it's out of date now
        if (recreate and (result == success or result == suboptimal)) return error_out_of_date;
        return result;
    }

    const Source = struct {
        pub const Key = *Swapchain;
        pub const noun = "swapchain";

        queue: ?Queue = null,

        pub fn keyOf(f: *const gfx.Frame) Key {
            return @ptrCast(@alignCast(f.swap_chain));
        }

        pub fn windowOf(_: Source, s: Key) ?*anyopaque {
            return s.window;
        }

        pub fn attach(self: Source, s: Key) !gfx.Frame {
            const window = s.window orelse return error.NoOutputWindow;
            return .{ .api = .vulkan, .window = window, .swap_chain = s, .device = s.device, .queue = self.queue, .color_space = s.colorSpace() };
        }

        /// No refs. The record lives until the swapchain is destroyed.
        pub fn release(_: *const gfx.Frame) void {}
    };
};

/// A Vulkan "game" of our own, for tests. Remakes the swapchain when it's out of date.
pub const OwnedSwapchain = struct {
    pub const max_images = 8;

    hwnd: tuft_window.Handle,
    owns_window: bool,
    instance: Instance,
    fns: InstanceFns,
    gpu: PhysicalDevice,
    family: u32,
    surface: SurfaceKHR,
    device: Device,
    dfns: DeviceFns,
    queue: Queue,
    swapchain: SwapchainKHR = null_handle,
    format: SurfaceFormatKHR = .{},
    extent: Extent2D = .{},
    images: [max_images]Image = undefined,
    image_count: u32 = 0,
    pool: CommandPool = null_handle,
    command_buffer: CommandBuffer = undefined,
    acquired: Semaphore = null_handle,
    drawn: Semaphore = null_handle,
    fence: Fence = null_handle,
    remakes: u32 = 0,
    color_space: u32 = color_space_srgb_nonlinear,

    pub const Options = struct {
        /// One of the `color_space_*`s.
        color_space: u32 = color_space_srgb_nonlinear,
    };

    pub fn create(options: Options) !*OwnedSwapchain {
        const hwnd = try tuft_window.createHidden();
        errdefer tuft_window.destroy(hwnd);
        const self = try createOn(hwnd, options);
        self.owns_window = true;
        return self;
    }

    pub fn createOn(hwnd: tuft_window.Handle, options: Options) !*OwnedSwapchain {
        const create_instance = instanceProc(fn (*const InstanceCreateInfo, Alloc, *?Instance) callconv(.winapi) Result, null, "vkCreateInstance") orelse return error.NoVulkan;
        const app: ApplicationInfo = .{ .application_name = "tuft test game" };
        // HDR color spaces come with VK_EXT_swapchain_colorspace
        const all_extensions = [_][*:0]const u8{ "VK_KHR_surface", "VK_KHR_win32_surface", "VK_EXT_swapchain_colorspace" };
        const extensions = all_extensions[0..if (options.color_space == color_space_srgb_nonlinear) 2 else 3];
        var instance: ?Instance = null;
        if (create_instance(&.{ .application_info = &app, .enabled_extension_count = @intCast(extensions.len), .enabled_extension_names = extensions.ptr }, null, &instance) < 0) {
            return if (extensions.len == 3) error.UnsupportedColorSpace else error.VulkanCallFailed;
        }
        const fns = loadFns(InstanceFns, instanceProc, instance) catch |err| {
            if (instanceProc(fn (Instance, Alloc) callconv(.winapi) void, instance, "vkDestroyInstance")) |destroy_instance| destroy_instance(instance.?, null);
            return err;
        };
        errdefer fns.vkDestroyInstance(instance.?, null);

        var surface: SurfaceKHR = null_handle;
        try check(fns.vkCreateWin32SurfaceKHR(instance.?, &.{ .hwnd = hwnd }, null, &surface));
        errdefer fns.vkDestroySurfaceKHR(instance.?, surface, null);

        // A GPU with a graphics family that can present to the window
        var devices: [max_gpus]PhysicalDevice = undefined;
        var count: u32 = devices.len;
        try check(fns.vkEnumeratePhysicalDevices(instance.?, &count, &devices));
        const picked: struct { gpu: PhysicalDevice, family: u32 } = for (devices[0..count]) |gpu| {
            const family = graphicsFamily(fns, gpu) orelse continue;
            var supported: Bool32 = 0;
            if (fns.vkGetPhysicalDeviceSurfaceSupportKHR(gpu, family, surface, &supported) >= 0 and supported != 0) break .{ .gpu = gpu, .family = family };
        } else return error.NoVulkanDevice;

        const priority: f32 = 1;
        const queue_info: DeviceQueueCreateInfo = .{ .queue_family_index = picked.family, .queue_priorities = @ptrCast(&priority) };
        const device_extensions = [_][*:0]const u8{"VK_KHR_swapchain"};
        var device: ?Device = null;
        try check(fns.vkCreateDevice(picked.gpu, &.{ .queue_create_infos = @ptrCast(&queue_info), .enabled_extension_count = device_extensions.len, .enabled_extension_names = &device_extensions }, null, &device));
        const dfns = loadFns(DeviceFns, deviceProc, device.?) catch |err| {
            if (deviceProc(fn (Device, Alloc) callconv(.winapi) void, device.?, "vkDestroyDevice")) |destroy_device| destroy_device(device.?, null);
            return err;
        };
        errdefer dfns.vkDestroyDevice(device.?, null);
        var queue: ?Queue = null;
        dfns.vkGetDeviceQueue(device.?, picked.family, 0, &queue);

        const self = try std.heap.page_allocator.create(OwnedSwapchain);
        errdefer std.heap.page_allocator.destroy(self);
        self.* = .{
            .hwnd = hwnd,
            .owns_window = false,
            .instance = instance.?,
            .fns = fns,
            .gpu = picked.gpu,
            .family = picked.family,
            .surface = surface,
            .device = device.?,
            .dfns = dfns,
            .queue = queue.?,
            .color_space = options.color_space,
        };
        errdefer self.destroyObjects();
        try check(dfns.vkCreateSemaphore(self.device, &.{}, null, &self.acquired));
        try check(dfns.vkCreateSemaphore(self.device, &.{}, null, &self.drawn));
        try check(dfns.vkCreateFence(self.device, &.{ .flags = fence_create_signaled_bit }, null, &self.fence));
        try check(dfns.vkCreateCommandPool(self.device, &.{ .flags = command_pool_reset_command_buffer_bit, .queue_family_index = self.family }, null, &self.pool));
        var command_buffer: [1]CommandBuffer = undefined;
        try check(dfns.vkAllocateCommandBuffers(self.device, &.{ .command_pool = self.pool }, &command_buffer));
        self.command_buffer = command_buffer[0];
        try self.makeSwapchain();
        self.remakes = 0;
        return self;
    }

    pub fn makeSwapchain(self: *OwnedSwapchain) !void {
        _ = self.dfns.vkDeviceWaitIdle(self.device);
        var caps: SurfaceCapabilitiesKHR = .{};
        try check(self.fns.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(self.gpu, self.surface, &caps));
        var extent = caps.current_extent;
        if (extent.width == 0xffff_ffff) extent = .{ .width = 64, .height = 64 };
        if (extent.width == 0 or extent.height == 0) return error.ZeroSizedWindow;

        var formats: [32]SurfaceFormatKHR = undefined;
        var format_count: u32 = formats.len;
        _ = self.fns.vkGetPhysicalDeviceSurfaceFormatsKHR(self.gpu, self.surface, &format_count, &formats);
        if (format_count == 0) return error.NoSurfaceFormat;
        var format: ?SurfaceFormatKHR = null;
        for (formats[0..format_count]) |f| {
            if (f.color_space != self.color_space) continue;
            if (format == null or f.format == format_b8g8r8a8_unorm or f.format == format_r16g16b16a16_sfloat) format = f;
        }
        const chosen = format orelse return error.UnsupportedColorSpace;

        var min_images = @max(caps.min_image_count, 2);
        if (caps.max_image_count != 0) min_images = @min(min_images, caps.max_image_count);
        const old = self.swapchain;
        var swapchain: SwapchainKHR = null_handle;
        try check(self.dfns.vkCreateSwapchainKHR(self.device, &.{
            .surface = self.surface,
            .min_image_count = min_images,
            .image_format = chosen.format,
            .image_color_space = chosen.color_space,
            .image_extent = extent,
            .image_usage = image_usage_color_attachment_bit,
            .pre_transform = caps.current_transform,
            .composite_alpha = composite_alpha_opaque_bit,
            .present_mode = present_mode_fifo,
            .old_swapchain = old,
        }, null, &swapchain));
        if (old != null_handle) self.dfns.vkDestroySwapchainKHR(self.device, old, null);
        self.swapchain = swapchain;
        self.format = chosen;
        self.extent = extent;
        var count: u32 = max_images;
        try check(self.dfns.vkGetSwapchainImagesKHR(self.device, swapchain, &count, &self.images));
        self.image_count = count;
        self.remakes += 1;
    }

    /// Remakes the swapchain when it's out of date, like a game has to.
    pub fn present(self: *OwnedSwapchain) !Result {
        const d = self.dfns;
        try check(d.vkWaitForFences(self.device, 1, @ptrCast(&self.fence), 1, std.math.maxInt(u64)));
        var index: u32 = 0;
        const acquired = d.vkAcquireNextImageKHR(self.device, self.swapchain, std.math.maxInt(u64), self.acquired, null_handle, &index);
        if (acquired == error_out_of_date) {
            try self.makeSwapchain();
            return acquired;
        }
        try check(acquired);
        try check(d.vkResetFences(self.device, 1, @ptrCast(&self.fence)));

        try check(d.vkBeginCommandBuffer(self.command_buffer, &.{ .flags = command_buffer_usage_one_time_submit_bit }));
        const barrier: ImageMemoryBarrier = .{ .old_layout = image_layout_undefined, .new_layout = image_layout_present_src, .image = self.images[index] };
        d.vkCmdPipelineBarrier(self.command_buffer, pipeline_stage_color_attachment_output_bit, pipeline_stage_bottom_of_pipe_bit, 0, 0, null, 0, null, 1, @ptrCast(&barrier));
        try check(d.vkEndCommandBuffer(self.command_buffer));
        const wait_stage: u32 = pipeline_stage_color_attachment_output_bit;
        const submit: SubmitInfo = .{
            .wait_semaphore_count = 1,
            .wait_semaphores = @ptrCast(&self.acquired),
            .wait_dst_stage_mask = @ptrCast(&wait_stage),
            .command_buffer_count = 1,
            .command_buffers = @ptrCast(&self.command_buffer),
            .signal_semaphore_count = 1,
            .signal_semaphores = @ptrCast(&self.drawn),
        };
        try check(d.vkQueueSubmit(self.queue, 1, @ptrCast(&submit), self.fence));

        const result = d.vkQueuePresentKHR(self.queue, &.{
            .wait_semaphore_count = 1,
            .wait_semaphores = @ptrCast(&self.drawn),
            .swapchain_count = 1,
            .swapchains = @ptrCast(&self.swapchain),
            .image_indices = @ptrCast(&index),
        });
        if (result == error_out_of_date or result == suboptimal) try self.makeSwapchain() else try check(result);
        return result;
    }

    pub fn waitIdle(self: *OwnedSwapchain) void {
        _ = self.dfns.vkDeviceWaitIdle(self.device);
    }

    fn destroyObjects(self: *OwnedSwapchain) void {
        const d = self.dfns;
        _ = d.vkDeviceWaitIdle(self.device);
        if (self.swapchain != null_handle) d.vkDestroySwapchainKHR(self.device, self.swapchain, null);
        if (self.pool != null_handle) d.vkDestroyCommandPool(self.device, self.pool, null);
        if (self.fence != null_handle) d.vkDestroyFence(self.device, self.fence, null);
        if (self.drawn != null_handle) d.vkDestroySemaphore(self.device, self.drawn, null);
        if (self.acquired != null_handle) d.vkDestroySemaphore(self.device, self.acquired, null);
        self.swapchain = null_handle;
        self.pool = null_handle;
        self.fence = null_handle;
        self.drawn = null_handle;
        self.acquired = null_handle;
    }

    pub fn destroy(self: *OwnedSwapchain) void {
        self.destroyObjects();
        self.dfns.vkDestroyDevice(self.device, null);
        self.fns.vkDestroySurfaceKHR(self.instance, self.surface, null);
        self.fns.vkDestroyInstance(self.instance, null);
        if (self.owns_window) tuft_window.destroy(self.hwnd);
        std.heap.page_allocator.destroy(self);
    }

    /// Like a frame listener, for testing `Swapchain.signal`. Destroy the semaphore once the GPU's done.
    pub fn signalAfter(self: *OwnedSwapchain, wait: []const Semaphore) !Semaphore {
        var semaphore: Semaphore = null_handle;
        try check(self.dfns.vkCreateSemaphore(self.device, &.{}, null, &semaphore));
        var stages: [8]u32 = @splat(pipeline_stage_color_attachment_output_bit);
        const submit: SubmitInfo = .{
            .wait_semaphore_count = @intCast(wait.len),
            .wait_semaphores = wait.ptr,
            .wait_dst_stage_mask = &stages,
            .signal_semaphore_count = 1,
            .signal_semaphores = @ptrCast(&semaphore),
        };
        try check(self.dfns.vkQueueSubmit(self.queue, 1, @ptrCast(&submit), null_handle));
        return semaphore;
    }

    pub fn destroySemaphore(self: *OwnedSwapchain, semaphore: Semaphore) void {
        self.dfns.vkDestroySemaphore(self.device, semaphore, null);
    }
};

const tests = struct {
    const testing = std.testing;

    /// Skips without Vulkan or a GPU, like on CI.
    fn ownedOrSkip() !*OwnedSwapchain {
        return OwnedSwapchain.create(.{}) catch |err| switch (err) {
            error.NoVulkan, error.NoVulkanDevice, error.VulkanCallFailed, error.MissingVulkanFunction, error.UnsupportedColorSpace => error.SkipZigTest,
            else => err,
        };
    }

    const Recorder = struct {
        attaches: u32 = 0,
        frames: u32 = 0,
        detaches: u32 = 0,
        presents: u32 = 0,
        last: ?gfx.Frame = null,
        /// Submit work each frame like a renderer.
        game: ?*OwnedSwapchain = null,
        signals: [16]Semaphore = undefined,
        signal_count: usize = 0,

        pub fn onAttach(self: *Recorder, f: *const gfx.Frame) void {
            self.attaches += 1;
            self.last = f.*;
        }
        pub fn onFrame(self: *Recorder, f: *const gfx.Frame) void {
            self.frames += 1;
            self.last = f.*;
            const game = self.game orelse return;
            const s = fromFrame(f).?.swapchain;
            const semaphore = game.signalAfter(s.wait_semaphores) catch return;
            s.signal = semaphore;
            self.signals[self.signal_count] = semaphore;
            self.signal_count += 1;
        }
        pub fn onResize(_: *Recorder, _: *const gfx.Frame) void {}
        pub fn onDetach(self: *Recorder, _: *const gfx.Frame) void {
            self.detaches += 1;
        }
        pub fn onPresented(self: *Recorder) void {
            self.presents += 1;
        }

        fn deinit(self: *Recorder) void {
            const game = self.game orelse return;
            game.waitIdle();
            for (self.signals[0..self.signal_count]) |s| game.destroySemaphore(s);
        }
    };

    fn quiet() std.log.Level {
        const saved = testing.log_level;
        testing.log_level = .err;
        return saved;
    }

    test "probe finds swapchain functions" {
        const game = try ownedOrSkip();
        defer game.destroy();
        var probe = try Probe.create();
        defer probe.destroy();
        try testing.expect(probe.gpu_count > 0);
        try testing.expect(probe.present.len > 0);
        try testing.expect(std.mem.indexOfScalar(usize, probe.present.slice(), @intFromPtr(game.dfns.vkQueuePresentKHR)) != null);
        try testing.expect(std.mem.indexOfScalar(usize, probe.create_swapchain.slice(), @intFromPtr(game.dfns.vkCreateSwapchainKHR)) != null);

        // Our handle for the game's GPU
        const gpu = probe.gpuFor(game.device);
        var game_props: [physical_device_properties_size]u8 align(8) = undefined;
        var ours_props: [physical_device_properties_size]u8 align(8) = undefined;
        game.fns.vkGetPhysicalDeviceProperties(game.gpu, &game_props);
        probe.fns.vkGetPhysicalDeviceProperties(gpu.device, &ours_props);
        const a: *const PhysicalDevicePropertiesHead = @ptrCast(&game_props);
        const b: *const PhysicalDevicePropertiesHead = @ptrCast(&ours_props);
        try testing.expectEqual(a.vendor_id, b.vendor_id);
        try testing.expectEqual(a.device_id, b.device_id);
    }

    test "late swapchain is remade" {
        const saved = quiet();
        defer testing.log_level = saved;
        try hook.init(testing.allocator);
        defer hook.deinit();

        const game = try ownedOrSkip();
        defer game.destroy();
        _ = try game.present(); // before we're hooked

        var recorder: Recorder = .{ .game = game };
        defer recorder.deinit();
        const present = try PresentHook.create(testing.allocator, .of(Recorder, &recorder));
        defer present.destroy();
        try present.enable();

        // Unknown format, so we say it's out of date and the game remakes it
        try testing.expectEqual(error_out_of_date, try game.present());
        try testing.expectEqual(1, game.remakes);
        try testing.expectEqual(0, recorder.attaches);
        try testing.expectEqual(1, recorder.presents);

        try testing.expectEqual(success, try game.present());
        try testing.expectEqual(success, try game.present());
        try testing.expectEqual(1, recorder.attaches);
        try testing.expectEqual(2, recorder.frames);
        const frame = recorder.last.?;
        try testing.expectEqual(gfx.Api.vulkan, frame.api);
        try testing.expectEqual(@as(*anyopaque, game.hwnd), frame.window);
        try testing.expectEqual(@as(*anyopaque, game.device), frame.device);
        try testing.expectEqual(@as(?*anyopaque, game.queue), frame.queue);
        const s = fromFrame(&frame).?.swapchain;
        try testing.expectEqual(game.swapchain, s.handle);
        try testing.expectEqual(game.format.format, s.format);
        try testing.expectEqual(game.extent, s.extent);
        try testing.expectEqual(game.image_count, s.image_count);
        try testing.expectEqual(1, s.wait_semaphores.len);
        try testing.expectEqual(gfx.ColorSpace.srgb, frame.color_space);
        // The game's instance and GPU, learnt while it remade the swapchain
        try testing.expect(s.games_instance);
        try testing.expectEqual(@as(?Instance, game.instance), s.instance);
        try testing.expectEqual(@as(?PhysicalDevice, game.gpu), s.physical_device);
    }

    test "loader records name instance" {
        const game = try ownedOrSkip();
        defer game.destroy();
        try testing.expectEqual(@as(?Instance, game.instance), loaderInstanceOf(game.gpu));
        // Anything else doesn't count
        var not_a_gpu: [4]u64 align(8) = @splat(0);
        try testing.expectEqual(null, loaderInstanceOf(@ptrCast(&not_a_gpu)));
    }

    test "HDR frames say so" {
        const saved = quiet();
        defer testing.log_level = saved;
        try hook.init(testing.allocator);
        defer hook.deinit();
        _ = load() catch return error.SkipZigTest;
        var recorder: Recorder = .{};
        const present = PresentHook.create(testing.allocator, .of(Recorder, &recorder)) catch |err| switch (err) {
            error.NoVulkan, error.NoVulkanDevice => return error.SkipZigTest,
            else => return err,
        };
        defer present.destroy();
        try present.enable();

        const game = OwnedSwapchain.create(.{ .color_space = color_space_extended_srgb_linear }) catch |err| switch (err) {
            error.NoVulkan, error.NoVulkanDevice, error.VulkanCallFailed, error.MissingVulkanFunction, error.UnsupportedColorSpace => return error.SkipZigTest,
            else => return err,
        };
        defer game.destroy();
        try testing.expectEqual(success, try game.present());
        try testing.expectEqual(gfx.ColorSpace.scrgb, recorder.last.?.color_space);
    }

    test "hooked swapchain reported" {
        const saved = quiet();
        defer testing.log_level = saved;
        try hook.init(testing.allocator);
        defer hook.deinit();

        // The path only hooks games that loaded Vulkan, so load it like a game would
        _ = load() catch return error.SkipZigTest;
        var recorder: Recorder = .{};
        const present = PresentHook.create(testing.allocator, .of(Recorder, &recorder)) catch |err| switch (err) {
            error.NoVulkan, error.NoVulkanDevice => return error.SkipZigTest,
            else => return err,
        };
        defer present.destroy();
        try present.enable();

        const game = try ownedOrSkip();
        defer game.destroy();
        try testing.expectEqual(success, try game.present());
        try testing.expectEqual(1, recorder.attaches);
        try testing.expectEqual(1, recorder.frames);
        try testing.expectEqual(0, game.remakes);

        // New swapchain, like on a resize. The old one goes and the new one gets picked up
        try game.makeSwapchain();
        try testing.expectEqual(1, recorder.detaches);
        try testing.expectEqual(success, try game.present());
        try testing.expectEqual(2, recorder.attaches);
        try testing.expectEqual(game.swapchain, fromFrame(&recorder.last.?).?.swapchain.handle);
    }
};

test {
    _ = tests;
}
