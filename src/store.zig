const std = @import("std");
const prompt_mod = @import("prompt.zig");
const toml = @import("toml.zig");

pub const Error = error{
    InvalidName,
    NotFound,
    AlreadyExists,
    DuplicatePrompt,
    UnknownThread,
    UnknownDependency,
    DependencyCycle,
    BadRun,
    BadStatus,
    BadAction,
    BadToml,
    OutOfMemory,
} || std.fs.Dir.OpenError || std.fs.Dir.MakeError || std.fs.Dir.WriteFileError || std.fs.File.OpenError || std.fs.File.ReadError || std.fs.File.StatError || prompt_mod.ParseError || toml.ParseError;

pub const ThreadStatus = enum {
    pending,
    ready,
    blocked,

    fn parse(s: []const u8) Error!ThreadStatus {
        if (std.mem.eql(u8, s, "pending")) return .pending;
        if (std.mem.eql(u8, s, "ready")) return .ready;
        if (std.mem.eql(u8, s, "blocked")) return .blocked;
        return error.BadStatus;
    }

    pub fn name(self: ThreadStatus) []const u8 {
        return switch (self) {
            .pending => "pending",
            .ready => "ready",
            .blocked => "blocked",
        };
    }
};

pub const PromptStatus = enum {
    queued,
    running,
    completed,
    blocked,
    failed,

    pub fn parse(s: []const u8) Error!PromptStatus {
        if (std.mem.eql(u8, s, "queued")) return .queued;
        if (std.mem.eql(u8, s, "running")) return .running;
        if (std.mem.eql(u8, s, "completed")) return .completed;
        if (std.mem.eql(u8, s, "blocked")) return .blocked;
        if (std.mem.eql(u8, s, "failed")) return .failed;
        return error.BadStatus;
    }

    pub fn name(self: PromptStatus) []const u8 {
        return switch (self) {
            .queued => "queued",
            .running => "running",
            .completed => "completed",
            .blocked => "blocked",
            .failed => "failed",
        };
    }
};

pub const Thread = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    command: []const u8,
    prompt_body: []const u8,
    tab_id: []const u8 = "",
    pane_id: []const u8 = "",
    status: ThreadStatus = .pending,

    pub fn deinit(self: *Thread) void {
        self.allocator.free(self.name);
        self.allocator.free(self.command);
        self.allocator.free(self.prompt_body);
        self.allocator.free(self.tab_id);
        self.allocator.free(self.pane_id);
    }
};

pub const PromptRun = struct {
    allocator: std.mem.Allocator,
    id: []const u8,
    thread: []const u8,
    action: prompt_mod.Action,
    after: []const []const u8,
    inputs: []const []const u8,
    order: u64,
    status: PromptStatus,
    snapshot: []const u8,
    rendered: []const u8,
    output: []const u8,
    blocked_reason: []const u8 = "",

    pub fn deinit(self: *PromptRun) void {
        self.allocator.free(self.id);
        self.allocator.free(self.thread);
        for (self.after) |dep| self.allocator.free(dep);
        self.allocator.free(self.after);
        for (self.inputs) |input| self.allocator.free(input);
        self.allocator.free(self.inputs);
        self.allocator.free(self.snapshot);
        self.allocator.free(self.rendered);
        self.allocator.free(self.output);
        self.allocator.free(self.blocked_reason);
    }
};

pub const EnqueueDisposition = enum {
    inserted,
    updated,
    existing,
};

pub const EnqueueReport = struct {
    allocator: std.mem.Allocator,
    id: []const u8,
    status: PromptStatus,
    disposition: EnqueueDisposition,

    pub fn deinit(self: *EnqueueReport) void {
        self.allocator.free(self.id);
    }
};

