//! Hex viewer for any range of memory. Only on-screen rows are read.

const HexView = @This();

const std = @import("std");

const ui = @import("tuft_ui");
const c = ui.c;

const root = @import("root.zig");
const Memory = @import("tuft_mem").Memory;
const Range = @import("tuft_mem").Range;
const Claims = @import("tuft_mem").Claims;
const Drag = @import("Drag.zig");

pub const bytes_per_row = 16;

/// Read a row at a time, aligned, so never across two pages.
memory: Memory,
/// First row's address, a multiple of `bytes_per_row`.
shown: Range = .{ .start = 0, .len = 0 },
/// From `anchor` to `cursor`, either way round.
anchor: ?usize = null,
cursor: usize = 0,
highlight: ?Range = null,
show_ascii: bool = true,
scroll_to: ?usize = null,
drawn: ?struct { first: usize, last: usize } = null,
drag: Drag = .{},
take_focus: bool = false,
/// First hex digit typed, until the second comes.
nibble: ?u8 = null,
in_ascii: bool = false,
/// Underlined, named on hover, can't be typed over.
claims: Claims = .none,
problem: ?root.Problem = null,

/// Also loads a megabyte around it to scroll through.
pub fn goTo(self: *HexView, address: usize, len: usize) void {
    const around: usize = 1 << 20;
    const start = std.mem.alignBackward(usize, address -| around / 2, bytes_per_row);
    self.shown = .{ .start = start, .len = around };
    self.anchor = address;
    self.cursor = address + @max(len, 1) - 1;
    self.scroll_to = address;
    self.drawn = null;
    self.nibble = null;
}

pub fn focus(self: *HexView) void {
    self.take_focus = true;
}

/// Where it's scrolled to and what's picked, to keep another view in step.
pub const Place = struct {
    start: usize,
    len: usize,
    /// The first row on screen, once it's been drawn.
    top: ?usize,
    anchor: ?usize,
    cursor: usize,
};

pub fn place(self: *const HexView) Place {
    const drawn_top = if (self.drawn) |d| self.shown.start + d.first * bytes_per_row else null;
    return .{ .start = self.shown.start, .len = self.shown.len, .top = self.scroll_to orelse drawn_top, .anchor = self.anchor, .cursor = self.cursor };
}

pub fn setPlace(self: *HexView, p: Place) void {
    self.shown = .{ .start = p.start, .len = p.len };
    self.anchor = p.anchor;
    self.cursor = p.cursor;
    self.nibble = null;
    if (p.top) |t| self.scroll_to = t;
}

pub fn selection(self: *const HexView) ?Range {
    const a = self.anchor orelse return null;
    const lo = @min(a, self.cursor);
    return .{ .start = lo, .len = @max(a, self.cursor) - lo + 1, .memory = self.memory };
}

/// Call every frame. 0 size fills, negative leaves room.
pub fn draw(self: *HexView, id: [:0]const u8, size: ui.Vec2) void {
    self.drawn = null;
    if (self.problem) |*p| ui.textColored(.{ 1, 0.4, 0.4, 1 }, "{s}", .{p.message()});
    const mono = ui.monospace();
    defer mono.end();
    const line_h = ui.getTextLineHeight();
    const stride = ui.getTextLineHeightWithSpacing();
    const rows = (self.shown.len + bytes_per_row - 1) / bytes_per_row;
    if (rows != 0) {
        // Set the extent before BeginChild so even a new child can jump far.
        ui.setNextWindowContentSize(.{ 0, @as(f32, @floatFromInt(rows - 1)) * stride + line_h });
        if (self.scroll_to) |address| {
            if (self.shown.contains(address)) {
                const row: f32 = @floatFromInt((address - self.shown.start) / bytes_per_row);
                ui.setNextWindowScroll(.{ -1, row * stride });
            }
        }
    }
    const child = ui.child(id, size, .{ .border = true, .horizontal_scrollbar = true }) orelse return;
    defer child.end();
    self.scroll_to = null;
    if (self.take_focus) {
        self.take_focus = false;
        ui.setWindowFocus();
    }
    if (self.shown.len == 0) {
        ui.textDisabled("Nothing to show", .{});
        return;
    }

    const char_w = ui.calcTextSize("F")[0];
    self.keys();

    const layout: Layout = .{ .char_w = char_w, .line_h = line_h, .ascii = self.show_ascii };
    const origin = ui.getCursorScreenPos();
    var clipper = ui.clip(rows);
    while (clipper.next()) |row| {
        self.drawRow(layout, self.shown.start + row * bytes_per_row);
        // The clipper may submit an off-screen row just to measure it.
        if (ui.isItemVisible()) {
            self.drawn = if (self.drawn) |d| .{ .first = d.first, .last = row } else .{ .first = row, .last = row };
        }
    }
    if (self.drag.update(origin, stride, rows)) |m| {
        const at = self.shown.start + m.row * bytes_per_row + layout.byteNear(m.x);
        if (m.restart or self.anchor == null) self.anchor = at;
        self.cursor = at;
        self.in_ascii = layout.inAscii(m.x);
        self.nibble = null;
    }
}

