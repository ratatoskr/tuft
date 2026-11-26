//! Data and the code that reads it, placed together so the code can always reach it.

const std = @import("std");
const builtin = @import("builtin");
const arch = @import("tuft_arch");
const memory = @import("tuft_mem");
const Placement = memory.Placement;
const Hook = @import("Hook.zig");
const Patch = @import("Patch.zig");
const registry = @import("registry.zig");

pub const Data = struct {
    len: usize,
    alignment: usize = 16,
};

pub const Code = struct {
    address: usize,
    build: Hook.InjectBuild,
    /// Replaces code like `Patch.replace`. Null injects before it, like `Hook.createInjectRaw`.
    replace: ?Patch.ReplaceOptions = null,
};

pub const Made = Patch.Replacement;

pub const Options = struct {
    /// What the data's for when no code jumps to it, like `Placement.Request.target`.
    near: usize = 0,
    /// Data placed before that the code reads.
    reach: []const usize = &.{},
};

/// What went wrong, if something did.
pub const Failure = struct {
    /// The code that failed. Null if there was no room for it all.
    index: ?usize = null,
    /// Bytes it all needed in one spot.
    bytes: usize = 0,
};

/// Places `data` and `code` together, code starting disabled. Nothing stays placed on failure.
/// Trial builds see `data_out` empty, so they should assume the data is right by the code.
pub fn place(data: []const Data, code: []const Code, options: Options, data_out: []Placement, code_out: []Made, failure: *Failure) !void {
    std.debug.assert(data_out.len == data.len and code_out.len == code.len);
    const gpa = registry.allocator();
    const sizes = try gpa.alloc(usize, code.len);
    defer gpa.free(sizes);
    const outside = try gpa.alloc(bool, code.len);
    defer gpa.free(outside);
    const parts = try gpa.alloc(Placement.Part, data.len + code.len);
    defer gpa.free(parts);
    const placed = try gpa.alloc(Placement, data.len + code.len);
    defer gpa.free(placed);
    var readers: std.ArrayList(usize) = .empty;
    defer readers.deinit(gpa);
    var buf: [Patch.max_len]u8 = undefined;

    for (data_out) |*d| d.* = .{ .tier = .anywhere };
    for (code, 0..) |c, i| {
        failure.index = i;
        sizes[i] = 0;
        outside[i] = true;
        const r = c.replace orelse continue;
        sizes[i] = try Patch.replaceSize(c.address, r);
        outside[i] = !try fits(c, sizes[i], &buf);
        if (outside[i] and sizes[i] > arch.relocate.max_stolen_bytes) return error.TooLong;
    }

    // In place code may not reach data placed far away, so it moves out and all is placed again
    var count: usize = 0;
    while (true) {
        count = data.len;
        readers.clearRetainingCapacity();
        for (data, 0..) |d, i| parts[i] = .{ .len = d.len, .alignment = d.alignment };
        for (code, 0..) |c, i| {
            failure.index = i;
            if (!outside[i]) {
                try readers.append(gpa, c.address);
                continue;
            }
            parts[count] = .{ .target = c.address, .len = Hook.injectRoom(c.address, c.build, .{ .replace = @intCast(sizes[i]), .reach = options.reach }) };
            count += 1;
        }
        failure.index = null;
        failure.bytes = Placement.groupSize(parts[0..count]);
        try Placement.placeGroup(.{ .parts = parts[0..count], .near = options.near, .reach = options.reach, .readers = readers.items }, placed[0..count]);
        @memcpy(data_out, placed[0..data.len]);

        var moved = false;
        for (code, 0..) |c, i| {
            if (outside[i]) continue;
            const still = fits(c, sizes[i], &buf) catch |err| {
                failure.index = i;
                freeAll(placed[0..count], data_out);
                return err;
            };
            if (still) continue;
            outside[i] = true;
            moved = true;
        }
        if (!moved) break;
        freeAll(placed[0..count], data_out);
    }

    // Placements past `next` aren't anyone's yet
    var next = data.len;
    var made: usize = 0;
    errdefer {
        for (placed[next..count]) |*p| p.free();
        var i = made;
        while (i > 0) {
            i -= 1;
            switch (code_out[i]) {
                .patch => |p| p.destroy(),
                .hook => |h| h.destroy(),
            }
        }
        for (data_out) |*d| d.free();
    }
    for (code, 0..) |c, i| {
        failure.index = i;
        if (outside[i]) {
            const spot = placed[next];
            next += 1;
            code_out[i] = .{ .hook = try Hook.createInjectRaw(c.address, c.build, .{ .replace = @intCast(sizes[i]), .place = spot }) };
        } else {
            _ = try fits(c, sizes[i], &buf);
            code_out[i] = .{ .patch = try Patch.create(c.address, buf[0..sizes[i]], .{}) };
        }
        made += 1;
    }
    failure.index = null;
}

