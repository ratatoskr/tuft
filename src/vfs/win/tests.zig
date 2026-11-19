//! Goes through kernel32 like a game would, with the hooks in.

const std = @import("std");

const Vfs = @import("../root.zig");
const hook = @import("tuft_hook");

const testing = std.testing;
const HANDLE = std.os.windows.HANDLE;
const BOOL = std.os.windows.BOOL;
const INVALID: HANDLE = std.os.windows.INVALID_HANDLE_VALUE;

const k32 = struct {
    extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: u32, share: u32, sa: ?*anyopaque, disposition: u32, flags: u32, template: ?HANDLE) callconv(.winapi) HANDLE;
    extern "kernel32" fn ReadFile(h: HANDLE, buf: [*]u8, len: u32, read: ?*u32, ov: ?*anyopaque) callconv(.winapi) BOOL;
    extern "kernel32" fn WriteFile(h: HANDLE, buf: [*]const u8, len: u32, written: ?*u32, ov: ?*anyopaque) callconv(.winapi) BOOL;
    extern "kernel32" fn GetFileSizeEx(h: HANDLE, size: *i64) callconv(.winapi) BOOL;
    extern "kernel32" fn SetFilePointerEx(h: HANDLE, distance: i64, new: ?*i64, method: u32) callconv(.winapi) BOOL;
    extern "kernel32" fn CloseHandle(h: HANDLE) callconv(.winapi) BOOL;
    extern "kernel32" fn GetFileAttributesW(name: [*:0]const u16) callconv(.winapi) u32;
    extern "kernel32" fn DeleteFileW(name: [*:0]const u16) callconv(.winapi) BOOL;
    extern "kernel32" fn GetTempPathW(len: u32, buf: [*]u16) callconv(.winapi) u32;
    extern "kernel32" fn FindFirstFileW(name: [*:0]const u16, data: *FindData) callconv(.winapi) HANDLE;
    extern "kernel32" fn FindNextFileW(h: HANDLE, data: *FindData) callconv(.winapi) BOOL;
    extern "kernel32" fn FindClose(h: HANDLE) callconv(.winapi) BOOL;
    extern "kernel32" fn DuplicateHandle(sp: HANDLE, s: HANDLE, tp: HANDLE, t: *HANDLE, access: u32, inherit: BOOL, options: u32) callconv(.winapi) BOOL;
    extern "kernel32" fn GetCurrentProcess() callconv(.winapi) HANDLE;
    extern "kernel32" fn GetLastError() callconv(.winapi) u32;
};

const FindData = extern struct {
    attributes: u32,
    created: u64 align(4),
    accessed: u64 align(4),
    written: u64 align(4),
    size_high: u32,
    size_low: u32,
    reserved: [2]u32,
    name: [260]u16,
    alt: [14]u16,
    // Only some builds fill these in
    extra: [3]u32,
};

const GENERIC_READ = 0x80000000;
const GENERIC_WRITE = 0x40000000;
const SHARE_ALL = 7;
const CREATE_NEW = 1;
const CREATE_ALWAYS = 2;
const OPEN_EXISTING = 3;
const DUPLICATE_SAME_ACCESS = 2;

fn wide(comptime s: []const u8) [:0]const u16 {
    return std.unicode.utf8ToUtf16LeStringLiteral(s);
}

fn wideAlloc(s: []const u8) ![:0]u16 {
    return std.unicode.wtf8ToWtf16LeAllocZ(testing.allocator, s);
}

/// A real file in the temp folder, with our slashes.
fn tempPath(buf: []u8, name: []const u8) ![]u8 {
    var w: [260]u16 = undefined;
    const n = k32.GetTempPathW(w.len, &w);
    var tmp: [520]u8 = undefined;
    const len = std.unicode.wtf16LeToWtf8(&tmp, w[0..n]);
    var joined: [600]u8 = undefined;
    const p = try std.fmt.bufPrint(&joined, "{s}{s}", .{ tmp[0..len], name });
    return Vfs.paths.normalize(buf, p);
}

fn readAll(h: HANDLE, buf: []u8) ![]u8 {
    var got: u32 = 0;
    if (k32.ReadFile(h, buf.ptr, @intCast(buf.len), &got, null).toBool() == false) return error.ReadFailed;
    return buf[0..got];
}

