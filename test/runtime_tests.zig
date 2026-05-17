//! Milestone 6 runtime-core integration tests.
//!
//! These tests exercise the runtime supervisor + session manager against
//! the fake-harness scripted binaries under `test/fixtures/harness/`. They
//! never call out to a real provider CLI.

const std = @import("std");
const stako = @import("stako");
const fake = @import("helpers/fake_harness.zig");

const init_mod = stako.init;
const daemon_mod = stako.daemon;
const audit_mod = stako.audit;
const sse_mod = stako.sse;
const session_manager = stako.session_manager;
const runtime_file = stako.runtime_file;
const runtime_mod = stako.runtime;
const events = stako.events;
const adapter_mod = stako.adapter;
const fake_adapter = stako.fake_adapter;

// ---------- scratch + paths ----------

const Scratch = struct {
    allocator: std.mem.Allocator,
    abs_path: []u8,

    fn create(allocator: std.mem.Allocator, name_hint: []const u8) !Scratch {
        const tmp = std.posix.getenv("TMPDIR") orelse "/tmp";
        var ts_buf: [40]u8 = undefined;
        const ts = std.time.nanoTimestamp();
        const ts_str = try std.fmt.bufPrint(&ts_buf, "{d}", .{ts});
        const base = try std.fs.path.join(allocator, &.{ tmp, "stako-test-runtime" });
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
    const content = try std.fmt.allocPrint(
        a,
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

fn seedThread(a: std.mem.Allocator, root: []const u8, stack: []const u8, name: []const u8, body: []const u8) !void {
    const dir = try std.fs.path.join(a, &.{ root, "stacks", stack, "threads" });
    defer a.free(dir);
    try std.fs.cwd().makePath(dir);
    const file_name = try std.fmt.allocPrint(a, "{s}.toml", .{name});
    defer a.free(file_name);
    const path = try std.fs.path.join(a, &.{ dir, file_name });
    defer a.free(path);
    var f = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer f.close();
    try f.writeAll(body);
}

fn readFileAlloc(a: std.mem.Allocator, path: []const u8) ![]u8 {
    var f = try std.fs.cwd().openFile(path, .{});
    defer f.close();
    const stat = try f.stat();
    const buf = try a.alloc(u8, stat.size);
    errdefer a.free(buf);
    _ = try f.readAll(buf);
    return buf;
}

fn metaPath(a: std.mem.Allocator, root: []const u8, stack: []const u8, dir_name: []const u8) ![]u8 {
    return std.fs.path.join(a, &.{ root, "stacks", stack, dir_name, "meta.toml" });
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
    item: *const stako.item.Item,
    item_dir_abs: []const u8,
    ctx: runtime_mod.ExecutionContext,
) anyerror![][]u8 {
    _ = harness;
    _ = item;
    _ = item_dir_abs;
    _ = ctx;
    const cs = GLOBAL_CAT_SCRIPT orelse return error.NoCatScript;
    return fake.buildCatArgv(allocator, cs.script_abs, cs.fixture_abs);
}

fn fakeDispatchCat() runtime_mod.Dispatch {
    return .{ .factory = factoryFake, .build_argv = buildCatArgvDispatch };
}

fn factoryUnavailable(allocator: std.mem.Allocator, harness: []const u8) anyerror!?adapter_mod.Adapter {
    _ = allocator;
    _ = harness;
    return null;
}

fn fakeDispatchUnavailable() runtime_mod.Dispatch {
    return .{ .factory = factoryUnavailable, .build_argv = buildCatArgvDispatch };
}

const NoResumeState = struct {};

fn noResumeParseLine(impl: *anyopaque, allocator: std.mem.Allocator, raw: []const u8) anyerror![]adapter_mod.OwnedEvent {
    _ = impl;
    _ = raw;
    return allocator.alloc(adapter_mod.OwnedEvent, 0);
}

fn noResumeOnExit(impl: *anyopaque, allocator: std.mem.Allocator, exit_code: i32, ran_to_completion: bool) anyerror!adapter_mod.OwnedEvent {
    _ = impl;
    _ = exit_code;
    _ = ran_to_completion;
    const storage = try allocator.dupe(u8, "{\"exit_code\":0}");
    return .{
        .ev = .{ .stack = "", .item = "", .kind = .session_ended, .data_json = storage },
        .storage = storage,
    };
}

fn noResumeSupports(impl: *anyopaque, cap: adapter_mod.Capability) bool {
    _ = impl;
    return cap != .@"resume";
}

fn noResumeDeinit(impl: *anyopaque, allocator: std.mem.Allocator) void {
    const st: *NoResumeState = @ptrCast(@alignCast(impl));
    allocator.destroy(st);
}

const no_resume_vtable: adapter_mod.Adapter.VTable = .{
    .parse_line = noResumeParseLine,
    .parse_stderr_line = noResumeParseLine,
    .on_exit = noResumeOnExit,
    .supports = noResumeSupports,
    .deinit = noResumeDeinit,
};

fn factoryNoResume(allocator: std.mem.Allocator, harness: []const u8) anyerror!?adapter_mod.Adapter {
    _ = harness;
    const st = try allocator.create(NoResumeState);
    st.* = .{};
    return .{ .name = "fake", .impl = st, .vtable = &no_resume_vtable };
}

fn fakeDispatchNoResume() runtime_mod.Dispatch {
    return .{ .factory = factoryNoResume, .build_argv = buildCatArgvDispatch };
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
    item: *const stako.item.Item,
    item_dir_abs: []const u8,
    ctx: runtime_mod.ExecutionContext,
) anyerror![][]u8 {
    _ = harness;
    _ = item;
    _ = item_dir_abs;
    _ = ctx;
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
    var reg = try stako.stack.StackRegistry.init(a, s.abs_path, &aw, false);
    defer reg.deinit();

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
        .stack_registry = &reg,
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

    const summary_path = try std.fs.path.join(a, &.{ item_dir, "output/summary.md" });
    defer a.free(summary_path);
    {
        var f = try std.fs.cwd().openFile(summary_path, .{});
        defer f.close();
        const stat = try f.stat();
        const buf = try a.alloc(u8, stat.size);
        defer a.free(buf);
        _ = try f.readAll(buf);
        try std.testing.expect(std.mem.indexOf(u8, buf, "Hello, world!") != null);
    }
    const manifest_path = try std.fs.path.join(a, &.{ item_dir, "output/manifest.toml" });
    defer a.free(manifest_path);
    {
        var f = try std.fs.cwd().openFile(manifest_path, .{});
        defer f.close();
        const stat = try f.stat();
        const buf = try a.alloc(u8, stat.size);
        defer a.free(buf);
        _ = try f.readAll(buf);
        try std.testing.expect(std.mem.indexOf(u8, buf, "status = \"completed\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, buf, "transcript_path = \"../transcript.jsonl\"") != null);
    }
    const changed_path = try std.fs.path.join(a, &.{ item_dir, "output/changed_paths.txt" });
    defer a.free(changed_path);
    {
        var f = try std.fs.cwd().openFile(changed_path, .{});
        defer f.close();
        const stat = try f.stat();
        try std.testing.expect(stat.size > 0);
    }

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
    var reg = try stako.stack.StackRegistry.init(a, s.abs_path, &aw, false);
    defer reg.deinit();

    const fixture = try absFixturePath(a, "harness/claude_hello.jsonl");
    defer a.free(fixture);
    const script = try absFixturePath(a, "harness/cat_jsonl.sh");
    defer a.free(script);
    const cs = CatScript{ .fixture_abs = fixture, .script_abs = script };
    GLOBAL_CAT_SCRIPT = &cs;
    defer GLOBAL_CAT_SCRIPT = null;

    var sup = runtime_mod.Supervisor.init(a, .{
        .notes_root_abs = s.abs_path,
        .stack_registry = &reg,
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
    var reg = try stako.stack.StackRegistry.init(a, s.abs_path, &aw, false);
    defer reg.deinit();

    const fixture = try absFixturePath(a, "harness/claude_hello.jsonl");
    defer a.free(fixture);
    const script = try absFixturePath(a, "harness/cat_jsonl.sh");
    defer a.free(script);
    const cs = CatScript{ .fixture_abs = fixture, .script_abs = script };
    GLOBAL_CAT_SCRIPT = &cs;
    defer GLOBAL_CAT_SCRIPT = null;

    var sup = runtime_mod.Supervisor.init(a, .{
        .notes_root_abs = s.abs_path,
        .stack_registry = &reg,
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
    var reg = try stako.stack.StackRegistry.init(a, s.abs_path, &aw, false);
    defer reg.deinit();

    const script = try absFixturePath(a, "harness/claude_ignores_sigint.sh");
    defer a.free(script);
    const sc = StubbornScript{ .script_abs = script };
    GLOBAL_STUBBORN = &sc;
    defer GLOBAL_STUBBORN = null;

    var sup = runtime_mod.Supervisor.init(a, .{
        .notes_root_abs = s.abs_path,
        .stack_registry = &reg,
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
    var reg = try stako.stack.StackRegistry.init(a, s.abs_path, &aw, false);
    defer reg.deinit();

    var sup = runtime_mod.Supervisor.init(a, .{
        .notes_root_abs = s.abs_path,
        .stack_registry = &reg,
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
    var reg = try stako.stack.StackRegistry.init(a, s.abs_path, &aw, false);
    defer reg.deinit();

    var sup = runtime_mod.Supervisor.init(a, .{
        .notes_root_abs = s.abs_path,
        .stack_registry = &reg,
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

test "runtime: threaded preflight blocks missing archived no-session and unsupported resume" {
    const a = std.testing.allocator;

    const Case = struct {
        hint: []const u8,
        mode: []const u8,
        thread_body: ?[]const u8,
        dispatch: runtime_mod.Dispatch,
        reason: []const u8,
    };
    const cases = [_]Case{
        .{
            .hint = "thread-missing",
            .mode = "resume",
            .thread_body = null,
            .dispatch = runtime_mod.fakeDispatch(),
            .reason = "thread_not_found",
        },
        .{
            .hint = "thread-archived",
            .mode = "resume",
            .thread_body =
            \\version = 1
            \\name = "admin"
            \\created_at = 2026-05-17T12:00:00.000Z
            \\updated_at = 2026-05-17T12:00:00.000Z
            \\status = "archived"
            \\
            ,
            .dispatch = runtime_mod.fakeDispatch(),
            .reason = "thread_archived",
        },
        .{
            .hint = "thread-no-session",
            .mode = "resume",
            .thread_body =
            \\version = 1
            \\name = "admin"
            \\created_at = 2026-05-17T12:00:00.000Z
            \\updated_at = 2026-05-17T12:00:00.000Z
            \\status = "active"
            \\
            ,
            .dispatch = runtime_mod.fakeDispatch(),
            .reason = "thread_no_session",
        },
        .{
            .hint = "thread-continue",
            .mode = "continue",
            .thread_body =
            \\version = 1
            \\name = "admin"
            \\created_at = 2026-05-17T12:00:00.000Z
            \\updated_at = 2026-05-17T12:00:00.000Z
            \\status = "active"
            \\
            ,
            .dispatch = runtime_mod.fakeDispatch(),
            .reason = "thread_mode_unsupported",
        },
        .{
            .hint = "thread-fork",
            .mode = "fork",
            .thread_body =
            \\version = 1
            \\name = "admin"
            \\created_at = 2026-05-17T12:00:00.000Z
            \\updated_at = 2026-05-17T12:00:00.000Z
            \\status = "active"
            \\
            ,
            .dispatch = runtime_mod.fakeDispatch(),
            .reason = "thread_mode_unsupported",
        },
        .{
            .hint = "thread-no-resume-cap",
            .mode = "resume",
            .thread_body =
            \\version = 1
            \\name = "admin"
            \\created_at = 2026-05-17T12:00:00.000Z
            \\updated_at = 2026-05-17T12:00:00.000Z
            \\status = "active"
            \\
            \\[state]
            \\last_harness = "fake"
            \\last_session_id = "sess-old"
            \\
            ,
            .dispatch = fakeDispatchNoResume(),
            .reason = "thread_mode_unsupported",
        },
        .{
            .hint = "thread-harness-mismatch",
            .mode = "resume",
            .thread_body =
            \\version = 1
            \\name = "admin"
            \\created_at = 2026-05-17T12:00:00.000Z
            \\updated_at = 2026-05-17T12:00:00.000Z
            \\status = "active"
            \\
            \\[state]
            \\last_harness = "codex"
            \\last_session_id = "sess-old"
            \\
            ,
            .dispatch = runtime_mod.fakeDispatch(),
            .reason = "thread_mode_unsupported",
        },
    };

    for (cases) |case| {
        var s = try Scratch.create(a, case.hint);
        defer s.deinit();
        try initNotesRoot(a, s.abs_path);
        try seedStack(a, s.abs_path, "demo", false);
        if (case.thread_body) |body| try seedThread(a, s.abs_path, "demo", "admin", body);
        const item_body = try std.fmt.allocPrint(a,
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
            \\[thread]
            \\name = "admin"
            \\mode = "{s}"
            \\
        , .{case.mode});
        defer a.free(item_body);
        try seedItem(a, s.abs_path, "demo", "0001", "hi", item_body);

        var aw = try audit_mod.Writer.init(a, s.abs_path);
        defer aw.deinit();
        var reg = try stako.stack.StackRegistry.init(a, s.abs_path, &aw, false);
        defer reg.deinit();
        var sup = runtime_mod.Supervisor.init(a, .{
            .notes_root_abs = s.abs_path,
            .stack_registry = &reg,
            .audit_writer = &aw,
            .dispatch = case.dispatch,
        });
        defer sup.deinit();
        try sup.tickStack("demo");
        sup.sm.waitAll();

        const path = try metaPath(a, s.abs_path, "demo", "0001-hi");
        defer a.free(path);
        const meta = try readFileAlloc(a, path);
        defer a.free(meta);
        try std.testing.expect(std.mem.indexOf(u8, meta, "status = \"blocked\"") != null);
        const expected = try std.fmt.allocPrint(a, "blocked_reason = \"{s}\"", .{case.reason});
        defer a.free(expected);
        try std.testing.expect(std.mem.indexOf(u8, meta, expected) != null);
    }
}

test "runtime: target provider merge order is item then thread then stack default" {
    const a = std.testing.allocator;

    const Case = struct {
        hint: []const u8,
        item_provider: ?[]const u8,
        expected_harness: []const u8,
    };
    const cases = [_]Case{
        .{ .hint = "target-thread-wins-stack", .item_provider = null, .expected_harness = "codex" },
        .{ .hint = "target-item-wins-thread", .item_provider = "anthropic", .expected_harness = "claude" },
    };

    for (cases) |case| {
        var s = try Scratch.create(a, case.hint);
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
                \\description = "runtime test stack"
                \\created_at = 2026-05-10T14:00:00Z
                \\paused = false
                \\continuity = "fresh"
                \\max_concurrent_per_stack = 1
                \\allowed_harnesses = ["claude", "codex"]
                \\
            );
        }
        try seedThread(a, s.abs_path, "demo", "admin",
            \\version = 1
            \\name = "admin"
            \\created_at = 2026-05-17T12:00:00.000Z
            \\updated_at = 2026-05-17T12:00:00.000Z
            \\status = "active"
            \\
            \\[target]
            \\provider = "openai"
            \\
        );

        const target_provider_line = if (case.item_provider) |provider|
            try std.fmt.allocPrint(a, "provider = \"{s}\"\n", .{provider})
        else
            try a.dupe(u8, "");
        defer a.free(target_provider_line);
        const item_body = try std.fmt.allocPrint(a,
            \\id = "0001"
            \\slug = "hi"
            \\kind = "prompt"
            \\status = "queued"
            \\created_at = 2026-05-10T14:00:00Z
            \\updated_at = 2026-05-10T14:00:00Z
            \\
            \\[target]
            \\{s}match = "any"
            \\
            \\[thread]
            \\name = "admin"
            \\mode = "fresh"
            \\
        , .{target_provider_line});
        defer a.free(item_body);
        try seedItem(a, s.abs_path, "demo", "0001", "hi", item_body);

        var aw = try audit_mod.Writer.init(a, s.abs_path);
        defer aw.deinit();
        var reg = try stako.stack.StackRegistry.init(a, s.abs_path, &aw, false);
        defer reg.deinit();
        var sup = runtime_mod.Supervisor.init(a, .{
            .notes_root_abs = s.abs_path,
            .stack_registry = &reg,
            .audit_writer = &aw,
            .dispatch = runtime_mod.fakeDispatch(),
        });
        defer sup.deinit();
        try sup.tickStack("demo");
        sup.sm.waitAll();

        const path = try metaPath(a, s.abs_path, "demo", "0001-hi");
        defer a.free(path);
        const meta = try readFileAlloc(a, path);
        defer a.free(meta);
        const expected = try std.fmt.allocPrint(a, "harness = \"{s}\"", .{case.expected_harness});
        defer a.free(expected);
        try std.testing.expect(std.mem.indexOf(u8, meta, "status = \"completed\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, meta, expected) != null);
    }
}

test "runtime: fake resume carries session into output manifest and advances thread on completion" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "thread-resume");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);
    try seedStack(a, s.abs_path, "demo", false);
    try seedThread(a, s.abs_path, "demo", "admin",
        \\version = 1
        \\name = "admin"
        \\created_at = 2026-05-17T12:00:00.000Z
        \\updated_at = 2026-05-17T12:00:00.000Z
        \\status = "active"
        \\
        \\[state]
        \\last_item_id = "0001"
        \\last_harness = "fake"
        \\last_session_id = "sess-old"
        \\
    );
    try seedItem(a, s.abs_path, "demo", "0002", "resume",
        \\id = "0002"
        \\slug = "resume"
        \\kind = "prompt"
        \\status = "queued"
        \\created_at = 2026-05-10T14:00:00Z
        \\updated_at = 2026-05-10T14:00:00Z
        \\
        \\[target]
        \\match = "any"
        \\
        \\[thread]
        \\name = "admin"
        \\mode = "resume"
        \\
    );

    var aw = try audit_mod.Writer.init(a, s.abs_path);
    defer aw.deinit();
    var reg = try stako.stack.StackRegistry.init(a, s.abs_path, &aw, false);
    defer reg.deinit();
    var sup = runtime_mod.Supervisor.init(a, .{
        .notes_root_abs = s.abs_path,
        .stack_registry = &reg,
        .audit_writer = &aw,
        .dispatch = runtime_mod.fakeDispatch(),
    });
    defer sup.deinit();
    try sup.tickStack("demo");
    sup.sm.waitAll();

    const thread_path = try std.fs.path.join(a, &.{ s.abs_path, "stacks/demo/threads/admin.toml" });
    defer a.free(thread_path);
    const thread = try readFileAlloc(a, thread_path);
    defer a.free(thread);
    try std.testing.expect(std.mem.indexOf(u8, thread, "last_item_id = \"0002\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, thread, "last_session_id = \"sess-old\"") != null);

    const manifest_path = try std.fs.path.join(a, &.{ s.abs_path, "stacks/demo/0002-resume/output/manifest.toml" });
    defer a.free(manifest_path);
    const manifest = try readFileAlloc(a, manifest_path);
    defer a.free(manifest);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "[thread]") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "name = \"admin\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "mode = \"resume\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, manifest, "resume_session_id = \"sess-old\"") != null);
}

test "runtime: input item summary materializes rendered prompt before dispatch" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "prompt-input-item");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);
    try seedStack(a, s.abs_path, "demo", false);
    try seedItem(a, s.abs_path, "demo", "0001", "plan",
        \\id = "0001"
        \\slug = "plan"
        \\kind = "prompt"
        \\status = "completed"
        \\created_at = 2026-05-10T14:00:00Z
        \\updated_at = 2026-05-10T14:00:00Z
        \\
        \\[target]
        \\match = "any"
        \\
    );
    const output_dir = try std.fs.path.join(a, &.{ s.abs_path, "stacks/demo/0001-plan/output" });
    defer a.free(output_dir);
    try std.fs.cwd().makePath(output_dir);
    {
        const summary_path = try std.fs.path.join(a, &.{ s.abs_path, "stacks/demo/0001-plan/output/summary.md" });
        defer a.free(summary_path);
        var f = try std.fs.cwd().createFile(summary_path, .{ .truncate = true });
        defer f.close();
        try f.writeAll("prior item summary\n");
    }
    try seedItem(a, s.abs_path, "demo", "0002", "next",
        \\id = "0002"
        \\slug = "next"
        \\kind = "prompt"
        \\status = "queued"
        \\created_at = 2026-05-10T14:00:00Z
        \\updated_at = 2026-05-10T14:00:00Z
        \\
        \\[target]
        \\match = "any"
        \\
        \\[inputs]
        \\items = ["0001"]
        \\mode = "append"
        \\
    );
    {
        const prompt_path = try std.fs.path.join(a, &.{ s.abs_path, "stacks/demo/0002-next/prompt.md" });
        defer a.free(prompt_path);
        var f = try std.fs.cwd().createFile(prompt_path, .{ .truncate = true });
        defer f.close();
        try f.writeAll("base prompt");
    }

    var aw = try audit_mod.Writer.init(a, s.abs_path);
    defer aw.deinit();
    var reg = try stako.stack.StackRegistry.init(a, s.abs_path, &aw, false);
    defer reg.deinit();

    const fixture = try absFixturePath(a, "harness/claude_hello.jsonl");
    defer a.free(fixture);
    const script = try absFixturePath(a, "harness/cat_jsonl.sh");
    defer a.free(script);
    const cs = CatScript{ .fixture_abs = fixture, .script_abs = script };
    GLOBAL_CAT_SCRIPT = &cs;
    defer GLOBAL_CAT_SCRIPT = null;

    var sup = runtime_mod.Supervisor.init(a, .{
        .notes_root_abs = s.abs_path,
        .stack_registry = &reg,
        .audit_writer = &aw,
        .dispatch = fakeDispatchCat(),
    });
    defer sup.deinit();
    try sup.tickStack("demo");
    sup.sm.waitAll();

    const rendered_path = try std.fs.path.join(a, &.{ s.abs_path, "stacks/demo/0002-next/rendered_prompt.md" });
    defer a.free(rendered_path);
    var f = try std.fs.cwd().openFile(rendered_path, .{});
    defer f.close();
    const stat = try f.stat();
    const buf = try a.alloc(u8, stat.size);
    defer a.free(buf);
    _ = try f.readAll(buf);
    try std.testing.expect(std.mem.indexOf(u8, buf, "base prompt\n\n---\n\n## Registered Inputs") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf, "Source: stacks/demo/0001-plan/output/summary.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf, "prior item summary") != null);
}

test "runtime: rendered prompt is not written for later preflight block" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "prompt-input-harness-block");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);
    try seedStack(a, s.abs_path, "demo", false);
    try seedItem(a, s.abs_path, "demo", "0001", "plan",
        \\id = "0001"
        \\slug = "plan"
        \\kind = "prompt"
        \\status = "completed"
        \\created_at = 2026-05-10T14:00:00Z
        \\updated_at = 2026-05-10T14:00:00Z
        \\
        \\[target]
        \\match = "any"
        \\
    );
    const output_dir = try std.fs.path.join(a, &.{ s.abs_path, "stacks/demo/0001-plan/output" });
    defer a.free(output_dir);
    try std.fs.cwd().makePath(output_dir);
    {
        const summary_path = try std.fs.path.join(a, &.{ output_dir, "summary.md" });
        defer a.free(summary_path);
        var f = try std.fs.cwd().createFile(summary_path, .{ .truncate = true });
        defer f.close();
        try f.writeAll("prior item summary\n");
    }
    try seedItem(a, s.abs_path, "demo", "0002", "next",
        \\id = "0002"
        \\slug = "next"
        \\kind = "prompt"
        \\status = "queued"
        \\created_at = 2026-05-10T14:00:00Z
        \\updated_at = 2026-05-10T14:00:00Z
        \\
        \\[target]
        \\match = "any"
        \\
        \\[inputs]
        \\items = ["0001"]
        \\
    );

    var aw = try audit_mod.Writer.init(a, s.abs_path);
    defer aw.deinit();
    var reg = try stako.stack.StackRegistry.init(a, s.abs_path, &aw, false);
    defer reg.deinit();
    var sup = runtime_mod.Supervisor.init(a, .{
        .notes_root_abs = s.abs_path,
        .stack_registry = &reg,
        .audit_writer = &aw,
        .dispatch = fakeDispatchUnavailable(),
    });
    defer sup.deinit();
    try sup.tickStack("demo");

    const rendered_path = try std.fs.path.join(a, &.{ s.abs_path, "stacks/demo/0002-next/rendered_prompt.md" });
    defer a.free(rendered_path);
    try std.testing.expectError(error.FileNotFound, std.fs.cwd().access(rendered_path, .{}));

    const meta_path = try std.fs.path.join(a, &.{ s.abs_path, "stacks/demo/0002-next/meta.toml" });
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

test "runtime: missing input item blocks before spawn" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "prompt-input-missing");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);
    try seedStack(a, s.abs_path, "demo", false);
    try seedItem(a, s.abs_path, "demo", "0001", "next",
        \\id = "0001"
        \\slug = "next"
        \\kind = "prompt"
        \\status = "queued"
        \\created_at = 2026-05-10T14:00:00Z
        \\updated_at = 2026-05-10T14:00:00Z
        \\
        \\[target]
        \\match = "any"
        \\
        \\[inputs]
        \\items = ["0009"]
        \\
    );

    var aw = try audit_mod.Writer.init(a, s.abs_path);
    defer aw.deinit();
    var reg = try stako.stack.StackRegistry.init(a, s.abs_path, &aw, false);
    defer reg.deinit();
    var sup = runtime_mod.Supervisor.init(a, .{
        .notes_root_abs = s.abs_path,
        .stack_registry = &reg,
        .audit_writer = &aw,
        .dispatch = runtime_mod.fakeDispatch(),
    });
    defer sup.deinit();
    try sup.tickStack("demo");
    sup.sm.waitAll();

    const meta_path = try std.fs.path.join(a, &.{ s.abs_path, "stacks/demo/0001-next/meta.toml" });
    defer a.free(meta_path);
    var f = try std.fs.cwd().openFile(meta_path, .{});
    defer f.close();
    const stat = try f.stat();
    const buf = try a.alloc(u8, stat.size);
    defer a.free(buf);
    _ = try f.readAll(buf);
    try std.testing.expect(std.mem.indexOf(u8, buf, "status = \"blocked\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf, "blocked_reason = \"input_missing\"") != null);
}

test "runtime: oversized input file blocks before spawn" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "prompt-input-large");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);
    try seedStack(a, s.abs_path, "demo", false);
    {
        const big_path = try std.fs.path.join(a, &.{ s.abs_path, "big.md" });
        defer a.free(big_path);
        var f = try std.fs.cwd().createFile(big_path, .{ .truncate = true });
        defer f.close();
        const chunk = "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n";
        var n: usize = 0;
        while (n <= stako.prompt_materializer.MAX_INPUT_BYTES) : (n += chunk.len) try f.writeAll(chunk);
    }
    try seedItem(a, s.abs_path, "demo", "0001", "next",
        \\id = "0001"
        \\slug = "next"
        \\kind = "prompt"
        \\status = "queued"
        \\created_at = 2026-05-10T14:00:00Z
        \\updated_at = 2026-05-10T14:00:00Z
        \\
        \\[target]
        \\match = "any"
        \\
        \\[inputs]
        \\files = ["big.md"]
        \\
    );

    var aw = try audit_mod.Writer.init(a, s.abs_path);
    defer aw.deinit();
    var reg = try stako.stack.StackRegistry.init(a, s.abs_path, &aw, false);
    defer reg.deinit();
    var sup = runtime_mod.Supervisor.init(a, .{
        .notes_root_abs = s.abs_path,
        .stack_registry = &reg,
        .audit_writer = &aw,
        .dispatch = runtime_mod.fakeDispatch(),
    });
    defer sup.deinit();
    try sup.tickStack("demo");
    sup.sm.waitAll();

    const meta_path = try std.fs.path.join(a, &.{ s.abs_path, "stacks/demo/0001-next/meta.toml" });
    defer a.free(meta_path);
    var f = try std.fs.cwd().openFile(meta_path, .{});
    defer f.close();
    const stat = try f.stat();
    const buf = try a.alloc(u8, stat.size);
    defer a.free(buf);
    _ = try f.readAll(buf);
    try std.testing.expect(std.mem.indexOf(u8, buf, "status = \"blocked\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf, "blocked_reason = \"input_too_large\"") != null);
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
    var reg = try stako.stack.StackRegistry.init(a, s.abs_path, &aw, false);
    defer reg.deinit();

    var sup = runtime_mod.Supervisor.init(a, .{
        .notes_root_abs = s.abs_path,
        .stack_registry = &reg,
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
    var reg = try stako.stack.StackRegistry.init(a, s.abs_path, &aw, false);
    defer reg.deinit();

    var sup = runtime_mod.Supervisor.init(a, .{
        .notes_root_abs = s.abs_path,
        .stack_registry = &reg,
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

    // .stako/runtime/ is clean.
    const rt_dir = try std.fs.path.join(a, &.{ s.abs_path, ".stako/runtime/demo" });
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
    var reg = try stako.stack.StackRegistry.init(a, s.abs_path, &aw, false);
    defer reg.deinit();

    const fixture = try absFixturePath(a, "harness/claude_hello.jsonl");
    defer a.free(fixture);
    const script = try absFixturePath(a, "harness/cat_jsonl.sh");
    defer a.free(script);
    const cs = CatScript{ .fixture_abs = fixture, .script_abs = script };
    GLOBAL_CAT_SCRIPT = &cs;
    defer GLOBAL_CAT_SCRIPT = null;

    var sup = runtime_mod.Supervisor.init(a, .{
        .notes_root_abs = s.abs_path,
        .stack_registry = &reg,
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
    var reg = try stako.stack.StackRegistry.init(a, s.abs_path, &aw, false);
    defer reg.deinit();

    var sup = runtime_mod.Supervisor.init(a, .{
        .notes_root_abs = s.abs_path,
        .stack_registry = &reg,
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
    var reg = try stako.stack.StackRegistry.init(a, s.abs_path, &aw, false);
    defer reg.deinit();

    // Note: fakeDispatch's factory returns a fake adapter for any
    // harness name, including "claude". With preflight OFF we should
    // see the item dispatch (and complete, since `/usr/bin/true` exits
    // with status 0 and our fake adapter emits no events but reports
    // session_ended.completed).
    var sup = runtime_mod.Supervisor.init(a, .{
        .notes_root_abs = s.abs_path,
        .stack_registry = &reg,
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

// ---------- milestone 6 audit coverage additions ----------

test "SSE Hub: multiple concurrent subscribers each receive every published event" {
    // Audit coverage gap: prior tests never exercised N>1 subscribers.
    const a = std.testing.allocator;
    var hub = sse_mod.Hub.init(a);
    defer hub.deinit();

    const Cap = struct {
        buf: std.ArrayList(u8) = .{},
        a: std.mem.Allocator,
        writes: usize = 0,
    };
    const writeFn = struct {
        fn cb(ctx: *anyopaque, line: []const u8) anyerror!void {
            const c: *Cap = @ptrCast(@alignCast(ctx));
            try c.buf.appendSlice(c.a, line);
            c.writes += 1;
        }
    }.cb;

    var c1 = Cap{ .a = a };
    var c2 = Cap{ .a = a };
    var c3 = Cap{ .a = a };
    defer c1.buf.deinit(a);
    defer c2.buf.deinit(a);
    defer c3.buf.deinit(a);

    const s1 = try hub.subscribe("demo", .{ .ctx = &c1, .write_fn = writeFn });
    const s2 = try hub.subscribe("demo", .{ .ctx = &c2, .write_fn = writeFn });
    const s3 = try hub.subscribe("demo", .{ .ctx = &c3, .write_fn = writeFn });

    // Three events; each subscriber should see all three.
    try hub.publish(.{ .stack = "demo", .item = "0001", .kind = .session_started });
    try hub.publish(.{ .stack = "demo", .item = "0001", .kind = .message });
    try hub.publish(.{ .stack = "demo", .item = "0001", .kind = .session_ended });

    try std.testing.expectEqual(@as(usize, 3), c1.writes);
    try std.testing.expectEqual(@as(usize, 3), c2.writes);
    try std.testing.expectEqual(@as(usize, 3), c3.writes);

    // Unsubscribe one and re-publish. The remaining two still receive.
    hub.unsubscribe(s2);
    try hub.publish(.{ .stack = "demo", .item = "0001", .kind = .message });
    try std.testing.expectEqual(@as(usize, 4), c1.writes);
    try std.testing.expectEqual(@as(usize, 3), c2.writes);
    try std.testing.expectEqual(@as(usize, 4), c3.writes);

    hub.unsubscribe(s1);
    hub.unsubscribe(s3);
}

test "SSE Hub: failing sink retires while other concurrent subscribers continue" {
    // Audit coverage gap: previously tested fail-sink with a single sub.
    // Here verify that one sink's failure doesn't drop events for healthy
    // siblings on the same stack.
    const a = std.testing.allocator;
    var hub = sse_mod.Hub.init(a);
    defer hub.deinit();

    const Cap = struct {
        buf: std.ArrayList(u8) = .{},
        a: std.mem.Allocator,
        writes: usize = 0,
        fail_after: ?usize = null,
    };
    const writeFn = struct {
        fn cb(ctx: *anyopaque, line: []const u8) anyerror!void {
            const c: *Cap = @ptrCast(@alignCast(ctx));
            if (c.fail_after) |lim| if (c.writes >= lim) return error.SinkFailure;
            try c.buf.appendSlice(c.a, line);
            c.writes += 1;
        }
    }.cb;

    var good = Cap{ .a = a };
    var bad = Cap{ .a = a, .fail_after = 1 };
    defer good.buf.deinit(a);
    defer bad.buf.deinit(a);

    const sg = try hub.subscribe("demo", .{ .ctx = &good, .write_fn = writeFn });
    _ = try hub.subscribe("demo", .{ .ctx = &bad, .write_fn = writeFn });

    try hub.publish(.{ .stack = "demo", .item = "0001", .kind = .session_started });
    try hub.publish(.{ .stack = "demo", .item = "0001", .kind = .message });
    try hub.publish(.{ .stack = "demo", .item = "0001", .kind = .session_ended });

    // The bad sink got removed after its second publish attempt; the good
    // sink got every event.
    try std.testing.expectEqual(@as(usize, 3), good.writes);
    try std.testing.expectEqual(@as(usize, 1), bad.writes);
    // Hub state: bad sub auto-removed.
    try std.testing.expectEqual(@as(usize, 1), hub.subs.items.len);
    hub.unsubscribe(sg);
}

test "Supervisor.wakeAllWorkers: signal reaches every registered worker" {
    // Audit coverage gap: wakeAllWorkers had no direct test. Build a
    // supervisor with two stacks, call wake, observe each worker ticks
    // once promptly.
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "wake-all");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);
    try seedStack(a, s.abs_path, "alpha", false);
    try seedStack(a, s.abs_path, "beta", false);

    var aw = try audit_mod.Writer.init(a, s.abs_path);
    defer aw.deinit();
    var reg = try stako.stack.StackRegistry.init(a, s.abs_path, &aw, false);
    defer reg.deinit();

    var sup = runtime_mod.Supervisor.init(a, .{
        .notes_root_abs = s.abs_path,
        .stack_registry = &reg,
        .audit_writer = &aw,
        .dispatch = runtime_mod.fakeDispatch(),
    });
    defer sup.deinit();

    const wa = try sup.ensureWorker("alpha");
    const wb = try sup.ensureWorker("beta");
    // Use a long poll interval so we know a tick only happens via wake.
    wa.poll_interval_ns = 60 * std.time.ns_per_s;
    wb.poll_interval_ns = 60 * std.time.ns_per_s;
    try wa.start();
    try wb.start();

    // Both workers ticked once at start (wake_pending=true). After a short
    // delay, seed an item under each stack and call wakeAllWorkers; the
    // workers should pick the items up well before the next poll interval.
    std.Thread.sleep(50 * std.time.ns_per_ms);
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

    sup.wakeAllWorkers();

    // Wait up to 2s for both items to land at `completed` or `running`.
    // /usr/bin/true exits 0 immediately, so the fake-dispatch will reach
    // completed quickly.
    const deadline_ms: i64 = std.time.milliTimestamp() + 2000;
    var both_seen = false;
    while (std.time.milliTimestamp() < deadline_ms) {
        var ok_alpha = false;
        var ok_beta = false;
        const a_meta = try std.fs.path.join(a, &.{ s.abs_path, "stacks/alpha/0001-hi/meta.toml" });
        defer a.free(a_meta);
        const b_meta = try std.fs.path.join(a, &.{ s.abs_path, "stacks/beta/0001-hi/meta.toml" });
        defer a.free(b_meta);
        if (std.fs.cwd().openFile(a_meta, .{})) |fa| {
            defer fa.close();
            const st = try fa.stat();
            const bf = try a.alloc(u8, st.size);
            defer a.free(bf);
            _ = try fa.readAll(bf);
            if (std.mem.indexOf(u8, bf, "status = \"completed\"") != null) ok_alpha = true;
        } else |_| {}
        if (std.fs.cwd().openFile(b_meta, .{})) |fb| {
            defer fb.close();
            const st = try fb.stat();
            const bf = try a.alloc(u8, st.size);
            defer a.free(bf);
            _ = try fb.readAll(bf);
            if (std.mem.indexOf(u8, bf, "status = \"completed\"") != null) ok_beta = true;
        } else |_| {}
        if (ok_alpha and ok_beta) {
            both_seen = true;
            break;
        }
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    try std.testing.expect(both_seen);
}

test "routingPreflight: compact item against a harness that cannot compact blocks with harness_unsupported_capability" {
    // Audit coverage gap: the `harness_unsupported_capability` slug was
    // the only canonical preflight reason without test coverage. The fake
    // adapter explicitly returns false for `.compact` (see fake_adapter
    // `supports`), so a compact item routes to fake and should block.
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "compact-unsup");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);
    try seedStack(a, s.abs_path, "demo", false);

    const body =
        \\id = "0001"
        \\slug = "do-compact"
        \\kind = "compact"
        \\status = "queued"
        \\created_at = 2026-05-10T14:00:00Z
        \\updated_at = 2026-05-10T14:00:00Z
        \\
        \\[target]
        \\provider = "anthropic"
        \\
    ;
    try seedItem(a, s.abs_path, "demo", "0001", "do-compact", body);

    var aw = try audit_mod.Writer.init(a, s.abs_path);
    defer aw.deinit();
    var reg = try stako.stack.StackRegistry.init(a, s.abs_path, &aw, false);
    defer reg.deinit();

    var sup = runtime_mod.Supervisor.init(a, .{
        .notes_root_abs = s.abs_path,
        .stack_registry = &reg,
        .audit_writer = &aw,
        .dispatch = runtime_mod.fakeDispatch(),
    });
    defer sup.deinit();
    try sup.tickStack("demo");
    sup.sm.waitAll();

    const meta_path = try std.fs.path.join(a, &.{ s.abs_path, "stacks/demo/0001-do-compact/meta.toml" });
    defer a.free(meta_path);
    var f = try std.fs.cwd().openFile(meta_path, .{});
    defer f.close();
    const stat = try f.stat();
    const buf = try a.alloc(u8, stat.size);
    defer a.free(buf);
    _ = try f.readAll(buf);
    try std.testing.expect(std.mem.indexOf(u8, buf, "status = \"blocked\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf, "blocked_reason = \"harness_unsupported_capability\"") != null);
}

test "fake adapter: recovers from a malformed line and continues parsing subsequent valid events" {
    // Audit coverage gap: the malformed-JSON test never exercised the
    // mixed "one bad, one good" sequence so a future regression in parser
    // state-keeping would not be caught.
    const a = std.testing.allocator;
    var ad = try fake_adapter.create(a);
    defer ad.deinit(a);

    // First: a malformed line → single .error event.
    {
        const evs = try ad.parseLine(a, "garbage\n");
        defer adapter_mod.freeOwnedSlice(a, evs);
        try std.testing.expectEqual(@as(usize, 1), evs.len);
        try std.testing.expectEqual(events.Kind.@"error", evs[0].ev.kind);
    }
    // Then: a valid session_started recovers normally.
    {
        const evs = try ad.parseLine(a, "{\"kind\":\"session_started\",\"data\":{\"session\":\"sess-x\"}}\n");
        defer adapter_mod.freeOwnedSlice(a, evs);
        try std.testing.expectEqual(@as(usize, 1), evs.len);
        try std.testing.expectEqual(events.Kind.session_started, evs[0].ev.kind);
    }
    // Then: a follow-up message picks up the captured session id.
    {
        const evs = try ad.parseLine(a, "{\"kind\":\"message\",\"data\":{\"text\":\"hi\",\"role\":\"assistant\"}}\n");
        defer adapter_mod.freeOwnedSlice(a, evs);
        try std.testing.expectEqualStrings("sess-x", evs[0].ev.session);
    }
}

test "fake adapter: parseStderrLine attaches captured session id to error event" {
    // Audit important #3: parseStderrLine used to discard the per-session
    // state. After the fix it should carry the captured session id so the
    // adapter contract matches parseLine.
    const a = std.testing.allocator;
    var ad = try fake_adapter.create(a);
    defer ad.deinit(a);

    // Prime the session id via a session_started event.
    {
        const evs = try ad.parseLine(a, "{\"kind\":\"session_started\",\"data\":{\"session\":\"sess-err\"}}\n");
        defer adapter_mod.freeOwnedSlice(a, evs);
    }

    const evs = try ad.parseStderrLine(a, "boom\n");
    defer adapter_mod.freeOwnedSlice(a, evs);
    try std.testing.expectEqual(@as(usize, 1), evs.len);
    try std.testing.expectEqual(events.Kind.@"error", evs[0].ev.kind);
    try std.testing.expectEqualStrings("sess-err", evs[0].ev.session);
}

test "runtime_file: write+read round-trip preserves quote-escaped values" {
    // Audit coverage gap: the parser strips a single enclosing pair of
    // quotes from values. Verify a stored value containing internal
    // characters (a backslash + a quote escape) round-trips correctly.
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = try tmp.dir.realpath(".", &buf);

    // A transcript path with spaces + an internal quote — exercises the
    // writer's escape codepath. Backslashes & quotes both get escaped on
    // write; the reader's "strip one outer pair" semantics still finds
    // the embedded delimiters as literal bytes.
    const weird_path = "/tmp/my dir/has \"quote\".jsonl";
    try runtime_file.write(a, abs, "demo", "0042", .{
        .pid = 99,
        .harness = "fake",
        .started_at = "2026-05-10T14:00:00.000Z",
        .transcript_path = weird_path,
        .session_id = "sess-q",
    });
    var p = (try runtime_file.read(a, abs, "demo", "0042")).?;
    defer p.deinit();
    try std.testing.expectEqualStrings("fake", p.rf.harness);
    try std.testing.expectEqualStrings("sess-q", p.rf.session_id);
    // The reader strips one pair of outer quotes but does not unescape;
    // the writer escapes internal `"` as `\"` and `\\` as `\\\\`. The
    // round-trip value therefore preserves the escape sequence rather
    // than the original raw bytes — pin that contract here so future
    // changes have to update both halves together.
    try std.testing.expect(std.mem.indexOf(u8, p.rf.transcript_path, "/tmp/my dir/has \\\"quote\\\".jsonl") != null);
}

test "[result] block: session_ended payload empty fields still produce a result block with exit_code" {
    // Audit coverage gap: the case where the adapter emits a session_ended
    // with no session_id / session_file / model. The fake adapter's onExit
    // produces `{"exit_code":N,"terminal_status":"completed"}` only — no
    // session_id field. The session manager should still write a
    // [result] block populated from the fallback session id captured at
    // session_started time (or empty if none was seen).
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "result-minimal");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);
    try seedStack(a, s.abs_path, "demo", false);

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
    var reg = try stako.stack.StackRegistry.init(a, s.abs_path, &aw, false);
    defer reg.deinit();

    // Use a fixture whose JSONL is empty (no session_started, no message).
    // We re-use the existing cat_jsonl helper but point it at an empty
    // fixture so the adapter emits no events.
    const empty_path = try std.fs.path.join(a, &.{ s.abs_path, "empty.jsonl" });
    defer a.free(empty_path);
    {
        var ef = try std.fs.cwd().createFile(empty_path, .{ .truncate = true });
        defer ef.close();
    }
    const script = try absFixturePath(a, "harness/cat_jsonl.sh");
    defer a.free(script);
    const cs = CatScript{ .fixture_abs = empty_path, .script_abs = script };
    GLOBAL_CAT_SCRIPT = &cs;
    defer GLOBAL_CAT_SCRIPT = null;

    var sup = runtime_mod.Supervisor.init(a, .{
        .notes_root_abs = s.abs_path,
        .stack_registry = &reg,
        .audit_writer = &aw,
        .dispatch = fakeDispatchCat(),
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
    // The [result] block must still exist with exit_code = 0 (cat of an
    // empty file exits 0) and a harness field, even without session_id.
    try std.testing.expect(std.mem.indexOf(u8, buf, "[result]") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf, "exit_code = 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf, "harness = \"") != null);
}

test "Manager.cancelAndEscalate: SIGTERM-resistant subprocess gets SIGKILLed" {
    // Audit coverage gap: cancel-escalation was only tested up to SIGTERM.
    // Use a script that ignores BOTH SIGINT and SIGTERM to drive the third
    // escalation step.
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "kill-escalate");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);
    try seedStack(a, s.abs_path, "demo", false);

    const body =
        \\id = "0001"
        \\slug = "very-stubborn"
        \\kind = "prompt"
        \\status = "queued"
        \\created_at = 2026-05-10T14:00:00Z
        \\updated_at = 2026-05-10T14:00:00Z
        \\
        \\[target]
        \\match = "any"
        \\
    ;
    try seedItem(a, s.abs_path, "demo", "0001", "very-stubborn", body);

    var aw = try audit_mod.Writer.init(a, s.abs_path);
    defer aw.deinit();
    var reg = try stako.stack.StackRegistry.init(a, s.abs_path, &aw, false);
    defer reg.deinit();

    const script = try absFixturePath(a, "harness/claude_ignores_sigterm.sh");
    defer a.free(script);
    const sc = StubbornScript{ .script_abs = script };
    GLOBAL_STUBBORN = &sc;
    defer GLOBAL_STUBBORN = null;

    var sup = runtime_mod.Supervisor.init(a, .{
        .notes_root_abs = s.abs_path,
        .stack_registry = &reg,
        .audit_writer = &aw,
        .dispatch = fakeDispatchStubborn(),
    });
    defer sup.deinit();
    try sup.tickStack("demo");

    var spins: usize = 0;
    while (sup.sm.findSessionByKey("demo", "0001") == null and spins < 200) : (spins += 1) {
        std.Thread.sleep(5 * std.time.ns_per_ms);
    }
    try std.testing.expect(sup.sm.findSessionByKey("demo", "0001") != null);

    // Tight bounds: 200 ms SIGINT grace, 200 ms SIGTERM grace, then SIGKILL.
    try sup.sm.cancelAndEscalate("demo", "0001", 200, 200);
    sup.sm.waitAll();

    const meta_path = try std.fs.path.join(a, &.{ s.abs_path, "stacks/demo/0001-very-stubborn/meta.toml" });
    defer a.free(meta_path);
    var f = try std.fs.cwd().openFile(meta_path, .{});
    defer f.close();
    const stat = try f.stat();
    const buf = try a.alloc(u8, stat.size);
    defer a.free(buf);
    _ = try f.readAll(buf);
    try std.testing.expect(std.mem.indexOf(u8, buf, "status = \"canceled\"") != null);
}

test "runtime: daemon shutdown mid-session reaps the live subprocess and clears the runtime file" {
    // Audit coverage gap: cancel-escalate exercises in-process cancel, but
    // not the path where the daemon itself is torn down while a session
    // is mid-stream. The expectation is: requestShutdown signals SIGINT,
    // sm.waitAll drains, the item lands at `canceled`, and the runtime
    // file is gone.
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "mid-shutdown");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);
    try seedStack(a, s.abs_path, "demo", false);

    const body =
        \\id = "0001"
        \\slug = "slow"
        \\kind = "prompt"
        \\status = "queued"
        \\created_at = 2026-05-10T14:00:00Z
        \\updated_at = 2026-05-10T14:00:00Z
        \\
        \\[target]
        \\match = "any"
        \\
    ;
    try seedItem(a, s.abs_path, "demo", "0001", "slow", body);

    var aw = try audit_mod.Writer.init(a, s.abs_path);
    defer aw.deinit();
    var reg = try stako.stack.StackRegistry.init(a, s.abs_path, &aw, false);
    defer reg.deinit();

    const script = try absFixturePath(a, "harness/slow_sigint_ok.sh");
    defer a.free(script);
    const sc = StubbornScript{ .script_abs = script };
    GLOBAL_STUBBORN = &sc;
    defer GLOBAL_STUBBORN = null;

    var sup = runtime_mod.Supervisor.init(a, .{
        .notes_root_abs = s.abs_path,
        .stack_registry = &reg,
        .audit_writer = &aw,
        .dispatch = fakeDispatchStubborn(),
    });
    // Do not `defer sup.deinit();` here — we call it explicitly below to
    // observe the mid-session reap. After that the supervisor is gone.
    try sup.tickStack("demo");

    // Wait for the session to register so we know we're mid-stream.
    var spins: usize = 0;
    while (sup.sm.findSessionByKey("demo", "0001") == null and spins < 200) : (spins += 1) {
        std.Thread.sleep(5 * std.time.ns_per_ms);
    }
    try std.testing.expect(sup.sm.findSessionByKey("demo", "0001") != null);

    // Drive daemon-style shutdown: request → wait → deinit. The script
    // honors SIGINT, so requestShutdown is enough to terminate it.
    sup.requestShutdown();
    sup.deinit();

    // Item ends up as `canceled` (the session manager classifies the
    // SIGINT-terminated run as canceled because `outcome.canceled` is set
    // by requestShutdown).
    const meta_path = try std.fs.path.join(a, &.{ s.abs_path, "stacks/demo/0001-slow/meta.toml" });
    defer a.free(meta_path);
    var f = try std.fs.cwd().openFile(meta_path, .{});
    defer f.close();
    const stat = try f.stat();
    const buf = try a.alloc(u8, stat.size);
    defer a.free(buf);
    _ = try f.readAll(buf);
    try std.testing.expect(std.mem.indexOf(u8, buf, "status = \"canceled\"") != null);

    // Runtime file was cleaned up.
    if (try runtime_file.read(a, s.abs_path, "demo", "0001")) |p| {
        var pp = p;
        defer pp.deinit();
        return error.RuntimeFileShouldBeGone;
    }
}

test "Worker: tear-down right after start cleanly joins the worker thread" {
    // Audit coverage gap: no test created a worker, kicked it, then
    // immediately tore down. Verify that even when the worker's first
    // tick is racing with `requestShutdown`, `deinit` returns promptly
    // and no leaks remain.
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "worker-churn");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);
    try seedStack(a, s.abs_path, "demo", false);

    var aw = try audit_mod.Writer.init(a, s.abs_path);
    defer aw.deinit();
    var reg = try stako.stack.StackRegistry.init(a, s.abs_path, &aw, false);
    defer reg.deinit();

    var sup = runtime_mod.Supervisor.init(a, .{
        .notes_root_abs = s.abs_path,
        .stack_registry = &reg,
        .audit_writer = &aw,
        .dispatch = runtime_mod.fakeDispatch(),
    });

    const w = try sup.ensureWorker("demo");
    try w.start();
    // Immediately request shutdown without waiting for the first tick.
    sup.deinit();
    // If we reach here without hanging, the join completed cleanly.
}

