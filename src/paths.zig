const std = @import("std");

pub const DEFAULT_NOTES_ROOT: []const u8 = "~/stako";

pub const Error = error{
    HomeNotSet,
    OutOfMemory,
} || std.process.GetEnvVarOwnedError;

pub fn resolveNotesRoot(allocator: std.mem.Allocator, root: []const u8) Error![]u8 {
    if (std.mem.eql(u8, root, "~")) {
        return homeDir(allocator);
    }
    if (std.mem.startsWith(u8, root, "~/")) {
        const home = try homeDir(allocator);
        defer allocator.free(home);
        return std.fs.path.join(allocator, &.{ home, root[2..] });
    }
    return allocator.dupe(u8, root);
}

fn homeDir(allocator: std.mem.Allocator) Error![]u8 {
    return std.process.getEnvVarOwned(allocator, "HOME") catch |e| switch (e) {
        error.EnvironmentVariableNotFound => return error.HomeNotSet,
        else => return e,
    };
}

test "resolveNotesRoot expands the default root" {
    const a = std.testing.allocator;
    const root = try resolveNotesRoot(a, DEFAULT_NOTES_ROOT);
    defer a.free(root);
    try std.testing.expect(std.fs.path.isAbsolute(root));
    try std.testing.expect(std.mem.endsWith(u8, root, "/stako"));
}
