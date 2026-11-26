//! ImGui renderer and viewport tests on a fake game.

const std = @import("std");
const testing = std.testing;

const gfx = @import("tuft_gfx");
const tuft_window = @import("tuft_window");

const c = @import("root.zig").c;
const Game = @import("Game.zig");
const str = Game.str;

const all_apis = .{ .d3d11, .d3d10, .d3d12, .d3d9, .opengl, .vulkan };

const win = @import("tuft_sys").win;

const Drawer = struct {
    draws: u32 = 0,

    pub fn draw(self: *Drawer) void {
        self.draws += 1;
        _ = c.ImGui_Begin(str("test"), null, 0);
        c.ImGui_TextUnformatted(str("frame"));
        c.ImGui_End();
    }
};

/// Draws past the small game window so ImGui gives it its own window.
const Outside = struct {
    draws: u32 = 0,

    pub fn draw(self: *Outside) void {
        self.draws += 1;
        // Screen coords, right of the game window
        const main = c.ImGui_GetMainViewport();
        c.ImGui_SetNextWindowPos(.{ .x = main.*.Pos.x + main.*.Size.x + 100, .y = main.*.Pos.y }, c.ImGuiCond_Always);
        c.ImGui_SetNextWindowSize(.{ .x = 200, .y = 120 }, c.ImGuiCond_Always);
        _ = c.ImGui_Begin(str("outside"), null, c.ImGuiWindowFlags_NoFocusOnAppearing);
        c.ImGui_End();
    }
};

test "draws through resize" {
    inline for (all_apis) |api| {
        var game: Game = undefined;
        try game.init(.{ .api = api });
        var done = false;
        defer if (!done) game.deinit();
        var drawer: Drawer = .{};
        game.hooks = .of(Drawer, &drawer);

        game.present();
        game.present();
        try testing.expectEqual(2, drawer.draws);

        // Fails if anything still holds the old buffers
        try testing.expect(game.resize(128, 96));
        game.present();
        try testing.expectEqual(3, drawer.draws);
        try testing.expect(c.ImGui_GetDrawData().*.CmdListsCount > 0);
        // On D3D9 that includes the font atlas
        const textures = c.ImGui_GetPlatformIO().*.Textures;
        for (textures.Data[0..@intCast(textures.Size)]) |tex| try testing.expectEqual(c.ImTextureStatus_OK, @as(c_int, @intCast(tex.*.Status)));

        game.deinit(); // presents after this aren't hooked
        done = true;
        try testing.expectEqual(3, drawer.draws);
    }
}

test "viewports get own windows" {
    inline for (all_apis) |api| {
        var game: Game = undefined;
        try game.init(.{ .viewports = true, .api = api });
        var done = false;
        defer if (!done) game.deinit();
        var outside: Outside = .{};
        game.hooks = .of(Outside, &outside);
        game.present(); // attaches
        game.present();
        game.present();

        const pio = c.ImGui_GetPlatformIO();
        try testing.expectEqual(2, pio.*.Viewports.Size);
        try testing.expectEqual(@as(?*anyopaque, game.hwnd), pio.*.Viewports.Data[0].*.PlatformHandle);
        try testing.expect(pio.*.Viewports.Data[1].*.RendererUserData != null);
        // OpenGL draws with its own context, then the game's is current again
        if (api == .opengl) try testing.expectEqual(game.surface.opengl.context, gfx.opengl.currentContext().?);
        const hwnd = pio.*.Viewports.Data[1].*.PlatformHandle.?;
        try testing.expect(win.IsWindow(@ptrCast(hwnd)).toBool());

        // Wheel, since a click would steal focus while tests run
        _ = tuft_window.send(@ptrCast(hwnd), Game.WM_MOUSEWHEEL, 120 << 16, 0);
        try testing.expectEqual(1, game.viewport_wheels);

        game.deinit();
        done = true;
        try testing.expect(!win.IsWindow(@ptrCast(hwnd)).toBool());
    }
}