pub fn isDrawn(self: *const HexView, address: usize) bool {
    const d = self.drawn orelse return false;
    if (!self.shown.contains(address)) return false;
    const row = (address - self.shown.start) / bytes_per_row;
    return row >= d.first and row <= d.last;
}

const Layout = struct {
    char_w: f32,
    line_h: f32,
    ascii: bool,

    const address_chars = 16 + 2;

    fn hexX(self: Layout, i: usize) f32 {
        const gap: f32 = if (i >= bytes_per_row / 2) 1 else 0;
        return (@as(f32, address_chars) + @as(f32, @floatFromInt(i)) * 3 + gap) * self.char_w;
    }

    fn asciiX(self: Layout, i: usize) f32 {
        return self.hexX(bytes_per_row) + (1 + @as(f32, @floatFromInt(i))) * self.char_w;
    }

    fn width(self: Layout) f32 {
        return if (self.ascii) self.asciiX(bytes_per_row) else self.hexX(bytes_per_row);
    }

    fn byteNear(self: Layout, x: f32) usize {
        if (self.inAscii(x)) {
            const i: usize = @intFromFloat(@max(0, (x - self.asciiX(0)) / self.char_w));
            return @min(i, bytes_per_row - 1);
        }
        var i: usize = bytes_per_row - 1;
        while (i > 0 and x < self.hexX(i) - self.char_w / 2) i -= 1;
        return i;
    }

    fn inAscii(self: Layout, x: f32) bool {
        return self.ascii and x >= self.asciiX(0) - self.char_w / 2;
    }
};

