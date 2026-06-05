//! The stako graph model: a stack is authored once as a single `plan.toml`
//! containing a header, `[[thread]]` declarations, and `[[prompt]]` nodes whose
//! only dependency edge is `blocked_by`. This module owns parsing and structural
//! validation of that file into an in-memory `Plan`. It deliberately knows
//! nothing about the filesystem, rendering, or scheduling: status is computed
//! elsewhere from this graph plus runtime markers (see `09_unified_authoring_model.md`).
//!
//! A `Plan` owns an arena holding every string it exposes, so callers free it
//! with a single `deinit`.

const std = @import("std");
const toml = @import("toml.zig");

/// The session action sent before a node body. Lives here because it is a node
/// field of the graph, not a rendering detail.
pub const Action = enum {
    none,
    new,
    clear,
    compact,

    pub fn parse(s: []const u8) error{BadAction}!Action {
        if (std.mem.eql(u8, s, "none")) return .none;
        if (std.mem.eql(u8, s, "new")) return .new;
        if (std.mem.eql(u8, s, "clear")) return .clear;
        if (std.mem.eql(u8, s, "compact")) return .compact;
        return error.BadAction;
    }

    /// The slash command delivered to the agent, or "" for `.none`.
    pub fn command(self: Action) []const u8 {
        return switch (self) {
            .none => "",
            .new => "/new",
            .clear => "/clear",
            .compact => "/compact",
        };
    }
};

/// Node and thread names are lowercase identifiers: `[a-z0-9_-]+`. Used as
/// stable handles and as `runs/<name>/` directory names.
pub fn isValidName(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (std.ascii.isLower(c) or std.ascii.isDigit(c) or c == '-' or c == '_') continue;
        return false;
    }
    return true;
}

/// A long-lived agent session in a zellij tab. The active model keeps `command`
/// required; optional `model`/harness selection is deferred (see
/// `deferred/08_harness_model_support.md`).
pub const Thread = struct {
    name: []const u8,
    command: []const u8,
    /// Body used by bare calls that set no `use`/`with`/`body`; "" if unset.
    default: []const u8,
};

/// A graph node: one prompt delivered to one thread. The body is composed at
/// render time from `use` + `with` + `body` (or the thread `default`).
pub const Node = struct {
    name: []const u8,
    thread: []const u8,
    action: Action,
    /// Reusable library prompt path, relative or absolute; "" if unset.
    use_path: []const u8,
    /// Extra body inputs (file paths or inline strings) appended to the body.
    with: []const []const u8,
    /// Inline body string; "" if unset.
    body: []const u8,
    /// Names of nodes this one waits for; their `result.md` paths are rendered
    /// in as inputs.
    blocked_by: []const []const u8,
    /// When true the body is delivered verbatim with no auto-contract appended.
    raw: bool,
};

/// Plan header: the stack identity and path roles. Values are stored as
/// authored (possibly relative, possibly absent); the folder planner resolves
/// them to absolute and fills inference gaps (see `04_directory_worktree_model.md`).
pub const Header = struct {
    name: []const u8,
    /// Agent cwd. Accepts `cwd` or `agent_cwd`; "" if unset.
    cwd: []const u8,
    /// Stack root. Accepts `root` or `stack_root`; "" if unset.
    root: []const u8,
    prompt_folder: []const u8,
    worktrees: []const []const u8,
    artifact_roots: []const []const u8,
};

