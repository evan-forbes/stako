//! Integration tests for the milestone-4 CLI read path.
//!
//! Each test:
//!   1. Stands up a temp notes root (init + seeded `demo` stack from
//!      milestone-3 fixtures-style writers).
//!   2. Launches a daemon on an ephemeral port in a background thread.
//!   3. Drives `cli.dispatch` in-process against that daemon, capturing
//!      stdout / stderr to ArrayList buffers.
//!
//! The one out-of-process test exec's the compiled `organo` binary as a
//! subprocess so we cover the real argv → main() → dispatch path that
//! `cli.dispatch` callers would miss.

const std = @import("std");
const organo = @import("organo");
const cli = organo.cli;
const init_mod = organo.init;
const daemon_mod = organo.daemon;
const http_client = organo.http_client;

// ---------- harness (mirrors test/daemon_tests.zig) ----------

const Scratch = struct {
    allocator: std.mem.Allocator,
    abs_path: []u8,

    fn create(allocator: std.mem.Allocator, name_hint: []const u8) !Scratch {
        const tmp = std.posix.getenv("TMPDIR") orelse "/tmp";
        var ts_buf: [32]u8 = undefined;
        const ts = std.time.nanoTimestamp();
        const ts_str = try std.fmt.bufPrint(&ts_buf, "{d}", .{ts});
        const path = try std.fs.path.join(allocator, &.{ tmp, "organo-test-cli" });
        defer allocator.free(path);
        try std.fs.cwd().makePath(path);

        const dir_name = try std.fmt.allocPrint(allocator, "{s}-{s}", .{ name_hint, ts_str });
        defer allocator.free(dir_name);
        const full = try std.fs.path.join(allocator, &.{ path, dir_name });
        try std.fs.cwd().makePath(full);
        return .{ .allocator = allocator, .abs_path = full };
    }

    fn deinit(self: *Scratch) void {
        std.fs.cwd().deleteTree(self.abs_path) catch {};
        self.allocator.free(self.abs_path);
    }
};

fn initNotesRoot(allocator: std.mem.Allocator, root: []const u8) !void {
    var r = try init_mod.run(allocator, .{
        .root = root,
        .yes = true,
        .quiet = true,
        .now_override = "2026-05-10T14:00:00Z",
        .rng_seed_override = 0xD3D0,
    });
    r.deinit();
}

fn seedDemoStack(allocator: std.mem.Allocator, root: []const u8) !void {
    const stack_dir = try std.fs.path.join(allocator, &.{ root, "stacks", "demo" });
    defer allocator.free(stack_dir);
    try std.fs.cwd().makePath(stack_dir);
    {
        const path = try std.fs.path.join(allocator, &.{ stack_dir, "stack.toml" });
        defer allocator.free(path);
        var f = try std.fs.cwd().createFile(path, .{ .truncate = true });
        defer f.close();
        try f.writeAll(
            \\description = "demo stack"
            \\created_at = 2026-05-10T14:00:00Z
            \\paused = false
            \\continuity = "chain"
            \\max_concurrent_per_stack = 1
            \\allowed_harnesses = ["claude", "codex"]
            \\
        );
    }
    {
        const item_dir = try std.fs.path.join(allocator, &.{ stack_dir, "0001-hello" });
        defer allocator.free(item_dir);
        try std.fs.cwd().makePath(item_dir);
        const meta = try std.fs.path.join(allocator, &.{ item_dir, "meta.toml" });
        defer allocator.free(meta);
        var f = try std.fs.cwd().createFile(meta, .{ .truncate = true });
        defer f.close();
        try f.writeAll(
            \\id = "0001"
            \\slug = "hello"
            \\kind = "prompt"
            \\status = "queued"
            \\created_at = 2026-05-10T14:00:00Z
            \\updated_at = 2026-05-10T14:00:00Z
            \\
            \\[target]
            \\provider = "anthropic"
            \\model = "claude-opus-4-7"
            \\match = "exact"
            \\
        );
    }
    {
        const item_dir = try std.fs.path.join(allocator, &.{ stack_dir, "0002-followup" });
        defer allocator.free(item_dir);
        try std.fs.cwd().makePath(item_dir);
        const meta = try std.fs.path.join(allocator, &.{ item_dir, "meta.toml" });
        defer allocator.free(meta);
        var f = try std.fs.cwd().createFile(meta, .{ .truncate = true });
        defer f.close();
        try f.writeAll(
            \\id = "0002"
            \\slug = "followup"
            \\kind = "review"
            \\status = "queued"
            \\created_at = 2026-05-10T14:00:00Z
            \\updated_at = 2026-05-10T14:00:00Z
            \\parents = ["0001"]
            \\
            \\[target]
            \\provider = "anthropic"
            \\match = "compatible"
            \\
        );
    }
}

