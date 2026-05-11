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
pub const cli_stack = @import("cli_stack.zig");
pub const config = @import("config.zig");
pub const local_token = @import("local_token.zig");
pub const errors = @import("errors.zig");
pub const storage = @import("storage.zig");
pub const daemon = @import("daemon.zig");
pub const http_client = @import("http_client.zig");
pub const audit = @import("audit.zig");
pub const vcs = @import("vcs.zig");
pub const mutations = @import("mutations.zig");
pub const mutation_queue = @import("mutation_queue.zig");
pub const events = @import("events.zig");
pub const adapter = @import("adapter.zig");
pub const fake_adapter = @import("fake_adapter.zig");
pub const claude_adapter = @import("claude_adapter.zig");
pub const codex_adapter = @import("codex_adapter.zig");
pub const harness_dispatch = @import("harness_dispatch.zig");
pub const transcript = @import("transcript.zig");
pub const sse = @import("sse.zig");
pub const runtime_file = @import("runtime_file.zig");
pub const session_manager = @import("session_manager.zig");
pub const runtime = @import("runtime.zig");

pub const Status = state.Status;
pub const Kind = item.Kind;
pub const Item = item.Item;
pub const StackConfig = stack_config.StackConfig;
pub const Config = config.Config;

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
