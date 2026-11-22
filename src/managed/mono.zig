//! Mono, from the `mono_` exports in mono-2.0-bdwgc.dll or mono.dll. Methods are compiled the first
//! time they run, so getting one's address may compile it.

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
const VTable = opaque {};
const Signature = opaque {};
/// `mono_bool` is an int.
const Bool = i32;

const typedef_table = 2;
const typedef_token = 0x02000000;

pub const Api = struct {
    get_corlib: *const fn () callconv(.c) ?*Image,
    get_root_domain: *const fn () callconv(.c) ?*Domain,
    thread_attach: *const fn (*Domain) callconv(.c) ?*Thread,
    thread_detach: *const fn (*Thread) callconv(.c) void,
    assembly_foreach: *const fn (*const fn (?*anyopaque, ?*anyopaque) callconv(.c) void, ?*anyopaque) callconv(.c) void,
    assembly_get_image: *const fn (*Assembly) callconv(.c) ?*Image,
    image_get_name: *const fn (*Image) callconv(.c) Name,
    image_get_table_rows: *const fn (*Image, c_int) callconv(.c) c_int,
    class_get: *const fn (*Image, u32) callconv(.c) ?*Class,
    class_from_name: *const fn (*Image, [*:0]const u8, [*:0]const u8) callconv(.c) ?*Class,
    class_get_name: *const fn (*Class) callconv(.c) Name,
    class_get_namespace: *const fn (*Class) callconv(.c) Name,
    class_get_parent: *const fn (*Class) callconv(.c) ?*Class,
    class_get_nesting_type: *const fn (*Class) callconv(.c) ?*Class,
    class_get_image: *const fn (*Class) callconv(.c) ?*Image,
    class_get_fields: *const fn (*Class, Iter) callconv(.c) ?*Field,
    class_get_methods: *const fn (*Class, Iter) callconv(.c) ?*Method,
    class_get_method_from_name: *const fn (*Class, [*:0]const u8, c_int) callconv(.c) ?*Method,
    class_instance_size: *const fn (*Class) callconv(.c) i32,
    class_is_valuetype: *const fn (*Class) callconv(.c) Bool,
    class_get_type: *const fn (*Class) callconv(.c) ?*Type,
    class_from_mono_type: *const fn (*Type) callconv(.c) ?*Class,
    class_vtable: *const fn (*Domain, *Class) callconv(.c) ?*VTable,
    vtable_get_static_field_data: *const fn (*VTable) callconv(.c) ?*anyopaque,
    field_get_name: *const fn (*Field) callconv(.c) Name,
    field_get_offset: *const fn (*Field) callconv(.c) u32,
    field_get_type: *const fn (*Field) callconv(.c) ?*Type,
    field_get_flags: *const fn (*Field) callconv(.c) u32,
    field_get_parent: *const fn (*Field) callconv(.c) ?*Class,
    field_static_get_value: *const fn (*VTable, *Field, *anyopaque) callconv(.c) void,
    type_get_name: *const fn (*Type) callconv(.c) ?[*:0]u8,
    type_get_type: *const fn (*Type) callconv(.c) c_int,
    free: *const fn (?*anyopaque) callconv(.c) void,
    method_get_name: *const fn (*Method) callconv(.c) Name,
    method_get_class: *const fn (*Method) callconv(.c) ?*Class,
    method_get_flags: *const fn (*Method, ?*u32) callconv(.c) u32,
    method_signature: *const fn (*Method) callconv(.c) ?*Signature,
    signature_get_param_count: *const fn (*Signature) callconv(.c) u32,
    signature_get_params: *const fn (*Signature, Iter) callconv(.c) ?*Type,
    signature_get_return_type: *const fn (*Signature) callconv(.c) ?*Type,
    compile_method: *const fn (*Method) callconv(.c) ?*anyopaque,
    object_get_class: *const fn (*Object) callconv(.c) ?*Class,
    object_unbox: *const fn (*Object) callconv(.c) ?*anyopaque,
    string_new: *const fn (*Domain, [*:0]const u8) callconv(.c) ?*String,
    string_chars: *const fn (*String) callconv(.c) ?[*]const u16,
    string_length: *const fn (*String) callconv(.c) i32,
    runtime_invoke: *const fn (*Method, ?*anyopaque, ?[*]const ?*anyopaque, ?*?*Object) callconv(.c) ?*Object,
    gchandle_new: *const fn (*Object, Bool) callconv(.c) u32,
    gchandle_get_target: *const fn (u32) callconv(.c) ?*Object,
    gchandle_free: *const fn (u32) callconv(.c) void,
    lookup_internal_call: *const fn (*Method) callconv(.c) ?*anyopaque,
    type_get_object: *const fn (*Domain, *Type) callconv(.c) ?*Object,
    array_new: *const fn (*Domain, *Class, usize) callconv(.c) ?*Object,
    array_length: *const fn (*Object) callconv(.c) usize,
    /// The thread's own, null on threads Mono doesn't know
    domain_get: *const fn () callconv(.c) ?*Domain,
    class_is_enum: *const fn (*Class) callconv(.c) Bool,
    class_enum_basetype: *const fn (*Class) callconv(.c) ?*Type,
};

