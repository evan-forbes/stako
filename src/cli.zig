//! CLI subcommand routing for the `organo` binary.
//!
//! Milestones 2–3 added `init` and `daemon`. Milestone 4 wraps the daemon's
//! read endpoints in user-facing subcommands plus short aliases. The shape
//! mirrors `todos/implement_cli_client.md`:
//!
//!   organo init                              # local-only filesystem work
//!   organo daemon start|stop|status          # process management
//!   organo d start|stop|st                   # short daemon aliases
//!   organo stack list|show|config            # API calls
//!   organo s ls|sh|cfg                       # short stack aliases
//!
//! Every API command supports the same global flag set:
//!
//!   --json, -j        Pass-through of the daemon response unchanged.
//!   --root, -r PATH   Override notes root for local config/token discovery.
//!   --port, -p N      Override the daemon port (highest priority).
//!   --verbose, -v     Include request URL / port on errors.
//!
//! Rendering belongs in `cli_stack.zig`; this file only routes and parses.

const std = @import("std");
const init_mod = @import("init.zig");
const daemon_mod = @import("daemon.zig");
const cli_stack = @import("cli_stack.zig");

pub const UsageError = error{
    NoSubcommand,
    UnknownSubcommand,
    BadFlagValue,
    OutOfMemory,
};

pub const Subcommand = enum {
    init,
    daemon,
    stack,

    /// Accepts the canonical name and the short alias documented in
    /// `todos/implement_cli_client.md`.
    pub fn fromString(s: []const u8) ?Subcommand {
        if (std.mem.eql(u8, s, "init")) return .init;
        if (std.mem.eql(u8, s, "daemon") or std.mem.eql(u8, s, "d")) return .daemon;
        if (std.mem.eql(u8, s, "stack") or std.mem.eql(u8, s, "s")) return .stack;
        return null;
    }
};

pub const DaemonAction = enum {
    start,
    stop,
    status,

    /// `st` is the short alias for `status` per the design doc.
    pub fn fromString(s: []const u8) ?DaemonAction {
        if (std.mem.eql(u8, s, "start")) return .start;
        if (std.mem.eql(u8, s, "stop")) return .stop;
        if (std.mem.eql(u8, s, "status") or std.mem.eql(u8, s, "st")) return .status;
        return null;
    }
};

pub const DaemonArgs = struct {
    action: DaemonAction,
    root: []const u8 = ".",
    /// Override `daemon.port` from config.
    port_override: ?u16 = null,
    /// When true, run the daemon in the foreground instead of forking.
    /// Milestone 3 only supports foreground for testability and
    /// simplicity; backgrounding lands when the supervisor matures.
    foreground: bool = true,
};

