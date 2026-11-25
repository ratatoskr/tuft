const std = @import("std");
const salamander_build = @import("salamander");

const Import = std.Build.Module.Import;

/// Where the built helper `tuft_managed` loads into a game's CoreCLR is kept, one per pointer size.
/// Built from `src/managed/coreclr` and the C# salamander makes from `reflect.sal`, by `zig build
/// coreclr`, so nothing else building tuft needs the dotnet SDK.
const helper_dir = "src/managed/coreclr/bin";

/// `zig build coreclr` writes the helpers into `helper_dir`, and `coreclr-check` fails if they're
/// not what it would write. Both need the dotnet SDK, found only when they run.
fn coreclrSteps(b: *std.Build, salamander: *std.Build.Dependency) void {
    const dotnet = b.findProgramLazy(.{ .names = &.{"dotnet"} });
    const update = b.addUpdateSourceFiles();
    b.step("coreclr", "Build the C# helper for reading games' CoreCLR into " ++ helper_dir ++ ", with the dotnet SDK").dependOn(&update.step);
    const check = b.step("coreclr-check", "Fail if the C# helper in " ++ helper_dir ++ " isn't what zig build coreclr would make");
    const same = b.addExecutable(.{
        .name = "same-file",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/managed/coreclr/same.zig"), .target = b.graph.host, .optimize = .ReleaseSafe }),
    });
    // One at a time, since two builds of one project at once can trip over each other
    var previous: ?*std.Build.Step = null;
    inline for (.{ .{ .x86_64, "64" }, .{ .x86, "32" } }) |bits| {
        // Only the pointer size changes the C#, so any target with it will do
        const target = b.resolveTargetQuery(.{ .cpu_arch = bits[0], .os_tag = .windows });
        const cs = salamander_build.csFiles(salamander, .{ .source = b.path("src/managed/coreclr/reflect.sal"), .target = target, .name = "Reflect.cs", .namespace = "Tuft.CoreClr" });
        const run = std.Build.Step.Run.create(b, "dotnet build Tuft.CoreClr (" ++ bits[1] ++ "-bit)");
        run.addFileArg(dotnet);
        run.addArg("build");
        run.addFileArg(b.path("src/managed/coreclr/Helper.csproj"));
        run.addArgs(&.{ "--nologo", "--disable-build-servers", "-v", "quiet", "-clp:ErrorsOnly;NoSummary", "-c", "Release", "-o" });
        const out = run.addOutputDirectoryArg("helper");
        if (previous) |p| run.step.dependOn(p);
        previous = &run.step;
        // Keeps obj out of the source tree
        run.addArg("--artifacts-path");
        _ = run.addOutputDirectoryArg("artifacts");
        run.addPrefixedDirectoryArg("-p:SalamanderDir=", cs);
        run.addFileInput(b.path("src/managed/coreclr/Reflection.cs"));
        run.setEnvironmentVariable("DOTNET_CLI_TELEMETRY_OPTOUT", "1");
        run.setEnvironmentVariable("DOTNET_NOLOGO", "1");
        // dotnet writes its errors to stdout
        run.stdio = .inherit;
        const dll = out.path(b, "Tuft.CoreClr.dll");
        const kept = helper_dir ++ "/Tuft.CoreClr." ++ bits[1] ++ ".dll";
        update.addCopyFileToSource(dll, kept);
        const compare = b.addRunArtifact(same);
        compare.addFileArg(dll);
        compare.addFileArg(b.path(kept));
        check.dependOn(&compare.step);
    }
}

