//! Public library surface for the zellij-first Stako core.

pub const paths = @import("paths.zig");
pub const prompt = @import("prompt.zig");
pub const store = @import("store.zig");
pub const scheduler = @import("scheduler.zig");
pub const zellij = @import("zellij.zig");
pub const cli = @import("cli.zig");

pub const Stack = store.Stack;
pub const Thread = store.Thread;
pub const PromptRun = store.PromptRun;
pub const PromptStatus = store.PromptStatus;
pub const ThreadStatus = store.ThreadStatus;
pub const Action = prompt.Action;

test {
    @import("std").testing.refAllDecls(@This());
}
