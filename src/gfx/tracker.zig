//! Picks which surface a path reports, and reports it.

const std = @import("std");

const gfx = @import("root.zig");

const log = std.log.scoped(.tuft_gfx);

pub fn Tracker(comptime Source: type) type {
    const Key = Source.Key;
    return struct {
        const Self = @This();

        listener: gfx.Listener,
        source: Source = .{},
        frame: ?gfx.Frame = null,
        /// Last object we couldn't attach to, so we don't retry it every frame.
        refused: ?Key = null,

        pub fn present(self: *Self, key: Key) void {
            if (self.track(key)) |f| self.listener.frame(self.listener.ctx, f);
        }

        /// Fires on any present, tracked or not.
        pub fn presented(self: *Self) void {
            if (self.listener.presented) |p| p(self.listener.ctx);
        }

        /// Buffers are about to be resized or reset.
        pub fn resize(self: *Self, key: Key) void {
            if (self.current(key)) |f| self.listener.resize(self.listener.ctx, f);
        }

        pub fn current(self: *Self, key: Key) ?*gfx.Frame {
            const f = &(self.frame orelse return null);
            return if (Source.keyOf(f) == key) f else null;
        }

        /// Releases without reporting `detach`.
        pub fn deinit(self: *Self) void {
            if (self.frame) |*f| Source.release(f);
            self.frame = null;
        }

        /// Reports `detach` if tracked, so the next presenter gets picked up.
        pub fn remove(self: *Self, key: Key) void {
            if (self.refused == key) self.refused = null;
            const f = self.current(key) orelse return;
            self.listener.detach(self.listener.ctx, f);
            Source.release(f);
            self.frame = null;
        }

        fn track(self: *Self, key: Key) ?*const gfx.Frame {
            if (self.frame) |*f| {
                if (Source.keyOf(f) == key) return f;
            }
            // Ours, like a tool window. Never the game's
            const window = self.source.windowOf(key);
            if (window) |w| if (gfx.own_windows.contains(w)) return null;
            if (self.frame) |*f| {
                // Only follow it if it replaced ours on the same window
                if (window != @as(?*anyopaque, f.window)) return null;
                self.listener.detach(self.listener.ctx, f);
                Source.release(f);
                self.frame = null;
            }

            if (self.refused == key) return null;
            self.frame = self.source.attach(key) catch |err| {
                if (err == error.NotReady) return null;
                log.err("Couldn't attach to " ++ Source.noun ++ " 0x{x}: {t}", .{ @intFromPtr(key), err });
                self.refused = key;
                return null;
            };
            self.refused = null;
            const f = &self.frame.?;
            log.info("Attached to {t} " ++ Source.noun ++ " 0x{x} (window 0x{x})", .{ f.api, @intFromPtr(key), @intFromPtr(f.window) });
            self.listener.attach(self.listener.ctx, f);
            return f;
        }
    };
}
