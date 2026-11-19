//! Converts ImGui's colors to the game window's HDR space at Windows' SDR white.

const std = @import("std");

const gfx = @import("tuft_gfx");
const sys = @import("tuft_sys");

const c = @import("../root.zig").c;

/// How often we recheck the display's SDR white while drawing HDR.
const recheck_ns = 2 * std.time.ns_per_s;

pub const Output = struct {
    color_space: gfx.ColorSpace = .srgb,
    sdr_white_nits: f32 = gfx.display.default_sdr_white_nits,
    applied: bool = false,
    checked_ns: u64 = 0,

    /// True if it changed and the shaders need remaking.
    pub fn update(self: *Output, frame: *const gfx.Frame) bool {
        const color_space = frame.color_space;
        var white = self.sdr_white_nits;
        if (color_space != .srgb) {
            const now = sys.clock.nanos();
            if (!self.applied or color_space != self.color_space or now -% self.checked_ns >= recheck_ns) {
                white = gfx.display.of(@ptrCast(frame.window)).sdr_white_nits;
                self.checked_ns = now;
            }
        }
        if (self.applied and color_space == self.color_space and white == self.sdr_white_nits) return false;
        self.applied = true;
        self.color_space = color_space;
        self.sdr_white_nits = white;
        return true;
    }

    /// The shaders' `TUFT_MODE`.
    pub fn mode(self: *const Output) c_int {
        return switch (self.color_space) {
            .scrgb => 1,
            .hdr10 => 2,
            else => 0,
        };
    }

    pub fn applyD3d(self: *const Output) void {
        tuft_imgui_hdr_set(self.mode(), self.sdr_white_nits);
    }
};

/// Goes on the main viewport's background list, which draws first. Call after `ImGui_NewFrame`.
pub fn drawFirst(callback: c.ImDrawCallback, user_data: ?*anyopaque) void {
    c.ImDrawList_AddCallbackEx(c.ImGui_GetBackgroundDrawListEx(c.ImGui_GetMainViewport()), callback, user_data, 0);
}

pub const d3d10_callback = tuft_imgui_hdr_dx10_callback;
pub const d3d11_callback = tuft_imgui_hdr_dx11_callback;
pub const d3d12_callback = tuft_imgui_hdr_dx12_callback;

extern fn tuft_imgui_hdr_set(mode: c_int, sdr_white_nits: f32) void;
/// Call before the device goes away.
pub extern fn tuft_imgui_hdr_release() void;
extern fn tuft_imgui_hdr_dx10_callback([*c]const c.ImDrawList, [*c]const c.ImDrawCmd) callconv(.c) void;
extern fn tuft_imgui_hdr_dx11_callback([*c]const c.ImDrawList, [*c]const c.ImDrawCmd) callconv(.c) void;
extern fn tuft_imgui_hdr_dx12_callback([*c]const c.ImDrawList, [*c]const c.ImDrawCmd) callconv(.c) void;

/// `TUFT_MODE` and `TUFT_SDR_WHITE` are specialization constants 0 and 1.
pub const vulkan_vert = spirv(@embedFile("hdr.vert.spv"));
pub const vulkan_frag = spirv(@embedFile("hdr.frag.spv"));

fn spirv(comptime bytes: []const u8) [bytes.len / 4]u32 {
    @setEvalBranchQuota(bytes.len * 4);
    var words: [bytes.len / 4]u32 = undefined;
    for (&words, 0..) |*w, i| w.* = std.mem.readInt(u32, bytes[i * 4 ..][0..4], .little);
    return words;
}

test "Vulkan shaders are SPIR-V" {
    try std.testing.expectEqual(0x07230203, vulkan_vert[0]);
    try std.testing.expectEqual(0x07230203, vulkan_frag[0]);
}