fn drawRow(self: *HexView, layout: Layout, address: usize) void {
    const origin = ui.getCursorScreenPos();
    var bytes: [bytes_per_row]u8 = undefined;
    const readable = if (self.memory.read(address, &bytes)) true else |_| false;

    // The whole row is one item so pressing it doesn't drag the window.
    const scope = ui.id(@as(i32, @truncate(@as(isize, @bitCast(address)))));
    defer scope.end();
    _ = ui.invisibleButton("##row", .{ layout.width(), layout.line_h });
    self.drag.press();
    var claim_buf: [4]Claims.Claim = undefined;
    const row_claims = self.claims.find(address, bytes_per_row, &claim_buf);
    if (row_claims.len != 0 and ui.isItemHovered()) {
        const at = address + layout.byteNear(ui.getMousePos()[0] - origin[0]);
        if (claimOf(row_claims, at)) |claim| ui.tooltip("{f}", .{claim});
    }

    const list = ui.getWindowDrawList();
    const text = ui.getColorU32(.text);
    const dim = ui.getColorU32(.text_disabled);
    const selected_bg = ui.getColorU32(.text_selected_bg);
    const highlight_bg = ui.getColorU32(.header_hovered);

    var buf: [24]u8 = undefined;
    drawText(list, origin, dim, std.fmt.bufPrintSentinel(&buf, "{X:0>16}", .{address}, 0) catch unreachable);

    const chosen = self.selection();
    for (0..bytes_per_row) |i| {
        const at = address + i;
        const hex_x = origin[0] + layout.hexX(i);
        const ascii_x = origin[0] + layout.asciiX(i);
        const bg = mark(chosen, self.highlight, at, selected_bg, highlight_bg);
        if (bg) |colour| {
            // Fill the gap to the next byte if it's marked the same
            const joined = i + 1 < bytes_per_row and mark(chosen, self.highlight, at + 1, selected_bg, highlight_bg) == colour;
            const hex_w = if (joined) layout.hexX(i + 1) - layout.hexX(i) else 2 * layout.char_w;
            fillRect(list, hex_x, origin[1], hex_w, layout.line_h, colour);
            if (layout.ascii) fillRect(list, ascii_x, origin[1], layout.char_w, layout.line_h, colour);
        }
        if (claimOf(row_claims, at) != null) {
            const joined = i + 1 < bytes_per_row and claimOf(row_claims, at + 1) != null;
            const hex_w = if (joined) layout.hexX(i + 1) - layout.hexX(i) else 2 * layout.char_w;
            const under = origin[1] + layout.line_h - 1;
            fillRect(list, hex_x, under, hex_w, 2, root.claimedColour());
            if (layout.ascii) fillRect(list, ascii_x, under, layout.char_w, 2, root.claimedColour());
        }

        if (self.nibble) |high| if (at == self.cursor) {
            // Half typed. Show the first digit and wait for the second
            fillRect(list, hex_x, origin[1], 2 * layout.char_w, layout.line_h, ui.getColorU32(.frame_bg_active));
            drawText(list, .{ hex_x, origin[1] }, text, std.fmt.bufPrintSentinel(&buf, "{X}_", .{high}, 0) catch unreachable);
            continue;
        };
        if (!readable) {
            drawText(list, .{ hex_x, origin[1] }, dim, "??");
            if (layout.ascii) drawText(list, .{ ascii_x, origin[1] }, dim, ".");
            continue;
        }
        const b = bytes[i];
        const hex = std.fmt.bufPrintSentinel(&buf, "{X:0>2}", .{b}, 0) catch unreachable;
        drawText(list, .{ hex_x, origin[1] }, if (b == 0) dim else text, hex);
        if (layout.ascii) {
            const printable = b >= 0x20 and b < 0x7F;
            buf[0] = if (printable) b else '.';
            buf[1] = 0;
            drawText(list, .{ ascii_x, origin[1] }, if (printable) text else dim, buf[0..1 :0]);
        }
    }
}

fn claimOf(claims: []const Claims.Claim, at: usize) ?*const Claims.Claim {
    for (claims) |*claim| if (claim.overlaps(at, 1)) return claim;
    return null;
}

fn mark(chosen: ?Range, highlight: ?Range, at: usize, selected_bg: u32, highlight_bg: u32) ?u32 {
    if (chosen) |r| if (r.contains(at)) return selected_bg;
    if (highlight) |r| if (r.contains(at)) return highlight_bg;
    return null;
}

fn keys(self: *HexView) void {
    if (!ui.isWindowFocused()) return;
    // While focused the arrows and Ctrl+C are ours, not the game's
    ui.captureKeyboard();
    if (self.anchor == null) return;
    const mods = ui.mods();
    var step: isize = 0;
    if (ui.isKeyPressed(.left, true)) step = -1;
    if (ui.isKeyPressed(.right, true)) step = 1;
    if (ui.isKeyPressed(.up, true)) step = -bytes_per_row;
    if (ui.isKeyPressed(.down, true)) step = bytes_per_row;
    if (step != 0) {
        const moved = @as(isize, @bitCast(self.cursor)) + step;
        const next: usize = @bitCast(moved);
        if (self.shown.contains(next)) {
            self.cursor = next;
            if (!mods.shift) self.anchor = next;
            self.nibble = null;
        }
    }
    // With a half-typed byte, Escape drops it instead of closing the window
    if (self.nibble != null and ui.shortcut(.escape)) self.nibble = null;
    if (!mods.ctrl and !mods.alt) {
        for (ui.typed()) |ch| self.typeChar(ch);
    }
}

