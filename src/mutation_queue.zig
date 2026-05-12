//! Single-writer mutation queue (milestone 5).
//!
//! Per `todos/design_daemon.md`: every stack-mutation request goes through
//! one daemon-owned worker that drains a FIFO queue. The worker:
//!
//!   1. Optionally checks for VCS conflicts on the targeted paths.
//!   2. Calls into `mutations.zig` to perform the on-disk write.
//!   3. Stages + commits the affected paths in the notes repo.
//!   4. Appends a single audit-log entry.
//!   5. Wakes the originating HTTP handler with the result.
//!
//! Concurrency model: callers (HTTP handlers) hold their connection thread,
//! enqueue a request, and `wait()` on the request's condvar. The worker
//! pops requests in arrival order, processes them, and signals the
//! per-request done flag.
//!
//! This is what gives the daemon its "exactly one commit per mutation,
//! audit order matches queue order" guarantee.

const std = @import("std");
const mutations = @import("mutations.zig");
const audit = @import("audit.zig");
const vcs = @import("vcs.zig");

pub const RequestKind = union(enum) {
    create_stack: mutations.CreateStackInput,
    append_item: mutations.AppendItemInput,
    insert_item: mutations.InsertItemInput,
    transition: mutations.TransitionInput,
    pause_stack: struct { stack: []const u8 },
    resume_stack: struct { stack: []const u8 },
    config_patch: struct { stack: []const u8, patches: []const mutations.ConfigPatch },
    /// Internal: runtime-initiated transition (queued↔running↔terminal).
    /// Not reachable from the HTTP API; the runtime / session manager
    /// submits these to keep all writes single-writer.
    runtime_transition: RuntimeTransitionInput,
};

/// Status targets the runtime can request via `runtime_transition`. The
/// queue maps these to `mutations.applyRuntimeTransition`.
pub const RuntimeTargetStatus = enum {
    running,
    completed,
    failed,
    canceled,
    blocked,
    paused,
    queued,
};

pub const RuntimeTransitionInput = struct {
    stack: []const u8,
    id: []const u8,
    to: RuntimeTargetStatus,
    failed_reason: ?[]const u8 = null,
    blocked_reason: ?[]const u8 = null,
    canceled_by: ?[]const u8 = null,
    /// Optional terminal `[result]` block to record on the item. Used when
    /// completing or failing a harness session.
    result_harness: ?[]const u8 = null,
    result_model: ?[]const u8 = null,
    result_session_id: ?[]const u8 = null,
    result_session_file: ?[]const u8 = null,
    result_transcript_path: ?[]const u8 = null,
    result_exit_code: ?i64 = null,
    result_completed_at: ?[]const u8 = null,
};

pub const RequestError = error{
    QueueClosed,
    QueueFull,
} || mutations.Error || std.mem.Allocator.Error;

/// Per-request slot. The HTTP handler allocates this, hands it to the worker
/// via `submit`, then waits on `done_flag` for completion. The worker fills
/// `result` or `err`.
pub const Request = struct {
    kind: RequestKind,
    ident: mutations.IdentityCtx,

    // Result state (filled by the worker).
    done_mutex: std.Thread.Mutex = .{},
    done_cv: std.Thread.Condition = .{},
    done: bool = false,

    /// Set when the mutation succeeded; the caller owns the allocations.
    /// Includes the commit SHA when committed (empty otherwise).
    output: ?mutations.MutationOutput = null,
    commit_short_sha: [12]u8 = std.mem.zeroes([12]u8),
    commit_short_sha_len: u8 = 0,

    /// Set when the mutation failed. The caller maps this to an error code.
    err: ?MutationFailureKind = null,
};

pub const MutationFailureKind = enum {
    invalid_name,
    name_reserved,
    already_exists,
    not_found,
    state_conflict,
    internal_state_only,
    validation_failed,
    vcs_conflict,
    vcs_dirty,
    git_not_found,
    git_failed,
    bad_config_key,
    bad_config_value,
    internal,
};