pub const Plan = struct {
    arena: std.heap.ArenaAllocator,
    header: Header,
    threads: []const Thread,
    nodes: []const Node,

    pub fn deinit(self: *Plan) void {
        self.arena.deinit();
    }

    pub fn threadByName(self: *const Plan, name: []const u8) ?*const Thread {
        for (self.threads) |*t| {
            if (std.mem.eql(u8, t.name, name)) return t;
        }
        return null;
    }

    pub fn nodeByName(self: *const Plan, name: []const u8) ?*const Node {
        for (self.nodes) |*n| {
            if (std.mem.eql(u8, n.name, name)) return n;
        }
        return null;
    }

    /// Append a node, duplicating its strings into the plan arena. The caller's
    /// `node` may borrow short-lived memory. Used by `stako inject`; re-validate
    /// afterward before persisting.
    pub fn addNode(self: *Plan, node: Node) error{OutOfMemory}!void {
        const a = self.arena.allocator();
        const grown = try a.alloc(Node, self.nodes.len + 1);
        @memcpy(grown[0..self.nodes.len], self.nodes);
        grown[self.nodes.len] = .{
            .name = try a.dupe(u8, node.name),
            .thread = try a.dupe(u8, node.thread),
            .action = node.action,
            .use_path = try a.dupe(u8, node.use_path),
            .with = try dupeStrArray(a, node.with),
            .body = try a.dupe(u8, node.body),
            .blocked_by = try dupeStrArray(a, node.blocked_by),
            .raw = node.raw,
        };
        self.nodes = grown;
    }

    /// Add `blocker` to `node_name`'s `blocked_by` (idempotent). Returns false if
    /// the node does not exist. Used by `stako link`/`inject`.
    pub fn addBlocker(self: *Plan, node_name: []const u8, blocker: []const u8) error{OutOfMemory}!bool {
        const a = self.arena.allocator();
        const nodes = @constCast(self.nodes);
        for (nodes) |*n| {
            if (!std.mem.eql(u8, n.name, node_name)) continue;
            for (n.blocked_by) |b| {
                if (std.mem.eql(u8, b, blocker)) return true;
            }
            const grown = try a.alloc([]const u8, n.blocked_by.len + 1);
            @memcpy(grown[0..n.blocked_by.len], n.blocked_by);
            grown[n.blocked_by.len] = try a.dupe(u8, blocker);
            n.blocked_by = grown;
            return true;
        }
        return false;
    }
};

pub const ParseError = error{
    MissingName,
    MissingThread,
    MissingCommand,
    BadAction,
    BadName,
    TypeMismatch,
} || toml.ParseError;

pub const ValidationError = error{
    DuplicateThread,
    DuplicateNode,
    UnknownThread,
    UnknownBlocker,
    Cycle,
    OutOfMemory,
};

/// Parse `plan.toml` source into a `Plan`. The returned plan owns an arena
/// backed by `gpa`; free it with `deinit`. Unknown keys are ignored so future
/// fields do not break older binaries. This checks per-entry shape only; call
/// `validate` for cross-entity graph checks.
pub fn parse(gpa: std.mem.Allocator, source: []const u8) ParseError!Plan {
    var doc = try toml.parse(gpa, source);
    defer doc.deinit();

    var plan: Plan = .{
        .arena = std.heap.ArenaAllocator.init(gpa),
        .header = undefined,
        .threads = &.{},
        .nodes = &.{},
    };
    errdefer plan.arena.deinit();
    const a = plan.arena.allocator();

    plan.header = .{
        .name = try dupeOpt(a, try topStr(&doc, "name")),
        .cwd = try dupeOpt(a, (try topStr(&doc, "cwd")) orelse (try topStr(&doc, "agent_cwd"))),
        .root = try dupeOpt(a, (try topStr(&doc, "root")) orelse (try topStr(&doc, "stack_root"))),
        .prompt_folder = try dupeOpt(a, try topStr(&doc, "prompt_folder")),
        .worktrees = try dupeStrArray(a, try tableStrArray(&doc, "paths", "worktrees")),
        .artifact_roots = try dupeStrArray(a, try tableStrArray(&doc, "paths", "artifact_roots")),
    };

    const thread_count = doc.arrayCount("thread");
    const threads = try a.alloc(Thread, thread_count);
    for (0..thread_count) |idx| {
        const name = (try arrStr(&doc, "thread", idx, "name")) orelse return error.MissingName;
        if (!isValidName(name)) return error.BadName;
        const command = (try arrStr(&doc, "thread", idx, "command")) orelse return error.MissingCommand;
        if (command.len == 0) return error.MissingCommand;
        threads[idx] = .{
            .name = try a.dupe(u8, name),
            .command = try a.dupe(u8, command),
            .default = try dupeOpt(a, try arrStr(&doc, "thread", idx, "default")),
        };
    }
    plan.threads = threads;

    const node_count = doc.arrayCount("prompt");
    const nodes = try a.alloc(Node, node_count);
    for (0..node_count) |idx| {
        const name = (try arrStr(&doc, "prompt", idx, "name")) orelse return error.MissingName;
        if (!isValidName(name)) return error.BadName;
        const thread = (try arrStr(&doc, "prompt", idx, "thread")) orelse return error.MissingThread;
        if (!isValidName(thread)) return error.BadName;
        const action = try Action.parse((try arrStr(&doc, "prompt", idx, "action")) orelse "none");
        const blockers_src = (try arrStrArray(&doc, "prompt", idx, "blocked_by")) orelse &.{};
        for (blockers_src) |b| {
            if (!isValidName(b)) return error.BadName;
        }
        nodes[idx] = .{
            .name = try a.dupe(u8, name),
            .thread = try a.dupe(u8, thread),
            .action = action,
            .use_path = try dupeOpt(a, try arrStr(&doc, "prompt", idx, "use")),
            .with = try dupeStrArray(a, try arrStrArray(&doc, "prompt", idx, "with")),
            .body = try dupeOpt(a, try arrStr(&doc, "prompt", idx, "body")),
            .blocked_by = try dupeStrArray(a, blockers_src),
            .raw = (try arrBool(&doc, "prompt", idx, "raw")) orelse false,
        };
    }
    plan.nodes = nodes;

    return plan;
}

