const Hook = @This();

const std = @import("std");
const arch = @import("tuft_arch");
const sys = @import("tuft_sys");
const memory = @import("tuft_mem");
const Address = @import("tuft_mem").Address;
const Placement = @import("tuft_mem").Placement;
const Claims = @import("tuft_mem").Claims;
const Owner = @import("tuft_event").Owner;
const meta = @import("tuft_arch").meta;
const thunk = @import("thunk.zig");
const registry = @import("registry.zig");
const relocate = arch.relocate;

pub const TypedHook = @import("typed_hook.zig").TypedHook;
pub const CpuContext = arch.CpuContext;
pub const Timing = @import("Timing.zig");

const log = std.log.scoped(.tuft_hook);

/// Longest patch a hook writes over its target.
const max_patch_len = @max(arch.near_jmp_len, arch.abs_jmp_len);

/// Where `Placement` put the code, and how the target gets there.
pub const Mode = enum {
    /// `jmp rel32` to a page within `arch.near_range`. Always used where rel32 reaches everything.
    near,
    /// `jmp rel32` to padding in the target's module.
    cave,
    /// `jmp rel32` to an absolute jump in a code cave near the target.
    cave_relay,
    /// Absolute jump to a page anywhere.
    far,
    /// Swaps the function pointer at the target for the stub. The "trampoline" is the pointer it held.
    slot,
};

pub const Kind = enum { function, mid, slot, inject };

pub const State = enum(u8) {
    disabled = 0,
    enabled,
    /// Another hook patched over ours. Our stub passes straight through and we keep the page alive.
    orphaned,
};

hook_id: u64 = registry.INVALID_HOOK_ID,
target_addr: usize,
detour_addr: usize,
trampoline_addr: usize,
callback_addr: usize = 0,
mode: Mode,
patch_len: u8,
stolen_len: u8,
stub_len: usize,
user_data: usize = 0,
state: State = .disabled,
/// Its stub, trampoline or injected code, and any relay.
place: Placement,
patch_bytes: [max_patch_len]u8,
original_bytes: [relocate.max_stolen_bytes]u8,
/// Callbacks running now, so `destroy` can wait for them. See `enterCall`.
active_calls: std.atomic.Value(u32) = .init(0),
/// Set by `destroy`. Callbacks that haven't started yet go straight to the original.
closing: std.atomic.Value(bool) = .init(false),
/// For a fn hook that includes the original if the detour calls it.
timing: Timing = .{},
/// Null means the host, or nobody said.
owner: ?*const Owner = null,
/// Runs code of its own instead of a stub, see `createInjectRaw`.
injected: bool = false,
/// Just after the targeted instructions, running any others the jump covered first. The first
/// instruction, or what `replace` covers.
resume_addr: usize = 0,
/// A mid hook replacing code, so its callback carries on at `resume_addr`, not the original.
mid_resumes: bool = false,

pub const MidOptions = struct {
    /// Bytes at the target the callback replaces, ending between instructions. Returning without
    /// setting the ip carries on after them. 0 runs the instruction there after it instead.
    replace: u8 = 0,
};

/// `CallbackFunc` gets a mutable `*CpuContext` before the original instruction runs.
pub fn createMid(
    target: anytype,
    comptime CallbackFunc: anytype,
    context: anytype,
) !*Hook {
    const target_addr = try Address.from(target).unwrap();
    return createMidRaw(target_addr, &thunk.MidBridge(CallbackFunc, @TypeOf(context)).run, meta.addressFromAny(context), .{});
}

/// Has to wrap its work in `enterCall`/`leaveCall` itself, like `MidBridge` does.
pub const MidEntry = fn (*Hook, *CpuContext) callconv(.c) void;

/// For callers with their own bridge, like a callback in another DLL.
pub fn createMidRaw(target_addr: usize, callback: *const MidEntry, user_data: usize, options: MidOptions) !*Hook {
    log.debug("Creating mid hook for target 0x{x}", .{target_addr});
    const hook = try create(target_addr, thunk.midStubSize(), user_data, options.replace);
    hook.callback_addr = @intFromPtr(callback);
    hook.mid_resumes = options.replace > 0;
    thunk.writeMidStub(hook.place.code[0..hook.stub_len], hook);
    try hook.register();
    return hook;
}

/// The callback takes `T`'s params, optionally after `context` and a hook handle.
pub fn createFn(
    comptime T: type,
    target: anytype,
    comptime CallbackFunc: anytype,
    context: anytype,
) !*TypedHook(T) {
    const target_addr = try Address.from(target).unwrap();
    const Bridge = thunk.FnBridge(T, CallbackFunc, @TypeOf(context));
    const hook = try createFnRaw(target_addr, @intFromPtr(&Bridge.detour), meta.addressFromAny(context));
    return TypedHook(T).fromHook(hook);
}

/// The detour must call `current()` before anything that could enter a hook,
/// then wrap its work in `enterCall`/`leaveCall`, passing through to `trampoline_addr` when told no.
pub fn createFnRaw(target_addr: usize, detour: usize, user_data: usize) !*Hook {
    log.debug("Creating fn hook for target 0x{x}", .{target_addr});
    const hook = try create(target_addr, thunk.fn_stub_size, user_data, 0);
    thunk.writeFnStub(hook.place.code[0..thunk.fn_stub_size], hook, detour);
    try hook.register();
    return hook;
}

/// Calls through the pointer go to `CallbackFunc`, direct calls don't. Enabling doesn't stop threads.
pub fn createSlot(
    comptime T: type,
    slot: anytype,
    comptime CallbackFunc: anytype,
    context: anytype,
) !*TypedHook(T) {
    const slot_addr = try Address.from(slot).unwrap();
    const Bridge = thunk.FnBridge(T, CallbackFunc, @TypeOf(context));
    const hook = try createSlotRaw(slot_addr, @intFromPtr(&Bridge.detour), meta.addressFromAny(context));
    return TypedHook(T).fromHook(hook);
}

/// Same rules as `createFnRaw`.
pub fn createSlotRaw(slot_addr: usize, detour: usize, user_data: usize) !*Hook {
    log.debug("Creating slot hook for 0x{x}", .{slot_addr});
    if (slot_addr % @alignOf(usize) != 0) return error.MisalignedPointer;
    const held = try Address.at(slot_addr).deref().unwrap();

    // `register` frees both if it fails
    var place = try Placement.place(.{ .code = thunk.fn_stub_size, .jump = false });
    const hook = registry.allocator().create(Hook) catch |err| {
        place.free();
        return err;
    };
    hook.* = .{
        .target_addr = slot_addr,
        .detour_addr = @intFromPtr(place.code.ptr),
        .trampoline_addr = held,
        .mode = .slot,
        .patch_len = @sizeOf(usize),
        .stolen_len = 0,
        .stub_len = thunk.fn_stub_size,
        .user_data = user_data,
        .place = place,
        .patch_bytes = @splat(0),
        .original_bytes = @splat(0),
    };
    thunk.writeFnStub(place.code[0..thunk.fn_stub_size], hook, detour);
    try hook.register();
    return hook;
}

