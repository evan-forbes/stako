const std = @import("std");
const runtime = @import("runtime.zig");
const scheduler = @import("scheduler.zig");
const plan = @import("plan.zig");
const status = @import("status.zig");

pub const Error = error{
    SessionConflict,
    MissingSession,
    MissingThreadPane,
    SpawnFailed,
    CommandFailed,
    Timeout,
    OutOfMemory,
} || runtime.Error || std.Thread.SpawnError;

pub const Pane = struct {
    tab_id: []const u8,
    pane_id: []const u8,
};

pub const SleepFn = *const fn () void;

pub fn listSessionsArgv() [4][]const u8 {
    return .{ "zellij", "list-sessions", "--short", "--no-formatting" };
}

pub fn createSessionArgv(name: []const u8) [4][]const u8 {
    return .{ "zellij", "attach", "--create-background", name };
}

pub fn newTabArgvAlloc(
    allocator: std.mem.Allocator,
    session: []const u8,
    thread: []const u8,
    command: []const u8,
    cwd: []const u8,
) error{OutOfMemory}![]const []const u8 {
    // Caller owns the returned slice; element strings are borrowed from the arguments.
    var argv: std.ArrayList([]const u8) = .empty;
    errdefer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{ "zellij", "--session", session, "action", "new-tab", "--name", thread });
    if (cwd.len != 0) try argv.appendSlice(allocator, &.{ "--cwd", cwd });
    try argv.appendSlice(allocator, &.{ "--", command });
    return argv.toOwnedSlice(allocator);
}

pub fn listPanesArgv(session: []const u8) [7][]const u8 {
    return .{ "zellij", "--session", session, "action", "list-panes", "--json", "--tab" };
}

pub fn dumpPaneArgv(session: []const u8, pane_id: []const u8) [8][]const u8 {
    return .{ "zellij", "--session", session, "action", "dump-screen", "--full", "--pane-id", pane_id };
}

pub fn pasteArgv(session: []const u8, pane_id: []const u8, text: []const u8) [8][]const u8 {
    return .{ "zellij", "--session", session, "action", "paste", "--pane-id", pane_id, text };
}

pub fn enterArgv(session: []const u8, pane_id: []const u8) [8][]const u8 {
    return .{ "zellij", "--session", session, "action", "send-keys", "--pane-id", pane_id, "Enter" };
}

