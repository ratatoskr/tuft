// The C# tuft loads into a game's CoreCLR to read it, since CoreCLR has no reflection API for
// native code. reflect.sal says what each call does. Only reads, and never keeps a type, field or
// method alive, so a mod loader can still unload what it loaded.

using System;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;
using System.Reflection.Emit;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

namespace Tuft.CoreClr;

public static class Exports
{
    /// <summary>What tuft calls, once it's loaded this.</summary>
    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    public static Raw.Reflector Open() => Reflector.From(new Reflection()).Raw;
}

sealed unsafe class Reflection : IReflector
{
    const BindingFlags All = BindingFlags.DeclaredOnly | BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Instance | BindingFlags.Static;

    sealed class Handle(nint value)
    {
        public readonly nint Value = value;
    }

    // Weak, so an assembly that's unloaded goes
    readonly ConditionalWeakTable<Assembly, Handle> assemblies = new();
    // What declares each field and method, which looking one up by its handle needs for generic types
    readonly Dictionary<nint, nint> fieldOwners = new();
    readonly Dictionary<nint, nint> methodOwners = new();
    readonly object gate = new();

    nuint HandleOf(Assembly a) =>
        (nuint)assemblies.GetValue(a, static x => new Handle(GCHandle.ToIntPtr(GCHandle.Alloc(x, GCHandleType.Weak)))).Value;

    static Assembly? AssemblyOf(nuint h) => h == 0 ? null : GCHandle.FromIntPtr((nint)h).Target as Assembly;

    static Type? TypeOf(nuint h) => h == 0 ? null : Type.GetTypeFromHandle(RuntimeTypeHandle.FromIntPtr((nint)h));

    static nuint HandleOf(Type? t)
    {
        if (t == null) return 0;
        try
        {
            return (nuint)t.TypeHandle.Value;
        }
        catch (NotSupportedException)
        {
            return 0;
        }
    }

    FieldInfo? FieldOf(nuint h)
    {
        if (h == 0) return null;
        nint owner;
        lock (gate)
        {
            if (!fieldOwners.TryGetValue((nint)h, out owner)) return null;
        }
        return FieldInfo.GetFieldFromHandle(RuntimeFieldHandle.FromIntPtr((nint)h), RuntimeTypeHandle.FromIntPtr(owner));
    }

    MethodBase? MethodOf(nuint h)
    {
        if (h == 0) return null;
        nint owner;
        lock (gate)
        {
            if (!methodOwners.TryGetValue((nint)h, out owner)) return null;
        }
        return MethodBase.GetMethodFromHandle(RuntimeMethodHandle.FromIntPtr((nint)h), RuntimeTypeHandle.FromIntPtr(owner));
    }

    public nuint[] Assemblies() => AppDomain.CurrentDomain.GetAssemblies().Select(HandleOf).ToArray();

    public string AssemblyName(nuint assembly) => AssemblyOf(assembly) is { } a ? (a.GetName().Name ?? "") + ".dll" : "";

    public nuint[] Types(nuint assembly)
    {
        if (AssemblyOf(assembly) is not { } a) return [];
        Type?[] types;
        try
        {
            types = a.GetTypes();
        }
        catch (ReflectionTypeLoadException e)
        {
            // Some couldn't load, like ones from an assembly that's missing. The rest still list.
            types = e.Types;
        }
        return types.Select(HandleOf).Where(h => h != 0).ToArray();
    }

    public nuint FindType(nuint assembly, string ns, string name) =>
        AssemblyOf(assembly) is { } a ? HandleOf(a.GetType(ns.Length > 0 ? $"{ns}.{name}" : name, false)) : 0;

    public string TypeName(nuint type) => TypeOf(type)?.Name ?? "";

    public string TypeNamespace(nuint type) => TypeOf(type) is { IsNested: false } t ? t.Namespace ?? "" : "";

    public string TypeFullName(nuint type) => TypeOf(type) is { } t ? FullName(t) : "";