pub fn parseDaemonArgs(args: []const []const u8) UsageError!DaemonArgs {
    if (args.len == 0) return error.NoSubcommand;
    const action = DaemonAction.fromString(args[0]) orelse return error.UnknownSubcommand;
    var out: DaemonArgs = .{ .action = action };
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--root") or std.mem.eql(u8, a, "-r")) {
            if (i + 1 >= args.len) return error.BadFlagValue;
            i += 1;
            out.root = args[i];
        } else if (std.mem.startsWith(u8, a, "--root=")) {
            out.root = a["--root=".len..];
            if (out.root.len == 0) return error.BadFlagValue;
        } else if (std.mem.eql(u8, a, "--port") or std.mem.eql(u8, a, "-p")) {
            if (i + 1 >= args.len) return error.BadFlagValue;
            i += 1;
            out.port_override = std.fmt.parseInt(u16, args[i], 10) catch return error.BadFlagValue;
        } else if (std.mem.startsWith(u8, a, "--port=")) {
            const v = a["--port=".len..];
            out.port_override = std.fmt.parseInt(u16, v, 10) catch return error.BadFlagValue;
        } else if (std.mem.eql(u8, a, "--foreground")) {
            out.foreground = true;
        } else {
            return error.BadFlagValue;
        }
    }
    return out;
}

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
        } else if (std.mem.eql(u8, a, "--root") or std.mem.eql(u8, a, "-r")) {
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

/// Action under the `stack` subcommand. Each canonical name has one short
/// alias; the table is also surfaced in `--help` text.
pub const StackAction = enum {
    list,
    show,
    config,

    pub fn fromString(s: []const u8) ?StackAction {
        if (std.mem.eql(u8, s, "list") or std.mem.eql(u8, s, "ls")) return .list;
        if (std.mem.eql(u8, s, "show") or std.mem.eql(u8, s, "sh")) return .show;
        if (std.mem.eql(u8, s, "config") or std.mem.eql(u8, s, "cfg")) return .config;
        return null;
    }
};

/// Flags shared by every API-touching subcommand. Initialized from the
/// command line; merged with config / env in `http_client.open`.
pub const ApiFlags = struct {
    root: []const u8 = ".",
    port_override: ?u16 = null,
    json: bool = false,
    verbose: bool = false,
};

pub const StackArgs = struct {
    action: StackAction,
    /// Required for `show`/`config`. Empty for `list`.
    name: []const u8 = "",
    flags: ApiFlags = .{},
};

/// Parse `stack <action> [<name>] [flags...]`. Flags can appear before or
/// after the positional `<name>` argument; positionals are taken in order.
pub fn parseStackArgs(args: []const []const u8) UsageError!StackArgs {
    if (args.len == 0) return error.NoSubcommand;
    const action = StackAction.fromString(args[0]) orelse return error.UnknownSubcommand;
    var out: StackArgs = .{ .action = action };
    var positional_seen: usize = 0;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--json") or std.mem.eql(u8, a, "-j")) {
            out.flags.json = true;
        } else if (std.mem.eql(u8, a, "--verbose") or std.mem.eql(u8, a, "-v")) {
            out.flags.verbose = true;
        } else if (std.mem.eql(u8, a, "--root") or std.mem.eql(u8, a, "-r")) {
            if (i + 1 >= args.len) return error.BadFlagValue;
            i += 1;
            out.flags.root = args[i];
        } else if (std.mem.startsWith(u8, a, "--root=")) {
            out.flags.root = a["--root=".len..];
            if (out.flags.root.len == 0) return error.BadFlagValue;
        } else if (std.mem.eql(u8, a, "--port") or std.mem.eql(u8, a, "-p")) {
            if (i + 1 >= args.len) return error.BadFlagValue;
            i += 1;
            out.flags.port_override = std.fmt.parseInt(u16, args[i], 10) catch return error.BadFlagValue;
        } else if (std.mem.startsWith(u8, a, "--port=")) {
            const v = a["--port=".len..];
            out.flags.port_override = std.fmt.parseInt(u16, v, 10) catch return error.BadFlagValue;
        } else if (std.mem.startsWith(u8, a, "-")) {
            return error.BadFlagValue;
        } else {
            // Positional.
            if (positional_seen == 0 and out.action != .list) {
                out.name = a;
            } else {
                return error.BadFlagValue;
            }
            positional_seen += 1;
        }
    }
    if (out.action != .list and out.name.len == 0) return error.NoSubcommand;
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
        .daemon => return try runDaemon(allocator, rest, stdout, stderr),
        .stack => return try runStack(allocator, rest, stdout, stderr),
    }
}

fn runDaemon(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    const parsed = parseDaemonArgs(args) catch |e| {
        try stderr.print("organo daemon: {s}\n", .{@errorName(e)});
        try printDaemonUsage(stderr);
        return 2;
    };

    switch (parsed.action) {
        .start => {
            var d = daemon_mod.start(allocator, .{
                .notes_root = parsed.root,
                .port_override = parsed.port_override,
            }) catch |e| {
                try stderr.print("organo daemon start: failed: {s}\n", .{@errorName(e)});
                return 1;
            };
            defer d.deinit();
            try stdout.print("organo daemon: listening on 127.0.0.1:{d}\n", .{d.bound_port});
            try stdout.flush();
            try stderr.flush();
            // Foreground accept loop until SIGTERM.
            g_daemon_for_signals = &d;
            defer g_daemon_for_signals = null;
            installSignalHandlers();
            // Best-effort: serve until interrupted.
            daemon_mod.serveUntilShutdown(&d) catch |e| {
                try stderr.print("organo daemon: serve loop ended: {s}\n", .{@errorName(e)});
            };
            // Clean up PID file on graceful exit.
            if (d.pid_written) {
                daemon_mod.removePidFile(allocator, d.notes_root_abs) catch {};
            }
            return 0;
        },
        .stop => {
            const result = daemon_mod.stop(allocator, parsed.root, 5) catch |e| {
                try stderr.print("organo daemon stop: failed: {s}\n", .{@errorName(e)});
                return 1;
            };
            switch (result) {
                .not_running => try stdout.writeAll("organo daemon: not running\n"),
                .stopped => try stdout.writeAll("organo daemon: stopped\n"),
                .timeout => {
                    try stdout.writeAll("organo daemon: process did not exit within grace; pid file left for inspection\n");
                    return 1;
                },
            }
            return 0;
        },
        .status => {
            const info = daemon_mod.readPidFile(allocator, parsed.root) catch |e| {
                try stderr.print("organo daemon status: failed: {s}\n", .{@errorName(e)});
                return 1;
            };
            if (info) |pi| {
                if (daemon_mod.isProcessAlive(pi.pid)) {
                    const uptime = std.time.timestamp() - pi.started_at;
                    try stdout.print("organo daemon: running (pid {d}, port {d}, uptime {d}s)\n", .{ pi.pid, pi.port, uptime });
                } else {
                    try stdout.print("organo daemon: stale pid file (pid {d} not alive)\n", .{pi.pid});
                }
            } else {
                try stdout.writeAll("organo daemon: stopped\n");
            }
            return 0;
        },
    }
}

