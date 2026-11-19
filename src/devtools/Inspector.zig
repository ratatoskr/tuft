//! Shows and edits the bytes at a selection as numbers, pointer, text and asm.

const Inspector = @This();

const std = @import("std");

const disasm = @import("tuft_asm").disasm;
const ui = @import("tuft_ui");
const mem = @import("tuft_mem");
const Text = @import("tuft_text").Text;

const root = @import("root.zig");
const AddressBar = @import("AddressBar.zig");
const write = @import("write.zig");
const Memory = mem.Memory;
const Range = mem.Range;
const Symbols = mem.Symbols;
const Claims = mem.Claims;
const Kind = mem.values.Kind;

memory: Memory,
symbols: Symbols = .none,
claims: Claims = .none,
problem: ?root.Problem = null,
editing: ?Field = null,
edit: Text(64) = .{},

pub const Field = enum {
    u8_dec,
    u8_hex,
    i8_dec,
    i8_hex,
    u16_dec,
    u16_hex,
    i16_dec,
    i16_hex,
    u32_dec,
    u32_hex,
    i32_dec,
    i32_hex,
    u64_dec,
    u64_hex,
    i64_dec,
    i64_hex,
    f32,
    f64,
    pointer,

    fn kind(f: Field) Kind {
        return switch (f) {
            .u8_dec, .u8_hex, .i8_dec, .i8_hex => .byte,
            .u16_dec, .u16_hex, .i16_dec, .i16_hex => .two_bytes,
            .u32_dec, .u32_hex, .i32_dec, .i32_hex => .four_bytes,
            .u64_dec, .u64_hex, .i64_dec, .i64_hex => .eight_bytes,
            .f32 => .float,
            .f64 => .double,
            .pointer => if (@sizeOf(usize) == 8) .eight_bytes else .four_bytes,
        };
    }

    fn typeName(f: Field) []const u8 {
        const tag = @tagName(f);
        return tag[0 .. std.mem.indexOfScalar(u8, tag, '_') orelse tag.len];
    }

    fn isHex(f: Field) bool {
        return std.mem.endsWith(u8, @tagName(f), "_hex");
    }
};

/// Returns the pointer's target if Follow was clicked.
pub fn draw(self: *Inspector, range: ?Range) ?usize {
    const selected = range orelse {
        ui.textDisabled("Select a byte", .{});
        return null;
    };
    ui.copyableText("##at", "0x{x}", .{selected.start});
    var name: [128]u8 = undefined;
    if (self.symbols.describe(selected.start, &name)) |where| ui.copyableText("##where", "{s}", .{where});
    if (selected.len > 1) ui.textDisabled("{d} bytes selected", .{selected.len});
    if (self.problem) |*p| ui.textColored(.{ 1, 0.4, 0.4, 1 }, "{s}", .{p.message()});
    ui.separator();

    var bytes: [16]u8 = undefined;
    self.memory.read(selected.start, &bytes) catch {
        ui.textDisabled("Can't be read", .{});
        return null;
    };
    // Escape cancels typing instead of closing the window
    if (self.editing != null) _ = ui.shortcut(.escape);
    const at = selected.start;
    const table = ui.table("values", 2, .{ .row_background = true, .sizing = .stretch_prop }) orelse return null;
    defer table.end();
    ui.tableColumnWith("type", .{ .fixed = true });
    ui.tableColumnWith("value", .{ .stretch = true });

    self.int("u8", at, bytes[0], .u8_dec, .u8_hex);
    self.int("i8", at, @as(i8, @bitCast(bytes[0])), .i8_dec, .i8_hex);
    self.int("u16", at, std.mem.readInt(u16, bytes[0..2], .little), .u16_dec, .u16_hex);
    self.int("i16", at, std.mem.readInt(i16, bytes[0..2], .little), .i16_dec, .i16_hex);
    self.int("u32", at, std.mem.readInt(u32, bytes[0..4], .little), .u32_dec, .u32_hex);
    self.int("i32", at, std.mem.readInt(i32, bytes[0..4], .little), .i32_dec, .i32_hex);
    self.int("u64", at, std.mem.readInt(u64, bytes[0..8], .little), .u64_dec, .u64_hex);
    self.int("i64", at, std.mem.readInt(i64, bytes[0..8], .little), .i64_dec, .i64_hex);

    self.numberRow("f32", at, .f32, "{d}", .{@as(f32, @bitCast(std.mem.readInt(u32, bytes[0..4], .little)))});
    self.numberRow("f64", at, .f64, "{d}", .{@as(f64, @bitCast(std.mem.readInt(u64, bytes[0..8], .little)))});

    var follow: ?usize = null;
    const pointer = std.mem.readInt(usize, bytes[0..@sizeOf(usize)], .little);
    self.numberRow("pointer", at, .pointer, "0x{x}", .{pointer});
    const points_somewhere = if (self.memory.load(u8, pointer)) |_| true else |_| false;
    if (pointer != 0 and points_somewhere) {
        var target: [128]u8 = undefined;
        if (self.symbols.describe(pointer, &target)) |where| ui.tooltip("{s}", .{where});
        ui.tableNextRow();
        _ = ui.tableNextColumn();
        _ = ui.tableNextColumn();
        if (ui.button("Follow")) follow = pointer;
        ui.tooltip("Go to where it points", .{});
    }

    var text: [16]u8 = undefined;
    var n: usize = 0;
    while (n < bytes.len and bytes[n] >= 0x20 and bytes[n] < 0x7F) : (n += 1) text[n] = bytes[n];
    if (n > 0) value("text", "\"{s}\"", .{text[0..n]});

    if (disasm.decode(&bytes, selected.start)) |insn| {
        value("instruction", "{s}", .{insn.text()});
        if (insn.len > 1) ui.tooltip("{d} bytes", .{insn.len});
    } else {
        ui.tableNextRow();
        _ = ui.tableNextColumn();
        ui.textDisabled("instruction", .{});
        _ = ui.tableNextColumn();
        ui.textDisabled("<invalid>", .{});
    }
    return follow;
}

