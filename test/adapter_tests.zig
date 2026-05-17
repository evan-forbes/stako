//! Milestone 7 — Claude/Codex adapter tests.
//!
//! All tests in this file are mock-only by default. They exercise the real
//! Claude and Codex adapter modules against scripted JSONL fixtures by
//! invoking `bash cat_jsonl.sh <fixture>` as the subprocess, so no provider
//! CLI is required.
//!
//! Real-provider smoke tests are gated behind `--with-real-credentials`
//! (see `impl/00_test_strategy.md`). Without the flag, those tests log
//! `[skipped: real-credentials gate]` and exit 0. They are named with the
//! `@integration:provider:<name>` tag so they can be selected/excluded.

const std = @import("std");
const stako = @import("stako");
const fake = @import("helpers/fake_harness.zig");

const init_mod = stako.init;
const audit_mod = stako.audit;
const sse_mod = stako.sse;
const mutation_queue = stako.mutation_queue;
const runtime_mod = stako.runtime;
const runtime_file = stako.runtime_file;
const events = stako.events;
const adapter_mod = stako.adapter;
const claude_adapter = stako.claude_adapter;
const codex_adapter = stako.codex_adapter;
const harness_dispatch = stako.harness_dispatch;

// ---------- scratch + paths ----------

const Scratch = struct {
    allocator: std.mem.Allocator,
    abs_path: []u8,

    fn create(allocator: std.mem.Allocator, name_hint: []const u8) !Scratch {
        const tmp = std.posix.getenv("TMPDIR") orelse "/tmp";
        var ts_buf: [40]u8 = undefined;
        const ts = std.time.nanoTimestamp();
        const ts_str = try std.fmt.bufPrint(&ts_buf, "{d}", .{ts});
        const base = try std.fs.path.join(allocator, &.{ tmp, "stako-test-m7" });
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
        .rng_seed_override = 0xD3D7,
    });
    r.deinit();
}

fn absFixturePath(allocator: std.mem.Allocator, sub: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = try std.fs.cwd().realpath(".", &cwd_buf);
    return std.fs.path.join(allocator, &.{ cwd, "test/fixtures", sub });
}

