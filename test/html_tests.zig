//! Milestone 9 — HTML rendering snapshot tests.
//!
//! Each test renders one of the daemon's browser-facing pages against the
//! `test/fixtures/stacks/smoke/` fixture, writes the output to a `.actual`
//! file next to the committed `.expected` file, and asserts byte equality.
//! Set `ORGANO_UPDATE_HTML_SNAPSHOTS=1` to regenerate the `.expected` files
//! when the templates intentionally change.
//!
//! See `impl/09_html_rendering.md` and `impl/00_test_strategy.md`.
//!
//! The fixture is the canonical smoke stack: item 0001 in `running` status
//! with a real transcript snapshot, item 0002 in `queued` status. Both pages
//! are rendered without the runtime SSE script so the snapshot stays
//! deterministic — SSE integration is covered separately by an integration
//! test that checks daemon Accept-header negotiation end-to-end.

const std = @import("std");
const organo = @import("organo");
const html = organo.html;
const storage = organo.storage;
const item_mod = organo.item;
const stack_config_mod = organo.stack_config;
const daemon_mod = organo.daemon;
const init_mod = organo.init;

const FIXTURE_ROOT = "test/fixtures/stacks/smoke";
const EXPECTED_DIR = "test/fixtures/html";

// ---------- snapshot helper ----------

/// Compare `actual` to the committed `expected_name` file. Always writes
/// `<name>.actual` next to the expected file so a failure leaves a diffable
/// artifact. When `ORGANO_UPDATE_HTML_SNAPSHOTS=1` is set, overwrite the
/// expected file instead.
fn assertSnapshot(allocator: std.mem.Allocator, expected_name: []const u8, actual: []const u8) !void {
    try std.fs.cwd().makePath(EXPECTED_DIR);
    const expected_path = try std.fs.path.join(allocator, &.{ EXPECTED_DIR, expected_name });
    defer allocator.free(expected_path);
    const actual_name = try std.fmt.allocPrint(allocator, "{s}.actual", .{expected_name});
    defer allocator.free(actual_name);
    const actual_path = try std.fs.path.join(allocator, &.{ EXPECTED_DIR, actual_name });
    defer allocator.free(actual_path);

    // Always write the actual artifact first, so a failure leaves a diff target.
    {
        var f = try std.fs.cwd().createFile(actual_path, .{ .truncate = true });
        defer f.close();
        try f.writeAll(actual);
    }

    const update_env = std.posix.getenv("ORGANO_UPDATE_HTML_SNAPSHOTS");
    const update = update_env != null and update_env.?.len > 0 and !std.mem.eql(u8, update_env.?, "0");
    if (update) {
        var f = try std.fs.cwd().createFile(expected_path, .{ .truncate = true });
        defer f.close();
        try f.writeAll(actual);
        return;
    }

    var f = std.fs.cwd().openFile(expected_path, .{}) catch |e| {
        std.debug.print(
            "html snapshot missing: {s}\n  actual written to: {s}\n  rerun with ORGANO_UPDATE_HTML_SNAPSHOTS=1 to create it\n",
            .{ expected_path, actual_path },
        );
        return e;
    };
    defer f.close();
    const stat = try f.stat();
    const expected = try allocator.alloc(u8, stat.size);
    defer allocator.free(expected);
    _ = try f.readAll(expected);
    if (!std.mem.eql(u8, expected, actual)) {
        std.debug.print(
            "html snapshot mismatch: {s}\n  actual: {s}\n  set ORGANO_UPDATE_HTML_SNAPSHOTS=1 to overwrite\n",
            .{ expected_path, actual_path },
        );
        return error.SnapshotMismatch;
    }
}

// ---------- temp roots ----------