// ---------- F1 (follow-up): dispatch denial audit-log shape ----------
//
// The runtime supervisor calls `policy_check_provider` for items routed to
// a known provider. The daemon-installed callback denies via the local
// identity's capability set. Before this follow-up, the only audit signal
// was the transition-to-blocked mutation, which writes `outcome=allowed`
// because the *mutation itself* is allowed — there was no parallel
// `denied` line attributing the dispatch refusal to the policy. These
// tests pin: (a) the parallel `denied` line is now emitted, (b) the
// allowed path is unchanged (no spurious denied lines), and (c) one
// item's denial does not break the supervisor's tick over its siblings.

fn writeIdentityCaps(a: std.mem.Allocator, root: []const u8, caps_toml_array: []const u8) !void {
    const path = try std.fs.path.join(a, &.{ root, ".stako", "config.toml" });
    defer a.free(path);
    const body = try std.fmt.allocPrint(a,
        \\[identity.local]
        \\type = "user"
        \\capabilities = {s}
        \\
    , .{caps_toml_array});
    defer a.free(body);
    var f = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer f.close();
    try f.writeAll(body);
    const local_path = try std.fs.path.join(a, &.{ root, ".stako", "config.local.toml" });
    defer a.free(local_path);
    var lf = try std.fs.cwd().createFile(local_path, .{ .truncate = true });
    defer lf.close();
    try lf.writeAll("# cleared so config.toml is authoritative for the test\n");
}

