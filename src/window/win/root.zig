//! Windows window helpers.

const std = @import("std");

const window = @import("../root.zig");
const win = @import("tuft_sys").win;
const sync = @import("tuft_sys").sync;

pub const Handle = win.HWND;
pub const Subclass = @import("Subclass.zig");

pub fn threadOf(hwnd: Handle) u32 {
    return win.GetWindowThreadProcessId(hwnd, null);
}

pub fn pickFile(gpa: std.mem.Allocator, options: window.FileDialog) !?[]u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const W = std.unicode.utf8ToUtf16LeAllocZ;
    // "Kind (*.ext)\0*.ext\0All files\0*.*\0\0"
    const filter_text = if (options.extension.len > 0)
        try std.fmt.allocPrint(a, "{s} (*{s})\x00*{s}\x00All files\x00*.*\x00", .{ options.kind, options.extension, options.extension })
    else
        "All files\x00*.*\x00";
    const filter = try std.unicode.utf8ToUtf16LeAllocZ(a, filter_text);
    var file: [4096:0]u16 = @splat(0);
    if (options.file_name.len > 0) {
        const n = std.unicode.utf8ToUtf16Le(&file, options.file_name) catch return error.NameTooLong;
        file[n] = 0;
    }
    const def_ext: ?[*:0]const u16 = if (options.extension.len > 1) try W(a, options.extension[1..]) else null;
    var ofn: win.OPENFILENAMEW = .{
        .hwndOwner = options.owner,
        .lpstrFilter = filter.ptr,
        .nFilterIndex = 1,
        .lpstrFile = &file,
        .nMaxFile = file.len,
        .lpstrInitialDir = if (options.folder.len > 0) try W(a, options.folder) else null,
        .lpstrTitle = if (options.title.len > 0) try W(a, options.title) else null,
        .lpstrDefExt = def_ext,
        .Flags = win.OFN_EXPLORER | win.OFN_NOCHANGEDIR | win.OFN_HIDEREADONLY | win.OFN_PATHMUSTEXIST |
            (if (options.mode == .save) win.OFN_OVERWRITEPROMPT else win.OFN_FILEMUSTEXIST),
    };
    var watching = Watch.start(options.owner, options.alive);
    defer if (watching) |*w| w.stop();
    const ok = switch (options.mode) {
        .open => win.GetOpenFileNameW(&ofn),
        .save => win.GetSaveFileNameW(&ofn),
    };
    if (!ok.toBool()) {
        if (win.CommDlgExtendedError() == 0) return null;
        return error.DialogFailed;
    }
    return try std.unicode.utf16LeToUtf8Alloc(gpa, std.mem.sliceTo(&file, 0));
}

