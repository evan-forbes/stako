const std = @import("std");
const runtime = @import("runtime.zig");
const scheduler = @import("scheduler.zig");
const plan = @import("plan.zig");
const status = @import("status.zig");
const events = @import("events.zig");

const log = std.log.scoped(.zellij);

pub const Error = error{
    SessionConflict,
    MissingSession,
    MissingThreadPane,
    SpawnFailed,
    CommandFailed,
    Timeout,
    RunnerAlreadyRunning,
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

pub fn listPanesArgv(session: []const u8) [8][]const u8 {
    // `--tab` adds tab name/id (used to match a thread's tab); `--state` adds the
    // `exited` flag so tab reuse can skip a tab whose agent has died.
    return .{ "zellij", "--session", session, "action", "list-panes", "--json", "--tab", "--state" };
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

/// How `runUntilIdle` should behave when there is no work to do.
pub const RunOptions = struct {
    sleep: SleepFn,
    /// When true, stay resident on idle (a daemon) instead of returning; the
    /// loop re-reads `plan.toml` each tick so injected work and resets are picked
    /// up without a restart. Stopped by `stako stop` (SIGTERM) or a signal.
    watch: bool = false,
};

/// Drives a stack over the `plan.toml` model. It owns only the per-thread pane
/// bindings; the graph, status, and the set of in-flight nodes are re-derived
/// from disk every tick (`plan.toml` + `runs/` markers + `events.jsonl`), so a
/// live `stako inject`/`reset` takes effect without a restart and a currently
/// running node is polled, never re-delivered. Status is never written — only
/// `delivered`/`completed`/`failed`/`runner_*` events and the run artifacts.
pub fn PlanRuntime(comptime Adapter: type) type {
    return struct {
        gpa: std.mem.Allocator,
        adapter: *Adapter,
        /// thread name -> pane id, both owned. The only state carried between
        /// ticks; everything else is recomputed from disk.
        panes: std.StringHashMapUnmanaged([]const u8) = .empty,
        /// `plan.toml` mtime at the last reload; the per-tick reload is gated on
        /// this so a stable graph is not re-parsed every second.
        plan_mtime: i128 = 0,
        /// Settle delay between paste and Enter (and around the submit retry).
        /// Set from `RunOptions.sleep` during a run; null in direct-`deliver`
        /// tests, where it is a no-op.
        sleep: ?SleepFn = null,

        const Self = @This();

        pub fn deinit(self: *Self) void {
            var pit = self.panes.iterator();
            while (pit.next()) |e| {
                self.gpa.free(e.key_ptr.*);
                self.gpa.free(e.value_ptr.*);
            }
            self.panes.deinit(self.gpa);
        }

        /// Ensure the session exists and is ours, then bind a pane per thread.
        pub fn startStack(self: *Self, stack: *runtime.Stack) Error!void {
            const exists = try self.adapter.sessionExists(stack.name);
            if (exists and !stack.hasOwnershipMarker()) return error.SessionConflict;
            if (!exists) try self.adapter.createSession(stack.name);
            try self.bindThreads(stack);
        }

        /// Bind a pane for every thread not yet bound. The adapter reuses an
        /// existing tab when one is present (idempotent across restarts), so this
        /// is cheap to call each tick and never spawns a duplicate tab set.
        fn bindThreads(self: *Self, stack: *runtime.Stack) Error!void {
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
                self.settle();
                try self.adapter.enter(stack.name, pane);
                self.settle();
            }
            try self.adapter.paste(stack.name, pane, rendered);
            self.settle();
            try self.submitWithRetry(stack.name, pane);
            try self.logDelivered(stack, node);
        }

        /// Send Enter, and if the pane is unchanged afterward, send it once more.
        /// A large paste can land while the agent is busy and swallow the first
        /// Enter, wedging the node as "running" forever; an identical pane before
        /// and after Enter is the tell that it never submitted. Dumps are
        /// best-effort — on a dump failure just send Enter and move on.
        fn submitWithRetry(self: *Self, session: []const u8, pane: []const u8) Error!void {
            const before = self.adapter.dumpPane(session, pane) catch null;
            defer if (before) |b| self.gpa.free(b);
            try self.adapter.enter(session, pane);
            self.settle();
            const after = self.adapter.dumpPane(session, pane) catch null;
            defer if (after) |a| self.gpa.free(a);
            if (before) |b| if (after) |a| {
                if (std.mem.eql(u8, b, a)) try self.adapter.enter(session, pane);
            };
        }

        fn settle(self: *Self) void {
            if (self.sleep) |s| s();
        }

        pub fn runUntilIdle(self: *Self, stack: *runtime.Stack, opts: RunOptions) Error!void {
            try self.guardSingleRunner(stack);
            try self.startStack(stack);
            self.sleep = opts.sleep;
            self.plan_mtime = stack.planMtimeNanos() orelse 0;
            stop_flag.store(false, .seq_cst);
            if (opts.watch) installStopHandler();

            try stack.writeRunnerPid(opts.watch);
            errdefer stack.removeRunnerPid();
            try stack.appendEvent(.{ .event = .runner_started, .pid = std.os.linux.getpid(), .watch = opts.watch });

            while (!stopRequested()) {
                const busy = try self.tick(stack);
                if (busy == 0 and !opts.watch) break;
                opts.sleep();
            }

            try stack.appendEvent(.{ .event = .runner_stopped });
            stack.removeRunnerPid();
        }

        /// One scheduling pass: reload the graph, poll running nodes, reconcile
        /// terminal ones into the log, and deliver whatever is ready. Returns the
        /// count of running + just-delivered nodes, so the caller knows whether
        /// the stack is idle.
        fn tick(self: *Self, stack: *runtime.Stack) Error!usize {
            self.reloadIfChanged(stack);
            try self.bindThreads(stack);

            const statuses = try stack.statusesAlloc(self.gpa);
            defer self.gpa.free(statuses);

            var arena: std.heap.ArenaAllocator = .init(self.gpa);
            defer arena.deinit();
            const event_log = try stack.eventsAlloc(arena.allocator());

            var running_left: usize = 0;
            for (stack.plan.nodes, 0..) |*node, i| switch (statuses[i]) {
                .running => {
                    try self.pollRunning(stack, node);
                    running_left += 1;
                },
                .completed, .blocked, .failed => try self.reconcile(stack, node.name, statuses[i], event_log),
                else => {},
            };

            const deliverable = try scheduler.deliverableAlloc(self.gpa, &stack.plan, statuses);
            defer self.gpa.free(deliverable);
            for (deliverable) |idx| {
                self.deliver(stack, &stack.plan.nodes[idx]) catch |e| switch (e) {
                    error.MissingThreadPane, error.CommandFailed, error.SpawnFailed, error.MissingUse => {
                        const reason = try self.deliverFailureReasonAlloc(e, &stack.plan.nodes[idx]);
                        defer self.gpa.free(reason);
                        try self.failNode(stack, stack.plan.nodes[idx].name, reason);
                        continue;
                    },
                    else => return e,
                };
            }
            return running_left + deliverable.len;
        }

        /// Re-read `plan.toml` when its mtime advanced. A transient parse/validate
        /// error (someone mid-edit) keeps the previous graph for this tick rather
        /// than aborting the runner.
        fn reloadIfChanged(self: *Self, stack: *runtime.Stack) void {
            const m = stack.planMtimeNanos() orelse return;
            if (m == self.plan_mtime) return;
            stack.reloadPlan() catch |e| {
                log.warn("keeping previous graph; plan.toml reload failed: {s}", .{@errorName(e)});
                return;
            };
            self.plan_mtime = m;
        }

        /// Dump a running node's pane for debug output. The dump is never a source
        /// of truth (completion comes from the `done` marker), so a dump failure
        /// is logged and the node stays running rather than being failed.
        fn pollRunning(self: *Self, stack: *runtime.Stack, node: *const plan.Node) Error!void {
            const pane = self.panes.get(node.thread) orelse {
                log.warn("no pane bound for thread {s}; cannot poll {s}", .{ node.thread, node.name });
                return;
            };
            const dump = self.adapter.dumpPane(stack.name, pane) catch {
                log.warn("pane dump failed for running node {s}", .{node.name});
                return;
            };
            defer self.gpa.free(dump);
            try stack.storeOutput(node.name, dump);
        }

        /// Emit the terminal event for a node that markers show as terminal but
        /// whose last logged event is still `delivered` — the normal completion
        /// (one tick after the agent wrote `done`) and the crash-recovery case
        /// (agent finished while the runner was down). Gated on the last logged
        /// event so it fires exactly once and never resurrects a reset node.
        fn reconcile(self: *Self, stack: *runtime.Stack, node_name: []const u8, st: status.Status, event_log: []const events.Event) Error!void {
            const last = lastEventKind(event_log, node_name) orelse return;
            if (last != .delivered) return;
            switch (st) {
                .completed => {
                    const result_rel = try std.fmt.allocPrint(self.gpa, "runs/{s}/result.md", .{node_name});
                    defer self.gpa.free(result_rel);
                    try stack.appendEvent(.{ .event = .completed, .node = node_name, .result = result_rel });
                },
                .blocked => try stack.appendEvent(.{ .event = .blocked, .node = node_name, .reason = "result_blocked" }),
                .failed => try self.failNode(stack, node_name, "missing_result_file"),
                else => {},
            }
        }

        fn guardSingleRunner(self: *Self, stack: *runtime.Stack) Error!void {
            _ = self;
            const info = (try stack.readRunnerPid()) orelse return;
            if (runtime.pidAlive(info.pid) and runtime.pidIsRunnerFor(info.pid, stack.name)) {
                log.err("a runner is already attached to stack {s} (pid {d})", .{ stack.name, info.pid });
                return error.RunnerAlreadyRunning;
            }
            // Stale pid file from a crashed runner: fall through and overwrite it.
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

        fn failNode(self: *Self, stack: *runtime.Stack, node_name: []const u8, reason: []const u8) Error!void {
            _ = self;
            try stack.appendEvent(.{ .event = .failed, .node = node_name, .reason = reason });
        }

        fn deliverFailureReasonAlloc(self: *Self, e: Error, node: *const plan.Node) Error![]u8 {
            // Caller owns returned memory.
            return switch (e) {
                error.MissingUse => std.fmt.allocPrint(self.gpa, "missing_use:{s}", .{node.use_path}),
                error.MissingThreadPane => self.gpa.dupe(u8, "missing_thread_pane"),
                error.SpawnFailed => self.gpa.dupe(u8, "zellij_spawn_failed"),
                error.CommandFailed => self.gpa.dupe(u8, "zellij_deliver_failed"),
                else => unreachable,
            };
        }
    };
}

/// Kind of the last event logged for `node_name`, or null if it has none. Used
/// to decide whether a terminal node still needs a reconciling terminal event.
fn lastEventKind(event_log: []const events.Event, node_name: []const u8) ?events.Kind {
    var last: ?events.Kind = null;
    for (event_log) |ev| {
        if (std.mem.eql(u8, ev.node, node_name)) last = ev.event;
    }
    return last;
}

/// Set by SIGTERM/SIGINT so a `--watch` runner exits its loop cleanly (removing
/// `runner.pid`) instead of being terminated with a stale pid file left behind.
var stop_flag: std.atomic.Value(bool) = .init(false);

pub fn requestStop() void {
    stop_flag.store(true, .seq_cst);
}

fn stopRequested() bool {
    return stop_flag.load(.seq_cst);
}

fn onStopSignal(_: i32) callconv(.c) void {
    stop_flag.store(true, .seq_cst);
}

fn installStopHandler() void {
    var act: std.posix.Sigaction = .{
        .handler = .{ .handler = onStopSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.TERM, &act, null);
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
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
        // Reuse this thread's tab if it already exists and its agent is live, so
        // a restart attaches to the running session instead of spawning a
        // duplicate tab set that no longer matches what the operator sees.
        if (self.findThreadPane(session, thread)) |pane| return pane;

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

    /// Look up an existing live pane for `thread`'s tab, or null if there is none
    /// (or the lookup fails — the caller then creates the tab). The returned
    /// `tab_id` is empty: only the pane id matters for reuse, and the runtime
    /// frees `tab_id` immediately.
    pub fn findThreadPane(self: *CommandAdapter, session: []const u8, thread: []const u8) ?Pane {
        const panes_argv = listPanesArgv(session);
        const panes_json = self.run(&panes_argv) catch return null;
        defer self.allocator.free(panes_json);
        const pane_id = findThreadPaneAlloc(self.allocator, panes_json, thread) catch return null;
        const tab_id = self.allocator.dupe(u8, "") catch {
            self.allocator.free(pane_id);
            return null;
        };
        return .{ .tab_id = tab_id, .pane_id = pane_id };
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
        error.MissingUse => "missing_use",
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

/// Find a live pane for the tab named `thread`, returning its pane id. Skips a
/// pane whose `exited` state is set (its agent has died) so a dead tab is not
/// reused. Caller owns the returned memory; errors when no live match exists.
fn findThreadPaneAlloc(allocator: std.mem.Allocator, src: []const u8, thread: []const u8) ![]u8 {
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
        if (!valueMatches(obj.get("tab_name"), thread)) continue;
        if (valueIsTrue(obj.get("exited"))) continue;
        if (obj.get("pane_id")) |pane| return valueToStringAlloc(allocator, pane);
        if (obj.get("id")) |pane| return valueToStringAlloc(allocator, pane);
    }
    return error.CommandFailed;
}

fn valueIsTrue(value: ?std.json.Value) bool {
    return switch (value orelse return false) {
        .bool => |b| b,
        else => false,
    };
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
    enter_count: usize = 0,
    dump: []const u8 = "",
    /// When set, successive `dumpPane` calls return these in order (clamping to
    /// the last), so a test can simulate a pane that does or doesn't change after
    /// Enter. Falls back to `dump` when empty.
    dumps: []const []const u8 = &.{},
    dump_idx: usize = 0,
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
        self.enter_count += 1;
        try self.paste_log.append(self.allocator, try std.fmt.allocPrint(self.allocator, "{s}:ENTER", .{pane_id}));
    }

    pub fn dumpPane(self: *FakeAdapter, session: []const u8, pane_id: []const u8) Error![]u8 {
        _ = session;
        if (self.fail_dump_pane.len != 0 and std.mem.eql(u8, self.fail_dump_pane, pane_id)) return error.CommandFailed;
        if (self.dumps.len != 0) {
            const i = @min(self.dump_idx, self.dumps.len - 1);
            self.dump_idx += 1;
            return self.allocator.dupe(u8, self.dumps[i]);
        }
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
    {
        // Tab reuse needs tab names and exited state, so list-panes carries both.
        const argv = listPanesArgv("demo");
        try std.testing.expectEqualStrings("list-panes", argv[4]);
        try std.testing.expectEqualStrings("--json", argv[5]);
        try std.testing.expectEqualStrings("--tab", argv[6]);
        try std.testing.expectEqualStrings("--state", argv[7]);
    }
}

test "findThreadPaneAlloc reuses a live tab and skips an exited one" {
    const a = std.testing.allocator;
    const json =
        \\[{"tab_name":"impl","pane_id":7,"exited":false},
        \\ {"tab_name":"reviewer","pane_id":9,"exited":true}]
    ;
    const impl = try findThreadPaneAlloc(a, json, "impl");
    defer a.free(impl);
    try std.testing.expectEqualStrings("7", impl);
    // reviewer's only pane has exited -> no live pane to reuse.
    try std.testing.expectError(error.CommandFailed, findThreadPaneAlloc(a, json, "reviewer"));
    try std.testing.expectError(error.CommandFailed, findThreadPaneAlloc(a, json, "ghost"));
}

fn noSleep() void {}

const run_opts: RunOptions = .{ .sleep = noSleep };

// Drives `--watch` test loops: requests a clean stop after a few idle ticks.
var watch_ticks: usize = 0;
fn stopAfterThreeTicks() void {
    watch_ticks += 1;
    if (watch_ticks >= 3) requestStop();
}

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

fn eventCount(stack: *runtime.Stack, node_name: []const u8, kind: events.Kind) usize {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const log_events = stack.eventsAlloc(arena.allocator()) catch return 0;
    var n: usize = 0;
    for (log_events) |ev| {
        if (ev.event == kind and std.mem.eql(u8, ev.node, node_name)) n += 1;
    }
    return n;
}

fn deliveredCount(stack: *runtime.Stack, node_name: []const u8) usize {
    return eventCount(stack, node_name, .delivered);
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

    // First tick delivers impl-1 (ready); review-1 stays blocked.
    const busy_one = try rt.tick(&stack);
    try std.testing.expectEqual(@as(usize, 1), busy_one);
    try std.testing.expect(std.mem.startsWith(u8, adapter.paste_log.items[0], "pane-impl:/new"));
    {
        const statuses = try stack.statusesAlloc(a);
        defer a.free(statuses);
        try std.testing.expectEqual(status.Status.running, statusOf(&stack, statuses, "impl-1"));
        try std.testing.expectEqual(status.Status.queued, statusOf(&stack, statuses, "review-1"));
    }

    // A second tick must not re-deliver the now-running impl-1.
    _ = try rt.tick(&stack);
    try std.testing.expectEqual(@as(usize, 1), deliveredCount(&stack, "impl-1"));

    // Agent finishes impl-1; the next tick reconciles it and delivers review-1
    // with impl-1's result path as an input.
    try stack.storeResult("impl-1", "impl result");
    try stack.storeCompletion("impl-1");
    _ = try rt.tick(&stack);
    {
        const statuses = try stack.statusesAlloc(a);
        defer a.free(statuses);
        try std.testing.expectEqual(status.Status.completed, statusOf(&stack, statuses, "impl-1"));
        try std.testing.expectEqual(status.Status.running, statusOf(&stack, statuses, "review-1"));
    }
    const rendered = try stack.readRunFileAlloc(a, "review-1", "rendered.md");
    defer a.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "runs/impl-1/result.md") != null);
}

test "a running node is reconciled to completed exactly once" {
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
    try stack.storeResult("impl-1", "r");
    try stack.storeCompletion("impl-1");
    _ = try rt.tick(&stack); // emits the reconciling completed event
    _ = try rt.tick(&stack); // must not emit it again
    try std.testing.expectEqual(@as(usize, 1), eventCount(&stack, "impl-1", .completed));
}

test "runUntilIdle terminates when all work is already complete, and clears the pid" {
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
    try rt.runUntilIdle(&stack, run_opts);

    const statuses = try stack.statusesAlloc(a);
    defer a.free(statuses);
    try std.testing.expectEqual(status.Status.completed, statusOf(&stack, statuses, "impl-1"));
    try std.testing.expectEqual(status.Status.completed, statusOf(&stack, statuses, "review-1"));
    try std.testing.expect((try stack.readRunnerPid()) == null); // removed on clean exit
}

test "watch mode stays resident on idle until stopped" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var stack = try planStack(&tmp, chain_plan);
    defer stack.deinit();
    // Everything already complete: a non-watch run would return immediately.
    try stack.storeResult("impl-1", "r");
    try stack.storeCompletion("impl-1");
    try stack.storeResult("review-1", "r");
    try stack.storeCompletion("review-1");

    var adapter = FakeAdapter{ .allocator = a };
    defer adapter.deinit();
    var rt = PlanRuntime(FakeAdapter){ .gpa = a, .adapter = &adapter };
    defer rt.deinit();
    watch_ticks = 0;
    try rt.runUntilIdle(&stack, .{ .sleep = stopAfterThreeTicks, .watch = true });
    try std.testing.expect(watch_ticks >= 3); // looped instead of exiting on idle
}

test "a stale runner pid does not block a new runner" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var stack = try planStack(&tmp, chain_plan);
    defer stack.deinit();
    try stack.storeResult("impl-1", "r");
    try stack.storeCompletion("impl-1");
    try stack.storeResult("review-1", "r");
    try stack.storeCompletion("review-1");

    // A pid file naming a process that is gone must be treated as stale, not as a
    // live runner, so a fresh `start` proceeds (and overwrites it). We forge one
    // by hand-writing a runner.pid for a dead pid.
    {
        var dir = try std.fs.cwd().openDir(stack.dir_abs, .{});
        defer dir.close();
        try dir.writeFile(.{ .sub_path = "runner.pid", .data = "{\"pid\":1073741824,\"started\":0,\"watch\":false}\n" });
    }
    try std.testing.expect(!runtime.pidAlive(1 << 30));

    var adapter = FakeAdapter{ .allocator = a };
    defer adapter.deinit();
    var rt = PlanRuntime(FakeAdapter){ .gpa = a, .adapter = &adapter };
    defer rt.deinit();
    try rt.runUntilIdle(&stack, run_opts); // must not error with RunnerAlreadyRunning
    try std.testing.expect((try stack.readRunnerPid()) == null);
}

