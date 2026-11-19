//! Disassembly view, decoded around its top row since instructions vary in length.

const AsmView = @This();

const std = @import("std");

const tuft_asm = @import("tuft_asm");
const disasm = tuft_asm.disasm;
const ui = @import("tuft_ui");
const c = ui.c;

const root = @import("root.zig");
const Memory = @import("tuft_mem").Memory;
const Range = @import("tuft_mem").Range;
const Symbols = @import("tuft_mem").Symbols;
const Claims = @import("tuft_mem").Claims;
const HexView = root.HexView;
const Drag = @import("Drag.zig");

pub const margin = 50;
/// Same block size as `HexView` rows so one `Memory` works for both.
const block = HexView.bytes_per_row;
const window_len = 4096;
const max_lines = 512;
const context_rows = 4;
/// Longer instructions end in `..`.
const shown_bytes = 8;

pub const Line = struct {
    address: usize,
    len: u8,
    kind: Kind,

    pub const Kind = enum {
        code,
        bad,
        unreadable,
    };
};

memory: Memory,
symbols: Symbols = .none,
top: usize = 0,
/// From `anchor` to `cursor`, either way round.
anchor: ?Pick = null,
cursor: Pick = .{ .address = 0, .len = 1 },
drag: Drag = .{},
addresses: disasm.Addresses = .relative,
lift: usize = 0,
/// `top` was moved, not scrolled to, so the scroll has to follow.
moved: bool = true,
scroll_frac: f32 = 0,
last_top_index: usize = 0,
take_focus: bool = false,
editing: ?Edit = null,
claims: Claims = .none,
problem: ?root.Problem = null,
marks: ?Marks = null,

/// This frame's decoding, read in blocks from `base`.
base: usize = 0,
bytes: [window_len]u8 = undefined,
blocks: [window_len / block]Block = undefined,
lines: [max_lines]Line = undefined,
line_count: usize = 0,
top_index: usize = 0,

const Block = enum { unread, ok, bad };

pub const Mark = struct {
    breakpoint: ?bool = null,
    current: bool = false,
};

pub const Marks = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, address: usize) Mark,
};

pub const Pick = struct {
    address: usize,
    len: u8,

    fn of(line: Line) Pick {
        return .{ .address = line.address, .len = line.len };
    }
};

pub const Edit = struct {
    address: usize,
    text: [128:0]u8 = @splat(0),
    focus: bool = true,
};

pub fn goTo(self: *AsmView, address: usize) void {
    self.editing = null;
    self.top = address;
    self.anchor = .{ .address = address, .len = 1 };
    self.cursor = self.anchor.?;
    self.lift = context_rows;
    self.moved = true;
    self.scroll_frac = 0;
}

pub fn focus(self: *AsmView) void {
    self.take_focus = true;
}

pub fn selection(self: *const AsmView) ?Range {
    const a = self.anchor orelse return null;
    const lo = if (a.address <= self.cursor.address) a else self.cursor;
    const hi = if (a.address <= self.cursor.address) self.cursor else a;
    return .{ .start = lo.address, .len = hi.address + hi.len - lo.address, .memory = self.memory };
}

fn isSelected(self: *const AsmView, address: usize) bool {
    const a = self.anchor orelse return false;
    return address >= @min(a.address, self.cursor.address) and address <= @max(a.address, self.cursor.address);
}

/// Not if any of it is claimed.
pub fn edit(self: *AsmView) void {
    const range = self.selection() orelse return;
    var e: Edit = .{ .address = range.start };
    if (self.indexOf(range.start)) |i| {
        if (!self.allowed(range.start, self.lines[i].len)) return;
        var buf: [128]u8 = undefined;
        var comment: [128]u8 = undefined;
        const shown = self.instructionText(self.lines[i], &buf, &comment);
        if (!shown.dim) @memcpy(e.text[0..shown.text.len], shown.text);
        self.anchor = .of(self.lines[i]);
        self.cursor = self.anchor.?;
    } else if (!self.allowed(range.start, 1)) return;
    self.problem = null;
    self.editing = e;
}