/// Cross-entity graph validation: unique names, resolvable thread and blocker
/// references, and acyclicity. `scratch` is used only during the call.
pub fn validate(plan: *const Plan, scratch: std.mem.Allocator) ValidationError!void {
    for (plan.threads, 0..) |t, i| {
        for (plan.threads[i + 1 ..]) |u| {
            if (std.mem.eql(u8, t.name, u.name)) return error.DuplicateThread;
        }
    }
    for (plan.nodes, 0..) |n, i| {
        for (plan.nodes[i + 1 ..]) |m| {
            if (std.mem.eql(u8, n.name, m.name)) return error.DuplicateNode;
        }
    }
    for (plan.nodes) |n| {
        if (plan.threadByName(n.thread) == null) return error.UnknownThread;
        for (n.blocked_by) |b| {
            if (plan.nodeByName(b) == null) return error.UnknownBlocker;
        }
    }
    try checkAcyclic(plan, scratch);
}

fn checkAcyclic(plan: *const Plan, scratch: std.mem.Allocator) ValidationError!void {
    const n = plan.nodes.len;
    if (n == 0) return;
    // 0 = unvisited, 1 = on current DFS path, 2 = fully explored.
    const color = try scratch.alloc(u8, n);
    defer scratch.free(color);
    @memset(color, 0);
    for (0..n) |i| {
        if (color[i] == 0) try dfsVisit(plan, i, color);
    }
}

fn dfsVisit(plan: *const Plan, i: usize, color: []u8) ValidationError!void {
    color[i] = 1;
    for (plan.nodes[i].blocked_by) |b| {
        const j = nodeIndex(plan, b) orelse continue; // unknown blocker caught earlier
        switch (color[j]) {
            1 => return error.Cycle,
            0 => try dfsVisit(plan, j, color),
            else => {},
        }
    }
    color[i] = 2;
}

fn nodeIndex(plan: *const Plan, name: []const u8) ?usize {
    for (plan.nodes, 0..) |nd, idx| {
        if (std.mem.eql(u8, nd.name, name)) return idx;
    }
    return null;
}

// ---------- emission ----------

/// Serialize a plan back to canonical `plan.toml` text. Caller owns the result.
/// Round-trips through `parse`: emitting a parsed plan and re-parsing yields the
/// same graph.
pub fn emitAlloc(gpa: std.mem.Allocator, p: *const Plan) ![]u8 {
    // Caller owns returned memory.
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    try emit(&aw.writer, p);
    return aw.toOwnedSlice();
}

