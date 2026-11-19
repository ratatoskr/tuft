//! tuft_asm tests.

const std = @import("std");
const testing = std.testing;

const tuft_asm = @import("root.zig");
const disasm = tuft_asm.disasm;
const Diagnostic = tuft_asm.Diagnostic;

const is64 = tuft_asm.is64;
const at: usize = 0x1000_0000;

fn assemble(text: []const u8, options: tuft_asm.Options) !tuft_asm.Block.Code {
    var d: Diagnostic = .{};
    return tuft_asm.assemble(testing.allocator, text, options, &d) catch |err| {
        std.debug.print("line {d}: {s}\n", .{ d.line, d.message() });
        return err;
    };
}

fn repeat(comptime s: []const u8, comptime n: usize) []const u8 {
    return comptime blk: {
        var out: []const u8 = "";
        for (0..n) |_| out = out ++ s;
        break :blk out;
    };
}

fn expectBytes(expected: []const u8, text: []const u8) !void {
    var code = try assemble(text, .{ .address = at });
    defer code.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, expected, code.bytes);
}

fn listing(buf: []u8, bytes: []const u8, address: usize) ![]const u8 {
    var len: usize = 0;
    var offset: usize = 0;
    while (offset < bytes.len) {
        const insn = disasm.decode(bytes[offset..], address + offset) orelse return error.DoesNotDecode;
        len += (try std.fmt.bufPrint(buf[len..], "{s}{s}", .{ if (len == 0) "" else "\n", insn.text() })).len;
        offset += insn.len;
    }
    return buf[0..len];
}

fn expectListing(expected: []const u8, text: []const u8) !void {
    var code = try assemble(text, .{ .address = at });
    defer code.deinit(testing.allocator);
    var buf: [1024]u8 = undefined;
    try testing.expectEqualStrings(expected, try listing(&buf, code.bytes, at));
}

test "single instructions" {
    try expectBytes(&.{0xC3}, "ret");
    try expectBytes(&.{ 0x6A, 0x10 }, "push 16");
    try expectBytes(&.{ 0x6A, 0x10 }, "push 0x10");
    try expectBytes(&.{ 0xB8, 0x10, 0, 0, 0 }, "mov eax, 0x10");
    try expectBytes(&.{ 0xF0, 0xFF, 0x00 }, "lock inc dword ptr [" ++ (if (is64) "rax" else "eax") ++ "]");

    var d: Diagnostic = .{};
    const one = try tuft_asm.assembleOne("jmp 0x10000010", .{ .address = at }, &d);
    try testing.expectEqualSlices(u8, &.{ 0xEB, 0x0E }, one.slice());
}

test "expect compares disassembly, so any encoding matches" {
    // mov eax, ecx two ways, then add eax, 0x98 with a 4-byte immediate
    const code = [_]u8{ 0x89, 0xC8, 0x8B, 0xC1, 0x05, 0x98, 0, 0, 0, 0xC3 };
    var d: Diagnostic = .{};
    var m: tuft_asm.Mismatch = .{};
    try testing.expectEqual(9, (try tuft_asm.expectAt(testing.allocator, "mov eax, ecx; mov eax, ecx\nadd eax, 0x98", &code, at, null, &d, &m)).?);
    try testing.expectEqual(null, try tuft_asm.expectAt(testing.allocator, "mov eax, ecx; mov eax, edx", &code, at, null, &d, &m));
    try testing.expectEqual(1, m.index);
    try testing.expectEqualStrings("mov eax, edx", m.expected());
    try testing.expectEqualStrings("mov eax, ecx", m.found());
    try testing.expectError(error.InvalidSyntax, tuft_asm.expectAt(testing.allocator, "top: db 1", &code, at, null, &d, &m));
    try testing.expectError(error.UnknownMnemonic, tuft_asm.expectAt(testing.allocator, "bogus", &code, at, null, &d, &m));
}

test "; separates statements and // comments" {
    var d: Diagnostic = .{};
    var code = try tuft_asm.assemble(testing.allocator, "top: nop; nop // nop; nop\ndb \"a;b\"; ret", .{ .address = at }, &d);
    defer code.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, &.{ 0x90, 0x90, 'a', ';', 'b', 0xC3 }, code.bytes);
    try testing.expectError(error.UnknownMnemonic, tuft_asm.assemble(testing.allocator, "nop\nnop; bogus", .{ .address = at }, &d));
    try testing.expectEqual(2, d.line);
}

