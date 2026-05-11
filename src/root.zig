//! organo public library surface.
//!
//! Milestone 1 exposes the stack-item file-format primitives. Later
//! milestones layer the daemon, runtime loop, and CLI on top.

const std = @import("std");

pub const toml = @import("toml.zig");
pub const state = @import("state.zig");
pub const item = @import("item.zig");
pub const stack_config = @import("stack_config.zig");
pub const init = @import("init.zig");
pub const cli = @import("cli.zig");

pub const Status = state.Status;
pub const Kind = item.Kind;
pub const Item = item.Item;
pub const StackConfig = stack_config.StackConfig;

pub fn bufferedPrint() !void {
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.print("Run `zig build test` to run the tests.\n", .{});

    try stdout.flush();
}

pub fn add(a: i32, b: i32) i32 {
    return a + b;
}

test "basic add functionality" {
    try std.testing.expect(add(3, 7) == 10);
}

test {
    // Pull in submodule tests.
    std.testing.refAllDecls(@This());
}