pub const Stack = struct {
    allocator: std.mem.Allocator,
    root: []const u8,
    name: []const u8,
    command: []const u8,
    cwd: []const u8,
    stack_prompt_body: []const u8,

    pub fn create(allocator: std.mem.Allocator, root: []const u8, name: []const u8, command: []const u8, cwd: []const u8) Error!Stack {
        if (!prompt_mod.isValidName(name)) return error.InvalidName;
        var root_dir = try std.fs.cwd().openDir(root, .{});
        defer root_dir.close();
        try root_dir.makePath("stacks");
        const stack_rel = try std.fs.path.join(allocator, &.{ "stacks", name });
        defer allocator.free(stack_rel);
        root_dir.makeDir(stack_rel) catch |e| switch (e) {
            error.PathAlreadyExists => return error.AlreadyExists,
            else => return e,
        };
        var stack_dir = try root_dir.openDir(stack_rel, .{});
        defer stack_dir.close();
        try stack_dir.makePath("threads");
        try stack_dir.makePath("runs");
        try stack_dir.makePath("state");
        var stack_md: std.ArrayList(u8) = .empty;
        defer stack_md.deinit(allocator);
        try stack_md.appendSlice(allocator, "+++\ncommand = ");
        try appendTomlString(allocator, &stack_md, command);
        try stack_md.appendSlice(allocator, "\ncwd = ");
        try appendTomlString(allocator, &stack_md, cwd);
        try stack_md.appendSlice(allocator, "\n+++\n\n");
        try stack_dir.writeFile(.{ .sub_path = "stack.md", .data = stack_md.items });
        try stack_dir.writeFile(.{ .sub_path = "state/zellij-owner", .data = "stako\n" });
        return open(allocator, root, name);
    }

    pub fn open(allocator: std.mem.Allocator, root: []const u8, name: []const u8) Error!Stack {
        if (!prompt_mod.isValidName(name)) return error.InvalidName;
        const stack_path = try stackPathAlloc(allocator, root, name);
        defer allocator.free(stack_path);
        var dir = std.fs.cwd().openDir(stack_path, .{}) catch |e| switch (e) {
            error.FileNotFound, error.NotDir => return error.NotFound,
            else => return e,
        };
        defer dir.close();
        const src = try readFileAlloc(allocator, &dir, "stack.md");
        defer allocator.free(src);
        var parsed = try prompt_mod.parseStackFile(allocator, src);
        errdefer parsed.deinit();
        return .{
            .allocator = allocator,
            .root = try allocator.dupe(u8, root),
            .name = try allocator.dupe(u8, name),
            .command = parsed.command,
            .cwd = parsed.cwd,
            .stack_prompt_body = parsed.body,
        };
    }

    pub fn deinit(self: *Stack) void {
        self.allocator.free(self.root);
        self.allocator.free(self.name);
        self.allocator.free(self.command);
        self.allocator.free(self.cwd);
        self.allocator.free(self.stack_prompt_body);
    }

    pub fn installThreadFile(self: *Stack, path: []const u8) Error!void {
        const src = try readPathAlloc(self.allocator, path);
        defer self.allocator.free(src);
        var parsed = try prompt_mod.parseThreadFile(self.allocator, src);
        defer parsed.deinit();
        try self.writeThread(parsed.thread, parsed.command, parsed.body, "", "", .pending);
    }

    pub fn addFiles(self: *Stack, paths: []const []const u8) Error![]EnqueueReport {
        var prompts: std.ArrayList(prompt_mod.PromptFile) = .empty;
        defer {
            for (prompts.items) |*p| p.deinit();
            prompts.deinit(self.allocator);
        }

        for (paths) |path| {
            const src = try readPathAlloc(self.allocator, path);
            defer self.allocator.free(src);
            if (prompt_mod.parseThreadFile(self.allocator, src)) |thread| {
                var t = thread;
                defer t.deinit();
                try self.writeThread(t.thread, t.command, t.body, "", "", .pending);
                continue;
            } else |e| switch (e) {
                error.BadType, error.MissingId, error.MissingThread => {},
                else => return e,
            }
            try prompts.append(self.allocator, try prompt_mod.parsePromptFile(self.allocator, src));
        }

        try self.validatePromptBatch(prompts.items);

        var reports: std.ArrayList(EnqueueReport) = .empty;
        errdefer {
            for (reports.items) |*r| r.deinit();
            reports.deinit(self.allocator);
        }
        for (prompts.items) |*p| {
            try reports.append(self.allocator, try self.upsertPrompt(p));
        }
        return reports.toOwnedSlice(self.allocator);
    }

    pub fn freeReports(self: *Stack, reports: []EnqueueReport) void {
        for (reports) |*r| {
            var rr = r.*;
            rr.deinit();
        }
        self.allocator.free(reports);
    }

    pub fn listRuns(self: *Stack) Error![]PromptRun {
        var dir = try self.openStackDir(.{ .iterate = true });
        defer dir.close();
        var runs_dir = dir.openDir("runs", .{ .iterate = true }) catch |e| switch (e) {
            error.FileNotFound, error.NotDir => return self.allocator.alloc(PromptRun, 0),
            else => return e,
        };
        defer runs_dir.close();

        var out: std.ArrayList(PromptRun) = .empty;
        errdefer {
            for (out.items) |*run| run.deinit();
            out.deinit(self.allocator);
        }
        var it = runs_dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .directory) continue;
            if (!prompt_mod.isValidName(entry.name)) continue;
            try out.append(self.allocator, try self.readRun(entry.name));
        }
        std.mem.sort(PromptRun, out.items, {}, lessRun);
        return out.toOwnedSlice(self.allocator);
    }

    pub fn freeRuns(self: *Stack, runs: []PromptRun) void {
        for (runs) |*r| {
            var rr = r.*;
            rr.deinit();
        }
        self.allocator.free(runs);
    }

    pub fn listThreads(self: *Stack) Error![]Thread {
        var dir = try self.openStackDir(.{ .iterate = true });
        defer dir.close();
        var threads_dir = dir.openDir("threads", .{ .iterate = true }) catch |e| switch (e) {
            error.FileNotFound, error.NotDir => return self.allocator.alloc(Thread, 0),
            else => return e,
        };
        defer threads_dir.close();

        var out: std.ArrayList(Thread) = .empty;
        errdefer {
            for (out.items) |*t| t.deinit();
            out.deinit(self.allocator);
        }
        var it = threads_dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".md")) continue;
            const name = entry.name[0 .. entry.name.len - ".md".len];
            try out.append(self.allocator, try self.readThread(name));
        }
        std.mem.sort(Thread, out.items, {}, lessThread);
        return out.toOwnedSlice(self.allocator);
    }

    pub fn freeThreads(self: *Stack, threads: []Thread) void {
        for (threads) |*t| {
            var tt = t.*;
            tt.deinit();
        }
        self.allocator.free(threads);
    }

    pub fn readRun(self: *Stack, id: []const u8) Error!PromptRun {
        if (!prompt_mod.isValidName(id)) return error.InvalidName;
        var dir = try self.openStackDir(.{});
        defer dir.close();
        const meta_rel = try std.fs.path.join(self.allocator, &.{ "runs", id, "meta.toml" });
        defer self.allocator.free(meta_rel);
        const meta_src = try readFileAlloc(self.allocator, &dir, meta_rel);
        defer self.allocator.free(meta_src);
        var doc = try toml.parse(self.allocator, meta_src);
        defer doc.deinit();

        const snapshot_rel = try std.fs.path.join(self.allocator, &.{ "runs", id, "prompt.md" });
        defer self.allocator.free(snapshot_rel);
        const rendered_rel = try std.fs.path.join(self.allocator, &.{ "runs", id, "rendered.md" });
        defer self.allocator.free(rendered_rel);
        const output_rel = try std.fs.path.join(self.allocator, &.{ "runs", id, "output.md" });
        defer self.allocator.free(output_rel);

        const id_owned = try self.allocator.dupe(u8, stringField(&doc, "id") orelse return error.BadRun);
        errdefer self.allocator.free(id_owned);
        const thread_owned = try self.allocator.dupe(u8, stringField(&doc, "thread") orelse return error.BadRun);
        errdefer self.allocator.free(thread_owned);
        const after_owned = try dupeStringArray(self.allocator, stringArrayField(&doc, "after") orelse &.{});
        errdefer freeStringArray(self.allocator, after_owned);
        const inputs_owned = try dupeStringArray(self.allocator, stringArrayField(&doc, "inputs") orelse &.{});
        errdefer freeStringArray(self.allocator, inputs_owned);
        const snapshot_owned = try readFileAlloc(self.allocator, &dir, snapshot_rel);
        errdefer self.allocator.free(snapshot_owned);
        const rendered_owned = readFileAlloc(self.allocator, &dir, rendered_rel) catch |e| switch (e) {
            error.FileNotFound => try self.allocator.dupe(u8, ""),
            else => return e,
        };
        errdefer self.allocator.free(rendered_owned);
        const output_owned = readFileAlloc(self.allocator, &dir, output_rel) catch |e| switch (e) {
            error.FileNotFound => try self.allocator.dupe(u8, ""),
            else => return e,
        };
        errdefer self.allocator.free(output_owned);
        const reason_owned = try self.allocator.dupe(u8, stringField(&doc, "blocked_reason") orelse "");
        errdefer self.allocator.free(reason_owned);

        return .{
            .allocator = self.allocator,
            .id = id_owned,
            .thread = thread_owned,
            .action = try prompt_mod.Action.parse(stringField(&doc, "action") orelse "none"),
            .after = after_owned,
            .inputs = inputs_owned,
            .order = try orderField(&doc),
            .status = try PromptStatus.parse(stringField(&doc, "status") orelse return error.BadRun),
            .snapshot = snapshot_owned,
            .rendered = rendered_owned,
            .output = output_owned,
            .blocked_reason = reason_owned,
        };
    }

    pub fn readThread(self: *Stack, name: []const u8) Error!Thread {
        if (!prompt_mod.isValidName(name)) return error.InvalidName;
        var dir = try self.openStackDir(.{});
        defer dir.close();
        const md_name = try mdNameAlloc(self.allocator, name);
        defer self.allocator.free(md_name);
        const rel = try std.fs.path.join(self.allocator, &.{ "threads", md_name });
        defer self.allocator.free(rel);
        const src = try readFileAlloc(self.allocator, &dir, rel);
        defer self.allocator.free(src);
        var parsed = try prompt_mod.parseThreadFile(self.allocator, src);
        defer parsed.deinit();
        const meta_name = try metaNameAlloc(self.allocator, name);
        defer self.allocator.free(meta_name);
        const meta_rel = try std.fs.path.join(self.allocator, &.{ "threads", meta_name });
        defer self.allocator.free(meta_rel);
        var tab: []const u8 = "";
        var pane: []const u8 = "";
        var status: ThreadStatus = .pending;
        if (readFileAlloc(self.allocator, &dir, meta_rel)) |meta_src| {
            defer self.allocator.free(meta_src);
            var doc = try toml.parse(self.allocator, meta_src);
            defer doc.deinit();
            tab = stringField(&doc, "tab_id") orelse "";
            pane = stringField(&doc, "pane_id") orelse "";
            status = try ThreadStatus.parse(stringField(&doc, "status") orelse "pending");
            return .{
                .allocator = self.allocator,
                .name = try self.allocator.dupe(u8, parsed.thread),
                .command = try self.allocator.dupe(u8, parsed.command),
                .prompt_body = try self.allocator.dupe(u8, parsed.body),
                .tab_id = try self.allocator.dupe(u8, tab),
                .pane_id = try self.allocator.dupe(u8, pane),
                .status = status,
            };
        } else |_| {}
        return .{
            .allocator = self.allocator,
            .name = try self.allocator.dupe(u8, parsed.thread),
            .command = try self.allocator.dupe(u8, parsed.command),
            .prompt_body = try self.allocator.dupe(u8, parsed.body),
            .tab_id = try self.allocator.dupe(u8, ""),
            .pane_id = try self.allocator.dupe(u8, ""),
            .status = .pending,
        };
    }

    pub fn setThreadPane(self: *Stack, name: []const u8, tab_id: []const u8, pane_id: []const u8) Error!void {
        var t = try self.readThread(name);
        defer t.deinit();
        try self.writeThread(name, t.command, t.prompt_body, tab_id, pane_id, .ready);
    }

    pub fn setRunStatus(self: *Stack, id: []const u8, status: PromptStatus, reason: []const u8) Error!void {
        var run = try self.readRun(id);
        defer run.deinit();
        try self.writeRunMeta(&run, status, reason);
    }

    pub fn storeOutput(self: *Stack, id: []const u8, output: []const u8) Error!void {
        var dir = try self.openStackDir(.{});
        defer dir.close();
        const rel = try std.fs.path.join(self.allocator, &.{ "runs", id, "output.md" });
        defer self.allocator.free(rel);
        try dir.writeFile(.{ .sub_path = rel, .data = output });
    }

    pub fn storeResult(self: *Stack, id: []const u8, result: []const u8) Error!void {
        var dir = try self.openStackDir(.{});
        defer dir.close();
        const rel = try std.fs.path.join(self.allocator, &.{ "runs", id, "result.md" });
        defer self.allocator.free(rel);
        try dir.writeFile(.{ .sub_path = rel, .data = result });
    }

    pub fn resultExists(self: *Stack, id: []const u8) bool {
        var dir = self.openStackDir(.{}) catch return false;
        defer dir.close();
        const rel = std.fs.path.join(self.allocator, &.{ "runs", id, "result.md" }) catch return false;
        defer self.allocator.free(rel);
        dir.access(rel, .{}) catch return false;
        return true;
    }

    pub fn resultPathAlloc(self: *Stack, id: []const u8) Error![]u8 {
        // Caller owns returned memory.
        if (!prompt_mod.isValidName(id)) return error.InvalidName;
        const stack_path = try stackPathAbsAlloc(self.allocator, self.root, self.name);
        defer self.allocator.free(stack_path);
        return std.fs.path.join(self.allocator, &.{ stack_path, "runs", id, "result.md" });
    }

    pub fn storeCompletion(self: *Stack, id: []const u8) Error!void {
        var dir = try self.openStackDir(.{});
        defer dir.close();
        const rel = try std.fs.path.join(self.allocator, &.{ "runs", id, "done" });
        defer self.allocator.free(rel);
        try dir.writeFile(.{ .sub_path = rel, .data = "" });
    }

    pub fn completionExists(self: *Stack, id: []const u8) bool {
        var dir = self.openStackDir(.{}) catch return false;
        defer dir.close();
        const rel = std.fs.path.join(self.allocator, &.{ "runs", id, "done" }) catch return false;
        defer self.allocator.free(rel);
        dir.access(rel, .{}) catch return false;
        return true;
    }

    pub fn completionPathAlloc(self: *Stack, id: []const u8) Error![]u8 {
        // Caller owns returned memory.
        if (!prompt_mod.isValidName(id)) return error.InvalidName;
        const stack_path = try stackPathAbsAlloc(self.allocator, self.root, self.name);
        defer self.allocator.free(stack_path);
        return std.fs.path.join(self.allocator, &.{ stack_path, "runs", id, "done" });
    }

    pub fn hasOwnershipMarker(self: *Stack) bool {
        var dir = self.openStackDir(.{}) catch return false;
        defer dir.close();
        dir.access("state/zellij-owner", .{}) catch return false;
        return true;
    }

    fn validatePromptBatch(self: *Stack, prompts: []const prompt_mod.PromptFile) Error!void {
        for (prompts, 0..) |p, i| {
            var thread = self.readThread(p.thread) catch |e| switch (e) {
                error.NotFound, error.FileNotFound => return error.UnknownThread,
                else => return e,
            };
            thread.deinit();
            for (prompts[i + 1 ..]) |q| {
                if (std.mem.eql(u8, p.id, q.id)) return error.DuplicatePrompt;
            }
        }

        const runs = try self.listRuns();
        defer self.freeRuns(runs);
        for (prompts) |p| {
            for (p.after) |dep| {
                if (!containsRun(runs, dep) and !containsPrompt(prompts, dep)) return error.UnknownDependency;
            }
            for (p.inputs) |input| {
                if (!containsRun(runs, input) and !containsPrompt(prompts, input)) return error.UnknownDependency;
            }
        }
        if (try self.hasCycle(runs, prompts)) return error.DependencyCycle;
    }

    fn hasCycle(self: *Stack, runs: []const PromptRun, prompts: []const prompt_mod.PromptFile) Error!bool {
        _ = self;
        for (runs) |run| {
            if (try visitId(run.id, runs, prompts, 0)) return true;
        }
        for (prompts) |p| {
            if (try visitId(p.id, runs, prompts, 0)) return true;
        }
        return false;
    }

    fn upsertPrompt(self: *Stack, p: *const prompt_mod.PromptFile) Error!EnqueueReport {
        if (self.readRun(p.id)) |existing| {
            var e = existing;
            defer e.deinit();
            switch (e.status) {
                .queued => {
                    if (!runMatchesPrompt(&e, p)) {
                        try self.writePromptRun(p, .queued, e.order);
                        return report(self.allocator, p.id, .queued, .updated);
                    }
                    return report(self.allocator, p.id, .queued, .existing);
                },
                .running, .completed => return report(self.allocator, p.id, e.status, .existing),
                .blocked, .failed => return report(self.allocator, p.id, e.status, .existing),
            }
        } else |e| switch (e) {
            error.NotFound, error.FileNotFound => {},
            else => return e,
        }
        const order = try self.nextRunOrder();
        try self.writePromptRun(p, .queued, order);
        return report(self.allocator, p.id, .queued, .inserted);
    }

    fn writePromptRun(self: *Stack, p: *const prompt_mod.PromptFile, status: PromptStatus, order: u64) Error!void {
        var thread = try self.readThread(p.thread);
        defer thread.deinit();
        const result_path = try self.resultPathAlloc(p.id);
        defer self.allocator.free(result_path);
        const completion_path = try self.completionPathAlloc(p.id);
        defer self.allocator.free(completion_path);
        const input_results = try self.inputResultsAlloc(p.inputs);
        defer self.freeInputResults(input_results);
        const rendered = try prompt_mod.renderPromptAlloc(self.allocator, self.stack_prompt_body, thread.prompt_body, p.body, result_path, completion_path, input_results);
        defer self.allocator.free(rendered);

        var dir = try self.openStackDir(.{});
        defer dir.close();
        const run_rel = try std.fs.path.join(self.allocator, &.{ "runs", p.id });
        defer self.allocator.free(run_rel);
        try dir.makePath(run_rel);
        const prompt_rel = try std.fs.path.join(self.allocator, &.{ "runs", p.id, "prompt.md" });
        defer self.allocator.free(prompt_rel);
        const rendered_rel = try std.fs.path.join(self.allocator, &.{ "runs", p.id, "rendered.md" });
        defer self.allocator.free(rendered_rel);
        try dir.writeFile(.{ .sub_path = prompt_rel, .data = p.body });
        try dir.writeFile(.{ .sub_path = rendered_rel, .data = rendered });

        const id_owned = try self.allocator.dupe(u8, p.id);
        errdefer self.allocator.free(id_owned);
        const thread_owned = try self.allocator.dupe(u8, p.thread);
        errdefer self.allocator.free(thread_owned);
        const after_owned = try dupeStringArray(self.allocator, p.after);
        errdefer freeStringArray(self.allocator, after_owned);
        const inputs_owned = try dupeStringArray(self.allocator, p.inputs);
        errdefer freeStringArray(self.allocator, inputs_owned);
        const snapshot_owned = try self.allocator.dupe(u8, p.body);
        errdefer self.allocator.free(snapshot_owned);
        const rendered_owned = try self.allocator.dupe(u8, rendered);
        errdefer self.allocator.free(rendered_owned);
        const output_owned = try self.allocator.dupe(u8, "");
        errdefer self.allocator.free(output_owned);

        var run = PromptRun{
            .allocator = self.allocator,
            .id = id_owned,
            .thread = thread_owned,
            .action = p.action,
            .after = after_owned,
            .inputs = inputs_owned,
            .order = order,
            .status = status,
            .snapshot = snapshot_owned,
            .rendered = rendered_owned,
            .output = output_owned,
        };
        defer run.deinit();
        try self.writeRunMeta(&run, status, "");
    }

    fn writeRunMeta(self: *Stack, run: *const PromptRun, status: PromptStatus, reason: []const u8) Error!void {
        var after_buf: std.ArrayList(u8) = .empty;
        defer after_buf.deinit(self.allocator);
        try writeStringArray(self.allocator, &after_buf, run.after);
        var inputs_buf: std.ArrayList(u8) = .empty;
        defer inputs_buf.deinit(self.allocator);
        try writeStringArray(self.allocator, &inputs_buf, run.inputs);
        var meta: std.ArrayList(u8) = .empty;
        defer meta.deinit(self.allocator);
        try appendTomlKeyString(self.allocator, &meta, "id", run.id);
        try appendTomlKeyString(self.allocator, &meta, "thread", run.thread);
        try appendTomlKeyString(self.allocator, &meta, "action", actionName(run.action));
        try meta.appendSlice(self.allocator, "after = ");
        try meta.appendSlice(self.allocator, after_buf.items);
        try meta.append(self.allocator, '\n');
        try meta.appendSlice(self.allocator, "inputs = ");
        try meta.appendSlice(self.allocator, inputs_buf.items);
        try meta.append(self.allocator, '\n');
        const order_line = try std.fmt.allocPrint(self.allocator, "order = {d}\n", .{run.order});
        defer self.allocator.free(order_line);
        try meta.appendSlice(self.allocator, order_line);
        try appendTomlKeyString(self.allocator, &meta, "status", status.name());
        try appendTomlKeyString(self.allocator, &meta, "blocked_reason", reason);
        var dir = try self.openStackDir(.{});
        defer dir.close();
        const rel = try std.fs.path.join(self.allocator, &.{ "runs", run.id, "meta.toml" });
        defer self.allocator.free(rel);
        try dir.writeFile(.{ .sub_path = rel, .data = meta.items });
    }

    fn writeThread(self: *Stack, name: []const u8, command: []const u8, body: []const u8, tab_id: []const u8, pane_id: []const u8, status: ThreadStatus) Error!void {
        if (!prompt_mod.isValidName(name)) return error.InvalidName;
        var dir = try self.openStackDir(.{});
        defer dir.close();
        try dir.makePath("threads");
        const md_name = try mdNameAlloc(self.allocator, name);
        defer self.allocator.free(md_name);
        const md_rel = try std.fs.path.join(self.allocator, &.{ "threads", md_name });
        defer self.allocator.free(md_rel);
        var src: std.ArrayList(u8) = .empty;
        defer src.deinit(self.allocator);
        try src.appendSlice(self.allocator, "+++\ntype = \"thread\"\nthread = ");
        try appendTomlString(self.allocator, &src, name);
        if (command.len != 0) {
            try src.appendSlice(self.allocator, "\ncommand = ");
            try appendTomlString(self.allocator, &src, command);
        }
        try src.appendSlice(self.allocator, "\n+++\n\n");
        try src.appendSlice(self.allocator, body);
        try src.append(self.allocator, '\n');
        try dir.writeFile(.{ .sub_path = md_rel, .data = src.items });

        const meta_name = try metaNameAlloc(self.allocator, name);
        defer self.allocator.free(meta_name);
        const meta_rel = try std.fs.path.join(self.allocator, &.{ "threads", meta_name });
        defer self.allocator.free(meta_rel);
        var meta: std.ArrayList(u8) = .empty;
        defer meta.deinit(self.allocator);
        try appendTomlKeyString(self.allocator, &meta, "tab_id", tab_id);
        try appendTomlKeyString(self.allocator, &meta, "pane_id", pane_id);
        try appendTomlKeyString(self.allocator, &meta, "status", status.name());
        try dir.writeFile(.{ .sub_path = meta_rel, .data = meta.items });
    }

    fn nextRunOrder(self: *Stack) Error!u64 {
        const runs = try self.listRuns();
        defer self.freeRuns(runs);
        var max: u64 = 0;
        for (runs) |run| {
            if (run.order > max) max = run.order;
        }
        return max + 1;
    }

    fn inputResultsAlloc(self: *Stack, inputs: []const []const u8) Error![]prompt_mod.InputResult {
        // Caller owns returned memory.
        var out: std.ArrayList(prompt_mod.InputResult) = .empty;
        errdefer {
            for (out.items) |input| {
                self.allocator.free(input.id);
                self.allocator.free(input.path);
            }
            out.deinit(self.allocator);
        }
        for (inputs) |input| {
            try out.append(self.allocator, .{
                .id = try self.allocator.dupe(u8, input),
                .path = try self.resultPathAlloc(input),
            });
        }
        return out.toOwnedSlice(self.allocator);
    }

    fn freeInputResults(self: *Stack, inputs: []prompt_mod.InputResult) void {
        for (inputs) |input| {
            self.allocator.free(input.id);
            self.allocator.free(input.path);
        }
        self.allocator.free(inputs);
    }

    fn openStackDir(self: *const Stack, options: std.fs.Dir.OpenOptions) Error!std.fs.Dir {
        const path = try stackPathAlloc(self.allocator, self.root, self.name);
        defer self.allocator.free(path);
        return std.fs.cwd().openDir(path, options) catch |e| switch (e) {
            error.FileNotFound, error.NotDir => return error.NotFound,
            else => return e,
        };
    }
};

