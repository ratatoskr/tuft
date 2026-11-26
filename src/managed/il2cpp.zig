//! IL2CPP, from the `il2cpp_` exports in GameAssembly.dll. The game's C# is compiled to native code
//! there, so every method already has an address.

const std = @import("std");
const h = @import("handles.zig");
const exports = @import("exports.zig");

const Domain = h.Domain;
const Assembly = h.Assembly;
const Image = h.Image;
const Class = h.Class;
const Field = h.Field;
const Method = h.Method;
const Type = h.Type;
const Object = h.Object;
const String = h.String;
const Thread = h.Thread;
const Name = ?[*:0]const u8;
const Iter = *?*anyopaque;

pub const Api = struct {
    get_corlib: *const fn () callconv(.c) ?*Image,
    domain_get: *const fn () callconv(.c) ?*Domain,
    domain_get_assemblies: *const fn (*Domain, *usize) callconv(.c) ?[*]const *Assembly,
    thread_attach: *const fn (*Domain) callconv(.c) ?*Thread,
    thread_detach: *const fn (*Thread) callconv(.c) void,
    assembly_get_image: *const fn (*Assembly) callconv(.c) ?*Image,
    image_get_name: *const fn (*Image) callconv(.c) Name,
    // Since Unity 2018.3
    image_get_class_count: ?*const fn (*Image) callconv(.c) usize,
    image_get_class: ?*const fn (*Image, usize) callconv(.c) ?*Class,
    class_from_name: *const fn (*Image, [*:0]const u8, [*:0]const u8) callconv(.c) ?*Class,
    class_get_name: *const fn (*Class) callconv(.c) Name,
    class_get_namespace: *const fn (*Class) callconv(.c) Name,
    class_get_parent: *const fn (*Class) callconv(.c) ?*Class,
    class_get_declaring_type: *const fn (*Class) callconv(.c) ?*Class,
    class_get_image: *const fn (*Class) callconv(.c) ?*Image,
    class_get_fields: *const fn (*Class, Iter) callconv(.c) ?*Field,
    class_get_methods: *const fn (*Class, Iter) callconv(.c) ?*Method,
    class_get_method_from_name: *const fn (*Class, [*:0]const u8, c_int) callconv(.c) ?*Method,
    class_instance_size: *const fn (*Class) callconv(.c) i32,
    class_is_valuetype: *const fn (*Class) callconv(.c) bool,
    class_get_type: *const fn (*Class) callconv(.c) ?*Type,
    class_from_type: *const fn (*Type) callconv(.c) ?*Class,
    field_get_name: *const fn (*Field) callconv(.c) Name,
    field_get_offset: *const fn (*Field) callconv(.c) usize,
    field_get_type: *const fn (*Field) callconv(.c) ?*Type,
    field_get_flags: *const fn (*Field) callconv(.c) c_int,
    field_get_parent: *const fn (*Field) callconv(.c) ?*Class,
    field_static_get_value: *const fn (*Field, *anyopaque) callconv(.c) void,
    field_get_value: *const fn (*Object, *Field, *anyopaque) callconv(.c) void,
    field_set_value: *const fn (*Object, *Field, ?*anyopaque) callconv(.c) void,
    // Not in older Unity
    class_get_static_field_data: ?*const fn (*Class) callconv(.c) ?*anyopaque,
    runtime_class_init: ?*const fn (*Class) callconv(.c) void,
    type_get_name: *const fn (*Type) callconv(.c) ?[*:0]u8,
    type_get_type: *const fn (*Type) callconv(.c) c_int,
    free: *const fn (?*anyopaque) callconv(.c) void,
    method_get_name: *const fn (*Method) callconv(.c) Name,
    method_get_param_count: *const fn (*Method) callconv(.c) u32,
    method_get_param: *const fn (*Method, u32) callconv(.c) ?*Type,
    method_get_return_type: *const fn (*Method) callconv(.c) ?*Type,
    method_get_class: *const fn (*Method) callconv(.c) ?*Class,
    method_get_flags: *const fn (*Method, ?*u32) callconv(.c) u32,
    object_get_class: *const fn (*Object) callconv(.c) ?*Class,
    object_unbox: *const fn (*Object) callconv(.c) ?*anyopaque,
    string_new: *const fn ([*:0]const u8) callconv(.c) ?*String,
    object_new: *const fn (*Class) callconv(.c) ?*Object,
    string_chars: *const fn (*String) callconv(.c) ?[*]const u16,
    string_length: *const fn (*String) callconv(.c) i32,
    runtime_invoke: *const fn (*Method, ?*anyopaque, ?[*]const ?*anyopaque, ?*?*Object) callconv(.c) ?*Object,
    gchandle_new: *const fn (*Object, bool) callconv(.c) u32,
    gchandle_get_target: *const fn (u32) callconv(.c) ?*Object,
    gchandle_free: *const fn (u32) callconv(.c) void,
    resolve_icall: *const fn ([*:0]const u8) callconv(.c) ?*anyopaque,
    type_get_object: *const fn (*Type) callconv(.c) ?*Object,
    array_new: *const fn (*Class, usize) callconv(.c) ?*Object,
    array_length: *const fn (*Object) callconv(.c) u32,
    thread_current: *const fn () callconv(.c) ?*Thread,
    class_is_enum: *const fn (*Class) callconv(.c) bool,
    class_enum_basetype: *const fn (*Class) callconv(.c) ?*Type,
};

