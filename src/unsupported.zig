//! Stand-in for every tuft module on unsupported targets.

const builtin = @import("builtin");

comptime {
    @compileError("tuft only builds for Windows on x64 or x86, not " ++ @tagName(builtin.os.tag) ++ " on " ++ @tagName(builtin.cpu.arch));
}
