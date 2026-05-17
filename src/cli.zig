//! CLI subcommand routing for the `stako` binary.
//!
//! Milestones 2–3 added `init` and `daemon`. Milestone 4 wraps the daemon's
//! read endpoints in user-facing subcommands plus short aliases. The shape
//! mirrors `todos/implement_cli_client.md`:
//!
//!   stako init                              # local-only filesystem work
//!   stako daemon start|stop|status          # process management
//!   stako d start|stop|st                   # short daemon aliases
//!   stako stack list|show|config            # API calls
//!   stako s ls|sh|cfg                       # short stack aliases
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
const cli_routine = @import("cli_routine.zig");
const harness_dispatch = @import("harness_dispatch.zig");

pub const UsageError = error{
    NoSubcommand,
    UnknownSubcommand,
    BadFlagValue,
    OutOfMemory,
};

fn nextFlagValue(args: []const []const u8, index: *usize) UsageError![]const u8 {
    if (index.* + 1 >= args.len) return error.BadFlagValue;
    index.* += 1;
    return args[index.*];
}

fn flagValue(
    args: []const []const u8,
    index: *usize,
    long: []const u8,
    short: ?[]const u8,
    long_eq: []const u8,
) UsageError!?[]const u8 {
    const a = args[index.*];
    if (std.mem.eql(u8, a, long) or (short != null and std.mem.eql(u8, a, short.?))) {
        return try nextFlagValue(args, index);
    }
    if (std.mem.startsWith(u8, a, long_eq)) return a[long_eq.len..];
    return null;
}

fn parsePort(v: []const u8) UsageError!u16 {
    return std.fmt.parseInt(u16, v, 10) catch error.BadFlagValue;
}

fn Alias(comptime T: type) type {
    return struct {
        name: []const u8,
        value: T,
    };
}

fn matchAlias(comptime T: type, s: []const u8, comptime aliases: []const Alias(T)) ?T {
    inline for (aliases) |a| {
        if (std.mem.eql(u8, s, a.name)) return a.value;
    }
    return null;
}

pub const Subcommand = enum {
    init,
    daemon,
    stack,
    routine,
    auth,

    /// Accepts the canonical name and the short alias documented in
    /// `todos/implement_cli_client.md`.
    pub fn fromString(s: []const u8) ?Subcommand {
        const aliases = [_]Alias(Subcommand){
            .{ .name = "init", .value = .init },
            .{ .name = "daemon", .value = .daemon },
            .{ .name = "d", .value = .daemon },
            .{ .name = "stack", .value = .stack },
            .{ .name = "s", .value = .stack },
            .{ .name = "routine", .value = .routine },
            .{ .name = "rtn", .value = .routine },
            .{ .name = "auth", .value = .auth },
            .{ .name = "a", .value = .auth },
        };
        return matchAlias(Subcommand, s, &aliases);
    }
};