fn readAuditLogF1(a: std.mem.Allocator, root: []const u8) ![]u8 {
    const path = try std.fs.path.join(a, &.{ root, ".stako", "audit.log" });
    defer a.free(path);
    var f = try std.fs.cwd().openFile(path, .{});
    defer f.close();
    const stat = try f.stat();
    const buf = try a.alloc(u8, stat.size);
    _ = try f.readAll(buf);
    return buf;
}

fn readItemMeta(a: std.mem.Allocator, root: []const u8, stack: []const u8, item_dir: []const u8) ![]u8 {
    const path = try std.fs.path.join(a, &.{ root, "stacks", stack, item_dir, "meta.toml" });
    defer a.free(path);
    var f = try std.fs.cwd().openFile(path, .{});
    defer f.close();
    const stat = try f.stat();
    const buf = try a.alloc(u8, stat.size);
    _ = try f.readAll(buf);
    return buf;
}

fn seedAnthropicItem(a: std.mem.Allocator, root: []const u8, stack: []const u8, id: []const u8, slug: []const u8) !void {
    const body = try std.fmt.allocPrint(a,
        \\id = "{s}"
        \\slug = "{s}"
        \\kind = "prompt"
        \\status = "queued"
        \\created_at = 2026-05-10T14:00:00Z
        \\updated_at = 2026-05-10T14:00:00Z
        \\
        \\[target]
        \\provider = "anthropic"
        \\match = "exact"
        \\
    , .{ id, slug });
    defer a.free(body);
    try seedItem(a, root, stack, id, slug, body);
}