const Pictures = struct {
    texture: ?*Texture,

    pub fn draw(self: *Pictures) void {
        _ = c.ImGui_Begin(str("pictures"), null, 0);
        if (self.texture) |t| t.draw(.{ .size = .{ 16, 16 } });
        c.ImGui_End();
    }
};

const Texture = @import("Texture.zig");

test "textures upload and go on every api" {
    inline for (all_apis) |api| {
        var game: Game = undefined;
        try game.init(.{ .api = api });
        var done = false;
        defer if (!done) game.deinit();
        const pixels: [4 * 4 * 4]u8 = @splat(255);
        const texture = try Texture.create(testing.allocator, 4, 4, &pixels);
        var pictures: Pictures = .{ .texture = texture };
        game.hooks = .of(Pictures, &pictures);
        for (0..3) |_| game.present();
        try testing.expectEqual(1, texture.copyCount());
        const data = texture.copies.items[0].data;
        try testing.expectEqual(c.ImTextureStatus_OK, @as(c_int, @intCast(data.*.Status)));
        try testing.expect(data.*.TexID != 0);

        pictures.texture = null;
        texture.destroy();
        // D3D12 and Vulkan wait out their frames in flight, up to 16
        for (0..40) |_| {
            if (Texture.liveCount() == 0) break;
            game.present();
        }
        try testing.expectEqual(0, Texture.liveCount());

        // One still around when the game goes
        const kept = try Texture.create(testing.allocator, 4, 4, &pixels);
        pictures.texture = kept;
        for (0..3) |_| game.present();
        try testing.expectEqual(1, kept.copyCount());
        game.deinit();
        done = true;
        try testing.expectEqual(0, kept.copyCount());
        kept.destroy();
    }
}

test "viewports on own thread" {
    var game: Game = undefined;
    try game.init(.{ .viewports = true, .api = .d3d11 });
    defer game.deinit();
    var outside: Outside = .{};
    game.hooks = .of(Outside, &outside);
    game.present();
    game.present();
    game.present();
    const pio = c.ImGui_GetPlatformIO();
    try testing.expectEqual(2, pio.*.Viewports.Size);
    const hwnd: win.HWND = @ptrCast(pio.*.Viewports.Data[1].*.PlatformHandle.?);
    const owner = win.GetWindowThreadProcessId(hwnd, null);
    try testing.expect(owner != win.GetCurrentThreadId());

    // Like a game presenting from a worker while this thread pumps nothing
    const Worker = struct {
        fn run(g: *Game, window: win.HWND, id: *win.DWORD) void {
            id.* = win.GetCurrentThreadId();
            for (0..3) |_| g.present();
            _ = tuft_window.send(window, Game.WM_MOUSEWHEEL, 120 << 16, 0);
        }
    };
    var worker_id: win.DWORD = 0;
    const thread = try std.Thread.spawn(.{}, Worker.run, .{ &game, hwnd, &worker_id });
    thread.join();
    try testing.expectEqual(1, game.viewport_wheels);
    try testing.expectEqual(@as(?*anyopaque, hwnd), pio.*.Viewports.Data[1].*.PlatformHandle);
    try testing.expectEqual(owner, win.GetWindowThreadProcessId(hwnd, null));
    try testing.expect(owner != worker_id);

    game.present();
    try testing.expectEqual(@as(?*anyopaque, hwnd), pio.*.Viewports.Data[1].*.PlatformHandle);
}

test "stop viewports midway" {
    inline for (all_apis) |api| {
        var game: Game = undefined;
        try game.init(.{ .viewports = true, .api = api });
        defer game.deinit();
        var outside: Outside = .{};
        game.hooks = .of(Outside, &outside);
        game.present();
        game.present();
        const pio = c.ImGui_GetPlatformIO();
        try testing.expectEqual(2, pio.*.Viewports.Size);
        const hwnd = pio.*.Viewports.Data[1].*.PlatformHandle.?;

        // Like on unload. The renderer keeps going
        game.stopViewports();
        try testing.expect(!win.IsWindow(@ptrCast(hwnd)).toBool());
        const draws = outside.draws;
        game.present();
        try testing.expectEqual(draws + 1, outside.draws);
    }
}

