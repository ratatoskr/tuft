//! In-process debugger with breakpoints that stop threads until a UI resumes them.

const Debugger = @This();

const std = @import("std");

const arch = @import("tuft_arch");
const sys = @import("tuft_sys");
const Memory = @import("tuft_mem").Memory;

const exceptions = @import("exceptions.zig");
const watch = @import("watch.zig");
const Patch = @import("Patch.zig");
const registry = @import("registry.zig");

const CpuContext = arch.CpuContext;
const Exception = exceptions.Exception;

pub const Kind = enum {
    /// A debug register, shared with memory watches. Only four, but the code stays untouched.
    hardware,
    /// An `int3` over the code's first byte. Unlimited, but visible to games checking their code.
    software,
};

pub const Stop = enum(u8) {
    thread,
    /// Plus every other game thread gets frozen.
    all,
    /// Just counts hits.
    none,
};

pub const Breakpoint = struct {
    address: usize,
    kind: Kind,
    stop: Stop,
    enabled: bool,
    hits: u32,
};

pub const Reason = enum(u8) { breakpoint, step, crash };

/// What a `crash` stop stopped on.
pub const Crash = struct {
    code: u32,
    kind: sys.exceptions.Kind,
    fault: ?sys.exceptions.Fault = null,
};

pub const Paused = struct {
    /// New every stop. What `resumeThread` takes.
    id: u32,
    thread_id: u32,
    reason: Reason,
    stop: Stop,
    /// Where it stopped is `cpu.ip()`. Edits from `setCpu` show here.
    cpu: CpuContext,
    /// By `sys.thread.tickMs`.
    since_ms: u64,
    /// For a `crash` stop.
    crash: ?Crash = null,
};

pub const How = enum(u8) {
    run,
    step,
    /// Like `step`, but runs a `call` through to where it returns.
    step_over,
    /// A crash goes on past the instruction that faulted.
    skip,
    /// A crash goes on to the game's own crash handling.
    crash,
};

/// What a crash should do after `stopCrash`.
pub const Verdict = enum { resumed, crash };

pub const Freeze = enum(u8) {
    idle,
    frozen,
    /// Couldn't freeze the other threads. Tries again.
    failed,
};

pub const Options = struct {
    /// How long without a `beat` before everything stopped goes again.
    stall_ms: u32 = 2000,
    /// Leave our own module's threads running when freezing. Off in tests, where the game's are ours.
    keep_own: bool = true,
};

pub const max_breakpoints = 32;
/// More threads stopping at once than this just run on.
pub const max_paused = 16;
const max_ignored = 8;

/// DR6 bit for a trap flag step.
const step_bit: usize = 1 << 14;

const Record = struct {
    /// 0 if unused.
    address: std.atomic.Value(usize) = .init(0),
    stop: std.atomic.Value(Stop) = .init(.thread),
    hits: std.atomic.Value(u32) = .init(0),
    /// In the debug registers, or about to be.
    armed: std.atomic.Value(bool) = .init(false),
    // Changed by the thread changing breakpoints
    kind: Kind = .hardware,
    slot: ?watch.Slot = null,
    /// For `software`, keeps hooks and patches off the byte. The int3 is written by hand since
    /// exceptions rewrite it too and mustn't allocate.
    patch: ?*Patch = null,
    /// The byte the int3 replaced.
    original: u8 = 0,
    /// A step over's landing spot, only for this thread. 0 for a breakpoint.
    temp_thread: std.atomic.Value(u32) = .init(0),
    temp_stop: Stop = .thread,

    fn isTemp(self: *const Record) bool {
        return self.temp_thread.load(.acquire) != 0;
    }
};

const SlotState = enum(u8) { free, taken, paused };
const Command = enum(u8) { none, run, step, step_over, skip, crash };

const PauseSlot = struct {
    state: std.atomic.Value(SlotState) = .init(.free),
    command: std.atomic.Value(Command) = .init(.none),
    /// `info.cpu` was changed by `setCpu`, so it goes back into the thread when it goes.
    edited: std.atomic.Value(bool) = .init(false),
    /// Guards `info` against readers while it's filled in or freed.
    lock: sys.sync.RwLock = .{},
    info: Paused = undefined,
};

allocator: std.mem.Allocator,
options: Options,
records: [max_breakpoints]Record = @splat(.{}),
slots: [max_paused]PauseSlot = @splat(.{}),
ignored: [max_ignored]std.atomic.Value(u32) = @splat(.init(0)),

started: bool = false,
subscription: ?exceptions.Subscription = null,
monitor: ?std.Thread = null,
monitor_thread: std.atomic.Value(u32) = .init(0),
own: sys.thread.CodeRange = .{ .start = 0, .len = 0 },

closing: std.atomic.Value(bool) = .init(false),
/// Everything stopped goes again, and nothing new stops, until it's all running.
rescuing: std.atomic.Value(bool) = .init(false),
rescue_count: std.atomic.Value(u32) = .init(0),
heartbeat: std.atomic.Value(u32) = .init(0),
/// Threads in `pause`.
waiting: std.atomic.Value(u32) = .init(0),
/// Threads running one instruction, and those of them that stopped everything.
stepping: std.atomic.Value(u32) = .init(0),
stepping_all: std.atomic.Value(u32) = .init(0),
/// Threads running the instruction under a software breakpoint before its int3 goes back.
rearming: std.atomic.Value(u32) = .init(0),
/// Software breakpoints taken out lately, so a thread already on its way to one isn't a crash.
removed: [16]std.atomic.Value(usize) = @splat(.init(0)),
removed_next: std.atomic.Value(u32) = .init(0),
next_id: std.atomic.Value(u32) = .init(0),
/// Counts stops, so a UI can spot a new one.
stops: std.atomic.Value(u32) = .init(0),
freeze: std.atomic.Value(Freeze) = .init(.idle),

/// The debugger this thread is stepping for, if it is.
threadlocal var stepping_for: ?*Debugger = null;
threadlocal var step_stop: Stop = .thread;
/// The software breakpoint this thread's running the real instruction of, to put its int3 back after.
threadlocal var rearm_for: ?*Debugger = null;
threadlocal var rearm_at: usize = 0;

