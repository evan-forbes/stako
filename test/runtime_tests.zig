//! Milestone 6 runtime-core integration tests.
//!
//! These tests exercise the runtime supervisor + session manager against
//! the fake-harness scripted binaries under `test/fixtures/harness/`. They
//! never call out to a real provider CLI.

const std = @import("std");
const organo = @import("organo");
const fake = @import("helpers/fake_harness.zig");

const init_mod = organo.init;
const daemon_mod = organo.daemon;
const audit_mod = organo.audit;
const sse_mod = organo.sse;
const mutation_queue = organo.mutation_queue;
const session_manager = organo.session_manager;
const runtime_file = organo.runtime_file;
const runtime_mod = organo.runtime;
const events = organo.events;
const adapter_mod = organo.adapter;
const fake_adapter = organo.fake_adapter;

// ---------- scratch + paths ----------

const Scratch = struct {
    allocator: std.mem.Allocator,
    abs_path: []u8,

    fn create(allocator: std.mem.Allocator, name_hint: []const u8) !Scratch {
        const tmp = std.posix.getenv("TMPDIR") orelse "/tmp";
        var ts_buf: [40]u8 = undefined;
        const ts = std.time.nanoTimestamp();
        const ts_str = try std.fmt.bufPrint(&ts_buf, "{d}", .{ts});
        const base = try std.fs.path.join(allocator, &.{ tmp, "organo-test-runtime" });
        defer allocator.free(base);
        try std.fs.cwd().makePath(base);
        const dir_name = try std.fmt.allocPrint(allocator, "{s}-{s}", .{ name_hint, ts_str });
        defer allocator.free(dir_name);
        const full = try std.fs.path.join(allocator, &.{ base, dir_name });
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

fn absFixturePath(allocator: std.mem.Allocator, sub: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = try std.fs.cwd().realpath(".", &cwd_buf);
    return std.fs.path.join(allocator, &.{ cwd, "test/fixtures", sub });
}

// ---------- helpers for seeding stacks / items ----------

fn seedStack(a: std.mem.Allocator, root: []const u8, stack: []const u8, paused: bool) !void {
    const dir = try std.fs.path.join(a, &.{ root, "stacks", stack });
    defer a.free(dir);
    try std.fs.cwd().makePath(dir);
    const cfg = try std.fs.path.join(a, &.{ dir, "stack.toml" });
    defer a.free(cfg);
    var f = try std.fs.cwd().createFile(cfg, .{ .truncate = true });
    defer f.close();
    const content = try std.fmt.allocPrint(a,
        "description = \"runtime test stack\"\ncreated_at = 2026-05-10T14:00:00Z\npaused = {s}\ncontinuity = \"fresh\"\nmax_concurrent_per_stack = 1\n",
        .{if (paused) "true" else "false"},
    );
    defer a.free(content);
    try f.writeAll(content);
}

fn seedItem(
    a: std.mem.Allocator,
    root: []const u8,
    stack: []const u8,
    id: []const u8,
    slug: []const u8,
    body: []const u8,
) !void {
    const dir_name = try std.fmt.allocPrint(a, "{s}-{s}", .{ id, slug });
    defer a.free(dir_name);
    const dir = try std.fs.path.join(a, &.{ root, "stacks", stack, dir_name });
    defer a.free(dir);
    try std.fs.cwd().makePath(dir);
    const path = try std.fs.path.join(a, &.{ dir, "meta.toml" });
    defer a.free(path);
    var f = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer f.close();
    try f.writeAll(body);
}

// ---------- adapter / dispatch factory wiring ----------

const CatScript = struct {
    fixture_abs: []u8,
    script_abs: []u8,

    fn deinit(self: *CatScript, a: std.mem.Allocator) void {
        a.free(self.fixture_abs);
        a.free(self.script_abs);
    }
};

var GLOBAL_CAT_SCRIPT: ?*const CatScript = null;

fn factoryFake(allocator: std.mem.Allocator, harness: []const u8) anyerror!?adapter_mod.Adapter {
    _ = harness;
    return try fake_adapter.create(allocator);
}

fn buildCatArgvDispatch(
    allocator: std.mem.Allocator,
    harness: []const u8,
    item: *const organo.item.Item,
    item_dir_abs: []const u8,
) anyerror![][]u8 {
    _ = harness;
    _ = item;
    _ = item_dir_abs;
    const cs = GLOBAL_CAT_SCRIPT orelse return error.NoCatScript;
    return fake.buildCatArgv(allocator, cs.script_abs, cs.fixture_abs);
}

fn fakeDispatchCat() runtime_mod.Dispatch {
    return .{ .factory = factoryFake, .build_argv = buildCatArgvDispatch };
}

const StubbornScript = struct {
    script_abs: []u8,

    fn deinit(self: *StubbornScript, a: std.mem.Allocator) void {
        a.free(self.script_abs);
    }
};

var GLOBAL_STUBBORN: ?*const StubbornScript = null;

fn buildStubbornArgvDispatch(
    allocator: std.mem.Allocator,
    harness: []const u8,
    item: *const organo.item.Item,
    item_dir_abs: []const u8,
) anyerror![][]u8 {
    _ = harness;
    _ = item;
    _ = item_dir_abs;
    const sc = GLOBAL_STUBBORN orelse return error.NoStubbornScript;
    return fake.buildScriptArgv(allocator, sc.script_abs);
}

fn fakeDispatchStubborn() runtime_mod.Dispatch {
    return .{ .factory = factoryFake, .build_argv = buildStubbornArgvDispatch };
}

// ---------- tests ----------

test "event schema: round-trip JSON via parseEvent" {
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try events.writeEvent(&w, .{
        .ts = "2026-05-10T14:00:00.000Z",
        .stack = "x",
        .item = "0001",
        .session = "s1",
        .kind = .tool_call,
        .data_json = "{\"tool\":\"Edit\",\"args\":{\"path\":\"a\"}}",
    }, null);
    const line = buf[0..w.end];
    const p = events.parseEvent(line) orelse return error.ParseFailed;
    try std.testing.expectEqual(events.Kind.tool_call, p.kind);
    try std.testing.expectEqualStrings("x", p.stack);
    try std.testing.expectEqualStrings("0001", p.item);
    try std.testing.expectEqualStrings("s1", p.session);
    try std.testing.expectEqualStrings("{\"tool\":\"Edit\",\"args\":{\"path\":\"a\"}}", p.data_json);
}

test "fake adapter: claude_hello fixture produces expected event sequence" {
    const a = std.testing.allocator;
    var ad = try fake_adapter.create(a);
    defer ad.deinit(a);

    const fixture_path = try absFixturePath(a, "harness/claude_hello.jsonl");
    defer a.free(fixture_path);

    var f = try std.fs.cwd().openFile(fixture_path, .{});
    defer f.close();
    const stat = try f.stat();
    const src = try a.alloc(u8, stat.size);
    defer a.free(src);
    _ = try f.readAll(src);

    var counts = std.AutoHashMap(events.Kind, usize).init(a);
    defer counts.deinit();
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |raw| {
        if (raw.len == 0) continue;
        const ev = try ad.parseLine(a, raw);
        defer adapter_mod.freeOwnedSlice(a, ev);
        for (ev) |oe| {
            const cur = counts.get(oe.ev.kind) orelse 0;
            try counts.put(oe.ev.kind, cur + 1);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), counts.get(.session_started).?);
    try std.testing.expectEqual(@as(usize, 1), counts.get(.turn_started).?);
    try std.testing.expectEqual(@as(usize, 2), counts.get(.message_chunk).?);
    try std.testing.expectEqual(@as(usize, 1), counts.get(.message).?);
    try std.testing.expectEqual(@as(usize, 1), counts.get(.turn_completed).?);
}

test "runtime: end-to-end fake run produces transcript and completes item" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "e2e");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);

    // Seed a stack + queued item.
    try seedStack(a, s.abs_path, "demo", false);
    const item_body =
        \\id = "0001"
        \\slug = "hello"
        \\kind = "prompt"
        \\status = "queued"
        \\created_at = 2026-05-10T14:00:00Z
        \\updated_at = 2026-05-10T14:00:00Z
        \\
        \\[target]
        \\match = "any"
        \\
    ;
    try seedItem(a, s.abs_path, "demo", "0001", "hello", item_body);

    // Stand up audit + queue + supervisor.
    var aw = try audit_mod.Writer.init(a, s.abs_path);
    defer aw.deinit();
    var q = mutation_queue.Queue.init(a, s.abs_path, &aw);
    q.enable_git = false;
    defer q.deinit();
    try q.start();

    const fixture = try absFixturePath(a, "harness/claude_hello.jsonl");
    defer a.free(fixture);
    const script = try absFixturePath(a, "harness/cat_jsonl.sh");
    defer a.free(script);
    const cs = CatScript{ .fixture_abs = fixture, .script_abs = script };
    GLOBAL_CAT_SCRIPT = &cs;
    defer GLOBAL_CAT_SCRIPT = null;

    var hub = sse_mod.Hub.init(a);
    defer hub.deinit();

    var sup = runtime_mod.Supervisor.init(a, .{
        .notes_root_abs = s.abs_path,
        .queue = &q,
        .audit_writer = &aw,
        .hub = &hub,
        .dispatch = fakeDispatchCat(),
    });
    defer sup.deinit();

    try sup.tickStack("demo");

    // The session manager spawned an async session. Wait for it.
    sup.sm.waitAll();

    // Item meta.toml should now be `completed`.
    const meta_path = try std.fs.path.join(a, &.{ s.abs_path, "stacks/demo/0001-hello/meta.toml" });
    defer a.free(meta_path);
    var mf = try std.fs.cwd().openFile(meta_path, .{});
    defer mf.close();
    const mstat = try mf.stat();
    const mbuf = try a.alloc(u8, mstat.size);
    defer a.free(mbuf);
    _ = try mf.readAll(mbuf);
    try std.testing.expect(std.mem.indexOf(u8, mbuf, "status = \"completed\"") != null);

    // Transcript exists and contains the expected events.
    const item_dir = try std.fs.path.join(a, &.{ s.abs_path, "stacks/demo/0001-hello" });
    defer a.free(item_dir);
    const t_buf = try fake.readTranscript(a, item_dir);
    defer a.free(t_buf);
    try std.testing.expect(fake.countSubstr(t_buf, "\"kind\":\"session_started\"") >= 1);
    try std.testing.expect(std.mem.indexOf(u8, t_buf, "\"kind\":\"message\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, t_buf, "\"kind\":\"session_ended\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, t_buf, "\"terminal_status\":\"completed\"") != null);

    // Runtime file was deleted.
    const rp = try runtime_file.read(a, s.abs_path, "demo", "0001");
    if (rp) |p| {
        var pp = p;
        defer pp.deinit();
        return error.RuntimeFileShouldBeAbsent;
    }
}

