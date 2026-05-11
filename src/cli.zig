//! CLI subcommand routing for the `organo` binary.
//!
//! Milestone 2 only routes `init`. Later milestones add `daemon`, `stack`, etc.

const std = @import("std");
const init_mod = @import("init.zig");

pub const UsageError = error{
    NoSubcommand,
    UnknownSubcommand,
    BadFlagValue,
    OutOfMemory,
};

pub const Subcommand = enum {
    init,

    pub fn fromString(s: []const u8) ?Subcommand {
        if (std.mem.eql(u8, s, "init")) return .init;
        return null;
    }
};

pub const InitArgs = struct {
    /// Defaults to "." (cwd) when --root is absent.
    root: []const u8 = ".",
    yes: bool = false,
    quiet: bool = false,
    /// Hidden: override `created_at` for deterministic fixture regeneration.
    /// Use only via `tools/regen_*` workflows; not documented in --help.
    now_override: ?[]const u8 = null,
    /// Hidden: override the RNG seed used for `local_token`. Same audience.
    rng_seed_override: ?u64 = null,
};

pub fn parseInitArgs(args: []const []const u8) UsageError!InitArgs {
    var out: InitArgs = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--yes") or std.mem.eql(u8, a, "-y")) {
            out.yes = true;
        } else if (std.mem.eql(u8, a, "--quiet") or std.mem.eql(u8, a, "-q")) {
            out.quiet = true;
        } else if (std.mem.eql(u8, a, "--root")) {
            if (i + 1 >= args.len) return error.BadFlagValue;
            i += 1;
            out.root = args[i];
        } else if (std.mem.startsWith(u8, a, "--root=")) {
            out.root = a["--root=".len..];
            if (out.root.len == 0) return error.BadFlagValue;
        } else if (std.mem.startsWith(u8, a, "--now=")) {
            const v = a["--now=".len..];
            if (v.len == 0) return error.BadFlagValue;
            out.now_override = v;
        } else if (std.mem.startsWith(u8, a, "--seed=")) {
            const v = a["--seed=".len..];
            out.rng_seed_override = std.fmt.parseInt(u64, v, 0) catch return error.BadFlagValue;
        } else {
            // Unknown flag for `init`; treat as bad usage.
            return error.BadFlagValue;
        }
    }
    return out;
}

/// Top-level dispatch. `argv` excludes argv[0]. `stdout`/`stderr` are
/// std.Io.Writer-compatible; in tests we pass an `ArrayList(u8)` writer.
pub fn dispatch(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    if (argv.len == 0) {
        try printUsage(stderr);
        return 2;
    }

    const sub = Subcommand.fromString(argv[0]) orelse {
        try stderr.print("organo: unknown subcommand `{s}`\n", .{argv[0]});
        try printUsage(stderr);
        return 2;
    };

    const rest = argv[1..];
    switch (sub) {
        .init => return try runInit(allocator, rest, stdout, stderr),
    }
}

fn runInit(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    const parsed = parseInitArgs(args) catch |e| {
        try stderr.print("organo init: {s}\n", .{@errorName(e)});
        try printInitUsage(stderr);
        return 2;
    };

    var report = init_mod.run(allocator, .{
        .root = parsed.root,
        .yes = parsed.yes or true, // non-interactive in this milestone
        .quiet = parsed.quiet,
        .now_override = parsed.now_override,
        .rng_seed_override = parsed.rng_seed_override,
    }) catch |e| {
        try stderr.print("organo init: failed: {s}\n", .{@errorName(e)});
        return 1;
    };
    defer report.deinit();

    try printReport(stdout, &report);
    return 0;
}

fn printUsage(w: anytype) !void {
    try w.writeAll(
        \\organo — local orchestrator for AI coding harnesses
        \\
        \\Usage:
        \\  organo <subcommand> [options]
        \\
        \\Subcommands:
        \\  init    Bootstrap a notes-root layout (see `organo init --help`)
        \\
    );
}

fn printInitUsage(w: anytype) !void {
    try w.writeAll(
        \\Usage: organo init [--root <path>] [--yes] [--quiet]
        \\
        \\  --root <path>   Path to the notes root (default: cwd).
        \\  --yes, -y       Skip prompts; auto-init git when needed.
        \\  --quiet, -q     Suppress per-line output; print a summary only.
        \\
    );
}

fn printReport(w: anytype, r: *const init_mod.Report) !void {
    if (r.inside_existing_git) {
        try w.writeAll("warning: notes root is inside an existing git repository;\n");
        try w.writeAll("         the organo layout will join that repo's history.\n");
    }
    if (r.git_initialized) {
        try w.writeAll("initialized git repository (.git)\n");
    }
    if (r.created.items.len == 0) {
        try w.writeAll("organo init: already initialized — no changes.\n");
        return;
    }
    try w.writeAll("created:\n");
    for (r.created.items) |p| try w.print("  {s}\n", .{p});
    if (r.already_present.items.len > 0) {
        try w.writeAll("already present:\n");
        for (r.already_present.items) |p| try w.print("  {s}\n", .{p});
    }
}

// ---------- unit tests ----------

test "parseInitArgs: defaults" {
    const a = try parseInitArgs(&.{});
    try std.testing.expectEqualStrings(".", a.root);
    try std.testing.expect(!a.yes);
    try std.testing.expect(!a.quiet);
}

test "parseInitArgs: --root path" {
    const a = try parseInitArgs(&.{ "--root", "/tmp/x" });
    try std.testing.expectEqualStrings("/tmp/x", a.root);
}

test "parseInitArgs: --root=path" {
    const a = try parseInitArgs(&.{"--root=/tmp/y"});
    try std.testing.expectEqualStrings("/tmp/y", a.root);
}

test "parseInitArgs: flags" {
    const a = try parseInitArgs(&.{ "-y", "-q" });
    try std.testing.expect(a.yes);
    try std.testing.expect(a.quiet);
}

test "parseInitArgs: unknown flag rejected" {
    try std.testing.expectError(error.BadFlagValue, parseInitArgs(&.{"--nope"}));
}

test "parseInitArgs: --root missing value rejected" {
    try std.testing.expectError(error.BadFlagValue, parseInitArgs(&.{"--root"}));
}

test "Subcommand.fromString" {
    try std.testing.expect(Subcommand.fromString("init") != null);
    try std.testing.expect(Subcommand.fromString("daemon") == null);
}