/// Begin `menu` right after `draw`.
pub fn commands(self: *HexView, menu: *ui.Commands) void {
    const any = self.selection() != null;
    if (menu.item(.{ .label = "Copy", .chord = root.keys.copy, .enabled = any, .tooltip = "The selected bytes as hex" })) self.copy();
    if (menu.item(.{ .label = "Copy address", .chord = root.keys.copy_address, .enabled = any })) {
        if (self.selection()) |r| ui.setClipboard(ui.format("0x{x}", .{r.start}));
    }
    if (menu.item(.{ .label = "Paste bytes", .chord = root.keys.paste, .enabled = any, .tooltip = "Write hex from the clipboard (48 8B 05) from the start of the selection" })) {
        if (ui.getClipboard()) |text| self.paste(text);
    }
}

pub fn paste(self: *HexView, text: []const u8) void {
    const range = self.selection() orelse return;
    var buf: [@import("tuft_mem").values.max_len]u8 = undefined;
    const bytes = root.write.valueBytes(.bytes, text, &buf) catch |err| {
        self.problem = .init("Not hex bytes: {t}", .{err});
        return;
    };
    if (bytes.len == 0) return;
    self.problem = root.write.store(self.memory, self.claims, range.start, bytes);
    if (self.problem != null) return;
    self.anchor = range.start;
    self.cursor = range.start + bytes.len - 1;
    self.nibble = null;
}

/// The first char typed over a selection goes to its start.
pub fn typeChar(self: *HexView, ch: u21) void {
    const range = self.selection() orelse return;
    const char = std.math.cast(u8, ch) orelse return;
    if (self.nibble == null) {
        self.anchor = range.start;
        self.cursor = range.start;
    }
    if (self.in_ascii) {
        if (char >= 0x20 and char < 0x7F) self.writeByte(char);
        return;
    }
    const digit = std.fmt.charToDigit(char, 16) catch return;
    if (self.nibble) |high| {
        self.nibble = null;
        self.writeByte((high << 4) | digit);
    } else if (self.allowed(self.cursor)) {
        self.nibble = digit;
    }
}

fn allowed(self: *HexView, at: usize) bool {
    const claim = self.claims.first(at, 1) orelse return true;
    self.problem = root.claimed(at, &claim);
    return false;
}

fn writeByte(self: *HexView, byte: u8) void {
    if (!self.allowed(self.cursor)) return;
    self.memory.write(self.cursor, &.{byte}) catch |err| {
        self.problem = .init("Couldn't write there: {t}", .{err});
        return;
    };
    self.problem = null;
    if (self.shown.contains(self.cursor + 1)) self.cursor += 1;
    self.anchor = self.cursor;
    if (self.drawn != null and !self.isDrawn(self.cursor)) self.scroll_to = self.cursor;
}

/// Unreadable bytes are `??`.
pub fn copy(self: *HexView) void {
    const range = self.selection() orelse return;
    var out: [3 * 1024 + 1]u8 = undefined;
    const n = @min(range.len, 1024);
    var len: usize = 0;
    var row_buf: [bytes_per_row]u8 = undefined;
    var row_start: ?usize = null;
    var row_ok = false;
    for (0..n) |i| {
        const at = range.start + i;
        const start = std.mem.alignBackward(usize, at, bytes_per_row);
        if (row_start != start) {
            row_start = start;
            row_ok = if (self.memory.read(start, &row_buf)) true else |_| false;
        }
        if (i != 0) {
            out[len] = ' ';
            len += 1;
        }
        const text = if (row_ok) std.fmt.bufPrint(out[len..], "{X:0>2}", .{row_buf[at - start]}) catch break else std.fmt.bufPrint(out[len..], "??", .{}) catch break;
        len += text.len;
    }
    out[len] = 0;
    ui.setClipboard(out[0..len :0]);
}

fn drawText(list: ui.DrawList, pos: ui.Vec2, colour: u32, s: []const u8) void {
    list.addText(pos, colour, s);
}

fn fillRect(list: ui.DrawList, x: f32, y: f32, w: f32, h: f32, colour: u32) void {
    list.addRectFilled(.{ x, y }, .{ x + w, y + h }, colour);
}