const int3: u8 = 0xCC;

pub fn init(allocator: std.mem.Allocator, options: Options) Debugger {
    return .{ .allocator = allocator, .options = options };
}

/// Lets every stopped thread go, removes the breakpoints and stops handling exceptions.
pub fn deinit(self: *Debugger) void {
    if (!self.started) return;
    self.closing.store(true, .release);
    if (self.monitor) |m| m.join();
    self.monitor = null;
    for (&self.records) |*r| {
        self.disarm(r);
        r.address.store(0, .release);
    }
    while (self.waiting.load(.acquire) != 0) sys.thread.sleepMs(1);
    // A step lands after one instruction, unless that's a call into the kernel that waits
    var tries: u32 = 0;
    while (self.stepping.load(.acquire) + self.rearming.load(.acquire) != 0 and tries < 500) : (tries += 1) sys.thread.sleepMs(1);
    if (self.stepping.load(.acquire) + self.rearming.load(.acquire) != 0) leftovers.keep();
    self.subscription.?.unsubscribe();
    self.subscription = null;
    watch.deinit();
    self.started = false;
}

fn start(self: *Debugger) !void {
    if (self.started) return;
    try watch.init(self.allocator);
    errdefer watch.deinit();
    // Ahead of `watch`, which would report our hits as its own
    self.subscription = try exceptions.subscribeUnscopedOpts(self, onException, .{ .priority = 10 });
    errdefer {
        self.subscription.?.unsubscribe();
        self.subscription = null;
    }
    const base = sys.module.selfBase();
    self.own = .{ .start = base, .len = sys.module.imageSize(base) catch 0 };
    self.monitor = try std.Thread.spawn(.{}, monitorMain, .{self});
    while (self.monitor_thread.load(.acquire) == 0) sys.thread.sleepMs(1);
    self.started = true;
}

/// Enabled. Change breakpoints from one thread at a time.
pub fn add(self: *Debugger, address: usize, kind: Kind, stop: Stop) !void {
    if (address <= reserved) return error.InvalidAddress;
    if (self.find(address) != null or self.findTemp(address) != null) return error.AlreadySet;
    const r = self.reserve() orelse return error.TooManyBreakpoints;
    errdefer r.address.store(0, .release);
    try self.start();
    r.kind = kind;
    r.stop.store(stop, .release);
    r.hits.store(0, .release);
    r.address.store(address, .release);
    self.arm(r) catch |err| {
        r.address.store(0, .release);
        return err;
    };
}

pub fn remove(self: *Debugger, address: usize) void {
    const r = self.find(address) orelse return;
    self.disarm(r);
    r.address.store(0, .release);
}

/// Off frees its debug register, or for software puts the byte back.
pub fn setEnabled(self: *Debugger, address: usize, on: bool) !void {
    const r = self.find(address) orelse return error.NotSet;
    if (on) try self.arm(r) else self.disarm(r);
}

pub fn setStop(self: *Debugger, address: usize, stop: Stop) void {
    const r = self.find(address) orelse return;
    r.stop.store(stop, .release);
}

pub fn get(self: *const Debugger, address: usize) ?Breakpoint {
    const r = @constCast(self).find(address) orelse return null;
    return describe(r);
}

/// As many as fit. Returns how many.
pub fn list(self: *const Debugger, out: []Breakpoint) usize {
    var n: usize = 0;
    for (&self.records) |*r| {
        if (n == out.len) break;
        if (r.address.load(.acquire) <= reserved or r.isTemp()) continue;
        out[n] = describe(r);
        n += 1;
    }
    return n;
}

fn describe(r: *const Record) Breakpoint {
    return .{
        .address = r.address.load(.acquire),
        .kind = r.kind,
        .stop = r.stop.load(.acquire),
        .enabled = r.armed.load(.acquire),
        .hits = r.hits.load(.acquire),
    };
}

/// Holds a record while it's filled in, so nothing finds it half done.
const reserved: usize = 1;

/// Any thread, even inside an exception.
fn reserve(self: *Debugger) ?*Record {
    for (&self.records) |*r| {
        if (r.address.cmpxchgStrong(0, reserved, .acq_rel, .acquire) == null) return r;
    }
    return null;
}

/// A breakpoint, not a step over's landing spot.
fn find(self: *Debugger, address: usize) ?*Record {
    if (address <= reserved) return null;
    for (&self.records) |*r| if (r.address.load(.acquire) == address and !r.isTemp()) return r;
    return null;
}

fn findTemp(self: *Debugger, address: usize) ?*Record {
    if (address <= reserved) return null;
    for (&self.records) |*r| if (r.address.load(.acquire) == address and r.isTemp()) return r;
    return null;
}

fn arm(self: *Debugger, r: *Record) !void {
    switch (r.kind) {
        .hardware => {
            if (r.slot != null) return;
            r.armed.store(true, .release);
            r.slot = watch.add(.{ .address = r.address.load(.acquire), .len = 1, .on = .execute }) catch |err| {
                r.armed.store(false, .release);
                return switch (err) {
                    error.NoFreeSlot => error.NoFreeDebugRegister,
                    else => err,
                };
            };
        },
        .software => try self.armSoftware(r),
    }
}

fn armSoftware(_: *Debugger, r: *Record) !void {
    if (r.patch != null) return;
    if (!registry.ready()) return error.HooksNotReady;
    const address = r.address.load(.acquire);
    // Made but never enabled, it only keeps hooks and patches off the byte
    const p = try Patch.create(address, &.{int3}, .{});
    r.original = p.original[0];
    r.patch = p;
    r.armed.store(true, .release);
    sys.memory.writeCode(address, &.{int3}) catch |err| {
        r.armed.store(false, .release);
        r.patch = null;
        p.destroy();
        return err;
    };
}

