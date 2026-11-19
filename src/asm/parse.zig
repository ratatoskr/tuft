//! Text to instructions, labels and data. Names point into the text.

const std = @import("std");

const root = @import("root.zig");
const Block = @import("Block.zig");
const Diagnostic = root.Diagnostic;
const Error = root.Error;
const Instruction = root.Instruction;
const Register = root.Register;
const Value = root.Value;

pub const Line = struct {
    label: ?[]const u8 = null,
    item: ?Block.Kind = null,
};

/// `arena` holds data values.
pub fn line(text: []const u8, number: u32, arena: std.mem.Allocator, diagnostic: ?*Diagnostic) Error!Line {
    var c: Cursor = .{ .s = withoutComment(text), .line = number, .diagnostic = diagnostic };
    var out: Line = .{};

    c.skipSpace();
    const start = c.i;
    const first = c.name();
    if (first.len != 0 and c.eat(':')) {
        out.label = first;
    } else {
        c.i = start;
    }

    c.skipSpace();
    if (c.done()) return out;
    const word_start = c.i;
    const word = c.name();
    if (dataUnit(word)) |unit| {
        out.item = .{ .data = try data(&c, unit, arena) };
    } else {
        c.i = word_start;
        out.item = .{ .instruction = try instructionAt(&c) };
    }
    return out;
}

/// For `assembleOne`.
pub fn instruction(text: []const u8, diagnostic: ?*Diagnostic) Error!Instruction {
    var c: Cursor = .{ .s = withoutComment(text), .line = 1, .diagnostic = diagnostic };
    return instructionAt(&c);
}

fn instructionAt(c: *Cursor) Error!Instruction {
    var prefixes: root.Prefixes = .{};
    var word: []const u8 = undefined;
    while (true) {
        c.skipSpace();
        word = c.name();
        if (word.len == 0) return c.fail(error.InvalidSyntax, "expected an instruction", .{});
        if (!prefix(&prefixes, word)) break;
    }
    var insn: Instruction = .{ .mnemonic = undefined, .prefixes = prefixes };
    if (root.Mnemonic.parse(word)) |m| {
        insn.mnemonic = m;
    } else if (std.ascii.eqlIgnoreCase(word, "retf")) {
        insn.mnemonic = .named("ret");
        insn.far = true;
    } else {
        return c.fail(error.UnknownMnemonic, "unknown instruction `{s}`", .{word});
    }

    c.skipSpace();
    const after_mnemonic = c.i;
    if (std.ascii.eqlIgnoreCase(c.name(), "far")) insn.far = true else c.i = after_mnemonic;
    c.skipSpace();
    while (!c.done()) {
        if (insn.operand_count == root.max_operands) return c.fail(error.InvalidSyntax, "too many operands", .{});
        insn.operands[insn.operand_count] = try operand(c);
        insn.operand_count += 1;
        c.skipSpace();
        while (c.eat('{')) {
            const close = std.mem.indexOfScalarPos(u8, c.s, c.i, '}') orelse return c.fail(error.InvalidSyntax, "expected `}}`", .{});
            const decoration = std.mem.trim(u8, c.s[c.i..close], " \t");
            c.i = close + 1;
            c.skipSpace();
            if (std.ascii.eqlIgnoreCase(decoration, "z")) {
                insn.zeroing = true;
            } else if (decoration.len > 0 and std.ascii.toLower(decoration[0]) == 'k' and Register.parse(decoration) != null) {
                insn.mask = Register.parse(decoration);
            } else {
                return c.fail(error.Unsupported, "AVX-512 broadcasts and rounding (`{{{s}}}`) aren't supported yet", .{decoration});
            }
        }
        if (c.done()) break;
        if (!c.eat(',')) return c.fail(error.InvalidSyntax, "expected `,` between operands", .{});
        c.skipSpace();
    }
    return insn;
}

fn prefix(p: *root.Prefixes, word: []const u8) bool {
    const Field = std.meta.FieldEnum(root.Prefixes);
    const table = [_]struct { []const u8, Field }{
        .{ "lock", .lock },         .{ "rep", .rep },           .{ "repe", .repe }, .{ "repz", .repe },
        .{ "repne", .repne },       .{ "repnz", .repne },       .{ "bnd", .bnd },   .{ "notrack", .notrack },
        .{ "xacquire", .xacquire }, .{ "xrelease", .xrelease },
    };
    for (table) |entry| {
        if (!std.ascii.eqlIgnoreCase(word, entry[0])) continue;
        switch (entry[1]) {
            inline else => |f| @field(p, @tagName(f)) = true,
        }
        return true;
    }
    return false;
}

