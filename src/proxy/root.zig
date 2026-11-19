//! Proxy DLLs, named like a Windows DLL in the game folder and forwarding to the real one.

const std = @import("std");
const builtin = @import("builtin");

const sys = @import("tuft_sys");
const hook = @import("tuft_hook");
const win = sys.win;

/// None are known DLLs or graphics DLLs, which ReShade and friends use.
pub const Dll = enum {
    version,
    winmm,
    dinput8,
    dsound,
    winhttp,

    pub fn fileName(comptime self: Dll) []const u8 {
        return @tagName(self) ++ ".dll";
    }

    /// winhttp's ordinals move between builds, but nobody imports it by ordinal.
    pub fn fixedOrdinals(self: Dll) bool {
        return self != .winhttp;
    }

    /// Relative to this folder.
    pub fn defPath(self: Dll, arch: std.Target.Cpu.Arch) []const u8 {
        return switch (arch) {
            .x86 => switch (self) {
                inline else => |d| "x86/" ++ @tagName(d) ++ ".def",
            },
            else => switch (self) {
                inline else => |d| "x64/" ++ @tagName(d) ++ ".def",
            },
        };
    }
};

pub const Export = struct {
    /// Ordinal-only exports get `tuft_proxy_ordinal_N`.
    name: [:0]const u8,
    ordinal: u16,
    noname: bool,
};

/// From the `.def` for the target arch.
pub fn exportsOf(comptime dll: Dll) []const Export {
    return comptime parseDef(@embedFile(dll.defPath(builtin.cpu.arch)));
}

fn parseDef(comptime def: []const u8) []const Export {
    @setEvalBranchQuota(100_000);
    var list: []const Export = &.{};
    var lines = std.mem.tokenizeAny(u8, def, "\r\n");
    while (lines.next()) |line| {
        var words = std.mem.tokenizeAny(u8, line, " \t");
        const name = words.next() orelse continue;
        if (name[0] == ';' or std.mem.eql(u8, name, "EXPORTS")) continue;
        const at = words.next() orelse @compileError("no ordinal for " ++ name);
        if (at[0] != '@') @compileError("no ordinal for " ++ name);
        const ordinal = std.fmt.parseInt(u16, at[1..], 10) catch @compileError("bad ordinal for " ++ name);
        const noname = if (words.next()) |flag| std.mem.eql(u8, flag, "NONAME") else false;
        list = list ++ [_]Export{.{ .name = std.fmt.comptimePrint("{s}", .{name}), .ordinal = ordinal, .noname = noname }};
    }
    return list;
}

/// Exports everything Windows' `dll` does and forwards once `load` runs.
pub fn Forwarder(comptime dll: Dll) type {
    const exports = exportsOf(dll);
    return struct {
        var slots: [exports.len]usize = @splat(0);
        var ready: bool = false;

        comptime {
            for (exports, 0..) |e, i| @export(&Stub(i).entry, .{ .name = e.name });
        }

        fn Stub(comptime i: usize) type {
            return struct {
                // Args stay as the caller set them. `void`, as what it jumps to returns to the caller
                fn entry() callconv(.naked) void {
                    switch (builtin.cpu.arch) {
                        // r11 and eax are scratch on entry, not argument registers
                        .x86_64 => asm volatile (
                            \\.intel_syntax noprefix
                            \\jmp qword ptr [%[slot:V]]
                            \\.att_syntax prefix
                            :
                            : [slot] "{r11}" (&slots[i]),
                        ),
                        .x86 => asm volatile (
                            \\.intel_syntax noprefix
                            \\jmp dword ptr [%[slot:V]]
                            \\.att_syntax prefix
                            :
                            : [slot] "{eax}" (&slots[i]),
                        ),
                        else => @compileError("tuft supports x86 and x64 only"),
                    }
                }
            };
        }

        /// Call from `DllMain`. Exports this Windows lacks trap if called.
        pub fn load() error{ LoadFailed, PathTooLong }!void {
            const base = try sys.module.systemBase(dll.fileName());
            for (exports, &slots) |e, *slot| {
                const found = if (e.noname)
                    win.GetProcAddress(@ptrFromInt(base), @ptrFromInt(e.ordinal))
                else
                    win.GetProcAddress(@ptrFromInt(base), e.name.ptr);
                slot.* = if (found) |f| @intFromPtr(f) else @intFromPtr(&unavailable);
            }
            ready = true;
        }

        pub fn loaded() bool {
            return ready;
        }
    };
}

