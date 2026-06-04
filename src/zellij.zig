const std = @import("std");
const store = @import("store.zig");

pub const Error = error{
    SessionConflict,
    MissingSession,
    MissingThreadPane,
    SpawnFailed,
    CommandFailed,
    Timeout,
    OutOfMemory,
} || store.Error || std.Thread.SpawnError;

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

pub fn Runtime(comptime Adapter: type) type {
    return struct {
        allocator: std.mem.Allocator,
        adapter: *Adapter,

        const Self = @This();

        pub fn startStack(self: *Self, stack: *store.Stack) Error!void {
            const exists = try self.adapter.sessionExists(stack.name);
            if (exists and !stack.hasOwnershipMarker()) return error.SessionConflict;
            if (!exists) try self.adapter.createSession(stack.name);

            const runs = try stack.listRuns();
            defer stack.freeRuns(runs);
            const threads = try stack.listThreads();
            defer stack.freeThreads(threads);
            for (threads) |thread| {
                if (thread.pane_id.len != 0) {
                    if (try self.adapter.paneExists(stack.name, thread.pane_id)) continue;
                    if (hasRunningOnThread(runs, thread.name)) continue;
                }
                const command = if (thread.command.len != 0) thread.command else stack.command;
                const pane = try self.adapter.ensureThreadTab(stack.name, thread.name, command, stack.cwd);
                defer {
                    self.allocator.free(pane.tab_id);
                    self.allocator.free(pane.pane_id);
                }
                try stack.setThreadPane(thread.name, pane.tab_id, pane.pane_id);
            }
        }

        pub fn deliver(self: *Self, stack: *store.Stack, run_id: []const u8) Error!void {
            var run = try stack.readRun(run_id);
            defer run.deinit();
            var thread = try stack.readThread(run.thread);
            defer thread.deinit();
            if (thread.pane_id.len == 0) return error.MissingThreadPane;
            if (run.action != .none) {
                try self.adapter.paste(stack.name, thread.pane_id, run.action.command());
                try self.adapter.enter(stack.name, thread.pane_id);
            }
            try self.adapter.paste(stack.name, thread.pane_id, run.rendered);
            try self.adapter.enter(stack.name, thread.pane_id);
            try stack.setRunStatus(run.id, .running, "");
        }

        pub fn pollOnce(self: *Self, stack: *store.Stack, run_id: []const u8) Error!bool {
            var run = try stack.readRun(run_id);
            defer run.deinit();
            if (stack.completionExists(run.id)) {
                if (stack.resultExists(run.id)) {
                    try stack.setRunStatus(run.id, .completed, "");
                } else {
                    try stack.setRunStatus(run.id, .failed, "missing_result_file");
                }
                return true;
            }
            var thread = try stack.readThread(run.thread);
            defer thread.deinit();
            if (thread.pane_id.len == 0) return error.MissingThreadPane;
            if (!try self.adapter.paneExists(stack.name, thread.pane_id)) return error.MissingThreadPane;
            const dump = try self.adapter.dumpPane(stack.name, thread.pane_id);
            defer self.allocator.free(dump);
            try stack.storeOutput(run.id, dump);
            return false;
        }

        pub fn runUntilIdle(self: *Self, stack: *store.Stack, sleep: SleepFn) Error!void {
            try self.startStack(stack);
            while (true) {
                const running_left = try self.pollRunning(stack);

                const runs = try stack.listRuns();
                defer stack.freeRuns(runs);
                const ready = try @import("scheduler.zig").readyRunsAlloc(self.allocator, runs);
                defer {
                    for (ready) |id| self.allocator.free(id);
                    self.allocator.free(ready);
                }
                for (ready) |id| {
                    self.deliver(stack, id) catch |e| switch (e) {
                        error.MissingThreadPane, error.CommandFailed => {
                            try stack.setRunStatus(id, .failed, deliverFailureReason(e));
                            continue;
                        },
                        else => return e,
                    };
                }
                try self.blockFailedDependents(stack);
                if (running_left == 0 and ready.len == 0) return;
                sleep();
            }
        }

        fn pollRunning(self: *Self, stack: *store.Stack) Error!usize {
            const runs = try stack.listRuns();
            defer stack.freeRuns(runs);
            var running_left: usize = 0;
            for (runs) |run| {
                if (run.status != .running) continue;
                const completed = self.pollOnce(stack, run.id) catch |e| switch (e) {
                    error.MissingThreadPane, error.CommandFailed => {
                        try stack.setRunStatus(run.id, .failed, pollFailureReason(e));
                        continue;
                    },
                    else => return e,
                };
                if (!completed) running_left += 1;
            }
            return running_left;
        }

        fn blockFailedDependents(self: *Self, stack: *store.Stack) Error!void {
            const runs = try stack.listRuns();
            defer stack.freeRuns(runs);
            for (runs) |run| {
                if (run.status != .queued) continue;
                if (try failedDepReason(self.allocator, runs, run.after, "dependency_failed")) |reason| {
                    defer self.allocator.free(reason);
                    try stack.setRunStatus(run.id, .blocked, reason);
                    continue;
                }
                if (try failedDepReason(self.allocator, runs, run.inputs, "input_failed")) |reason| {
                    defer self.allocator.free(reason);
                    try stack.setRunStatus(run.id, .blocked, reason);
                    continue;
                }
            }
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

fn hasRunningOnThread(runs: []const store.PromptRun, thread: []const u8) bool {
    for (runs) |run| {
        if (run.status == .running and std.mem.eql(u8, run.thread, thread)) return true;
    }
    return false;
}

fn pollFailureReason(e: Error) []const u8 {
    return switch (e) {
        error.MissingThreadPane => "missing_thread_pane",
        error.CommandFailed => "zellij_dump_failed",
        else => unreachable,
    };
}

fn deliverFailureReason(e: Error) []const u8 {
    return switch (e) {
        error.MissingThreadPane => "missing_thread_pane",
        error.CommandFailed => "zellij_deliver_failed",
        else => unreachable,
    };
}

fn failedDepReason(allocator: std.mem.Allocator, runs: []const store.PromptRun, deps: []const []const u8, prefix: []const u8) error{OutOfMemory}!?[]u8 {
    for (deps) |dep| {
        for (runs) |run| {
            if (!std.mem.eql(u8, run.id, dep)) continue;
            if (run.status == .failed or run.status == .blocked) {
                return try std.fmt.allocPrint(allocator, "{s}:{s}", .{ prefix, dep });
            }
            break;
        }
    }
    return null;
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

test "runUntilIdle completes a dependency chain with FakeAdapter" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/root", .{&tmp.sub_path});
    defer a.free(root);
    const thread_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/builder.md", .{&tmp.sub_path});
    defer a.free(thread_path);
    const plan_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/plan.md", .{&tmp.sub_path});
    defer a.free(plan_path);
    const impl_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/impl.md", .{&tmp.sub_path});
    defer a.free(impl_path);

    try tmp.dir.makePath("root");
    var stack = try store.Stack.create(a, root, "demo", "codex", "");
    defer stack.deinit();
    try tmp.dir.writeFile(.{ .sub_path = "builder.md", .data = 
        \\+++
        \\type = "thread"
        \\thread = "builder"
        \\+++
        \\Build.
    });
    try stack.installThreadFile(thread_path);
    try tmp.dir.writeFile(.{ .sub_path = "plan.md", .data = 
        \\+++
        \\id = "plan"
        \\thread = "builder"
        \\+++
        \\Plan.
    });
    try tmp.dir.writeFile(.{ .sub_path = "impl.md", .data = 
        \\+++
        \\id = "impl"
        \\thread = "builder"
        \\after = ["plan"]
        \\+++
        \\Implement.
    });
    const reports = try stack.addFiles(&.{ plan_path, impl_path });
    defer stack.freeReports(reports);
    try stack.storeResult("plan", "plan result");
    try stack.storeResult("impl", "impl result");
    try stack.storeCompletion("plan");
    try stack.storeCompletion("impl");

    var adapter = FakeAdapter{ .allocator = a };
    defer adapter.deinit();
    var runtime = Runtime(FakeAdapter){ .allocator = a, .adapter = &adapter };
    try runtime.runUntilIdle(&stack, noSleep);

    var plan = try stack.readRun("plan");
    defer plan.deinit();
    var impl = try stack.readRun("impl");
    defer impl.deinit();
    try std.testing.expectEqual(store.PromptStatus.completed, plan.status);
    try std.testing.expectEqual(store.PromptStatus.completed, impl.status);
}

test "startStack uses thread command override when present" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/root", .{&tmp.sub_path});
    defer a.free(root);
    const builder_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/builder.md", .{&tmp.sub_path});
    defer a.free(builder_path);
    const reviewer_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/reviewer.md", .{&tmp.sub_path});
    defer a.free(reviewer_path);

    try tmp.dir.makePath("root");
    var stack = try store.Stack.create(a, root, "demo", "codex", "/work/repo");
    defer stack.deinit();
    try tmp.dir.writeFile(.{ .sub_path = "builder.md", .data = 
        \\+++
        \\type = "thread"
        \\thread = "builder"
        \\+++
        \\Build.
    });
    try tmp.dir.writeFile(.{ .sub_path = "reviewer.md", .data = 
        \\+++
        \\type = "thread"
        \\thread = "reviewer"
        \\command = "claude"
        \\+++
        \\Review.
    });
    try stack.installThreadFile(builder_path);
    try stack.installThreadFile(reviewer_path);

    var adapter = FakeAdapter{ .allocator = a };
    defer adapter.deinit();
    var runtime = Runtime(FakeAdapter){ .allocator = a, .adapter = &adapter };
    try runtime.startStack(&stack);

    try std.testing.expectEqual(@as(usize, 2), adapter.launch_log.items.len);
    try std.testing.expectEqualStrings("builder:codex:/work/repo", adapter.launch_log.items[0]);
    try std.testing.expectEqualStrings("reviewer:claude:/work/repo", adapter.launch_log.items[1]);
}

test "runUntilIdle marks only a missing pane running prompt failed" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/root", .{&tmp.sub_path});
    defer a.free(root);
    const lost_thread_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/lost.md", .{&tmp.sub_path});
    defer a.free(lost_thread_path);
    const ok_thread_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/ok.md", .{&tmp.sub_path});
    defer a.free(ok_thread_path);
    const lost_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/lost-run.md", .{&tmp.sub_path});
    defer a.free(lost_path);
    const ok_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/ok-run.md", .{&tmp.sub_path});
    defer a.free(ok_path);

    try tmp.dir.makePath("root");
    var stack = try store.Stack.create(a, root, "demo", "codex", "");
    defer stack.deinit();
    try tmp.dir.writeFile(.{ .sub_path = "lost.md", .data = 
        \\+++
        \\type = "thread"
        \\thread = "lost"
        \\+++
        \\Lost.
    });
    try tmp.dir.writeFile(.{ .sub_path = "ok.md", .data = 
        \\+++
        \\type = "thread"
        \\thread = "ok"
        \\+++
        \\Ok.
    });
    try stack.installThreadFile(lost_thread_path);
    try stack.installThreadFile(ok_thread_path);
    try tmp.dir.writeFile(.{ .sub_path = "lost-run.md", .data = 
        \\+++
        \\id = "lost-run"
        \\thread = "lost"
        \\+++
        \\Lost run.
    });
    try tmp.dir.writeFile(.{ .sub_path = "ok-run.md", .data = 
        \\+++
        \\id = "ok-run"
        \\thread = "ok"
        \\+++
        \\Ok run.
    });
    const reports = try stack.addFiles(&.{ lost_path, ok_path });
    defer stack.freeReports(reports);
    try stack.storeResult("ok-run", "ok result");
    try stack.storeCompletion("ok-run");

    var adapter = FakeAdapter{ .allocator = a };
    defer adapter.deinit();
    var runtime = Runtime(FakeAdapter){ .allocator = a, .adapter = &adapter };
    try runtime.startStack(&stack);
    try stack.setRunStatus("lost-run", .running, "");
    try stack.setRunStatus("ok-run", .running, "");

    adapter.missing_pane = "pane-lost";
    try runtime.runUntilIdle(&stack, noSleep);

    var lost = try stack.readRun("lost-run");
    defer lost.deinit();
    var reread_ok = try stack.readRun("ok-run");
    defer reread_ok.deinit();
    try std.testing.expectEqual(store.PromptStatus.failed, lost.status);
    try std.testing.expectEqualStrings("missing_thread_pane", lost.blocked_reason);
    try std.testing.expectEqual(store.PromptStatus.completed, reread_ok.status);
}

test "runUntilIdle marks only a dump-failed running prompt failed" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/root", .{&tmp.sub_path});
    defer a.free(root);
    const bad_thread_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/bad.md", .{&tmp.sub_path});
    defer a.free(bad_thread_path);
    const ok_thread_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/ok.md", .{&tmp.sub_path});
    defer a.free(ok_thread_path);
    const bad_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/bad-run.md", .{&tmp.sub_path});
    defer a.free(bad_path);
    const ok_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/ok-run.md", .{&tmp.sub_path});
    defer a.free(ok_path);

    try tmp.dir.makePath("root");
    var stack = try store.Stack.create(a, root, "demo", "codex", "");
    defer stack.deinit();
    try tmp.dir.writeFile(.{ .sub_path = "bad.md", .data = 
        \\+++
        \\type = "thread"
        \\thread = "bad"
        \\+++
        \\Bad.
    });
    try tmp.dir.writeFile(.{ .sub_path = "ok.md", .data = 
        \\+++
        \\type = "thread"
        \\thread = "ok"
        \\+++
        \\Ok.
    });
    try stack.installThreadFile(bad_thread_path);
    try stack.installThreadFile(ok_thread_path);
    try tmp.dir.writeFile(.{ .sub_path = "bad-run.md", .data = 
        \\+++
        \\id = "bad-run"
        \\thread = "bad"
        \\+++
        \\Bad run.
    });
    try tmp.dir.writeFile(.{ .sub_path = "ok-run.md", .data = 
        \\+++
        \\id = "ok-run"
        \\thread = "ok"
        \\+++
        \\Ok run.
    });
    const reports = try stack.addFiles(&.{ bad_path, ok_path });
    defer stack.freeReports(reports);
    try stack.storeResult("ok-run", "ok result");
    try stack.storeCompletion("ok-run");

    var adapter = FakeAdapter{ .allocator = a };
    defer adapter.deinit();
    var runtime = Runtime(FakeAdapter){ .allocator = a, .adapter = &adapter };
    try runtime.startStack(&stack);
    try stack.setRunStatus("bad-run", .running, "");
    try stack.setRunStatus("ok-run", .running, "");

    adapter.fail_dump_pane = "pane-bad";
    try runtime.runUntilIdle(&stack, noSleep);

    var bad = try stack.readRun("bad-run");
    defer bad.deinit();
    var reread_ok = try stack.readRun("ok-run");
    defer reread_ok.deinit();
    try std.testing.expectEqual(store.PromptStatus.failed, bad.status);
    try std.testing.expectEqualStrings("zellij_dump_failed", bad.blocked_reason);
    try std.testing.expectEqual(store.PromptStatus.completed, reread_ok.status);
}