    static string FullName(Type t)
    {
        if (t.IsByRef) return FullName(t.GetElementType()!) + "&";
        if (t.IsPointer) return FullName(t.GetElementType()!) + "*";
        if (t.IsArray) return FullName(t.GetElementType()!) + (t.IsSZArray ? "[]" : $"[{new string(',', t.GetArrayRank() - 1)}]");
        if (t.IsGenericParameter) return t.Name;
        var name = t.IsNested ? $"{FullName(t.DeclaringType!)}.{Bare(t.Name)}" : string.IsNullOrEmpty(t.Namespace) ? Bare(t.Name) : $"{t.Namespace}.{Bare(t.Name)}";
        // A nested type's arguments start with its outer type's, which are shown there
        var args = t.IsGenericType ? t.GetGenericArguments().Skip(t.IsNested ? t.DeclaringType!.GetGenericArguments().Length : 0).ToArray() : [];
        if (args.Length > 0) name += $"<{string.Join(",", args.Select(FullName))}>";
        return name;
    }

    // Without its generic arity, like List for List`1
    static string Bare(string name) => name.IndexOf('`') is var at && at >= 0 ? name[..at] : name;

    public nuint TypeParent(nuint type) => HandleOf(TypeOf(type)?.BaseType);

    public nuint TypeOuter(nuint type) => TypeOf(type) is { IsNested: true } t ? HandleOf(t.DeclaringType) : 0;

    public nuint TypeAssembly(nuint type) => TypeOf(type) is { } t ? HandleOf(t.Assembly) : 0;

    public int InstanceSize(nuint type)
    {
        if (TypeOf(type) is not { } t || t.IsInterface || t.IsGenericParameter) return 0;
        if (t.IsValueType) return t.ContainsGenericParameters ? 0 : sizeof(nint) + RuntimeHelpers.SizeOf(t.TypeHandle);
        // A MethodTable starts with its flags then its base size, which counts the header before the
        // object and the MethodTable pointer at its start. The same since .NET Core 1.
        var baseSize = *(uint*)((byte*)type + 4);
        return (int)baseSize - sizeof(nint);
    }

    public bool IsValueType(nuint type) => TypeOf(type)?.IsValueType ?? false;

    public bool IsEnum(nuint type) => TypeOf(type)?.IsEnum ?? false;

    public nuint EnumBase(nuint type) => TypeOf(type) is { IsEnum: true } t ? HandleOf(Enum.GetUnderlyingType(t)) : 0;

    public byte ElementType(nuint type) => TypeOf(type) is { } t ? KindOf(t) : (byte)0;

    static byte KindOf(Type t)
    {
        if (t.IsByRef) return 0x10;
        if (t.IsPointer) return 0x0f;
        if (t.IsFunctionPointer) return 0x1b;
        if (t.IsArray) return t.IsSZArray ? (byte)0x1d : (byte)0x14;
        if (t.IsGenericParameter) return t.DeclaringMethod != null ? (byte)0x1e : (byte)0x13;
        if (t == typeof(void)) return 0x01;
        if (t == typeof(string)) return 0x0e;
        if (t == typeof(object)) return 0x1c;
        if (t == typeof(nint)) return 0x18;
        if (t == typeof(nuint)) return 0x19;
        if (t == typeof(TypedReference)) return 0x16;
        if (!t.IsEnum)
        {
            switch (Type.GetTypeCode(t))
            {
                case TypeCode.Boolean: return 0x02;
                case TypeCode.Char: return 0x03;
                case TypeCode.SByte: return 0x04;
                case TypeCode.Byte: return 0x05;
                case TypeCode.Int16: return 0x06;
                case TypeCode.UInt16: return 0x07;
                case TypeCode.Int32: return 0x08;
                case TypeCode.UInt32: return 0x09;
                case TypeCode.Int64: return 0x0a;
                case TypeCode.UInt64: return 0x0b;
                case TypeCode.Single: return 0x0c;
                case TypeCode.Double: return 0x0d;
            }
        }
        if (t.IsConstructedGenericType) return 0x15;
        return t.IsValueType ? (byte)0x11 : (byte)0x12;
    }

