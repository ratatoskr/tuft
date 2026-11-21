//! Cheat Engine style value search, run on its own thread.

const SearchView = @This();

const std = @import("std");

const ui = @import("tuft_ui");
const mem = @import("tuft_mem");
const sys = @import("tuft_sys");

const root = @import("root.zig");
const Memory = mem.Memory;
const Symbols = mem.Symbols;
const Search = mem.Search;
const Kind = mem.values.Kind;

memory: Memory,
symbols: Symbols = .none,

kind: Kind = .four_bytes,
value: [mem.values.max_len:0]u8 = @splat(0),
scope: Scope = .writable,
name: [128:0]u8 = @splat(0),
aligned: bool = true,
compare: Search.Compare = .exact,

/// Created on the first search. Only read the results while `running` is false.
search: ?Search = null,
worker: ?std.Thread = null,
running: std.atomic.Value(bool) = .init(false),
/// The worker sets it before clearing `running`.
problem: ?anyerror = null,
job: Job = .first,
picked: ui.Selection = .{},

pub const Scope = enum {
    writable,
    all,
    named,

    fn label(s: Scope) [:0]const u8 {
        return switch (s) {
            .writable => "Writable memory",
            .all => "All memory",
            .named => "Module or section",
        };
    }
};

pub const Job = enum { first, next };

pub const Hit = struct { address: usize, len: usize, kind: Kind };

pub fn deinit(self: *SearchView) void {
    // Keep cancelling until it stops. A search clears the cancel flag as it starts
    while (self.running.load(.acquire)) {
        if (self.search) |*s| s.cancel();
        sys.thread.sleepMs(1);
    }
    if (self.worker) |w| w.join();
    self.worker = null;
    if (self.search) |*s| s.deinit();
    self.search = null;
    self.picked.deinit();
}

pub fn selection(self: *const SearchView) ?Hit {
    const i = self.picked.focused() orelse return null;
    return self.hit(@intCast(i));
}

pub fn hit(self: *const SearchView, i: usize) ?Hit {
    if (self.running.load(.acquire)) return null;
    const s = &(self.search orelse return null);
    if (i >= s.count) return null;
    return .{ .address = s.address(i), .len = s.value_len, .kind = s.kind orelse return null };
}

pub fn selectedHits(self: *const SearchView, out: []Hit) []Hit {
    var n: usize = 0;
    var indices: [256]u64 = undefined;
    const keys = self.picked.keys();
    const take = @min(keys.len, indices.len, out.len);
    @memcpy(indices[0..take], keys[0..take]);
    std.mem.sort(u64, indices[0..take], {}, std.sort.asc(u64));
    for (indices[0..take]) |i| {
        out[n] = self.hit(@intCast(i)) orelse continue;
        n += 1;
    }
    return out[0..n];
}

/// A result was double-clicked this frame.
pub fn activated(self: *const SearchView) bool {
    return self.picked.activated;
}

pub fn draw(self: *SearchView) void {
    self.collect();
    if (self.running.load(.acquire)) {
        self.picked.activated = false;
        self.drawRunning();
        return;
    }
    self.drawControls();
    self.drawResults();
}

/// Begin it right after `draw`.
pub fn commands(self: *SearchView, menu: *ui.Commands) void {
    const any = self.picked.count() > 0 and !self.running.load(.acquire);
    if (menu.item(.{ .label = "Copy", .chord = root.keys.copy, .enabled = any, .tooltip = "Picked results' addresses and values" })) self.copy(false);
    if (menu.item(.{ .label = "Copy address", .chord = root.keys.copy_address, .enabled = any })) self.copy(true);
}

fn copy(self: *SearchView, addresses_only: bool) void {
    var hits: [256]Hit = undefined;
    var out: std.Io.Writer.Allocating = .init(std.heap.smp_allocator);
    defer out.deinit();
    var current: [mem.values.max_len]u8 = undefined;
    var text: [512]u8 = undefined;
    for (self.selectedHits(&hits), 0..) |h, n| {
        if (n > 0) out.writer.writeByte('\n') catch return;
        out.writer.print("0x{x}", .{h.address}) catch return;
        if (addresses_only) continue;
        const value = if (self.memory.read(h.address, current[0..h.len])) |_| mem.values.format(h.kind, current[0..h.len], &text) else |_| "??";
        out.writer.print("\t{s}", .{value}) catch return;
    }
    out.writer.writeByte(0) catch return;
    const written = out.written();
    ui.setClipboard(written[0 .. written.len - 1 :0]);
}

