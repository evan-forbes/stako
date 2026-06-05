//! The stack runtime: everything Stako needs at run time, computed from the one
//! `plan.toml` graph plus filesystem markers and the event log. A `Stack` owns a
//! parsed `plan.Plan` and the absolute path to its directory under
//! `<root>/stacks/<name>/`. It computes status, renders node prompts, records
//! events, and writes the run artifacts agents produce. There is no stored
//! status and no second copy of the graph (see `09_unified_authoring_model.md`).

const std = @import("std");
const plan = @import("plan.zig");
const prompt = @import("prompt.zig");
const events = @import("events.zig");
const status = @import("status.zig");

const log = std.log.scoped(.runtime);

pub const Error = error{
    InvalidName,
    NotFound,
    AlreadyExists,
    UnknownTarget,
    TargetNotQueued,
} || std.fs.Dir.OpenError ||
    std.fs.Dir.MakeError ||
    std.fs.Dir.WriteFileError ||
    std.fs.Dir.RenameError ||
    std.fs.File.OpenError ||
    std.fs.File.ReadError ||
    std.fs.File.StatError ||
    std.fs.File.SeekError ||
    std.posix.FlockError ||
    std.Io.Writer.Error ||
    plan.ParseError ||
    plan.ValidationError;

/// Inputs for creating a stack from an authored plan. Path roles are resolved to
/// absolute by the caller (the folder planner); see `04_directory_worktree_model.md`.
pub const Source = struct {
    plan_text: []const u8,
    agent_cwd_abs: []const u8 = "",
    prompt_folder_abs: []const u8 = "",
};