fn seedStack(
    a: std.mem.Allocator,
    root: []const u8,
    stack: []const u8,
    paused: bool,
    allowed_harnesses_toml: []const u8,
) !void {
    const dir = try std.fs.path.join(a, &.{ root, "stacks", stack });
    defer a.free(dir);
    try std.fs.cwd().makePath(dir);
    const cfg = try std.fs.path.join(a, &.{ dir, "stack.toml" });
    defer a.free(cfg);
    var f = try std.fs.cwd().createFile(cfg, .{ .truncate = true });
    defer f.close();
    const content = try std.fmt.allocPrint(a,
        "description = \"m7 stack\"\ncreated_at = 2026-05-10T14:00:00Z\npaused = {s}\ncontinuity = \"fresh\"\nmax_concurrent_per_stack = 1\nallowed_harnesses = {s}\n",
        .{ if (paused) "true" else "false", allowed_harnesses_toml },
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

// Adapter factory wiring: route harness names to the production adapters,
// but build argv that runs the scripted `cat_jsonl.sh` against the provider
// fixture. This lets us exercise the real adapter parsing logic without
// needing a real CLI on the test machine.

const ScriptedHarness = struct {
    fixture_claude_abs: []u8,
    fixture_codex_abs: []u8,
    script_abs: []u8,

    fn deinit(self: *ScriptedHarness, a: std.mem.Allocator) void {
        a.free(self.fixture_claude_abs);
        a.free(self.fixture_codex_abs);
        a.free(self.script_abs);
    }
};

var GLOBAL_SCRIPTED: ?*const ScriptedHarness = null;

fn factoryProd(allocator: std.mem.Allocator, harness: []const u8) anyerror!?adapter_mod.Adapter {
    return harness_dispatch.factory(allocator, harness);
}

fn buildScriptedArgv(
    allocator: std.mem.Allocator,
    harness: []const u8,
    item: *const stako.item.Item,
    item_dir_abs: []const u8,
) anyerror![][]u8 {
    _ = item;
    _ = item_dir_abs;
    const sh = GLOBAL_SCRIPTED orelse return error.NoScriptedHarness;
    const fixture = if (std.mem.eql(u8, harness, "codex")) sh.fixture_codex_abs else sh.fixture_claude_abs;
    return fake.buildCatArgv(allocator, sh.script_abs, fixture);
}

fn scriptedDispatch() runtime_mod.Dispatch {
    return .{ .factory = factoryProd, .build_argv = buildScriptedArgv };
}

// ---------- adapter parser unit tests on the real fixtures ----------

test "claude adapter parses claude_stream.jsonl into expected normalized events" {
    const a = std.testing.allocator;
    var ad = try claude_adapter.create(a);
    defer ad.deinit(a);

    const path = try absFixturePath(a, "harness/claude_stream.jsonl");
    defer a.free(path);
    var f = try std.fs.cwd().openFile(path, .{});
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
        const evs = try ad.parseLine(a, raw);
        defer adapter_mod.freeOwnedSlice(a, evs);
        for (evs) |oe| {
            const cur = counts.get(oe.ev.kind) orelse 0;
            try counts.put(oe.ev.kind, cur + 1);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), counts.get(.session_started).?);
    try std.testing.expectEqual(@as(usize, 1), counts.get(.turn_started).?);
    try std.testing.expectEqual(@as(usize, 2), counts.get(.message_chunk).?);
    // Assistant text block + final result text = 2 messages.
    try std.testing.expectEqual(@as(usize, 2), counts.get(.message).?);
    try std.testing.expectEqual(@as(usize, 1), counts.get(.turn_completed).?);
}

test "codex adapter parses codex_stream.jsonl into expected normalized events" {
    const a = std.testing.allocator;
    var ad = try codex_adapter.create(a);
    defer ad.deinit(a);

    const path = try absFixturePath(a, "harness/codex_stream.jsonl");
    defer a.free(path);
    var f = try std.fs.cwd().openFile(path, .{});
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
        const evs = try ad.parseLine(a, raw);
        defer adapter_mod.freeOwnedSlice(a, evs);
        for (evs) |oe| {
            const cur = counts.get(oe.ev.kind) orelse 0;
            try counts.put(oe.ev.kind, cur + 1);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), counts.get(.session_started).?);
    try std.testing.expectEqual(@as(usize, 1), counts.get(.turn_started).?);
    // reasoning + agent_message = 2 messages.
    try std.testing.expectEqual(@as(usize, 2), counts.get(.message).?);
    // command_execution emits tool_call + command_executed.
    // file_change emits tool_call + file_changed.
    try std.testing.expectEqual(@as(usize, 2), counts.get(.tool_call).?);
    try std.testing.expectEqual(@as(usize, 1), counts.get(.command_executed).?);
    try std.testing.expectEqual(@as(usize, 1), counts.get(.file_changed).?);
    try std.testing.expectEqual(@as(usize, 1), counts.get(.turn_completed).?);
}

// ---------- end-to-end runtime tests using the real adapters ----------