fn runStack(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    const parsed = parseStackArgs(args) catch |e| {
        try stderr.print("organo stack: {s}\n", .{@errorName(e)});
        try printStackUsage(stderr);
        return 2;
    };

    return cli_stack.run(allocator, parsed, stdout, stderr);
}

var g_daemon_for_signals: ?*daemon_mod.Daemon = null;

fn installSignalHandlers() void {
    if (@import("builtin").os.tag == .windows) return;
    var sa: std.posix.Sigaction = .{
        .handler = .{ .handler = handleTermSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.TERM, &sa, null);
    std.posix.sigaction(std.posix.SIG.INT, &sa, null);
}

fn handleTermSignal(_: c_int) callconv(.c) void {
    if (g_daemon_for_signals) |d| d.requestShutdown();
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
        \\  init                        Bootstrap a notes-root layout
        \\  daemon, d  start|stop|st    Start/stop/inspect the local daemon
        \\  stack,  s  list|show|cfg    Read stacks via the daemon
        \\
        \\Run `organo <subcommand>` with no further args for per-subcommand help.
        \\
    );
}

fn printDaemonUsage(w: anytype) !void {
    try w.writeAll(
        \\Usage: organo daemon|d <start|stop|status|st> [--root, -r <path>] [--port, -p <n>]
        \\
        \\Actions:
        \\  start         Bind loopback, serve HTTP read endpoints.
        \\  stop          Send SIGTERM to the running daemon.
        \\  status, st    Report running/stopped, pid, port, uptime.
        \\
    );
}

fn printInitUsage(w: anytype) !void {
    try w.writeAll(
        \\Usage: organo init [--root, -r <path>] [--yes, -y] [--quiet, -q]
        \\
        \\  --root, -r <path>   Path to the notes root (default: cwd).
        \\  --yes, -y           Skip prompts; auto-init git when needed.
        \\  --quiet, -q         Suppress per-line output; print a summary only.
        \\
    );
}