fn disarm(self: *Debugger, r: *Record) void {
    r.armed.store(false, .release);
    switch (r.kind) {
        .hardware => {
            const slot = r.slot orelse return;
            watch.remove(slot);
            r.slot = null;
        },
        .software => {
            if (r.isTemp()) {
                self.waitRearms();
                self.noteRemoved(r.address.load(.acquire));
                sys.memory.writeCode(r.address.load(.acquire), &.{r.original}) catch {};
                r.temp_thread.store(0, .release);
                return;
            }
            const p = r.patch orelse return;
            self.waitRearms();
            self.noteRemoved(r.address.load(.acquire));
            sys.memory.writeCode(r.address.load(.acquire), &.{r.original}) catch {};
            r.patch = null;
            p.destroy();
        },
    }
}
/// So one about to put its int3 back sees it's off first. Not from a thread that's mid-rearm itself.
fn waitRearms(self: *Debugger) void {
    var tries: u32 = 0;
    while (self.rearming.load(.acquire) != 0 and rearm_for == null and tries < 200) : (tries += 1) sys.thread.sleepMs(1);
}

/// Puts breakpoints on threads started since. Every second or so.
pub fn refresh(self: *Debugger) void {
    if (self.started) watch.refresh();
}

/// Never stops and never gets frozen, like the UI's own thread.
pub fn ignoreThread(self: *Debugger, id: u32) void {
    for (&self.ignored) |*slot| {
        if (slot.load(.acquire) == id) return;
        if (slot.cmpxchgStrong(0, id, .acq_rel, .acquire) == null) return;
    }
}

fn isIgnored(self: *const Debugger, id: u32) bool {
    for (&self.ignored) |*slot| if (slot.load(.acquire) == id) return true;
    return false;
}

/// Call every UI frame. Without it, stops get let go after `stall_ms`.
pub fn beat(self: *Debugger) void {
    _ = self.heartbeat.fetchAdd(1, .release);
}

/// As many as fit. Returns how many.
pub fn paused(self: *Debugger, out: []Paused) usize {
    var n: usize = 0;
    for (&self.slots) |*slot| {
        if (n == out.len) break;
        slot.lock.lockShared();
        defer slot.lock.unlockShared();
        if (slot.state.load(.acquire) != .paused) continue;
        out[n] = slot.info;
        n += 1;
    }
    return n;
}

/// False if it's not stopped any more.
pub fn resumeThread(self: *Debugger, id: u32, how: How) bool {
    for (&self.slots) |*slot| {
        slot.lock.lockShared();
        defer slot.lock.unlockShared();
        if (slot.state.load(.acquire) != .paused or slot.info.id != id) continue;
        const command: Command = switch (how) {
            .run => .run,
            .step => .step,
            .step_over => .step_over,
            .skip => .skip,
            .crash => .crash,
        };
        return slot.command.cmpxchgStrong(.none, command, .acq_rel, .acquire) == null;
    }
    return false;
}

pub fn resumeAll(self: *Debugger) void {
    for (&self.slots) |*slot| {
        if (slot.state.load(.acquire) == .paused) _ = slot.command.cmpxchgStrong(.none, .run, .acq_rel, .acquire);
    }
}

pub const SetCpuError = error{
    /// Gone, or already told to go.
    NotStopped,
    /// Nothing there to run.
    Unreadable,
};

/// Changes a stopped thread's registers, applied on resume and shown in `paused` till then.
pub fn setCpu(self: *Debugger, id: u32, cpu: CpuContext) SetCpuError!void {
    if (!sys.memory.isReadable(cpu.ip(), 1)) return error.Unreadable;
    for (&self.slots) |*slot| {
        slot.lock.lock();
        defer slot.lock.unlock();
        if (slot.state.load(.acquire) != .paused or slot.info.id != id) continue;
        if (slot.command.load(.acquire) != .none) return error.NotStopped;
        slot.info.cpu = cpu;
        slot.edited.store(true, .release);
        return;
    }
    return error.NotStopped;
}

/// Moves a stopped thread to `address`, like set next statement. The stack is left as is.
pub fn setIp(self: *Debugger, id: u32, address: usize) SetCpuError!void {
    var threads: [max_paused]Paused = undefined;
    for (threads[0..self.paused(&threads)]) |p| {
        if (p.id != id) continue;
        var cpu = p.cpu;
        cpu.setIp(address);
        return self.setCpu(id, cpu);
    }
    return error.NotStopped;
}

pub fn stopCount(self: *const Debugger) u32 {
    return self.stops.load(.acquire);
}

/// Times everything was let go because the UI stopped beating.
pub fn rescues(self: *const Debugger) u32 {
    return self.rescue_count.load(.acquire);
}

pub fn freezeState(self: *const Debugger) Freeze {
    return self.freeze.load(.acquire);
}

fn onException(self: *Debugger, e: *Exception) ?exceptions.Action {
    switch (e.kind) {
        .breakpoint => return self.onInt3(e),
        .single_step => {},
        else => return null,
    }
    var ours: usize = 0;
    var stop: ?Stop = null;
    var reason: Reason = .breakpoint;

    const traced = isTrace(e);
    // The real instruction under a software breakpoint ran, so its int3 goes back
    if (traced and rearm_for == self) {
        self.rearm();
        ours |= step_bit;
        if (stepping_for != self) e.setSingleStep(false);
    }
    if (traced and stepping_for == self) {
        stepping_for = null;
        e.setSingleStep(false);
        ours |= step_bit;
        stop = step_stop;
        reason = .step;
        if (step_stop == .all) _ = self.stepping_all.fetchSub(1, .acq_rel);
        _ = self.stepping.fetchSub(1, .acq_rel);
    }
    for (0..watch.max) |i| {
        const bit = @as(usize, 1) << @intCast(i);
        if (e.debug.status & bit == 0) continue;
        // Execute slots only. Data watches at the same address are `watch`'s
        if ((e.debug.control >> @intCast(16 + i * 4)) & 0b11 != 0) continue;
        const r = self.find(e.debug.address[i]) orelse continue;
        ours |= bit;
        // Or it'd hit again as soon as it resumes
        e.skipBreakpointOnce();
        if (!r.armed.load(.acquire)) continue;
        _ = r.hits.fetchAdd(1, .monotonic);
        const s = r.stop.load(.acquire);
        // A step that lands on a breakpoint stops as the breakpoint
        if (s != .none) {
            stop = s;
            reason = .breakpoint;
        }
    }
    // A step that lands on a software breakpoint stops as it too
    if (reason == .step) if (self.find(e.cpu.ip())) |r| if (r.kind == .software and r.armed.load(.acquire)) {
        _ = r.hits.fetchAdd(1, .monotonic);
        const s = r.stop.load(.acquire);
        if (s != .none) {
            stop = s;
            reason = .breakpoint;
        }
    };
    if (ours == 0) return null;
    e.debug.status &= ~ours;

    if (stop) |s| if (s != .none and self.mayStop()) {
        _ = self.pause(e, s, reason, null);
        // It stopped here already, so our int3 here only counts a hit
        self.stepPastInt3(e);
    };

    // It resumes with these. Breakpoints may have changed while it waited
    const regs = watch.registers();
    e.debug.address = regs.address;
    e.debug.control = regs.control;
    // A data watch at the same moment is `watch`'s to report
    return if (e.debug.status & 0xF != 0) null else .handled;
}

