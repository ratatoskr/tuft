//! Mnemonic and register names to Zydis ids.

const std = @import("std");

const zydis = @import("zydis");

pub const Entry = struct { name: []const u8, id: u32 };

pub const mnemonics: []const Entry = table("ZYDIS_MNEMONIC_");
pub const registers: []const Entry = table("ZYDIS_REGISTER_");

const max_name = 32;

/// Any case.
pub fn find(entries: []const Entry, name: []const u8) ?u32 {
    var buf: [max_name]u8 = undefined;
    if (name.len > buf.len) return null;
    const key = std.ascii.lowerString(&buf, name);
    var lo: usize = 0;
    var hi: usize = entries.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        switch (std.mem.order(u8, entries[mid].name, key)) {
            .eq => return entries[mid].id,
            .lt => lo = mid + 1,
            .gt => hi = mid,
        }
    }
    return null;
}

/// Any case. Takes other assemblers' names too, like `je` for `jz`.
pub fn findMnemonic(name: []const u8) ?u32 {
    var buf: [max_name]u8 = undefined;
    return find(mnemonics, canonical(name, &buf) orelse return null);
}

/// Zydis' lowercase name. Works at compile time.
pub fn canonical(name: []const u8, buf: *[max_name]u8) ?[]const u8 {
    if (name.len > buf.len) return null;
    const lower = std.ascii.lowerString(buf, name);
    if (std.mem.eql(u8, lower, "retn")) return "ret";
    for ([_][]const u8{ "cmov", "set", "j" }) |prefix| {
        if (!std.mem.startsWith(u8, lower, prefix)) continue;
        const cc = lower[prefix.len..];
        for (condition_aliases) |alias| {
            if (!std.mem.eql(u8, cc, alias[0])) continue;
            const out = buf[0 .. prefix.len + alias[1].len];
            @memcpy(out[prefix.len..], alias[1]);
            return out;
        }
        break;
    }
    return lower;
}

const condition_aliases = [_][2][]const u8{
    .{ "e", "z" },   .{ "ne", "nz" }, .{ "c", "b" },   .{ "nae", "b" },
    .{ "nc", "nb" }, .{ "ae", "nb" }, .{ "na", "be" }, .{ "a", "nbe" },
    .{ "pe", "p" },  .{ "po", "np" }, .{ "nge", "l" }, .{ "ge", "nl" },
    .{ "ng", "le" }, .{ "g", "nle" },
};

fn table(comptime prefix: []const u8) []const Entry {
    return comptime blk: {
        @setEvalBranchQuota(10_000_000);
        const decls = @typeInfo(zydis).@"struct".decl_names;
        var count = 0;
        for (decls) |decl| {
            if (isEntry(prefix, decl)) count += 1;
        }
        var entries: [count]Entry = undefined;
        var i = 0;
        for (decls) |decl| {
            if (!isEntry(prefix, decl)) continue;
            entries[i] = .{ .name = lowered(decl[prefix.len..]), .id = @field(zydis, decl) };
            i += 1;
        }
        std.mem.sortUnstable(Entry, &entries, {}, struct {
            fn lessThan(_: void, a: Entry, b: Entry) bool {
                return std.mem.order(u8, a.name, b.name) == .lt;
            }
        }.lessThan);
        const final = entries;
        break :blk &final;
    };
}

fn isEntry(comptime prefix: []const u8, comptime name: []const u8) bool {
    if (!std.mem.startsWith(u8, name, prefix)) return false;
    const rest = name[prefix.len..];
    for ([_][]const u8{ "INVALID", "NONE", "MAX_VALUE", "REQUIRED_BITS" }) |skip| {
        if (std.mem.eql(u8, rest, skip)) return false;
    }
    return @TypeOf(@field(zydis, name)) == c_int;
}

fn lowered(comptime s: []const u8) []const u8 {
    return comptime blk: {
        var buf: [s.len]u8 = undefined;
        _ = std.ascii.lowerString(&buf, s);
        const final = buf;
        break :blk &final;
    };
}

test "names to ids" {
    try std.testing.expectEqual(@as(u32, zydis.ZYDIS_MNEMONIC_MOV), findMnemonic("MOV").?);
    try std.testing.expectEqual(@as(u32, zydis.ZYDIS_MNEMONIC_JZ), findMnemonic("je").?);
    try std.testing.expectEqual(@as(u32, zydis.ZYDIS_MNEMONIC_SETNL), findMnemonic("setge").?);
    try std.testing.expectEqual(@as(u32, zydis.ZYDIS_MNEMONIC_CMOVNBE), findMnemonic("cmova").?);
    try std.testing.expectEqual(@as(u32, zydis.ZYDIS_MNEMONIC_RET), findMnemonic("retn").?);
    try std.testing.expectEqual(@as(u32, zydis.ZYDIS_REGISTER_XMM15), find(registers, "xmm15").?);
    try std.testing.expectEqual(null, findMnemonic("movz"));
    try std.testing.expectEqual(null, find(registers, "none"));
}
