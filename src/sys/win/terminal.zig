const win = @import("api.zig");

/// The parent's console or a new one, with ANSI codes on.
pub fn open(title: ?[*:0]const u8) bool {
    if (win.GetConsoleWindow() == null) {
        if (!win.AttachConsole(win.ATTACH_PARENT_PROCESS).toBool() and !win.AllocConsole().toBool()) return false;
    }

    const stdout = win.GetStdHandle(win.STD_HANDLE.OUTPUT_HANDLE);
    if (stdout == win.INVALID_HANDLE_VALUE) return false;

    var raw_mode: win.DWORD = 0;
    if (win.GetConsoleMode(stdout, &raw_mode).toBool()) {
        var mode: win.CONSOLE_OUTPUT_MODE = @bitCast(raw_mode);
        mode.ENABLE_PROCESSED_OUTPUT = true;
        mode.ENABLE_VIRTUAL_TERMINAL_PROCESSING = true;
        const new_mode: win.DWORD = @bitCast(mode);
        if (new_mode != raw_mode) _ = win.SetConsoleMode(stdout, new_mode);
    }

    _ = showTerminal();

    if (title) |t| _ = setTitle(t);

    return true;
}

pub fn setTitle(title: [*:0]const u8) bool {
    return win.SetConsoleTitleA(title).toBool();
}

/// Whether this process has a console, ours or one it was started with.
pub fn isOpen() bool {
    return win.GetConsoleWindow() != null;
}

pub fn showTerminal() bool {
    const hwnd = win.GetConsoleWindow();
    if (hwnd) |h| return win.ShowWindow(h, win.SW_SHOW).toBool();
    return false;
}

pub fn hideTerminal() bool {
    const hwnd = win.GetConsoleWindow();
    if (hwnd) |h| return win.ShowWindow(h, win.SW_HIDE).toBool();
    return false;
}