/// One control a line, or two side by side, to fit narrow panels too.
fn drawControls(self: *SearchView) void {
    const has_results = if (self.search) |s| s.kind != null else false;
    var submitted = false;

    {
        const disabled = ui.disabled(has_results and !self.compare.takesValue());
        defer disabled.end();
        ui.setNextItemWidth(ui.fill);
        if (ui.inputTextWith("##value", &self.value, .{ .hint = hint(self.kind), .flags = .{ .enter_returns_true = true } })) submitted = true;
    }

    const half = halfWidth();
    ui.setNextItemWidthPixels(if (has_results) half else ui.getContentRegionAvailPixels()[0]);
    {
        // Kind is locked between a search and searching again
        const disabled = ui.disabled(has_results);
        defer disabled.end();
        var kind: usize = @backingInt(self.kind);
        if (ui.combo("##kind", &kind, &kind_labels)) self.kind = @fromBackingInt(@intCast(kind));
    }
    if (has_results) {
        ui.sameLine();
        ui.setNextItemWidth(ui.fill);
        var compare: usize = @backingInt(self.compare);
        if (ui.combo("##compare", &compare, &compare_labels)) self.compare = @fromBackingInt(@intCast(compare));
    }

    {
        const disabled = ui.disabled(has_results);
        defer disabled.end();
        const aligned_w = if (self.kind.isNumber()) checkboxWidth("Aligned") + ui.scaled(ui.getStyle().item_spacing[0]) else 0;
        ui.setNextItemWidthPixels(ui.getContentRegionAvailPixels()[0] - aligned_w);
        var scope: usize = @backingInt(self.scope);
        if (ui.combo("##scope", &scope, &scope_labels)) self.scope = @fromBackingInt(@intCast(scope));
        if (self.kind.isNumber()) {
            ui.sameLine();
            _ = ui.checkbox("Aligned", &self.aligned);
            ui.tooltip("Only at addresses that are a multiple of the value's size, where programs keep numbers", .{});
        }
        if (self.scope == .named) {
            ui.setNextItemWidth(ui.fill);
            if (ui.inputTextWith("##name", &self.name, .{ .hint = "kai.exe or kai.exe:.data", .flags = .{ .enter_returns_true = true } })) submitted = true;
        }
    }

    if (!has_results) {
        if (ui.buttonSized("Search", .{ halfWidth(), 0 }) or submitted) self.start(.first);
    } else {
        if (ui.buttonSized("Search again", .{ halfWidth(), 0 }) or submitted) self.start(.next);
        ui.tooltip("Search the results again, keeping those that match (Enter in the value does too)", .{});
        ui.sameLine();
        if (ui.buttonSized("New search", .{ ui.getContentRegionAvailPixels()[0], 0 })) {
            self.search.?.reset();
            self.picked.clear();
            self.problem = null;
        }
    }
    if (self.problem) |err| {
        if (err == error.Cancelled) ui.textDisabled("Stopped", .{}) else ui.textColored(.{ 1, 0.4, 0.4, 1 }, "{t}", .{err});
    }
}

fn halfWidth() f32 {
    const gap = ui.getStyle().item_spacing[0] * ui.scale();
    return @max(1, (ui.getContentRegionAvailPixels()[0] - gap) / 2);
}

fn checkboxWidth(label: []const u8) f32 {
    return ui.frameHeight() + ui.scaled(ui.getStyle().item_inner_spacing[0]) + ui.calcTextSize(label)[0];
}

fn drawHint(self: *const SearchView) void {
    _ = self;
    ui.spacing();
    ui.textWrapped("Type a value the game shows, like your health, and press Enter. Then change it in the game and search again to narrow it down.", .{});
}

fn drawRunning(self: *SearchView) void {
    const s = &self.search.?;
    ui.text("Searching... {d:.0}%", .{s.progress.fraction() * 100});
    ui.sameLine();
    if (ui.button("Cancel")) s.cancel();
}

fn drawResults(self: *SearchView) void {
    self.picked.activated = false;
    const s = &(self.search orelse return self.drawHint());
    if (s.kind == null) return self.drawHint();
    ui.text("{d} found", .{s.count});
    if (self.picked.count() > 1) {
        ui.sameLine();
        ui.textDisabled("({d} picked)", .{self.picked.count()});
    }
    if (s.truncated) {
        ui.sameLine();
        ui.textColored(.{ 1, 0.8, 0.3, 1 }, "(stopped at the limit: search again to narrow it down)", .{});
    }

    const table = ui.table("results", 3, .{ .borders = true, .row_background = true, .resizable = true, .sortable = true, .scroll_y = true }) orelse return;
    defer table.end();
    ui.tableColumnWith("Address", .{ .stretch = true });
    ui.tableColumnWith("Value", .{ .stretch = true, .no_sort = true });
    ui.tableColumnWith("Previous", .{ .stretch = true, .no_sort = true });
    ui.tableHeaders();
    // Hits are in address order. Descending just walks them backwards
    const backwards = if (table.sortedBy(enum { address, value, previous })) |by| by.descending else false;

    var current: [mem.values.max_len]u8 = undefined;
    var text: [512]u8 = undefined;
    var picking = self.picked.begin(s.count, Shown{ .count = s.count, .backwards = backwards }, .{});
    defer picking.end();
    var rows = ui.clip(s.count);
    rows.include(picking.keep());
    while (rows.next()) |row| {
        const i = if (backwards) s.count - 1 - row else row;
        const at = s.address(i);
        const scope = ui.id(@as(i32, @intCast(i % std.math.maxInt(i32))));
        defer scope.end();
        ui.tableNextRow();
        _ = ui.tableNextColumn();
        var where: [128]u8 = undefined;
        const name = self.symbols.describe(at, &where) orelse (std.fmt.bufPrint(&where, "0x{x}", .{at}) catch "");
        _ = picking.row(row, ui.format("{s}", .{name}));
        _ = ui.tableNextColumn();
        const kind = s.kind.?;
        if (self.memory.read(at, current[0..s.value_len])) {
            ui.text("{s}", .{mem.values.format(kind, current[0..s.value_len], &text)});
        } else |_| {
            ui.textDisabled("??", .{});
        }
        _ = ui.tableNextColumn();
        ui.textDisabled("{s}", .{mem.values.format(kind, s.previous(i), &text)});
    }
}

