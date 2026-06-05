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
    std.fs.Dir.MakeError || std.process.Child.SpawnError || std.process.Child.WaitError;

const Options = struct {
    name: []const u8 = "",
    root: []const u8 = "",
    cwd: []const u8 = "",
    from: []const u8 = "",
    json: bool = false,
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
    if (std.mem.eql(u8, cmd, "attach")) return try cmdAttach(allocator, args[1..], stdout, stderr);
    if (std.mem.eql(u8, cmd, "output")) return try cmdOutput(allocator, args[1..], stdout, stderr);

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

fn printStatusText(w: *std.Io.Writer, stack: *const runtime.Stack, statuses: []const status.Status) Error!void {
    try w.print("stack {s} cwd={s}\n", .{ stack.name, stack.agentCwd() });
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
        }
        try w.writeByte('\n');
    }
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
        try stderr.writeAll("usage: stako inject <stack> <node> --thread T [--body B|--use F] [--action A] [--blocked-by a,b] [--gate target] [--raw] [--root P]\n");
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
    var it = std.mem.splitScalar(u8, blocked_csv, ',');
    while (it.next()) |part| {
        const t = std.mem.trim(u8, part, " \t");
        if (t.len != 0) try blockers.append(gpa, t);
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

    const gate_opt: ?[]const u8 = if (gate.len != 0) gate else null;
    stack.inject(.{
        .name = node_name,
        .thread = thread,
        .action = action,
        .use_path = use,
        .with = &.{},
        .body = body,
        .blocked_by = blockers.items,
        .raw = raw,
    }, gate_opt) catch |e| return reportMutationError(e, stderr);
    if (gate_opt) |g| {
        try stdout.print("injected {s} (gates {s})\n", .{ node_name, g });
    } else {
        try stdout.print("injected {s}\n", .{node_name});
    }
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
    return 0;
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
    try rt.runUntilIdle(&stack, sleepOneSecond);
    try stdout.print("stack {s} idle\n", .{stack.name});
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
        try stderr.writeAll("usage: stako output <stack> <node> [--root PATH]\n");
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
    const out = try stack.readRunFileAlloc(gpa, node_name, "output.md");
    defer gpa.free(out);
    try stdout.writeAll(out);
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
        } else {
            try stderr.print("unexpected argument: {s}\n", .{a});
            return false;
        }
    }
    return true;
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
        \\  stako inject <stack> <node> --thread T [--body B|--use F] [--gate target] [--root P]
        \\  stako link <stack> <source-node> <target-node> [--root P]
        \\  stako start <stack> [--root P]
        \\  stako attach <stack>
        \\  stako output <stack> <node> [--root P]
        \\
        \\A stack is one plan.toml graph: threads run prompts, and the only edge is
        \\blocked_by. `plan` validates and previews a prompt folder; `new` normalizes
        \\it into <root>/stacks/<name>/plan.toml. Status is computed from run markers
        \\and events.jsonl.
        \\
    );
}

fn sleepOneSecond() void {
    std.Thread.sleep(std.time.ns_per_s);
}

// ---------- tests ----------

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
