//! Windows window helpers.

const std = @import("std");

const window = @import("../root.zig");
const win = @import("tuft_sys").win;
const sync = @import("tuft_sys").sync;
const Atomic = @import("tuft_arch").atomic.Value;

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
    const com = Com.init();
    defer com.deinit();

    const save = options.mode == .save;
    const dialog = try Dialog.create(if (save) &win.CLSID_FileSaveDialog else &win.CLSID_FileOpenDialog);
    defer dialog.release();
    try dialog.setup(a, if (save) win.FOS_OVERWRITEPROMPT else win.FOS_FILEMUSTEXIST, options.title, options.folder);
    const d = dialog.ptr;

    // "Kind (*.ext)" then "All files"
    var types: [2]win.COMDLG_FILTERSPEC = undefined;
    var count: u32 = 0;
    if (options.extension.len > 0) {
        const spec = try std.fmt.allocPrint(a, "*{s}", .{options.extension});
        const name = if (options.kind.len > 0) try std.fmt.allocPrint(a, "{s} ({s})", .{ options.kind, spec }) else spec;
        types[count] = .{ .name = try W(a, name), .spec = try W(a, spec) };
        count += 1;
    }
    types[count] = .{ .name = std.unicode.utf8ToUtf16LeStringLiteral("All files"), .spec = std.unicode.utf8ToUtf16LeStringLiteral("*.*") };
    count += 1;
    _ = d.vtable.SetFileTypes(d, count, &types);
    _ = d.vtable.SetFileTypeIndex(d, 1);
    if (options.extension.len > 1) _ = d.vtable.SetDefaultExtension(d, try W(a, options.extension[1..]));
    if (options.file_name.len > 0) _ = d.vtable.SetFileName(d, try W(a, options.file_name));

    return dialog.show(gpa, options.owner, options.over, options.alive);
}

pub fn pickFolder(gpa: std.mem.Allocator, options: window.FolderDialog) !?[]u8 {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const com = Com.init();
    defer com.deinit();

    const dialog = try Dialog.create(&win.CLSID_FileOpenDialog);
    defer dialog.release();
    try dialog.setup(arena.allocator(), win.FOS_PICKFOLDERS, options.title, options.folder);
    return dialog.show(gpa, options.owner, options.over, options.alive);
}

/// COM on the dialog's thread, which the shell's dialogs need. Fine if it's already set up there,
/// and a thread set up for free threading still works.
const Com = struct {
    ok: bool,

    fn init() Com {
        return .{ .ok = win.CoInitializeEx(null, win.COINIT_APARTMENTTHREADED | win.COINIT_DISABLE_OLE1DDE) >= 0 };
    }

    fn deinit(self: Com) void {
        if (self.ok) win.CoUninitialize();
    }
};

/// The shell's open, save or folder dialog.
const Dialog = struct {
    ptr: *win.IFileDialog,

    fn create(clsid: *const @TypeOf(win.CLSID_FileOpenDialog)) !Dialog {
        var raw: ?*anyopaque = null;
        if (win.CoCreateInstance(clsid, null, win.CLSCTX_INPROC_SERVER, &win.IID_IFileDialog, &raw) < 0) return error.DialogFailed;
        return .{ .ptr = @ptrCast(@alignCast(raw orelse return error.DialogFailed)) };
    }

    fn release(self: Dialog) void {
        _ = self.ptr.vtable.Release(self.ptr);
    }

    fn setup(self: Dialog, a: std.mem.Allocator, extra: win.DWORD, title: []const u8, folder: []const u8) !void {
        const d = self.ptr;
        var flags: win.DWORD = 0;
        _ = d.vtable.GetOptions(d, &flags);
        _ = d.vtable.SetOptions(d, flags | extra | win.FOS_FORCEFILESYSTEM | win.FOS_PATHMUSTEXIST | win.FOS_NOCHANGEDIR);
        if (title.len > 0) _ = d.vtable.SetTitle(d, try std.unicode.utf8ToUtf16LeAllocZ(a, title));
        // A folder that's gone just starts it somewhere else
        if (folder.len > 0) start: {
            const path = try std.unicode.utf8ToUtf16LeAllocZ(a, folder);
            var item_raw: ?*anyopaque = null;
            if (win.SHCreateItemFromParsingName(path, null, &win.IID_IShellItem, &item_raw) < 0) break :start;
            const item: *win.IShellItem = @ptrCast(@alignCast(item_raw orelse break :start));
            defer _ = item.vtable.Release(item);
            _ = d.vtable.SetFolder(d, item);
        }
    }

    /// Blocks till it's closed. The picked path, or null if it was cancelled.
    fn show(self: Dialog, gpa: std.mem.Allocator, owner: ?Handle, over: ?Handle, alive: ?window.FileDialog.Alive) !?[]u8 {
        const d = self.ptr;
        const stand_in = StandIn.over(over);
        defer if (stand_in) |h| destroy(h);
        const noted = DialogThreads.note();
        defer DialogThreads.forget(noted);
        var watching = Watch.start(owner, alive);
        defer if (watching) |*w| w.stop();
        const shown = d.vtable.Show(d, owner orelse stand_in);
        if (shown == win.HRESULT_CANCELLED) return null;
        if (shown < 0) return error.DialogFailed;

        var result: ?*win.IShellItem = null;
        if (d.vtable.GetResult(d, &result) < 0) return error.DialogFailed;
        const item = result orelse return error.DialogFailed;
        defer _ = item.vtable.Release(item);
        var name: ?[*:0]u16 = null;
        if (item.vtable.GetDisplayName(item, win.SIGDN_FILESYSPATH, &name) < 0) return error.DialogFailed;
        const wide = name orelse return error.DialogFailed;
        defer win.CoTaskMemFree(wide);
        return try std.unicode.utf16LeToUtf8Alloc(gpa, std.mem.span(wide));
    }
};

pub fn ownsDialog(hwnd: Handle) bool {
    const id = threadOf(hwnd);
    if (id == 0) return false;
    for (&DialogThreads.ids) |*slot| if (slot.load(.acquire) == id) return true;
    return false;
}

/// Threads in `pickFile` or `pickFolder`. Every window of theirs is the dialog's while they are.
const DialogThreads = struct {
    var ids: [8]Atomic(u32) = @splat(.init(0));

    /// Null if they're all taken, which only means the game might see it as another program's.
    fn note() ?*Atomic(u32) {
        const me = win.GetCurrentThreadId();
        for (&ids) |*slot| if (slot.cmpxchgStrong(0, me, .acq_rel, .acquire) == null) return slot;
        return null;
    }

    fn forget(slot: ?*Atomic(u32)) void {
        if (slot) |s| s.store(0, .release);
    }
};

/// A hidden topmost window of this thread, covering `over`, to own a dialog. The dialog then opens
/// centered over `over` and in front of it, without waiting on `over`'s thread.
const StandIn = struct {
    fn over(target: ?Handle) ?Handle {
        const t = target orelse return null;
        var rect: win.RECT = .{};
        if (!win.GetWindowRect(t, &rect).toBool()) return null;
        return win.CreateWindowExW(
            win.WS_EX_TOOLWINDOW | win.WS_EX_TOPMOST,
            std.unicode.utf8ToUtf16LeStringLiteral("STATIC"),
            std.unicode.utf8ToUtf16LeStringLiteral(""),
            win.WS_POPUP,
            rect.left,
            rect.top,
            rect.right - rect.left,
            rect.bottom - rect.top,
            null,
            null,
            null,
            null,
        );
    }
};

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