/// Build a temp notes root that contains the committed smoke fixture under
/// `<root>/stacks/smoke/`. The fixture is copied (not symlinked) so the
/// test never mutates committed files.
const SmokeRoot = struct {
    allocator: std.mem.Allocator,
    abs_path: []u8,

    fn create(allocator: std.mem.Allocator, name_hint: []const u8) !SmokeRoot {
        const tmp_base = "/tmp/organo-test-html";
        try std.fs.cwd().makePath(tmp_base);
        var ts_buf: [32]u8 = undefined;
        const ts_str = try std.fmt.bufPrint(&ts_buf, "{d}", .{std.time.nanoTimestamp()});
        const dir_name = try std.fmt.allocPrint(allocator, "{s}-{s}", .{ name_hint, ts_str });
        defer allocator.free(dir_name);
        const full = try std.fs.path.join(allocator, &.{ tmp_base, dir_name });
        try std.fs.cwd().makePath(full);
        // Mirror committed fixture into <root>/stacks/smoke.
        const dest_stacks = try std.fs.path.join(allocator, &.{ full, "stacks" });
        defer allocator.free(dest_stacks);
        try std.fs.cwd().makePath(dest_stacks);
        try copyTree(allocator, FIXTURE_ROOT, dest_stacks, "smoke");
        return .{ .allocator = allocator, .abs_path = full };
    }

    fn deinit(self: *SmokeRoot) void {
        std.fs.cwd().deleteTree(self.abs_path) catch {};
        self.allocator.free(self.abs_path);
    }
};

fn copyTree(allocator: std.mem.Allocator, src: []const u8, dst_parent: []const u8, leaf: []const u8) !void {
    const dst = try std.fs.path.join(allocator, &.{ dst_parent, leaf });
    defer allocator.free(dst);
    try std.fs.cwd().makePath(dst);
    var src_dir = try std.fs.cwd().openDir(src, .{ .iterate = true });
    defer src_dir.close();
    var it = src_dir.iterate();
    while (try it.next()) |entry| {
        const src_child = try std.fs.path.join(allocator, &.{ src, entry.name });
        defer allocator.free(src_child);
        switch (entry.kind) {
            .directory => try copyTree(allocator, src_child, dst, entry.name),
            .file => {
                const dst_child = try std.fs.path.join(allocator, &.{ dst, entry.name });
                defer allocator.free(dst_child);
                try std.fs.cwd().copyFile(src_child, std.fs.cwd(), dst_child, .{});
            },
            else => {},
        }
    }
}

// ---------- snapshot tests (unit-level rendering) ----------

test "html snapshot: index (smoke stack only)" {
    const a = std.testing.allocator;
    var out = std.ArrayList(u8){};
    defer out.deinit(a);
    const stacks = [_][]const u8{"smoke"};
    try html.renderIndex(a, &out, &stacks);
    try assertSnapshot(a, "index.html", out.items);
}

test "html snapshot: stack detail" {
    const a = std.testing.allocator;
    var root = try SmokeRoot.create(a, "stack-detail");
    defer root.deinit();
    var reader = try storage.Reader.init(a, root.abs_path);
    defer reader.deinit();
    var cfg = try reader.readStackConfig("smoke");
    defer cfg.deinit();
    const items = try reader.listItems("smoke");
    defer reader.freeItemList(items);

    var out = std.ArrayList(u8){};
    defer out.deinit(a);
    try html.renderStack(a, &out, .{
        .name = "smoke",
        .config = &cfg,
        .items = items,
        .running_count = 1,
    });
    try assertSnapshot(a, "stack.html", out.items);
}

test "html snapshot: item detail (running, with transcript)" {
    const a = std.testing.allocator;
    var root = try SmokeRoot.create(a, "item-detail");
    defer root.deinit();
    var reader = try storage.Reader.init(a, root.abs_path);
    defer reader.deinit();
    var item = try reader.readItem("smoke", "0001");
    defer item.deinit();

    // Load the committed prompt + transcript directly so the snapshot is
    // deterministic regardless of FS metadata.
    const prompt_body = try readFixtureFile(a, "0001-hello/prompt.md");
    defer a.free(prompt_body);
    const transcript_jsonl = try readFixtureFile(a, "0001-hello/transcript.jsonl");
    defer a.free(transcript_jsonl);

    var out = std.ArrayList(u8){};
    defer out.deinit(a);
    try html.renderItem(a, &out, .{
        .stack = "smoke",
        .item = &item,
        .prompt_body = prompt_body,
        .transcript_jsonl = transcript_jsonl,
        .enable_sse = false,
    });
    try assertSnapshot(a, "item_running.html", out.items);
}

