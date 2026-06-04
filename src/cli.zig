const std = @import("std");
const paths = @import("paths.zig");
const prompt_mod = @import("prompt.zig");
const store = @import("store.zig");
const zellij = @import("zellij.zig");

pub const Error = error{
    Usage,
    OutOfMemory,
} || paths.Error || store.Error || zellij.Error || std.Io.Writer.Error || std.fs.Dir.MakeError || std.process.Child.SpawnError || std.process.Child.WaitError;

const Options = struct {
    root: []const u8 = paths.DEFAULT_NOTES_ROOT,
    command: []const u8 = "codex",
    cwd: []const u8 = "",
};

pub fn dispatch(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) Error!u8 {
    if (args.len == 0) {
        try usage(stderr);
        return 2;
    }

    const cmd = args[0];
    if (std.mem.eql(u8, cmd, "new")) return try cmdNew(allocator, args[1..], stdout, stderr);
    if (std.mem.eql(u8, cmd, "add")) return try cmdAdd(allocator, args[1..], stdout, stderr);
    if (std.mem.eql(u8, cmd, "link")) return try cmdLink(allocator, args[1..], stdout, stderr);
    if (std.mem.eql(u8, cmd, "start")) return try cmdStart(allocator, args[1..], stdout, stderr);
    if (std.mem.eql(u8, cmd, "attach")) return try cmdAttach(allocator, args[1..], stdout, stderr);
    if (std.mem.eql(u8, cmd, "status")) return try cmdStatus(allocator, args[1..], stdout, stderr);
    if (std.mem.eql(u8, cmd, "output")) return try cmdOutput(allocator, args[1..], stdout, stderr);

    try stderr.print("unknown command: {s}\n", .{cmd});
    try usage(stderr);
    return 2;
}

fn cmdLink(allocator: std.mem.Allocator, args: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) Error!u8 {
    if (args.len < 2) {
        try usage(stderr);
        return 2;
    }
    const source_path = args[0];
    const target_path = args[1];
    var action: prompt_mod.Action = .none;
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--pre-cmd")) {
            i += 1;
            if (i >= args.len) return error.Usage;
            action = try prompt_mod.Action.parse(args[i]);
        } else if (std.mem.startsWith(u8, a, "--pre-cmd=")) {
            action = try prompt_mod.Action.parse(a["--pre-cmd=".len..]);
        } else {
            return error.Usage;
        }
    }

    const source_src = try readPathAlloc(allocator, source_path);
    defer allocator.free(source_src);
    var source = try prompt_mod.parsePromptFile(allocator, source_src);
    defer source.deinit();

    const target_src = try readPathAlloc(allocator, target_path);
    defer allocator.free(target_src);
    var target = try prompt_mod.parsePromptFile(allocator, target_src);
    defer target.deinit();

    const linked = try renderLinkedPromptAlloc(allocator, &target, source.id, action);
    defer allocator.free(linked);
    try std.fs.cwd().writeFile(.{ .sub_path = target_path, .data = linked });
    try stdout.print("linked {s} -> {s} action={s}\n", .{ source.id, target.id, actionName(action) });
    return 0;
}

fn cmdNew(allocator: std.mem.Allocator, args: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) Error!u8 {
    if (args.len == 0) {
        try usage(stderr);
        return 2;
    }
    var opts: Options = .{};
    const name = args[0];
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--root")) {
            i += 1;
            if (i >= args.len) return error.Usage;
            opts.root = args[i];
        } else if (std.mem.startsWith(u8, a, "--root=")) {
            opts.root = a["--root=".len..];
        } else if (std.mem.eql(u8, a, "--command")) {
            i += 1;
            if (i >= args.len) return error.Usage;
            opts.command = args[i];
        } else if (std.mem.startsWith(u8, a, "--command=")) {
            opts.command = a["--command=".len..];
        } else if (std.mem.eql(u8, a, "--cwd")) {
            i += 1;
            if (i >= args.len) return error.Usage;
            opts.cwd = args[i];
        } else if (std.mem.startsWith(u8, a, "--cwd=")) {
            opts.cwd = a["--cwd=".len..];
        } else {
            return error.Usage;
        }
    }

    // A stack's cwd is the directory its agent threads launch in. Resolve it to
    // an absolute, existing path now so every thread tab is independent of where
    // `stako start` later runs.
    var cwd_abs: []const u8 = "";
    if (opts.cwd.len != 0) {
        cwd_abs = std.fs.cwd().realpathAlloc(allocator, opts.cwd) catch {
            try stderr.print("cannot resolve --cwd path: {s}\n", .{opts.cwd});
            return 2;
        };
    }
    defer if (cwd_abs.len != 0) allocator.free(cwd_abs);

    const root = try paths.resolveNotesRoot(allocator, opts.root);
    defer allocator.free(root);
    try std.fs.cwd().makePath(root);
    var stack = try store.Stack.create(allocator, root, name, opts.command, cwd_abs);
    defer stack.deinit();
    if (cwd_abs.len != 0) {
        try stdout.print("created stack {s} command={s} cwd={s}\n", .{ name, opts.command, cwd_abs });
    } else {
        try stdout.print("created stack {s} command={s}\n", .{ name, opts.command });
    }
    return 0;
}

