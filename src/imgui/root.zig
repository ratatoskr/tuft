//! Dear ImGui drawn into a game's frames.

const std = @import("std");

pub const c = @import("tuft_imgui_c");
pub const Renderer = @import("Renderer.zig");
pub const Win32 = @import("Win32.zig");
pub const Host = @import("Host.zig");
pub const capture = @import("capture.zig");
pub const AppWindow = @import("AppWindow.zig");
/// Images to draw, in any context.
pub const Texture = @import("Texture.zig");

/// Whether `window` is an outside ImGui window or an app window. Any thread.
pub fn isOurs(_: ?*anyopaque, window: *anyopaque) bool {
    return Win32.isOurs(null, @ptrCast(window)) or AppWindow.ownsWindow(null, @ptrCast(window));
}
pub const input = @import("input.zig");

/// ImGui carries on after.
pub const AssertHandler = *const fn (expr: [*:0]const u8, file: [*:0]const u8, line: c_int) callconv(.c) void;

/// Null means stderr. Any thread.
pub fn setAssertHandler(handler: ?AssertHandler) void {
    tuft_imgui_assert_handler = handler;
}

/// Unwinds anything `func` left unbalanced. False if something had to be.
pub fn guarded(func: *const fn (ctx: ?*anyopaque) callconv(.c) void, ctx: ?*anyopaque) bool {
    return tuft_imgui_guarded(func, ctx);
}

/// C API function by name, not the backends. Also tuft's own extras, see `extras`.
pub fn lookup(name: []const u8) ?*const anyopaque {
    return procs.get(name) orelse extras.get(name);
}

/// Internal ImGui bits tuft_ui can use when the host has them.
const extras = std.StaticStringMap(*const anyopaque).initComptime(.{
    .{ "tuft_imgui_bring_window_to_front", @as(*const anyopaque, @ptrCast(&tuft_imgui_bring_window_to_front)) },
    .{ "tuft_imgui_listen_keys", @as(*const anyopaque, @ptrCast(&listenKeys)) },
});

extern fn tuft_imgui_bring_window_to_front() void;

/// The context whose chord input is waiting for keys.
var listening: @import("tuft_arch").atomic.Value(?*c.ImGuiContext) = .init(null);

fn listenKeys() callconv(.c) void {
    listening.store(c.ImGui_GetCurrentContext(), .release);
}

/// Whether a chord input in the current context wanted keys since the last call. Clears it.
pub fn takeListening() bool {
    const context = c.ImGui_GetCurrentContext() orelse return false;
    return listening.cmpxchgStrong(context, null, .acq_rel, .acquire) == null;
}

const procs = blk: {
    @setEvalBranchQuota(2_000_000);
    var entries: []const struct { []const u8, *const anyopaque } = &.{};
    for (std.meta.declarations(c)) |name| {
        if (!std.mem.startsWith(u8, name, "Im")) continue;
        const T = @TypeOf(@field(c, name));
        if (@typeInfo(T) != .@"fn") continue;
        // Translated macros are Zig inline functions, skip them
        const cc = @typeInfo(T).@"fn".attrs.@"callconv";
        if (std.meta.activeTag(cc) != std.meta.activeTag(std.builtin.CallingConvention.c)) continue;
        entries = entries ++ .{.{ name, @as(*const anyopaque, @ptrCast(&@field(c, name))) }};
    }
    break :blk std.StaticStringMap(*const anyopaque).initComptime(entries);
};

/// Resets every window's saved layout. Call between windows, not while drawing one.
pub fn resetLayout() void {
    tuft_imgui_reset_layout();
}

