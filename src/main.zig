//! `organo` binary entry point.
//!
//! Milestone 2 wires `organo init`. Subcommand routing lives in `cli.zig`;
//! this file is a thin wrapper around it.

const std = @import("std");
const organo = @import("organo");

pub fn main() !u8 {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Collect argv (excluding argv[0]).
    var arg_it = try std.process.argsWithAllocator(allocator);
    defer arg_it.deinit();
    _ = arg_it.next(); // skip program name

    var args = std.ArrayList([]const u8){};
    defer {
        for (args.items) |s| allocator.free(s);
        args.deinit(allocator);
    }
    while (arg_it.next()) |a| {
        try args.append(allocator, try allocator.dupe(u8, a));
    }

    // Stdout/stderr writers (std.fs.File adapter).
    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
    const stdout = &stdout_writer.interface;
    const stderr = &stderr_writer.interface;

    const code = organo.cli.dispatch(allocator, args.items, stdout, stderr) catch |e| {
        stderr.print("organo: internal error: {s}\n", .{@errorName(e)}) catch {};
        stderr.flush() catch {};
        return 1;
    };

    stdout.flush() catch {};
    stderr.flush() catch {};
    return code;
}

test "main module compiles" {
    // Smoke test: ensure the module compiles. Behavioural tests live in
    // test/init_tests.zig.
    try std.testing.expect(true);
}