test "delivery resends Enter when the pane did not change" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var stack = try planStack(&tmp, chain_plan);
    defer stack.deinit();

    // before == after across the submit dumps -> the Enter was swallowed.
    const stuck = [_][]const u8{ "prompt box", "prompt box" };
    var adapter = FakeAdapter{ .allocator = a, .dumps = &stuck };
    defer adapter.deinit();
    var rt = PlanRuntime(FakeAdapter){ .gpa = a, .adapter = &adapter };
    defer rt.deinit();
    try rt.startStack(&stack);
    try rt.deliver(&stack, stack.plan.nodeByName("impl-1").?);
    // action Enter + body Enter + one retry Enter = 3.
    try std.testing.expectEqual(@as(usize, 3), adapter.enter_count);
}

test "delivery does not resend Enter when the pane advances" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var stack = try planStack(&tmp, chain_plan);
    defer stack.deinit();

    const advancing = [_][]const u8{ "prompt box", "agent working..." };
    var adapter = FakeAdapter{ .allocator = a, .dumps = &advancing };
    defer adapter.deinit();
    var rt = PlanRuntime(FakeAdapter){ .gpa = a, .adapter = &adapter };
    defer rt.deinit();
    try rt.startStack(&stack);
    try rt.deliver(&stack, stack.plan.nodeByName("impl-1").?);
    try std.testing.expectEqual(@as(usize, 2), adapter.enter_count); // action + body, no retry
}