fn seedClaudeAllowedStack(a: std.mem.Allocator, root: []const u8, stack: []const u8) !void {
    const dir = try std.fs.path.join(a, &.{ root, "stacks", stack });
    defer a.free(dir);
    try std.fs.cwd().makePath(dir);
    const cfg_path = try std.fs.path.join(a, &.{ dir, "stack.toml" });
    defer a.free(cfg_path);
    var f = try std.fs.cwd().createFile(cfg_path, .{ .truncate = true });
    defer f.close();
    try f.writeAll(
        \\description = "F1 dispatch-denial stack"
        \\created_at = 2026-05-10T14:00:00Z
        \\paused = false
        \\continuity = "fresh"
        \\max_concurrent_per_stack = 1
        \\allowed_harnesses = ["claude"]
        \\
    );
}

const F1ServeCtx = struct { d: *daemon_mod.Daemon };
fn f1ServeFn(ctx: *F1ServeCtx) void {
    daemon_mod.serveUntilShutdown(ctx.d) catch {};
}

fn waitMetaContains(a: std.mem.Allocator, meta_path: []const u8, needle: []const u8, deadline_ms: i64) !bool {
    while (std.time.milliTimestamp() < deadline_ms) {
        var mf = std.fs.cwd().openFile(meta_path, .{}) catch {
            std.Thread.sleep(20 * std.time.ns_per_ms);
            continue;
        };
        defer mf.close();
        const stat = try mf.stat();
        const buf = try a.alloc(u8, stat.size);
        defer a.free(buf);
        _ = try mf.readAll(buf);
        if (std.mem.indexOf(u8, buf, needle) != null) return true;
        std.Thread.sleep(20 * std.time.ns_per_ms);
    }
    return false;
}