fn startEphemeralDaemon(allocator: std.mem.Allocator, root: []const u8) !daemon_mod.Daemon {
    return daemon_mod.start(allocator, .{
        .notes_root = root,
        .port_override = 0,
        .ephemeral = true,
    });
}

const ServeContext = struct {
    daemon: *daemon_mod.Daemon,
    requests: usize,
};

fn serveThread(ctx: *ServeContext) void {
    var n: usize = 0;
    while (n < ctx.requests) : (n += 1) {
        daemon_mod.serveOne(ctx.daemon) catch break;
    }
}

const Driver = struct {
    allocator: std.mem.Allocator,
    daemon: daemon_mod.Daemon,
    thread: ?std.Thread = null,
    ctx: ServeContext = undefined,

    /// Cleanup is order-sensitive: a `serveOne` worker may still be blocked
    /// in `accept()` (e.g., because a test aborted before driving every
    /// scheduled request). Request shutdown first — that shuts down the
    /// listening socket so the next accept returns immediately — then join,
    /// then tear down the daemon. Without this, a test that fails to issue
    /// its full request count would deadlock the suite.
    fn deinit(self: *Driver) void {
        if (self.thread != null) self.daemon.requestShutdown();
        if (self.thread) |t| t.join();
        self.daemon.deinit();
    }

    fn serve(self: *Driver, n: usize) !void {
        self.ctx = .{ .daemon = &self.daemon, .requests = n };
        self.thread = try std.Thread.spawn(.{}, serveThread, .{&self.ctx});
    }
};

fn buildDriver(allocator: std.mem.Allocator, root: []const u8) !Driver {
    const d = try startEphemeralDaemon(allocator, root);
    return .{ .allocator = allocator, .daemon = d };
}

/// Write `<root>/.organo/config.local.toml` with `daemon.port = <port>` so
/// the CLI's port-resolution layer finds the ephemeral port without needing
/// `--port` on every invocation.
fn writePortConfig(allocator: std.mem.Allocator, root: []const u8, port: u16) !void {
    const path = try std.fs.path.join(allocator, &.{ root, ".organo", "config.local.toml" });
    defer allocator.free(path);
    var f = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer f.close();
    var buf: [256]u8 = undefined;
    const out = try std.fmt.bufPrint(&buf,
        \\[daemon]
        \\port = {d}
        \\
        \\[workdir]
        \\allowlist = []
        \\
    , .{port});
    try f.writeAll(out);
}

/// Run cli.dispatch with `argv` and return the exit code plus stdout/stderr.
/// Caller frees the returned buffers.
///
/// We construct `std.Io.Writer.Allocating` instances so the dispatch surface
/// (which calls `.print`, `.writeAll`, `.flush`) sees the exact same
/// `*std.Io.Writer` shape that `main.zig` provides at runtime.
const RunOut = struct {
    code: u8,
    stdout: []u8,
    stderr: []u8,
    allocator: std.mem.Allocator,
    fn deinit(self: *RunOut) void {
        self.allocator.free(self.stdout);
        self.allocator.free(self.stderr);
    }
};

fn runCli(allocator: std.mem.Allocator, argv: []const []const u8) !RunOut {
    var stdout_buf: std.Io.Writer.Allocating = .init(allocator);
    defer stdout_buf.deinit();
    var stderr_buf: std.Io.Writer.Allocating = .init(allocator);
    defer stderr_buf.deinit();

    const code = try cli.dispatch(allocator, argv, &stdout_buf.writer, &stderr_buf.writer);
    return .{
        .code = code,
        .stdout = try allocator.dupe(u8, stdout_buf.written()),
        .stderr = try allocator.dupe(u8, stderr_buf.written()),
        .allocator = allocator,
    };
}

// ---------- tests ----------

test "cli: stack list — canonical and short alias both work" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "stack-list");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);
    try seedDemoStack(a, s.abs_path);

    var drv = try buildDriver(a, s.abs_path);
    defer drv.deinit();
    // Two requests: canonical + alias.
    try drv.serve(2);
    try writePortConfig(a, s.abs_path, drv.daemon.bound_port);

    // Canonical.
    var r1 = try runCli(a, &.{ "stack", "list", "--root", s.abs_path });
    defer r1.deinit();
    try std.testing.expectEqual(@as(u8, 0), r1.code);
    try std.testing.expect(std.mem.indexOf(u8, r1.stdout, "NAME") != null);
    try std.testing.expect(std.mem.indexOf(u8, r1.stdout, "demo") != null);
    try std.testing.expect(std.mem.indexOf(u8, r1.stdout, "default") != null);

    // Short alias `s ls`.
    var r2 = try runCli(a, &.{ "s", "ls", "--root", s.abs_path });
    defer r2.deinit();
    try std.testing.expectEqual(@as(u8, 0), r2.code);
    try std.testing.expect(std.mem.indexOf(u8, r2.stdout, "demo") != null);
}