/// The hook whose stub entered the fn detour running on this thread.
pub fn current() *Hook {
    return thunk.currentHook();
}

/// Where injected code goes and what it can jump to.
pub const InjectSite = struct {
    /// Where the code starts.
    code: usize,
    /// Runs the targeted instructions as they were, then carries on. Null when the code's going
    /// in place, where there's no copy of them.
    original: ?usize,
    /// Just after the targeted instructions, running any others the jump covered first.
    resume_at: usize,
    /// Only sizing it up somewhere like where it'll go. It gets built again for real.
    trial: bool = false,
};

/// Writes the code for `site` into `out` and returns how many bytes.
pub const InjectBuild = struct {
    context: ?*anyopaque = null,
    build: *const fn (context: ?*anyopaque, site: InjectSite, out: []u8) anyerror!usize,
};

pub const InjectOptions = struct {
    /// Bytes at the target the code replaces, ending between instructions. Running off the end of
    /// the code carries on after them. 0 puts the code before the instruction there, and running
    /// off the end runs it.
    replace: u8 = 0,
    /// Data placed before that the code reads, so the code goes in reach of it.
    reach: []const usize = &.{},
    /// Where `Placement.placeGroup` already put it, with room from `injectRoom`. Its trampoline
    /// goes first. The hook has it even if making the hook fails.
    place: ?Placement = null,
};

/// Bytes an inject takes, for placing it with `Placement.placeGroup`.
pub fn injectRoom(target_addr: usize, code: InjectBuild, options: InjectOptions) usize {
    return trampolineRoom(target_addr, options.replace) + measureInject(target_addr, code, options);
}

/// Room for the relocated instructions, built as if far from where they came from, where they
/// grow the most. So whatever `Placement` picks, they fit.
fn trampolineRoom(target_addr: usize, replace: u8) usize {
    var scratch: [512]u8 = undefined;
    const far_away = if (arch.near_reaches_all) target_addr else target_addr ^ (@as(usize, 1) << 44);
    for ([_]u8{ arch.abs_jmp_len, arch.near_jmp_len }) |min| {
        const rel = relocate.buildTrampoline(target_addr, @max(min, replace), far_away, &scratch) catch continue;
        return std.mem.alignForward(usize, rel.trampoline_len, 16);
    }
    // It won't build, and `prepareAt` will say why
    return scratch.len;
}

/// Code the target jumps to. It either goes before the instruction there or replaces
/// `options.replace` bytes, see `InjectOptions`. Calls aren't counted, so `destroy` only waits for
/// threads to leave it.
pub fn createInjectRaw(target_addr: usize, code: InjectBuild, options: InjectOptions) !*Hook {
    log.debug("Creating inject hook for target 0x{x}", .{target_addr});
    const alloc = registry.allocator();
    const hook = alloc.create(Hook) catch |err| {
        if (options.place) |given| {
            var p = given;
            p.free();
        }
        return err;
    };

    const trampoline_room = trampolineRoom(target_addr, options.replace);
    var place = options.place orelse (Placement.place(.{
        .target = target_addr,
        .code = trampoline_room + measureInject(target_addr, code, options),
        .reach = options.reach,
    }) catch |err| {
        alloc.destroy(hook);
        return err;
    });
    if (place.code.len < trampoline_room + arch.max_jmp_len) {
        place.free();
        alloc.destroy(hook);
        return error.TooLong;
    }
    const base = @intFromPtr(place.code.ptr);
    const entry = base + trampoline_room;
    hook.prepareAt(target_addr, place, entry, base, place.code[0..trampoline_room], options.replace) catch |err| {
        place.free();
        alloc.destroy(hook);
        return err;
    };
    const site: InjectSite = .{ .code = entry, .original = base, .resume_at = hook.resume_addr };
    const room = place.code[trampoline_room .. place.code.len - arch.max_jmp_len];
    const len = code.build(code.context, site, room) catch |err| {
        _ = hook.release();
        alloc.destroy(hook);
        return err;
    };
    const back = arch.encodeJmp(entry + len, if (options.replace > 0) hook.resume_addr else base);
    @memcpy(place.code[trampoline_room + len ..][0..back.len], back.slice());
    hook.stub_len = trampoline_room + len + back.len;
    hook.injected = true;
    // Frees it if it fails
    try hook.register();
    return hook;
}

/// Room for the code, from a trial build next to its data or else the target. A page's worth if
/// that doesn't build.
fn measureInject(target_addr: usize, code: InjectBuild, options: InjectOptions) usize {
    const page_room = memory.pages.size / 2;
    var scratch: [2048]u8 = undefined;
    const at = if (options.reach.len > 0) options.reach[0] else target_addr;
    const site: InjectSite = .{ .code = at, .original = at, .resume_at = target_addr + options.replace, .trial = true };
    const len = code.build(code.context, site, &scratch) catch return page_room;
    // Some encodings grow with distance
    return len + len / 2 + 32 + arch.max_jmp_len;
}

/// Caller writes the stub, then `register`s. Covers at least `replace` bytes.
fn create(target_addr: usize, stub_size: usize, user_data: usize, replace: u8) !*Hook {
    const alloc = registry.allocator();
    const hook = try alloc.create(Hook);
    errdefer alloc.destroy(hook);

    try hook.allocateAndPrepare(target_addr, stub_size, replace);
    hook.user_data = user_data;
    return hook;
}

fn register(self: *Hook) !void {
    registry.register(self) catch |err| {
        _ = self.release();
        registry.allocator().destroy(self);
        return err;
    };
}