test "runtime: paused stack does NOT dispatch" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "paused");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);
    try seedStack(a, s.abs_path, "demo", true);
    const item_body =
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
    ;
    try seedItem(a, s.abs_path, "demo", "0001", "hi", item_body);

    var aw = try audit_mod.Writer.init(a, s.abs_path);
    defer aw.deinit();
    var q = mutation_queue.Queue.init(a, s.abs_path, &aw);
    q.enable_git = false;
    defer q.deinit();
    try q.start();

    const fixture = try absFixturePath(a, "harness/claude_hello.jsonl");
    defer a.free(fixture);
    const script = try absFixturePath(a, "harness/cat_jsonl.sh");
    defer a.free(script);
    const cs = CatScript{ .fixture_abs = fixture, .script_abs = script };
    GLOBAL_CAT_SCRIPT = &cs;
    defer GLOBAL_CAT_SCRIPT = null;

    var sup = runtime_mod.Supervisor.init(a, .{
        .notes_root_abs = s.abs_path,
        .queue = &q,
        .audit_writer = &aw,
        .dispatch = fakeDispatchCat(),
    });
    defer sup.deinit();
    try sup.tickStack("demo");
    sup.sm.waitAll();

    // Item stays queued.
    const meta_path = try std.fs.path.join(a, &.{ s.abs_path, "stacks/demo/0001-hi/meta.toml" });
    defer a.free(meta_path);
    var mf = try std.fs.cwd().openFile(meta_path, .{});
    defer mf.close();
    const mstat = try mf.stat();
    const mbuf = try a.alloc(u8, mstat.size);
    defer a.free(mbuf);
    _ = try mf.readAll(mbuf);
    try std.testing.expect(std.mem.indexOf(u8, mbuf, "status = \"queued\"") != null);
}

