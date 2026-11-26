//! Fading popups stacked in a screen corner. Push from any thread, `draw` once a frame.

const Toasts = @This();

const std = @import("std");
const atomic = @import("tuft_arch").atomic;

const root = @import("root.zig");
const c = root.c;
const raw = root.raw;

pub const Kind = enum(u8) { info, success, warning, @"error" };

pub const Toast = struct {
    kind: Kind = .info,
    /// Bold line on top, can be empty. Cut off past `max_title` bytes.
    title: []const u8 = "",
    /// Wrapped. Cut off past `max_text` bytes.
    text: []const u8 = "",
    /// How long it stays up, not counting while hovered. 0 keeps it until it's clicked or dismissed.
    seconds: f32 = 4,
};

/// Never 0, so 0 can mean none.
pub const Id = u32;

/// Pushing more drops the oldest.
pub const capacity = 8;
pub const max_title = 64;
pub const max_text = 256;

pub const Corner = enum { top_left, top_right, bottom_left, bottom_right };

pub const Options = struct {
    corner: Corner = .bottom_right,
    /// Unscaled, from the edges.
    margin: root.Vec2 = .{ 16, 16 },
    /// Unscaled.
    width: f32 = 320,
    /// `focused` follows the last used platform window, for apps whose main one is hidden.
    viewport: enum { main, focused } = .main,
};

const fade_in = 0.15;
const fade_out = 0.4;

const Slot = struct {
    id: Id,
    kind: Kind,
    seconds: f32,
    age: f32 = 0,
    closing: bool = false,
    title_len: u8 = 0,
    text_len: u16 = 0,
    title_buf: [max_title]u8 = undefined,
    text_buf: [max_text]u8 = undefined,

    fn set(self: *Slot, toast: Toast) void {
        self.kind = toast.kind;
        self.seconds = @max(toast.seconds, 0);
        self.title_len = @intCast(fit(&self.title_buf, toast.title));
        self.text_len = @intCast(fit(&self.text_buf, toast.text));
    }

    fn title(self: *const Slot) []const u8 {
        return self.title_buf[0..self.title_len];
    }

    fn text(self: *const Slot) []const u8 {
        return self.text_buf[0..self.text_len];
    }

    fn alpha(self: *const Slot) f32 {
        var a: f32 = self.age / fade_in;
        if (self.seconds > 0) a = @min(a, (self.seconds - self.age) / fade_out);
        return std.math.clamp(a, 0, 1);
    }

    fn expired(self: *const Slot) bool {
        return self.seconds > 0 and self.age >= self.seconds;
    }

    fn close(self: *Slot) void {
        if (self.closing) return;
        self.closing = true;
        self.seconds = self.age + self.alpha() * fade_out;
    }
};

locked: atomic.Value(bool) = .init(false),
/// Oldest first.
slots: [capacity]Slot = undefined,
len: u8 = 0,
last_id: Id = 0,
/// Draw thread only.
viewport: c.ImGuiID = 0,

/// Any thread.
pub fn push(self: *Toasts, toast: Toast) Id {
    self.lock();
    defer self.unlock();
    if (self.len == capacity) {
        std.mem.copyForwards(Slot, self.slots[0 .. capacity - 1], self.slots[1..]);
        self.len -= 1;
    }
    self.last_id +%= 1;
    if (self.last_id == 0) self.last_id = 1;
    const slot = &self.slots[self.len];
    slot.* = .{ .id = self.last_id, .kind = toast.kind, .seconds = 0 };
    slot.set(toast);
    self.len += 1;
    return self.last_id;
}

/// Changes what it says and starts its time over. False if it's gone. Any thread.
pub fn update(self: *Toasts, id: Id, toast: Toast) bool {
    self.lock();
    defer self.unlock();
    const slot = self.find(id) orelse return false;
    slot.set(toast);
    slot.closing = false;
    slot.age = @min(slot.age, fade_in);
    return true;
}

/// Fades it out. Any thread.
pub fn dismiss(self: *Toasts, id: Id) void {
    self.lock();
    defer self.unlock();
    if (self.find(id)) |slot| slot.close();
}