fn allowed(self: *AsmView, start: usize, len: usize) bool {
    const claim = self.claims.first(start, len) orelse return true;
    self.problem = root.claimed(@max(start, claim.start), &claim);
    return false;
}

/// Pads with nops to the end of what it overlaps. Rows around `address` must be decoded.
pub fn replace(self: *AsmView, address: usize, text: []const u8) bool {
    var d: tuft_asm.Diagnostic = .{};
    const encoded = tuft_asm.assembleOne(text, .{ .address = address, .resolver = .{ .context = &self.symbols, .resolve = resolveName } }, &d) catch |err| {
        self.problem = if (d.message().len == 0) .init("{t}", .{err}) else .init("{s}", .{d.message()});
        return false;
    };
    var buf: [64]u8 = undefined;
    const bytes = self.padded(address, encoded.slice(), &buf);
    if (!self.allowed(address, bytes.len)) return false;
    self.memory.write(address, bytes) catch |err| {
        self.problem = .init("couldn't write there: {t}", .{err});
        return false;
    };
    self.problem = null;
    self.anchor = .{ .address = address + bytes.len, .len = 1 };
    self.cursor = self.anchor.?;
    return true;
}

fn resolveName(context: ?*anyopaque, name: []const u8) ?usize {
    const symbols: *const Symbols = @ptrCast(@alignCast(context.?));
    return symbols.resolve(name);
}

/// Pads so no instruction gets cut in half.
fn padded(self: *const AsmView, address: usize, code: []const u8, buf: *[64]u8) []const u8 {
    var end = address + code.len;
    if (self.indexOf(address)) |first| {
        for (self.lines[first..self.line_count]) |line| {
            if (line.address >= address + code.len) break;
            end = @max(end, line.address + line.len);
        }
    }
    const len = @min(end - address, buf.len);
    @memcpy(buf[0..code.len], code);
    @memset(buf[code.len..len], 0x90);
    return buf[0..len];
}

/// Call every frame. 0 size fills, negative leaves room.
pub fn draw(self: *AsmView, id: [:0]const u8, size: ui.Vec2) void {
    if (self.problem) |*p| ui.textColored(.{ 1, 0.4, 0.4, 1 }, "{s}", .{p.message()});
    const mono = ui.monospace();
    defer mono.end();
    const line_h = ui.getTextLineHeight();
    const stride = ui.getTextLineHeightWithSpacing();
    const avail = ui.getContentRegionAvailPixels();
    const height = if (size[1] > 0) size[1] else avail[1] + size[1];
    const rows: usize = @intFromFloat(@max(1, @ceil(height / stride)));

    self.decodeLines(rows);
    if (self.lift > 0) {
        const up = @min(self.lift, self.top_index);
        self.lift = 0;
        if (up > 0) {
            self.top = self.lines[self.top_index - up].address;
            self.decodeLines(rows);
        }
    }

    if (self.line_count != 0) {
        ui.setNextWindowContentSize(.{ 0, @as(f32, @floatFromInt(self.line_count - 1)) * stride + line_h });
        // Rows above the top change as it moves, so pin the scroll to the top row
        if (self.moved or self.top_index != self.last_top_index) {
            ui.setNextWindowScroll(.{ -1, @as(f32, @floatFromInt(self.top_index)) * stride + self.scroll_frac });
        }
    }
    self.moved = false;
    self.last_top_index = self.top_index;

    const child = ui.child(id, size, .{ .border = true, .horizontal_scrollbar = true }) orelse return;
    defer child.end();
    if (self.take_focus) {
        self.take_focus = false;
        ui.setWindowFocus();
    }
    if (self.line_count == 0) {
        ui.textDisabled("Nothing to show", .{});
        return;
    }

    self.keys(rows);
    const layout: Layout = .{ .char_w = ui.calcTextSize("F")[0], .line_h = line_h };
    const origin = ui.getCursorScreenPos();
    var clipper = ui.clip(self.line_count);
    while (clipper.next()) |i| self.drawRow(layout, self.lines[i]);
    if (self.drag.update(origin, stride, self.line_count)) |m| {
        const pick: Pick = .of(self.lines[m.row]);
        if (m.restart or self.anchor == null) self.anchor = pick;
        self.cursor = pick;
    }

    // Scrolled. Decode around whatever row is at the top now
    const scroll = ui.getScrollY();
    const first = @min(@as(usize, @intFromFloat(@max(0, scroll / stride))), self.line_count - 1);
    if (first != self.top_index) {
        self.top = self.lines[first].address;
        self.scroll_frac = scroll - @as(f32, @floatFromInt(first)) * stride;
        self.moved = true;
    }
}