pub const DaemonAction = enum {
    start,
    stop,
    status,

    /// `st` is the short alias for `status` per the design doc.
    pub fn fromString(s: []const u8) ?DaemonAction {
        const aliases = [_]Alias(DaemonAction){
            .{ .name = "start", .value = .start },
            .{ .name = "stop", .value = .stop },
            .{ .name = "status", .value = .status },
            .{ .name = "st", .value = .status },
        };
        return matchAlias(DaemonAction, s, &aliases);
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
        if (try flagValue(args, &i, "--root", "-r", "--root=")) |v| {
            out.root = v;
            if (out.root.len == 0) return error.BadFlagValue;
        } else if (try flagValue(args, &i, "--port", "-p", "--port=")) |v| {
            out.port_override = try parsePort(v);
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
        } else if (try flagValue(args, &i, "--root", "-r", "--root=")) |v| {
            out.root = v;
            if (out.root.len == 0) return error.BadFlagValue;
        } else if (std.mem.startsWith(u8, a, "--now=")) {
            const v = a["--now=".len..];
            if (!isValidIsoUtc(v)) return error.BadFlagValue;
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

/// Strict shape check for `--now=` values: exactly `YYYY-MM-DDTHH:MM:SSZ`
/// (20 bytes). The hidden override flows into `stack.toml` as a TOML datetime,
/// so a malformed value would silently break readers downstream.
fn isValidIsoUtc(s: []const u8) bool {
    if (s.len != 20) return false;
    const expect_digit = [_]usize{ 0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18 };
    for (expect_digit) |i| {
        if (s[i] < '0' or s[i] > '9') return false;
    }
    return s[4] == '-' and s[7] == '-' and s[10] == 'T' and s[13] == ':' and s[16] == ':' and s[19] == 'Z';
}

/// Action under the `stack` subcommand. Each canonical name has one short
/// alias; the table is also surfaced in `--help` text.
pub const StackAction = enum {
    list,
    show,
    config,
    // Mutations (milestone 5).
    new,
    add,
    insert,
    retry,
    cancel,
    supersede,
    pause,
    @"resume",
    output,
    threads,
    thread_show,
    thread_create,
    thread_archive,
    run_routine,

    pub fn fromString(s: []const u8) ?StackAction {
        const aliases = [_]Alias(StackAction){
            .{ .name = "list", .value = .list },
            .{ .name = "ls", .value = .list },
            .{ .name = "show", .value = .show },
            .{ .name = "sh", .value = .show },
            .{ .name = "config", .value = .config },
            .{ .name = "cfg", .value = .config },
            .{ .name = "new", .value = .new },
            .{ .name = "add", .value = .add },
            .{ .name = "insert", .value = .insert },
            .{ .name = "ins", .value = .insert },
            .{ .name = "retry", .value = .retry },
            .{ .name = "rt", .value = .retry },
            .{ .name = "cancel", .value = .cancel },
            .{ .name = "cx", .value = .cancel },
            .{ .name = "supersede", .value = .supersede },
            .{ .name = "sup", .value = .supersede },
            .{ .name = "pause", .value = .pause },
            .{ .name = "p", .value = .pause },
            .{ .name = "resume", .value = .@"resume" },
            .{ .name = "r", .value = .@"resume" },
            .{ .name = "output", .value = .output },
            .{ .name = "out", .value = .output },
            .{ .name = "threads", .value = .threads },
            .{ .name = "run-routine", .value = .run_routine },
        };
        return matchAlias(StackAction, s, &aliases);
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

fn parseApiFlag(args: []const []const u8, index: *usize, flags: *ApiFlags) UsageError!bool {
    const a = args[index.*];
    if (std.mem.eql(u8, a, "--json") or std.mem.eql(u8, a, "-j")) {
        flags.json = true;
        return true;
    }
    if (std.mem.eql(u8, a, "--verbose") or std.mem.eql(u8, a, "-v")) {
        flags.verbose = true;
        return true;
    }
    if (try flagValue(args, index, "--root", "-r", "--root=")) |v| {
        flags.root = v;
        if (flags.root.len == 0) return error.BadFlagValue;
        return true;
    }
    if (try flagValue(args, index, "--port", "-p", "--port=")) |v| {
        flags.port_override = try parsePort(v);
        return true;
    }
    return false;
}

pub const StackArgs = struct {
    action: StackAction,
    /// Required for `show`/`config`. Empty for `list`.
    name: []const u8 = "",
    flags: ApiFlags = .{},

    // Action-specific positional / flag inputs (milestone 5 mutations).
    /// `add`: kind ("prompt", "compact", …). `insert`: same.
    kind: []const u8 = "",
    /// `add` / `insert`: target shorthand `provider[/model]` or `match=any`.
    target: []const u8 = "",
    /// `add` / `insert`: prompt body filename. `-` means stdin (not v1).
    prompt_file: []const u8 = "",
    /// `add` / `insert`: explicit slug (else derived from prompt file or
    /// auto-generated).
    slug: []const u8 = "",
    /// `insert`: reference item id (positional before the kind).
    ref: []const u8 = "",
    /// `retry`/`cancel`/`supersede`: target item id.
    item_id: []const u8 = "",
    /// `supersede`: replacement item id.
    replacement: []const u8 = "",
    thread_name: []const u8 = "",
    thread_mode: []const u8 = "",
    routine_name: []const u8 = "",
    input_items: [16][]const u8 = std.mem.zeroes([16][]const u8),
    input_item_count: u8 = 0,
    /// `config`: one or more --set entries (key=value). Up to 8 in v1.
    set_pairs: [8][]const u8 = std.mem.zeroes([8][]const u8),
    set_count: u8 = 0,
};

/// Parse `stack <action> [<name>] [flags...]`. Flags can appear before or
/// after the positional `<name>` argument; positionals are taken in order.
pub fn parseStackArgs(args: []const []const u8) UsageError!StackArgs {
    if (args.len == 0) return error.NoSubcommand;
    var action: StackAction = undefined;
    var nested_offset: usize = 1;
    if (std.mem.eql(u8, args[0], "thread")) {
        if (args.len < 2) return error.NoSubcommand;
        if (std.mem.eql(u8, args[1], "show")) action = .thread_show else if (std.mem.eql(u8, args[1], "create")) action = .thread_create else if (std.mem.eql(u8, args[1], "archive")) action = .thread_archive else return error.UnknownSubcommand;
        nested_offset = 2;
    } else {
        action = StackAction.fromString(args[0]) orelse return error.UnknownSubcommand;
    }
    var out: StackArgs = .{ .action = action };
    var positional_seen: usize = 0;
    var i: usize = nested_offset;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        // Global flags shared by every action.
        if (try parseApiFlag(args, &i, &out.flags)) continue;

        // Action-specific flags.
        if (out.action == .add or out.action == .insert) {
            if (try flagValue(args, &i, "--target", "-t", "--target=")) |v| {
                out.target = v;
                continue;
            }
            if (try flagValue(args, &i, "--prompt-file", "-f", "--prompt-file=")) |v| {
                out.prompt_file = v;
                continue;
            }
            if (try flagValue(args, &i, "--slug", null, "--slug=")) |v| {
                out.slug = v;
                continue;
            }
            if (try flagValue(args, &i, "--thread", null, "--thread=")) |v| {
                out.thread_name = v;
                continue;
            }
            if (try flagValue(args, &i, "--thread-mode", null, "--thread-mode=")) |v| {
                out.thread_mode = v;
                continue;
            }
            if (try flagValue(args, &i, "--input-item", null, "--input-item=")) |v| {
                if (out.input_item_count >= out.input_items.len) return error.BadFlagValue;
                out.input_items[out.input_item_count] = v;
                out.input_item_count += 1;
                continue;
            }
        }
        if (out.action == .thread_create) {
            if (try flagValue(args, &i, "--provider", null, "--provider=")) |v| {
                out.target = v;
                continue;
            }
            if (try flagValue(args, &i, "--model", null, "--model=")) |v| {
                out.replacement = v;
                continue;
            }
        }
        if (out.action == .config) {
            if (try flagValue(args, &i, "--set", "-s", "--set=")) |v| {
                if (out.set_count >= out.set_pairs.len) return error.BadFlagValue;
                out.set_pairs[out.set_count] = v;
                out.set_count += 1;
                continue;
            }
        }

        if (std.mem.startsWith(u8, a, "-")) return error.BadFlagValue;

        // Positionals (per-action layout).
        switch (out.action) {
            .list => return error.BadFlagValue,
            .show, .config, .new, .pause, .@"resume", .threads => {
                if (positional_seen != 0) return error.BadFlagValue;
                out.name = a;
            },
            .output => {
                switch (positional_seen) {
                    0 => out.name = a,
                    1 => out.item_id = a,
                    else => return error.BadFlagValue,
                }
            },
            .thread_show, .thread_create, .thread_archive => {
                switch (positional_seen) {
                    0 => out.name = a,
                    1 => out.thread_name = a,
                    else => return error.BadFlagValue,
                }
            },
            .run_routine => {
                switch (positional_seen) {
                    0 => out.name = a,
                    1 => out.routine_name = a,
                    else => return error.BadFlagValue,
                }
            },
            .add => {
                // positionals: <name> <kind>
                switch (positional_seen) {
                    0 => out.name = a,
                    1 => out.kind = a,
                    else => return error.BadFlagValue,
                }
            },
            .insert => {
                // positionals: <name> <ref> <kind>
                switch (positional_seen) {
                    0 => out.name = a,
                    1 => out.ref = a,
                    2 => out.kind = a,
                    else => return error.BadFlagValue,
                }
            },
            .retry, .cancel => {
                // positionals: <name> <id>
                switch (positional_seen) {
                    0 => out.name = a,
                    1 => out.item_id = a,
                    else => return error.BadFlagValue,
                }
            },
            .supersede => {
                // positionals: <name> <id> <replacement>
                switch (positional_seen) {
                    0 => out.name = a,
                    1 => out.item_id = a,
                    2 => out.replacement = a,
                    else => return error.BadFlagValue,
                }
            },
        }
        positional_seen += 1;
    }

    // Validate per-action that we got the required positionals.
    switch (out.action) {
        .list => {},
        .show, .config, .new, .pause, .@"resume", .threads => if (out.name.len == 0) return error.NoSubcommand,
        .output => if (out.name.len == 0 or out.item_id.len == 0) return error.NoSubcommand,
        .thread_show, .thread_create, .thread_archive => if (out.name.len == 0 or out.thread_name.len == 0) return error.NoSubcommand,
        .run_routine => if (out.name.len == 0 or out.routine_name.len == 0) return error.NoSubcommand,
        .add => if (out.name.len == 0 or out.kind.len == 0) return error.NoSubcommand,
        .insert => if (out.name.len == 0 or out.ref.len == 0 or out.kind.len == 0) return error.NoSubcommand,
        .retry, .cancel => if (out.name.len == 0 or out.item_id.len == 0) return error.NoSubcommand,
        .supersede => if (out.name.len == 0 or out.item_id.len == 0 or out.replacement.len == 0) return error.NoSubcommand,
    }
    return out;
}

/// `auth` subcommand actions (milestone 8). The canonical shape is:
///
///   stako auth status                  # GET /providers, summary view
///   stako auth <provider>              # GET /providers/<name>, single view
///   stako auth signout <provider>      # not implemented in v1 — see below
///
/// Short aliases: `stako a st`, `stako a <provider>`, `stako a out <p>`.
///
/// `signout` is recognized by the parser but the runner emits a stable
/// "not supported" message: stako doesn't own subscription tokens in v1
/// (see `todos/research_provider_sign_in.md`), so it has nothing to sign
/// out. API-key callers should unset the relevant env var themselves.
pub const AuthAction = enum {
    status,
    provider,
    signout,

    pub fn fromString(s: []const u8) ?AuthAction {
        const aliases = [_]Alias(AuthAction){
            .{ .name = "status", .value = .status },
            .{ .name = "st", .value = .status },
            .{ .name = "signout", .value = .signout },
            .{ .name = "out", .value = .signout },
        };
        return matchAlias(AuthAction, s, &aliases);
    }
};

pub const RoutineAction = enum {
    list,
    show,

    pub fn fromString(s: []const u8) ?RoutineAction {
        const aliases = [_]Alias(RoutineAction){
            .{ .name = "list", .value = .list },
            .{ .name = "ls", .value = .list },
            .{ .name = "show", .value = .show },
            .{ .name = "sh", .value = .show },
        };
        return matchAlias(RoutineAction, s, &aliases);
    }
};

pub const RoutineArgs = struct {
    action: RoutineAction,
    name: []const u8 = "",
    flags: ApiFlags = .{},
};

pub fn parseRoutineArgs(args: []const []const u8) UsageError!RoutineArgs {
    if (args.len == 0) return error.NoSubcommand;
    const action = RoutineAction.fromString(args[0]) orelse return error.UnknownSubcommand;
    var out: RoutineArgs = .{ .action = action };
    var i: usize = 1;
    var positional_seen: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (try parseApiFlag(args, &i, &out.flags)) continue;
        if (std.mem.startsWith(u8, a, "-")) return error.BadFlagValue;
        switch (out.action) {
            .list => return error.BadFlagValue,
            .show => {
                if (positional_seen != 0) return error.BadFlagValue;
                out.name = a;
            },
        }
        positional_seen += 1;
    }
    switch (out.action) {
        .list => {},
        .show => if (out.name.len == 0) return error.NoSubcommand,
    }
    return out;
}

pub const AuthArgs = struct {
    action: AuthAction,
    /// Filled for `provider` and `signout` actions.
    provider_name: []const u8 = "",
    flags: ApiFlags = .{},
};

/// Parse `auth [status|<provider>|signout <provider>] [flags...]`.
pub fn parseAuthArgs(args: []const []const u8) UsageError!AuthArgs {
    if (args.len == 0) {
        // Bare `stako auth` defaults to status.
        return .{ .action = .status };
    }
    var out: AuthArgs = .{ .action = .status };
    // First positional: either an action keyword or a provider name.
    var i: usize = 0;
    var positional_seen: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        // Shared API flags.
        if (try parseApiFlag(args, &i, &out.flags)) continue;
        if (std.mem.startsWith(u8, a, "-")) return error.BadFlagValue;

        // Positionals.
        if (positional_seen == 0) {
            if (AuthAction.fromString(a)) |act| {
                out.action = act;
            } else {
                // Treated as a provider name shortcut: `stako auth claude`.
                out.action = .provider;
                out.provider_name = a;
            }
        } else if (positional_seen == 1) {
            // Only valid for `signout`.
            if (out.action != .signout) return error.BadFlagValue;
            out.provider_name = a;
        } else {
            return error.BadFlagValue;
        }
        positional_seen += 1;
    }

    // Validate per-action.
    switch (out.action) {
        .status => {},
        .provider => if (out.provider_name.len == 0) return error.NoSubcommand,
        .signout => if (out.provider_name.len == 0) return error.NoSubcommand,
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
        try stderr.print("stako: unknown subcommand `{s}`\n", .{argv[0]});
        try printUsage(stderr);
        return 2;
    };

    const rest = argv[1..];
    switch (sub) {
        .init => return try runInit(allocator, rest, stdout, stderr),
        .daemon => return try runDaemon(allocator, rest, stdout, stderr),
        .stack => return try runStack(allocator, rest, stdout, stderr),
        .routine => return try runRoutine(allocator, rest, stdout, stderr),
        .auth => return try runAuth(allocator, rest, stdout, stderr),
    }
}

fn runRoutine(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    const parsed = parseRoutineArgs(args) catch |e| {
        try stderr.print("stako routine: {s}\n", .{@errorName(e)});
        try printRoutineUsage(stderr);
        return 2;
    };
    return cli_routine.run(allocator, parsed, stdout, stderr);
}

fn runAuth(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    const parsed = parseAuthArgs(args) catch |e| {
        try stderr.print("stako auth: {s}\n", .{@errorName(e)});
        try printAuthUsage(stderr);
        return 2;
    };
    return @import("cli_auth.zig").run(allocator, parsed, stdout, stderr);
}

fn runDaemon(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    const parsed = parseDaemonArgs(args) catch |e| {
        try stderr.print("stako daemon: {s}\n", .{@errorName(e)});
        try printDaemonUsage(stderr);
        return 2;
    };

    switch (parsed.action) {
        .start => {
            var d = daemon_mod.start(allocator, .{
                .notes_root = parsed.root,
                .port_override = parsed.port_override,
                .enable_runtime = true,
                .dispatch = harness_dispatch.dispatch(),
                .enable_provider_preflight = true,
            }) catch |e| {
                try stderr.print("stako daemon start: failed: {s}\n", .{@errorName(e)});
                return 1;
            };
            defer d.deinit();
            // Mutations + the runtime supervisor come up here, now that
            // `d` has a stable address (workers hold a pointer back to
            // the heap-allocated supervisor and the queue audit_writer).
            d.startWorker() catch |e| {
                try stderr.print("stako daemon start: failed to start mutation worker: {s}\n", .{@errorName(e)});
                return 1;
            };
            try stdout.print("stako daemon: listening on 127.0.0.1:{d}\n", .{d.bound_port});
            try stdout.flush();
            try stderr.flush();
            // Foreground accept loop until SIGTERM.
            g_daemon_for_signals = &d;
            defer g_daemon_for_signals = null;
            installSignalHandlers();
            // Best-effort: serve until interrupted.
            daemon_mod.serveUntilShutdown(&d) catch |e| {
                try stderr.print("stako daemon: serve loop ended: {s}\n", .{@errorName(e)});
            };
            // Clean up PID file on graceful exit.
            if (d.pid_written) {
                daemon_mod.removePidFile(allocator, d.notes_root_abs) catch {};
            }
            return 0;
        },
        .stop => {
            const result = daemon_mod.stop(allocator, parsed.root, 5) catch |e| {
                try stderr.print("stako daemon stop: failed: {s}\n", .{@errorName(e)});
                return 1;
            };
            switch (result) {
                .not_running => try stdout.writeAll("stako daemon: not running\n"),
                .stopped => try stdout.writeAll("stako daemon: stopped\n"),
                .timeout => {
                    try stdout.writeAll("stako daemon: process did not exit within grace; pid file left for inspection\n");
                    return 1;
                },
            }
            return 0;
        },
        .status => {
            const info = daemon_mod.readPidFile(allocator, parsed.root) catch |e| {
                try stderr.print("stako daemon status: failed: {s}\n", .{@errorName(e)});
                return 1;
            };
            if (info) |pi| {
                if (daemon_mod.isProcessAlive(pi.pid)) {
                    const uptime = std.time.timestamp() - pi.started_at;
                    try stdout.print("stako daemon: running (pid {d}, port {d}, uptime {d}s)\n", .{ pi.pid, pi.port, uptime });
                } else {
                    try stdout.print("stako daemon: stale pid file (pid {d} not alive)\n", .{pi.pid});
                }
            } else {
                try stdout.writeAll("stako daemon: stopped\n");
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
        try stderr.print("stako stack: {s}\n", .{@errorName(e)});
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
        try stderr.print("stako init: {s}\n", .{@errorName(e)});
        try printInitUsage(stderr);
        return 2;
    };

    var report = init_mod.run(allocator, .{
        .root = parsed.root,
        .yes = parsed.yes,
        .quiet = parsed.quiet,
        .now_override = parsed.now_override,
        .rng_seed_override = parsed.rng_seed_override,
    }) catch |e| {
        try stderr.print("stako init: failed: {s}\n", .{@errorName(e)});
        return 1;
    };
    defer report.deinit();

    try printReport(stdout, &report, parsed.quiet);
    return 0;
}

fn printUsage(w: anytype) !void {
    try w.writeAll(
        \\stako — local orchestrator for AI coding harnesses
        \\
        \\Usage:
        \\  stako <subcommand> [options]
        \\
        \\Subcommands:
        \\  init                        Bootstrap a notes-root layout
        \\  daemon, d  start|stop|st    Start/stop/inspect the local daemon
        \\  stack,  s  list|show|cfg    Read stacks via the daemon
        \\  routine    list|show        Read routines via the daemon
        \\  auth,   a  status|<prov>    Report provider availability + auth state
        \\
        \\Run `stako <subcommand>` with no further args for per-subcommand help.
        \\
    );
}

fn printAuthUsage(w: anytype) !void {
    try w.writeAll(
        \\Usage: stako auth|a [status|st|<provider>|signout|out <provider>] [flags...]
        \\
        \\Actions:
        \\  status, st                 Show all providers (default).
        \\  <provider>                 Show one provider (anthropic|openai|google
        \\                             or harness aliases claude|codex|gemini).
        \\  signout, out <provider>    Always fails in v1 — stako doesn't own
        \\                             provider subscription tokens. Local-only;
        \\                             never contacts the daemon. The --root,
        \\                             --port, and --verbose flags are accepted
        \\                             but ignored. --json emits a JSON envelope.
        \\
        \\Flags (common to every API subcommand):
        \\  --json,    -j         Pass the daemon JSON through unchanged
        \\                        (signout emits a `{"error":"not_supported"}`
        \\                        envelope on stdout instead).
        \\  --root,    -r <path>  Notes root for local config/token discovery.
        \\  --port,    -p <n>     Override the daemon port (also: STAKO_PORT).
        \\  --verbose, -v         Show request URL on errors.
        \\
    );
}

fn printDaemonUsage(w: anytype) !void {
    try w.writeAll(
        \\Usage: stako daemon|d <start|stop|status|st> [--root, -r <path>] [--port, -p <n>]
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
        \\Usage: stako init [--root, -r <path>] [--yes, -y] [--quiet, -q]
        \\
        \\  --root, -r <path>   Path to the notes root (default: cwd).
        \\  --yes, -y           Skip prompts; auto-init git when needed.
        \\  --quiet, -q         Suppress per-line output; print a summary only.
        \\
    );
}

fn printStackUsage(w: anytype) !void {
    try w.writeAll(
        \\Usage: stako stack|s <list|show|config> [<name>] [flags...]
        \\
        \\Actions:
        \\  list,   ls            List known stacks.
        \\  show,   sh   <name>   Show a stack's config + items.
        \\  config, cfg  <name>   Show a stack's config.
        \\
        \\Flags (common to every API subcommand):
        \\  --json,    -j         Pass the daemon JSON through unchanged.
        \\  --root,    -r <path>  Notes root for local config/token discovery.
        \\  --port,    -p <n>     Override the daemon port (also: STAKO_PORT).
        \\  --verbose, -v         Show request URL on errors.
        \\
    );
}

fn printRoutineUsage(w: anytype) !void {
    try w.writeAll(
        \\Usage: stako routine|rtn <list|show> [<name>] [flags...]
        \\
        \\Actions:
        \\  list, ls            List routines.
        \\  show, sh <name>     Show a routine.
        \\
        \\Flags (common to every API subcommand):
        \\  --json,    -j         Pass the daemon JSON through unchanged.
        \\  --root,    -r <path>  Notes root for local config/token discovery.
        \\  --port,    -p <n>     Override the daemon port (also: STAKO_PORT).
        \\  --verbose, -v         Show request URL on errors.
        \\
    );
}

fn printReport(w: anytype, r: *const init_mod.Report, quiet: bool) !void {
    if (r.inside_existing_git) {
        try w.writeAll("warning: notes root is inside an existing git repository;\n");
        try w.writeAll("         the stako layout will join that repo's history.\n");
    }
    if (r.git_initialized) {
        try w.writeAll("initialized git repository (.git)\n");
    }
    if (r.created.items.len == 0) {
        try w.writeAll("stako init: already initialized — no changes.\n");
        return;
    }
    if (quiet) {
        try w.print(
            "stako init: {d} created, {d} already present.\n",
            .{ r.created.items.len, r.already_present.items.len },
        );
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

test "parseInitArgs: --now= valid ISO UTC accepted" {
    const a = try parseInitArgs(&.{"--now=2026-05-10T14:00:00Z"});
    try std.testing.expectEqualStrings("2026-05-10T14:00:00Z", a.now_override.?);
}

test "parseInitArgs: --now= malformed rejected" {
    try std.testing.expectError(error.BadFlagValue, parseInitArgs(&.{"--now=not a date"}));
    try std.testing.expectError(error.BadFlagValue, parseInitArgs(&.{"--now="}));
    try std.testing.expectError(error.BadFlagValue, parseInitArgs(&.{"--now=2026-05-10"}));
    try std.testing.expectError(error.BadFlagValue, parseInitArgs(&.{"--now=2026-05-10T14:00:00"}));
    try std.testing.expectError(error.BadFlagValue, parseInitArgs(&.{"--now=2026/05/10T14:00:00Z"}));
}

test "parseInitArgs: --seed= malformed rejected" {
    try std.testing.expectError(error.BadFlagValue, parseInitArgs(&.{"--seed=notanumber"}));
}

test "parseInitArgs: --seed= hex and decimal both accepted" {
    const a = try parseInitArgs(&.{"--seed=0xCAFE"});
    try std.testing.expectEqual(@as(?u64, 0xCAFE), a.rng_seed_override);
    const b = try parseInitArgs(&.{"--seed=42"});
    try std.testing.expectEqual(@as(?u64, 42), b.rng_seed_override);
}

test "parseInitArgs: -r requires value" {
    try std.testing.expectError(error.BadFlagValue, parseInitArgs(&.{"-r"}));
}

test "parseInitArgs: flag ordering does not matter" {
    const a = try parseInitArgs(&.{ "-y", "--root", "/tmp/x", "-q" });
    try std.testing.expect(a.yes);
    try std.testing.expect(a.quiet);
    try std.testing.expectEqualStrings("/tmp/x", a.root);
    const b = try parseInitArgs(&.{ "--root", "/tmp/x", "-y", "-q" });
    try std.testing.expect(b.yes);
    try std.testing.expect(b.quiet);
    try std.testing.expectEqualStrings("/tmp/x", b.root);
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

test "parseStackArgs: output threads and routine commands" {
    const out = try parseStackArgs(&.{ "output", "demo", "0001" });
    try std.testing.expectEqual(StackAction.output, out.action);
    try std.testing.expectEqualStrings("demo", out.name);
    try std.testing.expectEqualStrings("0001", out.item_id);

    const threads = try parseStackArgs(&.{ "threads", "demo" });
    try std.testing.expectEqual(StackAction.threads, threads.action);
    try std.testing.expectEqualStrings("demo", threads.name);

    const show = try parseStackArgs(&.{ "thread", "show", "demo", "admin" });
    try std.testing.expectEqual(StackAction.thread_show, show.action);
    try std.testing.expectEqualStrings("admin", show.thread_name);

    const create = try parseStackArgs(&.{ "thread", "create", "demo", "admin", "--provider", "openai", "--model", "gpt" });
    try std.testing.expectEqual(StackAction.thread_create, create.action);
    try std.testing.expectEqualStrings("openai", create.target);
    try std.testing.expectEqualStrings("gpt", create.replacement);

    const routine = try parseStackArgs(&.{ "run-routine", "demo", "review" });
    try std.testing.expectEqual(StackAction.run_routine, routine.action);
    try std.testing.expectEqualStrings("review", routine.routine_name);
}

test "parseStackArgs: add threaded input item" {
    const a = try parseStackArgs(&.{ "add", "demo", "prompt", "--thread", "admin", "--thread-mode", "resume", "--input-item", "0001" });
    try std.testing.expectEqual(StackAction.add, a.action);
    try std.testing.expectEqualStrings("admin", a.thread_name);
    try std.testing.expectEqualStrings("resume", a.thread_mode);
    try std.testing.expectEqual(@as(u8, 1), a.input_item_count);
    try std.testing.expectEqualStrings("0001", a.input_items[0]);
}

test "parseRoutineArgs: list and show" {
    const list = try parseRoutineArgs(&.{"list"});
    try std.testing.expectEqual(RoutineAction.list, list.action);
    const show = try parseRoutineArgs(&.{ "show", "review", "--json" });
    try std.testing.expectEqual(RoutineAction.show, show.action);
    try std.testing.expectEqualStrings("review", show.name);
    try std.testing.expect(show.flags.json);
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

// ---------- mutation subcommand parser tests (milestone 5) ----------

test "parseStackArgs: new <name>" {
    const a = try parseStackArgs(&.{ "new", "demo" });
    try std.testing.expectEqual(StackAction.new, a.action);
    try std.testing.expectEqualStrings("demo", a.name);
}

test "parseStackArgs: add with kind, target shorthand, prompt file" {
    const a = try parseStackArgs(&.{ "add", "demo", "prompt", "-t", "anthropic/claude-opus-4-7", "-f", "p.md" });
    try std.testing.expectEqual(StackAction.add, a.action);
    try std.testing.expectEqualStrings("demo", a.name);
    try std.testing.expectEqualStrings("prompt", a.kind);
    try std.testing.expectEqualStrings("anthropic/claude-opus-4-7", a.target);
    try std.testing.expectEqualStrings("p.md", a.prompt_file);
}

test "parseStackArgs: insert <name> <ref> <kind>" {
    const a = try parseStackArgs(&.{ "ins", "demo", "0002", "prompt" });
    try std.testing.expectEqual(StackAction.insert, a.action);
    try std.testing.expectEqualStrings("demo", a.name);
    try std.testing.expectEqualStrings("0002", a.ref);
    try std.testing.expectEqualStrings("prompt", a.kind);
}

test "parseStackArgs: retry/cancel short aliases" {
    const r = try parseStackArgs(&.{ "rt", "demo", "0001" });
    try std.testing.expectEqual(StackAction.retry, r.action);
    try std.testing.expectEqualStrings("0001", r.item_id);
    const c = try parseStackArgs(&.{ "cx", "demo", "0001" });
    try std.testing.expectEqual(StackAction.cancel, c.action);
}

test "parseStackArgs: supersede has replacement positional" {
    const a = try parseStackArgs(&.{ "sup", "demo", "0001", "0007" });
    try std.testing.expectEqual(StackAction.supersede, a.action);
    try std.testing.expectEqualStrings("0001", a.item_id);
    try std.testing.expectEqualStrings("0007", a.replacement);
}

test "parseStackArgs: pause / resume short aliases" {
    const p = try parseStackArgs(&.{ "p", "demo" });
    try std.testing.expectEqual(StackAction.pause, p.action);
    const r = try parseStackArgs(&.{ "r", "demo" });
    try std.testing.expectEqual(StackAction.@"resume", r.action);
}

test "parseStackArgs: config --set key=value collects entries" {
    const a = try parseStackArgs(&.{ "cfg", "demo", "-s", "paused=true", "--set=continuity=chain" });
    try std.testing.expectEqual(StackAction.config, a.action);
    try std.testing.expectEqual(@as(u8, 2), a.set_count);
    try std.testing.expectEqualStrings("paused=true", a.set_pairs[0]);
    try std.testing.expectEqualStrings("continuity=chain", a.set_pairs[1]);
}

test "parseStackArgs: add missing kind rejected" {
    try std.testing.expectError(error.NoSubcommand, parseStackArgs(&.{ "add", "demo" }));
}

test "parseStackArgs: supersede missing replacement rejected" {
    try std.testing.expectError(error.NoSubcommand, parseStackArgs(&.{ "sup", "demo", "0001" }));
}

// ---------- auth parser tests (milestone 8) ----------

test "parseAuthArgs: bare auth defaults to status" {
    const a = try parseAuthArgs(&.{});
    try std.testing.expectEqual(AuthAction.status, a.action);
    try std.testing.expectEqualStrings("", a.provider_name);
}

test "parseAuthArgs: explicit status and short alias" {
    const a = try parseAuthArgs(&.{"status"});
    try std.testing.expectEqual(AuthAction.status, a.action);
    const b = try parseAuthArgs(&.{"st"});
    try std.testing.expectEqual(AuthAction.status, b.action);
}

test "parseAuthArgs: provider shortcut" {
    const a = try parseAuthArgs(&.{"anthropic"});
    try std.testing.expectEqual(AuthAction.provider, a.action);
    try std.testing.expectEqualStrings("anthropic", a.provider_name);
}

test "parseAuthArgs: signout + provider" {
    const a = try parseAuthArgs(&.{ "signout", "openai" });
    try std.testing.expectEqual(AuthAction.signout, a.action);
    try std.testing.expectEqualStrings("openai", a.provider_name);
    const b = try parseAuthArgs(&.{ "out", "claude" });
    try std.testing.expectEqual(AuthAction.signout, b.action);
    try std.testing.expectEqualStrings("claude", b.provider_name);
}

test "parseAuthArgs: signout without provider rejected" {
    try std.testing.expectError(error.NoSubcommand, parseAuthArgs(&.{"signout"}));
}

test "parseAuthArgs: --json flag picked up" {
    const a = try parseAuthArgs(&.{ "status", "--json" });
    try std.testing.expect(a.flags.json);
    const b = try parseAuthArgs(&.{ "-j", "claude" });
    try std.testing.expect(b.flags.json);
    try std.testing.expectEqual(AuthAction.provider, b.action);
}

test "Subcommand: auth and short alias a" {
    try std.testing.expectEqual(Subcommand.auth, Subcommand.fromString("auth").?);
    try std.testing.expectEqual(Subcommand.auth, Subcommand.fromString("a").?);
}