pub const Stack = struct {
    gpa: std.mem.Allocator,
    root: []const u8,
    name: []const u8,
    /// Absolute path to `<root>/stacks/<name>/`.
    dir_abs: []const u8,
    plan: plan.Plan,

    /// Open an existing stack, parsing and validating its `plan.toml`.
    pub fn open(gpa: std.mem.Allocator, root: []const u8, name: []const u8) Error!Stack {
        if (!plan.isValidName(name)) return error.InvalidName;
        const dir_abs = try stackDirAbsAlloc(gpa, root, name);
        errdefer gpa.free(dir_abs);

        var dir = std.fs.cwd().openDir(dir_abs, .{}) catch |e| switch (e) {
            error.FileNotFound, error.NotDir => return error.NotFound,
            else => return e,
        };
        defer dir.close();
        const src = readFileAlloc(gpa, &dir, "plan.toml") catch |e| switch (e) {
            error.FileNotFound => return error.NotFound,
            else => return e,
        };
        defer gpa.free(src);

        var p = try plan.parse(gpa, src);
        errdefer p.deinit();
        try plan.validate(&p, gpa);

        const root_owned = try gpa.dupe(u8, root);
        errdefer gpa.free(root_owned);
        const name_owned = try gpa.dupe(u8, name);
        errdefer gpa.free(name_owned);

        return .{ .gpa = gpa, .root = root_owned, .name = name_owned, .dir_abs = dir_abs, .plan = p };
    }

    /// Create `<root>/stacks/<name>/` from an authored plan, normalizing the
    /// header (stack name, agent cwd, prompt folder) and resolving `use` paths to
    /// absolute. `root` must already exist. The normalized plan becomes the one
    /// canonical graph; the source is consumed once.
    pub fn createFromSource(gpa: std.mem.Allocator, root: []const u8, name: []const u8, source: Source) Error!Stack {
        if (!plan.isValidName(name)) return error.InvalidName;

        var p = try plan.parse(gpa, source.plan_text);
        defer p.deinit();
        try plan.validate(&p, gpa);
        try normalize(&p, name, source);
        const text = try plan.emitAlloc(gpa, &p);
        defer gpa.free(text);

        var root_dir = std.fs.cwd().openDir(root, .{}) catch |e| switch (e) {
            error.FileNotFound, error.NotDir => return error.NotFound,
            else => return e,
        };
        defer root_dir.close();
        try root_dir.makePath("stacks");
        const stack_rel = try std.fs.path.join(gpa, &.{ "stacks", name });
        defer gpa.free(stack_rel);
        root_dir.makeDir(stack_rel) catch |e| switch (e) {
            error.PathAlreadyExists => return error.AlreadyExists,
            else => return e,
        };
        var stack_dir = try root_dir.openDir(stack_rel, .{});
        defer stack_dir.close();
        try stack_dir.makePath("runs");
        try stack_dir.makePath("state");
        try stack_dir.writeFile(.{ .sub_path = "plan.toml", .data = text });
        try stack_dir.writeFile(.{ .sub_path = "state/zellij-owner", .data = "stako\n" });

        return open(gpa, root, name);
    }

    pub fn deinit(self: *Stack) void {
        self.gpa.free(self.root);
        self.gpa.free(self.name);
        self.gpa.free(self.dir_abs);
        self.plan.deinit();
    }

    pub fn agentCwd(self: *const Stack) []const u8 {
        return self.plan.header.cwd;
    }

    // ---------- projection ----------

    /// Filesystem markers for one node's `runs/<node>/` directory.
    pub fn markerFor(self: *const Stack, node_name: []const u8) status.Marker {
        var dir = self.openDir(.{}) catch return .{ .done = false, .result = false };
        defer dir.close();
        return self.markerIn(&dir, node_name);
    }

    /// Markers for `node_name` through an already-open stack dir; lets a whole
    /// status pass share one handle instead of reopening per node.
    fn markerIn(self: *const Stack, dir: *std.fs.Dir, node_name: []const u8) status.Marker {
        return .{
            .done = self.accessRun(dir, node_name, "done"),
            .result = self.accessRun(dir, node_name, "result.md"),
        };
    }

    /// Computed status for every node, parallel to `plan.nodes`. Caller owns it.
    pub fn statusesAlloc(self: *const Stack, gpa: std.mem.Allocator) Error![]status.Status {
        // Caller owns returned memory.
        const markers = try gpa.alloc(status.Marker, self.plan.nodes.len);
        defer gpa.free(markers);
        {
            // One dir handle for every node's markers, not one open per node.
            var dir = try self.openDir(.{});
            defer dir.close();
            for (self.plan.nodes, 0..) |node, i| markers[i] = self.markerIn(&dir, node.name);
        }

        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const event_log = try self.eventsAlloc(arena.allocator());
        return status.computeAlloc(gpa, &self.plan, markers, event_log);
    }

    /// Read and parse `events.jsonl`. Results point into `arena`.
    pub fn eventsAlloc(self: *const Stack, arena: std.mem.Allocator) Error![]events.Event {
        var dir = try self.openDir(.{});
        defer dir.close();
        const src = readFileAlloc(arena, &dir, "events.jsonl") catch |e| switch (e) {
            error.FileNotFound => return &.{},
            else => return e,
        };
        return events.loadAlloc(arena, src);
    }

    // ---------- rendering ----------

    /// Compose the bytes that would be delivered to the agent for `node`:
    /// resolved body, inputs contract, output contract (or the raw body when
    /// `node.raw`). Caller owns the result.
    pub fn renderNodeAlloc(self: *const Stack, gpa: std.mem.Allocator, node: *const plan.Node) Error![]u8 {
        // Caller owns returned memory.
        const body = try self.buildBodyAlloc(gpa, node);
        defer gpa.free(body);
        if (node.raw) return gpa.dupe(u8, body);

        const result_abs = try self.runPathAbsAlloc(gpa, node.name, "result.md");
        defer gpa.free(result_abs);
        const done_abs = try self.runPathAbsAlloc(gpa, node.name, "done");
        defer gpa.free(done_abs);

        var inputs: std.ArrayList(prompt.RenderInput) = .empty;
        defer {
            for (inputs.items) |inp| gpa.free(inp.path);
            inputs.deinit(gpa);
        }
        for (node.blocked_by) |b| {
            try inputs.append(gpa, .{ .node = b, .path = try self.runPathAbsAlloc(gpa, b, "result.md") });
        }
        return prompt.composeAlloc(gpa, body, result_abs, done_abs, inputs.items);
    }

    fn buildBodyAlloc(self: *const Stack, gpa: std.mem.Allocator, node: *const plan.Node) Error![]u8 {
        var body: std.ArrayList(u8) = .empty;
        errdefer body.deinit(gpa);
        var wrote = false;

        if (node.use_path.len != 0) {
            const txt = try self.readBodyFileAlloc(gpa, node.use_path);
            defer gpa.free(txt);
            try appendSection(gpa, &body, &wrote, std.mem.trim(u8, txt, " \t\r\n"));
        }
        for (node.with) |item| {
            if (self.readBodyFileAlloc(gpa, item)) |txt| {
                defer gpa.free(txt);
                try appendSection(gpa, &body, &wrote, std.mem.trim(u8, txt, " \t\r\n"));
            } else |e| switch (e) {
                error.FileNotFound, error.NotFound, error.NotDir => try appendSection(gpa, &body, &wrote, item),
                else => return e,
            }
        }
        if (node.body.len != 0) {
            try appendSection(gpa, &body, &wrote, node.body);
        }
        if (!wrote) {
            const thread = self.plan.threadByName(node.thread) orelse return error.NotFound;
            try body.appendSlice(gpa, std.mem.trim(u8, thread.default, " \t\r\n"));
        }
        return body.toOwnedSlice(gpa);
    }

    fn readBodyFileAlloc(self: *const Stack, gpa: std.mem.Allocator, path: []const u8) Error![]u8 {
        if (std.fs.path.isAbsolute(path)) return readPathAlloc(gpa, path);
        const base = if (self.plan.header.prompt_folder.len != 0) self.plan.header.prompt_folder else self.dir_abs;
        const full = try std.fs.path.join(gpa, &.{ base, path });
        defer gpa.free(full);
        return readPathAlloc(gpa, full);
    }

    // ---------- run artifacts ----------

    pub fn writeRendered(self: *const Stack, node_name: []const u8, bytes: []const u8) Error!void {
        try self.writeRunFile(node_name, "rendered.md", bytes);
    }

    pub fn storeResult(self: *const Stack, node_name: []const u8, text: []const u8) Error!void {
        try self.writeRunFile(node_name, "result.md", text);
    }

    pub fn storeOutput(self: *const Stack, node_name: []const u8, text: []const u8) Error!void {
        try self.writeRunFile(node_name, "output.md", text);
    }

    pub fn storeCompletion(self: *const Stack, node_name: []const u8) Error!void {
        try self.writeRunFile(node_name, "done", "");
    }

    pub fn resultExists(self: *const Stack, node_name: []const u8) bool {
        return self.markerFor(node_name).result;
    }

    pub fn completionExists(self: *const Stack, node_name: []const u8) bool {
        return self.markerFor(node_name).done;
    }

    /// Read `runs/<node>/<file>`; a missing file yields "" so callers can treat
    /// optional artifacts (output dumps, renders) uniformly. Caller owns it.
    pub fn readRunFileAlloc(self: *const Stack, gpa: std.mem.Allocator, node_name: []const u8, file: []const u8) Error![]u8 {
        // Caller owns returned memory.
        var dir = try self.openDir(.{});
        defer dir.close();
        const rel = try std.fs.path.join(gpa, &.{ "runs", node_name, file });
        defer gpa.free(rel);
        return readFileAlloc(gpa, &dir, rel) catch |e| switch (e) {
            error.FileNotFound => try gpa.dupe(u8, ""),
            else => return e,
        };
    }

    /// Absolute path to `runs/<node>/<file>`. Caller owns it.
    pub fn runPathAbsAlloc(self: *const Stack, gpa: std.mem.Allocator, node_name: []const u8, file: []const u8) Error![]u8 {
        // Caller owns returned memory.
        return std.fs.path.join(gpa, &.{ self.dir_abs, "runs", node_name, file });
    }

    // ---------- event log ----------

    /// Append one event to `events.jsonl`, stamping `ts` if unset.
    pub fn appendEvent(self: *const Stack, ev_in: events.Event) Error!void {
        var ev = ev_in;
        var ts_buf: [24]u8 = undefined;
        if (ev.ts.len == 0) ev.ts = events.now(&ts_buf);

        var dir = try self.openDir(.{});
        defer dir.close();
        var file = try dir.createFile("events.jsonl", .{ .truncate = false });
        defer file.close();
        try file.seekFromEnd(0);
        // Streaming writer appends at the OS file offset; the positional
        // `file.writer` would start from pos 0 and overwrite earlier events.
        var buf: [4096]u8 = undefined;
        var fw = file.writerStreaming(&buf);
        try events.writeLine(&fw.interface, ev);
        try fw.interface.flush();
    }

    // ---------- mutation ----------

    /// Append `node` to the graph and, when `gate_target` is given, add the new
    /// node to that target's `blocked_by`. The target must still be queued —
    /// gating a running or completed node is rejected, which is the safety the
    /// injection design needs (`01_followup_injection.md`). The mutation is
    /// validated, persisted to `plan.toml`, and logged.
    ///
    /// Held under the stack mutation lock and applied to a freshly reloaded plan,
    /// so concurrent `inject`/`link` processes serialize instead of clobbering
    /// each other's edits (Phase 7's atomicity requirement).
    pub fn inject(self: *Stack, node: plan.Node, gate_target: ?[]const u8) Error!void {
        var lock = try self.acquireLock();
        defer lock.close();
        try self.reloadPlan();

        if (gate_target) |target| {
            if (self.plan.nodeByName(target) == null) return error.UnknownTarget;
            if (try self.nodeStatus(target) != .queued) return error.TargetNotQueued;
        }
        try self.plan.addNode(node);
        if (gate_target) |target| {
            _ = try self.plan.addBlocker(target, node.name);
        }
        try plan.validate(&self.plan, self.gpa);
        try self.writePlan();
        try self.appendEvent(.{ .event = .injected, .node = node.name, .thread = node.thread });
    }

    /// Add an edge: `target` becomes blocked by `source`. Both must exist and
    /// `target` must still be queued. Validated (no cycles), persisted, logged.
    /// Serialized under the mutation lock against a reloaded plan, like `inject`.
    pub fn link(self: *Stack, source: []const u8, target: []const u8) Error!void {
        var lock = try self.acquireLock();
        defer lock.close();
        try self.reloadPlan();

        if (self.plan.nodeByName(source) == null) return error.UnknownTarget;
        if (self.plan.nodeByName(target) == null) return error.UnknownTarget;
        if (try self.nodeStatus(target) != .queued) return error.TargetNotQueued;
        _ = try self.plan.addBlocker(target, source);
        try plan.validate(&self.plan, self.gpa);
        try self.writePlan();
        try self.appendEvent(.{ .event = .injected, .node = target, .reason = source });
    }

    /// Computed status for a single node.
    pub fn nodeStatus(self: *const Stack, node_name: []const u8) Error!status.Status {
        const marker = self.markerFor(node_name);
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const event_log = try self.eventsAlloc(arena.allocator());
        return status.nodeStatus(marker, node_name, event_log);
    }

    /// Re-emit the in-memory plan to `plan.toml`. Used after `inject`/`link`.
    /// Writes a temp file then renames it into place so a concurrent reader
    /// (status does not take the lock) never observes a half-written plan.
    pub fn writePlan(self: *const Stack) Error!void {
        const text = try plan.emitAlloc(self.gpa, &self.plan);
        defer self.gpa.free(text);
        var dir = try self.openDir(.{});
        defer dir.close();
        try dir.writeFile(.{ .sub_path = "plan.toml.tmp", .data = text });
        try dir.rename("plan.toml.tmp", "plan.toml");
    }

    /// Acquire the stack's exclusive mutation lock, serializing `inject`/`link`
    /// across processes. The returned file holds an advisory `flock`; the
    /// caller's `defer lock.close()` releases it, and the kernel also drops it
    /// if the process dies — so there is no stale lock file to reap.
    fn acquireLock(self: *const Stack) Error!std.fs.File {
        var dir = try self.openDir(.{});
        defer dir.close();
        dir.makePath("state") catch {};
        const file = try dir.createFile("state/lock", .{ .truncate = false });
        errdefer file.close();
        try std.posix.flock(file.handle, std.posix.LOCK.EX);
        return file;
    }

    /// Re-read `plan.toml` into `self.plan`, replacing the snapshot taken at
    /// `open`. Called while holding the mutation lock so a mutation always builds
    /// on the latest committed graph rather than a stale in-memory copy — the
    /// reload is what actually prevents the lost-update race, not the lock alone.
    fn reloadPlan(self: *Stack) Error!void {
        var dir = try self.openDir(.{});
        defer dir.close();
        const src = readFileAlloc(self.gpa, &dir, "plan.toml") catch |e| switch (e) {
            error.FileNotFound => return error.NotFound,
            else => return e,
        };
        defer self.gpa.free(src);
        var fresh = try plan.parse(self.gpa, src);
        errdefer fresh.deinit();
        try plan.validate(&fresh, self.gpa);
        self.plan.deinit();
        self.plan = fresh;
    }

    // ---------- ownership ----------

    pub fn hasOwnershipMarker(self: *const Stack) bool {
        var dir = self.openDir(.{}) catch return false;
        defer dir.close();
        dir.access("state/zellij-owner", .{}) catch return false;
        return true;
    }

    // ---------- internals ----------

    fn openDir(self: *const Stack, options: std.fs.Dir.OpenOptions) Error!std.fs.Dir {
        return std.fs.cwd().openDir(self.dir_abs, options) catch |e| switch (e) {
            error.FileNotFound, error.NotDir => return error.NotFound,
            else => return e,
        };
    }

    fn accessRun(self: *const Stack, dir: *std.fs.Dir, node_name: []const u8, file: []const u8) bool {
        const rel = std.fs.path.join(self.gpa, &.{ "runs", node_name, file }) catch return false;
        defer self.gpa.free(rel);
        dir.access(rel, .{}) catch return false;
        return true;
    }

    fn writeRunFile(self: *const Stack, node_name: []const u8, file: []const u8, data: []const u8) Error!void {
        if (!plan.isValidName(node_name)) return error.InvalidName;
        var dir = try self.openDir(.{});
        defer dir.close();
        const run_rel = try std.fs.path.join(self.gpa, &.{ "runs", node_name });
        defer self.gpa.free(run_rel);
        try dir.makePath(run_rel);
        const rel = try std.fs.path.join(self.gpa, &.{ "runs", node_name, file });
        defer self.gpa.free(rel);
        try dir.writeFile(.{ .sub_path = rel, .data = data });
    }
};