test "runtime: two stacks dispatch independently" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "indep");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);

    // Two stacks: alpha (paused), beta (active). Items in both. Beta's
    // item must complete; alpha's must stay queued.
    try seedStack(a, s.abs_path, "alpha", true);
    try seedStack(a, s.abs_path, "beta", false);
    const body =
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
    ;
    try seedItem(a, s.abs_path, "alpha", "0001", "hi", body);
    try seedItem(a, s.abs_path, "beta", "0001", "hi", body);

    var aw = try audit_mod.Writer.init(a, s.abs_path);
    defer aw.deinit();
    var q = mutation_queue.Queue.init(a, s.abs_path, &aw);
    q.enable_git = false;
    defer q.deinit();
    try q.start();

    const fixture = try absFixturePath(a, "harness/claude_hello.jsonl");
    defer a.free(fixture);
    const script = try absFixturePath(a, "harness/cat_jsonl.sh");
    defer a.free(script);
    const cs = CatScript{ .fixture_abs = fixture, .script_abs = script };
    GLOBAL_CAT_SCRIPT = &cs;
    defer GLOBAL_CAT_SCRIPT = null;

    var sup = runtime_mod.Supervisor.init(a, .{
        .notes_root_abs = s.abs_path,
        .queue = &q,
        .audit_writer = &aw,
        .dispatch = fakeDispatchCat(),
    });
    defer sup.deinit();
    try sup.tickStack("alpha");
    try sup.tickStack("beta");
    sup.sm.waitAll();

    const alpha_meta = try std.fs.path.join(a, &.{ s.abs_path, "stacks/alpha/0001-hi/meta.toml" });
    defer a.free(alpha_meta);
    const beta_meta = try std.fs.path.join(a, &.{ s.abs_path, "stacks/beta/0001-hi/meta.toml" });
    defer a.free(beta_meta);

    {
        var f = try std.fs.cwd().openFile(alpha_meta, .{});
        defer f.close();
        const stat = try f.stat();
        const buf = try a.alloc(u8, stat.size);
        defer a.free(buf);
        _ = try f.readAll(buf);
        try std.testing.expect(std.mem.indexOf(u8, buf, "status = \"queued\"") != null);
    }
    {
        var f = try std.fs.cwd().openFile(beta_meta, .{});
        defer f.close();
        const stat = try f.stat();
        const buf = try a.alloc(u8, stat.size);
        defer a.free(buf);
        _ = try f.readAll(buf);
        try std.testing.expect(std.mem.indexOf(u8, buf, "status = \"completed\"") != null);
    }
}

test "runtime: cancellation escalates SIGINT -> SIGTERM for a stubborn process" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "cancel-escalate");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);
    try seedStack(a, s.abs_path, "demo", false);

    const body =
        \\id = "0001"
        \\slug = "stubborn"
        \\kind = "prompt"
        \\status = "queued"
        \\created_at = 2026-05-10T14:00:00Z
        \\updated_at = 2026-05-10T14:00:00Z
        \\
        \\[target]
        \\match = "any"
        \\
    ;
    try seedItem(a, s.abs_path, "demo", "0001", "stubborn", body);

    var aw = try audit_mod.Writer.init(a, s.abs_path);
    defer aw.deinit();
    var q = mutation_queue.Queue.init(a, s.abs_path, &aw);
    q.enable_git = false;
    defer q.deinit();
    try q.start();

    const script = try absFixturePath(a, "harness/claude_ignores_sigint.sh");
    defer a.free(script);
    const sc = StubbornScript{ .script_abs = script };
    GLOBAL_STUBBORN = &sc;
    defer GLOBAL_STUBBORN = null;

    var sup = runtime_mod.Supervisor.init(a, .{
        .notes_root_abs = s.abs_path,
        .queue = &q,
        .audit_writer = &aw,
        .dispatch = fakeDispatchStubborn(),
    });
    defer sup.deinit();
    try sup.tickStack("demo");

    // Wait until the session is registered (i.e., the spawn returned).
    var spins: usize = 0;
    while (sup.sm.findSessionByKey("demo", "0001") == null and spins < 200) : (spins += 1) {
        std.Thread.sleep(5 * std.time.ns_per_ms);
    }
    try std.testing.expect(sup.sm.findSessionByKey("demo", "0001") != null);

    // SIGINT then escalate within tight test bounds.
    try sup.sm.cancelAndEscalate("demo", "0001", 250, 500);
    sup.sm.waitAll();

    const meta_path = try std.fs.path.join(a, &.{ s.abs_path, "stacks/demo/0001-stubborn/meta.toml" });
    defer a.free(meta_path);
    var f = try std.fs.cwd().openFile(meta_path, .{});
    defer f.close();
    const stat = try f.stat();
    const buf = try a.alloc(u8, stat.size);
    defer a.free(buf);
    _ = try f.readAll(buf);
    try std.testing.expect(std.mem.indexOf(u8, buf, "status = \"canceled\"") != null);
}

