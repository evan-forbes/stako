//! Integration tests for the milestone-3 daemon read path.
//!
//! Wired into `zig build test` via build.zig. Each test stands up a daemon
//! against a freshly init'd temp notes root, populated from milestone-1 item
//! fixtures, then drives HTTP read endpoints with the std.http client.

const std = @import("std");
const organo = @import("organo");
const init_mod = organo.init;
const daemon_mod = organo.daemon;
const errors_mod = organo.errors;

// ---------- harness ----------

const Scratch = struct {
    allocator: std.mem.Allocator,
    abs_path: []u8,

    fn create(allocator: std.mem.Allocator, name_hint: []const u8) !Scratch {
        const tmp = std.posix.getenv("TMPDIR") orelse "/tmp";
        var ts_buf: [32]u8 = undefined;
        const ts = std.time.nanoTimestamp();
        const ts_str = try std.fmt.bufPrint(&ts_buf, "{d}", .{ts});
        const path = try std.fs.path.join(allocator, &.{ tmp, "organo-test-daemon" });
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

/// Run `organo init` on the scratch dir with deterministic timestamp / seed.
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

/// Drop a small "demo" stack into `<root>/stacks/demo/` with two items
/// constructed from the prompt_basic / review_with_parent item fixtures.
/// This gives the read endpoints something predictable to return.
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
    // Item 0001 — prompt
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
    // Item 0002 — review with parent
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

/// Start a daemon on port 0 (ephemeral) and return the handle. Caller must
/// `deinit`. The daemon is in ephemeral mode so no PID file is written.
fn startEphemeralDaemon(allocator: std.mem.Allocator, root: []const u8) !daemon_mod.Daemon {
    return daemon_mod.start(allocator, .{
        .notes_root = root,
        .port_override = 0, // let kernel pick a free port
        .ephemeral = true,
    });
}

/// Open a TCP connection to the daemon, send `request`, read up to
/// `max_response` bytes. Returns the raw HTTP response bytes.
fn httpRequestRaw(
    allocator: std.mem.Allocator,
    port: u16,
    request: []const u8,
) ![]u8 {
    const addr = try std.net.Address.parseIp("127.0.0.1", port);
    var stream = try std.net.tcpConnectToAddress(addr);
    defer stream.close();
    try stream.writeAll(request);
    // Read until EOF.
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

/// Split an HTTP response into (status_line, headers, body). Naive; only
/// handles content-length / connection-close framing — fine for tests.
fn splitResponse(resp: []const u8) struct { status: u16, body: []const u8 } {
    const head_end = std.mem.indexOf(u8, resp, "\r\n\r\n") orelse return .{ .status = 0, .body = "" };
    const head = resp[0..head_end];
    const body = resp[head_end + 4 ..];
    // Status line: HTTP/1.1 <code> <reason>
    const sp1 = std.mem.indexOfScalar(u8, head, ' ') orelse return .{ .status = 0, .body = body };
    const after = head[sp1 + 1 ..];
    const sp2 = std.mem.indexOfScalar(u8, after, ' ') orelse after.len;
    const code_s = after[0..sp2];
    const code = std.fmt.parseInt(u16, code_s, 10) catch 0;
    return .{ .status = code, .body = body };
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

    fn deinit(self: *Driver) void {
        if (self.thread) |t| t.join();
        self.daemon.deinit();
    }

    fn serve(self: *Driver, n: usize) !void {
        self.ctx = .{ .daemon = &self.daemon, .requests = n };
        self.thread = try std.Thread.spawn(.{}, serveThread, .{&self.ctx});
    }

    fn waitServeDone(self: *Driver) void {
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }
};

fn buildDriver(allocator: std.mem.Allocator, root: []const u8) !Driver {
    const d = try startEphemeralDaemon(allocator, root);
    return .{ .allocator = allocator, .daemon = d };
}

// ---------- tests ----------

test "daemon: rejects non-loopback host fast" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "loopback");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);
    try std.testing.expectError(error.NotLoopbackHost, daemon_mod.start(a, .{
        .notes_root = s.abs_path,
        .host = "0.0.0.0",
        .port_override = 0,
        .ephemeral = true,
    }));
}

test "daemon: /healthz returns 200 ok" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "healthz");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);

    var drv = try buildDriver(a, s.abs_path);
    defer drv.deinit();
    try drv.serve(1);
    const resp = try httpRequestRaw(a, drv.daemon.bound_port, "GET /healthz HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n");
    defer a.free(resp);
    const parsed = splitResponse(resp);
    try std.testing.expectEqual(@as(u16, 200), parsed.status);
    try std.testing.expectEqualStrings("ok\n", parsed.body);
}