test "completion marker without result file fails the run" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/root", .{&tmp.sub_path});
    defer a.free(root);
    const thread_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/builder.md", .{&tmp.sub_path});
    defer a.free(thread_path);
    const prompt_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/impl.md", .{&tmp.sub_path});
    defer a.free(prompt_path);

    try tmp.dir.makePath("root");
    var stack = try store.Stack.create(a, root, "demo", "codex", "");
    defer stack.deinit();
    try tmp.dir.writeFile(.{ .sub_path = "builder.md", .data = 
        \\+++
        \\type = "thread"
        \\thread = "builder"
        \\+++
        \\Build.
    });
    try stack.installThreadFile(thread_path);
    try tmp.dir.writeFile(.{ .sub_path = "impl.md", .data = 
        \\+++
        \\id = "impl"
        \\thread = "builder"
        \\+++
        \\Implement.
    });
    const reports = try stack.addFiles(&.{prompt_path});
    defer stack.freeReports(reports);
    try stack.storeCompletion("impl");

    var adapter = FakeAdapter{ .allocator = a };
    defer adapter.deinit();
    var runtime = Runtime(FakeAdapter){ .allocator = a, .adapter = &adapter };
    try runtime.runUntilIdle(&stack, noSleep);

    var reread = try stack.readRun("impl");
    defer reread.deinit();
    try std.testing.expectEqual(store.PromptStatus.failed, reread.status);
    try std.testing.expectEqualStrings("missing_result_file", reread.blocked_reason);
}