/// Any thread.
pub fn clear(self: *Toasts) void {
    self.lock();
    defer self.unlock();
    self.len = 0;
}

/// Any thread.
pub fn count(self: *Toasts) usize {
    self.lock();
    defer self.unlock();
    return self.len;
}

/// Inside a frame, on the thread that owns it. Newest sits in the corner.
pub fn draw(self: *Toasts, options: Options) void {
    self.lock();
    defer self.unlock();
    if (self.len == 0) return;

    const dt = raw("ImGui_GetIO")().*.DeltaTime;
    const viewport = self.pickViewport(options.viewport);
    const right = options.corner == .top_right or options.corner == .bottom_right;
    const bottom = options.corner == .bottom_left or options.corner == .bottom_right;
    const area_min = viewport.*.WorkPos;
    const area_max: c.ImVec2 = .{ .x = area_min.x + viewport.*.WorkSize.x, .y = area_min.y + viewport.*.WorkSize.y };
    const x = if (right) area_max.x - root.scaled(options.margin[0]) else area_min.x + root.scaled(options.margin[0]);
    var y = if (bottom) area_max.y - root.scaled(options.margin[1]) else area_min.y + root.scaled(options.margin[1]);
    const pivot: c.ImVec2 = .{ .x = if (right) 1 else 0, .y = if (bottom) 1 else 0 };
    const width = @min(root.scaled(options.width), viewport.*.WorkSize.x);
    const gap = root.scaled(6);
    const to_front = root.rawOptional(fn () callconv(.c) void, "tuft_imgui_bring_window_to_front");

    var i: usize = self.len;
    while (i > 0) {
        i -= 1;
        const slot = &self.slots[i];
        var name_buf: [32]u8 = undefined;
        const name = std.fmt.bufPrintSentinel(&name_buf, "##tuft_toast_{d}", .{i}, 0) catch unreachable;

        raw("ImGui_PushStyleVar")(c.ImGuiStyleVar_Alpha, slot.alpha());
        raw("ImGui_SetNextWindowViewport")(viewport.*.ID);
        raw("ImGui_SetNextWindowPosEx")(.{ .x = x, .y = y }, c.ImGuiCond_Always, pivot);
        // 0 height fits it to the text every frame
        raw("ImGui_SetNextWindowSize")(.{ .x = width, .y = 0 }, c.ImGuiCond_Always);
        _ = raw("ImGui_Begin")(root.str(name), null, window_flags);
        if (to_front) |f| f();
        self.drawSlot(slot);
        const size = raw("ImGui_GetWindowSize")();
        const hovered = raw("ImGui_IsWindowHovered")(0);
        if (hovered and raw("ImGui_IsMouseClicked")(c.ImGuiMouseButton_Left)) slot.close();
        raw("ImGui_End")();
        raw("ImGui_PopStyleVar")();

        if (!hovered or slot.closing) slot.age += dt;
        y += if (bottom) -(size.y + gap) else size.y + gap;
    }

    var kept: u8 = 0;
    for (self.slots[0..self.len]) |slot| {
        if (slot.expired()) continue;
        self.slots[kept] = slot;
        kept += 1;
    }
    self.len = kept;
}

const window_flags = c.ImGuiWindowFlags_NoDecoration | c.ImGuiWindowFlags_NoSavedSettings |
    c.ImGuiWindowFlags_NoFocusOnAppearing | c.ImGuiWindowFlags_NoNav | c.ImGuiWindowFlags_NoDocking |
    c.ImGuiWindowFlags_NoMove | c.ImGuiWindowFlags_NoBringToFrontOnFocus;

