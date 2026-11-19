const std = @import("std");

pub fn fnInfo(comptime FuncOrPtr: anytype) std.builtin.Type.Fn {
    const raw_type = FnType(FuncOrPtr);
    return @typeInfo(raw_type).@"fn";
}

/// Bare fn type from a fn, fn value or fn pointer type.
pub fn FnType(comptime func_or_ptr: anytype) type {
    const T = comptime T: {
        if (@TypeOf(func_or_ptr) == type) {
            break :T func_or_ptr;
        }
        break :T @TypeOf(func_or_ptr);
    };

    const result = UnwrapType(T);
    if (@typeInfo(result) != .@"fn") {
        @compileError("FnType expects a function, function pointer, or function type, found: " ++ @typeName(T));
    }
    return result;
}

/// Strips optionals, error unions and pointers.
pub fn UnwrapType(comptime T: type) type {
    switch (@typeInfo(T)) {
        .optional => |opt| return UnwrapType(opt.child),
        .pointer => |ptr| return UnwrapType(ptr.child),
        .error_union => |eu| return UnwrapType(eu.payload),
        else => return T,
    }
}

pub fn assertBaseReturnTypesMatch(comptime a: anytype, comptime b: anytype) void {
    const OnceFn = FnType(a);
    const FollowupFn = FnType(b);

    const a_raw = @typeInfo(OnceFn).@"fn".return_type orelse void;
    const b_raw = @typeInfo(FollowupFn).@"fn".return_type orelse void;

    const once_payload = switch (@typeInfo(a_raw)) {
        .error_union => |eu| eu.payload,
        else => a_raw,
    };

    const followup_payload = switch (@typeInfo(b_raw)) {
        .error_union => |eu| eu.payload,
        else => b_raw,
    };

    if (once_payload != followup_payload) {
        @compileError("Success return types of 'a' and 'b' must match! Found: '" ++ @typeName(once_payload) ++ "' and '" ++ @typeName(followup_payload) ++ "'");
    }
}

/// Callback context to a word. `{}`, `null` and types give 0.
pub fn addressFromAny(val: anytype) usize {
    const T = @TypeOf(val);
    return switch (@typeInfo(T)) {
        .int, .comptime_int => @intCast(val),
        .pointer => @intFromPtr(val),
        .optional => if (val) |inner| addressFromAny(inner) else 0,
        .void, .null, .type => 0,
        else => @compileError("Unsupported address/context type: " ++ @typeName(T)),
    };
}

