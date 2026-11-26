//! ImGui's Win32 viewport backend. Input goes raw to the user's `Sink`.
//! Windows live on their own thread, so a game thread that never pumps can't hang us.

const Win32 = @This();

const std = @import("std");

const tuft_event = @import("tuft_event");
const tuft_input = @import("tuft_input");
const tuft_window = @import("tuft_window");

const c = @import("root.zig").c;
const sys = @import("tuft_sys");
const win = sys.win;

const log = std.log.scoped(.tuft_imgui);

/// Every message before it's handled, mouse in client coords.
pub const Input = union(enum) {
    message: *const tuft_window.Message,
    mouse_left,
};

/// Called on the windows' thread. Never wait on the render thread from it.
pub const Sink = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, input: Input) void,
};

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("TuftImGuiViewport");

/// Handles, 0 means free.
var ours: [32]std.atomic.Value(usize) = @splat(.init(0));

/// Any thread.
pub fn isOurs(_: ?*anyopaque, window: tuft_window.Handle) bool {
    const handle = @intFromPtr(window);
    for (&ours) |*slot| if (slot.load(.acquire) == handle) return true;
    return false;
}

fn noteOurs(hwnd: win.HWND) void {
    for (&ours) |*slot| if (slot.cmpxchgStrong(0, @intFromPtr(hwnd), .acq_rel, .acquire) == null) return;
}

fn forgetOurs(hwnd: win.HWND) void {
    for (&ours) |*slot| _ = slot.cmpxchgStrong(@intFromPtr(hwnd), 0, .acq_rel, .acquire);
}
const max_monitors = 32;
/// Frames further apart than this mean the game stopped rendering.
pub const stale_frame_ms = 250;

const wm_run_tasks = win.WM_APP + 1;
const wm_stop = win.WM_APP + 2;

allocator: std.mem.Allocator,
main: win.HWND,
sink: Sink,
/// user32's real `DefWindowProcW`, not our import thunk, which goes away with the DLL.
def_window_proc: *const win.WNDPROC,
instance: ?win.HINSTANCE,
/// Big and small, on every window it makes. Null for none.
icons: [2]?*anyopaque = .{ null, null },

tasks: tuft_event.TaskQueue = .{},
thread: ?win.HANDLE = null,
control: ?win.HWND = null,

// Shared with the windows' thread
want_update_monitors: std.atomic.Value(bool) = .init(true),
cursor: std.atomic.Value(c.ImGuiMouseCursor) = .init(c.ImGuiMouseCursor_Arrow),
draw_cursor: std.atomic.Value(bool) = .init(false),
/// `GetTickCount` at the last frame start.
last_frame_ms: std.atomic.Value(u32) = .init(0),
cursor_queued: std.atomic.Value(bool) = .init(false),
/// Where the IME goes in one of our windows. Any thread writes, the windows' thread applies.
ime_lock: sys.sync.RwLock = .{},
ime_target: ?ImeTarget = null,
ime_queued: std.atomic.Value(bool) = .init(false),

// Windows' thread only
tracked: ?win.HWND = null,
/// Bits numbered by `buttonOf`.
buttons: u8 = 0,

// Render thread only
hovering: bool = false,

/// Becomes the current context's platform backend. `icon` is a resource in this module. Render thread.
pub fn create(allocator: std.mem.Allocator, main: tuft_window.Handle, sink: Sink, icon: ?[]const u8) !*Win32 {
    const user32 = win.GetModuleHandleW(std.unicode.utf8ToUtf16LeStringLiteral("user32.dll")) orelse return error.User32NotLoaded;
    const def_window_proc = win.GetProcAddress(user32, "DefWindowProcW") orelse return error.DefWindowProcNotFound;

    const self = try allocator.create(Win32);
    errdefer allocator.destroy(self);
    self.* = .{
        .allocator = allocator,
        .main = main,
        .sink = sink,
        .def_window_proc = @ptrCast(def_window_proc),
        // The class can't belong to this DLL, which may get unloaded
        .instance = win.GetModuleHandleW(null),
    };
    self.tasks.wake = .{ .ctx = self, .func = wake };
    if (icon) |name| self.loadIcons(name);
    errdefer self.freeIcons();

    const class: win.WNDCLASSEXW = .{
        // Own DC for OpenGL
        .style = win.CS_HREDRAW | win.CS_VREDRAW | win.CS_OWNDC,
        .lpfnWndProc = self.def_window_proc,
        .hInstance = self.instance,
        .hCursor = win.LoadCursorW(null, win.IDC_ARROW),
        .lpszClassName = class_name,
    };
    // An earlier load of this DLL may have registered it already
    if (win.RegisterClassExW(&class) == 0 and @backingInt(win.GetLastError()) != win.ERROR_CLASS_ALREADY_EXISTS) {
        return error.RegisterClassFailed;
    }
    try self.startThread();
    errdefer self.stopThread();

    const io = c.ImGui_GetIO();
    io.*.BackendPlatformUserData = self;
    io.*.BackendFlags |= c.ImGuiBackendFlags_PlatformHasViewports | c.ImGuiBackendFlags_HasMouseHoveredViewport | c.ImGuiBackendFlags_HasParentViewport;

    const pio = c.ImGui_GetPlatformIO();
    pio.*.Platform_CreateWindow = createWindow;
    pio.*.Platform_DestroyWindow = destroyWindow;
    pio.*.Platform_ShowWindow = showWindow;
    pio.*.Platform_SetWindowPos = setWindowPos;
    c.ImGuiPlatformIO_SetPlatform_GetWindowPos(getWindowPos);
    pio.*.Platform_SetWindowSize = setWindowSize;
    c.ImGuiPlatformIO_SetPlatform_GetWindowSize(getWindowSize);
    pio.*.Platform_SetWindowFocus = setWindowFocus;
    pio.*.Platform_GetWindowFocus = getWindowFocus;
    pio.*.Platform_GetWindowMinimized = getWindowMinimized;
    pio.*.Platform_SetWindowTitle = setWindowTitle;
    pio.*.Platform_SetWindowAlpha = setWindowAlpha;
    pio.*.Platform_UpdateWindow = updateWindow;
    pio.*.Platform_GetWindowDpiScale = getWindowDpiScale;

    self.setMainViewport();
    self.updateMonitors();
    return self;
}

