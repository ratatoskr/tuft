const std = @import("std");
const zwin = std.os.windows;

const arch = @import("tuft_arch");
const sys = @import("../root.zig");

const win = @import("api.zig");

var live_bytes: std.atomic.Value(usize) = .init(0);
var allocs: std.atomic.Value(usize) = .init(0);
var frees: std.atomic.Value(usize) = .init(0);

fn mapped(slice: PageSlice) PageSlice {
    _ = live_bytes.fetchAdd(slice.len, .monotonic);
    _ = allocs.fetchAdd(1, .monotonic);
    return slice;
}

pub fn pageStats() sys.memory.PageStats {
    return .{ .live_bytes = live_bytes.load(.monotonic), .allocs = allocs.load(.monotonic), .frees = frees.load(.monotonic) };
}

pub const page_size = std.heap.page_size_min;
pub const PageSlice = []align(page_size) u8;

const max_near_range = arch.near_range;
const alloc_granularity: usize = 0x10000;

/// Null if there's no room. Errors only for other failures.
pub fn allocNear(target_addr: usize, size: usize) !?PageSlice {
    return allocNearSpan(target_addr, target_addr +| 1, size);
}

/// Within rel32 reach of every address from `start` up to `end`, like a whole module. Null if
/// there's no room.
pub fn allocNearSpan(start: usize, end: usize, size: usize) !?PageSlice {
    if (size == 0) return error.InvalidSize;
    if (arch.near_reaches_all) return try allocAny(size);

    const aligned_size = std.mem.alignForward(usize, size, page_size);
    const virtual_alloc2 = getVirtualAlloc2() orelse return null;

    // VirtualAlloc2 fails past user space, which ±2GB hits near system DLLs
    var info: win.SYSTEM_INFO = .{};
    win.GetSystemInfo(&info);
    const lowest = @max(info.lpMinimumApplicationAddress, alloc_granularity);
    const highest_end = info.lpMaximumApplicationAddress +| 1; // exclusive
    const last = @max(end, start +| 1) - 1;
    const raw_min: usize = @max(if (last > max_near_range) last - max_near_range else 0, lowest);
    const raw_max: usize = @min(start +| max_near_range, highest_end);
    if (raw_max <= raw_min) return null;

    const min_addr = std.mem.alignForward(usize, raw_min, alloc_granularity);
    const max_addr_aligned = std.mem.alignBackward(usize, raw_max, alloc_granularity);
    if (max_addr_aligned <= min_addr + aligned_size) return null;

    var addr_reqs = win.MEM_ADDRESS_REQUIREMENTS{
        .LowestStartingAddress = @ptrFromInt(min_addr),
        .HighestEndingAddress = @ptrFromInt(max_addr_aligned - 1),
        .Alignment = 0,
    };

    var ext_param = win.MEM_EXTENDED_PARAMETER{
        .Type = @backingInt(win.MEM_EXTENDED_PARAMETER_TYPE.MemExtendedParameterAddressRequirements),
        .Arg = .{ .Pointer = &addr_reqs },
    };

    const ptr = virtual_alloc2(
        zwin.GetCurrentProcess(),
        null,
        aligned_size,
        zwin.MEM.ALLOCATE{ .COMMIT = true, .RESERVE = true },
        zwin.PAGE{ .EXECUTE_READWRITE = true },
        @ptrCast(&ext_param),
        1,
    );

    if (ptr) |valid_ptr| {
        const byte_ptr: [*]align(page_size) u8 = @ptrCast(@alignCast(valid_ptr));
        return mapped(byte_ptr[0..aligned_size]);
    }

    const err = zwin.GetLastError();
    return switch (err) {
        .NOT_ENOUGH_MEMORY, .INVALID_ADDRESS, .OUTOFMEMORY => null,
        else => zwin.unexpectedError(err),
    };
}

/// The fallback when `allocNear` returns null.
pub fn allocAny(size: usize) !PageSlice {
    if (size == 0) return error.InvalidSize;

    const aligned_size = std.mem.alignForward(usize, size, page_size);
    const ptr = win.VirtualAlloc(
        null,
        aligned_size,
        zwin.MEM.ALLOCATE{ .COMMIT = true, .RESERVE = true },
        zwin.PAGE{ .EXECUTE_READWRITE = true },
    ) orelse return zwin.unexpectedError(zwin.GetLastError());

    const byte_ptr: [*]align(page_size) u8 = @ptrCast(@alignCast(ptr));
    return mapped(byte_ptr[0..aligned_size]);
}