/// Links the `.def` for a proxy DLL into `lib` so exports keep Windows' ordinals.
pub fn addProxyDef(tuft: *std.Build.Dependency, lib: *std.Build.Step.Compile, dll: []const u8) void {
    const arch_dir = if (lib.rootModuleTarget().cpu.arch == .x86) "x86" else "x64";
    lib.root_module.addObjectFile(tuft.path(tuft.builder.fmt("src/proxy/{s}/{s}.def", .{ arch_dir, dll })));
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_step = b.step("test", "Run tests");
    const build_test_step = b.step("build-test", "Build tests without running");

    if (!supported(b, target)) return;

    // The layer under tuft: runtime calls, fibers and owners. The same options as anyone above us
    // passes, so a build shares one.
    const salamander = b.dependency("salamander", .{ .target = target, .optimize = optimize });
    const zydis_t = zydis.cApi(b, target, optimize);

    // Each layer only imports the ones below it
    const test_filters = b.option([]const []const u8, "test-filter", "Only run tests whose names contain this (repeatable)") orelse &.{};
    const ctx: Context = .{ .b = b, .target = target, .optimize = optimize, .test_step = test_step, .build_test_step = build_test_step, .test_filters = test_filters };
    const arch = ctx.addModule("arch", &.{
        .{ .name = "zydis", .module = zydis_t },
        .{ .name = "salamander_dyn", .module = salamander.module("salamander_dyn") },
    });
    const text = ctx.addModule("text", &.{});
    // Plain maths, with nothing under it, so anything can share its types
    const math = ctx.addModule("math", &.{});
    const sys = ctx.addModule("sys", &.{
        .{ .name = "tuft_arch", .module = arch },
    });
    const event = ctx.addModule("event", &.{
        .{ .name = "tuft_arch", .module = arch },
        .{ .name = "tuft_sys", .module = sys },
        .{ .name = "salamander_runtime", .module = salamander.module("salamander_runtime") },
    });
    const asm_mod = ctx.addModule("asm", &.{
        .{ .name = "zydis", .module = zydis_t },
        .{ .name = "tuft_text", .module = text },
    });
    const mem = ctx.addModule("mem", &.{
        .{ .name = "tuft_arch", .module = arch },
        .{ .name = "tuft_sys", .module = sys },
        .{ .name = "tuft_event", .module = event },
        .{ .name = "tuft_text", .module = text },
    });
    const schema = ctx.addModule("schema", &.{
        .{ .name = "tuft_mem", .module = mem },
        .{ .name = "salamander_schema", .module = salamander.module("salamander_schema") },
    });
    // Mono and IL2CPP through the game's own runtime, and CoreCLR through a C# helper carried inside
    coreclrSteps(b, salamander);
    const managed = ctx.addModule("managed", &.{
        .{ .name = "tuft_sys", .module = sys },
        .{ .name = "salamander_clr", .module = salamander.module("salamander_clr") },
        .{ .name = "reflect_schema", .module = salamander_build.zigModule(salamander, .{ .source = b.path("src/managed/coreclr/reflect.sal"), .target = target }) },
    });
    // Off unless pointed at an installed Unity game, since they start its runtime in the test
    const ManagedKind = enum { mono, il2cpp };
    inline for (.{ ManagedKind.mono, ManagedKind.il2cpp }) |kind| {
        const game_options = b.addOptions();
        game_options.addOption([]const u8, "game", b.option([]const u8, @tagName(kind) ++ "-game", "A Unity " ++ @tagName(kind) ++ " game's folder, to test tuft_managed on its runtime") orelse "");
        game_options.addOption(ManagedKind, "kind", kind);
        const game_tests = b.createModule(.{
            .root_source_file = b.path("tests/managed_runtime.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "tuft_managed", .module = managed },
                .{ .name = "tuft_sys", .module = sys },
            },
        });
        game_tests.addOptions("build_options", game_options);
        ctx.addTests("managed_" ++ @tagName(kind), game_tests);
    }
    // Starts a CoreCLR in the test, and reads it with the helper
    ctx.addTests("managed_coreclr", b.createModule(.{
        .root_source_file = b.path("tests/managed_coreclr.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "tuft_managed", .module = managed }},
    }));
    // Needs exec pages from `mem`
    ctx.addTests("arch_exec", b.createModule(.{
        .root_source_file = b.path("tests/arch.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "tuft_arch", .module = arch },
            .{ .name = "tuft_sys", .module = sys },
            .{ .name = "tuft_mem", .module = mem },
        },
    }));
    const hook = ctx.addModule("hook", &.{
        .{ .name = "tuft_arch", .module = arch },
        .{ .name = "tuft_sys", .module = sys },
        .{ .name = "tuft_mem", .module = mem },
        .{ .name = "tuft_event", .module = event },
        .{ .name = "tuft_asm", .module = asm_mod },
        .{ .name = "tuft_text", .module = text },
    });
    const window = ctx.addModule("window", &.{
        .{ .name = "tuft_arch", .module = arch },
        .{ .name = "tuft_sys", .module = sys },
        .{ .name = "tuft_mem", .module = mem },
    });
    const input = ctx.addModule("input", &.{
        .{ .name = "tuft_arch", .module = arch },
        .{ .name = "tuft_sys", .module = sys },
        .{ .name = "tuft_hook", .module = hook },
        .{ .name = "tuft_event", .module = event },
        .{ .name = "tuft_window", .module = window },
    });
    const vfs = ctx.addModule("vfs", &.{
        .{ .name = "tuft_arch", .module = arch },
        .{ .name = "tuft_sys", .module = sys },
        .{ .name = "tuft_hook", .module = hook },
        .{ .name = "tuft_event", .module = event },
    });
    const input_options = b.addOptions();
    // Off by default since they move the real cursor and read the real keyboard
    input_options.addOption(bool, "real_input", b.option(bool, "real-input-tests", "Also run tests that move and clip the real cursor or read the real keyboard state") orelse false);
    input.addOptions("build_options", input_options);
    const inject_mod = ctx.addModule("inject", &.{
        .{ .name = "tuft_sys", .module = sys },
        .{ .name = "tuft_mem", .module = mem },
    });
    const proxy = ctx.addModule("proxy", &.{
        .{ .name = "tuft_sys", .module = sys },
        .{ .name = "tuft_hook", .module = hook },
    });
    const gfx = ctx.addModule("gfx", &.{
        .{ .name = "tuft_arch", .module = arch },
        .{ .name = "tuft_sys", .module = sys },
        .{ .name = "tuft_hook", .module = hook },
        .{ .name = "tuft_window", .module = window },
    });
    // Official Vulkan headers to check tuft_gfx.vulkan's structs against
    const vulkan_headers = b.dependency("vulkan_headers", .{}).path("include");
    b.addNamedLazyPath("vulkan_headers", vulkan_headers);
    const vk_t = b.addTranslateC(.{
        .root_source_file = b.path("tests/vulkan_layout.h"),
        .target = target,
        .optimize = optimize,
    });
    vk_t.addIncludePath(vulkan_headers);
    ctx.addTests("vulkan_layout", b.createModule(.{
        .root_source_file = b.path("tests/vulkan_layout.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "tuft_gfx", .module = gfx },
            .{ .name = "vk", .module = vk_t.createModule() },
        },
    }));

    // `tuft_imgui_c` is just the C API with nothing linked
    const imgui_c = imgui.cApi(b, target, optimize, vulkan_headers);
    b.modules.put(b.graph.arena, "tuft_imgui_c", imgui_c) catch @panic("OOM");
    const ui_mod = ctx.addModule("ui", &.{
        .{ .name = "tuft_imgui_c", .module = imgui_c },
        .{ .name = "tuft_arch", .module = arch },
        .{ .name = "tuft_input", .module = input },
        .{ .name = "tuft_math", .module = math },
    });
    const imgui_mod = ctx.addModule("imgui", &.{
        .{ .name = "tuft_imgui_c", .module = imgui_c },
        .{ .name = "tuft_ui", .module = ui_mod },
        .{ .name = "tuft_input", .module = input },
        .{ .name = "tuft_event", .module = event },
        .{ .name = "tuft_sys", .module = sys },
        .{ .name = "tuft_arch", .module = arch },
        // Tests only
        .{ .name = "tuft_hook", .module = hook },
        .{ .name = "tuft_window", .module = window },
        .{ .name = "tuft_gfx", .module = gfx },
    });
    imgui_mod.linkLibrary(imgui.library(b, target, optimize, vulkan_headers));

    // Plain CPU work on libc, so plugins can have it without ImGui
    const image_mod = ctx.addModule("image", &.{});
    image_mod.addIncludePath(b.dependency("stb", .{}).path(""));
    image_mod.addCSourceFile(.{ .file = b.path("src/image/stb.c"), .flags = &.{"-std=c99"} });

    const devtools = ctx.addModule("devtools", &.{
        .{ .name = "tuft_ui", .module = ui_mod },
        .{ .name = "tuft_asm", .module = asm_mod },
        .{ .name = "tuft_sys", .module = sys },
        .{ .name = "tuft_mem", .module = mem },
        .{ .name = "tuft_schema", .module = schema },
        .{ .name = "salamander_schema", .module = salamander.module("salamander_schema") },
        .{ .name = "tuft_text", .module = text },
        .{ .name = "tuft_input", .module = input },
    });
    // Separate module so tuft_ui and tuft_devtools never link ImGui
    ctx.addTests("ui_frames", b.createModule(.{
        .root_source_file = b.path("tests/ui.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "tuft_ui", .module = ui_mod },
            .{ .name = "tuft_devtools", .module = devtools },
            .{ .name = "tuft_mem", .module = mem },
            .{ .name = "tuft_schema", .module = schema },
            .{ .name = "salamander_schema", .module = salamander.module("salamander_schema") },
            .{ .name = "tuft_imgui", .module = imgui_mod },
            .{ .name = "tuft_input", .module = input },
        },
    }));

    _ = b.addModule("tuft", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "tuft_arch", .module = arch },
            .{ .name = "tuft_asm", .module = asm_mod },
            .{ .name = "tuft_sys", .module = sys },
            .{ .name = "tuft_mem", .module = mem },
            .{ .name = "tuft_schema", .module = schema },
            .{ .name = "salamander_schema", .module = salamander.module("salamander_schema") },
            .{ .name = "tuft_managed", .module = managed },
            .{ .name = "tuft_hook", .module = hook },
            .{ .name = "tuft_event", .module = event },
            .{ .name = "tuft_input", .module = input },
            .{ .name = "tuft_vfs", .module = vfs },
            .{ .name = "tuft_window", .module = window },
            .{ .name = "tuft_inject", .module = inject_mod },
            .{ .name = "tuft_proxy", .module = proxy },
            .{ .name = "tuft_gfx", .module = gfx },
            .{ .name = "tuft_ui", .module = ui_mod },
            .{ .name = "tuft_devtools", .module = devtools },
            .{ .name = "tuft_text", .module = text },
            .{ .name = "tuft_math", .module = math },
        },
    });

    // Injection test. Builds x86 and x64 targets and payloads, then really injects
    const inject_options = b.addOptions();
    for ([_]struct { opt: []const u8, triple: []const u8 }{
        .{ .opt = "x86", .triple = "x86-windows-gnu" },
        .{ .opt = "x64", .triple = "x86_64-windows-gnu" },
    }) |f| {
        const fixture_target = b.resolveTargetQuery(std.Target.Query.parse(.{ .arch_os_abi = f.triple }) catch unreachable);
        const target_exe = b.addExecutable(.{
            .name = b.fmt("tuft_inject_target_{s}", .{f.opt}),
            .root_module = b.createModule(.{ .root_source_file = b.path("tests/inject_target.zig"), .target = fixture_target, .optimize = .ReleaseSafe }),
        });
        const payload_dll = b.addLibrary(.{
            .name = b.fmt("tuft_inject_payload_{s}", .{f.opt}),
            .linkage = .dynamic,
            .root_module = b.createModule(.{ .root_source_file = b.path("tests/inject_payload.zig"), .target = fixture_target, .optimize = .ReleaseSafe }),
        });
        inject_options.addOptionPath(b.fmt("target_{s}", .{f.opt}), target_exe.getEmittedBin());
        inject_options.addOptionPath(b.fmt("payload_{s}", .{f.opt}), payload_dll.getEmittedBin());
    }
    const inject_test_mod = b.createModule(.{
        .root_source_file = b.path("tests/inject.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "tuft_inject", .module = inject_mod }},
    });
    inject_test_mod.addOptions("build_options", inject_options);
    ctx.addTests("inject_e2e", inject_test_mod);

    // Must match exactly or unsupported targets get "no module named"
    if (b.modules.count() != module_names.len) @panic("update module_names in build.zig");
    for (module_names) |name| {
        if (!b.modules.contains(name)) @panic("update module_names in build.zig");
    }
}