/// Context must be current. The renderer may still be running.
pub fn destroy(self: *Win32) void {
    tuft_imgui_destroy_viewport_windows();
    self.stopThread();
    self.freeIcons();

    const pio = c.ImGui_GetPlatformIO();
    pio.*.Platform_CreateWindow = null;
    pio.*.Platform_DestroyWindow = null;
    pio.*.Platform_ShowWindow = null;
    pio.*.Platform_SetWindowPos = null;
    pio.*.Platform_GetWindowPos = null;
    pio.*.Platform_SetWindowSize = null;
    pio.*.Platform_GetWindowSize = null;
    pio.*.Platform_SetWindowFocus = null;
    pio.*.Platform_GetWindowFocus = null;
    pio.*.Platform_GetWindowMinimized = null;
    pio.*.Platform_SetWindowTitle = null;
    pio.*.Platform_SetWindowAlpha = null;
    pio.*.Platform_UpdateWindow = null;
    pio.*.Platform_GetWindowDpiScale = null;

    const main_viewport = c.ImGui_GetMainViewport();
    main_viewport.*.PlatformHandle = null;
    main_viewport.*.PlatformHandleRaw = null;

    const io = c.ImGui_GetIO();
    io.*.ConfigFlags &= ~@as(c.ImGuiConfigFlags, c.ImGuiConfigFlags_ViewportsEnable);
    io.*.BackendFlags &= ~@as(c.ImGuiBackendFlags, c.ImGuiBackendFlags_PlatformHasViewports | c.ImGuiBackendFlags_HasMouseHoveredViewport | c.ImGuiBackendFlags_HasParentViewport);
    io.*.BackendPlatformUserData = null;
    self.allocator.destroy(self);
}

/// Any thread.
pub fn changesMonitors(m: *const tuft_window.Message) bool {
    return m.msg == win.WM_DISPLAYCHANGE or m.msg == win.WM_DPICHANGED;
}

/// Call before `ImGui_NewFrame` and before feeding queued input.
pub fn newFrame(self: *Win32, io: *c.ImGuiIO, monitors_changed: bool) void {
    self.last_frame_ms.store(win.GetTickCount(), .release);
    // ImGui forgets the main window's handle whenever its platform windows get destroyed
    self.setMainViewport();
    if (self.want_update_monitors.swap(false, .acq_rel) or monitors_changed) self.updateMonitors();

    const viewports = c.ImGui_GetPlatformIO().*.Viewports;
    for (0..@intCast(viewports.Size)) |i| {
        const vp = viewports.Data[i];
        const data = viewportData(vp) orelse continue;
        if (data.moved.swap(false, .acq_rel)) vp.*.PlatformRequestMove = true;
        if (data.resized.swap(false, .acq_rel)) vp.*.PlatformRequestResize = true;
        if (data.close_requested.swap(false, .acq_rel)) vp.*.PlatformRequestClose = true;
    }

    var point: win.POINT = .{};
    var hovered: c.ImGuiID = 0;
    self.hovering = false;
    if (win.GetCursorPos(&point).toBool()) {
        if (win.WindowFromPoint(point)) |hwnd| {
            if (c.ImGui_FindViewportByPlatformHandle(hwnd)) |viewport| {
                hovered = viewport.*.ID;
                self.hovering = hwnd != self.main;
            } else if (win.IsChild(self.main, hwnd).toBool()) {
                hovered = c.ImGui_GetMainViewport().*.ID;
            }
        }
    }
    c.ImGuiIO_AddMouseViewportEvent(io, hovered);
}

/// After `ImGui_Render`.
pub fn endFrame(self: *Win32) void {
    const cursor = c.ImGui_GetMouseCursor();
    const draw_cursor = c.ImGui_GetIO().*.MouseDrawCursor;
    const cursor_changed = self.cursor.swap(cursor, .acq_rel) != cursor;
    const draw_changed = self.draw_cursor.swap(draw_cursor, .acq_rel) != draw_cursor;
    // Only the thread owning the window under the cursor can set it
    if ((cursor_changed or draw_changed) and self.hovering and !self.cursor_queued.swap(true, .acq_rel)) {
        self.tasks.post(self, applyCursorTask) catch self.cursor_queued.store(false, .release);
    }
    c.ImGui_UpdatePlatformWindows();
}

const ImeTarget = struct { hwnd: win.HWND, placement: tuft_input.Ime.Placement };

/// Puts the IME's windows at the caret in one of our windows. Any thread.
pub fn placeIme(self: *Win32, hwnd: win.HWND, placement: tuft_input.Ime.Placement) void {
    {
        self.ime_lock.lock();
        defer self.ime_lock.unlock();
        self.ime_target = .{ .hwnd = hwnd, .placement = placement };
    }
    if (self.ime_queued.swap(true, .acq_rel)) return;
    self.tasks.post(self, applyImeTask) catch self.ime_queued.store(false, .release);
}