// Captures

const capture = @import("capture.zig");

/// Waits up to 5s, since CI's software renderer can be far slower than a frame.
const max_wait_frames = 500;

fn waitFrame(game: *Game) void {
    game.present();
    @import("tuft_sys").thread.sleepMs(10);
}

/// Fills the game window with one color.
const Fill = struct {
    color: u32,

    pub fn draw(self: *Fill) void {
        const main = c.ImGui_GetMainViewport();
        c.ImDrawList_AddRectFilled(c.ImGui_GetBackgroundDrawList(), main.*.Pos, .{ .x = main.*.Pos.x + main.*.Size.x, .y = main.*.Pos.y + main.*.Size.y }, self.color);
    }
};

const Collector = struct {
    started: capture.Points = .empty,
    failed: capture.Points = .empty,
    got: [2]?Got = @splat(null),

    const Got = struct { width: u32, height: u32, format: capture.Format, rgb: ?[3]u8 };

    fn onEvent(self: *Collector, event: capture.Event) void {
        switch (event) {
            .started => |point| self.started.insert(point),
            .failed => |point| self.failed.insert(point),
            .done => |image| self.got[@backingInt(image.point)] = .{
                .width = image.width,
                .height = image.height,
                .format = image.format,
                .rgb = cornerRgb(image),
            },
        }
    }

    /// Near the top left, since the test windows are short. For 8-bit formats.
    fn cornerRgb(image: *const capture.Image) ?[3]u8 {
        const at = image.pixels[2 * image.pitch + 2 * 4 ..][0..4];
        return switch (image.format) {
            .rgba8 => .{ at[0], at[1], at[2] },
            .bgra8, .bgrx8 => .{ at[2], at[1], at[0] },
            else => null,
        };
    }
};

test "captures before and after drawing" {
    inline for (all_apis) |api| {
        var collector: Collector = .{};
        var game: Game = undefined;
        // An API that isn't there skips before this
        try game.init(.{ .api = api, .capture_sink = .of(Collector, &collector, Collector.onEvent) });
        defer game.deinit();
        errdefer std.debug.print("captures failed on {t}\n", .{api});
        const green = 0xff00ff00;
        const red = 0xff0000ff;
        var fill: Fill = .{ .color = green };
        game.hooks = .of(Fill, &fill);
        game.present();
        game.present();

        // Only this frame is red, so before has last frame's green or nothing
        fill.color = red;
        game.host.requestCapture(.before);
        game.host.requestCapture(.after);
        game.present();

        fill.color = green;
        try testing.expectEqual(capture.Points.full, collector.started);
        var frames: u32 = 0;
        while ((collector.got[0] == null or collector.got[1] == null) and frames < max_wait_frames) : (frames += 1) waitFrame(&game);
        try testing.expectEqual(capture.Points.empty, collector.failed);
        if (collector.got[0] == null or collector.got[1] == null) {
            std.debug.print("no capture after {d} frames: before {}, after {}\n", .{ frames, collector.got[0] != null, collector.got[1] != null });
            return error.TestUnexpectedResult;
        }

        // The back buffer's size, which needn't be the window's
        const first = collector.got[0].?;
        if (first.width == 0 or first.height == 0 or first.format == .unknown) {
            std.debug.print("bad capture: {d} x {d} {t}\n", .{ first.width, first.height, first.format });
            return error.TestUnexpectedResult;
        }
        try testing.expectEqual(first, Collector.Got{ .width = collector.got[1].?.width, .height = collector.got[1].?.height, .format = collector.got[1].?.format, .rgb = first.rgb });

        if (collector.got[1].?.rgb) |rgb| try testing.expectEqual([3]u8{ 255, 0, 0 }, rgb);
        if (collector.got[0].?.rgb) |rgb| if (std.mem.eql(u8, &rgb, &.{ 255, 0, 0 })) {
            std.debug.print("before has this frame's drawing in it\n", .{});
            return error.TestUnexpectedResult;
        };
        // Nothing more comes without asking
        collector = .{};
        game.present();
        game.present();
        try testing.expectEqual(capture.Points.empty, collector.started);
    }
}

