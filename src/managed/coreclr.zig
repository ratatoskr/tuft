//! .NET's CoreCLR, which games and mod loaders like Dalamud run C# on. It has no reflection API
//! for native code, so this joins the runtime the game's already running and loads a C# helper
//! into it, then asks it. The helper's built from `coreclr/` by `zig build coreclr` and kept in
//! `coreclr/bin`, so building tuft doesn't need the dotnet SDK. Only reads for now: objects move
//! under CoreCLR's garbage collector, so calls that would hold one aren't there yet.
//!
//! Types are the runtime's MethodTables, so `Class` and `Type` are the same handle. Fields and
//! methods are its FieldDescs and MethodDescs. An image is its assembly.

const std = @import("std");
const sys = @import("tuft_sys");
/// salamander's hosting, for `lastStatus` and its codes when joining fails.
pub const clr = @import("salamander_clr");
const schema = @import("reflect_schema");
const h = @import("handles.zig");

/// The helper's IL, which only differs by pointer size.
const helper = if (@sizeOf(usize) == 8) @embedFile("coreclr/bin/Tuft.CoreClr.64.dll") else @embedFile("coreclr/bin/Tuft.CoreClr.32.dll");

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

/// The runtime's library, there once a game's started one.
pub const modules = [_][]const u8{clr.fxr.coreclr_name};

/// What the helper's config asks for. The running runtime has to be at least this to join it.
const runtime_config =
    \\{"runtimeOptions":{"tfm":"net10.0","rollForward":"LatestMajor","framework":{"name":"Microsoft.NETCore.App","version":"10.0.0"}}}
;

pub const OpenError = error{
    /// No CoreCLR in this process
    NotRunning,
    /// Ours wasn't loaded, see `clr.lastStatus`
    HelperFailed,
    /// Its config file couldn't be written to `dir`
    ConfigFailed,
} || clr.Error;

