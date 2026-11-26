//! Bytes written over code, put back when disabled.

const Patch = @This();

const std = @import("std");
const builtin = @import("builtin");
const arch = @import("tuft_arch");
const sys = @import("tuft_sys");
const memory = @import("tuft_mem");
const Claims = memory.Claims;
const Owner = @import("tuft_event").Owner;
const registry = @import("registry.zig");
const Hook = @import("Hook.zig");
const tuft_asm = @import("tuft_asm");

const log = std.log.scoped(.tuft_hook);

pub const max_len = 4096;

id: u64 = registry.INVALID_HOOK_ID,
address: usize,
bytes: []u8,
original: []u8,
enabled: bool = false,
owner: ?*const Owner = null,

pub const Options = struct {
    /// A signature like `89 83 ?? ??` the bytes there have to match.
    expect: ?[]const u8 = null,
    /// NOPs out the rest of an instruction the bytes end inside of.
    pad: bool = false,
    /// Names `expect`'s asm can use.
    resolver: ?tuft_asm.Resolver = null,
};

/// Starts disabled.
pub fn create(address: usize, given: []const u8, options: Options) !*Patch {
    if (given.len == 0) return error.Empty;
    if (given.len > max_len) return error.TooLong;
    const len = if (options.pad) try instructionEnd(address, given.len) else given.len;
    if (len > max_len) return error.TooLong;
    if (!memory.isReadable(address, len)) return error.Unreadable;
    const there: [*]const u8 = @ptrFromInt(address);
    try checkExpect(address, options.expect, options.resolver);

    const gpa = registry.allocator();
    const self = try gpa.create(Patch);
    errdefer gpa.destroy(self);
    const copies = try gpa.alloc(u8, len * 2);
    errdefer gpa.free(copies);
    @memcpy(copies[0..given.len], given);
    @memset(copies[given.len..len], 0x90);
    @memcpy(copies[len..], there[0..len]);
    self.* = .{ .address = address, .bytes = copies[0..len], .original = copies[len..] };
    try registry.registerPatch(self);
    return self;
}

/// Where the instruction at or after `address + len` starts.
pub fn instructionEnd(address: usize, len: usize) !usize {
    var at: usize = 0;
    while (at < len) {
        const d = arch.insn.decode(address + at) catch return error.DisassemblyFailed;
        at += d.len;
    }
    return at;
}

/// `error.UnexpectedBytes` if the code at `address` isn't `expect`, see `ExpectOptions`.
pub fn checkExpect(address: usize, expect: ?[]const u8, resolver: ?tuft_asm.Resolver) !void {
    const text = expect orelse return;
    if (text.len == 0) return;
    _ = try expected(address, text, .{ .resolver = resolver });
}

/// What went wrong with an `expect`, for people.
pub const ExpectProblem = struct {
    /// Its asm didn't match.
    mismatch: tuft_asm.Mismatch = .{},
    /// Its asm didn't make sense.
    diagnostic: tuft_asm.Diagnostic = .{},
};

pub const ExpectOptions = struct {
    problem: ?*ExpectProblem = null,
    /// Names its asm can use. Modules without it.
    resolver: ?tuft_asm.Resolver = null,
};

/// Bytes covered by a pattern like `89 83 ?? ??`, or asm like `cmp ecx, eax` matched in any encoding.
pub fn expected(address: usize, text: []const u8, options: ExpectOptions) !usize {
    if (isPattern(text)) {
        var buf: [max_len]?u8 = undefined;
        const pattern = memory.pattern.parseInto(text, &buf) catch return error.InvalidPattern;
        if (!memory.isReadable(address, pattern.len)) return error.Unreadable;
        const there: [*]const u8 = @ptrFromInt(address);
        if (!memory.pattern.matches(there[0..pattern.len], pattern)) return error.UnexpectedBytes;
        return pattern.len;
    }
    var scratch: ExpectProblem = .{};
    const problem = options.problem orelse &scratch;
    // Enough for a few instructions, without reading past what's there
    var len: usize = 64;
    while (len > 0 and !memory.isReadable(address, len)) len /= 2;
    if (len == 0) return error.Unreadable;
    const there: [*]const u8 = @ptrFromInt(address);
    const symbols: tuft_asm.Resolver = options.resolver orelse .{ .resolve = struct {
        fn resolve(_: ?*anyopaque, name: []const u8) ?usize {
            return memory.Symbols.local.resolve(name);
        }
    }.resolve };
    const matched = tuft_asm.expectAt(registry.allocator(), text, there[0..len], address, symbols, &problem.diagnostic, &problem.mismatch) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidExpect,
    };
    return matched orelse error.UnexpectedBytes;
}

