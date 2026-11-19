//! Glue from a hook's stub into the user's callback.

const std = @import("std");
const arch = @import("tuft_arch");
const sys = @import("tuft_sys");
const memory = @import("tuft_mem");
const Hook = @import("Hook.zig");
const meta = @import("tuft_arch").meta;
const CpuContext = arch.CpuContext;

// Stubs pass the *Hook in a thread-local, since a register wouldn't survive prologues like `__chkstk`

threadlocal var current_hook: ?*Hook = null;

/// Where `current_hook` lives, for the stubs. Found by `init`.
var current_hook_slot: arch.TlsSlot = undefined;
var initialized = false;

pub fn init() !void {
    if (initialized) return;
    current_hook_slot = try sys.tls.locate(@ptrCast(&current_hook));
    initialized = true;
}

pub const fn_stub_size = arch.fn_stub_size;

/// Sets `current_hook = hook`, then jumps to `entry`.
pub fn writeFnStub(dest: *[fn_stub_size]u8, hook: *Hook, entry: usize) void {
    std.debug.assert(initialized);
    arch.writeFnStub(dest, @intFromPtr(hook), current_hook_slot, entry);
}

/// Read it before the detour calls anything that could hit another fn hook on this thread.
pub inline fn currentHook() *Hook {
    return current_hook.?;
}

// Callbacks can also ask for the context and the hook, matched by type in any order

fn hasContext(comptime ContextType: type) bool {
    return ContextType != void and ContextType != @TypeOf(null) and ContextType != type;
}

fn CallbackArgs(comptime CallbackFunc: anytype) type {
    return std.meta.ArgsTuple(meta.FnType(@TypeOf(CallbackFunc)));
}

/// The context or `*Hook`. Fn hooks can also get `*TypedHook(FnT)`.
inline fn inject(comptime P: type, comptime ContextType: type, comptime FnT: ?type, hook: *Hook) P {
    if (comptime hasContext(ContextType) and P == ContextType) return @ptrFromInt(hook.user_data);
    if (P == *Hook) return hook;
    if (FnT) |T| {
        // TypedHook(T) is an opaque alias of the same pointer
        if (P == *Hook.TypedHook(T)) return @ptrCast(hook);
    }
    @compileError("Callback parameter of type '" ++ @typeName(P) ++ "' can't be injected; expected *Hook" ++
        (if (FnT != null) ", *TypedHook(T)" else "") ++
        (if (hasContext(ContextType)) " or the context type '" ++ @typeName(ContextType) ++ "'" else " (no context was provided)"));
}

/// A detour with `T`'s exact signature that forwards to `CallbackFunc`.
pub fn FnBridge(comptime T: type, comptime CallbackFunc: anytype, comptime ContextType: type) type {
    const target = meta.fnInfo(T);
    const cb_params = meta.fnInfo(@TypeOf(CallbackFunc)).param_types;
    const params = target.param_types;
    const R = target.return_type.?;

    if (cb_params.len < params.len) @compileError("CallbackFunc has fewer parameters than target signature T");
    const extra = cb_params.len - params.len;

    return meta.Forwarder(T, struct {
        pub inline fn invoke(args: anytype) R {
            const hook = currentHook();
            if (!hook.enterCall()) {
                const original: *const meta.FnType(T) = @ptrFromInt(hook.trampoline_addr);
                return @call(.auto, original, args);
            }
            defer hook.leaveCall();

            var cb_args: CallbackArgs(CallbackFunc) = undefined;
            inline for (0..extra) |i| cb_args[i] = inject(cb_params[i].?, ContextType, T, hook);
            inline for (0..params.len) |i| cb_args[extra + i] = args[i];
            return @call(.auto, CallbackFunc, cb_args);
        }
    });
}

pub fn midStubSize() usize {
    return arch.midStubSize();
}

pub fn writeMidStub(dest: []u8, hook: *Hook) void {
    arch.writeMidStub(dest, @intFromPtr(hook), &dispatchMidRouter);
}

