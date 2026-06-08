const std = @import("std");
const paths = @import("paths.zig");
const plan = @import("plan.zig");
const status = @import("status.zig");
const runtime = @import("runtime.zig");
const zellij = @import("zellij.zig");

pub const Error = error{
    Usage,
    OutOfMemory,
} || paths.Error || runtime.Error || zellij.Error || std.Io.Writer.Error ||
    std.fs.Dir.MakeError || std.process.Child.SpawnError || std.process.Child.WaitError ||
    std.posix.KillError;

const Options = struct {
    name: []const u8 = "",
    root: []const u8 = "",
    cwd: []const u8 = "",
    from: []const u8 = "",
    json: bool = false,
    watch: bool = false,
    force: bool = false,
    snapshot: bool = false,
};

pub fn dispatch(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) Error!u8 {
    if (args.len == 0) {
        try overview(stderr);
        return 2;
    }

    const cmd = args[0];
    if (isHelpArg(cmd) or std.mem.eql(u8, cmd, "help")) return try cmdHelp(args[1..], stdout, stderr);

    if (std.mem.eql(u8, cmd, "plan")) return try cmdPlan(allocator, args[1..], stdout, stderr);
    if (std.mem.eql(u8, cmd, "new")) return try cmdNew(allocator, args[1..], stdout, stderr);
    if (std.mem.eql(u8, cmd, "status")) return try cmdStatus(allocator, args[1..], stdout, stderr);
    if (std.mem.eql(u8, cmd, "render")) return try cmdRender(allocator, args[1..], stdout, stderr);
    if (std.mem.eql(u8, cmd, "inject")) return try cmdInject(allocator, args[1..], stdout, stderr);
    if (std.mem.eql(u8, cmd, "link")) return try cmdLink(allocator, args[1..], stdout, stderr);
    if (std.mem.eql(u8, cmd, "start")) return try cmdStart(allocator, args[1..], stdout, stderr);
    if (std.mem.eql(u8, cmd, "stop")) return try cmdStop(allocator, args[1..], stdout, stderr);
    if (std.mem.eql(u8, cmd, "attach")) return try cmdAttach(allocator, args[1..], stdout, stderr);
    if (std.mem.eql(u8, cmd, "output")) return try cmdOutput(allocator, args[1..], stdout, stderr);
    if (std.mem.eql(u8, cmd, "redeliver")) return try cmdRedeliver(allocator, args[1..], stdout, stderr);
    if (std.mem.eql(u8, cmd, "complete")) return try cmdComplete(allocator, args[1..], stdout, stderr);
    if (std.mem.eql(u8, cmd, "reset")) return try cmdReset(allocator, args[1..], stdout, stderr);

    try stderr.print("unknown command: {s}\n", .{cmd});
    try overview(stderr);
    return 2;
}

fn cmdHelp(args: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) Error!u8 {
    _ = args;
    _ = stderr;
    try overview(stdout);
    return 0;
}

// ---------- plan ----------

fn cmdPlan(gpa: std.mem.Allocator, args: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) Error!u8 {
    var opts: Options = .{};
    var folder: []const u8 = "";
    if (!try parsePlanArgs(args, &folder, &opts, stderr)) return 2;

    var resolved = resolvePlanAlloc(gpa, folder, opts) catch |e| return reportResolveError(e, folder, stderr);
    defer resolved.deinit();

    var p = try plan.parse(gpa, resolved.plan_text);
    defer p.deinit();

    if (opts.json) {
        try printPlanJson(stdout, &resolved, &p);
    } else {
        try printPlanText(stdout, &resolved, &p);
    }
    return 0;
}

fn printPlanText(w: *std.Io.Writer, resolved: *const Resolved, p: *const plan.Plan) Error!void {
    try w.print("stack name: {s}\n", .{resolved.name});
    try w.print("prompt folder: {s}\n", .{resolved.prompt_folder});
    try w.print("stack root: {s}\n", .{resolved.root});
    try w.print("agent cwd: {s}\n", .{resolved.agent_cwd});
    try w.writeAll("threads:");
    for (p.threads, 0..) |t, i| {
        try w.print("{s} {s}({s})", .{ if (i == 0) "" else ",", t.name, t.command });
    }
    try w.writeByte('\n');
    try w.writeAll("nodes:\n");
    for (p.nodes) |n| {
        try w.print("  {s} thread={s}", .{ n.name, n.thread });
        if (n.blocked_by.len == 0) {
            try w.writeAll(" ready");
        } else {
            try w.writeAll(" blocked_by=");
            for (n.blocked_by, 0..) |b, i| try w.print("{s}{s}", .{ if (i == 0) "" else ",", b });
        }
        try w.writeByte('\n');
    }
    return;
}

fn printPlanJson(w: *std.Io.Writer, resolved: *const Resolved, p: *const plan.Plan) Error!void {
    try w.writeAll("{\"name\":");
    try jsonString(w, resolved.name);
    try w.writeAll(",\"prompt_folder\":");
    try jsonString(w, resolved.prompt_folder);
    try w.writeAll(",\"stack_root\":");
    try jsonString(w, resolved.root);
    try w.writeAll(",\"agent_cwd\":");
    try jsonString(w, resolved.agent_cwd);
    try w.writeAll(",\"threads\":[");
    for (p.threads, 0..) |t, i| {
        if (i != 0) try w.writeByte(',');
        try w.writeAll("{\"name\":");
        try jsonString(w, t.name);
        try w.writeAll(",\"command\":");
        try jsonString(w, t.command);
        try w.writeByte('}');
    }
    try w.writeAll("],\"nodes\":[");
    for (p.nodes, 0..) |n, i| {
        if (i != 0) try w.writeByte(',');
        try w.writeAll("{\"name\":");
        try jsonString(w, n.name);
        try w.writeAll(",\"thread\":");
        try jsonString(w, n.thread);
        try w.writeAll(",\"blocked_by\":[");
        for (n.blocked_by, 0..) |b, j| {
            if (j != 0) try w.writeByte(',');
            try jsonString(w, b);
        }
        try w.writeAll("]}");
    }
    try w.writeAll("]}\n");
}

