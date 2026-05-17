//! Integration tests for milestone-10 authorization.
//!
//! Pattern mirrors `test/mutation_tests.zig`: boot an ephemeral daemon
//! against a temp notes root (no real git so tests stay fast), then drive
//! HTTP requests through `serveOne` on a worker thread.
//!
//! The key new wrinkle is that each test seeds
//! `<root>/.stako/config.toml` with an `[identity.local]` table BEFORE
//! the daemon starts, so the policy evaluator sees an explicit (rather
//! than implicit-`*`) identity. Backwards-compat is covered by the
//! pre-existing M5–M9 mutation tests — they pass without any new config,
//! demonstrating that an undeclared local identity retains full access.

const std = @import("std");
const stako = @import("stako");
const init_mod = stako.init;
const daemon_mod = stako.daemon;
const policy_mod = stako.policy;
const config_mod = stako.config;
const vcs = stako.vcs;

// ---------- harness ----------

const Scratch = struct {
    allocator: std.mem.Allocator,
    abs_path: []u8,

    fn create(allocator: std.mem.Allocator, name_hint: []const u8) !Scratch {
        const tmp = std.posix.getenv("TMPDIR") orelse "/tmp";
        var ts_buf: [32]u8 = undefined;
        const ts = std.time.nanoTimestamp();
        const ts_str = try std.fmt.bufPrint(&ts_buf, "{d}", .{ts});
        const path = try std.fs.path.join(allocator, &.{ tmp, "stako-test-authorization" });
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
        .rng_seed_override = 0xA10F,
    });
    r.deinit();
}

/// Overwrite `.stako/config.toml` with an `[identity.local]` block whose
/// `capabilities` array is taken verbatim. `stako init` writes BOTH
/// `config.toml` and `config.local.toml` — and the local layer's
/// pre-baked `[identity.local]` block (caps = `*`) would otherwise
/// shadow whatever we put here per the layered-config semantics. So we
/// truncate `config.local.toml` to keep our committed layer
/// authoritative for the test.
fn seedIdentityCapabilities(allocator: std.mem.Allocator, root: []const u8, caps_toml_array: []const u8) !void {
    const path = try std.fs.path.join(allocator, &.{ root, ".stako", "config.toml" });
    defer allocator.free(path);
    const body = try std.fmt.allocPrint(allocator,
        \\[identity.local]
        \\type = "user"
        \\capabilities = {s}
        \\
    , .{caps_toml_array});
    defer allocator.free(body);
    {
        var f = try std.fs.cwd().createFile(path, .{ .truncate = true });
        defer f.close();
        try f.writeAll(body);
    }
    // Truncate `config.local.toml` so the stub `[identity.local]` block
    // init writes there does not shadow our committed layer above.
    const local_path = try std.fs.path.join(allocator, &.{ root, ".stako", "config.local.toml" });
    defer allocator.free(local_path);
    var lf = try std.fs.cwd().createFile(local_path, .{ .truncate = true });
    defer lf.close();
    try lf.writeAll("# cleared by authorization tests so config.toml stays authoritative\n");
}

fn startDaemonNoGit(allocator: std.mem.Allocator, root: []const u8) !daemon_mod.Daemon {
    return daemon_mod.start(allocator, .{
        .notes_root = root,
        .port_override = 0,
        .ephemeral = true,
        .enable_git = false,
        .check_repo_conflicts = false,
    });
}

const ServeContext = struct { daemon: *daemon_mod.Daemon, requests: usize };

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

    fn startWorker(self: *Driver) !void {
        try self.daemon.startWorker();
    }

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

fn httpRaw(allocator: std.mem.Allocator, port: u16, request: []const u8) ![]u8 {
    const addr = try std.net.Address.parseIp("127.0.0.1", port);
    var stream = try std.net.tcpConnectToAddress(addr);
    defer stream.close();
    try stream.writeAll(request);
    var buf = std.ArrayList(u8){};
    errdefer buf.deinit(allocator);
    var tmp: [4096]u8 = undefined;
    while (true) {
        const n = stream.read(&tmp) catch break;
        if (n == 0) break;
        try buf.appendSlice(allocator, tmp[0..n]);
        if (buf.items.len > 1024 * 1024) break;
    }
    return buf.toOwnedSlice(allocator);
}

