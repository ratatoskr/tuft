//! Vectored exception handling.

const std = @import("std");
const builtin = @import("builtin");

const arch = @import("tuft_arch");
const sys = @import("../root.zig");

const win = @import("api.zig");

const Exception = sys.exceptions.Exception;
const Action = sys.exceptions.Action;
const Kind = sys.exceptions.Kind;
const CpuContext = arch.CpuContext;

pub const Router = fn (exception: *Exception) Action;

const context_flags = switch (builtin.cpu.arch) {
    .x86_64 => struct {
        const debug: win.DWORD = 0x0010_0010; // CONTEXT_AMD64 | CONTEXT_DEBUG_REGISTERS
        const xmm: win.DWORD = 0x0010_0008; // CONTEXT_AMD64 | CONTEXT_FLOATING_POINT
    },
    .x86 => struct {
        const debug: win.DWORD = 0x0001_0010; // CONTEXT_i386 | CONTEXT_DEBUG_REGISTERS
        const xmm: win.DWORD = 0x0001_0020; // CONTEXT_i386 | CONTEXT_EXTENDED_REGISTERS
    },
    else => @compileError("Unsupported architecture"),
};

const status_stack_overflow: u32 = 0xC00000FD;

pub fn Vectored(comptime router: Router) type {
    return struct {
        var handle: std.atomic.Value(?*anyopaque) = .init(null);

        pub fn install(first: bool) !void {
            if (handle.load(.acquire) != null) return;
            const h = win.AddVectoredExceptionHandler(@intFromBool(first), handler) orelse return error.InstallFailed;
            // Lost a race with another install, keep theirs
            if (handle.cmpxchgStrong(null, h, .acq_rel, .acquire) != null) _ = win.RemoveVectoredExceptionHandler(h);
        }

        pub fn uninstall() void {
            const h = handle.swap(null, .acq_rel) orelse return;
            _ = win.RemoveVectoredExceptionHandler(h);
        }

        pub fn installed() bool {
            return handle.load(.acquire) != null;
        }

        fn handler(info: *win.EXCEPTION_POINTERS) callconv(.winapi) c_long {
            return dispatch(info, router);
        }
    };
}

/// So a router's own faults go straight to the program.
threadlocal var dispatching: bool = false;

/// Last chance, for what no handler took. `.pass` hands it to the filter that was there before, or to
/// Windows. Others can set their own over it later, so `setNext` lets a hook keep ours first.
pub fn Unhandled(comptime router: Router) type {
    return struct {
        var next: std.atomic.Value(?*const win.TOP_LEVEL_EXCEPTION_FILTER) = .init(null);
        var installed_: std.atomic.Value(bool) = .init(false);

        pub fn install() void {
            if (installed_.swap(true, .acq_rel)) return;
            next.store(win.SetUnhandledExceptionFilter(filter), .release);
        }

        pub fn uninstall() void {
            if (!installed_.swap(false, .acq_rel)) return;
            _ = win.SetUnhandledExceptionFilter(next.load(.acquire));
        }

        pub fn installed() bool {
            return installed_.load(.acquire);
        }

        /// What `.pass` goes to instead. Gives back the one before. Address 0 is none.
        pub fn setNext(filter_address: usize) usize {
            const f: ?*const win.TOP_LEVEL_EXCEPTION_FILTER = @ptrFromInt(filter_address);
            return @intFromPtr(next.swap(f, .acq_rel));
        }

        /// Ours, so a hook can tell it from someone else's.
        pub fn address() usize {
            return @intFromPtr(&filter);
        }

        fn filter(info: *win.EXCEPTION_POINTERS) callconv(.winapi) c_long {
            if (!dispatching) {
                dispatching = true;
                defer dispatching = false;
                const ctx = info.ContextRecord;
                var exception = read(info.ExceptionRecord, ctx);
                exception.os = info;
                const before = exception.debug;
                if (router(&exception) == .handled) {
                    write(ctx, &exception, before);
                    return win.EXCEPTION_CONTINUE_EXECUTION;
                }
            }
            if (next.load(.acquire)) |f| return f(info);
            return win.EXCEPTION_CONTINUE_SEARCH;
        }
    };
}