/// `*CpuContext` gets the registers, anything else gets injected.
pub fn MidBridge(comptime CallbackFunc: anytype, comptime ContextType: type) type {
    const cb_params = meta.fnInfo(@TypeOf(CallbackFunc)).param_types;
    return struct {
        pub fn run(hook: *Hook, cpu: *CpuContext) callconv(.c) void {
            if (!hook.enterCall()) return;
            defer hook.leaveCall();

            var cb_args: CallbackArgs(CallbackFunc) = undefined;
            inline for (cb_params, 0..) |P, i| {
                cb_args[i] = if (P.? == *CpuContext) cpu else inject(P.?, ContextType, null, hook);
            }
            @call(.never_inline, CallbackFunc, cb_args);
        }
    };
}

/// Returns where to resume. That's the trampoline, or wherever the callback set the ip to.
pub fn dispatchMidRouter(context: usize, cpu: *CpuContext) callconv(.c) usize {
    const hook: *Hook = @ptrFromInt(context);
    cpu.setIp(hook.target_addr);
    const cb: *const fn (*Hook, *CpuContext) callconv(.c) void = @ptrFromInt(hook.callback_addr);
    cb(hook, cpu);
    const ip = cpu.ip();
    if (ip != hook.target_addr) return ip;
    return if (hook.mid_resumes) hook.resume_addr else hook.trampoline_addr;
}