fn operand(c: *Cursor) Error!root.Operand {
    if (c.peek() == '{') return c.fail(error.InvalidSyntax, "`{{...}}` goes after an operand", .{});

    // `dword ptr`, `fs:`, then `[...]`
    var size: u16 = 0;
    var segment: ?Register = null;
    const start = c.i;
    const word = c.name();
    if (sizeOf(word)) |s| {
        size = s;
        c.skipSpace();
        const after = c.i;
        if (!std.ascii.eqlIgnoreCase(c.name(), "ptr")) c.i = after;
        c.skipSpace();
    } else {
        c.i = start;
    }
    const seg_start = c.i;
    if (Register.parse(c.name())) |r| {
        c.skipSpace();
        if (c.eat(':')) segment = r else c.i = seg_start;
    } else {
        c.i = seg_start;
    }
    c.skipSpace();
    if (c.eat('[')) {
        var m = try memory(c);
        m.size = size;
        m.segment = segment;
        return .{ .mem = m };
    }
    if (size != 0 or segment != null) return c.fail(error.InvalidSyntax, "expected `[`", .{});

    // A register, `st(1)`, or a value
    const reg_start = c.i;
    const reg_word = c.name();
    if (std.ascii.eqlIgnoreCase(reg_word, "st") and c.eat('(')) {
        const digit = c.peek() orelse 0;
        if (digit < '0' or digit > '7') return c.fail(error.InvalidSyntax, "expected st(0) to st(7)", .{});
        c.i += 1;
        if (!c.eat(')')) return c.fail(error.InvalidSyntax, "expected `)`", .{});
        const name = [_]u8{ 's', 't', digit };
        return .{ .reg = Register.parse(&name).? };
    }
    if (Register.parse(reg_word)) |r| return .{ .reg = r };
    c.i = reg_start;
    const v = try value(c);
    // `0x1234:0x56789ABC`, a far pointer
    if (v.name == null and c.eat(':')) {
        const offset = (try c.number()) orelse return c.fail(error.InvalidSyntax, "expected an offset after `:`", .{});
        if (v.offset < 0 or v.offset > std.math.maxInt(u16) or offset > std.math.maxInt(u32)) {
            return c.fail(error.ValueOutOfRange, "a far pointer is a 16-bit segment and 32-bit offset", .{});
        }
        return .{ .ptr = .{ .segment = @intCast(v.offset), .offset = @intCast(offset) } };
    }
    return .{ .imm = v };
}

/// After `[`, up to `]`.
fn memory(c: *Cursor) Error!root.Mem {
    var m: root.Mem = .{};
    var first = true;
    while (true) {
        c.skipSpace();
        var negative = false;
        if (!first) {
            if (c.eat(']')) return m;
            if (c.eat('-')) {
                negative = true;
            } else if (!c.eat('+')) {
                return c.fail(error.InvalidSyntax, "expected `+`, `-` or `]`", .{});
            }
        } else if (c.eat('-')) {
            negative = true;
        }
        first = false;
        c.skipSpace();

        if (try c.number()) |n| {
            c.skipSpace();
            if (c.eat('*')) {
                // `8*rcx`
                c.skipSpace();
                const r = Register.parse(c.name()) orelse return c.fail(error.InvalidSyntax, "expected a register after `*`", .{});
                try setIndex(c, &m, r, n, negative);
            } else {
                m.disp.offset +%= if (negative) -%@as(i64, @bitCast(n)) else @as(i64, @bitCast(n));
            }
            continue;
        }
        const word = try c.nameOrQuoted();
        if (word.len == 0) return c.fail(error.InvalidSyntax, "expected a register, number or name", .{});
        if (Register.parse(word)) |r| {
            c.skipSpace();
            if (c.eat('*')) {
                c.skipSpace();
                const n = (try c.number()) orelse return c.fail(error.InvalidSyntax, "expected a scale after `*`", .{});
                try setIndex(c, &m, r, n, negative);
            } else if (negative) {
                return c.fail(error.InvalidSyntax, "registers can't be subtracted", .{});
            } else if (m.base == null) {
                m.base = r;
            } else if (m.index == null) {
                m.index = r;
                m.scale = 1;
            } else {
                return c.fail(error.InvalidSyntax, "too many registers", .{});
            }
            continue;
        }
        if (negative) return c.fail(error.InvalidSyntax, "names can't be subtracted", .{});
        if (m.disp.name != null) return c.fail(error.InvalidSyntax, "only one name per address", .{});
        m.disp.name = word;
    }
}