test "runtime: restart-orphan sweep marks running items failed" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "orphan");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);
    try seedStack(a, s.abs_path, "demo", false);

    const body =
        \\id = "0001"
        \\slug = "running-item"
        \\kind = "prompt"
        \\status = "running"
        \\created_at = 2026-05-10T14:00:00Z
        \\updated_at = 2026-05-10T14:00:00Z
        \\
        \\[target]
        \\match = "any"
        \\
    ;
    try seedItem(a, s.abs_path, "demo", "0001", "running-item", body);
    try runtime_file.write(a, s.abs_path, "demo", "0001", .{
        .pid = 999999,
        .harness = "claude",
        .started_at = "2026-05-10T14:00:00.000Z",
        .transcript_path = "/tmp/x.jsonl",
        .session_id = "sess-abandoned",
    });

    var aw = try audit_mod.Writer.init(a, s.abs_path);
    defer aw.deinit();
    var q = mutation_queue.Queue.init(a, s.abs_path, &aw);
    q.enable_git = false;
    defer q.deinit();
    try q.start();

    var sup = runtime_mod.Supervisor.init(a, .{
        .notes_root_abs = s.abs_path,
        .queue = &q,
        .audit_writer = &aw,
        .dispatch = runtime_mod.fakeDispatch(),
    });
    defer sup.deinit();

    try sup.reconcileOrphans();

    const meta_path = try std.fs.path.join(a, &.{ s.abs_path, "stacks/demo/0001-running-item/meta.toml" });
    defer a.free(meta_path);
    var f = try std.fs.cwd().openFile(meta_path, .{});
    defer f.close();
    const stat = try f.stat();
    const buf = try a.alloc(u8, stat.size);
    defer a.free(buf);
    _ = try f.readAll(buf);
    try std.testing.expect(std.mem.indexOf(u8, buf, "status = \"failed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf, "failed_reason = \"daemon_restart_orphan\"") != null);

    // Runtime file is gone.
    if (try runtime_file.read(a, s.abs_path, "demo", "0001")) |p| {
        var pp = p;
        defer pp.deinit();
        return error.RuntimeFileShouldBeGone;
    }
}

test "runtime: routing preflight blocks on harness_denied when allowed_harnesses is empty/missing match" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "denied");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);

    // Stack with allowed_harnesses = ["codex"]; our factory returns the
    // fake adapter so the harness-availability probe passes, but the
    // stack restricts to codex. v1 routes to first allowed, so the test
    // exercises the "match is the first allowed" case instead — to test
    // the deny path we need an allowlist that excludes the factory's
    // produced name. Our default factory accepts any harness; so we test
    // by using an empty allowlist (`[]`) which should reject anything.
    const dir = try std.fs.path.join(a, &.{ s.abs_path, "stacks", "demo" });
    defer a.free(dir);
    try std.fs.cwd().makePath(dir);
    {
        const cfg = try std.fs.path.join(a, &.{ dir, "stack.toml" });
        defer a.free(cfg);
        var f = try std.fs.cwd().createFile(cfg, .{ .truncate = true });
        defer f.close();
        try f.writeAll(
            \\description = "x"
            \\created_at = 2026-05-10T14:00:00Z
            \\paused = false
            \\allowed_harnesses = []
            \\
        );
    }
    const body =
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
    ;
    try seedItem(a, s.abs_path, "demo", "0001", "hi", body);

    var aw = try audit_mod.Writer.init(a, s.abs_path);
    defer aw.deinit();
    var q = mutation_queue.Queue.init(a, s.abs_path, &aw);
    q.enable_git = false;
    defer q.deinit();
    try q.start();

    var sup = runtime_mod.Supervisor.init(a, .{
        .notes_root_abs = s.abs_path,
        .queue = &q,
        .audit_writer = &aw,
        .dispatch = runtime_mod.fakeDispatch(),
    });
    defer sup.deinit();
    try sup.tickStack("demo");
    sup.sm.waitAll();

    const meta_path = try std.fs.path.join(a, &.{ s.abs_path, "stacks/demo/0001-hi/meta.toml" });
    defer a.free(meta_path);
    var f = try std.fs.cwd().openFile(meta_path, .{});
    defer f.close();
    const stat = try f.stat();
    const buf = try a.alloc(u8, stat.size);
    defer a.free(buf);
    _ = try f.readAll(buf);
    try std.testing.expect(std.mem.indexOf(u8, buf, "status = \"blocked\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf, "blocked_reason = \"harness_denied\"") != null);
}