/// Dock layout in code. Do it before the frame submits the dockspace.
pub const dock = struct {
    pub const Dir = enum(c_int) { left = 0, right = 1, up = 2, down = 3 };

    pub fn exists(id: c.ImGuiID) bool {
        return tuft_imgui_dock_exists(id);
    }

    pub fn reset(id: c.ImGuiID, size: [2]f32) void {
        tuft_imgui_dock_reset(id, size[0], size[1]);
    }

    /// Returns the split off part, `node` becomes the rest.
    pub fn split(node: *c.ImGuiID, dir: Dir, ratio: f32) c.ImGuiID {
        var rest: c.ImGuiID = 0;
        const out = tuft_imgui_dock_split(node.*, @backingInt(dir), ratio, &rest);
        node.* = rest;
        return out;
    }

    /// `name` includes its `##` part.
    pub fn window(name: [:0]const u8, node: c.ImGuiID) void {
        tuft_imgui_dock_window(name.ptr, node);
    }

    pub fn finish(id: c.ImGuiID) void {
        tuft_imgui_dock_finish(id);
    }

    /// Where the window is or was last docked. The node might be gone.
    pub fn of(name: [:0]const u8) ?c.ImGuiID {
        const id = tuft_imgui_dock_of(name.ptr);
        return if (id == 0) null else id;
    }

    /// Dockspace `id`'s central node.
    pub fn central(id: c.ImGuiID) ?c.ImGuiID {
        const node = tuft_imgui_dock_central(id);
        return if (node == 0) null else node;
    }

    /// From the next frame, without focusing it. New windows do it themselves on their first frame.
    pub fn bringToFront(name: [:0]const u8) void {
        tuft_imgui_dock_bring_to_front(name.ptr);
    }

    pub fn inFront(name: [:0]const u8) bool {
        return tuft_imgui_dock_in_front(name.ptr);
    }
};

extern fn tuft_imgui_dock_bring_to_front(name: [*:0]const u8) void;

extern fn tuft_imgui_dock_in_front(name: [*:0]const u8) bool;

extern fn tuft_imgui_dock_of(name: [*:0]const u8) c.ImGuiID;
extern fn tuft_imgui_dock_central(id: c.ImGuiID) c.ImGuiID;

pub const FontOptions = struct {
    /// Leaves U+E000 to U+F8FF to a font merged in later, like icons. Some text fonts put their own
    /// glyphs there, and the first font with a glyph wins.
    skip_private_use: bool = false,
};

/// ImGui doesn't copy `data`, so it must outlive the context. Null if it isn't a font.
pub fn addFont(data: []const u8, size: f32, name: [:0]const u8, options: FontOptions) ?*c.ImFont {
    return tuft_imgui_add_font(data.ptr, @intCast(data.len), size, name.ptr, options.skip_private_use);
}

pub const MergeOptions = struct {
    /// Pixels to move its glyphs down, so icons line up with the text they're merged into.
    offset_y: f32 = 0,
};

/// Adds `data`'s glyphs to `into`, where it has none of its own, like an icon font. Same lifetime
/// as `addFont`.
pub fn mergeFont(data: []const u8, size: f32, into: *c.ImFont, name: [:0]const u8, options: MergeOptions) bool {
    return tuft_imgui_merge_font(data.ptr, @intCast(data.len), size, into, name.ptr, options.offset_y);
}

extern fn tuft_imgui_merge_font(data: [*]const u8, len: c_int, size: f32, into: *c.ImFont, name: [*:0]const u8, offset_y: f32) bool;

extern fn tuft_imgui_add_font(data: [*]const u8, len: c_int, size: f32, name: [*:0]const u8, skip_private_use: bool) ?*c.ImFont;
extern fn tuft_imgui_dock_exists(id: c.ImGuiID) bool;
extern fn tuft_imgui_dock_reset(id: c.ImGuiID, width: f32, height: f32) void;
extern fn tuft_imgui_dock_split(node: c.ImGuiID, dir: c_int, ratio: f32, rest: *c.ImGuiID) c.ImGuiID;
extern fn tuft_imgui_dock_window(name: [*:0]const u8, node: c.ImGuiID) void;
extern fn tuft_imgui_dock_finish(id: c.ImGuiID) void;

/// No-GPU backend for tests. Call `textures` after each `ImGui_NewFrame`.
pub const headless = struct {
    pub fn init() void {
        tuft_imgui_headless_init();
    }

    pub fn textures() void {
        tuft_imgui_headless_textures();
    }
};

// shim.cpp
extern var tuft_imgui_assert_handler: ?AssertHandler;
extern fn tuft_imgui_guarded(func: *const fn (ctx: ?*anyopaque) callconv(.c) void, ctx: ?*anyopaque) bool;
extern fn tuft_imgui_reset_layout() void;
extern fn tuft_imgui_headless_init() void;
extern fn tuft_imgui_headless_textures() void;

