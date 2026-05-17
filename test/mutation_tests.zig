//! Integration tests for the milestone-5 mutation surface.
//!
//! Each test boots an ephemeral daemon against a temp notes root that has a
//! real git repo (created via `vcs.ensureRealRepo`). POST endpoints exercise
//! the full stack-client path:
//! HTTP → StackClient → mutations → vcs commit → audit log.

const std = @import("std");
const stako = @import("stako");
const init_mod = stako.init;
const daemon_mod = stako.daemon;
const vcs = stako.vcs;
const audit_mod = stako.audit;
const mutations_mod = stako.mutations;
const stack_mod = stako.stack;

// ---------- harness ----------

const Scratch = struct {
    allocator: std.mem.Allocator,
    abs_path: []u8,

    fn create(allocator: std.mem.Allocator, name_hint: []const u8) !Scratch {
        const tmp = std.posix.getenv("TMPDIR") orelse "/tmp";
        var ts_buf: [32]u8 = undefined;
        const ts = std.time.nanoTimestamp();
        const ts_str = try std.fmt.bufPrint(&ts_buf, "{d}", .{ts});
        const path = try std.fs.path.join(allocator, &.{ tmp, "stako-test-mutation" });
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

/// Replace the stub `.git/` produced by `stako init` with a real repo so
/// the vcs layer's git invocations work.
fn makeRealRepo(allocator: std.mem.Allocator, root: []const u8) !void {
    // Remove the stub .git directory first; ensureRealRepo will re-init.
    const git_path = try std.fs.path.join(allocator, &.{ root, ".git" });
    defer allocator.free(git_path);
    std.fs.cwd().deleteTree(git_path) catch {};
    try vcs.ensureRealRepo(allocator, root);

    // Stage and commit the init layout so the working tree is clean.
    const paths = [_][]const u8{ ".gitignore", "stacks", ".stako/config.toml" };
    _ = vcs.commit(allocator, root, .{
        .paths = &paths,
        .subject = "init: baseline",
    }) catch {};
}

fn startDaemonWithGit(allocator: std.mem.Allocator, root: []const u8) !daemon_mod.Daemon {
    return daemon_mod.start(allocator, .{
        .notes_root = root,
        .port_override = 0,
        .ephemeral = true,
        .enable_git = true,
        .check_repo_conflicts = true,
    });
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
    aux_thread: ?std.Thread = null,
    ctx: ServeContext = undefined,
    aux_ctx: ServeContext = undefined,
    worker_started: bool = false,

    /// Spawn the queue worker. Must run AFTER the daemon is at its final
    /// address (i.e. after Driver is constructed) because the worker holds
    /// a pointer into `daemon.audit_writer`.
    fn startWorker(self: *Driver) !void {
        if (self.worker_started) return;
        try self.daemon.startWorker();
        self.worker_started = true;
    }

    fn deinit(self: *Driver) void {
        if (self.thread != null or self.aux_thread != null) self.daemon.requestShutdown();
        if (self.thread) |t| t.join();
        if (self.aux_thread) |t| t.join();
        self.daemon.deinit();
    }

    fn serve(self: *Driver, n: usize) !void {
        self.ctx = .{ .daemon = &self.daemon, .requests = n };
        self.thread = try std.Thread.spawn(.{}, serveThread, .{&self.ctx});
    }

    /// Spawn a second accept-serving thread so the "two simultaneous"
    /// concurrency test can drive two clients in parallel.
    fn serveAux(self: *Driver, n: usize) !void {
        self.aux_ctx = .{ .daemon = &self.daemon, .requests = n };
        self.aux_thread = try std.Thread.spawn(.{}, serveThread, .{&self.aux_ctx});
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
    const code_s = after[0..sp2];
    const code = std.fmt.parseInt(u16, code_s, 10) catch 0;
    return .{ .status = code, .body = body };
}

fn buildAuthHeader(allocator: std.mem.Allocator, token: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "Authorization: Bearer {s}\r\n", .{token});
}

/// Compose `POST <path> HTTP/1.1\r\n...` with the bearer token and given JSON body.
fn buildPostRequest(allocator: std.mem.Allocator, path: []const u8, token: []const u8, body: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "POST {s} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\nAuthorization: Bearer {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}", .{ path, token, body.len, body });
}

fn buildPostNoToken(allocator: std.mem.Allocator, path: []const u8, body: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "POST {s} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}", .{ path, body.len, body });
}

fn buildGetRequest(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "GET {s} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n", .{path});
}