/// Only two-digit hex bytes and `?` or `??`.
fn isPattern(text: []const u8) bool {
    var any = false;
    var tokens = std.mem.tokenizeAny(u8, text, " \t");
    while (tokens.next()) |t| {
        any = true;
        if (std.mem.eql(u8, t, "?") or std.mem.eql(u8, t, "??")) continue;
        if (t.len != 2 or !std.ascii.isHex(t[0]) or !std.ascii.isHex(t[1])) return false;
    }
    return any;
}

pub const ReplaceOptions = struct {
    /// Bytes to replace, ending between instructions. 0 means what `expect` covers, or one instruction.
    size: usize = 0,
    /// A byte pattern or asm the code there has to be, see `expected`.
    expect: ?[]const u8 = null,
    problem: ?*ExpectProblem = null,
    /// Names `expect`'s asm can use.
    resolver: ?tuft_asm.Resolver = null,
    /// Data placed before that the code reads. If it can't go in place, it goes in reach of it.
    reach: []const usize = &.{},
};

pub const Replacement = union(enum) {
    /// The code fit in place.
    patch: *Patch,
    /// It didn't, so it's in a cave.
    hook: *Hook,
};

/// Replaces code at `address` with what `code` builds, in place if it fits, else in a cave. Starts disabled.
/// `code` is tried in place first with no `original`, returning `error.NeedsCave` or `error.TooLong` to move.
pub fn replace(address: usize, code: Hook.InjectBuild, options: ReplaceOptions) !Replacement {
    const size = try replaceSize(address, options);
    var buf: [max_len]u8 = undefined;
    if (size <= max_len) {
        const site: Hook.InjectSite = .{ .code = address, .original = null, .resume_at = address + size };
        if (code.build(code.context, site, buf[0..size])) |len| {
            @memset(buf[len..size], 0x90);
            return .{ .patch = try create(address, buf[0..size], .{}) };
        } else |err| switch (err) {
            error.NeedsCave, error.TooLong => {},
            else => return err,
        }
    }
    if (size > arch.relocate.max_stolen_bytes) return error.TooLong;
    return .{ .hook = try Hook.createInjectRaw(address, code, .{ .replace = @intCast(size), .reach = options.reach }) };
}

/// What `options` says to replace, after checking `expect`, and that it ends between instructions.
pub fn replaceSize(address: usize, options: ReplaceOptions) !usize {
    var size = options.size;
    if (options.expect) |text| if (text.len > 0) {
        const covered = try expected(address, text, .{ .problem = options.problem, .resolver = options.resolver });
        if (size == 0) size = covered;
    };
    if (size == 0) size = (arch.insn.decode(address) catch return error.DisassemblyFailed).len;
    if (try instructionEnd(address, size) != size) return error.SplitsInstruction;
    return size;
}

/// `error.TargetModified` if something else changed the bytes since it was made.
pub fn enable(self: *Patch) !void {
    if (self.enabled) return;
    {
        // Before freezing, since some games hook page protection with a lock of their own
        const unlocked = try memory.unlockCode(self.address, self.bytes.len);
        defer unlocked.lock();
        var guard = try self.freezeThreads();
        defer guard.deinit();
        if (!std.mem.eql(u8, self.current(), self.original)) return error.TargetModified;
        unlocked.write(self.address, self.bytes);
        self.enabled = true;
    }
}

/// Leaves the bytes alone if something else wrote over them.
pub fn disable(self: *Patch) !void {
    if (!self.enabled) return;
    {
        const unlocked = try memory.unlockCode(self.address, self.original.len);
        defer unlocked.lock();
        var guard = try self.freezeThreads();
        defer guard.deinit();
        if (!std.mem.eql(u8, self.current(), self.bytes)) {
            self.enabled = false;
            return error.TargetModified;
        }
        unlocked.write(self.address, self.original);
        self.enabled = false;
    }
}