fn splitResponse(resp: []const u8) struct { status: u16, body: []const u8 } {
    const head_end = std.mem.indexOf(u8, resp, "\r\n\r\n") orelse return .{ .status = 0, .body = "" };
    const head = resp[0..head_end];
    const body = resp[head_end + 4 ..];
    const sp1 = std.mem.indexOfScalar(u8, head, ' ') orelse return .{ .status = 0, .body = body };
    const after = head[sp1 + 1 ..];
    const sp2 = std.mem.indexOfScalar(u8, after, ' ') orelse after.len;
    const code = std.fmt.parseInt(u16, after[0..sp2], 10) catch 0;
    return .{ .status = code, .body = body };
}

fn buildPost(allocator: std.mem.Allocator, path: []const u8, token: []const u8, body: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        "POST {s} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\nAuthorization: Bearer {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ path, token, body.len, body });
}

fn buildPostNoAuth(allocator: std.mem.Allocator, path: []const u8, body: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        "POST {s} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ path, body.len, body });
}

fn readAuditLog(allocator: std.mem.Allocator, root: []const u8) ![]u8 {
    const path = try std.fs.path.join(allocator, &.{ root, ".stako", "audit.log" });
    defer allocator.free(path);
    var f = try std.fs.cwd().openFile(path, .{});
    defer f.close();
    const stat = try f.stat();
    const buf = try allocator.alloc(u8, stat.size);
    _ = try f.readAll(buf);
    return buf;
}

// ---------- read-only identity: append denied, no disk write, audit entry ----------

test "authorization: read-only identity denied for append_item" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "readonly-append");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);
    // The user holds nothing — every mutation is denied.
    try seedIdentityCapabilities(a, s.abs_path, "[]");

    // Seed a stack manually so the test isolates "append" from "create".
    const stack_dir = try std.fs.path.join(a, &.{ s.abs_path, "stacks", "demo" });
    defer a.free(stack_dir);
    try std.fs.cwd().makePath(stack_dir);
    {
        const path = try std.fs.path.join(a, &.{ stack_dir, "stack.toml" });
        defer a.free(path);
        var f = try std.fs.cwd().createFile(path, .{ .truncate = true });
        defer f.close();
        try f.writeAll("description = \"d\"\npaused = false\n");
    }

    var drv = Driver{ .allocator = a, .daemon = try startDaemonNoGit(a, s.abs_path) };
    defer drv.deinit();
    try drv.startWorker();
    try drv.serve(1);

    const body = "{\"kind\":\"prompt\",\"slug\":\"hi\",\"prompt\":\"hi\"}";
    const req = try buildPost(a, "/stacks/demo/items", drv.daemon.token.bytes, body);
    defer a.free(req);
    const resp = try httpRaw(a, drv.daemon.bound_port, req);
    defer a.free(resp);
    const parsed = splitResponse(resp);

    // Denial shape: 403, error.code = capability_denied, identity = local.
    try std.testing.expectEqual(@as(u16, 403), parsed.status);
    try std.testing.expect(std.mem.indexOf(u8, parsed.body, "\"code\":\"capability_denied\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, parsed.body, "\"identity\":\"local\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, parsed.body, "\"capability\":\"stack.demo.append\"") != null);

    // Disk: no new item directory was created.
    var d = try std.fs.openDirAbsolute(stack_dir, .{ .iterate = true });
    defer d.close();
    var it = d.iterate();
    while (it.next() catch null) |entry| {
        // Only stack.toml should be present.
        try std.testing.expect(std.mem.eql(u8, entry.name, "stack.toml"));
    }

    // Audit: a denied line is present with reason capability_denied and
    // identity local.
    const log = try readAuditLog(a, s.abs_path);
    defer a.free(log);
    try std.testing.expect(std.mem.indexOf(u8, log, "\"outcome\":\"denied\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, log, "\"reason\":\"capability_denied\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, log, "\"identity\":\"local\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, log, "\"action\":\"append_item\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, log, "\"target\":\"stack/demo\"") != null);
}

// ---------- create_stack denied without stack.create capability ----------