pub fn pickFolder(gpa: std.mem.Allocator, options: window.FolderDialog) !?[]u8 {
    const W = std.unicode.utf8ToUtf16LeAllocZ;
    // Fine if it's already set up on this thread. A thread set up for free threading still works
    const init = win.CoInitializeEx(null, win.COINIT_APARTMENTTHREADED | win.COINIT_DISABLE_OLE1DDE);
    defer if (init >= 0) win.CoUninitialize();

    var raw: ?*anyopaque = null;
    if (win.CoCreateInstance(&win.CLSID_FileOpenDialog, null, win.CLSCTX_INPROC_SERVER, &win.IID_IFileDialog, &raw) < 0) return error.DialogFailed;
    const dialog: *win.IFileDialog = @ptrCast(@alignCast(raw orelse return error.DialogFailed));
    defer _ = dialog.vtable.Release(dialog);

    var flags: win.DWORD = 0;
    _ = dialog.vtable.GetOptions(dialog, &flags);
    _ = dialog.vtable.SetOptions(dialog, flags | win.FOS_PICKFOLDERS | win.FOS_FORCEFILESYSTEM | win.FOS_PATHMUSTEXIST | win.FOS_NOCHANGEDIR);
    if (options.title.len > 0) {
        const title = try W(gpa, options.title);
        defer gpa.free(title);
        _ = dialog.vtable.SetTitle(dialog, title);
    }
    // A folder that's gone just starts it somewhere else
    if (options.folder.len > 0) start: {
        const path = try W(gpa, options.folder);
        defer gpa.free(path);
        var item_raw: ?*anyopaque = null;
        if (win.SHCreateItemFromParsingName(path, null, &win.IID_IShellItem, &item_raw) < 0) break :start;
        const item: *win.IShellItem = @ptrCast(@alignCast(item_raw orelse break :start));
        defer _ = item.vtable.Release(item);
        _ = dialog.vtable.SetFolder(dialog, item);
    }

    var watching = Watch.start(options.owner, options.alive);
    defer if (watching) |*w| w.stop();
    const shown = dialog.vtable.Show(dialog, options.owner);
    if (shown == win.HRESULT_CANCELLED) return null;
    if (shown < 0) return error.DialogFailed;

    var result: ?*win.IShellItem = null;
    if (dialog.vtable.GetResult(dialog, &result) < 0) return error.DialogFailed;
    const item = result orelse return error.DialogFailed;
    defer _ = item.vtable.Release(item);
    var name: ?[*:0]u16 = null;
    if (item.vtable.GetDisplayName(item, win.SIGDN_FILESYSPATH, &name) < 0) return error.DialogFailed;
    const wide = name orelse return error.DialogFailed;
    defer win.CoTaskMemFree(wide);
    return try std.unicode.utf16LeToUtf8Alloc(gpa, std.mem.span(wide));
}

/// Calls `alive` while the dialog's thread still answers, see `FileDialog.alive`.
const Watch = struct {
    done: sync.Signal,
    thread: std.Thread,

    const interval_ms = 500;

    /// Null if there's nothing to call, or no thread for it, which only means no calls.
    fn start(owner_: ?Handle, alive_: ?window.FileDialog.Alive) ?Watch {
        const alive = alive_ orelse return null;
        const owner = owner_ orelse return null;
        const done = sync.Signal.init() catch return null;
        const thread = std.Thread.spawn(.{}, run, .{ done, owner, alive }) catch {
            done.deinit();
            return null;
        };
        return .{ .done = done, .thread = thread };
    }

    fn stop(self: *Watch) void {
        self.done.set();
        self.thread.join();
        self.done.deinit();
    }

    fn run(done: sync.Signal, owner: Handle, alive: window.FileDialog.Alive) void {
        while (!done.wait(interval_ms)) {
            if (responds(owner)) alive.func(alive.ctx);
        }
    }
};

pub fn createHidden() !Handle {
    return win.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("STATIC"),
        std.unicode.utf8ToUtf16LeStringLiteral("tuft"),
        win.WS_OVERLAPPEDWINDOW,
        0,
        0,
        64,
        64,
        null,
        null,
        null,
        null,
    ) orelse error.CreateWindowFailed;
}

pub fn clientSize(hwnd: Handle) window.Size {
    var rect: win.RECT = .{};
    if (!win.GetClientRect(hwnd, &rect).toBool()) return .{ .width = 0, .height = 0 };
    return .{ .width = @intCast(@max(0, rect.right - rect.left)), .height = @intCast(@max(0, rect.bottom - rect.top)) };
}

pub fn clientToScreen(hwnd: Handle, p: window.Point) ?window.Point {
    var point: win.POINT = .{ .x = p.x, .y = p.y };
    if (!win.ClientToScreen(hwnd, &point).toBool()) return null;
    return .{ .x = point.x, .y = point.y };
}

pub fn setSize(hwnd: Handle, size: window.Size) bool {
    return win.SetWindowPos(hwnd, null, 0, 0, @intCast(size.width), @intCast(size.height), win.SWP_NOMOVE | win.SWP_NOZORDER | win.SWP_NOACTIVATE).toBool();
}