// ---------- new ----------

fn cmdNew(gpa: std.mem.Allocator, args: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) Error!u8 {
    var opts: Options = .{};
    var positional: []const u8 = "";
    if (!try parseNewArgs(args, &positional, &opts, stderr)) return 2;

    // `new <name> --from <folder>` names the stack explicitly; otherwise the
    // positional is the prompt folder and the name is inferred.
    const folder = if (opts.from.len != 0) opts.from else positional;
    var name_opt = opts.name;
    if (opts.from.len != 0) name_opt = positional;

    var resolve_opts = opts;
    resolve_opts.name = name_opt;
    var resolved = resolvePlanAlloc(gpa, folder, resolve_opts) catch |e| return reportResolveError(e, folder, stderr);
    defer resolved.deinit();

    // Agents write run artifacts (result.md, done) under the stack root. With a
    // sandboxed harness (e.g. codex workspace-write) a root outside the agent cwd
    // is unwritable, so the stack silently never completes. Warn, don't block.
    if (std.fs.path.isAbsolute(resolved.root) and std.fs.path.isAbsolute(resolved.agent_cwd) and
        !pathInside(resolved.root, resolved.agent_cwd))
    {
        try stderr.print("warning: stack root {s} is outside the agent cwd {s}; a sandboxed agent may be unable to write results there\n", .{ resolved.root, resolved.agent_cwd });
    }

    std.fs.cwd().makePath(resolved.root) catch {
        try stderr.print("cannot create stack root: {s}\n", .{resolved.root});
        return 2;
    };
    var stack = runtime.Stack.createFromSource(gpa, resolved.root, resolved.name, .{
        .plan_text = resolved.plan_text,
        .agent_cwd_abs = resolved.agent_cwd,
        .prompt_folder_abs = resolved.prompt_folder,
    }) catch |e| switch (e) {
        error.AlreadyExists => {
            try stderr.print("stack already exists: {s}\n", .{resolved.name});
            return 2;
        },
        else => return e,
    };
    defer stack.deinit();
    try stdout.print("created stack {s} root={s} cwd={s} ({d} threads, {d} nodes)\n", .{
        resolved.name, resolved.root, resolved.agent_cwd, stack.plan.threads.len, stack.plan.nodes.len,
    });
    return 0;
}

// ---------- status ----------

fn cmdStatus(gpa: std.mem.Allocator, args: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) Error!u8 {
    var opts: Options = .{};
    var name: []const u8 = "";
    if (!try parseStackArgs(args, &name, &opts, stderr)) return 2;
    const root = try paths.resolveNotesRoot(gpa, rootOrDefault(opts.root));
    defer gpa.free(root);

    var stack = runtime.Stack.open(gpa, root, name) catch |e| switch (e) {
        error.NotFound => {
            try stderr.print("no such stack: {s}\n", .{name});
            return 2;
        },
        else => return e,
    };
    defer stack.deinit();

    const statuses = try stack.statusesAlloc(gpa);
    defer gpa.free(statuses);

    if (opts.json) {
        try printStatusJson(stdout, &stack, statuses);
    } else {
        try printStatusText(stdout, &stack, statuses);
    }
    return 0;
}

/// A running node whose pane has not changed for this many seconds is flagged as
/// possibly stalled. The pane heartbeat (`output.md` mtime) proves only that the
/// pane repaints, so this is a hint, not proof — durable progress is `result.md`.
const stall_threshold_s: i64 = 300;

fn printStatusText(w: *std.Io.Writer, stack: *const runtime.Stack, statuses: []const status.Status) Error!void {
    try w.print("stack {s} cwd={s}\n", .{ stack.name, stack.agentCwd() });
    try printRunner(w, stack);
    for (stack.plan.threads) |t| {
        if (runningNode(stack, statuses, t.name)) |node| {
            try w.print("thread {s} running={s}\n", .{ t.name, node });
        } else {
            try w.print("thread {s} idle\n", .{t.name});
        }
    }
    for (stack.plan.nodes, 0..) |n, i| {
        try w.print("prompt {s} thread={s} status={s}", .{ n.name, n.thread, statuses[i].name() });
        if (statuses[i] == .queued) {
            if (status.blockersComplete(&stack.plan, statuses, &n) and status.threadIdle(&stack.plan, statuses, n.thread)) {
                try w.writeAll(" (ready)");
            } else {
                try printUnmet(w, stack, statuses, &n);
            }
        } else if (statuses[i] == .running) {
            if (idleSeconds(stack, n.name)) |idle| {
                if (idle >= stall_threshold_s) try w.print(" (stalled? quiet {d}s)", .{idle});
            }
        }
        try w.writeByte('\n');
    }
}

/// Print the attached runner's liveness, and note when the graph was edited
/// after the runner started. Runners reload live on every tick.
fn printRunner(w: *std.Io.Writer, stack: *const runtime.Stack) Error!void {
    const info = (stack.readRunnerPid() catch null) orelse {
        try w.writeAll("runner none\n");
        return;
    };
    const alive = runtime.pidAlive(info.pid);
    try w.print("runner pid={d} watch={} {s}\n", .{ info.pid, info.watch, if (alive) "alive" else "stale" });
    if (alive) {
        if (stack.planMtimeNanos()) |pm| {
            const pm_s: i64 = @intCast(@divFloor(pm, std.time.ns_per_s));
            if (pm_s > info.started) try w.writeAll("note: plan.toml was edited after this runner started; the live runner reloads it each tick\n");
        }
    }
}

