//! Reflection over a game's C# runtime: Mono, IL2CPP, and CoreCLR (read-only so far, see `coreclr.zig`).
//! Threads must `attach` before calling in, and check `started` first.

const std = @import("std");
const sys = @import("tuft_sys");
const h = @import("handles.zig");
pub const exports = @import("exports.zig");
pub const Il2Cpp = @import("il2cpp.zig").Il2Cpp;
pub const Mono = @import("mono.zig").Mono;
pub const coreclr = @import("coreclr.zig");
pub const CoreClr = coreclr.CoreClr;
/// For reading a game's C# outside the game, like in tests and tools.
pub const standalone = @import("standalone.zig");

pub const Resolver = exports.Resolver;
pub const Domain = h.Domain;
pub const Assembly = h.Assembly;
pub const Image = h.Image;
pub const Class = h.Class;
pub const Field = h.Field;
pub const Method = h.Method;
pub const Type = h.Type;
pub const Object = h.Object;
pub const String = h.String;
pub const Thread = h.Thread;
pub const ElementType = h.ElementType;

pub const Kind = enum { il2cpp, mono, coreclr };

/// Where Mono and IL2CPP array items start: after the object header, bounds and length. CoreCLR differs.
pub const array_items_offset = 4 * @sizeOf(usize);

/// What each runtime's DLL is usually called.
pub const il2cpp_modules = [_][]const u8{"GameAssembly.dll"};
pub const mono_modules = [_][]const u8{ "mono-2.0-bdwgc.dll", "mono-2.0-sgen.dll", "mono-2.0-boehm.dll", "mono.dll" };
/// CoreCLR's, which `CoreClr.open` joins rather than reading exports.
pub const coreclr_modules = coreclr.modules;