/// FIFO queue + worker thread.
pub const Queue = struct {
    allocator: std.mem.Allocator,
    notes_root_abs: []const u8,
    /// When true, mutations attempt git operations. Off in tests that don't
    /// want subprocess overhead; on by default in production.
    enable_git: bool = true,

    mutex: std.Thread.Mutex = .{},
    cv: std.Thread.Condition = .{},
    items: std.ArrayList(*Request) = .{},
    closed: bool = false,

    audit_writer: *audit.Writer,

    worker_thread: ?std.Thread = null,

    pub fn init(
        allocator: std.mem.Allocator,
        notes_root_abs: []const u8,
        audit_writer: *audit.Writer,
    ) Queue {
        return .{
            .allocator = allocator,
            .notes_root_abs = notes_root_abs,
            .audit_writer = audit_writer,
        };
    }

    pub fn deinit(self: *Queue) void {
        self.close();
        if (self.worker_thread) |t| {
            t.join();
            self.worker_thread = null;
        }
        self.items.deinit(self.allocator);
    }

    pub fn start(self: *Queue) !void {
        if (self.worker_thread != null) return;
        self.worker_thread = try std.Thread.spawn(.{}, workerMain, .{self});
    }

    pub fn close(self: *Queue) void {
        self.mutex.lock();
        self.closed = true;
        self.cv.broadcast();
        self.mutex.unlock();
    }

    /// Push a request onto the queue and wait for the worker to complete it.
    /// Returns when `req.done` is true. Caller owns `req.output` (if set).
    pub fn submitAndWait(self: *Queue, req: *Request) void {
        self.mutex.lock();
        if (self.closed) {
            self.mutex.unlock();
            req.done_mutex.lock();
            req.done = true;
            req.err = .internal;
            req.done_cv.broadcast();
            req.done_mutex.unlock();
            return;
        }
        self.items.append(self.allocator, req) catch {
            self.mutex.unlock();
            req.done_mutex.lock();
            req.done = true;
            req.err = .internal;
            req.done_cv.broadcast();
            req.done_mutex.unlock();
            return;
        };
        self.cv.signal();
        self.mutex.unlock();

        // Wait.
        req.done_mutex.lock();
        defer req.done_mutex.unlock();
        while (!req.done) req.done_cv.wait(&req.done_mutex);
    }

    fn dequeueOne(self: *Queue) ?*Request {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.items.items.len == 0 and !self.closed) {
            self.cv.wait(&self.mutex);
        }
        if (self.items.items.len == 0) return null;
        const r = self.items.orderedRemove(0);
        return r;
    }

    fn workerMain(self: *Queue) void {
        while (true) {
            const req = self.dequeueOne() orelse return;
            self.processOne(req);
            // Signal completion.
            req.done_mutex.lock();
            req.done = true;
            req.done_cv.broadcast();
            req.done_mutex.unlock();
        }
    }

    fn processOne(self: *Queue, req: *Request) void {
        // 1. Preflight: for mutations that overwrite an existing tracked
        //    file (stack.toml or an existing item's meta.toml), refuse if
        //    that path has uncommitted user edits.
        if (self.enable_git) {
            const preflight_paths = computePreflightPaths(self.allocator, self.notes_root_abs, req.kind) catch {
                req.err = .internal;
                return;
            };
            defer freePreflightPaths(self.allocator, preflight_paths);
            if (preflight_paths.len > 0) {
                if (vcs.assertPathsClean(self.allocator, self.notes_root_abs, preflight_paths)) |_| {} else |e| switch (e) {
                    error.HasDirtyTarget => {
                        req.err = .vcs_dirty;
                        return;
                    },
                    error.GitNotFound => {
                        req.err = .git_not_found;
                        return;
                    },
                    else => {
                        req.err = .git_failed;
                        return;
                    },
                }
            }
        }
        // 2. Run the mutation; this writes files.
        var maybe_output: ?mutations.MutationOutput = null;
        const op_err: ?MutationFailureKind = blk: {
            const out = switch (req.kind) {
                .create_stack => |inp| mutations.applyCreateStack(self.allocator, self.notes_root_abs, req.ident, inp),
                .append_item => |inp| mutations.applyAppendItem(self.allocator, self.notes_root_abs, req.ident, inp),
                .insert_item => |inp| mutations.applyInsertItem(self.allocator, self.notes_root_abs, req.ident, inp),
                .transition => |inp| mutations.applyTransition(self.allocator, self.notes_root_abs, req.ident, inp),
                .pause_stack => |p| mutations.applySetPaused(self.allocator, self.notes_root_abs, req.ident, p.stack, true),
                .resume_stack => |p| mutations.applySetPaused(self.allocator, self.notes_root_abs, req.ident, p.stack, false),
                .config_patch => |p| mutations.applyConfigPatch(self.allocator, self.notes_root_abs, req.ident, p.stack, p.patches),
                .runtime_transition => |inp| mutations.applyRuntimeTransition(self.allocator, self.notes_root_abs, req.ident, .{
                    .stack = inp.stack,
                    .id = inp.id,
                    .to = switch (inp.to) {
                        .running => .running,
                        .completed => .completed,
                        .failed => .failed,
                        .canceled => .canceled,
                        .blocked => .blocked,
                        .paused => .paused,
                        .queued => .queued,
                    },
                    .failed_reason = inp.failed_reason,
                    .blocked_reason = inp.blocked_reason,
                    .canceled_by = inp.canceled_by,
                    .result_harness = inp.result_harness,
                    .result_model = inp.result_model,
                    .result_session_id = inp.result_session_id,
                    .result_session_file = inp.result_session_file,
                    .result_transcript_path = inp.result_transcript_path,
                    .result_exit_code = inp.result_exit_code,
                    .result_completed_at = inp.result_completed_at,
                }),
            } catch |e| break :blk mutationErrorToKind(e);

            maybe_output = out;
            break :blk null;
        };
        if (op_err) |k| {
            req.err = k;
            return;
        }
        var out = maybe_output.?;
        // 3. Commit. Per design_version_control.md, the runtime-initiated
        //    `queued → running` transition is NOT committed (that would
        //    flood the history with intermediate status flips); only the
        //    one-per-harness-completion terminal transition is committed.
        const skip_commit = blk: {
            switch (req.kind) {
                .runtime_transition => |inp| {
                    if (inp.to == .running) break :blk true;
                },
                else => {},
            }
            break :blk false;
        };
        if (self.enable_git and !skip_commit) {
            const commit_res = vcs.commit(self.allocator, self.notes_root_abs, .{
                .paths = sliceConst(out.paths),
                .subject = out.commit_subject,
                .body = out.commit_body,
            }) catch |e| {
                vcs.rollbackPaths(self.allocator, self.notes_root_abs, sliceConst(out.paths)) catch {};
                out.deinit();
                req.err = switch (e) {
                    error.GitNotFound => .git_not_found,
                    else => .git_failed,
                };
                return;
            };
            req.commit_short_sha_len = commit_res.short_sha_len;
            std.mem.copyForwards(u8, &req.commit_short_sha, &commit_res.short_sha);
        }

        // 4. Audit-log entry. We skip writing a second audit line for the
        //    runtime `running` transition because the session manager
        //    already emitted a `dispatch_harness` event at spawn time.
        if (!skip_commit or req.kind != .runtime_transition) {
            self.audit_writer.append(.{
                .identity = req.ident.identity,
                .action = out.audit_action,
                .target = out.audit_target,
                .outcome = .allowed,
                .details = out.audit_details,
            }) catch {};
        }

        req.output = out;
    }

    fn sliceConst(s: [][]u8) []const []const u8 {
        return @ptrCast(s);
    }
};

