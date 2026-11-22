//! Hooking and memory tools for x86 and x64 Windows processes.

pub const arch = @import("tuft_arch");
pub const @"asm" = @import("tuft_asm");
pub const sys = @import("tuft_sys");
pub const mem = @import("tuft_mem");
pub const schema = @import("tuft_schema");
pub const hook = @import("tuft_hook");
pub const event = @import("tuft_event");
pub const input = @import("tuft_input");
pub const vfs = @import("tuft_vfs");
pub const inject = @import("tuft_inject");
pub const proxy = @import("tuft_proxy");
pub const window = @import("tuft_window");
pub const gfx = @import("tuft_gfx");
pub const ui = @import("tuft_ui");
pub const devtools = @import("tuft_devtools");
pub const text = @import("tuft_text");
pub const math = @import("tuft_math");

/// Addresses that can hook themselves. The rest is in `mem`.
pub const memory = hook.memory;
pub const Hook = hook.Hook;
pub const TypedHook = hook.TypedHook;
pub const CpuContext = arch.CpuContext;
