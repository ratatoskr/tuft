//! Starts a game's Mono or IL2CPP in this process without the game, to read its C# outside it. Only
//! the runtime starts, so nothing that needs the engine works, but reflection and plain C# do. Can't
//! be undone, and only one runtime fits in a process. Games with Denuvo kill the process.

const std = @import("std");
const sys = @import("tuft_sys");
const managed = @import("root.zig");

const Runtime = managed.Runtime;

pub const Started = struct {
    rt: Runtime,
    /// The runtime's DLL
    base: usize,
};

pub const Error = error{ NoDataFolder, LoadFailed, MissingExport, NotStarted, OutOfMemory } || std.Io.Dir.OpenError || std.Io.Dir.Iterator.Error;

/// `game` is the folder with the exe and `<Game>_Data` in.
pub fn start(a: std.mem.Allocator, io: std.Io, kind: managed.Kind, game: []const u8, missing: ?*[]const u8) Error!Started {
    const data = try dataDir(a, io, game);
    defer a.free(data);
    return switch (kind) {
        .mono => startMono(a, io, game, data, missing),
        .il2cpp => startIl2Cpp(a, data, game, missing),
    };
}

/// `<Game>_Data`, the folder with Managed or il2cpp_data in.
fn dataDir(a: std.mem.Allocator, io: std.Io, game: []const u8) Error![]u8 {
    var dir = try std.Io.Dir.openDirAbsolute(io, game, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        if (e.kind == .directory and std.mem.endsWith(u8, e.name, "_Data")) return std.fs.path.join(a, &.{ game, e.name });
    }
    return error.NoDataFolder;
}

fn startMono(a: std.mem.Allocator, io: std.Io, game: []const u8, data: []const u8, missing: ?*[]const u8) Error!Started {
    const dll = try std.fs.path.join(a, &.{ game, "MonoBleedingEdge", "EmbedRuntime", "mono-2.0-bdwgc.dll" });
    defer a.free(dll);
    const base = sys.module.loadBeside(a, dll) catch return error.LoadFailed;
    const managed_dir = try std.fs.path.joinZ(a, &.{ data, "Managed" });
    defer a.free(managed_dir);
    const etc = try std.fs.path.joinZ(a, &.{ game, "MonoBleedingEdge", "etc" });
    defer a.free(etc);

    const set_dirs = try fnOf(base, "mono_set_dirs", fn ([*:0]const u8, [*:0]const u8) callconv(.c) void, missing);
    const set_path = try fnOf(base, "mono_set_assemblies_path", fn ([*:0]const u8) callconv(.c) void, missing);
    const jit_init = try fnOf(base, "mono_jit_init_version", fn ([*:0]const u8, [*:0]const u8) callconv(.c) ?*managed.Domain, missing);
    const open = try fnOf(base, "mono_domain_assembly_open", fn (*managed.Domain, [*:0]const u8) callconv(.c) ?*managed.Assembly, missing);
    const rt = try Runtime.fromModule(.mono, base, missing);
    set_dirs(managed_dir, etc);
    set_path(managed_dir);
    const domain = jit_init("tuft", "v4.0.30319") orelse return error.NotStarted;

    // IL2CPP has the lot loaded from the start, so load them all here too
    var dir = try std.Io.Dir.openDirAbsolute(io, managed_dir, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |e| {
        if (e.kind != .file or !std.ascii.endsWithIgnoreCase(e.name, ".dll")) continue;
        const path = try std.fs.path.joinZ(a, &.{ managed_dir, e.name });
        defer a.free(path);
        _ = open(domain, path);
    }
    return .{ .rt = rt, .base = base };
}

fn startIl2Cpp(a: std.mem.Allocator, data: []const u8, game: []const u8, missing: ?*[]const u8) Error!Started {
    const dll = try std.fs.path.join(a, &.{ game, "GameAssembly.dll" });
    defer a.free(dll);
    const base = sys.module.loadBeside(a, dll) catch return error.LoadFailed;
    const il2cpp_data = try std.fs.path.joinZ(a, &.{ data, "il2cpp_data" });
    defer a.free(il2cpp_data);

    const set_data_dir = try fnOf(base, "il2cpp_set_data_dir", fn ([*:0]const u8) callconv(.c) void, missing);
    const init = try fnOf(base, "il2cpp_init", fn ([*:0]const u8) callconv(.c) c_int, missing);
    const rt = try Runtime.fromModule(.il2cpp, base, missing);
    set_data_dir(il2cpp_data);
    if (init("IL2CPP Root Domain") == 0) return error.NotStarted;
    return .{ .rt = rt, .base = base };
}

fn fnOf(base: usize, comptime name: []const u8, comptime F: type, missing: ?*[]const u8) error{MissingExport}!*const F {
    const at = sys.module.findExport(base, name) orelse {
        if (missing) |m| m.* = name;
        return error.MissingExport;
    };
    return @ptrFromInt(at);
}