fn drawSlot(_: *Toasts, slot: *const Slot) void {
    const color = kindColor(slot.kind);
    if (slot.title_len > 0) {
        const b = root.bold();
        defer b.end();
        const coloured = root.withColor(c.ImGuiCol_Text, color);
        defer coloured.end();
        textOf(slot.title());
    }
    if (slot.text_len > 0) {
        raw("ImGui_PushTextWrapPos")(0);
        textOf(slot.text());
        raw("ImGui_PopTextWrapPos")();
    }

    // Accent down the left edge and the time left along the bottom
    const pos = raw("ImGui_GetWindowPos")();
    const size = raw("ImGui_GetWindowSize")();
    const list = root.getWindowDrawList();
    list.pushClipRectFullScreen();
    defer list.popClipRect();
    const packed_color = raw("ImGui_GetColorU32ImVec4")(color);
    const rounding = raw("ImGui_GetStyle")().*.WindowRounding;
    raw("ImDrawList_AddRectFilledEx")(list.ptr, pos, .{ .x = pos.x + root.scaled(3), .y = pos.y + size.y }, packed_color, rounding, c.ImDrawFlags_RoundCornersLeft);
    if (slot.seconds > 0 and !slot.closing) {
        const left = std.math.clamp(1 - slot.age / slot.seconds, 0, 1);
        const bar_y = pos.y + size.y - root.scaled(2);
        list.addRectFilled(.{ pos.x, bar_y }, .{ pos.x + size.x * left, pos.y + size.y }, packed_color & 0x80FFFFFF);
    }
}

fn textOf(s: []const u8) void {
    raw("ImGui_TextUnformattedEx")(@ptrCast(s.ptr), @ptrCast(s.ptr + s.len));
}

fn kindColor(kind: Kind) c.ImVec4 {
    return switch (kind) {
        .info => .{ .x = 0.40, .y = 0.65, .z = 1.00, .w = 1 },
        .success => .{ .x = 0.35, .y = 0.80, .z = 0.45, .w = 1 },
        .warning => .{ .x = 1.00, .y = 0.75, .z = 0.30, .w = 1 },
        .@"error" => .{ .x = 1.00, .y = 0.40, .z = 0.40, .w = 1 },
    };
}

fn pickViewport(self: *Toasts, which: @FieldType(Options, "viewport")) *c.ImGuiViewport {
    const main: *c.ImGuiViewport = @ptrCast(raw("ImGui_GetMainViewport")());
    if (which == .main) return main;
    const list = raw("ImGui_GetPlatformIO")().*.Viewports;
    if (list.Size > 0) for (list.Data[0..@intCast(list.Size)]) |vp| {
        if (vp.*.Flags & c.ImGuiViewportFlags_IsFocused != 0 and vp.*.Flags & c.ImGuiViewportFlags_IsMinimized == 0) {
            self.viewport = vp.*.ID;
            return vp;
        }
    };
    if (self.viewport != 0) {
        const vp = raw("ImGui_FindViewportByID")(self.viewport);
        if (vp != null and vp.*.Flags & c.ImGuiViewportFlags_IsMinimized == 0) return vp;
    }
    return main;
}

fn find(self: *Toasts, id: Id) ?*Slot {
    for (self.slots[0..self.len]) |*slot| if (slot.id == id) return slot;
    return null;
}

fn lock(self: *Toasts) void {
    while (self.locked.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
}

fn unlock(self: *Toasts) void {
    self.locked.store(false, .release);
}

/// Copies what fits without splitting a UTF-8 character.
fn fit(dst: []u8, src: []const u8) usize {
    var n = @min(dst.len, src.len);
    if (n < src.len) {
        while (n > 0 and src[n] & 0xC0 == 0x80) n -= 1;
    }
    @memcpy(dst[0..n], src[0..n]);
    return n;
}

test fit {
    var buf: [4]u8 = undefined;
    try std.testing.expectEqual(2, fit(&buf, "ab"));
    try std.testing.expectEqual(4, fit(&buf, "abcdef"));
    // "é" is 2 bytes and would straddle the end
    try std.testing.expectEqual(3, fit(&buf, "abcé"));
}

test "push drops the oldest when full" {
    var toasts: Toasts = .{};
    const first = toasts.push(.{ .text = "first" });
    for (0..capacity) |_| _ = toasts.push(.{});
    try std.testing.expectEqual(capacity, toasts.count());
    try std.testing.expect(!toasts.update(first, .{}));
}
