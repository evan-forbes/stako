//! Public library surface for the zellij-first Stako core.

pub const paths = @import("paths.zig");
pub const plan = @import("plan.zig");
pub const prompt = @import("prompt.zig");
pub const events = @import("events.zig");
pub const status = @import("status.zig");
pub const runtime = @import("runtime.zig");
pub const scheduler = @import("scheduler.zig");
pub const zellij = @import("zellij.zig");
pub const cli = @import("cli.zig");

pub const Stack = runtime.Stack;
pub const Plan = plan.Plan;
pub const Node = plan.Node;
pub const Action = plan.Action;
pub const Status = status.Status;

test {
    @import("std").testing.refAllDecls(@This());
}