fn visitId(id: []const u8, runs: []const PromptRun, prompts: []const prompt_mod.PromptFile, depth: usize) Error!bool {
    if (depth > runs.len + prompts.len) return error.DependencyCycle;
    const deps = depsFor(id, runs, prompts) orelse return false;
    for (deps) |dep| {
        if (std.mem.eql(u8, dep, id)) return true;
        if (try reaches(dep, id, runs, prompts, depth + 1)) return true;
    }
    const inputs = inputsFor(id, runs, prompts) orelse return false;
    for (inputs) |input| {
        if (std.mem.eql(u8, input, id)) return true;
        if (try reaches(input, id, runs, prompts, depth + 1)) return true;
    }
    return false;
}

fn reaches(id: []const u8, target: []const u8, runs: []const PromptRun, prompts: []const prompt_mod.PromptFile, depth: usize) Error!bool {
    if (depth > runs.len + prompts.len) return error.DependencyCycle;
    const deps = depsFor(id, runs, prompts) orelse return false;
    for (deps) |dep| {
        if (std.mem.eql(u8, dep, target)) return true;
        if (try reaches(dep, target, runs, prompts, depth + 1)) return true;
    }
    const inputs = inputsFor(id, runs, prompts) orelse return false;
    for (inputs) |input| {
        if (std.mem.eql(u8, input, target)) return true;
        if (try reaches(input, target, runs, prompts, depth + 1)) return true;
    }
    return false;
}

