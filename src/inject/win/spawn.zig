//! Spawns a process, optionally suspended.

const std = @import("std");

const inject = @import("../root.zig");
const win = @import("tuft_sys").win;

pub const Spawned = struct {
    pid: u32,
    process: win.HANDLE,
    thread: win.HANDLE,

    pub fn @"resume"(self: *const Spawned) void {
        _ = win.ResumeThread(self.thread);
    }

    pub fn isAlive(self: *const Spawned) bool {
        var code: win.DWORD = 0;
        if (win.GetExitCodeProcess(self.process, &code) == .FALSE) return false;
        return code == win.STILL_ACTIVE;
    }

    pub fn terminate(self: *const Spawned) void {
        _ = win.TerminateProcess(self.process, 0);
    }

    pub fn close(self: *Spawned) void {
        win.CloseHandle(self.thread);
        win.CloseHandle(self.process);
        self.* = undefined;
    }
};

pub const SpawnOptions = struct {
    /// `Spawned.resume` to run, like to inject before any game code runs.
    suspended: bool = false,
    no_window: bool = false,
    /// After the program itself.
    args: []const []const u8 = &.{},
    /// Null means ours.
    cwd: ?[]const u8 = null,
};

pub fn spawn(allocator: std.mem.Allocator, path: []const u8, options: inject.SpawnOptions) !Spawned {
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(allocator, path);
    defer allocator.free(wide);

    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(allocator);
    try appendQuoted(allocator, &line, path);
    for (options.args) |arg| {
        try line.append(allocator, ' ');
        try appendQuoted(allocator, &line, arg);
    }
    // CreateProcessW may write to the command line, so give it its own copy
    const command_line = try std.unicode.utf8ToUtf16LeAllocZ(allocator, line.items);
    defer allocator.free(command_line);
    const cwd = if (options.cwd) |dir| try std.unicode.utf8ToUtf16LeAllocZ(allocator, dir) else null;
    defer if (cwd) |dir| allocator.free(dir);

    var flags: win.DWORD = 0;
    if (options.suspended) flags |= win.CREATE_SUSPENDED;
    if (options.no_window) flags |= win.CREATE_NO_WINDOW;

    var startup: win.STARTUPINFOW = std.mem.zeroes(win.STARTUPINFOW);
    startup.cb = @sizeOf(win.STARTUPINFOW);
    var info: win.PROCESS_INFORMATION = undefined;

    if (win.CreateProcessW(wide.ptr, command_line.ptr, null, null, .FALSE, flags, null, if (cwd) |dir| dir.ptr else null, &startup, &info) == .FALSE) {
        return error.SpawnFailed;
    }
    return .{ .pid = info.dwProcessId, .process = info.hProcess, .thread = info.hThread };
}

/// Quoted like `CommandLineToArgvW` splits them.
fn appendQuoted(allocator: std.mem.Allocator, line: *std.ArrayList(u8), arg: []const u8) !void {
    if (arg.len != 0 and std.mem.indexOfAny(u8, arg, " \t\"") == null) return line.appendSlice(allocator, arg);
    try line.append(allocator, '"');
    var backslashes: usize = 0;
    for (arg) |ch| {
        if (ch == '\\') {
            backslashes += 1;
            continue;
        }
        const doubled = if (ch == '"') backslashes * 2 + 1 else backslashes;
        try line.appendNTimes(allocator, '\\', doubled);
        backslashes = 0;
        try line.append(allocator, ch);
    }
    try line.appendNTimes(allocator, '\\', backslashes * 2);
    try line.append(allocator, '"');
}

test "argument quoting" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "plain", "plain" },
        .{ "has space", "\"has space\"" },
        .{ "", "\"\"" },
        .{ "say \"hi\"", "\"say \\\"hi\\\"\"" },
        .{ "C:\\dir with space\\", "\"C:\\dir with space\\\\\"" },
    };
    for (cases) |c| {
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(allocator);
        try appendQuoted(allocator, &line, c[0]);
        try std.testing.expectEqualStrings(c[1], line.items);
    }
}