test "far branches go through the address after them" {
    if (!is64) return error.SkipZigTest;
    const addr = [_]u8{ 0x34, 0x12, 0, 0, 0xF0, 0x7F, 0, 0 };
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "jmp 0x7FF000001234", &[_]u8{ 0xFF, 0x25, 0, 0, 0, 0 } ++ addr },
        .{ "call 0x7FF000001234", &[_]u8{ 0xFF, 0x15, 2, 0, 0, 0, 0xEB, 8 } ++ addr },
        // The opposite jcc skips it
        .{ "jz 0x7FF000001234", &[_]u8{ 0x75, 14, 0xFF, 0x25, 0, 0, 0, 0 } ++ addr },
    };
    for (cases) |case| {
        var d: Diagnostic = .{};
        const encoded = try tuft_asm.assembleOne(case[0], .{ .address = 0x10000 }, &d);
        try testing.expectEqualSlices(u8, case[1], encoded.slice());
    }
    // In a block, with labels around it
    var d: Diagnostic = .{};
    var code = try tuft_asm.assemble(testing.allocator, "top: jnz 0x7FF000001234\njmp top", .{ .address = 0x10000 }, &d);
    defer code.deinit(testing.allocator);
    try testing.expectEqual(16 + 2, code.bytes.len);
    try testing.expectEqualSlices(u8, &.{ 0xEB, 0xEE }, code.bytes[16..]);
}

test "xchg eax stays xchg" {
    try expectBytes(&.{0x90}, "nop");
    try expectBytes(&.{ 0x87, 0xC0 }, "xchg eax, eax");
    try expectBytes(&.{ 0x66, 0x87, 0xC0 }, "xchg ax, ax");
    try expectListing("xchg eax, eax", "xchg eax, eax");
    if (is64) try expectBytes(&.{ 0x48, 0x87, 0xC0 }, "xchg rax, rax");
    try expectListing("xchg ecx, eax", "xchg ecx, eax");
}

test "AVX-512 masks" {
    try expectListing("vaddps zmm0 {k1} {z}, zmm1, zmm2", "vaddps zmm0 {k1}{z}, zmm1, zmm2");
    try expectListing("vaddps zmm0, zmm1, zmm2", "vaddps zmm0, zmm1, zmm2");
}

test "memory operand size" {
    const r = if (is64) "rax" else "eax";
    try expectListing("mov dword ptr [" ++ r ++ "], ecx", "mov [" ++ r ++ "], ecx");
    try expectListing("mov byte ptr [" ++ r ++ "], cl", "mov [" ++ r ++ "], cl");
    try expectListing("inc dword ptr [" ++ r ++ "]", "inc [" ++ r ++ "]");
    try expectListing("mov word ptr [" ++ r ++ "], 0x1", "mov word ptr [" ++ r ++ "], 1");
    try expectListing("movss xmm0, dword ptr [" ++ r ++ "+0x10]", "movss xmm0, [" ++ r ++ "+16]");
}

test "labels short and long" {
    var code = try assemble(
        \\top:
        \\    dec ecx
        \\    jnz top     // short, backwards
        \\    je near_end // short, forwards
        \\    jmp far_end // past 200 bytes: long
        \\near_end:
        \\    db
    ++ comptime repeat(" 0x90", 200) ++ "\n" ++
        \\far_end:
        \\    ret
    , .{ .address = at });
    defer code.deinit(testing.allocator);

    const dec_len: usize = if (is64) 2 else 1;
    const top = code.labelAddress("top").?;
    const near_end = code.labelAddress("near_end").?;
    const far_end = code.labelAddress("far_end").?;
    try testing.expectEqual(at, top);
    try testing.expectEqual(at + dec_len + 2 + 2 + 5, near_end);
    try testing.expectEqual(near_end + 200, far_end);
    try testing.expectEqual(0xC3, code.bytes[code.bytes.len - 1]);

    const jnz = disasm.decode(code.bytes[dec_len..], at + dec_len).?;
    try testing.expectEqual(2, jnz.len);
    var expected: [64]u8 = undefined;
    try testing.expectEqualStrings(try std.fmt.bufPrint(&expected, "jnz 0x{x}", .{top}), jnz.text());
    try testing.expectEqual(0xE9, code.bytes[dec_len + 4]);
}