fn decodeLines(self: *AsmView, rows: usize) void {
    self.base = std.mem.alignBackward(usize, self.top -| margin, block);
    @memset(&self.blocks, .unread);

    // Start at the first byte within `margin` whose instructions end exactly on `top`
    self.line_count = 0;
    var start = self.top -| margin;
    while (start < self.top) : (start += 1) {
        self.line_count = 0;
        var at = start;
        while (at < self.top) {
            const line = self.lineAt(at).?;
            self.lines[self.line_count] = line;
            self.line_count += 1;
            at += line.len;
        }
        if (at == self.top) break;
    } else self.line_count = 0;
    self.top_index = self.line_count;

    var at = self.top;
    var screen_end: ?usize = null;
    while (self.line_count < max_lines) {
        if (screen_end == null and self.line_count - self.top_index >= rows) screen_end = at;
        if (screen_end) |end| if (at - end >= margin) break;
        const line = self.lineAt(at) orelse break;
        self.lines[self.line_count] = line;
        self.line_count += 1;
        at = std.math.add(usize, at, line.len) catch break;
    }

    // `goTo` doesn't know how long the instruction is until it's decoded
    for (self.lines[0..self.line_count]) |line| {
        if (self.anchor) |*a| if (a.address == line.address) {
            a.len = line.len;
        };
        if (self.cursor.address == line.address) self.cursor.len = line.len;
    }
}

fn lineAt(self: *AsmView, at: usize) ?Line {
    const offset = at - self.base;
    if (offset >= window_len) return null;
    if (!self.readable(offset / block)) {
        return .{ .address = at, .len = @intCast(block - offset % block), .kind = .unreadable };
    }
    const len = disasm.length(self.available(offset)) orelse return .{ .address = at, .len = 1, .kind = .bad };
    return .{ .address = at, .len = len, .kind = .code };
}

fn available(self: *AsmView, offset: usize) []const u8 {
    const limit = @min(offset + disasm.max_len, window_len);
    var end = offset;
    while (end < limit and self.readable(end / block)) end = (end / block + 1) * block;
    return self.bytes[offset..@min(end, limit)];
}

fn readable(self: *AsmView, index: usize) bool {
    if (self.blocks[index] == .unread) {
        const ok = if (self.memory.read(self.base + index * block, self.bytes[index * block ..][0..block])) true else |_| false;
        self.blocks[index] = if (ok) .ok else .bad;
    }
    return self.blocks[index] == .ok;
}

const Layout = struct {
    char_w: f32,
    line_h: f32,

    const gutter_chars = 2;
    const address_chars = 16 + 2;
    const bytes_chars = shown_bytes * 3 + 2;
    const text_chars = 88;

    fn addressX(self: Layout) f32 {
        return gutter_chars * self.char_w;
    }

    fn bytesX(self: Layout) f32 {
        return (gutter_chars + address_chars) * self.char_w;
    }

    fn textX(self: Layout) f32 {
        return (gutter_chars + address_chars + bytes_chars) * self.char_w;
    }

    fn width(self: Layout) f32 {
        return (gutter_chars + address_chars + bytes_chars + text_chars) * self.char_w;
    }
};