fn appendSection(gpa: std.mem.Allocator, body: *std.ArrayList(u8), wrote: *bool, text: []const u8) std.mem.Allocator.Error!void {
    if (wrote.*) try body.appendSlice(gpa, "\n\n");
    try body.appendSlice(gpa, text);
    wrote.* = true;
}

/// Rewrite the header for the canonical location and make `use` paths absolute.
fn normalize(p: *plan.Plan, name: []const u8, source: Source) error{OutOfMemory}!void {
    const a = p.arena.allocator();
    p.header.name = try a.dupe(u8, name);
    if (source.agent_cwd_abs.len != 0) p.header.cwd = try a.dupe(u8, source.agent_cwd_abs);
    if (source.prompt_folder_abs.len != 0) p.header.prompt_folder = try a.dupe(u8, source.prompt_folder_abs);
    if (source.prompt_folder_abs.len == 0) return;
    // Resolve relative `use` library paths against the prompt folder so the
    // stack directory is self-contained. The node memory is arena-owned.
    const nodes = @constCast(p.nodes);
    for (nodes) |*node| {
        if (node.use_path.len == 0 or std.fs.path.isAbsolute(node.use_path)) continue;
        node.use_path = try std.fs.path.join(a, &.{ source.prompt_folder_abs, node.use_path });
    }
}

