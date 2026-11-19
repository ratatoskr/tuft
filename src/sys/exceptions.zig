//! Raw exceptions. Use `tuft_hook.exceptions` to subscribe.

const arch = @import("tuft_arch");
const native = @import("win/exceptions.zig");

pub const Kind = enum {
    access_violation,
    /// Guard stays off until rearmed.
    guard_page,
    /// Mapped-file fault. See `fault`.
    in_page_error,
    /// `ip` points at int3. Skip it or restore its byte.
    breakpoint,
    /// See `debug.status`.
    single_step,
    illegal_instruction,
    privileged_instruction,
    misaligned_data,
    int_divide_by_zero,
    int_overflow,
    float,
    /// Includes C++ throws. Check `code`.
    other,
};

pub const Fault = struct {
    pub const Access = enum { read, write, execute };
    access: Access,
    address: usize,
};

/// `control` is DR7, `status` is DR6.
pub const DebugRegisters = struct {
    address: [4]usize = @splat(0),
    status: usize = 0,
    control: usize = 0,
};

/// Edits apply on `.handled`, not `.pass`. `cpu.ip()` is where it happened, and data breakpoints point after the access.
pub const Exception = struct {
    kind: Kind,
    /// Like `0xC0000005`.
    code: u32,
    /// For access violations, guard pages and in-page errors.
    fault: ?Fault = null,
    /// Returning `.handled` when false raises another exception.
    continuable: bool = true,
    cpu: arch.CpuContext,
    debug: DebugRegisters = .{},
    /// Borrowed OS record, valid only during `Unhandled`.
    os: ?*const anyopaque = null,

    const trap_flag: usize = 1 << 8;
    const resume_flag: usize = 1 << 16;

    pub fn setSingleStep(self: *Exception, on: bool) void {
        const flags = self.flagsPtr();
        if (on) flags.* |= trap_flag else flags.* &= ~@as(@TypeOf(flags.*), trap_flag);
    }

    pub fn singleStep(self: *const Exception) bool {
        return @constCast(self).flagsPtr().* & trap_flag != 0;
    }

    /// Avoids retriggering an execute breakpoint.
    pub fn skipBreakpointOnce(self: *Exception) void {
        self.flagsPtr().* |= resume_flag;
    }

    fn flagsPtr(self: *Exception) if (arch.bits == 64) *u64 else *u32 {
        return if (comptime arch.bits == 64) &self.cpu.rflags else &self.cpu.eflags;
    }
};

pub const Action = enum {
    pass,
    handled,
};

/// Runs on the faulting thread. Ignores nested faults and stack overflows.
pub const Router = native.Router;
/// One per router. `uninstall` doesn't wait for callbacks.
pub const Vectored = native.Vectored;
/// Last-chance handler, including stack overflows.
pub const Unhandled = native.Unhandled;
/// Call early so crashes don't need to load DLLs.
pub const prepareMinidumps = native.prepareMinidumps;
/// `exception` is an `Exception.os`.
pub const writeMinidump = native.writeMinidump;
/// Of another process, from outside it, so its locks can't hang the dump.
pub const writeMinidumpOf = native.writeMinidumpOf;
/// Runs a command line and waits for its exit code, without allocating. Like a dump helper mid-crash.
pub const runAndWait = native.runAndWait;
