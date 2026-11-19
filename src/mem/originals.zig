//! Code as it was before any hooks, one provider per DLL.

const std = @import("std");

/// The range has to sit in one copied section.
pub const Provider = *const fn (start: usize, len: usize) ?[*]const u8;

var provider: std.atomic.Value(?Provider) = .init(null);

/// Returns the old one. Thread-safe.
pub fn setProvider(new: ?Provider) ?Provider {
    return provider.swap(new, .acq_rel);
}

pub fn find(start: usize, len: usize) ?[]const u8 {
    const p = provider.load(.acquire) orelse return null;
    const copy = p(start, len) orelse return null;
    return copy[0..len];
}