/// Zydis and Zycore from source, all features on like CMake's defaults.
const zydis = struct {
    const defines: []const []const u8 = &.{ "-DZYDIS_STATIC_BUILD", "-DZYCORE_STATIC_BUILD" };

    fn cApi(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
        const zydis_dep = b.dependency("zydis", .{});
        const zycore_dep = b.dependency("zycore", .{});

        // Zig's translate-c overflows on Zydis' static asserts. The C build still checks them.
        const header = b.addWriteFiles().add("zydis_api.h",
            \\#include <Zycore/Defines.h>
            \\#undef ZYAN_STATIC_ASSERT
            \\#define ZYAN_STATIC_ASSERT(x) _Static_assert(1, "")
            \\#include <Zydis/Zydis.h>
            \\
        );
        const t = b.addTranslateC(.{
            .root_source_file = header,
            .target = target,
            .optimize = optimize,
        });
        t.addIncludePath(zydis_dep.path("include"));
        t.addIncludePath(zycore_dep.path("include"));
        t.defineCMacro("ZYDIS_STATIC_BUILD", null);
        t.defineCMacro("ZYCORE_STATIC_BUILD", null);
        const mod = t.createModule();
        mod.linkLibrary(library(b, zydis_dep, zycore_dep, target, optimize));
        return mod;
    }

    fn library(b: *std.Build, zydis_dep: *std.Build.Dependency, zycore_dep: *std.Build.Dependency, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
        const lib = b.addLibrary(.{
            .name = "zydis",
            .linkage = .static,
            .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
        });
        for ([_]std.Build.LazyPath{
            zydis_dep.path("include"),
            zydis_dep.path("src"),
            zycore_dep.path("include"),
        }) |dir| lib.root_module.addIncludePath(dir);
        lib.root_module.addCSourceFiles(.{
            .root = zycore_dep.path("src"),
            .files = &.{ "API/Memory.c", "API/Process.c", "API/Synchronization.c", "API/Terminal.c", "API/Thread.c", "Allocator.c", "ArgParse.c", "Bitset.c", "Format.c", "List.c", "String.c", "Vector.c", "Zycore.c" },
            .flags = defines,
        });
        lib.root_module.addCSourceFiles(.{
            .root = zydis_dep.path("src"),
            .files = &.{ "MetaInfo.c", "Mnemonic.c", "Register.c", "SharedData.c", "String.c", "Utils.c", "Zydis.c", "Decoder.c", "DecoderData.c", "Encoder.c", "EncoderData.c", "Disassembler.c", "Formatter.c", "FormatterBuffer.c", "FormatterATT.c", "FormatterBase.c", "FormatterIntel.c", "Segment.c" },
            .flags = defines,
        });
        return lib;
    }
};