const Shown = struct {
    count: usize,
    backwards: bool,

    pub fn id(self: Shown, row: usize) u64 {
        return if (self.backwards) self.count - 1 - row else row;
    }
};

/// Ignored while one is running.
pub fn start(self: *SearchView, job: Job) void {
    if (self.running.load(.acquire)) return;
    self.collect();
    if (self.search == null) self.search = .init(self.memory);
    // Results get renumbered, so what was picked means nothing after
    self.picked.clear();
    self.problem = null;
    self.job = job;
    self.running.store(true, .release);
    self.worker = std.Thread.spawn(.{}, run, .{self}) catch |err| {
        self.running.store(false, .release);
        self.problem = err;
        return;
    };
}

/// Runs on the worker. Only it touches `search` until it clears `running`.
fn run(self: *SearchView) void {
    defer self.running.store(false, .release);
    const s = &self.search.?;
    const text = std.mem.sliceTo(&self.value, 0);
    const result = switch (self.job) {
        .first => blk: {
            const where: Search.Where = switch (self.scope) {
                .writable => .{ .all = .{ .writable_only = true } },
                .all => .{ .all = .{} },
                .named => named: {
                    const e = self.symbols.extent(std.mem.trim(u8, std.mem.sliceTo(&self.name, 0), " ")) orelse break :blk error.UnknownName;
                    break :named .{ .range = .{ .start = e.start, .len = e.len } };
                },
            };
            break :blk s.first(where, self.kind, text, .{ .aligned = self.aligned });
        },
        .next => s.next(self.compare, text),
    };
    result catch |err| {
        self.problem = err;
    };
}

fn collect(self: *SearchView) void {
    if (self.running.load(.acquire)) return;
    const w = self.worker orelse return;
    w.join();
    self.worker = null;
}

fn hint(kind: Kind) [:0]const u8 {
    return switch (kind) {
        .byte, .two_bytes, .four_bytes, .eight_bytes => "100, -5 or 0x64",
        .float, .double => "1.5",
        .text, .text_utf16 => "text",
        .bytes => "48 8B ?? ?? C3",
    };
}

const kind_labels = root.labels(Kind, Kind.label);
const compare_labels = root.labels(Search.Compare, Search.Compare.label);
const scope_labels = root.labels(Scope, Scope.label);

const tests = struct {
    const testing = std.testing;

    fn waitDone(view: *SearchView) !void {
        var tries: usize = 0;
        while (view.running.load(.acquire)) : (tries += 1) {
            if (tries > 10_000) return error.Timeout;
            sys.thread.sleepMs(1);
        }
        view.collect();
    }

    test "search then narrow" {
        var mark: [3]u32 align(4) = .{ 0x51C0_FFEE, 0x51C0_FFEE, 7 };
        var view: SearchView = .{ .memory = .local, .symbols = .local };
        defer view.deinit();
        _ = try std.fmt.bufPrintSentinel(&view.value, "0x51C0FFEE", .{}, 0);
        view.start(.first);
        try waitDone(&view);
        try testing.expectEqual(null, view.problem);
        const found = view.search.?.count;
        try testing.expect(found >= 2);

        mark[0] = 1;
        view.compare = .unchanged;
        view.start(.next);
        try waitDone(&view);
        var still: bool = false;
        for (0..view.search.?.count) |i| {
            try testing.expect(view.search.?.address(i) != @intFromPtr(&mark[0]));
            if (view.search.?.address(i) == @intFromPtr(&mark[1])) still = true;
        }
        try testing.expect(still);
    }

    test "search by name" {
        var view: SearchView = .{ .memory = .local, .symbols = .local, .scope = .named };
        defer view.deinit();
        _ = try std.fmt.bufPrintSentinel(&view.value, "MZ", .{}, 0);
        view.kind = .text;
        _ = try std.fmt.bufPrintSentinel(&view.name, "kernel32.dll", .{}, 0);
        view.start(.first);
        try waitDone(&view);
        try testing.expect(view.search.?.count >= 1);
        try testing.expectEqual(Symbols.local.resolve("kernel32.dll").?, view.search.?.address(0));

        _ = try std.fmt.bufPrintSentinel(&view.name, "nothing.dll", .{}, 0);
        view.search.?.reset();
        view.start(.first);
        try waitDone(&view);
        try testing.expectEqual(error.UnknownName, view.problem.?);
    }
};

test {
    _ = tests;
}