test "rendered prompt echoed in pane does not complete the run" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/root", .{&tmp.sub_path});
    defer a.free(root);
    const thread_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/builder.md", .{&tmp.sub_path});
    defer a.free(thread_path);
    const prompt_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/impl.md", .{&tmp.sub_path});
    defer a.free(prompt_path);

    try tmp.dir.makePath("root");
    var stack = try store.Stack.create(a, root, "demo", "codex", "");
    defer stack.deinit();
    try tmp.dir.writeFile(.{ .sub_path = "builder.md", .data = 
        \\+++
        \\type = "thread"
        \\thread = "builder"
        \\+++
        \\Build.
    });
    try stack.installThreadFile(thread_path);
    try tmp.dir.writeFile(.{ .sub_path = "impl.md", .data = 
        \\+++
        \\id = "impl"
        \\thread = "builder"
        \\+++
        \\Implement.
    });
    const reports = try stack.addFiles(&.{prompt_path});
    defer stack.freeReports(reports);

    var adapter = FakeAdapter{ .allocator = a };
    defer adapter.deinit();
    var runtime = Runtime(FakeAdapter){ .allocator = a, .adapter = &adapter };
    try runtime.startStack(&stack);
    try runtime.deliver(&stack, "impl");

    var running = try stack.readRun("impl");
    const rendered_echo = try a.dupe(u8, running.rendered);
    running.deinit();
    defer a.free(rendered_echo);
    adapter.dump = rendered_echo;
    try stack.storeResult("impl", "durable result");
    try std.testing.expect(!try runtime.pollOnce(&stack, "impl"));

    var reread = try stack.readRun("impl");
    defer reread.deinit();
    try std.testing.expectEqual(store.PromptStatus.running, reread.status);
}

