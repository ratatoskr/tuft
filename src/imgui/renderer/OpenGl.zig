//! ImGui's OpenGL2 backend, drawn with our own context so the game's GL state is never touched.

const OpenGl = @This();

const std = @import("std");

const gfx = @import("tuft_gfx");
const tuft_window = @import("tuft_window");

const c = @import("../root.zig").c;
const capture = @import("../capture.zig");
const log = std.log.scoped(.tuft_imgui);

const opengl = gfx.opengl;
const Frame = gfx.Frame;

state: *State,

const State = struct {
    /// Plus the DC it was last presented through.
    window: *anyopaque,
    dc: opengl.Dc,
    context: opengl.Context,
    format: ?opengl.PixelFormat,
    render_window: ?*const RenderWindowFn = null,
    gl: ?Gl = null,
    copies: [2]Copy = @splat(.{}),
    /// GL rows go bottom up, so they get flipped into here.
    flipped: std.ArrayList(u8) = .empty,
    /// Where reads land without pixel buffers.
    read: std.ArrayList(u8) = .empty,

    /// Our context is current.
    fn copyAt(self: *State, frame: *const Frame, point: capture.Point, captures: *capture.Captures) void {
        if (!captures.want(point)) return;
        const copy = &self.copies[@backingInt(point)];
        if (copy.busy) return;
        const gl = self.gl orelse return captures.failed(point);
        const size = tuft_window.clientSize(@ptrCast(frame.window));
        if (size.width == 0 or size.height == 0) return captures.failed(point);
        const pixels: Pixels = .of(frame.color_space);
        copy.width = size.width;
        copy.height = size.height;
        copy.pixels = pixels;
        copy.color_space = frame.color_space;
        const len = @as(usize, size.width) * size.height * pixels.format.bytesPerPixel();
        const w: i32 = @intCast(size.width);
        const h: i32 = @intCast(size.height);
        gl.readBuffer(GL_BACK);
        const pbo = gl.pbo orelse {
            // Waits for the GPU, but only old drivers get here
            self.read.resize(std.heap.page_allocator, len) catch return captures.failed(point);
            gl.readPixels(0, 0, w, h, GL_RGBA, pixels.gl_type, self.read.items.ptr);
            captures.started(point);
            return self.deliver(copy, point, self.read.items, captures);
        };
        if (copy.buffer == 0) pbo.genBuffers(1, &copy.buffer);
        pbo.bindBuffer(GL_PIXEL_PACK_BUFFER, copy.buffer);
        defer pbo.bindBuffer(GL_PIXEL_PACK_BUFFER, 0);
        if (copy.size != len) {
            pbo.bufferData(GL_PIXEL_PACK_BUFFER, @intCast(len), null, GL_STREAM_READ);
            copy.size = len;
        }
        gl.readPixels(0, 0, w, h, GL_RGBA, pixels.gl_type, null);
        copy.sync = pbo.fenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0) orelse return captures.failed(point);
        // So the fence gets to the GPU without waiting for the game's next frame
        gl.flush();
        copy.busy = true;
        captures.started(point);
    }

    fn land(self: *State, pbo: Gl.Pbo, copy: *Copy, point: capture.Point, captures: *capture.Captures) void {
        const status = pbo.clientWaitSync(copy.sync, 0, 0);
        if (status == GL_TIMEOUT_EXPIRED) return;
        pbo.deleteSync(copy.sync);
        copy.sync = null;
        copy.busy = false;
        if (status == GL_WAIT_FAILED) return captures.failed(point);
        pbo.bindBuffer(GL_PIXEL_PACK_BUFFER, copy.buffer);
        defer pbo.bindBuffer(GL_PIXEL_PACK_BUFFER, 0);
        const data = pbo.mapBuffer(GL_PIXEL_PACK_BUFFER, GL_READ_ONLY) orelse return captures.failed(point);
        defer _ = pbo.unmapBuffer(GL_PIXEL_PACK_BUFFER);
        self.deliver(copy, point, data[0..copy.size], captures);
    }

    fn deliver(self: *State, copy: *const Copy, point: capture.Point, bottom_up: []const u8, captures: *capture.Captures) void {
        const pitch = copy.width * copy.pixels.format.bytesPerPixel();
        self.flipped.resize(std.heap.page_allocator, bottom_up.len) catch return captures.failed(point);
        for (0..copy.height) |row| {
            const from = (copy.height - 1 - row) * pitch;
            @memcpy(self.flipped.items[row * pitch ..][0..pitch], bottom_up[from..][0..pitch]);
        }
        captures.done(&.{
            .point = point,
            .width = copy.width,
            .height = copy.height,
            .pitch = pitch,
            .format = copy.pixels.format,
            .native_format = copy.pixels.native,
            .color_space = copy.color_space,
            .pixels = self.flipped.items,
        });
    }

    /// Our context is current, else it's gone and took these along.
    fn dropCopies(self: *State) void {
        const gl = self.gl orelse return;
        const pbo = gl.pbo orelse return;
        for (&self.copies) |*copy| {
            if (copy.sync) |sync| pbo.deleteSync(sync);
            if (copy.buffer != 0) pbo.deleteBuffers(1, &copy.buffer);
            copy.* = .{};
        }
    }
};