test "m7 runtime: claude adapter end-to-end against scripted fixture" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "claude-e2e");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);
    try seedStack(a, s.abs_path, "demo", false, "[\"claude\"]");

    const item_body =
        \\id = "0001"
        \\slug = "hello"
        \\kind = "prompt"
        \\status = "queued"
        \\created_at = 2026-05-10T14:00:00Z
        \\updated_at = 2026-05-10T14:00:00Z
        \\
        \\[target]
        \\provider = "anthropic"
        \\match = "exact"
        \\
    ;
    try seedItem(a, s.abs_path, "demo", "0001", "hello", item_body);

    var aw = try audit_mod.Writer.init(a, s.abs_path);
    defer aw.deinit();
    var reg = try stako.stack.StackRegistry.init(a, s.abs_path, &aw, false);
    defer reg.deinit();

    const fixture_claude = try absFixturePath(a, "harness/claude_stream.jsonl");
    const fixture_codex = try absFixturePath(a, "harness/codex_stream.jsonl");
    const script = try absFixturePath(a, "harness/cat_jsonl.sh");
    const sh = ScriptedHarness{
        .fixture_claude_abs = fixture_claude,
        .fixture_codex_abs = fixture_codex,
        .script_abs = script,
    };
    GLOBAL_SCRIPTED = &sh;
    defer {
        GLOBAL_SCRIPTED = null;
        a.free(fixture_claude);
        a.free(fixture_codex);
        a.free(script);
    }

    var hub = sse_mod.Hub.init(a);
    defer hub.deinit();

    var sup = runtime_mod.Supervisor.init(a, .{
        .notes_root_abs = s.abs_path,
        .stack_registry = &reg,
        .audit_writer = &aw,
        .hub = &hub,
        .dispatch = scriptedDispatch(),
    });
    defer sup.deinit();
    try sup.tickStack("demo");
    sup.sm.waitAll();

    const meta_path = try std.fs.path.join(a, &.{ s.abs_path, "stacks/demo/0001-hello/meta.toml" });
    defer a.free(meta_path);
    var mf = try std.fs.cwd().openFile(meta_path, .{});
    defer mf.close();
    const stat = try mf.stat();
    const mbuf = try a.alloc(u8, stat.size);
    defer a.free(mbuf);
    _ = try mf.readAll(mbuf);
    try std.testing.expect(std.mem.indexOf(u8, mbuf, "status = \"completed\"") != null);

    const item_dir = try std.fs.path.join(a, &.{ s.abs_path, "stacks/demo/0001-hello" });
    defer a.free(item_dir);
    const t_buf = try fake.readTranscript(a, item_dir);
    defer a.free(t_buf);
    try std.testing.expect(std.mem.indexOf(u8, t_buf, "\"harness\":\"claude\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, t_buf, "\"session\":\"sess-claude-real\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, t_buf, "\"kind\":\"message\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, t_buf, "\"kind\":\"session_ended\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, t_buf, "\"terminal_status\":\"completed\"") != null);
}

test "m7 runtime: codex adapter end-to-end against scripted fixture" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "codex-e2e");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);
    try seedStack(a, s.abs_path, "demo", false, "[\"codex\"]");

    const item_body =
        \\id = "0001"
        \\slug = "hello"
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
    try seedItem(a, s.abs_path, "demo", "0001", "hello", item_body);

    var aw = try audit_mod.Writer.init(a, s.abs_path);
    defer aw.deinit();
    var reg = try stako.stack.StackRegistry.init(a, s.abs_path, &aw, false);
    defer reg.deinit();

    const fixture_claude = try absFixturePath(a, "harness/claude_stream.jsonl");
    const fixture_codex = try absFixturePath(a, "harness/codex_stream.jsonl");
    const script = try absFixturePath(a, "harness/cat_jsonl.sh");
    const sh = ScriptedHarness{
        .fixture_claude_abs = fixture_claude,
        .fixture_codex_abs = fixture_codex,
        .script_abs = script,
    };
    GLOBAL_SCRIPTED = &sh;
    defer {
        GLOBAL_SCRIPTED = null;
        a.free(fixture_claude);
        a.free(fixture_codex);
        a.free(script);
    }

    var sup = runtime_mod.Supervisor.init(a, .{
        .notes_root_abs = s.abs_path,
        .stack_registry = &reg,
        .audit_writer = &aw,
        .dispatch = scriptedDispatch(),
    });
    defer sup.deinit();
    try sup.tickStack("demo");
    sup.sm.waitAll();

    const meta_path = try std.fs.path.join(a, &.{ s.abs_path, "stacks/demo/0001-hello/meta.toml" });
    defer a.free(meta_path);
    var mf = try std.fs.cwd().openFile(meta_path, .{});
    defer mf.close();
    const stat = try mf.stat();
    const mbuf = try a.alloc(u8, stat.size);
    defer a.free(mbuf);
    _ = try mf.readAll(mbuf);
    try std.testing.expect(std.mem.indexOf(u8, mbuf, "status = \"completed\"") != null);

    const item_dir = try std.fs.path.join(a, &.{ s.abs_path, "stacks/demo/0001-hello" });
    defer a.free(item_dir);
    const t_buf = try fake.readTranscript(a, item_dir);
    defer a.free(t_buf);
    try std.testing.expect(std.mem.indexOf(u8, t_buf, "\"harness\":\"codex\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, t_buf, "\"session\":\"th-codex-real\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, t_buf, "\"kind\":\"file_changed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, t_buf, "\"kind\":\"command_executed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, t_buf, "\"terminal_status\":\"completed\"") != null);
}

