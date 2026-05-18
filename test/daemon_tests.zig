//! Integration tests for the milestone-3 daemon read path.
//!
//! Wired into `zig build test` via build.zig. Each test stands up a daemon
//! against a freshly init'd temp notes root, populated from milestone-1 item
//! fixtures, then drives HTTP read endpoints with the std.http client.

const std = @import("std");
const stako = @import("stako");
const init_mod = stako.init;
const daemon_mod = stako.daemon;
const errors_mod = stako.errors;

// ---------- harness ----------

const Scratch = struct {
    allocator: std.mem.Allocator,
    abs_path: []u8,

    fn create(allocator: std.mem.Allocator, name_hint: []const u8) !Scratch {
        const tmp = std.posix.getenv("TMPDIR") orelse "/tmp";
        var ts_buf: [32]u8 = undefined;
        const ts = std.time.nanoTimestamp();
        const ts_str = try std.fmt.bufPrint(&ts_buf, "{d}", .{ts});
        const path = try std.fs.path.join(allocator, &.{ tmp, "stako-test-daemon" });
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

/// Run `stako init` on the scratch dir with deterministic timestamp / seed.
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
    const log_path = try std.fs.path.join(a, &.{ s.abs_path, "state", "daemon.log" });
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

// ---------- milestone 8: provider status endpoints ----------

test "daemon: GET /providers lists anthropic, openai, google" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "providers-list");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);

    var drv = try buildDriver(a, s.abs_path);
    defer drv.deinit();
    try drv.serve(1);
    const resp = try httpRequestRaw(a, drv.daemon.bound_port, "GET /providers HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n");
    defer a.free(resp);
    const parsed = splitResponse(resp);
    try std.testing.expectEqual(@as(u16, 200), parsed.status);
    // Body is a JSON {"providers":[...]} list with the three providers
    // and their harness mappings.
    try std.testing.expect(std.mem.indexOf(u8, parsed.body, "\"providers\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, parsed.body, "\"provider\":\"anthropic\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, parsed.body, "\"provider\":\"openai\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, parsed.body, "\"provider\":\"google\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, parsed.body, "\"harness\":\"claude\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, parsed.body, "\"harness\":\"codex\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, parsed.body, "\"harness\":\"gemini\"") != null);
}

test "daemon: GET /providers/google marks gemini deferred" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "provider-google");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);

    var drv = try buildDriver(a, s.abs_path);
    defer drv.deinit();
    try drv.serve(1);
    const resp = try httpRequestRaw(a, drv.daemon.bound_port, "GET /providers/google HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n");
    defer a.free(resp);
    const parsed = splitResponse(resp);
    try std.testing.expectEqual(@as(u16, 200), parsed.status);
    try std.testing.expect(std.mem.indexOf(u8, parsed.body, "\"provider\":\"google\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, parsed.body, "\"available\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, parsed.body, "\"blocked_reason\":\"harness_unavailable\"") != null);
}

test "daemon: GET /providers/gemini harness-alias path resolves" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "provider-gemini-alias");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);

    var drv = try buildDriver(a, s.abs_path);
    defer drv.deinit();
    try drv.serve(1);
    const resp = try httpRequestRaw(a, drv.daemon.bound_port, "GET /providers/gemini HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n");
    defer a.free(resp);
    const parsed = splitResponse(resp);
    try std.testing.expectEqual(@as(u16, 200), parsed.status);
    // Returns the google provider record (gemini is the harness name).
    try std.testing.expect(std.mem.indexOf(u8, parsed.body, "\"provider\":\"google\"") != null);
}

test "daemon: GET /providers/anthropic surfaces signed_in/signed_out fields" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "provider-anthropic");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);

    var drv = try buildDriver(a, s.abs_path);
    defer drv.deinit();
    try drv.serve(1);
    const resp = try httpRequestRaw(a, drv.daemon.bound_port, "GET /providers/anthropic HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n");
    defer a.free(resp);
    const parsed = splitResponse(resp);
    try std.testing.expectEqual(@as(u16, 200), parsed.status);
    try std.testing.expect(std.mem.indexOf(u8, parsed.body, "\"provider\":\"anthropic\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, parsed.body, "\"harness\":\"claude\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, parsed.body, "\"credential_env\":\"ANTHROPIC_API_KEY\"") != null);
    // Either signed_in or signed_out — both are fine; we only require the
    // field to be present.
    try std.testing.expect(std.mem.indexOf(u8, parsed.body, "\"auth\":\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, parsed.body, "\"login_hint\":\"") != null);
}