// HDR

/// Reads back the white square's pixel just before the present. D3D11 only.
const WhiteProbe = struct {
    pixel: [8]u8 = @splat(0),
    color_space: gfx.ColorSpace = .srgb,
    outside: bool = false,

    pub fn draw(self: *WhiteProbe) void {
        // Screen coords with viewports
        const main = c.ImGui_GetMainViewport();
        const at = main.*.Pos;
        c.ImDrawList_AddRectFilled(c.ImGui_GetForegroundDrawListEx(main), at, .{ .x = at.x + 8, .y = at.y + 8 }, 0xffffffff);
        if (self.outside) GreyOutside.draw();
    }

    pub fn after(self: *WhiteProbe, frame: *const gfx.Frame) void {
        const native = gfx.d3d11.fromFrame(frame) orelse return;
        self.pixel = readPixel(native.device, native.context, native.swap_chain, 2, 2) orelse return;
        self.color_space = frame.color_space;
    }

    fn half(self: *const WhiteProbe, channel: usize) f32 {
        return @floatCast(@as(f16, @bitCast(std.mem.readInt(u16, self.pixel[channel * 2 ..][0..2], .little))));
    }

    fn ten(self: *const WhiteProbe, channel: u5) f32 {
        const v = std.mem.readInt(u32, self.pixel[0..4], .little);
        return @as(f32, @floatFromInt((v >> (channel * 10)) & 0x3ff)) / 1023.0;
    }
};

/// 8 bytes for FP16, else 4.
fn readPixel(device: *gfx.d3d11.Device, context: *gfx.d3d11.DeviceContext, swap_chain: *gfx.dxgi.SwapChain, x: usize, y: usize) ?[8]u8 {
    var desc: gfx.dxgi.SwapChainDesc = .{};
    if (!gfx.com.succeeded(swap_chain.getDesc(&desc))) return null;
    var buffer: ?*anyopaque = null;
    if (!gfx.com.succeeded(swap_chain.getBuffer(0, &gfx.d3d11.IID_ID3D11Texture2D, &buffer))) return null;
    defer gfx.com.release(buffer.?);
    const staging = device.createTexture2D(&.{
        .width = desc.buffer_desc.width,
        .height = desc.buffer_desc.height,
        .format = desc.buffer_desc.format,
        .usage = gfx.d3d11.USAGE_STAGING,
        .cpu_access_flags = gfx.d3d11.CPU_ACCESS_READ,
    }) orelse return null;
    defer gfx.com.release(staging);
    context.copyResource(staging, buffer.?);
    const mapped = context.map(staging, gfx.d3d11.MAP_READ) orelse return null;
    defer context.unmap(staging);
    const bytes: [*]const u8 = @ptrCast(mapped.data.?);
    const size: usize = if (desc.buffer_desc.format == gfx.dxgi.FORMAT_R16G16B16A16_FLOAT) 8 else 4;
    var pixel: [8]u8 = @splat(0);
    @memcpy(pixel[0..size], bytes[y * mapped.row_pitch + x * size ..][0..size]);
    return pixel;
}

fn pq(nits: f32) f32 {
    const y = std.math.pow(f32, nits / 10000.0, 0.1593017578125);
    return std.math.pow(f32, (0.8359375 + 18.8515625 * y) / (1.0 + 18.6875 * y), 78.84375);
}