/// Compute the set of TRACKED file paths that a mutation would overwrite,
/// for the purpose of refusing it when the user has uncommitted edits to
/// those files. Returns paths relative to repo root; caller frees them with
/// `freePreflightPaths`.
///
/// Append/insert produce brand-new files; their paths cannot be predicted
/// ahead of time without scanning the directory (and they aren't tracked
/// yet anyway), so they have no preflight paths.
fn computePreflightPaths(
    allocator: std.mem.Allocator,
    notes_root_abs: []const u8,
    kind: RequestKind,
) ![][]u8 {
    var out = std.ArrayList([]u8){};
    errdefer {
        for (out.items) |p| allocator.free(p);
        out.deinit(allocator);
    }
    switch (kind) {
        .pause_stack => |p| {
            const path = try std.fmt.allocPrint(allocator, "stacks/{s}/stack.toml", .{p.stack});
            try out.append(allocator, path);
        },
        .resume_stack => |p| {
            const path = try std.fmt.allocPrint(allocator, "stacks/{s}/stack.toml", .{p.stack});
            try out.append(allocator, path);
        },
        .config_patch => |p| {
            const path = try std.fmt.allocPrint(allocator, "stacks/{s}/stack.toml", .{p.stack});
            try out.append(allocator, path);
        },
        .insert_item => |inp| {
            const path = try std.fmt.allocPrint(allocator, "stacks/{s}", .{inp.stack});
            try out.append(allocator, path);
        },
        .transition => |inp| {
            // Find the item directory by scanning.
            const stack_abs = try std.fs.path.join(allocator, &.{ notes_root_abs, "stacks", inp.stack });
            defer allocator.free(stack_abs);
            var d = std.fs.openDirAbsolute(stack_abs, .{ .iterate = true }) catch return out.toOwnedSlice(allocator);
            defer d.close();
            var it = d.iterate();
            while (it.next() catch null) |entry| {
                if (entry.kind != .directory) continue;
                const dash = std.mem.indexOfScalar(u8, entry.name, '-') orelse continue;
                if (std.mem.eql(u8, entry.name[0..dash], inp.id)) {
                    const path = try std.fmt.allocPrint(allocator, "stacks/{s}/{s}/meta.toml", .{ inp.stack, entry.name });
                    try out.append(allocator, path);
                    break;
                }
            }
        },
        else => {},
    }
    return out.toOwnedSlice(allocator);
}