    public nuint[] Fields(nuint type)
    {
        if (TypeOf(type) is not { } t) return [];
        var list = new List<nuint>();
        foreach (var f in t.GetFields(All))
        {
            nint h;
            try
            {
                h = f.FieldHandle.Value;
            }
            catch (NotSupportedException)
            {
                // A const, which has no handle
                continue;
            }
            lock (gate) fieldOwners[h] = (nint)type;
            list.Add((nuint)h);
        }
        return list.ToArray();
    }

    public string FieldName(nuint field) => FieldOf(field)?.Name ?? "";

    public nuint FieldType(nuint field) => HandleOf(FieldOf(field)?.FieldType);

    public nuint FieldOwner(nuint field) => HandleOf(FieldOf(field)?.DeclaringType);

    public uint FieldFlags(nuint field) => (uint)(FieldOf(field)?.Attributes ?? 0);

    public nint FieldOffset(nuint field)
    {
        if (FieldOf(field) is not { IsStatic: false }) return -1;
        // A FieldDesc is its MethodTable pointer, a word of flags, then 27 bits of offset from where
        // the fields start, right after the object's MethodTable pointer. The same since .NET Core 1.
        var offset = *(uint*)((byte*)field + sizeof(nint) + 4) & 0x7FFFFFF;
        // The top few are markers for fields that aren't placed yet
        if (offset >= 0x7FFFFFB) return -1;
        return (nint)offset + sizeof(nint);
    }

    public nuint StaticAddress(nuint field)
    {
        if (FieldOf(field) is not { IsStatic: true, IsLiteral: false } f || f.DeclaringType is not { } owner) return 0;
        if (owner.ContainsGenericParameters || f.IsDefined(typeof(ThreadStaticAttribute), false)) return 0;
        RuntimeHelpers.RunClassConstructor(owner.TypeHandle);
        // There's no API for where statics are, so this asks the JIT, like C# taking &Type.field would
        var get = new DynamicMethod("", typeof(nuint), Type.EmptyTypes, owner.Module, true);
        var il = get.GetILGenerator();
        il.Emit(OpCodes.Ldsflda, f);
        il.Emit(OpCodes.Conv_U);
        il.Emit(OpCodes.Ret);
        return get.CreateDelegate<Func<nuint>>()();
    }

    public nuint[] Methods(nuint type)
    {
        if (TypeOf(type) is not { } t) return [];
        var list = new List<nuint>();
        foreach (var m in t.GetMethods(All).Cast<MethodBase>().Concat(t.GetConstructors(All)))
        {
            var h = m.MethodHandle.Value;
            lock (gate) methodOwners[h] = (nint)type;
            list.Add((nuint)h);
        }
        return list.ToArray();
    }

    public string MethodName(nuint method) => MethodOf(method)?.Name ?? "";

    public nuint[] ParamTypes(nuint method) => MethodOf(method) is { } m ? m.GetParameters().Select(p => HandleOf(p.ParameterType)).ToArray() : [];

    public nuint ReturnType(nuint method) => MethodOf(method) switch
    {
        MethodInfo m => HandleOf(m.ReturnType),
        ConstructorInfo => HandleOf(typeof(void)),
        _ => 0,
    };

    public nuint MethodOwner(nuint method) => HandleOf(MethodOf(method)?.DeclaringType);

    public uint MethodFlags(nuint method) => (uint)(MethodOf(method)?.Attributes ?? 0);

    public uint MethodImplFlags(nuint method) => (uint)(MethodOf(method)?.MethodImplementationFlags ?? 0);

    public nuint MethodPointer(nuint method)
    {
        if (MethodOf(method) is not { } m || m.IsAbstract || m.ContainsGenericParameters) return 0;
        RuntimeHelpers.PrepareMethod(m.MethodHandle);
        return (nuint)m.MethodHandle.GetFunctionPointer();
    }
}