pub fn destroy(self: *Patch) void {
    self.disable() catch |err| log.warn("Couldn't put back the patch at 0x{x}: {t}", .{ self.address, err });
    registry.unregisterPatch(self);
    const gpa = registry.allocator();
    gpa.free(self.bytes.ptr[0 .. self.bytes.len * 2]);
    gpa.destroy(self);
}

/// The owner has to outlive the patch.
pub fn setOwner(self: *Patch, owner: ?*const Owner) void {
    self.owner = owner;
    if (self.id != registry.INVALID_HOOK_ID) Claims.setOwner(.patch, self.id, owner);
}

pub fn range(self: *const Patch) sys.thread.CodeRange {
    return .{ .start = self.address, .len = self.bytes.len };
}

fn current(self: *const Patch) []const u8 {
    const p: [*]const u8 = @ptrFromInt(self.address);
    return p[0..self.bytes.len];
}

fn freezeThreads(self: *const Patch) !sys.thread.ThreadFreezeGuard {
    return sys.thread.freezeThreads(registry.allocator(), .{ .executing = &.{self.range()} });
}

const tests = struct {
    const testing = std.testing;

    noinline fn seven() callconv(.c) u32 {
        var x: u32 = 7;
        asm volatile (""
            : [x] "+r" (x),
        );
        return x;
    }

    // mov eax, 42 then ret
    const forty_two = [_]u8{ 0xB8, 0x2A, 0x00, 0x00, 0x00, 0xC3 };

    test "patch and restore" {
        try registry.init(testing.allocator);
        defer registry.deinit();
        const p = try create(@intFromPtr(&seven), &forty_two, .{});
        defer p.destroy();
        try testing.expectEqual(7, seven());
        try p.enable();
        try testing.expectEqual(42, seven());
        try p.disable();
        try testing.expectEqual(7, seven());
    }

    test "pads to an instruction" {
        try registry.init(testing.allocator);
        defer registry.deinit();
        const at = @intFromPtr(&seven);
        const first = try instructionEnd(at, 2);
        const p = try create(at, &.{ 0x90, 0x90 }, .{ .pad = true });
        defer p.destroy();
        try testing.expectEqual(first, p.bytes.len);
        for (p.bytes) |b| try testing.expectEqual(0x90, b);
    }

    test "expect and overlaps" {
        try registry.init(testing.allocator);
        defer registry.deinit();
        const at = @intFromPtr(&seven);
        try testing.expectError(error.UnexpectedBytes, create(at, &forty_two, .{ .expect = "C3 C3 C3" }));
        var first: [2]u8 = undefined;
        @memcpy(&first, @as([*]const u8, @ptrFromInt(at))[0..2]);
        var buf: [8]u8 = undefined;
        const p = try create(at, &forty_two, .{ .expect = try std.fmt.bufPrint(&buf, "{X:0>2} ??", .{first[0]}) });
        defer p.destroy();
        try testing.expectError(error.AlreadyHooked, create(at + 1, &.{0x90}, .{}));
        try testing.expectError(error.AlreadyHooked, Hook.createMidRaw(at, &noop, 0, .{}));
    }

    fn noop(_: *Hook, _: *Hook.CpuContext) callconv(.c) void {}

    // a + b + 100 + 3, as 2, 2, 3, 3, 3 and 3 byte instructions
    comptime {
        if (builtin.cpu.arch == .x86_64) asm (
            \\.text
            \\.globl tuft_replace_target
            \\tuft_replace_target:
            \\  movl %ecx, %eax
            \\  addl %edx, %eax
            \\  addl $100, %eax
            \\  addl $1, %eax
            \\  addl $1, %eax
            \\  addl $1, %eax
            \\  retq
        );
    }
    extern fn tuft_replace_target(a: u32, b: u32) callconv(.c) u32;

    const Code = struct {
        bytes: []const u8,
        /// Built in place, asks for a cave.
        cave: bool = false,

        fn build(context: ?*anyopaque, site: Hook.InjectSite, out: []u8) anyerror!usize {
            const self: *const Code = @ptrCast(@alignCast(context.?));
            if (self.cave and site.original == null) return error.NeedsCave;
            if (self.bytes.len > out.len) return error.TooLong;
            @memcpy(out[0..self.bytes.len], self.bytes);
            return self.bytes.len;
        }

        fn of(self: *Code) Hook.InjectBuild {
            return .{ .context = self, .build = build };
        }
    };

    fn expectReplaced(r: Replacement, kind: std.meta.Tag(Replacement), want: u32) !void {
        defer switch (r) {
            .patch => |p| p.destroy(),
            .hook => |h| h.destroy(),
        };
        try testing.expectEqual(kind, std.meta.activeTag(r));
        switch (r) {
            .patch => |p| try p.enable(),
            .hook => |h| try h.enable(),
        }
        try testing.expectEqual(want, tuft_replace_target(1, 10));
    }

    test "replace in place, in a cave, and only whole instructions" {
        if (builtin.cpu.arch != .x86_64) return error.SkipZigTest;
        try registry.init(testing.allocator);
        defer registry.deinit();
        const at = @intFromPtr(&tuft_replace_target);
        try testing.expectEqual(114, tuft_replace_target(1, 10));

        // mov eax, edx fits over mov eax, ecx
        var fits: Code = .{ .bytes = &.{ 0x89, 0xD0 } };
        try expectReplaced(try replace(at, fits.of(), .{}), .patch, 123);
        // mov eax, edx and add eax, edx don't, so the add after still runs from the cave
        var longer: Code = .{ .bytes = &.{ 0x89, 0xD0, 0x01, 0xD0 } };
        try expectReplaced(try replace(at, longer.of(), .{ .expect = "89 C8" }), .hook, 133);
        // Both of the first two, by size
        var both: Code = .{ .bytes = &.{ 0x31, 0xC0 } };
        try expectReplaced(try replace(at, both.of(), .{ .size = 4 }), .patch, 103);
        var cave: Code = .{ .bytes = &.{ 0x31, 0xC0 }, .cave = true };
        try expectReplaced(try replace(at, cave.of(), .{ .size = 4 }), .hook, 103);
        try testing.expectEqual(114, tuft_replace_target(1, 10));

        try testing.expectError(error.SplitsInstruction, replace(at, fits.of(), .{ .size = 3 }));
        try testing.expectError(error.SplitsInstruction, replace(at, fits.of(), .{ .expect = "89 C8 01" }));
        try testing.expectError(error.UnexpectedBytes, replace(at, fits.of(), .{ .expect = "90 90" }));
    }

    /// `mov eax, [rip+data]`, if it reaches from there.
    const ReadData = struct {
        data: usize,

        fn build(context: ?*anyopaque, site: Hook.InjectSite, out: []u8) anyerror!usize {
            const self: *const ReadData = @ptrCast(@alignCast(context.?));
            const rel = std.math.cast(i32, @as(isize, @bitCast(self.data -% (site.code + 6)))) orelse
                return if (site.original == null) error.NeedsCave else error.OutOfReach;
            if (out.len < 6) return error.TooLong;
            out[0..2].* = .{ 0x8B, 0x05 };
            std.mem.writeInt(i32, out[2..6], rel, .little);
            return 6;
        }

        fn of(self: *ReadData) Hook.InjectBuild {
            return .{ .context = self, .build = build };
        }
    };

    fn placeData(at: usize, value: u32) !memory.Placement {
        var data = try memory.Placement.place(.{ .target = at, .data = 4 });
        std.mem.writeInt(u32, data.data[0..4], value, .little);
        return data;
    }

    test "code reads data placed first, in every tier" {
        if (builtin.cpu.arch != .x86_64) return error.SkipZigTest;
        try registry.init(testing.allocator);
        defer registry.deinit();
        defer memory.Placement.tiers = .full;
        const at = @intFromPtr(&tuft_replace_target);
        for (std.enums.values(memory.Placement.Tier)) |tier| {
            memory.Placement.tiers = .initOne(tier);
            // The test exe might have no padding to spare
            const no_room = error.OutOfReach;
            var data = placeData(at, 40) catch |err| if (tier == .cave and err == no_room) continue else return err;
            defer data.free();
            var read: ReadData = .{ .data = @intFromPtr(data.data.ptr) };
            const h = Hook.createInjectRaw(at, read.of(), .{ .replace = 4, .reach = &.{read.data} }) catch |err|
                if (tier == .cave and err == no_room) continue else return err;
            defer h.destroy();
            try testing.expectEqual(tier, h.place.tier);
            try h.enable();
            // 40, then the + 100 and three + 1s after it
            try testing.expectEqual(143, tuft_replace_target(1, 10));
        }
    }

    test "a patch goes in place, or out beside data it can't reach" {
        if (builtin.cpu.arch != .x86_64) return error.SkipZigTest;
        try registry.init(testing.allocator);
        defer registry.deinit();
        defer memory.Placement.tiers = .full;
        const at = @intFromPtr(&tuft_replace_target);

        memory.Placement.tiers = .initOne(.near);
        {
            var data = try placeData(at, 40);
            defer data.free();
            var read: ReadData = .{ .data = @intFromPtr(data.data.ptr) };
            try expectReplaced(try replace(at, read.of(), .{ .size = 10, .reach = &.{read.data} }), .patch, 42);
        }

        memory.Placement.tiers = .initMany(&.{ .far, .anywhere });
        var data = try placeData(at, 40);
        defer data.free();
        var read: ReadData = .{ .data = @intFromPtr(data.data.ptr) };
        if (std.math.cast(i32, @as(isize, @bitCast(read.data -% at))) != null) return error.SkipZigTest;
        try expectReplaced(try replace(at, read.of(), .{ .size = 10, .reach = &.{read.data} }), .hook, 42);
    }

    test "expect takes asm, and covers what it matched" {
        if (builtin.cpu.arch != .x86_64) return error.SkipZigTest;
        try registry.init(testing.allocator);
        defer registry.deinit();
        const at = @intFromPtr(&tuft_replace_target);

        var zero: Code = .{ .bytes = &.{ 0x31, 0xC0 } };
        try expectReplaced(try replace(at, zero.of(), .{ .expect = "mov eax, ecx; add eax, edx" }), .patch, 103);

        var problem: ExpectProblem = .{};
        try testing.expectError(error.UnexpectedBytes, replace(at, zero.of(), .{ .expect = "mov eax, ecx; sub eax, edx", .problem = &problem }));
        try testing.expectEqual(1, problem.mismatch.index);
        try testing.expect(std.mem.indexOf(u8, problem.mismatch.found(), "add") != null);
        try testing.expectError(error.InvalidExpect, replace(at, zero.of(), .{ .expect = "mov eax,", .problem = &problem }));
        try testing.expect(problem.diagnostic.message().len > 0);
    }

    test "inject runs the original after, unless it replaces" {
        if (builtin.cpu.arch != .x86_64) return error.SkipZigTest;
        try registry.init(testing.allocator);
        defer registry.deinit();
        const at = @intFromPtr(&tuft_replace_target);
        // add ecx, 5 before the first instruction
        var before: Code = .{ .bytes = &.{ 0x83, 0xC1, 0x05 } };
        const h = try Hook.createInjectRaw(at, before.of(), .{});
        try h.enable();
        try testing.expectEqual(119, tuft_replace_target(1, 10));
        h.destroy();
        try testing.expectEqual(114, tuft_replace_target(1, 10));
    }

    const Mid = struct {
        /// Runs the original instead, from its copy.
        var run_original = false;

        fn edx(hook: *Hook, cpu: *Hook.CpuContext) callconv(.c) void {
            if (run_original) return cpu.setIp(hook.trampoline_addr);
            cpu.rax = cpu.rdx;
        }

        fn addToEcx(_: *Hook, cpu: *Hook.CpuContext) callconv(.c) void {
            cpu.rcx +%= 5;
        }
    };

    test "a mid hook replaces code, or goes before it" {
        if (builtin.cpu.arch != .x86_64) return error.SkipZigTest;
        try registry.init(testing.allocator);
        defer registry.deinit();
        const at = @intFromPtr(&tuft_replace_target);

        // In place of mov eax, ecx, carrying on after it from the copy
        Mid.run_original = false;
        const replacing = try Hook.createMidRaw(at, &Mid.edx, 0, .{ .replace = 2 });
        try replacing.enable();
        try testing.expectEqual(123, tuft_replace_target(1, 10));
        Mid.run_original = true;
        try testing.expectEqual(114, tuft_replace_target(1, 10));
        replacing.destroy();
        try testing.expectError(error.SplitsInstruction, Hook.createMidRaw(at, &Mid.edx, 0, .{ .replace = 3 }));

        const before = try Hook.createMidRaw(at, &Mid.addToEcx, 0, .{});
        try before.enable();
        try testing.expectEqual(119, tuft_replace_target(1, 10));
        before.destroy();
        try testing.expectEqual(114, tuft_replace_target(1, 10));
    }
};

test {
    _ = tests;
}