pub fn emit(w: *std.Io.Writer, p: *const Plan) std.Io.Writer.Error!void {
    try emitHeaderKey(w, "name", p.header.name);
    try emitHeaderKey(w, "cwd", p.header.cwd);
    try emitHeaderKey(w, "root", p.header.root);
    try emitHeaderKey(w, "prompt_folder", p.header.prompt_folder);
    if (p.header.worktrees.len != 0 or p.header.artifact_roots.len != 0) {
        try w.writeAll("\n[paths]\n");
        if (p.header.worktrees.len != 0) {
            try w.writeAll("worktrees = ");
            try toml.writeStringArray(w, p.header.worktrees);
            try w.writeByte('\n');
        }
        if (p.header.artifact_roots.len != 0) {
            try w.writeAll("artifact_roots = ");
            try toml.writeStringArray(w, p.header.artifact_roots);
            try w.writeByte('\n');
        }
    }
    for (p.threads) |t| {
        try w.writeAll("\n[[thread]]\n");
        try emitKey(w, "name", t.name);
        try emitKey(w, "command", t.command);
        if (t.default.len != 0) try emitKey(w, "default", t.default);
    }
    for (p.nodes) |n| {
        try w.writeAll("\n[[prompt]]\n");
        try emitKey(w, "name", n.name);
        try emitKey(w, "thread", n.thread);
        if (n.action != .none) try emitKey(w, "action", @tagName(n.action));
        if (n.use_path.len != 0) try emitKey(w, "use", n.use_path);
        if (n.with.len != 0) {
            try w.writeAll("with = ");
            try toml.writeStringArray(w, n.with);
            try w.writeByte('\n');
        }
        if (n.body.len != 0) try emitKey(w, "body", n.body);
        if (n.raw) try w.writeAll("raw = true\n");
        if (n.blocked_by.len != 0) {
            try w.writeAll("blocked_by = ");
            try toml.writeStringArray(w, n.blocked_by);
            try w.writeByte('\n');
        }
    }
}

fn emitHeaderKey(w: *std.Io.Writer, key: []const u8, value: []const u8) std.Io.Writer.Error!void {
    if (value.len == 0) return;
    try emitKey(w, key, value);
}

fn emitKey(w: *std.Io.Writer, key: []const u8, value: []const u8) std.Io.Writer.Error!void {
    try w.writeAll(key);
    try w.writeAll(" = ");
    try toml.writeString(w, value);
    try w.writeByte('\n');
}

// ---------- TOML field extraction ----------

// These accessors return `null` only when a key is genuinely absent. A key that
// is present with the wrong TOML type is a `TypeMismatch` error, never a silent
// `null` — otherwise e.g. `blocked_by = "x"` (a string, not an array) would
// vanish into "no blockers" and let a dependent prompt run early.
fn topStr(doc: *const toml.Document, key: []const u8) error{TypeMismatch}!?[]const u8 {
    const e = doc.find("", key) orelse return null;
    return switch (e.value) {
        .string => |s| s,
        else => error.TypeMismatch,
    };
}

fn tableStrArray(doc: *const toml.Document, table: []const u8, key: []const u8) error{TypeMismatch}!?[]const []const u8 {
    const e = doc.find(table, key) orelse return null;
    return switch (e.value) {
        .string_array => |s| s,
        else => error.TypeMismatch,
    };
}

fn arrStr(doc: *const toml.Document, name: []const u8, idx: usize, key: []const u8) error{TypeMismatch}!?[]const u8 {
    const e = doc.findInArray(name, idx, key) orelse return null;
    return switch (e.value) {
        .string => |s| s,
        else => error.TypeMismatch,
    };
}

fn arrStrArray(doc: *const toml.Document, name: []const u8, idx: usize, key: []const u8) error{TypeMismatch}!?[]const []const u8 {
    const e = doc.findInArray(name, idx, key) orelse return null;
    return switch (e.value) {
        .string_array => |s| s,
        else => error.TypeMismatch,
    };
}

fn arrBool(doc: *const toml.Document, name: []const u8, idx: usize, key: []const u8) error{TypeMismatch}!?bool {
    const e = doc.findInArray(name, idx, key) orelse return null;
    return switch (e.value) {
        .boolean => |b| b,
        else => error.TypeMismatch,
    };
}

fn dupeOpt(arena: std.mem.Allocator, opt: ?[]const u8) ![]const u8 {
    return arena.dupe(u8, opt orelse "");
}

fn dupeStrArray(arena: std.mem.Allocator, opt: ?[]const []const u8) ![]const []const u8 {
    const src = opt orelse return &.{};
    const out = try arena.alloc([]const u8, src.len);
    for (src, 0..) |s, k| out[k] = try arena.dupe(u8, s);
    return out;
}