/// `error.TargetModified` if its bytes changed since the trampoline was built.
pub fn enable(self: *Hook) !void {
    switch (self.state) {
        .enabled => return,
        .orphaned => return error.HookOrphaned,
        .disabled => {},
    }
    if (self.mode == .slot) {
        // One atomic store, so no need to stop threads
        if (!try memory.swapPointer(self.target_addr, self.trampoline_addr, self.detour_addr)) return error.TargetModified;
        self.state = .enabled;
        log.debug("Enabled slot hook for 0x{x}", .{self.target_addr});
        return;
    }
    // Nothing that could take a lock while threads are frozen, like logging or allocating. Page
    // protection too, which some games hook with a lock of their own
    {
        const unlocked = try memory.unlockCode(self.target_addr, self.patch_len);
        defer unlocked.lock();
        var guard = try self.freezeThreads();
        defer guard.deinit();

        if (!std.mem.eql(u8, self.targetBytes(self.stolen_len), self.original_bytes[0..self.stolen_len])) {
            return error.TargetModified;
        }
        unlocked.write(self.target_addr, self.patch_bytes[0..self.patch_len]);
        self.state = .enabled;
    }
    log.debug("Enabled hook for target 0x{x}", .{self.target_addr});
}

/// Orphans the hook instead if another hook patched over ours.
pub fn disable(self: *Hook) !void {
    if (self.state != .enabled) return;
    if (self.mode == .slot and try memory.swapPointer(self.target_addr, self.detour_addr, self.trampoline_addr)) {
        self.state = .disabled;
        log.debug("Disabled slot hook for 0x{x}", .{self.target_addr});
        return;
    }
    // Same as `enable`, no logging or page protection while threads are frozen
    {
        const target: ?memory.Unlocked = if (self.mode != .slot) try memory.unlockCode(self.target_addr, @max(self.patch_len, self.stolen_len)) else null;
        defer if (target) |t| t.lock();
        const detour = try memory.unlockCode(self.detour_addr, arch.abs_jmp_len);
        defer detour.lock();
        var guard = try self.freezeThreads();
        defer guard.deinit();

        if (self.mode != .slot and std.mem.eql(u8, self.targetBytes(self.patch_len), self.patch_bytes[0..self.patch_len])) {
            target.?.write(self.target_addr, self.original_bytes[0..self.stolen_len]);
            self.state = .disabled;
        } else {
            // Whoever replaced our patch or pointer might have kept ours as their original
            detour.write(self.detour_addr, arch.encodeJmp(self.detour_addr, self.trampoline_addr).slice());
            self.state = .orphaned;
        }
    }
    if (self.state == .orphaned) {
        log.warn("Hook for target 0x{x} was patched over by someone else; orphaning it", .{self.target_addr});
    } else {
        log.debug("Disabled hook for target 0x{x}", .{self.target_addr});
    }
}

/// Waits for running callbacks, then frees it. Leaks it if something might still reach it.
pub fn destroy(self: *Hook) void {
    const target_addr = self.target_addr;
    const alloc = registry.allocator();
    registry.unregister(self);

    self.closing.store(true, .seq_cst);
    self.disable() catch |err| {
        // The target still jumps into our page, which embeds this Hook's address. Leak both
        log.err("Failed to disable hook for target 0x{x} ({}); leaking it", .{ target_addr, err });
        return;
    };

    if (!self.waitForCalls(destroy_timeout_ms)) {
        log.err("Callbacks for hook on target 0x{x} still running after {}ms; leaking it", .{ target_addr, destroy_timeout_ms });
        return;
    }

    if (self.state == .orphaned) {
        // The neutralized stub doesn't point at this Hook anymore, so only the page has to stay
        log.warn("Leaking page of orphaned hook for target 0x{x}", .{target_addr});
    } else {
        var guard = self.freezeThreads() catch |err| {
            // A thread might be in our stub about to read this Hook. Leak both
            log.err("Couldn't safely free hook for target 0x{x} ({}); leaking it", .{ target_addr, err });
            return;
        };
        const relay_restored = self.place.unlink();
        guard.deinit();
        // Nothing jumps there now, so it's fine to free with threads running
        self.place.free();
        if (!relay_restored) log.warn("Failed to restore code cave of hook for target 0x{x}", .{target_addr});
    }
    alloc.destroy(self);

    log.debug("Destroyed hook for target 0x{x}", .{target_addr});
}

pub fn original(self: *const Hook, comptime T: type) T {
    return @ptrFromInt(self.trampoline_addr);
}

const destroy_timeout_ms = 2000;

/// False once closing, then the call goes to the original. Otherwise pair it with `leaveCall`.
pub fn enterCall(self: *Hook) bool {
    // seq_cst pairs with `destroy`'s store-then-wait. A call is either counted or sees `closing`
    _ = self.active_calls.fetchAdd(1, .seq_cst);
    if (self.closing.load(.seq_cst)) {
        _ = self.active_calls.fetchSub(1, .seq_cst);
        return false;
    }
    if (call_depth < call_starts.len) call_starts[call_depth] = sys.clock.nanos();
    call_depth += 1;
    return true;
}

/// Per-thread start times. Calls nest, so a stack works. Deeper ones don't get timed.
threadlocal var call_starts: [32]u64 = undefined;
threadlocal var call_depth: u32 = 0;

pub fn kind(self: *const Hook) Kind {
    if (self.mode == .slot) return .slot;
    if (self.injected) return .inject;
    return if (self.callback_addr != 0) .mid else .function;
}

/// The owner has to outlive the hook, so destroy it when the owner closes.
pub fn setOwner(self: *Hook, owner: ?*const Owner) void {
    self.owner = owner;
    if (self.hook_id != registry.INVALID_HOOK_ID) Claims.setOwner(.hook, self.hook_id, owner);
}

pub fn leaveCall(self: *Hook) void {
    if (call_depth > 0) {
        call_depth -= 1;
        if (call_depth < call_starts.len) self.timing.record(sys.clock.nanos() -| call_starts[call_depth]);
    }
    _ = self.active_calls.fetchSub(1, .seq_cst);
}

fn waitForCalls(self: *const Hook, timeout_ms: u32) bool {
    var waited: u32 = 0;
    while (self.active_calls.load(.seq_cst) != 0) : (waited += 1) {
        if (waited >= timeout_ms) return false;
        sys.thread.sleepMs(1);
    }
    return true;
}

/// Bytes it overwrites and relocates. For a slot hook, its slot.
pub fn patchedRange(self: *const Hook) sys.thread.CodeRange {
    return .{ .start = self.target_addr, .len = if (self.mode == .slot) @sizeOf(usize) else self.stolen_len };
}

fn targetBytes(self: *const Hook, len: usize) []const u8 {
    const target: [*]const u8 = @ptrFromInt(self.target_addr);
    return target[0..len];
}

/// The code `Placement` put it in and any relay.
pub fn placedRanges(self: *const Hook) [2]sys.thread.CodeRange {
    return .{
        .{ .start = @intFromPtr(self.place.code.ptr), .len = self.place.code.len },
        .{ .start = self.place.relay, .len = if (self.place.relay != 0) arch.abs_jmp_len else 0 },
    };
}