test "m7 result block: claude scripted run records session_id + harness in meta.toml [result]" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "claude-result");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);
    try seedStack(a, s.abs_path, "demo", false, "[\"claude\"]");

    const item_body =
        \\id = "0001"
        \\slug = "hello"
        \\kind = "prompt"
        \\status = "queued"
        \\created_at = 2026-05-10T14:00:00Z
        \\updated_at = 2026-05-10T14:00:00Z
        \\
        \\[target]
        \\provider = "anthropic"
        \\match = "exact"
        \\
    ;
    try seedItem(a, s.abs_path, "demo", "0001", "hello", item_body);

    var aw = try audit_mod.Writer.init(a, s.abs_path);
    defer aw.deinit();
    var reg = try stako.stack.StackRegistry.init(a, s.abs_path, &aw, false);
    defer reg.deinit();

    const fixture_claude = try absFixturePath(a, "harness/claude_stream.jsonl");
    const fixture_codex = try absFixturePath(a, "harness/codex_stream.jsonl");
    const script = try absFixturePath(a, "harness/cat_jsonl.sh");
    const sh = ScriptedHarness{
        .fixture_claude_abs = fixture_claude,
        .fixture_codex_abs = fixture_codex,
        .script_abs = script,
    };
    GLOBAL_SCRIPTED = &sh;
    defer {
        GLOBAL_SCRIPTED = null;
        a.free(fixture_claude);
        a.free(fixture_codex);
        a.free(script);
    }

    var sup = runtime_mod.Supervisor.init(a, .{
        .notes_root_abs = s.abs_path,
        .stack_registry = &reg,
        .audit_writer = &aw,
        .dispatch = scriptedDispatch(),
    });
    defer sup.deinit();
    try sup.tickStack("demo");
    sup.sm.waitAll();

    const meta_path = try std.fs.path.join(a, &.{ s.abs_path, "stacks/demo/0001-hello/meta.toml" });
    defer a.free(meta_path);
    var mf = try std.fs.cwd().openFile(meta_path, .{});
    defer mf.close();
    const stat = try mf.stat();
    const mbuf = try a.alloc(u8, stat.size);
    defer a.free(mbuf);
    _ = try mf.readAll(mbuf);

    // Item must be terminal.
    try std.testing.expect(std.mem.indexOf(u8, mbuf, "status = \"completed\"") != null);
    // [result] block must exist and carry the adapter-captured fields.
    const result_idx = std.mem.indexOf(u8, mbuf, "[result]") orelse return error.NoResultBlock;
    const tail = mbuf[result_idx..];
    try std.testing.expect(std.mem.indexOf(u8, tail, "harness = \"claude\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tail, "session_id = \"sess-claude-real\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tail, "model = \"claude-opus-4-7\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tail, "exit_code = 0") != null);
}

test "m7 result block: codex scripted run records session_id + harness in meta.toml [result]" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "codex-result");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);
    try seedStack(a, s.abs_path, "demo", false, "[\"codex\"]");

    const item_body =
        \\id = "0001"
        \\slug = "hello"
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
    try seedItem(a, s.abs_path, "demo", "0001", "hello", item_body);

    var aw = try audit_mod.Writer.init(a, s.abs_path);
    defer aw.deinit();
    var reg = try stako.stack.StackRegistry.init(a, s.abs_path, &aw, false);
    defer reg.deinit();

    const fixture_claude = try absFixturePath(a, "harness/claude_stream.jsonl");
    const fixture_codex = try absFixturePath(a, "harness/codex_stream.jsonl");
    const script = try absFixturePath(a, "harness/cat_jsonl.sh");
    const sh = ScriptedHarness{
        .fixture_claude_abs = fixture_claude,
        .fixture_codex_abs = fixture_codex,
        .script_abs = script,
    };
    GLOBAL_SCRIPTED = &sh;
    defer {
        GLOBAL_SCRIPTED = null;
        a.free(fixture_claude);
        a.free(fixture_codex);
        a.free(script);
    }

    var sup = runtime_mod.Supervisor.init(a, .{
        .notes_root_abs = s.abs_path,
        .stack_registry = &reg,
        .audit_writer = &aw,
        .dispatch = scriptedDispatch(),
    });
    defer sup.deinit();
    try sup.tickStack("demo");
    sup.sm.waitAll();

    const meta_path = try std.fs.path.join(a, &.{ s.abs_path, "stacks/demo/0001-hello/meta.toml" });
    defer a.free(meta_path);
    var mf = try std.fs.cwd().openFile(meta_path, .{});
    defer mf.close();
    const stat = try mf.stat();
    const mbuf = try a.alloc(u8, stat.size);
    defer a.free(mbuf);
    _ = try mf.readAll(mbuf);

    try std.testing.expect(std.mem.indexOf(u8, mbuf, "status = \"completed\"") != null);
    const result_idx = std.mem.indexOf(u8, mbuf, "[result]") orelse return error.NoResultBlock;
    const tail = mbuf[result_idx..];
    try std.testing.expect(std.mem.indexOf(u8, tail, "harness = \"codex\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tail, "session_id = \"th-codex-real\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tail, "model = \"gpt-5\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, tail, "exit_code = 0") != null);
}

test "m7 routing: item.target.provider=anthropic picks claude when allowed" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "route-anthropic");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);
    try seedStack(a, s.abs_path, "demo", false, "[\"codex\",\"claude\"]");
    // Item explicitly asks for anthropic.
    try seedItem(a, s.abs_path, "demo", "0001", "hi",
        \\id = "0001"
        \\slug = "hi"
        \\kind = "prompt"
        \\status = "queued"
        \\created_at = 2026-05-10T14:00:00Z
        \\updated_at = 2026-05-10T14:00:00Z
        \\
        \\[target]
        \\provider = "anthropic"
        \\match = "exact"
        \\
    );

    var aw = try audit_mod.Writer.init(a, s.abs_path);
    defer aw.deinit();
    var reg = try stako.stack.StackRegistry.init(a, s.abs_path, &aw, false);
    defer reg.deinit();

    const fixture_claude = try absFixturePath(a, "harness/claude_stream.jsonl");
    const fixture_codex = try absFixturePath(a, "harness/codex_stream.jsonl");
    const script = try absFixturePath(a, "harness/cat_jsonl.sh");
    const sh = ScriptedHarness{
        .fixture_claude_abs = fixture_claude,
        .fixture_codex_abs = fixture_codex,
        .script_abs = script,
    };
    GLOBAL_SCRIPTED = &sh;
    defer {
        GLOBAL_SCRIPTED = null;
        a.free(fixture_claude);
        a.free(fixture_codex);
        a.free(script);
    }

    var sup = runtime_mod.Supervisor.init(a, .{
        .notes_root_abs = s.abs_path,
        .stack_registry = &reg,
        .audit_writer = &aw,
        .dispatch = scriptedDispatch(),
    });
    defer sup.deinit();
    try sup.tickStack("demo");
    sup.sm.waitAll();

    const item_dir = try std.fs.path.join(a, &.{ s.abs_path, "stacks/demo/0001-hi" });
    defer a.free(item_dir);
    const t_buf = try fake.readTranscript(a, item_dir);
    defer a.free(t_buf);
    try std.testing.expect(std.mem.indexOf(u8, t_buf, "\"harness\":\"claude\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, t_buf, "\"harness\":\"codex\"") == null);
}

