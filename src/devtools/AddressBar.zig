//! Address field with Back and Forward.

const AddressBar = @This();

const std = @import("std");

const ui = @import("tuft_ui");

const Symbols = @import("tuft_mem").Symbols;
const Memory = @import("tuft_mem").Memory;
const Location = @import("tuft_mem").Location;

const max_history = 32;

symbols: Symbols = .none,
/// For `[pointer]` in what's typed.
memory: ?Memory = null,
hint: [:0]const u8 = "0x7FF6A0001000, kai.exe+0x1234, (player.health) or [ptr]+8",
/// Unscaled pixels left free at the end of the row.
trailing: f32 = 0,
text: [128:0]u8 = @splat(0),
problem: ?anyerror = null,
/// What `problem` means.
problem_text: Location.Problem = .{},
history: [max_history]usize = undefined,
history_len: usize = 0,
history_at: usize = 0,
take_focus: bool = false,

pub fn focus(self: *AddressBar) void {
    self.take_focus = true;
}
/// Returns where to go if Back, Forward or Go was hit. It's already in the history.
pub fn draw(self: *AddressBar) ?usize {
    if (self.problem) |err| ui.textColored(.{ 1, 0.4, 0.4, 1 }, "{s}", .{if (self.problem_text.len > 0) self.problem_text.message() else @errorName(err)});
    var go: ?usize = null;
    {
        const disabled = ui.disabled(self.history_at == 0);
        defer disabled.end();
        if (ui.button("<")) go = self.retrace(self.history_at - 1);
    }
    ui.tooltip("Back", .{});
    ui.sameLine();
    {
        const disabled = ui.disabled(self.history_at + 1 >= self.history_len);
        defer disabled.end();
        if (ui.button(">")) go = self.retrace(self.history_at + 1);
    }
    ui.tooltip("Forward", .{});
    ui.sameLine();
    ui.setNextItemWidth(-ui.scaled(40 + self.trailing));
    if (self.take_focus) {
        self.take_focus = false;
        ui.focusNext();
    }
    const entered = ui.inputTextWith("##address", &self.text, .{ .hint = self.hint, .flags = .{ .enter_returns_true = true, .auto_select_all = true } });
    ui.sameLine();
    if (ui.button("Go") or entered) {
        self.problem_text = .{};
        if (Location.eval(std.mem.sliceTo(&self.text, 0), .{ .symbols = self.symbols, .memory = self.memory }, &self.problem_text)) |address| {
            self.visit(address);
            go = address;
        } else |err| {
            self.problem = err;
        }
    }
    return go;
}

pub fn visit(self: *AddressBar, address: usize) void {
    self.problem = null;
    if (self.history_len == 0 or self.history[self.history_at] != address) {
        if (self.history_len != 0) self.history_len = self.history_at + 1;
        if (self.history_len == max_history) {
            std.mem.copyForwards(usize, self.history[0 .. max_history - 1], self.history[1..]);
            self.history_len -= 1;
        }
        self.history[self.history_len] = address;
        self.history_at = self.history_len;
        self.history_len += 1;
    }
    self.show(address);
}

pub fn current(self: *const AddressBar) ?usize {
    return if (self.history_len == 0) null else self.history[self.history_at];
}

fn retrace(self: *AddressBar, at: usize) usize {
    self.problem = null;
    self.history_at = at;
    self.show(self.history[at]);
    return self.history[at];
}

fn show(self: *AddressBar, address: usize) void {
    _ = std.fmt.bufPrintSentinel(&self.text, "0x{x}", .{address}, 0) catch {};
}

/// See `tuft_mem.Location`, like `0x7FF6A0001000`, `kai.exe+0x1234` or `[ptr]+8`.
pub fn parse(self: *const AddressBar, text: []const u8) !usize {
    return Location.eval(text, .{ .symbols = self.symbols, .memory = self.memory }, null);
}

/// Without pointers, which need memory to read.
pub fn parseAddress(symbols: Symbols, text: []const u8) !usize {
    return Location.eval(text, .{ .symbols = symbols }, null);
}

const tests = struct {
    const testing = std.testing;

    test "parse addresses" {
        const bar: AddressBar = .{ .symbols = .local };
        try testing.expectEqual(0x6A00_1000, try bar.parse("0x6A001000"));
        try testing.expectEqual(1234, try bar.parse(" 1234 "));
        const kernel32 = Symbols.local.resolve("kernel32.dll").?;
        try testing.expectEqual(kernel32, try bar.parse("kernel32.dll"));
        try testing.expectEqual(kernel32 + 0x10, try bar.parse("kernel32.dll+0x10"));
        try testing.expectEqual(kernel32 + 0x10, try bar.parse("KERNEL32.DLL + 16"));
        try testing.expectError(error.UnknownName, bar.parse("nope.dll+0x10"));
        try testing.expectError(error.InvalidAddress, bar.parse("#"));
    }

    test "back and forward" {
        var bar: AddressBar = .{};
        bar.visit(0x1000);
        bar.visit(0x2000);
        bar.visit(0x3000);
        try testing.expectEqual(0x2000, bar.retrace(bar.history_at - 1));
        try testing.expectEqual(0x2000, bar.current());
        bar.visit(0x4000);
        try testing.expectEqual(3, bar.history_len);
        try testing.expectEqual(0x4000, bar.current());
        try testing.expectEqualStrings("0x4000", std.mem.sliceTo(&bar.text, 0));
    }
};

test {
    _ = tests;
}