test "html snapshot: item detail (queued, no transcript)" {
    const a = std.testing.allocator;
    var root = try SmokeRoot.create(a, "item-queued");
    defer root.deinit();
    var reader = try storage.Reader.init(a, root.abs_path);
    defer reader.deinit();
    var item = try reader.readItem("smoke", "0002");
    defer item.deinit();

    const prompt_body = try readFixtureFile(a, "0002-followup/prompt.md");
    defer a.free(prompt_body);

    var out = std.ArrayList(u8){};
    defer out.deinit(a);
    try html.renderItem(a, &out, .{
        .stack = "smoke",
        .item = &item,
        .prompt_body = prompt_body,
        .transcript_jsonl = null,
        .enable_sse = false,
    });
    try assertSnapshot(a, "item_queued.html", out.items);
}

fn readFixtureFile(allocator: std.mem.Allocator, rel: []const u8) ![]u8 {
    const path = try std.fs.path.join(allocator, &.{ FIXTURE_ROOT, rel });
    defer allocator.free(path);
    var f = try std.fs.cwd().openFile(path, .{});
    defer f.close();
    const stat = try f.stat();
    const buf = try allocator.alloc(u8, stat.size);
    errdefer allocator.free(buf);
    _ = try f.readAll(buf);
    return buf;
}

// ---------- end-to-end daemon Accept-header negotiation ----------

/// Build a fully initialized notes root and copy the smoke fixture into it.
/// The result is a self-contained temp root suitable for the daemon to
/// serve.
fn buildInitializedRoot(allocator: std.mem.Allocator, name_hint: []const u8) !SmokeRoot {
    var root = try SmokeRoot.create(allocator, name_hint);
    errdefer root.deinit();
    var ir = try init_mod.run(allocator, .{
        .root = root.abs_path,
        .yes = true,
        .quiet = true,
        .now_override = "2026-05-10T14:00:00Z",
        .rng_seed_override = 0xD3D0,
    });
    ir.deinit();
    // `init` may have overwritten stacks/smoke during a make; restore from
    // the committed fixture so the test data is stable.
    const dest_stacks = try std.fs.path.join(allocator, &.{ root.abs_path, "stacks" });
    defer allocator.free(dest_stacks);
    {
        const smoke_path = try std.fs.path.join(allocator, &.{ dest_stacks, "smoke" });
        defer allocator.free(smoke_path);
        std.fs.cwd().deleteTree(smoke_path) catch {};
    }
    try copyTree(allocator, FIXTURE_ROOT, dest_stacks, "smoke");
    return root;
}

fn startEphemeralDaemon(allocator: std.mem.Allocator, root: []const u8) !daemon_mod.Daemon {
    return daemon_mod.start(allocator, .{
        .notes_root = root,
        .port_override = 0,
        .ephemeral = true,
    });
}

fn httpRequestRaw(allocator: std.mem.Allocator, port: u16, request: []const u8) ![]u8 {
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

fn splitResponse(resp: []const u8) struct { status: u16, content_type: []const u8, body: []const u8 } {
    const head_end = std.mem.indexOf(u8, resp, "\r\n\r\n") orelse return .{ .status = 0, .content_type = "", .body = "" };
    const head = resp[0..head_end];
    const body = resp[head_end + 4 ..];
    const sp1 = std.mem.indexOfScalar(u8, head, ' ') orelse return .{ .status = 0, .content_type = "", .body = body };
    const after = head[sp1 + 1 ..];
    const sp2 = std.mem.indexOfScalar(u8, after, ' ') orelse after.len;
    const code = std.fmt.parseInt(u16, after[0..sp2], 10) catch 0;
    // Crude content-type lookup.
    var ct: []const u8 = "";
    var lines_it = std.mem.splitSequence(u8, head, "\r\n");
    while (lines_it.next()) |line| {
        if (line.len > 14 and asciiEqlIgnoreCase(line[0..13], "content-type:")) {
            const v = std.mem.trim(u8, line[13..], " \t");
            ct = v;
            break;
        }
    }
    return .{ .status = code, .content_type = ct, .body = body };
}

fn asciiEqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        const xl = if (x >= 'A' and x <= 'Z') x + 32 else x;
        const yl = if (y >= 'A' and y <= 'Z') y + 32 else y;
        if (xl != yl) return false;
    }
    return true;
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
};

