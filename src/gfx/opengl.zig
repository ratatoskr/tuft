//! OpenGL (WGL) bindings and present path.

const std = @import("std");

const hook = @import("tuft_hook");
const sys = @import("tuft_sys");
const tuft_window = @import("tuft_window");

const gfx = @import("root.zig");
const Tracker = @import("tracker.zig").Tracker;

/// `HDC`.
pub const Dc = *anyopaque;
/// `HGLRC`.
pub const Context = *anyopaque;

const BOOL = i32;

// Looked up at runtime so games don't all load opengl32.dll. Only called once it's loaded
fn wgl(comptime name: []const u8, comptime F: type) *const F {
    return sys.module.lazyFn("opengl32.dll", name, F) orelse std.debug.panic("opengl32.dll has no {s}", .{name});
}
fn wglCreateContext(dc: Dc) ?Context {
    return wgl("wglCreateContext", fn (Dc) callconv(.winapi) ?Context)(dc);
}
fn wglDeleteContext(context: Context) BOOL {
    return wgl("wglDeleteContext", fn (Context) callconv(.winapi) BOOL)(context);
}
fn wglMakeCurrent(dc: ?Dc, context: ?Context) BOOL {
    return wgl("wglMakeCurrent", fn (?Dc, ?Context) callconv(.winapi) BOOL)(dc, context);
}
fn wglGetCurrentContext() ?Context {
    return wgl("wglGetCurrentContext", fn () callconv(.winapi) ?Context)();
}
fn wglGetCurrentDC() ?Dc {
    return wgl("wglGetCurrentDC", fn () callconv(.winapi) ?Dc)();
}
fn wglSwapBuffers(dc: Dc) BOOL {
    return wgl("wglSwapBuffers", fn (Dc) callconv(.winapi) BOOL)(dc);
}

/// For the current context. GL 1.1 ones come straight from opengl32.dll.
pub fn glProc(comptime F: type, comptime name: [:0]const u8) ?*const F {
    const get = wgl("wglGetProcAddress", fn ([*:0]const u8) callconv(.winapi) ?*const anyopaque);
    // Some drivers return small numbers or -1 instead of null
    if (get(name.ptr)) |p| switch (@intFromPtr(p)) {
        1, 2, 3, std.math.maxInt(usize) => {},
        else => return @ptrCast(p),
    };
    return sys.module.lazyFn("opengl32.dll", name, F);
}

/// In `dc`'s pixel format. Shares nothing with other contexts.
pub fn createContext(dc: Dc) ?Context {
    return wglCreateContext(dc);
}

pub fn deleteContext(context: Context) void {
    _ = wglDeleteContext(context);
}

pub fn currentContext() ?Context {
    return wglGetCurrentContext();
}

pub fn windowOf(dc: Dc) ?tuft_window.Handle {
    return sys.win.WindowFromDC(dc);
}

/// Null for both clears it. False if it failed.
pub fn makeCurrent(dc: ?Dc, context: ?Context) bool {
    return wglMakeCurrent(dc, context) != 0;
}

pub fn swapBuffers(dc: Dc) bool {
    return SwapBuffers(dc) != 0;
}

/// Release with `releaseWindowDc`. Long-held ones want `CS_OWNDC`.
pub fn windowDc(hwnd: tuft_window.Handle) ?Dc {
    return sys.win.GetDC(hwnd);
}

pub fn releaseWindowDc(hwnd: tuft_window.Handle, dc: Dc) void {
    _ = sys.win.ReleaseDC(hwnd, dc);
}

pub const PixelFormat = struct {
    index: i32,
    descriptor: PixelFormatDescriptor,
};

pub fn pixelFormatOf(dc: Dc) ?PixelFormat {
    const index = GetPixelFormat(dc);
    if (index == 0) return null;
    var format: PixelFormat = .{ .index = index, .descriptor = .{} };
    if (DescribePixelFormat(dc, index, @sizeOf(PixelFormatDescriptor), &format.descriptor) == 0) return null;
    return format;
}