fn depsFor(id: []const u8, runs: []const PromptRun, prompts: []const prompt_mod.PromptFile) ?[]const []const u8 {
    for (prompts) |p| if (std.mem.eql(u8, p.id, id)) return p.after;
    for (runs) |r| if (std.mem.eql(u8, r.id, id)) return r.after;
    return null;
}

fn inputsFor(id: []const u8, runs: []const PromptRun, prompts: []const prompt_mod.PromptFile) ?[]const []const u8 {
    for (prompts) |p| if (std.mem.eql(u8, p.id, id)) return p.inputs;
    for (runs) |r| if (std.mem.eql(u8, r.id, id)) return r.inputs;
    return null;
}

fn containsRun(runs: []const PromptRun, id: []const u8) bool {
    for (runs) |r| if (std.mem.eql(u8, r.id, id)) return true;
    return false;
}

fn containsPrompt(prompts: []const prompt_mod.PromptFile, id: []const u8) bool {
    for (prompts) |p| if (std.mem.eql(u8, p.id, id)) return true;
    return false;
}

fn runMatchesPrompt(run: *const PromptRun, prompt: *const prompt_mod.PromptFile) bool {
    return std.mem.eql(u8, run.thread, prompt.thread) and
        run.action == prompt.action and
        std.mem.eql(u8, run.snapshot, prompt.body) and
        stringArraysEqual(run.after, prompt.after) and
        stringArraysEqual(run.inputs, prompt.inputs);
}