fn drawRow(self: *AsmView, layout: Layout, line: Line) void {
    const origin = ui.getCursorScreenPos();
    const scope = ui.id(@as(i32, @truncate(@as(isize, @bitCast(line.address)))));
    defer scope.end();
    const editing: ?*Edit = if (self.editing) |*e| (if (e.address == line.address) e else null) else null;
    // One item per row so pressing it doesn't drag the window.
    const row_w = if (editing != null) layout.textX() else layout.width();
    _ = ui.invisibleButton("##row", .{ row_w, layout.line_h });
    self.drag.press();
    const double_clicked = editing == null and ui.isItemDoubleClicked();

    const list = ui.getWindowDrawList();
    const text = ui.getColorU32(.text);
    const dim = ui.getColorU32(.text_disabled);
    const mark: Mark = if (self.marks) |m| m.func(m.ctx, line.address) else .{};
    if (mark.current) {
        // Amber, like most debuggers' current line
        list.addRectFilled(origin, .{ origin[0] + layout.width(), origin[1] + layout.line_h }, 0x5000C0FF);
    }
    if (self.isSelected(line.address)) {
        // Extend down to the next row too, so selected rows look like one block
        const selected_bg = ui.getColorU32(.text_selected_bg);
        const below = if (self.isSelected(line.address + line.len)) ui.getTextLineHeightWithSpacing() else layout.line_h;
        list.addRectFilled(origin, .{ origin[0] + layout.width(), origin[1] + below }, selected_bg);
    }
    if (mark.breakpoint) |enabled| {
        const centre: ui.Vec2 = .{ origin[0] + layout.char_w, origin[1] + layout.line_h / 2 };
        const radius = layout.line_h * 0.3;
        const red: u32 = 0xFF3C3CE0;
        if (enabled) list.addCircleFilled(centre, radius, red) else list.addCircle(centre, radius, red, 1);
    }

    var buf: [128]u8 = undefined;
    drawText(list, origin[0] + layout.addressX(), origin[1], dim, std.fmt.bufPrint(&buf, "{X:0>16}", .{line.address}) catch unreachable);
    const bytes = self.lineBytes(line);
    drawText(list, origin[0] + layout.bytesX(), origin[1], dim, formatBytes(&buf, line, bytes));

    if (editing) |e| return self.drawField(layout, e);
    if (double_clicked) {
        self.anchor = .of(line);
        self.cursor = .of(line);
        self.edit();
    }

    var comment_buf: [128]u8 = undefined;
    const shown = self.instructionText(line, &buf, &comment_buf);
    const text_x = origin[0] + layout.textX();
    drawText(list, text_x, origin[1], if (shown.dim) dim else text, shown.text);
    var end_x = text_x + ui.calcTextSize(shown.text)[0];
    if (shown.comment) |comment| {
        end_x += 2 * layout.char_w;
        drawText(list, end_x, origin[1], dim, comment);
        end_x += ui.calcTextSize(comment)[0];
    }
    if (self.claims.first(line.address, line.len)) |claim| {
        const label = std.fmt.bufPrintSentinel(&buf, "[{f}]", .{&claim}, 0) catch "[claimed]";
        drawText(list, end_x + 2 * layout.char_w, origin[1], root.claimedColour(), label);
    }
}

/// Stays open if assembling or writing fails.
fn drawField(self: *AsmView, layout: Layout, e: *Edit) void {
    ui.sameLineWith(0, 0);
    if (e.focus) {
        ui.focusNext();
        e.focus = false;
    }
    ui.setNextItemWidthPixels(layout.width() - layout.textX());
    const options: ui.InputTextOptions = .{ .flags = .{ .enter_returns_true = true, .auto_select_all = true }, .tight = true };
    if (ui.inputTextWith("##edit", &e.text, options)) {
        const text = std.mem.trim(u8, std.mem.sliceTo(&e.text, 0), " \t");
        if (text.len == 0 or self.replace(e.address, text)) {
            self.editing = null;
        } else {
            e.focus = true;
        }
    } else if (ui.isItemDeactivated()) {
        self.editing = null;
    }
}

const Shown = struct {
    text: [:0]const u8,
    comment: ?[:0]const u8 = null,
    dim: bool = false,
};