const Log = struct {
    opened: u32 = 0,
    closed: u32 = 0,
    reads: u32 = 0,
    bytes: usize = 0,
    /// Only counts paths under this.
    under: []const u8,

    fn mine(self: *Log, path: []const u8) bool {
        return std.ascii.startsWithIgnoreCase(path, self.under);
    }
    fn onOpened(self: *Log, f: *const Vfs.File) void {
        if (self.mine(f.path)) self.opened += 1;
    }
    fn onClosed(self: *Log, f: *const Vfs.File) void {
        if (self.mine(f.path)) self.closed += 1;
    }
    fn onRead(self: *Log, r: *Vfs.Read) void {
        if (!self.mine(r.file.path)) return;
        self.reads += 1;
        self.bytes += r.data.len;
    }
};

fn setup() !*Vfs {
    try hook.init(testing.allocator);
    return Vfs.init(testing.allocator);
}

fn teardown(vfs: *Vfs) void {
    vfs.deinit();
    hook.deinit();
}

test "tracks a real file from open to close" {
    const vfs = try setup();
    defer teardown(vfs);
    var path_buf: [600]u8 = undefined;
    const path = try tempPath(&path_buf, "tuft_vfs_real.txt");
    const w = try wideAlloc(path);
    defer testing.allocator.free(w);
    defer _ = k32.DeleteFileW(w);

    var log: Log = .{ .under = path };
    const s1 = try vfs.opened.subscribeUnscoped(&log, Log.onOpened);
    defer s1.unsubscribe();
    const s2 = try vfs.closed.subscribeUnscoped(&log, Log.onClosed);
    defer s2.unsubscribe();
    const s3 = try vfs.read.subscribeUnscoped(&log, Log.onRead);
    defer s3.unsubscribe();

    const h = k32.CreateFileW(w, GENERIC_READ | GENERIC_WRITE, SHARE_ALL, null, CREATE_ALWAYS, 0, null);
    try testing.expect(h != INVALID);
    var wrote: u32 = 0;
    try testing.expect(k32.WriteFile(h, "hello", 5, &wrote, null).toBool());
    _ = k32.SetFilePointerEx(h, 0, null, 0);

    var dup: HANDLE = undefined;
    try testing.expect(k32.DuplicateHandle(k32.GetCurrentProcess(), h, k32.GetCurrentProcess(), &dup, 0, .FALSE, DUPLICATE_SAME_ACCESS).toBool());

    const files = try vfs.openFiles(testing.allocator);
    defer Vfs.freeSnapshots(testing.allocator, files);
    var found: ?Vfs.Snapshot = null;
    for (files) |f| {
        if (std.ascii.eqlIgnoreCase(f.path, path)) found = f;
    }
    try testing.expectEqual(2, found.?.handles);
    try testing.expectEqual(5, found.?.bytes_written);
    try testing.expect(found.?.access.write);

    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("hello", try readAll(dup, &buf));
    _ = k32.CloseHandle(h);
    try testing.expectEqual(0, log.closed);
    _ = k32.CloseHandle(dup);

    try testing.expectEqual(1, log.opened);
    try testing.expectEqual(1, log.closed);
    try testing.expectEqual(1, log.reads);
    try testing.expectEqual(5, log.bytes);
}

test "serves virtual files" {
    const vfs = try setup();
    defer teardown(vfs);
    try vfs.put("C:/tuft_vfs_zz/data/a.txt", "hello world");

    const h = k32.CreateFileW(wide("C:\\tuft_vfs_zz\\data\\a.txt"), GENERIC_READ, 1, null, OPEN_EXISTING, 0, null);
    try testing.expect(h != INVALID);
    defer _ = k32.CloseHandle(h);
    var size: i64 = 0;
    try testing.expect(k32.GetFileSizeEx(h, &size).toBool());
    try testing.expectEqual(11, size);
    try testing.expect(k32.SetFilePointerEx(h, 6, null, 0).toBool());
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("world", try readAll(h, &buf));
    try testing.expectEqualStrings("", try readAll(h, &buf));

    // Writes need write access
    var wrote: u32 = 0;
    try testing.expect(k32.WriteFile(h, "x", 1, &wrote, null).toBool() == false);

    try testing.expectEqual(0x20, k32.GetFileAttributesW(wide("C:\\tuft_vfs_zz\\data\\a.txt")));
    try testing.expectEqual(0x10, k32.GetFileAttributesW(wide("C:\\tuft_vfs_zz\\data")));
    try testing.expectEqual(0xFFFFFFFF, k32.GetFileAttributesW(wide("C:\\tuft_vfs_zz\\data\\missing.txt")));
}

