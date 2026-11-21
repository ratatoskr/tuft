//! Dev tools for poking at a process, drawn with tuft_ui.

const std = @import("std");

const ui = @import("tuft_ui");
const Claims = @import("tuft_mem").Claims;
const Message = @import("tuft_text").Message;

pub const HexView = @import("HexView.zig");
pub const AsmView = @import("AsmView.zig");
pub const AddressBar = @import("AddressBar.zig");
pub const Inspector = @import("Inspector.zig");
pub const SearchView = @import("SearchView.zig");
pub const write = @import("write.zig");
pub const AddressList = @import("AddressList.zig");
pub const StructView = @import("StructView.zig");
pub const StructRows = @import("StructRows.zig");
pub const StructEdit = @import("StructEdit.zig");

/// Keys for the views' commands, shared so a key does the same thing everywhere.
pub const Keys = struct {
    copy: ?ui.Chord = .{ .key = .c, .ctrl = true },
    copy_address: ?ui.Chord = .{ .key = .c, .ctrl = true, .shift = true },
    paste: ?ui.Chord = .{ .key = .v, .ctrl = true },
    delete: ?ui.Chord = .{ .key = .delete },
    edit: ?ui.Chord = .{ .key = .f2 },
    go_to: ?ui.Chord = .{ .key = .g, .ctrl = true },
    show_code: ?ui.Chord = .{ .key = .d, .ctrl = true },
    show_memory: ?ui.Chord = .{ .key = .b, .ctrl = true },
    add_to_list: ?ui.Chord = .{ .key = .l, .ctrl = true },
    what_writes: ?ui.Chord = .{ .key = .w, .ctrl = true, .shift = true },
    what_reads: ?ui.Chord = .{ .key = .r, .ctrl = true, .shift = true },
    make_sig: ?ui.Chord = .{ .key = .s, .ctrl = true, .alt = true },
    hold: ?ui.Chord = .{ .key = .space },
    new_entry: ?ui.Chord = .{ .key = .n, .ctrl = true },
    new_group: ?ui.Chord = .{ .key = .n, .ctrl = true, .shift = true },
    /// Works while typing too.
    run: ?ui.Chord = .{ .key = .enter, .ctrl = true },
    /// Works while typing too.
    save: ?ui.Chord = .{ .key = .s, .ctrl = true },
    save_as: ?ui.Chord = .{ .key = .s, .ctrl = true, .shift = true },
    open: ?ui.Chord = .{ .key = .o, .ctrl = true },
    /// Writes what's picked to a file of its own.
    export_file: ?ui.Chord = .{ .key = .e, .ctrl = true },
    import_file: ?ui.Chord = .{ .key = .i, .ctrl = true },
    toggle_breakpoint: ?ui.Chord = .{ .key = .f9 },
    toggle_hardware_breakpoint: ?ui.Chord = .{ .key = .f9, .shift = true },
    enable_breakpoint: ?ui.Chord = .{ .key = .f9, .ctrl = true },
    delete_all_breakpoints: ?ui.Chord = .{ .key = .f9, .ctrl = true, .shift = true },
    continue_thread: ?ui.Chord = .{ .key = .f5 },
    step_into: ?ui.Chord = .{ .key = .f11 },
    step_over: ?ui.Chord = .{ .key = .f10 },
    /// Moves the stopped thread to the picked instruction, without running anything.
    set_next: ?ui.Chord = .{ .key = .f10, .ctrl = true, .shift = true },
    expand: ?ui.Chord = .{ .key = .right },
    collapse: ?ui.Chord = .{ .key = .left },
    toggle_search: ?ui.Chord = .{ .key = .f, .ctrl = true, .shift = true },
    move_up: ?ui.Chord = .{ .key = .up, .alt = true },
    move_down: ?ui.Chord = .{ .key = .down, .alt = true },
};

/// Set before drawing.
pub var keys: Keys = .{};

pub const Problem = Message(200);

/// Why `at` can't be changed.
pub fn claimed(at: usize, claim: *const Claims.Claim) Problem {
    return .init("0x{x} is {f}'s: remove that before changing it", .{ at, claim });
}

pub fn claimedColour() u32 {
    return ui.getColorU32(.plot_histogram);
}

pub fn labels(comptime E: type, comptime label: fn (E) [:0]const u8) [@typeInfo(E).@"enum".field_names.len][:0]const u8 {
    var out: [@typeInfo(E).@"enum".field_names.len][:0]const u8 = undefined;
    for (&out, 0..) |*l, i| l.* = label(@fromBackingInt(@intCast(i)));
    return out;
}

test {
    std.testing.refAllDecls(@This());
    _ = HexView;
    _ = AsmView;
    _ = AddressBar;
    _ = Inspector;
    _ = SearchView;
    _ = write;
    _ = AddressList;
    _ = StructView;
    _ = StructEdit;
    _ = StructRows;
    _ = @import("Drag.zig");
}
