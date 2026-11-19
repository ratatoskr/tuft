//! The part of `tuft_mem` build tools can use.

pub const pattern = @import("pattern.zig");
/// Only its data. `locate` needs the rest of `tuft_mem`.
pub const Sig = @import("Sig.zig");