/// Count lines in audit.log under <root>/.stako/audit.log; returns 0 if absent.
fn auditLineCount(allocator: std.mem.Allocator, root: []const u8) !usize {
    const path = try std.fs.path.join(allocator, &.{ root, ".stako", "audit.log" });
    defer allocator.free(path);
    var f = std.fs.cwd().openFile(path, .{}) catch return 0;
    defer f.close();
    const stat = try f.stat();
    const buf = try allocator.alloc(u8, stat.size);
    defer allocator.free(buf);
    _ = try f.readAll(buf);
    var n: usize = 0;
    for (buf) |c| if (c == '\n') {
        n += 1;
    };
    return n;
}

fn countCommits(allocator: std.mem.Allocator, root: []const u8) !usize {
    var child = std.process.Child.init(&.{ "git", "rev-list", "--count", "HEAD" }, allocator);
    child.cwd = root;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);
    var dummy = std.ArrayList(u8){};
    defer dummy.deinit(allocator);
    try child.collectOutput(allocator, &out, &dummy, 4096);
    _ = try child.wait();
    return std.fmt.parseInt(usize, std.mem.trim(u8, out.items, " \t\r\n"), 10) catch 0;
}

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var f = try std.fs.cwd().openFile(path, .{});
    defer f.close();
    const stat = try f.stat();
    const buf = try allocator.alloc(u8, stat.size);
    errdefer allocator.free(buf);
    _ = try f.readAll(buf);
    return buf;
}

fn dirExistsPath(path: []const u8) bool {
    var d = std.fs.cwd().openDir(path, .{}) catch return false;
    d.close();
    return true;
}

const WakeCounter = struct {
    count: usize = 0,
};

fn countWake(ctx: ?*anyopaque, stack_name: []const u8) void {
    _ = stack_name;
    const counter: *WakeCounter = @ptrCast(@alignCast(ctx.?));
    counter.count += 1;
}

// ---------- tests ----------

test "mutation: one create_stack -> one commit + one audit line" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "create-one");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);
    try makeRealRepo(a, s.abs_path);
    const baseline_commits = try countCommits(a, s.abs_path);
    const baseline_audit = try auditLineCount(a, s.abs_path);

    var drv = Driver{ .allocator = a, .daemon = try startDaemonWithGit(a, s.abs_path) };
    defer drv.deinit();
    try drv.startWorker();
    try drv.serve(1);

    const body = "{\"name\":\"demo\"}";
    const req = try buildPostRequest(a, "/stacks", drv.daemon.token.bytes, body);
    defer a.free(req);
    const resp = try httpRaw(a, drv.daemon.bound_port, req);
    defer a.free(resp);
    const parsed = splitResponse(resp);
    try std.testing.expectEqual(@as(u16, 200), parsed.status);
    try std.testing.expect(std.mem.indexOf(u8, parsed.body, "\"ok\":true") != null);

    // Exactly one new commit.
    const new_commits = try countCommits(a, s.abs_path);
    try std.testing.expectEqual(baseline_commits + 1, new_commits);

    // Exactly one new audit line (the create_stack; daemon_started already
    // counted in baseline).
    const new_audit = try auditLineCount(a, s.abs_path);
    try std.testing.expect(new_audit >= baseline_audit + 1);
}

test "mutation: missing token rejects POST with 401 identity_required" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "auth-missing");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);

    var drv = Driver{ .allocator = a, .daemon = try startDaemonNoGit(a, s.abs_path) };
    defer drv.deinit();
    try drv.startWorker();
    try drv.serve(1);

    const body = "{\"name\":\"demo\"}";
    const req = try buildPostNoToken(a, "/stacks", body);
    defer a.free(req);
    const resp = try httpRaw(a, drv.daemon.bound_port, req);
    defer a.free(resp);
    const parsed = splitResponse(resp);
    try std.testing.expectEqual(@as(u16, 401), parsed.status);
    try std.testing.expect(std.mem.indexOf(u8, parsed.body, "\"code\":\"identity_required\"") != null);
}

test "mutation: bad token rejects POST" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "auth-bad");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);

    var drv = Driver{ .allocator = a, .daemon = try startDaemonNoGit(a, s.abs_path) };
    defer drv.deinit();
    try drv.startWorker();
    try drv.serve(1);

    const body = "{\"name\":\"demo\"}";
    const req = try buildPostRequest(a, "/stacks", "deadbeef" ** 8, body);
    defer a.free(req);
    const resp = try httpRaw(a, drv.daemon.bound_port, req);
    defer a.free(resp);
    const parsed = splitResponse(resp);
    try std.testing.expectEqual(@as(u16, 401), parsed.status);
}