/// IMM only places them from the thread that made the window.
fn applyImeTask(self: *Win32) void {
    self.ime_queued.store(false, .release);
    const target = blk: {
        self.ime_lock.lock();
        defer self.ime_lock.unlock();
        defer self.ime_target = null;
        break :blk self.ime_target orelse return;
    };
    if (isOurs(null, target.hwnd)) tuft_input.Ime.placeOn(target.hwnd, target.placement);
}

pub fn appFocused(self: *const Win32) bool {
    const foreground = win.GetForegroundWindow() orelse return false;
    if (foreground == self.main or win.IsChild(foreground, self.main).toBool()) return true;
    return c.ImGui_FindViewportByPlatformHandle(foreground) != null;
}

pub fn hoveringViewport(self: *const Win32) bool {
    return self.hovering;
}

pub fn windowsThread(self: *const Win32) win.DWORD {
    const control = self.control orelse return 0;
    return win.GetWindowThreadProcessId(control, null);
}

fn setMainViewport(self: *const Win32) void {
    const main_viewport = c.ImGui_GetMainViewport();
    main_viewport.*.PlatformHandle = self.main;
    main_viewport.*.PlatformHandleRaw = self.main;
}

fn updateMonitors(self: *Win32) void {
    _ = self;
    var list: MonitorList = .{};
    _ = win.EnumDisplayMonitors(null, null, MonitorList.add, @bitCast(@intFromPtr(&list)));
    tuft_imgui_set_monitors(&list.items, @intCast(list.len));
}

const MonitorList = struct {
    items: [max_monitors]c.ImGuiPlatformMonitor = undefined,
    len: usize = 0,

    fn add(monitor: win.HMONITOR, _: ?*anyopaque, _: ?*win.RECT, data: isize) callconv(.winapi) win.BOOL {
        const list: *MonitorList = @ptrFromInt(@as(usize, @bitCast(data)));
        if (list.len == max_monitors) return .FALSE;
        var info: win.MONITORINFO = .{};
        if (!win.GetMonitorInfoW(monitor, &info).toBool()) return .TRUE;

        var dpi_x: u32 = 96;
        var dpi_y: u32 = 96;
        if (win.GetDpiForMonitor(monitor, win.MDT_EFFECTIVE_DPI, &dpi_x, &dpi_y) < 0) dpi_x = 96;
        const entry: c.ImGuiPlatformMonitor = .{
            .MainPos = vec(info.rcMonitor.left, info.rcMonitor.top),
            .MainSize = vec(info.rcMonitor.right - info.rcMonitor.left, info.rcMonitor.bottom - info.rcMonitor.top),
            .WorkPos = vec(info.rcWork.left, info.rcWork.top),
            .WorkSize = vec(info.rcWork.right - info.rcWork.left, info.rcWork.bottom - info.rcWork.top),
            .DpiScale = @as(f32, @floatFromInt(dpi_x)) / 96.0,
            .PlatformHandle = monitor,
        };
        // ImGui treats the first one as primary
        if (info.dwFlags & win.MONITORINFOF_PRIMARY != 0) {
            std.mem.copyBackwards(c.ImGuiPlatformMonitor, list.items[1 .. list.len + 1], list.items[0..list.len]);
            list.items[0] = entry;
        } else {
            list.items[list.len] = entry;
        }
        list.len += 1;
        return .TRUE;
    }
};

extern fn tuft_imgui_set_monitors(monitors: [*]const c.ImGuiPlatformMonitor, count: c_int) void;
extern fn tuft_imgui_destroy_viewport_windows() void;

// The windows' thread