test "runtime: sleep item with elapsed `until` transitions to completed" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "sleep-elapsed");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);
    try seedStack(a, s.abs_path, "demo", false);

    const body =
        \\id = "0001"
        \\slug = "wake"
        \\kind = "sleep"
        \\status = "queued"
        \\created_at = 2026-05-10T14:00:00Z
        \\updated_at = 2026-05-10T14:00:00Z
        \\
        \\[sleep]
        \\until = 2020-01-01T00:00:00Z
        \\
    ;
    try seedItem(a, s.abs_path, "demo", "0001", "wake", body);

    var aw = try audit_mod.Writer.init(a, s.abs_path);
    defer aw.deinit();
    var q = mutation_queue.Queue.init(a, s.abs_path, &aw);
    q.enable_git = false;
    defer q.deinit();
    try q.start();

    var sup = runtime_mod.Supervisor.init(a, .{
        .notes_root_abs = s.abs_path,
        .queue = &q,
        .audit_writer = &aw,
        .dispatch = runtime_mod.fakeDispatch(),
    });
    defer sup.deinit();
    try sup.tickStack("demo");
    sup.sm.waitAll();

    const meta_path = try std.fs.path.join(a, &.{ s.abs_path, "stacks/demo/0001-wake/meta.toml" });
    defer a.free(meta_path);
    var f = try std.fs.cwd().openFile(meta_path, .{});
    defer f.close();
    const stat = try f.stat();
    const buf = try a.alloc(u8, stat.size);
    defer a.free(buf);
    _ = try f.readAll(buf);
    try std.testing.expect(std.mem.indexOf(u8, buf, "status = \"completed\"") != null);
}

test "runtime: consumes with_running_item fixture for restart sweep" {
    const a = std.testing.allocator;
    // Copy the committed fixture into a scratch dir so the sweep can write
    // to it. The fixture is read-only in-tree; we deinit the scratch on exit.
    var s = try Scratch.create(a, "fixture-orphan");
    defer s.deinit();

    // Recursively copy the fixture tree.
    const fix_root = try absFixturePath(a, "notes_roots/with_running_item");
    defer a.free(fix_root);
    try copyTree(a, fix_root, s.abs_path);

    var aw = try audit_mod.Writer.init(a, s.abs_path);
    defer aw.deinit();
    var q = mutation_queue.Queue.init(a, s.abs_path, &aw);
    q.enable_git = false;
    defer q.deinit();
    try q.start();

    var sup = runtime_mod.Supervisor.init(a, .{
        .notes_root_abs = s.abs_path,
        .queue = &q,
        .audit_writer = &aw,
        .dispatch = runtime_mod.fakeDispatch(),
    });
    defer sup.deinit();

    try sup.reconcileOrphans();

    const meta_path = try std.fs.path.join(a, &.{ s.abs_path, "stacks/demo/0001-running-item/meta.toml" });
    defer a.free(meta_path);
    var f = try std.fs.cwd().openFile(meta_path, .{});
    defer f.close();
    const stat = try f.stat();
    const buf = try a.alloc(u8, stat.size);
    defer a.free(buf);
    _ = try f.readAll(buf);
    try std.testing.expect(std.mem.indexOf(u8, buf, "status = \"failed\"") != null);

    // .organo/runtime/ is clean.
    const rt_dir = try std.fs.path.join(a, &.{ s.abs_path, ".organo/runtime/demo" });
    defer a.free(rt_dir);
    var dir = std.fs.openDirAbsolute(rt_dir, .{ .iterate = true }) catch return;
    defer dir.close();
    var it = dir.iterate();
    var count: usize = 0;
    while (try it.next()) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 0), count);
}

fn copyTree(a: std.mem.Allocator, src_abs: []const u8, dst_abs: []const u8) !void {
    try std.fs.cwd().makePath(dst_abs);
    var src_dir = try std.fs.openDirAbsolute(src_abs, .{ .iterate = true });
    defer src_dir.close();
    var it = src_dir.iterate();
    while (try it.next()) |entry| {
        const src_child = try std.fs.path.join(a, &.{ src_abs, entry.name });
        defer a.free(src_child);
        const dst_child = try std.fs.path.join(a, &.{ dst_abs, entry.name });
        defer a.free(dst_child);
        switch (entry.kind) {
            .directory => try copyTree(a, src_child, dst_child),
            .file => {
                var sf = try std.fs.cwd().openFile(src_child, .{});
                defer sf.close();
                const stat = try sf.stat();
                const buf = try a.alloc(u8, stat.size);
                defer a.free(buf);
                _ = try sf.readAll(buf);
                var df = try std.fs.cwd().createFile(dst_child, .{ .truncate = true });
                defer df.close();
                try df.writeAll(buf);
            },
            else => {},
        }
    }
}

test "runtime: global concurrency cap pauses spawns above the limit" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "cap");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);

    // Two stacks each with one queued item. Set global cap to 1.
    try seedStack(a, s.abs_path, "alpha", false);
    try seedStack(a, s.abs_path, "beta", false);
    const body =
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
    ;
    try seedItem(a, s.abs_path, "alpha", "0001", "hi", body);
    try seedItem(a, s.abs_path, "beta", "0001", "hi", body);

    var aw = try audit_mod.Writer.init(a, s.abs_path);
    defer aw.deinit();
    var q = mutation_queue.Queue.init(a, s.abs_path, &aw);
    q.enable_git = false;
    defer q.deinit();
    try q.start();

    const fixture = try absFixturePath(a, "harness/claude_hello.jsonl");
    defer a.free(fixture);
    const script = try absFixturePath(a, "harness/cat_jsonl.sh");
    defer a.free(script);
    const cs = CatScript{ .fixture_abs = fixture, .script_abs = script };
    GLOBAL_CAT_SCRIPT = &cs;
    defer GLOBAL_CAT_SCRIPT = null;

    var sup = runtime_mod.Supervisor.init(a, .{
        .notes_root_abs = s.abs_path,
        .queue = &q,
        .audit_writer = &aw,
        .max_concurrent_total = 1,
        .dispatch = fakeDispatchCat(),
    });
    defer sup.deinit();

    // Tick both stacks; with cap=1, the second spawn blocks until the
    // first reaps. The session manager's slot logic enforces this.
    try sup.tickStack("alpha");
    try sup.tickStack("beta");
    sup.sm.waitAll();

    // Both items should end up completed (the cap throttles, doesn't drop).
    for (&[_][]const u8{ "alpha", "beta" }) |stack| {
        const meta_path = try std.fs.path.join(a, &.{ s.abs_path, "stacks", stack, "0001-hi/meta.toml" });
        defer a.free(meta_path);
        var f = try std.fs.cwd().openFile(meta_path, .{});
        defer f.close();
        const stat = try f.stat();
        const buf = try a.alloc(u8, stat.size);
        defer a.free(buf);
        _ = try f.readAll(buf);
        try std.testing.expect(std.mem.indexOf(u8, buf, "status = \"completed\"") != null);
    }
}