test "lists virtual folders" {
    const vfs = try setup();
    defer teardown(vfs);
    try vfs.put("C:/tuft_vfs_zz/a.txt", "a");
    try vfs.put("C:/tuft_vfs_zz/b.pak", "bb");
    try vfs.put("C:/tuft_vfs_zz/sub/c.txt", "c");

    var data: FindData = undefined;
    const h = k32.FindFirstFileW(wide("C:\\tuft_vfs_zz\\*"), &data);
    try testing.expect(h != INVALID);
    defer _ = k32.FindClose(h);
    var seen: [8][16]u8 = undefined;
    var n: usize = 0;
    while (true) {
        const name = std.mem.sliceTo(&data.name, 0);
        seen[n] = @splat(0);
        _ = std.unicode.wtf16LeToWtf8(&seen[n], name);
        n += 1;
        if (k32.FindNextFileW(h, &data).toBool() == false) break;
    }
    try testing.expectEqual(5, n);
    var names: [5][]const u8 = undefined;
    for (seen[0..n], 0..) |*s, i| names[i] = std.mem.sliceTo(s, 0);
    std.mem.sort([]const u8, &names, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.less);
    try testing.expectEqualStrings(".", names[0]);
    try testing.expectEqualStrings("..", names[1]);
    try testing.expectEqualStrings("a.txt", names[2]);
    try testing.expectEqualStrings("b.pak", names[3]);
    try testing.expectEqualStrings("sub", names[4]);

    // Patterns filter
    const p = k32.FindFirstFileW(wide("C:\\tuft_vfs_zz\\*.pak"), &data);
    try testing.expect(p != INVALID);
    defer _ = k32.FindClose(p);
    try testing.expectEqualSlices(u16, wide("b.pak"), std.mem.sliceTo(&data.name, 0));
    try testing.expectEqual(2, data.size_low);
    try testing.expect(k32.FindNextFileW(p, &data).toBool() == false);
}

test "mixes virtual files into real folders" {
    const vfs = try setup();
    defer teardown(vfs);
    var path_buf: [600]u8 = undefined;
    const real = try tempPath(&path_buf, "tuft_vfs_mix.txt");
    const w = try wideAlloc(real);
    defer testing.allocator.free(w);
    const h = k32.CreateFileW(w, GENERIC_WRITE, 0, null, CREATE_ALWAYS, 0, null);
    _ = k32.CloseHandle(h);
    defer _ = k32.DeleteFileW(w);

    var extra_buf: [600]u8 = undefined;
    const extra = try tempPath(&extra_buf, "tuft_vfs_mix_virtual.txt");
    try vfs.put(extra, "virtual");

    var pattern_buf: [600]u8 = undefined;
    const pattern = try tempPath(&pattern_buf, "tuft_vfs_mix*");
    const pw = try wideAlloc(pattern);
    defer testing.allocator.free(pw);
    var data: FindData = undefined;
    const f = k32.FindFirstFileW(pw, &data);
    try testing.expect(f != INVALID);
    defer _ = k32.FindClose(f);
    var count: usize = 1;
    var saw_virtual = false;
    while (true) {
        if (std.mem.eql(u16, std.mem.sliceTo(&data.name, 0), wide("tuft_vfs_mix_virtual.txt"))) saw_virtual = true;
        if (k32.FindNextFileW(f, &data).toBool() == false) break;
        count += 1;
    }
    try testing.expectEqual(2, count);
    try testing.expect(saw_virtual);
}

const Redirect = struct {
    from: []const u8,
    to: []const u8,
    fn onOpen(self: *Redirect, req: *Vfs.OpenRequest) void {
        if (std.ascii.eqlIgnoreCase(req.path, self.from)) req.redirect(self.to) catch {};
    }
};

test "listeners redirect opens" {
    const vfs = try setup();
    defer teardown(vfs);
    var path_buf: [600]u8 = undefined;
    const real = try tempPath(&path_buf, "tuft_vfs_target.txt");
    const w = try wideAlloc(real);
    defer testing.allocator.free(w);
    const h = k32.CreateFileW(w, GENERIC_WRITE, 0, null, CREATE_ALWAYS, 0, null);
    var wrote: u32 = 0;
    _ = k32.WriteFile(h, "real data", 9, &wrote, null);
    _ = k32.CloseHandle(h);
    defer _ = k32.DeleteFileW(w);

    try vfs.put("C:/tuft_vfs_zz/virtual.txt", "virtual data");

    var r: Redirect = .{ .from = "C:/tuft_vfs_zz/missing.txt", .to = real };
    const sub = try vfs.open.subscribeUnscoped(&r, Redirect.onOpen);
    defer sub.unsubscribe();

    var buf: [32]u8 = undefined;
    const a = k32.CreateFileW(wide("C:\\tuft_vfs_zz\\missing.txt"), GENERIC_READ, 1, null, OPEN_EXISTING, 0, null);
    try testing.expect(a != INVALID);
    try testing.expectEqualStrings("real data", try readAll(a, &buf));

    const files = try vfs.openFiles(testing.allocator);
    defer Vfs.freeSnapshots(testing.allocator, files);
    var found = false;
    for (files) |f| {
        if (f.requested) |req| {
            if (std.ascii.eqlIgnoreCase(req, "C:/tuft_vfs_zz/missing.txt")) found = std.ascii.eqlIgnoreCase(f.path, real);
        }
    }
    try testing.expect(found);
    _ = k32.CloseHandle(a);

    // Redirects into virtual files too, and attribute checks follow
    r.to = "C:/tuft_vfs_zz/virtual.txt";
    try testing.expectEqual(0x20, k32.GetFileAttributesW(wide("C:\\tuft_vfs_zz\\missing.txt")));
    const b = k32.CreateFileW(wide("C:\\tuft_vfs_zz\\missing.txt"), GENERIC_READ, 1, null, OPEN_EXISTING, 0, null);
    try testing.expect(b != INVALID);
    defer _ = k32.CloseHandle(b);
    try testing.expectEqualStrings("virtual data", try readAll(b, &buf));
}

