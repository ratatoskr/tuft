//! A box to type code or commands into, like a REPL's. Enter runs it, Shift+Enter adds a line,
//! and Up and Down go back through what ran before, from its first or last line.

const Prompt = @This();

const std = @import("std");

const root = @import("root.zig");
const c = root.c;
const raw = root.raw;

/// Not ImGui's, so it can be freed without a context.
const allocator = std.heap.smp_allocator;

pub const max_len = 8192;
const max_history = 200;
/// Taller than this scrolls.
const max_lines = 8;

buffer: [max_len:0]u8 = @splat(0),
/// What ran, oldest first.
history: std.ArrayList([]u8) = .empty,
/// Where Up and Down are in `history`. Null while typing something new.
at: ?usize = null,
/// What was being typed before going back through history.
draft: std.ArrayList(u8) = .empty,
/// What `draw` gave back last.
entered: std.ArrayList(u8) = .empty,
/// Where the cursor was last frame, so Up and Down only go through history from the first or
/// last line.
cursor: usize = 0,
submit: bool = false,
refocus: bool = false,

pub fn deinit(self: *Prompt) void {
    for (self.history.items) |h| allocator.free(h);
    self.history.deinit(allocator);
    self.draft.deinit(allocator);
    self.entered.deinit(allocator);
    self.* = .{};
}

/// What's typed now.
pub fn text(self: *const Prompt) []const u8 {
    return std.mem.sliceTo(&self.buffer, 0);
}

/// Pixels, as it'll be drawn next.
pub fn height(self: *const Prompt) f32 {
    const lines = @min(std.mem.count(u8, self.text(), "\n") + 1, max_lines);
    const style = raw("ImGui_GetStyle")();
    return @as(f32, @floatFromInt(lines)) * root.getTextLineHeight() + style.*.FramePadding.y * 2;
}

/// Fills the width left. What was entered, good till the next `draw`, or null.
pub fn draw(self: *Prompt, label: [:0]const u8, hint: []const u8) ?[]const u8 {
    if (self.refocus) {
        self.refocus = false;
        root.focusNext();
    }
    self.submit = false;
    const flags = c.ImGuiInputTextFlags_CallbackAlways | c.ImGuiInputTextFlags_EnterReturnsTrue;
    // Ctrl+Enter, which ImGui gives back itself
    const ctrl_entered = raw("ImGui_InputTextMultilineEx")(root.str(label), &self.buffer, self.buffer.len + 1, .{ .x = -std.math.floatMin(f32), .y = self.height() }, flags, callback, self);
    if (self.buffer[0] == 0 and hint.len > 0) drawHint(hint);
    if (!self.submit and !ctrl_entered) return null;
    const code = std.mem.trim(u8, self.text(), " \t\r\n");
    self.refocus = true;
    if (code.len == 0) return null;
    self.entered.clearRetainingCapacity();
    self.entered.appendSlice(allocator, code) catch return null;
    self.remember(self.entered.items);
    self.buffer[0] = 0;
    self.at = null;
    return self.entered.items;
}

fn remember(self: *Prompt, code: []const u8) void {
    // The same again isn't kept twice in a row
    if (self.history.items.len > 0 and std.mem.eql(u8, self.history.items[self.history.items.len - 1], code)) return;
    if (self.history.items.len == max_history) allocator.free(self.history.orderedRemove(0));
    const copy = allocator.dupe(u8, code) catch return;
    self.history.append(allocator, copy) catch allocator.free(copy);
}

fn drawHint(hint: []const u8) void {
    const min = root.getItemRectMin();
    const pad = raw("ImGui_GetStyle")().*.FramePadding;
    root.getWindowDrawList().addText(.{ min[0] + pad.x, min[1] + pad.y }, root.getColorU32(.text_disabled), hint);
}

fn callback(data: [*c]c.ImGuiInputTextCallbackData) callconv(.c) c_int {
    const d: *c.ImGuiInputTextCallbackData = data;
    const self: *Prompt = @ptrCast(@alignCast(d.UserData.?));
    const was = self.cursor;
    defer self.cursor = @intCast(d.CursorPos);
    const now: usize = @intCast(d.CursorPos);
    const typed = d.Buf[0..@intCast(d.BufTextLen)];
    const mods = root.mods();
    const enter = root.isKeyPressed(.enter, false) or root.isKeyPressed(.keypad_enter, false);
    if (enter and !mods.shift and !mods.ctrl) {
        // ImGui put a new line in, which Enter here runs instead
        if (now > 0 and typed[now - 1] == '\n') raw("ImGuiInputTextCallbackData_DeleteChars")(d, @intCast(now - 1), 1);
        self.submit = true;
        return 0;
    }
    const first_line = std.mem.indexOfScalar(u8, typed[0..@min(was, typed.len)], '\n') == null;
    const last_line = std.mem.indexOfScalar(u8, typed[@min(was, typed.len)..], '\n') == null;
    if (root.isKeyPressed(.up, true) and first_line) self.step(d, .back);
    if (root.isKeyPressed(.down, true) and last_line) self.step(d, .forward);
    return 0;
}

fn step(self: *Prompt, d: *c.ImGuiInputTextCallbackData, way: enum { back, forward }) void {
    const n = self.history.items.len;
    if (n == 0) return;
    const to: ?usize = switch (way) {
        .back => if (self.at) |i| (if (i > 0) i - 1 else return) else n - 1,
        .forward => if (self.at) |i| (if (i + 1 < n) i + 1 else null) else return,
    };
    // Kept, to come back to past the newest
    if (self.at == null) {
        self.draft.clearRetainingCapacity();
        self.draft.appendSlice(allocator, d.Buf[0..@intCast(d.BufTextLen)]) catch {};
    }
    self.at = to;
    const with = if (to) |i| self.history.items[i] else self.draft.items;
    const fits = with[0..@min(with.len, max_len)];
    raw("ImGuiInputTextCallbackData_DeleteChars")(d, 0, d.BufTextLen);
    raw("ImGuiInputTextCallbackData_InsertChars")(d, 0, fits.ptr, fits.ptr + fits.len);
}

test "what ran is kept once, newest last" {
    var p: Prompt = .{};
    defer p.deinit();
    p.remember("1 + 1");
    p.remember("1 + 1");
    p.remember("hooks.list()");
    try std.testing.expectEqual(2, p.history.items.len);
    try std.testing.expectEqualStrings("hooks.list()", p.history.items[1]);
}