fn setIndex(c: *Cursor, m: *root.Mem, r: Register, scale: u64, negative: bool) Error!void {
    if (negative) return c.fail(error.InvalidSyntax, "registers can't be subtracted", .{});
    if (m.index != null) return c.fail(error.InvalidSyntax, "only one register can be scaled", .{});
    if (scale != 1 and scale != 2 and scale != 4 and scale != 8) return c.fail(error.InvalidSyntax, "scale has to be 1, 2, 4 or 8", .{});
    m.index = r;
    m.scale = @intCast(scale);
}

/// Numbers and at most one name, like `kai.exe+0x1234`.
fn value(c: *Cursor) Error!Value {
    var v: Value = .{};
    var first = true;
    while (true) {
        c.skipSpace();
        var negative = false;
        if (c.eat('-')) {
            negative = true;
        } else if (!c.eat('+') and !first) {
            return v;
        }
        c.skipSpace();
        first = false;
        if (try c.number()) |n| {
            v.offset +%= if (negative) -%@as(i64, @bitCast(n)) else @as(i64, @bitCast(n));
            continue;
        }
        const word = try c.nameOrQuoted();
        if (word.len == 0) return c.fail(error.InvalidSyntax, "expected a number or name", .{});
        if (negative) return c.fail(error.InvalidSyntax, "names can't be subtracted", .{});
        if (v.name != null) return c.fail(error.InvalidSyntax, "only one name per value", .{});
        v.name = word;
    }
}

/// `db 1, 2, "text"`, `dd 1.5`, `dq (double)2`
fn data(c: *Cursor, unit: u8, arena: std.mem.Allocator) Error!Block.Data {
    var values: std.ArrayList(Block.Datum) = .empty;
    const commas = std.mem.indexOfScalar(u8, c.s[c.i..], ',') != null;
    while (true) {
        c.skipSpace();
        if (c.done()) break;
        const datum = try datumAt(c, unit, commas, arena);
        try values.append(arena, datum);
        c.skipSpace();
        if (c.done()) break;
        if (commas and !c.eat(',')) return c.fail(error.InvalidSyntax, "expected `,` between values", .{});
    }
    if (values.items.len == 0) return c.fail(error.InvalidSyntax, "expected values", .{});
    return .{ .unit = unit, .values = values.items };
}

fn datumAt(c: *Cursor, unit: u8, commas: bool, arena: std.mem.Allocator) Error!Block.Datum {
    if ((c.peek() == 'x' or c.peek() == 'X') and c.i + 1 < c.s.len and c.s[c.i + 1] == '"') {
        if (unit != 1) return c.fail(error.InvalidSyntax, "x\"...\" bytes only go in `db`", .{});
        c.i += 1;
        return .{ .text = try hexBytes(c, try c.quoted(), arena) };
    }
    if (c.peek() == '"' or c.peek() == '\'') {
        if (unit != 1) return c.fail(error.InvalidSyntax, "text only goes in `db`", .{});
        return .{ .text = try c.quoted() };
    }
    const cast_float = c.eatWord("(float)");
    const cast_double = !cast_float and c.eatWord("(double)");
    c.skipSpace();
    // A float literal, or a cast number
    const token_end = tokenEnd(c, commas);
    const token = std.mem.trim(u8, c.s[c.i..token_end], " \t");
    if (cast_float or cast_double or looksFloat(token)) {
        if (unit != 4 and unit != 8) return c.fail(error.InvalidSyntax, "floats only go in `dd` or `dq`", .{});
        if ((cast_float and unit != 4) or (cast_double and unit != 8)) return c.fail(error.InvalidSyntax, "(float) goes in `dd`, (double) in `dq`", .{});
        const f = std.fmt.parseFloat(f64, token) catch return c.fail(error.InvalidSyntax, "expected a number, not `{s}`", .{token});
        c.i = token_end;
        return .{ .float = f };
    }
    if (commas) return .{ .value = try value(c) };
    // Space-separated, one token each
    var sub: Cursor = .{ .s = token, .line = c.line, .diagnostic = c.diagnostic };
    const v = try value(&sub);
    if (!sub.done()) return c.fail(error.InvalidSyntax, "unexpected `{s}`", .{sub.s[sub.i..]});
    c.i = token_end;
    return .{ .value = v };
}

