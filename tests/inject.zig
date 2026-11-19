//! Real DLL injection into another process.

const std = @import("std");
const inject = @import("tuft_inject");
const build_options = @import("build_options");

const fixtures = [_]struct { arch: inject.Arch, target: []const u8, payload: []const u8 }{
    .{ .arch = .x86, .target = build_options.target_x86, .payload = build_options.payload_x86 },
    .{ .arch = .x64, .target = build_options.target_x64, .payload = build_options.payload_x64 },
};

test "inject each bitness" {
    const allocator = std.testing.allocator;

    for (fixtures) |f| {
        // An x86 injector can't reach an x64 target
        if (inject.self_arch == .x86 and f.arch == .x64) continue;

        var spawned = try inject.spawn(allocator, f.target, .{ .no_window = true });
        defer {
            spawned.terminate();
            spawned.close();
        }

        var target = try inject.Process.open(spawned.pid);
        defer target.close();
        try std.testing.expectEqual(f.arch, target.arch());

        const payload_name = std.fs.path.basename(f.payload);
        try std.testing.expectError(error.ModuleNotFound, target.findModule(payload_name));

        try inject.injectInto(allocator, spawned.pid, f.payload);

        try std.testing.expect((try target.findModule(payload_name)) != 0);
        const kernel32 = try target.findModule("kernel32.dll");
        try std.testing.expect((try target.findExport(allocator, kernel32, "LoadLibraryW")) != 0);
        var buf: [64]u8 = undefined;
        try std.testing.expectEqual(kernel32, target.symbols().resolve("kernel32.dll").?);
        try std.testing.expect(std.ascii.eqlIgnoreCase("kernel32.dll+0x10", target.symbols().describe(kernel32 + 0x10, &buf).?));
    }
}

test "watch injects suspended" {
    const allocator = std.testing.allocator;

    for (fixtures) |f| {
        if (inject.self_arch == .x86 and f.arch == .x64) continue;

        // Watch before it starts, like a game started by its launcher
        const name = std.fs.path.basename(f.target);
        var watch = try inject.Watch.init(.{ .name = name }, .{ .interval_ms = 10, .timeout_ms = 10_000 });
        var spawned = try inject.spawn(allocator, f.target, .{ .no_window = true });
        defer {
            spawned.terminate();
            spawned.close();
        }

        const pid = try watch.wait();
        try std.testing.expectEqual(spawned.pid, pid);
        try inject.injectStarting(allocator, pid, f.payload, .{});

        var target = try inject.Process.open(pid);
        defer target.close();
        try std.testing.expect((try target.findModule(std.fs.path.basename(f.payload))) != 0);
        // Resumed after, so still running
        try std.testing.expect(!target.exited());
    }
}

test "watch folder" {
    const allocator = std.testing.allocator;
    const f = fixtures[0];
    if (inject.self_arch == .x86 and f.arch == .x64) return error.SkipZigTest;

    const dir = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, std.fs.path.dirname(f.target).?, allocator);
    defer allocator.free(dir);
    var watch = try inject.Watch.init(.{ .folder = dir }, .{ .interval_ms = 10, .timeout_ms = 10_000 });
    var spawned = try inject.spawn(allocator, f.target, .{ .no_window = true });
    defer {
        spawned.terminate();
        spawned.close();
    }
    try std.testing.expectEqual(spawned.pid, try watch.wait());

    // Nothing else starts from there, so a second wait times out
    watch.ignore(spawned.pid);
    watch.options.timeout_ms = 100;
    try std.testing.expectError(error.Timeout, watch.wait());
}

test "watch path" {
    const allocator = std.testing.allocator;
    const f = fixtures[0];
    const path = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, f.target, allocator);
    defer allocator.free(path);

    // Same name somewhere else doesn't count
    const elsewhere_path = try std.fmt.allocPrint(allocator, "C:\\nowhere\\{s}", .{std.fs.path.basename(path)});
    defer allocator.free(elsewhere_path);
    var elsewhere = try inject.Watch.init(.{ .path = elsewhere_path }, .{ .interval_ms = 10, .timeout_ms = 300 });
    var watch = try inject.Watch.init(.{ .path = path }, .{ .interval_ms = 10, .timeout_ms = 10_000 });
    var spawned = try inject.spawn(allocator, f.target, .{ .no_window = true });
    defer {
        spawned.terminate();
        spawned.close();
    }
    try std.testing.expectEqual(spawned.pid, try watch.wait());
    try std.testing.expectError(error.Timeout, elsewhere.wait());
}

test "watch timeout" {
    var watch = try inject.Watch.init(.{ .name = "tuft-no-such-process.exe" }, .{ .interval_ms = 5, .timeout_ms = 30 });
    try std.testing.expectError(error.Timeout, watch.wait());
}

test "x86 refuses x64" {
    if (inject.self_arch != .x86) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var spawned = try inject.spawn(allocator, build_options.target_x64, .{ .no_window = true });
    defer {
        spawned.terminate();
        spawned.close();
    }
    try std.testing.expectError(error.ArchMismatch, inject.injectInto(allocator, spawned.pid, build_options.payload_x64));
}
