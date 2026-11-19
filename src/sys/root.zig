//! OS basics under `tuft_mem` and `tuft_hook`. Backed by `win/`.

const std = @import("std");
const builtin = @import("builtin");

/// Win32 bindings. Only what we use.
pub const win = if (builtin.os.tag == .windows) @import("win/api.zig") else struct {};

const native = switch (builtin.os.tag) {
    .windows => @import("win/root.zig"),
    else => @compileError("tuft supports Windows only"),
};

pub const clipboard = @import("clipboard.zig");
/// WAV sounds, played off the caller's thread.
pub const sound = @import("sound.zig");
pub const memory = @import("memory.zig");
pub const thread = @import("thread.zig");
pub const exceptions = @import("exceptions.zig");
pub const module = @import("module.zig");

pub const version = struct {
    pub const FileInfo = native.version.FileInfo;
    pub const Version = native.version.Version;
    pub const Versions = native.version.Versions;
    /// Null if the file has no version resource.
    pub const fileInfo = native.version.fileInfo;
};

pub const drivers = struct {
    /// Like `vgk`. Anyone can list these, unlike their addresses. Free with `free`.
    pub const runningAlloc = native.drivers.runningDriversAlloc;
    pub const free = native.drivers.freeNames;
};

pub const registry = struct {
    pub const Root = enum { current_user, local_machine };
    /// x86 programs get `WOW6432Node` keys on 64-bit Windows.
    pub const View = enum { native, x86 };
    /// Strings come back as WTF-8 and the caller frees each one.
    pub const Key = native.registry.Key;

    pub fn free(allocator: std.mem.Allocator, names: []const []const u8) void {
        for (names) |n| allocator.free(n);
        allocator.free(names);
    }
};

pub const appearance = struct {
    pub const Mode = enum { light, dark };
    /// Whether the OS wants apps light or dark. Null if it doesn't say.
    pub const mode = native.appearance.mode;
};

pub const tls = struct {
    /// So a stub can write it. See `arch.writeFnStub`.
    pub const locate = native.tls.locate;
};

pub const sync = struct {
    /// No allocation, no setup beyond `.{}`.
    pub const RwLock = native.sync.RwLock;
    /// Wakes one waiter per `set`, like a thread waiting for rare work.
    pub const Signal = native.sync.Signal;
    pub const SharedList = @import("shared_list.zig").SharedList;
};

pub const fiber = struct {
    /// A stack you switch into and out of, maybe on different threads.
    pub const Fiber = native.fiber.Fiber;
};

pub const clock = struct {
    /// Monotonic, same across threads and modules.
    pub const nanos = native.clock.nanos;
};

test "appearance" {
    // Whatever it says, asking mustn't fail
    _ = appearance.mode();
}

pub const terminal = struct {
    /// The parent's console or a new one, with ANSI codes on.
    pub const open = native.terminal.open;

    pub const isOpen = native.terminal.isOpen;

    pub const showTerminal = native.terminal.showTerminal;

    pub const hideTerminal = native.terminal.hideTerminal;
};

test {
    std.testing.refAllDecls(@This());
    _ = native;
    _ = @import("shared_list.zig");
}
