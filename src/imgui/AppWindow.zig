//! An ImGui app window on its own thread, inside the game's process.

const AppWindow = @This();

const std = @import("std");

const gfx = @import("tuft_gfx");
const tuft_arch = @import("tuft_arch");
const tuft_input = @import("tuft_input");
const tuft_window = @import("tuft_window");
const sys = @import("tuft_sys");
const ui = @import("tuft_ui");
const win = sys.win;

const c = @import("root.zig").c;

const log = std.log.scoped(.tuft_imgui);

pub const Callback = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque) void,
};

pub const Options = struct {
    title: []const u8,
    /// Every frame while shown, on its thread.
    draw: Callback,
    /// Also every `tick_ms` while hidden.
    tick: ?Callback = null,
    /// Once when the context's made.
    setup: ?Callback = null,
    /// When one of its windows gets activated.
    activated: ?Callback = null,
    ini_path: ?[]const u8 = null,
    /// Unscaled.
    size: [2]i32 = .{ 1280, 800 },
    topmost: bool = false,
    background: [4]f32 = .{ 0.06, 0.06, 0.07, 1 },
    /// Keep our own window hidden so every ImGui window pops out. `draw` makes the main one.
    floating: bool = false,
    /// Icon resource name, used for every window it makes.
    icon: ?[]const u8 = null,
};

pub const tick_ms = 50;

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("TuftImGuiApp");
const QS_ALLINPUT: u32 = 0x04FF;

allocator: std.mem.Allocator,
options: Options,
title: [:0]u16,
ini_path: ?[:0]u8,
thread: win.HANDLE,
wake: win.HANDLE,
want_shown: std.atomic.Value(bool) = .init(false),
want_raise: std.atomic.Value(bool) = .init(false),
want_topmost: std.atomic.Value(bool),
stop: std.atomic.Value(bool) = .init(false),
thread_id: std.atomic.Value(u32) = .init(0),
frames: std.atomic.Value(u32) = .init(0),
ticks: std.atomic.Value(u32) = .init(0),
failure: ?anyerror = null,
/// Its thread couldn't make the window, and stopped. `failure` says why. Any thread.
failed_flag: tuft_arch.atomic.Value(bool) = .init(false),
/// Drawn over its windows each frame while shown. Push from any thread. Needs tuft_ui bound.
toasts: ui.Toasts = .{},

// Its thread only
hwnd: ?win.HWND = null,
swap: ?gfx.d3d11.OwnedSwapChain = null,
target: ?*gfx.d3d11.RenderTargetView = null,
target_size: [2]u32 = .{ 0, 0 },
visible: bool = false,
topmost: bool = false,
foreground: bool = false,
/// With `floating`, `draw` raises it with `takeRaise`.
raise_pending: bool = false,
icons: [2]?*anyopaque = .{ null, null },

/// Starts its thread, which makes the window hidden. Doesn't wait; check `failed` later.
pub fn create(allocator: std.mem.Allocator, options: Options) !*AppWindow {
    const self = try allocator.create(AppWindow);
    errdefer allocator.destroy(self);
    const title = try std.unicode.utf8ToUtf16LeAllocZ(allocator, options.title);
    errdefer allocator.free(title);
    const ini_path = if (options.ini_path) |p| try allocator.dupeSentinel(u8, p, 0) else null;
    errdefer if (ini_path) |p| allocator.free(p);
    const wake = win.CreateEventW(null, .FALSE, .FALSE, null) orelse return error.CreateEventFailed;
    errdefer win.CloseHandle(wake);
    self.* = .{
        .allocator = allocator,
        .options = options,
        .title = title,
        .ini_path = ini_path,
        .thread = undefined,
        .wake = wake,
        .want_topmost = .init(options.topmost),
    };
    self.options.ini_path = null;

    // Not std.Thread, its spawn fails on threads with an activation context
    self.thread = win.CreateThread(null, 0, Start.run, self, 0, null) orelse return error.CreateThreadFailed;
    return self;
}

/// Stops its thread and saves the layout.
pub fn destroy(self: *AppWindow) void {
    self.stop.store(true, .release);
    _ = win.SetEvent(self.wake);
    _ = win.WaitForSingleObject(self.thread, win.INFINITE);
    win.CloseHandle(self.thread);
    win.CloseHandle(self.wake);
    self.allocator.free(self.title);
    if (self.ini_path) |p| self.allocator.free(p);
    self.toasts.deinit();
    self.allocator.destroy(self);
}