fn freePreflightPaths(allocator: std.mem.Allocator, paths: [][]u8) void {
    for (paths) |p| allocator.free(p);
    allocator.free(paths);
}

fn mutationErrorToKind(e: anyerror) MutationFailureKind {
    return switch (e) {
        error.InvalidName => .invalid_name,
        error.NameReserved => .name_reserved,
        error.AlreadyExists => .already_exists,
        error.NotFound => .not_found,
        error.InvalidStateTransition => .state_conflict,
        error.InternalStateOnly => .internal_state_only,
        error.ValidationFailed, error.BadType => .validation_failed,
        error.DirtyTarget => .vcs_dirty,
        error.BadConfigKey => .bad_config_key,
        error.BadConfigValue => .bad_config_value,
        else => .internal,
    };
}

// ---------- tests ----------

test "Queue: serial submission processes in order" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("stacks");
    try tmp.dir.makePath(".organo");
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = try tmp.dir.realpath(".", &buf);

    var aw = try audit.Writer.init(a, abs);
    defer aw.deinit();

    var q = Queue.init(a, abs, &aw);
    q.enable_git = false;
    defer q.deinit();
    try q.start();

    var r1 = Request{
        .kind = .{ .create_stack = .{ .name = "first", .created_at_override = "2026-05-10T14:00:00Z" } },
        .ident = .{ .api_path = "POST /stacks" },
    };
    var r2 = Request{
        .kind = .{ .create_stack = .{ .name = "second", .created_at_override = "2026-05-10T14:00:00Z" } },
        .ident = .{ .api_path = "POST /stacks" },
    };
    q.submitAndWait(&r1);
    q.submitAndWait(&r2);

    try std.testing.expect(r1.output != null);
    try std.testing.expect(r2.output != null);
    if (r1.output) |*o| o.deinit();
    if (r2.output) |*o| o.deinit();

    // Both stacks were created.
    try tmp.dir.access("stacks/first/stack.toml", .{});
    try tmp.dir.access("stacks/second/stack.toml", .{});
}

test "Queue: duplicate stack rejected with already_exists" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("stacks/dup");
    try tmp.dir.makePath(".organo");
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = try tmp.dir.realpath(".", &buf);

    var aw = try audit.Writer.init(a, abs);
    defer aw.deinit();
    var q = Queue.init(a, abs, &aw);
    q.enable_git = false;
    defer q.deinit();
    try q.start();

    var r1 = Request{
        .kind = .{ .create_stack = .{ .name = "dup", .created_at_override = "2026-05-10T14:00:00Z" } },
        .ident = .{ .api_path = "POST /stacks" },
    };
    q.submitAndWait(&r1);
    try std.testing.expect(r1.err != null);
    try std.testing.expectEqual(MutationFailureKind.already_exists, r1.err.?);
}
