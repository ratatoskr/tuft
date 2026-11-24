//! Text for where something is, like `game.exe+0x10`, `[player.base]+8`, `kernel32.dll!Sleep`,
//! `Game.Player:Update+0x3a`, `"odd-name.dll"+0x10` or `sig("48 8B 05 ??", Rip)`. Numbers are
//! decimal unless they start with 0x or end in h, like `0FFh`. Names go to `Symbols`, and `(name)` is
//! the same as `name`.
//! Math is `+ - * / %`, with `* / %` first, wrapping like pointer math.

const std = @import("std");

const root = @import("root.zig");
const Symbols = root.Symbols;
const Memory = root.Memory;
const Sig = @import("Sig.zig");

pub const Env = struct {
    symbols: Symbols = .none,
    /// For `[x]`. Without it they can't be read.
    memory: ?Memory = null,
    /// Looked up before `symbols`, like a tweak's own names.
    scope: Symbols = .none,
    /// What text starting with + or - is relative to, like a group's address. Without it a
    /// leading - is just negative.
    base: ?usize = null,
};

pub const Error = error{ NoAddress, InvalidAddress, UnknownName, Unreadable, NotFound };

/// What went wrong, said plainly.
pub const Problem = @import("tuft_text").Message(256);

/// Where `text` is now. Follows pointers and scans, so ask again later if things move.
pub fn eval(text: []const u8, env: Env, problem: ?*Problem) Error!usize {
    var p: Parser = .{ .text = text, .env = env, .problem = problem };
    p.skip();
    if (p.at == text.len) return p.fail(error.NoAddress, "there's no address", .{});
    const first = text[p.at];
    const v = if (first == '+' or (first == '-' and env.base != null)) blk: {
        const base = env.base orelse return p.fail(error.InvalidAddress, "{s} is relative, so it has to be in a group with an address", .{std.mem.trim(u8, text, " \t")});
        break :blk try p.sumFrom(base);
    } else try p.sum();
    p.skip();
    if (p.at < text.len) return p.fail(error.InvalidAddress, "didn't expect {s}", .{p.rest()});
    return v;
}

/// Follows `offsets` from `start`, reading a pointer then adding each one, Cheat Engine style.
pub fn follow(memory: Memory, start: usize, offsets: []const isize) Memory.Error!usize {
    var at = start;
    for (offsets) |offset| {
        const pointer = try memory.load(usize, at);
        at = pointer +% @as(usize, @bitCast(offset));
    }
    return at;
}

/// `16`, `0x10`, `-0x10`.
pub fn parseOffset(text: []const u8) error{InvalidAddress}!isize {
    var t = std.mem.trim(u8, text, " \t");
    const negative = std.mem.startsWith(u8, t, "-");
    if (negative or std.mem.startsWith(u8, t, "+")) t = std.mem.trim(u8, t[1..], " \t");
    const magnitude: isize = @bitCast(parseNumber(t) orelse return error.InvalidAddress);
    return if (negative) 0 -% magnitude else magnitude;
}

/// `16`, `0x10`, `10h` or `0b10000`. Hex ending in h starts with a digit, so `0FFh` and not `FFh`.
pub fn parseNumber(t: []const u8) ?usize {
    return parseUnsigned(usize, t) catch null;
}

/// `parseNumber` for any unsigned int.
pub fn parseUnsigned(comptime T: type, t: []const u8) std.fmt.ParseIntError!T {
    if (t.len > 1 and std.ascii.isDigit(t[0]) and (t[t.len - 1] == 'h' or t[t.len - 1] == 'H')) return std.fmt.parseInt(T, t[0 .. t.len - 1], 16);
    if (t.len > 2 and t[0] == '0' and (t[1] == 'x' or t[1] == 'X')) return std.fmt.parseInt(T, t[2..], 16);
    if (t.len > 2 and t[0] == '0' and (t[1] == 'b' or t[1] == 'B')) return std.fmt.parseInt(T, t[2..], 2);
    return std.fmt.parseInt(T, t, 10);
}