fn cmdAdd(allocator: std.mem.Allocator, args: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) Error!u8 {
    if (args.len < 2) {
        try usage(stderr);
        return 2;
    }
    var opts: Options = .{};
    const name = args[0];
    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(allocator);
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--root")) {
            i += 1;
            if (i >= args.len) return error.Usage;
            opts.root = args[i];
        } else if (std.mem.startsWith(u8, a, "--root=")) {
            opts.root = a["--root=".len..];
        } else {
            try files.append(allocator, a);
        }
    }
    if (files.items.len == 0) return error.Usage;
    const root = try paths.resolveNotesRoot(allocator, opts.root);
    defer allocator.free(root);
    var stack = try store.Stack.open(allocator, root, name);
    defer stack.deinit();
    const reports = try stack.addFiles(files.items);
    defer stack.freeReports(reports);
    for (reports) |r| {
        try stdout.print("{s}: {s} ({s})\n", .{ r.id, r.status.name(), dispositionName(r.disposition) });
    }
    return 0;
}

fn cmdStart(allocator: std.mem.Allocator, args: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) Error!u8 {
    const parsed = try parseStackOnly(args, stderr);
    if (parsed.name.len == 0) return 2;
    const root = try paths.resolveNotesRoot(allocator, parsed.opts.root);
    defer allocator.free(root);
    var stack = try store.Stack.open(allocator, root, parsed.name);
    defer stack.deinit();
    var adapter = zellij.CommandAdapter{ .allocator = allocator };
    var runtime = zellij.Runtime(zellij.CommandAdapter){ .allocator = allocator, .adapter = &adapter };
    try runtime.runUntilIdle(&stack, sleepOneSecond);
    try stdout.print("stack {s} idle\n", .{stack.name});
    return 0;
}

fn cmdAttach(allocator: std.mem.Allocator, args: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) Error!u8 {
    _ = stdout;
    const parsed = try parseStackOnly(args, stderr);
    if (parsed.name.len == 0) return 2;
    const argv = [_][]const u8{ "zellij", "attach", parsed.name };
    var child = std.process.Child.init(&argv, allocator);
    try child.spawn();
    const term = try child.wait();
    return switch (term) {
        .Exited => |code| code,
        else => 1,
    };
}

fn cmdStatus(allocator: std.mem.Allocator, args: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) Error!u8 {
    const parsed = try parseStackOnly(args, stderr);
    if (parsed.name.len == 0) return 2;
    const root = try paths.resolveNotesRoot(allocator, parsed.opts.root);
    defer allocator.free(root);
    var stack = try store.Stack.open(allocator, root, parsed.name);
    defer stack.deinit();
    if (stack.cwd.len != 0) {
        try stdout.print("stack {s} command={s} cwd={s}\n", .{ stack.name, stack.command, stack.cwd });
    } else {
        try stdout.print("stack {s} command={s}\n", .{ stack.name, stack.command });
    }
    const threads = try stack.listThreads();
    defer stack.freeThreads(threads);
    for (threads) |thread| {
        const command = if (thread.command.len != 0) thread.command else stack.command;
        try stdout.print("thread {s} status={s} command={s} pane={s}\n", .{ thread.name, thread.status.name(), command, thread.pane_id });
    }
    const runs = try stack.listRuns();
    defer stack.freeRuns(runs);
    for (runs) |run| {
        try stdout.print("prompt {s} thread={s} status={s}\n", .{ run.id, run.thread, run.status.name() });
    }
    return 0;
}

fn cmdOutput(allocator: std.mem.Allocator, args: []const []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) Error!u8 {
    if (args.len < 2) {
        try usage(stderr);
        return 2;
    }
    var opts: Options = .{};
    const name = args[0];
    const id = args[1];
    var i: usize = 2;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--root")) {
            i += 1;
            if (i >= args.len) return error.Usage;
            opts.root = args[i];
        } else if (std.mem.startsWith(u8, a, "--root=")) {
            opts.root = a["--root=".len..];
        } else {
            return error.Usage;
        }
    }
    const root = try paths.resolveNotesRoot(allocator, opts.root);
    defer allocator.free(root);
    var stack = try store.Stack.open(allocator, root, name);
    defer stack.deinit();
    var run = try stack.readRun(id);
    defer run.deinit();
    try stdout.print("{s}", .{run.output});
    return 0;
}

const ParsedStack = struct {
    name: []const u8 = "",
    opts: Options = .{},
};

fn parseStackOnly(args: []const []const u8, stderr: *std.Io.Writer) Error!ParsedStack {
    if (args.len == 0) {
        try usage(stderr);
        return .{};
    }
    var out: ParsedStack = .{ .name = args[0] };
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--root")) {
            i += 1;
            if (i >= args.len) return error.Usage;
            out.opts.root = args[i];
        } else if (std.mem.startsWith(u8, a, "--root=")) {
            out.opts.root = a["--root=".len..];
        } else {
            return error.Usage;
        }
    }
    return out;
}