pub fn free(mem: PageSlice) void {
    if (mem.len == 0) return;
    if (win.VirtualFree(mem.ptr, 0, zwin.MEM.FREE{ .RELEASE = true }) == zwin.BOOL.FALSE) {
        // Already freed or corrupted
        @panic("Fatal OS failure: VirtualFree returned error during memory release");
    }
    _ = live_bytes.fetchSub(mem.len, .monotonic);
    _ = frees.fetchAdd(1, .monotonic);
}

fn pageFlags(p: sys.memory.Protection) zwin.PAGE {
    return switch (p) {
        .no_access => .{ .NOACCESS = true },
        .read => .{ .READONLY = true },
        .read_write => .{ .READWRITE = true },
        .read_execute => .{ .EXECUTE_READ = true },
        .read_write_execute => .{ .EXECUTE_READWRITE = true },
    };
}

fn protectionOf(flags: zwin.PAGE) sys.memory.Protection {
    if (flags.EXECUTE_READWRITE or flags.EXECUTE_WRITECOPY) return .read_write_execute;
    if (flags.EXECUTE_READ or flags.EXECUTE) return .read_execute;
    if (flags.READWRITE or flags.WRITECOPY) return .read_write;
    if (flags.READONLY) return .read;
    return .no_access;
}

/// `error.InvalidAddress` if it isn't all mapped, like memory that's been freed.
pub fn protect(addr: usize, len: usize, protection: sys.memory.Protection) !sys.memory.Protection {
    var old: zwin.PAGE = .{};
    if (win.VirtualProtect(@ptrFromInt(addr), len, pageFlags(protection), &old) == zwin.BOOL.FALSE) {
        return switch (zwin.GetLastError()) {
            .INVALID_ADDRESS, .NOACCESS => error.InvalidAddress,
            else => |e| zwin.unexpectedError(e),
        };
    }
    return protectionOf(old);
}

pub fn writeCode(addr: usize, bytes: []const u8) !void {
    if (bytes.len == 0) return;
    const unlocked = try unlockCode(addr, bytes.len);
    defer unlocked.lock();
    unlocked.write(addr, bytes);
}

/// `len` bytes from `addr`, writable till `lock`.
pub const Unlocked = struct {
    addr: usize,
    len: usize,
    old: zwin.PAGE,

    /// Inside what was unlocked. No system calls bar the icache flush, so it's fine with every
    /// other thread frozen.
    pub fn write(self: Unlocked, at: usize, bytes: []const u8) void {
        std.debug.assert(at >= self.addr and at + bytes.len <= self.addr + self.len);
        const target: [*]u8 = @ptrFromInt(at);
        @memcpy(target[0..bytes.len], bytes);
        _ = win.FlushInstructionCache(zwin.GetCurrentProcess(), target, bytes.len);
    }

    /// Puts the protection back.
    pub fn lock(self: Unlocked) void {
        var dummy: zwin.PAGE = .{};
        _ = win.VirtualProtect(@ptrFromInt(self.addr), self.len, self.old, &dummy);
    }
};

/// `error.ProtectFailed` if it can't be made writable, like when a game's anti-tamper refuses.
pub fn unlockCode(addr: usize, len: usize) !Unlocked {
    var old: zwin.PAGE = .{};
    if (win.VirtualProtect(@ptrFromInt(addr), len, zwin.PAGE{ .EXECUTE_READWRITE = true }, &old) == zwin.BOOL.FALSE)
        return error.ProtectFailed;
    return .{ .addr = addr, .len = len, .old = old };
}

pub fn swapPointer(addr: usize, expected: usize, new: usize) !bool {
    if (addr % @alignOf(usize) != 0) return error.MisalignedPointer;
    const slot: *usize = @ptrFromInt(addr);

    // Keep execute in case the slot shares a page with code
    var old_protect: zwin.PAGE = .{};
    if (win.VirtualProtect(slot, @sizeOf(usize), zwin.PAGE{ .EXECUTE_READWRITE = true }, &old_protect) == zwin.BOOL.FALSE)
        return zwin.unexpectedError(zwin.GetLastError());
    defer {
        var dummy: zwin.PAGE = .{};
        _ = win.VirtualProtect(slot, @sizeOf(usize), old_protect, &dummy);
    }

    return @cmpxchgStrong(usize, slot, expected, new, .seq_cst, .seq_cst) == null;
}

/// Lets pointer chains fail instead of crashing, like while the game loads.
pub fn isReadable(addr: usize, len: usize) bool {
    if (len == 0) return true;
    const end = std.math.add(usize, addr, len) catch return false;

    var cur = addr;
    while (cur < end) {
        var info: win.MEMORY_BASIC_INFORMATION = undefined;
        if (win.VirtualQuery(@ptrFromInt(cur), &info, @sizeOf(win.MEMORY_BASIC_INFORMATION)) == 0) return false;
        if (info.State != win.MEM_COMMIT or info.Protect == 0) return false;
        if (info.Protect & (win.PAGE_NOACCESS | win.PAGE_GUARD) != 0) return false;
        cur = @intFromPtr(info.BaseAddress) + info.RegionSize;
    }
    return true;
}