const Parser = struct {
    text: []const u8,
    env: Env,
    problem: ?*Problem,
    at: usize = 0,

    fn fail(self: *Parser, err: Error, comptime fmt: []const u8, args: anytype) Error {
        if (self.problem) |p| p.print(fmt, args);
        return err;
    }

    fn skip(self: *Parser) void {
        while (self.at < self.text.len and (self.text[self.at] == ' ' or self.text[self.at] == '\t')) self.at += 1;
    }

    fn rest(self: *const Parser) []const u8 {
        return self.text[self.at..];
    }

    fn peek(self: *Parser) ?u8 {
        self.skip();
        return if (self.at < self.text.len) self.text[self.at] else null;
    }

    fn eat(self: *Parser, ch: u8) bool {
        if (self.peek() != ch) return false;
        self.at += 1;
        return true;
    }

    fn expect(self: *Parser, ch: u8) Error!void {
        if (self.eat(ch)) return;
        if (self.at >= self.text.len) return self.fail(error.InvalidAddress, "expected {c} at the end", .{ch});
        return self.fail(error.InvalidAddress, "expected {c}, not {s}", .{ ch, self.rest() });
    }

    fn sum(self: *Parser) Error!usize {
        return self.sumFrom(try self.product());
    }

    fn sumFrom(self: *Parser, start: usize) Error!usize {
        var v = start;
        while (true) {
            if (self.eat('+')) {
                v +%= try self.product();
            } else if (self.eat('-')) {
                v -%= try self.product();
            } else return v;
        }
    }

    fn product(self: *Parser) Error!usize {
        var v = try self.term();
        while (true) {
            if (self.eat('*')) {
                v *%= try self.term();
            } else if (self.eat('/')) {
                v /= try self.divisor('/');
            } else if (self.eat('%')) {
                v %= try self.divisor('%');
            } else return v;
        }
    }

    fn divisor(self: *Parser, op: u8) Error!usize {
        const start = self.at;
        const v = try self.term();
        if (v == 0) return self.fail(error.InvalidAddress, "{c}{s} divides by zero", .{ op, std.mem.trim(u8, self.text[start..self.at], " \t") });
        return v;
    }

    fn term(self: *Parser) Error!usize {
        const ch = self.peek() orelse return self.fail(error.InvalidAddress, "it ends too soon", .{});
        switch (ch) {
            '-' => {
                self.at += 1;
                return 0 -% try self.term();
            },
            '(' => {
                self.at += 1;
                const v = try self.sum();
                try self.expect(')');
                return v;
            },
            '[' => {
                self.at += 1;
                const v = try self.sum();
                try self.expect(']');
                const memory = self.env.memory orelse return self.fail(error.Unreadable, "can't read [0x{x}] here", .{v});
                return memory.load(usize, v) catch self.fail(error.Unreadable, "can't read [0x{x}]", .{v});
            },
            '"' => return self.name(try self.string()),
            '0'...'9' => return self.number(),
            else => {},
        }
        if (!isNameStart(ch)) return self.fail(error.InvalidAddress, "didn't expect {s}", .{self.rest()});
        const start = self.at;
        const w = self.word();
        if (std.mem.eql(u8, w, "sig") and self.peek() == '(') return self.sig(start);
        return self.name(w);
    }

    fn word(self: *Parser) []const u8 {
        const start = self.at;
        while (self.at < self.text.len) : (self.at += 1) {
            const ch = self.text[self.at];
            if (isNameChar(ch)) continue;
            // `Class:Method`, as C# methods are named. Not `fs:[...]`
            if (ch == ':' and self.at > start and self.at + 1 < self.text.len and isNameStart(self.text[self.at + 1])) continue;
            break;
        }
        return self.text[start..self.at];
    }

    fn string(self: *Parser) Error![]const u8 {
        if (!self.eat('"')) return self.fail(error.InvalidAddress, "expected \"text\", not {s}", .{self.rest()});
        const start = self.at;
        const end = std.mem.indexOfScalarPos(u8, self.text, start, '"') orelse return self.fail(error.InvalidAddress, "a \" isn't closed", .{});
        self.at = end + 1;
        return self.text[start..end];
    }

    fn number(self: *Parser) Error!usize {
        const t = self.word();
        if (parseNumber(t)) |n| return n;
        if (std.fmt.parseInt(usize, t, 16)) |_| {
            return self.fail(error.InvalidAddress, "{s} isn't a number. Hex starts with 0x or ends in h, like 0x{s} or {s}h", .{ t, t, t });
        } else |_| {}
        return self.fail(error.InvalidAddress, "{s} isn't a number", .{t});
    }

    fn name(self: *Parser, n: []const u8) Error!usize {
        if (self.env.scope.resolve(n)) |v| return v;
        if (self.env.symbols.resolve(n)) |v| return v;
        var buf: [@typeInfo(@FieldType(Problem, "buf")).array.len]u8 = undefined;
        const miss = self.env.scope.why(n, &buf) orelse self.env.symbols.why(n, &buf) orelse {
            if (hexDigits(n)) |d| return self.fail(error.UnknownName, "there's no {s}. Hex starts with 0x or ends in h, like 0x{s} or 0{s}h", .{ n, d, d });
            return self.fail(error.UnknownName, "there's no {s}", .{n});
        };
        return self.fail(miss.err, "{s}: {s}", .{ n, miss.message });
    }

    /// `sig("48 8B ??", Rip, Follow, Rel32, Offset(n), Module("x.dll"), Section(".data"))`. The whole
    /// image without a `Section`.
    fn sig(self: *Parser, start: usize) Error!usize {
        try self.expect('(');
        var s: Sig = .{ .pattern = try self.string(), .section = "" };
        var steps: [16]Sig.Step = undefined;
        var n: usize = 0;
        while (self.eat(',')) {
            self.skip();
            const step = self.word();
            if (std.mem.eql(u8, step, "Module")) {
                try self.expect('(');
                s.module = try self.string();
                try self.expect(')');
                continue;
            }
            if (std.mem.eql(u8, step, "Section")) {
                try self.expect('(');
                s.section = try self.string();
                try self.expect(')');
                continue;
            }
            if (n == steps.len) return self.fail(error.InvalidAddress, "that's too many steps", .{});
            if (std.mem.eql(u8, step, "Rip")) {
                steps[n] = .rip;
            } else if (std.mem.eql(u8, step, "Follow")) {
                steps[n] = .follow;
            } else if (std.mem.eql(u8, step, "Rel32")) {
                steps[n] = .rel32;
            } else if (std.mem.eql(u8, step, "Offset")) {
                try self.expect('(');
                steps[n] = .{ .offset = @bitCast(try self.sum()) };
                try self.expect(')');
            } else {
                return self.fail(error.InvalidAddress, "there's no step {s}. It's Rip, Follow, Rel32, Offset(n), Module(\"x\") or Section(\".x\")", .{step});
            }
            n += 1;
        }
        try self.expect(')');
        s.resolve = steps[0..n];
        const label = self.text[start..self.at];
        const shown = if (label.len > max_shown) label[0..max_shown] else label;
        const more = if (label.len > max_shown) "..." else "";
        return self.env.symbols.scan(s, label).unwrap() catch |err| switch (err) {
            error.PatternNotFound, error.SignatureNotFound => self.fail(error.NotFound, "{s}{s} wasn't found", .{ shown, more }),
            error.PatternNotUnique => self.fail(error.NotFound, "{s}{s} matches more than once", .{ shown, more }),
            error.NotScanned => self.fail(error.NotFound, "{s}{s} hasn't been scanned yet", .{ shown, more }),
            else => self.fail(error.NotFound, "{s}{s}: {t}", .{ shown, more, err }),
        };
    }

    /// Of a sig's text in messages, so what went wrong still fits.
    const max_shown = 160;
};