test "mutation: POST /stacks then GET /stacks includes the new stack" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "post-then-get");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);

    var drv = Driver{ .allocator = a, .daemon = try startDaemonNoGit(a, s.abs_path) };
    defer drv.deinit();
    try drv.startWorker();
    try drv.serve(2);

    // POST.
    {
        const body = "{\"name\":\"alpha\"}";
        const req = try buildPostRequest(a, "/stacks", drv.daemon.token.bytes, body);
        defer a.free(req);
        const resp = try httpRaw(a, drv.daemon.bound_port, req);
        defer a.free(resp);
        const parsed = splitResponse(resp);
        try std.testing.expectEqual(@as(u16, 200), parsed.status);
    }
    // GET.
    {
        const req = try buildGetRequest(a, "/stacks");
        defer a.free(req);
        const resp = try httpRaw(a, drv.daemon.bound_port, req);
        defer a.free(resp);
        const parsed = splitResponse(resp);
        try std.testing.expectEqual(@as(u16, 200), parsed.status);
        try std.testing.expect(std.mem.indexOf(u8, parsed.body, "\"name\":\"alpha\"") != null);
    }
}

test "mutation: pause flips stack.toml without touching item statuses" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "pause-isolation");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);

    // Seed a stack with a queued item by hand.
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
    const item_dir = try std.fs.path.join(a, &.{ stack_dir, "0001-hi" });
    defer a.free(item_dir);
    try std.fs.cwd().makePath(item_dir);
    {
        const meta = try std.fs.path.join(a, &.{ item_dir, "meta.toml" });
        defer a.free(meta);
        var f = try std.fs.cwd().createFile(meta, .{ .truncate = true });
        defer f.close();
        try f.writeAll(
            \\id = "0001"
            \\slug = "hi"
            \\kind = "prompt"
            \\status = "queued"
            \\created_at = 2026-05-10T14:00:00Z
            \\updated_at = 2026-05-10T14:00:00Z
            \\
            \\[target]
            \\match = "any"
            \\
        );
    }

    var drv = Driver{ .allocator = a, .daemon = try startDaemonNoGit(a, s.abs_path) };
    defer drv.deinit();
    try drv.startWorker();
    try drv.serve(1);

    const req = try buildPostRequest(a, "/stacks/demo/pause", drv.daemon.token.bytes, "");
    defer a.free(req);
    const resp = try httpRaw(a, drv.daemon.bound_port, req);
    defer a.free(resp);
    const parsed = splitResponse(resp);
    try std.testing.expectEqual(@as(u16, 200), parsed.status);

    // stack.toml flipped.
    const cfg_path = try std.fs.path.join(a, &.{ stack_dir, "stack.toml" });
    defer a.free(cfg_path);
    var cfg_f = try std.fs.cwd().openFile(cfg_path, .{});
    defer cfg_f.close();
    const cfg_stat = try cfg_f.stat();
    const cfg = try a.alloc(u8, cfg_stat.size);
    defer a.free(cfg);
    _ = try cfg_f.readAll(cfg);
    try std.testing.expect(std.mem.indexOf(u8, cfg, "paused = true") != null);

    // Item meta.toml still queued.
    const meta_path = try std.fs.path.join(a, &.{ item_dir, "meta.toml" });
    defer a.free(meta_path);
    var meta_f = try std.fs.cwd().openFile(meta_path, .{});
    defer meta_f.close();
    const meta_stat = try meta_f.stat();
    const meta = try a.alloc(u8, meta_stat.size);
    defer a.free(meta);
    _ = try meta_f.readAll(meta);
    try std.testing.expect(std.mem.indexOf(u8, meta, "status = \"queued\"") != null);
}