test "daemon: GET / returns HTML index" {
    const a = std.testing.allocator;
    var root = try buildInitializedRoot(a, "index-html");
    defer root.deinit();
    var drv: Driver = .{ .allocator = a, .daemon = try startEphemeralDaemon(a, root.abs_path) };
    defer drv.deinit();
    try drv.serve(1);
    const resp = try httpRequestRaw(a, drv.daemon.bound_port,
        "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nAccept: text/html\r\nConnection: close\r\n\r\n");
    defer a.free(resp);
    const parsed = splitResponse(resp);
    try std.testing.expectEqual(@as(u16, 200), parsed.status);
    try std.testing.expect(std.mem.startsWith(u8, parsed.content_type, "text/html"));
    try std.testing.expect(std.mem.indexOf(u8, parsed.body, "<title>organo</title>") != null);
    // Smoke stack should be listed.
    try std.testing.expect(std.mem.indexOf(u8, parsed.body, "href=\"/stacks/smoke\"") != null);
}

test "daemon: GET /stacks/smoke serves HTML when Accept: text/html" {
    const a = std.testing.allocator;
    var root = try buildInitializedRoot(a, "stack-html");
    defer root.deinit();
    var drv: Driver = .{ .allocator = a, .daemon = try startEphemeralDaemon(a, root.abs_path) };
    defer drv.deinit();
    try drv.serve(1);
    const resp = try httpRequestRaw(a, drv.daemon.bound_port,
        "GET /stacks/smoke HTTP/1.1\r\nHost: 127.0.0.1\r\nAccept: text/html\r\nConnection: close\r\n\r\n");
    defer a.free(resp);
    const parsed = splitResponse(resp);
    try std.testing.expectEqual(@as(u16, 200), parsed.status);
    try std.testing.expect(std.mem.startsWith(u8, parsed.content_type, "text/html"));
    try std.testing.expect(std.mem.indexOf(u8, parsed.body, "<table>") != null);
    try std.testing.expect(std.mem.indexOf(u8, parsed.body, "0001") != null);
    try std.testing.expect(std.mem.indexOf(u8, parsed.body, "0002") != null);
}

test "daemon: GET /stacks/smoke returns JSON by default" {
    const a = std.testing.allocator;
    var root = try buildInitializedRoot(a, "stack-json");
    defer root.deinit();
    var drv: Driver = .{ .allocator = a, .daemon = try startEphemeralDaemon(a, root.abs_path) };
    defer drv.deinit();
    try drv.serve(1);
    // No Accept header: programmatic clients keep getting JSON.
    const resp = try httpRequestRaw(a, drv.daemon.bound_port,
        "GET /stacks/smoke HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n");
    defer a.free(resp);
    const parsed = splitResponse(resp);
    try std.testing.expectEqual(@as(u16, 200), parsed.status);
    try std.testing.expect(std.mem.startsWith(u8, parsed.content_type, "application/json"));
}

