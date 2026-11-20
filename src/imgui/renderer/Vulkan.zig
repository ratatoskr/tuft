//! ImGui's Vulkan backend. Draws into the game's swapchain image right before its present.
//! Everything we make goes with the swapchain, since the game might destroy its device next.

const Vulkan = @This();

const std = @import("std");

const gfx = @import("tuft_gfx");

const c = @import("../root.zig").c;

const vulkan = gfx.vulkan;
const Frame = gfx.Frame;
const hdr = @import("hdr.zig");
const capture = @import("../capture.zig");
const log = std.log.scoped(.tuft_imgui);

/// Drivers reject surfaces from other instances with the game's device.
pub fn viewportsFor(frame: *const Frame) bool {
    const native = vulkan.fromFrame(frame) orelse return false;
    return native.swapchain.games_instance;
}

const max_images = 16;

state: *State,

fn Pfn(comptime P: type) type {
    return @typeInfo(@typeInfo(P).optional.child).pointer.child;
}

/// Loaded the way the game's calls reach them.
const Fns = struct {
    vkCreateRenderPass: *const Pfn(c.PFN_vkCreateRenderPass),
    vkDestroyRenderPass: *const Pfn(c.PFN_vkDestroyRenderPass),
    vkCreateImageView: *const Pfn(c.PFN_vkCreateImageView),
    vkDestroyImageView: *const Pfn(c.PFN_vkDestroyImageView),
    vkCreateFramebuffer: *const Pfn(c.PFN_vkCreateFramebuffer),
    vkDestroyFramebuffer: *const Pfn(c.PFN_vkDestroyFramebuffer),
    vkCreateCommandPool: *const Pfn(c.PFN_vkCreateCommandPool),
    vkDestroyCommandPool: *const Pfn(c.PFN_vkDestroyCommandPool),
    vkAllocateCommandBuffers: *const Pfn(c.PFN_vkAllocateCommandBuffers),
    vkCreateFence: *const Pfn(c.PFN_vkCreateFence),
    vkDestroyFence: *const Pfn(c.PFN_vkDestroyFence),
    vkWaitForFences: *const Pfn(c.PFN_vkWaitForFences),
    vkResetFences: *const Pfn(c.PFN_vkResetFences),
    vkCreateSemaphore: *const Pfn(c.PFN_vkCreateSemaphore),
    vkDestroySemaphore: *const Pfn(c.PFN_vkDestroySemaphore),
    vkBeginCommandBuffer: *const Pfn(c.PFN_vkBeginCommandBuffer),
    vkEndCommandBuffer: *const Pfn(c.PFN_vkEndCommandBuffer),
    vkCmdBeginRenderPass: *const Pfn(c.PFN_vkCmdBeginRenderPass),
    vkCmdEndRenderPass: *const Pfn(c.PFN_vkCmdEndRenderPass),
    vkQueueSubmit: *const Pfn(c.PFN_vkQueueSubmit),
    vkDeviceWaitIdle: *const Pfn(c.PFN_vkDeviceWaitIdle),
    vkCreateShaderModule: *const Pfn(c.PFN_vkCreateShaderModule),
    vkDestroyShaderModule: *const Pfn(c.PFN_vkDestroyShaderModule),
    vkCreateGraphicsPipelines: *const Pfn(c.PFN_vkCreateGraphicsPipelines),
    vkDestroyPipeline: *const Pfn(c.PFN_vkDestroyPipeline),
    vkCmdBindPipeline: *const Pfn(c.PFN_vkCmdBindPipeline),
    vkCreateBuffer: *const Pfn(c.PFN_vkCreateBuffer),
    vkDestroyBuffer: *const Pfn(c.PFN_vkDestroyBuffer),
    vkGetBufferMemoryRequirements: *const Pfn(c.PFN_vkGetBufferMemoryRequirements),
    vkAllocateMemory: *const Pfn(c.PFN_vkAllocateMemory),
    vkFreeMemory: *const Pfn(c.PFN_vkFreeMemory),
    vkBindBufferMemory: *const Pfn(c.PFN_vkBindBufferMemory),
    vkMapMemory: *const Pfn(c.PFN_vkMapMemory),
    vkInvalidateMappedMemoryRanges: *const Pfn(c.PFN_vkInvalidateMappedMemoryRanges),
    vkGetFenceStatus: *const Pfn(c.PFN_vkGetFenceStatus),
    vkCmdPipelineBarrier: *const Pfn(c.PFN_vkCmdPipelineBarrier),
    vkCmdCopyImageToBuffer: *const Pfn(c.PFN_vkCmdCopyImageToBuffer),

    fn load(device: vulkan.Device) ?Fns {
        var fns: Fns = undefined;
        const info = @typeInfo(Fns).@"struct";
        inline for (info.field_names, info.field_types) |name, Field| {
            @field(fns, name) = vulkan.deviceProc(@typeInfo(Field).pointer.child, device, name) orelse return null;
        }
        return fns;
    }
};

