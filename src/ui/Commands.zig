//! A view's commands, shared by its right-click menu, keys, default action and the Edit menu.

const Commands = @This();

const std = @import("std");

const root = @import("root.zig");
const c = root.c;
const raw = root.raw;
const Chord = root.Chord;

const max_recorded = 32;

pub const Item = struct {
    /// Has to outlive the frame since the Edit menu shows it later.
    label: [:0]const u8,
    chord: ?Chord = null,
    enabled: bool = true,
    /// Runs on Enter or a double-click too. The first enabled one does.
    default: bool = false,
    /// Shown on hover in the menu.
    tooltip: ?[:0]const u8 = null,
    /// The app checks its chord itself, so it's only shown here.
    global: bool = false,
};

pub const Options = struct {
    /// Like when `Selection.activated`.
    activated: bool = false,
};

owner: c.ImGuiID,
popup: bool,
/// Has focus and nothing's being typed.
keys: bool,
activate: bool,
/// Focused, so the Edit menu shows these.
record: bool,
/// Picked from the Edit menu last frame.
pending: ?u8 = null,
next: u8 = 0,
separate_next: bool = false,

pub fn begin(id: [:0]const u8, options: Options) Commands {
    // Menu items begun inside a table can't be clicked. Begin after `Table.end`
    std.debug.assert(raw("ImGui_TableGetColumnCount")() == 0);
    const owner = raw("ImGui_GetID")(root.str(id));
    const focused = raw("ImGui_IsWindowFocused")(c.ImGuiFocusedFlags_ChildWindows);
    if (raw("ImGui_IsWindowHovered")(c.ImGuiHoveredFlags_ChildWindows) and raw("ImGui_IsMouseReleased")(c.ImGuiMouseButton_Right)) {
        _ = raw("ImGui_OpenPopup")(root.str(id), 0);
    }
    const popup = raw("ImGui_BeginPopup")(root.str(id), 0);
    const keys = focused and !popup and !root.getIO().WantTextInput and !root.listeningForKeys();
    // Plain Enter only. Ctrl+Enter and friends are commands' own keys
    const io = root.getIO();
    const plain = !io.KeyCtrl and !io.KeyShift and !io.KeyAlt;
    var self: Commands = .{
        .owner = owner,
        .popup = popup,
        .keys = keys,
        .activate = options.activated or (keys and plain and (root.isKeyPressed(.enter, false) or root.isKeyPressed(.keypad_enter, false))),
        .record = focused,
    };
    if (focused) {
        edit.owner = owner;
        edit.len = 0;
    }
    if (edit.pending) |p| if (p.owner == owner) {
        self.pending = p.index;
        edit.pending = null;
    };
    return self;
}

/// Picked, key pressed, default and activated, or picked from the Edit menu. Never if disabled.
pub fn item(self: *Commands, it: Item) bool {
    const index = self.next;
    self.next +|= 1;
    const separated = self.separate_next;
    self.separate_next = false;
    if (self.record and edit.len < max_recorded) {
        edit.items[edit.len] = .{ .item = it, .index = index, .separated = separated };
        edit.len += 1;
    }

    var fired = false;
    if (self.popup) {
        if (separated) root.separator();
        if (menuItem(it)) fired = true;
    }
    if (!it.enabled) return false;
    if (self.keys and !it.global) if (it.chord) |chord| if (chord.pressed()) {
        fired = true;
    };
    if (it.default and self.activate) {
        self.activate = false;
        fired = true;
    }
    if (self.pending == index) fired = true;
    return fired;
}

pub fn separator(self: *Commands) void {
    if (self.next > 0) self.separate_next = true;
}

pub fn end(self: *Commands) void {
    if (self.popup) raw("ImGui_EndPopup")();
}

fn menuItem(it: Item) bool {
    const shortcut: [*c]const u8 = if (it.chord) |chord| root.str(root.format("{f}", .{chord})) else null;
    const clicked = raw("ImGui_MenuItemBoolPtr")(root.str(it.label), shortcut, null, it.enabled);
    if (it.tooltip) |t| if (raw("ImGui_IsItemHovered")(c.ImGuiHoveredFlags_AllowWhenDisabled)) raw("ImGui_SetItemTooltipUnformatted")(root.str(t));
    return clicked;
}

const Recorded = struct {
    item: Item,
    index: u8,
    separated: bool,
};

/// Per thread since each thread draws its own ImGui.
const Edit = struct {
    owner: c.ImGuiID = 0,
    items: [max_recorded]Recorded = undefined,
    len: u8 = 0,
    pending: ?struct { owner: c.ImGuiID, index: u8 } = null,
};

threadlocal var edit: Edit = .{};

/// For an app's Edit menu. Picking one runs it next time that view draws.
pub fn menuItems() bool {
    if (edit.len == 0) return false;
    for (edit.items[0..edit.len]) |r| {
        if (r.separated) root.separator();
        if (menuItem(r.item)) edit.pending = .{ .owner = edit.owner, .index = r.index };
    }
    return true;
}

/// Like when the view it's for goes away.
pub fn forget() void {
    edit = .{};
}