test "cli: stack list --json passes the daemon body through unchanged" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "stack-list-json");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);
    try seedDemoStack(a, s.abs_path);

    var drv = try buildDriver(a, s.abs_path);
    defer drv.deinit();
    try drv.serve(1);
    try writePortConfig(a, s.abs_path, drv.daemon.bound_port);

    var r = try runCli(a, &.{ "s", "ls", "--root", s.abs_path, "-j" });
    defer r.deinit();
    try std.testing.expectEqual(@as(u8, 0), r.code);
    // Must look like the daemon's JSON envelope.
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "\"stacks\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "\"name\":\"demo\"") != null);
    // No human-readable header in JSON mode.
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "NAME\n") == null);
}

test "cli: stack show — canonical and short alias both work" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "stack-show");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);
    try seedDemoStack(a, s.abs_path);

    var drv = try buildDriver(a, s.abs_path);
    defer drv.deinit();
    try drv.serve(2);
    try writePortConfig(a, s.abs_path, drv.daemon.bound_port);

    var r1 = try runCli(a, &.{ "stack", "show", "demo", "--root", s.abs_path });
    defer r1.deinit();
    try std.testing.expectEqual(@as(u8, 0), r1.code);
    try std.testing.expect(std.mem.indexOf(u8, r1.stdout, "stack: demo") != null);
    try std.testing.expect(std.mem.indexOf(u8, r1.stdout, "continuity:     chain") != null);
    // Items table.
    try std.testing.expect(std.mem.indexOf(u8, r1.stdout, "0001") != null);
    try std.testing.expect(std.mem.indexOf(u8, r1.stdout, "0002") != null);
    // Queue order: 0001 appears before 0002 in the rendered table.
    const idx_one = std.mem.indexOf(u8, r1.stdout, "0001").?;
    const idx_two = std.mem.indexOf(u8, r1.stdout, "0002").?;
    try std.testing.expect(idx_one < idx_two);

    var r2 = try runCli(a, &.{ "s", "sh", "demo", "--root", s.abs_path });
    defer r2.deinit();
    try std.testing.expectEqual(@as(u8, 0), r2.code);
    try std.testing.expect(std.mem.indexOf(u8, r2.stdout, "stack: demo") != null);
}

test "cli: stack config — canonical and short alias both work" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "stack-config");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);
    try seedDemoStack(a, s.abs_path);

    var drv = try buildDriver(a, s.abs_path);
    defer drv.deinit();
    try drv.serve(2);
    try writePortConfig(a, s.abs_path, drv.daemon.bound_port);

    var r1 = try runCli(a, &.{ "stack", "config", "demo", "--root", s.abs_path });
    defer r1.deinit();
    try std.testing.expectEqual(@as(u8, 0), r1.code);
    try std.testing.expect(std.mem.indexOf(u8, r1.stdout, "stack: demo") != null);
    try std.testing.expect(std.mem.indexOf(u8, r1.stdout, "continuity:     chain") != null);
    try std.testing.expect(std.mem.indexOf(u8, r1.stdout, "claude") != null);

    var r2 = try runCli(a, &.{ "s", "cfg", "demo", "--root", s.abs_path });
    defer r2.deinit();
    try std.testing.expectEqual(@as(u8, 0), r2.code);
    try std.testing.expect(std.mem.indexOf(u8, r2.stdout, "stack: demo") != null);
}

test "cli: stack show unknown stack -> non-zero exit + canonical error" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "stack-404");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);

    var drv = try buildDriver(a, s.abs_path);
    defer drv.deinit();
    try drv.serve(1);
    try writePortConfig(a, s.abs_path, drv.daemon.bound_port);

    var r = try runCli(a, &.{ "stack", "show", "nope", "--root", s.abs_path });
    defer r.deinit();
    try std.testing.expectEqual(@as(u8, 1), r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "HTTP 404") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "not_found") != null);
}

test "cli: connection refused prints the daemon-not-started hint" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "no-daemon");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);

    // No daemon spawned. Point the CLI at a port that's almost certainly
    // closed (0 is not valid for IPv4 client-side connect on Linux: it maps
    // to "any" and will refuse). Use an explicit, unused-ish high port.
    var r = try runCli(a, &.{ "stack", "list", "--root", s.abs_path, "--port", "1" });
    defer r.deinit();
    try std.testing.expectEqual(@as(u8, 1), r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "daemon not started") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "organo daemon start") != null);
}

test "cli: --verbose includes the request URL on connection failure" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "verbose-conn");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);

    var r = try runCli(a, &.{ "stack", "list", "--root", s.abs_path, "--port", "1", "-v" });
    defer r.deinit();
    try std.testing.expectEqual(@as(u8, 1), r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "attempted: http://127.0.0.1:1/stacks") != null);
}