const GL_BACK = 0x0405;
const GL_RGBA = 0x1908;
const GL_UNSIGNED_BYTE = 0x1401;
const GL_HALF_FLOAT = 0x140B;
const GL_UNSIGNED_INT_2_10_10_10_REV = 0x8368;
const GL_PIXEL_PACK_BUFFER = 0x88EB;
const GL_STREAM_READ = 0x88E1;
const GL_READ_ONLY = 0x88B8;
const GL_SYNC_GPU_COMMANDS_COMPLETE = 0x9117;
const GL_TIMEOUT_EXPIRED = 0x911B;
const GL_WAIT_FAILED = 0x911D;

/// What a read asks GL for, by what the window holds.
const Pixels = struct {
    format: capture.Format = .rgba8,
    /// GL's internal format for it.
    native: u32 = 0x8058,
    gl_type: u32 = GL_UNSIGNED_BYTE,

    fn of(color_space: gfx.ColorSpace) Pixels {
        return switch (color_space) {
            .scrgb => .{ .format = .rgba16f, .native = 0x881A, .gl_type = GL_HALF_FLOAT },
            .hdr10 => .{ .format = .rgb10a2, .native = 0x8059, .gl_type = GL_UNSIGNED_INT_2_10_10_10_REV },
            else => .{},
        };
    }
};

const Copy = struct {
    /// A pixel buffer the read goes into, and a fence for when it's done.
    buffer: u32 = 0,
    size: usize = 0,
    sync: ?*anyopaque = null,
    busy: bool = false,
    width: u32 = 0,
    height: u32 = 0,
    pixels: Pixels = .{},
    color_space: gfx.ColorSpace = .srgb,
};

/// Loaded with our context current.
const Gl = struct {
    readPixels: *const fn (i32, i32, i32, i32, u32, u32, ?*anyopaque) callconv(.winapi) void,
    readBuffer: *const fn (u32) callconv(.winapi) void,
    flush: *const fn () callconv(.winapi) void,
    /// Null before GL 3.2, then reads wait.
    pbo: ?Pbo,

    const Pbo = struct {
        genBuffers: *const fn (i32, *u32) callconv(.winapi) void,
        deleteBuffers: *const fn (i32, *const u32) callconv(.winapi) void,
        bindBuffer: *const fn (u32, u32) callconv(.winapi) void,
        bufferData: *const fn (u32, isize, ?*const anyopaque, u32) callconv(.winapi) void,
        mapBuffer: *const fn (u32, u32) callconv(.winapi) ?[*]const u8,
        unmapBuffer: *const fn (u32) callconv(.winapi) u8,
        fenceSync: *const fn (u32, u32) callconv(.winapi) ?*anyopaque,
        clientWaitSync: *const fn (?*anyopaque, u32, u64) callconv(.winapi) u32,
        deleteSync: *const fn (?*anyopaque) callconv(.winapi) void,
    };

    fn load() ?Gl {
        return .{
            .readPixels = opengl.glProc(@typeInfo(@FieldType(Gl, "readPixels")).pointer.child, "glReadPixels") orelse return null,
            .readBuffer = opengl.glProc(@typeInfo(@FieldType(Gl, "readBuffer")).pointer.child, "glReadBuffer") orelse return null,
            .flush = opengl.glProc(@typeInfo(@FieldType(Gl, "flush")).pointer.child, "glFlush") orelse return null,
            .pbo = loadPbo(),
        };
    }

    fn loadPbo() ?Pbo {
        var pbo: Pbo = undefined;
        const info = @typeInfo(Pbo).@"struct";
        inline for (info.field_names, info.field_types) |name, Field| {
            @field(pbo, name) = opengl.glProc(@typeInfo(Field).pointer.child, std.fmt.comptimePrint("gl{c}{s}", .{ comptime std.ascii.toUpper(name[0]), name[1..] })) orelse return null;
        }
        return pbo;
    }
};

const RenderWindowFn = fn ([*c]c.ImGuiViewport, ?*anyopaque) callconv(.c) void;

/// ImGui's window callbacks can't find it any other way.
var active: ?*State = null;