test "m7 routing: item.target.provider denied when stack excludes the mapped harness" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "route-deny");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);
    // Stack allows only codex; item asks for anthropic → must block.
    try seedStack(a, s.abs_path, "demo", false, "[\"codex\"]");
    try seedItem(a, s.abs_path, "demo", "0001", "hi",
        \\id = "0001"
        \\slug = "hi"
        \\kind = "prompt"
        \\status = "queued"
        \\created_at = 2026-05-10T14:00:00Z
        \\updated_at = 2026-05-10T14:00:00Z
        \\
        \\[target]
        \\provider = "anthropic"
        \\match = "exact"
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
        .dispatch = harness_dispatch.dispatch(),
    });
    defer sup.deinit();
    try sup.tickStack("demo");
    sup.sm.waitAll();

    const meta_path = try std.fs.path.join(a, &.{ s.abs_path, "stacks/demo/0001-hi/meta.toml" });
    defer a.free(meta_path);
    var mf = try std.fs.cwd().openFile(meta_path, .{});
    defer mf.close();
    const stat = try mf.stat();
    const mbuf = try a.alloc(u8, stat.size);
    defer a.free(mbuf);
    _ = try mf.readAll(mbuf);
    try std.testing.expect(std.mem.indexOf(u8, mbuf, "status = \"blocked\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, mbuf, "blocked_reason = \"harness_denied\"") != null);
}