test "daemon: GET /stacks lists initialized stacks" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "stacks-list");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);
    try seedDemoStack(a, s.abs_path);

    var drv = try buildDriver(a, s.abs_path);
    defer drv.deinit();
    try drv.serve(1);
    const resp = try httpRequestRaw(a, drv.daemon.bound_port, "GET /stacks HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n");
    defer a.free(resp);
    const parsed = splitResponse(resp);
    try std.testing.expectEqual(@as(u16, 200), parsed.status);
    // Body contains both the init-created `default` stack and the seeded
    // `demo` stack.
    try std.testing.expect(std.mem.indexOf(u8, parsed.body, "\"default\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, parsed.body, "\"demo\"") != null);
}

test "daemon: GET /stacks/{name}/config returns parsed config JSON" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "stack-config");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);
    try seedDemoStack(a, s.abs_path);

    var drv = try buildDriver(a, s.abs_path);
    defer drv.deinit();
    try drv.serve(1);
    const resp = try httpRequestRaw(a, drv.daemon.bound_port, "GET /stacks/demo/config HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n");
    defer a.free(resp);
    const parsed = splitResponse(resp);
    try std.testing.expectEqual(@as(u16, 200), parsed.status);
    try std.testing.expect(std.mem.indexOf(u8, parsed.body, "\"description\":\"demo stack\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, parsed.body, "\"continuity\":\"chain\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, parsed.body, "\"allowed_harnesses\":[\"claude\",\"codex\"]") != null);
}

test "daemon: GET /stacks/{name}/items lists items in id order" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "items-list");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);
    try seedDemoStack(a, s.abs_path);

    var drv = try buildDriver(a, s.abs_path);
    defer drv.deinit();
    try drv.serve(1);
    const resp = try httpRequestRaw(a, drv.daemon.bound_port, "GET /stacks/demo/items HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n");
    defer a.free(resp);
    const parsed = splitResponse(resp);
    try std.testing.expectEqual(@as(u16, 200), parsed.status);
    // 0001 appears before 0002.
    const idx_one = std.mem.indexOf(u8, parsed.body, "\"0001\"") orelse return error.MissingId;
    const idx_two = std.mem.indexOf(u8, parsed.body, "\"0002\"") orelse return error.MissingId;
    try std.testing.expect(idx_one < idx_two);
    try std.testing.expect(std.mem.indexOf(u8, parsed.body, "\"slug\":\"hello\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, parsed.body, "\"kind\":\"review\"") != null);
}

test "daemon: GET /stacks/{name}/items/{id} returns the item detail" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "item-get");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);
    try seedDemoStack(a, s.abs_path);

    var drv = try buildDriver(a, s.abs_path);
    defer drv.deinit();
    try drv.serve(1);
    const resp = try httpRequestRaw(a, drv.daemon.bound_port, "GET /stacks/demo/items/0002 HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n");
    defer a.free(resp);
    const parsed = splitResponse(resp);
    try std.testing.expectEqual(@as(u16, 200), parsed.status);
    try std.testing.expect(std.mem.indexOf(u8, parsed.body, "\"id\":\"0002\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, parsed.body, "\"kind\":\"review\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, parsed.body, "\"parents\":[\"0001\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, parsed.body, "\"target\":{") != null);
}

test "daemon: GET /stacks/{name} returns config + items" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "stack-get");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);
    try seedDemoStack(a, s.abs_path);

    var drv = try buildDriver(a, s.abs_path);
    defer drv.deinit();
    try drv.serve(1);
    const resp = try httpRequestRaw(a, drv.daemon.bound_port, "GET /stacks/demo HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n");
    defer a.free(resp);
    const parsed = splitResponse(resp);
    try std.testing.expectEqual(@as(u16, 200), parsed.status);
    try std.testing.expect(std.mem.indexOf(u8, parsed.body, "\"name\":\"demo\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, parsed.body, "\"config\":{") != null);
    try std.testing.expect(std.mem.indexOf(u8, parsed.body, "\"items\":[") != null);
}

test "daemon: GET unknown stack returns 404 with canonical error body" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "stack-404");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);

    var drv = try buildDriver(a, s.abs_path);
    defer drv.deinit();
    try drv.serve(1);
    const resp = try httpRequestRaw(a, drv.daemon.bound_port, "GET /stacks/does-not-exist HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n");
    defer a.free(resp);
    const parsed = splitResponse(resp);
    try std.testing.expectEqual(@as(u16, 404), parsed.status);
    try std.testing.expect(std.mem.indexOf(u8, parsed.body, "\"code\":\"not_found\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, parsed.body, "\"details\":{\"stack\":\"does-not-exist\"}") != null);
}

