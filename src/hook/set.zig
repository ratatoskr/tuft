//! Hooks for a method that lives at several addresses.

const std = @import("std");

const hook = @import("root.zig");

pub const max = 8;

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

        buf: [max]*Typed = undefined,
        len: usize = 0,

        /// Hooks start disabled.
        pub fn create(self: *Self, addresses: *const Addresses, comptime callback: anytype, context: anytype) !void {
            for (addresses.slice()) |address| _ = try self.add(address, callback, context);
        }

        /// If new and there's room. Returns the new hook, disabled.
        pub fn add(self: *Self, address: usize, comptime callback: anytype, context: anytype) !?*Typed {
            for (self.buf[0..self.len]) |h| if (h.toConstHook().target_addr == address) return null;
            if (self.len == self.buf.len) return null;
            const h = try hook.memory.Address.at(address).createFn(F, callback, context);
            self.buf[self.len] = h;
            self.len += 1;
            return h;
        }

        pub fn covers(self: *const Self, address: usize) bool {
            for (self.buf[0..self.len]) |h| if (h.toConstHook().target_addr == address) return true;
            return false;
        }

        pub fn enable(self: *Self) !void {
            for (self.buf[0..self.len]) |h| try h.enable();
        }

        /// Waits for calls in flight.
        pub fn destroy(self: *Self) void {
            for (self.buf[0..self.len]) |h| h.destroy();
            self.len = 0;
        }
    };
}
