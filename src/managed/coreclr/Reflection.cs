// The C# tuft loads into a game's CoreCLR to read it, since CoreCLR has no reflection API for
// native code. reflect.sal says what each call does. Never keeps a type, field or method alive, so
// a mod loader can still unload what it loaded. Objects are their addresses, see Keep.

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Reflection.Emit;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Runtime.Loader;
using System.Threading;

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

    // Mod loaders like Dalamud unload plugins, which frees their types, fields and methods, and the
    // runtime can put new ones where they were. So nothing here keeps a handle that could be freed
    // without knowing it's gone, and `changes` goes up when tuft's names for handles could be wrong.

    // Goes up when a load context unloads, or a handle comes back meaning something else. Never freed,
    // since tuft reads it.
    static readonly int* changes = (int*)NativeMemory.AllocZeroed(sizeof(int));

    static void Changed() => Interlocked.Increment(ref *changes);

    public nuint Changes() => (nuint)changes;

    sealed class Id(nuint value)
    {
        public readonly nuint Value = value;
    }

    // Goes up once the load context it's kept for is collected, which is when its handles can be reused
    sealed class Watch
    {
        ~Watch() => Changed();
    }

    // Shared by every Reflection, since joining again opens another. Assemblies are ids that are never used again, so an unloaded one's can't come to mean another
    static readonly ConditionalWeakTable<Assembly, Id> assemblyIds = new();
    static readonly Dictionary<nuint, WeakReference<Assembly>> assembliesById = new();
    static nuint lastAssembly;
    static readonly ConditionalWeakTable<AssemblyLoadContext, Watch> watched = new();
    // Types that can be unloaded, by handle. Kept once they're gone, so a stale handle gives nothing
    static readonly Dictionary<nint, WeakReference<Type>> collectible = new();
    // What declares each field and method, which looking one up by its handle needs for generic types
    static readonly Dictionary<nint, WeakReference<Type>> fieldOwners = new();
    static readonly Dictionary<nint, WeakReference<Type>> methodOwners = new();
    static readonly object gate = new();

    static nuint HandleOf(Assembly a)
    {
        lock (gate)
        {
            if (assemblyIds.TryGetValue(a, out var id)) return id.Value;
            id = new Id(++lastAssembly);
            assemblyIds.Add(a, id);
            assembliesById[id.Value] = new(a);
            if (a.IsCollectible && AssemblyLoadContext.GetLoadContext(a) is { } alc && !watched.TryGetValue(alc, out _))
            {
                watched.Add(alc, new Watch());
                alc.Unloading += static _ => Changed();
            }
            return id.Value;
        }
    }

    static Assembly? AssemblyOf(nuint h)
    {
        lock (gate) return assembliesById.TryGetValue(h, out var w) && w.TryGetTarget(out var a) ? a : null;
    }

    static Type? TypeOf(nuint h)
    {
        if (h == 0) return null;
        lock (gate)
        {
            if (collectible.TryGetValue((nint)h, out var w)) return w.TryGetTarget(out var t) ? t : null;
        }
        return Type.GetTypeFromHandle(RuntimeTypeHandle.FromIntPtr((nint)h));
    }

    static nuint HandleOf(Type? t)
    {
        if (t == null) return 0;
        nint h;
        try
        {
            h = t.TypeHandle.Value;
        }
        catch (NotSupportedException)
        {
            return 0;
        }
        if (t.IsCollectible) lock (gate) Remember(collectible, h, t);
        return (nuint)h;
    }

    // Under gate. A handle whose last one's gone has been reused, so what tuft has for it is wrong.
    static void Remember(Dictionary<nint, WeakReference<Type>> into, nint h, Type t)
    {
        if (into.TryGetValue(h, out var w))
        {
            if (!w.TryGetTarget(out var was)) Changed();
            else if (ReferenceEquals(was, t)) return;
        }
        into[h] = new(t);
    }

    // Null once its type's gone, which a stale handle would need to be looked up
    static RuntimeTypeHandle? OwnerOf(Dictionary<nint, WeakReference<Type>> owners, nuint h)
    {
        if (h == 0) return null;
        lock (gate) return owners.TryGetValue((nint)h, out var w) && w.TryGetTarget(out var t) ? t.TypeHandle : null;
    }

    static FieldInfo? FieldOf(nuint h) =>
        OwnerOf(fieldOwners, h) is { } owner ? FieldInfo.GetFieldFromHandle(RuntimeFieldHandle.FromIntPtr((nint)h), owner) : null;

    static MethodBase? MethodOf(nuint h) =>
        OwnerOf(methodOwners, h) is { } owner ? MethodBase.GetMethodFromHandle(RuntimeMethodHandle.FromIntPtr((nint)h), owner) : null;

    public nuint[] Assemblies()
    {
        var all = AppDomain.CurrentDomain.GetAssemblies().Select(HandleOf).ToArray();
        // Ids are never reused, and a field or method with no owner gives nothing, so what's gone can
        // just go. Not collectible types, whose handles would be looked up again if they went.
        lock (gate)
        {
            foreach (var (id, w) in assembliesById)
            {
                if (!w.TryGetTarget(out _)) assembliesById.Remove(id);
            }
            Prune(fieldOwners);
            Prune(methodOwners);
        }
        return all;
    }

    static void Prune(Dictionary<nint, WeakReference<Type>> owners)
    {
        foreach (var (h, w) in owners)
        {
            if (!w.TryGetTarget(out _)) owners.Remove(h);
        }
    }

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
            lock (gate) Remember(fieldOwners, h, t);
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
            lock (gate) Remember(methodOwners, h, t);
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

    // Objects

    // What's been handed out lately, so it isn't collected before the caller holds it
    readonly object?[] recent = new object?[64];
    int nextRecent;

    nuint Keep(object? o)
    {
        if (o == null) return 0;
        lock (gate) recent[nextRecent++ % recent.Length] = o;
        return AddressOf(o);
    }

    static nuint AddressOf(object o) => Unsafe.As<object, nuint>(ref o);

    static object? ObjectAt(nuint address) => address == 0 ? null : Unsafe.As<nuint, object>(ref address);

    // A boxed value's bytes start right after its MethodTable. Never made, only laid over a box.
    sealed class Boxed
    {
#pragma warning disable CS0649
        public byte Data;
#pragma warning restore CS0649
    }

    static object Box(Type t, nuint at) =>
        at == 0 ? RuntimeHelpers.GetUninitializedObject(t) : RuntimeHelpers.Box(ref *(byte*)at, t.TypeHandle)!;

    static void Unbox(Type t, object boxed, nuint into) =>
        Unsafe.CopyBlockUnaligned(ref *(byte*)into, ref Unsafe.As<Boxed>(boxed).Data, (uint)RuntimeHelpers.SizeOf(t.TypeHandle));

    /// <summary>An argument or field value from native code: a pointer to a value, or an object.</summary>
    static object? ValueFrom(Type t, nuint at)
    {
        if (t.IsByRef)
        {
            var inner = t.GetElementType()!;
            return inner.IsValueType ? Box(inner, at) : ObjectAt(at == 0 ? 0 : *(nuint*)at);
        }
        if (t.IsPointer) return Pointer.Box(at == 0 ? null : *(void**)at, t);
        return t.IsValueType ? Box(t, at) : ObjectAt(at);
    }

    public uint TypeSize(nuint type) => TypeOf(type) is { IsValueType: true, ContainsGenericParameters: false } t ? (uint)RuntimeHelpers.SizeOf(t.TypeHandle) : (uint)sizeof(nint);

    public nuint Invoke(nuint method, nuint self, nuint args, ref nuint exception)
    {
        exception = 0;
        if (MethodOf(method) is not { } m || m.DeclaringType is not { } owner) return 0;
        var ps = m.GetParameters();
        var argv = (nuint*)args;
        var values = new object?[ps.Length];
        for (var i = 0; i < ps.Length; i++) values[i] = ValueFrom(ps[i].ParameterType, argv == null ? 0 : argv[i]);
        var target = m.IsStatic ? null : owner.IsValueType ? Box(owner, self) : ObjectAt(self);
        object? result;
        try
        {
            result = m is ConstructorInfo ctor && self == 0
                ? ctor.Invoke(BindingFlags.DoNotWrapExceptions, null, values, null)
                : m.Invoke(target, BindingFlags.DoNotWrapExceptions, null, values, null);
        }
        catch (Exception e)
        {
            exception = Keep(e);
            return 0;
        }
        // What it changed through ref parameters and this goes back where it came from
        for (var i = 0; i < ps.Length; i++)
        {
            var t = ps[i].ParameterType;
            if (!t.IsByRef || argv == null || argv[i] == 0) continue;
            var inner = t.GetElementType()!;
            if (inner.IsValueType) Unbox(inner, values[i]!, argv[i]);
            else *(nuint*)argv[i] = Keep(values[i]);
        }
        if (target != null && owner.IsValueType && self != 0) Unbox(owner, target, self);
        return Keep(result);
    }

    public void SetFieldValue(nuint field, nuint obj, nuint value)
    {
        if (FieldOf(field) is not { } f) return;
        f.SetValue(f.IsStatic ? null : ObjectAt(obj), ValueFrom(f.FieldType, value));
    }

    public nuint NewString(string text) => Keep(text);

    public nuint NewHandle(nuint obj, bool pinned)
    {
        try
        {
            return (nuint)GCHandle.ToIntPtr(GCHandle.Alloc(ObjectAt(obj), pinned ? GCHandleType.Pinned : GCHandleType.Normal));
        }
        catch (ArgumentException)
        {
            // Only arrays and strings of plain values can be pinned
            return 0;
        }
    }

    public nuint HandleTarget(nuint handle) => handle == 0 ? 0 : Keep(GCHandle.FromIntPtr((nint)handle).Target);

    public void FreeHandle(nuint handle)
    {
        if (handle != 0) GCHandle.FromIntPtr((nint)handle).Free();
    }

    public nuint TypeObject(nuint type) => Keep(TypeOf(type));

    public nuint NewArray(nuint element, nuint length) => TypeOf(element) is { } t ? Keep(Array.CreateInstance(t, checked((int)length))) : 0;

    // Isolated assemblies

    sealed class Isolated : AssemblyLoadContext
    {
        readonly AssemblyDependencyResolver? deps;
        public Assembly? Main;

        public Isolated(string path) : base(Path.GetFileNameWithoutExtension(path), isCollectible: true)
        {
            // Without a .deps.json it finds nothing, and what's shared comes from the default context
            try
            {
                deps = new AssemblyDependencyResolver(path);
            }
            catch (InvalidOperationException) { }
        }

        public Assembly LoadRead(string path)
        {
            using var dll = File.OpenRead(path);
            var pdb = Path.ChangeExtension(path, ".pdb");
            if (!File.Exists(pdb)) return LoadFromStream(dll);
            using var symbols = File.OpenRead(pdb);
            return LoadFromStream(dll, symbols);
        }

        protected override Assembly? Load(AssemblyName name) =>
            deps?.ResolveAssemblyToPath(name) is { } p ? LoadRead(p) : null;

        protected override nint LoadUnmanagedDll(string name) =>
            deps?.ResolveUnmanagedDllToPath(name) is { } p ? LoadUnmanagedDllFromPath(p) : 0;
    }

    static readonly Dictionary<nuint, Isolated> isolated = new();
    static nuint lastIsolated;
    static string loadError = "";

    public string LoadError()
    {
        lock (gate) return loadError;
    }

    public nuint LoadIsolated(string path)
    {
        try
        {
            var context = new Isolated(path);
            context.Main = context.LoadRead(path);
            lock (gate)
            {
                isolated[++lastIsolated] = context;
                return lastIsolated;
            }
        }
        catch (Exception e)
        {
            lock (gate) loadError = e.Message;
            return 0;
        }
    }

    public nuint IsolatedFunction(nuint context, string type, string method)
    {
        Isolated? c;
        lock (gate)
        {
            if (!isolated.TryGetValue(context, out c)) return 0;
        }
        var m = c.Main?.GetType(type, false)?.GetMethod(method, BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Static);
        return m == null ? 0 : (nuint)m.MethodHandle.GetFunctionPointer();
    }

    public void UnloadIsolated(nuint context)
    {
        Isolated? c;
        lock (gate)
        {
            if (!isolated.Remove(context, out c)) return;
        }
        c.Main = null;
        c.Unload();
    }
}