/// Loads dbghelp now, since loading it mid-crash could wait on a lock the crash holds.
pub fn prepareMinidumps() bool {
    return minidumpFn() != null;
}

fn minidumpFn() ?*const win.MiniDumpWriteDumpFn {
    return sys.module.lazyFn("dbghelp.dll", "MiniDumpWriteDump", win.MiniDumpWriteDumpFn);
}

/// Of this process, stopped at `exception` on thread `thread_id`. From another thread than that one.
/// It pauses our other threads, so it hangs if one holds a lock it needs. `writeMinidumpOf` from
/// another process can't.
pub fn writeMinidump(path: []const u8, thread_id: u32, exception: ?*const anyopaque) !void {
    return dumpTo(win.GetCurrentProcess(), win.GetCurrentProcessId(), path, thread_id, if (exception) |e| @intFromPtr(e) else 0, false);
}

/// Of process `process_id`, from outside it. `exception` is the address of its `EXCEPTION_POINTERS`,
/// 0 for none. Run it from a process of the same arch, or the exception's read with the wrong layout.
pub fn writeMinidumpOf(process_id: u32, path: []const u8, thread_id: u32, exception: usize) !void {
    const process = win.OpenProcess(win.PROCESS_QUERY_INFORMATION | win.PROCESS_VM_READ, .FALSE, process_id) orelse return error.CantOpenProcess;
    defer win.CloseHandle(process);
    return dumpTo(process, process_id, path, thread_id, exception, true);
}

fn dumpTo(process: win.HANDLE, process_id: u32, path: []const u8, thread_id: u32, exception: usize, client: bool) !void {
    const dump = minidumpFn() orelse return error.Unavailable;
    var wide: [1024:0]u16 = undefined;
    const n = std.unicode.wtf8ToWtf16Le(&wide, path) catch return error.BadPath;
    wide[n] = 0;
    const file = win.CreateFileW(&wide, win.GENERIC_WRITE, 0, null, win.CREATE_ALWAYS, win.FILE_ATTRIBUTE_NORMAL, null);
    if (file == win.INVALID_HANDLE_VALUE) return error.CantOpenFile;
    defer win.CloseHandle(file);
    const info: win.MINIDUMP_EXCEPTION_INFORMATION = .{
        .ThreadId = thread_id,
        .ExceptionPointers = @ptrFromInt(exception),
        .ClientPointers = if (client) .TRUE else .FALSE,
    };
    const kind = win.MiniDumpWithIndirectlyReferencedMemory | win.MiniDumpWithThreadInfo | win.MiniDumpWithUnloadedModules;
    if (dump(process, process_id, file, kind, if (exception != 0) &info else null, null, null) == .FALSE) return error.DumpFailed;
}

/// Runs `command_line` and waits up to `timeout_ms` for its exit code, killing it if it's longer.
/// No allocation, so it's fine mid-crash.
pub fn runAndWait(command_line: []const u8, timeout_ms: u32) !u32 {
    const S = struct {
        var wide: [4096:0]u16 = undefined;
    };
    const n = std.unicode.wtf8ToWtf16Le(&S.wide, command_line) catch return error.CommandTooLong;
    S.wide[n] = 0;
    var startup = std.mem.zeroes(win.STARTUPINFOW);
    startup.cb = @sizeOf(win.STARTUPINFOW);
    var info: win.PROCESS_INFORMATION = undefined;
    if (win.CreateProcessW(null, &S.wide, null, null, .FALSE, win.CREATE_NO_WINDOW, null, null, &startup, &info) == .FALSE) return error.CantStart;
    defer {
        win.CloseHandle(info.hThread);
        win.CloseHandle(info.hProcess);
    }
    if (win.WaitForSingleObject(info.hProcess, timeout_ms) != win.WAIT_OBJECT_0) {
        _ = win.TerminateProcess(info.hProcess, 1);
        return error.TimedOut;
    }
    var code: win.DWORD = 0;
    if (win.GetExitCodeProcess(info.hProcess, &code) == .FALSE) return error.Unknown;
    return code;
}

