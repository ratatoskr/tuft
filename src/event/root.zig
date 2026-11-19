//! Concurrency helpers for code living in another process.

const std = @import("std");

pub const event = @import("event.zig");
pub const Event = event.Event;
pub const Scope = @import("Scope.zig");
pub const Owner = @import("Owner.zig");
pub const Mailbox = @import("Mailbox.zig").Mailbox;
pub const TaskQueue = @import("TaskQueue.zig");
pub const once = @import("once.zig");

test {
    std.testing.refAllDecls(@This());
    _ = event;
    _ = Scope;
    _ = Owner;
    _ = @import("Mailbox.zig");
    _ = TaskQueue;
    _ = once;
}
