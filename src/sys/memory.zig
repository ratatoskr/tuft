//! Low-level memory. Use `tuft_mem` for higher-level helpers.

const native = @import("win/memory.zig");

pub const page_size = native.page_size;
pub const PageSlice = []align(page_size) u8;

pub const Protection = enum { no_access, read, read_write, read_execute, read_write_execute };

/// Within rel32 reach of `target`. Null if there's no room.
pub const allocNear = native.allocNear;
/// Within rel32 reach of everything from `start` up to `end`. Null if there's no room.
pub const allocNearSpan = native.allocNearSpan;
/// RWX pages anywhere.
pub const allocAny = native.allocAny;
pub const free = native.free;
/// Returns the first page's old protection.
pub const protect = native.protect;
/// Ignores page protection and flushes the icache.
pub const writeCode = native.writeCode;
/// Code made writable, to write while threads are frozen. Protection's changed before freezing
/// and put back after, since some games hook it with a lock a frozen thread can hold.
pub const Unlocked = native.Unlocked;
pub const unlockCode = native.unlockCode;
/// Swaps even read-only pointers. True if swapped.
pub const swapPointer = native.swapPointer;
pub const isReadable = native.isReadable;

pub const Region = struct {
    start: usize,
    len: usize,
    writable: bool,
    executable: bool,
    /// Only `committedFrom` gives unreadable ones.
    readable: bool = true,
};

/// First readable region at or after `addr`.
pub const regionFrom = native.regionFrom;
/// First committed region at or after `addr`, readable or not.
pub const committedFrom = native.committedFrom;
/// Safe even if the memory goes away mid-read.
pub const readSafe = native.readSafe;
/// Waits for the heap lock. Suspended threads may block it.
pub const waitHeapUnlocked = native.waitHeapUnlocked;

/// Mapped pages, including hook stubs and trampolines.
pub const PageStats = struct {
    live_bytes: usize,
    allocs: usize,
    frees: usize,
};

pub const pageStats = native.pageStats;