test "SSE: subscriber receives events for its stack only" {
    const a = std.testing.allocator;
    var hub = sse_mod.Hub.init(a);
    defer hub.deinit();

    const Capture = struct {
        buf: std.ArrayList(u8) = .{},
        a: std.mem.Allocator,
    };
    var cap = Capture{ .a = a };
    defer cap.buf.deinit(a);

    const writeFn = struct {
        fn cb(ctx: *anyopaque, line: []const u8) anyerror!void {
            const c: *Capture = @ptrCast(@alignCast(ctx));
            try c.buf.appendSlice(c.a, line);
        }
    }.cb;

    const sub = try hub.subscribe("demo", .{ .ctx = &cap, .write_fn = writeFn });
    defer hub.unsubscribe(sub);

    try hub.publish(.{
        .ts = "2026-05-10T14:00:00.000Z",
        .stack = "other",
        .item = "0001",
        .kind = .session_started,
    });
    try std.testing.expectEqual(@as(usize, 0), cap.buf.items.len);

    try hub.publish(.{
        .ts = "2026-05-10T14:00:00.001Z",
        .stack = "demo",
        .item = "0001",
        .kind = .message,
        .data_json = "{\"text\":\"hi\"}",
    });
    try std.testing.expect(std.mem.startsWith(u8, cap.buf.items, "data: "));
    try std.testing.expect(std.mem.endsWith(u8, cap.buf.items, "\n\n"));
}

test "daemon SSE endpoint: returns 503 when sse_hub is null (no runtime wired)" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "sse-503");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);

    var d = try daemon_mod.start(a, .{
        .notes_root = s.abs_path,
        .port_override = 0,
        .ephemeral = true,
    });
    defer d.deinit();

    const ServeCtx = struct {
        d: *daemon_mod.Daemon,
        n: usize,
    };
    const serveFn = struct {
        fn run(ctx: *ServeCtx) void {
            var i: usize = 0;
            while (i < ctx.n) : (i += 1) daemon_mod.serveOne(ctx.d) catch break;
        }
    }.run;
    var sc = ServeCtx{ .d = &d, .n = 1 };
    const th = try std.Thread.spawn(.{}, serveFn, .{&sc});
    defer th.join();

    const addr = try std.net.Address.parseIp("127.0.0.1", d.bound_port);
    var stream = try std.net.tcpConnectToAddress(addr);
    defer stream.close();
    try stream.writeAll("GET /stacks/demo/events HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n");
    var rbuf: [4096]u8 = undefined;
    const n = stream.read(&rbuf) catch 0;
    const resp = rbuf[0..n];
    try std.testing.expect(std.mem.indexOf(u8, resp, "503") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "daemon_starting") != null);
}