test "delivery failure marks only that node failed" {
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

test "completion without result fails the node" {
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
    _ = try rt.tick(&stack);

    const statuses = try stack.statusesAlloc(a);
    defer a.free(statuses);
    try std.testing.expectEqual(status.Status.failed, statusOf(&stack, statuses, "impl-1"));
}

test "blocked result does not release dependents" {
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
    try stack.storeResult("impl-1", "FOLLOWUPS REQUIRED\nneeds a fix\n");
    try stack.storeCompletion("impl-1");
    _ = try rt.tick(&stack);

    const statuses = try stack.statusesAlloc(a);
    defer a.free(statuses);
    try std.testing.expectEqual(status.Status.blocked, statusOf(&stack, statuses, "impl-1"));
    try std.testing.expectEqual(status.Status.queued, statusOf(&stack, statuses, "review-1"));
    try std.testing.expectEqual(@as(usize, 0), deliveredCount(&stack, "review-1"));
    try std.testing.expectEqual(@as(usize, 1), eventCount(&stack, "impl-1", .blocked));
}

test "missing use fails only that node and unrelated work continues" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const text =
        \\[[thread]]
        \\name = "bad"
        \\command = "codex"
        \\
        \\[[thread]]
        \\name = "good"
        \\command = "claude"
        \\
        \\[[prompt]]
        \\name = "bad-1"
        \\thread = "bad"
        \\use = "missing.md"
        \\
        \\[[prompt]]
        \\name = "good-1"
        \\thread = "good"
        \\body = "still run"
        \\
    ;
    var stack = try planStack(&tmp, text);
    defer stack.deinit();

    var adapter = FakeAdapter{ .allocator = a };
    defer adapter.deinit();
    var rt = PlanRuntime(FakeAdapter){ .gpa = a, .adapter = &adapter };
    defer rt.deinit();
    try rt.startStack(&stack);
    _ = try rt.tick(&stack);

    const statuses = try stack.statusesAlloc(a);
    defer a.free(statuses);
    try std.testing.expectEqual(status.Status.failed, statusOf(&stack, statuses, "bad-1"));
    try std.testing.expectEqual(status.Status.running, statusOf(&stack, statuses, "good-1"));
    try std.testing.expectEqual(@as(usize, 1), deliveredCount(&stack, "good-1"));
}

test "a running node survives a transient pane dump failure" {
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
    _ = try rt.tick(&stack); // dump fails, but a dump is debug-only -> stays running

    const statuses = try stack.statusesAlloc(a);
    defer a.free(statuses);
    try std.testing.expectEqual(status.Status.running, statusOf(&stack, statuses, "impl-1"));
}

test "an injected node is picked up live without a restart" {
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

    // Complete the whole chain so the runner would otherwise be idle.
    try stack.storeResult("impl-1", "r");
    try stack.storeCompletion("impl-1");
    try stack.storeResult("review-1", "r");
    try stack.storeCompletion("review-1");
    _ = try rt.tick(&stack);

    // Inject a post-stack node on the impl thread. The next tick must reload the
    // graph from disk and deliver it without the runtime being restarted.
    try stack.inject(.{
        .name = "followup-1",
        .thread = "impl",
        .action = .none,
        .use_path = "",
        .with = &.{},
        .body = "Post-stack follow-up.",
        .blocked_by = &.{},
        .raw = false,
    }, null);
    _ = try rt.tick(&stack);

    const statuses = try stack.statusesAlloc(a);
    defer a.free(statuses);
    try std.testing.expectEqual(status.Status.running, statusOf(&stack, statuses, "followup-1"));
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