test "F1: dispatch denied by policy emits parallel denied audit line and blocks item" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "f1-denied");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);
    // No provider.* capability → dispatch_harness denied for anthropic.
    try writeIdentityCaps(a, s.abs_path, "[\"stack.*.*\"]");
    try seedClaudeAllowedStack(a, s.abs_path, "demo");
    try seedAnthropicItem(a, s.abs_path, "demo", "0001", "denied-prompt");

    // Use the cat_jsonl dispatch as the factory — the per-harness factory
    // resolves whether or not the item ever dispatches. Denial fires
    // *before* spawn, so the script never runs.
    const fixture = try absFixturePath(a, "harness/claude_hello.jsonl");
    defer a.free(fixture);
    const script = try absFixturePath(a, "harness/cat_jsonl.sh");
    defer a.free(script);
    const cs = CatScript{ .fixture_abs = fixture, .script_abs = script };
    GLOBAL_CAT_SCRIPT = &cs;
    defer GLOBAL_CAT_SCRIPT = null;

    var d = try daemon_mod.start(a, .{
        .notes_root = s.abs_path,
        .port_override = 0,
        .ephemeral = true,
        .enable_git = false,
        .check_repo_conflicts = false,
        .enable_runtime = true,
        .dispatch = fakeDispatchCat(),
    });
    defer d.deinit();
    try d.startWorker();

    var sc = F1ServeCtx{ .d = &d };
    const th = try std.Thread.spawn(.{}, f1ServeFn, .{&sc});
    defer {
        d.requestShutdown();
        th.join();
    }

    const meta_path = try std.fs.path.join(a, &.{ s.abs_path, "stacks/demo/0001-denied-prompt/meta.toml" });
    defer a.free(meta_path);
    const deadline = std.time.milliTimestamp() + 5000;
    try std.testing.expect(try waitMetaContains(a, meta_path, "status = \"blocked\"", deadline));

    const meta = try readItemMeta(a, s.abs_path, "demo", "0001-denied-prompt");
    defer a.free(meta);
    try std.testing.expect(std.mem.indexOf(u8, meta, "blocked_reason = \"capability_denied\"") != null);

    // The parallel `denied` audit line — this is the bug F1 fixes.
    const log = try readAuditLogF1(a, s.abs_path);
    defer a.free(log);
    // One denial line: action=dispatch_harness, outcome=denied,
    // reason=capability_denied, identity=local, target=stack/demo/item/0001.
    try std.testing.expect(std.mem.indexOf(u8, log, "\"action\":\"dispatch_harness\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, log, "\"outcome\":\"denied\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, log, "\"reason\":\"capability_denied\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, log, "\"identity\":\"local\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, log, "\"target\":\"stack/demo/item/0001\"") != null);

    // No spawn happened: no transcript file was written.
    const t_path = try std.fs.path.join(a, &.{ s.abs_path, "stacks/demo/0001-denied-prompt/transcript.ndjson" });
    defer a.free(t_path);
    if (std.fs.cwd().openFile(t_path, .{})) |f| {
        var ff = f;
        defer ff.close();
        const stat = try ff.stat();
        try std.testing.expectEqual(@as(u64, 0), stat.size);
    } else |_| {}
}

