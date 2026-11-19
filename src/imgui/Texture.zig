//! RGBA8 pixels ImGui can draw, in whichever contexts draw them. Each context gets its own
//! `ImTextureData` the first time it draws it, and the backend uploads it from there, so it works
//! the same on every graphics API.
//!
//! `destroy` is fine from any thread. Each context then lets its copy go at the start of its next
//! frame. It asks the backend to destroy it, which can take a frame, then unregisters and frees it.
//! A context that shuts down first lets all of its copies go right away. The pixels are freed once
//! no context has a copy left.

const Texture = @This();

const std = @import("std");

const c = @import("tuft_imgui_c");
const sync = @import("tuft_sys").sync;
const ui = @import("tuft_ui");

allocator: std.mem.Allocator,
width: u32,
height: u32,
/// RGBA, rows packed. Backends read it whenever they make a copy.
pixels: []u8,
/// Under `lock`.
dead: bool = false,
/// Under `lock`. One per context that's drawn it.
copies: std.ArrayList(Copy) = .empty,

const Copy = struct {
    context: *c.ImGuiContext,
    data: *c.ImTextureData,
};

/// Bigger won't fit in a texture on most GPUs.
pub const max_side = 16384;

var lock: sync.RwLock = .{};
/// Under `lock`. Every texture with copies.
var live: std.ArrayList(*Texture) = .empty;
/// Under `lock`. Contexts with our hooks in.
var hooked: std.ArrayList(*c.ImGuiContext) = .empty;
const lists = std.heap.page_allocator;

/// Copies `rgba`. Any thread.
pub fn create(gpa: std.mem.Allocator, width: u32, height: u32, rgba: []const u8) error{ OutOfMemory, InvalidSize }!*Texture {
    try check(width, height, rgba.len);
    const pixels = try gpa.dupe(u8, rgba);
    errdefer gpa.free(pixels);
    return adopt(gpa, width, height, pixels);
}

/// Takes `pixels`, which `gpa` made, even on error. Any thread.
pub fn adopt(gpa: std.mem.Allocator, width: u32, height: u32, pixels: []u8) error{ OutOfMemory, InvalidSize }!*Texture {
    errdefer gpa.free(pixels);
    try check(width, height, pixels.len);
    const self = try gpa.create(Texture);
    self.* = .{ .allocator = gpa, .width = width, .height = height, .pixels = pixels };
    return self;
}

fn check(width: u32, height: u32, len: usize) error{InvalidSize}!void {
    if (width == 0 or height == 0 or width > max_side or height > max_side) return error.InvalidSize;
    if (len != @as(usize, width) * height * 4) return error.InvalidSize;
}

/// Don't use it after. Any thread.
pub fn destroy(self: *Texture) void {
    lock.lock();
    defer lock.unlock();
    if (self.copies.items.len == 0) return self.free();
    self.dead = true;
}

pub fn size(self: *const Texture) ui.Vec2 {
    return .{ @floatFromInt(self.width), @floatFromInt(self.height) };
}

/// For `ImGui_Image` and co in the current context, this frame. Null without a context, or if its
/// renderer can't take textures. Render thread.
pub fn ref(self: *Texture) ?c.ImTextureRef {
    const context = c.ImGui_GetCurrentContext() orelse return null;
    if (!hasTextures()) return null;
    lock.lock();
    defer lock.unlock();
    if (self.dead) return null;
    for (self.copies.items) |copy| {
        if (copy.context == context) return refOf(copy.data);
    }
    hook(context) catch return null;
    self.copies.ensureUnusedCapacity(self.allocator, 1) catch return null;
    if (self.copies.items.len == 0) live.append(lists, self) catch return null;
    const data = tuft_imgui_texture_add(@intCast(self.width), @intCast(self.height), self.pixels.ptr);
    self.copies.appendAssumeCapacity(.{ .context = context, .data = data });
    return refOf(data);
}