pub const Mono = struct {
    api: Api,

    pub fn init(r: exports.Resolver, missing: ?*[]const u8) !Mono {
        return .{ .api = try exports.load(Api, "mono_", r, missing) };
    }

    /// Only reads statics, so it's safe before Mono's started.
    pub fn started(self: *const Mono) bool {
        return self.api.get_root_domain() != null and self.api.get_corlib() != null;
    }

    /// Null till the game's started Mono.
    pub fn domain(self: *const Mono) ?*Domain {
        return self.api.get_root_domain();
    }

    pub fn attach(self: *const Mono) ?*Thread {
        return self.api.thread_attach(self.domain() orelse return null);
    }

    pub fn detach(self: *const Mono, t: *Thread) void {
        self.api.thread_detach(t);
    }

    pub fn assemblies(self: *const Mono, allocator: std.mem.Allocator) ![]*Assembly {
        const Gather = struct {
            list: std.ArrayList(*Assembly) = .empty,
            allocator: std.mem.Allocator,
            failed: bool = false,

            fn each(a: ?*anyopaque, ctx: ?*anyopaque) callconv(.c) void {
                const g: *@This() = @ptrCast(@alignCast(ctx.?));
                g.list.append(g.allocator, @ptrCast(a orelse return)) catch {
                    g.failed = true;
                };
            }
        };
        var g: Gather = .{ .allocator = allocator };
        errdefer g.list.deinit(allocator);
        self.api.assembly_foreach(Gather.each, &g);
        if (g.failed) return error.OutOfMemory;
        return g.list.toOwnedSlice(allocator);
    }

    pub fn assemblyImage(self: *const Mono, a: *Assembly) ?*Image {
        return self.api.assembly_get_image(a);
    }

    pub fn imageName(self: *const Mono, i: *Image) Name {
        return self.api.image_get_name(i);
    }

    pub fn classCount(self: *const Mono, i: *Image) usize {
        return @intCast(@max(0, self.api.image_get_table_rows(i, typedef_table)));
    }

    /// The image's type definitions, by row. Row 1 is `<Module>`, as in IL2CPP.
    pub fn classAt(self: *const Mono, i: *Image, n: usize) ?*Class {
        return self.api.class_get(i, typedef_token | @as(u32, @intCast(n + 1)));
    }

    pub fn findClass(self: *const Mono, i: *Image, namespace: [*:0]const u8, name: [*:0]const u8) ?*Class {
        return self.api.class_from_name(i, namespace, name);
    }

    pub fn className(self: *const Mono, c: *Class) Name {
        return self.api.class_get_name(c);
    }

    pub fn classNamespace(self: *const Mono, c: *Class) Name {
        return self.api.class_get_namespace(c);
    }

    pub fn classParent(self: *const Mono, c: *Class) ?*Class {
        return self.api.class_get_parent(c);
    }

    pub fn classOuter(self: *const Mono, c: *Class) ?*Class {
        return self.api.class_get_nesting_type(c);
    }

    pub fn classImage(self: *const Mono, c: *Class) ?*Image {
        return self.api.class_get_image(c);
    }

    pub fn instanceSize(self: *const Mono, c: *Class) i32 {
        return self.api.class_instance_size(c);
    }

    pub fn isValueType(self: *const Mono, c: *Class) bool {
        return self.api.class_is_valuetype(c) != 0;
    }

    pub fn classType(self: *const Mono, c: *Class) ?*Type {
        return self.api.class_get_type(c);
    }

    pub fn typeClass(self: *const Mono, t: *Type) ?*Class {
        return self.api.class_from_mono_type(t);
    }

    pub fn nextField(self: *const Mono, c: *Class, iter: Iter) ?*Field {
        return self.api.class_get_fields(c, iter);
    }

    pub fn nextMethod(self: *const Mono, c: *Class, iter: Iter) ?*Method {
        return self.api.class_get_methods(c, iter);
    }

    pub fn findMethod(self: *const Mono, c: *Class, name: [*:0]const u8, args: i32) ?*Method {
        return self.api.class_get_method_from_name(c, name, args);
    }

    pub fn fieldName(self: *const Mono, f: *Field) Name {
        return self.api.field_get_name(f);
    }

    pub fn fieldOffset(self: *const Mono, f: *Field) usize {
        return self.api.field_get_offset(f);
    }

    pub fn fieldType(self: *const Mono, f: *Field) ?*Type {
        return self.api.field_get_type(f);
    }

    pub fn fieldFlags(self: *const Mono, f: *Field) u32 {
        return self.api.field_get_flags(f);
    }

    pub fn fieldClass(self: *const Mono, f: *Field) ?*Class {
        return self.api.field_get_parent(f);
    }

    fn vtable(self: *const Mono, c: *Class) ?*VTable {
        return self.api.class_vtable(self.domain() orelse return null, c);
    }

    pub fn staticValue(self: *const Mono, f: *Field, out: *anyopaque) bool {
        const vt = self.vtable(self.fieldClass(f) orelse return false) orelse return false;
        self.api.field_static_get_value(vt, f, out);
        return true;
    }

    /// Add a static field's offset to get its address.
    pub fn staticData(self: *const Mono, c: *Class) ?usize {
        const data = self.api.vtable_get_static_field_data(self.vtable(c) orelse return null) orelse return null;
        return @intFromPtr(data);
    }

    pub fn typeNameOwned(self: *const Mono, t: *Type) ?[*:0]u8 {
        return self.api.type_get_name(t);
    }

    pub fn free(self: *const Mono, p: ?*anyopaque) void {
        self.api.free(p);
    }

    pub fn typeKind(self: *const Mono, t: *Type) h.ElementType {
        return @fromBackingInt(@intCast(@as(u8, @truncate(@as(c_uint, @bitCast(self.api.type_get_type(t)))))));
    }

    pub fn methodName(self: *const Mono, m: *Method) Name {
        return self.api.method_get_name(m);
    }

    pub fn paramCount(self: *const Mono, m: *Method) u32 {
        const sig = self.api.method_signature(m) orelse return 0;
        return self.api.signature_get_param_count(sig);
    }

    pub fn paramType(self: *const Mono, m: *Method, i: u32) ?*Type {
        const sig = self.api.method_signature(m) orelse return null;
        var iter: ?*anyopaque = null;
        var n: u32 = 0;
        while (self.api.signature_get_params(sig, &iter)) |t| : (n += 1) {
            if (n == i) return t;
        }
        return null;
    }

    pub fn returnType(self: *const Mono, m: *Method) ?*Type {
        const sig = self.api.method_signature(m) orelse return null;
        return self.api.signature_get_return_type(sig);
    }

    pub fn methodClass(self: *const Mono, m: *Method) ?*Class {
        return self.api.method_get_class(m);
    }

    pub fn methodFlags(self: *const Mono, m: *Method) u32 {
        return self.api.method_get_flags(m, null);
    }

    /// Compiles it if nothing's run it yet. Needs an attached thread.
    pub fn methodPointer(self: *const Mono, m: *Method) ?usize {
        const code = self.api.compile_method(m) orelse return null;
        return @intFromPtr(code);
    }

    pub fn objectClass(self: *const Mono, o: *Object) ?*Class {
        return self.api.object_get_class(o);
    }

    pub fn unbox(self: *const Mono, o: *Object) ?*anyopaque {
        return self.api.object_unbox(o);
    }

    pub fn newString(self: *const Mono, text: [*:0]const u8) ?*String {
        return self.api.string_new(self.domain() orelse return null, text);
    }

    pub fn stringChars(self: *const Mono, s: *String) []const u16 {
        const chars = self.api.string_chars(s) orelse return &.{};
        return chars[0..@intCast(@max(0, self.api.string_length(s)))];
    }

    pub fn invoke(self: *const Mono, m: *Method, this: ?*anyopaque, args: ?[*]const ?*anyopaque, exception: ?*?*Object) ?*Object {
        return self.api.runtime_invoke(m, this, args, exception);
    }

    pub fn newHandle(self: *const Mono, o: *Object, pinned: bool) u32 {
        return self.api.gchandle_new(o, @intFromBool(pinned));
    }

    pub fn handleTarget(self: *const Mono, handle: u32) ?*Object {
        return self.api.gchandle_get_target(handle);
    }

    pub fn freeHandle(self: *const Mono, handle: u32) void {
        self.api.gchandle_free(handle);
    }

    pub fn methodImplFlags(self: *const Mono, m: *Method) u32 {
        var iflags: u32 = 0;
        _ = self.api.method_get_flags(m, &iflags);
        return iflags;
    }

    /// Mono looks them up by method, not name.
    pub fn icallOf(self: *const Mono, m: *Method) ?usize {
        return @intFromPtr(self.api.lookup_internal_call(m) orelse return null);
    }

    pub fn typeObject(self: *const Mono, t: *Type) ?*Object {
        return self.api.type_get_object(self.domain() orelse return null, t);
    }

    pub fn newArray(self: *const Mono, element: *Class, length: usize) ?*Object {
        return self.api.array_new(self.domain() orelse return null, element, length);
    }

    pub fn arrayLength(self: *const Mono, array: *Object) usize {
        return self.api.array_length(array);
    }

    pub fn attachedHere(self: *const Mono) bool {
        return self.api.domain_get() != null;
    }

    pub fn isEnum(self: *const Mono, c: *Class) bool {
        return self.api.class_is_enum(c) != 0;
    }

    pub fn enumBase(self: *const Mono, c: *Class) ?*Type {
        return self.api.class_enum_basetype(c);
    }
};