fn stackDirAbsAlloc(gpa: std.mem.Allocator, root: []const u8, name: []const u8) Error![]u8 {
    const rel = try std.fs.path.join(gpa, &.{ root, "stacks", name });
    if (std.fs.path.isAbsolute(rel)) return rel;
    defer gpa.free(rel);
    const cwd = std.fs.cwd().realpathAlloc(gpa, ".") catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NotFound,
    };
    defer gpa.free(cwd);
    return std.fs.path.join(gpa, &.{ cwd, rel });
}

fn readPathAlloc(gpa: std.mem.Allocator, path: []const u8) Error![]u8 {
    // Caller owns returned memory.
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const stat = try file.stat();
    const buf = try gpa.alloc(u8, stat.size);
    errdefer gpa.free(buf);
    const n = try file.readAll(buf);
    // The file may have shrunk between stat and read; trim to the bytes actually
    // read so no uninitialized tail escapes. (A grow is harmlessly truncated.)
    if (n != buf.len) return gpa.realloc(buf, n);
    return buf;
}

fn readFileAlloc(gpa: std.mem.Allocator, dir: *std.fs.Dir, rel: []const u8) Error![]u8 {
    // Caller owns returned memory.
    var file = try dir.openFile(rel, .{});
    defer file.close();
    const stat = try file.stat();
    const buf = try gpa.alloc(u8, stat.size);
    errdefer gpa.free(buf);
    const n = try file.readAll(buf);
    // See readPathAlloc: never expose bytes past what was actually read.
    if (n != buf.len) return gpa.realloc(buf, n);
    return buf;
}

