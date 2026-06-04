const std = @import("std");
const stako = @import("stako");

test "public core surface compiles" {
    std.testing.refAllDecls(stako);
}