/// Non-dispatchable handles are pointers in 64-bit headers and integers in 32-bit ones.
fn handle(comptime T: type, value: u64) T {
    return switch (@typeInfo(T)) {
        .optional => @ptrFromInt(@as(usize, @intCast(value))),
        .int => value,
        else => @compileError("not a Vulkan handle: " ++ @typeName(T)),
    };
}

fn raw(h: anytype) u64 {
    return switch (@typeInfo(@TypeOf(h))) {
        .optional => if (h) |p| @intFromPtr(p) else 0,
        .int => h,
        else => @compileError("not a Vulkan handle: " ++ @typeName(@TypeOf(h))),
    };
}

fn isNull(h: anytype) bool {
    return raw(h) == 0;
}

fn ok(result: c.VkResult) bool {
    return result >= 0;
}

const State = struct {
    device: vulkan.Device,
    instance: vulkan.Instance,
    physical_device: vulkan.PhysicalDevice,
    queue_family: u32,
    format: u32,
    fns: Fns,
    /// HDR pipeline made on first use.
    output: hdr.Output = .{},
    hdr_pipeline: c.VkPipeline = std.mem.zeroes(c.VkPipeline),

    /// Null means not set up.
    owner: ?*vulkan.Swapchain = null,
    render_pass: c.VkRenderPass = std.mem.zeroes(c.VkRenderPass),
    imgui: bool = false,
    extent: vulkan.Extent2D = .{},
    pool: c.VkCommandPool = std.mem.zeroes(c.VkCommandPool),
    count: u32 = 0,
    images: [max_images]c.VkImage = undefined,
    views: [max_images]c.VkImageView = undefined,
    framebuffers: [max_images]c.VkFramebuffer = undefined,
    command_buffers: [max_images]c.VkCommandBuffer = undefined,
    fences: [max_images]c.VkFence = undefined,
    /// Its present waits on it.
    drawn: [max_images]c.VkSemaphore = undefined,
    pending: [max_images]bool = @splat(false),
    /// The swapchain's images can be copied out of.
    copyable: bool = false,
    copies: [2]Copy = @splat(.{}),

    fn cDevice(self: *const State) c.VkDevice {
        return @ptrCast(self.device);
    }

    fn createRenderPass(self: *State) !void {
        var attachment = std.mem.zeroes(c.VkAttachmentDescription);
        attachment.format = @intCast(self.format);
        attachment.samples = c.VK_SAMPLE_COUNT_1_BIT;
        attachment.loadOp = c.VK_ATTACHMENT_LOAD_OP_LOAD;
        attachment.storeOp = c.VK_ATTACHMENT_STORE_OP_STORE;
        attachment.stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE;
        attachment.stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE;
        attachment.initialLayout = c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
        attachment.finalLayout = c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
        const reference: c.VkAttachmentReference = .{ .attachment = 0, .layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };
        var subpass = std.mem.zeroes(c.VkSubpassDescription);
        subpass.pipelineBindPoint = c.VK_PIPELINE_BIND_POINT_GRAPHICS;
        subpass.colorAttachmentCount = 1;
        subpass.pColorAttachments = &reference;
        var dependency = std.mem.zeroes(c.VkSubpassDependency);
        dependency.srcSubpass = c.VK_SUBPASS_EXTERNAL;
        dependency.dstSubpass = 0;
        dependency.srcStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
        dependency.dstStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
        dependency.dstAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_READ_BIT | c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
        var info = std.mem.zeroes(c.VkRenderPassCreateInfo);
        info.sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO;
        info.attachmentCount = 1;
        info.pAttachments = &attachment;
        info.subpassCount = 1;
        info.pSubpasses = &subpass;
        info.dependencyCount = 1;
        info.pDependencies = &dependency;
        if (!ok(self.fns.vkCreateRenderPass(self.cDevice(), &info, null, &self.render_pass))) return error.VulkanCallFailed;
    }

    fn setUp(self: *State, swapchain: *vulkan.Swapchain, queue: vulkan.Queue) !void {
        errdefer self.tearDown();
        const f = self.fns;
        const device = self.cDevice();
        var images_raw: [max_images]vulkan.Image = undefined;
        const images = try swapchain.images(&images_raw);
        self.owner = swapchain;
        self.extent = swapchain.extent;
        self.format = swapchain.format;
        self.copyable = swapchain.copyable;
        try self.createRenderPass();

        var pool_info = std.mem.zeroes(c.VkCommandPoolCreateInfo);
        pool_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
        pool_info.flags = c.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
        pool_info.queueFamilyIndex = self.queue_family;
        if (!ok(f.vkCreateCommandPool(device, &pool_info, null, &self.pool))) return error.VulkanCallFailed;

        for (images, 0..) |image, i| {
            var view_info = std.mem.zeroes(c.VkImageViewCreateInfo);
            view_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
            view_info.image = handle(c.VkImage, image);
            view_info.viewType = c.VK_IMAGE_VIEW_TYPE_2D;
            view_info.format = @intCast(self.format);
            view_info.subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 };
            var view = std.mem.zeroes(c.VkImageView);
            if (!ok(f.vkCreateImageView(device, &view_info, null, &view))) return error.VulkanCallFailed;
            self.views[i] = view;
            self.images[i] = view_info.image;

            var fb_info = std.mem.zeroes(c.VkFramebufferCreateInfo);
            fb_info.sType = c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
            fb_info.renderPass = self.render_pass;
            fb_info.attachmentCount = 1;
            fb_info.pAttachments = &self.views[i];
            fb_info.width = self.extent.width;
            fb_info.height = self.extent.height;
            fb_info.layers = 1;
            var framebuffer = std.mem.zeroes(c.VkFramebuffer);
            if (!ok(f.vkCreateFramebuffer(device, &fb_info, null, &framebuffer))) {
                f.vkDestroyImageView(device, view, null);
                return error.VulkanCallFailed;
            }
            self.framebuffers[i] = framebuffer;

            var fence_info = std.mem.zeroes(c.VkFenceCreateInfo);
            fence_info.sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
            var fence = std.mem.zeroes(c.VkFence);
            var semaphore_info = std.mem.zeroes(c.VkSemaphoreCreateInfo);
            semaphore_info.sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
            var semaphore = std.mem.zeroes(c.VkSemaphore);
            var alloc_info = std.mem.zeroes(c.VkCommandBufferAllocateInfo);
            alloc_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
            alloc_info.commandPool = self.pool;
            alloc_info.level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY;
            alloc_info.commandBufferCount = 1;
            if (!ok(f.vkCreateFence(device, &fence_info, null, &fence)) or
                !ok(f.vkCreateSemaphore(device, &semaphore_info, null, &semaphore)) or
                !ok(f.vkAllocateCommandBuffers(device, &alloc_info, &self.command_buffers[i])))
            {
                if (!isNull(fence)) f.vkDestroyFence(device, fence, null);
                if (!isNull(semaphore)) f.vkDestroySemaphore(device, semaphore, null);
                f.vkDestroyFramebuffer(device, framebuffer, null);
                f.vkDestroyImageView(device, view, null);
                return error.VulkanCallFailed;
            }
            self.fences[i] = fence;
            self.drawn[i] = semaphore;
            self.pending[i] = false;
            self.count = @intCast(i + 1);
        }

        // Instance functions come from ours
        if (!c.cImGui_ImplVulkan_LoadFunctionsEx(vulkan.api_version_1_1, loadFunction, self)) return error.BackendFailed;
        var info = std.mem.zeroes(c.ImGui_ImplVulkan_InitInfo);
        info.ApiVersion = vulkan.api_version_1_1;
        info.Instance = @ptrCast(self.instance);
        info.PhysicalDevice = @ptrCast(self.physical_device);
        info.Device = device;
        info.QueueFamily = self.queue_family;
        info.Queue = @ptrCast(queue);
        info.DescriptorPoolSize = 64;
        info.CheckVkResultFn = checkResult;
        info.MinImageCount = @max(2, swapchain.min_image_count);
        info.ImageCount = @max(info.MinImageCount, self.count);
        info.PipelineInfoMain.RenderPass = self.render_pass;
        info.PipelineInfoMain.Subpass = 0;
        info.PipelineInfoMain.MSAASamples = c.VK_SAMPLE_COUNT_1_BIT;
        c.ImGui_GetPlatformIO().*.Platform_CreateVkSurface = createSurface;
        if (!c.cImGui_ImplVulkan_Init(&info)) return error.BackendFailed;
        self.imgui = true;
    }

    /// Fences aren't enough, presents waiting on our semaphores have to finish too.
    fn tearDown(self: *State) void {
        const f = self.fns;
        const device = self.cDevice();
        _ = f.vkDeviceWaitIdle(device);
        self.dropHdrPipeline();
        if (self.imgui) shutDownImGui();
        self.imgui = false;
        for (&self.copies) |*copy| copy.release(self);
        for (0..self.count) |i| {
            f.vkDestroySemaphore(device, self.drawn[i], null);
            f.vkDestroyFence(device, self.fences[i], null);
            f.vkDestroyFramebuffer(device, self.framebuffers[i], null);
            f.vkDestroyImageView(device, self.views[i], null);
        }
        if (!isNull(self.pool)) f.vkDestroyCommandPool(device, self.pool, null);
        self.pool = std.mem.zeroes(c.VkCommandPool);
        if (!isNull(self.render_pass)) f.vkDestroyRenderPass(device, self.render_pass, null);
        self.render_pass = std.mem.zeroes(c.VkRenderPass);
        self.count = 0;
        self.owner = null;
    }

    /// Host-visible, so it stays mapped.
    fn memoryType(self: *const State, bits: u32) ?struct { index: u32, coherent: bool } {
        const get = vulkan.instanceProc(Pfn(c.PFN_vkGetPhysicalDeviceMemoryProperties), self.instance, "vkGetPhysicalDeviceMemoryProperties") orelse return null;
        var props = std.mem.zeroes(c.VkPhysicalDeviceMemoryProperties);
        get(@ptrCast(self.physical_device), &props);
        var best: ?u32 = null;
        for (0..props.memoryTypeCount) |i| {
            if (bits & (@as(u32, 1) << @intCast(i)) == 0) continue;
            const flags = props.memoryTypes[i].propertyFlags;
            if (flags & c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT == 0) continue;
            // Cached reads much faster
            if (best == null or flags & c.VK_MEMORY_PROPERTY_HOST_CACHED_BIT != 0) best = @intCast(i);
            if (flags & c.VK_MEMORY_PROPERTY_HOST_CACHED_BIT != 0) break;
        }
        const index = best orelse return null;
        return .{ .index = index, .coherent = props.memoryTypes[index].propertyFlags & c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT != 0 };
    }

    /// Images go back to how presents want them after.
    fn recordCopy(self: *State, cb: c.VkCommandBuffer, image: c.VkImage, copy: *const Copy, point: capture.Point) void {
        const f = self.fns;
        const range: c.VkImageSubresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 };
        var to_copy = std.mem.zeroes(c.VkImageMemoryBarrier);
        to_copy.sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
        to_copy.srcAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
        to_copy.dstAccessMask = c.VK_ACCESS_TRANSFER_READ_BIT;
        to_copy.oldLayout = c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
        to_copy.newLayout = c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
        to_copy.srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
        to_copy.dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
        to_copy.image = image;
        to_copy.subresourceRange = range;
        // Chains onto the present's semaphores, which we wait for at this stage
        f.vkCmdPipelineBarrier(cb, c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, c.VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, null, 0, null, 1, &to_copy);

        var region = std.mem.zeroes(c.VkBufferImageCopy);
        region.imageSubresource = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .mipLevel = 0, .baseArrayLayer = 0, .layerCount = 1 };
        region.imageExtent = .{ .width = copy.width, .height = copy.height, .depth = 1 };
        f.vkCmdCopyImageToBuffer(cb, image, c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, copy.buffer, 1, &region);

        var back = to_copy;
        back.srcAccessMask = 0;
        back.oldLayout = c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
        back.newLayout = c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
        var host = std.mem.zeroes(c.VkBufferMemoryBarrier);
        host.sType = c.VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER;
        host.srcAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT;
        host.dstAccessMask = c.VK_ACCESS_HOST_READ_BIT;
        host.srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
        host.dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
        host.buffer = copy.buffer;
        host.size = c.VK_WHOLE_SIZE;
        switch (point) {
            // Our render pass draws into it next
            .before => {
                back.dstAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_READ_BIT | c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
                f.vkCmdPipelineBarrier(cb, c.VK_PIPELINE_STAGE_TRANSFER_BIT, c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | c.VK_PIPELINE_STAGE_HOST_BIT, 0, 0, null, 1, &host, 1, &back);
            },
            .after => {
                back.dstAccessMask = 0;
                f.vkCmdPipelineBarrier(cb, c.VK_PIPELINE_STAGE_TRANSFER_BIT, c.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT | c.VK_PIPELINE_STAGE_HOST_BIT, 0, 0, null, 1, &host, 1, &back);
            },
        }
    }

    fn dropHdrPipeline(self: *State) void {
        if (!isNull(self.hdr_pipeline)) self.fns.vkDestroyPipeline(self.cDevice(), self.hdr_pipeline, null);
        self.hdr_pipeline = std.mem.zeroes(c.VkPipeline);
    }

    /// ImGui's pipeline but with hdr.frag specialized for the output.
    fn hdrPipeline(self: *State, layout: c.VkPipelineLayout) c.VkPipeline {
        if (!isNull(self.hdr_pipeline)) return self.hdr_pipeline;
        const f = self.fns;
        const device = self.cDevice();
        var vert = std.mem.zeroes(c.VkShaderModule);
        var frag = std.mem.zeroes(c.VkShaderModule);
        defer if (!isNull(vert)) f.vkDestroyShaderModule(device, vert, null);
        defer if (!isNull(frag)) f.vkDestroyShaderModule(device, frag, null);
        for ([_]struct { []const u32, *c.VkShaderModule }{ .{ &hdr.vulkan_vert, &vert }, .{ &hdr.vulkan_frag, &frag } }) |shader| {
            var info = std.mem.zeroes(c.VkShaderModuleCreateInfo);
            info.sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
            info.codeSize = shader[0].len * @sizeOf(u32);
            info.pCode = shader[0].ptr;
            if (!ok(f.vkCreateShaderModule(device, &info, null, shader[1]))) return self.hdr_pipeline;
        }

        const constants = extern struct { mode: i32, white: f32 }{ .mode = self.output.mode(), .white = self.output.sdr_white_nits };
        const entries = [_]c.VkSpecializationMapEntry{
            .{ .constantID = 0, .offset = 0, .size = 4 },
            .{ .constantID = 1, .offset = 4, .size = 4 },
        };
        const specialization: c.VkSpecializationInfo = .{ .mapEntryCount = entries.len, .pMapEntries = &entries, .dataSize = @sizeOf(@TypeOf(constants)), .pData = &constants };
        var stages = std.mem.zeroes([2]c.VkPipelineShaderStageCreateInfo);
        for (&stages, [_]c.VkShaderStageFlagBits{ c.VK_SHADER_STAGE_VERTEX_BIT, c.VK_SHADER_STAGE_FRAGMENT_BIT }, [_]c.VkShaderModule{ vert, frag }) |*stage, kind, module| {
            stage.sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
            stage.stage = kind;
            stage.module = module;
            stage.pName = @ptrCast("main");
        }
        stages[1].pSpecializationInfo = &specialization;

        const binding: c.VkVertexInputBindingDescription = .{ .binding = 0, .stride = @sizeOf(c.ImDrawVert), .inputRate = c.VK_VERTEX_INPUT_RATE_VERTEX };
        const attributes = [_]c.VkVertexInputAttributeDescription{
            .{ .location = 0, .binding = 0, .format = c.VK_FORMAT_R32G32_SFLOAT, .offset = @offsetOf(c.ImDrawVert, "pos") },
            .{ .location = 1, .binding = 0, .format = c.VK_FORMAT_R32G32_SFLOAT, .offset = @offsetOf(c.ImDrawVert, "uv") },
            .{ .location = 2, .binding = 0, .format = c.VK_FORMAT_R8G8B8A8_UNORM, .offset = @offsetOf(c.ImDrawVert, "col") },
        };
        var vertex_input = std.mem.zeroes(c.VkPipelineVertexInputStateCreateInfo);
        vertex_input.sType = c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
        vertex_input.vertexBindingDescriptionCount = 1;
        vertex_input.pVertexBindingDescriptions = &binding;
        vertex_input.vertexAttributeDescriptionCount = attributes.len;
        vertex_input.pVertexAttributeDescriptions = &attributes;
        var assembly = std.mem.zeroes(c.VkPipelineInputAssemblyStateCreateInfo);
        assembly.sType = c.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
        assembly.topology = c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
        var viewport = std.mem.zeroes(c.VkPipelineViewportStateCreateInfo);
        viewport.sType = c.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO;
        viewport.viewportCount = 1;
        viewport.scissorCount = 1;
        var raster = std.mem.zeroes(c.VkPipelineRasterizationStateCreateInfo);
        raster.sType = c.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
        raster.polygonMode = c.VK_POLYGON_MODE_FILL;
        raster.cullMode = c.VK_CULL_MODE_NONE;
        raster.frontFace = c.VK_FRONT_FACE_COUNTER_CLOCKWISE;
        raster.lineWidth = 1;
        var multisample = std.mem.zeroes(c.VkPipelineMultisampleStateCreateInfo);
        multisample.sType = c.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
        multisample.rasterizationSamples = c.VK_SAMPLE_COUNT_1_BIT;
        var attachment = std.mem.zeroes(c.VkPipelineColorBlendAttachmentState);
        attachment.blendEnable = c.VK_TRUE;
        attachment.srcColorBlendFactor = c.VK_BLEND_FACTOR_SRC_ALPHA;
        attachment.dstColorBlendFactor = c.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
        attachment.colorBlendOp = c.VK_BLEND_OP_ADD;
        attachment.srcAlphaBlendFactor = c.VK_BLEND_FACTOR_ONE;
        attachment.dstAlphaBlendFactor = c.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
        attachment.alphaBlendOp = c.VK_BLEND_OP_ADD;
        attachment.colorWriteMask = c.VK_COLOR_COMPONENT_R_BIT | c.VK_COLOR_COMPONENT_G_BIT | c.VK_COLOR_COMPONENT_B_BIT | c.VK_COLOR_COMPONENT_A_BIT;
        var depth = std.mem.zeroes(c.VkPipelineDepthStencilStateCreateInfo);
        depth.sType = c.VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO;
        var blend = std.mem.zeroes(c.VkPipelineColorBlendStateCreateInfo);
        blend.sType = c.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
        blend.attachmentCount = 1;
        blend.pAttachments = &attachment;
        const dynamic_states = [_]c.VkDynamicState{ c.VK_DYNAMIC_STATE_VIEWPORT, c.VK_DYNAMIC_STATE_SCISSOR };
        var dynamic = std.mem.zeroes(c.VkPipelineDynamicStateCreateInfo);
        dynamic.sType = c.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO;
        dynamic.dynamicStateCount = dynamic_states.len;
        dynamic.pDynamicStates = &dynamic_states;

        var info = std.mem.zeroes(c.VkGraphicsPipelineCreateInfo);
        info.sType = c.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
        info.stageCount = stages.len;
        info.pStages = &stages;
        info.pVertexInputState = &vertex_input;
        info.pInputAssemblyState = &assembly;
        info.pViewportState = &viewport;
        info.pRasterizationState = &raster;
        info.pMultisampleState = &multisample;
        info.pDepthStencilState = &depth;
        info.pColorBlendState = &blend;
        info.pDynamicState = &dynamic;
        info.layout = layout;
        info.renderPass = self.render_pass;
        info.subpass = 0;
        _ = f.vkCreateGraphicsPipelines(device, std.mem.zeroes(c.VkPipelineCache), 1, &info, null, &self.hdr_pipeline);
        return self.hdr_pipeline;
    }

    /// User data is the state.
    fn bindHdrPipeline(_: [*c]const c.ImDrawList, cmd: [*c]const c.ImDrawCmd) callconv(.c) void {
        const self: *State = @ptrCast(@alignCast(cmd.*.UserCallbackData.?));
        const render_state: *const c.ImGui_ImplVulkan_RenderState = @ptrCast(@alignCast(c.ImGui_GetPlatformIO().*.Renderer_RenderState orelse return));
        const pipeline = self.hdrPipeline(render_state.PipelineLayout);
        if (!isNull(pipeline)) self.fns.vkCmdBindPipeline(render_state.CommandBuffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
    }

    fn loadFunction(c_name: [*c]const u8, user: ?*anyopaque) callconv(.c) c.PFN_vkVoidFunction {
        const self: *State = @ptrCast(@alignCast(user.?));
        const name: [*:0]const u8 = @ptrCast(c_name);
        const F = Pfn(c.PFN_vkVoidFunction);
        // Instance-level ones come from our instance
        const span = std.mem.span(name);
        const instance_level = std.mem.indexOf(u8, span, "PhysicalDevice") != null or std.mem.indexOf(u8, span, "Instance") != null or std.mem.endsWith(u8, span, "SurfaceKHR");
        if (!instance_level) {
            if (vulkan.deviceProc(F, self.device, name)) |p| return p;
        }
        return vulkan.instanceProc(F, self.instance, name);
    }
};