/// Freezes other threads once none are inside the patched bytes or our code.
/// Can't spot return addresses into the trampoline, or a stub address loaded from a slot.
fn freezeThreads(self: *const Hook) !sys.thread.ThreadFreezeGuard {
    const placed = self.placedRanges();
    return sys.thread.freezeThreads(registry.allocator(), .{
        .executing = &.{ self.patchedRange(), placed[0], placed[1] },
        .referenced = if (self.mode == .slot) placed[0..1] else &.{},
    });
}

fn modeOf(place: *const Placement) Mode {
    return switch (place.jump) {
        .near => if (place.tier == .cave) .cave else .near,
        .relay => .cave_relay,
        .absolute => .far,
    };
}

fn allocateAndPrepare(self: *Hook, target_addr: usize, stub_size: usize, replace: u8) !void {
    const stub_len = std.mem.alignForward(usize, stub_size, 16);
    var place = try Placement.place(.{ .target = target_addr, .code = stub_len + trampolineRoom(target_addr, replace) });
    errdefer place.free();
    try self.prepare(target_addr, stub_size, place, replace);
}

/// Lays out `[stub | trampoline]` and builds the patch. Only owns `place` on success.
fn prepare(self: *Hook, target_addr: usize, stub_size: usize, place: Placement, replace: u8) !void {
    const stub_len = std.mem.alignForward(usize, stub_size, 16);
    const base = @intFromPtr(place.code.ptr);
    try self.prepareAt(target_addr, place, base, base + stub_len, place.code[stub_len..], replace);
    self.stub_len = stub_len;
}

/// Builds the trampoline at `tramp_base` and a patch that jumps to `entry`. Covers at least
/// `replace` bytes, which have to end between instructions. Only owns `placed` on success.
fn prepareAt(self: *Hook, target_addr: usize, placed: Placement, entry: usize, tramp_base: usize, tramp_buf: []u8, replace: u8) !void {
    var place = placed;
    const mode = modeOf(&place);
    log.debug("Preparing {t} hook for target 0x{x} (code at 0x{x})", .{ mode, target_addr, @intFromPtr(place.code.ptr) });

    const rel = try relocate.buildTrampoline(target_addr, @max(place.jumpLen(), replace), tramp_base, tramp_buf);
    log.debug("Stole {} bytes at 0x{x}; trampoline at 0x{x} ({} bytes)", .{ rel.stolen_len, target_addr, tramp_base, rel.trampoline_len });
    const targeted = if (replace > 0) replace else rel.firstLen();
    const resume_offset = rel.after(targeted) orelse return error.SplitsInstruction;
    const resume_addr = if (targeted == rel.stolen_len) target_addr + rel.stolen_len else tramp_base + resume_offset;

    // Last, since it fills in the relay
    const jump = try place.link(target_addr, entry);

    self.* = .{
        .target_addr = target_addr,
        .detour_addr = entry,
        .trampoline_addr = tramp_base,
        .mode = mode,
        .patch_len = jump.len,
        .stolen_len = rel.stolen_len,
        .stub_len = 0,
        .place = place,
        .patch_bytes = jump.bytes,
        .original_bytes = rel.original_bytes,
        .resume_addr = resume_addr,
    };
}

/// Hook must be disabled, and threads not frozen. False if the relay restore failed.
fn release(self: *Hook) bool {
    const restored = self.place.unlink();
    self.place.free();
    return restored;
}