test "daemon: GET /stacks/smoke/items/0001 serves HTML item page" {
    const a = std.testing.allocator;
    var root = try buildInitializedRoot(a, "item-html");
    defer root.deinit();
    var drv: Driver = .{ .allocator = a, .daemon = try startEphemeralDaemon(a, root.abs_path) };
    defer drv.deinit();
    try drv.serve(1);
    const resp = try httpRequestRaw(a, drv.daemon.bound_port,
        "GET /stacks/smoke/items/0001 HTTP/1.1\r\nHost: 127.0.0.1\r\nAccept: text/html\r\nConnection: close\r\n\r\n");
    defer a.free(resp);
    const parsed = splitResponse(resp);
    try std.testing.expectEqual(@as(u16, 200), parsed.status);
    try std.testing.expect(std.mem.startsWith(u8, parsed.content_type, "text/html"));
    try std.testing.expect(std.mem.indexOf(u8, parsed.body, "Say hello and exit") != null);
    // The committed prompt body contains an `<em>` token that MUST be HTML
    // escaped — otherwise a malicious prompt could break the page.
    try std.testing.expect(std.mem.indexOf(u8, parsed.body, "&lt;em&gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, parsed.body, "<em>HTML in prompts") == null);
    // Transcript snapshot rendered.
    try std.testing.expect(std.mem.indexOf(u8, parsed.body, "session_started") != null);
}

test "daemon: HTML responses include a CSP" {
    const a = std.testing.allocator;
    var root = try buildInitializedRoot(a, "html-csp");
    defer root.deinit();
    var drv: Driver = .{ .allocator = a, .daemon = try startEphemeralDaemon(a, root.abs_path) };
    defer drv.deinit();
    try drv.serve(1);
    const resp = try httpRequestRaw(a, drv.daemon.bound_port,
        "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nAccept: text/html\r\nConnection: close\r\n\r\n");
    defer a.free(resp);
    try std.testing.expect(std.mem.indexOf(u8, resp, "content-security-policy:") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "form-action 'self'") != null);
}

test "daemon: GET /static/style.css returns CSS" {
    const a = std.testing.allocator;
    var root = try buildInitializedRoot(a, "static-css");
    defer root.deinit();
    var drv: Driver = .{ .allocator = a, .daemon = try startEphemeralDaemon(a, root.abs_path) };
    defer drv.deinit();
    try drv.serve(1);
    const resp = try httpRequestRaw(a, drv.daemon.bound_port,
        "GET /static/style.css HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n");
    defer a.free(resp);
    const parsed = splitResponse(resp);
    try std.testing.expectEqual(@as(u16, 200), parsed.status);
    try std.testing.expect(std.mem.startsWith(u8, parsed.content_type, "text/css"));
    try std.testing.expect(std.mem.indexOf(u8, parsed.body, "body {") != null);
}

test "daemon: HTML routes don't bypass auth gate (no auth required for GET)" {
    // Sanity: GETs on HTML routes are still anonymous (loopback only).
    const a = std.testing.allocator;
    var root = try buildInitializedRoot(a, "html-auth");
    defer root.deinit();
    var drv: Driver = .{ .allocator = a, .daemon = try startEphemeralDaemon(a, root.abs_path) };
    defer drv.deinit();
    try drv.serve(1);
    const resp = try httpRequestRaw(a, drv.daemon.bound_port,
        "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nAccept: text/html\r\nConnection: close\r\n\r\n");
    defer a.free(resp);
    const parsed = splitResponse(resp);
    try std.testing.expectEqual(@as(u16, 200), parsed.status);
}

// ---------- mutation-control rendering (plan step 6) ----------

test "renderStack: pause form rendered when local_token set and stack running" {
    const a = std.testing.allocator;
    var root = try SmokeRoot.create(a, "stack-controls-pause");
    defer root.deinit();
    var reader = try storage.Reader.init(a, root.abs_path);
    defer reader.deinit();
    var cfg = try reader.readStackConfig("smoke");
    defer cfg.deinit();
    const items = try reader.listItems("smoke");
    defer reader.freeItemList(items);

    var out = std.ArrayList(u8){};
    defer out.deinit(a);
    try html.renderStack(a, &out, .{
        .name = "smoke",
        .config = &cfg,
        .items = items,
        .running_count = 1,
        .local_token = "deadbeefdeadbeefdeadbeefdeadbeef",
    });
    // The Controls section surfaces, the form posts to .../pause, and the
    // hidden field carries the local token verbatim.
    try std.testing.expect(std.mem.indexOf(u8, out.items, "<section class=\"controls\">") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "action=\"/stacks/smoke/pause\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items,
        "name=\"_token\" value=\"deadbeefdeadbeefdeadbeefdeadbeef\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "Pause stack") != null);
    // Resume form must NOT appear when the stack isn't paused.
    try std.testing.expect(std.mem.indexOf(u8, out.items, "action=\"/stacks/smoke/resume\"") == null);
}

test "renderStack: no controls when local_token omitted" {
    const a = std.testing.allocator;
    var root = try SmokeRoot.create(a, "stack-controls-none");
    defer root.deinit();
    var reader = try storage.Reader.init(a, root.abs_path);
    defer reader.deinit();
    var cfg = try reader.readStackConfig("smoke");
    defer cfg.deinit();
    const items = try reader.listItems("smoke");
    defer reader.freeItemList(items);

    var out = std.ArrayList(u8){};
    defer out.deinit(a);
    try html.renderStack(a, &out, .{
        .name = "smoke",
        .config = &cfg,
        .items = items,
        .running_count = 0,
    });
    // Default-rendered page (e.g. without a loopback token) shows no
    // mutation forms. The existing committed snapshot pins this same path.
    try std.testing.expect(std.mem.indexOf(u8, out.items, "<form") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "_token") == null);
}

test "renderItem: cancel form rendered for queued item" {
    const a = std.testing.allocator;
    var root = try SmokeRoot.create(a, "item-controls-cancel");
    defer root.deinit();
    var reader = try storage.Reader.init(a, root.abs_path);
    defer reader.deinit();
    var item = try reader.readItem("smoke", "0002"); // queued
    defer item.deinit();

    var out = std.ArrayList(u8){};
    defer out.deinit(a);
    try html.renderItem(a, &out, .{
        .stack = "smoke",
        .item = &item,
        .prompt_body = null,
        .transcript_jsonl = null,
        .enable_sse = false,
        .local_token = "0123456789abcdef0123456789abcdef",
    });
    try std.testing.expect(std.mem.indexOf(u8, out.items, "action=\"/stacks/smoke/items/0002/cancel\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items,
        "name=\"_token\" value=\"0123456789abcdef0123456789abcdef\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "Cancel item") != null);
    // Retry button doesn't apply to queued items.
    try std.testing.expect(std.mem.indexOf(u8, out.items, "Retry item") == null);
}

test "renderItem: no controls for running item (mutation layer rejects mid-run cancel)" {
    // Plan text mentions "Cancel running item" but `mutations.applyTransition`
    // rejects cancel-from-running, so we surface nothing instead of showing
    // a button that the daemon would reject. Documents the truth-table
    // alignment between html.zig and mutations.zig.
    const a = std.testing.allocator;
    var root = try SmokeRoot.create(a, "item-controls-running");
    defer root.deinit();
    var reader = try storage.Reader.init(a, root.abs_path);
    defer reader.deinit();
    var item = try reader.readItem("smoke", "0001"); // running
    defer item.deinit();

    var out = std.ArrayList(u8){};
    defer out.deinit(a);
    try html.renderItem(a, &out, .{
        .stack = "smoke",
        .item = &item,
        .prompt_body = null,
        .transcript_jsonl = null,
        .enable_sse = false,
        .local_token = "0123456789abcdef0123456789abcdef",
    });
    try std.testing.expect(std.mem.indexOf(u8, out.items, "<form") == null);
}

test "renderItem: hostile token never breaks out of hidden-input attribute" {
    // Defense-in-depth: the local token is a hex string by construction
    // (see `local_token.zig`), but the renderer still runs every dynamic
    // insertion through `escape`. Feed a quote-laden bogus token and
    // confirm no raw quote survives inside the hidden field — otherwise
    // a hostile token could break out of the attribute and inject markup.
    const a = std.testing.allocator;
    var root = try SmokeRoot.create(a, "item-token-escape");
    defer root.deinit();
    var reader = try storage.Reader.init(a, root.abs_path);
    defer reader.deinit();
    var item = try reader.readItem("smoke", "0002");
    defer item.deinit();

    var out = std.ArrayList(u8){};
    defer out.deinit(a);
    try html.renderItem(a, &out, .{
        .stack = "smoke",
        .item = &item,
        .prompt_body = null,
        .transcript_jsonl = null,
        .enable_sse = false,
        .local_token = "x\"><script>alert(1)</script>",
    });
    try std.testing.expect(std.mem.indexOf(u8, out.items, "<script>alert(1)</script>") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "&lt;script&gt;") != null);
}

// ---------- mutation-token rejection (plan step 7) ----------

test "daemon: POST /pause without form token returns 401 identity_required" {
    // Plan step 7: "Mutation-token rejection test for browser POST helpers."
    // A browser-form POST without the embedded `_token` field MUST be
    // rejected by the same auth gate that protects `Authorization: Bearer`
    // callers — otherwise the token-protection claim on plan acceptance
    // criterion 5 is vacuous.
    const a = std.testing.allocator;
    var root = try buildInitializedRoot(a, "pause-no-token");
    defer root.deinit();
    var drv: Driver = .{ .allocator = a, .daemon = try startEphemeralDaemon(a, root.abs_path) };
    defer drv.deinit();
    try drv.serve(1);

    // Empty body; form path is recognised by the content-type header.
    const body = "";
    const req = try std.fmt.allocPrint(a,
        "POST /stacks/smoke/pause HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ body.len, body });
    defer a.free(req);
    const resp = try httpRequestRaw(a, drv.daemon.bound_port, req);
    defer a.free(resp);
    const parsed = splitResponse(resp);
    try std.testing.expectEqual(@as(u16, 401), parsed.status);
    try std.testing.expect(std.mem.indexOf(u8, parsed.body, "\"code\":\"identity_required\"") != null);
}

test "daemon: POST /pause with valid form token succeeds" {
    // Plan step 6 acceptance: "Browser mutation POSTs are token-protected."
    // The complement to the rejection test — with the correct `_token`
    // form field the same endpoint accepts the request and the mutation
    // queue records the pause. Uses the daemon's in-memory token.
    const a = std.testing.allocator;
    var root = try buildInitializedRoot(a, "pause-with-token");
    defer root.deinit();
    var drv: Driver = .{ .allocator = a, .daemon = try daemon_mod.start(a, .{
        .notes_root = root.abs_path,
        .port_override = 0,
        .ephemeral = true,
        .enable_git = false,
        .check_repo_conflicts = false,
    }) };
    defer drv.deinit();
    try drv.daemon.startWorker();
    try drv.serve(1);

    const body = try std.fmt.allocPrint(a, "_token={s}", .{drv.daemon.token.bytes});
    defer a.free(body);
    const req = try std.fmt.allocPrint(a,
        "POST /stacks/smoke/pause HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ body.len, body });
    defer a.free(req);
    const resp = try httpRequestRaw(a, drv.daemon.bound_port, req);
    defer a.free(resp);
    const parsed = splitResponse(resp);
    try std.testing.expectEqual(@as(u16, 200), parsed.status);
    try std.testing.expect(std.mem.indexOf(u8, parsed.body, "\"ok\":true") != null);
}

test "daemon: HTML stack page embeds working pause form" {
    // End-to-end: GET the HTML stack page, scrape the hidden `_token`
    // value from the rendered form, then POST the same form body back to
    // the daemon. Confirms the embedded token is verbatim what the
    // daemon's auth check accepts (i.e. no encoding drift between
    // `html.zig` and `verifyAuthFormBody`).
    const a = std.testing.allocator;
    var root = try buildInitializedRoot(a, "html-form-roundtrip");
    defer root.deinit();
    var drv: Driver = .{ .allocator = a, .daemon = try daemon_mod.start(a, .{
        .notes_root = root.abs_path,
        .port_override = 0,
        .ephemeral = true,
        .enable_git = false,
        .check_repo_conflicts = false,
    }) };
    defer drv.deinit();
    try drv.daemon.startWorker();
    try drv.serve(2);

    // Step 1: render the HTML stack page.
    const get_req = "GET /stacks/smoke HTTP/1.1\r\nHost: 127.0.0.1\r\nAccept: text/html\r\nConnection: close\r\n\r\n";
    const get_resp = try httpRequestRaw(a, drv.daemon.bound_port, get_req);
    defer a.free(get_resp);
    const get_parsed = splitResponse(get_resp);
    try std.testing.expectEqual(@as(u16, 200), get_parsed.status);

    // Extract `name="_token" value="<hex>"`.
    const token_key = "name=\"_token\" value=\"";
    const idx = std.mem.indexOf(u8, get_parsed.body, token_key) orelse return error.TestUnexpectedResult;
    const after = get_parsed.body[idx + token_key.len ..];
    const end = std.mem.indexOfScalar(u8, after, '"') orelse return error.TestUnexpectedResult;
    const token = after[0..end];
    try std.testing.expectEqualStrings(drv.daemon.token.bytes, token);

    // Step 2: replay the form body with that token.
    const body = try std.fmt.allocPrint(a, "_token={s}", .{token});
    defer a.free(body);
    const post_req = try std.fmt.allocPrint(a,
        "POST /stacks/smoke/pause HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: {d}\r\n\r\n{s}",
        .{ body.len, body });
    defer a.free(post_req);
    const post_resp = try httpRequestRaw(a, drv.daemon.bound_port, post_req);
    defer a.free(post_resp);
    const post_parsed = splitResponse(post_resp);
    try std.testing.expectEqual(@as(u16, 200), post_parsed.status);
}