fn stringArraysEqual(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (!std.mem.eql(u8, left, right)) return false;
    }
    return true;
}

fn report(allocator: std.mem.Allocator, id: []const u8, status: PromptStatus, disposition: EnqueueDisposition) !EnqueueReport {
    return .{
        .allocator = allocator,
        .id = try allocator.dupe(u8, id),
        .status = status,
        .disposition = disposition,
    };
}

fn lessRun(_: void, a: PromptRun, b: PromptRun) bool {
    if (a.order != b.order) return a.order < b.order;
    return std.mem.lessThan(u8, a.id, b.id);
}

fn lessThread(_: void, a: Thread, b: Thread) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

fn stackPathAlloc(allocator: std.mem.Allocator, root: []const u8, name: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ root, "stacks", name });
}

fn stackPathAbsAlloc(allocator: std.mem.Allocator, root: []const u8, name: []const u8) Error![]u8 {
    // Caller owns returned memory.
    const stack_path = try stackPathAlloc(allocator, root, name);
    errdefer allocator.free(stack_path);
    if (std.fs.path.isAbsolute(stack_path)) return stack_path;
    const cwd = std.fs.cwd().realpathAlloc(allocator, ".") catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NotFound,
    };
    defer allocator.free(cwd);
    defer allocator.free(stack_path);
    return std.fs.path.join(allocator, &.{ cwd, stack_path });
}