test "x64 RIP-relative and data" {
    var code = try assemble(
        \\    mov eax, [value]
        \\    ret
        \\value:
        \\    dd 42
        \\    db 1, 0x90, "hi"
        \\    dw 0x1234
        \\    dd 1.5
        \\    dq (double)2, value
    , .{ .address = at });
    defer code.deinit(testing.allocator);
    const value = code.labelAddress("value").?;

    const mov = disasm.decode(code.bytes, at).?;
    var expected: [64]u8 = undefined;
    try testing.expectEqualStrings(try std.fmt.bufPrint(&expected, "mov eax, dword ptr [0x{x}]", .{value}), mov.text());
    if (is64) try testing.expectEqual(0x05, code.bytes[1]); // ModR/M: [rip+disp32]

    const data = code.bytes[value - at ..];
    try testing.expectEqualSlices(u8, &.{ 42, 0, 0, 0, 1, 0x90, 'h', 'i', 0x34, 0x12 }, data[0..10]);
    try testing.expectEqual(@as(f32, 1.5), @as(f32, @bitCast(std.mem.readInt(u32, data[10..14], .little))));
    try testing.expectEqual(@as(f64, 2), @as(f64, @bitCast(std.mem.readInt(u64, data[14..22], .little))));
    try testing.expectEqual(@as(u64, value), std.mem.readInt(u64, data[22..30], .little));
}

test "resolver names" {
    const Symbols = struct {
        fn resolve(_: ?*anyopaque, name: []const u8) ?usize {
            return if (std.mem.eql(u8, name, "game.exe")) 0x1000_8000 else null;
        }
    };
    const options: tuft_asm.Options = .{ .address = at, .resolver = .{ .resolve = Symbols.resolve } };
    var code = try assemble("call game.exe+0x10\njmp \"game.exe\"", options);
    defer code.deinit(testing.allocator);
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("call 0x10008010\njmp 0x10008000", try listing(&buf, code.bytes, at));

    var d: Diagnostic = .{};
    try testing.expectError(error.UnknownName, tuft_asm.assemble(testing.allocator, "nop\njmp nowhere", options, &d));
    try testing.expectEqual(2, d.line);
    try testing.expectEqualStrings("unknown name `nowhere`", d.message());
    try testing.expectError(error.UnknownName, tuft_asm.assemble(testing.allocator, "db 12 21 FF", options, &d));
    try testing.expectEqualStrings("FF isn't a name. Hex starts with 0x or ends in h, like 0xFF or 0FFh", d.message());
    try testing.expectError(error.UnknownName, tuft_asm.assemble(testing.allocator, "mov eax, FF", options, &d));
    try testing.expectEqualStrings("FF isn't a name. Hex starts with 0x or ends in h, like 0xFF or 0FFh", d.message());
}

test "hex bytes and h suffixes" {
    var code = try assemble("mov eax, 10h\nmov ah, 1\ndb x\"12 21 FF\"\ndb x\"1221ff\", 1", .{ .address = at });
    defer code.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, &.{ 0xB8, 0x10, 0, 0, 0, 0xB4, 1, 0x12, 0x21, 0xFF, 0x12, 0x21, 0xFF, 1 }, code.bytes);

    var d: Diagnostic = .{};
    try testing.expectError(error.InvalidSyntax, tuft_asm.assemble(testing.allocator, "nop\ndb x\"1G\"", .{ .address = at }, &d));
    try testing.expectEqual(2, d.line);
    try testing.expectEqualStrings("`1G` isn't a hex byte. It's byte 1 of the x\"...\"", d.message());
    try testing.expectError(error.InvalidSyntax, tuft_asm.assemble(testing.allocator, "db x\"12 3\"", .{ .address = at }, &d));
    try testing.expectEqualStrings("`3` isn't a hex byte. It's byte 2 of the x\"...\", and bytes are two digits", d.message());
    try testing.expectError(error.InvalidSyntax, tuft_asm.assemble(testing.allocator, "dd x\"12\"", .{ .address = at }, &d));
}

test "Zig matches text" {
    var block: tuft_asm.Block = .init(testing.allocator);
    defer block.deinit();
    const base = if (is64) .rcx else .ecx;
    try block.emit(.mov, .{ .eax, tuft_asm.mem(.{ .base = base, .disp = 0x10 }) });
    try block.emit(.@"test", .{ .eax, .eax });
    try block.emit(.je, .{tuft_asm.ref("skip")});
    try block.emit(.inc, .{tuft_asm.mem(.{ .base = base, .disp = 0x10, .size = 4 })});
    try block.label("skip");
    try block.emit(.ret, .{});
    var built = try block.assemble(testing.allocator, .{ .address = at }, null);
    defer built.deinit(testing.allocator);

    const r = if (is64) "rcx" else "ecx";
    var code = try assemble(
        \\    mov eax, [
    ++ r ++
        \\+0x10]
        \\    test eax, eax
        \\    je skip
        \\    inc dword ptr [
    ++ r ++
        \\+16]
        \\skip:
        \\    ret
    , .{ .address = at });
    defer code.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, code.bytes, built.bytes);
}