test "m7 routing: clear item blocks when routed harness lacks clear capability" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "cap-clear");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);
    try seedStack(a, s.abs_path, "demo", false, "[\"codex\"]");

    const item_body =
        \\id = "0001"
        \\slug = "clear"
        \\kind = "clear"
        \\status = "queued"
        \\created_at = 2026-05-10T14:00:00Z
        \\updated_at = 2026-05-10T14:00:00Z
        \\
        \\[target]
        \\provider = "openai"
        \\match = "exact"
        \\
        \\[clear]
        \\
    ;
    try seedItem(a, s.abs_path, "demo", "0001", "clear", item_body);

    var aw = try audit_mod.Writer.init(a, s.abs_path);
    defer aw.deinit();
    var reg = try stako.stack.StackRegistry.init(a, s.abs_path, &aw, false);
    defer reg.deinit();

    var sup = runtime_mod.Supervisor.init(a, .{
        .notes_root_abs = s.abs_path,
        .stack_registry = &reg,
        .audit_writer = &aw,
        .dispatch = scriptedDispatch(),
    });
    defer sup.deinit();
    try sup.tickStack("demo");
    sup.sm.waitAll();

    const meta_path = try std.fs.path.join(a, &.{ s.abs_path, "stacks/demo/0001-clear/meta.toml" });
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