fn mdNameAlloc(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}.md", .{name});
}

fn metaNameAlloc(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}.toml", .{name});
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

fn readFileAlloc(allocator: std.mem.Allocator, dir: *std.fs.Dir, rel: []const u8) ![]u8 {
    // Caller owns returned memory.
    var file = try dir.openFile(rel, .{});
    defer file.close();
    const stat = try file.stat();
    const buf = try allocator.alloc(u8, stat.size);
    errdefer allocator.free(buf);
    _ = try file.readAll(buf);
    return buf;
}

fn stringField(doc: *const toml.Document, key: []const u8) ?[]const u8 {
    const entry = doc.find("", key) orelse return null;
    return switch (entry.value) {
        .string => |s| s,
        else => null,
    };
}

fn stringArrayField(doc: *const toml.Document, key: []const u8) ?[]const []const u8 {
    const entry = doc.find("", key) orelse return null;
    return switch (entry.value) {
        .string_array => |s| s,
        else => null,
    };
}

fn orderField(doc: *const toml.Document) Error!u64 {
    const entry = doc.find("", "order") orelse return 0;
    return switch (entry.value) {
        .integer => |n| if (n >= 0) @intCast(n) else error.BadRun,
        else => error.BadRun,
    };
}

fn dupeStringArray(allocator: std.mem.Allocator, src: []const []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |s| allocator.free(s);
        out.deinit(allocator);
    }
    for (src) |s| try out.append(allocator, try allocator.dupe(u8, s));
    return out.toOwnedSlice(allocator);
}