pub fn set(self: *Inspector, at: usize, field: Field, text: []const u8) void {
    const t = std.mem.trim(u8, text, " \t");
    var buf: [mem.values.max_len]u8 = undefined;
    const bytes = blk: {
        if (field == .pointer) {
            const address = AddressBar.parseAddress(self.symbols, t) catch |err| {
                self.problem = .init("Not an address: {t}", .{err});
                return;
            };
            std.mem.writeInt(usize, buf[0..@sizeOf(usize)], address, .little);
            break :blk buf[0..@sizeOf(usize)];
        }
        // Hex fields take hex without `0x` too
        var prefixed: [70]u8 = undefined;
        const suffixed = t.len > 0 and (t[t.len - 1] == 'h' or t[t.len - 1] == 'H');
        const typed = if (field.isHex() and !std.ascii.startsWithIgnoreCase(t, "0x") and !std.mem.startsWith(u8, t, "-"))
            std.fmt.bufPrint(&prefixed, "{s}{s}", .{ if (suffixed) "0" else "0x", t }) catch t
        else
            t;
        break :blk write.valueBytes(field.kind(), typed, &buf) catch |err| {
            self.problem = .init("Not a {s}: {t}", .{ field.typeName(), err });
            return;
        };
    };
    self.problem = write.store(self.memory, self.claims, at, bytes);
}

/// Hex alongside so signed values don't show negated.
fn int(self: *Inspector, comptime label: [:0]const u8, at: usize, number: anytype, comptime dec: Field, comptime hex: Field) void {
    ui.tableNextRow();
    _ = ui.tableNextColumn();
    ui.textDisabled(label, .{});
    _ = ui.tableNextColumn();

    const half_w = (ui.getContentRegionAvail()[0] - ui.getStyle().item_spacing[0]) * 0.5;
    var shown: [64]u8 = undefined;
    self.editField(at, dec, half_w, std.fmt.bufPrint(&shown, "{d}", .{number}) catch "");
    ui.sameLine();
    const Bits = @Int(.unsigned, @bitSizeOf(@TypeOf(number)));
    self.editField(at, hex, -1, std.fmt.bufPrint(&shown, "0x{x}", .{@as(Bits, @bitCast(number))}) catch "");
}

fn numberRow(self: *Inspector, comptime label: [:0]const u8, at: usize, comptime f: Field, comptime fmt: []const u8, args: anytype) void {
    ui.tableNextRow();
    _ = ui.tableNextColumn();
    ui.textDisabled(label, .{});
    _ = ui.tableNextColumn();
    var shown: [64]u8 = undefined;
    self.editField(at, f, -1, std.fmt.bufPrint(&shown, fmt, args) catch "");
}