/// A trap flag step. Windows omits debug registers when none are set, so no bits means trap flag.
fn isTrace(e: *const Exception) bool {
    return e.debug.status & step_bit != 0 or e.debug.status & 0xF == 0;
}

fn onInt3(self: *Debugger, e: *Exception) ?exceptions.Action {
    const ip = e.cpu.ip();
    if (self.findTemp(ip)) |r| {
        if (r.temp_thread.load(.acquire) == std.Thread.getCurrentId()) {
            // Its step over came back. The spot's done with
            const stop = r.temp_stop;
            self.disarm(r);
            r.address.store(0, .release);
            if (self.mayStop()) _ = self.pause(e, stop, .step, null);
        }
        // Someone else's step over spot runs on
        self.stepPastInt3(e);
        return .handled;
    }
    const r = self.find(ip) orelse {
        // Taken out after this thread hit it. The byte's back, so run it
        if (self.wasRemoved(ip) and @as(*const volatile u8, @ptrFromInt(ip)).* != int3) return .handled;
        return null;
    };
    if (r.kind != .software) return null;
    if (r.armed.load(.acquire)) {
        _ = r.hits.fetchAdd(1, .monotonic);
        const s = r.stop.load(.acquire);
        if (s != .none and self.mayStop()) _ = self.pause(e, s, .breakpoint, null);
    }
    // Disarmed on the way here means the byte's back, or about to be
    self.stepPastInt3(e);
    return .handled;
}

/// If it's on an int3 of ours, puts the real byte back for one instruction, then the int3.
fn stepPastInt3(self: *Debugger, e: *Exception) void {
    if (rearm_for != null) return;
    const r = self.softwareAt(e.cpu.ip()) orelse return;
    _ = self.rearming.fetchAdd(1, .acq_rel);
    if (!r.armed.load(.acquire)) {
        _ = self.rearming.fetchSub(1, .acq_rel);
        return;
    }
    sys.memory.writeCode(e.cpu.ip(), &.{r.original}) catch {
        _ = self.rearming.fetchSub(1, .acq_rel);
        return;
    };
    rearm_for = self;
    rearm_at = e.cpu.ip();
    e.setSingleStep(true);
}

/// After `stepPastInt3`'s instruction ran.
fn rearm(self: *Debugger) void {
    defer {
        rearm_for = null;
        _ = self.rearming.fetchSub(1, .acq_rel);
    }
    // Not if it's been taken out meanwhile
    if (self.softwareAt(rearm_at) == null) return;
    sys.memory.writeCode(rearm_at, &.{int3}) catch {};
}

/// This process's memory with our int3s read as the original bytes. Writes under one keep the int3.
pub fn memory(self: *Debugger) Memory {
    return .{ .context = self, .vtable = &memory_vtable };
}

const memory_vtable: Memory.VTable = .{
    .read = memoryRead,
    .write = memoryWrite,
    .region_from = memoryRegionFrom,
    .read_in_region = memoryReadInRegion,
};

fn memoryRead(ctx: ?*anyopaque, address: usize, out: []u8) Memory.Error!void {
    const self: *Debugger = @ptrCast(@alignCast(ctx.?));
    try Memory.local.read(address, out);
    self.hideInt3s(address, out);
}

fn memoryReadInRegion(ctx: ?*anyopaque, address: usize, out: []u8) Memory.Error!void {
    const self: *Debugger = @ptrCast(@alignCast(ctx.?));
    try Memory.local.readInRegion(address, out);
    self.hideInt3s(address, out);
}

fn memoryRegionFrom(_: ?*anyopaque, address: usize) ?Memory.Region {
    return Memory.local.regionFrom(address);
}

fn memoryWrite(ctx: ?*anyopaque, address: usize, bytes: []const u8) Memory.Error!void {
    const self: *Debugger = @ptrCast(@alignCast(ctx.?));
    var done: usize = 0;
    while (done < bytes.len) {
        var chunk: [256]u8 = undefined;
        const n = @min(chunk.len, bytes.len - done);
        const at = address + done;
        @memcpy(chunk[0..n], bytes[done..][0..n]);
        for (&self.records) |*r| {
            const where = r.address.load(.acquire);
            if (r.kind != .software or !r.armed.load(.acquire) or where <= reserved) continue;
            if (where < at or where - at >= n) continue;
            r.original = chunk[where - at];
            chunk[where - at] = int3;
        }
        try Memory.local.write(at, chunk[0..n]);
        done += n;
    }
}

/// Puts the real bytes back in `out`, read from `address`.
fn hideInt3s(self: *Debugger, address: usize, out: []u8) void {
    for (&self.records) |*r| {
        const where = r.address.load(.acquire);
        if (r.kind != .software or !r.armed.load(.acquire) or where <= reserved) continue;
        if (where < address or where - address >= out.len) continue;
        // Mid step past it, the real byte's there already
        if (out[where - address] == int3) out[where - address] = r.original;
    }
}

/// An armed software breakpoint or step over spot.
fn softwareAt(self: *Debugger, address: usize) ?*Record {
    if (address <= reserved) return null;
    for (&self.records) |*r| {
        if (r.address.load(.acquire) == address and r.kind == .software and r.armed.load(.acquire)) return r;
    }
    return null;
}

fn noteRemoved(self: *Debugger, address: usize) void {
    const i = self.removed_next.fetchAdd(1, .monotonic) % @as(u32, self.removed.len);
    self.removed[i].store(address, .release);
}