fn isNameStart(ch: u8) bool {
    return std.ascii.isAlphabetic(ch) or ch == '_';
}

fn isNameChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '.' or ch == '!';
}

/// The digits of a name that's probably hex, like `FF` or `FFh`.
fn hexDigits(n: []const u8) ?[]const u8 {
    const d = if (n.len > 1 and (n[n.len - 1] == 'h' or n[n.len - 1] == 'H')) n[0 .. n.len - 1] else n;
    if (d.len == 0) return null;
    for (d) |ch| if (!std.ascii.isHex(ch)) return null;
    return d;
}

const tests = struct {
    const testing = std.testing;

    const Names = struct {
        fn resolve(_: ?*anyopaque, n: []const u8) ?usize {
            if (std.mem.eql(u8, n, "player.health")) return 0x1000;
            if (std.mem.eql(u8, n, "odd-name")) return 0x2000;
            if (std.mem.eql(u8, n, "Game.Player:Update")) return 0x3000;
            return null;
        }
    };
    const names: Symbols = .{ .vtable = &.{ .resolve = Names.resolve } };

    fn expectEval(want: usize, text: []const u8, env: Env) !void {
        var problem: Problem = .{};
        const got = eval(text, env, &problem) catch |err| {
            std.debug.print("{s}: {t} {s}\n", .{ text, err, problem.message() });
            return err;
        };
        try testing.expectEqual(want, got);
    }

    fn expectProblem(text: []const u8, env: Env, want: Error, message: []const u8) !void {
        var problem: Problem = .{};
        try testing.expectError(want, eval(text, env, &problem));
        try testing.expectEqualStrings(message, problem.message());
    }

    test "numbers, names and sums" {
        const env: Env = .{ .symbols = names };
        try expectEval(16, "16", env);
        try expectEval(0x10, " 0x10 ", env);
        try expectEval(0x1008, "player.health+8", env);
        try expectEval(0x1008, "(player.health) + 0x8", env);
        try expectEval(0x2000 - 2, "\"odd-name\" - 2", env);
        try expectEval(0x1000 - 0x10 + 3, "player.health - (0x10 - 3)", env);
        try expectEval(5, "-(-5)", env);
        try expectEval(0x303a, "Game.Player:Update+0x3a", env);
        try expectProblem("player.health:[8]", env, error.InvalidAddress, "didn't expect :[8]");
        try expectProblem("7FF6", env, error.InvalidAddress, "7FF6 isn't a number. Hex starts with 0x or ends in h, like 0x7FF6 or 7FF6h");
        try expectProblem("nobody+4", env, error.UnknownName, "there's no nobody");
        try expectProblem("4 4", env, error.InvalidAddress, "didn't expect 4");
        try expectProblem("(4", env, error.InvalidAddress, "expected ) at the end");
        try expectProblem("  ", env, error.NoAddress, "there's no address");
    }

    test "hex ending in h" {
        const Regs = struct {
            fn resolve(_: ?*anyopaque, n: []const u8) ?usize {
                return if (std.mem.eql(u8, n, "ah")) 0xA0 else null;
            }
        };
        const env: Env = .{ .symbols = .{ .vtable = &.{ .resolve = Regs.resolve } } };
        try expectEval(0x10, "0x10", env);
        try expectEval(0x10, "10h", env);
        try expectEval(0xFF, "0FFh", env);
        try expectEval(0xFF + 0x10, "0ffH + 10h", env);
        try expectEval(0xA0, "ah", env);
        try expectProblem("FFh", env, error.UnknownName, "there's no FFh. Hex starts with 0x or ends in h, like 0xFF or 0FFh");
        try expectProblem("1Gh", env, error.InvalidAddress, "1Gh isn't a number");
        try testing.expectEqual(-0x10, try parseOffset("-10h"));
    }

    test "times, divide and remainder" {
        const env: Env = .{ .symbols = names };
        try expectEval(0x1000 + 4 * 0x1A, "player.health+4*0x1A", env);
        try expectEval(2 + 12, "2 + 3 * 4", env);
        try expectEval(20, "(2 + 3) * 4", env);
        try expectEval(7 - 6 / 4, "7 - 6 / 4", env);
        try expectEval(0x10 + 10 % 4, "0x10 + 10 % 4", env);
        try expectEval(0 -% @as(usize, 6), "-2*3", env);
        try expectEval(0x1000, "2*(player.health/2 - 0x300) + 0x500 * 2 - 0x400", env);
        try expectProblem("8/0", env, error.InvalidAddress, "/0 divides by zero");
        try expectProblem("8 % (4-4)", env, error.InvalidAddress, "%(4-4) divides by zero");
        try expectProblem("4*", env, error.InvalidAddress, "it ends too soon");
    }

    test "pointers and scope" {
        var value: usize = 0x500;
        const Scope = struct {
            var at: usize = 0;
            fn resolve(_: ?*anyopaque, n: []const u8) ?usize {
                return if (std.mem.eql(u8, n, "here")) at else null;
            }
        };
        Scope.at = @intFromPtr(&value);
        const env: Env = .{ .symbols = names, .memory = .local, .scope = .{ .vtable = &.{ .resolve = Scope.resolve } } };
        try expectEval(0x508, "[here]+8", env);
        try expectEval(0x1000, "player.health", env);
        var buf: [64]u8 = undefined;
        try expectProblem("[here]", .{ .scope = env.scope }, error.Unreadable, try std.fmt.bufPrint(&buf, "can't read [0x{x}] here", .{Scope.at}));
        var chain = [_]usize{@intFromPtr(&value)};
        try testing.expectEqual(0x500 - 0x10, try follow(.local, @intFromPtr(&chain), &.{ 0, -0x10 }));
        try testing.expectEqual(-0x10, try parseOffset("-0x10"));
        try testing.expectEqual(16, try parseOffset("16"));
    }

    test "relative to a base" {
        const env: Env = .{ .symbols = names, .base = 0x5000 };
        try expectEval(0x5010, "+0x10", env);
        try expectEval(0x5000 - 8, " -8", env);
        try expectEval(0x5010 + 4, "+0x10 + 4", env);
        try expectEval(0x1000, "player.health", env);
        try expectEval(0x5000 + 0x1000, "+player.health", env);
        try expectEval(0x5000, "+0x218*0", env);
        try expectEval(0x5000 + 0x68, "+4*0x1A", env);
        try expectEval(0x5000 - 0x30, "-0x10*3", env);
        try expectProblem("+0x10", .{ .symbols = names }, error.InvalidAddress, "+0x10 is relative, so it has to be in a group with an address");
        try expectEval(0 -% @as(usize, 8), "-8", .{ .symbols = names });
    }

    test "known names say why they missed" {
        const Known = struct {
            fn why(_: ?*anyopaque, n: []const u8, buf: []u8) ?Symbols.Miss {
                if (std.mem.eql(u8, n, "kai.hp")) return .{ .err = error.Unreadable, .message = std.fmt.bufPrint(buf, "can't read [0x{x}]", .{0x1234}) catch return null };
                if (std.mem.eql(u8, n, "Game.instance")) return .{ .err = error.NotFound, .message = "sig(\"48 8B 0D\", Rip) wasn't found" };
                return null;
            }
        };
        const env: Env = .{ .symbols = .{ .vtable = &.{ .resolve = Names.resolve, .why = Known.why } } };
        try expectProblem("[kai.hp]+4", env, error.Unreadable, "kai.hp: can't read [0x1234]");
        try expectProblem("Game.instance", env, error.NotFound, "Game.instance: sig(\"48 8B 0D\", Rip) wasn't found");
        try expectProblem("nobody", env, error.UnknownName, "there's no nobody");
        try expectEval(0x1000, "player.health", env);
        // The scope's reason comes first
        const scope: Symbols = .{ .vtable = &.{ .why = struct {
            fn why(_: ?*anyopaque, _: []const u8, _: []u8) ?Symbols.Miss {
                return .{ .err = error.InvalidAddress, .message = "didn't expect !" };
            }
        }.why } };
        try expectProblem("kai.hp", .{ .symbols = env.symbols, .scope = scope }, error.InvalidAddress, "kai.hp: didn't expect !");
    }

    test "modules, exports and sigs" {
        // The sig that's meant to miss logs a warning, and output fails the run
        const saved = testing.log_level;
        testing.log_level = .err;
        defer testing.log_level = saved;
        const env: Env = .{ .symbols = .local, .memory = .local };
        const kernel32 = Symbols.local.resolve("kernel32.dll").?;
        try expectEval(kernel32 + 0x10, "KERNEL32.DLL + 0x10", env);
        try expectEval(Symbols.local.resolve("kernel32.dll!Sleep").?, "kernel32.dll!Sleep", env);
        var problem: Problem = .{};
        try testing.expectError(error.NotFound, eval("sig(\"DE AD BE EF 13 37 C0 DE 13 37 C0 DE AA\", Module(\"kernel32.dll\"))", env, &problem));
        try testing.expectEqualStrings("sig(\"DE AD BE EF 13 37 C0 DE 13 37 C0 DE AA\", Module(\"kernel32.dll\")) wasn't found", problem.message());
        try expectProblem("sig(\"90\", Bogus)", env, error.InvalidAddress, "there's no step Bogus. It's Rip, Follow, Rel32, Offset(n), Module(\"x\") or Section(\".x\")");
    }
};

test {
    _ = tests;
}