/// Drives a stack to idle over the `plan.toml` model: it owns the per-thread
/// pane bindings for the life of the run, delivers ready nodes, and records the
/// lifecycle in `events.jsonl`. Status is never written — it is computed from
/// markers and the event log — so this only appends `delivered`/`completed`/
/// `failed` events and writes the run artifacts.
pub fn PlanRuntime(comptime Adapter: type) type {
    return struct {
        gpa: std.mem.Allocator,
        adapter: *Adapter,
        /// thread name -> pane id, both owned.
        panes: std.StringHashMapUnmanaged([]const u8) = .empty,
        /// nodes delivered this run and awaiting a terminal marker; keys owned.
        pending: std.StringHashMapUnmanaged(void) = .empty,

        const Self = @This();

        pub fn deinit(self: *Self) void {
            var pit = self.panes.iterator();
            while (pit.next()) |e| {
                self.gpa.free(e.key_ptr.*);
                self.gpa.free(e.value_ptr.*);
            }
            self.panes.deinit(self.gpa);
            var dit = self.pending.keyIterator();
            while (dit.next()) |k| self.gpa.free(k.*);
            self.pending.deinit(self.gpa);
        }

        pub fn startStack(self: *Self, stack: *runtime.Stack) Error!void {
            const exists = try self.adapter.sessionExists(stack.name);
            if (exists and !stack.hasOwnershipMarker()) return error.SessionConflict;
            if (!exists) try self.adapter.createSession(stack.name);
            for (stack.plan.threads) |thread| {
                if (self.panes.contains(thread.name)) continue;
                const pane = try self.adapter.ensureThreadTab(stack.name, thread.name, thread.command, stack.agentCwd());
                self.gpa.free(pane.tab_id);
                errdefer self.gpa.free(pane.pane_id);
                const key = try self.gpa.dupe(u8, thread.name);
                errdefer self.gpa.free(key);
                try self.panes.put(self.gpa, key, pane.pane_id);
            }
        }

        pub fn deliver(self: *Self, stack: *runtime.Stack, node: *const plan.Node) Error!void {
            const pane = self.panes.get(node.thread) orelse return error.MissingThreadPane;
            const rendered = try stack.renderNodeAlloc(self.gpa, node);
            defer self.gpa.free(rendered);
            try stack.writeRendered(node.name, rendered);
            if (node.action != .none) {
                try self.adapter.paste(stack.name, pane, node.action.command());
                try self.adapter.enter(stack.name, pane);
            }
            try self.adapter.paste(stack.name, pane, rendered);
            try self.adapter.enter(stack.name, pane);
            try self.logDelivered(stack, node);
            try self.trackPending(node.name);
        }

        pub fn runUntilIdle(self: *Self, stack: *runtime.Stack, sleep: SleepFn) Error!void {
            try self.startStack(stack);
            try stack.appendEvent(.{ .event = .runner_started });
            try self.seedPending(stack);
            while (true) {
                const running_left = try self.pollPending(stack);

                const statuses = try stack.statusesAlloc(self.gpa);
                defer self.gpa.free(statuses);
                const deliverable = try scheduler.deliverableAlloc(self.gpa, &stack.plan, statuses);
                defer self.gpa.free(deliverable);
                for (deliverable) |idx| {
                    self.deliver(stack, &stack.plan.nodes[idx]) catch |e| switch (e) {
                        error.MissingThreadPane, error.CommandFailed, error.SpawnFailed => {
                            try self.failNode(stack, stack.plan.nodes[idx].name, deliverFailureReason(e));
                            continue;
                        },
                        else => return e,
                    };
                }
                if (running_left == 0 and deliverable.len == 0) {
                    try stack.appendEvent(.{ .event = .runner_stopped });
                    return;
                }
                sleep();
            }
        }

        /// Poll each pending node: a `done` marker closes it (completed when a
        /// result exists, failed otherwise); otherwise dump its pane for debug
        /// output. Returns how many are still running.
        fn pollPending(self: *Self, stack: *runtime.Stack) Error!usize {
            var keys: std.ArrayList([]const u8) = .empty;
            defer keys.deinit(self.gpa);
            var it = self.pending.keyIterator();
            while (it.next()) |k| try keys.append(self.gpa, k.*);

            var running_left: usize = 0;
            for (keys.items) |node_name| {
                const node = stack.plan.nodeByName(node_name) orelse {
                    self.removePending(node_name);
                    continue;
                };
                if (stack.completionExists(node_name)) {
                    try self.logTerminal(stack, node_name);
                    self.removePending(node_name);
                    continue;
                }
                const pane = self.panes.get(node.thread) orelse {
                    try self.failNode(stack, node_name, "missing_thread_pane");
                    self.removePending(node_name);
                    continue;
                };
                const dump = self.adapter.dumpPane(stack.name, pane) catch {
                    try self.failNode(stack, node_name, "zellij_dump_failed");
                    self.removePending(node_name);
                    continue;
                };
                defer self.gpa.free(dump);
                try stack.storeOutput(node_name, dump);
                running_left += 1;
            }
            return running_left;
        }

        fn seedPending(self: *Self, stack: *runtime.Stack) Error!void {
            const statuses = try stack.statusesAlloc(self.gpa);
            defer self.gpa.free(statuses);
            for (stack.plan.nodes, 0..) |node, i| {
                if (statuses[i] == .running) try self.trackPending(node.name);
            }
        }

        fn logDelivered(self: *Self, stack: *runtime.Stack, node: *const plan.Node) Error!void {
            const rendered_rel = try std.fmt.allocPrint(self.gpa, "runs/{s}/rendered.md", .{node.name});
            defer self.gpa.free(rendered_rel);
            var inputs: std.ArrayList([]const u8) = .empty;
            defer {
                for (inputs.items) |s| self.gpa.free(s);
                inputs.deinit(self.gpa);
            }
            for (node.blocked_by) |b| {
                try inputs.append(self.gpa, try std.fmt.allocPrint(self.gpa, "runs/{s}/result.md", .{b}));
            }
            try stack.appendEvent(.{
                .event = .delivered,
                .node = node.name,
                .thread = node.thread,
                .action = if (node.action == .none) "" else @tagName(node.action),
                .rendered = rendered_rel,
                .inputs = inputs.items,
            });
        }

        fn logTerminal(self: *Self, stack: *runtime.Stack, node_name: []const u8) Error!void {
            if (stack.resultExists(node_name)) {
                const result_rel = try std.fmt.allocPrint(self.gpa, "runs/{s}/result.md", .{node_name});
                defer self.gpa.free(result_rel);
                try stack.appendEvent(.{ .event = .completed, .node = node_name, .result = result_rel });
            } else {
                try self.failNode(stack, node_name, "missing_result_file");
            }
        }

        fn failNode(self: *Self, stack: *runtime.Stack, node_name: []const u8, reason: []const u8) Error!void {
            _ = self;
            try stack.appendEvent(.{ .event = .failed, .node = node_name, .reason = reason });
        }

        fn trackPending(self: *Self, node_name: []const u8) Error!void {
            if (self.pending.contains(node_name)) return;
            const key = try self.gpa.dupe(u8, node_name);
            errdefer self.gpa.free(key);
            try self.pending.put(self.gpa, key, {});
        }

        fn removePending(self: *Self, node_name: []const u8) void {
            if (self.pending.fetchRemove(node_name)) |kv| self.gpa.free(kv.key);
        }
    };
}