pub const Runtime = union(Kind) {
    il2cpp: Il2Cpp,
    mono: Mono,
    coreclr: CoreClr,

    /// The loaded IL2CPP or Mono runtime, or null. `missing` gets any absent export.
    pub fn find(missing: ?*[]const u8) error{MissingExport}!?Runtime {
        for (il2cpp_modules) |name| if (sys.module.findBase(name)) |base| return try fromModule(.il2cpp, base, missing);
        for (mono_modules) |name| if (sys.module.findBase(name)) |base| return try fromModule(.mono, base, missing);
        return null;
    }

    pub fn fromModule(kind: Kind, base: usize, missing: ?*[]const u8) error{MissingExport}!Runtime {
        return fromResolver(kind, .module(base), missing);
    }

    pub fn fromResolver(kind: Kind, r: Resolver, missing: ?*[]const u8) error{MissingExport}!Runtime {
        return switch (kind) {
            .il2cpp => .{ .il2cpp = try .init(r, missing) },
            .mono => .{ .mono = try .init(r, missing) },
            // Joined, not read from exports
            .coreclr => {
                if (missing) |m| m.* = "CoreCLR, which CoreClr.open joins";
                return error.MissingExport;
            },
        };
    }

    /// True once the runtime and core library are up. Safe from any thread; check before `domain` or `attach`.
    pub fn started(self: *const Runtime) bool {
        return switch (self.*) {
            inline else => |*r| r.started(),
        };
    }

    /// Null till the game's started the runtime. Check `started` first.
    pub fn domain(self: *const Runtime) ?*Domain {
        return switch (self.*) {
            inline else => |*r| r.domain(),
        };
    }

    /// Call on each of our threads before anything else. Null if the runtime hasn't started.
    pub fn attach(self: *const Runtime) ?*Thread {
        return switch (self.*) {
            inline else => |*r| r.attach(),
        };
    }

    /// For threads we own, before they exit. Detach idle ones too: the game waits on attached threads at exit.
    pub fn detach(self: *const Runtime, t: *Thread) void {
        switch (self.*) {
            inline else => |*r| r.detach(t),
        }
    }

    /// Free with `allocator`.
    pub fn assemblies(self: *const Runtime, allocator: std.mem.Allocator) ![]*Assembly {
        return switch (self.*) {
            inline else => |*r| r.assemblies(allocator),
        };
    }

    pub fn assemblyImage(self: *const Runtime, a: *Assembly) ?*Image {
        return switch (self.*) {
            inline else => |*r| r.assemblyImage(a),
        };
    }

    /// Like `Assembly-CSharp.dll`.
    pub fn imageName(self: *const Runtime, i: *Image) []const u8 {
        return span(switch (self.*) {
            inline else => |*r| r.imageName(i),
        });
    }

    /// The loaded image called `name`, with or without `.dll` (Mono omits it).
    pub fn findImage(self: *const Runtime, allocator: std.mem.Allocator, name: []const u8) !?*Image {
        const list = try self.assemblies(allocator);
        defer allocator.free(list);
        for (list) |a| {
            const i = self.assemblyImage(a) orelse continue;
            if (std.ascii.eqlIgnoreCase(withoutDll(self.imageName(i)), withoutDll(name))) return i;
        }
        return null;
    }

    pub fn classCount(self: *const Runtime, i: *Image) usize {
        return switch (self.*) {
            inline else => |*r| r.classCount(i),
        };
    }

    /// Nested classes too. Use `classOuter` to tell.
    pub fn classAt(self: *const Runtime, i: *Image, n: usize) ?*Class {
        return switch (self.*) {
            inline else => |*r| r.classAt(i, n),
        };
    }

    /// `namespace` is empty for none. Nested classes aren't found this way.
    pub fn findClass(self: *const Runtime, i: *Image, namespace: [*:0]const u8, name: [*:0]const u8) ?*Class {
        return switch (self.*) {
            inline else => |*r| r.findClass(i, namespace, name),
        };
    }

    pub fn className(self: *const Runtime, c: *Class) []const u8 {
        return span(switch (self.*) {
            inline else => |*r| r.className(c),
        });
    }

    pub fn classNamespace(self: *const Runtime, c: *Class) []const u8 {
        return span(switch (self.*) {
            inline else => |*r| r.classNamespace(c),
        });
    }

    pub fn classParent(self: *const Runtime, c: *Class) ?*Class {
        return switch (self.*) {
            inline else => |*r| r.classParent(c),
        };
    }

    /// The class it's nested in.
    pub fn classOuter(self: *const Runtime, c: *Class) ?*Class {
        return switch (self.*) {
            inline else => |*r| r.classOuter(c),
        };
    }

    pub fn classImage(self: *const Runtime, c: *Class) ?*Image {
        return switch (self.*) {
            inline else => |*r| r.classImage(c),
        };
    }

    /// Counts the object header, even for value types.
    pub fn instanceSize(self: *const Runtime, c: *Class) i32 {
        return switch (self.*) {
            inline else => |*r| r.instanceSize(c),
        };
    }

    pub fn isValueType(self: *const Runtime, c: *Class) bool {
        return switch (self.*) {
            inline else => |*r| r.isValueType(c),
        };
    }

    pub fn classType(self: *const Runtime, c: *Class) ?*Type {
        return switch (self.*) {
            inline else => |*r| r.classType(c),
        };
    }

    pub fn typeClass(self: *const Runtime, t: *Type) ?*Class {
        return switch (self.*) {
            inline else => |*r| r.typeClass(t),
        };
    }

    /// Its own fields, not its parents'.
    pub fn fields(self: *const Runtime, c: *Class) Fields {
        return .{ .rt = self, .class = c };
    }

    /// Its own methods, not its parents'.
    pub fn methods(self: *const Runtime, c: *Class) Methods {
        return .{ .rt = self, .class = c };
    }

    /// The first called `name`, or with `args` parameters too unless it's -1. Not its parents'.
    pub fn findMethod(self: *const Runtime, c: *Class, name: [*:0]const u8, args: i32) ?*Method {
        return switch (self.*) {
            inline else => |*r| r.findMethod(c, name, args),
        };
    }

    pub fn findField(self: *const Runtime, c: *Class, name: []const u8) ?*Field {
        var it = self.fields(c);
        while (it.next()) |f| if (std.mem.eql(u8, self.fieldName(f), name)) return f;
        return null;
    }

    pub fn fieldName(self: *const Runtime, f: *Field) []const u8 {
        return span(switch (self.*) {
            inline else => |*r| r.fieldName(f),
        });
    }

    /// From the object start, header included even for value types. From static data for statics.
    pub fn fieldOffset(self: *const Runtime, f: *Field) usize {
        return switch (self.*) {
            inline else => |*r| r.fieldOffset(f),
        };
    }

    pub fn fieldType(self: *const Runtime, f: *Field) ?*Type {
        return switch (self.*) {
            inline else => |*r| r.fieldType(f),
        };
    }

    /// ECMA-335 FieldAttributes.
    pub fn fieldFlags(self: *const Runtime, f: *Field) u32 {
        return switch (self.*) {
            inline else => |*r| r.fieldFlags(f),
        };
    }

    pub fn isStatic(self: *const Runtime, f: *Field) bool {
        return self.fieldFlags(f) & h.field_static != 0;
    }

    /// A `const`, with no storage. Read it with `staticValue`.
    pub fn isLiteral(self: *const Runtime, f: *Field) bool {
        return self.fieldFlags(f) & h.field_literal != 0;
    }

    pub fn fieldClass(self: *const Runtime, f: *Field) ?*Class {
        return switch (self.*) {
            inline else => |*r| r.fieldClass(f),
        };
    }

    /// Copies a static field's value into `out`. May run the static constructor. False on failure.
    pub fn staticValue(self: *const Runtime, f: *Field, out: *anyopaque) bool {
        return switch (self.*) {
            inline else => |*r| r.staticValue(f, out),
        };
    }

    /// The class's static field block. May run its static constructor. Null on IL2CPP before ~Unity 2019.
    pub fn staticData(self: *const Runtime, c: *Class) ?usize {
        return switch (self.*) {
            inline else => |*r| r.staticData(c),
        };
    }

    /// Copies an instance field's value into `out`. References come out as the object pointer.
    pub fn fieldValue(self: *const Runtime, o: *Object, f: *Field, out: *anyopaque) void {
        switch (self.*) {
            inline else => |*r| r.fieldValue(o, f, out),
        }
    }

    /// Sets an instance field via the runtime so the GC sees references.
    /// `value` points at the value for value types, and is the object itself for references.
    pub fn setFieldValue(self: *const Runtime, o: *Object, f: *Field, value: ?*anyopaque) void {
        switch (self.*) {
            inline else => |*r| r.setFieldValue(o, f, value),
        }
    }

    pub const StaticError = error{
        /// Or a `const`, which has no storage
        NotStatic,
        /// Each thread has its own, so there's no one address
        ThreadStatic,
        /// The runtime doesn't say where statics are
        Unsupported,
    };

    /// Where a static field is now. May run its class's static constructor.
    pub fn staticAddress(self: *const Runtime, f: *Field) StaticError!usize {
        if (!self.isStatic(f) or self.isLiteral(f)) return error.NotStatic;
        if (self.* == .coreclr) return self.coreclr.staticAddress(f) orelse error.ThreadStatic;
        const offset = self.fieldOffset(f);
        // Both mark thread statics with an offset of -1, Mono's only 32 bits wide
        if (offset == std.math.maxInt(usize) or (self.* == .mono and offset == std.math.maxInt(u32))) return error.ThreadStatic;
        const c = self.fieldClass(f) orelse return error.Unsupported;
        const data = self.staticData(c) orelse return error.Unsupported;
        return data + offset;
    }

    /// Like `System.Collections.Generic.List<System.Int32>`. Free with `allocator`.
    pub fn typeName(self: *const Runtime, allocator: std.mem.Allocator, t: *Type) ![]u8 {
        switch (self.*) {
            inline else => |*r| {
                const name = r.typeNameOwned(t) orelse return allocator.dupe(u8, "");
                defer r.free(name);
                return allocator.dupe(u8, std.mem.span(name));
            },
        }
    }

    pub fn typeKind(self: *const Runtime, t: *Type) ElementType {
        return switch (self.*) {
            inline else => |*r| r.typeKind(t),
        };
    }

    pub fn methodName(self: *const Runtime, m: *Method) []const u8 {
        return span(switch (self.*) {
            inline else => |*r| r.methodName(m),
        });
    }

    pub fn paramCount(self: *const Runtime, m: *Method) u32 {
        return switch (self.*) {
            inline else => |*r| r.paramCount(m),
        };
    }

    pub fn paramType(self: *const Runtime, m: *Method, i: u32) ?*Type {
        return switch (self.*) {
            inline else => |*r| r.paramType(m, i),
        };
    }

    pub fn returnType(self: *const Runtime, m: *Method) ?*Type {
        return switch (self.*) {
            inline else => |*r| r.returnType(m),
        };
    }

    pub fn methodClass(self: *const Runtime, m: *Method) ?*Class {
        return switch (self.*) {
            inline else => |*r| r.methodClass(m),
        };
    }

    /// ECMA-335 MethodAttributes.
    pub fn methodFlags(self: *const Runtime, m: *Method) u32 {
        return switch (self.*) {
            inline else => |*r| r.methodFlags(m),
        };
    }

    pub fn isStaticMethod(self: *const Runtime, m: *Method) bool {
        return self.methodFlags(m) & h.method_static != 0;
    }

    /// Its native code, to hook or call. Mono compiles it if needed. Null if none, like abstract methods.
    pub fn methodPointer(self: *const Runtime, m: *Method) ?usize {
        return switch (self.*) {
            inline else => |*r| r.methodPointer(m),
        };
    }

    pub fn objectClass(self: *const Runtime, o: *Object) ?*Class {
        return switch (self.*) {
            inline else => |*r| r.objectClass(o),
        };
    }

    /// A boxed value type's value.
    pub fn unbox(self: *const Runtime, o: *Object) ?*anyopaque {
        return switch (self.*) {
            inline else => |*r| r.unbox(o),
        };
    }

    /// A zeroed, unconstructed object of `c`: call its `.ctor` next and hold a handle to keep it.
    /// CoreCLR's can move, so construct it at once, or `invoke` a constructor with no `this`.
    pub fn newObject(self: *const Runtime, c: *Class) ?*Object {
        return switch (self.*) {
            inline else => |*r| r.newObject(c),
        };
    }

    /// From UTF-8. GC-owned, so hold a handle to keep it.
    pub fn newString(self: *const Runtime, text: [*:0]const u8) ?*String {
        return switch (self.*) {
            inline else => |*r| r.newString(text),
        };
    }

    pub fn stringChars(self: *const Runtime, s: *String) []const u16 {
        return switch (self.*) {
            inline else => |*r| r.stringChars(s),
        };
    }

    /// As UTF-8, or WTF-8 if it has a lone surrogate. Free with `allocator`.
    pub fn readString(self: *const Runtime, allocator: std.mem.Allocator, s: *String) ![]u8 {
        return std.unicode.wtf16LeToWtf8Alloc(allocator, self.stringChars(s));
    }

    /// Runs the game's C#. `this` is null for statics and the unboxed value for value types.
    /// `args` holds pointers to value-type args and objects as-is. Value results come boxed.
    /// If it throws, `exception` gets it and this returns null.
    pub fn invoke(self: *const Runtime, m: *Method, this: ?*anyopaque, args: ?[*]const ?*anyopaque, exception: ?*?*Object) ?*Object {
        return switch (self.*) {
            inline else => |*r| r.invoke(m, this, args, exception),
        };
    }

    /// Keeps `o` from being collected, and from moving too if `pinned`, till `freeHandle`.
    pub fn newHandle(self: *const Runtime, o: *Object, pinned: bool) u32 {
        return switch (self.*) {
            inline else => |*r| r.newHandle(o, pinned),
        };
    }

    pub fn handleTarget(self: *const Runtime, handle: u32) ?*Object {
        return switch (self.*) {
            inline else => |*r| r.handleTarget(handle),
        };
    }

    pub fn freeHandle(self: *const Runtime, handle: u32) void {
        switch (self.*) {
            inline else => |*r| r.freeHandle(handle),
        }
    }

    /// ECMA-335 MethodImplAttributes.
    pub fn methodImplFlags(self: *const Runtime, m: *Method) u32 {
        return switch (self.*) {
            inline else => |*r| r.methodImplFlags(m),
        };
    }

    /// The native function behind a C# `extern` method, like `Transform.position`, by class full name.
    /// Null if none. Mono logs missing ones to its console.
    pub fn icall(self: *const Runtime, allocator: std.mem.Allocator, class_name: []const u8, method: []const u8) !?usize {
        // IL2CPP finds them by name, usually without the signature
        if (self.* == .il2cpp) {
            var buf: [512]u8 = undefined;
            const name = std.fmt.bufPrintSentinel(&buf, "{s}::{s}", .{ class_name, method }, 0) catch return null;
            if (self.il2cpp.icallNamed(name)) |at| return at;
        }
        const c = try self.findClassAnywhere(allocator, class_name) orelse return null;
        var it = self.methods(c);
        while (it.next()) |m| {
            if (!std.mem.eql(u8, self.methodName(m), method)) continue;
            if (self.methodImplFlags(m) & h.method_internal_call == 0) continue;
            switch (self.*) {
                .coreclr => return null,
                .mono => |*r| return r.icallOf(m),
                .il2cpp => |*r| {
                    // Some are registered with their signature, like `Class::name(System.Int32,UnityEngine.Vector3&)`
                    var buf: [1024]u8 = undefined;
                    var w: std.Io.Writer = .fixed(&buf);
                    w.print("{s}::{s}(", .{ class_name, method }) catch continue;
                    for (0..self.paramCount(m)) |i| {
                        const t = self.paramType(m, @intCast(i)) orelse continue;
                        const type_name = r.typeNameOwned(t) orelse continue;
                        defer r.free(type_name);
                        w.print("{s}{s}", .{ if (i > 0) "," else "", std.mem.span(type_name) }) catch continue;
                    }
                    w.writeAll(")\x00") catch continue;
                    if (r.icallNamed(@ptrCast(w.buffered().ptr))) |at| return at;
                },
            }
        }
        return null;
    }

    /// `Namespace.Name` in whichever image has it. Not nested classes.
    pub fn findClassAnywhere(self: *const Runtime, allocator: std.mem.Allocator, full_name: []const u8) !?*Class {
        const dot = std.mem.lastIndexOfScalar(u8, full_name, '.');
        var ns_buf: [256]u8 = undefined;
        var name_buf: [256]u8 = undefined;
        const ns = std.fmt.bufPrintSentinel(&ns_buf, "{s}", .{if (dot) |d| full_name[0..d] else ""}, 0) catch return null;
        const name = std.fmt.bufPrintSentinel(&name_buf, "{s}", .{if (dot) |d| full_name[d + 1 ..] else full_name}, 0) catch return null;
        const list = try self.assemblies(allocator);
        defer allocator.free(list);
        for (list) |a| {
            const image = self.assemblyImage(a) orelse continue;
            if (self.findClass(image, ns, name)) |c| return c;
        }
        return null;
    }

    /// The `System.Type` for `t`, like `typeof`. The runtime owns it.
    pub fn typeObject(self: *const Runtime, t: *Type) ?*Object {
        return switch (self.*) {
            inline else => |*r| r.typeObject(t),
        };
    }

    /// A zeroed `T[]` of `element`. GC-owned, so hold a handle to keep it.
    pub fn newArray(self: *const Runtime, element: *Class, length: usize) ?*Object {
        return switch (self.*) {
            inline else => |*r| r.newArray(element, length),
        };
    }

    pub fn arrayLength(self: *const Runtime, array: *Object) usize {
        return switch (self.*) {
            inline else => |*r| r.arrayLength(array),
        };
    }

    /// Where an array's items start. They're objects, or values for value types.
    pub fn arrayItems(self: *const Runtime, array: *Object) usize {
        return @intFromPtr(array) + @as(usize, if (self.* == .coreclr) CoreClr.array_items_offset else array_items_offset);
    }

    /// Whether this thread can call in without `attach`, like the game's own threads.
    pub fn attachedHere(self: *const Runtime) bool {
        return switch (self.*) {
            inline else => |*r| r.attachedHere(),
        };
    }

    /// Bumps when earlier lookups may be stale, like after a plugin unload. Only CoreCLR's changes.
    pub fn changes(self: *const Runtime) u32 {
        return switch (self.*) {
            .coreclr => |*r| r.changes(),
            else => 0,
        };
    }

    pub fn isEnum(self: *const Runtime, c: *Class) bool {
        return switch (self.*) {
            inline else => |*r| r.isEnum(c),
        };
    }

    /// The type an enum's values are, like `System.Int32`.
    pub fn enumBase(self: *const Runtime, c: *Class) ?*Type {
        return switch (self.*) {
            inline else => |*r| r.enumBase(c),
        };
    }
};