test "HDR white at SDR level" {
    const WhiteCapture = struct {
        white: ?f32 = null,

        fn onEvent(self: *@This(), event: capture.Event) void {
            if (event == .done) self.white = event.done.sdr_white_nits;
        }
    };
    var captured: WhiteCapture = .{};
    var game: Game = undefined;
    try game.init(.{ .capture_sink = .of(WhiteCapture, &captured, WhiteCapture.onEvent) });
    defer game.deinit();
    var probe: WhiteProbe = .{};
    game.hooks = .of(WhiteProbe, &probe);
    const swap_chain = game.surface.d3d11.swap_chain;

    game.present();
    try testing.expectEqual(gfx.ColorSpace.srgb, probe.color_space);
    try testing.expectEqual(0xff, probe.pixel[0]);

    // scRGB is linear, 1.0 = 80 nits
    try testing.expect(gfx.com.succeeded(swap_chain.resizeBuffers(0, 0, 0, gfx.dxgi.FORMAT_R16G16B16A16_FLOAT, 0)));
    game.present();
    try testing.expectEqual(gfx.ColorSpace.scrgb, probe.color_space);
    const white = game.host.renderer.?.backend.d3d11.output.sdr_white_nits;
    for (0..3) |ch| try testing.expectApproxEqRel(white / 80.0, probe.half(ch), 0.01);
    try testing.expectApproxEqRel(1.0, probe.half(3), 0.01);

    game.host.requestCapture(.after);
    var frames: u32 = 0;
    while (captured.white == null and frames < max_wait_frames) : (frames += 1) waitFrame(&game);
    try testing.expectEqual(white, captured.white orelse return error.NoCapture);

    // HDR10 if this display lets us switch to it
    try testing.expect(gfx.com.succeeded(swap_chain.resizeBuffers(0, 0, 0, gfx.dxgi.FORMAT_R10G10B10A2_UNORM, 0)));
    const set = gfx.com.method(swap_chain, 38, gfx.dxgi.SetColorSpace1Fn);
    _ = set(swap_chain, gfx.dxgi.COLOR_SPACE_RGB_FULL_G2084_NONE_P2020);
    game.present();
    if (probe.color_space == .hdr10) {
        for (0..3) |ch| try testing.expectApproxEqAbs(pq(white), probe.ten(@intCast(ch)), 2.0 / 1023.0);
    }
}

/// Read back right before ImGui presents it. D3D11 only.
const GreyOutside = struct {
    var game: *Game = undefined;
    var pixel: ?[8]u8 = null;
    var swap_buffers: ?*const fn (?*c.ImGuiViewport, ?*anyopaque) callconv(.c) void = null;

    fn draw() void {
        const main = c.ImGui_GetMainViewport();
        c.ImGui_SetNextWindowPos(.{ .x = main.*.Pos.x + main.*.Size.x + 100, .y = main.*.Pos.y }, c.ImGuiCond_Always);
        c.ImGui_SetNextWindowSize(.{ .x = 200, .y = 120 }, c.ImGuiCond_Always);
        _ = c.ImGui_Begin(str("outside"), null, c.ImGuiWindowFlags_NoFocusOnAppearing);
        const at = c.ImGui_GetWindowPos();
        c.ImDrawList_AddRectFilled(c.ImGui_GetWindowDrawList(), .{ .x = at.x + 20, .y = at.y + 40 }, .{ .x = at.x + 60, .y = at.y + 80 }, 0xff808080);
        c.ImGui_End();
    }

    fn swapBuffers(viewport: ?*c.ImGuiViewport, arg: ?*anyopaque) callconv(.c) void {
        // ImGui_ImplDX11_ViewportData's first field
        const swap_chain: *const ?*gfx.dxgi.SwapChain = @ptrCast(@alignCast(viewport.?.RendererUserData.?));
        const d3d = &game.surface.d3d11;
        if (swap_chain.*) |sc| pixel = readPixel(d3d.device, d3d.context, sc, 40, 60);
        swap_buffers.?(viewport, arg);
    }
};

