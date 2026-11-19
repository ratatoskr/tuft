const std = @import("std");
const zwin = std.os.windows;

const arch = @import("tuft_arch");

/// Goes through the TEB's `ThreadLocalStoragePointer` and `_tls_index`.
pub fn locate(variable: *const anyopaque) !arch.TlsSlot {
    const blocks: [*]const usize = @ptrCast(@alignCast(zwin.teb().ThreadLocalStoragePointer));
    const block = blocks[_tls_index];
    const addr = @intFromPtr(variable);
    if (addr < block) return error.UnsupportedTlsLayout;
    const offset = addr - block;
    if (offset > std.math.maxInt(i32) or _tls_index > std.math.maxInt(i32) / @sizeOf(usize)) return error.UnsupportedTlsLayout;
    return .{
        .segment = if (arch.bits == 64) .gs else .fs,
        .array_offset = @offsetOf(zwin.TEB, "ThreadLocalStoragePointer"),
        .index = _tls_index,
        .offset = @intCast(offset),
    };
}

/// The loader sets it.
extern var _tls_index: u32;

const tests = struct {
    threadlocal var value: u32 = 7;

    test "locate via TEB" {
        const slot = try locate(&value);
        const blocks: [*]const usize = @ptrCast(@alignCast(zwin.teb().ThreadLocalStoragePointer));
        try std.testing.expectEqual(@intFromPtr(&value), blocks[slot.index] + slot.offset);
    }
};

test {
    _ = tests;
}