test "mutation: two concurrent requests serialize and both succeed" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "concurrent");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);

    var drv = Driver{ .allocator = a, .daemon = try startDaemonNoGit(a, s.abs_path) };
    defer drv.deinit();
    try drv.startWorker();
    // Two server threads so two clients can hand off requests in parallel.
    try drv.serve(1);
    try drv.serveAux(1);

    // Spawn two client threads each posting one stack.
    const ClientCtx = struct {
        a: std.mem.Allocator,
        port: u16,
        token: []const u8,
        body: []const u8,
        result_status: u16 = 0,

        fn run(self: *@This()) void {
            const req = std.fmt.allocPrint(
                self.a,
                "POST /stacks HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\nAuthorization: Bearer {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}",
                .{ self.token, self.body.len, self.body },
            ) catch return;
            defer self.a.free(req);
            const resp = httpRaw(self.a, self.port, req) catch return;
            defer self.a.free(resp);
            const parsed = splitResponse(resp);
            self.result_status = parsed.status;
        }
    };
    var ctx1 = ClientCtx{ .a = a, .port = drv.daemon.bound_port, .token = drv.daemon.token.bytes, .body = "{\"name\":\"alpha\"}" };
    var ctx2 = ClientCtx{ .a = a, .port = drv.daemon.bound_port, .token = drv.daemon.token.bytes, .body = "{\"name\":\"beta\"}" };
    const t1 = try std.Thread.spawn(.{}, ClientCtx.run, .{&ctx1});
    const t2 = try std.Thread.spawn(.{}, ClientCtx.run, .{&ctx2});
    t1.join();
    t2.join();
    try std.testing.expectEqual(@as(u16, 200), ctx1.result_status);
    try std.testing.expectEqual(@as(u16, 200), ctx2.result_status);

    // Both stacks were created.
    const alpha = try std.fs.path.join(a, &.{ s.abs_path, "stacks", "alpha", "stack.toml" });
    defer a.free(alpha);
    const beta = try std.fs.path.join(a, &.{ s.abs_path, "stacks", "beta", "stack.toml" });
    defer a.free(beta);
    try std.fs.cwd().access(alpha, .{});
    try std.fs.cwd().access(beta, .{});

    // Audit log contains at least 2 mutation entries; their order matches
    // queue arrival (we can't predict order between the threads, but
    // exactly-one of each is guaranteed by the single-writer queue).
    const log_path = try std.fs.path.join(a, &.{ s.abs_path, ".stako", "audit.log" });
    defer a.free(log_path);
    var lf = try std.fs.cwd().openFile(log_path, .{});
    defer lf.close();
    const lstat = try lf.stat();
    const log = try a.alloc(u8, lstat.size);
    defer a.free(log);
    _ = try lf.readAll(log);
    try std.testing.expect(std.mem.indexOf(u8, log, "\"target\":\"stack/alpha\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, log, "\"target\":\"stack/beta\"") != null);
}

test "mutation: dirty target file rejects mutation with vcs_conflict" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "dirty-target");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);
    try makeRealRepo(a, s.abs_path);

    // Seed a committed stack so we can perturb its stack.toml.
    const stack_dir = try std.fs.path.join(a, &.{ s.abs_path, "stacks", "demo" });
    defer a.free(stack_dir);
    try std.fs.cwd().makePath(stack_dir);
    {
        const cfg_path = try std.fs.path.join(a, &.{ stack_dir, "stack.toml" });
        defer a.free(cfg_path);
        var f = try std.fs.cwd().createFile(cfg_path, .{ .truncate = true });
        defer f.close();
        try f.writeAll("description = \"d\"\npaused = false\n");
    }
    _ = try vcs.commit(a, s.abs_path, .{
        .paths = &.{"stacks/demo/stack.toml"},
        .subject = "stack: seed demo",
    });

    // Dirty the file without committing.
    {
        const cfg_path = try std.fs.path.join(a, &.{ stack_dir, "stack.toml" });
        defer a.free(cfg_path);
        var f = try std.fs.cwd().createFile(cfg_path, .{ .truncate = true });
        defer f.close();
        try f.writeAll("description = \"hand-edited\"\npaused = false\n");
    }

    var drv = Driver{ .allocator = a, .daemon = try startDaemonWithGit(a, s.abs_path) };
    defer drv.deinit();
    try drv.startWorker();
    try drv.serve(1);

    const req = try buildPostRequest(a, "/stacks/demo/pause", drv.daemon.token.bytes, "");
    defer a.free(req);
    const resp = try httpRaw(a, drv.daemon.bound_port, req);
    defer a.free(resp);
    const parsed = splitResponse(resp);
    try std.testing.expectEqual(@as(u16, 409), parsed.status);
    try std.testing.expect(std.mem.indexOf(u8, parsed.body, "\"code\":\"vcs_conflict\"") != null);
}

