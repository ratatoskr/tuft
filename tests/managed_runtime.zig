//! Starts a real game's Mono or IL2CPP in this process, without the game, and reads it. Off unless
//! `-Dmono-game` or `-Dil2cpp-game` points at an installed Unity game's folder.

const std = @import("std");
const managed = @import("tuft_managed");
const sys = @import("tuft_sys");
const options = @import("build_options");

const testing = std.testing;
const Runtime = managed.Runtime;
const kind: managed.Kind = switch (options.kind) {
    .mono => .mono,
    .il2cpp => .il2cpp,
};

test "a real runtime" {
    if (options.game.len == 0) return error.SkipZigTest;
    const a = testing.allocator;
    var missing: []const u8 = "";

    // Loaded but not started, which is how Wraith often finds it
    const dll = try std.fs.path.join(a, &.{ options.game, switch (kind) {
        .mono => "MonoBleedingEdge\\EmbedRuntime\\mono-2.0-bdwgc.dll",
        .il2cpp => "GameAssembly.dll",
    } });
    defer a.free(dll);
    const before = try Runtime.fromModule(kind, try sys.module.loadBeside(a, dll), &missing);
    try testing.expect(!before.started());

    const started = managed.standalone.start(a, testing.io, kind, options.game, &missing) catch |err| {
        std.debug.print("{t} {s}\n", .{ err, missing });
        return err;
    };
    const rt = started.rt;
    try testing.expect(rt.started());
    try testing.expect(before.started());
    _ = rt.attach() orelse return error.NotStarted;

    // mscorlib's in every game, so check the calls on it
    const corlib = (try rt.findImage(a, "mscorlib.dll")) orelse return error.NoCorlib;
    const string = rt.findClass(corlib, "System", "String") orelse return error.NoString;
    try testing.expectEqualStrings("String", rt.className(string));
    try testing.expectEqualStrings("System", rt.classNamespace(string));
    try testing.expect(!rt.isValueType(string));

    const empty = rt.findField(string, "Empty") orelse return error.NoEmpty;
    try testing.expect(rt.isStatic(empty));
    const type_name = try rt.typeName(a, rt.fieldType(empty).?);
    defer a.free(type_name);
    try testing.expectEqualStrings("System.String", type_name);
    try testing.expectEqual(.string, rt.typeKind(rt.fieldType(empty).?));
    var empty_value: ?*managed.String = null;
    try testing.expect(rt.staticValue(empty, @ptrCast(&empty_value)));
    try testing.expectEqual(0, rt.stringChars(empty_value.?).len);
    // Its address holds the same value
    const empty_at = try rt.staticAddress(empty);
    try testing.expectEqual(@intFromPtr(empty_value.?), @as(*const usize, @ptrFromInt(empty_at)).*);

    const concat = findConcat(rt, string) orelse return error.NoConcat;
    try testing.expect(rt.isStaticMethod(concat));
    try testing.expect(rt.methodPointer(concat) != null);

    const hello = rt.newString("Velvet ") orelse return error.NoNewString;
    const crowe = rt.newString("Crowe ✦") orelse return error.NoNewString;
    var exception: ?*managed.Object = null;
    const joined = rt.invoke(concat, null, &.{ @ptrCast(hello), @ptrCast(crowe) }, &exception) orelse return error.InvokeFailed;
    try testing.expectEqual(null, exception);
    try testing.expectEqual(string, rt.objectClass(joined));
    const text = try rt.readString(a, @ptrCast(joined));
    defer a.free(text);
    try testing.expectEqualStrings("Velvet Crowe ✦", text);

    // Unity registers its engine calls like this when it starts, so stand in for it
    const FakeEngine = struct {
        fn getPosition(_: ?*anyopaque, out: *[3]f32) callconv(.c) void {
            out.* = .{ 1, 2, 3 };
        }
    };
    const register = try fnOf(started.base, switch (kind) {
        .mono => "mono_add_internal_call",
        .il2cpp => "il2cpp_add_internal_call",
    }, fn ([*:0]const u8, *const anyopaque) callconv(.c) void);
    register("UnityEngine.Transform::get_position_Injected", &FakeEngine.getPosition);
    const get_position: *const fn (?*anyopaque, *[3]f32) callconv(.c) void = @ptrFromInt((try rt.icall(a, "UnityEngine.Transform", "get_position_Injected")) orelse return error.NoIcall);
    try testing.expectEqual(@intFromPtr(&FakeEngine.getPosition), @intFromPtr(get_position));
    var position: [3]f32 = undefined;
    get_position(null, &position);
    try testing.expectEqual([3]f32{ 1, 2, 3 }, position);
    try testing.expectEqual(null, try rt.icall(a, "UnityEngine.Transform", "get_rotation_Injected"));
    try testing.expectEqual(null, try rt.icall(a, "System.String", "Concat"));
    // Mono finds its own by method too. IL2CPP calls its own directly, so they're not looked up
    if (kind == .mono) {
        const cpus: *const fn () callconv(.c) i32 = @ptrFromInt((try rt.icall(a, "System.Environment", "get_ProcessorCount")) orelse return error.NoIcall);
        try testing.expectEqual(@as(i32, @intCast(try std.Thread.getCpuCount())), cpus());
    }

    // Starting it attached this thread, but not others
    try testing.expect(rt.attachedHere());
    const Elsewhere = struct {
        fn check(r: *const Runtime, out: *bool) void {
            out.* = r.attachedHere();
        }
    };
    var elsewhere = true;
    const other = try std.Thread.spawn(.{}, Elsewhere.check, .{ &rt, &elsewhere });
    other.join();
    try testing.expect(!elsewhere);
    const day = rt.findClass(corlib, "System", "DayOfWeek") orelse return error.NoDayOfWeek;
    try testing.expect(rt.isEnum(day));
    try testing.expect(!rt.isEnum(string));
    try testing.expectEqual(.i4, rt.typeKind(rt.enumBase(day).?));

    const type_object = rt.typeObject(rt.classType(string).?) orelse return error.NoTypeObject;
    try testing.expect(std.mem.endsWith(u8, rt.className(rt.objectClass(type_object).?), "Type"));
    const object_class = rt.findClass(corlib, "System", "Object").?;
    const array = rt.newArray(object_class, 3) orelse return error.NoArray;
    try testing.expectEqual(3, rt.arrayLength(array));
    const items: *const [3]usize = @ptrFromInt(rt.arrayItems(array));
    try testing.expectEqual([3]usize{ 0, 0, 0 }, items.*);

    // Then walk everything loaded, which is where odd types turn up
    const images = try rt.assemblies(a);
    defer a.free(images);
    var classes: usize = 0;
    var fields: usize = 0;
    var methods: usize = 0;
    var pointers: usize = 0;
    for (images) |entry| {
        const image = rt.assemblyImage(entry) orelse continue;
        _ = rt.imageName(image);
        for (0..rt.classCount(image)) |i| {
            const c = rt.classAt(image, i) orelse continue;
            classes += 1;
            _ = rt.className(c);
            _ = rt.classNamespace(c);
            var fs = rt.fields(c);
            while (fs.next()) |f| : (fields += 1) {
                const name = try rt.typeName(a, rt.fieldType(f) orelse continue);
                a.free(name);
                _ = rt.fieldOffset(f);
            }
            var ms = rt.methods(c);
            while (ms.next()) |m| : (methods += 1) {
                _ = rt.methodName(m);
                for (0..rt.paramCount(m)) |p| _ = rt.paramType(m, @intCast(p));
                // Compiling every Mono method would take minutes
                if (kind == .il2cpp and rt.methodPointer(m) != null) pointers += 1;
            }
        }
    }
    std.debug.print("{d} images: {d} classes, {d} fields, {d} methods, {d} with code\n", .{ images.len, classes, fields, methods, pointers });
    try testing.expect(classes > 10);
    try testing.expect(methods > classes);

    // Last, since the runtime's gone after. The game closing waits for every thread its runtime
    // knows, so one of ours that's idle has to have detached
    const Idle = struct {
        fn run(r: *const Runtime, ready: *std.atomic.Value(bool)) void {
            r.detach(r.attach() orelse @panic("can't attach"));
            ready.store(true, .release);
            while (true) sys.thread.sleepMs(1000);
        }
    };
    var ready: std.atomic.Value(bool) = .init(false);
    const idle = try std.Thread.spawn(.{}, Idle.run, .{ &rt, &ready });
    idle.detach();
    while (!ready.load(.acquire)) sys.thread.sleepMs(1);
    // On this thread, which started it, as the game would. If it waits for the idle one, the
    // watchdog fails the test
    const Watchdog = struct {
        fn run(done: *std.atomic.Value(bool)) void {
            var waited: u32 = 0;
            while (!done.load(.acquire)) : (waited += 10) {
                if (waited >= 10_000) {
                    std.debug.print("shut down: false, it's waiting for the idle thread\n", .{});
                    std.process.exit(1);
                }
                sys.thread.sleepMs(10);
            }
        }
    };
    var done: std.atomic.Value(bool) = .init(false);
    const watchdog = try std.Thread.spawn(.{}, Watchdog.run, .{&done});
    watchdog.detach();
    switch (kind) {
        .il2cpp => (try fnOf(started.base, "il2cpp_shutdown", fn () callconv(.c) void))(),
        .mono => {
            const get = try fnOf(started.base, "mono_get_root_domain", fn () callconv(.c) ?*managed.Domain);
            (try fnOf(started.base, "mono_jit_cleanup", fn (?*managed.Domain) callconv(.c) void))(get());
        },
    }
    done.store(true, .release);
    std.debug.print("shut down: true\n", .{});
}

fn findConcat(rt: Runtime, string: *managed.Class) ?*managed.Method {
    var ms = rt.methods(string);
    while (ms.next()) |m| {
        if (!std.mem.eql(u8, rt.methodName(m), "Concat") or rt.paramCount(m) != 2) continue;
        const t = rt.paramType(m, 0) orelse continue;
        if (rt.typeKind(t) == .string) return m;
    }
    return null;
}

fn fnOf(base: usize, name: []const u8, comptime F: type) !*const F {
    return @ptrFromInt(sys.module.findExport(base, name) orelse return error.MissingExport);
}