fn wasRemoved(self: *Debugger, address: usize) bool {
    for (&self.removed) |*a| if (a.load(.acquire) == address) return true;
    return false;
}

/// For a `call`, a one-off breakpoint after it just for this thread, and true.
fn placeStepOver(self: *Debugger, e: *const Exception, stop: Stop) bool {
    const d = self.decodeAt(e.cpu.ip()) orelse return false;
    if (!d.isCall()) return false;
    const after = e.cpu.ip() + d.len;
    // A breakpoint already there stops it, or it's simpler to step into the call
    if (self.find(after)) |r| return r.armed.load(.acquire) and r.stop.load(.acquire) != .none;
    if (self.findTemp(after) != null or !sys.memory.isReadable(after, 1)) return false;
    const r = self.reserve() orelse return false;
    r.kind = .software;
    r.patch = null;
    r.slot = null;
    r.original = @as(*const volatile u8, @ptrFromInt(after)).*;
    r.temp_stop = stop;
    r.stop.store(.thread, .release);
    r.hits.store(0, .release);
    r.temp_thread.store(std.Thread.getCurrentId(), .release);
    r.address.store(after, .release);
    r.armed.store(true, .release);
    sys.memory.writeCode(after, &.{int3}) catch {
        r.armed.store(false, .release);
        r.temp_thread.store(0, .release);
        r.address.store(0, .release);
        return false;
    };
    return true;
}

/// With an int3 of ours taken out, so it's the real instruction.
fn decodeAt(self: *Debugger, ip: usize) ?arch.insn.DecodedInsn {
    var bytes: [16]u8 = undefined;
    if (!sys.memory.readSafe(ip, &bytes)) return arch.insn.decode(ip) catch null;
    if (self.softwareAt(ip)) |r| bytes[0] = r.original;
    return arch.insn.decodeBytes(&bytes, ip) catch null;
}

/// Step over spots this thread never got back to, like when something threw past them.
fn dropTemps(self: *Debugger, thread: u32) void {
    for (&self.records) |*r| {
        if (r.temp_thread.load(.acquire) != thread) continue;
        self.disarm(r);
        r.address.store(0, .release);
    }
}

fn mayStop(self: *const Debugger) bool {
    return !self.closing.load(.acquire) and !self.rescuing.load(.acquire) and
        !self.isIgnored(std.Thread.getCurrentId()) and self.monitor_thread.load(.acquire) != std.Thread.getCurrentId();
}

/// Waits inside the exception until told to go. No allocating or logging, it could hold any lock.
/// Null if let go untold, like when the UI stalls or the debugger closes.
fn pause(self: *Debugger, e: *Exception, stop: Stop, reason: Reason, crash: ?Crash) ?Command {
    _ = self.waiting.fetchAdd(1, .acq_rel);
    defer _ = self.waiting.fetchSub(1, .acq_rel);
    const slot = for (&self.slots) |*s| {
        if (s.state.cmpxchgStrong(.free, .taken, .acq_rel, .acquire) == null) break s;
    } else return null;

    slot.lock.lock();
    slot.info = .{
        .id = self.next_id.fetchAdd(1, .monotonic) +% 1,
        .thread_id = std.Thread.getCurrentId(),
        .reason = reason,
        .stop = stop,
        .cpu = e.cpu,
        .since_ms = sys.thread.tickMs(),
        .crash = crash,
    };
    slot.command.store(.none, .release);
    slot.edited.store(false, .release);
    slot.state.store(.paused, .release);
    slot.lock.unlock();
    _ = self.stops.fetchAdd(1, .acq_rel);

    var beat_seen = self.heartbeat.load(.acquire);
    var beat_at = sys.thread.tickMs();
    var command: ?Command = while (true) {
        const c = slot.command.load(.acquire);
        if (c != .none) break c;
        if (self.closing.load(.acquire) or self.rescuing.load(.acquire)) break null;
        sys.thread.sleepMs(1);
        const now = sys.thread.tickMs();
        const b = self.heartbeat.load(.acquire);
        if (b != beat_seen) {
            beat_seen = b;
            beat_at = now;
        } else if (now -% beat_at > self.options.stall_ms) {
            self.rescue();
            break null;
        }
    };

    self.dropTemps(std.Thread.getCurrentId());
    // Before anything else looks at where it is, so a step or step over goes from there
    if (slot.edited.load(.acquire)) {
        slot.lock.lockShared();
        e.cpu = slot.info.cpu;
        slot.lock.unlockShared();
    }
    if (command == .step_over) command = if (reason != .crash and self.placeStepOver(e, stop)) .run else .step;
    // Counted as stepping before unstopping so a freeze never lifts between. Crashes can't step
    if (command == .step and reason != .crash and !self.closing.load(.acquire)) {
        _ = self.stepping.fetchAdd(1, .acq_rel);
        if (stop == .all) _ = self.stepping_all.fetchAdd(1, .acq_rel);
        stepping_for = self;
        step_stop = stop;
        e.setSingleStep(true);
    }
    slot.lock.lock();
    slot.state.store(.free, .release);
    slot.lock.unlock();
    return command;
}

/// Starts its thread now, which allocates, so a crash later doesn't have to.
pub fn prepare(self: *Debugger) !void {
    try self.start();
}

/// Whether `stopCrash` would stop it, rather than say crash. Not on the UI's own thread, say.
pub fn canStopCrash(self: *const Debugger) bool {
    return self.started and self.mayStop();
}

/// For a crash's last-chance handler, on the crashing thread. Stops it with everything frozen till the
/// UI says. `e` comes back changed for `skip`. Crash if it can't stop or the UI stalled.
pub fn stopCrash(self: *Debugger, e: *Exception) Verdict {
    if (!self.started or !self.mayStop()) return .crash;
    const command = self.pause(e, .all, .crash, .{ .code = e.code, .kind = e.kind, .fault = e.fault }) orelse return .crash;
    switch (command) {
        .none, .run, .step, .step_over => return .resumed,
        .crash => return .crash,
        .skip => {
            const len = instructionLength(e.cpu.ip()) orelse return .crash;
            e.cpu.setIp(e.cpu.ip() + len);
            return .resumed;
        },
    }
}

