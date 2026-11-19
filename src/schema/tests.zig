const std = @import("std");
const testing = std.testing;

const mem = @import("tuft_mem");
const Memory = mem.Memory;
const Address = mem.Address;
const salamander = @import("salamander_schema");
const Schema = salamander.Schema;
const Ref = @import("Ref.zig");
const sigs = @import("sigs.zig");
const sigTarget = @import("sig_target.zig").sigTarget;

const source =
    \\struct Vec3 { f32 x; f32 y; f32 z; }
    \\
    \\[Size(0x20)]
    \\struct Entity {
    \\    [0x8] u32 id;
    \\    [0x10] Vec3 pos;
    \\    [Virtual(2)] void update(f32 dt);
    \\    [Virtual(5)] void describe();
    \\    [game.Sig("B8 0D F0 70 1A", Offset(5)), game.Section(".text")] void spawn();
    \\}
    \\
    \\// Not really its vtable, it finds `sigTarget`
    \\[Size(0x100), game.VirtualTable("B8 0D F0 70 1A E8", Offset(13), Rip)]
    \\struct Player : Entity {
    \\    utf8[16] name;
    \\    utf16* title;
    \\    [0x38] f32 health;
    \\    Job job;
    \\    [0x40] Flags flags;
    \\    Stat stat;
    \\    [0x48] Player* target;
    \\    [0x50] Player*[4] party;
    \\    [0x71] u32 odd;
    \\    i16 level;
    \\    [0x78] u8 relation { bool party; bool alliance; [Bit(6)] bool drawn; }
    \\    [Virtual(9)] void attack();
    \\    [game.Sig("B8 0D F0 70 1A"), Thiscall] f32 heal(f32 amount, Job job);
    \\    [game.Sig("B8 0D F0 70 1A")] static i32 total(u32 n);
    \\    [game.Sig("B8 0D F0 70 1A E8", Offset(13), Rip)] static u32 count;
    \\}
    \\
    \\enum Job : u8 { warrior = 1, mage, thief }
    \\
    \\bitfield Flags : u32 {
    \\    bool alive;
    \\    [Bit(4)] u8 level;
    \\    Job job : 4;
    \\}
    \\
    \\union Stat {
    \\    i32 int;
    \\    f32 float;
    \\}
    \\
    \\// These find `sigTarget`
    \\[game.Sig("B8 0D F0 70 1A E8", Offset(13), Rip)] static u32 answer;
    \\[game.Sig("B8 0D F0 70 1A E8", Offset(13), Rip)] static Player* player;
    \\[game.Sig("B8 0D F0 70 1A E8 ?? ?? ?? ??", Offset(5), Rip, Follow)] void landing();
    \\[game.Sig("B8 0D F0 70 1A")] i32 entry(u32 a, u32 b);
;

fn parsed(text: []const u8, pointer_size: u8) !salamander.Parsed {
    var diag: Schema.Diagnostic = .{};
    return salamander.parse(testing.allocator, text, .{ .pointer_size = pointer_size, .any_namespace = true }, &diag) catch |err| {
        std.debug.print("{s}\n", .{diag.message()});
        return err;
    };
}