/// A buffer the swapchain image gets copied into on our command buffer. Stays mapped.
const Copy = struct {
    buffer: c.VkBuffer = std.mem.zeroes(c.VkBuffer),
    memory: c.VkDeviceMemory = std.mem.zeroes(c.VkDeviceMemory),
    mapped: ?[*]const u8 = null,
    size: u64 = 0,
    coherent: bool = true,
    width: u32 = 0,
    height: u32 = 0,
    format: u32 = 0,
    /// Done once this image's fence is.
    image_index: u32 = 0,
    busy: bool = false,
    color_space: gfx.ColorSpace = .srgb,

    fn release(self: *Copy, s: *const State) void {
        const device = s.cDevice();
        if (!isNull(self.buffer)) s.fns.vkDestroyBuffer(device, self.buffer, null);
        // Unmapped when freed
        if (!isNull(self.memory)) s.fns.vkFreeMemory(device, self.memory, null);
        self.* = .{};
    }

    /// Room for the swapchain's images, false if they can't be copied.
    fn prepare(self: *Copy, s: *const State) bool {
        if (!s.copyable or capture.Format.fromVulkan(s.format) == .unknown) return false;
        const size = @as(u64, s.extent.width) * s.extent.height * capture.Format.fromVulkan(s.format).bytesPerPixel();
        if (!isNull(self.buffer) and self.size == size and self.format == s.format) return true;
        self.release(s);
        const f = s.fns;
        const device = s.cDevice();
        var info = std.mem.zeroes(c.VkBufferCreateInfo);
        info.sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
        info.size = size;
        info.usage = c.VK_BUFFER_USAGE_TRANSFER_DST_BIT;
        info.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;
        if (!ok(f.vkCreateBuffer(device, &info, null, &self.buffer))) return false;
        var needs = std.mem.zeroes(c.VkMemoryRequirements);
        f.vkGetBufferMemoryRequirements(device, self.buffer, &needs);
        const kind = s.memoryType(needs.memoryTypeBits) orelse return self.fail(s);
        var alloc = std.mem.zeroes(c.VkMemoryAllocateInfo);
        alloc.sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        alloc.allocationSize = needs.size;
        alloc.memoryTypeIndex = kind.index;
        if (!ok(f.vkAllocateMemory(device, &alloc, null, &self.memory))) return self.fail(s);
        if (!ok(f.vkBindBufferMemory(device, self.buffer, self.memory, 0))) return self.fail(s);
        var data: ?*anyopaque = null;
        if (!ok(f.vkMapMemory(device, self.memory, 0, c.VK_WHOLE_SIZE, 0, &data))) return self.fail(s);
        self.mapped = @ptrCast(data);
        self.coherent = kind.coherent;
        self.size = size;
        self.format = s.format;
        self.width = s.extent.width;
        self.height = s.extent.height;
        return true;
    }

    fn fail(self: *Copy, s: *const State) bool {
        self.release(s);
        return false;
    }

    fn land(self: *Copy, s: *State, point: capture.Point, captures: *capture.Captures) void {
        const i = self.image_index;
        if (s.pending[i] and s.fns.vkGetFenceStatus(s.cDevice(), s.fences[i]) != c.VK_SUCCESS) return;
        self.busy = false;
        if (!self.coherent) {
            var range = std.mem.zeroes(c.VkMappedMemoryRange);
            range.sType = c.VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE;
            range.memory = self.memory;
            range.size = c.VK_WHOLE_SIZE;
            if (!ok(s.fns.vkInvalidateMappedMemoryRanges(s.cDevice(), 1, &range))) return captures.failed(point);
        }
        const format = capture.Format.fromVulkan(self.format);
        const pitch = self.width * format.bytesPerPixel();
        captures.done(&.{
            .point = point,
            .width = self.width,
            .height = self.height,
            .pitch = pitch,
            .format = format,
            .native_format = self.format,
            .color_space = self.color_space,
            .pixels = self.mapped.?[0..@intCast(self.size)],
        });
    }
};