pub const CommandAdapter = struct {
    allocator: std.mem.Allocator,

    pub fn sessionExists(self: *CommandAdapter, name: []const u8) Error!bool {
        const argv = listSessionsArgv();
        const out = try self.run(&argv);
        defer self.allocator.free(out);
        var lines = std.mem.tokenizeScalar(u8, out, '\n');
        while (lines.next()) |line| {
            if (std.mem.eql(u8, std.mem.trim(u8, line, " \t\r\n"), name)) return true;
        }
        return false;
    }

    pub fn createSession(self: *CommandAdapter, name: []const u8) Error!void {
        const argv = createSessionArgv(name);
        const out = try self.run(&argv);
        self.allocator.free(out);
    }

    pub fn ensureThreadTab(self: *CommandAdapter, session: []const u8, thread: []const u8, command: []const u8, cwd: []const u8) Error!Pane {
        const tab_argv = try newTabArgvAlloc(self.allocator, session, thread, command, cwd);
        defer self.allocator.free(tab_argv);
        const tab_out = try self.run(tab_argv);
        defer self.allocator.free(tab_out);
        const tab_id = std.mem.trim(u8, tab_out, " \t\r\n");
        const panes_argv = listPanesArgv(session);
        const panes_json = try self.run(&panes_argv);
        defer self.allocator.free(panes_json);
        const pane_id = try findPaneForTabAlloc(self.allocator, panes_json, tab_id, thread);
        errdefer self.allocator.free(pane_id);
        return .{
            .tab_id = try self.allocator.dupe(u8, tab_id),
            .pane_id = pane_id,
        };
    }

    pub fn paneExists(self: *CommandAdapter, session: []const u8, pane_id: []const u8) Error!bool {
        const argv = dumpPaneArgv(session, pane_id);
        const out = self.run(&argv) catch return false;
        self.allocator.free(out);
        return true;
    }

    pub fn paste(self: *CommandAdapter, session: []const u8, pane_id: []const u8, text: []const u8) Error!void {
        const argv = pasteArgv(session, pane_id, text);
        const out = try self.run(&argv);
        self.allocator.free(out);
    }

    pub fn enter(self: *CommandAdapter, session: []const u8, pane_id: []const u8) Error!void {
        const argv = enterArgv(session, pane_id);
        const out = try self.run(&argv);
        self.allocator.free(out);
    }

    pub fn dumpPane(self: *CommandAdapter, session: []const u8, pane_id: []const u8) Error![]u8 {
        const argv = dumpPaneArgv(session, pane_id);
        return self.run(&argv);
    }

    fn run(self: *CommandAdapter, argv: []const []const u8) Error![]u8 {
        var child = std.process.Child.init(argv, self.allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        child.spawn() catch |e| switch (e) {
            error.FileNotFound => return error.SpawnFailed,
            else => return error.CommandFailed,
        };
        var stdout: std.ArrayList(u8) = .empty;
        errdefer stdout.deinit(self.allocator);
        var stderr: std.ArrayList(u8) = .empty;
        defer stderr.deinit(self.allocator);
        child.collectOutput(self.allocator, &stdout, &stderr, 8 * 1024 * 1024) catch return error.CommandFailed;
        const term = child.wait() catch return error.CommandFailed;
        const code: u8 = switch (term) {
            .Exited => |c| c,
            else => 1,
        };
        if (code != 0) return error.CommandFailed;
        return stdout.toOwnedSlice(self.allocator);
    }
};

fn deliverFailureReason(e: Error) []const u8 {
    return switch (e) {
        error.MissingThreadPane => "missing_thread_pane",
        error.SpawnFailed => "zellij_spawn_failed",
        error.CommandFailed => "zellij_deliver_failed",
        else => unreachable,
    };
}

fn findPaneForTabAlloc(allocator: std.mem.Allocator, src: []const u8, tab_id: []const u8, tab_name: []const u8) ![]u8 {
    // Caller owns returned memory.
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, src, .{}) catch return error.CommandFailed;
    defer parsed.deinit();
    const arr = switch (parsed.value) {
        .array => |a| a,
        else => return error.CommandFailed,
    };
    for (arr.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        if (valueMatches(obj.get("tab_id"), tab_id) or valueMatches(obj.get("tab_name"), tab_name)) {
            if (obj.get("pane_id")) |pane| return valueToStringAlloc(allocator, pane);
            if (obj.get("id")) |pane| return valueToStringAlloc(allocator, pane);
        }
    }
    return error.CommandFailed;
}