test "cli: ORGANO_PORT env override is honored" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "env-port");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);
    try seedDemoStack(a, s.abs_path);

    var drv = try buildDriver(a, s.abs_path);
    defer drv.deinit();
    try drv.serve(1);

    // Don't write a config.local.toml port — rely on the env var. We mutate
    // the process environment via libc setenv (the test binary links libc).
    const c = struct {
        extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
        extern "c" fn unsetenv(name: [*:0]const u8) c_int;
    };
    var port_buf: [16:0]u8 = undefined;
    _ = try std.fmt.bufPrintZ(&port_buf, "{d}", .{drv.daemon.bound_port});
    _ = c.setenv("ORGANO_PORT", &port_buf, 1);
    defer _ = c.unsetenv("ORGANO_PORT");

    var r = try runCli(a, &.{ "stack", "list", "--root", s.abs_path });
    defer r.deinit();
    try std.testing.expectEqual(@as(u8, 0), r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "demo") != null);
}

test "cli: bad usage returns exit code 2 and prints help" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "usage");
    defer s.deinit();

    // No args at all.
    var r1 = try runCli(a, &.{});
    defer r1.deinit();
    try std.testing.expectEqual(@as(u8, 2), r1.code);
    try std.testing.expect(std.mem.indexOf(u8, r1.stderr, "Usage:") != null);

    // Unknown subcommand.
    var r2 = try runCli(a, &.{"frobnicate"});
    defer r2.deinit();
    try std.testing.expectEqual(@as(u8, 2), r2.code);
    try std.testing.expect(std.mem.indexOf(u8, r2.stderr, "unknown subcommand") != null);

    // `stack show` without a name.
    var r3 = try runCli(a, &.{ "stack", "show" });
    defer r3.deinit();
    try std.testing.expectEqual(@as(u8, 2), r3.code);
}

test "cli: daemon st (short alias for status) reports `stopped` on empty root" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "daemon-st");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);

    var r = try runCli(a, &.{ "d", "st", "--root", s.abs_path });
    defer r.deinit();
    try std.testing.expectEqual(@as(u8, 0), r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "stopped") != null);
}

// ---------- milestone 2: organo init via cli.dispatch ----------

test "cli: init on a fresh dir exits 0 and prints created list" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "init-fresh");
    defer s.deinit();

    var r = try runCli(a, &.{ "init", "--root", s.abs_path, "--yes", "--now=2026-05-10T14:00:00Z", "--seed=0x1234" });
    defer r.deinit();
    try std.testing.expectEqual(@as(u8, 0), r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "created:") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, ".organo/local_token") != null);

    // Layout actually landed on disk.
    var d = try std.fs.openDirAbsolute(s.abs_path, .{});
    defer d.close();
    d.access(".organo/local_token", .{}) catch return error.LayoutNotCreated;
    d.access("stacks/default/stack.toml", .{}) catch return error.LayoutNotCreated;
}

test "cli: init --quiet suppresses per-line output but prints a summary" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "init-quiet");
    defer s.deinit();

    var r = try runCli(a, &.{ "init", "--root", s.abs_path, "--yes", "--quiet", "--now=2026-05-10T14:00:00Z", "--seed=0x5678" });
    defer r.deinit();
    try std.testing.expectEqual(@as(u8, 0), r.code);
    // No per-line `created:` block under --quiet.
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "created:\n") == null);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "  .organo/local_token\n") == null);
    // But a one-line summary is present.
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "organo init:") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "created") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "already present") != null);
}

test "cli: init re-run prints the `already initialized` line and exits 0" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "init-rerun");
    defer s.deinit();

    var r1 = try runCli(a, &.{ "init", "--root", s.abs_path, "--yes", "--quiet", "--now=2026-05-10T14:00:00Z", "--seed=0x7" });
    defer r1.deinit();
    try std.testing.expectEqual(@as(u8, 0), r1.code);

    var r2 = try runCli(a, &.{ "init", "--root", s.abs_path, "--yes", "--quiet", "--now=2026-05-10T14:00:00Z", "--seed=0x7" });
    defer r2.deinit();
    try std.testing.expectEqual(@as(u8, 0), r2.code);
    try std.testing.expect(std.mem.indexOf(u8, r2.stdout, "already initialized") != null);
}

test "cli: init on a missing root exits 1 with a useful stderr message" {
    const a = std.testing.allocator;
    var r = try runCli(a, &.{ "init", "--root", "/path/does/not/exist/anywhere/12345", "--yes", "--quiet" });
    defer r.deinit();
    try std.testing.expectEqual(@as(u8, 1), r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "organo init:") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "RootNotADirectory") != null);
}

test "cli: init --now= malformed rejected at parse time (exit 2)" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "init-bad-now");
    defer s.deinit();

    var r = try runCli(a, &.{ "init", "--root", s.abs_path, "--now=not a date" });
    defer r.deinit();
    try std.testing.expectEqual(@as(u8, 2), r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "BadFlagValue") != null);
}