test "authorization: create_stack denied without capability" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "no-create");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);
    // Only append on a specific stack, no create.
    try seedIdentityCapabilities(a, s.abs_path, "[\"stack.foo.append\"]");

    var drv = Driver{ .allocator = a, .daemon = try startDaemonNoGit(a, s.abs_path) };
    defer drv.deinit();
    try drv.startWorker();
    try drv.serve(1);

    const body = "{\"name\":\"newstack\"}";
    const req = try buildPost(a, "/stacks", drv.daemon.token.bytes, body);
    defer a.free(req);
    const resp = try httpRaw(a, drv.daemon.bound_port, req);
    defer a.free(resp);
    const parsed = splitResponse(resp);
    try std.testing.expectEqual(@as(u16, 403), parsed.status);
    try std.testing.expect(std.mem.indexOf(u8, parsed.body, "\"code\":\"capability_denied\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, parsed.body, "\"capability\":\"stack.create\"") != null);

    // No `stacks/newstack` directory created.
    const new_dir = try std.fs.path.join(a, &.{ s.abs_path, "stacks", "newstack" });
    defer a.free(new_dir);
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().access(new_dir, .{}));
}

// ---------- pause denied for stack the identity doesn't own ----------

test "authorization: pause denied for stack outside scope" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "scoped-pause");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);
    // Identity can pause `mine` but not `other`.
    try seedIdentityCapabilities(a, s.abs_path, "[\"stack.mine.pause\"]");

    // Seed both stacks.
    for ([_][]const u8{ "mine", "other" }) |name| {
        const sd = try std.fs.path.join(a, &.{ s.abs_path, "stacks", name });
        defer a.free(sd);
        try std.fs.cwd().makePath(sd);
        const cp = try std.fs.path.join(a, &.{ sd, "stack.toml" });
        defer a.free(cp);
        var f = try std.fs.cwd().createFile(cp, .{ .truncate = true });
        defer f.close();
        try f.writeAll("description = \"d\"\npaused = false\n");
    }

    var drv = Driver{ .allocator = a, .daemon = try startDaemonNoGit(a, s.abs_path) };
    defer drv.deinit();
    try drv.startWorker();
    try drv.serve(2);

    // mine: allowed.
    {
        const req = try buildPost(a, "/stacks/mine/pause", drv.daemon.token.bytes, "");
        defer a.free(req);
        const resp = try httpRaw(a, drv.daemon.bound_port, req);
        defer a.free(resp);
        const parsed = splitResponse(resp);
        try std.testing.expectEqual(@as(u16, 200), parsed.status);
    }
    // other: denied.
    {
        const req = try buildPost(a, "/stacks/other/pause", drv.daemon.token.bytes, "");
        defer a.free(req);
        const resp = try httpRaw(a, drv.daemon.bound_port, req);
        defer a.free(resp);
        const parsed = splitResponse(resp);
        try std.testing.expectEqual(@as(u16, 403), parsed.status);
        try std.testing.expect(std.mem.indexOf(u8, parsed.body, "\"capability\":\"stack.other.pause\"") != null);
    }

    // Disk check: `other/stack.toml` was NOT flipped.
    const other_path = try std.fs.path.join(a, &.{ s.abs_path, "stacks", "other", "stack.toml" });
    defer a.free(other_path);
    var f = try std.fs.cwd().openFile(other_path, .{});
    defer f.close();
    const stat = try f.stat();
    const buf = try a.alloc(u8, stat.size);
    defer a.free(buf);
    _ = try f.readAll(buf);
    try std.testing.expect(std.mem.indexOf(u8, buf, "paused = false") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf, "paused = true") == null);
}

// ---------- wildcard capability: local identity with * keeps full access ----------

test "authorization: explicit `*` keeps full access" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "wildcard");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);
    try seedIdentityCapabilities(a, s.abs_path, "[\"*\"]");

    var drv = Driver{ .allocator = a, .daemon = try startDaemonNoGit(a, s.abs_path) };
    defer drv.deinit();
    try drv.startWorker();
    try drv.serve(1);

    const body = "{\"name\":\"demo\"}";
    const req = try buildPost(a, "/stacks", drv.daemon.token.bytes, body);
    defer a.free(req);
    const resp = try httpRaw(a, drv.daemon.bound_port, req);
    defer a.free(resp);
    const parsed = splitResponse(resp);
    try std.testing.expectEqual(@as(u16, 200), parsed.status);

    // Disk: the stack was created.
    const stack_toml = try std.fs.path.join(a, &.{ s.abs_path, "stacks", "demo", "stack.toml" });
    defer a.free(stack_toml);
    try std.fs.cwd().access(stack_toml, .{});
}