test "mutation: daemon startup refuses repo with merge conflicts" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "merge-conflict");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);
    try makeRealRepo(a, s.abs_path);

    // Forge a merge-conflict marker by writing a file with an unmerged
    // entry into the index. The cheapest reproducer: create two branches
    // with conflicting changes to the same file and attempt a merge.
    {
        // Write initial content + commit.
        const fp = try std.fs.path.join(a, &.{ s.abs_path, "conflict.txt" });
        defer a.free(fp);
        var f = try std.fs.cwd().createFile(fp, .{ .truncate = true });
        defer f.close();
        try f.writeAll("base\n");
    }
    _ = try vcs.commit(a, s.abs_path, .{ .paths = &.{"conflict.txt"}, .subject = "base" });

    // Make a 'feature' branch with a change.
    try runGitCmd(a, s.abs_path, &.{ "checkout", "-q", "-b", "feature" });
    {
        const fp = try std.fs.path.join(a, &.{ s.abs_path, "conflict.txt" });
        defer a.free(fp);
        var f = try std.fs.cwd().createFile(fp, .{ .truncate = true });
        defer f.close();
        try f.writeAll("feature\n");
    }
    _ = try vcs.commit(a, s.abs_path, .{ .paths = &.{"conflict.txt"}, .subject = "feature change" });

    // Switch back to main and make a conflicting change.
    try runGitCmd(a, s.abs_path, &.{ "checkout", "-q", "main" });
    {
        const fp = try std.fs.path.join(a, &.{ s.abs_path, "conflict.txt" });
        defer a.free(fp);
        var f = try std.fs.cwd().createFile(fp, .{ .truncate = true });
        defer f.close();
        try f.writeAll("main\n");
    }
    _ = try vcs.commit(a, s.abs_path, .{ .paths = &.{"conflict.txt"}, .subject = "main change" });

    // Merge — this should leave the index in a conflicted state.
    runGitCmd(a, s.abs_path, &.{ "-c", "user.name=t", "-c", "user.email=t@l", "merge", "--no-commit", "--no-ff", "feature" }) catch {};

    // Now starting the daemon must refuse.
    const err = daemon_mod.start(a, .{
        .notes_root = s.abs_path,
        .port_override = 0,
        .ephemeral = true,
        .enable_git = true,
        .check_repo_conflicts = true,
    });
    if (err) |maybe_d| {
        var dd = maybe_d;
        dd.deinit();
        return error.ExpectedRefusal;
    } else |e| {
        try std.testing.expectEqual(daemon_mod.ErrorExt.MergeConflictsPresent, e);
    }
}

test "mutation: commit failure rolls back working tree (B1)" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "rollback");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);
    try makeRealRepo(a, s.abs_path);

    // Install a pre-commit hook that always fails, forcing `git commit` to
    // return non-zero for any subsequent mutation.
    const hooks_dir = try std.fs.path.join(a, &.{ s.abs_path, ".git", "hooks" });
    defer a.free(hooks_dir);
    try std.fs.cwd().makePath(hooks_dir);
    const hook_path = try std.fs.path.join(a, &.{ hooks_dir, "pre-commit" });
    defer a.free(hook_path);
    {
        var hf = try std.fs.cwd().createFile(hook_path, .{ .truncate = true, .mode = 0o755 });
        defer hf.close();
        try hf.writeAll("#!/bin/sh\nexit 1\n");
    }

    var drv = Driver{ .allocator = a, .daemon = try startDaemonWithGit(a, s.abs_path) };
    defer drv.deinit();
    try drv.startWorker();
    try drv.serve(1);

    const baseline_commits = try countCommits(a, s.abs_path);
    const baseline_audit = try auditLineCount(a, s.abs_path);

    const body = "{\"name\":\"rollback-demo\"}";
    const req = try buildPostRequest(a, "/stacks", drv.daemon.token.bytes, body);
    defer a.free(req);
    const resp = try httpRaw(a, drv.daemon.bound_port, req);
    defer a.free(resp);
    const parsed = splitResponse(resp);
    try std.testing.expectEqual(@as(u16, 500), parsed.status);

    // No new commit.
    try std.testing.expectEqual(baseline_commits, try countCommits(a, s.abs_path));
    // No new audit line (commit failure path bypasses audit append).
    try std.testing.expectEqual(baseline_audit, try auditLineCount(a, s.abs_path));

    // Working tree is clean: the mutator wrote stacks/rollback-demo/stack.toml
    // and the rollback must remove both the file and the dangling directory.
    const file_path = try std.fs.path.join(a, &.{ s.abs_path, "stacks", "rollback-demo", "stack.toml" });
    defer a.free(file_path);
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().access(file_path, .{}));
    const dir_path = try std.fs.path.join(a, &.{ s.abs_path, "stacks", "rollback-demo" });
    defer a.free(dir_path);
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().access(dir_path, .{}));

    // Index is clean (no staged changes).
    var status = std.process.Child.init(&.{ "git", "status", "--porcelain" }, a);
    status.cwd = s.abs_path;
    status.stdout_behavior = .Pipe;
    status.stderr_behavior = .Pipe;
    try status.spawn();
    var out = std.ArrayList(u8){};
    defer out.deinit(a);
    var err = std.ArrayList(u8){};
    defer err.deinit(a);
    try status.collectOutput(a, &out, &err, 65536);
    _ = try status.wait();
    try std.testing.expectEqual(@as(usize, 0), std.mem.trim(u8, out.items, " \t\r\n").len);
}