fn freeStringArray(allocator: std.mem.Allocator, values: []const []const u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(values);
}

fn writeStringArray(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), src: []const []const u8) !void {
    try buf.append(allocator, '[');
    for (src, 0..) |value, i| {
        if (i != 0) try buf.appendSlice(allocator, ", ");
        try appendTomlString(allocator, buf, value);
    }
    try buf.append(allocator, ']');
}

fn appendTomlKeyString(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), key: []const u8, value: []const u8) !void {
    try buf.appendSlice(allocator, key);
    try buf.appendSlice(allocator, " = ");
    try appendTomlString(allocator, buf, value);
    try buf.append(allocator, '\n');
}

fn appendTomlString(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), value: []const u8) !void {
    try buf.append(allocator, '"');
    for (value) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            0x08 => try buf.appendSlice(allocator, "\\b"),
            0x0c => try buf.appendSlice(allocator, "\\f"),
            else => {
                if (c < 0x20) {
                    const escaped = try std.fmt.allocPrint(allocator, "\\u00{x:0>2}", .{c});
                    defer allocator.free(escaped);
                    try buf.appendSlice(allocator, escaped);
                } else {
                    try buf.append(allocator, c);
                }
            },
        }
    }
    try buf.append(allocator, '"');
}

fn actionName(action: prompt_mod.Action) []const u8 {
    return switch (action) {
        .none => "none",
        .new => "new",
        .clear => "clear",
        .compact => "compact",
    };
}

