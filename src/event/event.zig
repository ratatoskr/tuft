//! Events with many subscribers, fired from any thread while they come and go.

const std = @import("std");

const meta = @import("tuft_arch").meta;
const Scope = @import("Scope.zig");

pub const Options = struct {
    /// Higher runs first, ties in subscription order.
    priority: i32 = 0,
};

/// Inside a handler, list changes can't wait for dispatches since one is ours.
threadlocal var dispatch_depth: u32 = 0;

pub fn Event(comptime Signature: type) type {
    const info = meta.fnInfo(Signature);
    const Return = info.return_type.?;
    const Args = std.meta.ArgsTuple(meta.FnType(Signature));

    const Mode = enum { broadcast, first };
    const mode: Mode = switch (@typeInfo(Return)) {
        .void => .broadcast,
        .optional => .first,
        else => @compileError("Event handlers must return void (broadcast) or an optional (first non-null wins), found " ++ @typeName(Return)),
    };
    const Payload = if (mode == .first) @typeInfo(Return).optional.child else void;

    return struct {
        const Self = @This();

        pub const Result = Return;

        /// C-ABI so other DLLs can subscribe. Writes first-wins results to `out`.
        const Call = *const fn (ctx: ?*anyopaque, args: *const anyopaque, out: ?*anyopaque) callconv(.c) bool;

        const Entry = struct {
            id: u64,
            priority: i32,
            ctx: ?*anyopaque,
            call: Call,
            /// Cleared to retire an entry in place when we can't allocate.
            alive: std.atomic.Value(bool),
        };

        const Snapshot = struct {
            entries: []Entry,
        };

        /// Unsubscribing waits for running dispatches, except from inside a handler. Twice is fine.
        pub const Subscription = struct {
            event: *Self,
            id: u64,

            pub fn unsubscribe(self: Subscription) void {
                self.event.remove(self.id);
            }

            fn release(token: *Subscription) void {
                const event = token.event;
                token.unsubscribe();
                event.allocator.destroy(token);
            }
        };

        allocator: std.mem.Allocator,
        snapshot: std.atomic.Value(?*Snapshot) = .init(null),
        /// Readers register in `readers[epoch & 1]`. Writers flip and drain the old slot.
        epoch: std.atomic.Value(u32) = .init(0),
        readers: [2]std.atomic.Value(u32) = .{ .init(0), .init(0) },
        /// Serializes list changes. Dispatch never takes it.
        writing: std.atomic.Value(bool) = .init(false),
        // Guarded by `writing`
        next_id: u64 = 1,
        /// Old snapshots a dispatch might still read.
        retired: std.ArrayList(*Snapshot) = .empty,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        /// No dispatch can be running and scopes must be disposed already.
        pub fn deinit(self: *Self) void {
            if (self.snapshot.swap(null, .seq_cst)) |s| self.destroySnapshot(s);
            for (self.retired.items) |s| self.destroySnapshot(s);
            self.retired.deinit(self.allocator);
            self.* = undefined;
        }

        /// Broadcast calls everyone. First-wins returns the first non-null result.
        pub fn fire(self: *Self, args: Args) Return {
            const slot = self.enter();
            defer self.leave(slot);

            const snapshot = self.snapshot.load(.seq_cst) orelse return emptyResult();

            dispatch_depth += 1;
            defer dispatch_depth -= 1;

            switch (comptime mode) {
                .broadcast => {
                    for (snapshot.entries) |*entry| {
                        if (!entry.alive.load(.acquire)) continue;
                        _ = entry.call(entry.ctx, &args, null);
                    }
                },
                .first => {
                    var out: Payload = undefined;
                    for (snapshot.entries) |*entry| {
                        if (!entry.alive.load(.acquire)) continue;
                        if (entry.call(entry.ctx, &args, &out)) return out;
                    }
                    return null;
                },
            }
        }

        /// Racy, for diagnostics and tests.
        pub fn count(self: *Self) usize {
            const slot = self.enter();
            defer self.leave(slot);
            const snapshot = self.snapshot.load(.seq_cst) orelse return 0;
            var n: usize = 0;
            for (snapshot.entries) |*entry| {
                if (entry.alive.load(.acquire)) n += 1;
            }
            return n;
        }

        /// Until `scope` is disposed.
        pub fn subscribe(self: *Self, scope: *Scope, ctx: anytype, comptime func: anytype) !void {
            return self.subscribeOpts(scope, ctx, func, .{});
        }

        pub fn subscribeOpts(self: *Self, scope: *Scope, ctx: anytype, comptime func: anytype, options: Options) !void {
            const token = try self.allocator.create(Subscription);
            errdefer self.allocator.destroy(token);

            token.* = try self.subscribeUnscopedOpts(ctx, func, options);
            errdefer token.unsubscribe();

            try scope.add(token, Subscription.release);
        }

        pub fn subscribeUnscoped(self: *Self, ctx: anytype, comptime func: anytype) !Subscription {
            return self.subscribeUnscopedOpts(ctx, func, .{});
        }

        pub fn subscribeUnscopedOpts(self: *Self, ctx: anytype, comptime func: anytype, options: Options) !Subscription {
            const Ctx = @TypeOf(ctx);
            if (@typeInfo(Ctx) != .pointer) @compileError("Event subscriber context must be a pointer, found " ++ @typeName(Ctx));
            checkHandler(Ctx, func);

            const Thunk = struct {
                fn call(raw_ctx: ?*anyopaque, raw_args: *const anyopaque, out: ?*anyopaque) callconv(.c) bool {
                    const typed_ctx: Ctx = @ptrCast(@alignCast(raw_ctx.?));
                    const args: *const Args = @ptrCast(@alignCast(raw_args));
                    const result = @call(.auto, func, .{typed_ctx} ++ args.*);
                    switch (comptime mode) {
                        .broadcast => return true,
                        .first => {
                            const value = result orelse return false;
                            const slot: *Payload = @ptrCast(@alignCast(out.?));
                            slot.* = value;
                            return true;
                        },
                    }
                }
            };

            const id = try self.add(.{
                .id = 0,
                .priority = options.priority,
                .ctx = @ptrCast(@constCast(ctx)),
                .call = Thunk.call,
                .alive = .init(true),
            });
            return .{ .event = self, .id = id };
        }

        fn checkHandler(comptime Ctx: type, comptime func: anytype) void {
            const handler = meta.fnInfo(func);
            const name = @typeName(@TypeOf(func));
            if (handler.param_types.len != info.param_types.len + 1) {
                @compileError("Event handler " ++ name ++ " must take the context followed by the event's arguments");
            }
            if (handler.param_types[0]) |First| {
                if (First != Ctx) @compileError("Event handler " ++ name ++ " takes " ++ @typeName(First) ++ " as its context, but was subscribed with " ++ @typeName(Ctx));
            }
            if (handler.return_type.? != Return) {
                @compileError("Event handler " ++ name ++ " must return " ++ @typeName(Return));
            }
        }

        fn emptyResult() Return {
            return switch (comptime mode) {
                .broadcast => {},
                .first => null,
            };
        }

        fn enter(self: *Self) u1 {
            while (true) {
                const epoch = self.epoch.load(.seq_cst);
                const slot: u1 = @truncate(epoch);
                _ = self.readers[slot].fetchAdd(1, .seq_cst);
                // A writer flipped the epoch meanwhile and might not wait on this slot
                if (self.epoch.load(.seq_cst) == epoch) return slot;
                _ = self.readers[slot].fetchSub(1, .seq_cst);
            }
        }

        fn leave(self: *Self, slot: u1) void {
            _ = self.readers[slot].fetchSub(1, .seq_cst);
        }

        /// Waits for dispatches that started before this. Writers only.
        fn synchronize(self: *Self) void {
            const slot: u1 = @truncate(self.epoch.fetchAdd(1, .seq_cst));
            while (self.readers[slot].load(.seq_cst) != 0) std.Thread.yield() catch {};
        }

        fn lock(self: *Self) void {
            while (self.writing.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.Thread.yield() catch {};
        }

        fn unlock(self: *Self) void {
            self.writing.store(false, .release);
        }

        fn add(self: *Self, entry: Entry) !u64 {
            self.lock();
            defer self.unlock();

            const current = self.liveEntries();
            const new = try self.createSnapshot(current.live + 1);
            errdefer self.destroySnapshot(new);
            if (dispatch_depth > 0) try self.retired.ensureUnusedCapacity(self.allocator, 1);

            var added = entry;
            added.id = self.next_id;
            self.next_id += 1;

            // Higher priority first, new entry after equal ones
            var out: usize = 0;
            var inserted = false;
            for (current.entries) |*existing| {
                if (!existing.alive.load(.acquire)) continue;
                if (!inserted and added.priority > existing.priority) {
                    new.entries[out] = added;
                    out += 1;
                    inserted = true;
                }
                new.entries[out] = copyEntry(existing);
                out += 1;
            }
            if (!inserted) new.entries[out] = added;

            self.publish(new);
            return added.id;
        }

        fn remove(self: *Self, id: u64) void {
            self.lock();
            defer self.unlock();

            const current = self.liveEntries();
            const target = for (current.entries) |*entry| {
                if (entry.id == id and entry.alive.load(.acquire)) break entry;
            } else return;

            if (self.rebuildWithout(current, id)) |new| {
                self.publish(new);
                return;
            } else |_| {}

            // Out of memory, so retire the entry in place and wait out dispatches
            target.alive.store(false, .release);
            if (dispatch_depth == 0) self.synchronize();
        }

        fn rebuildWithout(self: *Self, current: Live, id: u64) !?*Snapshot {
            if (current.live == 1) {
                if (dispatch_depth > 0) try self.retired.ensureUnusedCapacity(self.allocator, 1);
                return null;
            }
            const new = try self.createSnapshot(current.live - 1);
            errdefer self.destroySnapshot(new);
            if (dispatch_depth > 0) try self.retired.ensureUnusedCapacity(self.allocator, 1);

            var out: usize = 0;
            for (current.entries) |*entry| {
                if (entry.id == id or !entry.alive.load(.acquire)) continue;
                new.entries[out] = copyEntry(entry);
                out += 1;
            }
            return new;
        }

        /// Can't fail, the memory was reserved up front.
        fn publish(self: *Self, new: ?*Snapshot) void {
            const old = self.snapshot.swap(new, .seq_cst);
            if (dispatch_depth > 0) {
                // Our own dispatch might still be walking `old`
                if (old) |s| self.retired.appendAssumeCapacity(s);
                return;
            }
            self.synchronize();
            if (old) |s| self.destroySnapshot(s);
            for (self.retired.items) |s| self.destroySnapshot(s);
            self.retired.clearRetainingCapacity();
        }

        const Live = struct { entries: []Entry, live: usize };

        fn liveEntries(self: *Self) Live {
            const snapshot = self.snapshot.load(.seq_cst) orelse return .{ .entries = &.{}, .live = 0 };
            var live: usize = 0;
            for (snapshot.entries) |*entry| {
                if (entry.alive.load(.acquire)) live += 1;
            }
            return .{ .entries = snapshot.entries, .live = live };
        }

        fn copyEntry(entry: *const Entry) Entry {
            return .{ .id = entry.id, .priority = entry.priority, .ctx = entry.ctx, .call = entry.call, .alive = .init(true) };
        }

        fn createSnapshot(self: *Self, len: usize) !*Snapshot {
            const snapshot = try self.allocator.create(Snapshot);
            errdefer self.allocator.destroy(snapshot);
            snapshot.* = .{ .entries = try self.allocator.alloc(Entry, len) };
            return snapshot;
        }

        fn destroySnapshot(self: *Self, snapshot: *Snapshot) void {
            self.allocator.free(snapshot.entries);
            self.allocator.destroy(snapshot);
        }
    };
}

const tests = struct {
    const testing = std.testing;

    const Recorder = struct {
        tag: u8,
        log: *std.ArrayList(u8),

        fn onValue(self: *Recorder, value: u32) void {
            _ = value;
            self.log.append(testing.allocator, self.tag) catch unreachable;
        }
    };

    test "broadcast order" {
        var event: Event(fn (u32) void) = .init(testing.allocator);
        defer event.deinit();
        var scope = Scope.init(testing.allocator);
        defer scope.deinit();

        var log: std.ArrayList(u8) = .empty;
        defer log.deinit(testing.allocator);

        var a: Recorder = .{ .tag = 'a', .log = &log };
        var b: Recorder = .{ .tag = 'b', .log = &log };
        var c: Recorder = .{ .tag = 'c', .log = &log };
        var d: Recorder = .{ .tag = 'd', .log = &log };
        try event.subscribe(&scope, &a, Recorder.onValue);
        try event.subscribe(&scope, &b, Recorder.onValue);
        try event.subscribeOpts(&scope, &c, Recorder.onValue, .{ .priority = 10 });
        try event.subscribeOpts(&scope, &d, Recorder.onValue, .{ .priority = -1 });

        event.fire(.{7});
        try testing.expectEqualStrings("cabd", log.items);
        try testing.expectEqual(4, event.count());
    }

    test "first-wins" {
        const Handler = struct {
            answer: ?i32,
            calls: u32 = 0,

            fn handle(self: *@This(), x: i32) ?i32 {
                self.calls += 1;
                return if (self.answer) |a| a + x else null;
            }
        };

        var event: Event(fn (i32) ?i32) = .init(testing.allocator);
        defer event.deinit();
        var scope = Scope.init(testing.allocator);
        defer scope.deinit();

        try testing.expectEqual(null, event.fire(.{1}));

        var declines: Handler = .{ .answer = null };
        var answers: Handler = .{ .answer = 100 };
        var never: Handler = .{ .answer = 5 };
        try event.subscribe(&scope, &declines, Handler.handle);
        try event.subscribe(&scope, &answers, Handler.handle);
        try event.subscribe(&scope, &never, Handler.handle);

        try testing.expectEqual(@as(?i32, 101), event.fire(.{1}));
        try testing.expectEqual(1, declines.calls);
        try testing.expectEqual(1, answers.calls);
        try testing.expectEqual(0, never.calls);
    }

    test "scope dispose unsubscribes" {
        const Sum = struct {
            total: i64 = 0,
            fn add(self: *@This(), a: i32, b: i32) void {
                self.total += a + b;
            }
        };

        var event: Event(fn (i32, i32) void) = .init(testing.allocator);
        defer event.deinit();
        var scope = Scope.init(testing.allocator);
        defer scope.deinit();

        var sum: Sum = .{};
        try event.subscribe(&scope, &sum, Sum.add);
        event.fire(.{ 2, 3 });
        try testing.expectEqual(5, sum.total);

        scope.dispose();
        event.fire(.{ 2, 3 });
        try testing.expectEqual(5, sum.total);
        try testing.expectEqual(0, event.count());
    }

    test "unscoped unsubscribe twice" {
        const Counter = struct {
            n: u32 = 0,
            fn bump(self: *@This()) void {
                self.n += 1;
            }
        };

        var event: Event(fn () void) = .init(testing.allocator);
        defer event.deinit();

        var counter: Counter = .{};
        const sub = try event.subscribeUnscoped(&counter, Counter.bump);
        event.fire(.{});
        sub.unsubscribe();
        sub.unsubscribe();
        event.fire(.{});
        try testing.expectEqual(1, counter.n);
    }

    test "handler changes subscriptions" {
        const Event0 = Event(fn () void);
        const Self_ = struct {
            event: *Event0,
            sub: ?Event0.Subscription = null,
            calls: u32 = 0,
            other_calls: u32 = 0,
            added: ?Event0.Subscription = null,

            fn once(self: *@This()) void {
                self.calls += 1;
                self.sub.?.unsubscribe();
                if (self.added == null) self.added = self.event.subscribeUnscoped(self, other) catch unreachable;
            }

            fn other(self: *@This()) void {
                self.other_calls += 1;
            }
        };

        var event: Event0 = .init(testing.allocator);
        defer event.deinit();

        var state: Self_ = .{ .event = &event };
        state.sub = try event.subscribeUnscoped(&state, Self_.once);

        event.fire(.{}); // `once` runs, removes itself, adds `other` for next time
        event.fire(.{}); // only `other`
        try testing.expectEqual(1, state.calls);
        try testing.expectEqual(1, state.other_calls);

        state.added.?.unsubscribe();
        try testing.expectEqual(0, event.count());
    }

    test "unsubscribe waits for handler" {
        const Blocking = struct {
            entered: std.atomic.Value(bool) = .init(false),
            release: std.atomic.Value(bool) = .init(false),
            finished: std.atomic.Value(bool) = .init(false),

            fn handle(self: *@This()) void {
                self.entered.store(true, .seq_cst);
                while (!self.release.load(.seq_cst)) std.Thread.yield() catch {};
                self.finished.store(true, .seq_cst);
            }
        };
        const E = Event(fn () void);

        var event: E = .init(testing.allocator);
        defer event.deinit();

        var state: Blocking = .{};
        const sub = try event.subscribeUnscoped(&state, Blocking.handle);

        const firer = try std.Thread.spawn(.{}, struct {
            fn run(e: *E) void {
                e.fire(.{});
            }
        }.run, .{&event});
        while (!state.entered.load(.seq_cst)) std.Thread.yield() catch {};

        var unsubscribed = std.atomic.Value(bool).init(false);
        const remover = try std.Thread.spawn(.{}, struct {
            fn run(s: E.Subscription, done: *std.atomic.Value(bool)) void {
                s.unsubscribe();
                done.store(true, .seq_cst);
            }
        }.run, .{ sub, &unsubscribed });

        try testing.io.sleep(.fromMilliseconds(20), .awake);
        try testing.expect(!unsubscribed.load(.seq_cst)); // blocked on the running handler

        state.release.store(true, .seq_cst);
        remover.join();
        firer.join();
        try testing.expect(state.finished.load(.seq_cst));
        try testing.expect(unsubscribed.load(.seq_cst));
    }

    test "churn while firing" {
        const Counter = struct {
            n: @import("tuft_arch").atomic.Value(u64) = .init(0),
            fn bump(self: *@This(), by: u64) void {
                _ = self.n.fetchAdd(by, .monotonic);
            }
        };
        const E = Event(fn (u64) void);

        var event: E = .init(testing.allocator);
        defer event.deinit();

        var stable: Counter = .{};
        var churn: Counter = .{};
        const stable_sub = try event.subscribeUnscoped(&stable, Counter.bump);
        defer stable_sub.unsubscribe();

        var stop = std.atomic.Value(bool).init(false);
        const firer = try std.Thread.spawn(.{}, struct {
            fn run(e: *E, s: *std.atomic.Value(bool)) void {
                while (!s.load(.acquire)) e.fire(.{1});
            }
        }.run, .{ &event, &stop });

        // Threads can be slow to start on a busy machine
        while (stable.n.load(.monotonic) == 0) std.Thread.yield() catch {};
        for (0..500) |_| {
            const sub = try event.subscribeUnscoped(&churn, Counter.bump);
            sub.unsubscribe();
        }
        stop.store(true, .release);
        firer.join();

        try testing.expect(stable.n.load(.monotonic) > 0);
        try testing.expectEqual(1, event.count());
    }

    test "alloc failure on unsubscribe" {
        const Counter = struct {
            n: u32 = 0,
            fn bump(self: *@This()) void {
                self.n += 1;
            }
        };

        var failing = std.testing.FailingAllocator.init(testing.allocator, .{});
        var event: Event(fn () void) = .init(failing.allocator());
        defer event.deinit();

        var a: Counter = .{};
        var b: Counter = .{};
        const sub_a = try event.subscribeUnscoped(&a, Counter.bump);
        const sub_b = try event.subscribeUnscoped(&b, Counter.bump);
        defer sub_b.unsubscribe();

        failing.fail_index = failing.alloc_index; // every further allocation fails
        sub_a.unsubscribe();
        event.fire(.{});
        try testing.expectEqual(0, a.n);
        try testing.expectEqual(1, b.n);
        failing.fail_index = std.math.maxInt(usize);
    }
};

test {
    _ = tests;
}