pub const Fields = struct {
    rt: *const Runtime,
    class: *Class,
    iter: ?*anyopaque = null,

    pub fn next(self: *Fields) ?*Field {
        return switch (self.rt.*) {
            inline else => |*r| r.nextField(self.class, &self.iter),
        };
    }
};

pub const Methods = struct {
    rt: *const Runtime,
    class: *Class,
    iter: ?*anyopaque = null,

    pub fn next(self: *Methods) ?*Method {
        return switch (self.rt.*) {
            inline else => |*r| r.nextMethod(self.class, &self.iter),
        };
    }
};

fn span(name: ?[*:0]const u8) []const u8 {
    return if (name) |n| std.mem.span(n) else "";
}

fn withoutDll(name: []const u8) []const u8 {
    return if (std.ascii.endsWithIgnoreCase(name, ".dll")) name[0 .. name.len - 4] else name;
}

test {
    _ = exports;
}

const testing = std.testing;

/// Hands out fake handles, which are just numbers, since the fakes never look inside them.
fn fakeHandle(comptime T: type, n: usize) *T {
    return @ptrFromInt(n * 16);
}

test "Mono lists classes by type definition row, from 1" {
    const Fake = struct {
        var asked: [3]u32 = undefined;
        var n: usize = 0;
        fn rows(_: *Image, table: c_int) callconv(.c) c_int {
            return if (table == 2) 3 else 0;
        }
        fn get(_: *Image, token: u32) callconv(.c) ?*Class {
            asked[n] = token;
            n += 1;
            return fakeHandle(Class, 1);
        }
    };
    var mono: Mono = .{ .api = undefined };
    mono.api.image_get_table_rows = Fake.rows;
    mono.api.class_get = Fake.get;
    const rt: Runtime = .{ .mono = mono };
    const image = fakeHandle(Image, 1);
    try testing.expectEqual(3, rt.classCount(image));
    for (0..rt.classCount(image)) |i| _ = rt.classAt(image, i);
    try testing.expectEqualSlices(u32, &.{ 0x02000001, 0x02000002, 0x02000003 }, &Fake.asked);
}