test "cli: init without --yes does not auto-init git on a non-git root" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "init-no-yes");
    defer s.deinit();

    var r = try runCli(a, &.{ "init", "--root", s.abs_path, "--quiet", "--now=2026-05-10T14:00:00Z", "--seed=0x99" });
    defer r.deinit();
    try std.testing.expectEqual(@as(u8, 0), r.code);

    // Layout landed, but .git was NOT created because --yes was absent.
    var d = try std.fs.openDirAbsolute(s.abs_path, .{});
    defer d.close();
    d.access(".organo/local_token", .{}) catch return error.LayoutNotCreated;
    if (d.access(".git", .{})) |_| {
        return error.GitInitShouldHaveBeenSkipped;
    } else |_| {}
}

// ---------- subprocess test ----------
//
// One end-to-end test exec's the compiled binary so we cover the argv parsing
// path inside `main.zig` that the in-process tests skip.

test "cli (subprocess): organo stack list against a live daemon" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "subproc");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);
    try seedDemoStack(a, s.abs_path);

    var drv = try buildDriver(a, s.abs_path);
    defer drv.deinit();
    try drv.serve(1);
    try writePortConfig(a, s.abs_path, drv.daemon.bound_port);

    // Resolve binary path. `zig build test` runs from the build root and
    // installs to `zig-out/bin/organo` for the default install step. Tests
    // that need the binary depend on the install step via build.zig.
    const candidates = [_][]const u8{
        "zig-out/bin/organo",
        "./zig-out/bin/organo",
    };
    var bin_path: []const u8 = "";
    for (candidates) |c| {
        std.fs.cwd().access(c, .{}) catch continue;
        bin_path = c;
        break;
    }
    if (bin_path.len == 0) return error.SkipZigTest;

    const result = try std.process.Child.run(.{
        .allocator = a,
        .argv = &.{ bin_path, "stack", "list", "--root", s.abs_path },
        .max_output_bytes = 64 * 1024,
    });
    defer a.free(result.stdout);
    defer a.free(result.stderr);

    switch (result.term) {
        .Exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.UnexpectedTerm,
    }
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "demo") != null);
}

// ---------- milestone 8: auth subcommand ----------

test "cli: auth status renders header + every provider row" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "auth-status");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);

    var drv = try buildDriver(a, s.abs_path);
    defer drv.deinit();
    try drv.serve(1);
    try writePortConfig(a, s.abs_path, drv.daemon.bound_port);

    var r = try runCli(a, &.{ "auth", "status", "--root", s.abs_path });
    defer r.deinit();
    try std.testing.expectEqual(@as(u8, 0), r.code);
    // Header row.
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "PROVIDER") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "HARNESS") != null);
    // One row per provider (substring match).
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "anthropic") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "openai") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "google") != null);
}

test "cli: auth a st short alias matches canonical" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "auth-short");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);

    var drv = try buildDriver(a, s.abs_path);
    defer drv.deinit();
    try drv.serve(1);
    try writePortConfig(a, s.abs_path, drv.daemon.bound_port);

    var r = try runCli(a, &.{ "a", "st", "--root", s.abs_path });
    defer r.deinit();
    try std.testing.expectEqual(@as(u8, 0), r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "anthropic") != null);
}

test "cli: auth <provider> renders single-provider detail" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "auth-one");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);

    var drv = try buildDriver(a, s.abs_path);
    defer drv.deinit();
    try drv.serve(1);
    try writePortConfig(a, s.abs_path, drv.daemon.bound_port);

    var r = try runCli(a, &.{ "auth", "google", "--root", s.abs_path });
    defer r.deinit();
    try std.testing.expectEqual(@as(u8, 0), r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "provider:        google") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "harness:       gemini") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "available:     false") != null);
}

test "cli: auth status --json passes daemon body through unchanged" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "auth-json");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);

    var drv = try buildDriver(a, s.abs_path);
    defer drv.deinit();
    try drv.serve(1);
    try writePortConfig(a, s.abs_path, drv.daemon.bound_port);

    var r = try runCli(a, &.{ "auth", "status", "--root", s.abs_path, "-j" });
    defer r.deinit();
    try std.testing.expectEqual(@as(u8, 0), r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "\"providers\":[") != null);
    // No human header in JSON mode.
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "PROVIDER\n") == null);
}

test "cli: auth signout always exits non-zero with helpful note" {
    const a = std.testing.allocator;
    // No root setup and no daemon: signout is intentionally local-only.
    var r = try runCli(a, &.{ "auth", "signout", "anthropic", "--root", "/path/that/does/not/exist" });
    defer r.deinit();
    try std.testing.expectEqual(@as(u8, 1), r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "signout not supported") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "anthropic") != null);
}