// ---------- backwards-compat: undeclared identity retains full access ----------

test "authorization: undeclared identity retains M3-era full access" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "undeclared");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);
    // Do NOT seed identity capabilities. We DO remove the local-layer
    // `[identity.local]` block init wrote so the loader genuinely sees
    // no `[identity.local]` table — that's the path the policy evaluator
    // must keep open with implicit full access for milestone-3..9
    // single-token deployments that never wrote an identity block.
    {
        const local_path = try std.fs.path.join(a, &.{ s.abs_path, ".stako", "config.local.toml" });
        defer a.free(local_path);
        var lf = try std.fs.cwd().createFile(local_path, .{ .truncate = true });
        defer lf.close();
        try lf.writeAll("# cleared so no identity.local is declared\n");
    }
    {
        const path = try std.fs.path.join(a, &.{ s.abs_path, ".stako", "config.toml" });
        defer a.free(path);
        var f = try std.fs.cwd().createFile(path, .{ .truncate = true });
        defer f.close();
        try f.writeAll("# no identity blocks\n");
    }

    var drv = Driver{ .allocator = a, .daemon = try startDaemonNoGit(a, s.abs_path) };
    defer drv.deinit();
    try drv.startWorker();
    try drv.serve(1);

    const body = "{\"name\":\"demo\"}";
    const req = try buildPost(a, "/stacks", drv.daemon.token.bytes, body);
    defer a.free(req);
    const resp = try httpRaw(a, drv.daemon.bound_port, req);
    defer a.free(resp);
    const parsed = splitResponse(resp);
    try std.testing.expectEqual(@as(u16, 200), parsed.status);
}

// ---------- identity_required audit on missing token ----------

test "authorization: missing token records identity_required audit line" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "no-token");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);
    try seedIdentityCapabilities(a, s.abs_path, "[\"*\"]");

    var drv = Driver{ .allocator = a, .daemon = try startDaemonNoGit(a, s.abs_path) };
    defer drv.deinit();
    try drv.startWorker();
    try drv.serve(1);

    const body = "{\"name\":\"demo\"}";
    const req = try buildPostNoAuth(a, "/stacks", body);
    defer a.free(req);
    const resp = try httpRaw(a, drv.daemon.bound_port, req);
    defer a.free(resp);
    const parsed = splitResponse(resp);
    try std.testing.expectEqual(@as(u16, 401), parsed.status);

    // Audit: an `identity_required` denial was logged with identity
    // "(anonymous)" — the caller never presented one.
    const log = try readAuditLog(a, s.abs_path);
    defer a.free(log);
    try std.testing.expect(std.mem.indexOf(u8, log, "\"outcome\":\"denied\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, log, "\"reason\":\"identity_required\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, log, "\"identity\":\"(anonymous)\"") != null);
}

// ---------- routing/dispatch policy: providerless harness denied at preflight ----------

test "authorization: routing denied for provider lacking capability" {
    // Drive the policy callback directly, since wiring a full supervisor
    // for this case would require a real fixture stack. The daemon
    // installs `runtimePolicyCheck` with a Daemon pointer; here we
    // exercise the underlying `policy.evaluate` for the dispatch case to
    // keep the test deterministic without a runtime tick.
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "dispatch-cap");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);
    try seedIdentityCapabilities(a, s.abs_path, "[\"provider.anthropic\"]");

    var cfg = try config_mod.loadFromRoot(a, s.abs_path);
    defer cfg.deinit();
    const id = policy_mod.resolveLocal(&cfg);
    try std.testing.expect(id.explicitly_declared);

    try std.testing.expect(policy_mod.evaluate(id, .dispatch_harness, .{ .provider = "anthropic" }) == .allow);
    try std.testing.expect(policy_mod.evaluate(id, .dispatch_harness, .{ .provider = "openai" }) == .capability_denied);
}

// ---------- coverage gap #4 (audit_10): form-body auth path produces the same canonical denial body ----------

fn buildPostForm(allocator: std.mem.Allocator, path: []const u8, body: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        "POST {s} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ path, body.len, body });
}