test "error lines" {
    var d: Diagnostic = .{};
    try testing.expectError(error.DuplicateLabel, tuft_asm.assemble(testing.allocator, "a:\nnop\na:", .{ .address = at }, &d));
    try testing.expectEqual(3, d.line);
    try testing.expectError(error.ValueOutOfRange, tuft_asm.assemble(testing.allocator, "db 300", .{ .address = at }, &d));
    try testing.expectError(error.CannotEncode, tuft_asm.assemble(testing.allocator, "nop\nmov eax, bx", .{ .address = at }, &d));
    try testing.expectEqual(2, d.line);
    try testing.expectError(error.UnknownMnemonic, tuft_asm.assemble(testing.allocator, "nop\n\nfrob eax", .{ .address = at }, &d));
    try testing.expectEqual(3, d.line);
}

extern "kernel32" fn GetModuleHandleA(name: ?[*:0]const u8) callconv(.winapi) ?[*]const u8;

test "ntdll round trip" {
    const ntdll = GetModuleHandleA("ntdll.dll") orelse return error.SkipZigTest;
    const nt = ntdll + std.mem.readInt(u32, ntdll[0x3C..][0..4], .little);
    const optional = nt + 4 + 20;
    const code_size = std.mem.readInt(u32, optional[4..][0..4], .little);
    const code_start = ntdll + std.mem.readInt(u32, optional[20..][0..4], .little);
    const code = code_start[0..code_size];

    // `[rip+x]` only differs from `[address]` on x64
    const modes: []const disasm.Addresses = if (is64) &.{ .absolute, .relative } else &.{.absolute};
    for (modes) |mode| try roundTrip(code, mode);
}

fn roundTrip(code: []const u8, mode: disasm.Addresses) !void {
    var checked: usize = 0;
    var failed: usize = 0;
    // One failure per mnemonic so we see every kind
    var seen: [64][16]u8 = undefined;
    var seen_lens: [64]usize = undefined;
    var seen_len: usize = 0;
    var offset: usize = 0;
    while (offset < code.len) {
        const address = @intFromPtr(code.ptr) + offset;
        const original = disasm.decodeWith(code[offset..], address, .{ .addresses = mode }) orelse {
            offset += 1;
            continue;
        };
        offset += original.len;
        const text = original.text();

        var d: Diagnostic = .{};
        const encoded = tuft_asm.assembleOne(text, .{ .address = address }, &d);
        if (encoded) |_| {} else |err| if (err == error.Unsupported) continue;
        checked += 1;
        const again: ?disasm.Instruction = if (encoded) |e| disasm.decodeWith(e.slice(), address, .{ .addresses = mode }) else |_| null;
        if (again != null and std.mem.eql(u8, again.?.text(), text)) continue;
        // Skip data decoded as code, like branches with size overrides
        if (isJunkBranch(code[offset - original.len ..][0..original.len], text)) continue;
        failed += 1;
        const mnemonic = text[0..@min(std.mem.indexOfScalar(u8, text, ' ') orelse text.len, 16)];
        const new = for (seen[0..seen_len], seen_lens[0..seen_len]) |*s, len| {
            if (std.mem.eql(u8, s[0..len], mnemonic)) break false;
        } else true;
        if (new and seen_len < seen.len) {
            @memcpy(seen[seen_len][0..mnemonic.len], mnemonic);
            seen_lens[seen_len] = mnemonic.len;
            seen_len += 1;
            std.debug.print("{t}: {s}  ->  {s} ({s})\n", .{ mode, text, if (again) |*a| a.text() else "", d.message() });
        }
    }
    if (failed != 0) std.debug.print("{t}: {d} of {d} didn't round trip\n", .{ mode, failed, checked });
    try testing.expect(checked > 100_000);
    try testing.expectEqual(0, failed);
}

fn isJunkBranch(bytes: []const u8, text: []const u8) bool {
    const branch = text[0] == 'j' or std.mem.startsWith(u8, text, "loop") or std.mem.startsWith(u8, text, "call");
    for (bytes) |b| switch (b) {
        0x67 => return true,
        0x66 => if (branch) return true,
        0x26, 0x2E, 0x36, 0x3E, 0x64, 0x65, 0xF0, 0xF2, 0xF3 => {},
        else => return false,
    };
    return false;
}
