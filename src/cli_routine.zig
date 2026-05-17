const std = @import("std");
const cli = @import("cli.zig");
const http_client = @import("http_client.zig");

pub fn run(
    allocator: std.mem.Allocator,
    args: cli.RoutineArgs,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    var client = http_client.open(allocator, .{
        .root = args.flags.root,
        .port_override = args.flags.port_override,
        .verbose = args.flags.verbose,
    }) catch |e| {
        try stderr.print("stako routine: failed to prepare client: {s}\n", .{@errorName(e)});
        return 1;
    };
    defer client.deinit();

    const path = switch (args.action) {
        .list => try allocator.dupe(u8, "/routines"),
        .show => try std.fmt.allocPrint(allocator, "/routines/{s}", .{args.name}),
    };
    defer allocator.free(path);
    var resp = http_client.get(&client, path) catch |e| return reportClientError(e, &client, path, stderr);
    defer resp.deinit();
    if (resp.status != 200) return reportApiError(resp.status, resp.body, path, args.flags.verbose, stderr);
    try stdout.writeAll(resp.body);
    try stdout.writeAll("\n");
    return 0;
}

fn reportClientError(e: anyerror, client: *http_client.Client, path: []const u8, stderr: anytype) !u8 {
    switch (e) {
        error.DaemonNotRunning, error.ConnectionRefused => {
            try stderr.writeAll("stako: daemon not started; try `stako daemon start`\n");
            if (client.verbose) try stderr.print("  attempted: http://{s}:{d}{s}\n", .{ client.host, client.port, path });
            return 1;
        },
        else => {
            try stderr.print("stako: request failed: {s}\n", .{@errorName(e)});
            if (client.verbose) try stderr.print("  attempted: http://{s}:{d}{s}\n", .{ client.host, client.port, path });
            return 1;
        },
    }
}

fn reportApiError(status: u16, body: []const u8, path: []const u8, verbose: bool, stderr: anytype) !u8 {
    _ = body;
    try stderr.print("stako: HTTP {d}\n", .{status});
    if (verbose) try stderr.print("  path: {s}\n", .{path});
    return 1;
}
