//! Asks before doing something, in a small modal centered on the window that asks, not the screen.
//! Keep one per question, call `open` when it's time, and `draw` every frame from that window.

const Confirm = @This();

const root = @import("root.zig");
const c = root.c;
const raw = root.raw;

pub const Options = struct {
    yes: [:0]const u8 = "OK",
    no: [:0]const u8 = "Cancel",
};

/// Set by `open`, and the next `draw` shows it.
asking: bool = false,

pub fn open(self: *Confirm) void {
    self.asking = true;
}

/// True the frame it's answered yes. `title` is its ID too, so give it a `##` part if it's not
/// unique. Call it outside tables, or its buttons can't be clicked.
pub fn draw(self: *Confirm, title: [:0]const u8, comptime fmt: []const u8, args: anytype, options: Options) bool {
    const name = root.str(title);
    if (self.asking) {
        self.asking = false;
        _ = raw("ImGui_OpenPopup")(name, 0);
        // The middle of the window asking, which might not be on the main viewport at all
        const pos = raw("ImGui_GetWindowPos")();
        const size = raw("ImGui_GetWindowSize")();
        const middle: c.ImVec2 = .{ .x = pos.x + size.x / 2, .y = pos.y + size.y / 2 };
        raw("ImGui_SetNextWindowPosEx")(middle, c.ImGuiCond_Appearing, .{ .x = 0.5, .y = 0.5 });
    }
    if (!raw("ImGui_BeginPopupModal")(name, null, c.ImGuiWindowFlags_AlwaysAutoResize | c.ImGuiWindowFlags_NoSavedSettings)) return false;
    defer raw("ImGui_EndPopup")();
    root.text(fmt, args);
    root.spacing();
    var yes = false;
    if (root.button(options.yes) or root.isKeyPressed(.enter, false)) {
        yes = true;
        raw("ImGui_CloseCurrentPopup")();
    }
    root.sameLine();
    if (root.button(options.no) or root.isKeyPressed(.escape, false)) raw("ImGui_CloseCurrentPopup")();
    return yes;
}