/// Seconds since a running node's pane last changed, or null when there is no
/// dump yet.
fn idleSeconds(stack: *const runtime.Stack, node_name: []const u8) ?i64 {
    const mt = stack.runFileMtimeNanos(node_name, "output.md") orelse return null;
    const mt_s: i64 = @intCast(@divFloor(mt, std.time.ns_per_s));
    return std.time.timestamp() - mt_s;
}

fn printUnmet(w: *std.Io.Writer, stack: *const runtime.Stack, statuses: []const status.Status, node: *const plan.Node) Error!void {
    var wrote = false;
    for (node.blocked_by) |b| {
        if (statusOfNode(stack, statuses, b)) |s| {
            if (s == .completed) continue;
        }
        try w.print("{s}{s}", .{ if (wrote) "," else " waiting=", b });
        wrote = true;
    }
}

fn printStatusJson(w: *std.Io.Writer, stack: *const runtime.Stack, statuses: []const status.Status) Error!void {
    try w.writeAll("{\"stack\":");
    try jsonString(w, stack.name);
    try w.writeAll(",\"agent_cwd\":");
    try jsonString(w, stack.agentCwd());
    try w.writeAll(",\"runner\":");
    if (stack.readRunnerPid() catch null) |info| {
        try w.print("{{\"pid\":{d},\"watch\":{},\"alive\":{}}}", .{ info.pid, info.watch, runtime.pidAlive(info.pid) });
    } else {
        try w.writeAll("null");
    }
    try w.writeAll(",\"nodes\":[");
    for (stack.plan.nodes, 0..) |n, i| {
        if (i != 0) try w.writeByte(',');
        try w.writeAll("{\"name\":");
        try jsonString(w, n.name);
        try w.writeAll(",\"thread\":");
        try jsonString(w, n.thread);
        try w.writeAll(",\"status\":");
        try jsonString(w, statuses[i].name());
        const ready = statuses[i] == .queued and
            status.blockersComplete(&stack.plan, statuses, &n) and
            status.threadIdle(&stack.plan, statuses, n.thread);
        try w.print(",\"ready\":{}", .{ready});
        if (statuses[i] == .running) {
            if (idleSeconds(stack, n.name)) |idle| try w.print(",\"idle_seconds\":{d}", .{idle});
        }
        try w.writeAll("}");
    }
    try w.writeAll("]}\n");
}

// ---------- render ----------

fn cmdRender(gpa: std.mem.Allocator, args: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) Error!u8 {
    if (args.len < 2) {
        try stderr.writeAll("usage: stako render <stack> <node> [--root PATH]\n");
        return 2;
    }
    var opts: Options = .{};
    const name = args[0];
    const node_name = args[1];
    if (!try parseFlags(args[2..], &opts, stderr)) return 2;
    const root = try paths.resolveNotesRoot(gpa, rootOrDefault(opts.root));
    defer gpa.free(root);

    var stack = runtime.Stack.open(gpa, root, name) catch |e| switch (e) {
        error.NotFound => {
            try stderr.print("no such stack: {s}\n", .{name});
            return 2;
        },
        else => return e,
    };
    defer stack.deinit();
    const node = stack.plan.nodeByName(node_name) orelse {
        try stderr.print("no such node: {s}\n", .{node_name});
        return 2;
    };
    const rendered = try stack.renderNodeAlloc(gpa, node);
    defer gpa.free(rendered);
    try stdout.writeAll(rendered);
    return 0;
}

// ---------- inject / link ----------

fn cmdInject(gpa: std.mem.Allocator, args: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) Error!u8 {
    if (args.len < 2) {
        try stderr.writeAll("usage: stako inject <stack> <node> --thread T [--body B|--use F] [--with f1,f2] [--action A] [--blocked-by a,b] [--gate target] [--raw] [--root P]\n");
        return 2;
    }
    const name = args[0];
    const node_name = args[1];
    var root: []const u8 = "";
    var thread: []const u8 = "";
    var body: []const u8 = "";
    var use: []const u8 = "";
    var gate: []const u8 = "";
    var action_str: []const u8 = "none";
    var blocked_csv: []const u8 = "";
    var raw = false;

    // `--with` may repeat and/or carry a comma list; collect every value.
    var with_items: std.ArrayList([]const u8) = .empty;
    defer with_items.deinit(gpa);

    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (try flagValue(args, &i, a, "--root")) |v| {
            root = v;
        } else if (try flagValue(args, &i, a, "--thread")) |v| {
            thread = v;
        } else if (try flagValue(args, &i, a, "--body")) |v| {
            body = v;
        } else if (try flagValue(args, &i, a, "--use")) |v| {
            use = v;
        } else if (try flagValue(args, &i, a, "--with")) |v| {
            try appendCsv(gpa, &with_items, v);
        } else if (try flagValue(args, &i, a, "--gate")) |v| {
            gate = v;
        } else if (try flagValue(args, &i, a, "--action")) |v| {
            action_str = v;
        } else if (try flagValue(args, &i, a, "--blocked-by")) |v| {
            blocked_csv = v;
        } else if (std.mem.eql(u8, a, "--raw")) {
            raw = true;
        } else {
            try stderr.print("unexpected argument: {s}\n", .{a});
            return 2;
        }
    }
    if (thread.len == 0) {
        try stderr.writeAll("inject requires --thread\n");
        return 2;
    }
    const action = plan.Action.parse(action_str) catch {
        try stderr.print("invalid --action: {s}\n", .{action_str});
        return 2;
    };

    var blockers: std.ArrayList([]const u8) = .empty;
    defer blockers.deinit(gpa);
    try appendCsv(gpa, &blockers, blocked_csv);

    const root_resolved = try paths.resolveNotesRoot(gpa, rootOrDefault(root));
    defer gpa.free(root_resolved);
    var stack = runtime.Stack.open(gpa, root_resolved, name) catch |e| switch (e) {
        error.NotFound => {
            try stderr.print("no such stack: {s}\n", .{name});
            return 2;
        },
        else => return e,
    };
    defer stack.deinit();

    if (use.len != 0 and !stack.bodyFileExists(use)) {
        try stderr.print("cannot inject {s}: use file not found: {s}\n", .{ node_name, use });
        return 2;
    }

    const gate_opt: ?[]const u8 = if (gate.len != 0) gate else null;
    stack.inject(.{
        .name = node_name,
        .thread = thread,
        .action = action,
        .use_path = use,
        .with = with_items.items,
        .body = body,
        .blocked_by = blockers.items,
        .raw = raw,
    }, gate_opt) catch |e| return reportMutationError(e, stderr);
    if (gate_opt) |g| {
        try stdout.print("injected {s} (gates {s})\n", .{ node_name, g });
    } else {
        try stdout.print("injected {s}\n", .{node_name});
    }
    try printMutationRunnerHint(stdout, &stack, root_resolved);
    return 0;
}

