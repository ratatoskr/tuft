//! Hooks for a method that lives at several addresses.

const std = @import("std");
const sys = @import("tuft_sys");

const hook = @import("root.zig");

const log = std.log.scoped(.tuft_hook);

pub const max = 8;

/// Tries at enabling one, see `HookSet.enable`.
const enable_tries = 3;

/// Anything past `max` gets dropped.
pub const Addresses = struct {
    buf: [max]usize = undefined,
    len: usize = 0,

    pub fn add(self: *Addresses, address: usize) void {
        if (std.mem.indexOfScalar(usize, self.slice(), address) != null) return;
        if (self.len == self.buf.len) return;
        self.buf[self.len] = address;
        self.len += 1;
    }

    pub fn slice(self: *const Addresses) []const usize {
        return self.buf[0..self.len];
    }
};

pub fn HookSet(comptime F: type) type {
    return struct {
        const Self = @This();
        pub const Typed = hook.TypedHook(F);

        /// Makes a hook again at an address, with what `add` was given.
        const Remake = *const fn (address: usize, context: usize) anyerror!*Typed;

        buf: [max]*Typed = undefined,
        remakes: [max]Remake = undefined,
        contexts: [max]usize = undefined,
        len: usize = 0,

        /// Hooks start disabled.
        pub fn create(self: *Self, addresses: *const Addresses, comptime callback: anytype, context: anytype) !void {
            for (addresses.slice()) |address| _ = try self.add(address, callback, context);
        }

        /// If new and there's room. Returns the new hook, disabled.
        pub fn add(self: *Self, address: usize, comptime callback: anytype, context: anytype) !?*Typed {
            for (self.buf[0..self.len]) |h| if (h.toConstHook().target_addr == address) return null;
            if (self.len == self.buf.len) return null;
            const Context = @TypeOf(context);
            if (@typeInfo(Context) != .pointer) @compileError("HookSet contexts have to be pointers, not " ++ @typeName(Context));
            const remake = struct {
                fn remake(at: usize, ctx: usize) anyerror!*Typed {
                    return hook.memory.Address.at(at).createFn(F, callback, @as(Context, @ptrFromInt(ctx)));
                }
            }.remake;
            const h = try remake(address, @intFromPtr(context));
            self.buf[self.len] = h;
            self.remakes[self.len] = remake;
            self.contexts[self.len] = @intFromPtr(context);
            self.len += 1;
            return h;
        }

        pub fn covers(self: *const Self, address: usize) bool {
            for (self.buf[0..self.len]) |h| if (h.toConstHook().target_addr == address) return true;
            return false;
        }

        /// Enables the disabled ones. If something else hooked a target since its hook was made,
        /// like an overlay hooking the same DLL as it loads, the hook gets made again over theirs,
        /// so ours runs first and then theirs. A few tries, since they might still be writing.
        pub fn enable(self: *Self) !void {
            for (0..self.len) |i| try self.enableAt(i);
        }

        /// One `add` returned, the same way as `enable`.
        pub fn enableHook(self: *Self, h: *Typed) !void {
            const i = std.mem.indexOfScalar(*Typed, self.buf[0..self.len], h) orelse return error.NotInSet;
            try self.enableAt(i);
        }

        fn enableAt(self: *Self, i: usize) !void {
            var tries: u8 = 1;
            while (true) : (tries += 1) {
                const h = self.buf[i];
                if (h.toConstHook().state != .disabled) return;
                h.enable() catch |err| {
                    if (err != error.TargetModified or tries == enable_tries) return err;
                    const address = h.toConstHook().target_addr;
                    sys.thread.sleepMs(5);
                    h.destroy();
                    self.buf[i] = self.remakes[i](address, self.contexts[i]) catch |remake_err| {
                        self.drop(i);
                        return remake_err;
                    };
                    log.info("Something else hooked 0x{x} first, so ours goes over theirs", .{address});
                    continue;
                };
                return;
            }
        }

        fn drop(self: *Self, i: usize) void {
            self.len -= 1;
            self.buf[i] = self.buf[self.len];
            self.remakes[i] = self.remakes[self.len];
            self.contexts[i] = self.contexts[self.len];
        }

        /// Waits for calls in flight.
        pub fn destroy(self: *Self) void {
            for (self.buf[0..self.len]) |h| h.destroy();
            self.len = 0;
        }
    };
}

const tests = struct {
    const arch = @import("tuft_arch");
    const memory = @import("tuft_mem");
    const registry = @import("registry.zig");

    const Sig = fn (i32, i32) callconv(.c) i32;

    noinline fn target(a: i32, b: i32) callconv(.c) i32 {
        var x = a;
        var y = b;
        asm volatile (""
            : [x] "+r" (x),
              [y] "+r" (y),
        );
        return x - y;
    }

    noinline fn theirs(a: i32, b: i32) callconv(.c) i32 {
        return a * b;
    }

    const Ours = struct {
        calls: u32 = 0,
        fn run(self: *Ours, h: *hook.TypedHook(Sig), a: i32, b: i32) i32 {
            self.calls += 1;
            return h.original()(a, b) + 100;
        }
    };

    test "goes over a hook made after ours" {
        // Remaking it logs, keep that out of the test output
        const saved_level = std.testing.log_level;
        std.testing.log_level = .err;
        defer std.testing.log_level = saved_level;

        try registry.init(std.testing.allocator);
        defer registry.deinit();

        var target_addr = @intFromPtr(&target);
        _ = &target_addr; // comptime can't read function memory
        const bytes: [*]const u8 = @ptrFromInt(target_addr);
        const pristine = bytes[0..16].*;

        const overlay = (try memory.pages.allocNear(target_addr, memory.pages.size)) orelse return error.SkipZigTest;
        defer memory.pages.free(overlay);
        defer memory.writeCode(target_addr, &pristine) catch {};

        var ours: Ours = .{};
        var set: HookSet(Sig) = .{};
        _ = try set.add(target_addr, Ours.run, &ours);
        defer set.destroy();

        // An overlay hooks it too, before we enable
        const jump_to_theirs = arch.encodeAbsJmp(@intFromPtr(&theirs));
        try memory.writeCode(@intFromPtr(overlay.ptr), &jump_to_theirs);
        try memory.writeCode(target_addr, &arch.encodeNearJmp(target_addr, @intFromPtr(overlay.ptr)).?);
        try std.testing.expectEqual(12, target(3, 4));

        try set.enable();
        try std.testing.expectEqual(1, set.len);
        try std.testing.expectEqual(112, target(3, 4));
        try std.testing.expectEqual(1, ours.calls);
    }
};

test {
    _ = tests;
}