/// Skips guard pages since touching a stack guard is bad news.
pub fn regionFrom(addr: usize) ?sys.memory.Region {
    return walkFrom(addr, true);
}

pub fn committedFrom(addr: usize) ?sys.memory.Region {
    return walkFrom(addr, false);
}

fn walkFrom(addr: usize, readable_only: bool) ?sys.memory.Region {
    var cur = addr;
    while (true) {
        var info: win.MEMORY_BASIC_INFORMATION = undefined;
        if (win.VirtualQuery(@ptrFromInt(cur), &info, @sizeOf(win.MEMORY_BASIC_INFORMATION)) == 0) return null;
        const base = @intFromPtr(info.BaseAddress);
        const end = std.math.add(usize, base, info.RegionSize) catch return null;
        const p = info.Protect;
        // Low byte is the access, the rest are modifiers
        const access = p & 0xFF;
        const readable = info.State == win.MEM_COMMIT and p & win.PAGE_GUARD == 0 and
            access != 0 and access != win.PAGE_NOACCESS and access != win.PAGE_EXECUTE;
        if (readable or (!readable_only and info.State == win.MEM_COMMIT)) {
            // On the first query `cur` may be mid-region
            const start = @max(base, cur);
            return .{
                .start = start,
                .len = end - start,
                .writable = p & (win.PAGE_READWRITE | win.PAGE_WRITECOPY | win.PAGE_EXECUTE_READWRITE | win.PAGE_EXECUTE_WRITECOPY) != 0,
                .executable = p & (win.PAGE_EXECUTE | win.PAGE_EXECUTE_READ | win.PAGE_EXECUTE_READWRITE | win.PAGE_EXECUTE_WRITECOPY) != 0,
                .readable = readable,
            };
        }
        if (end <= cur) return null;
        cur = end;
    }
}

/// On false `out` is garbage.
pub fn readSafe(addr: usize, out: []u8) bool {
    if (out.len == 0) return true;
    var n: usize = 0;
    return win.ReadProcessMemory(win.current_process, addr, out.ptr, out.len, &n) != .FALSE and n == out.len;
}

pub fn waitHeapUnlocked() void {
    const heap = win.GetProcessHeap() orelse return;
    if (win.HeapLock(heap) != .FALSE) _ = win.HeapUnlock(heap);
}

fn isNear(a: usize, b: usize) bool {
    const dist = if (a >= b) a - b else b - a;
    return dist <= max_near_range;
}

fn getVirtualAlloc2() ?win.PFN_VirtualAlloc2 {
    if (resolved_virtual_alloc2.load(.acquire)) {
        return cached_virtual_alloc2.load(.monotonic);
    }

    var func: ?win.PFN_VirtualAlloc2 = null;
    if (win.GetModuleHandleW(std.unicode.utf8ToUtf16LeStringLiteral("kernelbase.dll"))) |hmod| {
        if (win.GetProcAddress(hmod, "VirtualAlloc2")) |proc| {
            func = @ptrCast(proc);
        }
    }

    cached_virtual_alloc2.store(func, .monotonic);
    resolved_virtual_alloc2.store(true, .release);
    return func;
}

var cached_virtual_alloc2: std.atomic.Value(?win.PFN_VirtualAlloc2) = .init(null);
var resolved_virtual_alloc2: std.atomic.Value(bool) = .init(false);

