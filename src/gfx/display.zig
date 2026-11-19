//! HDR state and SDR white level of a window's monitor.

const std = @import("std");

const tuft_window = @import("tuft_window");
const win = @import("tuft_sys").win;

pub const Display = struct {
    hdr: bool = false,
    sdr_white_nits: f32 = default_sdr_white_nits,
};

/// When Windows can't say.
pub const default_sdr_white_nits: f32 = 200;

/// The display `window` is mostly on.
pub fn of(window: tuft_window.Handle) Display {
    var result: Display = .{};
    const target = targetOf(window) orelse return result;

    var color: win.DISPLAYCONFIG_GET_ADVANCED_COLOR_INFO = .{ .header = header(win.DISPLAYCONFIG_DEVICE_INFO_GET_ADVANCED_COLOR_INFO, win.DISPLAYCONFIG_GET_ADVANCED_COLOR_INFO, target) };
    if (win.DisplayConfigGetDeviceInfo(&color.header) == 0) result.hdr = color.value & 0x2 != 0; // advancedColorEnabled

    var white: win.DISPLAYCONFIG_SDR_WHITE_LEVEL = .{ .header = header(win.DISPLAYCONFIG_DEVICE_INFO_GET_SDR_WHITE_LEVEL, win.DISPLAYCONFIG_SDR_WHITE_LEVEL, target) };
    if (win.DisplayConfigGetDeviceInfo(&white.header) == 0 and white.SDRWhiteLevel != 0) {
        result.sdr_white_nits = @as(f32, @floatFromInt(white.SDRWhiteLevel)) / 1000.0 * 80.0;
    }
    return result;
}

const Target = struct { adapter_id: win.LUID, id: u32 };

fn header(kind: u32, comptime Packet: type, target: Target) win.DISPLAYCONFIG_DEVICE_INFO_HEADER {
    return .{ .type = kind, .size = @sizeOf(Packet), .adapterId = target.adapter_id, .id = target.id };
}

fn targetOf(window: tuft_window.Handle) ?Target {
    const monitor = win.MonitorFromWindow(window, win.MONITOR_DEFAULTTONEAREST) orelse return null;
    var info: win.MONITORINFOEXW = .{};
    if (!win.GetMonitorInfoW(monitor, @ptrCast(&info)).toBool()) return null;
    const device = std.mem.sliceTo(&info.szDevice, 0);

    var path_count: u32 = 0;
    var mode_count: u32 = 0;
    if (win.GetDisplayConfigBufferSizes(win.QDC_ONLY_ACTIVE_PATHS, &path_count, &mode_count) != 0) return null;
    var paths: [16]win.DISPLAYCONFIG_PATH_INFO = undefined;
    var modes: [32]win.DISPLAYCONFIG_MODE_INFO = undefined;
    path_count = @min(path_count, paths.len);
    mode_count = @min(mode_count, modes.len);
    if (win.QueryDisplayConfig(win.QDC_ONLY_ACTIVE_PATHS, &path_count, &paths, &mode_count, &modes, null) != 0) return null;

    for (paths[0..path_count]) |path| {
        var source: win.DISPLAYCONFIG_SOURCE_DEVICE_NAME = .{ .header = header(win.DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME, win.DISPLAYCONFIG_SOURCE_DEVICE_NAME, .{ .adapter_id = path.sourceInfo.adapterId, .id = path.sourceInfo.id }) };
        if (win.DisplayConfigGetDeviceInfo(&source.header) != 0) continue;
        if (std.mem.eql(u16, std.mem.sliceTo(&source.viewGdiDeviceName, 0), device)) {
            return .{ .adapter_id = path.targetInfo.adapterId, .id = path.targetInfo.id };
        }
    }
    return null;
}

test "window display info" {
    const window = try tuft_window.createHidden();
    defer tuft_window.destroy(window);
    try std.testing.expectEqual(72, @sizeOf(win.DISPLAYCONFIG_PATH_INFO));
    try std.testing.expectEqual(104, @sizeOf(win.MONITORINFOEXW));
    const d = of(window);
    try std.testing.expect(d.sdr_white_nits >= 80);
}