/// Dear ImGui plus dear_bindings' C API. Vulkan is loaded via tuft_gfx, not linked.
const imgui = struct {
    // No UBSan alignment checks since `IID_PPV_ARGS` casts garbage out-pointers
    const flags: []const []const u8 = &.{ "-std=c++17", "-DIMGUI_USER_CONFIG=\"tuft_imconfig.h\"", "-fno-sanitize=alignment" };

    fn library(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, vulkan_headers: std.Build.LazyPath) *std.Build.Step.Compile {
        const src = b.dependency("imgui", .{});
        const bindings = b.dependency("dear_bindings", .{});
        const lib = b.addLibrary(.{
            .name = "imgui",
            .linkage = .static,
            // Zig's libc++ doesn't build for the MSVC ABI
            .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libcpp = target.result.abi != .msvc, .link_libc = true }),
        });
        // Full path so the cache tracks it
        const lazy_flags = std.mem.concat(b.allocator, []const u8, &.{ flags, &.{ "-include", b.root.joinString(b.allocator, "src/imgui/lazy_imports.h") catch @panic("OOM") } }) catch @panic("OOM");
        for ([_]std.Build.LazyPath{
            src.path(""),
            src.path("backends"),
            bindings.path(""),
            bindings.path("backends"),
            b.path("src/imgui"),
            vulkan_headers,
        }) |dir| lib.root_module.addIncludePath(dir);
        lib.root_module.addCSourceFiles(.{
            .root = src.path(""),
            .files = &.{ "imgui.cpp", "imgui_draw.cpp", "imgui_tables.cpp", "imgui_widgets.cpp", "imgui_demo.cpp", "backends/imgui_impl_dx9.cpp", "backends/imgui_impl_vulkan.cpp" },
            .flags = flags,
        });
        // These load Direct3D, OpenGL and DWM on first use instead of importing
        lib.root_module.addCSourceFiles(.{
            .root = src.path(""),
            .files = &.{ "backends/imgui_impl_dx10.cpp", "backends/imgui_impl_dx11.cpp", "backends/imgui_impl_dx12.cpp", "backends/imgui_impl_opengl2.cpp", "backends/imgui_impl_win32.cpp" },
            .flags = lazy_flags,
        });
        lib.root_module.addCSourceFiles(.{ .root = bindings.path(""), .files = &.{ "dcimgui.cpp", "backends/dcimgui_impl_dx11.cpp", "backends/dcimgui_impl_dx10.cpp", "backends/dcimgui_impl_dx12.cpp", "backends/dcimgui_impl_dx9.cpp", "backends/dcimgui_impl_opengl2.cpp", "backends/dcimgui_impl_vulkan.cpp", "backends/dcimgui_impl_win32.cpp" }, .flags = flags });
        lib.root_module.addCSourceFiles(.{ .root = b.path("src/imgui"), .files = &.{"shim.cpp"}, .flags = flags });
        lib.root_module.addCSourceFiles(.{ .root = b.path("src/imgui"), .files = &.{"hdr.cpp"}, .flags = lazy_flags });
        // The sequencer casts a -FLT_MAX mouse pos to int, which UBSan would panic on
        const guizmo = b.dependency("imguizmo", .{});
        const guizmo_flags = std.mem.concat(b.allocator, []const u8, &.{ flags, &.{"-fno-sanitize=float-cast-overflow"} }) catch @panic("OOM");
        lib.root_module.addIncludePath(guizmo.path("src"));
        lib.root_module.addCSourceFiles(.{ .root = guizmo.path("src"), .files = &.{ "ImGuizmo.cpp", "ImSequencer.cpp", "GraphEditor.cpp", "ImVectorEditor.cpp" }, .flags = guizmo_flags });
        lib.root_module.addCSourceFiles(.{ .root = b.path("src/imgui"), .files = &.{"guizmo.cpp"}, .flags = flags });
        const implot = b.dependency("implot", .{});
        lib.root_module.addIncludePath(implot.path(""));
        lib.root_module.addCSourceFiles(.{ .root = implot.path(""), .files = &.{ "implot.cpp", "implot_items.cpp", "implot_demo.cpp" }, .flags = flags });
        lib.root_module.addCSourceFiles(.{ .root = b.path("src/imgui"), .files = &.{"plot.cpp"}, .flags = flags });
        // No graphics DLLs, importing them would load them into every game
        for ([_][]const u8{ "user32", "gdi32", "imm32" }) |name| lib.root_module.linkSystemLibrary(name, .{});
        return lib;
    }

    fn cApi(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, vulkan_headers: std.Build.LazyPath) *std.Build.Module {
        const t = b.addTranslateC(.{
            .root_source_file = b.path("src/imgui/c.h"),
            .target = target,
            .optimize = optimize,
        });
        // Goes first. Fake D3D12 headers for the DX12 backend header
        t.addIncludePath(b.path("src/imgui/stubs"));
        t.addIncludePath(b.dependency("imgui", .{}).path(""));
        t.addIncludePath(b.dependency("dear_bindings", .{}).path(""));
        t.addIncludePath(b.dependency("dear_bindings", .{}).path("backends"));
        t.addIncludePath(vulkan_headers);
        return t.createModule();
    }
};