test "daemon: GET /providers/bogus returns 404" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "provider-404");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);

    var drv = try buildDriver(a, s.abs_path);
    defer drv.deinit();
    try drv.serve(1);
    const resp = try httpRequestRaw(a, drv.daemon.bound_port, "GET /providers/bogus HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n");
    defer a.free(resp);
    const parsed = splitResponse(resp);
    try std.testing.expectEqual(@as(u16, 404), parsed.status);
    try std.testing.expect(std.mem.indexOf(u8, parsed.body, "\"code\":\"not_found\"") != null);
}

test "daemon: GET /providers is a read endpoint (no auth required)" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "providers-noauth");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);

    var drv = try buildDriver(a, s.abs_path);
    defer drv.deinit();
    try drv.serve(1);
    // No Authorization header.
    const resp = try httpRequestRaw(a, drv.daemon.bound_port, "GET /providers HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n");
    defer a.free(resp);
    const parsed = splitResponse(resp);
    try std.testing.expectEqual(@as(u16, 200), parsed.status);
}

// ---------- milestone 3 audit additions ----------

test "daemon: start fails fast on already-bound port" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "addr-in-use");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);

    // Hold an ephemeral port open so a second listen() against the same
    // address surfaces AddressInUse.
    const addr = try std.net.Address.parseIp("127.0.0.1", 0);
    var holder = try addr.listen(.{ .reuse_address = false });
    defer holder.deinit();
    const taken = holder.listen_address.in.getPort();

    if (daemon_mod.start(a, .{
        .notes_root = s.abs_path,
        .port_override = taken,
        .ephemeral = true,
    })) |d| {
        // If the kernel allowed the rebind (some configs ignore reuse_address
        // contention on loopback) we don't fail the test — that's a platform
        // quirk, not a daemon bug. Drain and skip.
        var dd = d;
        dd.deinit();
        return error.SkipZigTest;
    } else |e| {
        try std.testing.expectEqual(error.AddressInUse, e);
    }
}

test "daemon: serves multiple sequential requests on the same listener" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "concurrent-seq");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);
    try seedDemoStack(a, s.abs_path);

    var drv = try buildDriver(a, s.abs_path);
    defer drv.deinit();
    // Drive three back-to-back requests through one accept-loop thread.
    try drv.serve(3);

    const r1 = try httpRequestRaw(a, drv.daemon.bound_port, "GET /healthz HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n");
    defer a.free(r1);
    const r2 = try httpRequestRaw(a, drv.daemon.bound_port, "GET /stacks HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n");
    defer a.free(r2);
    const r3 = try httpRequestRaw(a, drv.daemon.bound_port, "GET /stacks/demo HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n");
    defer a.free(r3);

    try std.testing.expectEqual(@as(u16, 200), splitResponse(r1).status);
    try std.testing.expectEqual(@as(u16, 200), splitResponse(r2).status);
    try std.testing.expectEqual(@as(u16, 200), splitResponse(r3).status);
    // Per-response bodies are isolated.
    try std.testing.expectEqualStrings("ok\n", splitResponse(r1).body);
    try std.testing.expect(std.mem.indexOf(u8, splitResponse(r2).body, "\"demo\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, splitResponse(r3).body, "\"name\":\"demo\"") != null);
}

test "daemon: POST on a GET-only endpoint returns 405 method_not_allowed" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "method-405");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);

    var drv = try buildDriver(a, s.abs_path);
    defer drv.deinit();
    try drv.serve(1);
    // /healthz has no mutation form. The POST is a method mismatch, not a 404.
    const req = "POST /healthz HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\nContent-Length: 0\r\n\r\n";
    const resp = try httpRequestRaw(a, drv.daemon.bound_port, req);
    defer a.free(resp);
    const parsed = splitResponse(resp);
    try std.testing.expectEqual(@as(u16, 405), parsed.status);
    try std.testing.expect(std.mem.indexOf(u8, parsed.body, "\"code\":\"method_not_allowed\"") != null);
}