/// False if the window already has a different one, since it can only be set once.
pub fn setPixelFormat(dc: Dc, format: PixelFormat) bool {
    if (GetPixelFormat(dc) == format.index) return true;
    return SetPixelFormat(dc, format.index, &format.descriptor) != 0;
}

/// Put it back with `restore`.
pub const Current = struct {
    dc: ?Dc,
    context: ?Context,

    /// Returns what was current before, or null and no change if it failed.
    pub fn swap(dc: ?Dc, context: ?Context) ?Current {
        const before: Current = .{ .dc = wglGetCurrentDC(), .context = wglGetCurrentContext() };
        if (wglMakeCurrent(dc, context) == 0) return null;
        return before;
    }

    pub fn restore(self: Current) void {
        _ = wglMakeCurrent(self.dc, self.context);
    }
};

pub const Native = struct {
    dc: Dc,
    context: Context,
};

pub fn fromFrame(frame: *const gfx.Frame) ?Native {
    if (frame.api != .opengl) return null;
    return .{ .dc = frame.swap_chain, .context = frame.device };
}

pub const SwapBuffersFn = fn (dc: Dc) callconv(.winapi) BOOL;

/// Nesting depth on this thread, so `SwapBuffers` into `wglSwapBuffers` reports once.
threadlocal var swap_depth: u32 = 0;

/// The OpenGL path. Init `tuft_hook` first.
pub const PresentHook = struct {
    allocator: std.mem.Allocator,
    swap_hook: *hook.TypedHook(SwapBuffersFn),
    tracker: Tracker(Source),

    /// Hook starts disabled. Loads Windows' `opengl32.dll` if the game hasn't.
    pub fn create(allocator: std.mem.Allocator, listener: gfx.Listener) !*PresentHook {
        const opengl32 = try sys.module.systemBase("opengl32.dll");
        const address = sys.module.findExport(opengl32, "wglSwapBuffers") orelse return error.NoSwapBuffers;

        const self = try allocator.create(PresentHook);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .swap_hook = undefined, .tracker = .{ .listener = listener } };
        self.swap_hook = try hook.memory.Address.at(address).createFn(SwapBuffersFn, onSwapBuffers, self);
        return self;
    }

    pub fn enable(self: *PresentHook) !void {
        try self.swap_hook.enable();
    }

    /// Unhooks, waiting for swaps in flight.
    pub fn destroy(self: *PresentHook) void {
        self.swap_hook.destroy();
        self.tracker.deinit();
        self.allocator.destroy(self);
    }

    fn onSwapBuffers(self: *PresentHook, h: *hook.TypedHook(SwapBuffersFn), dc: Dc) BOOL {
        swap_depth += 1;
        defer swap_depth -= 1;
        // The swapper has their context current. No context, nothing to draw with
        if (swap_depth == 1) if (wglGetCurrentContext()) |context| {
            self.tracker.presented();
            self.tracker.source.dc = dc;
            if (self.tracker.current(context)) |f| f.swap_chain = dc;
            self.tracker.present(context);
        };
        return h.original()(dc);
    }

    const Source = struct {
        pub const Key = Context;
        pub const noun = "context";

        dc: ?Dc = null,

        pub fn keyOf(f: *const gfx.Frame) Key {
            return f.device;
        }

        pub fn windowOf(self: Source, _: Key) ?*anyopaque {
            return sys.win.WindowFromDC(self.dc orelse return null);
        }

        pub fn attach(self: Source, context: Key) !gfx.Frame {
            const dc = self.dc orelse return error.NoDc;
            const hwnd = sys.win.WindowFromDC(dc) orelse return error.NoOutputWindow;
            return .{ .api = .opengl, .window = hwnd, .swap_chain = dc, .device = context };
        }

        /// OpenGL handles aren't ref counted.
        pub fn release(_: *const gfx.Frame) void {}
    };
};