const Deny = struct {
    fn onOpen(_: *Deny, req: *Vfs.OpenRequest) void {
        if (std.mem.endsWith(u8, req.path, "secret.txt")) req.deny(.access_denied);
    }
    fn onWrite(_: *Deny, w: *Vfs.Write) void {
        if (std.mem.endsWith(u8, w.file.path, "log.txt")) w.deny(.write_protected);
    }
};

test "listeners refuse opens and writes" {
    const vfs = try setup();
    defer teardown(vfs);
    try vfs.put("C:/tuft_vfs_zz/secret.txt", "s");
    try vfs.put("C:/tuft_vfs_zz/log.txt", "");
    var d: Deny = .{};
    const s1 = try vfs.open.subscribeUnscoped(&d, Deny.onOpen);
    defer s1.unsubscribe();
    const s2 = try vfs.write.subscribeUnscoped(&d, Deny.onWrite);
    defer s2.unsubscribe();

    try testing.expectEqual(INVALID, k32.CreateFileW(wide("C:\\tuft_vfs_zz\\secret.txt"), GENERIC_READ, 1, null, OPEN_EXISTING, 0, null));
    try testing.expectEqual(5, k32.GetLastError()); // ERROR_ACCESS_DENIED

    const h = k32.CreateFileW(wide("C:\\tuft_vfs_zz\\log.txt"), GENERIC_WRITE, 1, null, OPEN_EXISTING, 0, null);
    try testing.expect(h != INVALID);
    defer _ = k32.CloseHandle(h);
    var wrote: u32 = 0;
    try testing.expect(k32.WriteFile(h, "x", 1, &wrote, null).toBool() == false);
    try testing.expectEqual(0, (try vfs.contents(testing.allocator, "C:/tuft_vfs_zz/log.txt")).?.len);
}

test "creates, writes and deletes in virtual folders" {
    const vfs = try setup();
    defer teardown(vfs);
    try vfs.putDir("C:/tuft_vfs_zz/saves");

    const h = k32.CreateFileW(wide("C:\\tuft_vfs_zz\\saves\\slot1.sav"), GENERIC_READ | GENERIC_WRITE, 0, null, CREATE_NEW, 0, null);
    try testing.expect(h != INVALID);
    var wrote: u32 = 0;
    try testing.expect(k32.WriteFile(h, "save", 4, &wrote, null).toBool());
    try testing.expect(k32.WriteFile(h, "data", 4, &wrote, null).toBool());
    _ = k32.CloseHandle(h);

    const bytes = (try vfs.contents(testing.allocator, "C:/tuft_vfs_zz/saves/slot1.sav")).?;
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("savedata", bytes);

    try testing.expectEqual(INVALID, k32.CreateFileW(wide("C:\\tuft_vfs_zz\\saves\\slot1.sav"), GENERIC_WRITE, 0, null, CREATE_NEW, 0, null));
    try testing.expect(k32.DeleteFileW(wide("C:\\tuft_vfs_zz\\saves\\slot1.sav")).toBool());
    try testing.expectEqual(null, vfs.exists("C:/tuft_vfs_zz/saves/slot1.sav"));
    try testing.expectEqual(.dir, vfs.exists("C:/tuft_vfs_zz/saves"));
}

test "bypassed threads see the real disk" {
    const vfs = try setup();
    defer teardown(vfs);
    try vfs.put("C:/tuft_vfs_zz/a.txt", "a");
    Vfs.beginBypass();
    defer Vfs.endBypass();
    try testing.expectEqual(0xFFFFFFFF, k32.GetFileAttributesW(wide("C:\\tuft_vfs_zz\\a.txt")));
}
