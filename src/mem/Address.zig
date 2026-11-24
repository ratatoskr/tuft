//! Pointer chasing where each step carries the first error.

const std = @import("std");

const log = std.log.scoped(.tuft_mem);
const addr_digits = std.fmt.comptimePrint("{d}", .{@sizeOf(usize) * 2});

const insn = @import("tuft_arch").insn;
const Memory = @import("Memory.zig");

pub const State = union(enum) {
    ok: usize,
    err: anyerror,
};

pub const NoHooks = struct {};

/// `Hooks` needs `createFn`, `createMid`, `createSlot`, `FnHook(T)` and `MidHook`.
pub fn Generic(comptime Hooks: type) type {
    return struct {
        const Self = @This();
        /// Marks every `Generic` so `from` takes any of them.
        pub const is_address = {};

        state: State,
        memory: Memory = .local,

        pub fn at(addr: usize) Self {
            return .{ .state = .{ .ok = addr } };
        }

        pub fn fail(err: anyerror) Self {
            return .{ .state = .{ .err = err } };
        }

        /// Like `from`, but the chain reads `memory`.
        pub fn fromMemory(memory: Memory, value: anytype) Self {
            var self = from(value);
            self.memory = memory;
            return self;
        }

        /// Takes an int, pointer, slice, function, optional, error union or any `Address`.
        pub fn from(value: anytype) Self {
            const T = @TypeOf(value);
            if (T == Self) return value;
            if (@typeInfo(T) == .@"struct" and @hasDecl(T, "is_address")) return .{ .state = value.state, .memory = value.memory };
            return switch (@typeInfo(T)) {
                .int, .comptime_int => if (std.math.cast(usize, value)) |a| at(a) else fail(error.InvalidAddress),
                .pointer => |p| if (p.size == .slice) at(@intFromPtr(value.ptr)) else at(@intFromPtr(value)),
                .optional => if (value) |v| from(v) else fail(error.NullAddress),
                .null => fail(error.NullAddress),
                .error_union => if (value) |v| from(v) else |err| fail(err),
                .@"fn" => at(@intFromPtr(&value)),
                else => @compileError("can't make an Address from " ++ @typeName(T)),
            };
        }

        fn moved(self: Self, addr: usize) Self {
            return .{ .state = .{ .ok = addr }, .memory = self.memory };
        }

        fn failed(self: Self, err: anyerror) Self {
            return .{ .state = .{ .err = err }, .memory = self.memory };
        }

        pub fn offset(self: Self, delta: isize) Self {
            const a = self.unwrap() catch return self;
            return self.moved(a +% @as(usize, @bitCast(delta)));
        }

        /// Null gives `error.NullPointer`.
        pub fn deref(self: Self) Self {
            const value = self.load(usize) catch |err| return self.failed(err);
            return if (value == 0) self.failed(error.NullPointer) else self.moved(value);
        }

        pub fn vtable(self: Self, index: usize) Self {
            return self.vtableSlot(index).deref();
        }

        /// For slot hooks.
        pub fn vtableSlot(self: Self, index: usize) Self {
            return self.deref().offset(@intCast(index * @sizeOf(usize)));
        }

        /// Branch target or memory operand, like `mov rax, [rip + x]`.
        pub fn rip(self: Self) Self {
            const a = self.unwrap() catch return self;
            var code: [insn.max_len]u8 = undefined;
            self.memory.read(a, &code) catch return self.failed(error.InvalidPointer);
            const target = insn.toStaticAddressOf(&code, a) catch |err| return self.failed(err);
            return if (target) |t| self.moved(t) else self.failed(error.NoAddressOperand);
        }

        /// Through a relative jmp or call here, else stays put.
        pub fn follow(self: Self) Self {
            const a = self.unwrap() catch return self;
            var code: [insn.max_len]u8 = undefined;
            self.memory.read(a, &code) catch return self.failed(error.InvalidPointer);
            return self.moved(insn.resolveControlFlowTargetOf(&code, a));
        }

        /// Where the 32-bit relative offset here points, from just past it. For when the
        /// instruction it's in starts before what was matched.
        pub fn rel32(self: Self) Self {
            const a = self.unwrap() catch return self;
            const rel = self.load(i32) catch |err| return self.failed(err);
            return self.moved(a +% 4 +% @as(usize, @bitCast(@as(isize, rel))));
        }

        pub fn unwrap(self: Self) !usize {
            return switch (self.state) {
                .ok => |a| a,
                .err => |err| err,
            };
        }

        pub fn orNull(self: Self) ?usize {
            return self.unwrap() catch null;
        }

        /// Local memory only.
        pub fn ptr(self: Self, comptime P: type) !P {
            if (@typeInfo(P) != .pointer) @compileError("Address.ptr expects a pointer type, found " ++ @typeName(P));
            if (!self.memory.isLocal()) return error.NotLocalMemory;
            return @ptrFromInt(try self.unwrap());
        }

        pub fn load(self: Self, comptime T: type) !T {
            const a = try self.unwrap();
            return self.memory.load(T, a) catch error.InvalidPointer;
        }

        pub fn store(self: Self, comptime T: type, value: T) !void {
            const a = try self.unwrap();
            return self.memory.store(T, a, value) catch error.InvalidPointer;
        }

        pub fn logAs(self: Self, name: []const u8) Self {
            switch (self.state) {
                .ok => |a| log.info("{s}: 0x{x:0>" ++ addr_digits ++ "}", .{ name, a }),
                .err => |err| log.warn("{s}: {t}", .{ name, err }),
            }
            return self;
        }

        /// The backend's `FnHook(T)` and `MidHook` are what it gives back, like a pointer to a hook.
        pub fn createFn(self: Self, comptime T: type, comptime callback: anytype, context: anytype) anyerror!Backend().FnHook(T) {
            return Backend().createFn(T, try self.local(), callback, context);
        }

        pub fn createMid(self: Self, comptime callback: anytype, context: anytype) anyerror!Backend().MidHook {
            return Backend().createMid(try self.local(), callback, context);
        }

        pub fn createSlot(self: Self, comptime T: type, comptime callback: anytype, context: anytype) anyerror!Backend().FnHook(T) {
            return Backend().createSlot(T, try self.local(), callback, context);
        }

        fn Backend() type {
            if (!@hasDecl(Hooks, "createFn")) @compileError("This Address can't hook; use the one from tuft_hook.memory");
            return Hooks;
        }

        /// Hooks can only patch our own code.
        fn local(self: Self) !Self {
            return if (self.memory.isLocal()) self else error.NotLocalMemory;
        }
    };
}

