//! Shared fake-harness test helper (milestone 6+).
//!
//! Provides helpers to build adapter+argv pairs that invoke the bundled
//! `cat_jsonl.sh` / `claude_ignores_sigint.sh` scripts. Used by milestone
//! 6 runtime tests; milestone 7's real-adapter tests reuse this for the
//! pure-mock paths.

const std = @import("std");
const organo = @import("organo");

pub const fake_adapter = organo.fake_adapter;
pub const adapter_mod = organo.adapter;
pub const runtime = organo.runtime;
pub const events = organo.events;

/// Build an argv that runs `bash cat_jsonl.sh <fixture>` against
/// `fixture_path_abs`. Caller owns; free via `freeArgv`.
pub fn buildCatArgv(allocator: std.mem.Allocator, script_path_abs: []const u8, fixture_path_abs: []const u8) ![][]u8 {
    var argv = std.ArrayList([]u8){};
    errdefer {
        for (argv.items) |a| allocator.free(a);
        argv.deinit(allocator);
    }
    try argv.append(allocator, try allocator.dupe(u8, "/usr/bin/env"));
    try argv.append(allocator, try allocator.dupe(u8, "bash"));
    try argv.append(allocator, try allocator.dupe(u8, script_path_abs));
    try argv.append(allocator, try allocator.dupe(u8, fixture_path_abs));
    return argv.toOwnedSlice(allocator);
}

/// Build an argv that runs a script with no extra args (used by the
/// ignores-sigint fixture).
pub fn buildScriptArgv(allocator: std.mem.Allocator, script_path_abs: []const u8) ![][]u8 {
    var argv = std.ArrayList([]u8){};
    errdefer {
        for (argv.items) |a| allocator.free(a);
        argv.deinit(allocator);
    }
    try argv.append(allocator, try allocator.dupe(u8, "/usr/bin/env"));
    try argv.append(allocator, try allocator.dupe(u8, "bash"));
    try argv.append(allocator, try allocator.dupe(u8, script_path_abs));
    return argv.toOwnedSlice(allocator);
}

pub fn freeArgv(allocator: std.mem.Allocator, argv: [][]u8) void {
    for (argv) |a| allocator.free(a);
    allocator.free(argv);
}

/// Read a JSONL transcript file into a buffer; caller frees.
pub fn readTranscript(allocator: std.mem.Allocator, item_dir_abs: []const u8) ![]u8 {
    const path = try std.fs.path.join(allocator, &.{ item_dir_abs, "transcript.jsonl" });
    defer allocator.free(path);
    var f = try std.fs.cwd().openFile(path, .{});
    defer f.close();
    const stat = try f.stat();
    const buf = try allocator.alloc(u8, stat.size);
    _ = try f.readAll(buf);
    return buf;
}

/// Count occurrences of a substring in a buffer.
pub fn countSubstr(haystack: []const u8, needle: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (true) {
        if (std.mem.indexOf(u8, haystack[i..], needle)) |idx| {
            n += 1;
            i += idx + needle.len;
        } else break;
    }
    return n;
}