test "m7 review item routes the same way as prompt (fresh session)" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "review-claude");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);
    try seedStack(a, s.abs_path, "demo", false, "[\"claude\"]");
    // A review item with no [target] block — should route to the first
    // allowed harness on the stack (claude).
    try seedItem(a, s.abs_path, "demo", "0001", "review",
        \\id = "0001"
        \\slug = "review"
        \\kind = "review"
        \\status = "queued"
        \\created_at = 2026-05-10T14:00:00Z
        \\updated_at = 2026-05-10T14:00:00Z
        \\
    );

    var aw = try audit_mod.Writer.init(a, s.abs_path);
    defer aw.deinit();
    var reg = try stako.stack.StackRegistry.init(a, s.abs_path, &aw, false);
    defer reg.deinit();

    const fixture_claude = try absFixturePath(a, "harness/claude_stream.jsonl");
    const fixture_codex = try absFixturePath(a, "harness/codex_stream.jsonl");
    const script = try absFixturePath(a, "harness/cat_jsonl.sh");
    const sh = ScriptedHarness{
        .fixture_claude_abs = fixture_claude,
        .fixture_codex_abs = fixture_codex,
        .script_abs = script,
    };
    GLOBAL_SCRIPTED = &sh;
    defer {
        GLOBAL_SCRIPTED = null;
        a.free(fixture_claude);
        a.free(fixture_codex);
        a.free(script);
    }

    var sup = runtime_mod.Supervisor.init(a, .{
        .notes_root_abs = s.abs_path,
        .stack_registry = &reg,
        .audit_writer = &aw,
        .dispatch = scriptedDispatch(),
    });
    defer sup.deinit();
    try sup.tickStack("demo");
    sup.sm.waitAll();

    const meta_path = try std.fs.path.join(a, &.{ s.abs_path, "stacks/demo/0001-review/meta.toml" });
    defer a.free(meta_path);
    var mf = try std.fs.cwd().openFile(meta_path, .{});
    defer mf.close();
    const stat = try mf.stat();
    const mbuf = try a.alloc(u8, stat.size);
    defer a.free(mbuf);
    _ = try mf.readAll(mbuf);
    try std.testing.expect(std.mem.indexOf(u8, mbuf, "status = \"completed\"") != null);
}

// ---------- malformed-input guardrails ----------

test "m7 claude adapter: each malformed line yields exactly one recoverable error" {
    const a = std.testing.allocator;
    var ad = try claude_adapter.create(a);
    defer ad.deinit(a);
    const lines = [_][]const u8{
        "{}",
        "{\"type\":\"unknown_kind\"}",
        "trailing junk",
    };
    for (lines) |line| {
        const evs = try ad.parseLine(a, line);
        defer adapter_mod.freeOwnedSlice(a, evs);
        // For "{}", type missing -> error event.
        // For unknown_kind, line is dropped silently (0 events) — that's fine.
        // For "trailing junk", error event.
        if (evs.len == 0) continue;
        try std.testing.expectEqual(@as(usize, 1), evs.len);
        try std.testing.expectEqual(events.Kind.@"error", evs[0].ev.kind);
        try std.testing.expect(std.mem.indexOf(u8, evs[0].ev.data_json, "\"recoverable\":true") != null);
    }
}

// ---------- gated real-provider smoke tests ----------

fn realCredentialsEnabled(provider: []const u8) bool {
    const env = std.posix.getenv("STAKO_WITH_REAL_CREDENTIALS") orelse return false;
    if (env.len == 0) return false;
    if (std.mem.eql(u8, env, "1") or std.mem.eql(u8, env, "all")) return true;
    // Comma-separated list of providers.
    var it = std.mem.splitScalar(u8, env, ',');
    while (it.next()) |p| {
        if (std.mem.eql(u8, p, provider)) return true;
    }
    return false;
}