const tests = struct {
    const testing = std.testing;

    fn leaky(_: ?*anyopaque) callconv(.c) void {
        _ = c.ImGui_Begin(@ptrCast("leaky"), null, 0);
    }

    fn tidy(_: ?*anyopaque) callconv(.c) void {
        _ = c.ImGui_Begin(@ptrCast("tidy"), null, 0);
        c.ImGui_End();
    }

    test "headless frame and guarded unwind" {
        const context = c.ImGui_CreateContext(null) orelse return error.CreateContextFailed;
        defer c.ImGui_DestroyContext(context);
        const io = c.ImGui_GetIO();
        io.*.IniFilename = null;
        io.*.DisplaySize = .{ .x = 640, .y = 480 };
        io.*.DeltaTime = 1.0 / 60.0;
        io.*.ConfigErrorRecoveryEnableAssert = false;
        headless.init();

        c.ImGui_NewFrame();
        headless.textures();
        try testing.expect(!guarded(leaky, null));
        try testing.expect(guarded(tidy, null));
        c.ImGui_Render();
        try testing.expect(c.ImGui_GetDrawData().*.Valid);
    }

    test "reset layout" {
        const context = c.ImGui_CreateContext(null) orelse return error.CreateContextFailed;
        defer c.ImGui_DestroyContext(context);
        const io = c.ImGui_GetIO();
        io.*.IniFilename = null;
        io.*.DisplaySize = .{ .x = 640, .y = 480 };
        io.*.DeltaTime = 1.0 / 60.0;
        headless.init();

        const Frame = struct {
            fn run(moved: bool) [2]c.ImVec2 {
                c.ImGui_NewFrame();
                headless.textures();
                if (moved) {
                    c.ImGui_SetNextWindowPos(.{ .x = 300, .y = 200 }, c.ImGuiCond_Always);
                    c.ImGui_SetNextWindowSize(.{ .x = 100, .y = 80 }, c.ImGuiCond_Always);
                    c.ImGui_SetNextWindowCollapsed(true, c.ImGuiCond_Always);
                }
                c.ImGui_SetNextWindowSize(.{ .x = 200, .y = 150 }, c.ImGuiCond_FirstUseEver);
                _ = c.ImGui_Begin(@ptrCast("layout"), null, 0);
                const at: [2]c.ImVec2 = .{ c.ImGui_GetWindowPos(), c.ImGui_GetWindowSize() };
                c.ImGui_End();
                c.ImGui_Render();
                return at;
            }
        };
        const fresh = Frame.run(false);
        _ = Frame.run(true);
        try testing.expectEqual(300, Frame.run(false)[0].x);

        resetLayout();
        _ = Frame.run(false);
        const reset = Frame.run(false);
        try testing.expectEqual(fresh[0], reset[0]);
        try testing.expectEqual(fresh[1], reset[1]);
    }

    test "lookup skips backends" {
        try testing.expectEqual(@as(*const anyopaque, @ptrCast(&c.ImGui_Begin)), lookup("ImGui_Begin").?);
        try testing.expect(lookup("ImGuiIO_AddKeyEvent") != null);
        try testing.expect(lookup("ImDrawList_AddLine") != null);
        try testing.expectEqual(null, lookup("cImGui_ImplDX11_Init"));
        try testing.expectEqual(null, lookup("ImGui_NoSuchThing"));
        try testing.expect(lookup("tuft_imgui_bring_window_to_front") != null);
    }
};

test {
    _ = tests;
    _ = @import("tests.zig");
    _ = @import("renderer/hdr.zig");
    _ = input;
    std.testing.refAllDecls(Win32);
    std.testing.refAllDecls(Host);
    _ = capture;
    _ = AppWindow;
    _ = Texture;
    std.testing.refAllDecls(Renderer);
    inline for (.{ Renderer.D3d9, Renderer.D3d10, Renderer.D3d11, Renderer.D3d12, Renderer.OpenGl, Renderer.Vulkan }) |Backend| {
        std.testing.refAllDecls(Backend);
    }
}