/// Two players laid out like `source` says, and a vtable.
const World = struct {
    bytes: [2][0x100]u8 align(16) = @splat(@splat(0)),
    vtable: [10]usize = @splat(0),
    title: [6:0]u16 = .{ 'H', 'e', 'r', 0xD83D, 0xDE00, 'o' },

    fn player(self: *World, i: usize) usize {
        return @intFromPtr(&self.bytes[i]);
    }

    fn put(self: *World, i: usize, comptime T: type, offset: usize, value: T) void {
        @memcpy(self.bytes[i][offset..][0..@sizeOf(T)], std.mem.asBytes(&value));
    }

    fn get(self: *World, i: usize, comptime T: type, offset: usize) T {
        return std.mem.bytesToValue(T, self.bytes[i][offset..][0..@sizeOf(T)]);
    }

    fn setUp(self: *World) void {
        self.put(0, usize, 0, @intFromPtr(&self.vtable));
        self.put(0, f32, 0x10, 1);
        self.put(0, f32, 0x14, 2);
        @memcpy(self.bytes[0][0x20..][0..5], "Alice");
        self.put(0, usize, 0x30, @intFromPtr(&self.title));
        self.put(0, f32, 0x38, 87.5);
        self.put(0, u8, 0x3C, 2);
        // alive, level 42, thief
        self.put(0, u32, 0x40, 1 | (42 << 4) | (3 << 12));
        self.put(0, f32, 0x44, 1.5);
        self.put(0, usize, 0x48, self.player(1));
        self.put(0, usize, 0x50 + 2 * @sizeOf(usize), self.player(1));
        self.put(0, u32, 0x71, 0xDEADBEEF);
        self.put(0, i16, 0x76, -7);
        self.put(1, u32, 0x8, 2);
        self.put(1, f32, 0x38, 12);
        self.put(1, usize, 0x48, self.player(0));
        self.vtable[9] = 0x1234;
    }
};

test "refs by name" {
    var p = try parsed(source, @sizeOf(usize));
    defer p.deinit();
    var world: World = .{};
    world.setUp();
    const a = Ref.of(&p.schema, "Player", world.player(0));
    try testing.expectEqual(87.5, (try a.field("health").load()).float);
    try testing.expectEqual(2, (try a.path("pos.y").load()).float);
    try testing.expectEqual(2, (try a.path("target.id").load()).uint);
    try testing.expectEqual(12, (try a.path("party[2].health").load()).float);
    try testing.expectEqual(87.5, (try a.path("target.target.*.health").load()).float);
    try testing.expectEqual(-7, (try a.field("level").load()).int);
    try testing.expectEqual(0xDEADBEEF, (try a.field("odd").load()).uint);
    try testing.expectEqual(1.5, (try a.path("stat.float").load()).float);

    const job = (try a.field("job").load()).@"enum";
    try testing.expectEqual(2, job.value);
    try testing.expectEqualStrings("mage", job.name.?);

    try testing.expect((try a.path("flags.alive").load()).bool);
    try testing.expectEqual(42, (try a.path("flags.level").load()).uint);
    try testing.expectEqualStrings("thief", (try a.path("flags.job").load()).@"enum".name.?);

    try a.path("flags.level").store(.{ .uint = 200 });
    try a.path("flags.alive").store(.{ .bool = false });
    try testing.expectEqual((200 << 4) | (3 << 12), world.get(0, u32, 0x40));
    try testing.expectError(error.Overflow, a.path("flags.level").store(.{ .uint = 256 }));

    try a.path("target.health").store(.{ .int = 3 });
    try testing.expectEqual(3, world.get(1, f32, 0x38));
    try a.field("level").store(.{ .int = -300 });
    try testing.expectEqual(-300, world.get(0, i16, 0x76));
    try testing.expectError(error.Overflow, a.field("level").store(.{ .int = 40000 }));
    try a.field("job").store(.{ .@"enum" = .{ .value = 1 } });
    try testing.expectEqual(1, world.get(0, u8, 0x3C));

    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("Alice", try a.field("name").text(&buf));
    try testing.expectEqualStrings("Her\u{1F600}o", try a.field("title").text(&buf));
    try testing.expectEqualStrings("He", try a.field("title").text(buf[0..2]));
    try testing.expectError(error.NotText, a.field("health").text(&buf));

    try testing.expectEqual(0x1234, try a.vfunc("attack").unwrap());
    try testing.expectError(error.NoSuchFunction, a.vfunc("nope").unwrap());
    try testing.expectError(error.NoSuchField, a.path("target.nope.x").load());
    try testing.expectError(error.NullPointer, a.path("party[1].health").load());
    try testing.expectError(error.OutOfBounds, a.path("party[4]").load());
    try testing.expectError(error.NotAValue, a.field("pos").load());
    try testing.expectError(error.InvalidPath, a.path("party[x]").load());

    try a.path("relation.alliance").store(.{ .bool = true });
    try a.path("relation.drawn").store(.{ .bool = true });
    try testing.expectEqual(0x42, world.get(0, u8, 0x78));
    try testing.expect(!(try a.path("relation.party").load()).bool);
}

