//! Checks the hand-written Vulkan structs against the official headers.

const std = @import("std");

const vulkan = @import("tuft_gfx").vulkan;
const vk = @import("vk");

fn expectSameLayout(comptime Ours: type, comptime Theirs: type) !void {
    try std.testing.expectEqual(@sizeOf(Theirs), @sizeOf(Ours));
    const ours = @typeInfo(Ours).@"struct".field_names;
    const theirs = @typeInfo(Theirs).@"struct".field_names;
    try std.testing.expectEqual(theirs.len, ours.len);
    inline for (ours, theirs) |a, b| {
        std.testing.expectEqual(@offsetOf(Theirs, b), @offsetOf(Ours, a)) catch |err| {
            std.debug.print("{s}.{s} is at {d}, but {s}.{s} at {d}\n", .{ @typeName(Ours), a, @offsetOf(Ours, a), @typeName(Theirs), b, @offsetOf(Theirs, b) });
            return err;
        };
    }
}

test "Vulkan structs match headers" {
    try expectSameLayout(vulkan.Extent2D, vk.VkExtent2D);
    try expectSameLayout(vulkan.Extent3D, vk.VkExtent3D);
    try expectSameLayout(vulkan.ApplicationInfo, vk.VkApplicationInfo);
    try expectSameLayout(vulkan.InstanceCreateInfo, vk.VkInstanceCreateInfo);
    try expectSameLayout(vulkan.DeviceQueueCreateInfo, vk.VkDeviceQueueCreateInfo);
    try expectSameLayout(vulkan.DeviceCreateInfo, vk.VkDeviceCreateInfo);
    try expectSameLayout(vulkan.QueueFamilyProperties, vk.VkQueueFamilyProperties);
    try expectSameLayout(vulkan.SurfaceCapabilitiesKHR, vk.VkSurfaceCapabilitiesKHR);
    try expectSameLayout(vulkan.SurfaceFormatKHR, vk.VkSurfaceFormatKHR);
    try expectSameLayout(vulkan.SwapchainCreateInfoKHR, vk.VkSwapchainCreateInfoKHR);
    try expectSameLayout(vulkan.PresentInfoKHR, vk.VkPresentInfoKHR);
    try expectSameLayout(vulkan.AcquireNextImageInfoKHR, vk.VkAcquireNextImageInfoKHR);
    try expectSameLayout(vulkan.SubmitInfo, vk.VkSubmitInfo);
    try expectSameLayout(vulkan.SemaphoreCreateInfo, vk.VkSemaphoreCreateInfo);
    try expectSameLayout(vulkan.FenceCreateInfo, vk.VkFenceCreateInfo);
    try expectSameLayout(vulkan.CommandPoolCreateInfo, vk.VkCommandPoolCreateInfo);
    try expectSameLayout(vulkan.CommandBufferAllocateInfo, vk.VkCommandBufferAllocateInfo);
    try expectSameLayout(vulkan.CommandBufferBeginInfo, vk.VkCommandBufferBeginInfo);
    try expectSameLayout(vulkan.ImageSubresourceRange, vk.VkImageSubresourceRange);
    try expectSameLayout(vulkan.ImageMemoryBarrier, vk.VkImageMemoryBarrier);

    // Start of VkPhysicalDeviceProperties
    const P = vk.VkPhysicalDeviceProperties;
    const H = vulkan.PhysicalDevicePropertiesHead;
    try std.testing.expectEqual(@offsetOf(P, "deviceType"), @offsetOf(H, "device_type"));
    try std.testing.expectEqual(@offsetOf(P, "deviceName"), @offsetOf(H, "device_name"));
    try std.testing.expect(@sizeOf(P) <= 1024);

    // Non-dispatchable handles are 64-bit everywhere
    try std.testing.expectEqual(@sizeOf(vk.VkSwapchainKHR), @sizeOf(vulkan.SwapchainKHR));
    try std.testing.expectEqual(@sizeOf(vk.VkSemaphore), @sizeOf(vulkan.Semaphore));
}