fn runGitCmd(allocator: std.mem.Allocator, root: []const u8, args: []const []const u8) !void {
    var argv = std.ArrayList([]const u8){};
    defer argv.deinit(allocator);
    try argv.append(allocator, "git");
    for (args) |aa| try argv.append(allocator, aa);
    var child = std.process.Child.init(argv.items, allocator);
    child.cwd = root;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);
    var err = std.ArrayList(u8){};
    defer err.deinit(allocator);
    try child.collectOutput(allocator, &out, &err, 65536);
    _ = try child.wait();
}

test "mutation: append item then cancel produces two commits + two audit lines" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "append-cancel");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);
    try makeRealRepo(a, s.abs_path);
    const baseline_commits = try countCommits(a, s.abs_path);

    // Stack 'demo' must exist; create via POST.
    var drv = Driver{ .allocator = a, .daemon = try startDaemonWithGit(a, s.abs_path) };
    defer drv.deinit();
    try drv.startWorker();
    try drv.serve(3);

    // 1. Create stack.
    {
        const req = try buildPostRequest(a, "/stacks", drv.daemon.token.bytes, "{\"name\":\"demo\"}");
        defer a.free(req);
        const resp = try httpRaw(a, drv.daemon.bound_port, req);
        defer a.free(resp);
        try std.testing.expectEqual(@as(u16, 200), splitResponse(resp).status);
    }
    // 2. Append a prompt item.
    {
        const body = "{\"kind\":\"prompt\",\"slug\":\"hello\",\"target\":{\"match\":\"any\"}}";
        const req = try buildPostRequest(a, "/stacks/demo/items", drv.daemon.token.bytes, body);
        defer a.free(req);
        const resp = try httpRaw(a, drv.daemon.bound_port, req);
        defer a.free(resp);
        try std.testing.expectEqual(@as(u16, 200), splitResponse(resp).status);
    }
    // 3. Cancel the item.
    {
        const req = try buildPostRequest(a, "/stacks/demo/items/0001/cancel", drv.daemon.token.bytes, "{}");
        defer a.free(req);
        const resp = try httpRaw(a, drv.daemon.bound_port, req);
        defer a.free(resp);
        try std.testing.expectEqual(@as(u16, 200), splitResponse(resp).status);
    }
    const new_commits = try countCommits(a, s.abs_path);
    try std.testing.expectEqual(baseline_commits + 3, new_commits);
}