// ---------- tests ----------

const testing = std.testing;

const fixture_plan =
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

const TestStack = struct {
    tmp: std.testing.TmpDir,
    root: []u8,
    stack: Stack,

    fn deinit(self: *TestStack) void {
        self.stack.deinit();
        testing.allocator.free(self.root);
        self.tmp.cleanup();
    }
};

fn makeStack(plan_text: []const u8) !TestStack {
    const a = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    errdefer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/root", .{&tmp.sub_path});
    errdefer a.free(root);
    try tmp.dir.makePath("root");
    const stack = try Stack.createFromSource(a, root, "demo", .{ .plan_text = plan_text, .agent_cwd_abs = "/work/repo" });
    return .{ .tmp = tmp, .root = root, .stack = stack };
}

test "create then open exposes the graph and agent cwd" {
    var ts = try makeStack(fixture_plan);
    defer ts.deinit();
    try testing.expectEqual(@as(usize, 2), ts.stack.plan.threads.len);
    try testing.expectEqual(@as(usize, 2), ts.stack.plan.nodes.len);
    try testing.expectEqualStrings("/work/repo", ts.stack.agentCwd());
    try testing.expectEqualStrings("codex", ts.stack.plan.threadByName("impl").?.command);
}

test "status is computed from markers and events" {
    const a = testing.allocator;
    var ts = try makeStack(fixture_plan);
    defer ts.deinit();

    {
        const statuses = try ts.stack.statusesAlloc(a);
        defer a.free(statuses);
        try testing.expectEqual(status.Status.queued, statuses[0]);
        try testing.expectEqual(status.Status.queued, statuses[1]);
    }

    // Deliver impl-1: a delivered event makes it running.
    try ts.stack.appendEvent(.{ .event = .delivered, .node = "impl-1", .thread = "impl" });
    {
        const statuses = try ts.stack.statusesAlloc(a);
        defer a.free(statuses);
        try testing.expectEqual(status.Status.running, statuses[0]);
    }

    // Result + done marker make it completed.
    try ts.stack.storeResult("impl-1", "the result");
    try ts.stack.storeCompletion("impl-1");
    {
        const statuses = try ts.stack.statusesAlloc(a);
        defer a.free(statuses);
        try testing.expectEqual(status.Status.completed, statuses[0]);
    }
}