fn valueMatches(value: ?std.json.Value, expected: []const u8) bool {
    const v = value orelse return false;
    return switch (v) {
        .string => |s| std.mem.eql(u8, s, expected),
        .integer => |i| blk: {
            const parsed = std.fmt.parseInt(i64, expected, 10) catch break :blk false;
            break :blk parsed == i;
        },
        else => false,
    };
}

fn valueToStringAlloc(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    // Caller owns returned memory.
    return switch (value) {
        .string => |s| allocator.dupe(u8, s),
        .integer => |i| std.fmt.allocPrint(allocator, "{d}", .{i}),
        else => error.CommandFailed,
    };
}

pub const FakeAdapter = struct {
    allocator: std.mem.Allocator,
    session_exists: bool = false,
    created: bool = false,
    panes: std.StringHashMapUnmanaged([]const u8) = .empty,
    launch_log: std.ArrayList([]const u8) = .empty,
    paste_log: std.ArrayList([]const u8) = .empty,
    dump: []const u8 = "",
    missing_pane: []const u8 = "",
    fail_dump_pane: []const u8 = "",
    fail_paste_pane: []const u8 = "",

    pub fn deinit(self: *FakeAdapter) void {
        var it = self.panes.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.panes.deinit(self.allocator);
        for (self.launch_log.items) |p| self.allocator.free(p);
        self.launch_log.deinit(self.allocator);
        for (self.paste_log.items) |p| self.allocator.free(p);
        self.paste_log.deinit(self.allocator);
    }

    pub fn sessionExists(self: *FakeAdapter, name: []const u8) Error!bool {
        _ = name;
        return self.session_exists;
    }

    pub fn createSession(self: *FakeAdapter, name: []const u8) Error!void {
        _ = name;
        self.created = true;
        self.session_exists = true;
    }

    pub fn ensureThreadTab(self: *FakeAdapter, session: []const u8, thread: []const u8, command: []const u8, cwd: []const u8) Error!Pane {
        _ = session;
        try self.launch_log.append(self.allocator, try std.fmt.allocPrint(self.allocator, "{s}:{s}:{s}", .{ thread, command, cwd }));
        const pane_id = try std.fmt.allocPrint(self.allocator, "pane-{s}", .{thread});
        try self.panes.put(self.allocator, try self.allocator.dupe(u8, thread), try self.allocator.dupe(u8, pane_id));
        return .{
            .tab_id = try std.fmt.allocPrint(self.allocator, "tab-{s}", .{thread}),
            .pane_id = pane_id,
        };
    }

    pub fn paneExists(self: *FakeAdapter, session: []const u8, pane_id: []const u8) Error!bool {
        _ = session;
        if (self.missing_pane.len != 0 and std.mem.eql(u8, self.missing_pane, pane_id)) return false;
        var it = self.panes.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.*, pane_id)) return true;
        }
        return false;
    }

    pub fn paste(self: *FakeAdapter, session: []const u8, pane_id: []const u8, text: []const u8) Error!void {
        _ = session;
        if (self.fail_paste_pane.len != 0 and std.mem.eql(u8, self.fail_paste_pane, pane_id)) return error.CommandFailed;
        try self.paste_log.append(self.allocator, try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ pane_id, text }));
    }

    pub fn enter(self: *FakeAdapter, session: []const u8, pane_id: []const u8) Error!void {
        _ = session;
        try self.paste_log.append(self.allocator, try std.fmt.allocPrint(self.allocator, "{s}:ENTER", .{pane_id}));
    }

    pub fn dumpPane(self: *FakeAdapter, session: []const u8, pane_id: []const u8) Error![]u8 {
        _ = session;
        if (self.fail_dump_pane.len != 0 and std.mem.eql(u8, self.fail_dump_pane, pane_id)) return error.CommandFailed;
        return self.allocator.dupe(u8, self.dump);
    }
};