test "mutation: append routine writes ordinary items in one commit and one wake" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "append-routine");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);
    try makeRealRepo(a, s.abs_path);

    const routines_dir = try std.fs.path.join(a, &.{ s.abs_path, "routines" });
    defer a.free(routines_dir);
    try std.fs.cwd().makePath(routines_dir);
    {
        const routine_path = try std.fs.path.join(a, &.{ s.abs_path, "routines", "planning.toml" });
        defer a.free(routine_path);
        var f = try std.fs.cwd().createFile(routine_path, .{ .truncate = true });
        defer f.close();
        try f.writeAll(
            \\version = 1
            \\name = "planning"
            \\description = "Plan work."
            \\
            \\[[step]]
            \\name = "research"
            \\slug = "research"
            \\kind = "prompt"
            \\prompt = "Research the task."
            \\
            \\[step.target]
            \\match = "any"
            \\
            \\[[step]]
            \\name = "write-plan"
            \\slug = "write-plan"
            \\kind = "prompt"
            \\prompt = "Write the plan."
            \\after = ["research"]
            \\inputs_from = ["research"]
            \\
            \\[step.target]
            \\match = "any"
            \\
        );
    }

    var audit_writer = try audit_mod.Writer.init(a, s.abs_path);
    defer audit_writer.deinit();
    var registry = try stack_mod.StackRegistry.init(a, s.abs_path, &audit_writer, true);
    defer registry.deinit();
    var wakes = WakeCounter{};
    registry.setPostCommitHook(&wakes, countWake);
    const client = registry.localClient("local", "/internal/routine-test");

    const routines = try client.listRoutines();
    defer client.freeRoutineList(routines);
    try std.testing.expectEqual(@as(usize, 1), routines.len);
    try std.testing.expectEqualStrings("planning", routines[0].name);

    var routine = try client.readRoutine("planning");
    defer routine.deinit();

    const baseline_commits = try countCommits(a, s.abs_path);
    const baseline_audit = try auditLineCount(a, s.abs_path);
    const before_items = try client.listItems("default");
    defer client.freeItemList(before_items);

    var result = client.appendRoutine("default", .{
        .stack = "default",
        .routine = &routine,
        .created_at_override = "2026-05-17T12:00:00.000Z",
    });
    switch (result) {
        .ok => |*ok| ok.deinit(),
        .err => |e| {
            std.debug.print("appendRoutine failed: {any}\n", .{e});
            return error.UnexpectedAppendRoutineFailure;
        },
    }

    try std.testing.expectEqual(baseline_commits + 1, try countCommits(a, s.abs_path));
    try std.testing.expectEqual(baseline_audit + 1, try auditLineCount(a, s.abs_path));
    try std.testing.expectEqual(@as(usize, 1), wakes.count);

    const after_items = try client.listItems("default");
    defer client.freeItemList(after_items);
    try std.testing.expectEqual(before_items.len + 2, after_items.len);

    var item1 = try client.readItem("default", after_items[after_items.len - 2].id);
    defer item1.deinit();
    var item2 = try client.readItem("default", after_items[after_items.len - 1].id);
    defer item2.deinit();
    try std.testing.expectEqualStrings("research", item1.slug);
    try std.testing.expectEqualStrings("write-plan", item2.slug);
    try std.testing.expectEqualStrings(item1.id, item2.parents.?[0]);
    try std.testing.expectEqualStrings(item1.id, item2.inputs.?.items.?[0]);

    const log_path = try std.fs.path.join(a, &.{ s.abs_path, ".stako", "audit.log" });
    defer a.free(log_path);
    const log = try readFileAlloc(a, log_path);
    defer a.free(log);
    try std.testing.expect(std.mem.indexOf(u8, log, "\"action\":\"append_routine\"") != null);
}

test "mutation: append routine validation failure leaves stack unchanged" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "append-routine-fails");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);
    try makeRealRepo(a, s.abs_path);

    const routines_dir = try std.fs.path.join(a, &.{ s.abs_path, "routines" });
    defer a.free(routines_dir);
    try std.fs.cwd().makePath(routines_dir);
    {
        const routine_path = try std.fs.path.join(a, &.{ s.abs_path, "routines", "missing-prompt.toml" });
        defer a.free(routine_path);
        var f = try std.fs.cwd().createFile(routine_path, .{ .truncate = true });
        defer f.close();
        try f.writeAll(
            \\version = 1
            \\name = "missing-prompt"
            \\
            \\[[step]]
            \\name = "first"
            \\slug = "first"
            \\kind = "prompt"
            \\prompt_file = "prompts/nope.md"
            \\
            \\[step.target]
            \\match = "any"
            \\
        );
    }

    var audit_writer = try audit_mod.Writer.init(a, s.abs_path);
    defer audit_writer.deinit();
    var registry = try stack_mod.StackRegistry.init(a, s.abs_path, &audit_writer, true);
    defer registry.deinit();
    var wakes = WakeCounter{};
    registry.setPostCommitHook(&wakes, countWake);
    const client = registry.localClient("local", "/internal/routine-test");

    var routine = try client.readRoutine("missing-prompt");
    defer routine.deinit();
    const baseline_commits = try countCommits(a, s.abs_path);
    const baseline_audit = try auditLineCount(a, s.abs_path);
    const before_items = try client.listItems("default");
    defer client.freeItemList(before_items);

    var result = client.appendRoutine("default", .{ .stack = "default", .routine = &routine });
    switch (result) {
        .ok => |*ok| {
            ok.deinit();
            return error.ExpectedAppendRoutineFailure;
        },
        .err => |e| try std.testing.expectEqual(stack_mod.MutationFailureKind.validation_failed, e),
    }
    try std.testing.expectEqual(baseline_commits, try countCommits(a, s.abs_path));
    try std.testing.expectEqual(baseline_audit, try auditLineCount(a, s.abs_path));
    try std.testing.expectEqual(@as(usize, 0), wakes.count);
    const after_items = try client.listItems("default");
    defer client.freeItemList(after_items);
    try std.testing.expectEqual(before_items.len, after_items.len);
}