/// Builds it in place into `buf`, padded with NOPs. False if it doesn't fit there.
fn fits(c: Code, size: usize, buf: *[Patch.max_len]u8) !bool {
    if (size > buf.len) return false;
    const site: Hook.InjectSite = .{ .code = c.address, .original = null, .resume_at = c.address + size };
    const len = c.build.build(c.build.context, site, buf[0..size]) catch |err| switch (err) {
        error.NeedsCave, error.TooLong => return false,
        else => return err,
    };
    @memset(buf[len..size], 0x90);
    return true;
}

fn freeAll(placed: []Placement, data_out: []Placement) void {
    for (placed) |*p| p.free();
    for (data_out) |*d| d.* = .{ .tier = .anywhere };
}

const tests = struct {
    const testing = std.testing;

    // a + b + 100 + 3, as 2, 2, 3, 3, 3 and 3 byte instructions, twice
    comptime {
        if (builtin.cpu.arch == .x86_64) asm (
            \\.text
            \\.globl tuft_batch_a
            \\tuft_batch_a:
            \\  movl %ecx, %eax
            \\  addl %edx, %eax
            \\  addl $100, %eax
            \\  addl $1, %eax
            \\  addl $1, %eax
            \\  addl $1, %eax
            \\  retq
            \\.globl tuft_batch_b
            \\tuft_batch_b:
            \\  movl %ecx, %eax
            \\  addl %edx, %eax
            \\  addl $100, %eax
            \\  addl $1, %eax
            \\  addl $1, %eax
            \\  addl $1, %eax
            \\  retq
        );
    }
    extern fn tuft_batch_a(a: u32, b: u32) callconv(.c) u32;
    extern fn tuft_batch_b(a: u32, b: u32) callconv(.c) u32;

    /// `mov eax, [rip+data]` reading `data_out[0]` plus `offset`.
    const ReadData = struct {
        data: []const Placement,
        offset: usize = 0,
        /// NOPs after it, to make it too big for a cave.
        pad: usize = 0,
        broken: bool = false,

        fn build(context: ?*anyopaque, site: Hook.InjectSite, out: []u8) anyerror!usize {
            const self: *const ReadData = @ptrCast(@alignCast(context.?));
            if (self.broken) return error.InvalidAsm;
            const base = if (self.data[0].data.len > 0) @intFromPtr(self.data[0].data.ptr) else site.code;
            const rel = std.math.cast(i32, @as(isize, @bitCast(base + self.offset -% (site.code + 6)))) orelse
                return if (site.original == null) error.NeedsCave else error.OutOfReach;
            const len = 6 + self.pad;
            if (out.len < len) return error.TooLong;
            out[0..2].* = .{ 0x8B, 0x05 };
            std.mem.writeInt(i32, out[2..6], rel, .little);
            @memset(out[6..len], 0x90);
            return len;
        }

        fn of(self: *ReadData) Hook.InjectBuild {
            return .{ .context = self, .build = build };
        }
    };

    fn destroy(made: []const Made, data: []Placement) void {
        for (made) |m| switch (m) {
            .patch => |p| p.destroy(),
            .hook => |h| h.destroy(),
        };
        for (data) |*d| d.free();
    }

    fn enable(made: []const Made) !void {
        for (made) |m| switch (m) {
            .patch => |p| try p.enable(),
            .hook => |h| try h.enable(),
        };
    }

    test "data and several bodies go together and reach each other, in every tier" {
        if (builtin.cpu.arch != .x86_64) return error.SkipZigTest;
        try registry.init(testing.allocator);
        defer registry.deinit();
        defer Placement.tiers = .full;
        const a = @intFromPtr(&tuft_batch_a);
        const b = @intFromPtr(&tuft_batch_b);
        for (std.enums.values(Placement.Tier)) |tier| {
            Placement.tiers = .initOne(tier);
            var data: [1]Placement = undefined;
            var first: ReadData = .{ .data = &data };
            var second: ReadData = .{ .data = &data, .offset = 4 };
            // Over the first two instructions, which 6 bytes doesn't fit
            const code = [_]Code{
                .{ .address = a, .build = first.of(), .replace = .{ .size = 4 } },
                .{ .address = b, .build = second.of(), .replace = .{ .size = 4 } },
            };
            var made: [2]Made = undefined;
            var failure: Failure = .{};
            place(&.{.{ .len = 8 }}, &code, .{}, &data, &made, &failure) catch |err| {
                // The test exe might have no padding to spare
                if (tier == .cave and err == error.OutOfReach) continue;
                return err;
            };
            defer destroy(&made, &data);
            const at = @intFromPtr(data[0].data.ptr);
            std.mem.writeInt(u32, data[0].data[0..4], 40, .little);
            std.mem.writeInt(u32, data[0].data[4..8], 50, .little);
            for (made) |m| {
                try testing.expectEqual(tier, m.hook.place.tier);
                try testing.expectEqual(data[0].held[0], m.hook.place.held[0]);
            }
            try enable(&made);
            try testing.expect(Placement.holds(at));
            // 40 and 50, then the + 100 and three + 1s after
            try testing.expectEqual(143, tuft_batch_a(1, 10));
            try testing.expectEqual(153, tuft_batch_b(1, 10));
        }
        try testing.expectEqual(114, tuft_batch_a(1, 10));
    }

    test "too big for a cave and nothing near, it all goes far together" {
        if (builtin.cpu.arch != .x86_64) return error.SkipZigTest;
        try registry.init(testing.allocator);
        defer registry.deinit();
        defer Placement.tiers = .full;
        Placement.tiers = .initMany(&.{ .cave, .far, .anywhere });
        var data: [1]Placement = undefined;
        var read: ReadData = .{ .data = &data, .pad = 600 };
        const code = [_]Code{.{ .address = @intFromPtr(&tuft_batch_a), .build = read.of(), .replace = .{ .size = 4 } }};
        var made: [1]Made = undefined;
        var failure: Failure = .{};
        try place(&.{.{ .len = 600 }}, &code, .{}, &data, &made, &failure);
        defer destroy(&made, &data);
        try testing.expectEqual(.far, made[0].hook.place.tier);
        try testing.expect(failure.bytes > 1200);
        std.mem.writeInt(u32, data[0].data[0..4], 40, .little);
        try enable(&made);
        try testing.expectEqual(143, tuft_batch_a(1, 10));
    }

    test "a patch in place moves out to its data when that can only go far" {
        if (builtin.cpu.arch != .x86_64) return error.SkipZigTest;
        try registry.init(testing.allocator);
        defer registry.deinit();
        defer Placement.tiers = .full;
        const at = @intFromPtr(&tuft_batch_a);
        for ([_]bool{ true, false }) |near| {
            Placement.tiers = if (near) .initOne(.near) else .initMany(&.{ .far, .anywhere });
            var data: [1]Placement = undefined;
            var read: ReadData = .{ .data = &data };
            // 10 bytes, room for it in place
            const code = [_]Code{.{ .address = at, .build = read.of(), .replace = .{ .size = 10 } }};
            var made: [1]Made = undefined;
            var failure: Failure = .{};
            try place(&.{.{ .len = 4 }}, &code, .{}, &data, &made, &failure);
            defer destroy(&made, &data);
            const where = @intFromPtr(data[0].data.ptr);
            if (!near and std.math.cast(i32, @as(isize, @bitCast(where -% at))) != null) return error.SkipZigTest;
            try testing.expectEqual(near, made[0] == .patch);
            if (!near) try testing.expectEqual(made[0].hook.place.held[0], data[0].held[0]);
            std.mem.writeInt(u32, data[0].data[0..4], 40, .little);
            try enable(&made);
            // 40, then the two + 1s after what it replaced
            try testing.expectEqual(42, tuft_batch_a(1, 10));
        }
    }

    test "nothing's left when one fails" {
        if (builtin.cpu.arch != .x86_64) return error.SkipZigTest;
        try registry.init(testing.allocator);
        defer registry.deinit();
        const a = @intFromPtr(&tuft_batch_a);
        var data: [1]Placement = undefined;
        var good: ReadData = .{ .data = &data };
        var bad: ReadData = .{ .data = &data, .broken = true };
        const code = [_]Code{
            .{ .address = a, .build = good.of(), .replace = .{ .size = 4 } },
            .{ .address = @intFromPtr(&tuft_batch_b), .build = bad.of() },
        };
        var made: [2]Made = undefined;
        var failure: Failure = .{};
        try testing.expectError(error.InvalidAsm, place(&.{.{ .len = 8 }}, &code, .{}, &data, &made, &failure));
        try testing.expectEqual(1, failure.index);
        // Its patch went, so the code there's free again
        var again: [1]Made = undefined;
        try place(&.{.{ .len = 8 }}, code[0..1], .{}, &data, &again, &failure);
        destroy(&again, &data);
    }
};

test {
    _ = tests;
}