/// Null if it can't be read, like after a jump to nowhere.
fn instructionLength(ip: usize) ?usize {
    if (!sys.memory.isReadable(ip, 1)) return null;
    const decoded = arch.insn.decode(ip) catch return null;
    return decoded.len;
}

fn rescue(self: *Debugger) void {
    if (self.rescuing.swap(true, .acq_rel)) return;
    _ = self.rescue_count.fetchAdd(1, .acq_rel);
}

fn monitorMain(self: *Debugger) void {
    self.monitor_thread.store(std.Thread.getCurrentId(), .release);
    var guard: ?sys.thread.ThreadFreezeGuard = null;
    var beat_seen = self.heartbeat.load(.acquire);
    var beat_at = sys.thread.tickMs();
    while (!self.closing.load(.acquire)) {
        const want = !self.rescuing.load(.acquire) and self.wantsFreeze();
        if (want and guard == null) {
            if (sys.thread.freezeThreads(self.allocator, .{ .keep = .{ .ctx = self, .func = keep }, .loader_lock = true })) |g| {
                guard = g;
                self.freeze.store(.frozen, .release);
            } else |_| {
                self.freeze.store(.failed, .release);
                sys.thread.sleepMs(20);
            }
        } else if (!want) {
            if (guard) |*g| g.deinit();
            guard = null;
            self.freeze.store(.idle, .release);
        }

        // Nothing here allocates while frozen. A frozen thread may hold the heap's lock
        const now = sys.thread.tickMs();
        const b = self.heartbeat.load(.acquire);
        const holding = guard != null or self.waiting.load(.acquire) != 0;
        if (b != beat_seen or !holding) {
            beat_seen = b;
            beat_at = now;
        } else if (now -% beat_at > self.options.stall_ms) {
            self.rescue();
        }
        if (self.rescuing.load(.acquire) and guard == null and self.waiting.load(.acquire) == 0 and self.stepping_all.load(.acquire) == 0) {
            self.rescuing.store(false, .release);
        }
        sys.thread.sleepMs(2);
    }
    if (guard) |*g| g.deinit();
    self.freeze.store(.idle, .release);
}

fn wantsFreeze(self: *Debugger) bool {
    if (self.stepping_all.load(.acquire) != 0) return true;
    for (&self.slots) |*slot| {
        slot.lock.lockShared();
        defer slot.lock.unlockShared();
        if (slot.state.load(.acquire) == .paused and slot.info.stop == .all) return true;
    }
    return false;
}

/// A freeze leaves ignored, stopped and our threads, plus Windows' and the GPU driver's for the UI.
fn keep(ctx: ?*anyopaque, info: sys.thread.Info) bool {
    const self: *Debugger = @ptrCast(@alignCast(ctx.?));
    if (self.isIgnored(info.id)) return true;
    for (&self.slots) |*slot| {
        slot.lock.lockShared();
        defer slot.lock.unlockShared();
        if (slot.state.load(.acquire) == .paused and slot.info.thread_id == info.id) return true;
    }
    if (info.start == 0) return true;
    if (self.options.keep_own and self.own.contains(info.start)) return true;
    const base = sys.module.containingBase(info.start) orelse return false;
    var buf: [1024]u8 = undefined;
    const path = sys.module.pathOf(base, &buf) orelse return true;
    return sys.module.inSystemTree(path);
}

/// Steps still on their way when a debugger closes still trap, so this handler stays for good.
const leftovers = struct {
    var kept: std.atomic.Value(bool) = .init(false);
    var subscription: exceptions.Subscription = undefined;

    fn keep() void {
        if (kept.swap(true, .acq_rel)) return;
        exceptions.init(std.heap.page_allocator) catch return;
        subscription = exceptions.subscribeUnscopedOpts(&kept, onStep, .{ .priority = 10 }) catch return;
    }

    fn onStep(_: *std.atomic.Value(bool), e: *Exception) ?exceptions.Action {
        if (e.kind != .single_step or !isTrace(e) or (stepping_for == null and rearm_for == null)) return null;
        // Its debugger's gone, and its breakpoints with it, so no int3 goes back
        rearm_for = null;
        stepping_for = null;
        e.setSingleStep(false);
        e.debug.status &= ~step_bit;
        return .handled;
    }
};