test "F1: dispatch allowed leaves audit log free of spurious denied lines" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "f1-allowed");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);
    // Full access — dispatch must succeed.
    try writeIdentityCaps(a, s.abs_path, "[\"*\"]");
    try seedClaudeAllowedStack(a, s.abs_path, "demo");
    try seedAnthropicItem(a, s.abs_path, "demo", "0001", "ok-prompt");

    const fixture = try absFixturePath(a, "harness/claude_hello.jsonl");
    defer a.free(fixture);
    const script = try absFixturePath(a, "harness/cat_jsonl.sh");
    defer a.free(script);
    const cs = CatScript{ .fixture_abs = fixture, .script_abs = script };
    GLOBAL_CAT_SCRIPT = &cs;
    defer GLOBAL_CAT_SCRIPT = null;

    var d = try daemon_mod.start(a, .{
        .notes_root = s.abs_path,
        .port_override = 0,
        .ephemeral = true,
        .enable_git = false,
        .check_repo_conflicts = false,
        .enable_runtime = true,
        .dispatch = fakeDispatchCat(),
    });
    defer d.deinit();
    try d.startWorker();

    var sc = F1ServeCtx{ .d = &d };
    const th = try std.Thread.spawn(.{}, f1ServeFn, .{&sc});
    defer {
        d.requestShutdown();
        th.join();
    }

    const meta_path = try std.fs.path.join(a, &.{ s.abs_path, "stacks/demo/0001-ok-prompt/meta.toml" });
    defer a.free(meta_path);
    const deadline = std.time.milliTimestamp() + 5000;
    try std.testing.expect(try waitMetaContains(a, meta_path, "status = \"completed\"", deadline));

    const log = try readAuditLogF1(a, s.abs_path);
    defer a.free(log);
    // Regression guard: no denied lines in the audit log on the happy path.
    try std.testing.expect(std.mem.indexOf(u8, log, "\"outcome\":\"denied\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, log, "\"reason\":\"capability_denied\"") == null);
}