pub fn poll(self: *Vulkan, _: *const Frame, captures: *capture.Captures) void {
    const s = self.state;
    for (&s.copies, 0..) |*copy, i| {
        if (captures.check(@fromBackingInt(@intCast(i)), copy.busy)) copy.land(s, @fromBackingInt(@intCast(i)), captures);
    }
}

pub fn init(frame: *const Frame) error{BackendFailed}!Vulkan {
    const native = vulkan.fromFrame(frame) orelse return error.BackendFailed;
    const s = native.swapchain;
    const fns = Fns.load(native.device) orelse return error.BackendFailed;
    const state = std.heap.page_allocator.create(State) catch return error.BackendFailed;
    errdefer std.heap.page_allocator.destroy(state);
    state.* = .{
        .device = native.device,
        .instance = s.instance orelse return error.BackendFailed,
        .physical_device = s.physical_device orelse return error.BackendFailed,
        .queue_family = s.queue_family,
        .format = s.format,
        .fns = fns,
    };
    _ = state.output.update(frame);
    state.setUp(s, native.queue) catch return error.BackendFailed;
    return .{ .state = state };
}

pub fn deinit(self: *Vulkan) void {
    const s = self.state;
    if (s.owner != null) s.tearDown();
    // Other backends' shutdowns do this, `shutDownImGui` doesn't
    c.ImGui_DestroyPlatformWindows();
    std.heap.page_allocator.destroy(s);
}