test "render inlines the body and a blocker result path" {
    const a = testing.allocator;
    var ts = try makeStack(fixture_plan);
    defer ts.deinit();

    const review = ts.stack.plan.nodeByName("review-1").?;
    const rendered = try ts.stack.renderNodeAlloc(a, review);
    defer a.free(rendered);
    try testing.expect(std.mem.indexOf(u8, rendered, "Review it.") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "runs/impl-1/result.md") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "Result file contract:") != null);
}

test "appended events round-trip through the log" {
    const a = testing.allocator;
    var ts = try makeStack(fixture_plan);
    defer ts.deinit();
    try ts.stack.appendEvent(.{ .event = .scheduled, .node = "impl-1", .thread = "impl" });
    try ts.stack.appendEvent(.{ .event = .completed, .node = "impl-1", .result = "runs/impl-1/result.md" });

    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const evs = try ts.stack.eventsAlloc(arena.allocator());
    try testing.expectEqual(@as(usize, 2), evs.len);
    try testing.expectEqual(events.Kind.scheduled, evs[0].event);
    try testing.expectEqual(events.Kind.completed, evs[1].event);
    try testing.expect(evs[0].ts.len >= 20);
}

test "inject appends a node and gates a queued target" {
    const a = testing.allocator;
    var ts = try makeStack(fixture_plan);
    defer ts.deinit();

    try ts.stack.inject(.{
        .name = "fix-1",
        .thread = "impl",
        .action = .compact,
        .use_path = "",
        .with = &.{},
        .body = "Fix the review findings.",
        .blocked_by = &.{},
        .raw = false,
    }, "review-1");

    // Persisted: reopening sees the new node and the gated blocker.
    var reopened = try Stack.open(a, ts.root, "demo");
    defer reopened.deinit();
    try testing.expectEqual(@as(usize, 3), reopened.plan.nodes.len);
    const review = reopened.plan.nodeByName("review-1").?;
    try testing.expectEqual(@as(usize, 2), review.blocked_by.len);
    try testing.expectEqualStrings("impl-1", review.blocked_by[0]);
    try testing.expectEqualStrings("fix-1", review.blocked_by[1]);
}