// ---------- tests ----------

const sample_plan =
    \\name = "refactor-loop"
    \\cwd = "../.."
    \\
    \\[paths]
    \\worktrees = ["/abs/repo"]
    \\artifact_roots = ["/abs/art"]
    \\
    \\[[thread]]
    \\name = "impl"
    \\command = "codex"
    \\
    \\[[thread]]
    \\name = "reviewer"
    \\command = "claude"
    \\default = "Review carefully."
    \\
    \\[[prompt]]
    \\name = "impl-1"
    \\thread = "impl"
    \\action = "new"
    \\use = "prompts/implement.md"
    \\with = ["plans/auth.md"]
    \\
    \\[[prompt]]
    \\name = "review-1"
    \\thread = "reviewer"
    \\action = "new"
    \\use = "prompts/review.md"
    \\blocked_by = ["impl-1"]
    \\
    \\[[prompt]]
    \\name = "fix-1"
    \\thread = "impl"
    \\action = "compact"
    \\use = "prompts/fix.md"
    \\raw = true
    \\blocked_by = ["review-1"]
    \\
;

test "parse and validate a good plan" {
    const a = std.testing.allocator;
    var plan = try parse(a, sample_plan);
    defer plan.deinit();
    try validate(&plan, a);

    try std.testing.expectEqualStrings("refactor-loop", plan.header.name);
    try std.testing.expectEqualStrings("../..", plan.header.cwd);
    try std.testing.expectEqual(@as(usize, 1), plan.header.worktrees.len);
    try std.testing.expectEqualStrings("/abs/repo", plan.header.worktrees[0]);
    try std.testing.expectEqualStrings("/abs/art", plan.header.artifact_roots[0]);

    try std.testing.expectEqual(@as(usize, 2), plan.threads.len);
    try std.testing.expectEqualStrings("codex", plan.threadByName("impl").?.command);
    try std.testing.expectEqualStrings("Review carefully.", plan.threadByName("reviewer").?.default);

    try std.testing.expectEqual(@as(usize, 3), plan.nodes.len);
    const review = plan.nodeByName("review-1").?;
    try std.testing.expectEqual(Action.new, review.action);
    try std.testing.expectEqualStrings("prompts/review.md", review.use_path);
    try std.testing.expectEqual(@as(usize, 1), review.blocked_by.len);
    try std.testing.expectEqualStrings("impl-1", review.blocked_by[0]);

    const impl1 = plan.nodeByName("impl-1").?;
    try std.testing.expectEqual(@as(usize, 1), impl1.with.len);
    try std.testing.expectEqualStrings("plans/auth.md", impl1.with[0]);

    try std.testing.expect(plan.nodeByName("fix-1").?.raw);
    try std.testing.expect(!review.raw);
}

test "thread requires a non-empty command" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.MissingCommand, parse(a,
        \\[[thread]]
        \\name = "impl"
        \\
    ));
}

test "node referencing an unknown thread fails validation" {
    const a = std.testing.allocator;
    var plan = try parse(a,
        \\[[thread]]
        \\name = "impl"
        \\command = "codex"
        \\
        \\[[prompt]]
        \\name = "n1"
        \\thread = "ghost"
        \\
    );
    defer plan.deinit();
    try std.testing.expectError(error.UnknownThread, validate(&plan, a));
}

test "blocked_by referencing an unknown node fails validation" {
    const a = std.testing.allocator;
    var plan = try parse(a,
        \\[[thread]]
        \\name = "impl"
        \\command = "codex"
        \\
        \\[[prompt]]
        \\name = "n1"
        \\thread = "impl"
        \\blocked_by = ["ghost"]
        \\
    );
    defer plan.deinit();
    try std.testing.expectError(error.UnknownBlocker, validate(&plan, a));
}

test "duplicate node names fail validation" {
    const a = std.testing.allocator;
    var plan = try parse(a,
        \\[[thread]]
        \\name = "impl"
        \\command = "codex"
        \\
        \\[[prompt]]
        \\name = "dup"
        \\thread = "impl"
        \\
        \\[[prompt]]
        \\name = "dup"
        \\thread = "impl"
        \\
    );
    defer plan.deinit();
    try std.testing.expectError(error.DuplicateNode, validate(&plan, a));
}