test "daemon: GET unknown item returns 404 with canonical error body" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "item-404");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);
    try seedDemoStack(a, s.abs_path);

    var drv = try buildDriver(a, s.abs_path);
    defer drv.deinit();
    try drv.serve(1);
    const resp = try httpRequestRaw(a, drv.daemon.bound_port, "GET /stacks/demo/items/9999 HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n");
    defer a.free(resp);
    const parsed = splitResponse(resp);
    try std.testing.expectEqual(@as(u16, 404), parsed.status);
    try std.testing.expect(std.mem.indexOf(u8, parsed.body, "\"code\":\"not_found\"") != null);
}

test "daemon: malformed item id returns 400 validation_failed" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "item-bad");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);
    try seedDemoStack(a, s.abs_path);

    var drv = try buildDriver(a, s.abs_path);
    defer drv.deinit();
    try drv.serve(1);
    const resp = try httpRequestRaw(a, drv.daemon.bound_port, "GET /stacks/demo/items/abc HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n");
    defer a.free(resp);
    const parsed = splitResponse(resp);
    try std.testing.expectEqual(@as(u16, 400), parsed.status);
    try std.testing.expect(std.mem.indexOf(u8, parsed.body, "\"code\":\"validation_failed\"") != null);
}

test "daemon: unknown endpoint returns 404 with canonical error body" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "unknown");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);

    var drv = try buildDriver(a, s.abs_path);
    defer drv.deinit();
    try drv.serve(1);
    const resp = try httpRequestRaw(a, drv.daemon.bound_port, "GET /nonsense HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n");
    defer a.free(resp);
    const parsed = splitResponse(resp);
    try std.testing.expectEqual(@as(u16, 404), parsed.status);
    try std.testing.expect(std.mem.indexOf(u8, parsed.body, "\"code\":\"not_found\"") != null);
}

test "daemon: token is generated/loaded on start and verifies" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "token");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);

    var d = try startEphemeralDaemon(a, s.abs_path);
    defer d.deinit();
    // Token is 64 hex chars (generated by init).
    try std.testing.expectEqual(@as(usize, 64), d.token.bytes.len);
    try std.testing.expect(d.token.verify(d.token.bytes));
    try std.testing.expect(!d.token.verify("not the token"));
}

test "daemon: daemon.log is created on non-ephemeral start" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "logfile");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);

    var d = try daemon_mod.start(a, .{
        .notes_root = s.abs_path,
        .port_override = 0,
        .ephemeral = false,
    });
    defer d.deinit();

    // Log file exists.
    const log_path = try std.fs.path.join(a, &.{ s.abs_path, ".organo", "daemon.log" });
    defer a.free(log_path);
    var f = try std.fs.cwd().openFile(log_path, .{});
    defer f.close();
    const stat = try f.stat();
    try std.testing.expect(stat.size > 0); // start banner was written

    // Clean up pid file from this run.
    try daemon_mod.removePidFile(a, s.abs_path);
}

test "daemon: PID file is written and removed across start/stop cycle (non-ephemeral)" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "pidfile");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);

    var d = try daemon_mod.start(a, .{
        .notes_root = s.abs_path,
        .port_override = 0,
        .ephemeral = false,
    });
    // PID file should exist.
    {
        const info = try daemon_mod.readPidFile(a, s.abs_path);
        try std.testing.expect(info != null);
        try std.testing.expect(info.?.port == d.bound_port);
    }
    d.deinit();
    // Simulated stop on the same process — daemon.stop sends SIGTERM but
    // the calling process is alive, so use removePidFile directly for the
    // cleanup half of the cycle.
    try daemon_mod.removePidFile(a, s.abs_path);
    {
        const info = try daemon_mod.readPidFile(a, s.abs_path);
        try std.testing.expect(info == null);
    }
}

test "daemon: refuses to start when PID file points to a live process" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "already-running");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);

    // First start writes the PID file (this is the live process).
    var d = try daemon_mod.start(a, .{
        .notes_root = s.abs_path,
        .port_override = 0,
        .ephemeral = false,
    });
    defer {
        d.deinit();
        // Clean up the PID file we wrote for the test.
        daemon_mod.removePidFile(a, s.abs_path) catch {};
    }

    // Second start should refuse because the current PID is alive.
    try std.testing.expectError(error.AlreadyRunning, daemon_mod.start(a, .{
        .notes_root = s.abs_path,
        .port_override = 0,
        .ephemeral = false,
    }));
}
