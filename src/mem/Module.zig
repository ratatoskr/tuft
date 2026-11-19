//! A loaded PE image, read straight from its headers.

const std = @import("std");

const sys = @import("tuft_sys");

const address = @import("Address.zig");
const range_ = @import("Range.zig");

pub fn Generic(comptime Hooks: type) type {
    return struct {
        const Module = @This();
        const Address = address.Generic(Hooks);
        const Range = range_.Generic(Hooks);

        base: usize,

        pub const Section = sys.module.Section;
        pub const Sections = sys.module.SectionIterator;

        /// The host exe.
        pub fn main() Module {
            return .{ .base = sys.module.mainBase() };
        }

        /// The module tuft is linked into.
        pub fn self() Module {
            return .{ .base = sys.module.selfBase() };
        }

        pub fn find(name_: []const u8) !Module {
            return .{ .base = sys.module.findBase(name_) orelse return error.ModuleNotFound };
        }

        pub fn containing(addr: usize) !Module {
            return .{ .base = sys.module.containingBase(addr) orelse return error.ModuleNotFound };
        }

        pub fn name(m: Module, buf: []u8) ?[]const u8 {
            return sys.module.nameOf(m.base, buf);
        }

        pub fn path(m: Module, buf: []u8) ?[]const u8 {
            return sys.module.pathOf(m.base, buf);
        }

        pub fn size(m: Module) !usize {
            return sys.module.imageSize(m.base);
        }

        /// Null if there isn't one.
        pub fn entryPoint(m: Module) !?usize {
            return sys.module.entryPoint(m.base);
        }

        pub fn range(m: Module) !Range {
            return .{ .start = m.base, .len = try m.size() };
        }

        pub fn sections(m: Module) !Sections {
            return sys.module.sections(m.base);
        }

        pub fn section(m: Module, name_: []const u8) !Range {
            const s = try sys.module.section(m.base, name_) orelse return error.SectionNotFound;
            return .{ .start = s.start, .len = s.len };
        }

        pub fn text(m: Module) !Range {
            return m.section(".text");
        }

        pub fn symbol(m: Module, name_: []const u8) Address {
            return .at(sys.module.findExport(m.base, name_) orelse return .fail(error.SymbolNotFound));
        }
    };
}

const tests = struct {
    const Module = Generic(address.NoHooks);

    /// Same bytes on x86 and x64, unique in the test exe. Never called.
    fn uniqueCode() callconv(.naked) void {
        asm volatile (
            \\.intel_syntax noprefix
            \\mov eax, 0xDEADBEEF
            \\mov ecx, 0x0BADF00D
            \\ret
            \\.att_syntax prefix
        );
    }

    test "main .text scan" {
        const main_module = Module.main();
        const code = @intFromPtr(&uniqueCode);

        try std.testing.expectEqual(main_module.base, (try Module.containing(code)).base);
        const text_range = try main_module.text();
        try std.testing.expect(text_range.contains(code));
        try std.testing.expect((try main_module.range()).contains(text_range.end() - 1));

        try std.testing.expectEqual(code, try text_range.scan("unique code", "B8 EF BE AD DE B9 0D F0 AD 0B C3").unwrap());
        try std.testing.expectError(error.SectionNotFound, main_module.section(".nope"));
    }

    test "kernel32 exports" {
        const kernel32 = try Module.find("kernel32.dll");
        try std.testing.expect(try kernel32.symbol("Sleep").unwrap() != 0);
        try std.testing.expectError(error.SymbolNotFound, kernel32.symbol("NotARealExport").unwrap());
        try std.testing.expectError(error.ModuleNotFound, Module.find("not_loaded.dll"));
    }

    test "name, path and sections" {
        const kernel32 = try Module.find("kernel32.dll");
        var buf: [260]u8 = undefined;
        try std.testing.expect(std.ascii.eqlIgnoreCase("kernel32.dll", kernel32.name(&buf).?));
        try std.testing.expect(std.ascii.endsWithIgnoreCase(kernel32.path(&buf).?, "\\kernel32.dll"));
        try std.testing.expect((try kernel32.range()).contains((try kernel32.entryPoint()).?));

        var it = try kernel32.sections();
        var found_text = false;
        while (it.next()) |s| {
            if (std.mem.eql(u8, s.name(), ".text")) found_text = s.executable and s.start == (try kernel32.text()).start;
        }
        try std.testing.expect(found_text);
        // The test is linked into the exe itself
        try std.testing.expectEqual(Module.main().base, Module.self().base);
    }
};

test {
    _ = tests;
}