test "delivery failure marks only that prompt failed" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/root", .{&tmp.sub_path});
    defer a.free(root);
    const bad_thread_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/bad.md", .{&tmp.sub_path});
    defer a.free(bad_thread_path);
    const ok_thread_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/ok.md", .{&tmp.sub_path});
    defer a.free(ok_thread_path);
    const bad_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/bad-run.md", .{&tmp.sub_path});
    defer a.free(bad_path);
    const ok_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/ok-run.md", .{&tmp.sub_path});
    defer a.free(ok_path);

    try tmp.dir.makePath("root");
    var stack = try store.Stack.create(a, root, "demo", "codex", "");
    defer stack.deinit();
    try tmp.dir.writeFile(.{ .sub_path = "bad.md", .data = 
        \\+++
        \\type = "thread"
        \\thread = "bad"
        \\+++
        \\Bad.
    });
    try tmp.dir.writeFile(.{ .sub_path = "ok.md", .data = 
        \\+++
        \\type = "thread"
        \\thread = "ok"
        \\+++
        \\Ok.
    });
    try stack.installThreadFile(bad_thread_path);
    try stack.installThreadFile(ok_thread_path);
    try tmp.dir.writeFile(.{ .sub_path = "bad-run.md", .data = 
        \\+++
        \\id = "bad-run"
        \\thread = "bad"
        \\+++
        \\Bad run.
    });
    try tmp.dir.writeFile(.{ .sub_path = "ok-run.md", .data = 
        \\+++
        \\id = "ok-run"
        \\thread = "ok"
        \\+++
        \\Ok run.
    });
    const reports = try stack.addFiles(&.{ bad_path, ok_path });
    defer stack.freeReports(reports);
    try stack.storeResult("ok-run", "ok result");
    try stack.storeCompletion("ok-run");

    var adapter = FakeAdapter{ .allocator = a, .fail_paste_pane = "pane-bad" };
    defer adapter.deinit();
    var runtime = Runtime(FakeAdapter){ .allocator = a, .adapter = &adapter };
    try runtime.runUntilIdle(&stack, noSleep);

    var bad = try stack.readRun("bad-run");
    defer bad.deinit();
    var ok = try stack.readRun("ok-run");
    defer ok.deinit();
    try std.testing.expectEqual(store.PromptStatus.failed, bad.status);
    try std.testing.expectEqualStrings("zellij_deliver_failed", bad.blocked_reason);
    try std.testing.expectEqual(store.PromptStatus.completed, ok.status);
}