fn instructionText(self: *AsmView, line: Line, buf: *[128]u8, comment_buf: *[128]u8) Shown {
    return switch (line.kind) {
        .code => {
            const insn = disasm.decodeWith(self.available(line.address - self.base), line.address, .{ .addresses = self.addresses }) orelse return .{ .text = "(bad)", .dim = true };
            const comment: ?[:0]const u8 = if (self.addresses == .relative)
                if (insn.ip_relative) |target| self.describe(target, comment_buf) else null
            else
                null;
            return .{ .text = std.fmt.bufPrintSentinel(buf, "{s}", .{insn.text()}, 0) catch unreachable, .comment = comment };
        },
        .bad => .{ .text = "(bad)", .dim = true },
        .unreadable => .{ .text = "??", .dim = true },
    };
}

fn describe(self: *AsmView, address: usize, buf: *[128]u8) [:0]const u8 {
    var name: [112]u8 = undefined;
    if (self.symbols.describe(address, &name)) |n| {
        if (std.fmt.bufPrintSentinel(buf, "; {s}", .{n}, 0)) |s| return s else |_| {}
    }
    return std.fmt.bufPrintSentinel(buf, "; 0x{x}", .{address}, 0) catch unreachable;
}

fn lineBytes(self: *AsmView, line: Line) ?[]const u8 {
    if (line.kind == .unreadable) return null;
    const offset = line.address - self.base;
    return self.bytes[offset..][0..line.len];
}

fn formatBytes(buf: []u8, line: Line, bytes: ?[]const u8) [:0]const u8 {
    const b = bytes orelse return "??";
    var len: usize = 0;
    for (b[0..@min(b.len, shown_bytes)], 0..) |byte, i| {
        len += (std.fmt.bufPrint(buf[len..], "{s}{X:0>2}", .{ if (i == 0) "" else " ", byte }) catch unreachable).len;
    }
    if (line.len > shown_bytes) len += (std.fmt.bufPrint(buf[len..], " ..", .{}) catch unreachable).len;
    buf[len] = 0;
    return buf[0..len :0];
}

fn keys(self: *AsmView, rows: usize) void {
    if (!ui.isWindowFocused()) return;
    // While focused the arrows and Ctrl+C are ours, not the game's
    ui.captureKeyboard();
    if (self.editing != null) {
        // The open field gets the keys, Escape too, not the window
        _ = ui.shortcut(.escape);
        return;
    }
    if (self.anchor == null) return;
    const mods = ui.mods();
    if (self.indexOf(self.cursor.address)) |index| {
        var next = index;
        if (ui.isKeyPressed(.up, true) and index > 0) next = index - 1;
        if (ui.isKeyPressed(.down, true) and index + 1 < self.line_count) next = index + 1;
        if (next != index) {
            self.cursor = .of(self.lines[next]);
            if (!mods.shift) self.anchor = self.cursor;
            const last_full = self.top_index + rows -| 2;
            if (next < self.top_index or next > last_full) {
                const top = if (next < self.top_index) next else next - (last_full - self.top_index);
                self.top = self.lines[top].address;
                self.scroll_frac = 0;
                self.moved = true;
            }
        }
    }
    if (ui.isKeyPressed(.enter, false) or ui.isKeyPressed(.keypad_enter, false)) self.edit();
}

/// Begin `menu` right after `draw`.
pub fn commands(self: *AsmView, menu: *ui.Commands) void {
    const any = self.selection() != null;
    if (menu.item(.{ .label = "Replace instruction", .chord = root.keys.edit, .enabled = any and self.editing == null, .tooltip = "Type a new one over it (Enter or a double-click does too)" })) self.edit();
    menu.separator();
    if (menu.item(.{ .label = "Copy", .chord = root.keys.copy, .enabled = any, .tooltip = "The selected rows as shown" })) self.copy();
    if (menu.item(.{ .label = "Copy address", .chord = root.keys.copy_address, .enabled = any })) {
        if (self.selection()) |r| ui.setClipboard(ui.format("0x{x}", .{r.start}));
    }
}

fn indexOf(self: *const AsmView, address: usize) ?usize {
    for (self.lines[0..self.line_count], 0..) |line, i| {
        if (line.address == address) return i;
    }
    return null;
}