/// Fake 32-bit game memory at 0x1000.
const Dump = struct {
    bytes: [0x200]u8 = @splat(0),
    const base = 0x1000;

    fn read(context: ?*anyopaque, address: usize, out: []u8) Memory.Error!void {
        const self: *Dump = @ptrCast(@alignCast(context));
        if (address < base or address - base + out.len > self.bytes.len) return error.Unreadable;
        @memcpy(out, self.bytes[address - base ..][0..out.len]);
    }

    fn write(context: ?*anyopaque, address: usize, bytes: []const u8) Memory.Error!void {
        const self: *Dump = @ptrCast(@alignCast(context));
        if (address < base or address - base + bytes.len > self.bytes.len) return error.Unwritable;
        @memcpy(self.bytes[address - base ..][0..bytes.len], bytes);
    }

    fn memory(self: *Dump) Memory {
        return .{ .context = self, .vtable = &.{ .read = read, .write = write } };
    }
};

test "refs in 32-bit memory" {
    var p = try parsed("struct Node { u16 value; Node* next; cstring name; }", 4);
    defer p.deinit();
    try testing.expectEqual(12, p.schema.findType("Node").?.size);

    var dump: Dump = .{};
    std.mem.writeInt(u16, dump.bytes[0..2], 7, .little);
    std.mem.writeInt(u32, dump.bytes[4..8], 0x1010, .little);
    std.mem.writeInt(u32, dump.bytes[8..12], 0x1100, .little);
    std.mem.writeInt(u16, dump.bytes[0x10..0x12], 9, .little);
    std.mem.writeInt(u32, dump.bytes[0x14..0x18], 0x9000, .little);
    @memcpy(dump.bytes[0x100..0x104], "abc\x00");

    const node = Ref.of(&p.schema, "Node", Address.fromMemory(dump.memory(), 0x1000));
    try testing.expectEqual(9, (try node.path("next.value").load()).uint);
    try testing.expectEqual(0x1010, (try node.field("next").load()).pointer);
    var buf: [8]u8 = undefined;
    try testing.expectEqualStrings("abc", try node.field("name").text(&buf));
    try testing.expectError(error.InvalidPointer, node.path("next.next.value").load());
    try testing.expectError(error.NullPointer, node.path("next.name.*").load());
    try node.path("next.value").store(.{ .uint = 0xBEEF });
    try testing.expectEqual(0xBEEF, std.mem.readInt(u16, dump.bytes[0x10..0x12], .little));
    try testing.expectError(error.Overflow, node.field("next").store(.{ .pointer = 0x1_0000_0000 }));
}

test "typed in" {
    var p = try parsed(source, @sizeOf(usize));
    defer p.deinit();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var world: World = .{};
    world.setUp();
    const party = try salamander.parseType(arena.allocator(), "Player*[4]", null);
    const r = Ref.at(&p.schema, party, world.player(0) + 0x50);
    try testing.expectEqual(4 * @sizeOf(usize), try r.size());
    try testing.expectEqual(12, (try r.path("[2].health").load()).float);
}

