//! `same-file <built> <kept>`: fails unless both files have the same bytes. For `zig build coreclr-check`.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    var args = try init.minimal.args.iterateAllocator(a);
    _ = args.skip();
    const built_path = args.next() orelse return error.Usage;
    const kept_path = args.next() orelse return error.Usage;
    const cwd = std.Io.Dir.cwd();
    const built = try cwd.readFileAlloc(init.io, built_path, a, .limited(64 << 20));
    const kept = cwd.readFileAlloc(init.io, kept_path, a, .limited(64 << 20)) catch "";
    if (std.mem.eql(u8, built, kept)) return;
    std.debug.print("{s} is out of date. Write it again with `zig build coreclr`.\n", .{kept_path});
    std.process.exit(1);
}
