//! Fills a struct of function pointers from a runtime's exports, by field name.

const std = @import("std");
const sys = @import("tuft_sys");

/// Where exports come from: usually a loaded module, but games that rename them, or tests, can map names.
pub const Resolver = struct {
    ctx: ?*anyopaque,
    find: *const fn (ctx: ?*anyopaque, name: [:0]const u8) ?usize,

    pub fn module(base: usize) Resolver {
        return .{ .ctx = @ptrFromInt(base), .find = findIn };
    }

    fn findIn(ctx: ?*anyopaque, name: [:0]const u8) ?usize {
        return sys.module.findExport(@intFromPtr(ctx.?), name);
    }
};

/// Optional fields stay null when missing. `missing` gets the first required one that wasn't there.
pub fn load(comptime Api: type, comptime prefix: []const u8, r: Resolver, missing: ?*[]const u8) error{MissingExport}!Api {
    const info = @typeInfo(Api).@"struct";
    var api: Api = undefined;
    inline for (info.field_names, info.field_types) |name, T| {
        const addr = r.find(r.ctx, prefix ++ name);
        if (@typeInfo(T) == .optional) {
            @field(api, name) = if (addr) |a| @ptrFromInt(a) else null;
        } else if (addr) |a| {
            @field(api, name) = @ptrFromInt(a);
        } else {
            if (missing) |m| m.* = prefix ++ name;
            return error.MissingExport;
        }
    }
    return api;
}

/// For tests. Looks names up in the pub functions of `Fns`.
pub fn fake(comptime Fns: type) Resolver {
    const S = struct {
        fn find(_: ?*anyopaque, name: [:0]const u8) ?usize {
            inline for (@typeInfo(Fns).@"struct".decl_names) |d| {
                if (std.mem.eql(u8, d, name)) return @intFromPtr(&@field(Fns, d));
            }
            return null;
        }
    };
    return .{ .ctx = null, .find = S.find };
}

test "a missing export is named" {
    const Api = struct {
        one: *const fn () callconv(.c) i32,
        two: ?*const fn () callconv(.c) i32,
        three: *const fn () callconv(.c) i32,
    };
    const Fns = struct {
        pub fn x_one() callconv(.c) i32 {
            return 1;
        }
    };
    var missing: []const u8 = "";
    try std.testing.expectError(error.MissingExport, load(Api, "x_", fake(Fns), &missing));
    try std.testing.expectEqualStrings("x_three", missing);
}
