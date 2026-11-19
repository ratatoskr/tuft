//! Picks the backend. Only this module looks at `native`.

const builtin = @import("builtin");

pub const native = switch (builtin.cpu.arch) {
    .x86_64 => @import("x64/root.zig"),
    .x86 => @import("x86/root.zig"),
    else => @compileError("tuft supports x86 and x64 only"),
};

comptime {
    if (builtin.os.tag != .windows) @compileError("tuft's code stubs assume the Windows ABI");
}