test "mutation: append routine item validation failure writes nothing" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "append-routine-invalid-expanded-item");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);
    try makeRealRepo(a, s.abs_path);

    const routines_dir = try std.fs.path.join(a, &.{ s.abs_path, "routines" });
    defer a.free(routines_dir);
    try std.fs.cwd().makePath(routines_dir);
    {
        const routine_path = try std.fs.path.join(a, &.{ s.abs_path, "routines", "invalid-expanded-item.toml" });
        defer a.free(routine_path);
        var f = try std.fs.cwd().createFile(routine_path, .{ .truncate = true });
        defer f.close();
        try f.writeAll(
            \\version = 1
            \\name = "invalid-expanded-item"
            \\
            \\[[step]]
            \\name = "research"
            \\slug = "research"
            \\kind = "prompt"
            \\prompt = "Research the task."
            \\
            \\[step.target]
            \\match = "any"
            \\
            \\[[step]]
            \\name = "compact"
            \\slug = "compact"
            \\kind = "compact"
            \\prompt = "Compact context."
            \\after = ["research"]
            \\
            \\[step.target]
            \\match = "any"
            \\
        );
    }

    var audit_writer = try audit_mod.Writer.init(a, s.abs_path);
    defer audit_writer.deinit();
    var registry = try stack_mod.StackRegistry.init(a, s.abs_path, &audit_writer, true);
    defer registry.deinit();
    var wakes = WakeCounter{};
    registry.setPostCommitHook(&wakes, countWake);
    const client = registry.localClient("local", "/internal/routine-test");

    var routine = try client.readRoutine("invalid-expanded-item");
    defer routine.deinit();
    const baseline_commits = try countCommits(a, s.abs_path);
    const baseline_audit = try auditLineCount(a, s.abs_path);

    var result = client.appendRoutine("default", .{ .stack = "default", .routine = &routine });
    switch (result) {
        .ok => |*ok| {
            ok.deinit();
            return error.ExpectedAppendRoutineFailure;
        },
        .err => |e| try std.testing.expectEqual(stack_mod.MutationFailureKind.validation_failed, e),
    }

    try std.testing.expectEqual(baseline_commits, try countCommits(a, s.abs_path));
    try std.testing.expectEqual(baseline_audit, try auditLineCount(a, s.abs_path));
    try std.testing.expectEqual(@as(usize, 0), wakes.count);

    const first_dir = try std.fs.path.join(a, &.{ s.abs_path, "stacks", "default", "0001-research" });
    defer a.free(first_dir);
    const second_dir = try std.fs.path.join(a, &.{ s.abs_path, "stacks", "default", "0002-compact" });
    defer a.free(second_dir);
    try std.testing.expect(!dirExistsPath(first_dir));
    try std.testing.expect(!dirExistsPath(second_dir));
}

test "mutation: append item with missing thread writes nothing" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "append-missing-thread");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);
    try makeRealRepo(a, s.abs_path);

    var audit_writer = try audit_mod.Writer.init(a, s.abs_path);
    defer audit_writer.deinit();
    var registry = try stack_mod.StackRegistry.init(a, s.abs_path, &audit_writer, true);
    defer registry.deinit();
    var wakes = WakeCounter{};
    registry.setPostCommitHook(&wakes, countWake);
    const client = registry.localClient("local", "/internal/thread-test");

    const baseline_commits = try countCommits(a, s.abs_path);
    const baseline_audit = try auditLineCount(a, s.abs_path);
    const before_items = try client.listItems("default");
    defer client.freeItemList(before_items);

    var result = client.appendItem("default", .{
        .stack = "default",
        .kind = "prompt",
        .slug = "missing-thread",
        .prompt_body = "hello",
        .target_match = .any,
        .thread_name = "admin",
        .thread_mode = .fresh,
        .created_at_override = "2026-05-17T12:00:00.000Z",
    });
    switch (result) {
        .ok => |*ok| {
            ok.deinit();
            return error.ExpectedAppendThreadFailure;
        },
        .err => |e| try std.testing.expectEqual(stack_mod.MutationFailureKind.not_found, e),
    }

    try std.testing.expectEqual(baseline_commits, try countCommits(a, s.abs_path));
    try std.testing.expectEqual(baseline_audit, try auditLineCount(a, s.abs_path));
    try std.testing.expectEqual(@as(usize, 0), wakes.count);

    const after_items = try client.listItems("default");
    defer client.freeItemList(after_items);
    try std.testing.expectEqual(before_items.len, after_items.len);

    const item_dir = try std.fs.path.join(a, &.{ s.abs_path, "stacks", "default", "0001-missing-thread" });
    defer a.free(item_dir);
    try std.testing.expect(!dirExistsPath(item_dir));
}
