//! What `[Sig("48 8B 05", Offset(3), Rip, Follow, Rel32, FirstMatch, Sources(Live, Disk), Module("x.dll"),
//! Section(".text"))]` says, as a `mem.Sig`. `Module` and `Section` can also be annotations of their
//! own. `[VirtualTable]` reads the same way.

const std = @import("std");
const mem = @import("tuft_mem");
const sal = @import("salamander_schema").Schema;

pub const names = [_][]const u8{ "Sig", "Module", "Section", "VirtualTable" };

pub const max_steps = 8;

pub const Error = error{ NoPattern, BadStep, TooManySteps, BadModule, BadSection, BadSources };

/// The one in `namespace`, or in any if it's null. Null if there's none.
pub fn find(annotations: []const sal.Annotation, namespace: ?[]const u8, name: []const u8) ?*const sal.Annotation {
    for (annotations) |*a| {
        if (namespace) |ns| if (!std.mem.eql(u8, a.namespace, ns)) continue;
        if (std.mem.eql(u8, a.name, name)) return a;
    }
    return null;
}

/// `which` is `Sig` or `VirtualTable`. Its steps go in `steps`, which has to outlive it.
pub fn of(annotations: []const sal.Annotation, namespace: ?[]const u8, which: []const u8, steps: *[max_steps]mem.Sig.Step) Error!?mem.Sig {
    const a = find(annotations, namespace, which) orelse return null;
    if (a.args.len == 0 or a.args[0] != .string) return error.NoPattern;
    var sig: mem.Sig = .{ .pattern = a.args[0].string };
    var len: usize = 0;
    for (a.args[1..]) |arg| {
        const step: ?mem.Sig.Step = switch (arg) {
            .ident => |n| if (std.mem.eql(u8, n, "Rip")) .rip else if (std.mem.eql(u8, n, "Follow")) .follow else if (std.mem.eql(u8, n, "Rel32")) .rel32 else if (std.mem.eql(u8, n, "FirstMatch")) blk: {
                sig.first_match = true;
                break :blk null;
            } else return error.BadStep,
            .call => |c| if (std.mem.eql(u8, c.name, "Offset")) blk: {
                if (c.args.len != 1 or c.args[0] != .int) return error.BadStep;
                break :blk .{ .offset = std.math.cast(isize, c.args[0].int) orelse return error.BadStep };
            } else if (std.mem.eql(u8, c.name, "Sources")) blk: {
                var sources: mem.originals.Sources = .{ .live = false, .snapshot = false, .disk = false };
                for (c.args) |s| {
                    if (s != .ident) return error.BadSources;
                    sources.set(mem.originals.parseLabel(s.ident) orelse return error.BadSources, true);
                }
                if (sources.none()) return error.BadSources;
                sig.sources = sources;
                break :blk null;
            } else if (std.mem.eql(u8, c.name, "Module")) blk: {
                sig.module = try oneString(c.args, error.BadModule);
                break :blk null;
            } else if (std.mem.eql(u8, c.name, "Section")) blk: {
                sig.section = try oneString(c.args, error.BadSection);
                break :blk null;
            } else return error.BadStep,
            else => return error.BadStep,
        };
        if (step) |st| {
            if (len == max_steps) return error.TooManySteps;
            steps[len] = st;
            len += 1;
        }
    }
    if (find(annotations, namespace, "Module")) |m| sig.module = try oneString(m.args, error.BadModule);
    if (find(annotations, namespace, "Section")) |m| sig.section = try oneString(m.args, error.BadSection);
    sig.resolve = steps[0..len];
    return sig;
}

/// Like `of`, with its steps in `arena`.
pub fn alloc(arena: std.mem.Allocator, annotations: []const sal.Annotation, namespace: ?[]const u8, which: []const u8) (Error || error{OutOfMemory})!?mem.Sig {
    var steps: [max_steps]mem.Sig.Step = undefined;
    var sig = try of(annotations, namespace, which, &steps) orelse return null;
    sig.resolve = try arena.dupe(mem.Sig.Step, sig.resolve);
    return sig;
}

/// What to say about each error, after where it is.
pub fn explain(err: Error) []const u8 {
    return switch (err) {
        error.NoPattern => "it starts with its bytes, like [Sig(\"48 8B 05 ?? ?? ?? ??\", Offset(3), Rip)]",
        error.BadStep => "after the bytes come Offset(n), Rip, Follow, Rel32, FirstMatch, Sources(Live, Snapshot, Disk), Module(\"x.dll\") or Section(\".text\")",
        error.TooManySteps => "that's more steps than fit",
        error.BadModule => "Module takes a name, like Module(\"game.dll\")",
        error.BadSection => "Section takes a name, like Section(\".text\")",
        error.BadSources => "Sources takes some of Live, Snapshot and Disk, like Sources(Live, Disk)",
    };
}

fn oneString(args: []const sal.Arg, err: Error) Error![]const u8 {
    if (args.len != 1 or args[0] != .string) return err;
    return args[0].string;
}