test "goTo and selection" {
    const Fake = struct {
        fn read(_: ?*anyopaque, _: usize, _: []u8) Memory.Error!void {
            return error.Unreadable;
        }
    };
    var view: HexView = .{ .memory = .{ .vtable = &.{ .read = Fake.read } } };
    view.goTo(0x1000_0008, 4);
    try std.testing.expect(view.shown.contains(0x1000_0008));
    try std.testing.expectEqual(0, view.shown.start % bytes_per_row);
    try std.testing.expectEqual(Range{ .start = 0x1000_0008, .len = 4, .memory = view.memory }, view.selection().?);

    view.anchor = 0x1000_0010;
    view.cursor = 0x1000_000C;
    try std.testing.expectEqual(Range{ .start = 0x1000_000C, .len = 5, .memory = view.memory }, view.selection().?);
}

test "typing writes bytes" {
    const Fake = struct {
        var bytes: [32]u8 = @splat(0);
        const at: usize = 0x1000;

        fn read(_: ?*anyopaque, address: usize, out: []u8) Memory.Error!void {
            if (address < at or address + out.len > at + bytes.len) return error.Unreadable;
            @memcpy(out, bytes[address - at ..][0..out.len]);
        }

        fn write(_: ?*anyopaque, address: usize, in: []const u8) Memory.Error!void {
            if (address < at or address + in.len > at + bytes.len) return error.Unwritable;
            @memcpy(bytes[address - at ..][0..in.len], in);
        }
    };
    var view: HexView = .{ .memory = .{ .vtable = &.{ .read = Fake.read, .write = Fake.write } } };
    view.goTo(Fake.at + 2, 3);
    view.cursor = Fake.at + 4;
    for ("9x0") |ch| view.typeChar(ch); // not hex, ignored
    try std.testing.expectEqual(0x90, Fake.bytes[2]);
    try std.testing.expectEqual(Fake.at + 3, view.cursor);
    view.typeChar('a');
    try std.testing.expectEqual(0x0A, view.nibble);
    try std.testing.expectEqual(0, Fake.bytes[3]); // not until the byte's done
    view.typeChar('B');
    try std.testing.expectEqual(0xAB, Fake.bytes[3]);

    view.in_ascii = true;
    for ("hi\x01") |ch| view.typeChar(ch);
    try std.testing.expectEqualStrings("hi", Fake.bytes[4..6]);
    try std.testing.expectEqual(Range{ .start = Fake.at + 6, .len = 1, .memory = view.memory }, view.selection().?);

    view.goTo(Fake.at + Fake.bytes.len, 1);
    view.typeChar('!');
    try std.testing.expectEqualStrings("Couldn't write there: Unwritable", view.problem.?.message());
    try std.testing.expectEqual(Fake.at + Fake.bytes.len, view.cursor);

    const Hooked = struct {
        fn find(_: ?*anyopaque, start: usize, len: usize, out: []Claims.Claim) usize {
            const Kai = struct {
                var owner: Claims.Owner = .init("kai");
            };
            var claim: Claims.Claim = .{ .start = Fake.at + 8, .len = 5, .kind = .hook, .id = 43 };
            if (!claim.overlaps(start, len) or out.len == 0) return 0;
            claim.setOwner(&Kai.owner);
            out[0] = claim;
            return 1;
        }
    };
    view.claims = .{ .vtable = &.{ .find = Hooked.find } };
    view.in_ascii = false;
    view.goTo(Fake.at + 7, 1);
    for ("1122") |ch| view.typeChar(ch);
    try std.testing.expectEqual(0x11, Fake.bytes[7]);
    try std.testing.expectEqual(0, Fake.bytes[8]);
    try std.testing.expectEqual(null, view.nibble);
    try std.testing.expectEqualStrings("0x1008 is kai's hook 43's: remove that before changing it", view.problem.?.message());
}

test "nearest byte to mouse" {
    const layout: Layout = .{ .char_w = 10, .line_h = 16, .ascii = true };
    try std.testing.expectEqual(0, layout.byteNear(layout.hexX(0) + 1));
    try std.testing.expectEqual(9, layout.byteNear(layout.hexX(9) + 15));
    try std.testing.expectEqual(9, layout.byteNear(layout.hexX(9) + 24));
    try std.testing.expectEqual(3, layout.byteNear(layout.asciiX(3) + 2));
    try std.testing.expectEqual(0, layout.byteNear(5)); // the address
    try std.testing.expectEqual(bytes_per_row - 1, layout.byteNear(layout.width() + 500)); // past the end
}