/// ImGui's `Platform_CreateVkSurface`.
fn createSurface(viewport: [*c]c.ImGuiViewport, instance: c.ImU64, _: ?*const anyopaque, out: [*c]c.ImU64) callconv(.c) c_int {
    const vk_instance: vulkan.Instance = @ptrFromInt(@as(usize, @intCast(instance)));
    const create = vulkan.instanceProc(fn (vulkan.Instance, *const vulkan.Win32SurfaceCreateInfoKHR, ?*const anyopaque, *vulkan.SurfaceKHR) callconv(.winapi) i32, vk_instance, "vkCreateWin32SurfaceKHR") orelse return c.VK_ERROR_EXTENSION_NOT_PRESENT;
    var surface: vulkan.SurfaceKHR = vulkan.null_handle;
    const result = create(vk_instance, &.{ .hwnd = @ptrCast(viewport.*.PlatformHandle.?) }, null, &surface);
    out.* = surface;
    return result;
}

/// ImGui keeps going either way.
fn checkResult(result: c.VkResult) callconv(.c) void {
    if (result < 0) log.warn("A Vulkan call of ImGui's failed: {d}", .{result});
}

/// Keeps the game window's platform data, which the real shutdown would destroy.
fn shutDownImGui() void {
    tuft_imgui_destroy_viewport_windows();
    const pio = c.ImGui_GetPlatformIO();
    const main = c.ImGui_GetMainViewport();
    const user_data = main.*.PlatformUserData;
    const platform_handle = main.*.PlatformHandle;
    const handle_raw = main.*.PlatformHandleRaw;
    const destroy_window = pio.*.Platform_DestroyWindow;
    pio.*.Platform_DestroyWindow = null;
    main.*.PlatformUserData = null;
    c.cImGui_ImplVulkan_Shutdown();
    pio.*.Platform_DestroyWindow = destroy_window;
    main.*.PlatformUserData = user_data;
    main.*.PlatformHandle = platform_handle;
    main.*.PlatformHandleRaw = handle_raw;
}