test "inject before a non-queued target is rejected" {
    const a = testing.allocator;
    var ts = try makeStack(fixture_plan);
    defer ts.deinit();
    try ts.stack.storeResult("impl-1", "r");
    try ts.stack.storeCompletion("impl-1");

    try testing.expectError(error.TargetNotQueued, ts.stack.inject(.{
        .name = "late",
        .thread = "impl",
        .action = .none,
        .use_path = "",
        .with = &.{},
        .body = "too late",
        .blocked_by = &.{},
        .raw = false,
    }, "impl-1"));

    // Nothing was persisted.
    var reopened = try Stack.open(a, ts.root, "demo");
    defer reopened.deinit();
    try testing.expectEqual(@as(usize, 2), reopened.plan.nodes.len);
}

test "link rejects an unknown node" {
    var ts = try makeStack(fixture_plan);
    defer ts.deinit();
    try testing.expectError(error.UnknownTarget, ts.stack.link("impl-1", "ghost"));
}

test "concurrent handles do not lose each other's injected nodes" {
    const a = testing.allocator;
    var ts = try makeStack(fixture_plan);
    defer ts.deinit();

    // A second handle on the same stack, opened before either mutates: the
    // analogue of a second `stako inject` process holding a stale snapshot.
    var b = try Stack.open(a, ts.root, "demo");
    defer b.deinit();

    try ts.stack.inject(.{
        .name = "fix-a",
        .thread = "impl",
        .action = .none,
        .use_path = "",
        .with = &.{},
        .body = "A",
        .blocked_by = &.{},
        .raw = false,
    }, null);
    // `b`'s in-memory plan predates fix-a. The lock + reload must rebase its
    // edit onto the latest committed graph instead of overwriting fix-a.
    try b.inject(.{
        .name = "fix-b",
        .thread = "impl",
        .action = .none,
        .use_path = "",
        .with = &.{},
        .body = "B",
        .blocked_by = &.{},
        .raw = false,
    }, null);

    var reopened = try Stack.open(a, ts.root, "demo");
    defer reopened.deinit();
    try testing.expectEqual(@as(usize, 4), reopened.plan.nodes.len);
    try testing.expect(reopened.plan.nodeByName("fix-a") != null);
    try testing.expect(reopened.plan.nodeByName("fix-b") != null);
}

test "raw node renders the body verbatim with no contract" {
    const a = testing.allocator;
    var ts = try makeStack(
        \\[[thread]]
        \\name = "impl"
        \\command = "codex"
        \\
        \\[[prompt]]
        \\name = "n"
        \\thread = "impl"
        \\raw = true
        \\body = "verbatim only"
        \\
    );
    defer ts.deinit();
    const node = ts.stack.plan.nodeByName("n").?;
    const rendered = try ts.stack.renderNodeAlloc(a, node);
    defer a.free(rendered);
    try testing.expectEqualStrings("verbatim only", rendered);
}