test "failed dependency blocks queued dependent" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/root", .{&tmp.sub_path});
    defer a.free(root);
    const thread_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/builder.md", .{&tmp.sub_path});
    defer a.free(thread_path);
    const plan_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/plan.md", .{&tmp.sub_path});
    defer a.free(plan_path);
    const impl_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/impl.md", .{&tmp.sub_path});
    defer a.free(impl_path);

    try tmp.dir.makePath("root");
    var stack = try store.Stack.create(a, root, "demo", "codex", "");
    defer stack.deinit();
    try tmp.dir.writeFile(.{ .sub_path = "builder.md", .data = 
        \\+++
        \\type = "thread"
        \\thread = "builder"
        \\+++
        \\Build.
    });
    try stack.installThreadFile(thread_path);
    try tmp.dir.writeFile(.{ .sub_path = "plan.md", .data = 
        \\+++
        \\id = "plan"
        \\thread = "builder"
        \\+++
        \\Plan.
    });
    try tmp.dir.writeFile(.{ .sub_path = "impl.md", .data = 
        \\+++
        \\id = "impl"
        \\thread = "builder"
        \\after = ["plan"]
        \\+++
        \\Implement.
    });
    const reports = try stack.addFiles(&.{ plan_path, impl_path });
    defer stack.freeReports(reports);
    try stack.setRunStatus("plan", .failed, "test_failed");

    var adapter = FakeAdapter{ .allocator = a };
    defer adapter.deinit();
    var runtime = Runtime(FakeAdapter){ .allocator = a, .adapter = &adapter };
    try runtime.runUntilIdle(&stack, noSleep);

    var impl = try stack.readRun("impl");
    defer impl.deinit();
    try std.testing.expectEqual(store.PromptStatus.blocked, impl.status);
    try std.testing.expectEqualStrings("dependency_failed:plan", impl.blocked_reason);
}