test "statics and functions by signature" {
    var p = try parsed(source, @sizeOf(usize));
    defer p.deinit();
    const schema = &p.schema;
    const base = @intFromPtr(&sigTarget);
    // After the lea and the ret
    const data = base + 13 + @as(usize, if (@sizeOf(usize) == 8) 7 else 6) + 1;

    try testing.expectEqual(0x0BADC0DE, (try Ref.static(schema, "answer").load()).uint);
    try testing.expectEqual(data, try Ref.static(schema, "player").address.unwrap());
    // Through the call to the jmp, then through the jmp
    try testing.expectEqual(base + 13, try Ref.function(schema, "landing").unwrap());
    // Only the type matters, so a pointer works without reading through it. Player gets Entity's
    try testing.expectEqual(base + 5, try Ref.static(schema, "player").method("spawn").unwrap());
    try testing.expectEqual(base + 5, try Ref.of(schema, "Entity", 0).method("spawn").unwrap());

    try testing.expectError(error.NoSuchStatic, Ref.static(schema, "nope").load());
    try testing.expectError(error.NoSuchFunction, Ref.function(schema, "nope").unwrap());
    try testing.expectError(error.NoSuchFunction, Ref.of(schema, "Player", 0).method("nope").unwrap());
    try testing.expectError(error.NoSuchFunction, Ref.of(schema, "Player", 0).method("attack").unwrap());
    try testing.expectError(error.NotAStruct, Ref.of(schema, "Job", 0).method("spawn").unwrap());

    try testing.expectEqual(0x0BADC0DE, (try Ref.staticOf(schema, "Player", "count").load()).uint);
    try testing.expectError(error.NoSuchStatic, Ref.staticOf(schema, "Entity", "count").load());

    try testing.expectEqual(data, try Ref.virtualTable(schema, "Player").unwrap());
    try testing.expectEqual(data + 9 * @sizeOf(usize), try Ref.virtualSlot(schema, "Player", "attack").unwrap());
    try testing.expectEqual(data + 2 * @sizeOf(usize), try Ref.virtualSlot(schema, "Player", "update").unwrap());
    try testing.expectError(error.NoVirtualTable, Ref.virtualTable(schema, "Entity").unwrap());
    try testing.expectError(error.NoSuchFunction, Ref.virtualSlot(schema, "Player", "nope").unwrap());
}

test "missing signature says why" {
    const saved = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = saved;
    var p = try parsed(
        \\[game.Sig("DE AD 13 37 C0 DE 13 37 C0 DE")] void missing();
        \\[game.Sig("B8 0D F0 70 1A", Module("nope.dll"))] void no_module();
        \\[game.Sig("B8 0D F0 70 1A"), game.Section(".nope")] void no_section();
        \\[game.Sig("B8 0D F0 70 1A", Rip)] void no_operand();
        \\[game.Sig("90", Sideways)] void bad_step();
    , @sizeOf(usize));
    defer p.deinit();
    const s = &p.schema;
    try testing.expectError(error.PatternNotFound, Ref.function(s, "missing").unwrap());
    try testing.expectError(error.ModuleNotFound, Ref.function(s, "no_module").unwrap());
    try testing.expectError(error.SectionNotFound, Ref.function(s, "no_section").unwrap());
    // The marker `mov` points nowhere
    try testing.expectError(error.NoAddressOperand, Ref.function(s, "no_operand").unwrap());
    try testing.expectError(error.BadStep, Ref.function(s, "bad_step").unwrap());
}

test "steps" {
    var p = try parsed(
        \\[game.Sig("90", Follow)] void a();
        \\[game.Sig("90", Offset(-2))] void b();
        \\[game.Sig("90", Offset(3), Rip, Follow), game.Module("x.dll")] void c();
        \\[other.Sig("90")] void d();
    , @sizeOf(usize));
    defer p.deinit();
    const f = p.schema.functions;
    var steps: [sigs.max_steps]mem.Sig.Step = undefined;
    try testing.expectEqualSlices(mem.Sig.Step, &.{.follow}, (try sigs.of(f[0].annotations, "game", "Sig", &steps)).?.resolve);
    try testing.expectEqualSlices(mem.Sig.Step, &.{.{ .offset = -2 }}, (try sigs.of(f[1].annotations, "game", "Sig", &steps)).?.resolve);
    const c = (try sigs.of(f[2].annotations, "game", "Sig", &steps)).?;
    try testing.expectEqualSlices(mem.Sig.Step, &.{ .{ .offset = 3 }, .rip, .follow }, c.resolve);
    try testing.expectEqualStrings("x.dll", c.module.?);
    try testing.expectEqualStrings(".text", c.section);
    try testing.expectEqual(null, try sigs.of(f[3].annotations, "game", "Sig", &steps));
    try testing.expect(try sigs.of(f[3].annotations, null, "Sig", &steps) != null);
}