test "Mono's assemblies come from its callback" {
    const Fake = struct {
        fn each(func: *const fn (?*anyopaque, ?*anyopaque) callconv(.c) void, ctx: ?*anyopaque) callconv(.c) void {
            for (1..4) |i| func(fakeHandle(Assembly, i), ctx);
        }
    };
    var mono: Mono = .{ .api = undefined };
    mono.api.assembly_foreach = Fake.each;
    const rt: Runtime = .{ .mono = mono };
    const list = try rt.assemblies(testing.allocator);
    defer testing.allocator.free(list);
    try testing.expectEqualSlices(*Assembly, &.{ fakeHandle(Assembly, 1), fakeHandle(Assembly, 2), fakeHandle(Assembly, 3) }, list);
}

test "IL2CPP's method pointer is the first word of the method" {
    var method: [4]usize = .{ 0x1234, 0, 0, 0 };
    const rt: Runtime = .{ .il2cpp = .{ .api = undefined } };
    try testing.expectEqual(0x1234, rt.methodPointer(@ptrCast(&method)));
    method[0] = 0;
    try testing.expectEqual(null, rt.methodPointer(@ptrCast(&method)));
}

test "strings come out as UTF-8" {
    const Fake = struct {
        const text = std.unicode.utf8ToUtf16LeStringLiteral("Velvet Crowe ✦");
        fn chars(_: *String) callconv(.c) ?[*]const u16 {
            return text.ptr;
        }
        fn length(_: *String) callconv(.c) i32 {
            return text.len;
        }
    };
    var il2cpp: Il2Cpp = .{ .api = undefined };
    il2cpp.api.string_chars = Fake.chars;
    il2cpp.api.string_length = Fake.length;
    const rt: Runtime = .{ .il2cpp = il2cpp };
    const s = try rt.readString(testing.allocator, fakeHandle(String, 1));
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("Velvet Crowe ✦", s);
}