test "a dependency cycle fails validation" {
    const a = std.testing.allocator;
    var plan = try parse(a,
        \\[[thread]]
        \\name = "impl"
        \\command = "codex"
        \\
        \\[[prompt]]
        \\name = "a"
        \\thread = "impl"
        \\blocked_by = ["b"]
        \\
        \\[[prompt]]
        \\name = "b"
        \\thread = "impl"
        \\blocked_by = ["a"]
        \\
    );
    defer plan.deinit();
    try std.testing.expectError(error.Cycle, validate(&plan, a));
}

test "a known field with the wrong TOML type is rejected, not silently dropped" {
    const a = std.testing.allocator;
    // `blocked_by` must be an array. A bare string must error rather than
    // collapse to "no blockers" and let `b` run before `a`.
    try std.testing.expectError(error.TypeMismatch, parse(a,
        \\[[thread]]
        \\name = "impl"
        \\command = "codex"
        \\
        \\[[prompt]]
        \\name = "a"
        \\thread = "impl"
        \\
        \\[[prompt]]
        \\name = "b"
        \\thread = "impl"
        \\blocked_by = "a"
        \\
    ));
}

test "an invalid action is rejected at parse" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.BadAction, parse(a,
        \\[[thread]]
        \\name = "impl"
        \\command = "codex"
        \\
        \\[[prompt]]
        \\name = "n1"
        \\thread = "impl"
        \\action = "reboot"
        \\
    ));
}

test "emit round-trips a parsed plan" {
    const a = std.testing.allocator;
    var first = try parse(a, sample_plan);
    defer first.deinit();

    const text = try emitAlloc(a, &first);
    defer a.free(text);

    var second = try parse(a, text);
    defer second.deinit();
    try validate(&second, a);

    try std.testing.expectEqualStrings(first.header.name, second.header.name);
    try std.testing.expectEqualStrings(first.header.cwd, second.header.cwd);
    try std.testing.expectEqual(first.threads.len, second.threads.len);
    try std.testing.expectEqual(first.nodes.len, second.nodes.len);
    try std.testing.expectEqualStrings("Review carefully.", second.threadByName("reviewer").?.default);

    const fix = second.nodeByName("fix-1").?;
    try std.testing.expectEqual(Action.compact, fix.action);
    try std.testing.expect(fix.raw);
    try std.testing.expectEqualStrings("review-1", fix.blocked_by[0]);
    const impl1 = second.nodeByName("impl-1").?;
    try std.testing.expectEqualStrings("plans/auth.md", impl1.with[0]);
}

test "addNode and addBlocker mutate the graph" {
    const a = std.testing.allocator;
    var p = try parse(a, sample_plan);
    defer p.deinit();

    try p.addNode(.{
        .name = "fix-2",
        .thread = "impl",
        .action = .compact,
        .use_path = "",
        .with = &.{},
        .body = "Apply the second round of fixes.",
        .blocked_by = &.{"review-1"},
        .raw = false,
    });
    try std.testing.expectEqual(@as(usize, 4), p.nodes.len);
    try std.testing.expectEqualStrings("fix-2", p.nodes[3].name);
    try std.testing.expectEqualStrings("review-1", p.nodes[3].blocked_by[0]);

    // Gate an existing queued node on the new one; idempotent.
    try std.testing.expect(try p.addBlocker("fix-1", "fix-2"));
    try std.testing.expect(try p.addBlocker("fix-1", "fix-2"));
    try std.testing.expectEqual(@as(usize, 2), p.nodeByName("fix-1").?.blocked_by.len);
    try std.testing.expect(!try p.addBlocker("ghost", "fix-2"));
    try validate(&p, a);
}

test "unknown header and node keys are ignored" {
    const a = std.testing.allocator;
    var plan = try parse(a,
        \\name = "s"
        \\future_header_field = "ok"
        \\
        \\[[thread]]
        \\name = "impl"
        \\command = "codex"
        \\
        \\[[prompt]]
        \\name = "n1"
        \\thread = "impl"
        \\future_node_field = "ok"
        \\
    );
    defer plan.deinit();
    try validate(&plan, a);
    try std.testing.expectEqual(@as(usize, 1), plan.nodes.len);
}