/// `x"12 21 FF"` or `x"1221FF"`, hex pairs with optional spaces.
fn hexBytes(c: *Cursor, text: []const u8, arena: std.mem.Allocator) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (true) {
        while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
        if (i == text.len) break;
        var end = i;
        while (end < text.len and end < i + 2 and text[end] != ' ' and text[end] != '\t') end += 1;
        const pair = text[i..end];
        const n = out.items.len + 1;
        if (pair.len < 2) return c.fail(error.InvalidSyntax, "`{s}` isn't a hex byte. It's byte {d} of the x\"...\", and bytes are two digits", .{ pair, n });
        if (!std.ascii.isHex(pair[0]) or !std.ascii.isHex(pair[1])) return c.fail(error.InvalidSyntax, "`{s}` isn't a hex byte. It's byte {d} of the x\"...\"", .{ pair, n });
        try out.append(arena, std.fmt.parseInt(u8, pair, 16) catch unreachable);
        i = end;
    }
    if (out.items.len == 0) return c.fail(error.InvalidSyntax, "x\"\" has no bytes", .{});
    return out.items;
}

fn tokenEnd(c: *const Cursor, commas: bool) usize {
    var i = c.i;
    while (i < c.s.len) : (i += 1) {
        const ch = c.s[i];
        if (ch == ',' or (!commas and (ch == ' ' or ch == '\t'))) break;
    }
    return i;
}

/// Has a point, but isn't a name like `kai.exe`.
fn looksFloat(token: []const u8) bool {
    if (std.mem.indexOfScalar(u8, token, '.') == null) return false;
    _ = std.fmt.parseFloat(f64, token) catch return false;
    return true;
}

fn dataUnit(word: []const u8) ?u8 {
    const units = .{ .{ "db", 1 }, .{ "dw", 2 }, .{ "dd", 4 }, .{ "dq", 8 } };
    inline for (units) |u| {
        if (std.ascii.eqlIgnoreCase(word, u[0])) return u[1];
    }
    return null;
}

fn sizeOf(word: []const u8) ?u16 {
    const sizes = .{
        .{ "byte", 1 },   .{ "word", 2 },     .{ "dword", 4 },    .{ "fword", 6 },    .{ "qword", 8 },
        .{ "tbyte", 10 }, .{ "xmmword", 16 }, .{ "ymmword", 32 }, .{ "zmmword", 64 },
    };
    inline for (sizes) |s| {
        if (std.ascii.eqlIgnoreCase(word, s[0])) return s[1];
    }
    return null;
}

/// The line up to a `//` outside quotes.
fn withoutComment(text: []const u8) []const u8 {
    var quote: ?u8 = null;
    for (text, 0..) |ch, i| {
        if (quote) |q| {
            if (ch == q) quote = null;
            continue;
        }
        switch (ch) {
            '"', '\'' => quote = ch,
            '/' => if (i + 1 < text.len and text[i + 1] == '/') return text[0..i],
            else => {},
        }
    }
    return text;
}

/// A line's statements, split at `;` outside quotes, like `push rax; push rcx`. Comments go first.
pub const Statements = struct {
    rest: ?[]const u8,

    pub fn of(line_text: []const u8) Statements {
        return .{ .rest = withoutComment(line_text) };
    }

    pub fn next(self: *Statements) ?[]const u8 {
        const text = self.rest orelse return null;
        var quote: ?u8 = null;
        for (text, 0..) |ch, i| {
            if (quote) |q| {
                if (ch == q) quote = null;
                continue;
            }
            switch (ch) {
                '"', '\'' => quote = ch,
                ';' => {
                    self.rest = text[i + 1 ..];
                    return text[0..i];
                },
                else => {},
            }
        }
        self.rest = null;
        return text;
    }
};

fn isHex(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |ch| if (!std.ascii.isHex(ch)) return false;
    return true;
}

/// Says a name wasn't found, with a hint if it looks like hex.
pub fn unknownName(diagnostic: ?*Diagnostic, line_number: u32, word: []const u8) Error {
    const digits = if (word.len > 1 and (word[word.len - 1] == 'h' or word[word.len - 1] == 'H')) word[0 .. word.len - 1] else word;
    if (isHex(digits)) {
        Diagnostic.set(diagnostic, line_number, "{s} isn't a name. Hex starts with 0x or ends in h, like 0x{s} or 0{s}h", .{ word, digits, digits });
    } else {
        Diagnostic.set(diagnostic, line_number, "unknown name `{s}`", .{word});
    }
    return error.UnknownName;
}