const tests = struct {
    const testing = std.testing;

    var calls: std.atomic.Value(u32) = .init(0);

    /// A few instructions, so there's something to step through.
    noinline fn target(x: u32) u32 {
        _ = calls.fetchAdd(1, .monotonic);
        return x *% 3 +% 1;
    }

    fn address() usize {
        return @intFromPtr(&target);
    }

    /// Waits up to two seconds for a stop, beating like a UI.
    fn waitStop(d: *Debugger, after: u32) !Paused {
        var out: [max_paused]Paused = undefined;
        for (0..2000) |_| {
            d.beat();
            if (d.stopCount() != after and d.paused(&out) != 0) return out[0];
            sys.thread.sleepMs(1);
        }
        return error.TimedOut;
    }

    const Caller = struct {
        result: std.atomic.Value(u32) = .init(0),
        thread_id: std.atomic.Value(u32) = .init(0),
        go: std.atomic.Value(bool) = .init(false),

        fn run(self: *Caller) void {
            self.thread_id.store(std.Thread.getCurrentId(), .release);
            while (!self.go.load(.acquire)) sys.thread.sleepMs(1);
            self.result.store(target(4), .release);
        }

        /// A new thread hasn't got the breakpoints, so this gives them before it calls.
        fn start(self: *Caller, d: *Debugger) !std.Thread {
            const thread = try std.Thread.spawn(.{}, run, .{self});
            while (self.thread_id.load(.acquire) == 0) sys.thread.sleepMs(1);
            d.refresh();
            self.go.store(true, .release);
            return thread;
        }
    };

    test "counting and ignored threads" {
        var d: Debugger = .init(testing.allocator, .{});
        defer d.deinit();
        d.ignoreThread(std.Thread.getCurrentId());
        try d.add(address(), .hardware, .none);
        try testing.expectError(error.AlreadySet, d.add(address(), .hardware, .thread));

        for (0..3) |_| _ = target(1);
        try testing.expectEqual(3, d.get(address()).?.hits);

        // Stopping, but not this thread
        d.setStop(address(), .thread);
        try testing.expectEqual(4, target(1));
        try testing.expectEqual(4, d.get(address()).?.hits);
        try testing.expectEqual(0, d.stopCount());

        try d.setEnabled(address(), false);
        _ = target(1);
        try testing.expectEqual(4, d.get(address()).?.hits);
        var all: [4]Breakpoint = undefined;
        try testing.expectEqual(1, d.list(&all));
        try testing.expect(!all[0].enabled);
        d.remove(address());
        try testing.expectEqual(0, d.list(&all));
    }

    test "stop and step" {
        var d: Debugger = .init(testing.allocator, .{});
        defer d.deinit();
        d.ignoreThread(std.Thread.getCurrentId());
        try d.add(address(), .hardware, .thread);

        var caller: Caller = .{};
        const thread = try caller.start(&d);
        const hit = try waitStop(&d, 0);
        try testing.expectEqual(address(), hit.cpu.ip());
        try testing.expectEqual(.breakpoint, hit.reason);
        try testing.expectEqual(caller.thread_id.load(.acquire), hit.thread_id);
        try testing.expectEqual(0, caller.result.load(.acquire));

        try testing.expect(d.resumeThread(hit.id, .step));
        try testing.expect(!d.resumeThread(hit.id, .run));
        const stepped = try waitStop(&d, 1);
        try testing.expectEqual(.step, stepped.reason);
        try testing.expect(stepped.cpu.ip() != hit.cpu.ip());
        try testing.expect(stepped.cpu.ip() - hit.cpu.ip() <= 16);

        try testing.expect(d.resumeThread(stepped.id, .run));
        thread.join();
        try testing.expectEqual(13, caller.result.load(.acquire));
        try testing.expectEqual(0, d.rescues());
    }

    test "stop all freezes others" {
        var d: Debugger = .init(testing.allocator, .{ .keep_own = false });
        defer d.deinit();
        d.ignoreThread(std.Thread.getCurrentId());
        try d.add(address(), .hardware, .all);

        const Spinner = struct {
            ticks: std.atomic.Value(u32) = .init(0),
            stop: std.atomic.Value(bool) = .init(false),
            fn run(self: *@This()) void {
                while (!self.stop.load(.acquire)) {
                    _ = self.ticks.fetchAdd(1, .monotonic);
                    std.atomic.spinLoopHint();
                }
            }
        };
        var spinner: Spinner = .{};
        const spinning = try std.Thread.spawn(.{}, Spinner.run, .{&spinner});
        defer {
            spinner.stop.store(true, .release);
            spinning.join();
        }

        var caller: Caller = .{};
        const thread = try caller.start(&d);
        const hit = try waitStop(&d, 0);
        for (0..2000) |_| {
            d.beat();
            if (d.freezeState() == .frozen) break;
            sys.thread.sleepMs(1);
        }
        try testing.expectEqual(.frozen, d.freezeState());
        const before = spinner.ticks.load(.monotonic);
        for (0..10) |_| {
            d.beat();
            sys.thread.sleepMs(2);
        }
        try testing.expectEqual(before, spinner.ticks.load(.monotonic));

        try testing.expect(d.resumeThread(hit.id, .run));
        thread.join();
        for (0..2000) |_| {
            if (spinner.ticks.load(.monotonic) != before) break;
            sys.thread.sleepMs(1);
        }
        try testing.expect(spinner.ticks.load(.monotonic) != before);
    }

    test "resumes without a UI" {
        var d: Debugger = .init(testing.allocator, .{ .stall_ms = 100 });
        defer d.deinit();
        d.ignoreThread(std.Thread.getCurrentId());
        try d.add(address(), .hardware, .thread);
        var caller: Caller = .{};
        const thread = try caller.start(&d);
        thread.join();
        try testing.expectEqual(13, caller.result.load(.acquire));
        try testing.expectEqual(1, d.stopCount());
        try testing.expectEqual(1, d.rescues());
    }

    /// Calls `target`, so there's a call to step over.
    noinline fn outer(x: u32) u32 {
        return target(x) +% 1;
    }

    fn firstCall(from: usize) !usize {
        var at = from;
        for (0..64) |_| {
            const d = try arch.insn.decode(at);
            if (d.isCall()) return at;
            at += d.len;
        }
        return error.NoCall;
    }

    const OuterCaller = struct {
        result: std.atomic.Value(u32) = .init(0),
        thread_id: std.atomic.Value(u32) = .init(0),
        go: std.atomic.Value(bool) = .init(false),

        fn run(self: *OuterCaller) void {
            self.thread_id.store(std.Thread.getCurrentId(), .release);
            while (!self.go.load(.acquire)) sys.thread.sleepMs(1);
            self.result.store(outer(4), .release);
        }

        /// Gives a new thread the debug registers before it calls.
        fn start(self: *OuterCaller, d: *Debugger) !std.Thread {
            const thread = try std.Thread.spawn(.{}, run, .{self});
            while (self.thread_id.load(.acquire) == 0) sys.thread.sleepMs(1);
            d.refresh();
            self.go.store(true, .release);
            return thread;
        }
    };

    fn byteAt(at: usize) u8 {
        return @as(*const volatile u8, @ptrFromInt(at)).*;
    }

    test "software breakpoints, and stepping over a call" {
        try registry.init(testing.allocator);
        defer registry.deinit();
        var d: Debugger = .init(testing.allocator, .{});
        defer d.deinit();
        d.ignoreThread(std.Thread.getCurrentId());

        const call_at = try firstCall(@intFromPtr(&outer));
        const call_len = (try arch.insn.decode(call_at)).len;
        const before = byteAt(call_at);
        try d.add(call_at, .software, .thread);
        try testing.expectEqual(int3, byteAt(call_at));
        // Viewers see the real code
        var seen: [3]u8 = undefined;
        try d.memory().read(call_at - 1, &seen);
        try testing.expectEqual(before, seen[1]);
        // A write under it keeps the int3 and changes what goes back
        try d.memory().write(call_at, &.{before});
        try testing.expectEqual(int3, byteAt(call_at));
        try testing.expectEqual(before, try d.memory().load(u8, call_at));
        // Hooks and patches keep off it
        try testing.expectError(error.AlreadyHooked, Patch.create(call_at, &.{0x90}, .{}));

        var caller: OuterCaller = .{};
        const thread = try caller.start(&d);
        const hit = try waitStop(&d, 0);
        try testing.expectEqual(call_at, hit.cpu.ip());
        try testing.expectEqual(.breakpoint, hit.reason);

        const calls_before = calls.load(.monotonic);
        try testing.expect(d.resumeThread(hit.id, .step_over));
        const over = try waitStop(&d, 1);
        try testing.expectEqual(.step, over.reason);
        try testing.expectEqual(call_at + call_len, over.cpu.ip());
        try testing.expectEqual(calls_before + 1, calls.load(.monotonic));
        // Its int3's back once the real call ran
        try testing.expectEqual(int3, byteAt(call_at));
        try testing.expectEqual(int3, byteAt(call_at));
        // The landing spot's gone
        try testing.expect(byteAt(over.cpu.ip()) != int3 or d.findTemp(over.cpu.ip()) == null);

        // Not a call, so one instruction
        try testing.expect(d.resumeThread(over.id, .step_over));
        const next = try waitStop(&d, 2);
        try testing.expect(next.cpu.ip() > over.cpu.ip() and next.cpu.ip() - over.cpu.ip() <= 16);
        try testing.expect(d.resumeThread(next.id, .run));
        thread.join();
        try testing.expectEqual(14, caller.result.load(.acquire));

        // An ignored thread just counts it, and it keeps working after
        try testing.expectEqual(14, outer(4));
        try testing.expectEqual(14, outer(4));
        try testing.expectEqual(3, d.get(call_at).?.hits);

        d.remove(call_at);
        try testing.expectEqual(before, byteAt(call_at));
        try testing.expectEqual(14, outer(4));
        // Hooks can have it now
        const patch = try Patch.create(call_at, &.{0x90}, .{});
        patch.destroy();
    }

    test "set ip skips code" {
        try registry.init(testing.allocator);
        defer registry.deinit();
        var d: Debugger = .init(testing.allocator, .{});
        defer d.deinit();
        d.ignoreThread(std.Thread.getCurrentId());
        const call_at = try firstCall(@intFromPtr(&outer));
        const after = call_at + (try arch.insn.decode(call_at)).len;
        try d.add(call_at, .hardware, .thread);

        var caller: OuterCaller = .{};
        const thread = try caller.start(&d);
        const hit = try waitStop(&d, 0);
        try testing.expectEqual(call_at, hit.cpu.ip());
        try testing.expectError(error.Unreadable, d.setIp(hit.id, 0x10));
        try d.setIp(hit.id, after);
        var out: [max_paused]Paused = undefined;
        try testing.expectEqual(1, d.paused(&out));
        try testing.expectEqual(after, out[0].cpu.ip());

        // It carries on past the call, so `target` never runs
        const calls_before = calls.load(.monotonic);
        try testing.expect(d.resumeThread(hit.id, .run));
        thread.join();
        try testing.expectEqual(calls_before, calls.load(.monotonic));
        try testing.expectError(error.NotStopped, d.setIp(hit.id, after));
    }

    test "step over from a hardware breakpoint" {
        try registry.init(testing.allocator);
        defer registry.deinit();
        var d: Debugger = .init(testing.allocator, .{});
        defer d.deinit();
        d.ignoreThread(std.Thread.getCurrentId());
        const call_at = try firstCall(@intFromPtr(&outer));
        try d.add(call_at, .hardware, .thread);

        var caller: OuterCaller = .{};
        const thread = try caller.start(&d);
        const hit = try waitStop(&d, 0);
        try testing.expect(d.resumeThread(hit.id, .step_over));
        const over = try waitStop(&d, 1);
        try testing.expectEqual(.step, over.reason);
        try testing.expectEqual(call_at + (try arch.insn.decode(call_at)).len, over.cpu.ip());
        try testing.expect(d.resumeThread(over.id, .run));
        thread.join();
        try testing.expectEqual(14, caller.result.load(.acquire));
    }

    const Crasher = struct {
        e: Exception,
        /// Read after joining.
        verdict: ?Verdict = null,

        fn run(self: *Crasher, d: *Debugger) void {
            self.verdict = d.stopCrash(&self.e);
        }

        fn at(ip: usize) Crasher {
            var cpu = std.mem.zeroes(CpuContext);
            cpu.setIp(ip);
            return .{ .e = .{
                .kind = .access_violation,
                .code = 0xC0000005,
                .fault = .{ .access = .read, .address = 0x10 },
                .cpu = cpu,
            } };
        }
    };

    test "crashes stop until told what to do" {
        var d: Debugger = .init(testing.allocator, .{ .keep_own = false });
        defer d.deinit();
        d.ignoreThread(std.Thread.getCurrentId());
        // Not started, so it can't stop, so it crashes
        var early: Crasher = .at(address());
        try testing.expectEqual(.crash, d.stopCrash(&early.e));
        try d.prepare();

        var skipping: Crasher = .at(address());
        var thread = try std.Thread.spawn(.{}, Crasher.run, .{ &skipping, &d });
        const stop = try waitStop(&d, 0);
        try testing.expectEqual(.crash, stop.reason);
        try testing.expectEqual(0xC0000005, stop.crash.?.code);
        try testing.expectEqual(0x10, stop.crash.?.fault.?.address);
        try testing.expect(d.resumeThread(stop.id, .skip));
        thread.join();
        try testing.expectEqual(.resumed, skipping.verdict.?);
        const len = (try arch.insn.decode(address())).len;
        try testing.expectEqual(address() + len, skipping.e.cpu.ip());

        var crashing: Crasher = .at(address());
        thread = try std.Thread.spawn(.{}, Crasher.run, .{ &crashing, &d });
        const second = try waitStop(&d, 1);
        try testing.expect(d.resumeThread(second.id, .crash));
        thread.join();
        try testing.expectEqual(.crash, crashing.verdict.?);
        try testing.expectEqual(address(), crashing.e.cpu.ip());
    }
};

test {
    _ = tests;
}