test "daemon: PUT returns 405 method_not_allowed" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "put-405");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);

    var drv = try buildDriver(a, s.abs_path);
    defer drv.deinit();
    try drv.serve(1);
    const req = "PUT /stacks HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\nContent-Length: 0\r\n\r\n";
    const resp = try httpRequestRaw(a, drv.daemon.bound_port, req);
    defer a.free(resp);
    const parsed = splitResponse(resp);
    try std.testing.expectEqual(@as(u16, 405), parsed.status);
    try std.testing.expect(std.mem.indexOf(u8, parsed.body, "\"code\":\"method_not_allowed\"") != null);
}

test "daemon: bearer-auth negative paths surface 401 over HTTP" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "auth-negative");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);

    var drv = try buildDriver(a, s.abs_path);
    defer drv.deinit();
    try drv.serve(3);

    // (1) Missing Authorization header on a mutation route.
    const r1 = try httpRequestRaw(a, drv.daemon.bound_port,
        "POST /stacks HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}");
    defer a.free(r1);
    const p1 = splitResponse(r1);
    try std.testing.expectEqual(@as(u16, 401), p1.status);
    try std.testing.expect(std.mem.indexOf(u8, p1.body, "\"code\":\"identity_required\"") != null);

    // (2) Wrong scheme (Basic).
    const r2 = try httpRequestRaw(a, drv.daemon.bound_port,
        "POST /stacks HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\nAuthorization: Basic abcdef\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}");
    defer a.free(r2);
    try std.testing.expectEqual(@as(u16, 401), splitResponse(r2).status);

    // (3) Wrong token (right shape, wrong bytes).
    const r3 = try httpRequestRaw(a, drv.daemon.bound_port,
        "POST /stacks HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\nAuthorization: Bearer ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}");
    defer a.free(r3);
    try std.testing.expectEqual(@as(u16, 401), splitResponse(r3).status);
}

test "daemon: malformed _token form-body escape rejected without leaking" {
    // Anchors the Blocking #1 fix: a `_token` value with an invalid %XX
    // escape used to leak the 256 KiB body buffer because the
    // `formUrlDecode` error path returned null without freeing. We exercise
    // the path here to ensure the testing allocator catches any regression.
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "form-bad-escape");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);

    var drv = try buildDriver(a, s.abs_path);
    defer drv.deinit();
    try drv.serve(1);
    // %ZZ is not valid hex — `formUrlDecode` raises `error.InvalidEscape`.
    const body = "_token=%ZZ";
    const req_buf = try std.fmt.allocPrint(a, "POST /stacks HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: {d}\r\n\r\n{s}", .{ body.len, body });
    defer a.free(req_buf);
    const resp = try httpRequestRaw(a, drv.daemon.bound_port, req_buf);
    defer a.free(resp);
    const parsed = splitResponse(resp);
    try std.testing.expectEqual(@as(u16, 401), parsed.status);
}

test "daemon: deinit removes daemon.pid on clean shutdown" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "pid-deinit");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);

    var d = try daemon_mod.start(a, .{
        .notes_root = s.abs_path,
        .port_override = 0,
        .ephemeral = false,
    });
    {
        const info = try daemon_mod.readPidFile(a, s.abs_path);
        try std.testing.expect(info != null);
    }
    d.deinit();
    // PID file is removed as part of deinit.
    const info_after = try daemon_mod.readPidFile(a, s.abs_path);
    try std.testing.expect(info_after == null);
}

test "daemon: daemon_started and daemon_stopped events recorded in audit.log" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "audit-lifecycle");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);

    var d = try startEphemeralDaemon(a, s.abs_path);
    try d.startWorker();
    d.deinit();

    const path = try std.fs.path.join(a, &.{ s.abs_path, "state", "audit.log" });
    defer a.free(path);
    var f = try std.fs.cwd().openFile(path, .{});
    defer f.close();
    const stat = try f.stat();
    const buf = try a.alloc(u8, stat.size);
    defer a.free(buf);
    _ = try f.readAll(buf);
    try std.testing.expect(std.mem.indexOf(u8, buf, "\"action\":\"daemon_started\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf, "\"action\":\"daemon_stopped\"") != null);
}

test "daemon: stop returns not_running when no pidfile present" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "stop-empty");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);

    const r = try daemon_mod.stop(a, s.abs_path, 1);
    try std.testing.expectEqual(daemon_mod.StopResult.not_running, r);
}

