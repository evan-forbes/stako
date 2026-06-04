const std = @import("std");
const stako = @import("stako");

pub fn main() !u8 {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var arg_it = try std.process.argsWithAllocator(allocator);
    defer arg_it.deinit();
    _ = arg_it.next();

    var args: std.ArrayList([]const u8) = .empty;
    defer {
        for (args.items) |s| allocator.free(s);
        args.deinit(allocator);
    }
    while (arg_it.next()) |a| {
        try args.append(allocator, try allocator.dupe(u8, a));
    }

    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
    const stdout = &stdout_writer.interface;
    const stderr = &stderr_writer.interface;

    const code = stako.cli.dispatch(allocator, args.items, stdout, stderr) catch |e| {
        stderr.print("stako: {s}\n", .{@errorName(e)}) catch {};
        stderr.flush() catch {};
        return 1;
    };

    try stdout.flush();
    try stderr.flush();
    return code;
}

test "main compiles" {
    try std.testing.expect(true);
}