/// `PIXELFORMATDESCRIPTOR`. Defaults give a double-buffered RGBA window format.
pub const PixelFormatDescriptor = extern struct {
    size: u16 = @sizeOf(PixelFormatDescriptor),
    version: u16 = 1,
    flags: u32 = 0x4 | 0x20 | 0x1, // PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER
    pixel_type: u8 = 0, // PFD_TYPE_RGBA
    color_bits: u8 = 32,
    red_bits: u8 = 0,
    red_shift: u8 = 0,
    green_bits: u8 = 0,
    green_shift: u8 = 0,
    blue_bits: u8 = 0,
    blue_shift: u8 = 0,
    alpha_bits: u8 = 8,
    alpha_shift: u8 = 0,
    accum_bits: u8 = 0,
    accum_red_bits: u8 = 0,
    accum_green_bits: u8 = 0,
    accum_blue_bits: u8 = 0,
    accum_alpha_bits: u8 = 0,
    depth_bits: u8 = 24,
    stencil_bits: u8 = 8,
    aux_buffers: u8 = 0,
    layer_type: u8 = 0,
    reserved: u8 = 0,
    layer_mask: u32 = 0,
    visible_mask: u32 = 0,
    damage_mask: u32 = 0,
};

extern "gdi32" fn ChoosePixelFormat(dc: Dc, pfd: *const PixelFormatDescriptor) callconv(.winapi) i32;
extern "gdi32" fn SetPixelFormat(dc: Dc, format: i32, pfd: *const PixelFormatDescriptor) callconv(.winapi) BOOL;
extern "gdi32" fn GetPixelFormat(dc: Dc) callconv(.winapi) i32;
extern "gdi32" fn DescribePixelFormat(dc: Dc, format: i32, size: u32, pfd: *PixelFormatDescriptor) callconv(.winapi) i32;
extern "gdi32" fn SwapBuffers(dc: Dc) callconv(.winapi) BOOL;

/// Our own window and context, for tests.
pub const OwnedContext = struct {
    hwnd: tuft_window.Handle,
    owns_window: bool,
    dc: Dc,
    context: Context,

    pub fn create() !OwnedContext {
        const hwnd = try tuft_window.createHidden();
        errdefer tuft_window.destroy(hwnd);
        var owned = try createOn(hwnd);
        owned.owns_window = true;
        return owned;
    }

    /// Makes it current.
    pub fn createOn(hwnd: tuft_window.Handle) !OwnedContext {
        const dc = sys.win.GetDC(hwnd) orelse return error.NoDc;
        errdefer _ = sys.win.ReleaseDC(hwnd, dc);
        const pfd: PixelFormatDescriptor = .{};
        const format = ChoosePixelFormat(dc, &pfd);
        if (format == 0) return error.NoPixelFormat;
        // Pixel format can only be set once, so a second context reuses it
        _ = SetPixelFormat(dc, format, &pfd);
        const context = wglCreateContext(dc) orelse return error.CreateContextFailed;
        errdefer _ = wglDeleteContext(context);
        if (wglMakeCurrent(dc, context) == 0) return error.MakeCurrentFailed;
        return .{ .hwnd = hwnd, .owns_window = false, .dc = dc, .context = context };
    }

    pub fn makeCurrent(self: OwnedContext) void {
        _ = wglMakeCurrent(self.dc, self.context);
    }

    /// Like most games, through gdi32's `SwapBuffers`.
    pub fn swap(self: OwnedContext) bool {
        return SwapBuffers(self.dc) != 0;
    }

    pub fn wglSwap(self: OwnedContext) bool {
        return wglSwapBuffers(self.dc) != 0;
    }

    pub fn destroy(self: OwnedContext) void {
        if (wglGetCurrentContext() == self.context) _ = wglMakeCurrent(null, null);
        _ = wglDeleteContext(self.context);
        _ = sys.win.ReleaseDC(self.hwnd, self.dc);
        if (self.owns_window) tuft_window.destroy(self.hwnd);
    }
};