fn editField(self: *Inspector, at: usize, comptime f: Field, width: f32, shown: []const u8) void {
    const mine = self.editing == f;
    var display: Text(64) = .init(shown);
    const buf: [:0]u8 = if (mine) &self.edit.buf else &display.buf;
    ui.setNextItemWidth(width);
    const entered = ui.inputTextWith("##" ++ @tagName(f), buf, .{ .flags = .{ .enter_returns_true = true, .auto_select_all = true }, .tight = true });
    if (ui.isItemActive()) {
        if (!mine) {
            self.edit = display;
            self.editing = f;
        }
    } else if (mine) {
        self.editing = null;
    }
    if (entered) self.set(at, f, std.mem.sliceTo(buf, 0));
}

fn value(comptime label: [:0]const u8, comptime fmt: []const u8, args: anytype) void {
    ui.tableNextRow();
    _ = ui.tableNextColumn();
    ui.textDisabled(label, .{});
    _ = ui.tableNextColumn();
    ui.copyableText("##" ++ label, fmt, args);
}

const tests = struct {
    const testing = std.testing;

    test "typed values get written" {
        var bytes: [8]u8 align(8) = @splat(0);
        const at = @intFromPtr(&bytes);
        var inspector: Inspector = .{ .memory = .local, .symbols = .local };

        inspector.set(at, .u32_dec, "1234");
        try testing.expectEqual(1234, std.mem.readInt(u32, bytes[0..4], .little));
        inspector.set(at, .u32_dec, "0x10");
        try testing.expectEqual(16, std.mem.readInt(u32, bytes[0..4], .little));
        inspector.set(at, .u16_hex, "ff");
        try testing.expectEqual(0xFF, std.mem.readInt(u16, bytes[0..2], .little));
        inspector.set(at, .i16_dec, "-2");
        try testing.expectEqual(-2, std.mem.readInt(i16, bytes[0..2], .little));
        inspector.set(at, .f32, "1.5");
        try testing.expectEqual(1.5, @as(f32, @bitCast(std.mem.readInt(u32, bytes[0..4], .little))));
        inspector.set(at, .pointer, "0x1000");
        try testing.expectEqual(0x1000, std.mem.readInt(usize, bytes[0..@sizeOf(usize)], .little));
        inspector.set(at, .pointer, "kernel32.dll+0x10");
        try testing.expectEqual(Symbols.local.resolve("kernel32.dll").? + 0x10, std.mem.readInt(usize, bytes[0..@sizeOf(usize)], .little));
        try testing.expectEqual(null, inspector.problem);
    }

    test "unwritable values refused" {
        var bytes: [8]u8 = @splat(0);
        const at = @intFromPtr(&bytes);
        var inspector: Inspector = .{ .memory = .local };

        inspector.set(at, .u8_dec, "256");
        try testing.expectEqualStrings("Not a u8: ValueOutOfRange", inspector.problem.?.message());
        inspector.set(at, .f64, "fast");
        try testing.expectEqualStrings("Not a f64: InvalidValue", inspector.problem.?.message());
        try testing.expectEqualSlices(u8, &@as([8]u8, @splat(0)), &bytes);

        const Hooked = struct {
            var owner: Claims.Owner = .init("kai");
            fn find(_: ?*anyopaque, start: usize, len: usize, out: []Claims.Claim) usize {
                var claim: Claims.Claim = .{ .start = 0x2002, .len = 5, .kind = .hook, .id = 43 };
                if (!claim.overlaps(start, len) or out.len == 0) return 0;
                claim.setOwner(&owner);
                out[0] = claim;
                return 1;
            }
        };
        inspector.claims = .{ .vtable = &.{ .find = Hooked.find } };
        inspector.set(0x2000, .u32_dec, "1");
        try testing.expectEqualStrings("0x2000 is kai's hook 43's: remove that before changing it", inspector.problem.?.message());

        inspector.claims = .none;
        inspector.set(0, .u32_dec, "1");
        try testing.expectEqualStrings("Couldn't write there: Unwritable", inspector.problem.?.message());
    }
};

test {
    _ = tests;
}