fn dispositionName(d: store.EnqueueDisposition) []const u8 {
    return switch (d) {
        .inserted => "inserted",
        .updated => "updated",
        .existing => "existing",
    };
}

fn actionName(action: prompt_mod.Action) []const u8 {
    return switch (action) {
        .none => "none",
        .new => "new",
        .clear => "clear",
        .compact => "compact",
    };
}

fn readPathAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    // Caller owns returned memory.
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const stat = try file.stat();
    const buf = try allocator.alloc(u8, stat.size);
    errdefer allocator.free(buf);
    _ = try file.readAll(buf);
    return buf;
}

fn renderLinkedPromptAlloc(allocator: std.mem.Allocator, target: *const prompt_mod.PromptFile, source_id: []const u8, action: prompt_mod.Action) ![]u8 {
    // Caller owns returned memory.
    const after = try withUniqueAlloc(allocator, target.after, source_id);
    defer freeStringArray(allocator, after);
    const inputs = try withUniqueAlloc(allocator, target.inputs, source_id);
    defer freeStringArray(allocator, inputs);

    var after_buf: std.ArrayList(u8) = .empty;
    defer after_buf.deinit(allocator);
    try writeStringArray(allocator, &after_buf, after);
    var inputs_buf: std.ArrayList(u8) = .empty;
    defer inputs_buf.deinit(allocator);
    try writeStringArray(allocator, &inputs_buf, inputs);

    return std.fmt.allocPrint(allocator,
        \\+++
        \\id = "{s}"
        \\thread = "{s}"
        \\action = "{s}"
        \\after = {s}
        \\inputs = {s}
        \\+++
        \\
        \\{s}
        \\
    , .{ target.id, target.thread, actionName(action), after_buf.items, inputs_buf.items, target.body });
}

fn withUniqueAlloc(allocator: std.mem.Allocator, values: []const []const u8, extra: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |value| allocator.free(value);
        out.deinit(allocator);
    }
    var found = false;
    for (values) |value| {
        if (std.mem.eql(u8, value, extra)) found = true;
        try out.append(allocator, try allocator.dupe(u8, value));
    }
    if (!found) try out.append(allocator, try allocator.dupe(u8, extra));
    return out.toOwnedSlice(allocator);
}

fn freeStringArray(allocator: std.mem.Allocator, values: []const []const u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

fn writeStringArray(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), values: []const []const u8) !void {
    try buf.append(allocator, '[');
    for (values, 0..) |value, i| {
        if (i != 0) try buf.appendSlice(allocator, ", ");
        try buf.append(allocator, '"');
        try buf.appendSlice(allocator, value);
        try buf.append(allocator, '"');
    }
    try buf.append(allocator, ']');
}

fn usage(w: *std.Io.Writer) !void {
    try w.print(
        \\usage:
        \\  stako new <stack> [--command codex] [--cwd PATH] [--root PATH]
        \\  stako add <stack> <thread-or-prompt.md...> [--root PATH]
        \\  stako link <source-prompt.md> <target-prompt.md> [--pre-cmd compact]
        \\  stako start <stack> [--root PATH]
        \\  stako attach <stack>
        \\  stako status <stack> [--root PATH]
        \\  stako output <stack> <prompt-id> [--root PATH]
        \\
    , .{});
}

fn sleepOneSecond() void {
    std.Thread.sleep(std.time.ns_per_s);
}

test "link rewrites target prompt with after input and pre command" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const review_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/review.md", .{&tmp.sub_path});
    defer a.free(review_path);
    const impl_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/impl.md", .{&tmp.sub_path});
    defer a.free(impl_path);

    try tmp.dir.writeFile(.{ .sub_path = "review.md", .data = 
        \\+++
        \\id = "003-review"
        \\thread = "reviewer"
        \\+++
        \\
        \\Review.
    });
    try tmp.dir.writeFile(.{ .sub_path = "impl.md", .data = 
        \\+++
        \\id = "004-implement"
        \\thread = "builder"
        \\+++
        \\
        \\Address review.
    });

    var stdout_buf: [1024]u8 = undefined;
    var stderr_buf: [1024]u8 = undefined;
    var stdout: std.Io.Writer = .fixed(&stdout_buf);
    var stderr: std.Io.Writer = .fixed(&stderr_buf);
    const code = try dispatch(a, &.{ "link", review_path, impl_path, "--pre-cmd", "compact" }, &stdout, &stderr);
    try std.testing.expectEqual(@as(u8, 0), code);

    const linked_src = try readPathAlloc(a, impl_path);
    defer a.free(linked_src);
    var linked = try prompt_mod.parsePromptFile(a, linked_src);
    defer linked.deinit();
    try std.testing.expectEqual(prompt_mod.Action.compact, linked.action);
    try std.testing.expectEqual(@as(usize, 1), linked.after.len);
    try std.testing.expectEqualStrings("003-review", linked.after[0]);
    try std.testing.expectEqual(@as(usize, 1), linked.inputs.len);
    try std.testing.expectEqualStrings("003-review", linked.inputs[0]);
    try std.testing.expectEqualStrings("Address review.", linked.body);
}