fn dispatch(info: *win.EXCEPTION_POINTERS, comptime router: Router) c_long {
    const record = info.ExceptionRecord;
    if (dispatching or record.ExceptionCode == status_stack_overflow) return win.EXCEPTION_CONTINUE_SEARCH;
    dispatching = true;
    defer dispatching = false;

    const ctx = info.ContextRecord;
    var exception = read(record, ctx);
    const before = exception.debug;
    if (router(&exception) == .pass) return win.EXCEPTION_CONTINUE_SEARCH;
    write(ctx, &exception, before);
    return win.EXCEPTION_CONTINUE_EXECUTION;
}

fn kindOf(code: u32) Kind {
    return switch (code) {
        0xC0000005 => .access_violation,
        0x80000001 => .guard_page,
        0xC0000006 => .in_page_error,
        0x80000003 => .breakpoint,
        0x80000004 => .single_step,
        0xC000001D => .illegal_instruction,
        0xC0000096 => .privileged_instruction,
        0x80000002 => .misaligned_data,
        0xC0000094 => .int_divide_by_zero,
        0xC0000095 => .int_overflow,
        0xC000008D...0xC0000093, 0xC00002B4, 0xC00002B5 => .float,
        else => .other,
    };
}

fn read(record: *const win.EXCEPTION_RECORD, ctx: *const win.CONTEXT) Exception {
    const kind = kindOf(record.ExceptionCode);
    var e: Exception = .{
        .kind = kind,
        .code = record.ExceptionCode,
        .continuable = record.ExceptionFlags & win.EXCEPTION_NONCONTINUABLE == 0,
        .cpu = std.mem.zeroes(CpuContext),
    };
    switch (kind) {
        .access_violation, .guard_page, .in_page_error => if (record.NumberParameters >= 2) {
            e.fault = .{
                .access = switch (record.ExceptionInformation[0]) {
                    0 => .read,
                    8 => .execute,
                    else => .write,
                },
                .address = record.ExceptionInformation[1],
            };
        },
        else => {},
    }
    if (ctx.ContextFlags & context_flags.debug == context_flags.debug) {
        e.debug = .{
            .address = .{ ctx.Dr0, ctx.Dr1, ctx.Dr2, ctx.Dr3 },
            .status = ctx.Dr6,
            .control = ctx.Dr7,
        };
    }
    const has_xmm = ctx.ContextFlags & context_flags.xmm == context_flags.xmm;
    inline for (registers) |pair| @field(e.cpu, pair[0]) = @field(ctx, pair[1]);
    if (has_xmm) {
        inline for (0..xmm_count) |i| @field(e.cpu, std.fmt.comptimePrint("xmm{d}", .{i})) = xmmAt(ctx, i).*;
    }
    return e;
}

fn write(ctx: *win.CONTEXT, e: *const Exception, before: sys.exceptions.DebugRegisters) void {
    inline for (registers) |pair| @field(ctx, pair[1]) = @intCast(@field(e.cpu, pair[0]));
    if (ctx.ContextFlags & context_flags.xmm == context_flags.xmm) {
        inline for (0..xmm_count) |i| xmmAt(ctx, i).* = @field(e.cpu, std.fmt.comptimePrint("xmm{d}", .{i}));
    }
    // Only when changed. Zeros we made up aren't real
    if (!std.meta.eql(before, e.debug)) {
        ctx.Dr0 = @intCast(e.debug.address[0]);
        ctx.Dr1 = @intCast(e.debug.address[1]);
        ctx.Dr2 = @intCast(e.debug.address[2]);
        ctx.Dr3 = @intCast(e.debug.address[3]);
        ctx.Dr6 = @intCast(e.debug.status);
        ctx.Dr7 = @intCast(e.debug.control);
        ctx.ContextFlags |= context_flags.debug;
    }
}