test "authorization: form-body auth path emits canonical capability_denied" {
    // The form-body auth path (browser `<form>` POST) carries the token
    // in `_token=...` rather than the Authorization header. Capability
    // denials taken via this path must produce the same JSON shape and
    // 403 status as the bearer-header path so HTML clients see a
    // consistent error vocabulary. See audit_10 coverage gap #4.
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "form-deny");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);
    try seedIdentityCapabilities(a, s.abs_path, "[]"); // pause on any stack denied

    // Seed a stack so pause/resume can run end-to-end through the form path.
    const stack_dir = try std.fs.path.join(a, &.{ s.abs_path, "stacks", "demo" });
    defer a.free(stack_dir);
    try std.fs.cwd().makePath(stack_dir);
    {
        const path = try std.fs.path.join(a, &.{ stack_dir, "stack.toml" });
        defer a.free(path);
        var f = try std.fs.cwd().createFile(path, .{ .truncate = true });
        defer f.close();
        try f.writeAll("description = \"d\"\npaused = false\n");
    }

    var drv = Driver{ .allocator = a, .daemon = try startDaemonNoGit(a, s.abs_path) };
    defer drv.deinit();
    try drv.startWorker();
    try drv.serve(1);

    const body = try std.fmt.allocPrint(a, "_token={s}", .{drv.daemon.token.bytes});
    defer a.free(body);
    const req = try buildPostForm(a, "/stacks/demo/pause", body);
    defer a.free(req);
    const resp = try httpRaw(a, drv.daemon.bound_port, req);
    defer a.free(resp);
    const parsed = splitResponse(resp);
    try std.testing.expectEqual(@as(u16, 403), parsed.status);
    try std.testing.expect(std.mem.indexOf(u8, parsed.body, "\"code\":\"capability_denied\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, parsed.body, "\"identity\":\"local\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, parsed.body, "\"capability\":\"stack.demo.pause\"") != null);

    // The mutation never landed: stack remains unpaused on disk.
    const stack_toml_path = try std.fs.path.join(a, &.{ stack_dir, "stack.toml" });
    defer a.free(stack_toml_path);
    var f = try std.fs.cwd().openFile(stack_toml_path, .{});
    defer f.close();
    const stat = try f.stat();
    const buf = try a.alloc(u8, stat.size);
    defer a.free(buf);
    _ = try f.readAll(buf);
    try std.testing.expect(std.mem.indexOf(u8, buf, "paused = false") != null);

    // Audit denial entry written for the form-path denial.
    const log = try readAuditLog(a, s.abs_path);
    defer a.free(log);
    try std.testing.expect(std.mem.indexOf(u8, log, "\"reason\":\"capability_denied\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, log, "\"action\":\"pause_stack\"") != null);
}

// ---------- coverage gap #6 (audit_10): denied mutation produces zero git activity ----------

fn makeRealRepo(allocator: std.mem.Allocator, root: []const u8) !void {
    const git_path = try std.fs.path.join(allocator, &.{ root, ".git" });
    defer allocator.free(git_path);
    std.fs.cwd().deleteTree(git_path) catch {};
    try vcs.ensureRealRepo(allocator, root);
    const paths = [_][]const u8{ ".gitignore", "stacks", ".stako/config.toml" };
    _ = vcs.commit(allocator, root, .{ .paths = &paths, .subject = "init: baseline" }) catch {};
}

fn startDaemonWithGit(allocator: std.mem.Allocator, root: []const u8) !daemon_mod.Daemon {
    return daemon_mod.start(allocator, .{
        .notes_root = root,
        .port_override = 0,
        .ephemeral = true,
        .enable_git = true,
        .check_repo_conflicts = false,
    });
}

fn runGitCapture(allocator: std.mem.Allocator, cwd: []const u8, argv: []const []const u8) ![]u8 {
    var full_argv = std.ArrayList([]const u8){};
    defer full_argv.deinit(allocator);
    try full_argv.append(allocator, "git");
    for (argv) |a| try full_argv.append(allocator, a);
    var child = std.process.Child.init(full_argv.items, allocator);
    child.cwd = cwd;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    var out_buf = std.ArrayList(u8){};
    errdefer out_buf.deinit(allocator);
    var err_buf = std.ArrayList(u8){};
    defer err_buf.deinit(allocator);
    try child.collectOutput(allocator, &out_buf, &err_buf, 1 * 1024 * 1024);
    _ = try child.wait();
    return out_buf.toOwnedSlice(allocator);
}

