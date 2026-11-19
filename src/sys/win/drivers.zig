const std = @import("std");

const win = @import("api.zig");

pub fn runningDriversAlloc(allocator: std.mem.Allocator) ![]const []const u8 {
    return listDrivers(allocator, 64 * 1024);
}

fn listDrivers(allocator: std.mem.Allocator, first_size: usize) ![]const []const u8 {
    const manager = win.OpenSCManagerW(null, null, win.SC_MANAGER_ENUMERATE_SERVICE) orelse return error.ServicesUnavailable;
    defer _ = win.CloseServiceHandle(manager);

    var buf = try allocator.alignedAlloc(u8, .of(win.ENUM_SERVICE_STATUS_PROCESSW), first_size);
    defer allocator.free(buf);

    var names: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }
    // In chunks, picking up where the last one stopped. The size it says it needs is only for
    // what's left and can be short, so asking for it all at once can go round forever.
    var resume_at: win.DWORD = 0;
    for (0..4096) |_| {
        var needed: win.DWORD = 0;
        var count: win.DWORD = 0;
        const ok = win.EnumServicesStatusExW(manager, win.SC_ENUM_PROCESS_INFO, win.SERVICE_DRIVER, win.SERVICE_ACTIVE, buf.ptr, @intCast(buf.len), &needed, &count, &resume_at, null) != .FALSE;
        const more = !ok and win.GetLastError() == .MORE_DATA;
        if (!ok and !more) return error.ServicesUnavailable;
        if (more and count == 0) {
            // One entry bigger than the whole buffer
            const size = @max(needed, buf.len) + 4096;
            allocator.free(buf);
            buf = &.{};
            buf = try allocator.alignedAlloc(u8, .of(win.ENUM_SERVICE_STATUS_PROCESSW), size);
            continue;
        }
        const services: [*]const win.ENUM_SERVICE_STATUS_PROCESSW = @ptrCast(buf.ptr);
        try names.ensureUnusedCapacity(allocator, count);
        for (services[0..count]) |service| {
            const wide = std.mem.span(service.lpServiceName);
            const utf8 = try allocator.alloc(u8, std.unicode.calcWtf8Len(wide));
            names.appendAssumeCapacity(utf8[0..std.unicode.wtf16LeToWtf8(utf8, wide)]);
        }
        if (!more) return names.toOwnedSlice(allocator);
    }
    return error.ServicesUnavailable;
}

pub fn freeNames(allocator: std.mem.Allocator, names: []const []const u8) void {
    for (names) |n| allocator.free(n);
    allocator.free(names);
}

test "list running drivers" {
    const names = try runningDriversAlloc(std.testing.allocator);
    defer freeNames(std.testing.allocator, names);
    for (names) |n| {
        if (std.ascii.eqlIgnoreCase(n, "Ntfs") or std.ascii.eqlIgnoreCase(n, "ReFS")) return;
    }
    return error.TestUnexpectedResult;
}

test "a small buffer gets the same drivers, a few at a time" {
    const a = std.testing.allocator;
    const all = try runningDriversAlloc(a);
    defer freeNames(a, all);
    // Smaller than one entry to start, so it grows too
    const bit = try listDrivers(a, 16);
    defer freeNames(a, bit);
    // Drivers can start or stop between the two, so only roughly
    try std.testing.expect(bit.len + 8 >= all.len and all.len + 8 >= bit.len);
}