pub fn dpiScale(hwnd: Handle) f32 {
    const dpi = win.GetDpiForWindow(hwnd);
    return if (dpi == 0) 1.0 else @as(f32, @floatFromInt(dpi)) / 96.0;
}

pub fn isForeground(hwnd: Handle) bool {
    return win.GetForegroundWindow() == hwnd;
}

/// Windows only lets the front thread do this, so it borrows that thread's input.
pub fn bringToFront(hwnd: Handle) bool {
    const me = win.GetCurrentThreadId();
    const fg = win.GetForegroundWindow();
    const front = if (fg) |f| win.GetWindowThreadProcessId(f, null) else 0;
    // Sharing input with a thread that isn't pumping, like one stopped in a debugger, makes the focus
    // change below wait on it forever. Without sharing, its deactivation just queues up for it
    const borrow = front != 0 and front != me and responds(fg.?);
    if (borrow) _ = win.AttachThreadInput(me, front, .TRUE);
    defer if (borrow) {
        _ = win.AttachThreadInput(me, front, .FALSE);
    };
    _ = win.BringWindowToTop(hwnd);
    _ = win.SetForegroundWindow(hwnd);
    _ = win.SetFocus(hwnd);
    return win.GetForegroundWindow() == hwnd;
}

/// Whether its thread answers a message soon.
fn responds(hwnd: Handle) bool {
    return win.SendMessageTimeoutW(hwnd, WM_NULL, 0, 0, win.SMTO_BLOCK | win.SMTO_ABORTIFHUNG, 100, null) != 0;
}

const WM_NULL: u32 = 0;

pub fn destroy(hwnd: Handle) void {
    _ = win.DestroyWindow(hwnd);
}

pub fn send(hwnd: Handle, msg: u32, wparam: usize, lparam: isize) isize {
    return win.SendMessageW(hwnd, msg, wparam, lparam);
}

pub fn post(hwnd: Handle, msg: u32, wparam: usize, lparam: isize) bool {
    return win.PostMessageW(hwnd, msg, wparam, lparam).toBool();
}

pub fn pump() void {
    var m: win.MSG = .{};
    while (win.PeekMessageW(&m, null, 0, 0, win.PM_REMOVE).toBool()) {
        _ = win.TranslateMessage(&m);
        _ = win.DispatchMessageW(&m);
    }
}

pub fn defaultProc(m: *const window.Message) isize {
    return win.DefWindowProcW(m.window, m.msg, m.wparam, m.lparam);
}

pub fn registerMessage(comptime name: []const u8) !u32 {
    const id = win.RegisterWindowMessageW(std.unicode.utf8ToUtf16LeStringLiteral(name));
    return if (id == 0) error.RegisterMessageFailed else id;
}

test {
    _ = Subclass;
}

test "a file dialog's watch only calls while its thread answers" {
    const hwnd = try createHidden();
    defer destroy(hwnd);
    const Count = struct {
        n: u32 = 0,
        fn add(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            _ = @atomicRmw(u32, &self.n, .Add, 1, .monotonic);
        }
    };
    var count: Count = .{};
    var watching = Watch.start(hwnd, .{ .ctx = &count, .func = Count.add }).?;
    defer watching.stop();

    // Pumping, like a dialog's modal loop
    const until = win.GetTickCount64() + 1500;
    while (win.GetTickCount64() < until) {
        pump();
        sys_thread.sleepMs(5);
    }
    const while_pumping = @atomicLoad(u32, &count.n, .monotonic);
    try std.testing.expect(while_pumping >= 1);

    // Stuck, so no calls. One already in flight might still land
    sys_thread.sleepMs(1500);
    try std.testing.expect(@atomicLoad(u32, &count.n, .monotonic) <= while_pumping + 1);
}

const sys_thread = @import("tuft_sys").thread;