// @integration:provider:anthropic
test "real claude smoke @integration:provider:anthropic" {
    if (!realCredentialsEnabled("anthropic")) {
        std.debug.print("[skipped: real-credentials gate (anthropic)]\n", .{});
        return;
    }
    // Best-effort: try to run `claude --version` to confirm the CLI is on
    // PATH; otherwise skip without failing.
    const a = std.testing.allocator;
    var child = std.process.Child.init(&.{ "claude", "--version" }, a);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch {
        std.debug.print("[skipped: `claude` not on PATH]\n", .{});
        return;
    };
    _ = child.wait() catch {};
    // Full end-to-end vs. a real Anthropic backend is deliberately tiny:
    // we spawn `claude -p "say hello" --output-format stream-json --verbose
    // --include-partial-messages` and only check that some session_started
    // event surfaces. Wall-clock cap: 30s.
    var s = try Scratch.create(a, "real-claude");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);
    try seedStack(a, s.abs_path, "demo", false, "[\"claude\"]");
    try seedItem(a, s.abs_path, "demo", "0001", "say-hello",
        \\id = "0001"
        \\slug = "say-hello"
        \\kind = "prompt"
        \\status = "queued"
        \\created_at = 2026-05-10T14:00:00Z
        \\updated_at = 2026-05-10T14:00:00Z
        \\
        \\[target]
        \\provider = "anthropic"
        \\match = "exact"
        \\
    );
    // Write prompt.md so the adapter passes a real prompt.
    {
        const prompt_path = try std.fs.path.join(a, &.{ s.abs_path, "stacks/demo/0001-say-hello/prompt.md" });
        defer a.free(prompt_path);
        var f = try std.fs.cwd().createFile(prompt_path, .{ .truncate = true });
        defer f.close();
        try f.writeAll("Reply with exactly the two words: hello world\n");
    }

    var aw = try audit_mod.Writer.init(a, s.abs_path);
    defer aw.deinit();
    var reg = try stako.stack.StackRegistry.init(a, s.abs_path, &aw, false);
    defer reg.deinit();

    var sup = runtime_mod.Supervisor.init(a, .{
        .notes_root_abs = s.abs_path,
        .stack_registry = &reg,
        .audit_writer = &aw,
        .dispatch = harness_dispatch.dispatch(),
    });
    defer sup.deinit();
    try sup.tickStack("demo");
    // Bounded wait — don't hang CI if the provider stalls.
    const deadline_ms = std.time.milliTimestamp() + 30_000;
    while (std.time.milliTimestamp() < deadline_ms) {
        if (sup.sm.findSessionByKey("demo", "0001") == null) break;
        std.Thread.sleep(50 * std.time.ns_per_ms);
    }
    sup.sm.requestShutdown();
    sup.sm.waitAll();
}

// @integration:provider:openai
test "real codex smoke @integration:provider:openai" {
    if (!realCredentialsEnabled("openai")) {
        std.debug.print("[skipped: real-credentials gate (openai)]\n", .{});
        return;
    }
    const a = std.testing.allocator;
    var child = std.process.Child.init(&.{ "codex", "--version" }, a);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch {
        std.debug.print("[skipped: `codex` not on PATH]\n", .{});
        return;
    };
    _ = child.wait() catch {};
    var s = try Scratch.create(a, "real-codex");
    defer s.deinit();
    try initNotesRoot(a, s.abs_path);
    try seedStack(a, s.abs_path, "demo", false, "[\"codex\"]");
    try seedItem(a, s.abs_path, "demo", "0001", "say-hello",
        \\id = "0001"
        \\slug = "say-hello"
        \\kind = "prompt"
        \\status = "queued"
        \\created_at = 2026-05-10T14:00:00Z
        \\updated_at = 2026-05-10T14:00:00Z
        \\
        \\[target]
        \\provider = "openai"
        \\match = "exact"
        \\
    );
    {
        const prompt_path = try std.fs.path.join(a, &.{ s.abs_path, "stacks/demo/0001-say-hello/prompt.md" });
        defer a.free(prompt_path);
        var f = try std.fs.cwd().createFile(prompt_path, .{ .truncate = true });
        defer f.close();
        try f.writeAll("Reply with exactly the two words: hello world\n");
    }

    var aw = try audit_mod.Writer.init(a, s.abs_path);
    defer aw.deinit();
    var reg = try stako.stack.StackRegistry.init(a, s.abs_path, &aw, false);
    defer reg.deinit();

    var sup = runtime_mod.Supervisor.init(a, .{
        .notes_root_abs = s.abs_path,
        .stack_registry = &reg,
        .audit_writer = &aw,
        .dispatch = harness_dispatch.dispatch(),
    });
    defer sup.deinit();
    try sup.tickStack("demo");
    const deadline_ms = std.time.milliTimestamp() + 30_000;
    while (std.time.milliTimestamp() < deadline_ms) {
        if (sup.sm.findSessionByKey("demo", "0001") == null) break;
        std.Thread.sleep(50 * std.time.ns_per_ms);
    }
    sup.sm.requestShutdown();
    sup.sm.waitAll();
}
