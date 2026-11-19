const native = @import("win/thread.zig");

pub const CodeRange = struct {
    start: usize,
    len: usize,

    pub fn contains(self: CodeRange, addr: usize) bool {
        return addr >= self.start and addr - self.start < self.len;
    }
};

/// What a suspended thread can't be using.
pub const Avoid = struct {
    /// No thread's IP can be in these.
    executing: []const CodeRange = &.{},
    /// No thread's registers can point into these.
    referenced: []const CodeRange = &.{},
    /// Excludes matching threads.
    keep: ?Keep = null,
    /// Avoids threads holding the loader lock.
    loader_lock: bool = false,
};

/// For `Avoid.keep`.
pub const Info = struct {
    id: u32,
    /// 0 if unknown.
    start: usize,
};

pub const Keep = struct {
    ctx: ?*anyopaque = null,
    func: *const fn (ctx: ?*anyopaque, thread: Info) bool,
};

/// Freezes other threads clear of `avoid`. `deinit` resumes them.
pub const freezeThreads = native.freezeThreads;
pub const ThreadFreezeGuard = native.ThreadFreezeGuard;

pub const sleepMs = native.sleepMs;
/// `spawn(*T, func, ctx)`, then `join` it. Works from game threads, unlike `std.Thread.spawn`.
pub const spawn = native.spawn;
pub const join = native.join;
pub const tickMs = native.tickMs;
/// Sets DR0-3 and DR7. Repeat to cover new threads.
pub const setDebugRegisters = native.setDebugRegisters;
/// Includes reserved stack pages.
pub const currentStack = native.currentStack;