fn printStackUsage(w: anytype) !void {
    try w.writeAll(
        \\Usage: organo stack|s <list|show|config> [<name>] [flags...]
        \\
        \\Actions:
        \\  list,   ls            List known stacks.
        \\  show,   sh   <name>   Show a stack's config + items.
        \\  config, cfg  <name>   Show a stack's config.
        \\
        \\Flags (common to every API subcommand):
        \\  --json,    -j         Pass the daemon JSON through unchanged.
        \\  --root,    -r <path>  Notes root for local config/token discovery.
        \\  --port,    -p <n>     Override the daemon port (also: ORGANO_PORT).
        \\  --verbose, -v         Show request URL on errors.
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

test "parseInitArgs: -r short flag" {
    const a = try parseInitArgs(&.{ "-r", "/tmp/z" });
    try std.testing.expectEqualStrings("/tmp/z", a.root);
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

test "Subcommand.fromString canonical names" {
    try std.testing.expect(Subcommand.fromString("init") != null);
    try std.testing.expect(Subcommand.fromString("daemon") != null);
    try std.testing.expect(Subcommand.fromString("stack") != null);
    try std.testing.expect(Subcommand.fromString("nope") == null);
}

test "Subcommand.fromString: short aliases d, s" {
    try std.testing.expectEqual(Subcommand.daemon, Subcommand.fromString("d").?);
    try std.testing.expectEqual(Subcommand.stack, Subcommand.fromString("s").?);
}

test "DaemonAction.fromString: st alias for status" {
    try std.testing.expectEqual(DaemonAction.status, DaemonAction.fromString("st").?);
    try std.testing.expectEqual(DaemonAction.start, DaemonAction.fromString("start").?);
    try std.testing.expectEqual(DaemonAction.stop, DaemonAction.fromString("stop").?);
}

test "StackAction.fromString: every canonical name has a short alias" {
    try std.testing.expectEqual(StackAction.list, StackAction.fromString("list").?);
    try std.testing.expectEqual(StackAction.list, StackAction.fromString("ls").?);
    try std.testing.expectEqual(StackAction.show, StackAction.fromString("show").?);
    try std.testing.expectEqual(StackAction.show, StackAction.fromString("sh").?);
    try std.testing.expectEqual(StackAction.config, StackAction.fromString("config").?);
    try std.testing.expectEqual(StackAction.config, StackAction.fromString("cfg").?);
}

test "parseDaemonArgs: actions" {
    const a = try parseDaemonArgs(&.{"start"});
    try std.testing.expectEqual(DaemonAction.start, a.action);
    const b = try parseDaemonArgs(&.{ "stop", "--root=/tmp/x" });
    try std.testing.expectEqual(DaemonAction.stop, b.action);
    try std.testing.expectEqualStrings("/tmp/x", b.root);
    const c = try parseDaemonArgs(&.{ "start", "--port", "8080" });
    try std.testing.expectEqual(@as(?u16, 8080), c.port_override);
    try std.testing.expectError(error.UnknownSubcommand, parseDaemonArgs(&.{"foo"}));
}

test "parseDaemonArgs: -r, -p short flags" {
    const a = try parseDaemonArgs(&.{ "start", "-r", "/tmp/y", "-p", "9000" });
    try std.testing.expectEqualStrings("/tmp/y", a.root);
    try std.testing.expectEqual(@as(?u16, 9000), a.port_override);
}

test "parseStackArgs: list with --json" {
    const a = try parseStackArgs(&.{ "list", "--json" });
    try std.testing.expectEqual(StackAction.list, a.action);
    try std.testing.expectEqualStrings("", a.name);
    try std.testing.expect(a.flags.json);
}

test "parseStackArgs: ls -j short forms" {
    const a = try parseStackArgs(&.{ "ls", "-j" });
    try std.testing.expectEqual(StackAction.list, a.action);
    try std.testing.expect(a.flags.json);
}

test "parseStackArgs: show requires name" {
    try std.testing.expectError(error.NoSubcommand, parseStackArgs(&.{"show"}));
    try std.testing.expectError(error.NoSubcommand, parseStackArgs(&.{"sh"}));
}

test "parseStackArgs: show with name and flags" {
    const a = try parseStackArgs(&.{ "show", "demo", "--port", "1234", "-v" });
    try std.testing.expectEqual(StackAction.show, a.action);
    try std.testing.expectEqualStrings("demo", a.name);
    try std.testing.expectEqual(@as(?u16, 1234), a.flags.port_override);
    try std.testing.expect(a.flags.verbose);
}

test "parseStackArgs: cfg short alias for config with --root" {
    const a = try parseStackArgs(&.{ "cfg", "demo", "--root=/tmp/n" });
    try std.testing.expectEqual(StackAction.config, a.action);
    try std.testing.expectEqualStrings("demo", a.name);
    try std.testing.expectEqualStrings("/tmp/n", a.flags.root);
}

test "parseStackArgs: rejects unknown flag" {
    try std.testing.expectError(error.BadFlagValue, parseStackArgs(&.{ "list", "--nope" }));
}

test "parseStackArgs: rejects extra positional" {
    try std.testing.expectError(error.BadFlagValue, parseStackArgs(&.{ "show", "a", "b" }));
}

test "parseStackArgs: rejects unknown action" {
    try std.testing.expectError(error.UnknownSubcommand, parseStackArgs(&.{"bogus"}));
}