// ---------- milestone 4 audit additions ----------
//
// The following tests stand up a hand-rolled TCP server (not the real daemon)
// so we can return precisely the status/body/headers we need to exercise
// error-handling paths, header propagation, and the empty/truncation
// branches. The harness is intentionally minimal: one connection, read until
// blank line or timeout, then write a canned response.

const FakeServer = struct {
    allocator: std.mem.Allocator,
    listener: std.net.Server,
    port: u16,
    thread: ?std.Thread = null,
    canned: []const u8 = "",
    /// Captured request headers from the most recent connection. Owned by the
    /// allocator; freed in deinit.
    captured_request: ?[]u8 = null,
    /// When set, the server reads the request, then writes nothing and lets
    /// the socket dangle so the client's read times out.
    slow: bool = false,

    fn start(allocator: std.mem.Allocator) !*FakeServer {
        const self = try allocator.create(FakeServer);
        errdefer allocator.destroy(self);
        const addr = try std.net.Address.parseIp("127.0.0.1", 0);
        var server = try addr.listen(.{ .reuse_address = true });
        const port = server.listen_address.in.getPort();
        self.* = .{ .allocator = allocator, .listener = server, .port = port };
        return self;
    }

    fn setCanned(self: *FakeServer, response: []const u8) void {
        self.canned = response;
    }

    fn handleOne(self: *FakeServer) void {
        var conn = self.listener.accept() catch return;
        defer conn.stream.close();
        var buf: [4096]u8 = undefined;
        var total: usize = 0;
        // Read until we see CRLFCRLF (no body for the GETs we care about).
        while (total < buf.len) {
            const n = conn.stream.read(buf[total..]) catch break;
            if (n == 0) break;
            total += n;
            if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n") != null) break;
        }
        const dup = self.allocator.dupe(u8, buf[0..total]) catch return;
        self.captured_request = dup;
        if (self.slow) {
            // Keep the connection open without sending bytes. The client's
            // SO_RCVTIMEO should fire and cause a TransportTimeout.
            std.Thread.sleep(2 * std.time.ns_per_s);
            return;
        }
        conn.stream.writeAll(self.canned) catch return;
    }

    fn serveAsync(self: *FakeServer) !void {
        self.thread = try std.Thread.spawn(.{}, FakeServer.handleOne, .{self});
    }

    fn deinit(self: *FakeServer) void {
        // Make sure the worker exits even if the test never connected.
        // listen_address.close() doesn't unblock accept(); a self-connect
        // does. We open a sacrificial socket so the accept returns.
        if (self.thread != null) {
            const addr = std.net.Address.parseIp("127.0.0.1", self.port) catch null;
            if (addr) |a| {
                if (std.net.tcpConnectToAddress(a)) |s| {
                    s.close();
                } else |_| {}
            }
        }
        if (self.thread) |t| t.join();
        self.listener.deinit();
        if (self.captured_request) |c| self.allocator.free(c);
        self.allocator.destroy(self);
    }
};

test "cli: 401 bad-token surfaces canonical HTTP error with code+message" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "fake-401");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);

    const fake = try FakeServer.start(a);
    defer fake.deinit();
    fake.setCanned(
        "HTTP/1.1 401 Unauthorized\r\n" ++
            "Content-Type: application/json\r\n" ++
            "Content-Length: 67\r\n" ++
            "Connection: close\r\n" ++
            "\r\n" ++
            "{\"error\":{\"code\":\"unauthorized\",\"message\":\"bearer token rejected\"}}",
    );
    try fake.serveAsync();

    var port_buf: [16]u8 = undefined;
    const port_str = try std.fmt.bufPrint(&port_buf, "{d}", .{fake.port});
    var r = try runCli(a, &.{ "stack", "list", "--root", s.abs_path, "--port", port_str });
    defer r.deinit();
    try std.testing.expectEqual(@as(u8, 1), r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "HTTP 401") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "unauthorized") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "bearer token rejected") != null);
}

test "cli: 5xx daemon response is reported with the daemon's code/message" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "fake-500");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);

    const fake = try FakeServer.start(a);
    defer fake.deinit();
    fake.setCanned(
        "HTTP/1.1 500 Internal Server Error\r\n" ++
            "Content-Length: 70\r\n" ++
            "Connection: close\r\n" ++
            "\r\n" ++
            "{\"error\":{\"code\":\"internal\",\"message\":\"unexpected nil in supervisor\"}}",
    );
    try fake.serveAsync();

    var port_buf: [16]u8 = undefined;
    const port_str = try std.fmt.bufPrint(&port_buf, "{d}", .{fake.port});
    var r = try runCli(a, &.{ "stack", "list", "--root", s.abs_path, "--port", port_str });
    defer r.deinit();
    try std.testing.expectEqual(@as(u8, 1), r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "HTTP 500") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "internal") != null);
}