const Cursor = struct {
    s: []const u8,
    i: usize = 0,
    line: u32,
    diagnostic: ?*Diagnostic,

    fn skipSpace(self: *Cursor) void {
        while (self.i < self.s.len and std.ascii.isWhitespace(self.s[self.i])) self.i += 1;
    }

    fn done(self: *Cursor) bool {
        self.skipSpace();
        return self.i >= self.s.len;
    }

    fn peek(self: *const Cursor) ?u8 {
        return if (self.i < self.s.len) self.s[self.i] else null;
    }

    fn eat(self: *Cursor, ch: u8) bool {
        if (self.peek() != ch) return false;
        self.i += 1;
        return true;
    }

    fn eatWord(self: *Cursor, word: []const u8) bool {
        if (!std.ascii.startsWithIgnoreCase(self.s[self.i..], word)) return false;
        self.i += word.len;
        return true;
    }

    /// Letters, digits and `_.@$?`, not starting with a digit.
    fn name(self: *Cursor) []const u8 {
        const start = self.i;
        if (self.i < self.s.len and std.ascii.isDigit(self.s[self.i])) return self.s[start..start];
        while (self.i < self.s.len) : (self.i += 1) {
            const ch = self.s[self.i];
            if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '.' and ch != '@' and ch != '$' and ch != '?') break;
        }
        return self.s[start..self.i];
    }

    fn nameOrQuoted(self: *Cursor) Error![]const u8 {
        if (self.peek() == '"') return self.quoted();
        return self.name();
    }

    fn quoted(self: *Cursor) Error![]const u8 {
        const q = self.s[self.i];
        self.i += 1;
        const start = self.i;
        const end = std.mem.indexOfScalarPos(u8, self.s, start, q) orelse return self.fail(error.InvalidSyntax, "unterminated text", .{});
        self.i = end + 1;
        return self.s[start..end];
    }

    /// Null if there's no number here.
    fn number(self: *Cursor) Error!?u64 {
        if (self.i >= self.s.len or !std.ascii.isDigit(self.s[self.i])) return null;
        const start = self.i;
        while (self.i < self.s.len and (std.ascii.isAlphanumeric(self.s[self.i]) or self.s[self.i] == '_')) self.i += 1;
        const text = self.s[start..self.i];
        const base: u8, const digits = if (text.len > 1 and (text[text.len - 1] == 'h' or text[text.len - 1] == 'H'))
            .{ 16, text[0 .. text.len - 1] }
        else if (std.ascii.startsWithIgnoreCase(text, "0x"))
            .{ 16, text[2..] }
        else if (std.ascii.startsWithIgnoreCase(text, "0b"))
            .{ 2, text[2..] }
        else
            .{ 10, text };
        return std.fmt.parseInt(u64, digits, base) catch |err| {
            if (err == error.InvalidCharacter and base == 10 and isHex(text)) return self.fail(error.InvalidSyntax, "`{s}` isn't a number. Hex starts with 0x or ends in h, like 0x{s} or {s}h", .{ text, text, text });
            return self.fail(error.InvalidSyntax, "`{s}` isn't a number", .{text});
        };
    }

    fn fail(self: *const Cursor, err: Error, comptime fmt: []const u8, args: anytype) Error {
        Diagnostic.set(self.diagnostic, self.line, fmt, args);
        return err;
    }
};