const Context = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    test_step: *std.Build.Step,
    build_test_step: *std.Build.Step,
    test_filters: []const []const u8,

    /// Adds `tuft_<name>` from `src/<name>/root.zig` with its tests.
    fn addModule(self: Context, comptime name: []const u8, imports: []const Import) *std.Build.Module {
        const mod = self.b.addModule("tuft_" ++ name, .{
            .root_source_file = self.b.path("src/" ++ name ++ "/root.zig"),
            .target = self.target,
            .optimize = self.optimize,
            .link_libc = true,
            .imports = imports,
        });
        self.addTests(name, mod);
        return mod;
    }

    fn addTests(self: Context, comptime name: []const u8, mod: *std.Build.Module) void {
        const tests = self.b.addTest(.{ .name = "tuft_" ++ name ++ "_tests", .root_module = mod, .filters = self.test_filters });
        const run_artifact = self.b.addRunArtifact(tests);
        run_artifact.has_side_effects = true;
        self.test_step.dependOn(&run_artifact.step);
        self.build_test_step.dependOn(&self.b.addInstallArtifact(tests, .{}).step);
    }
};

/// If not, steps fail with a reason so `zig build --help` still works.
fn supported(b: *std.Build, target: std.Build.ResolvedTarget) bool {
    const t = target.result;
    const windows = t.os.tag == .windows;
    const x86 = t.cpu.arch == .x86 or t.cpu.arch == .x86_64;
    if (windows and x86) return true;

    const fail = b.addFail(b.fmt("tuft only builds for Windows on x64 or x86, not {s} on {s}", .{ @tagName(t.os.tag), @tagName(t.cpu.arch) }));
    var steps = b.top_level_steps.iterator();
    while (steps.next()) |entry| entry.value_ptr.*.step.dependOn(&fail.step);

    for (module_names) |name| {
        _ = b.addModule(name, .{ .root_source_file = b.path("src/unsupported.zig"), .target = target });
    }
    return false;
}

/// Every exported module, checked in `build`.
const module_names = [_][]const u8{
    "tuft",         "tuft_arch",  "tuft_sys",    "tuft_mem",      "tuft_hook",   "tuft_event",
    "tuft_window",  "tuft_input", "tuft_inject", "tuft_proxy",    "tuft_gfx",    "tuft_imgui",
    "tuft_imgui_c", "tuft_asm",   "tuft_ui",     "tuft_devtools", "tuft_schema", "tuft_text",
    "tuft_image",   "tuft_vfs",   "tuft_math",   "tuft_managed",
};