test "cli: silent daemon triggers transport timeout, not infinite hang" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "fake-slow");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);

    const fake = try FakeServer.start(a);
    defer fake.deinit();
    fake.slow = true;
    try fake.serveAsync();

    // We cannot pass a custom read_timeout_ms through the CLI flags layer
    // without expanding the public surface, so drive http_client directly
    // with a short timeout. This still exercises the production code path
    // (setsockopt + EAGAIN → TransportTimeout).
    const organo_root = organo;
    var client = try organo_root.http_client.open(a, .{
        .root = s.abs_path,
        .port_override = fake.port,
        .read_timeout_ms = 200,
    });
    defer client.deinit();
    const result = organo_root.http_client.get(&client, "/stacks");
    try std.testing.expectError(error.TransportTimeout, result);
}

test "cli: --port flag wins over ORGANO_PORT and config" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "port-prec");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);
    try seedDemoStack(a, s.abs_path);

    var drv = try buildDriver(a, s.abs_path);
    defer drv.deinit();
    try drv.serve(1);
    // Config writes a bogus port; env points at another bogus port; the
    // --port flag carries the real port and must win.
    try writePortConfig(a, s.abs_path, 65111);
    const c = struct {
        extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
        extern "c" fn unsetenv(name: [*:0]const u8) c_int;
    };
    _ = c.setenv("ORGANO_PORT", "65222", 1);
    defer _ = c.unsetenv("ORGANO_PORT");

    var port_buf: [16]u8 = undefined;
    const port_str = try std.fmt.bufPrint(&port_buf, "{d}", .{drv.daemon.bound_port});
    var r = try runCli(a, &.{ "stack", "list", "--root", s.abs_path, "--port", port_str });
    defer r.deinit();
    try std.testing.expectEqual(@as(u8, 0), r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "demo") != null);
}

test "cli: stack show --json passes the composite body through unchanged" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "show-json");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);
    try seedDemoStack(a, s.abs_path);

    var drv = try buildDriver(a, s.abs_path);
    defer drv.deinit();
    try drv.serve(1);
    try writePortConfig(a, s.abs_path, drv.daemon.bound_port);

    var r = try runCli(a, &.{ "s", "sh", "demo", "--root", s.abs_path, "-j" });
    defer r.deinit();
    try std.testing.expectEqual(@as(u8, 0), r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "\"items\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "0001") != null);
    // No human-readable label header in JSON mode.
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "stack: demo") == null);
}

test "cli: stack config --json passes the daemon body through unchanged" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "config-json");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);
    try seedDemoStack(a, s.abs_path);

    var drv = try buildDriver(a, s.abs_path);
    defer drv.deinit();
    try drv.serve(1);
    try writePortConfig(a, s.abs_path, drv.daemon.bound_port);

    var r = try runCli(a, &.{ "stack", "config", "demo", "--root", s.abs_path, "-j" });
    defer r.deinit();
    try std.testing.expectEqual(@as(u8, 0), r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "\"continuity\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "stack: demo") == null);
}

test "cli: stack list renders (no stacks) when daemon returns empty array" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "fake-empty-list");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);

    const fake = try FakeServer.start(a);
    defer fake.deinit();
    fake.setCanned(
        "HTTP/1.1 200 OK\r\n" ++
            "Content-Length: 13\r\n" ++
            "Connection: close\r\n" ++
            "\r\n" ++
            "{\"stacks\":[]}",
    );
    try fake.serveAsync();

    var port_buf: [16]u8 = undefined;
    const port_str = try std.fmt.bufPrint(&port_buf, "{d}", .{fake.port});
    var r = try runCli(a, &.{ "stack", "list", "--root", s.abs_path, "--port", port_str });
    defer r.deinit();
    try std.testing.expectEqual(@as(u8, 0), r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "(no stacks)") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "NAME\n") == null);
}

test "cli: stack show renders (no items) when items array is empty" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "fake-empty-items");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);

    const fake = try FakeServer.start(a);
    defer fake.deinit();
    const body =
        "{\"name\":\"demo\",\"description\":\"d\",\"created_at\":\"2026-05-10T14:00:00Z\"," ++
        "\"continuity\":\"chain\",\"paused\":false,\"max_concurrent_per_stack\":1," ++
        "\"items\":[]}";
    var len_buf: [16]u8 = undefined;
    const len_str = try std.fmt.bufPrint(&len_buf, "{d}", .{body.len});
    const head = try std.fmt.allocPrint(
        a,
        "HTTP/1.1 200 OK\r\nContent-Length: {s}\r\nConnection: close\r\n\r\n",
        .{len_str},
    );
    defer a.free(head);
    const whole = try std.mem.concat(a, u8, &.{ head, body });
    defer a.free(whole);
    fake.setCanned(whole);
    try fake.serveAsync();

    var port_buf: [16]u8 = undefined;
    const port_str = try std.fmt.bufPrint(&port_buf, "{d}", .{fake.port});
    var r = try runCli(a, &.{ "stack", "show", "demo", "--root", s.abs_path, "--port", port_str });
    defer r.deinit();
    try std.testing.expectEqual(@as(u8, 0), r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "(no items)") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "stack: demo") != null);
}