pub const CoreClr = struct {
    reflector: schema.Reflector,
    cache: *Cache,

    pub const Options = struct {
        /// Where to write the small config file hostfxr needs to join, like a cache folder.
        dir: []const u8,
        /// Start a runtime if there isn't one, which only tests should.
        start: bool = false,
        /// Gets hostfxr's own messages about what went wrong.
        messages: ?*std.Io.Writer = null,
    };

    /// Joins the CoreCLR this process runs and loads the helper into it. Lives as long as the
    /// process, and so does `a`.
    pub fn open(a: std.mem.Allocator, io: std.Io, options: Options) OpenError!CoreClr {
        if (!options.start and !clr.running()) return error.NotRunning;
        const config = try std.fs.path.join(a, &.{ options.dir, "tuft-coreclr.runtimeconfig.json" });
        defer a.free(config);
        std.Io.Dir.cwd().createDirPath(io, options.dir) catch return error.ConfigFailed;
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = config, .data = runtime_config }) catch return error.ConfigFailed;
        const host = try clr.Host.open(a, io, .{ .runtime_config = config, .join_only = !options.start, .messages = options.messages });
        // Already there when something in this process opened it before, which loading again refuses
        host.loadBytes(helper, null) catch {};
        const open_fn = host.function(*const fn () callconv(clr.cc) schema.Reflector, a, "Tuft.CoreClr.Exports, Tuft.CoreClr", "Open") catch return error.HelperFailed;
        const reflector = open_fn();
        if (reflector.table == null) return error.HelperFailed;
        const cache = try a.create(Cache);
        cache.* = .{ .a = a };
        return .{ .reflector = reflector, .cache = cache };
    }

    /// What the helper gives back is only good till it's called again, so names and lists are
    /// copied once and kept, like Mono's are.
    const Cache = struct {
        a: std.mem.Allocator,
        lock: sys.sync.Mutex = .{},
        names: std.AutoHashMapUnmanaged(Key, [:0]const u8) = .empty,
        lists: std.AutoHashMapUnmanaged(Key, []const usize) = .empty,

        const Key = struct { what: What, handle: usize };
        const What = enum(u8) { assembly, type, namespace, full_name, field, method, types, fields, methods, params };
    };

    fn name(self: *const CoreClr, what: Cache.What, handle: usize, comptime get: anytype) Name {
        if (handle == 0) return null;
        const c = self.cache;
        c.lock.lock();
        defer c.lock.unlock();
        const key: Cache.Key = .{ .what = what, .handle = handle };
        if (c.names.get(key)) |n| return n.ptr;
        const text = c.a.dupeSentinel(u8, get(self.reflector, handle), 0) catch return null;
        c.names.put(c.a, key, text) catch {
            c.a.free(text);
            return null;
        };
        return text.ptr;
    }

    fn list(self: *const CoreClr, what: Cache.What, handle: usize, comptime get: anytype) []const usize {
        const c = self.cache;
        c.lock.lock();
        defer c.lock.unlock();
        const key: Cache.Key = .{ .what = what, .handle = handle };
        if (c.lists.get(key)) |l| return l;
        const items = c.a.dupe(usize, get(self.reflector, handle)) catch return &.{};
        c.lists.put(c.a, key, items) catch {
            c.a.free(items);
            return &.{};
        };
        return items;
    }

    fn of(comptime T: type, handle: usize) ?*T {
        return if (handle == 0) null else @ptrFromInt(handle);
    }

    fn id(p: anytype) usize {
        return @intFromPtr(p);
    }

    // Threads that call in are set up by the runtime itself, so there's nothing to attach, but
    // callers want something back

    pub fn started(_: *const CoreClr) bool {
        return true;
    }

    pub fn domain(self: *const CoreClr) ?*Domain {
        return @ptrCast(self.cache);
    }

    pub fn attach(self: *const CoreClr) ?*Thread {
        return @ptrCast(self.cache);
    }

    pub fn detach(_: *const CoreClr, _: *Thread) void {}

    pub fn attachedHere(_: *const CoreClr) bool {
        return true;
    }

    pub fn assemblies(self: *const CoreClr, allocator: std.mem.Allocator) ![]*Assembly {
        // Fresh each time, since more load as the game goes
        const got = self.reflector.assemblies();
        const out = try allocator.alloc(*Assembly, got.len);
        var n: usize = 0;
        for (got) |a| if (of(Assembly, a)) |p| {
            out[n] = p;
            n += 1;
        };
        return allocator.realloc(out, n);
    }

    pub fn assemblyImage(_: *const CoreClr, a: *Assembly) ?*Image {
        return @ptrCast(a);
    }

    pub fn imageName(self: *const CoreClr, i: *Image) Name {
        return self.name(.assembly, id(i), schema.Reflector.assemblyName);
    }

    pub fn classCount(self: *const CoreClr, i: *Image) usize {
        return self.list(.types, id(i), schema.Reflector.types).len;
    }

    pub fn classAt(self: *const CoreClr, i: *Image, n: usize) ?*Class {
        const all = self.list(.types, id(i), schema.Reflector.types);
        return if (n < all.len) of(Class, all[n]) else null;
    }

    pub fn findClass(self: *const CoreClr, i: *Image, namespace: [*:0]const u8, class_name: [*:0]const u8) ?*Class {
        return of(Class, self.reflector.findType(id(i), std.mem.span(namespace), std.mem.span(class_name)));
    }

    pub fn className(self: *const CoreClr, c: *Class) Name {
        return self.name(.type, id(c), schema.Reflector.typeName);
    }

    pub fn classNamespace(self: *const CoreClr, c: *Class) Name {
        return self.name(.namespace, id(c), schema.Reflector.typeNamespace);
    }

    pub fn classParent(self: *const CoreClr, c: *Class) ?*Class {
        return of(Class, self.reflector.typeParent(id(c)));
    }

    pub fn classOuter(self: *const CoreClr, c: *Class) ?*Class {
        return of(Class, self.reflector.typeOuter(id(c)));
    }

    pub fn classImage(self: *const CoreClr, c: *Class) ?*Image {
        return of(Image, self.reflector.typeAssembly(id(c)));
    }

    pub fn instanceSize(self: *const CoreClr, c: *Class) i32 {
        return self.reflector.instanceSize(id(c));
    }

    pub fn isValueType(self: *const CoreClr, c: *Class) bool {
        return self.reflector.isValueType(id(c));
    }

    pub fn classType(_: *const CoreClr, c: *Class) ?*Type {
        return @ptrCast(c);
    }

    pub fn typeClass(_: *const CoreClr, t: *Type) ?*Class {
        return @ptrCast(t);
    }

    /// `iter` holds where it's up to, plus one.
    fn nextIn(all: []const usize, iter: Iter) usize {
        const at: usize = @intFromPtr(iter.*);
        if (at >= all.len) return 0;
        iter.* = @ptrFromInt(at + 1);
        return all[at];
    }

    pub fn nextField(self: *const CoreClr, c: *Class, iter: Iter) ?*Field {
        return of(Field, nextIn(self.list(.fields, id(c), schema.Reflector.fields), iter));
    }

    pub fn nextMethod(self: *const CoreClr, c: *Class, iter: Iter) ?*Method {
        return of(Method, nextIn(self.list(.methods, id(c), schema.Reflector.methods), iter));
    }

    pub fn findMethod(self: *const CoreClr, c: *Class, method_name: [*:0]const u8, args: i32) ?*Method {
        const want = std.mem.span(method_name);
        for (self.list(.methods, id(c), schema.Reflector.methods)) |m| {
            const p = of(Method, m) orelse continue;
            if (!std.mem.eql(u8, std.mem.span(self.methodName(p) orelse continue), want)) continue;
            if (args >= 0 and self.paramCount(p) != args) continue;
            return p;
        }
        return null;
    }

    pub fn fieldName(self: *const CoreClr, f: *Field) Name {
        return self.name(.field, id(f), schema.Reflector.fieldName);
    }

    /// `maxInt` for statics, which `staticAddress` finds instead.
    pub fn fieldOffset(self: *const CoreClr, f: *Field) usize {
        const offset = self.reflector.fieldOffset(id(f));
        return if (offset < 0) std.math.maxInt(usize) else @intCast(offset);
    }

    pub fn fieldType(self: *const CoreClr, f: *Field) ?*Type {
        return of(Type, self.reflector.fieldType(id(f)));
    }

    pub fn fieldFlags(self: *const CoreClr, f: *Field) u32 {
        return self.reflector.fieldFlags(id(f));
    }

    pub fn fieldClass(self: *const CoreClr, f: *Field) ?*Class {
        return of(Class, self.reflector.fieldOwner(id(f)));
    }

    /// Where a static field is, or null for a thread static or a const.
    pub fn staticAddress(self: *const CoreClr, f: *Field) ?usize {
        const at = self.reflector.staticAddress(id(f));
        return if (at == 0) null else at;
    }

    // Not yet, see the top
    pub fn staticValue(_: *const CoreClr, _: *Field, _: *anyopaque) bool {
        return false;
    }

    pub fn staticData(_: *const CoreClr, _: *Class) ?usize {
        return null;
    }

    pub fn fieldValue(_: *const CoreClr, _: *Object, _: *Field, _: *anyopaque) void {}

    pub fn setFieldValue(_: *const CoreClr, _: *Object, _: *Field, _: ?*anyopaque) void {}

    /// The runtime keeps it, so `free` does nothing.
    pub fn typeNameOwned(self: *const CoreClr, t: *Type) ?[*:0]u8 {
        return @constCast(self.name(.full_name, id(t), schema.Reflector.typeFullName));
    }

    pub fn free(_: *const CoreClr, _: ?*anyopaque) void {}

    pub fn typeKind(self: *const CoreClr, t: *Type) h.ElementType {
        return @fromBackingInt(self.reflector.elementType(id(t)));
    }

    pub fn methodName(self: *const CoreClr, m: *Method) Name {
        return self.name(.method, id(m), schema.Reflector.methodName);
    }

    pub fn paramCount(self: *const CoreClr, m: *Method) u32 {
        return @intCast(self.list(.params, id(m), schema.Reflector.paramTypes).len);
    }

    pub fn paramType(self: *const CoreClr, m: *Method, i: u32) ?*Type {
        const all = self.list(.params, id(m), schema.Reflector.paramTypes);
        return if (i < all.len) of(Type, all[i]) else null;
    }

    pub fn returnType(self: *const CoreClr, m: *Method) ?*Type {
        return of(Type, self.reflector.returnType(id(m)));
    }

    pub fn methodClass(self: *const CoreClr, m: *Method) ?*Class {
        return of(Class, self.reflector.methodOwner(id(m)));
    }

    pub fn methodFlags(self: *const CoreClr, m: *Method) u32 {
        return self.reflector.methodFlags(id(m));
    }

    pub fn methodImplFlags(self: *const CoreClr, m: *Method) u32 {
        return self.reflector.methodImplFlags(id(m));
    }

    /// Where calls to it go. It may be a stub the runtime moves on to newer code from, but calls
    /// always go through it, so it's what to hook.
    pub fn methodPointer(self: *const CoreClr, m: *Method) ?usize {
        const at = self.reflector.methodPointer(id(m));
        return if (at == 0) null else at;
    }

    // Objects, read straight from memory, since their layout's been the same since .NET Core 1.
    // Each is only good till the garbage collector next runs.

    const word = @sizeOf(usize);

    /// Every object starts with its MethodTable.
    pub fn objectClass(_: *const CoreClr, o: *Object) ?*Class {
        const mt: *const usize = @ptrCast(@alignCast(o));
        return of(Class, mt.*);
    }

    /// A boxed value starts right after the MethodTable.
    pub fn unbox(_: *const CoreClr, o: *Object) ?*anyopaque {
        return @ptrFromInt(@intFromPtr(o) + word);
    }

    /// Its length as an i32, then its UTF-16.
    pub fn stringChars(_: *const CoreClr, s: *String) []const u16 {
        const at = @intFromPtr(s);
        const len: *const i32 = @ptrFromInt(at + word);
        const chars: [*]const u16 = @ptrFromInt(at + word + 4);
        return chars[0..@intCast(@max(0, len.*))];
    }

    /// Its length, a word wide with padding, then its items.
    pub fn arrayLength(_: *const CoreClr, array: *Object) usize {
        const len: *const u32 = @ptrFromInt(@intFromPtr(array) + word);
        return len.*;
    }

    pub const array_items_offset = 2 * word;

    // Not yet, see the top
    pub fn newString(_: *const CoreClr, _: [*:0]const u8) ?*String {
        return null;
    }

    pub fn invoke(_: *const CoreClr, _: *Method, _: ?*anyopaque, _: ?[*]const ?*anyopaque, _: ?*?*Object) ?*Object {
        return null;
    }

    pub fn newHandle(_: *const CoreClr, _: *Object, _: bool) u32 {
        return 0;
    }

    pub fn handleTarget(_: *const CoreClr, _: u32) ?*Object {
        return null;
    }

    pub fn freeHandle(_: *const CoreClr, _: u32) void {}

    pub fn typeObject(_: *const CoreClr, _: *Type) ?*Object {
        return null;
    }

    pub fn newArray(_: *const CoreClr, _: *Class, _: usize) ?*Object {
        return null;
    }

    pub fn isEnum(self: *const CoreClr, c: *Class) bool {
        return self.reflector.isEnum(id(c));
    }

    pub fn enumBase(self: *const CoreClr, c: *Class) ?*Type {
        return of(Type, self.reflector.enumBase(id(c)));
    }
};