pub fn init(frame: *const Frame) error{BackendFailed}!OpenGl {
    const native = opengl.fromFrame(frame) orelse return error.BackendFailed;
    const context = opengl.createContext(native.dc) orelse return error.BackendFailed;
    errdefer opengl.deleteContext(context);
    const before = opengl.Current.swap(native.dc, context) orelse return error.BackendFailed;
    defer before.restore();

    const state = std.heap.page_allocator.create(State) catch return error.BackendFailed;
    errdefer std.heap.page_allocator.destroy(state);
    state.* = .{ .window = frame.window, .dc = native.dc, .context = context, .format = opengl.pixelFormatOf(native.dc), .gl = Gl.load() };

    if (!c.cImGui_ImplOpenGL2_Init()) return error.BackendFailed;
    active = state;
    const pio = c.ImGui_GetPlatformIO();
    state.render_window = pio.*.Renderer_RenderWindow;
    pio.*.Renderer_CreateWindow = createWindow;
    pio.*.Renderer_DestroyWindow = destroyWindow;
    pio.*.Renderer_RenderWindow = renderWindow;
    pio.*.Renderer_SwapBuffers = swapBuffers;
    return .{ .state = state };
}

pub fn deinit(self: *OpenGl) void {
    const s = self.state;
    // Make ours current so ImGui deletes its objects from ours. Else none, deleting the context frees all
    const before = opengl.Current.swap(s.dc, s.context) orelse opengl.Current.swap(null, null);
    if (opengl.currentContext() == s.context) s.dropCopies();
    s.flipped.deinit(std.heap.page_allocator);
    s.read.deinit(std.heap.page_allocator);
    c.cImGui_ImplOpenGL2_Shutdown();
    if (before) |b| b.restore();
    opengl.deleteContext(s.context);
    if (active == s) active = null;
    std.heap.page_allocator.destroy(s);
}

/// The game replacing its context doesn't affect ours.
pub fn matches(self: *const OpenGl, frame: *const Frame) bool {
    return frame.api == .opengl and frame.window == self.state.window;
}

pub fn beginFrame(self: *OpenGl, frame: *const Frame) bool {
    const native = opengl.fromFrame(frame) orelse return false;
    const s = self.state;
    s.dc = native.dc;
    const before = opengl.Current.swap(s.dc, s.context) orelse return false;
    defer before.restore();
    c.cImGui_ImplOpenGL2_NewFrame();
    return true;
}

pub fn drawStarted(_: *OpenGl) void {}

pub fn render(self: *OpenGl, frame: *const Frame, draw_data: *c.ImDrawData, captures: *capture.Captures) void {
    const s = self.state;
    const before = opengl.Current.swap(s.dc, s.context) orelse return;
    defer before.restore();
    s.copyAt(frame, .before, captures);
    c.cImGui_ImplOpenGL2_RenderDrawData(draw_data);
    s.copyAt(frame, .after, captures);
}

pub fn poll(self: *OpenGl, frame: *const Frame, captures: *capture.Captures) void {
    const s = self.state;
    const pbo = (s.gl orelse return).pbo orelse return;
    const native = opengl.fromFrame(frame) orelse return;
    const before = opengl.Current.swap(native.dc, s.context) orelse return;
    defer before.restore();
    for (&s.copies, 0..) |*copy, i| {
        if (captures.check(@fromBackingInt(@intCast(i)), copy.busy)) s.land(pbo, copy, @fromBackingInt(@intCast(i)), captures);
    }
}

/// Puts the game's context back after.
pub fn renderPlatformWindows(self: *OpenGl, _: *const Frame) void {
    const s = self.state;
    const before = opengl.Current.swap(s.dc, s.context) orelse return;
    defer before.restore();
    c.ImGui_RenderPlatformWindowsDefault();
}

pub fn releaseTarget(_: *OpenGl) void {}

// Outside windows. Each keeps its DC in `RendererUserData`, null leaves it blank.

fn createWindow(viewport: [*c]c.ImGuiViewport) callconv(.c) void {
    const s = active orelse return;
    const hwnd = viewport.*.PlatformHandle orelse return;
    const format = s.format orelse return;
    const dc = opengl.windowDc(@ptrCast(hwnd)) orelse return;
    if (!opengl.setPixelFormat(dc, format)) {
        log.warn("An ImGui window can't take the game window's pixel format; it stays blank", .{});
        opengl.releaseWindowDc(@ptrCast(hwnd), dc);
        return;
    }
    viewport.*.RendererUserData = dc;
}

fn destroyWindow(viewport: [*c]c.ImGuiViewport) callconv(.c) void {
    const dc = viewport.*.RendererUserData orelse return;
    if (viewport.*.PlatformHandle) |hwnd| opengl.releaseWindowDc(@ptrCast(hwnd), dc);
    viewport.*.RendererUserData = null;
}

fn renderWindow(viewport: [*c]c.ImGuiViewport, arg: ?*anyopaque) callconv(.c) void {
    const s = active orelse return;
    const dc = viewport.*.RendererUserData orelse return;
    if (!opengl.makeCurrent(dc, s.context)) return;
    if (s.render_window) |f| f(viewport, arg);
}

fn swapBuffers(viewport: [*c]c.ImGuiViewport, _: ?*anyopaque) callconv(.c) void {
    const dc = viewport.*.RendererUserData orelse return;
    _ = opengl.swapBuffers(dc);
}