test "D3D11 HDR viewports stay SDR" {
    var game: Game = undefined;
    try game.init(.{ .viewports = true });
    defer game.deinit();
    var probe: WhiteProbe = .{ .outside = true };
    game.hooks = .of(WhiteProbe, &probe);
    try testing.expect(gfx.com.succeeded(game.surface.d3d11.swap_chain.resizeBuffers(0, 0, 0, gfx.dxgi.FORMAT_R16G16B16A16_FLOAT, 0)));
    game.present(); // attaches
    game.present();

    const pio = c.ImGui_GetPlatformIO();
    try testing.expectEqual(2, pio.*.Viewports.Size);
    GreyOutside.game = &game;
    GreyOutside.pixel = null;
    GreyOutside.swap_buffers = pio.*.Renderer_SwapBuffers;
    pio.*.Renderer_SwapBuffers = GreyOutside.swapBuffers;
    defer pio.*.Renderer_SwapBuffers = GreyOutside.swap_buffers;
    game.present();

    try testing.expectEqual(gfx.ColorSpace.scrgb, probe.color_space);
    const white = game.host.renderer.?.backend.d3d11.output.sdr_white_nits;
    try testing.expectApproxEqRel(white / 80.0, probe.half(0), 0.01);
    const pixel = GreyOutside.pixel orelse return error.NotRead;
    for (0..3) |ch| try testing.expectApproxEqAbs(@as(f32, 0x80), @as(f32, @floatFromInt(pixel[ch])), 1);
}

test "D3D12 HDR viewports drawn" {
    var game: Game = undefined;
    try game.init(.{ .viewports = true, .api = .d3d12 });
    defer game.deinit();
    var outside: Outside = .{};
    game.hooks = .of(Outside, &outside);
    game.surface.d3d12.waitIdle();
    try testing.expect(gfx.com.succeeded(game.surface.d3d12.swap_chain.resizeBuffers(0, 0, 0, gfx.dxgi.FORMAT_R16G16B16A16_FLOAT, 0)));
    for (0..3) |_| game.present();
    try testing.expectEqual(gfx.ColorSpace.scrgb, game.host.renderer.?.backend.d3d12.state.output.color_space);
    try testing.expectEqual(2, c.ImGui_GetPlatformIO().*.Viewports.Size);
    const draws = outside.draws;
    game.present();
    try testing.expectEqual(draws + 1, outside.draws);
}

test "Vulkan HDR pipeline" {
    var game: Game = undefined;
    try game.init(.{ .api = .vulkan, .hdr = true });
    defer game.deinit();
    var drawer: Drawer = .{};
    game.hooks = .of(Drawer, &drawer);
    game.present();
    game.present();
    try testing.expectEqual(2, drawer.draws);
    const state = game.host.renderer.?.backend.vulkan.state;
    try testing.expectEqual(gfx.ColorSpace.scrgb, state.output.color_space);
    try testing.expectEqual(@as(c_int, 1), state.output.mode());
    try testing.expect(state.output.sdr_white_nits >= 80);
    // The draw callback made and bound it
    try testing.expect(state.hdr_pipeline != std.mem.zeroes(@TypeOf(state.hdr_pipeline)));
}

// Vulkan viewports

/// Its viewport data starts with an `ImGui_ImplVulkanH_Window`.
fn vulkanSwapchain(viewport: *c.ImGuiViewport) u64 {
    const window: *const c.ImGui_ImplVulkanH_Window = @ptrCast(@alignCast(viewport.RendererUserData orelse return 0));
    return switch (@typeInfo(c.VkSwapchainKHR)) {
        .optional => if (window.Swapchain) |p| @intFromPtr(p) else 0,
        else => window.Swapchain,
    };
}

test "Vulkan viewport swapchain" {
    var game: Game = undefined;
    try game.init(.{ .viewports = true, .api = .vulkan });
    defer game.deinit();
    var outside: Outside = .{};
    game.hooks = .of(Outside, &outside);
    for (0..3) |_| game.present();
    const pio = c.ImGui_GetPlatformIO();
    try testing.expectEqual(2, pio.*.Viewports.Size);
    try testing.expect(vulkanSwapchain(pio.*.Viewports.Data[1]) != 0);

    // ImGui's backend restarts for the new swapchain
    try testing.expect(game.resize(500, 400));
    for (0..3) |_| game.present();
    try testing.expectEqual(2, pio.*.Viewports.Size);
    try testing.expectEqual(@as(?*anyopaque, game.hwnd), pio.*.Viewports.Data[0].*.PlatformHandle);
    try testing.expect(vulkanSwapchain(pio.*.Viewports.Data[1]) != 0);
    const draws = outside.draws;
    game.present();
    try testing.expectEqual(draws + 1, outside.draws);
}