/// Only rows decoded around the view, so a far selection gets cut short.
pub fn copy(self: *AsmView) void {
    var out: [16 * 1024]u8 = undefined;
    var len: usize = 0;
    for (self.lines[0..self.line_count]) |line| {
        if (!self.isSelected(line.address)) continue;
        var bytes_buf: [64]u8 = undefined;
        const bytes = formatBytes(&bytes_buf, line, self.lineBytes(line));
        var text_buf: [128]u8 = undefined;
        var comment_buf: [128]u8 = undefined;
        const shown = self.instructionText(line, &text_buf, &comment_buf);
        const row = std.fmt.bufPrint(out[len .. out.len - 1], "{s}{X:0>16}  {s}  {s}{s}{s}", .{
            if (len == 0) "" else "\n",
            line.address,
            bytes,
            shown.text,
            if (shown.comment != null) "  " else "",
            shown.comment orelse "",
        }) catch break;
        len += row.len;
    }
    if (len == 0) return;
    out[len] = 0;
    ui.setClipboard(out[0..len :0]);
}

fn drawText(list: ui.DrawList, x: f32, y: f32, colour: u32, s: []const u8) void {
    list.addText(.{ x, y }, colour, s);
}

const tests = struct {
    const testing = std.testing;

    /// 16 `mov eax, 1`s at `code_at`, nothing readable around them.
    const code_at: usize = 0x10000;
    const code: [80]u8 = @bitCast(@as([16][5]u8, @splat(.{ 0xB8, 0x01, 0x00, 0x00, 0x00 })));

    fn read(_: ?*anyopaque, address: usize, out: []u8) Memory.Error!void {
        if (address < code_at or address + out.len > code_at + code.len) return error.Unreadable;
        @memcpy(out, code[address - code_at ..][0..out.len]);
    }

    const memory: Memory = .{ .vtable = &.{ .read = read } };

    fn expectContiguous(view: *const AsmView) !void {
        try testing.expectEqual(view.top, view.lines[view.top_index].address);
        for (view.lines[1..view.line_count], view.lines[0 .. view.line_count - 1]) |line, prev| {
            try testing.expectEqual(prev.address + prev.len, line.address);
        }
    }

    test "rows above line up" {
        var view: AsmView = .{ .memory = memory, .top = code_at + 60 };
        view.decodeLines(3);
        try expectContiguous(&view);
        try testing.expectEqual(code_at + 10, view.lines[0].address);
        try testing.expectEqual(10, view.top_index);
        for (view.lines[0..view.top_index]) |line| try testing.expectEqual(Line.Kind.code, line.kind);
    }

    test "top mid-instruction" {
        var view: AsmView = .{ .memory = memory, .top = code_at + 62 };
        view.decodeLines(3);
        try expectContiguous(&view);
    }

    test "rows past the screen" {
        var view: AsmView = .{ .memory = memory, .top = code_at + 60 };
        view.decodeLines(3);
        const last = view.lines[view.line_count - 1];
        try testing.expect(last.address + last.len >= view.top + 3 * 5 + margin);
        try testing.expectEqual(Line.Kind.unreadable, last.kind);
        try testing.expectEqual(0, (last.address + last.len) % block);
    }

    test "RIP-relative comments" {
        if (@sizeOf(usize) != 8) return error.SkipZigTest;
        const Rip = struct {
            const bytes: [16]u8 = .{ 0x8B, 0x05, 0x10, 0x00, 0x00, 0x00, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90, 0x90 };
            fn read(_: ?*anyopaque, address: usize, out: []u8) Memory.Error!void {
                if (address != code_at) return error.Unreadable;
                @memcpy(out, &bytes);
            }
        };
        var view: AsmView = .{ .memory = .{ .vtable = &.{ .read = Rip.read } }, .top = code_at };
        view.decodeLines(3);
        var buf: [128]u8 = undefined;
        var comment_buf: [128]u8 = undefined;
        const line = view.lines[view.top_index];
        const relative = view.instructionText(line, &buf, &comment_buf);
        try testing.expectEqualStrings("mov eax, dword ptr [rip+0x10]", relative.text);
        try testing.expectEqualStrings("; 0x10016", relative.comment.?);

        const Names = struct {
            fn describe(_: ?*anyopaque, address: usize, out: []u8) ?[]const u8 {
                return std.fmt.bufPrint(out, "kai.exe+0x{x}", .{address - code_at}) catch null;
            }
        };
        view.symbols = .{ .vtable = &.{ .describe = Names.describe } };
        try testing.expectEqualStrings("; kai.exe+0x16", view.instructionText(line, &buf, &comment_buf).comment.?);

        view.addresses = .absolute;
        const absolute = view.instructionText(line, &buf, &comment_buf);
        try testing.expectEqualStrings("mov eax, dword ptr [0x10016]", absolute.text);
        try testing.expectEqual(null, absolute.comment);
    }

    test "selection length" {
        var view: AsmView = .{ .memory = memory };
        view.goTo(code_at + 20);
        view.decodeLines(3);
        try testing.expectEqual(Range{ .start = code_at + 20, .len = 5, .memory = memory }, view.selection().?);
    }

    test "replace pads with nops" {
        const Writable = struct {
            var bytes: [code.len]u8 = code;

            fn read(_: ?*anyopaque, address: usize, out: []u8) Memory.Error!void {
                if (address < code_at or address + out.len > code_at + bytes.len) return error.Unreadable;
                @memcpy(out, bytes[address - code_at ..][0..out.len]);
            }

            fn write(_: ?*anyopaque, address: usize, in: []const u8) Memory.Error!void {
                if (address < code_at or address + in.len > code_at + bytes.len) return error.Unwritable;
                @memcpy(bytes[address - code_at ..][0..in.len], in);
            }
        };
        var view: AsmView = .{ .memory = .{ .vtable = &.{ .read = Writable.read, .write = Writable.write } } };
        view.goTo(code_at + 10);
        view.decodeLines(3);

        view.edit();
        try testing.expectEqualStrings("mov eax, 0x1", std.mem.sliceTo(&view.editing.?.text, 0));
        try testing.expect(view.replace(code_at + 10, "nop"));
        try testing.expectEqualSlices(u8, &@as([5]u8, @splat(0x90)), Writable.bytes[10..15]);
        try testing.expectEqual(code_at + 15, view.cursor.address);

        view.decodeLines(3);
        try testing.expect(view.replace(code_at + 15, "add ebx, 0x12345678"));
        try testing.expectEqualSlices(u8, &.{ 0x81, 0xC3, 0x78, 0x56, 0x34, 0x12, 0x90, 0x90, 0x90, 0x90, 0xB8 }, Writable.bytes[15..26]);
        try testing.expectEqual(code_at + 25, view.cursor.address);
        try testing.expectEqual(null, view.problem);

        const before = Writable.bytes;
        try testing.expect(!view.replace(code_at + 25, "mov eax,"));
        try testing.expect(view.problem.?.message().len > 0);
        view.decodeLines(3);
        try testing.expect(!view.replace(code_at + code.len - 2, "mov eax, 1"));
        try testing.expect(std.mem.startsWith(u8, view.problem.?.message(), "couldn't write there"));
        try testing.expectEqualSlices(u8, &before, &Writable.bytes);

        const Hooked = struct {
            fn find(_: ?*anyopaque, start: usize, len: usize, out: []Claims.Claim) usize {
                const claim: Claims.Claim = .{ .start = code_at + 30, .len = 5, .kind = .hook, .id = 43 };
                if (!claim.overlaps(start, len) or out.len == 0) return 0;
                out[0] = claim;
                return 1;
            }
        };
        view.claims = .{ .vtable = &.{ .find = Hooked.find } };
        view.goTo(code_at + 30);
        view.decodeLines(3);
        view.edit();
        try testing.expectEqual(null, view.editing);
        try testing.expect(std.mem.indexOf(u8, view.problem.?.message(), "is hook 43's") != null);
        view.goTo(code_at + 25);
        view.decodeLines(3);
        view.edit();
        try testing.expect(view.editing != null);
        try testing.expectEqual(null, view.problem);
        try testing.expect(!view.replace(code_at + 25, "add ebx, 0x12345678"));
        try testing.expect(std.mem.indexOf(u8, view.problem.?.message(), "is hook 43's") != null);
        try testing.expectEqualSlices(u8, &before, &Writable.bytes);
    }
};

test {
    _ = tests;
}