test "daemon SSE endpoint: when wired, streams a published event" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "sse-stream");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);

    var d = try daemon_mod.start(a, .{
        .notes_root = s.abs_path,
        .port_override = 0,
        .ephemeral = true,
    });
    // Wire an SSE hub before tearing down. This mimics the supervisor.
    var hub = sse_mod.Hub.init(a);
    d.sse_hub = &hub;
    defer {
        d.deinit();
        hub.deinit();
    }

    const ServeCtx = struct {
        d: *daemon_mod.Daemon,
        n: usize,
    };
    const serveFn = struct {
        fn run(ctx: *ServeCtx) void {
            var i: usize = 0;
            while (i < ctx.n) : (i += 1) daemon_mod.serveOne(ctx.d) catch break;
        }
    }.run;
    var sc = ServeCtx{ .d = &d, .n = 1 };
    const th = try std.Thread.spawn(.{}, serveFn, .{&sc});

    // Open the SSE connection.
    const addr = try std.net.Address.parseIp("127.0.0.1", d.bound_port);
    var stream = try std.net.tcpConnectToAddress(addr);
    try stream.writeAll("GET /stacks/demo/events HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: keep-alive\r\n\r\n");

    // Wait for the SSE 200 header by reading until we see the blank line.
    var hdr: [1024]u8 = undefined;
    var hdr_len: usize = 0;
    while (hdr_len < hdr.len) {
        const n = stream.read(hdr[hdr_len..]) catch 0;
        if (n == 0) break;
        hdr_len += n;
        if (std.mem.indexOf(u8, hdr[0..hdr_len], "\r\n\r\n") != null) break;
    }
    try std.testing.expect(std.mem.indexOf(u8, hdr[0..hdr_len], "200 OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, hdr[0..hdr_len], "text/event-stream") != null);

    // Now ensure the accept loop is FREE: another GET on /healthz works
    // while the SSE connection is still open.
    th.join();
    sc.n = 1;
    const th2 = try std.Thread.spawn(.{}, serveFn, .{&sc});
    defer th2.join();
    {
        var stream2 = try std.net.tcpConnectToAddress(addr);
        defer stream2.close();
        try stream2.writeAll("GET /healthz HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n");
        var rb: [256]u8 = undefined;
        const n = stream2.read(&rb) catch 0;
        try std.testing.expect(std.mem.indexOf(u8, rb[0..n], "200") != null);
    }

    // Publish an event; SSE client should see it.
    try hub.publish(.{
        .ts = "2026-05-10T14:32:00.000Z",
        .stack = "demo",
        .item = "0001",
        .kind = .message,
        .data_json = "{\"text\":\"hi\"}",
    });

    // Read until we see `data:` or timeout.
    var got: [4096]u8 = undefined;
    var got_len: usize = 0;
    var attempts: usize = 0;
    while (got_len < got.len and attempts < 50) : (attempts += 1) {
        const n = stream.read(got[got_len..]) catch 0;
        if (n == 0) {
            std.Thread.sleep(10 * std.time.ns_per_ms);
            continue;
        }
        got_len += n;
        if (std.mem.indexOf(u8, got[0..got_len], "\"kind\":\"message\"") != null) break;
    }
    try std.testing.expect(std.mem.indexOf(u8, got[0..got_len], "data: ") != null);
    try std.testing.expect(std.mem.indexOf(u8, got[0..got_len], "\"kind\":\"message\"") != null);

    // Close client; the daemon thread will shut us down on deinit.
    stream.close();
}

test "runtime: daemon-owned supervisor drives a seeded item to completed without tickStack" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "daemon-driven");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);

    // Seed a stack + queued prompt item BEFORE starting the daemon, so
    // the supervisor's first poll picks the item up on its own.
    try seedStack(a, s.abs_path, "demo", false);
    const item_body =
        \\id = "0001"
        \\slug = "hello"
        \\kind = "prompt"
        \\status = "queued"
        \\created_at = 2026-05-10T14:00:00Z
        \\updated_at = 2026-05-10T14:00:00Z
        \\
        \\[target]
        \\match = "any"
        \\
    ;
    try seedItem(a, s.abs_path, "demo", "0001", "hello", item_body);

    // Wire the test-side fake-cat dispatch so the harness produces a
    // deterministic transcript.
    const fixture = try absFixturePath(a, "harness/claude_hello.jsonl");
    defer a.free(fixture);
    const script = try absFixturePath(a, "harness/cat_jsonl.sh");
    defer a.free(script);
    const cs = CatScript{ .fixture_abs = fixture, .script_abs = script };
    GLOBAL_CAT_SCRIPT = &cs;
    defer GLOBAL_CAT_SCRIPT = null;

    // Start the daemon with the runtime supervisor enabled. Per the M5
    // contract, startWorker is called AFTER the daemon is at its final
    // address; the supervisor depends on the same invariant.
    var d = try daemon_mod.start(a, .{
        .notes_root = s.abs_path,
        .port_override = 0,
        .ephemeral = true,
        .enable_git = false,
        .enable_runtime = true,
        .dispatch = fakeDispatchCat(),
    });
    defer d.deinit();
    try d.startWorker();

    // Background-serve so /healthz stays available; we never hit any
    // mutation endpoint in this test.
    const ServeCtx = struct {
        d: *daemon_mod.Daemon,
    };
    const serveFn = struct {
        fn run(ctx: *ServeCtx) void {
            // serveUntilShutdown returns when the daemon is asked to stop.
            daemon_mod.serveUntilShutdown(ctx.d) catch {};
        }
    }.run;
    var sc = ServeCtx{ .d = &d };
    const th = try std.Thread.spawn(.{}, serveFn, .{&sc});
    defer {
        d.requestShutdown();
        th.join();
    }

    // Wait until the item reaches `completed`, with a tight wall-clock
    // cap (5s). Polling the meta.toml is cheap and avoids any need to
    // call `tickStack` from the test.
    const meta_path = try std.fs.path.join(a, &.{ s.abs_path, "stacks/demo/0001-hello/meta.toml" });
    defer a.free(meta_path);

    const deadline_ms: i64 = std.time.milliTimestamp() + 5000;
    var saw_completed = false;
    while (std.time.milliTimestamp() < deadline_ms) {
        var mf = std.fs.cwd().openFile(meta_path, .{}) catch {
            std.Thread.sleep(20 * std.time.ns_per_ms);
            continue;
        };
        defer mf.close();
        const mstat = try mf.stat();
        const mbuf = try a.alloc(u8, mstat.size);
        defer a.free(mbuf);
        _ = try mf.readAll(mbuf);
        if (std.mem.indexOf(u8, mbuf, "status = \"completed\"") != null) {
            saw_completed = true;
            break;
        }
        std.Thread.sleep(20 * std.time.ns_per_ms);
    }
    try std.testing.expect(saw_completed);

    // Transcript was written by the daemon-owned session manager.
    const item_dir = try std.fs.path.join(a, &.{ s.abs_path, "stacks/demo/0001-hello" });
    defer a.free(item_dir);
    const t_buf = try fake.readTranscript(a, item_dir);
    defer a.free(t_buf);
    try std.testing.expect(std.mem.indexOf(u8, t_buf, "\"kind\":\"session_ended\"") != null);

    // Runtime file was cleaned up.
    const rp = try runtime_file.read(a, s.abs_path, "demo", "0001");
    if (rp) |p| {
        var pp = p;
        defer pp.deinit();
        return error.RuntimeFileShouldBeAbsent;
    }
}