const tests = struct {
    const Address = Generic(NoHooks);

    test "from converts or rejects" {
        var value: u32 = 0;
        const slice: []const u32 = (&value)[0..1];
        const some: ?*u32 = &value;
        const none: ?*u32 = null;
        const failed: anyerror!usize = error.Upstream;

        try std.testing.expectEqual(0x1400, try Address.from(0x1400).unwrap());
        try std.testing.expectEqual(@intFromPtr(&value), try Address.from(&value).unwrap());
        try std.testing.expectEqual(@intFromPtr(&value), try Address.from(slice).unwrap());
        try std.testing.expectEqual(@intFromPtr(&value), try Address.from(some).unwrap());
        try std.testing.expectError(error.NullAddress, Address.from(none).unwrap());
        try std.testing.expectError(error.NullAddress, Address.from(null).unwrap());
        try std.testing.expectError(error.InvalidAddress, Address.from(@as(isize, -1)).unwrap());
        try std.testing.expectError(error.Upstream, Address.from(failed).unwrap());
    }

    test "pointer chasing" {
        var target: u64 = 0x1122_3344;
        var ptr_to_target: usize = @intFromPtr(&target);
        var zero: usize = 0;
        const methods = [_]usize{ 0xA0, 0xB0, 0xC0 };
        var object: usize = @intFromPtr(&methods);

        try std.testing.expectEqual(@intFromPtr(&target), try Address.from(&ptr_to_target).deref().unwrap());
        try std.testing.expectEqual(0x1122_3344, try Address.from(&ptr_to_target).deref().load(u64));
        try std.testing.expectEqual(@intFromPtr(&target) - 8, try Address.from(&ptr_to_target).deref().offset(-8).unwrap());
        try std.testing.expectEqual(0xC0, try Address.from(&object).vtable(2).unwrap());
        try std.testing.expectEqual(@intFromPtr(&methods[2]), try Address.from(&object).vtableSlot(2).unwrap());

        try std.testing.expectError(error.NullPointer, Address.from(&zero).deref().unwrap());
        // The first failure sticks through later steps
        try std.testing.expectError(error.InvalidPointer, Address.at(0x10).deref().offset(8).deref().unwrap());
        try std.testing.expectEqual(null, Address.at(0x10).deref().orNull());
    }

    test "rip and follow" {
        var code: [32]u8 = @splat(0xCC);
        const base = @intFromPtr(&code);
        // A 7-byte instruction whose operand is base + 0x17
        if (@sizeOf(usize) == 8) {
            code[0..7].* = .{ 0x48, 0x8B, 0x05, 0x10, 0x00, 0x00, 0x00 }; // mov rax, [rip + 0x10]
        } else {
            code[0..2].* = .{ 0x8B, 0x05 }; // mov eax, [base + 0x17]
            std.mem.writeInt(u32, code[2..6], @intCast(base + 0x17), .little);
            code[6] = 0x90; // nop
        }
        code[7..12].* = .{ 0xE8, 0x05, 0x00, 0x00, 0x00 }; // call +5
        code[12..14].* = .{ 0x89, 0xC8 }; // mov eax, ecx

        try std.testing.expectEqual(base + 0x17, try Address.at(base).rip().unwrap());
        try std.testing.expectEqual(base + 12 + 5, try Address.at(base + 7).rip().unwrap());
        try std.testing.expectEqual(base + 12 + 5, try Address.at(base + 7).follow().unwrap());
        // The call's own rel32, from just past it
        try std.testing.expectEqual(base + 12 + 5, try Address.at(base + 8).rel32().unwrap());
        try std.testing.expectEqual(base + 12, try Address.at(base + 12).follow().unwrap());
        try std.testing.expectError(error.NoAddressOperand, Address.at(base + 12).rip().unwrap());
    }

    test "hooks and backend conversion" {
        const Fake = struct {
            var seen: usize = 0;
            pub fn FnHook(comptime T: type) type {
                return *T;
            }
            pub const MidHook = *u8;
            var mid_handle: u8 = 0;
            var fn_handle: u16 = 0;

            pub fn createFn(comptime T: type, target: anytype, comptime _: anytype, _: anytype) !*T {
                seen = try Address.from(target).unwrap();
                return &fn_handle;
            }
            pub fn createMid(target: anytype, comptime _: anytype, _: anytype) !*u8 {
                seen = try Address.from(target).unwrap();
                return &mid_handle;
            }
            pub fn createSlot(comptime T: type, target: anytype, comptime _: anytype, _: anytype) !*T {
                seen = try Address.from(target).unwrap() + 1;
                return &fn_handle;
            }
            fn cb() void {}
        };
        const Hooking = Generic(Fake);

        try std.testing.expectEqual(&Fake.mid_handle, try Hooking.at(0x10).offset(8).createMid(Fake.cb, {}));
        try std.testing.expectEqual(0x18, Fake.seen);
        try std.testing.expectEqual(&Fake.fn_handle, try Hooking.at(0x20).createFn(u16, Fake.cb, {}));
        try std.testing.expectEqual(0x20, Fake.seen);
        _ = try Hooking.at(0x30).createSlot(u16, Fake.cb, {});
        try std.testing.expectEqual(0x31, Fake.seen);
        try std.testing.expectError(error.Upstream, Hooking.fail(error.Upstream).createMid(Fake.cb, {}));

        // Only our own code can be hooked
        const Elsewhere = struct {
            fn read(_: ?*anyopaque, _: usize, _: []u8) Memory.Error!void {
                return error.Unreadable;
            }
        };
        const elsewhere: Memory = .{ .vtable = &.{ .read = Elsewhere.read } };
        try std.testing.expectError(error.NotLocalMemory, Hooking.fromMemory(elsewhere, 0x10).createMid(Fake.cb, {}));

        try std.testing.expectEqual(0x40, try Address.from(Hooking.at(0x40)).unwrap());
        try std.testing.expectError(error.Nope, Hooking.from(Address.fail(error.Nope)).unwrap());
    }

    test "memory chains won't hook" {
        const Fake = struct {
            // Pointer at 0x100 to 0x200, with 1.5 at +8
            fn read(_: ?*anyopaque, at: usize, out: []u8) Memory.Error!void {
                @memset(out, 0);
                if (at == 0x100 and out.len == @sizeOf(usize)) {
                    std.mem.writeInt(usize, out[0..@sizeOf(usize)], 0x200, .little);
                } else if (at == 0x208 and out.len == 4) {
                    out[0..4].* = @bitCast(@as(f32, 1.5));
                } else return error.Unreadable;
            }
        };
        const memory: Memory = .{ .vtable = &.{ .read = Fake.read } };
        const chain = Address.fromMemory(memory, 0x100).deref().offset(8);
        try std.testing.expectEqual(0x208, try chain.unwrap());
        try std.testing.expectEqual(1.5, try chain.load(f32));
        try std.testing.expectError(error.InvalidPointer, chain.store(f32, 2));
        try std.testing.expectError(error.InvalidPointer, chain.offset(4).deref().unwrap());
        try std.testing.expectError(error.NotLocalMemory, chain.ptr(*f32));
        try std.testing.expectEqual(1.5, try Generic(struct {}).from(chain).load(f32));
    }

    test "logAs passes through" {
        const saved = std.testing.log_level;
        std.testing.log_level = .err;
        defer std.testing.log_level = saved;

        try std.testing.expectEqual(0x1234, try Address.at(0x1234).logAs("ok").unwrap());
        try std.testing.expectError(error.Nope, Address.fail(error.Nope).logAs("err").unwrap());
    }
};

test {
    _ = tests;
}