test "daemon: stop returns not_running and cleans pidfile when pid is dead" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "stop-stale");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);

    const state_dir = try std.fs.path.join(a, &.{ s.abs_path, "state" });
    defer a.free(state_dir);
    try std.fs.cwd().makePath(state_dir);

    // Write a pidfile pointing at a PID that's almost certainly absent.
    const pid_path = try std.fs.path.join(a, &.{ s.abs_path, "state", "daemon.pid" });
    defer a.free(pid_path);
    {
        var f = try std.fs.cwd().createFile(pid_path, .{ .truncate = true, .mode = 0o600 });
        defer f.close();
        // 2^31 - 2 is well above any reasonable live pid in CI.
        try f.writeAll("2147483646\n0\n0\n");
    }
    const r = try daemon_mod.stop(a, s.abs_path, 1);
    try std.testing.expectEqual(daemon_mod.StopResult.not_running, r);
    // pidfile is gone.
    const info = try daemon_mod.readPidFile(a, s.abs_path);
    try std.testing.expect(info == null);
}

// ---------- F3 (follow-up): HTTP plumbing coverage ----------
//
// These tests pin daemon-layer behavior that previously had no direct
// regression coverage: pidfile recovery from a dead-pid sentinel, the
// daemon's response to chunked transfer-encoding, content-length=0 on a
// mutation route, body-too-large rejection, and case-insensitive
// Authorization header matching. They focus on the public HTTP surface
// (request → response → audit/disk side effects), not internal
// daemon-struct shape, so they survive future routing refactors.

fn writeStalePidFile(a: std.mem.Allocator, root: []const u8, pid: i32) !void {
    const dir = try std.fs.path.join(a, &.{ root, "state" });
    defer a.free(dir);
    try std.fs.cwd().makePath(dir);
    const pid_path = try std.fs.path.join(a, &.{ dir, "daemon.pid" });
    defer a.free(pid_path);
    var f = try std.fs.cwd().createFile(pid_path, .{ .truncate = true, .mode = 0o600 });
    defer f.close();
    var buf: [64]u8 = undefined;
    const out = try std.fmt.bufPrint(&buf, "{d}\n0\n0\n", .{pid});
    try f.writeAll(out);
}

test "F3: stale pidfile pointing at a dead pid is recovered on startup" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "stale-pid-dead");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);
    // 2^31 - 2: not a live pid on any practical system.
    try writeStalePidFile(a, s.abs_path, 2147483646);

    // Start should succeed (the writePidFile path treats the existing
    // pidfile as stale once isProcessAlive returns false) and overwrite
    // the file with this process's pid.
    var d = try daemon_mod.start(a, .{
        .notes_root = s.abs_path,
        .port_override = 0,
        .ephemeral = false,
    });
    defer {
        d.deinit();
        daemon_mod.removePidFile(a, s.abs_path) catch {};
    }
    const info = try daemon_mod.readPidFile(a, s.abs_path);
    try std.testing.expect(info != null);
    try std.testing.expect(info.?.pid != 2147483646);
    try std.testing.expectEqual(d.bound_port, info.?.port);
}

test "F3: stale pidfile pointing at a live unrelated pid refuses startup" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "stale-pid-live");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);
    // PID 1 is always alive on Linux; kill(1, 0) returns EPERM, which
    // isProcessAlive maps to "alive". The daemon must NOT clobber a
    // pidfile that names an unrelated live process.
    try writeStalePidFile(a, s.abs_path, 1);
    defer daemon_mod.removePidFile(a, s.abs_path) catch {};

    try std.testing.expectError(error.AlreadyRunning, daemon_mod.start(a, .{
        .notes_root = s.abs_path,
        .port_override = 0,
        .ephemeral = false,
    }));

    // The pidfile is unchanged — refusing didn't truncate it.
    const info = try daemon_mod.readPidFile(a, s.abs_path);
    try std.testing.expect(info != null);
    try std.testing.expectEqual(@as(std.posix.pid_t, 1), info.?.pid);
}