/// A fn with `T`'s exact signature that forwards its args to `Impl.invoke`.
pub fn Forwarder(comptime T: type, comptime Impl: type) type {
    const info = fnInfo(T);
    const params = info.param_types;
    const R = info.return_type.?;
    const cc = info.attrs.@"callconv";
    const P = struct {
        fn P(comptime i: usize) type {
            return params[i].?;
        }
    }.P;

    return switch (params.len) {
        0 => struct {
            pub fn detour() callconv(cc) R {
                return Impl.invoke(.{});
            }
        },
        1 => struct {
            pub fn detour(a0: P(0)) callconv(cc) R {
                return Impl.invoke(.{a0});
            }
        },
        2 => struct {
            pub fn detour(a0: P(0), a1: P(1)) callconv(cc) R {
                return Impl.invoke(.{ a0, a1 });
            }
        },
        3 => struct {
            pub fn detour(a0: P(0), a1: P(1), a2: P(2)) callconv(cc) R {
                return Impl.invoke(.{ a0, a1, a2 });
            }
        },
        4 => struct {
            pub fn detour(a0: P(0), a1: P(1), a2: P(2), a3: P(3)) callconv(cc) R {
                return Impl.invoke(.{ a0, a1, a2, a3 });
            }
        },
        5 => struct {
            pub fn detour(a0: P(0), a1: P(1), a2: P(2), a3: P(3), a4: P(4)) callconv(cc) R {
                return Impl.invoke(.{ a0, a1, a2, a3, a4 });
            }
        },
        6 => struct {
            pub fn detour(a0: P(0), a1: P(1), a2: P(2), a3: P(3), a4: P(4), a5: P(5)) callconv(cc) R {
                return Impl.invoke(.{ a0, a1, a2, a3, a4, a5 });
            }
        },
        7 => struct {
            pub fn detour(a0: P(0), a1: P(1), a2: P(2), a3: P(3), a4: P(4), a5: P(5), a6: P(6)) callconv(cc) R {
                return Impl.invoke(.{ a0, a1, a2, a3, a4, a5, a6 });
            }
        },
        8 => struct {
            pub fn detour(a0: P(0), a1: P(1), a2: P(2), a3: P(3), a4: P(4), a5: P(5), a6: P(6), a7: P(7)) callconv(cc) R {
                return Impl.invoke(.{ a0, a1, a2, a3, a4, a5, a6, a7 });
            }
        },
        9 => struct {
            pub fn detour(a0: P(0), a1: P(1), a2: P(2), a3: P(3), a4: P(4), a5: P(5), a6: P(6), a7: P(7), a8: P(8)) callconv(cc) R {
                return Impl.invoke(.{ a0, a1, a2, a3, a4, a5, a6, a7, a8 });
            }
        },
        10 => struct {
            pub fn detour(a0: P(0), a1: P(1), a2: P(2), a3: P(3), a4: P(4), a5: P(5), a6: P(6), a7: P(7), a8: P(8), a9: P(9)) callconv(cc) R {
                return Impl.invoke(.{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9 });
            }
        },
        11 => struct {
            pub fn detour(a0: P(0), a1: P(1), a2: P(2), a3: P(3), a4: P(4), a5: P(5), a6: P(6), a7: P(7), a8: P(8), a9: P(9), a10: P(10)) callconv(cc) R {
                return Impl.invoke(.{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10 });
            }
        },
        12 => struct {
            pub fn detour(a0: P(0), a1: P(1), a2: P(2), a3: P(3), a4: P(4), a5: P(5), a6: P(6), a7: P(7), a8: P(8), a9: P(9), a10: P(10), a11: P(11)) callconv(cc) R {
                return Impl.invoke(.{ a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11 });
            }
        },
        else => @compileError("Detours support at most 12 parameters"),
    };
}

const tests = struct {
    test "addressFromAny" {
        var dummy: u32 = 42;
        const dummy_ptr = &dummy;
        const some_opt: ?*u32 = dummy_ptr;
        const none_opt: ?*u32 = null;

        try std.testing.expectEqual(0x1404_eff6, addressFromAny(0x1404_eff6));
        try std.testing.expectEqual(1234, addressFromAny(1234));
        try std.testing.expectEqual(@intFromPtr(dummy_ptr), addressFromAny(dummy_ptr));
        try std.testing.expectEqual(@intFromPtr(dummy_ptr), addressFromAny(some_opt));
        try std.testing.expectEqual(0, addressFromAny(none_opt));
        try std.testing.expectEqual(0, addressFromAny(null));
        try std.testing.expectEqual(0, addressFromAny({}));
        try std.testing.expectEqual(0, addressFromAny(u32));
    }

    test "FnType and UnwrapType" {
        const Fn = fn (u8) callconv(.c) void;
        try std.testing.expectEqual(Fn, FnType(Fn));
        try std.testing.expectEqual(Fn, FnType(*const Fn));
        try std.testing.expectEqual(Fn, FnType(?*const Fn));
        try std.testing.expectEqual(u32, UnwrapType(anyerror!?*u32));
        try std.testing.expectEqual(u8, UnwrapType(u8));
    }

    test "fnInfo" {
        const SampleFn = fn (u32, i64) callconv(.c) bool;
        const SampleFnPtr = *const SampleFn;

        const info_bare = fnInfo(SampleFn);
        const info_ptr = fnInfo(SampleFnPtr);

        try std.testing.expectEqual(2, info_bare.param_types.len);
        try std.testing.expectEqual(u32, info_bare.param_types[0].?);
        try std.testing.expectEqual(i64, info_bare.param_types[1].?);
        try std.testing.expectEqual(bool, info_bare.return_type.?);

        try std.testing.expectEqual(info_bare.param_types.len, info_ptr.param_types.len);
        try std.testing.expectEqual(info_bare.return_type, info_ptr.return_type);
        try std.testing.expectEqual(info_bare.attrs.@"callconv", info_ptr.attrs.@"callconv");
    }
};

test {
    _ = tests;
}