/// Its thread couldn't make the window, and stopped. `destroy` it. Any thread.
pub fn failed(self: *const AppWindow) ?anyerror {
    if (!self.failed_flag.load(.acquire)) return null;
    return self.failure orelse error.Failed;
}

/// Any thread.
pub fn show(self: *AppWindow) void {
    self.want_shown.store(true, .release);
    self.want_raise.store(true, .release);
    _ = win.SetEvent(self.wake);
}

/// Any thread.
pub fn hide(self: *AppWindow) void {
    self.want_shown.store(false, .release);
    _ = win.SetEvent(self.wake);
}

/// Any thread.
pub fn isOpen(self: *const AppWindow) bool {
    return self.want_shown.load(.acquire);
}

/// Any thread. With `floating` it's only stored for `draw` to apply.
pub fn setTopmost(self: *AppWindow, on: bool) void {
    self.want_topmost.store(on, .release);
    _ = win.SetEvent(self.wake);
}

pub fn isTopmost(self: *const AppWindow) bool {
    return self.want_topmost.load(.acquire);
}

/// With `floating`, whether `show` asked to raise it. Its thread.
pub fn takeRaise(self: *AppWindow) bool {
    defer self.raise_pending = false;
    return self.raise_pending;
}

/// A `show` raise not yet taken by a frame; other focus requests wait for it. Its thread.
pub fn raising(self: *const AppWindow) bool {
    return self.raise_pending or self.want_raise.load(.acquire);
}

pub fn frameCount(self: *const AppWindow) u32 {
    return self.frames.load(.acquire);
}

pub fn tickCount(self: *const AppWindow) u32 {
    return self.ticks.load(.acquire);
}

/// One of its windows is in front. Its thread.
pub fn isActive(self: *const AppWindow) bool {
    return self.foreground;
}

/// Any thread.
pub fn ownsWindow(_: ?*anyopaque, window: tuft_window.Handle) bool {
    const id = tuft_window.threadOf(window);
    if (id == 0) return false;
    for (&threads) |*slot| if (slot.load(.acquire) == id) return true;
    return false;
}

var threads: [8]std.atomic.Value(u32) = @splat(.init(0));

// Its thread