test "zellij action argv targets the stack session" {
    {
        const argv = try newTabArgvAlloc(std.testing.allocator, "demo", "builder", "codex", "");
        defer std.testing.allocator.free(argv);
        try std.testing.expectEqual(@as(usize, 9), argv.len);
        try std.testing.expectEqualStrings("zellij", argv[0]);
        try std.testing.expectEqualStrings("--session", argv[1]);
        try std.testing.expectEqualStrings("demo", argv[2]);
        try std.testing.expectEqualStrings("action", argv[3]);
        try std.testing.expectEqualStrings("new-tab", argv[4]);
        try std.testing.expectEqualStrings("--", argv[7]);
        try std.testing.expectEqualStrings("codex", argv[8]);
    }
    {
        const argv = try newTabArgvAlloc(std.testing.allocator, "demo", "builder", "codex", "/work/repo");
        defer std.testing.allocator.free(argv);
        try std.testing.expectEqual(@as(usize, 11), argv.len);
        try std.testing.expectEqualStrings("--cwd", argv[7]);
        try std.testing.expectEqualStrings("/work/repo", argv[8]);
        try std.testing.expectEqualStrings("--", argv[9]);
        try std.testing.expectEqualStrings("codex", argv[10]);
    }
    {
        const argv = pasteArgv("demo", "12", "hello");
        try std.testing.expectEqualStrings("--session", argv[1]);
        try std.testing.expectEqualStrings("demo", argv[2]);
        try std.testing.expectEqualStrings("paste", argv[4]);
    }
    {
        const argv = dumpPaneArgv("demo", "12");
        try std.testing.expectEqualStrings("--session", argv[1]);
        try std.testing.expectEqualStrings("demo", argv[2]);
        try std.testing.expectEqualStrings("dump-screen", argv[4]);
    }
}