/// Like `tuft_ui.image`. Leaves a gap the right size when it can't draw. Render thread.
pub fn draw(self: *Texture, options: ui.ImageOptions) void {
    const avail = c.ImGui_GetContentRegionAvail();
    const s = ui.imageSize(self.size(), options, .{ avail.x, avail.y });
    const vec: c.ImVec2 = .{ .x = s[0], .y = s[1] };
    const texture = self.ref() orelse return c.ImGui_Dummy(vec);
    const t = options.tint;
    c.ImGui_ImageWithBgEx(texture, vec, .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 1 }, .{ .x = 0, .y = 0, .z = 0, .w = 0 }, .{ .x = t[0], .y = t[1], .z = t[2], .w = t[3] });
}

fn refOf(data: *c.ImTextureData) c.ImTextureRef {
    return .{ ._TexData = data, ._TexID = 0 };
}

fn hasTextures() bool {
    return c.ImGui_GetIO().*.BackendFlags & c.ImGuiBackendFlags_RendererHasTextures != 0;
}

/// Under `lock`.
fn free(self: *Texture) void {
    self.copies.deinit(self.allocator);
    self.allocator.free(self.pixels);
    self.allocator.destroy(self);
}

/// Under `lock`.
fn hook(context: *c.ImGuiContext) !void {
    if (std.mem.indexOfScalar(*c.ImGuiContext, hooked.items, context) != null) return;
    try hooked.append(lists, context);
    tuft_imgui_texture_hooks(newFrame, shutdown);
}

/// Copies whose texture is dead go once the backend's let go. Before the backend sees a frame.
fn newFrame() callconv(.c) void {
    const context = c.ImGui_GetCurrentContext() orelse return;
    const backend = hasTextures();
    lock.lock();
    defer lock.unlock();
    var i = live.items.len;
    while (i > 0) {
        i -= 1;
        const self = live.items[i];
        if (!self.dead) continue;
        var j = self.copies.items.len;
        while (j > 0) {
            j -= 1;
            const copy = self.copies.items[j];
            if (copy.context != context) continue;
            const data = copy.data;
            const gone = data.*.Status == c.ImTextureStatus_Destroyed or (data.*.TexID == 0 and data.*.BackendUserData == null);
            if (!backend or gone) {
                tuft_imgui_texture_remove(data);
                _ = self.copies.swapRemove(j);
            } else data.*.WantDestroyNextFrame = true;
        }
        if (self.copies.items.len == 0) {
            _ = live.swapRemove(i);
            self.free();
        }
    }
}

/// The context's going, so all its copies go now. Its backend shut down first and destroyed them.
fn shutdown() callconv(.c) void {
    const context = c.ImGui_GetCurrentContext() orelse return;
    lock.lock();
    defer lock.unlock();
    var i = live.items.len;
    while (i > 0) {
        i -= 1;
        const self = live.items[i];
        var j = self.copies.items.len;
        while (j > 0) {
            j -= 1;
            if (self.copies.items[j].context != context) continue;
            tuft_imgui_texture_remove(self.copies.items[j].data);
            _ = self.copies.swapRemove(j);
        }
        if (self.copies.items.len == 0) {
            _ = live.swapRemove(i);
            if (self.dead) self.free();
        }
    }
    if (std.mem.indexOfScalar(*c.ImGuiContext, hooked.items, context)) |at| _ = hooked.swapRemove(at);
}

/// How many contexts have a copy of it. For tests.
pub fn copyCount(self: *Texture) usize {
    lock.lockShared();
    defer lock.unlockShared();
    return self.copies.items.len;
}

/// How many textures have copies or are waiting on them to go. For tests.
pub fn liveCount() usize {
    lock.lockShared();
    defer lock.unlockShared();
    return live.items.len;
}

extern fn tuft_imgui_texture_add(width: c_int, height: c_int, pixels: [*]u8) *c.ImTextureData;
extern fn tuft_imgui_texture_remove(tex: *c.ImTextureData) void;
extern fn tuft_imgui_texture_hooks(new_frame: *const fn () callconv(.c) void, shutdown: *const fn () callconv(.c) void) void;