// ---------- milestone 8: provider preflight integration ----------

test "m8 routing: gemini-routed item blocks with harness_unavailable when preflight enabled" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "gemini-preflight");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);

    // Stack allows gemini explicitly; the item targets google. With
    // `enable_provider_preflight=true`, the supervisor consults
    // provider_status which marks gemini deferred → harness_unavailable.
    const dir = try std.fs.path.join(a, &.{ s.abs_path, "stacks", "demo" });
    defer a.free(dir);
    try std.fs.cwd().makePath(dir);
    {
        const cfg = try std.fs.path.join(a, &.{ dir, "stack.toml" });
        defer a.free(cfg);
        var f = try std.fs.cwd().createFile(cfg, .{ .truncate = true });
        defer f.close();
        try f.writeAll(
            \\description = "gemini test"
            \\created_at = 2026-05-10T14:00:00Z
            \\paused = false
            \\continuity = "fresh"
            \\max_concurrent_per_stack = 1
            \\allowed_harnesses = ["gemini"]
            \\
        );
    }
    const body =
        \\id = "0001"
        \\slug = "hi"
        \\kind = "prompt"
        \\status = "queued"
        \\created_at = 2026-05-10T14:00:00Z
        \\updated_at = 2026-05-10T14:00:00Z
        \\
        \\[target]
        \\provider = "google"
        \\match = "exact"
        \\
    ;
    try seedItem(a, s.abs_path, "demo", "0001", "hi", body);

    var aw = try audit_mod.Writer.init(a, s.abs_path);
    defer aw.deinit();
    var q = mutation_queue.Queue.init(a, s.abs_path, &aw);
    q.enable_git = false;
    defer q.deinit();
    try q.start();

    var sup = runtime_mod.Supervisor.init(a, .{
        .notes_root_abs = s.abs_path,
        .queue = &q,
        .audit_writer = &aw,
        .dispatch = runtime_mod.fakeDispatch(),
        .enable_provider_preflight = true,
    });
    defer sup.deinit();
    try sup.tickStack("demo");
    sup.sm.waitAll();

    const meta_path = try std.fs.path.join(a, &.{ s.abs_path, "stacks/demo/0001-hi/meta.toml" });
    defer a.free(meta_path);
    var f = try std.fs.cwd().openFile(meta_path, .{});
    defer f.close();
    const stat = try f.stat();
    const buf = try a.alloc(u8, stat.size);
    defer a.free(buf);
    _ = try f.readAll(buf);
    try std.testing.expect(std.mem.indexOf(u8, buf, "status = \"blocked\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf, "blocked_reason = \"harness_unavailable\"") != null);
}

test "m8 routing: preflight disabled allows the fake-harness path to run as before" {
    // Regression guard: M6/M7 tests that wire scripted dispatch with
    // `enable_provider_preflight=false` (the default) must keep working
    // even when the routed harness is one of the known providers. This
    // exercises the same harness name as the M7 tests use through
    // factoryProd, but with the fake dispatch and preflight off.
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "preflight-off");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);

    const dir = try std.fs.path.join(a, &.{ s.abs_path, "stacks", "demo" });
    defer a.free(dir);
    try std.fs.cwd().makePath(dir);
    {
        const cfg = try std.fs.path.join(a, &.{ dir, "stack.toml" });
        defer a.free(cfg);
        var f = try std.fs.cwd().createFile(cfg, .{ .truncate = true });
        defer f.close();
        try f.writeAll(
            \\description = "preflight off"
            \\created_at = 2026-05-10T14:00:00Z
            \\paused = false
            \\continuity = "fresh"
            \\max_concurrent_per_stack = 1
            \\allowed_harnesses = ["claude"]
            \\
        );
    }
    const body =
        \\id = "0001"
        \\slug = "hi"
        \\kind = "prompt"
        \\status = "queued"
        \\created_at = 2026-05-10T14:00:00Z
        \\updated_at = 2026-05-10T14:00:00Z
        \\
        \\[target]
        \\provider = "anthropic"
        \\
    ;
    try seedItem(a, s.abs_path, "demo", "0001", "hi", body);

    var aw = try audit_mod.Writer.init(a, s.abs_path);
    defer aw.deinit();
    var q = mutation_queue.Queue.init(a, s.abs_path, &aw);
    q.enable_git = false;
    defer q.deinit();
    try q.start();

    // Note: fakeDispatch's factory returns a fake adapter for any
    // harness name, including "claude". With preflight OFF we should
    // see the item dispatch (and complete, since `/usr/bin/true` exits
    // with status 0 and our fake adapter emits no events but reports
    // session_ended.completed).
    var sup = runtime_mod.Supervisor.init(a, .{
        .notes_root_abs = s.abs_path,
        .queue = &q,
        .audit_writer = &aw,
        .dispatch = runtime_mod.fakeDispatch(),
        .enable_provider_preflight = false,
    });
    defer sup.deinit();
    try sup.tickStack("demo");
    sup.sm.waitAll();

    const meta_path = try std.fs.path.join(a, &.{ s.abs_path, "stacks/demo/0001-hi/meta.toml" });
    defer a.free(meta_path);
    var f = try std.fs.cwd().openFile(meta_path, .{});
    defer f.close();
    const stat = try f.stat();
    const buf = try a.alloc(u8, stat.size);
    defer a.free(buf);
    _ = try f.readAll(buf);
    // The item should NOT be blocked (preflight is off). It should have
    // transitioned to running (and may now be either running or
    // completed depending on scheduling — both are acceptable as long
    // as it isn't `blocked`).
    try std.testing.expect(std.mem.indexOf(u8, buf, "status = \"blocked\"") == null);
}