const tests = struct {
    const testing = std.testing;

    fn reg(comptime name: []const u8) Register {
        return .named(name);
    }

    test "operands" {
        const insn = try instruction("mov rax, qword ptr fs:[rbx+rcx*8-0x10]", null);
        try testing.expectEqual(2, insn.operand_count);
        try testing.expect(insn.operands[0].reg.eql(reg("rax")));
        const m = insn.operands[1].mem;
        try testing.expectEqual(8, m.size);
        try testing.expect(m.segment.?.eql(reg("fs")));
        try testing.expect(m.base.?.eql(reg("rbx")));
        try testing.expect(m.index.?.eql(reg("rcx")));
        try testing.expectEqual(8, m.scale);
        try testing.expectEqual(-16, m.disp.offset);

        try testing.expectEqual(16, (try instruction("push 16", null)).operands[0].imm.offset);
        try testing.expectEqual(16, (try instruction("push 0x10", null)).operands[0].imm.offset);
        try testing.expectEqual(-1, (try instruction("push -1", null)).operands[0].imm.offset);
        const named = (try instruction("jmp \"my-game.exe\"+16", null)).operands[0].imm;
        try testing.expectEqualStrings("my-game.exe", named.name.?);
        try testing.expectEqual(16, named.offset);
        try testing.expect((try instruction("fld st(1)", null)).operands[0].reg.eql(reg("st1")));
    }

    test "memory operand forms" {
        const m = (try instruction("lea eax, [4*ecx+edx+label]", null)).operands[1].mem;
        try testing.expectEqual(0, m.size);
        try testing.expect(m.index.?.eql(reg("ecx")));
        try testing.expectEqual(4, m.scale);
        try testing.expect(m.base.?.eql(reg("edx")));
        try testing.expectEqualStrings("label", m.disp.name.?);

        const two = (try instruction("mov eax, [ecx+edx]", null)).operands[1].mem;
        try testing.expect(two.index.?.eql(reg("edx")));
        try testing.expectEqual(1, two.scale);
    }

    test "prefixes, aliases and comments" {
        const insn = try instruction("lock inc dword ptr [eax] // comment", null);
        try testing.expect(insn.prefixes.lock);
        try testing.expectEqual(1, insn.operand_count);
        try testing.expectEqualStrings("jz", (try instruction("je 0", null)).mnemonic.text());
        try testing.expect((try instruction("rep movsb // copy", null)).prefixes.rep);
    }

    test "labels and data" {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const labelled = try line("loop: dec ecx", 1, a, null);
        try testing.expectEqualStrings("loop", labelled.label.?);
        try testing.expect(labelled.item.?.instruction.mnemonic.id == root.Mnemonic.named("dec").id);
        try testing.expectEqual(null, (try line("  done:  ", 1, a, null)).item);

        const bytes = (try line("db 144, 0x90, \"hi\"", 1, a, null)).item.?.data;
        try testing.expectEqual(1, bytes.unit);
        try testing.expectEqual(3, bytes.values.len);
        try testing.expectEqual(144, bytes.values[0].value.offset);
        try testing.expectEqualStrings("hi", bytes.values[2].text);

        const spaced = (try line("db 1 2 0x3", 1, a, null)).item.?.data;
        try testing.expectEqual(3, spaced.values.len);
        try testing.expectEqual(3, spaced.values[2].value.offset);

        try testing.expectEqual(1.5, (try line("dd 1.5", 1, a, null)).item.?.data.values[0].float);
        try testing.expectEqual(2, (try line("dq (double)2", 1, a, null)).item.?.data.values[0].float);
        try testing.expectEqualStrings("target", (try line("dq target+8", 1, a, null)).item.?.data.values[0].value.name.?);
    }

    test "error locations" {
        var d: Diagnostic = .{};
        try testing.expectError(error.UnknownMnemonic, instruction("mvo eax, 1", &d));
        try testing.expectEqualStrings("unknown instruction `mvo`", d.message());
        try testing.expectError(error.InvalidSyntax, instruction("mov eax, 1f", &d));
        try testing.expectEqualStrings("`1f` isn't a number. Hex starts with 0x or ends in h, like 0x1f or 1fh", d.message());
        try testing.expectEqual(0x10, (try instruction("mov eax, 10h", null)).operands[1].imm.offset);
        try testing.expectEqual(0xFF, (try instruction("mov eax, [ebx+0FFH]", null)).operands[1].mem.disp.offset);
        try testing.expect((try instruction("mov ah, 1", null)).operands[0].reg.eql(reg("ah")));
        try testing.expectError(error.InvalidSyntax, instruction("mov eax, [eax*3]", &d));
        try testing.expectError(error.InvalidSyntax, instruction("mov eax ecx", &d));
        try testing.expectError(error.Unsupported, instruction("vaddps zmm0, zmm1, dword ptr [rax] {1to16}", &d));

        const masked = try instruction("vaddps zmm0 {k1}{z}, zmm1, zmm2", null);
        try testing.expect(masked.mask.?.eql(reg("k1")));
        try testing.expect(masked.zeroing);
        try testing.expectEqual(3, masked.operand_count);
        const far = (try instruction("jmp far 0x10:0x2000", null));
        try testing.expect(far.far);
        try testing.expectEqual(root.Operand.Pointer{ .segment = 0x10, .offset = 0x2000 }, far.operands[0].ptr);
    }
};

test {
    _ = tests;
}