const tests = struct {
    const testing = std.testing;
    const headless = @import("root.zig").headless;

    const Headless = struct {
        context: *c.ImGuiContext,

        fn init(textures: bool) !Headless {
            const context = c.ImGui_CreateContext(null) orelse return error.CreateContextFailed;
            c.ImGui_SetCurrentContext(context);
            const io = c.ImGui_GetIO();
            io.*.IniFilename = null;
            io.*.DisplaySize = .{ .x = 640, .y = 480 };
            io.*.DeltaTime = 1.0 / 60.0;
            if (textures) headless.init() else io.*.BackendFlags &= ~@as(c_int, c.ImGuiBackendFlags_RendererHasTextures);
            return .{ .context = context };
        }

        fn deinit(self: Headless) void {
            c.ImGui_DestroyContext(self.context);
        }

        fn frame(_: Headless, texture: ?*Texture) void {
            c.ImGui_NewFrame();
            headless.textures();
            _ = c.ImGui_Begin(@ptrCast("pictures"), null, 0);
            if (texture) |t| t.draw(.{ .size = .{ 32, 0 } });
            c.ImGui_End();
            c.ImGui_Render();
        }

        fn registered(_: Headless, data: *c.ImTextureData) bool {
            const list = c.ImGui_GetPlatformIO().*.Textures;
            for (list.Data[0..@intCast(list.Size)]) |t| if (t == data) return true;
            return false;
        }

        /// Some draw command last frame used it.
        fn drawnWith(_: Headless, data: *c.ImTextureData) bool {
            const draw_data = c.ImGui_GetDrawData();
            const lists_ = draw_data.*.CmdLists;
            for (lists_.Data[0..@intCast(lists_.Size)]) |list| {
                const cmds = list.*.CmdBuffer;
                for (cmds.Data[0..@intCast(cmds.Size)]) |cmd| if (cmd.TexRef._TexData == data) return true;
            }
            return false;
        }
    };

    const pixels: [2 * 2 * 4]u8 = @splat(200);

    test "drawn, then destroyed through the backend" {
        const h = try Headless.init(true);
        defer h.deinit();
        const texture = try create(testing.allocator, 2, 2, &pixels);
        h.frame(texture);
        try testing.expectEqual(1, texture.copyCount());
        const data = texture.copies.items[0].data;
        try testing.expect(h.registered(data));
        h.frame(texture);
        try testing.expectEqual(c.ImTextureStatus_OK, @as(c_int, @intCast(data.*.Status)));
        try testing.expectEqual(1, texture.copyCount());
        try testing.expect(h.drawnWith(data));

        texture.destroy();
        h.frame(null);
        try testing.expect(data.*.WantDestroyNextFrame);
        try testing.expectEqual(c.ImTextureStatus_Destroyed, @as(c_int, @intCast(data.*.Status)));
        // Next frame it's gone, and with no copies left so is the texture, which the allocator checks
        c.ImGui_NewFrame();
        c.ImGui_EndFrame();
        try testing.expect(!h.registered(data));
        try testing.expectEqual(0, live.items.len);
    }

    test "a context going takes its copies" {
        const a = try Headless.init(true);
        const texture = try create(testing.allocator, 2, 2, &pixels);
        defer texture.destroy();
        a.frame(texture);
        const b = try Headless.init(true);
        b.frame(texture);
        try testing.expectEqual(2, texture.copyCount());
        b.deinit();
        try testing.expectEqual(1, texture.copyCount());
        c.ImGui_SetCurrentContext(a.context);
        a.deinit();
        try testing.expectEqual(0, texture.copyCount());
        try testing.expectEqual(0, hooked.items.len);
    }

    test "dead before a context goes" {
        const a = try Headless.init(true);
        const texture = try create(testing.allocator, 2, 2, &pixels);
        a.frame(texture);
        texture.destroy();
        a.deinit();
        try testing.expectEqual(0, live.items.len);
    }

    test "no textures in the renderer, nothing to draw" {
        const h = try Headless.init(false);
        defer h.deinit();
        const texture = try create(testing.allocator, 2, 2, &pixels);
        defer texture.destroy();
        try testing.expectEqual(null, texture.ref());
        try testing.expectEqual(0, texture.copyCount());
        try testing.expectError(error.InvalidSize, create(testing.allocator, 3, 2, &pixels));
    }
};

test {
    _ = tests;
}