test "F1: policy denial on one item does not break subsequent ticks for sibling items" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "f1-sibling");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);
    // Identity allows openai but not anthropic — item 0001 (anthropic)
    // will be denied; item 0002 (openai) must still proceed.
    try writeIdentityCaps(a, s.abs_path, "[\"provider.openai\", \"stack.*.*\"]");

    // Stack allows both claude and codex so the harness allowlist gate
    // doesn't pre-empt either item.
    const dir = try std.fs.path.join(a, &.{ s.abs_path, "stacks", "demo" });
    defer a.free(dir);
    try std.fs.cwd().makePath(dir);
    {
        const cfg_path = try std.fs.path.join(a, &.{ dir, "stack.toml" });
        defer a.free(cfg_path);
        var f = try std.fs.cwd().createFile(cfg_path, .{ .truncate = true });
        defer f.close();
        try f.writeAll(
            \\description = "F1 sibling stack"
            \\created_at = 2026-05-10T14:00:00Z
            \\paused = false
            \\continuity = "fresh"
            \\max_concurrent_per_stack = 1
            \\allowed_harnesses = ["claude", "codex"]
            \\
        );
    }
    try seedAnthropicItem(a, s.abs_path, "demo", "0001", "denied");
    // Item 0002 targets openai (→ codex harness, allowed).
    {
        const body =
            \\id = "0002"
            \\slug = "ok"
            \\kind = "prompt"
            \\status = "queued"
            \\created_at = 2026-05-10T14:00:00Z
            \\updated_at = 2026-05-10T14:00:00Z
            \\
            \\[target]
            \\provider = "openai"
            \\match = "exact"
            \\
        ;
        try seedItem(a, s.abs_path, "demo", "0002", "ok", body);
    }

    const fixture = try absFixturePath(a, "harness/claude_hello.jsonl");
    defer a.free(fixture);
    const script = try absFixturePath(a, "harness/cat_jsonl.sh");
    defer a.free(script);
    const cs = CatScript{ .fixture_abs = fixture, .script_abs = script };
    GLOBAL_CAT_SCRIPT = &cs;
    defer GLOBAL_CAT_SCRIPT = null;

    var d = try daemon_mod.start(a, .{
        .notes_root = s.abs_path,
        .port_override = 0,
        .ephemeral = true,
        .enable_git = false,
        .check_repo_conflicts = false,
        .enable_runtime = true,
        .dispatch = fakeDispatchCat(),
    });
    defer d.deinit();
    try d.startWorker();

    var sc = F1ServeCtx{ .d = &d };
    const th = try std.Thread.spawn(.{}, f1ServeFn, .{&sc});
    defer {
        d.requestShutdown();
        th.join();
    }

    // 0001 must reach blocked; 0002 must reach completed. Polling for each
    // independently lets us tolerate any tick ordering.
    const meta1 = try std.fs.path.join(a, &.{ s.abs_path, "stacks/demo/0001-denied/meta.toml" });
    defer a.free(meta1);
    const meta2 = try std.fs.path.join(a, &.{ s.abs_path, "stacks/demo/0002-ok/meta.toml" });
    defer a.free(meta2);
    const deadline = std.time.milliTimestamp() + 8000;
    try std.testing.expect(try waitMetaContains(a, meta1, "status = \"blocked\"", deadline));
    try std.testing.expect(try waitMetaContains(a, meta2, "status = \"completed\"", deadline));
}