const registers = switch (builtin.cpu.arch) {
    .x86_64 => .{
        .{ "rax", "Rax" },       .{ "rcx", "Rcx" }, .{ "rdx", "Rdx" }, .{ "rbx", "Rbx" },
        .{ "rsp", "Rsp" },       .{ "rbp", "Rbp" }, .{ "rsi", "Rsi" }, .{ "rdi", "Rdi" },
        .{ "r8", "R8" },         .{ "r9", "R9" },   .{ "r10", "R10" }, .{ "r11", "R11" },
        .{ "r12", "R12" },       .{ "r13", "R13" }, .{ "r14", "R14" }, .{ "r15", "R15" },
        .{ "rflags", "EFlags" }, .{ "rip", "Rip" },
    },
    .x86 => .{
        .{ "eax", "Eax" },       .{ "ecx", "Ecx" }, .{ "edx", "Edx" }, .{ "ebx", "Ebx" },
        .{ "esp", "Esp" },       .{ "ebp", "Ebp" }, .{ "esi", "Esi" }, .{ "edi", "Edi" },
        .{ "eflags", "EFlags" }, .{ "eip", "Eip" },
    },
    else => @compileError("Unsupported architecture"),
};

const xmm_count = if (builtin.cpu.arch == .x86_64) 16 else 8;

/// In the FXSAVE area. On x86 that's `ExtendedRegisters`, 160 in.
fn xmmAt(ctx: anytype, comptime i: usize) switch (@TypeOf(ctx)) {
    *win.CONTEXT => *align(1) arch.XmmReg,
    else => *align(1) const arch.XmmReg,
} {
    return switch (builtin.cpu.arch) {
        .x86_64 => @ptrCast(&ctx.DUMMYUNIONNAME.FltSave.XmmRegisters[i]),
        .x86 => @ptrCast(ctx.ExtendedRegisters[160 + i * 16 ..][0..16]),
        else => unreachable,
    };
}