const tests = struct {
    const testing = std.testing;

    const Recorder = struct {
        attaches: u32 = 0,
        frames: u32 = 0,
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
        pub fn onResize(_: *Recorder, _: *const gfx.Frame) void {}
        pub fn onDetach(self: *Recorder, _: *const gfx.Frame) void {
            self.detaches += 1;
        }
    };

    fn quiet() std.log.Level {
        const saved = testing.log_level;
        testing.log_level = .err;
        return saved;
    }

    test "reports each swap once" {
        const saved = quiet();
        defer testing.log_level = saved;
        try hook.init(testing.allocator);
        defer hook.deinit();

        const owned = try OwnedContext.create();
        defer owned.destroy();
        var recorder: Recorder = .{};
        const present = try PresentHook.create(testing.allocator, .of(Recorder, &recorder));
        try present.enable();

        try testing.expect(owned.swap());
        try testing.expect(owned.wglSwap());
        try testing.expectEqual(1, recorder.attaches);
        try testing.expectEqual(2, recorder.frames);
        const frame = recorder.last.?;
        try testing.expectEqual(gfx.Api.opengl, frame.api);
        try testing.expectEqual(@as(*anyopaque, owned.hwnd), frame.window);
        try testing.expectEqual(owned.context, frame.device);
        try testing.expectEqual(owned.dc, frame.swap_chain);
        try testing.expectEqual(owned.context, fromFrame(&frame).?.context);

        present.destroy();
        _ = owned.swap();
        try testing.expectEqual(2, recorder.frames);
    }

    test "no context no report" {
        try hook.init(testing.allocator);
        defer hook.deinit();

        const owned = try OwnedContext.create();
        defer owned.destroy();
        var recorder: Recorder = .{};
        const present = try PresentHook.create(testing.allocator, .of(Recorder, &recorder));
        defer present.destroy();
        try present.enable();

        _ = wglMakeCurrent(null, null);
        _ = owned.swap();
        try testing.expectEqual(0, recorder.frames);
    }

    test "new context detaches old" {
        const saved = quiet();
        defer testing.log_level = saved;
        try hook.init(testing.allocator);
        defer hook.deinit();

        const first = try OwnedContext.create();
        defer first.destroy();
        var recorder: Recorder = .{};
        const present = try PresentHook.create(testing.allocator, .of(Recorder, &recorder));
        defer present.destroy();
        try present.enable();

        _ = first.swap();
        try testing.expectEqual(1, recorder.attaches);

        const replacement = try OwnedContext.createOn(first.hwnd);
        defer replacement.destroy();
        _ = replacement.swap();
        try testing.expectEqual(1, recorder.detaches);
        try testing.expectEqual(2, recorder.attaches);
        try testing.expectEqual(replacement.context, recorder.last.?.device);

        const elsewhere = try OwnedContext.create();
        defer elsewhere.destroy();
        const frames = recorder.frames;
        _ = elsewhere.swap();
        try testing.expectEqual(frames, recorder.frames);
    }

    test "draws to matching window" {
        const owned = try OwnedContext.create();
        defer owned.destroy();
        const format = pixelFormatOf(owned.dc).?;

        const other = try tuft_window.createHidden();
        defer tuft_window.destroy(other);
        const dc = windowDc(other).?;
        defer releaseWindowDc(other, dc);
        try testing.expectEqual(null, pixelFormatOf(dc));
        try testing.expect(setPixelFormat(dc, format));
        try testing.expectEqual(format.index, pixelFormatOf(dc).?.index);
        try testing.expect(setPixelFormat(dc, format)); // already set, nothing to do

        try testing.expect(makeCurrent(dc, owned.context));
        try testing.expect(swapBuffers(dc));
        owned.makeCurrent();
    }

    test "Current.swap and restore" {
        const a = try OwnedContext.create();
        defer a.destroy();
        const b = try OwnedContext.create();
        defer b.destroy();
        a.makeCurrent();
        const before = Current.swap(b.dc, b.context).?;
        try testing.expectEqual(b.context, currentContext().?);
        before.restore();
        try testing.expectEqual(a.context, currentContext().?);
    }
};

test {
    _ = tests;
}