test "enqueue validates dependencies and stores output" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/root", .{&tmp.sub_path});
    defer a.free(root);
    const thread_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/builder.md", .{&tmp.sub_path});
    defer a.free(thread_path);
    const p1_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/plan.md", .{&tmp.sub_path});
    defer a.free(p1_path);
    const p2_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/impl.md", .{&tmp.sub_path});
    defer a.free(p2_path);

    try tmp.dir.makePath("root");
    var stack = try Stack.create(a, root, "demo", "codex", "");
    defer stack.deinit();
    try tmp.dir.writeFile(.{ .sub_path = "builder.md", .data = 
        \\+++
        \\type = "thread"
        \\thread = "builder"
        \\+++
        \\Build carefully.
    });
    try stack.installThreadFile(thread_path);
    try tmp.dir.writeFile(.{ .sub_path = "plan.md", .data = 
        \\+++
        \\id = "plan"
        \\thread = "builder"
        \\+++
        \\Plan first.
    });
    try tmp.dir.writeFile(.{ .sub_path = "impl.md", .data = 
        \\+++
        \\id = "impl"
        \\thread = "builder"
        \\after = ["plan"]
        \\+++
        \\Implement second.
    });
    const reports = try stack.addFiles(&.{ p1_path, p2_path });
    defer stack.freeReports(reports);
    try std.testing.expectEqual(@as(usize, 2), reports.len);
    try stack.storeOutput("plan", "codex output\n");
    var run = try stack.readRun("plan");
    defer run.deinit();
    try std.testing.expect(std.mem.indexOf(u8, run.output, "codex output") != null);
}

test "queue order follows insertion order instead of thread or id sorting" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/root", .{&tmp.sub_path});
    defer a.free(root);
    const alpha_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/alpha.md", .{&tmp.sub_path});
    defer a.free(alpha_path);
    const beta_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/beta.md", .{&tmp.sub_path});
    defer a.free(beta_path);
    const first_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/z-first.md", .{&tmp.sub_path});
    defer a.free(first_path);
    const second_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/a-second.md", .{&tmp.sub_path});
    defer a.free(second_path);

    try tmp.dir.makePath("root");
    var stack = try Stack.create(a, root, "demo", "codex", "");
    defer stack.deinit();
    try tmp.dir.writeFile(.{ .sub_path = "alpha.md", .data = 
        \\+++
        \\type = "thread"
        \\thread = "alpha"
        \\+++
        \\Alpha thread.
    });
    try tmp.dir.writeFile(.{ .sub_path = "beta.md", .data = 
        \\+++
        \\type = "thread"
        \\thread = "beta"
        \\+++
        \\Beta thread.
    });
    try stack.installThreadFile(alpha_path);
    try stack.installThreadFile(beta_path);

    try tmp.dir.writeFile(.{ .sub_path = "z-first.md", .data = 
        \\+++
        \\id = "z-first"
        \\thread = "beta"
        \\+++
        \\First by insertion.
    });
    try tmp.dir.writeFile(.{ .sub_path = "a-second.md", .data = 
        \\+++
        \\id = "a-second"
        \\thread = "alpha"
        \\+++
        \\Second by insertion.
    });

    const reports = try stack.addFiles(&.{ first_path, second_path });
    defer stack.freeReports(reports);
    const runs = try stack.listRuns();
    defer stack.freeRuns(runs);
    try std.testing.expectEqual(@as(usize, 2), runs.len);
    try std.testing.expectEqualStrings("z-first", runs[0].id);
    try std.testing.expectEqual(@as(u64, 1), runs[0].order);
    try std.testing.expectEqualStrings("a-second", runs[1].id);
    try std.testing.expectEqual(@as(u64, 2), runs[1].order);
}

test "stack command is escaped in toml front matter" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/root", .{&tmp.sub_path});
    defer a.free(root);

    try tmp.dir.makePath("root");
    var created = try Stack.create(a, root, "demo", "foo\"bar\nbaz", "");
    created.deinit();

    var reopened = try Stack.open(a, root, "demo");
    defer reopened.deinit();
    try std.testing.expectEqualStrings("foo\"bar\nbaz", reopened.command);
}

test "thread command overrides stack command when present" {
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
    var stack = try Stack.create(a, root, "demo", "codex", "");
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

    var builder = try stack.readThread("builder");
    defer builder.deinit();
    var reviewer = try stack.readThread("reviewer");
    defer reviewer.deinit();
    try std.testing.expectEqualStrings("", builder.command);
    try std.testing.expectEqualStrings("claude", reviewer.command);
}