fn cmdLink(gpa: std.mem.Allocator, args: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) Error!u8 {
    if (args.len < 3) {
        try stderr.writeAll("usage: stako link <stack> <source-node> <target-node> [--root P]\n");
        return 2;
    }
    const name = args[0];
    const source = args[1];
    const target = args[2];
    var opts: Options = .{};
    if (!try parseFlags(args[3..], &opts, stderr)) return 2;
    const root = try paths.resolveNotesRoot(gpa, rootOrDefault(opts.root));
    defer gpa.free(root);
    var stack = runtime.Stack.open(gpa, root, name) catch |e| switch (e) {
        error.NotFound => {
            try stderr.print("no such stack: {s}\n", .{name});
            return 2;
        },
        else => return e,
    };
    defer stack.deinit();
    stack.link(source, target) catch |e| return reportMutationError(e, stderr);
    try stdout.print("linked {s} -> {s}\n", .{ source, target });
    try printMutationRunnerHint(stdout, &stack, root);
    return 0;
}

fn printMutationRunnerHint(w: *std.Io.Writer, stack: *const runtime.Stack, root: []const u8) Error!void {
    if (stack.readRunnerPid() catch null) |info| {
        if (runtime.pidAlive(info.pid) and runtime.pidIsRunnerFor(info.pid, stack.name)) {
            try w.print("live runner pid={d} will pick it up on the next tick\n", .{info.pid});
            return;
        }
    }
    try w.print("no live runner; continue with: stako start {s} --watch", .{stack.name});
    if (!std.mem.eql(u8, root, paths.DEFAULT_NOTES_ROOT)) try w.print(" --root {s}", .{root});
    try w.writeByte('\n');
}

fn reportMutationError(e: Error, stderr: *std.Io.Writer) Error!u8 {
    switch (e) {
        error.TargetNotQueued => try stderr.writeAll("target node is not queued; cannot gate a running or finished node\n"),
        error.UnknownTarget => try stderr.writeAll("unknown source or target node\n"),
        error.UnknownThread => try stderr.writeAll("node references an unknown thread\n"),
        error.UnknownBlocker => try stderr.writeAll("node references an unknown blocker\n"),
        error.DuplicateNode => try stderr.writeAll("a node with that name already exists\n"),
        error.Cycle => try stderr.writeAll("that edge would create a dependency cycle\n"),
        else => return e,
    }
    return 2;
}

// ---------- start / attach / output ----------

fn cmdStart(gpa: std.mem.Allocator, args: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) Error!u8 {
    var opts: Options = .{};
    var name: []const u8 = "";
    if (!try parseStackArgs(args, &name, &opts, stderr)) return 2;
    const root = try paths.resolveNotesRoot(gpa, rootOrDefault(opts.root));
    defer gpa.free(root);
    var stack = runtime.Stack.open(gpa, root, name) catch |e| switch (e) {
        error.NotFound => {
            try stderr.print("no such stack: {s}\n", .{name});
            return 2;
        },
        else => return e,
    };
    defer stack.deinit();
    var adapter = zellij.CommandAdapter{ .allocator = gpa };
    var rt = zellij.PlanRuntime(zellij.CommandAdapter){ .gpa = gpa, .adapter = &adapter };
    defer rt.deinit();
    rt.runUntilIdle(&stack, .{ .sleep = sleepOneSecond, .watch = opts.watch }) catch |e| switch (e) {
        error.RunnerAlreadyRunning => {
            try stderr.print("a runner is already attached to {s}; use stako stop {s} first\n", .{ name, name });
            return 2;
        },
        error.SessionConflict => {
            try stderr.print("a foreign zellij session named {s} exists; rename it or remove it\n", .{name});
            return 2;
        },
        else => return e,
    };
    try stdout.print("stack {s} idle\n", .{stack.name});
    return 0;
}

fn cmdStop(gpa: std.mem.Allocator, args: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) Error!u8 {
    var opts: Options = .{};
    var name: []const u8 = "";
    if (!try parseStackArgs(args, &name, &opts, stderr)) return 2;
    const root = try paths.resolveNotesRoot(gpa, rootOrDefault(opts.root));
    defer gpa.free(root);
    var stack = runtime.Stack.open(gpa, root, name) catch |e| switch (e) {
        error.NotFound => {
            try stderr.print("no such stack: {s}\n", .{name});
            return 2;
        },
        else => return e,
    };
    defer stack.deinit();

    const info = (try stack.readRunnerPid()) orelse {
        try stderr.print("no runner recorded for {s}\n", .{name});
        return 2;
    };
    if (!runtime.pidAlive(info.pid)) {
        stack.removeRunnerPid();
        try stdout.print("runner for {s} was already gone (cleared stale pid {d})\n", .{ name, info.pid });
        return 0;
    }
    if (!runtime.pidIsRunnerFor(info.pid, name)) {
        try stderr.print("pid {d} does not look like the {s} runner; refusing to signal it\n", .{ info.pid, name });
        return 2;
    }
    try std.posix.kill(@intCast(info.pid), std.posix.SIG.TERM);
    try stdout.print("sent stop to {s} runner (pid {d})\n", .{ name, info.pid });
    return 0;
}

