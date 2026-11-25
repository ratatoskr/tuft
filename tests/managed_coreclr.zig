//! Starts a CoreCLR in this process, like a .NET game would, then joins and reads it like Wraith
//! does a game's. Skipped unless there's a .NET 10 runtime.

const std = @import("std");
const managed = @import("tuft_managed");

const testing = std.testing;
const word = @sizeOf(usize);

test "reads a CoreCLR" {
    // It lives as long as the process
    const gpa = std.heap.smp_allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(dir);
    var messages: std.Io.Writer.Allocating = .init(testing.allocator);
    defer messages.deinit();
    const cc = managed.CoreClr.open(gpa, testing.io, .{ .dir = dir, .start = true, .messages = &messages.writer }) catch |err| switch (err) {
        error.NoDotnet => return error.SkipZigTest,
        else => {
            std.debug.print("{t}: {s}\n", .{ err, messages.written() });
            return err;
        },
    };
    const rt: managed.Runtime = .{ .coreclr = cc };
    const a = testing.allocator;

    try testing.expect(rt.started());
    const corlib = (try rt.findImage(a, "System.Private.CoreLib")) orelse return error.NoCorlib;
    try testing.expectEqualStrings("System.Private.CoreLib.dll", rt.imageName(corlib));
    try testing.expect(rt.classCount(corlib) > 1000);

    // Strings are their length then their characters, right after the MethodTable
    const string = rt.findClass(corlib, "System", "String") orelse return error.NoString;
    try testing.expectEqualStrings("String", rt.className(string));
    try testing.expectEqualStrings("System", rt.classNamespace(string));
    try testing.expectEqual(corlib, rt.classImage(string).?);
    const length = rt.findField(string, "_stringLength") orelse return error.NoField;
    try testing.expectEqual(word, rt.fieldOffset(length));
    try testing.expectEqual(word + 4, rt.fieldOffset(rt.findField(string, "_firstChar").?));
    try testing.expectEqual(.i4, rt.typeKind(rt.fieldType(length).?));
    try testing.expectEqual(string, rt.fieldClass(length).?);

    // Four ints after the MethodTable
    const version = rt.findClass(corlib, "System", "Version") orelse return error.NoVersion;
    for ([_][]const u8{ "_Major", "_Minor", "_Build", "_Revision" }, 0..) |name, i| {
        try testing.expectEqual(word + 4 * i, rt.fieldOffset(rt.findField(version, name) orelse return error.NoField));
    }
    try testing.expectEqual(@as(i32, word + 16), rt.instanceSize(version));
    try testing.expect(!rt.isValueType(version));
    try testing.expectEqualStrings("Object", rt.className(rt.classParent(version).?));

    // String.Empty is a static holding a string with nothing in it
    const empty = rt.findField(string, "Empty") orelse return error.NoField;
    try testing.expect(rt.isStatic(empty));
    const slot: *const ?*managed.Object = @ptrFromInt(try rt.staticAddress(empty));
    const empty_string = slot.* orelse return error.NoEmpty;
    try testing.expectEqual(string, rt.objectClass(empty_string).?);
    try testing.expectEqual(0, rt.stringChars(@ptrCast(empty_string)).len);

    // Methods have code once they're compiled
    const is_empty = rt.findMethod(string, "IsNullOrEmpty", 1) orelse return error.NoMethod;
    try testing.expect(rt.isStaticMethod(is_empty));
    try testing.expectEqual(1, rt.paramCount(is_empty));
    try testing.expectEqual(.boolean, rt.typeKind(rt.returnType(is_empty).?));
    try testing.expectEqual(string, rt.typeClass(rt.paramType(is_empty, 0).?).?);
    try testing.expect(rt.methodPointer(is_empty) != null);
    try testing.expectEqual(string, rt.methodClass(is_empty).?);

    // Generics by their C# names, and nested enums
    const list = rt.findClass(corlib, "System.Collections.Generic", "List`1") orelse return error.NoList;
    const list_name = try rt.typeName(a, rt.classType(list).?);
    defer a.free(list_name);
    try testing.expectEqualStrings("System.Collections.Generic.List<T>", list_name);
    const env = rt.findClass(corlib, "System", "Environment") orelse return error.NoEnvironment;
    const folder = for (0..rt.classCount(corlib)) |i| {
        const c = rt.classAt(corlib, i) orelse continue;
        if (rt.classOuter(c) == env and std.mem.eql(u8, rt.className(c), "SpecialFolder")) break c;
    } else return error.NoNested;
    try testing.expectEqualStrings("", rt.classNamespace(folder));
    try testing.expect(rt.isEnum(folder) and rt.isValueType(folder));
    try testing.expectEqual(.i4, rt.typeKind(rt.enumBase(folder).?));

    // Joining again, like Wraith does after a test or a second copy has, finds the helper it loaded
    const again = try managed.CoreClr.open(gpa, testing.io, .{ .dir = dir });
    try testing.expectEqual(string, again.findClass(@ptrCast(corlib), "System", "String").?);

    // Strings, made and read, and held while the garbage collector moves things
    const hello = rt.newString("hello") orelse return error.NoString;
    const hello_obj: *managed.Object = @ptrCast(hello);
    try testing.expectEqual(string, rt.objectClass(hello_obj).?);
    const handle = rt.newHandle(hello_obj, false);
    try testing.expect(handle != 0);
    defer rt.freeHandle(handle);
    var chars: i32 = 0;
    rt.fieldValue(hello_obj, length, &chars);
    try testing.expectEqual(5, chars);
    const held = try rt.readString(a, @ptrCast(rt.handleTarget(handle).?));
    defer a.free(held);
    try testing.expectEqualStrings("hello", held);
    const pinned = rt.newHandle(hello_obj, true);
    try testing.expect(pinned != 0);
    rt.freeHandle(pinned);

    // Methods, with objects and values in and out, and what they throw
    const substring = rt.findMethod(string, "Substring", 1) orelse return error.NoMethod;
    var start: i32 = 2;
    var thrown: ?*managed.Object = null;
    const tail = rt.invoke(substring, rt.handleTarget(handle), &[_]?*anyopaque{&start}, &thrown) orelse return error.NoResult;
    try testing.expectEqual(null, thrown);
    const tail_text = try rt.readString(a, @ptrCast(tail));
    defer a.free(tail_text);
    try testing.expectEqualStrings("llo", tail_text);
    start = 100;
    try testing.expectEqual(null, rt.invoke(substring, rt.handleTarget(handle), &[_]?*anyopaque{&start}, &thrown));
    try testing.expectEqualStrings("ArgumentOutOfRangeException", rt.className(rt.objectClass(thrown.?).?));
    const boxed = rt.invoke(is_empty, null, &[_]?*anyopaque{rt.handleTarget(handle)}, null) orelse return error.NoResult;
    try testing.expectEqual(false, @as(*const bool, @ptrCast(rt.unbox(boxed).?)).*);

    // A new object from its constructor, and its fields read and written
    const make_version = blk: {
        var it = rt.methods(version);
        while (it.next()) |m| if (std.mem.eql(u8, rt.methodName(m), ".ctor") and rt.paramCount(m) == 2) break :blk m;
        break :blk null;
    };
    var major: i32 = 3;
    var minor: i32 = 4;
    const v = rt.invoke(make_version orelse return error.NoMethod, null, &[_]?*anyopaque{ &major, &minor }, null) orelse return error.NoResult;
    var got: i32 = 0;
    rt.fieldValue(v, rt.findField(version, "_Major").?, &got);
    try testing.expectEqual(3, got);
    var seven: i32 = 7;
    rt.setFieldValue(v, rt.findField(version, "_Minor").?, &seven);
    rt.fieldValue(v, rt.findField(version, "_Minor").?, &got);
    try testing.expectEqual(7, got);

    // Statics' values, arrays and System.Type
    var empty_value: ?*managed.Object = null;
    try testing.expect(rt.staticValue(empty, @ptrCast(&empty_value)));
    try testing.expectEqual(string, rt.objectClass(empty_value.?).?);
    const int32 = rt.findClass(corlib, "System", "Int32").?;
    const numbers = rt.newArray(int32, 3) orelse return error.NoArray;
    try testing.expectEqual(3, rt.arrayLength(numbers));
    const type_object = rt.typeObject(rt.classType(string).?) orelse return error.NoType;
    try testing.expectEqualStrings("RuntimeType", rt.className(rt.objectClass(type_object).?));

    // Mono and IL2CPP's way of finding a class anywhere works too
    try testing.expectEqual(string, (try rt.findClassAnywhere(a, "System.String")).?);
}