pub const Il2Cpp = struct {
    api: Api,

    pub fn init(r: exports.Resolver, missing: ?*[]const u8) !Il2Cpp {
        return .{ .api = try exports.load(Api, "il2cpp_", r, missing) };
    }

    /// Only reads a static, so it's safe before IL2CPP's started, unlike `domain`, which allocates.
    pub fn started(self: *const Il2Cpp) bool {
        return self.api.get_corlib() != null;
    }

    pub fn domain(self: *const Il2Cpp) ?*Domain {
        return self.api.domain_get();
    }

    pub fn attach(self: *const Il2Cpp) ?*Thread {
        return self.api.thread_attach(self.domain() orelse return null);
    }

    pub fn detach(self: *const Il2Cpp, t: *Thread) void {
        self.api.thread_detach(t);
    }

    pub fn assemblies(self: *const Il2Cpp, allocator: std.mem.Allocator) ![]*Assembly {
        const d = self.domain() orelse return &.{};
        var n: usize = 0;
        const list = self.api.domain_get_assemblies(d, &n) orelse return &.{};
        return allocator.dupe(*Assembly, @constCast(list[0..n]));
    }

    pub fn assemblyImage(self: *const Il2Cpp, a: *Assembly) ?*Image {
        return self.api.assembly_get_image(a);
    }

    pub fn imageName(self: *const Il2Cpp, i: *Image) Name {
        return self.api.image_get_name(i);
    }

    /// 0 before Unity 2018.3, which can't list them.
    pub fn classCount(self: *const Il2Cpp, i: *Image) usize {
        const count = self.api.image_get_class_count orelse return 0;
        return count(i);
    }

    pub fn classAt(self: *const Il2Cpp, i: *Image, n: usize) ?*Class {
        const get = self.api.image_get_class orelse return null;
        return get(i, n);
    }

    pub fn findClass(self: *const Il2Cpp, i: *Image, namespace: [*:0]const u8, name: [*:0]const u8) ?*Class {
        return self.api.class_from_name(i, namespace, name);
    }

    pub fn className(self: *const Il2Cpp, c: *Class) Name {
        return self.api.class_get_name(c);
    }

    pub fn classNamespace(self: *const Il2Cpp, c: *Class) Name {
        return self.api.class_get_namespace(c);
    }

    pub fn classParent(self: *const Il2Cpp, c: *Class) ?*Class {
        return self.api.class_get_parent(c);
    }

    pub fn classOuter(self: *const Il2Cpp, c: *Class) ?*Class {
        return self.api.class_get_declaring_type(c);
    }

    pub fn classImage(self: *const Il2Cpp, c: *Class) ?*Image {
        return self.api.class_get_image(c);
    }

    pub fn instanceSize(self: *const Il2Cpp, c: *Class) i32 {
        return self.api.class_instance_size(c);
    }

    pub fn isValueType(self: *const Il2Cpp, c: *Class) bool {
        return self.api.class_is_valuetype(c);
    }

    pub fn classType(self: *const Il2Cpp, c: *Class) ?*Type {
        return self.api.class_get_type(c);
    }

    pub fn typeClass(self: *const Il2Cpp, t: *Type) ?*Class {
        return self.api.class_from_type(t);
    }

    pub fn nextField(self: *const Il2Cpp, c: *Class, iter: Iter) ?*Field {
        return self.api.class_get_fields(c, iter);
    }

    pub fn nextMethod(self: *const Il2Cpp, c: *Class, iter: Iter) ?*Method {
        return self.api.class_get_methods(c, iter);
    }

    pub fn findMethod(self: *const Il2Cpp, c: *Class, name: [*:0]const u8, args: i32) ?*Method {
        return self.api.class_get_method_from_name(c, name, args);
    }

    pub fn fieldName(self: *const Il2Cpp, f: *Field) Name {
        return self.api.field_get_name(f);
    }

    pub fn fieldOffset(self: *const Il2Cpp, f: *Field) usize {
        return self.api.field_get_offset(f);
    }

    pub fn fieldType(self: *const Il2Cpp, f: *Field) ?*Type {
        return self.api.field_get_type(f);
    }

    pub fn fieldFlags(self: *const Il2Cpp, f: *Field) u32 {
        return @bitCast(self.api.field_get_flags(f));
    }

    pub fn fieldClass(self: *const Il2Cpp, f: *Field) ?*Class {
        return self.api.field_get_parent(f);
    }

    pub fn staticValue(self: *const Il2Cpp, f: *Field, out: *anyopaque) bool {
        self.api.field_static_get_value(f, out);
        return true;
    }

    pub fn fieldValue(self: *const Il2Cpp, o: *Object, f: *Field, out: *anyopaque) void {
        self.api.field_get_value(o, f, out);
    }

    pub fn setFieldValue(self: *const Il2Cpp, o: *Object, f: *Field, value: ?*anyopaque) void {
        self.api.field_set_value(o, f, value);
    }

    /// Runs the static constructor first if needed, since statics don't exist till then. Null in older Unity.
    pub fn staticData(self: *const Il2Cpp, c: *Class) ?usize {
        const get = self.api.class_get_static_field_data orelse return null;
        if (self.api.runtime_class_init) |init_class| init_class(c);
        return @intFromPtr(get(c) orelse return null);
    }

    pub fn typeNameOwned(self: *const Il2Cpp, t: *Type) ?[*:0]u8 {
        return self.api.type_get_name(t);
    }

    pub fn free(self: *const Il2Cpp, p: ?*anyopaque) void {
        self.api.free(p);
    }

    pub fn typeKind(self: *const Il2Cpp, t: *Type) h.ElementType {
        return @fromBackingInt(@intCast(@as(u8, @truncate(@as(c_uint, @bitCast(self.api.type_get_type(t)))))));
    }

    pub fn methodName(self: *const Il2Cpp, m: *Method) Name {
        return self.api.method_get_name(m);
    }

    pub fn paramCount(self: *const Il2Cpp, m: *Method) u32 {
        return self.api.method_get_param_count(m);
    }

    pub fn paramType(self: *const Il2Cpp, m: *Method, i: u32) ?*Type {
        return self.api.method_get_param(m, i);
    }

    pub fn returnType(self: *const Il2Cpp, m: *Method) ?*Type {
        return self.api.method_get_return_type(m);
    }

    pub fn methodClass(self: *const Il2Cpp, m: *Method) ?*Class {
        return self.api.method_get_class(m);
    }

    pub fn methodFlags(self: *const Il2Cpp, m: *Method) u32 {
        return self.api.method_get_flags(m, null);
    }

    /// Native code is first in every MethodInfo. Null for abstract methods and generics never instantiated.
    pub fn methodPointer(_: *const Il2Cpp, m: *Method) ?usize {
        const first: *const usize = @ptrCast(@alignCast(m));
        return if (first.* == 0) null else first.*;
    }

    pub fn objectClass(self: *const Il2Cpp, o: *Object) ?*Class {
        return self.api.object_get_class(o);
    }

    pub fn unbox(self: *const Il2Cpp, o: *Object) ?*anyopaque {
        return self.api.object_unbox(o);
    }

    /// Not constructed: call its `.ctor` next.
    pub fn newObject(self: *const Il2Cpp, c: *Class) ?*Object {
        return self.api.object_new(c);
    }

    pub fn newString(self: *const Il2Cpp, text: [*:0]const u8) ?*String {
        return self.api.string_new(text);
    }

    pub fn stringChars(self: *const Il2Cpp, s: *String) []const u16 {
        const chars = self.api.string_chars(s) orelse return &.{};
        return chars[0..@intCast(@max(0, self.api.string_length(s)))];
    }

    pub fn invoke(self: *const Il2Cpp, m: *Method, this: ?*anyopaque, args: ?[*]const ?*anyopaque, exception: ?*?*Object) ?*Object {
        return self.api.runtime_invoke(m, this, args, exception);
    }

    pub fn newHandle(self: *const Il2Cpp, o: *Object, pinned: bool) u32 {
        return self.api.gchandle_new(o, pinned);
    }

    pub fn handleTarget(self: *const Il2Cpp, handle: u32) ?*Object {
        return self.api.gchandle_get_target(handle);
    }

    pub fn freeHandle(self: *const Il2Cpp, handle: u32) void {
        self.api.gchandle_free(handle);
    }

    pub fn methodImplFlags(self: *const Il2Cpp, m: *Method) u32 {
        var iflags: u32 = 0;
        _ = self.api.method_get_flags(m, &iflags);
        return iflags;
    }

    /// By name, like `UnityEngine.Transform::get_position_Injected`, with or without its signature.
    pub fn icallNamed(self: *const Il2Cpp, name: [*:0]const u8) ?usize {
        return @intFromPtr(self.api.resolve_icall(name) orelse return null);
    }

    pub fn typeObject(self: *const Il2Cpp, t: *Type) ?*Object {
        return self.api.type_get_object(t);
    }

    pub fn newArray(self: *const Il2Cpp, element: *Class, length: usize) ?*Object {
        return self.api.array_new(element, length);
    }

    pub fn arrayLength(self: *const Il2Cpp, array: *Object) usize {
        return self.api.array_length(array);
    }

    pub fn attachedHere(self: *const Il2Cpp) bool {
        return self.api.thread_current() != null;
    }

    pub fn isEnum(self: *const Il2Cpp, c: *Class) bool {
        return self.api.class_is_enum(c);
    }

    pub fn enumBase(self: *const Il2Cpp, c: *Class) ?*Type {
        return self.api.class_enum_basetype(c);
    }
};