fn cmdAttach(gpa: std.mem.Allocator, args: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) Error!u8 {
    _ = stdout;
    var opts: Options = .{};
    var name: []const u8 = "";
    if (!try parseStackArgs(args, &name, &opts, stderr)) return 2;
    const argv = [_][]const u8{ "zellij", "attach", name };
    var child = std.process.Child.init(&argv, gpa);
    try child.spawn();
    const term = try child.wait();
    return switch (term) {
        .Exited => |code| code,
        else => 1,
    };
}

fn cmdOutput(gpa: std.mem.Allocator, args: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) Error!u8 {
    if (args.len < 2) {
        try stderr.writeAll("usage: stako output <stack> <node> [--snapshot] [--root PATH]\n");
        return 2;
    }
    var opts: Options = .{};
    const name = args[0];
    const node_name = args[1];
    if (!try parseFlags(args[2..], &opts, stderr)) return 2;
    const root = try paths.resolveNotesRoot(gpa, rootOrDefault(opts.root));
    defer gpa.free(root);
    var stack = runtime.Stack.open(gpa, root, name) catch |e| switch (e) {
        error.NotFound => {
            try stderr.print("no such stack: {s}\n", .{name});
            return 2;
        },
        else => return e,
    };
    defer stack.deinit();
    const node = stack.plan.nodeByName(node_name) orelse {
        try stderr.print("no such node: {s}\n", .{node_name});
        return 2;
    };
    if (!opts.snapshot and (try stack.nodeStatus(node_name)) == .running) {
        var adapter = zellij.CommandAdapter{ .allocator = gpa };
        if (adapter.findThreadPane(stack.name, node.thread)) |pane| {
            defer {
                gpa.free(pane.tab_id);
                gpa.free(pane.pane_id);
            }
            const dump = adapter.dumpPane(stack.name, pane.pane_id) catch null;
            if (dump) |text| {
                defer gpa.free(text);
                try stack.storeOutput(node_name, text);
                try stdout.writeAll(text);
                return 0;
            }
        }
        try stderr.writeAll("note: no live pane available; showing stored output snapshot\n");
    }
    const out = try stack.readRunFileAlloc(gpa, node_name, "output.md");
    defer gpa.free(out);
    try stdout.writeAll(out);
    return 0;
}

// ---------- recovery ----------

fn cmdRedeliver(gpa: std.mem.Allocator, args: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) Error!u8 {
    if (args.len < 2) {
        try stderr.writeAll("usage: stako redeliver <stack> <node> [--force] [--root P]\n");
        return 2;
    }
    var opts: Options = .{};
    const name = args[0];
    const node_name = args[1];
    if (!try parseFlags(args[2..], &opts, stderr)) return 2;
    const root = try paths.resolveNotesRoot(gpa, rootOrDefault(opts.root));
    defer gpa.free(root);
    var stack = runtime.Stack.open(gpa, root, name) catch |e| switch (e) {
        error.NotFound => {
            try stderr.print("no such stack: {s}\n", .{name});
            return 2;
        },
        else => return e,
    };
    defer stack.deinit();
    const node = stack.plan.nodeByName(node_name) orelse {
        try stderr.print("no such node: {s}\n", .{node_name});
        return 2;
    };
    if (!opts.force and (try stack.nodeStatus(node_name)) == .completed) {
        try stderr.print("{s} is completed; pass --force to redeliver and overwrite its result\n", .{node_name});
        return 2;
    }
    var adapter = zellij.CommandAdapter{ .allocator = gpa };
    var rt = zellij.PlanRuntime(zellij.CommandAdapter){ .gpa = gpa, .adapter = &adapter };
    defer rt.deinit();
    try rt.startStack(&stack);
    rt.deliver(&stack, node) catch |e| switch (e) {
        error.MissingThreadPane, error.CommandFailed, error.SpawnFailed, error.MissingUse => {
            try stderr.print("could not deliver {s}: {s}\n", .{ node_name, deliveryErrorName(e) });
            return 2;
        },
        else => return e,
    };
    try stdout.print("redelivered {s}\n", .{node_name});
    return 0;
}

fn deliveryErrorName(e: Error) []const u8 {
    return switch (e) {
        error.MissingThreadPane => "missing_thread_pane",
        error.CommandFailed => "zellij_deliver_failed",
        error.SpawnFailed => "zellij_spawn_failed",
        error.MissingUse => "missing_use",
        else => unreachable,
    };
}