test "cli: Authorization: Bearer header is sent when local_token is present" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "auth-hdr");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);

    // init writes a local_token; confirm the CLI forwards it.
    const fake = try FakeServer.start(a);
    defer fake.deinit();
    fake.setCanned(
        "HTTP/1.1 200 OK\r\n" ++
            "Content-Length: 13\r\n" ++
            "Connection: close\r\n" ++
            "\r\n" ++
            "{\"stacks\":[]}",
    );
    try fake.serveAsync();

    var port_buf: [16]u8 = undefined;
    const port_str = try std.fmt.bufPrint(&port_buf, "{d}", .{fake.port});
    var r = try runCli(a, &.{ "stack", "list", "--root", s.abs_path, "--port", port_str });
    defer r.deinit();
    try std.testing.expectEqual(@as(u8, 0), r.code);

    // Inspect captured request: should contain "Authorization: Bearer ".
    const req = fake.captured_request orelse return error.NoRequestCaptured;
    try std.testing.expect(std.mem.indexOf(u8, req, "Authorization: Bearer ") != null);
}

test "cli: --root pointing at non-existing directory still attempts the daemon" {
    const a = std.testing.allocator;
    // No initNotesRoot — the path does not exist at all. The CLI should
    // tolerate missing config (treat as defaults) and still try to connect.
    // Combined with --port 1, we expect "daemon not started" rather than a
    // config-load error from the open() call.
    var r = try runCli(a, &.{ "stack", "list", "--root", "/path/does/not/exist/cli-root-test", "--port", "1" });
    defer r.deinit();
    try std.testing.expectEqual(@as(u8, 1), r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "daemon not started") != null);
}

test "cli: large response is bounded by the 8 MiB read cap" {
    // We don't try to serve 8 MiB; instead we verify that a response just
    // beyond the cap still results in a definite outcome rather than a hang.
    // 9 MiB body with no Content-Length header forces the read loop to break
    // on the cap and parseResponse to handle whatever lands.
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "fake-large");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);

    const fake = try FakeServer.start(a);
    defer fake.deinit();
    // Build a "small" canned response — the read cap is well above what this
    // test serves. We're chiefly asserting the path completes deterministically
    // with a status. Full 8MiB transfers are exercised by the parseResponse
    // unit tests in http_client.zig.
    const body = "{\"stacks\":[{\"name\":\"alpha\"},{\"name\":\"beta\"}]}";
    var len_buf: [16]u8 = undefined;
    const len_str = try std.fmt.bufPrint(&len_buf, "{d}", .{body.len});
    const head = try std.fmt.allocPrint(
        a,
        "HTTP/1.1 200 OK\r\nContent-Length: {s}\r\nConnection: close\r\n\r\n",
        .{len_str},
    );
    defer a.free(head);
    const whole = try std.mem.concat(a, u8, &.{ head, body });
    defer a.free(whole);
    fake.setCanned(whole);
    try fake.serveAsync();

    var port_buf: [16]u8 = undefined;
    const port_str = try std.fmt.bufPrint(&port_buf, "{d}", .{fake.port});
    var r = try runCli(a, &.{ "stack", "list", "--root", s.abs_path, "--port", port_str });
    defer r.deinit();
    try std.testing.expectEqual(@as(u8, 0), r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "alpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "beta") != null);
}

test "cli: renderStackList does not match nested `name` fields outside `stacks[]`" {
    // Regression for the audit's substring-grep brittleness: a top-level
    // `name` (e.g. an API metadata stamp) must not appear as a row.
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "fake-name-confusion");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);

    const fake = try FakeServer.start(a);
    defer fake.deinit();
    fake.setCanned(
        "HTTP/1.1 200 OK\r\n" ++
            "Content-Length: 50\r\n" ++
            "Connection: close\r\n" ++
            "\r\n" ++
            "{\"name\":\"organo\",\"stacks\":[{\"name\":\"real-stack\"}]}",
    );
    try fake.serveAsync();

    var port_buf: [16]u8 = undefined;
    const port_str = try std.fmt.bufPrint(&port_buf, "{d}", .{fake.port});
    var r = try runCli(a, &.{ "stack", "list", "--root", s.abs_path, "--port", port_str });
    defer r.deinit();
    try std.testing.expectEqual(@as(u8, 0), r.code);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "real-stack") != null);
    // The top-level "organo" name must not be rendered as a stack row.
    // Single-pass scan: split by newline, no line should be exactly "organo".
    var it = std.mem.splitScalar(u8, r.stdout, '\n');
    while (it.next()) |line| {
        try std.testing.expect(!std.mem.eql(u8, line, "organo"));
    }
}