const Start = struct {
    fn run(param: ?*anyopaque) callconv(.winapi) win.DWORD {
        const self: *AppWindow = @ptrCast(@alignCast(param.?));
        const id = win.GetCurrentThreadId();
        self.thread_id.store(id, .release);
        for (&threads) |*slot| if (slot.cmpxchgStrong(0, id, .acq_rel, .acquire) == null) break;
        defer for (&threads) |*slot| {
            _ = slot.cmpxchgStrong(id, 0, .acq_rel, .acquire);
        };
        // ImGui's backend reads key state, so bypass the blocker
        const bypass = tuft_input.Blocker.Bypass.begin();
        defer bypass.end();
        if (sys.module.lazyFn("user32.dll", "SetThreadDpiAwarenessContext", win.SetThreadDpiAwarenessContextFn)) |set| {
            _ = set(win.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        }

        const context = self.open() catch |err| {
            self.failure = err;
            self.close(null);
            self.failed_flag.store(true, .release);
            return 1;
        };
        self.loop();
        self.close(context);
        return 0;
    }
};

fn instance() ?win.HINSTANCE {
    return @ptrFromInt(sys.module.selfBase());
}

fn open(self: *AppWindow) !*c.ImGuiContext {
    self.loadIcons();
    const class: win.WNDCLASSEXW = .{
        .style = win.CS_HREDRAW | win.CS_VREDRAW,
        .lpfnWndProc = &wndProc,
        .hInstance = instance(),
        .hIcon = self.icons[0],
        .hIconSm = self.icons[1],
        .hCursor = win.LoadCursorW(null, win.IDC_ARROW),
        .lpszClassName = class_name,
    };
    if (win.RegisterClassExW(&class) == 0 and @backingInt(win.GetLastError()) != win.ERROR_CLASS_ALREADY_EXISTS) {
        return error.RegisterClassFailed;
    }
    const floating = self.options.floating;
    const style = if (floating) win.WS_POPUP else win.WS_OVERLAPPEDWINDOW;
    const ex_style = if (floating) win.WS_EX_TOOLWINDOW else win.WS_EX_APPWINDOW;
    var rect: win.RECT = .{ .right = if (floating) 0 else self.options.size[0], .bottom = if (floating) 0 else self.options.size[1] };
    if (!floating) _ = win.AdjustWindowRectEx(&rect, style, .FALSE, ex_style);
    const x = if (floating) 0 else win.CW_USEDEFAULT;
    const hwnd = win.CreateWindowExW(ex_style, class_name, self.title, style, x, x, rect.right - rect.left, rect.bottom - rect.top, null, null, instance(), null) orelse return error.CreateWindowFailed;
    self.hwnd = hwnd;
    _ = win.SetWindowLongPtrW(hwnd, win.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
    gfx.own_windows.add(hwnd);
    self.swap = try gfx.d3d11.OwnedSwapChain.createOn(hwnd);

    const context = c.ImGui_CreateContext(null) orelse return error.CreateContextFailed;
    errdefer c.ImGui_DestroyContext(context);
    c.ImGui_SetCurrentContext(context);
    const io = c.ImGui_GetIO();
    io.*.ConfigFlags |= c.ImGuiConfigFlags_DockingEnable | c.ImGuiConfigFlags_ViewportsEnable;
    io.*.IniFilename = if (self.ini_path) |p| @ptrCast(p.ptr) else null;
    // Nothing can go back into the hidden one
    if (floating) io.*.ConfigViewportsNoAutoMerge = true;
    if (!c.cImGui_ImplWin32_Init(hwnd)) return error.BackendFailed;
    errdefer shutdownWin32();
    keepPlatformClass();
    // ImGui's own is compiled out with clang
    c.ImGui_GetPlatformIO().*.Platform_SetImeDataFn = placeIme;
    if (!c.cImGui_ImplDX11_Init(@ptrCast(self.swap.?.device), @ptrCast(self.swap.?.context))) return error.BackendFailed;
    if (self.options.setup) |s| s.func(s.ctx);
    return context;
}

fn close(self: *AppWindow, context: ?*c.ImGuiContext) void {
    if (context) |ctx| {
        c.ImGui_SetCurrentContext(ctx);
        c.cImGui_ImplDX11_Shutdown();
        shutdownWin32();
        c.ImGui_DestroyContext(ctx);
    }
    self.releaseTarget();
    if (self.swap) |s| s.destroy();
    self.swap = null;
    if (self.hwnd) |hwnd| {
        gfx.own_windows.remove(hwnd);
        _ = win.SetWindowLongPtrW(hwnd, win.GWLP_USERDATA, 0);
        _ = win.DestroyWindow(hwnd);
    }
    self.hwnd = null;
    // Fails while another app window still uses it
    _ = win.UnregisterClassW(class_name, instance());
    for (&self.icons) |*icon| {
        if (icon.*) |i| _ = win.DestroyIcon(i);
        icon.* = null;
    }
}

/// ImGui's Win32 backend shares one window class across contexts and any shutdown can unregister it,
/// so it's re-registered before every window and shutdowns wait while one's being made.
const platform_class = struct {
    const name = std.unicode.utf8ToUtf16LeStringLiteral("ImGui Platform");
    var lock: sys.sync.RwLock = .{};
    var info: ?win.WNDCLASSEXW = null;
    var create: ?*const fn (?*c.ImGuiViewport) callconv(.c) void = null;
};

/// Right after the backend's init, on its context.
fn keepPlatformClass() void {
    const pio = c.ImGui_GetPlatformIO();
    platform_class.lock.lock();
    defer platform_class.lock.unlock();
    if (platform_class.info == null) {
        var info: win.WNDCLASSEXW = .{ .lpfnWndProc = undefined, .lpszClassName = platform_class.name };
        if (win.GetClassInfoExW(win.GetModuleHandleW(null), platform_class.name, &info) == .FALSE) return;
        info.cbSize = @sizeOf(win.WNDCLASSEXW);
        info.lpszClassName = platform_class.name;
        platform_class.info = info;
        platform_class.create = pio.*.Platform_CreateWindow;
    }
    pio.*.Platform_CreateWindow = createPlatformWindow;
}

fn createPlatformWindow(viewport: ?*c.ImGuiViewport) callconv(.c) void {
    platform_class.lock.lock();
    defer platform_class.lock.unlock();
    // Fails when it's already there, which is fine
    _ = win.RegisterClassExW(&platform_class.info.?);
    platform_class.create.?(viewport);
}

fn shutdownWin32() void {
    platform_class.lock.lock();
    defer platform_class.lock.unlock();
    c.cImGui_ImplWin32_Shutdown();
}

/// Puts the IME's windows at the caret. Its thread made every window it draws in, which IMM wants.
fn placeIme(_: ?*c.ImGuiContext, viewport: ?*c.ImGuiViewport, data: ?*c.ImGuiPlatformImeData) callconv(.c) void {
    const vp = viewport orelse return;
    const d = (data orelse return).*;
    if (!d.WantVisible) return;
    const hwnd: win.HWND = @ptrCast(vp.*.PlatformHandleRaw orelse return);
    tuft_input.Ime.placeOn(hwnd, .{
        .x = @intFromFloat(d.InputPos.x - vp.*.Pos.x),
        .y = @intFromFloat(d.InputPos.y - vp.*.Pos.y),
        .line_height = @intFromFloat(d.InputLineHeight),
    });
}

fn loadIcons(self: *AppWindow) void {
    const name = self.options.icon orelse return;
    var buf: [64:0]u16 = undefined;
    const len = std.unicode.utf8ToUtf16Le(&buf, name[0..@min(name.len, buf.len)]) catch return;
    buf[len] = 0;
    const sizes = [2][2]i32{ .{ win.SM_CXICON, win.SM_CYICON }, .{ win.SM_CXSMICON, win.SM_CYSMICON } };
    for (&self.icons, sizes) |*icon, size| {
        icon.* = win.LoadImageW(instance(), buf[0..len :0], win.IMAGE_ICON, win.GetSystemMetrics(size[0]), win.GetSystemMetrics(size[1]), 0);
    }
}

/// ImGui's own windows have no icon, so give them ours.
fn iconViewports(self: *AppWindow) void {
    const big = self.icons[0] orelse return;
    const viewports = c.ImGui_GetPlatformIO().*.Viewports;
    for (0..@intCast(viewports.Size)) |i| {
        const hwnd: win.HWND = @ptrCast(viewports.Data[i].*.PlatformHandle orelse continue);
        if (win.SendMessageW(hwnd, win.WM_GETICON, win.ICON_BIG, 0) != 0) continue;
        _ = win.SendMessageW(hwnd, win.WM_SETICON, win.ICON_BIG, @bitCast(@intFromPtr(big)));
        if (self.icons[1]) |small| _ = win.SendMessageW(hwnd, win.WM_SETICON, win.ICON_SMALL, @bitCast(@intFromPtr(small)));
    }
}

fn loop(self: *AppWindow) void {
    const handles = [_]win.HANDLE{self.wake};
    while (!self.stop.load(.acquire)) {
        self.applyWants();
        self.watchForeground();
        if (self.visible) {
            pump();
            if (self.stop.load(.acquire)) break;
            self.runTick();
            self.frame();
        } else {
            _ = win.MsgWaitForMultipleObjects(1, &handles, .FALSE, tick_ms, QS_ALLINPUT);
            pump();
            self.runTick();
        }
    }
    if (self.visible) self.disappear();
}

/// Not done in a wndproc since ImGui's windows have their own.
fn watchForeground(self: *AppWindow) void {
    const front = win.GetForegroundWindow();
    const ours = if (front) |f| tuft_window.threadOf(f) == self.thread_id.load(.acquire) else false;
    if (ours and !self.foreground) if (self.options.activated) |a| a.func(a.ctx);
    self.foreground = ours;
}

fn runTick(self: *AppWindow) void {
    if (self.options.tick) |t| t.func(t.ctx);
    _ = self.ticks.fetchAdd(1, .release);
}

fn pump() void {
    var m: win.MSG = .{};
    while (win.PeekMessageW(&m, null, 0, 0, win.PM_REMOVE).toBool()) {
        _ = win.TranslateMessage(&m);
        _ = win.DispatchMessageW(&m);
    }
}

fn applyWants(self: *AppWindow) void {
    const hwnd = self.hwnd.?;
    const floating = self.options.floating;
    const topmost = self.want_topmost.load(.acquire);
    if (topmost != self.topmost) {
        const after: isize = if (topmost) win.HWND_TOPMOST else win.HWND_NOTOPMOST;
        if (!floating) _ = win.SetWindowPos(hwnd, @ptrFromInt(@as(usize, @bitCast(after))), 0, 0, 0, 0, win.SWP_NOMOVE | win.SWP_NOSIZE | win.SWP_NOACTIVATE);
        self.topmost = topmost;
    }
    const shown = self.want_shown.load(.acquire);
    if (shown and !self.visible) {
        if (!floating) _ = win.ShowWindow(hwnd, win.SW_SHOW);
        self.visible = true;
    } else if (!shown and self.visible) {
        self.disappear();
    }
    if (shown and self.want_raise.swap(false, .acq_rel)) {
        if (floating) {
            self.raise_pending = true;
        } else {
            if (win.IsIconic(hwnd).toBool()) _ = win.ShowWindow(hwnd, win.SW_RESTORE);
            _ = tuft_window.bringToFront(hwnd);
        }
    }
}

fn disappear(self: *AppWindow) void {
    // Outside windows would linger with nobody drawing them
    tuft_imgui_destroy_viewport_windows();
    if (!self.options.floating) _ = win.ShowWindow(self.hwnd.?, win.SW_HIDE);
    self.visible = false;
}

extern fn tuft_imgui_destroy_viewport_windows() void;

fn frame(self: *AppWindow) void {
    if (self.options.floating) return self.floatingFrame();
    const hwnd = self.hwnd.?;
    const swap = self.swap.?;
    if (win.IsIconic(hwnd).toBool()) {
        sys.thread.sleepMs(tick_ms);
        return;
    }
    const size = tuft_window.clientSize(hwnd);
    if (size.width == 0 or size.height == 0) {
        sys.thread.sleepMs(tick_ms);
        return;
    }
    if (size.width != self.target_size[0] or size.height != self.target_size[1]) {
        self.releaseTarget();
        _ = swap.swap_chain.resizeBuffers(0, size.width, size.height, 0, 0);
        self.target_size = .{ size.width, size.height };
    }
    const target = self.renderTarget() orelse {
        sys.thread.sleepMs(tick_ms);
        return;
    };

    c.cImGui_ImplDX11_NewFrame();
    c.cImGui_ImplWin32_NewFrame();
    c.ImGui_NewFrame();
    self.options.draw.func(self.options.draw.ctx);
    self.drawToasts();
    c.ImGui_Render();
    swap.context.setRenderTarget(target);
    swap.context.clearRenderTarget(target, self.options.background);
    c.cImGui_ImplDX11_RenderDrawData(c.ImGui_GetDrawData());
    if (c.ImGui_GetIO().*.ConfigFlags & c.ImGuiConfigFlags_ViewportsEnable != 0) {
        c.ImGui_UpdatePlatformWindows();
        c.ImGui_RenderPlatformWindowsDefault();
        self.iconViewports();
    }
    _ = swap.swap_chain.present(1, 0);
    _ = self.frames.fetchAdd(1, .release);
}

fn floatingFrame(self: *AppWindow) void {
    c.cImGui_ImplDX11_NewFrame();
    c.cImGui_ImplWin32_NewFrame();
    c.ImGui_NewFrame();
    self.options.draw.func(self.options.draw.ctx);
    self.drawToasts();
    c.ImGui_Render();
    c.ImGui_UpdatePlatformWindows();
    c.ImGui_RenderPlatformWindowsDefault();
    self.iconViewports();
    waitForVsync();
    _ = self.frames.fetchAdd(1, .release);
}

fn drawToasts(self: *AppWindow) void {
    if (!ui.isBound()) return;
    // With `floating` the main viewport is hidden, so they follow the window in use
    self.toasts.draw(.{ .viewport = if (self.options.floating) .focused else .main });
}

/// Waits once for the compositor instead of a vblank per outside window.
fn waitForVsync() void {
    if (sys.module.lazyFn("dwmapi.dll", "DwmFlush", win.DwmFlushFn)) |flush| {
        if (flush() >= 0) return;
    }
    sys.thread.sleepMs(16);
}

fn renderTarget(self: *AppWindow) ?*gfx.d3d11.RenderTargetView {
    if (self.target) |t| return t;
    const swap = self.swap.?;
    var buffer: ?*anyopaque = null;
    if (!gfx.com.succeeded(swap.swap_chain.getBuffer(0, &gfx.d3d11.IID_ID3D11Texture2D, &buffer))) return null;
    defer gfx.com.release(buffer.?);
    var view: ?*gfx.d3d11.RenderTargetView = null;
    if (!gfx.com.succeeded(swap.device.createRenderTargetView(buffer.?, &view))) return null;
    self.target = view;
    return view;
}

fn releaseTarget(self: *AppWindow) void {
    if (self.target) |t| gfx.com.release(t);
    self.target = null;
    self.target_size = .{ 0, 0 };
}

// Window proc, on its thread with its context current

extern fn cImGui_ImplWin32_WndProcHandler(hwnd: win.HWND, msg: u32, wparam: usize, lparam: isize) callconv(.c) isize;

fn wndProc(hwnd: win.HWND, msg: u32, wparam: usize, lparam: isize) callconv(.winapi) isize {
    const user_data: usize = @bitCast(win.GetWindowLongPtrW(hwnd, win.GWLP_USERDATA));
    if (user_data == 0) return win.DefWindowProcW(hwnd, msg, wparam, lparam);
    const self: *AppWindow = @ptrFromInt(user_data);
    if (c.ImGui_GetCurrentContext() != null and cImGui_ImplWin32_WndProcHandler(hwnd, msg, wparam, lparam) != 0) return 1;
    switch (msg) {
        // Alt would open the window menu and freeze our frames
        win.WM_SYSCOMMAND => if (wparam & 0xFFF0 == win.SC_KEYMENU) return 0,
        win.WM_CLOSE => {
            self.want_shown.store(false, .release);
            return 0;
        },
        else => {},
    }
    return win.DefWindowProcW(hwnd, msg, wparam, lparam);
}

const tests = struct {
    const testing = std.testing;

    const Probe = struct {
        draws: std.atomic.Value(u32) = .init(0),
        context: std.atomic.Value(?*c.ImGuiContext) = .init(null),
        outside_ours: std.atomic.Value(bool) = .init(false),

        fn draw(ctx: *anyopaque) void {
            const self: *Probe = @ptrCast(@alignCast(ctx));
            self.context.store(c.ImGui_GetCurrentContext(), .release);
            _ = c.ImGui_DockSpaceOverViewport();
            _ = c.ImGui_Begin(@ptrCast("docked"), null, 0);
            c.ImGui_End();

            const main = c.ImGui_GetMainViewport();
            c.ImGui_SetNextWindowPos(.{ .x = main.*.Pos.x + main.*.Size.x + 40, .y = main.*.Pos.y }, c.ImGuiCond_Always);
            _ = c.ImGui_Begin(@ptrCast("outside"), null, 0);
            c.ImGui_End();
            const viewports = c.ImGui_GetPlatformIO().*.Viewports;
            for (0..@intCast(viewports.Size)) |i| {
                const vp = viewports.Data[i];
                if (vp == main) continue;
                const hwnd: win.HWND = @ptrCast(vp.*.PlatformHandle orelse continue);
                if (ownsWindow(null, hwnd)) self.outside_ours.store(true, .release);
            }
            _ = self.draws.fetchAdd(1, .release);
        }
    };

    /// Till its thread's made the window. No GPU, like some CI machines, skips.
    fn started(app: *AppWindow) !void {
        for (0..5000) |_| {
            if (app.failed()) |err| return switch (err) {
                error.CreateDeviceFailed, error.NoD3D11 => error.SkipZigTest,
                else => err,
            };
            if (app.tickCount() > 0) return;
            sys.thread.sleepMs(1);
        }
        return error.TimedOut;
    }

    fn waitFor(counter: *const std.atomic.Value(u32), at_least: u32) !void {
        for (0..3000) |_| {
            if (counter.load(.acquire) >= at_least) return;
            sys.thread.sleepMs(1);
        }
        return error.TimedOut;
    }

    test "docked with outside windows" {
        const ours = c.ImGui_CreateContext(null) orelse return error.CreateContextFailed;
        defer c.ImGui_DestroyContext(ours);
        c.ImGui_SetCurrentContext(ours);

        var probe: Probe = .{};
        const app = try AppWindow.create(testing.allocator, .{ .title = "tuft test", .size = .{ 320, 200 }, .draw = .{ .ctx = &probe, .func = Probe.draw } });
        defer app.destroy();
        try started(app);
        try testing.expect(!app.isOpen());
        try waitFor(&app.ticks, 2);
        try testing.expectEqual(0, app.frameCount());

        app.show();
        try waitFor(&app.frames, 4);
        try testing.expect(probe.context.load(.acquire) != ours);
        try testing.expectEqual(ours, c.ImGui_GetCurrentContext());
        try testing.expect(probe.outside_ours.load(.acquire));
        app.hide();
        sys.thread.sleepMs(100);
        const stopped = app.frameCount();
        sys.thread.sleepMs(100);
        try testing.expectEqual(stopped, app.frameCount());

        app.setTopmost(true);
        app.show();
        try waitFor(&app.frames, stopped + 2);
        try testing.expect(app.isTopmost());
    }

    const Floating = struct {
        draws: std.atomic.Value(u32) = .init(0),
        popped_out: std.atomic.Value(bool) = .init(false),

        fn draw(ctx: *anyopaque) void {
            const self: *Floating = @ptrCast(@alignCast(ctx));
            c.ImGui_SetNextWindowPos(.{ .x = 200, .y = 200 }, c.ImGuiCond_FirstUseEver);
            c.ImGui_SetNextWindowSize(.{ .x = 300, .y = 200 }, c.ImGuiCond_FirstUseEver);
            _ = c.ImGui_Begin(@ptrCast("tools"), null, 0);
            const vp = c.ImGui_GetWindowViewport();
            c.ImGui_End();
            if (vp != c.ImGui_GetMainViewport()) {
                if (vp.*.PlatformHandle) |h| {
                    const hwnd: win.HWND = @ptrCast(h);
                    if (ownsWindow(null, hwnd) and win.IsWindowVisible(hwnd).toBool()) self.popped_out.store(true, .release);
                }
            }
            _ = self.draws.fetchAdd(1, .release);
        }
    };

    test "floating pops every window out" {
        var probe: Floating = .{};
        const app = try AppWindow.create(testing.allocator, .{ .title = "tuft test", .floating = true, .draw = .{ .ctx = &probe, .func = Floating.draw } });
        defer app.destroy();
        try started(app);
        app.show();
        try waitFor(&app.frames, 4);
        try testing.expect(probe.popped_out.load(.acquire));
        try testing.expect(!win.IsWindowVisible(app.hwnd.?).toBool());

        // Paced by vsync, even 240 Hz is well under this
        const before = app.frameCount();
        sys.thread.sleepMs(250);
        try testing.expect(app.frameCount() - before < 120);
    }

    test "a hidden floating app comes back after another closes" {
        var probe: Floating = .{};
        const app = try AppWindow.create(testing.allocator, .{ .title = "tuft test", .floating = true, .draw = .{ .ctx = &probe, .func = Floating.draw } });
        defer app.destroy();
        try started(app);
        app.show();
        try waitFor(&app.frames, 4);
        try testing.expect(probe.popped_out.load(.acquire));
        // Hidden takes its windows down, so nothing's using ImGui's class
        app.hide();
        const ticked = app.ticks.load(.acquire);
        try waitFor(&app.ticks, ticked + 2);

        // Like the crash window. Its shutdown would take the class out
        var other_probe: Probe = .{};
        const other = try AppWindow.create(testing.allocator, .{ .title = "tuft test 2", .size = .{ 320, 200 }, .draw = .{ .ctx = &other_probe, .func = Probe.draw } });
        other.show();
        try waitFor(&other.frames, 2);
        other.destroy();

        probe.popped_out.store(false, .release);
        app.show();
        try waitFor(&app.frames, app.frameCount() + 4);
        try testing.expect(probe.popped_out.load(.acquire));
    }

    test "close button hides" {
        var probe: Probe = .{};
        const app = try AppWindow.create(testing.allocator, .{ .title = "tuft test", .size = .{ 320, 200 }, .draw = .{ .ctx = &probe, .func = Probe.draw } });
        defer app.destroy();
        try started(app);
        app.show();
        try waitFor(&app.frames, 2);
        for (0..1000) |_| {
            if (app.hwnd != null) break;
            sys.thread.sleepMs(1);
        }
        _ = win.PostMessageW(app.hwnd.?, win.WM_CLOSE, 0, 0);
        for (0..2000) |_| {
            if (!app.isOpen()) break;
            sys.thread.sleepMs(1);
        }
        try testing.expect(!app.isOpen());
    }
};

test {
    _ = tests;
}