const tests = struct {
    fn dummyTargetFunction(x: u32) callconv(.c) u32 {
        return x + 42;
    }

    test "allocNear within 2GB" {
        const target_addr = @intFromPtr(&dummyTargetFunction);
        const slice = (try allocNear(target_addr, 64)) orelse return error.ExpectedNearAlloc;
        defer free(slice);

        try std.testing.expect(slice.len >= page_size);
        try std.testing.expect(isNear(@intFromPtr(slice.ptr), target_addr));
    }

    test "allocNear at address space edges" {
        if (arch.near_reaches_all) return error.SkipZigTest;
        var info: win.SYSTEM_INFO = .{};
        win.GetSystemInfo(&info);
        for ([_]usize{ info.lpMaximumApplicationAddress - 0x10_0000, info.lpMinimumApplicationAddress + 0x10_0000 }) |target_addr| {
            const slice = (try allocNear(target_addr, 64)) orelse continue;
            defer free(slice);
            try std.testing.expect(isNear(@intFromPtr(slice.ptr), target_addr));
        }
    }

    test "mapped pages counted" {
        const before = pageStats();
        const slice = try allocAny(64);
        try std.testing.expectEqual(before.live_bytes + page_size, pageStats().live_bytes);
        free(slice);
        const after = pageStats();
        try std.testing.expectEqual(before.live_bytes, after.live_bytes);
        try std.testing.expect(after.allocs > before.allocs and after.frees > before.frees);
    }

    test "protect" {
        const slice = try allocAny(64);
        defer free(slice);
        try std.testing.expectEqual(.read_write_execute, try protect(@intFromPtr(slice.ptr), slice.len, .read));
        try std.testing.expectEqual(.read, try protect(@intFromPtr(slice.ptr), slice.len, .read_write_execute));
    }

    test "allocAny runs code" {
        const slice = try allocAny(64);
        defer free(slice);

        // mov eax, 0x1337, ret
        const shellcode = [_]u8{ 0xB8, 0x37, 0x13, 0x00, 0x00, 0xC3 };
        @memcpy(slice[0..shellcode.len], &shellcode);

        const generated_fn: *const fn () callconv(.c) u32 = @ptrCast(slice.ptr);
        try std.testing.expectEqual(0x1337, generated_fn());
    }

    test "writeCode patches code" {
        const slice = try allocAny(64);
        defer free(slice);

        // mov eax, 1, ret
        @memcpy(slice[0..6], &[_]u8{ 0xB8, 0x01, 0x00, 0x00, 0x00, 0xC3 });

        // RX like a real .text
        var old_protect: zwin.PAGE = .{};
        _ = win.VirtualProtect(slice.ptr, page_size, zwin.PAGE{ .EXECUTE_READ = true }, &old_protect);

        const func_ptr: *const fn () callconv(.c) u32 = @ptrCast(slice.ptr);
        try std.testing.expectEqual(1, func_ptr());

        try writeCode(@intFromPtr(slice.ptr) + 1, &[_]u8{ 99, 0, 0, 0 });
        try std.testing.expectEqual(99, func_ptr());
    }

    test "swapPointer" {
        const slice = try allocAny(64);
        defer free(slice);
        const slot: *usize = @ptrCast(@alignCast(slice.ptr));
        slot.* = 0xA0;

        var old_protect: zwin.PAGE = .{};
        _ = win.VirtualProtect(slice.ptr, page_size, zwin.PAGE{ .READONLY = true }, &old_protect);

        try std.testing.expect(try swapPointer(@intFromPtr(slot), 0xA0, 0xB0));
        try std.testing.expectEqual(0xB0, slot.*);
        try std.testing.expect(!try swapPointer(@intFromPtr(slot), 0xA0, 0xC0));
        try std.testing.expectEqual(0xB0, slot.*);
        try std.testing.expectError(error.MisalignedPointer, swapPointer(@intFromPtr(slot) + 1, 0, 0));
    }

    test "isReadable" {
        var value: u64 = 0;
        try std.testing.expect(isReadable(@intFromPtr(&value), @sizeOf(u64)));
        try std.testing.expect(!isReadable(0x10, 8));
        try std.testing.expect(!isReadable(std.math.maxInt(usize) - 3, 8));
    }
};

test {
    _ = tests;
}

test "protecting memory that's gone says so" {
    const page = try allocAny(page_size);
    const at = @intFromPtr(page.ptr);
    _ = try protect(at, page_size, .read);
    free(page);
    try std.testing.expectError(error.InvalidAddress, protect(at, page_size, .read_write));
}

test "regions and safe reads" {
    const page = try allocAny(page_size);
    const at = @intFromPtr(page.ptr);
    page[0] = 0x5A;

    const found = regionFrom(at).?;
    try std.testing.expect(found.start <= at and at < found.start + found.len);
    try std.testing.expect(found.writable and found.executable);
    _ = try protect(at, page_size, .read);
    const read_only = regionFrom(at).?;
    try std.testing.expect(!read_only.writable and !read_only.executable);

    // Walking up from 0 one region at a time gets to it
    var walked = false;
    var r = regionFrom(0);
    while (r) |region| : (r = regionFrom(region.start + region.len)) {
        if (region.start <= at and at < region.start + region.len) walked = true;
    }
    try std.testing.expect(walked);

    var out: [8]u8 = undefined;
    try std.testing.expect(readSafe(at, &out));
    try std.testing.expectEqual(0x5A, out[0]);

    // Unreadable ones only show up committed
    _ = try protect(at, page_size, .no_access);
    const hidden = committedFrom(at).?;
    try std.testing.expect(hidden.start == at and !hidden.readable);
    if (regionFrom(at)) |skipped| try std.testing.expect(skipped.start > at);
    try std.testing.expect(regionFrom(0).?.readable);
    free(page);
    try std.testing.expect(!readSafe(at, &out));
    if (regionFrom(at)) |after| try std.testing.expect(after.start > at);
}