fn cmdComplete(gpa: std.mem.Allocator, args: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) Error!u8 {
    if (args.len < 2) {
        try stderr.writeAll("usage: stako complete <stack> <node> [--result FILE] [--root P]\n       (reads result from stdin when --result is omitted)\n");
        return 2;
    }
    const name = args[0];
    const node_name = args[1];
    var root: []const u8 = "";
    var result_file: []const u8 = "";
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (try flagValue(args, &i, a, "--root")) |v| {
            root = v;
        } else if (try flagValue(args, &i, a, "--result")) |v| {
            result_file = v;
        } else {
            try stderr.print("unexpected argument: {s}\n", .{a});
            return 2;
        }
    }
    const root_resolved = try paths.resolveNotesRoot(gpa, rootOrDefault(root));
    defer gpa.free(root_resolved);
    var stack = runtime.Stack.open(gpa, root_resolved, name) catch |e| switch (e) {
        error.NotFound => {
            try stderr.print("no such stack: {s}\n", .{name});
            return 2;
        },
        else => return e,
    };
    defer stack.deinit();
    if (stack.plan.nodeByName(node_name) == null) {
        try stderr.print("no such node: {s}\n", .{node_name});
        return 2;
    }

    const result_text = if (result_file.len != 0)
        readPathAlloc(gpa, result_file) catch {
            try stderr.print("cannot read result file: {s}\n", .{result_file});
            return 2;
        }
    else
        try readStdinAlloc(gpa);
    defer gpa.free(result_text);

    try stack.storeResult(node_name, result_text);
    try stack.storeCompletion(node_name);
    const result_rel = try std.fmt.allocPrint(gpa, "runs/{s}/result.md", .{node_name});
    defer gpa.free(result_rel);
    switch (status.classifyResult(result_text).status) {
        .completed => try stack.appendEvent(.{ .event = .completed, .node = node_name, .result = result_rel }),
        .blocked => try stack.appendEvent(.{ .event = .blocked, .node = node_name, .reason = "result_blocked" }),
        .failed => try stack.appendEvent(.{ .event = .failed, .node = node_name, .reason = "result_failed" }),
        else => unreachable,
    }
    try stdout.print("recorded result for {s} ({d} bytes)\n", .{ node_name, result_text.len });
    return 0;
}

fn cmdReset(gpa: std.mem.Allocator, args: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) Error!u8 {
    if (args.len < 2) {
        try stderr.writeAll("usage: stako reset <stack> <node> [--root P]\n");
        return 2;
    }
    var opts: Options = .{};
    const name = args[0];
    const node_name = args[1];
    if (!try parseFlags(args[2..], &opts, stderr)) return 2;
    const root = try paths.resolveNotesRoot(gpa, rootOrDefault(opts.root));
    defer gpa.free(root);
    var stack = runtime.Stack.open(gpa, root, name) catch |e| switch (e) {
        error.NotFound => {
            try stderr.print("no such stack: {s}\n", .{name});
            return 2;
        },
        else => return e,
    };
    defer stack.deinit();
    stack.resetNode(node_name) catch |e| switch (e) {
        error.UnknownTarget => {
            try stderr.print("no such node: {s}\n", .{node_name});
            return 2;
        },
        else => return e,
    };
    try stdout.print("reset {s} (queued; a running runner will re-deliver it)\n", .{node_name});
    return 0;
}

// ---------- planner ----------

const Resolved = struct {
    gpa: std.mem.Allocator,
    name: []u8,
    root: []u8,
    agent_cwd: []u8,
    prompt_folder: []u8,
    plan_text: []u8,

    fn deinit(self: *Resolved) void {
        self.gpa.free(self.name);
        self.gpa.free(self.root);
        self.gpa.free(self.agent_cwd);
        self.gpa.free(self.prompt_folder);
        self.gpa.free(self.plan_text);
    }
};

/// Resolve a prompt folder into the stack name, path roles, and plan text,
/// validating the graph. CLI flags override plan-header values, which override
/// inference. This is the shared dry-run path behind `plan` and `new`.
fn resolvePlanAlloc(gpa: std.mem.Allocator, folder: []const u8, opts: Options) Error!Resolved {
    const folder_abs = std.fs.cwd().realpathAlloc(gpa, folder) catch return error.NotFound;
    errdefer gpa.free(folder_abs);

    const plan_path = try std.fs.path.join(gpa, &.{ folder_abs, "plan.toml" });
    defer gpa.free(plan_path);
    const plan_text = readPathAlloc(gpa, plan_path) catch return error.NotFound;
    errdefer gpa.free(plan_text);

    var p = try plan.parse(gpa, plan_text);
    defer p.deinit();
    try plan.validate(&p, gpa);

    const name_src = if (opts.name.len != 0) opts.name else if (p.header.name.len != 0) p.header.name else std.fs.path.basename(folder_abs);
    if (!plan.isValidName(name_src)) return error.InvalidName;
    const name = try gpa.dupe(u8, name_src);
    errdefer gpa.free(name);

    const root_src = if (opts.root.len != 0) opts.root else if (p.header.root.len != 0) p.header.root else paths.DEFAULT_NOTES_ROOT;
    const root = try paths.resolveNotesRoot(gpa, root_src);
    errdefer gpa.free(root);

    const agent_cwd = try resolveAgentCwdAlloc(gpa, folder_abs, p.header.cwd, opts.cwd);
    errdefer gpa.free(agent_cwd);

    return .{ .gpa = gpa, .name = name, .root = root, .agent_cwd = agent_cwd, .prompt_folder = folder_abs, .plan_text = plan_text };
}

fn resolveAgentCwdAlloc(gpa: std.mem.Allocator, folder_abs: []const u8, header_cwd: []const u8, flag_cwd: []const u8) Error![]u8 {
    // Caller owns returned memory.
    if (flag_cwd.len != 0) return std.fs.cwd().realpathAlloc(gpa, flag_cwd) catch return error.NotFound;
    if (header_cwd.len != 0) return resolveAgainstAlloc(gpa, folder_abs, header_cwd);
    if (try inferGitRootAlloc(gpa, folder_abs)) |git| return git;
    return gpa.dupe(u8, folder_abs);
}

fn resolveAgainstAlloc(gpa: std.mem.Allocator, base_abs: []const u8, path: []const u8) Error![]u8 {
    // Caller owns returned memory.
    if (std.fs.path.isAbsolute(path)) return std.fs.cwd().realpathAlloc(gpa, path) catch return error.NotFound;
    const joined = try std.fs.path.join(gpa, &.{ base_abs, path });
    defer gpa.free(joined);
    return std.fs.cwd().realpathAlloc(gpa, joined) catch return error.NotFound;
}