fn noSleep() void {}

// ---------- PlanRuntime tests (plan.toml model) ----------

const chain_plan =
    \\[[thread]]
    \\name = "impl"
    \\command = "codex"
    \\
    \\[[thread]]
    \\name = "reviewer"
    \\command = "claude"
    \\
    \\[[prompt]]
    \\name = "impl-1"
    \\thread = "impl"
    \\action = "new"
    \\body = "Implement the feature."
    \\
    \\[[prompt]]
    \\name = "review-1"
    \\thread = "reviewer"
    \\body = "Review it."
    \\blocked_by = ["impl-1"]
    \\
;

fn planStack(tmp: *std.testing.TmpDir, plan_text: []const u8) !runtime.Stack {
    const a = std.testing.allocator;
    try tmp.dir.makePath("root");
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/root", .{&tmp.sub_path});
    defer a.free(root);
    return runtime.Stack.createFromSource(a, root, "demo", .{ .plan_text = plan_text, .agent_cwd_abs = "/work/repo" });
}

fn statusOf(stack: *const runtime.Stack, statuses: []const status.Status, name: []const u8) status.Status {
    for (stack.plan.nodes, 0..) |n, i| {
        if (std.mem.eql(u8, n.name, name)) return statuses[i];
    }
    unreachable;
}

test "plan startStack launches each thread command in agent cwd" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var stack = try planStack(&tmp, chain_plan);
    defer stack.deinit();

    var adapter = FakeAdapter{ .allocator = a };
    defer adapter.deinit();
    var rt = PlanRuntime(FakeAdapter){ .gpa = a, .adapter = &adapter };
    defer rt.deinit();
    try rt.startStack(&stack);

    try std.testing.expectEqual(@as(usize, 2), adapter.launch_log.items.len);
    try std.testing.expectEqualStrings("impl:codex:/work/repo", adapter.launch_log.items[0]);
    try std.testing.expectEqualStrings("reviewer:claude:/work/repo", adapter.launch_log.items[1]);
}

test "plan runtime delivers ready nodes and advances on completion" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var stack = try planStack(&tmp, chain_plan);
    defer stack.deinit();

    var adapter = FakeAdapter{ .allocator = a };
    defer adapter.deinit();
    var rt = PlanRuntime(FakeAdapter){ .gpa = a, .adapter = &adapter };
    defer rt.deinit();
    try rt.startStack(&stack);

    // impl-1 is ready; review-1 is blocked.
    try rt.deliver(&stack, stack.plan.nodeByName("impl-1").?);
    try std.testing.expect(std.mem.startsWith(u8, adapter.paste_log.items[0], "pane-impl:/new"));
    {
        const statuses = try stack.statusesAlloc(a);
        defer a.free(statuses);
        try std.testing.expectEqual(status.Status.running, statusOf(&stack, statuses, "impl-1"));
        try std.testing.expectEqual(status.Status.queued, statusOf(&stack, statuses, "review-1"));
    }

    // Agent finishes impl-1; poll closes it and review-1 becomes deliverable.
    try stack.storeResult("impl-1", "impl result");
    try stack.storeCompletion("impl-1");
    _ = try rt.pollPending(&stack);
    {
        const statuses = try stack.statusesAlloc(a);
        defer a.free(statuses);
        try std.testing.expectEqual(status.Status.completed, statusOf(&stack, statuses, "impl-1"));
        const deliverable = try scheduler.deliverableAlloc(a, &stack.plan, statuses);
        defer a.free(deliverable);
        try std.testing.expectEqual(@as(usize, 1), deliverable.len);
        try std.testing.expectEqualStrings("review-1", stack.plan.nodes[deliverable[0]].name);
    }

    // review-1 receives impl-1's result path as an input.
    try rt.deliver(&stack, stack.plan.nodeByName("review-1").?);
    const rendered = try stack.readRunFileAlloc(a, "review-1", "rendered.md");
    defer a.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "runs/impl-1/result.md") != null);
}

