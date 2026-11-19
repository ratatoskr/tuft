//! Reading game memory by the types in a `.sal` schema, and finding what its `[Sig]`s point at.

const std = @import("std");

pub const Ref = @import("Ref.zig");
pub const Value = Ref.Value;
pub const sigs = @import("sigs.zig");

test {
    std.testing.refAllDecls(@This());
    _ = @import("tests.zig");
}
