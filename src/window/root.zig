//! Native windows and message interception.

const std = @import("std");
const builtin = @import("builtin");

const native = switch (builtin.os.tag) {
    .windows => @import("win/root.zig"),
    else => @compileError("tuft supports Windows only"),
};

pub const Handle = native.Handle;

pub const Message = extern struct {
    window: Handle,
    msg: u32,
    wparam: usize,
    lparam: isize,
};

/// Return a result to eat the message, or null to pass it on.
pub const Handler = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, message: *const Message) ?isize,
};

/// Our DLL can unload after `uninstall` even if someone subclassed on top.
pub const Subclass = native.Subclass;

pub const Size = struct { width: u32, height: u32 };
pub const Point = struct { x: i32, y: i32 };

pub const threadOf = native.threadOf;
/// Invisible window for tests and probing. `destroy` it.
pub const createHidden = native.createHidden;
pub const destroy = native.destroy;
pub const clientSize = native.clientSize;
/// Null if the window's gone.
pub const clientToScreen = native.clientToScreen;
/// Frame included, without moving it.
pub const setSize = native.setSize;
/// 1.0 is 100%.
pub const dpiScale = native.dpiScale;
pub const isForeground = native.isForeground;
/// From any thread of this process. True if it worked.
pub const bringToFront = native.bringToFront;
pub const send = native.send;
pub const post = native.post;
pub const pump = native.pump;
pub const defaultProc = native.defaultProc;
/// Unique to `name` system-wide.
pub const registerMessage = native.registerMessage;

pub const FileDialog = struct {
    pub const Mode = enum { open, save };

    mode: Mode,
    owner: ?Handle = null,
    /// Another thread's window to show over, like the game's. Unlike `owner`, doesn't tie the dialog to its slow message loop.
    over: ?Handle = null,
    title: []const u8 = "",
    /// Where it starts. Empty is the system's pick.
    folder: []const u8 = "",
    /// Filled in to start with, for saving.
    file_name: []const u8 = "",
    /// Like "Wraith project".
    kind: []const u8 = "",
    /// Like ".rwp". Added when a name's typed without it.
    extension: []const u8 = "",
    /// Called about twice a second from another thread while the dialog is open, to keep hang watchdogs quiet.
    alive: ?Alive = null,

    pub const Alive = struct {
        ctx: *anyopaque,
        func: *const fn (ctx: *anyopaque) void,
    };
};

/// A native open or save dialog. Blocks until done. Null if cancelled; the caller frees the path.
pub const pickFile = native.pickFile;

pub const FolderDialog = struct {
    owner: ?Handle = null,
    /// See `FileDialog.over`.
    over: ?Handle = null,
    title: []const u8 = "",
    /// Where it starts. Empty is the system's pick.
    folder: []const u8 = "",
    /// See `FileDialog.alive`.
    alive: ?FileDialog.Alive = null,
};

/// Whether `window` belongs to a dialog `pickFile` or `pickFolder` is showing now, for focus hooks. Any thread.
pub const ownsDialog = native.ownsDialog;

/// A native folder picker. Blocks until done. Null if cancelled; the caller frees the path.
pub const pickFolder = native.pickFolder;

test {
    std.testing.refAllDecls(@This());
    _ = native;
}
