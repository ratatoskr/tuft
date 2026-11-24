//! Memory, ours or anyone's.

const std = @import("std");

const sys_memory = @import("tuft_sys").memory;

pub const pattern = @import("pattern.zig");
pub const insn = @import("tuft_arch").insn;
pub const scans = @import("scans.zig");
pub const originals = @import("originals.zig");
pub const AddressSource = originals.AddressSource;
pub const Sources = originals.Sources;
pub const CodeSnapshot = @import("CodeSnapshot.zig");
pub const DiskImage = @import("DiskImage.zig");
pub const Memory = @import("Memory.zig");
pub const Symbols = @import("Symbols.zig");
pub const Sig = @import("Sig.zig");
/// Signatures made for an address.
pub const sig_maker = @import("sig_maker.zig");
pub const Location = @import("Location.zig");
pub const Claims = @import("Claims.zig");
pub const pages = @import("pages.zig");
/// Where code we put in a game and the data it reads go.
pub const Placement = @import("Placement.zig");
pub const values = @import("values.zig");
pub const Search = @import("Search.zig");

pub const isReadable = sys_memory.isReadable;
/// Ignores protection and flushes the instruction cache.
pub const writeCode = sys_memory.writeCode;
/// Works on read-only data like vtables. Returns whether it swapped.
pub const swapPointer = sys_memory.swapPointer;
pub const Protection = sys_memory.Protection;
/// Returns the first page's old protection.
pub const protect = sys_memory.protect;
/// First committed region at or after an address, readable or not. `Memory.regionFrom` skips
/// unreadable ones.
pub const committedFrom = sys_memory.committedFrom;
pub const findCodeCave = @import("caves.zig").findCodeCave;

const plain = With(@import("Address.zig").NoHooks);
/// These can't hook themselves. Use `With` for that.
pub const Address = plain.Address;
pub const Module = plain.Module;
pub const Range = plain.Range;

/// Addresses that can hook themselves through `Hooks`, like `tuft_hook.memory`. Only these
/// depend on `Hooks`, so the rest comes from `tuft_mem` itself.
pub fn With(comptime Hooks: type) type {
    return struct {
        pub const Address = @import("Address.zig").Generic(Hooks);
        pub const Module = @import("Module.zig").Generic(Hooks);
        pub const Range = @import("Range.zig").Generic(Hooks);
    };
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("caves.zig");
    _ = Placement;
    _ = values;
    _ = Search;
    _ = sig_maker;
}