const Start = struct {
    win32: *Win32,
    ready: win.HANDLE,

    fn run(param: ?*anyopaque) callconv(.winapi) win.DWORD {
        const start: *Start = @ptrCast(@alignCast(param.?));
        const self = start.win32;
        const message_only: win.HWND = @ptrFromInt(@as(usize, @bitCast(win.HWND_MESSAGE)));
        const control = win.CreateWindowExW(0, class_name, null, 0, 0, 0, 0, 0, message_only, null, self.instance, null);
        if (control) |hwnd| {
            _ = win.SetWindowLongPtrW(hwnd, win.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
            _ = win.SetWindowLongPtrW(hwnd, win.GWLP_WNDPROC, @bitCast(@intFromPtr(&controlProc)));
            self.tasks.setThread(win.GetCurrentThreadId());
        }
        self.control = control;
        // `start` is on the starting thread's stack, don't touch it after this
        _ = win.SetEvent(start.ready);
        if (control == null) return 1;
        var m: win.MSG = .{};
        while (win.GetMessageW(&m, null, 0, 0).toBool()) {
            _ = win.TranslateMessage(&m);
            _ = win.DispatchMessageW(&m);
        }
        return 0;
    }
};

fn startThread(self: *Win32) !void {
    const ready = win.CreateEventW(null, .TRUE, .FALSE, null) orelse return error.CreateEventFailed;
    defer win.CloseHandle(ready);
    var start: Start = .{ .win32 = self, .ready = ready };
    // Not std.Thread, its spawn fails on threads with an activation context
    const thread = win.CreateThread(null, 0, Start.run, &start, 0, null) orelse return error.CreateThreadFailed;
    waitAnswering(ready);
    if (self.control == null) {
        waitAnswering(thread);
        win.CloseHandle(thread);
        return error.CreateWindowFailed;
    }
    self.thread = thread;
}

fn loadIcons(self: *Win32, name: []const u8) void {
    var buf: [64:0]u16 = undefined;
    const len = std.unicode.utf8ToUtf16Le(&buf, name[0..@min(name.len, buf.len)]) catch return;
    buf[len] = 0;
    // From this module, not the game's
    const module: ?win.HINSTANCE = @ptrFromInt(sys.module.selfBase());
    const sizes = [2][2]i32{ .{ win.SM_CXICON, win.SM_CYICON }, .{ win.SM_CXSMICON, win.SM_CYSMICON } };
    for (&self.icons, sizes) |*slot, size| {
        slot.* = win.LoadImageW(module, buf[0..len :0], win.IMAGE_ICON, win.GetSystemMetrics(size[0]), win.GetSystemMetrics(size[1]), 0);
    }
}

/// Once its windows are gone.
fn freeIcons(self: *Win32) void {
    for (&self.icons) |*slot| {
        if (slot.*) |i| _ = win.DestroyIcon(i);
        slot.* = null;
    }
}

fn stopThread(self: *Win32) void {
    const thread = self.thread orelse return;
    if (self.control) |control| _ = win.PostMessageW(control, wm_stop, 0, 0);
    waitAnswering(thread);
    win.CloseHandle(thread);
    self.thread = null;
    self.control = null;
    self.tasks.close();
}

fn wake(ctx: *anyopaque) void {
    const self: *Win32 = @ptrCast(@alignCast(ctx));
    if (self.control) |control| _ = win.PostMessageW(control, wm_run_tasks, 0, 0);
}

fn controlProc(hwnd: win.HWND, msg: u32, wparam: usize, lparam: isize) callconv(.winapi) isize {
    const self: *Win32 = @ptrFromInt(@as(usize, @bitCast(win.GetWindowLongPtrW(hwnd, win.GWLP_USERDATA))));
    switch (msg) {
        wm_run_tasks => self.tasks.runPending(),
        wm_stop => {
            self.tasks.runPending();
            _ = win.SetWindowLongPtrW(hwnd, win.GWLP_WNDPROC, @bitCast(@intFromPtr(self.def_window_proc)));
            _ = win.DestroyWindow(hwnd);
            win.PostQuitMessage(0);
        },
        else => return win.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
    return 0;
}

/// Answers sent messages while waiting, or the windows' thread could deadlock us.
fn waitAnswering(handle: win.HANDLE) void {
    const handles = [_]win.HANDLE{handle};
    while (true) {
        const r = win.MsgWaitForMultipleObjects(1, &handles, .FALSE, win.INFINITE, win.QS_SENDMESSAGE);
        if (r != win.WAIT_OBJECT_0 + 1) return;
        // Sent messages only. Posted ones are the game's
        var m: win.MSG = .{};
        _ = win.PeekMessageW(&m, null, 0, 0, win.PM_NOREMOVE | win.PM_QS_SENDMESSAGE);
    }
}

fn runOnThread(self: *Win32, ptr: anytype, comptime func: fn (@TypeOf(ptr)) void) void {
    const Call = struct {
        ptr: @TypeOf(ptr),
        done: win.HANDLE,

        fn run(call: *@This()) void {
            func(call.ptr);
            _ = win.SetEvent(call.done);
        }
    };
    const done = win.CreateEventW(null, .TRUE, .FALSE, null) orelse return;
    defer win.CloseHandle(done);
    var call: Call = .{ .ptr = ptr, .done = done };
    self.tasks.post(&call, Call.run) catch |err| return log.warn("Couldn't reach the windows' thread: {t}", .{err});
    waitAnswering(done);
}

// ImGuiPlatformIO callbacks, on the render thread

const State = struct {
    /// Client area, screen coords.
    pos: c.ImVec2 = .{ .x = 0, .y = 0 },
    size: c.ImVec2 = .{ .x = 0, .y = 0 },
    parent: ?win.HWND = null,
    style: win.DWORD = 0,
    ex_style: win.DWORD = 0,
    no_focus_on_click: bool = false,
    no_inputs: bool = false,
    visible: bool = false,
    show_inactive: bool = false,
    /// So a tooltip or popup doesn't drag its owner forward.
    detach_to_show: bool = false,
    alpha: f32 = 1,
    title: [128:0]u16 = @splat(0),
    title_len: usize = 0,
};

/// `PlatformUserData`. The main viewport has none.
const ViewportData = struct {
    win32: *Win32,
    /// Set by the windows' thread.
    hwnd: ?win.HWND = null,
    /// Under `lock`.
    want: State = .{},
    /// Under `lock`.
    focus: bool = false,
    lock: sys.sync.RwLock = .{},
    queued: std.atomic.Value(bool) = .init(false),
    // From the windows' thread, for `newFrame`
    moved: std.atomic.Value(bool) = .init(false),
    resized: std.atomic.Value(bool) = .init(false),
    close_requested: std.atomic.Value(bool) = .init(false),
    // Windows' thread's
    have: State = .{},
    /// Our own moves and resizes aren't news for ImGui.
    applying: bool = false,
    raised_topmost: bool = false,

    /// Render thread.
    fn update(data: *ViewportData, comptime change: anytype, args: anytype) void {
        {
            data.lock.lock();
            defer data.lock.unlock();
            @call(.auto, change, .{&data.want} ++ args);
        }
        data.queueApply();
    }

    fn queueApply(data: *ViewportData) void {
        if (data.queued.swap(true, .acq_rel)) return;
        data.win32.tasks.post(data, apply) catch data.queued.store(false, .release);
    }

    /// Windows' thread.
    fn apply(data: *ViewportData) void {
        data.queued.store(false, .release);
        const hwnd = data.hwnd orelse return;
        var want: State = undefined;
        var focus = false;
        {
            data.lock.lock();
            defer data.lock.unlock();
            want = data.want;
            focus = data.focus;
            data.focus = false;
        }
        const have = &data.have;
        data.applying = true;
        defer data.applying = false;

        have.no_focus_on_click = want.no_focus_on_click;
        have.no_inputs = want.no_inputs;
        if (want.parent != have.parent) {
            _ = win.SetWindowLongPtrW(hwnd, win.GWLP_HWNDPARENT, if (want.parent) |p| @bitCast(@intFromPtr(p)) else 0);
            have.parent = want.parent;
        }
        if (want.style != have.style or want.ex_style != have.ex_style) {
            const topmost_changed = (have.ex_style ^ want.ex_style) & win.WS_EX_TOPMOST != 0;
            _ = win.SetWindowLongPtrW(hwnd, win.GWL_STYLE, @bitCast(@as(usize, want.style)));
            _ = win.SetWindowLongPtrW(hwnd, win.GWL_EXSTYLE, @bitCast(@as(usize, want.ex_style)));
            const insert_after: ?win.HWND = if (!topmost_changed)
                null
            else
                @ptrFromInt(@as(usize, @bitCast(if (want.ex_style & win.WS_EX_TOPMOST != 0) win.HWND_TOPMOST else win.HWND_NOTOPMOST)));
            const rect = windowRect(want.pos, want.size, want.style, want.ex_style);
            const z: u32 = if (topmost_changed) 0 else win.SWP_NOZORDER;
            _ = win.SetWindowPos(hwnd, insert_after, rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top, z | win.SWP_NOACTIVATE | win.SWP_FRAMECHANGED);
            have.style = want.style;
            have.ex_style = want.ex_style;
            have.pos = want.pos;
            have.size = want.size;
            // Needed after a style change
            if (have.visible) _ = win.ShowWindow(hwnd, win.SW_SHOWNA);
        }
        // Unowned by the game's window, so raise above a topmost game while dragging
        const dragging = want.no_inputs and want.ex_style & win.WS_EX_TOPMOST == 0;
        if (data.raised_topmost and !dragging) {
            _ = win.SetWindowPos(hwnd, @ptrFromInt(@as(usize, @bitCast(win.HWND_NOTOPMOST))), 0, 0, 0, 0, win.SWP_NOMOVE | win.SWP_NOSIZE | win.SWP_NOACTIVATE);
            data.raised_topmost = false;
        }
        const moved = want.pos.x != have.pos.x or want.pos.y != have.pos.y;
        const resized = want.size.x != have.size.x or want.size.y != have.size.y;
        if (moved or resized) {
            const rect = windowRect(want.pos, want.size, want.style, want.ex_style);
            var flags: u32 = win.SWP_NOACTIVATE | win.SWP_NOZORDER;
            if (!moved) flags |= win.SWP_NOMOVE;
            if (!resized) flags |= win.SWP_NOSIZE;
            _ = win.SetWindowPos(hwnd, null, rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top, flags);
            have.pos = want.pos;
            have.size = want.size;
        }
        if (!std.mem.eql(u16, want.title[0..want.title_len], have.title[0..have.title_len])) {
            _ = win.SetWindowTextW(hwnd, want.title[0..want.title_len :0]);
            have.title = want.title;
            have.title_len = want.title_len;
        }
        if (want.alpha != have.alpha) {
            setAlpha(hwnd, want.alpha);
            have.alpha = want.alpha;
        }
        if (want.visible and !have.visible) {
            // Showing an owned window brings its owner forward too
            const detach = want.detach_to_show and have.parent != null;
            if (detach) _ = win.SetWindowLongPtrW(hwnd, win.GWLP_HWNDPARENT, 0);
            _ = win.ShowWindow(hwnd, if (want.show_inactive) win.SW_SHOWNA else win.SW_SHOW);
            if (detach) _ = win.SetWindowLongPtrW(hwnd, win.GWLP_HWNDPARENT, @bitCast(@intFromPtr(have.parent.?)));
            have.visible = true;
        }
        // After showing, since a dragged-off window shows without a move. HWND_TOP doesn't stick in some games
        if (dragging and have.visible) {
            _ = win.SetWindowPos(hwnd, @ptrFromInt(@as(usize, @bitCast(win.HWND_TOPMOST))), 0, 0, 0, 0, win.SWP_NOMOVE | win.SWP_NOSIZE | win.SWP_NOACTIVATE);
            data.raised_topmost = true;
        }
        if (focus) _ = tuft_window.bringToFront(hwnd);
    }
};

fn backend() ?*Win32 {
    return @ptrCast(@alignCast(c.ImGui_GetIO().*.BackendPlatformUserData orelse return null));
}

fn viewportData(viewport: ?*c.ImGuiViewport) ?*ViewportData {
    const vp = viewport orelse return null;
    return @ptrCast(@alignCast(vp.*.PlatformUserData orelse return null));
}

fn hwndOf(viewport: ?*c.ImGuiViewport) ?win.HWND {
    const vp = viewport orelse return null;
    return @ptrCast(vp.*.PlatformHandle orelse return null);
}

/// Only another of our windows can own ours. Owning across threads ties their input together.
fn ownerFor(viewport: *c.ImGuiViewport) ?win.HWND {
    const parent = hwndOf(viewport.*.ParentViewport) orelse return null;
    return if (isOurs(null, parent)) parent else null;
}

fn styleFor(flags: c.ImGuiViewportFlags) struct { win.DWORD, win.DWORD } {
    const style = if (flags & c.ImGuiViewportFlags_NoDecoration != 0) win.WS_POPUP else win.WS_OVERLAPPEDWINDOW;
    var ex_style = if (flags & c.ImGuiViewportFlags_NoTaskBarIcon != 0) win.WS_EX_TOOLWINDOW else win.WS_EX_APPWINDOW;
    if (flags & c.ImGuiViewportFlags_TopMost != 0) ex_style |= win.WS_EX_TOPMOST;
    return .{ style, ex_style };
}

fn shapeOf(want: *State, vp: *c.ImGuiViewport) void {
    want.parent = ownerFor(vp);
    want.style, want.ex_style = styleFor(vp.*.Flags);
    want.no_focus_on_click = vp.*.Flags & c.ImGuiViewportFlags_NoFocusOnClick != 0;
    want.no_inputs = vp.*.Flags & c.ImGuiViewportFlags_NoInputs != 0;
}

fn windowRect(pos: c.ImVec2, size: c.ImVec2, style: win.DWORD, ex_style: win.DWORD) win.RECT {
    var rect: win.RECT = .{
        .left = @intFromFloat(pos.x),
        .top = @intFromFloat(pos.y),
        .right = @intFromFloat(pos.x + size.x),
        .bottom = @intFromFloat(pos.y + size.y),
    };
    _ = win.AdjustWindowRectEx(&rect, style, .FALSE, ex_style);
    return rect;
}

fn createWindow(viewport: ?*c.ImGuiViewport) callconv(.c) void {
    const self = backend() orelse return;
    const vp = viewport orelse return;
    const data = self.allocator.create(ViewportData) catch return;
    data.* = .{ .win32 = self };
    data.want.pos = vp.*.Pos;
    data.want.size = vp.*.Size;
    shapeOf(&data.want, vp);

    self.runOnThread(data, makeWindow);
    const hwnd = data.hwnd orelse {
        log.warn("Couldn't make a window for an ImGui window outside the game", .{});
        self.allocator.destroy(data);
        return;
    };
    vp.*.PlatformRequestResize = false;
    vp.*.PlatformUserData = data;
    vp.*.PlatformHandle = hwnd;
    vp.*.PlatformHandleRaw = hwnd;
    noteOurs(hwnd);
}

/// Windows' thread.
fn makeWindow(data: *ViewportData) void {
    const want = data.want;
    const rect = windowRect(want.pos, want.size, want.style, want.ex_style);
    const hwnd = win.CreateWindowExW(
        want.ex_style,
        class_name,
        std.unicode.utf8ToUtf16LeStringLiteral("ImGui"),
        want.style,
        rect.left,
        rect.top,
        rect.right - rect.left,
        rect.bottom - rect.top,
        want.parent,
        null,
        data.win32.instance,
        null,
    ) orelse return;
    _ = win.SetWindowLongPtrW(hwnd, win.GWLP_USERDATA, @bitCast(@intFromPtr(data)));
    _ = win.SetWindowLongPtrW(hwnd, win.GWLP_WNDPROC, @bitCast(@intFromPtr(&wndProc)));
    if (data.win32.icons[0]) |big| _ = win.SendMessageW(hwnd, win.WM_SETICON, win.ICON_BIG, @bitCast(@intFromPtr(big)));
    if (data.win32.icons[1]) |small| _ = win.SendMessageW(hwnd, win.WM_SETICON, win.ICON_SMALL, @bitCast(@intFromPtr(small)));
    data.have = want;
    data.have.visible = false;
    data.have.title_len = 0;
    data.hwnd = hwnd;
}

fn destroyWindow(viewport: ?*c.ImGuiViewport) callconv(.c) void {
    const vp = viewport orelse return;
    if (viewportData(vp)) |data| {
        const self = data.win32;
        if (data.hwnd) |hwnd| {
            forgetOurs(hwnd);
            // Otherwise focus goes nowhere and lots of games stop rendering
            if (win.GetForegroundWindow() == hwnd) _ = win.SetForegroundWindow(self.main);
            // Tasks run in order, so this goes after any queued update
            self.runOnThread(data, unmakeWindow);
        }
        self.allocator.destroy(data);
    }
    vp.*.PlatformUserData = null;
    vp.*.PlatformHandle = null;
    vp.*.PlatformHandleRaw = null;
}

/// Windows' thread.
fn unmakeWindow(data: *ViewportData) void {
    const self = data.win32;
    const hwnd = data.hwnd orelse return;
    if (self.tracked == hwnd) {
        self.tracked = null;
        self.sink.func(self.sink.ctx, .mouse_left);
    }
    if (win.GetCapture() == hwnd) {
        _ = win.ReleaseCapture();
        self.buttons = 0;
    }
    _ = win.DestroyWindow(hwnd);
    data.hwnd = null;
}

fn showWindow(viewport: ?*c.ImGuiViewport) callconv(.c) void {
    const vp = viewport orelse return;
    const data = viewportData(vp) orelse return;
    data.update(struct {
        fn f(want: *State, flags: c.ImGuiViewportFlags) void {
            want.visible = true;
            want.show_inactive = flags & c.ImGuiViewportFlags_NoFocusOnAppearing != 0;
            want.detach_to_show = flags & (c.ImGuiViewportFlags_NoFocusOnAppearing | c.ImGuiViewportFlags_NoTaskBarIcon) != 0;
        }
    }.f, .{vp.*.Flags});
}

fn updateWindow(viewport: ?*c.ImGuiViewport) callconv(.c) void {
    const vp = viewport orelse return;
    const data = viewportData(vp) orelse return;
    var next: State = .{};
    shapeOf(&next, vp);
    const same = blk: {
        data.lock.lockShared();
        defer data.lock.unlockShared();
        const w = &data.want;
        break :blk next.parent == w.parent and next.style == w.style and next.ex_style == w.ex_style and
            next.no_focus_on_click == w.no_focus_on_click and next.no_inputs == w.no_inputs;
    };
    if (same) return;
    data.update(shapeOf, .{vp});
}

fn getWindowPos(viewport: ?*c.ImGuiViewport, out: ?*c.ImVec2) callconv(.c) void {
    const result = out orelse return;
    var point: win.POINT = .{};
    if (hwndOf(viewport)) |hwnd| _ = win.ClientToScreen(hwnd, &point);
    result.* = vec(point.x, point.y);
}

fn setWindowPos(viewport: ?*c.ImGuiViewport, pos: c.ImVec2) callconv(.c) void {
    const data = viewportData(viewport) orelse return;
    data.update(struct {
        fn f(want: *State, p: c.ImVec2) void {
            want.pos = p;
        }
    }.f, .{pos});
}

fn getWindowSize(viewport: ?*c.ImGuiViewport, out: ?*c.ImVec2) callconv(.c) void {
    const result = out orelse return;
    var rect: win.RECT = .{};
    if (hwndOf(viewport)) |hwnd| _ = win.GetClientRect(hwnd, &rect);
    result.* = vec(rect.right - rect.left, rect.bottom - rect.top);
}

fn setWindowSize(viewport: ?*c.ImGuiViewport, size: c.ImVec2) callconv(.c) void {
    const data = viewportData(viewport) orelse return;
    data.update(struct {
        fn f(want: *State, s: c.ImVec2) void {
            want.size = s;
        }
    }.f, .{size});
}

fn setWindowFocus(viewport: ?*c.ImGuiViewport) callconv(.c) void {
    // Never the game's window, focusing that isn't our call
    const data = viewportData(viewport) orelse return;
    {
        data.lock.lock();
        defer data.lock.unlock();
        data.focus = true;
    }
    data.queueApply();
}

fn getWindowFocus(viewport: ?*c.ImGuiViewport) callconv(.c) bool {
    const hwnd = hwndOf(viewport) orelse return false;
    return win.GetForegroundWindow() == hwnd;
}

fn getWindowMinimized(viewport: ?*c.ImGuiViewport) callconv(.c) bool {
    const hwnd = hwndOf(viewport) orelse return false;
    return win.IsIconic(hwnd).toBool();
}

fn setWindowTitle(viewport: ?*c.ImGuiViewport, title: [*c]const u8) callconv(.c) void {
    const data = viewportData(viewport) orelse return;
    if (title == null) return;
    const utf8 = std.mem.span(@as([*:0]const u8, @ptrCast(title)));
    var buf: [128:0]u16 = @splat(0);
    const len = std.unicode.calcUtf16LeLen(utf8) catch return;
    if (len > buf.len) return;
    _ = std.unicode.utf8ToUtf16Le(&buf, utf8) catch return;
    data.update(struct {
        fn f(want: *State, b: *const [128:0]u16, l: usize) void {
            want.title = b.*;
            want.title_len = l;
        }
    }.f, .{ &buf, len });
}

fn setWindowAlpha(viewport: ?*c.ImGuiViewport, alpha: f32) callconv(.c) void {
    const data = viewportData(viewport) orelse return;
    data.update(struct {
        fn f(want: *State, a: f32) void {
            want.alpha = a;
        }
    }.f, .{alpha});
}

/// Windows' thread.
fn setAlpha(hwnd: win.HWND, alpha: f32) void {
    var ex_style: win.DWORD = @truncate(@as(usize, @bitCast(win.GetWindowLongPtrW(hwnd, win.GWL_EXSTYLE))));
    if (alpha < 1.0) {
        ex_style |= win.WS_EX_LAYERED;
        _ = win.SetWindowLongPtrW(hwnd, win.GWL_EXSTYLE, @bitCast(@as(usize, ex_style)));
        _ = win.SetLayeredWindowAttributes(hwnd, 0, @intFromFloat(255.0 * std.math.clamp(alpha, 0, 1)), win.LWA_ALPHA);
    } else {
        ex_style &= ~win.WS_EX_LAYERED;
        _ = win.SetWindowLongPtrW(hwnd, win.GWL_EXSTYLE, @bitCast(@as(usize, ex_style)));
    }
}

fn getWindowDpiScale(viewport: ?*c.ImGuiViewport) callconv(.c) f32 {
    const hwnd = hwndOf(viewport) orelse return 1;
    return tuft_window.dpiScale(hwnd);
}

// Window proc, on the windows' thread

fn wndProc(hwnd: win.HWND, msg: u32, wparam: usize, lparam: isize) callconv(.winapi) isize {
    const user_data: usize = @bitCast(win.GetWindowLongPtrW(hwnd, win.GWLP_USERDATA));
    if (user_data == 0) return win.DefWindowProcW(hwnd, msg, wparam, lparam);
    const data: *ViewportData = @ptrFromInt(user_data);
    const self = data.win32;

    switch (msg) {
        win.WM_CLOSE => {
            data.close_requested.store(true, .release);
            return 0; // ImGui closes it
        },
        // The user or Windows moved or resized it. ImGui reads the new spot
        win.WM_MOVE => if (!data.applying) {
            var point: win.POINT = .{};
            _ = win.ClientToScreen(hwnd, &point);
            data.have.pos = vec(point.x, point.y);
            data.moved.store(true, .release);
        },
        win.WM_SIZE => if (!data.applying) {
            var rect: win.RECT = .{};
            _ = win.GetClientRect(hwnd, &rect);
            data.have.size = vec(rect.right - rect.left, rect.bottom - rect.top);
            data.resized.store(true, .release);
        },
        win.WM_MOUSEACTIVATE => if (data.have.no_focus_on_click) return win.MA_NOACTIVATE,
        // So `newFrame` can find the window under a dragged one
        win.WM_NCHITTEST => if (data.have.no_inputs) return win.HTTRANSPARENT,
        win.WM_DISPLAYCHANGE, win.WM_DPICHANGED => self.want_update_monitors.store(true, .release),
        win.WM_SETCURSOR => if (lparam & 0xFFFF == win.HTCLIENT) {
            self.applyCursor();
            return 1;
        },
        win.WM_DESTROY => if (self.tracked == hwnd) {
            self.tracked = null;
            self.sink.func(self.sink.ctx, .mouse_left);
        },
        win.WM_MOUSEMOVE => if (self.tracked != hwnd) {
            var track: win.TRACKMOUSEEVENT = .{ .dwFlags = win.TME_LEAVE, .hwndTrack = hwnd };
            if (win.TrackMouseEvent(&track).toBool()) self.tracked = hwnd;
        },
        win.WM_MOUSELEAVE => {
            if (self.tracked == hwnd) {
                self.tracked = null;
                self.sink.func(self.sink.ctx, .mouse_left);
            }
            return 0;
        },
        else => {},
    }

    if (buttonOf(msg, wparam)) |button| self.capture(hwnd, button.index, button.down);
    const m: tuft_window.Message = .{ .window = hwnd, .msg = msg, .wparam = wparam, .lparam = lparam };
    self.sink.func(self.sink.ctx, .{ .message = &m });
    return win.DefWindowProcW(hwnd, msg, wparam, lparam);
}

/// 0 left, 1 right, 2 middle, 3 and 4 the X ones.
fn buttonOf(msg: u32, wparam: usize) ?struct { index: u3, down: bool } {
    const x: u3 = if ((wparam >> 16) & 0xFFFF == 2) 4 else 3; // XBUTTON2, else XBUTTON1
    return switch (msg) {
        win.WM_LBUTTONDOWN, win.WM_LBUTTONDBLCLK => .{ .index = 0, .down = true },
        win.WM_LBUTTONUP => .{ .index = 0, .down = false },
        win.WM_RBUTTONDOWN, win.WM_RBUTTONDBLCLK => .{ .index = 1, .down = true },
        win.WM_RBUTTONUP => .{ .index = 1, .down = false },
        win.WM_MBUTTONDOWN, win.WM_MBUTTONDBLCLK => .{ .index = 2, .down = true },
        win.WM_MBUTTONUP => .{ .index = 2, .down = false },
        win.WM_XBUTTONDOWN, win.WM_XBUTTONDBLCLK => .{ .index = x, .down = true },
        win.WM_XBUTTONUP => .{ .index = x, .down = false },
        else => null,
    };
}

/// So a drag that leaves the window still ends here.
fn capture(self: *Win32, hwnd: win.HWND, button: u3, down: bool) void {
    const bit = @as(u8, 1) << button;
    if (down) {
        if (self.buttons == 0 and win.GetCapture() == null) _ = win.SetCapture(hwnd);
        self.buttons |= bit;
    } else {
        self.buttons &= ~bit;
        if (self.buttons == 0 and win.GetCapture() == hwnd) _ = win.ReleaseCapture();
    }
}

/// Windows' thread.
fn applyCursorTask(self: *Win32) void {
    self.cursor_queued.store(false, .release);
    var point: win.POINT = .{};
    if (!win.GetCursorPos(&point).toBool()) return;
    const under = win.WindowFromPoint(point) orelse return;
    if (isOurs(null, under)) self.applyCursor();
}

/// Windows' thread.
fn applyCursor(self: *Win32) void {
    // Nothing draws ImGui's cursor if the game isn't rendering, so show the system one
    if (win.GetTickCount() -% self.last_frame_ms.load(.acquire) > stale_frame_ms) {
        _ = win.SetCursor(win.LoadCursorW(null, win.IDC_ARROW));
        return;
    }
    const shape = self.cursor.load(.acquire);
    if (self.draw_cursor.load(.acquire) or shape == c.ImGuiMouseCursor_None) {
        _ = win.SetCursor(null);
        return;
    }
    const id: usize = switch (shape) {
        c.ImGuiMouseCursor_TextInput => win.IDC_IBEAM,
        c.ImGuiMouseCursor_ResizeAll => win.IDC_SIZEALL,
        c.ImGuiMouseCursor_ResizeNS => win.IDC_SIZENS,
        c.ImGuiMouseCursor_ResizeEW => win.IDC_SIZEWE,
        c.ImGuiMouseCursor_ResizeNESW => win.IDC_SIZENESW,
        c.ImGuiMouseCursor_ResizeNWSE => win.IDC_SIZENWSE,
        c.ImGuiMouseCursor_Hand => win.IDC_HAND,
        c.ImGuiMouseCursor_Wait => win.IDC_WAIT,
        c.ImGuiMouseCursor_Progress => win.IDC_APPSTARTING,
        c.ImGuiMouseCursor_NotAllowed => win.IDC_NO,
        else => win.IDC_ARROW,
    };
    _ = win.SetCursor(win.LoadCursorW(null, id));
}

fn vec(x: i32, y: i32) c.ImVec2 {
    return .{ .x = @floatFromInt(x), .y = @floatFromInt(y) };
}