const tests = struct {
    // Targets need `noinline` and an asm barrier, or optimized builds skip the patch

    noinline fn mockTargetSite(a: i32) callconv(.c) i32 {
        var x = a;
        asm volatile (""
            : [x] "+r" (x),
        );
        return x * 2;
    }

    noinline fn testTargetFunction(a: i32, b: i32) callconv(.c) i32 {
        // Some plain math so the prologue has normal bytes to steal
        var x = a;
        var y = b;
        asm volatile (""
            : [x] "+r" (x),
              [y] "+r" (y),
        );
        return x + y;
    }

    noinline fn testTargetMath(a: i32, b: i32) callconv(.c) i32 {
        var x = a;
        var y = b;
        asm volatile (""
            : [x] "+r" (x),
              [y] "+r" (y),
        );
        return x + y;
    }

    const TargetSig = fn (i32, i32) callconv(.c) i32;

    test "createFn detours calls" {
        try registry.init(std.testing.allocator);
        defer registry.deinit();

        const TargetType = fn (i32, i32) callconv(.c) i32;

        // Checks the args and returns something else
        const DetourClosure = struct {
            fn detour(hook: *Hook, a: i32, b: i32) i32 {
                _ = hook;
                std.testing.expectEqual(10, a) catch {};
                std.testing.expectEqual(20, b) catch {};

                return 9999;
            }
        }.detour;

        const hook = try createFn(TargetType, &testTargetFunction, DetourClosure, void);
        defer hook.destroy();

        try std.testing.expectEqual(30, testTargetFunction(10, 20));

        try hook.enable();

        try std.testing.expectEqual(9999, testTargetFunction(10, 20));

        try hook.disable();
        try std.testing.expectEqual(30, testTargetFunction(10, 20));
    }

    fn returnNinetyNine(_: ?*anyopaque, _: InjectSite, out: []u8) anyerror!usize {
        // mov eax, 99 then ret
        const code = [_]u8{ 0xB8, 0x63, 0x00, 0x00, 0x00, 0xC3 };
        @memcpy(out[0..code.len], &code);
        return code.len;
    }

    fn runOriginal(_: ?*anyopaque, site: InjectSite, out: []u8) anyerror!usize {
        const jmp = arch.encodeJmp(site.code, site.original.?);
        @memcpy(out[0..jmp.len], jmp.slice());
        return jmp.len;
    }

    test "inject replaces in place, or runs the original" {
        try registry.init(std.testing.allocator);
        defer registry.deinit();

        const early = try createInjectRaw(@intFromPtr(&testTargetMath), .{ .build = returnNinetyNine }, .{});
        try std.testing.expectEqual(.inject, early.kind());
        try early.enable();
        try std.testing.expectEqual(99, testTargetMath(1, 2));
        try early.disable();
        try std.testing.expectEqual(3, testTargetMath(1, 2));
        early.destroy();

        const kept = try createInjectRaw(@intFromPtr(&testTargetMath), .{ .build = runOriginal }, .{});
        defer kept.destroy();
        try kept.enable();
        try std.testing.expectEqual(3, testTargetMath(1, 2));
    }

    test "stub then trampoline" {
        try registry.init(std.testing.allocator);
        defer registry.deinit();

        var mock_hook = std.mem.zeroes(Hook);
        const target = @intFromPtr(&mockTargetSite);

        // About what a register-saving mid stub takes
        const requested_stub_size = 208;
        const expected_alignment_padding = std.mem.alignForward(usize, requested_stub_size, 16);

        try mock_hook.allocateAndPrepare(target, requested_stub_size, 0);
        defer _ = mock_hook.release();

        try std.testing.expectEqual(target, mock_hook.target_addr);
        try std.testing.expectEqual(@intFromPtr(mock_hook.place.code.ptr), mock_hook.detour_addr);
        try std.testing.expectEqual(mock_hook.detour_addr + expected_alignment_padding, mock_hook.trampoline_addr);
        try std.testing.expectEqual(expected_alignment_padding, mock_hook.stub_len);
        try std.testing.expectEqual(expected_alignment_padding + trampolineRoom(target, 0), mock_hook.place.code.len);
        try std.testing.expectEqual(mock_hook.place.jumpLen(), mock_hook.patch_len);
        // Where a rel32 reaches everything, it's always near
        if (arch.near_reaches_all) try std.testing.expectEqual(.near, mock_hook.mode);
    }

    test "zero-size stub layout" {
        try registry.init(std.testing.allocator);
        defer registry.deinit();

        var mock_hook = std.mem.zeroes(Hook);
        const target = @intFromPtr(&mockTargetSite);

        // Plain fn detours pass 0 for stub_size
        try mock_hook.allocateAndPrepare(target, 0, 0);
        defer _ = mock_hook.release();

        try std.testing.expectEqual(0, mock_hook.stub_len);
        try std.testing.expectEqual(mock_hook.detour_addr, mock_hook.trampoline_addr);
    }

    noinline fn placementTarget(a: i32, b: i32) callconv(.c) i32 {
        var x = a;
        var y = b;
        // Padding keeps the body longer than the longest patch in every optimize mode
        asm volatile ("nop; nop; nop; nop; nop; nop; nop; nop; nop; nop; nop; nop; nop; nop; nop; nop"
            : [x] "+r" (x),
              [y] "+r" (y),
        );
        return x * y + 1;
    }

    fn placementReplacement(a: i32, b: i32) callconv(.c) i32 {
        _ = a;
        _ = b;
        return -1;
    }

    /// Only `tier`, and checks enable, original and disable. Null if there was no room there.
    fn expectTierWorks(tier: Placement.Tier) !?Mode {
        Placement.tiers = .initOne(tier);
        defer Placement.tiers = .full;
        var hook: Hook = undefined;
        hook.allocateAndPrepare(@intFromPtr(&placementTarget), arch.abs_jmp_len, 0) catch |err| {
            // The test exe might have no padding to spare
            if (err == error.OutOfReach and tier == .cave) return null;
            return err;
        };
        defer _ = hook.release();
        try std.testing.expectEqual(tier, hook.place.tier);

        const stub: *[arch.abs_jmp_len]u8 = @ptrFromInt(hook.detour_addr);
        stub.* = arch.encodeAbsJmp(@intFromPtr(&placementReplacement));

        try hook.enable();
        try std.testing.expectEqual(-1, placementTarget(3, 4));
        try std.testing.expectEqual(13, hook.original(*const @TypeOf(placementTarget))(3, 4));
        try hook.disable();
        try std.testing.expectEqual(13, placementTarget(3, 4));
        return hook.mode;
    }

    test "hooks work in every tier" {
        try registry.init(std.testing.allocator);
        defer registry.deinit();

        try std.testing.expectEqual(.near, (try expectTierWorks(.near)).?);
        if (try expectTierWorks(.cave)) |mode| try std.testing.expectEqual(.cave, mode);
        try std.testing.expectEqual(.far, (try expectTierWorks(.anywhere)).?);

        const far = (try expectTierWorks(.far)).?;
        try std.testing.expect(far == .cave_relay or far == .far);
        Placement.relays = false;
        defer Placement.relays = true;
        try std.testing.expectEqual(.far, (try expectTierWorks(.far)).?);
    }

    test "cave relay goes back" {
        try registry.init(std.testing.allocator);
        defer registry.deinit();
        Placement.tiers = .initOne(.far);
        defer Placement.tiers = .full;

        const hook = try createFn(TargetSig, &placementTarget, struct {
            fn detour(h: *TypedHook(TargetSig), a: i32, b: i32) i32 {
                return h.original()(a, b) + 100;
            }
        }.detour, void);
        const relay = hook.toHook().place.relay;
        if (relay == 0) {
            hook.destroy();
            return error.SkipZigTest;
        }
        try std.testing.expectEqual(.cave_relay, hook.toHook().mode);
        const cave: *const [arch.abs_jmp_len]u8 = @ptrFromInt(relay);
        try std.testing.expectEqualSlices(u8, &arch.encodeAbsJmp(hook.toHook().detour_addr), cave);
        try hook.enable();
        try std.testing.expectEqual(113, placementTarget(3, 4));
        const before = hook.toHook().place.held[2].?.what.relay;
        hook.destroy();
        try std.testing.expectEqualSlices(u8, &before, cave);
        try std.testing.expectEqual(13, placementTarget(3, 4));
    }

    test "destroy restores enabled target" {
        try registry.init(std.testing.allocator);
        defer registry.deinit();

        const hook = try createFn(TargetSig, &placementTarget, struct {
            fn detour(a: i32, b: i32) i32 {
                return a + b;
            }
        }.detour, void);

        try hook.enable();
        try std.testing.expectEqual(7, placementTarget(3, 4));
        hook.destroy();
        try std.testing.expectEqual(13, placementTarget(3, 4));
    }

    test "chains through an existing E9" {
        try registry.init(std.testing.allocator);
        defer registry.deinit();

        // Fake an overlay's 5-byte hook, then padding its trampoline would resume into
        const fake = (try memory.pages.allocNear(@intFromPtr(&placementTarget), 64)) orelse return error.SkipZigTest;
        defer memory.pages.free(fake);
        @memset(fake, 0xCC);
        fake[0..arch.near_jmp_len].* = arch.encodeNearJmp(@intFromPtr(fake.ptr), @intFromPtr(&placementTarget)).?;

        const Storage = struct {
            var hook: ?*TypedHook(TargetSig) = null;
        };
        const hook = try createFn(TargetSig, @intFromPtr(fake.ptr), struct {
            fn detour(a: i32, b: i32) i32 {
                return Storage.hook.?.original()(a, b) + 100;
            }
        }.detour, void);
        defer hook.destroy();
        Storage.hook = hook;
        defer Storage.hook = null;

        try std.testing.expectEqual(.near, hook.toHook().mode);
        try std.testing.expectEqual(5, hook.toHook().stolen_len);

        try hook.enable();
        const fake_fn: *const TargetSig = @ptrCast(fake.ptr);
        try std.testing.expectEqual(113, fake_fn(3, 4));
        // The overlay's padding after its jump has to be untouched
        try std.testing.expectEqual(0xCC, fake[5]);
    }

    test "createMid mutates registers" {
        try registry.init(std.testing.allocator);
        defer registry.deinit();

        const Target = struct {
            noinline fn run(a: usize) callconv(.c) usize {
                var x = a;
                asm volatile (""
                    : [x] "+r" (x),
                );
                return x + 1;
            }
        };

        var calls: u32 = 0;
        const hook = try createMid(&Target.run, struct {
            fn cb(count: *u32, cpu: *CpuContext) void {
                count.* += 1;
                std.testing.expectEqual(5, arch.testing.firstArg(cpu)) catch {};
                arch.testing.changeFirstArg(cpu);
            }
        }.cb, &calls);
        defer hook.destroy();

        try hook.enable();
        try std.testing.expectEqual(arch.testing.changed_arg + 1, Target.run(5));
        try std.testing.expectEqual(1, calls);

        try hook.disable();
        try std.testing.expectEqual(6, Target.run(5));
        try std.testing.expectEqual(1, calls);
    }

    test "mid hook sees its ip and can jump elsewhere" {
        try registry.init(std.testing.allocator);
        defer registry.deinit();

        const Fns = struct {
            noinline fn run(a: usize) callconv(.c) usize {
                var x = a;
                asm volatile (""
                    : [x] "+r" (x),
                );
                return x + 1;
            }

            noinline fn instead(a: usize) callconv(.c) usize {
                var x = a;
                asm volatile (""
                    : [x] "+r" (x),
                );
                return x * 100;
            }
        };

        var seen_ip: usize = 0;
        const hook = try createMid(&Fns.run, struct {
            fn cb(seen: *usize, cpu: *CpuContext) void {
                seen.* = cpu.ip();
                // Same args and stack at entry, so it's a tail call
                cpu.setIp(@intFromPtr(&Fns.instead));
            }
        }.cb, &seen_ip);
        defer hook.destroy();

        try hook.enable();
        try std.testing.expectEqual(500, Fns.run(5));
        try std.testing.expectEqual(@intFromPtr(&Fns.run), seen_ip);
        try hook.disable();
        try std.testing.expectEqual(6, Fns.run(5));
    }

    noinline fn lifecycleTarget(a: i32, b: i32) callconv(.c) i32 {
        var x = a;
        var y = b;
        asm volatile (""
            : [x] "+r" (x),
              [y] "+r" (y),
        );
        return x - y;
    }

    const CountingDetour = struct {
        var calls: u32 = 0;
        fn detour(a: i32, b: i32) i32 {
            calls += 1;
            return a * b;
        }
    };

    test "refuses a modified target" {
        try registry.init(std.testing.allocator);
        defer registry.deinit();

        var target_addr = @intFromPtr(&lifecycleTarget);
        _ = &target_addr; // comptime can't read function memory
        const target: [*]const u8 = @ptrFromInt(target_addr);
        const pristine = target[0..16].*;
        defer memory.writeCode(target_addr, &pristine) catch {};

        const hook = try createFn(TargetSig, &lifecycleTarget, CountingDetour.detour, void);
        defer hook.destroy();

        // Someone else patches the prologue between create and enable
        try memory.writeCode(target_addr, &[_]u8{0x90});
        try std.testing.expectError(error.TargetModified, hook.enable());
        try std.testing.expectEqual(.disabled, hook.toHook().state);
    }

    test "orphans when patched over" {
        // It'll get orphaned, so keep its warnings out of the test output
        const saved_level = std.testing.log_level;
        std.testing.log_level = .err;
        defer std.testing.log_level = saved_level;

        try registry.init(std.testing.allocator);
        defer registry.deinit();

        var target_addr = @intFromPtr(&lifecycleTarget);
        _ = &target_addr; // comptime can't read function memory
        const target: [*]const u8 = @ptrFromInt(target_addr);
        const pristine = target[0..16].*;

        CountingDetour.calls = 0;
        const hook = try createFn(TargetSig, &lifecycleTarget, CountingDetour.detour, void);
        try hook.enable();
        try std.testing.expectEqual(12, lifecycleTarget(3, 4));

        // Fake an overlay on top of us that moves our jump into its own trampoline
        const overlay = (try memory.pages.allocNear(target_addr, memory.pages.size)) orelse return error.SkipZigTest;
        defer {
            memory.writeCode(target_addr, &pristine) catch {};
            memory.pages.free(overlay);
        }
        _ = try relocate.buildTrampoline(target_addr, arch.near_jmp_len, @intFromPtr(overlay.ptr), overlay);
        try memory.writeCode(target_addr, &arch.encodeNearJmp(target_addr, @intFromPtr(overlay.ptr)).?);
        try std.testing.expectEqual(12, lifecycleTarget(3, 4));
        try std.testing.expectEqual(2, CountingDetour.calls);

        // Putting our original bytes back would drop the overlay, so we pass through instead
        try hook.disable();
        try std.testing.expectEqual(.orphaned, hook.toHook().state);
        try std.testing.expectEqual(0xE9, target[0]);
        try std.testing.expectEqual(-1, lifecycleTarget(3, 4));
        try std.testing.expectEqual(2, CountingDetour.calls);
        try std.testing.expectError(error.HookOrphaned, hook.enable());

        // Destroying keeps the page alive, so the overlay's chain still works
        hook.destroy();
        try std.testing.expectEqual(-1, lifecycleTarget(3, 4));
    }

    test "registry snapshot" {
        try registry.init(std.testing.allocator);
        defer registry.deinit();

        const hook = try createFn(TargetSig, &lifecycleTarget, CountingDetour.detour, void);
        defer hook.destroy();
        var kai: Claims.Owner = .init("kai");
        hook.toHook().setOwner(&kai);
        try hook.enable();
        _ = lifecycleTarget(3, 4);
        _ = lifecycleTarget(3, 4);

        var out: [8]registry.Info = undefined;
        const n = registry.snapshot(&out);
        try std.testing.expectEqual(1, n);
        try std.testing.expectEqual(Kind.function, out[0].kind);
        try std.testing.expectEqual(&kai, out[0].owner.?);
        try std.testing.expectEqualStrings("kai", out[0].ownerName());
        try std.testing.expectEqual(State.enabled, out[0].state);
        try std.testing.expectEqual(2, out[0].timing.calls);
        try std.testing.expect(out[0].timing.max_ns >= out[0].timing.last_ns);
        try std.testing.expect(out[0].timing.total_ns >= out[0].timing.max_ns);

        registry.resetTimings();
        _ = registry.snapshot(&out);
        try std.testing.expectEqual(0, out[0].timing.calls);
        try std.testing.expectEqual(@intFromPtr(&lifecycleTarget), out[0].target);
    }

    test "rejects overlapping hooks" {
        try registry.init(std.testing.allocator);
        defer registry.deinit();

        const hook = try createFn(TargetSig, &lifecycleTarget, CountingDetour.detour, void);
        defer hook.destroy();

        try std.testing.expectError(error.AlreadyHooked, createFn(TargetSig, &lifecycleTarget, CountingDetour.detour, void));
        try std.testing.expectError(error.AlreadyHooked, createMid(@intFromPtr(&lifecycleTarget) + 1, struct {
            fn cb(cpu: *CpuContext) void {
                _ = cpu;
            }
        }.cb, void));
    }

    test "idempotent enable and disable" {
        try registry.init(std.testing.allocator);
        defer registry.deinit();

        const hook = try createFn(TargetSig, &lifecycleTarget, CountingDetour.detour, void);
        try hook.enable();
        try hook.enable();
        try std.testing.expectEqual(12, lifecycleTarget(3, 4));
        try hook.disable();
        try hook.disable();
        try std.testing.expectEqual(-1, lifecycleTarget(3, 4));

        try hook.enable();
        try std.testing.expectEqual(12, lifecycleTarget(3, 4));
        registry.deinit();
        try std.testing.expectEqual(-1, lifecycleTarget(3, 4));
    }

    test "destroy waits for callbacks" {
        try registry.init(std.testing.allocator);
        defer registry.deinit();

        const Ctl = struct {
            var entered: std.atomic.Value(bool) = .init(false);
            var proceed: std.atomic.Value(bool) = .init(false);
            var destroyed: std.atomic.Value(bool) = .init(false);

            fn detour(a: i32, b: i32) i32 {
                entered.store(true, .seq_cst);
                while (!proceed.load(.seq_cst)) std.atomic.spinLoopHint();
                return a * b;
            }

            fn call(out: *i32) void {
                out.* = lifecycleTarget(3, 4);
            }

            fn destroyHook(h: *TypedHook(TargetSig)) void {
                h.destroy();
                destroyed.store(true, .seq_cst);
            }
        };

        const hook = try createFn(TargetSig, &lifecycleTarget, Ctl.detour, void);
        try hook.enable();

        var result: i32 = 0;
        const caller = try std.Thread.spawn(.{}, Ctl.call, .{&result});
        // If a check fails, let the callback go instead of leaving it spinning
        errdefer Ctl.proceed.store(true, .seq_cst);
        while (!Ctl.entered.load(.seq_cst)) std.atomic.spinLoopHint();

        const destroyer = try std.Thread.spawn(.{}, Ctl.destroyHook, .{hook});
        // Calling before `destroy` starts would run the never-returning detour
        const raw = hook.toHook();
        for (0..5000) |_| {
            if (raw.closing.load(.seq_cst)) break;
            try std.testing.io.sleep(.fromMilliseconds(1), .awake);
        } else return error.TimedOut;
        try std.testing.io.sleep(.fromMilliseconds(50), .awake);
        // Calls go to the original now, but the Hook can't be freed while the callback runs
        try std.testing.expect(!Ctl.destroyed.load(.seq_cst));
        try std.testing.expectEqual(-1, lifecycleTarget(3, 4));

        Ctl.proceed.store(true, .seq_cst);
        caller.join();
        destroyer.join();
        try std.testing.expect(Ctl.destroyed.load(.seq_cst));
        try std.testing.expectEqual(12, result);
    }

    noinline fn slotMethod(a: i32, b: i32) callconv(.c) i32 {
        var x = a;
        var y = b;
        asm volatile (""
            : [x] "+r" (x),
              [y] "+r" (y),
        );
        return x * y;
    }

    /// A read-only vtable `{ 0, &slotMethod }` in a page of its own.
    const SlotTable = struct {
        page: memory.pages.Slice,

        fn init() !SlotTable {
            const page = try memory.pages.allocAny(16);
            const entries: *[2]usize = @ptrCast(@alignCast(page.ptr));
            entries.* = .{ 0, @intFromPtr(&slotMethod) };
            _ = try memory.protect(@intFromPtr(page.ptr), page.len, .read);
            return .{ .page = page };
        }

        fn deinit(self: SlotTable) void {
            memory.pages.free(self.page);
        }

        fn slot(self: SlotTable) *volatile usize {
            return @ptrFromInt(@intFromPtr(self.page.ptr) + @sizeOf(usize));
        }

        fn call(self: SlotTable, a: i32, b: i32) i32 {
            const f: *const TargetSig = @ptrFromInt(self.slot().*);
            return f(a, b);
        }
    };

    test "slot hook catches virtual calls" {
        try registry.init(std.testing.allocator);
        defer registry.deinit();
        const table = try SlotTable.init();
        defer table.deinit();

        const vtable_holder: usize = @intFromPtr(table.page.ptr);
        const hook = try createSlot(TargetSig, Address.from(&vtable_holder).vtableSlot(1), struct {
            fn detour(h: *TypedHook(TargetSig), a: i32, b: i32) i32 {
                return h.original()(a, b) + 100;
            }
        }.detour, {});
        defer hook.destroy();
        try std.testing.expectEqual(@intFromPtr(&slotMethod), @intFromPtr(hook.original()));

        try hook.enable();
        try std.testing.expectEqual(@intFromPtr(hook.toHook().place.code.ptr), table.slot().*);
        try std.testing.expectEqual(112, table.call(3, 4));
        try std.testing.expectEqual(12, slotMethod(3, 4));

        try hook.disable();
        try std.testing.expectEqual(@intFromPtr(&slotMethod), table.slot().*);
        try std.testing.expectEqual(12, table.call(3, 4));

        try std.testing.expectError(error.AlreadyHooked, createSlot(TargetSig, table.slot(), CountingDetour.detour, void));
    }

    test "slot enable refuses changed slot" {
        try registry.init(std.testing.allocator);
        defer registry.deinit();
        const table = try SlotTable.init();
        defer table.deinit();

        {
            const hook = try createSlot(TargetSig, table.slot(), CountingDetour.detour, void);
            defer hook.destroy();
            _ = try memory.swapPointer(@intFromPtr(table.slot()), @intFromPtr(&slotMethod), @intFromPtr(&lifecycleTarget));
            try std.testing.expectError(error.TargetModified, hook.enable());
            _ = try memory.swapPointer(@intFromPtr(table.slot()), @intFromPtr(&lifecycleTarget), @intFromPtr(&slotMethod));
        }

        const hook = try createSlot(TargetSig, table.slot(), CountingDetour.detour, void);
        try hook.enable();
        hook.destroy();
        try std.testing.expectEqual(@intFromPtr(&slotMethod), table.slot().*);
        try std.testing.expectError(error.MisalignedPointer, createSlot(TargetSig, @intFromPtr(table.slot()) + 1, CountingDetour.detour, void));
    }

    test "slot orphans when replaced" {
        const saved_level = std.testing.log_level;
        std.testing.log_level = .err;
        defer std.testing.log_level = saved_level;

        try registry.init(std.testing.allocator);
        defer registry.deinit();
        const table = try SlotTable.init();
        defer table.deinit();

        CountingDetour.calls = 0;
        const hook = try createSlot(TargetSig, table.slot(), CountingDetour.detour, void);
        try hook.enable();

        // Another hook takes the slot, keeping our stub as its original
        const ours = table.slot().*;
        _ = try memory.swapPointer(@intFromPtr(table.slot()), ours, @intFromPtr(&lifecycleTarget));
        const theirs_original: *const TargetSig = @ptrFromInt(ours);
        try std.testing.expectEqual(12, theirs_original(3, 4));
        try std.testing.expectEqual(1, CountingDetour.calls);

        try hook.disable();
        try std.testing.expectEqual(.orphaned, hook.toHook().state);
        try std.testing.expectEqual(@intFromPtr(&lifecycleTarget), table.slot().*);
        // Their chain still reaches the original, without our callback
        try std.testing.expectEqual(12, theirs_original(3, 4));
        try std.testing.expectEqual(1, CountingDetour.calls);
        hook.destroy();
        try std.testing.expectEqual(12, theirs_original(3, 4));
    }

    test "calls original via handle" {
        try registry.init(std.testing.allocator);
        defer registry.deinit();

        // Lets the detour find its trampoline without a hook param
        const StaticStorage = struct {
            pub threadlocal var active_hook: ?*TypedHook(TargetSig) = null;
        };

        const CallOriginalDetour = struct {
            fn detour(a: i32, b: i32) i32 {
                std.testing.expectEqual(5, a) catch {};
                std.testing.expectEqual(10, b) catch {};

                const h = StaticStorage.active_hook orelse unreachable;

                const original_result = h.original()(a, b);

                return original_result + 500;
            }
        }.detour;

        const hook = try createFn(TargetSig, &testTargetMath, CallOriginalDetour, void);
        defer hook.destroy();

        StaticStorage.active_hook = hook;
        defer StaticStorage.active_hook = null;

        try hook.enable();

        // Detour adds 500 to the original 15
        try std.testing.expectEqual(@as(i32, 515), testTargetMath(5, 10));

        try hook.disable();
        try std.testing.expectEqual(@as(i32, 15), testTargetMath(5, 10));
    }

    test "no extra params" {
        try registry.init(std.testing.allocator);
        defer registry.deinit();

        const PureDetour = struct {
            fn detour(a: i32, b: i32) i32 {
                std.testing.expectEqual(5, a) catch {};
                std.testing.expectEqual(10, b) catch {};
                return 100;
            }
        }.detour;

        const hook = try createFn(TargetSig, &testTargetMath, PureDetour, void);
        defer hook.destroy();

        try hook.enable();
        try std.testing.expectEqual(100, testTargetMath(5, 10));
    }

    test "context param" {
        try registry.init(std.testing.allocator);
        defer registry.deinit();

        const ContextState = struct { magical_checksum: u32 };
        var mock_state = ContextState{ .magical_checksum = 0x7777_8888 };

        const ContextFirstDetour = struct {
            fn detour(ctx: *ContextState, a: i32, b: i32) i32 {
                std.testing.expectEqual(0x7777_8888, ctx.magical_checksum) catch {};
                return a * b;
            }
        }.detour;

        const hook = try createFn(TargetSig, &testTargetMath, ContextFirstDetour, &mock_state);
        defer hook.destroy();

        try hook.enable();
        try std.testing.expectEqual(50, testTargetMath(5, 10));
    }

    test "hook param" {
        try registry.init(std.testing.allocator);
        defer registry.deinit();

        const HookFirstDetour = struct {
            fn detour(h: *Hook, a: i32, b: i32) i32 {
                // The stub published this hook for the detour
                std.testing.expect(h.detour_addr != 0) catch {};
                return a + b + 5;
            }
        }.detour;

        const hook = try createFn(TargetSig, &testTargetMath, HookFirstDetour, void);
        defer hook.destroy();

        try hook.enable();
        try std.testing.expectEqual(20, testTargetMath(5, 10));
    }

    test "context then hook" {
        try registry.init(std.testing.allocator);
        defer registry.deinit();

        var dummy_context: u64 = 0xDECA_FBAD_FFFF_FFFF;

        const ContextThenHookDetour = struct {
            fn detour(ctx: *u64, h: *Hook, a: i32, b: i32) i32 {
                std.testing.expectEqual(0xDECA_FBAD_FFFF_FFFF, ctx.*) catch {};
                std.testing.expect(h.detour_addr != 0) catch {};
                return a - b;
            }
        }.detour;

        const hook = try createFn(TargetSig, &testTargetMath, ContextThenHookDetour, &dummy_context);
        defer hook.destroy();

        try hook.enable();
        try std.testing.expectEqual(-5, testTargetMath(5, 10));
    }

    test "hook then context" {
        try registry.init(std.testing.allocator);
        defer registry.deinit();

        var dummy_context: i32 = 123456;

        const HookThenContextDetour = struct {
            fn detour(h: *Hook, ctx: *i32, a: i32, b: i32) i32 {
                std.testing.expect(h.detour_addr != 0) catch {};
                std.testing.expectEqual(@as(i32, 123456), ctx.*) catch {};
                return (a + b) * 2;
            }
        }.detour;

        const hook = try createFn(TargetSig, &testTargetMath, HookThenContextDetour, &dummy_context);
        defer hook.destroy();

        try hook.enable();
        try std.testing.expectEqual(30, testTargetMath(5, 10));
    }
};

test {
    _ = tests;
}