test "authorization: denied mutation leaves zero git activity" {
    // A future regression could accidentally route a denied mutation
    // through the queue before consulting policy; that would land a git
    // commit on disk. This test enables a real git repo, denies a
    // mutation, and asserts `git log --oneline` shows only the baseline
    // commit — i.e. the denied path never reached the queue. See
    // audit_10 coverage gap #6.
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "no-git-on-deny");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);
    try makeRealRepo(a, s.abs_path);
    try seedIdentityCapabilities(a, s.abs_path, "[]");

    // Re-commit the rewritten config so the baseline log is exactly one entry.
    _ = vcs.commit(a, s.abs_path, .{
        .paths = &.{".stako/config.toml"},
        .subject = "test: seed identity",
    }) catch {};

    const log_before = try runGitCapture(a, s.abs_path, &.{ "log", "--oneline" });
    defer a.free(log_before);
    var before_lines: usize = 0;
    {
        var it = std.mem.splitScalar(u8, log_before, '\n');
        while (it.next()) |line| if (line.len > 0) {
            before_lines += 1;
        };
    }

    var drv = Driver{ .allocator = a, .daemon = try startDaemonWithGit(a, s.abs_path) };
    defer drv.deinit();
    try drv.startWorker();
    try drv.serve(1);

    const body = "{\"name\":\"demo\"}";
    const req = try buildPost(a, "/stacks", drv.daemon.token.bytes, body);
    defer a.free(req);
    const resp = try httpRaw(a, drv.daemon.bound_port, req);
    defer a.free(resp);
    const parsed = splitResponse(resp);
    try std.testing.expectEqual(@as(u16, 403), parsed.status);

    // Drive the daemon worker to quiescence before sampling git so any
    // background commit that erroneously slipped through has had its
    // chance to land.
    drv.daemon.requestShutdown();
    if (drv.thread) |t| {
        t.join();
        drv.thread = null;
    }

    const log_after = try runGitCapture(a, s.abs_path, &.{ "log", "--oneline" });
    defer a.free(log_after);
    var after_lines: usize = 0;
    {
        var it = std.mem.splitScalar(u8, log_after, '\n');
        while (it.next()) |line| if (line.len > 0) {
            after_lines += 1;
        };
    }
    try std.testing.expectEqual(before_lines, after_lines);
}

// ---------- coverage gap #5 (audit_10): illegal stack-name flows through policy first ----------

test "authorization: illegal stack name denied by policy before handler validation" {
    // The route matcher passes the raw stack-name to the policy
    // evaluator (`policy.evaluate` runs before the handler's
    // `isValidStackName` check). For an identity scoped to a specific
    // stack, an illegal name will trip the 403 path before the 400.
    // Confirm the policy verdict and audit shape match the canonical
    // capability_denied vocabulary. See audit_10 coverage gap #5.
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "illegal-stack");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);
    try seedIdentityCapabilities(a, s.abs_path, "[\"stack.demo.append\"]");

    var drv = Driver{ .allocator = a, .daemon = try startDaemonNoGit(a, s.abs_path) };
    defer drv.deinit();
    try drv.startWorker();
    try drv.serve(1);

    // `BadName` is not a route the daemon would accept anyway (uppercase
    // is rejected by `isValidStackName`), but the policy layer runs
    // first. With `stack.demo.append` only, this stack is outside scope.
    const body = "{\"kind\":\"prompt\",\"slug\":\"hi\",\"prompt\":\"hi\"}";
    const req = try buildPost(a, "/stacks/BadName/items", drv.daemon.token.bytes, body);
    defer a.free(req);
    const resp = try httpRaw(a, drv.daemon.bound_port, req);
    defer a.free(resp);
    const parsed = splitResponse(resp);
    try std.testing.expectEqual(@as(u16, 403), parsed.status);
    try std.testing.expect(std.mem.indexOf(u8, parsed.body, "\"code\":\"capability_denied\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, parsed.body, "\"capability\":\"stack.BadName.append\"") != null);
}