/// Walk up from `start` looking for a `.git` entry; return the worktree root.
fn inferGitRootAlloc(gpa: std.mem.Allocator, start: []const u8) Error!?[]u8 {
    // Caller owns returned memory.
    var current: []const u8 = start;
    while (true) {
        const git = try std.fs.path.join(gpa, &.{ current, ".git" });
        defer gpa.free(git);
        if (std.fs.cwd().access(git, .{})) |_| {
            return try gpa.dupe(u8, current);
        } else |_| {}
        const parent = std.fs.path.dirname(current) orelse break;
        if (parent.len >= current.len) break;
        current = parent;
    }
    return null;
}

fn reportResolveError(e: Error, folder: []const u8, stderr: *std.Io.Writer) Error!u8 {
    switch (e) {
        error.NotFound => {
            try stderr.print("cannot read plan.toml under: {s}\n", .{folder});
            return 2;
        },
        error.InvalidName => {
            try stderr.writeAll("stack name is not a valid identifier; pass --name\n");
            return 2;
        },
        else => return e,
    }
}

// ---------- argument parsing ----------

fn parsePlanArgs(args: []const []const u8, folder: *[]const u8, opts: *Options, stderr: *std.Io.Writer) Error!bool {
    if (args.len == 0) {
        try stderr.writeAll("usage: stako plan <prompt-folder> [--name N] [--root P] [--cwd P] [--json]\n");
        return false;
    }
    folder.* = args[0];
    return parseFlags(args[1..], opts, stderr);
}

fn parseNewArgs(args: []const []const u8, positional: *[]const u8, opts: *Options, stderr: *std.Io.Writer) Error!bool {
    if (args.len == 0) {
        try stderr.writeAll("usage: stako new <prompt-folder> [--name N] [--root P] [--cwd P]\n       stako new <name> --from <prompt-folder>\n");
        return false;
    }
    positional.* = args[0];
    return parseFlags(args[1..], opts, stderr);
}

fn parseStackArgs(args: []const []const u8, name: *[]const u8, opts: *Options, stderr: *std.Io.Writer) Error!bool {
    if (args.len == 0) {
        try stderr.writeAll("usage: stako <command> <stack> [--root PATH] [--json]\n");
        return false;
    }
    name.* = args[0];
    return parseFlags(args[1..], opts, stderr);
}

fn parseFlags(args: []const []const u8, opts: *Options, stderr: *std.Io.Writer) Error!bool {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (try flagValue(args, &i, a, "--name")) |v| {
            opts.name = v;
        } else if (try flagValue(args, &i, a, "--root")) |v| {
            opts.root = v;
        } else if (try flagValue(args, &i, a, "--cwd")) |v| {
            opts.cwd = v;
        } else if (try flagValue(args, &i, a, "--from")) |v| {
            opts.from = v;
        } else if (std.mem.eql(u8, a, "--json")) {
            opts.json = true;
        } else if (std.mem.eql(u8, a, "--watch")) {
            opts.watch = true;
        } else if (std.mem.eql(u8, a, "--force")) {
            opts.force = true;
        } else if (std.mem.eql(u8, a, "--snapshot")) {
            opts.snapshot = true;
        } else {
            try stderr.print("unexpected argument: {s}\n", .{a});
            return false;
        }
    }
    return true;
}

/// Append each non-empty, comma-separated, trimmed item of `csv` to `list`. The
/// item slices borrow from `csv`, so they live as long as the argv does.
fn appendCsv(gpa: std.mem.Allocator, list: *std.ArrayList([]const u8), csv: []const u8) Error!void {
    var it = std.mem.splitScalar(u8, csv, ',');
    while (it.next()) |part| {
        const t = std.mem.trim(u8, part, " \t");
        if (t.len != 0) try list.append(gpa, t);
    }
}

/// Match `--flag VALUE` or `--flag=VALUE`; advances `i` past a separate value.
fn flagValue(args: []const []const u8, i: *usize, arg: []const u8, flag: []const u8) Error!?[]const u8 {
    if (std.mem.eql(u8, arg, flag)) {
        if (i.* + 1 >= args.len) return error.Usage;
        i.* += 1;
        return args[i.*];
    }
    if (arg.len > flag.len + 1 and std.mem.startsWith(u8, arg, flag) and arg[flag.len] == '=') {
        return arg[flag.len + 1 ..];
    }
    return null;
}

// ---------- helpers ----------

fn rootOrDefault(root: []const u8) []const u8 {
    return if (root.len != 0) root else paths.DEFAULT_NOTES_ROOT;
}

/// True if absolute path `inner` is `outer` or lies beneath it. Used only for a
/// best-effort sandbox warning, so it is a lexical check, not a realpath one.
fn pathInside(inner: []const u8, outer: []const u8) bool {
    if (outer.len == 0) return true;
    if (!std.mem.startsWith(u8, inner, outer)) return false;
    return inner.len == outer.len or inner[outer.len] == '/' or std.mem.endsWith(u8, outer, "/");
}

fn runningNode(stack: *const runtime.Stack, statuses: []const status.Status, thread: []const u8) ?[]const u8 {
    for (stack.plan.nodes, 0..) |n, i| {
        if (statuses[i] == .running and std.mem.eql(u8, n.thread, thread)) return n.name;
    }
    return null;
}

fn statusOfNode(stack: *const runtime.Stack, statuses: []const status.Status, name: []const u8) ?status.Status {
    for (stack.plan.nodes, 0..) |n, i| {
        if (std.mem.eql(u8, n.name, name)) return statuses[i];
    }
    return null;
}

fn jsonString(w: *std.Io.Writer, s: []const u8) Error!void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        else => if (c < 0x20) try w.print("\\u{x:0>4}", .{c}) else try w.writeByte(c),
    };
    try w.writeByte('"');
}

fn readStdinAlloc(gpa: std.mem.Allocator) Error![]u8 {
    // Caller owns returned memory.
    var buf: [4096]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&buf);
    return stdin_reader.interface.allocRemaining(gpa, .limited(16 * 1024 * 1024)) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NotFound,
    };
}