test "plan runUntilIdle terminates when all work is already complete" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var stack = try planStack(&tmp, chain_plan);
    defer stack.deinit();
    try stack.storeResult("impl-1", "r");
    try stack.storeCompletion("impl-1");
    try stack.storeResult("review-1", "r");
    try stack.storeCompletion("review-1");

    var adapter = FakeAdapter{ .allocator = a };
    defer adapter.deinit();
    var rt = PlanRuntime(FakeAdapter){ .gpa = a, .adapter = &adapter };
    defer rt.deinit();
    try rt.runUntilIdle(&stack, noSleep);

    const statuses = try stack.statusesAlloc(a);
    defer a.free(statuses);
    try std.testing.expectEqual(status.Status.completed, statusOf(&stack, statuses, "impl-1"));
    try std.testing.expectEqual(status.Status.completed, statusOf(&stack, statuses, "review-1"));
}

test "plan delivery failure marks only that node failed" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var stack = try planStack(&tmp, chain_plan);
    defer stack.deinit();

    var adapter = FakeAdapter{ .allocator = a, .fail_paste_pane = "pane-impl" };
    defer adapter.deinit();
    var rt = PlanRuntime(FakeAdapter){ .gpa = a, .adapter = &adapter };
    defer rt.deinit();
    try rt.startStack(&stack);

    rt.deliver(&stack, stack.plan.nodeByName("impl-1").?) catch |e| {
        try rt.failNode(&stack, "impl-1", deliverFailureReason(e));
    };
    const statuses = try stack.statusesAlloc(a);
    defer a.free(statuses);
    try std.testing.expectEqual(status.Status.failed, statusOf(&stack, statuses, "impl-1"));
}

test "plan completion without result fails the node" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var stack = try planStack(&tmp, chain_plan);
    defer stack.deinit();

    var adapter = FakeAdapter{ .allocator = a };
    defer adapter.deinit();
    var rt = PlanRuntime(FakeAdapter){ .gpa = a, .adapter = &adapter };
    defer rt.deinit();
    try rt.startStack(&stack);
    try rt.deliver(&stack, stack.plan.nodeByName("impl-1").?);
    try stack.storeCompletion("impl-1"); // done marker, no result file
    _ = try rt.pollPending(&stack);

    const statuses = try stack.statusesAlloc(a);
    defer a.free(statuses);
    try std.testing.expectEqual(status.Status.failed, statusOf(&stack, statuses, "impl-1"));
}

test "plan running node with a dump failure is marked failed" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var stack = try planStack(&tmp, chain_plan);
    defer stack.deinit();

    var adapter = FakeAdapter{ .allocator = a, .fail_dump_pane = "pane-impl" };
    defer adapter.deinit();
    var rt = PlanRuntime(FakeAdapter){ .gpa = a, .adapter = &adapter };
    defer rt.deinit();
    try rt.startStack(&stack);
    try rt.deliver(&stack, stack.plan.nodeByName("impl-1").?);
    _ = try rt.pollPending(&stack); // no done marker; dump fails -> failed

    const statuses = try stack.statusesAlloc(a);
    defer a.free(statuses);
    try std.testing.expectEqual(status.Status.failed, statusOf(&stack, statuses, "impl-1"));
}

test "rejects an existing unowned zellij session" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var stack = try planStack(&tmp, chain_plan);
    defer stack.deinit();

    // Remove the ownership marker so the existing session is treated as foreign.
    var dir = try std.fs.cwd().openDir(stack.dir_abs, .{});
    defer dir.close();
    try dir.deleteFile("state/zellij-owner");

    var adapter = FakeAdapter{ .allocator = a, .session_exists = true };
    defer adapter.deinit();
    var rt = PlanRuntime(FakeAdapter){ .gpa = a, .adapter = &adapter };
    defer rt.deinit();
    try std.testing.expectError(error.SessionConflict, rt.startStack(&stack));
}