extern fn tuft_imgui_destroy_viewport_windows() void;

/// A new swapchain gets set up on its first frame.
pub fn matches(self: *const Vulkan, frame: *const Frame) bool {
    const native = vulkan.fromFrame(frame) orelse return false;
    return native.device == self.state.device;
}

pub fn beginFrame(self: *Vulkan, frame: *const Frame) bool {
    const native = vulkan.fromFrame(frame) orelse return false;
    const s = self.state;
    // New swapchain, or the HDR pipeline needs remaking
    const changed = s.output.update(frame);
    if (s.owner != native.swapchain) {
        if (s.owner != null) s.tearDown();
        s.setUp(native.swapchain, native.queue) catch return false;
    } else if (changed and !isNull(s.hdr_pipeline)) {
        _ = s.fns.vkDeviceWaitIdle(s.cDevice());
        s.dropHdrPipeline();
    }
    c.cImGui_ImplVulkan_NewFrame();
    return true;
}

/// HDR pipeline for the game window only.
pub fn drawStarted(self: *Vulkan) void {
    if (self.state.imgui and self.state.output.mode() != 0) hdr.drawFirst(State.bindHdrPipeline, self.state);
}

pub fn render(self: *Vulkan, frame: *const Frame, draw_data: *c.ImDrawData, captures: *capture.Captures) void {
    const native = vulkan.fromFrame(frame) orelse return;
    const s = self.state;
    const swapchain = native.swapchain;
    if (s.owner != swapchain) return;
    const i = swapchain.image_index;
    if (i >= s.count) return;
    const f = s.fns;
    const device = s.cDevice();

    // Wait for our last work on this image before reusing its command buffer
    if (s.pending[i]) {
        if (!ok(f.vkWaitForFences(device, 1, &s.fences[i], c.VK_TRUE, std.math.maxInt(u64)))) return;
        s.pending[i] = false;
    }
    var taking = capture.Points.empty;
    for ([_]capture.Point{ .before, .after }) |point| {
        const copy = &s.copies[@backingInt(point)];
        if (!captures.want(point) or copy.busy) continue;
        if (copy.prepare(s)) taking.insert(point) else captures.failed(point);
    }

    const cb = s.command_buffers[i];
    var begin = std.mem.zeroes(c.VkCommandBufferBeginInfo);
    begin.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    begin.flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    if (!ok(f.vkBeginCommandBuffer(cb, &begin))) return;
    if (taking.contains(.before)) s.recordCopy(cb, s.images[i], &s.copies[0], .before);
    var pass = std.mem.zeroes(c.VkRenderPassBeginInfo);
    pass.sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
    pass.renderPass = s.render_pass;
    pass.framebuffer = s.framebuffers[i];
    pass.renderArea.extent = .{ .width = s.extent.width, .height = s.extent.height };
    f.vkCmdBeginRenderPass(cb, &pass, c.VK_SUBPASS_CONTENTS_INLINE);
    c.cImGui_ImplVulkan_RenderDrawData(draw_data, cb);
    f.vkCmdEndRenderPass(cb);
    if (taking.contains(.after)) s.recordCopy(cb, s.images[i], &s.copies[1], .after);
    if (!ok(f.vkEndCommandBuffer(cb))) return;

    // Run after whatever the present was waiting on. The present waits on us instead
    var waits: [max_images]c.VkSemaphore = undefined;
    var stages: [max_images]c.VkPipelineStageFlags = undefined;
    const wait_count = @min(swapchain.wait_semaphores.len, waits.len);
    for (swapchain.wait_semaphores[0..wait_count], 0..) |w, n| {
        waits[n] = handle(c.VkSemaphore, w);
        stages[n] = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    }
    var submit = std.mem.zeroes(c.VkSubmitInfo);
    submit.sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO;
    submit.waitSemaphoreCount = @intCast(wait_count);
    submit.pWaitSemaphores = &waits;
    submit.pWaitDstStageMask = &stages;
    submit.commandBufferCount = 1;
    submit.pCommandBuffers = &cb;
    submit.signalSemaphoreCount = 1;
    submit.pSignalSemaphores = &s.drawn[i];
    if (!ok(f.vkResetFences(device, 1, &s.fences[i]))) return;
    if (!ok(f.vkQueueSubmit(@ptrCast(native.queue), 1, &submit, s.fences[i]))) {
        // Nothing in flight. The fence isn't waited on until it's submitted again
        return;
    }
    s.pending[i] = true;
    swapchain.signal = raw(s.drawn[i]);
    var it = taking.iterator();
    while (it.next()) |point| {
        const copy = &s.copies[@backingInt(point)];
        copy.busy = true;
        copy.image_index = i;
        copy.color_space = frame.color_space;
        captures.started(point);
    }
}

pub fn renderPlatformWindows(self: *Vulkan, _: *const Frame) void {
    if (self.state.imgui) c.ImGui_RenderPlatformWindowsDefault();
}

/// Before its swapchain goes. Waits for our work and frees everything we made.
pub fn releaseTarget(self: *Vulkan) void {
    if (self.state.owner != null) self.state.tearDown();
}