fn unavailable() callconv(.naked) noreturn {
    asm volatile ("ud2");
}
/// Holds the main thread at the EXE's entry point so a mod can finish loading first.
pub const EntryGate = struct {
    var event: ?win.HANDLE = null;
    var timeout_ms: u32 = 0;
    var timed_out: std.atomic.Value(bool) = .init(false);

    /// `error.NoEntryPoint` if the EXE has none.
    pub fn hold(wait_ms: u32) !void {
        const entry = (try sys.module.entryPoint(sys.module.mainBase())) orelse return error.NoEntryPoint;
        event = win.CreateEventW(null, .TRUE, .FALSE, null) orelse return error.CreateEventFailed;
        timeout_ms = wait_ms;
        try hook.init(std.heap.page_allocator);
        // Mid hook keeps every register whatever the calling convention
        const h = try hook.Hook.createMid(entry, wait, {});
        try h.enable();
    }

    /// Any thread can call it.
    pub fn open() void {
        if (event) |e| _ = win.SetEvent(e);
    }

    /// True if `hold`'s wait ran out.
    pub fn timedOut() bool {
        return timed_out.load(.acquire);
    }

    fn wait() void {
        const e = event orelse return;
        if (win.WaitForSingleObject(e, timeout_ms) == win.WAIT_TIMEOUT) timed_out.store(true, .release);
    }
};

/// Starts once the loader lock is released, with no activation context.
/// `std.Thread.spawn` fails with `INVALID_PARAMETER` while the loader's is active.
pub fn startThread(comptime func: fn () void) error{CreateThreadFailed}!void {
    const Thunk = struct {
        fn run(_: ?*anyopaque) callconv(.winapi) win.DWORD {
            var cookie: usize = 0;
            const switched = win.ActivateActCtx(null, &cookie).toBool();
            defer if (switched) {
                _ = win.DeactivateActCtx(0, cookie);
            };
            func();
            return 0;
        }
    };
    const thread = win.CreateThread(null, 0, Thunk.run, null, 0, null) orelse return error.CreateThreadFailed;
    win.CloseHandle(thread);
}

const tests = struct {
    const testing = std.testing;

    const Version = Forwarder(.version);

    test "entry gate" {
        // This test's entry point already ran, so nothing waits
        try EntryGate.hold(1000);
        defer hook.deinit();
        EntryGate.open();
        try testing.expect(!EntryGate.timedOut());
    }

    test "forwarder reaches Windows" {
        try Version.load();
        try testing.expect(Version.loaded());

        // Call through our stub like a game would
        const index = comptime for (exportsOf(.version), 0..) |e, i| {
            if (std.mem.eql(u8, e.name, "GetFileVersionInfoSizeW")) break i;
        } else unreachable;
        const GetSizeFn = fn (path: [*:0]const u16, handle: ?*u32) callconv(.winapi) u32;
        // Loaded at runtime so the optimizer can't tell it's the `noreturn` stub
        var stub: *const GetSizeFn = @ptrCast(&Version.Stub(index).entry);
        const get_size = @as(*volatile *const GetSizeFn, &stub).*;

        var buf: [win.MAX_PATH]u8 = undefined;
        const kernel32 = sys.module.pathOf(sys.module.findBase("kernel32.dll").?, &buf).?;
        var wide: [win.MAX_PATH:0]u16 = undefined;
        const n = try std.unicode.utf8ToUtf16Le(&wide, kernel32);
        wide[n] = 0;

        const real = sys.module.lazyFn("version.dll", "GetFileVersionInfoSizeW", GetSizeFn).?;
        try testing.expect(get_size(&wide, null) != 0);
        try testing.expectEqual(real(&wide, null), get_size(&wide, null));
    }

    test "export lists match Windows" {
        var wrong: usize = 0;
        inline for (comptime std.enums.values(Dll)) |dll| {
            const base = try sys.module.systemBase(dll.fileName());
            const exports = exportsOf(dll);
            try testing.expect(exports.len > 0);
            for (exports) |e| {
                if (e.noname or !dll.fixedOrdinals()) continue;
                // Missing is fine, but anything present must keep its ordinal
                const by_name = win.GetProcAddress(@ptrFromInt(base), e.name.ptr) orelse continue;
                if (win.GetProcAddress(@ptrFromInt(base), @ptrFromInt(e.ordinal)) != by_name) {
                    std.debug.print("{s}: {s} isn't @{d} on this Windows\n", .{ dll.fileName(), e.name, e.ordinal });
                    wrong += 1;
                }
            }
        }
        try testing.expectEqual(0, wrong);
    }
};

test {
    _ = tests;
}
