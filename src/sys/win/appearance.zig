const registry = @import("registry.zig");

const Mode = @import("../root.zig").appearance.Mode;

/// The app mode Settings > Personalization > Colors picks. Null before Windows 10 or if unreadable.
pub fn mode() ?Mode {
    const key = (registry.Key.open(.current_user, "Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize", .native) catch return null) orelse return null;
    defer key.close();
    const light = (key.dword("AppsUseLightTheme") catch return null) orelse return null;
    return if (light != 0) .light else .dark;
}