fn readPathAlloc(gpa: std.mem.Allocator, path: []const u8) Error![]u8 {
    // Caller owns returned memory.
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const stat = try file.stat();
    const buf = try gpa.alloc(u8, stat.size);
    errdefer gpa.free(buf);
    const n = try file.readAll(buf);
    // If the file shrank between stat and read, trim to the bytes read so no
    // uninitialized tail leaks into parsed input.
    if (n != buf.len) return gpa.realloc(buf, n);
    return buf;
}

fn isHelpArg(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help");
}

fn overview(w: *std.Io.Writer) Error!void {
    try w.writeAll(
        \\usage:
        \\  stako help
        \\  stako plan <prompt-folder> [--name N] [--root P] [--cwd P] [--json]
        \\  stako new <prompt-folder> [--name N] [--root P] [--cwd P]
        \\  stako new <name> --from <prompt-folder> [--root P] [--cwd P]
        \\  stako status <stack> [--root P] [--json]
        \\  stako render <stack> <node> [--root P]
        \\  stako inject <stack> <node> --thread T [--body B|--use F] [--with f1,f2] [--gate target] [--root P]
        \\  stako link <stack> <source-node> <target-node> [--root P]
        \\  stako start <stack> [--watch] [--root P]
        \\  stako stop <stack> [--root P]
        \\  stako attach <stack>
        \\  stako output <stack> <node> [--snapshot] [--root P]
        \\  stako redeliver <stack> <node> [--force] [--root P]
        \\  stako complete <stack> <node> [--result FILE] [--root P]
        \\  stako reset <stack> <node> [--root P]
        \\
        \\A stack is one plan.toml graph: threads run prompts, and the only edge is
        \\blocked_by. `plan` validates and previews a prompt folder; `new` normalizes
        \\it into <root>/stacks/<name>/plan.toml. `start` delivers ready prompts and,
        \\with --watch, stays resident and picks up injects/resets live; `stop` ends a
        \\watch runner. Status is computed from run markers and events.jsonl;
        \\redeliver/complete/reset recover a wedged node.
        \\
    );
}

fn sleepOneSecond() void {
    std.Thread.sleep(std.time.ns_per_s);
}

// ---------- tests ----------

test "appendCsv splits, trims, and drops empty items" {
    const a = std.testing.allocator;
    var list: std.ArrayList([]const u8) = .empty;
    defer list.deinit(a);
    try appendCsv(a, &list, " a , b ,,c");
    try std.testing.expectEqual(@as(usize, 3), list.items.len);
    try std.testing.expectEqualStrings("a", list.items[0]);
    try std.testing.expectEqualStrings("b", list.items[1]);
    try std.testing.expectEqualStrings("c", list.items[2]);
    // A repeated flag accumulates; an empty value contributes nothing.
    try appendCsv(a, &list, "");
    try std.testing.expectEqual(@as(usize, 3), list.items.len);
}

test "pathInside detects a root beneath the agent cwd" {
    try std.testing.expect(pathInside("/work/repo/stacks/x", "/work/repo"));
    try std.testing.expect(pathInside("/work/repo", "/work/repo"));
    try std.testing.expect(!pathInside("/other/place", "/work/repo"));
    try std.testing.expect(!pathInside("/work/repo-sibling", "/work/repo"));
}

test "plan and new resolve a folder, then status reports computed state" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath("folder");
    try tmp.dir.makePath("root");
    try tmp.dir.makePath("work");
    const plan_data =
        \\[[thread]]
        \\name = "impl"
        \\command = "codex"
        \\
        \\[[prompt]]
        \\name = "impl-1"
        \\thread = "impl"
        \\body = "Do it."
        \\
        \\[[prompt]]
        \\name = "review-1"
        \\thread = "impl"
        \\body = "Check it."
        \\blocked_by = ["impl-1"]
        \\
    ;
    try tmp.dir.writeFile(.{ .sub_path = "folder/plan.toml", .data = plan_data });
    const folder = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/folder", .{&tmp.sub_path});
    defer a.free(folder);
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/root", .{&tmp.sub_path});
    defer a.free(root);
    const work = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/work", .{&tmp.sub_path});
    defer a.free(work);

    var out_buf: [4096]u8 = undefined;
    var err_buf: [1024]u8 = undefined;

    // plan: dry run, writes nothing, names the stack from the folder basename.
    {
        var stdout: std.Io.Writer = .fixed(&out_buf);
        var stderr: std.Io.Writer = .fixed(&err_buf);
        const code = try dispatch(a, &.{ "plan", folder, "--root", root, "--cwd", work }, &stdout, &stderr);
        try std.testing.expectEqual(@as(u8, 0), code);
        const text = stdout.buffered();
        try std.testing.expect(std.mem.indexOf(u8, text, "stack name: folder") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "blocked_by=impl-1") != null);
    }

    // new: create the stack under root.
    {
        var stdout: std.Io.Writer = .fixed(&out_buf);
        var stderr: std.Io.Writer = .fixed(&err_buf);
        const code = try dispatch(a, &.{ "new", folder, "--root", root, "--cwd", work }, &stdout, &stderr);
        try std.testing.expectEqual(@as(u8, 0), code);
    }

    // status: review-1 waits on impl-1, impl-1 is ready.
    {
        var stdout: std.Io.Writer = .fixed(&out_buf);
        var stderr: std.Io.Writer = .fixed(&err_buf);
        const code = try dispatch(a, &.{ "status", "folder", "--root", root }, &stdout, &stderr);
        try std.testing.expectEqual(@as(u8, 0), code);
        const text = stdout.buffered();
        try std.testing.expect(std.mem.indexOf(u8, text, "impl-1 thread=impl status=queued (ready)") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "review-1 thread=impl status=queued waiting=impl-1") != null);
    }
}