const tests = struct {
    const testing = std.testing;

    noinline fn breakpointEax() u32 {
        return asm volatile (
            \\.intel_syntax noprefix
            \\xor eax, eax
            \\int3
            \\.att_syntax prefix
            : [ret] "={eax}" (-> u32),
            :
            : .{ .memory = true });
    }

    var seen_value: ?Exception = null;

    /// Handlers set it in the middle of a faulting statement, so it can't be cached across one.
    fn seen() *volatile ?Exception {
        return &seen_value;
    }

    fn setEax(e: *Exception, v: u32) void {
        if (comptime arch.bits == 64) e.cpu.rax = v else e.cpu.eax = v;
    }

    test "breakpoint handled" {
        const V = Vectored(struct {
            fn route(e: *Exception) Action {
                if (e.kind != .breakpoint) return .pass;
                seen().* = e.*;
                e.cpu.setIp(e.cpu.ip() + 1);
                setEax(e, 0x1234);
                return .handled;
            }
        }.route);
        seen().* = null;
        try V.install(true);
        defer V.uninstall();

        try testing.expectEqual(0x1234, breakpointEax());
        const e = seen().*.?;
        try testing.expectEqual(0x80000003, e.code);
        try testing.expect(e.continuable);
        try testing.expectEqual(null, e.fault);
    }

    var page_addr: usize = 0;

    test "access violations" {
        const V = Vectored(struct {
            fn route(e: *Exception) Action {
                const f = e.fault orelse return .pass;
                if (e.kind != .access_violation or f.address -% page_addr >= sys.memory.page_size) return .pass;
                seen().* = e.*;
                _ = sys.memory.protect(page_addr, sys.memory.page_size, .read_write) catch return .pass;
                return .handled;
            }
        }.route);
        const page = try sys.memory.allocAny(sys.memory.page_size);
        defer sys.memory.free(page);
        page_addr = @intFromPtr(page.ptr);
        try V.install(true);
        defer V.uninstall();

        const slot: *volatile u32 = @ptrCast(@alignCast(page.ptr + 8));
        slot.* = 7;

        _ = try sys.memory.protect(page_addr, page.len, .no_access);
        seen().* = null;
        try testing.expectEqual(7, slot.*);
        try testing.expectEqual(sys.exceptions.Fault{ .access = .read, .address = page_addr + 8 }, seen().*.?.fault.?);

        _ = try sys.memory.protect(page_addr, page.len, .read);
        seen().* = null;
        slot.* = 9;
        try testing.expectEqual(sys.exceptions.Fault{ .access = .write, .address = page_addr + 8 }, seen().*.?.fault.?);
        try testing.expectEqual(9, slot.*);
    }

    var watched: u32 = 0;
    var watch_hits: u32 = 0;

    test "hardware write breakpoint" {
        const V = Vectored(struct {
            fn route(e: *Exception) Action {
                switch (e.kind) {
                    .breakpoint => {
                        e.cpu.setIp(e.cpu.ip() + 1);
                        e.debug.address[0] = @intFromPtr(&watched);
                        // L0 on, RW0 = write, LEN0 = 4 bytes
                        e.debug.control = 1 | (0b01 << 16) | (0b11 << 18);
                        return .handled;
                    },
                    .single_step => {
                        if (e.debug.status & 1 == 0) return .pass;
                        watch_hits += 1;
                        e.debug.control = 0;
                        e.debug.status = 0;
                        return .handled;
                    },
                    else => return .pass,
                }
            }
        }.route);
        watch_hits = 0;
        try V.install(true);
        defer V.uninstall();

        _ = breakpointEax();
        @as(*volatile u32, &watched).* = 5;
        try testing.expectEqual(1, watch_hits);
        // Disarmed by the hit
        @as(*volatile u32, &watched).* = 6;
        try testing.expectEqual(1, watch_hits);
    }

    var stepping = false;

    var shared: u32 align(8) = 0;
    var shared_hits: std.atomic.Value(u32) = .init(0);

    test "debug registers on every thread" {
        const V = Vectored(struct {
            fn route(e: *Exception) Action {
                if (e.kind != .single_step or e.debug.status & 1 == 0 or e.debug.address[0] != @intFromPtr(&shared)) return .pass;
                _ = shared_hits.fetchAdd(1, .monotonic);
                e.debug.status = 0;
                return .handled;
            }
        }.route);
        shared_hits.store(0, .monotonic);
        try V.install(true);
        defer V.uninstall();

        // L0 on, RW0 = write, LEN0 = 4 bytes
        const control: usize = 1 | (0b01 << 16) | (0b11 << 18);
        try testing.expect(try sys.thread.setDebugRegisters(.{ @intFromPtr(&shared), 0, 0, 0 }, control) >= 1);
        // Already set everywhere
        try testing.expectEqual(0, try sys.thread.setDebugRegisters(.{ @intFromPtr(&shared), 0, 0, 0 }, control));

        @as(*volatile u32, &shared).* = 1;
        try testing.expectEqual(1, shared_hits.load(.monotonic));

        // Started after, so it needs another call
        const Writer = struct {
            running: std.atomic.Value(bool) = .init(false),
            go: std.atomic.Value(bool) = .init(false),
            fn run(self: *@This()) void {
                self.running.store(true, .release);
                while (!self.go.load(.acquire)) win.Sleep(1);
                @as(*volatile u32, &shared).* = 2;
            }
        };
        var writer: Writer = .{};
        const thread = try std.Thread.spawn(.{}, Writer.run, .{&writer});
        // A thread that hasn't started yet gets its first context put back over ours
        while (!writer.running.load(.acquire)) win.Sleep(1);
        try testing.expect(try sys.thread.setDebugRegisters(.{ @intFromPtr(&shared), 0, 0, 0 }, control) >= 1);
        writer.go.store(true, .release);
        thread.join();
        try testing.expectEqual(2, shared_hits.load(.monotonic));

        _ = try sys.thread.setDebugRegisters(@splat(0), 0);
        @as(*volatile u32, &shared).* = 3;
        try testing.expectEqual(2, shared_hits.load(.monotonic));
    }

    test "trap flag single step" {
        const V = Vectored(struct {
            fn route(e: *Exception) Action {
                switch (e.kind) {
                    .breakpoint => {
                        e.cpu.setIp(e.cpu.ip() + 1);
                        e.setSingleStep(true);
                        stepping = true;
                        return .handled;
                    },
                    .single_step => {
                        if (!stepping) return .pass;
                        stepping = false;
                        seen().* = e.*;
                        e.setSingleStep(false);
                        return .handled;
                    },
                    else => return .pass,
                }
            }
        }.route);
        seen().* = null;
        try V.install(true);
        defer V.uninstall();

        _ = breakpointEax();
        try testing.expectEqual(Kind.single_step, seen().*.?.kind);
    }

    var last_chance: ?Exception = null;
    var dump_path: []const u8 = "";
    var dumped: ?anyerror!void = null;

    test "unhandled breakpoint reaches the last-chance filter" {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
        defer testing.allocator.free(root);
        dump_path = try std.fs.path.join(testing.allocator, &.{ root, "crash.dmp" });
        defer testing.allocator.free(dump_path);
        try testing.expect(prepareMinidumps());

        const U = Unhandled(struct {
            fn route(e: *Exception) Action {
                if (e.kind != .breakpoint) return .pass;
                last_chance = e.*;
                // With the exception, which is what a crash dump needs
                dumped = writeMinidump(dump_path, win.GetCurrentThreadId(), e.os);
                e.cpu.setIp(e.cpu.ip() + 1);
                setEax(e, 0x5678);
                return .handled;
            }
        }.route);
        last_chance = null;
        U.install();
        defer U.uninstall();
        try testing.expect(U.installed());
        // Nothing before it takes an int3, so it's left to the last-chance filter
        try testing.expectEqual(0x5678, breakpointEax());
        try testing.expect(last_chance.?.os != null);
        try dumped.?;
        try testing.expect((try tmp.dir.statFile(testing.io, "crash.dmp", .{})).size > 1024);

        // Passing hands it on to whatever's next
        const Next = struct {
            var calls: u32 = 0;
            fn filter(info: *win.EXCEPTION_POINTERS) callconv(.winapi) c_long {
                calls += 1;
                if (comptime arch.bits == 64) info.ContextRecord.Rip += 1 else info.ContextRecord.Eip += 1;
                return win.EXCEPTION_CONTINUE_EXECUTION;
            }
        };
        const PassAll = Unhandled(struct {
            fn route(_: *Exception) Action {
                return .pass;
            }
        }.route);
        PassAll.install();
        defer PassAll.uninstall();
        const before = PassAll.setNext(@intFromPtr(&Next.filter));
        defer _ = PassAll.setNext(before);
        _ = breakpointEax();
        try testing.expectEqual(1, Next.calls);
    }

    test "minidump of this process" {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
        defer testing.allocator.free(root);
        const path = try std.fs.path.join(testing.allocator, &.{ root, "test.dmp" });
        defer testing.allocator.free(path);
        try testing.expect(prepareMinidumps());
        try writeMinidump(path, win.GetCurrentThreadId(), null);
        const stat = try tmp.dir.statFile(testing.io, "test.dmp", .{});
        try testing.expect(stat.size > 1024);
    }

    test "repeat install and uninstall" {
        const V = Vectored(struct {
            fn route(_: *Exception) Action {
                return .handled;
            }
        }.route);
        try V.install(false);
        try V.install(false);
        try testing.expect(V.installed());
        V.uninstall();
        V.uninstall();
        try testing.expect(!V.installed());
    }
};

test {
    _ = tests;
}