fn noSleep() void {}

test "runtime rejects unowned existing zellij session" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/root", .{&tmp.sub_path});
    defer a.free(root);
    try tmp.dir.makePath("root");
    var stack = try store.Stack.create(a, root, "demo", "codex", "");
    defer stack.deinit();

    const marker = try std.fmt.allocPrint(a, "{s}/stacks/demo/state/zellij-owner", .{root});
    defer a.free(marker);
    try std.fs.cwd().deleteFile(marker);

    var fake = FakeAdapter{ .allocator = a, .session_exists = true };
    defer fake.deinit();
    var runtime = Runtime(FakeAdapter){ .allocator = a, .adapter = &fake };
    try std.testing.expectError(error.SessionConflict, runtime.startStack(&stack));
}

test "runtime targets panes, stores dumps, and completes on done marker" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/root", .{&tmp.sub_path});
    defer a.free(root);
    const thread_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/builder.md", .{&tmp.sub_path});
    defer a.free(thread_path);
    const prompt_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/plan.md", .{&tmp.sub_path});
    defer a.free(prompt_path);

    try tmp.dir.makePath("root");
    var stack = try store.Stack.create(a, root, "demo", "codex", "");
    defer stack.deinit();
    try tmp.dir.writeFile(.{ .sub_path = "builder.md", .data = 
        \\+++
        \\type = "thread"
        \\thread = "builder"
        \\+++
        \\Thread prompt.
    });
    try tmp.dir.writeFile(.{ .sub_path = "plan.md", .data = 
        \\+++
        \\id = "plan"
        \\thread = "builder"
        \\action = "compact"
        \\+++
        \\Plan the work.
    });
    const reports = try stack.addFiles(&.{ thread_path, prompt_path });
    defer stack.freeReports(reports);

    var fake = FakeAdapter{ .allocator = a };
    defer fake.deinit();
    var runtime = Runtime(FakeAdapter){ .allocator = a, .adapter = &fake };
    try runtime.startStack(&stack);
    try runtime.deliver(&stack, "plan");
    try std.testing.expect(fake.created);
    try std.testing.expect(fake.paste_log.items.len >= 4);
    try std.testing.expect(std.mem.startsWith(u8, fake.paste_log.items[0], "pane-builder:/compact"));

    fake.dump = try a.dupe(u8, "claude/codex result\n");
    defer a.free(fake.dump);
    try stack.storeResult("plan", "durable plan result");
    try std.testing.expect(!try runtime.pollOnce(&stack, "plan"));
    try stack.storeCompletion("plan");
    try std.testing.expect(try runtime.pollOnce(&stack, "plan"));

    var after = try stack.readRun("plan");
    defer after.deinit();
    try std.testing.expectEqual(store.PromptStatus.completed, after.status);
    try std.testing.expect(std.mem.indexOf(u8, after.output, "claude/codex result") != null);
}