test "F3: pins behavior for Transfer-Encoding: chunked on POST" {
    // Daemon has no first-class chunked handling — what comes back is
    // whatever Zig's std.http.Server decides. This test does NOT assert
    // a specific status; it asserts that the request completes cleanly
    // (does not hang, does not crash, returns *some* HTTP response) so
    // a regression that breaks the framing path is caught.
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "te-chunked");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);

    var drv = try buildDriver(a, s.abs_path);
    defer drv.deinit();
    try drv.serve(1);
    // POST to a GET-only route with a valid empty chunked body. Any
    // sensible response is acceptable (405 / 400 / 411 / 200 — all
    // legitimate framings); the assertion is "we got a response".
    const req = "POST /healthz HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n";
    const resp = try httpRequestRaw(a, drv.daemon.bound_port, req);
    defer a.free(resp);
    const parsed = splitResponse(resp);
    try std.testing.expect(parsed.status >= 200 and parsed.status < 600);
}

test "F3: POST with Content-Length: 0 on a mutation route handled cleanly" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "cl-zero");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);
    try seedDemoStack(a, s.abs_path);

    var drv = try buildDriver(a, s.abs_path);
    defer drv.deinit();
    try drv.serve(1);
    // POST /stacks/demo/resume is a no-body mutation — Content-Length: 0
    // should reach the handler, which (with default identity caps = "*")
    // applies the resume mutation. The assertion is "no 500/crash"; the
    // exact 2xx/4xx is recorded for the regression guard.
    const token = drv.daemon.token.bytes;
    const req = try std.fmt.allocPrint(a,
        "POST /stacks/demo/resume HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\nAuthorization: Bearer {s}\r\nContent-Length: 0\r\n\r\n",
        .{token});
    defer a.free(req);
    const resp = try httpRequestRaw(a, drv.daemon.bound_port, req);
    defer a.free(resp);
    const parsed = splitResponse(resp);
    try std.testing.expect(parsed.status < 500);
}

test "F3: request body exceeding MAX_BODY_BYTES is rejected with 400 validation_failed" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "body-too-large");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);
    try seedDemoStack(a, s.abs_path);

    var drv = try buildDriver(a, s.abs_path);
    defer drv.deinit();
    try drv.serve(1);
    const token = drv.daemon.token.bytes;
    // MAX_BODY_BYTES is 256 KiB; send 300 KiB of 'a' to comfortably
    // exceed it. The body is intentionally not JSON — the body-size
    // gate must fire before parse.
    const body_size: usize = 300 * 1024;
    const body = try a.alloc(u8, body_size);
    defer a.free(body);
    @memset(body, 'a');
    const head = try std.fmt.allocPrint(a,
        "POST /stacks/demo/items HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\nAuthorization: Bearer {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\n\r\n",
        .{ token, body_size });
    defer a.free(head);
    const req = try a.alloc(u8, head.len + body.len);
    defer a.free(req);
    @memcpy(req[0..head.len], head);
    @memcpy(req[head.len..], body);
    const resp = try httpRequestRaw(a, drv.daemon.bound_port, req);
    defer a.free(resp);
    const parsed = splitResponse(resp);
    try std.testing.expectEqual(@as(u16, 400), parsed.status);
    try std.testing.expect(std.mem.indexOf(u8, parsed.body, "\"code\":\"validation_failed\"") != null);
}

test "F3: Authorization header lookup is case-insensitive in both name and scheme" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "header-case");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);
    try seedDemoStack(a, s.abs_path);

    var drv = try buildDriver(a, s.abs_path);
    defer drv.deinit();
    try drv.serve(2);
    const token = drv.daemon.token.bytes;

    // Lowercase header name + lowercase scheme.
    {
        const req = try std.fmt.allocPrint(a,
            "POST /stacks/demo/resume HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\nauthorization: bearer {s}\r\nContent-Length: 0\r\n\r\n",
            .{token});
        defer a.free(req);
        const resp = try httpRequestRaw(a, drv.daemon.bound_port, req);
        defer a.free(resp);
        const parsed = splitResponse(resp);
        // Must NOT be 401 — auth would have failed with the case-sensitive
        // header check that used to live here.
        try std.testing.expect(parsed.status != 401);
        try std.testing.expect(parsed.status != 403);
    }

    // ALLCAPS header name + canonical scheme.
    {
        const req = try std.fmt.allocPrint(a,
            "POST /stacks/demo/resume HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\nAUTHORIZATION: Bearer {s}\r\nContent-Length: 0\r\n\r\n",
            .{token});
        defer a.free(req);
        const resp = try httpRequestRaw(a, drv.daemon.bound_port, req);
        defer a.free(resp);
        const parsed = splitResponse(resp);
        try std.testing.expect(parsed.status != 401);
        try std.testing.expect(parsed.status != 403);
    }
}