const tests = struct {
    const registry = @import("registry.zig");

    /// Fn stub for `Bridge` in a fresh executable page. Returns the page.
    fn stubFor(comptime Bridge: type, hook: *Hook) !memory.pages.Slice {
        const page = try memory.pages.allocAny(fn_stub_size);
        writeFnStub(page[0..fn_stub_size], hook, @intFromPtr(&Bridge.detour));
        return page;
    }

    test "forwards register and float args" {
        try registry.init(std.testing.allocator);
        defer registry.deinit();

        const TargetFn = fn (i32, f32, u64) callconv(.c) i32;
        var mock_hook = std.mem.zeroes(Hook);
        const Bridge = FnBridge(TargetFn, struct {
            fn cb(hook: *Hook, a: i32, b: f32, c: u64) i32 {
                std.testing.expectEqual(42, a) catch return -1;
                std.testing.expectEqual(3.14, b) catch return -1;
                std.testing.expectEqual(0xDEADBEEF, c) catch return -1;
                return @intCast(@intFromPtr(hook) & 0x7FFF_FFFF);
            }
        }.cb, void);

        const page = try stubFor(Bridge, &mock_hook);
        defer memory.pages.free(page);

        const f: *const TargetFn = @ptrCast(page.ptr);
        try std.testing.expectEqual(@as(i32, @intCast(@intFromPtr(&mock_hook) & 0x7FFF_FFFF)), f(42, 3.14, 0xDEADBEEF));
    }

    test "forwards stack args" {
        try registry.init(std.testing.allocator);
        defer registry.deinit();

        const TargetFn = fn (u64, u64, u64, u64, u64, u64) callconv(.c) u64;
        var ctx_value: u64 = 1000;
        var mock_hook = std.mem.zeroes(Hook);
        mock_hook.user_data = @intFromPtr(&ctx_value);

        const CtxFirst = FnBridge(TargetFn, struct {
            fn cb(ctx: *u64, h: *Hook, a: u64, b: u64, c: u64, d: u64, e: u64, f: u64) u64 {
                _ = h;
                return ctx.* + a + b + c + d + e + f;
            }
        }.cb, *u64);
        const HookFirst = FnBridge(TargetFn, struct {
            fn cb(h: *Hook, ctx: *u64, a: u64, b: u64, c: u64, d: u64, e: u64, f: u64) u64 {
                _ = h;
                return ctx.* * 2 + a + b + c + d + e + f;
            }
        }.cb, *u64);

        const p1 = try stubFor(CtxFirst, &mock_hook);
        defer memory.pages.free(p1);
        const p2 = try stubFor(HookFirst, &mock_hook);
        defer memory.pages.free(p2);

        try std.testing.expectEqual(1021, @as(*const TargetFn, @ptrCast(p1.ptr))(1, 2, 3, 4, 5, 6));
        try std.testing.expectEqual(2021, @as(*const TargetFn, @ptrCast(p2.ptr))(1, 2, 3, 4, 5, 6));
    }

    test "survives stack probe" {
        try registry.init(std.testing.allocator);
        defer registry.deinit();

        const TargetFn = fn (u32) callconv(.c) usize;
        var mock_hook = std.mem.zeroes(Hook);
        const Bridge = FnBridge(TargetFn, struct {
            fn cb(hook: *Hook, n: u32) usize {
                var big: [64 * 1024]u8 = undefined;
                @memset(&big, @truncate(n));
                std.mem.doNotOptimizeAway(&big);
                return @intFromPtr(hook) + big[n];
            }
        }.cb, void);

        const page = try stubFor(Bridge, &mock_hook);
        defer memory.pages.free(page);

        const f: *const TargetFn = @ptrCast(page.ptr);
        try std.testing.expectEqual(@intFromPtr(&mock_hook) + 7, f(7));
    }

    test "works on new threads" {
        try registry.init(std.testing.allocator);
        defer registry.deinit();

        const TargetFn = fn (u32) callconv(.c) usize;
        var mock_hook = std.mem.zeroes(Hook);
        const Bridge = FnBridge(TargetFn, struct {
            fn cb(hook: *Hook, n: u32) usize {
                return @intFromPtr(hook) + n;
            }
        }.cb, void);

        const page = try stubFor(Bridge, &mock_hook);
        defer memory.pages.free(page);

        const Worker = struct {
            fn run(f: *const TargetFn, out: *usize) void {
                out.* = f(3);
            }
        };
        var result: usize = 0;
        const thread = try std.Thread.spawn(.{}, Worker.run, .{ @as(*const TargetFn, @ptrCast(page.ptr)), &result });
        thread.join();
        try std.testing.expectEqual(@intFromPtr(&mock_hook) + 3, result);
    }

    const ax = if (arch.bits == 64) "rax" else "eax";
    const cx = if (arch.bits == 64) "rcx" else "ecx";

    test "router resumes at trampoline" {
        const MockPlugin = struct {
            call_count: u32 = 0,
            last_ax: usize = 0,

            fn detour(self: *@This(), cpu: *CpuContext) void {
                self.call_count += 1;
                self.last_ax = @field(cpu, ax);
                @field(cpu, ax) = 0x7777_AAAA;
            }
        };

        var plugin_state = MockPlugin{};
        var mock_hook = std.mem.zeroes(Hook);
        mock_hook.callback_addr = @intFromPtr(&MidBridge(MockPlugin.detour, *MockPlugin).run);
        mock_hook.user_data = @intFromPtr(&plugin_state);
        mock_hook.trampoline_addr = 0x1400_1234;

        var cpu_frame = std.mem.zeroes(CpuContext);
        @field(cpu_frame, ax) = 0x1111_4444;

        const resume_addr = dispatchMidRouter(@intFromPtr(&mock_hook), &cpu_frame);

        try std.testing.expectEqual(1, plugin_state.call_count);
        try std.testing.expectEqual(0x1111_4444, plugin_state.last_ax);
        try std.testing.expectEqual(0x7777_AAAA, @field(cpu_frame, ax));
        try std.testing.expectEqual(0x1400_1234, resume_addr);
    }

    test "MidBridge injects by type" {
        var counter: u32 = 0;
        var mock_hook = std.mem.zeroes(Hook);
        mock_hook.user_data = @intFromPtr(&counter);
        var cpu_frame = std.mem.zeroes(CpuContext);

        const CpuOnly = MidBridge(struct {
            fn cb(cpu: *CpuContext) void {
                @field(cpu, ax) += 1;
            }
        }.cb, void);
        const Shuffled = MidBridge(struct {
            fn cb(hook: *Hook, cpu: *CpuContext, count: *u32) void {
                count.* += 1;
                @field(cpu, cx) = @intCast(@intFromPtr(hook));
            }
        }.cb, *u32);

        CpuOnly.run(&mock_hook, &cpu_frame);
        Shuffled.run(&mock_hook, &cpu_frame);

        try std.testing.expectEqual(1, @field(cpu_frame, ax));
        try std.testing.expectEqual(@intFromPtr(&mock_hook), @field(cpu_frame, cx));
        try std.testing.expectEqual(1, counter);
    }
};

test {
    _ = tests;
}
