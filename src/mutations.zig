//! Pure mutation operations (milestone 5).
//!
//! Each `apply*` function is a transaction: it computes the on-disk shape,
//! writes the affected files, returns the list of relative paths that were
//! created or modified, and produces a commit subject/body. The caller (the
//! mutation queue worker) is responsible for staging+committing those paths
//! and appending an audit-log line.
//!
//! Functions in here may write directly to the notes root. They do NOT
//! invoke git or the audit log; that orchestration is one level up so the
//! same code path can be reused by tests and the queue.

const std = @import("std");
const item_mod = @import("item.zig");
const output_packet = @import("output_packet.zig");
const prompt_materializer = @import("prompt_materializer.zig");
const routine_mod = @import("routine.zig");
const stack_config = @import("stack_config.zig");
const stack_thread = @import("stack_thread.zig");
const state = @import("state.zig");
const storage = @import("storage.zig");
const audit = @import("audit.zig");

pub const Error = error{
    InvalidName,
    NameReserved,
    AlreadyExists,
    NotFound,
    InvalidStateTransition,
    InternalStateOnly,
    BadType,
    ValidationFailed,
    DirtyTarget,
    BadConfigKey,
    BadConfigValue,
    BadThreadKey,
    BadThreadValue,
} || anyerror;

/// Bundle of information one mutation produces. Owned by the caller; freed
/// with `deinit`.
pub const MutationOutput = struct {
    allocator: std.mem.Allocator,
    /// Paths (relative to notes root) the caller should `git add` + commit.
    paths: [][]u8,
    /// Commit subject; first line of the message.
    commit_subject: []u8,
    /// Commit body (multi-line); the queue appends standard fields.
    commit_body: []u8,
    /// Audit action.
    audit_action: audit.Action,
    /// Audit target (e.g. "stack/default" or "stack/default/item/0007").
    audit_target: []u8,
    /// Optional details for audit + JSON response.
    audit_details: []audit.DetailKV,
    /// Owned backing storage for audit detail values.
    detail_storage: []u8,
    /// Whether a follow-up "no-op" should be reported (e.g. pausing an
    /// already-paused stack).
    no_op: bool = false,

    pub fn deinit(self: *MutationOutput) void {
        for (self.paths) |p| self.allocator.free(p);
        self.allocator.free(self.paths);
        self.allocator.free(self.commit_subject);
        self.allocator.free(self.commit_body);
        self.allocator.free(self.audit_target);
        self.allocator.free(self.audit_details);
        self.allocator.free(self.detail_storage);
    }
};

/// Identity context passed through every mutation.
pub const IdentityCtx = struct {
    /// Identity slug ("local" for the loopback user; richer per-identity
    /// lookup lands in milestone 10).
    identity: []const u8 = "local",
    /// HTTP path of the originating endpoint, used in commit messages.
    api_path: []const u8,
};

// ---------- name validation ----------

const RESERVED_STACK_NAMES = [_][]const u8{
    "stacks", "state", ".git",
};

pub fn validateNewStackName(name: []const u8) Error!void {
    // Check reserved names first (including those that start with '.').
    for (RESERVED_STACK_NAMES) |r| {
        if (std.mem.eql(u8, name, r)) return error.NameReserved;
    }
    if (!storage.isValidStackName(name)) return error.InvalidName;
}

// ---------- create stack ----------

pub const CreateStackInput = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    /// Override for stack.toml `created_at`. When null, current UTC is used.
    created_at_override: ?[]const u8 = null,
    continuity: ?stack_config.Continuity = null,
    paused: ?bool = null,
    max_concurrent_per_stack: ?i64 = null,
    default_workdir: ?[]const u8 = null,
    allowed_harnesses: ?[]const []const u8 = null,
};

pub fn applyCreateStack(
    allocator: std.mem.Allocator,
    notes_root_abs: []const u8,
    ident: IdentityCtx,
    input: CreateStackInput,
) Error!MutationOutput {
    try validateNewStackName(input.name);
    if (input.max_concurrent_per_stack) |m| {
        if (m < 1) return error.ValidationFailed;
    }

    // Refuse if stack already exists.
    const stack_dir = try std.fs.path.join(allocator, &.{ notes_root_abs, "stacks", input.name });
    defer allocator.free(stack_dir);
    if (dirExists(stack_dir)) return error.AlreadyExists;

    // Create the directory.
    try std.fs.cwd().makePath(stack_dir);

    // Build stack.toml content.
    var buf = std.ArrayList(u8){};
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);

    var ts_buf: [40]u8 = undefined;
    const created_at = input.created_at_override orelse audit.nowRfc3339Millis(&ts_buf);

    if (input.description) |d| {
        try w.writeAll("description = \"");
        try writeTomlString(w, d);
        try w.writeAll("\"\n");
    }
    try w.writeAll("created_at = ");
    try w.writeAll(created_at);
    try w.writeByte('\n');
    if (input.paused) |p| try w.print("paused = {s}\n", .{if (p) "true" else "false"});
    if (input.continuity) |c| try w.print("continuity = \"{s}\"\n", .{c.toString()});
    if (input.max_concurrent_per_stack) |m| try w.print("max_concurrent_per_stack = {d}\n", .{m});
    if (input.default_workdir) |s| {
        try w.writeAll("default_workdir = \"");
        try writeTomlString(w, s);
        try w.writeAll("\"\n");
    }
    if (input.allowed_harnesses) |arr| {
        try w.writeAll("allowed_harnesses = [");
        for (arr, 0..) |h, i| {
            if (i != 0) try w.writeAll(", ");
            try w.writeAll("\"");
            try writeTomlString(w, h);
            try w.writeAll("\"");
        }
        try w.writeAll("]\n");
    }

    // Write the file.
    const file_rel = try stackConfigRel(allocator, input.name);
    defer allocator.free(file_rel);
    const file_abs = try std.fs.path.join(allocator, &.{ notes_root_abs, file_rel });
    defer allocator.free(file_abs);
    {
        var f = try std.fs.cwd().createFile(file_abs, .{ .truncate = true });
        defer f.close();
        try f.writeAll(buf.items);
    }

    // Build the MutationOutput.
    var paths_list = std.ArrayList([]u8){};
    errdefer {
        for (paths_list.items) |p| allocator.free(p);
        paths_list.deinit(allocator);
    }
    try paths_list.append(allocator, try allocator.dupe(u8, file_rel));

    const subject = try std.fmt.allocPrint(allocator, "stack: create {s}", .{input.name});
    errdefer allocator.free(subject);
    const body = try std.fmt.allocPrint(allocator, "stack: {s}\nidentity: {s}\napi: {s}\n", .{ input.name, ident.identity, ident.api_path });
    errdefer allocator.free(body);
    const target = try std.fmt.allocPrint(allocator, "stack/{s}", .{input.name});
    errdefer allocator.free(target);
    const details = try allocator.alloc(audit.DetailKV, 0);

    return .{
        .allocator = allocator,
        .paths = try paths_list.toOwnedSlice(allocator),
        .commit_subject = subject,
        .commit_body = body,
        .audit_action = .create_stack,
        .audit_target = target,
        .audit_details = details,
        .detail_storage = try allocator.alloc(u8, 0),
    };
}

// ---------- append item ----------

pub const AppendItemInput = struct {
    stack: []const u8,
    /// Item kind. Required.
    kind: []const u8,
    /// Slug. Required.
    slug: []const u8,
    /// Optional initial prompt body (written to prompt.md when kind=prompt).
    prompt_body: ?[]const u8 = null,
    /// Optional [target] block. All sub-fields are optional.
    target_provider: ?[]const u8 = null,
    target_model: ?[]const u8 = null,
    target_match: ?item_mod.Match = null,
    target_workdir: ?[]const u8 = null,
    input_items: ?[]const []const u8 = null,
    input_files: ?[]const []const u8 = null,
    input_commits: ?[]const []const u8 = null,
    input_mode: ?item_mod.InputMode = null,
    thread_name: ?[]const u8 = null,
    thread_mode: ?item_mod.ThreadMode = null,
    /// Parents (e.g. for review items).
    parents: ?[]const []const u8 = null,
    /// Sleep `until` (RFC3339); required when kind=sleep.
    sleep_until: ?[]const u8 = null,
    /// When non-null, override `created_at` (for deterministic fixtures).
    created_at_override: ?[]const u8 = null,
};

pub const AppendRoutineInput = struct {
    stack: []const u8,
    routine: *const routine_mod.Routine,
    input_items: ?[]const []const u8 = null,
    input_files: ?[]const []const u8 = null,
    input_commits: ?[]const []const u8 = null,
    input_mode: ?item_mod.InputMode = null,
    created_at_override: ?[]const u8 = null,
};

pub fn applyAppendItem(
    allocator: std.mem.Allocator,
    notes_root_abs: []const u8,
    ident: IdentityCtx,
    input: AppendItemInput,
) Error!MutationOutput {
    // Validate stack name and presence.
    if (!storage.isValidStackName(input.stack)) return error.InvalidName;
    const stack_abs = try std.fs.path.join(allocator, &.{ notes_root_abs, "stacks", input.stack });
    defer allocator.free(stack_abs);
    if (!dirExists(stack_abs)) return error.NotFound;

    // Validate slug.
    if (!item_mod.isValidSlug(input.slug)) return error.ValidationFailed;

    // Validate kind.
    const kind = item_mod.Kind.fromString(input.kind) orelse return error.ValidationFailed;

    // Compute next id by scanning existing items.
    const next_id_int = try computeNextItemIdInt(allocator, stack_abs);
    var id_buf: [16]u8 = undefined;
    const id = try std.fmt.bufPrint(&id_buf, "{d:0>4}", .{next_id_int});

    return writeItem(allocator, notes_root_abs, ident, .append_item, input.stack, id, kind, input.slug, .{
        .prompt_body = input.prompt_body,
        .target_provider = input.target_provider,
        .target_model = input.target_model,
        .target_match = input.target_match,
        .target_workdir = input.target_workdir,
        .input_items = input.input_items,
        .input_files = input.input_files,
        .input_commits = input.input_commits,
        .input_mode = input.input_mode,
        .thread_name = input.thread_name,
        .thread_mode = input.thread_mode,
        .parents = input.parents,
        .sleep_until = input.sleep_until,
        .created_at_override = input.created_at_override,
    });
}

pub fn applyAppendRoutine(
    allocator: std.mem.Allocator,
    notes_root_abs: []const u8,
    ident: IdentityCtx,
    input: AppendRoutineInput,
) Error!MutationOutput {
    if (!storage.isValidStackName(input.stack)) return error.InvalidName;
    const stack_abs = try std.fs.path.join(allocator, &.{ notes_root_abs, "stacks", input.stack });
    defer allocator.free(stack_abs);
    if (!dirExists(stack_abs)) return error.NotFound;

    const order = input.routine.topologicalOrder(allocator) catch return error.ValidationFailed;
    defer allocator.free(order);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const next_id_int = try computeNextItemIdInt(allocator, stack_abs);
    const step_ids = try aa.alloc([]const u8, input.routine.steps.len);
    for (order, 0..) |step_index, seq| {
        const id_int: u32 = next_id_int + @as(u32, @intCast(seq));
        step_ids[step_index] = try std.fmt.allocPrint(aa, "{d:0>4}", .{id_int});
    }

    const prompt_bodies = try aa.alloc(?[]const u8, input.routine.steps.len);
    const effective_thread_modes = try aa.alloc(?item_mod.ThreadMode, input.routine.steps.len);
    var missing_threads = std.ArrayList([]const u8){};
    defer missing_threads.deinit(allocator);
    @memset(effective_thread_modes, null);
    for (input.routine.steps, 0..) |*step, i| {
        if (step.command == null) {
            const body = input.routine.resolvePrompt(allocator, step) catch return error.ValidationFailed;
            prompt_bodies[i] = try aa.dupe(u8, body);
            allocator.free(body);
        } else {
            prompt_bodies[i] = null;
        }

        if (step.thread) |thread_name| {
            const thread_abs = try std.fs.path.join(allocator, &.{ notes_root_abs, "stacks", input.stack, "threads", try std.fmt.allocPrint(aa, "{s}.toml", .{thread_name}) });
            defer allocator.free(thread_abs);
            var th = readThreadFile(allocator, thread_abs) catch |e| switch (e) {
                error.NotFound => {
                    try appendUniqueThreadName(allocator, &missing_threads, thread_name);
                    effective_thread_modes[i] = .fresh;
                    continue;
                },
                else => return error.ValidationFailed,
            };
            defer th.deinit();
            if (th.status != .active) return error.ValidationFailed;
            effective_thread_modes[i] = if (threadHasSession(&th)) .@"resume" else .fresh;
        }
    }

    for (order) |step_index| {
        const step = &input.routine.steps[step_index];
        try validateExpandedRoutineStep(allocator, notes_root_abs, input.stack, step, effective_thread_modes[step_index], true, step_ids[step_index], &.{}, .{
            .input_items = input.input_items,
            .input_files = input.input_files,
            .input_commits = input.input_commits,
            .input_mode = input.input_mode,
        }, input.created_at_override);
    }

    var paths_list = std.ArrayList([]u8){};
    errdefer {
        for (paths_list.items) |p| allocator.free(p);
        paths_list.deinit(allocator);
    }

    for (missing_threads.items) |thread_name| {
        const rel = try createRoutineThread(allocator, notes_root_abs, input.stack, thread_name, input.created_at_override);
        try appendPathUnique(allocator, &paths_list, rel);
    }

    for (order) |step_index| {
        const step = &input.routine.steps[step_index];
        var out = try writeItem(allocator, notes_root_abs, ident, .append_item, input.stack, step_ids[step_index], step.kind, step.slug, .{
            .prompt_body = prompt_bodies[step_index],
            .input_items = input.input_items,
            .input_files = input.input_files,
            .input_commits = input.input_commits,
            .input_mode = input.input_mode,
            .thread_name = step.thread,
            .thread_mode = effective_thread_modes[step_index],
            .created_at_override = input.created_at_override,
        });
        defer out.deinit();
        for (out.paths) |p| try paths_list.append(allocator, try allocator.dupe(u8, p));
    }

    const subject = try std.fmt.allocPrint(allocator, "routine: append {s} to {s}", .{ input.routine.name, input.stack });
    errdefer allocator.free(subject);
    const body = try std.fmt.allocPrint(allocator, "stack: {s}\nroutine: {s}\nsteps: {d}\nidentity: {s}\napi: {s}\n", .{ input.stack, input.routine.name, input.routine.steps.len, ident.identity, ident.api_path });
    errdefer allocator.free(body);
    const target = try std.fmt.allocPrint(allocator, "stack/{s}/routine/{s}", .{ input.stack, input.routine.name });
    errdefer allocator.free(target);

    var details_buf = std.ArrayList(u8){};
    errdefer details_buf.deinit(allocator);
    try details_buf.appendSlice(allocator, input.routine.name);
    try details_buf.append(allocator, 0);
    const steps_str_start = details_buf.items.len;
    try details_buf.writer(allocator).print("{d}", .{input.routine.steps.len});
    const detail_storage = try details_buf.toOwnedSlice(allocator);
    errdefer allocator.free(detail_storage);
    const details = try allocator.alloc(audit.DetailKV, 2);
    errdefer allocator.free(details);
    details[0] = .{ .key = "routine", .value = detail_storage[0..input.routine.name.len] };
    details[1] = .{ .key = "steps", .value = detail_storage[steps_str_start..] };

    return .{
        .allocator = allocator,
        .paths = try paths_list.toOwnedSlice(allocator),
        .commit_subject = subject,
        .commit_body = body,
        .audit_action = .append_routine,
        .audit_target = target,
        .audit_details = details,
        .detail_storage = detail_storage,
    };
}

// ---------- insert item ----------

pub const InsertItemInput = struct {
    stack: []const u8,
    /// Reference id; the new item is inserted such that its id sorts BEFORE
    /// `ref`. v1 simplification: we don't renumber existing items. Instead,
    /// the new item gets the next free id; if that id sorts after `ref`, we
    /// reject the call. (Full renumbering can land later if needed.)
    ref: []const u8,
    kind: []const u8,
    slug: []const u8,
    prompt_body: ?[]const u8 = null,
    target_provider: ?[]const u8 = null,
    target_model: ?[]const u8 = null,
    target_match: ?item_mod.Match = null,
    target_workdir: ?[]const u8 = null,
    input_items: ?[]const []const u8 = null,
    input_files: ?[]const []const u8 = null,
    input_commits: ?[]const []const u8 = null,
    input_mode: ?item_mod.InputMode = null,
    thread_name: ?[]const u8 = null,
    thread_mode: ?item_mod.ThreadMode = null,
    parents: ?[]const []const u8 = null,
    sleep_until: ?[]const u8 = null,
    created_at_override: ?[]const u8 = null,
};

pub fn applyInsertItem(
    allocator: std.mem.Allocator,
    notes_root_abs: []const u8,
    ident: IdentityCtx,
    input: InsertItemInput,
) Error!MutationOutput {
    if (!storage.isValidStackName(input.stack)) return error.InvalidName;
    const stack_abs = try std.fs.path.join(allocator, &.{ notes_root_abs, "stacks", input.stack });
    defer allocator.free(stack_abs);
    if (!dirExists(stack_abs)) return error.NotFound;

    if (!item_mod.isValidId(input.ref)) return error.ValidationFailed;
    // Confirm the reference item exists.
    const ref_dir = (try findItemDir(allocator, stack_abs, input.ref)) orelse return error.NotFound;
    allocator.free(ref_dir);

    if (!item_mod.isValidSlug(input.slug)) return error.ValidationFailed;
    const kind = item_mod.Kind.fromString(input.kind) orelse return error.ValidationFailed;

    const ref_int = std.fmt.parseInt(u32, input.ref, 10) catch return error.ValidationFailed;
    try renumberItemsFrom(allocator, stack_abs, ref_int);

    return writeItem(allocator, notes_root_abs, ident, .insert_item, input.stack, input.ref, kind, input.slug, .{
        .prompt_body = input.prompt_body,
        .target_provider = input.target_provider,
        .target_model = input.target_model,
        .target_match = input.target_match,
        .target_workdir = input.target_workdir,
        .input_items = input.input_items,
        .input_files = input.input_files,
        .input_commits = input.input_commits,
        .input_mode = input.input_mode,
        .thread_name = input.thread_name,
        .thread_mode = input.thread_mode,
        .parents = input.parents,
        .sleep_until = input.sleep_until,
        .created_at_override = input.created_at_override,
        .commit_stack_dir = true,
    });
}

// ---------- status transitions ----------

/// Transitions allowed over the API. Internal-only transitions (running,
/// completed, failed, blocked←running) are rejected with InternalStateOnly.
pub const ApiTransition = enum {
    cancel,
    supersede,
    retry,

    pub fn targetStatus(self: ApiTransition) state.Status {
        return switch (self) {
            .cancel => .canceled,
            .supersede => .superseded,
            .retry => .queued,
        };
    }
};

pub const TransitionInput = struct {
    stack: []const u8,
    id: []const u8,
    transition: ApiTransition,
    /// For supersede: the replacement item id.
    superseded_by: ?[]const u8 = null,
};

pub fn applyTransition(
    allocator: std.mem.Allocator,
    notes_root_abs: []const u8,
    ident: IdentityCtx,
    input: TransitionInput,
) Error!MutationOutput {
    if (!storage.isValidStackName(input.stack)) return error.InvalidName;
    if (!item_mod.isValidId(input.id)) return error.ValidationFailed;
    const stack_abs = try std.fs.path.join(allocator, &.{ notes_root_abs, "stacks", input.stack });
    defer allocator.free(stack_abs);
    if (!dirExists(stack_abs)) return error.NotFound;

    const item_dir_name = (try findItemDir(allocator, stack_abs, input.id)) orelse return error.NotFound;
    defer allocator.free(item_dir_name);
    const meta_abs = try std.fs.path.join(allocator, &.{ stack_abs, item_dir_name, "meta.toml" });
    defer allocator.free(meta_abs);

    // Parse the existing item.
    var src_buf: []u8 = undefined;
    {
        var f = try std.fs.cwd().openFile(meta_abs, .{});
        defer f.close();
        const stat = try f.stat();
        src_buf = try allocator.alloc(u8, stat.size);
        _ = try f.readAll(src_buf);
    }
    defer allocator.free(src_buf);
    var diag: item_mod.ParseDiagnostic = .{};
    var item = item_mod.parseSlice(allocator, src_buf, &diag) catch return error.ValidationFailed;
    defer item.deinit();

    const target_status = input.transition.targetStatus();
    // Validate the transition against the API-allowed subset:
    switch (input.transition) {
        .cancel => {
            // Allowed from queued | paused | blocked | running.
            // For running we'd need session-manager interaction; v1 mutation
            // queue rejects mid-run cancel and points the user at the
            // session manager — but that hasn't landed yet, so reject.
            switch (item.status) {
                .queued, .paused, .blocked => {},
                .running => return error.InvalidStateTransition,
                else => return error.InvalidStateTransition,
            }
        },
        .supersede => {
            // Allowed from queued only (v1).
            if (item.status != .queued) return error.InvalidStateTransition;
            if (input.superseded_by == null) return error.ValidationFailed;
            if (!item_mod.isValidId(input.superseded_by.?)) return error.ValidationFailed;
        },
        .retry => {
            // Allowed only from blocked.
            if (item.status != .blocked) return error.InvalidStateTransition;
        },
    }
    if (!state.isValidTransition(item.status, target_status)) return error.InvalidStateTransition;

    // Apply the transition: rewrite meta.toml with the new status + reason
    // field, leaving everything else intact.
    item.status = target_status;
    switch (input.transition) {
        .cancel => {
            // Record canceled_by (use the identity).
            const arena = item.arena.allocator();
            const cb_buf = try std.fmt.allocPrint(arena, "user:{s}", .{ident.identity});
            item.canceled_by = cb_buf;
            // Clear blocked_reason if present.
            item.blocked_reason = null;
        },
        .supersede => {
            const arena = item.arena.allocator();
            item.superseded_by = try arena.dupe(u8, input.superseded_by.?);
        },
        .retry => {
            item.blocked_reason = null;
        },
    }
    // Bump updated_at.
    var ts_buf: [40]u8 = undefined;
    const now_str = audit.nowRfc3339Millis(&ts_buf);
    item.updated_at = try item.arena.allocator().dupe(u8, now_str);

    // Write back.
    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);
    const w = out.writer(allocator);
    try item_mod.write(&item, w);
    {
        var f = try std.fs.cwd().createFile(meta_abs, .{ .truncate = true });
        defer f.close();
        try f.writeAll(out.items);
    }

    // Build output.
    const action: audit.Action = switch (input.transition) {
        .cancel => .cancel_item,
        .supersede => .supersede_item,
        .retry => .retry_item,
    };
    const verb: []const u8 = switch (input.transition) {
        .cancel => "cancel",
        .supersede => "supersede",
        .retry => "retry",
    };
    const path_rel = try itemMetaRel(allocator, input.stack, item_dir_name);
    var paths_list = std.ArrayList([]u8){};
    errdefer {
        for (paths_list.items) |p| allocator.free(p);
        paths_list.deinit(allocator);
    }
    try paths_list.append(allocator, path_rel);

    const subject = try std.fmt.allocPrint(allocator, "item: {s} {s}", .{ verb, input.id });
    const body = try std.fmt.allocPrint(allocator, "stack: {s}\nitem: {s}\nidentity: {s}\napi: {s}\n", .{ input.stack, input.id, ident.identity, ident.api_path });
    const target = try std.fmt.allocPrint(allocator, "stack/{s}/item/{s}", .{ input.stack, input.id });
    const details = try allocator.alloc(audit.DetailKV, 0);

    return .{
        .allocator = allocator,
        .paths = try paths_list.toOwnedSlice(allocator),
        .commit_subject = subject,
        .commit_body = body,
        .audit_action = action,
        .audit_target = target,
        .audit_details = details,
        .detail_storage = try allocator.alloc(u8, 0),
    };
}

// ---------- edit a queued item's prompt ----------

pub const UpdateItemPromptInput = struct {
    stack: []const u8,
    id: []const u8,
    /// New prompt body, written verbatim to the item's `prompt.md`.
    prompt: []const u8,
};

/// Overwrite the prompt body of a queued prompt/review item. Rewrites
/// `prompt.md`, drops any stale `rendered_prompt.md` (the supervisor
/// regenerates it at dispatch), and bumps `updated_at`.
pub fn applyUpdateItemPrompt(
    allocator: std.mem.Allocator,
    notes_root_abs: []const u8,
    ident: IdentityCtx,
    input: UpdateItemPromptInput,
) Error!MutationOutput {
    if (!storage.isValidStackName(input.stack)) return error.InvalidName;
    if (!item_mod.isValidId(input.id)) return error.ValidationFailed;
    if (input.prompt.len > prompt_materializer.MAX_INPUT_BYTES) return error.ValidationFailed;
    const stack_abs = try std.fs.path.join(allocator, &.{ notes_root_abs, "stacks", input.stack });
    defer allocator.free(stack_abs);
    if (!dirExists(stack_abs)) return error.NotFound;

    const item_dir_name = (try findItemDir(allocator, stack_abs, input.id)) orelse return error.NotFound;
    defer allocator.free(item_dir_name);
    const meta_abs = try std.fs.path.join(allocator, &.{ stack_abs, item_dir_name, "meta.toml" });
    defer allocator.free(meta_abs);

    var src_buf: []u8 = undefined;
    {
        var f = try std.fs.cwd().openFile(meta_abs, .{});
        defer f.close();
        const stat = try f.stat();
        src_buf = try allocator.alloc(u8, stat.size);
        _ = try f.readAll(src_buf);
    }
    defer allocator.free(src_buf);
    var diag: item_mod.ParseDiagnostic = .{};
    var item = item_mod.parseSlice(allocator, src_buf, &diag) catch return error.ValidationFailed;
    defer item.deinit();

    // Editing in place is only safe before the item runs.
    if (item.status != .queued) return error.InvalidStateTransition;
    // Only prompt-bearing kinds have a prompt.md to overwrite.
    if (item.kind != .prompt and item.kind != .review) return error.ValidationFailed;
    // Items whose body is composed from a `prompts = [...]` file list have no
    // single prompt.md; those are edited at the source files instead.
    if (item.prompts != null) return error.ValidationFailed;

    const prompt_abs = try std.fs.path.join(allocator, &.{ stack_abs, item_dir_name, "prompt.md" });
    defer allocator.free(prompt_abs);
    {
        var f = try std.fs.cwd().createFile(prompt_abs, .{ .truncate = true });
        defer f.close();
        try f.writeAll(input.prompt);
    }

    var ts_buf: [40]u8 = undefined;
    const now_str = audit.nowRfc3339Millis(&ts_buf);
    item.updated_at = try item.arena.allocator().dupe(u8, now_str);
    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);
    try item_mod.write(&item, out.writer(allocator));
    {
        var f = try std.fs.cwd().createFile(meta_abs, .{ .truncate = true });
        defer f.close();
        try f.writeAll(out.items);
    }

    var paths_list = std.ArrayList([]u8){};
    errdefer {
        for (paths_list.items) |p| allocator.free(p);
        paths_list.deinit(allocator);
    }
    try paths_list.append(allocator, try itemMetaRel(allocator, input.stack, item_dir_name));
    try paths_list.append(allocator, try std.fmt.allocPrint(allocator, "stacks/{s}/{s}/prompt.md", .{ input.stack, item_dir_name }));
    if (try prompt_materializer.renderedPromptExists(allocator, notes_root_abs, input.stack, item_dir_name)) {
        const rendered_rel = try prompt_materializer.renderedPromptRel(allocator, input.stack, item_dir_name);
        const rendered_abs = try std.fs.path.join(allocator, &.{ notes_root_abs, rendered_rel });
        defer allocator.free(rendered_abs);
        std.fs.cwd().deleteFile(rendered_abs) catch {};
        try appendPathUnique(allocator, &paths_list, rendered_rel);
    }

    const subject = try std.fmt.allocPrint(allocator, "item: edit prompt {s}", .{input.id});
    const body = try std.fmt.allocPrint(allocator, "stack: {s}\nitem: {s}\nidentity: {s}\napi: {s}\n", .{ input.stack, input.id, ident.identity, ident.api_path });
    const target = try std.fmt.allocPrint(allocator, "stack/{s}/item/{s}", .{ input.stack, input.id });
    const details_buf = try allocator.alloc(u8, input.id.len);
    @memcpy(details_buf, input.id);
    const details = try allocator.alloc(audit.DetailKV, 1);
    details[0] = .{ .key = "id", .value = details_buf };

    return .{
        .allocator = allocator,
        .paths = try paths_list.toOwnedSlice(allocator),
        .commit_subject = subject,
        .commit_body = body,
        .audit_action = .update_item_prompt,
        .audit_target = target,
        .audit_details = details,
        .detail_storage = details_buf,
    };
}

// ---------- runtime-initiated transitions ----------

/// Status targets the runtime/session-manager may set. Internal-only.
pub const RuntimeStatus = enum {
    running,
    completed,
    failed,
    canceled,
    blocked,
    paused,
    queued,

    pub fn toStatus(self: RuntimeStatus) state.Status {
        return switch (self) {
            .running => .running,
            .completed => .completed,
            .failed => .failed,
            .canceled => .canceled,
            .blocked => .blocked,
            .paused => .paused,
            .queued => .queued,
        };
    }
};

pub const RuntimeTransitionInput = struct {
    stack: []const u8,
    id: []const u8,
    to: RuntimeStatus,
    failed_reason: ?[]const u8 = null,
    blocked_reason: ?[]const u8 = null,
    canceled_by: ?[]const u8 = null,
    result_harness: ?[]const u8 = null,
    result_model: ?[]const u8 = null,
    result_session_id: ?[]const u8 = null,
    result_session_file: ?[]const u8 = null,
    result_transcript_path: ?[]const u8 = null,
    result_exit_code: ?i64 = null,
    result_completed_at: ?[]const u8 = null,
    output_packet: ?output_packet.PacketInput = null,
};

pub const CreateThreadInput = struct {
    stack: []const u8,
    name: []const u8,
    target_provider: ?[]const u8 = null,
    target_model: ?[]const u8 = null,
    target_match: ?stack_thread.Match = null,
    created_at_override: ?[]const u8 = null,
};

pub const ThreadPatch = struct {
    /// Supported keys: target.provider, target.model, target.match,
    /// state.last_item_id, state.last_harness, state.last_session_id,
    /// state.last_session_file, state.last_transcript_path, status.
    key: []const u8,
    /// Null clears optional target/state fields. `status` cannot be cleared.
    value: ?[]const u8,
};

pub const PatchThreadInput = struct {
    stack: []const u8,
    name: []const u8,
    patches: []const ThreadPatch,
};

pub fn applyRuntimeTransition(
    allocator: std.mem.Allocator,
    notes_root_abs: []const u8,
    ident: IdentityCtx,
    input: RuntimeTransitionInput,
) Error!MutationOutput {
    if (!storage.isValidStackName(input.stack)) return error.InvalidName;
    if (!item_mod.isValidId(input.id)) return error.ValidationFailed;
    const stack_abs = try std.fs.path.join(allocator, &.{ notes_root_abs, "stacks", input.stack });
    defer allocator.free(stack_abs);
    if (!dirExists(stack_abs)) return error.NotFound;

    const item_dir_name = (try findItemDir(allocator, stack_abs, input.id)) orelse return error.NotFound;
    defer allocator.free(item_dir_name);
    const meta_abs = try std.fs.path.join(allocator, &.{ stack_abs, item_dir_name, "meta.toml" });
    defer allocator.free(meta_abs);

    var src_buf: []u8 = undefined;
    {
        var f = try std.fs.cwd().openFile(meta_abs, .{});
        defer f.close();
        const stat = try f.stat();
        src_buf = try allocator.alloc(u8, stat.size);
        _ = try f.readAll(src_buf);
    }
    defer allocator.free(src_buf);
    var diag: item_mod.ParseDiagnostic = .{};
    var item = item_mod.parseSlice(allocator, src_buf, &diag) catch return error.ValidationFailed;
    defer item.deinit();

    const target_status = input.to.toStatus();
    if (!state.isValidTransition(item.status, target_status)) return error.InvalidStateTransition;
    item.status = target_status;

    const arena = item.arena.allocator();
    if (input.failed_reason) |r| item.failed_reason = try arena.dupe(u8, r);
    if (input.blocked_reason) |r| item.blocked_reason = try arena.dupe(u8, r);
    if (input.canceled_by) |r| item.canceled_by = try arena.dupe(u8, r);

    // [result] block: written on terminal harness completion.
    const terminal = input.to == .completed or input.to == .failed or input.to == .canceled;
    if (terminal and (input.result_harness != null or input.result_session_id != null or input.result_exit_code != null or input.result_transcript_path != null)) {
        var r: item_mod.Result = .{};
        if (input.result_harness) |s| r.harness = try arena.dupe(u8, s);
        if (input.result_model) |s| r.model = try arena.dupe(u8, s);
        if (input.result_session_id) |s| r.session_id = try arena.dupe(u8, s);
        if (input.result_session_file) |s| r.session_file = try arena.dupe(u8, s);
        if (input.result_transcript_path) |s| r.transcript_path = try arena.dupe(u8, s);
        if (input.result_exit_code) |n| r.exit_code = n;
        if (input.result_completed_at) |s| r.completed_at = try arena.dupe(u8, s);
        item.result = r;
    }

    var ts_buf: [40]u8 = undefined;
    item.updated_at = try arena.dupe(u8, audit.nowRfc3339Millis(&ts_buf));

    var out_buf = std.ArrayList(u8){};
    defer out_buf.deinit(allocator);
    try item_mod.write(&item, out_buf.writer(allocator));
    {
        var f = try std.fs.cwd().createFile(meta_abs, .{ .truncate = true });
        defer f.close();
        try f.writeAll(out_buf.items);
    }

    const path_rel = try itemMetaRel(allocator, input.stack, item_dir_name);
    var paths_list = std.ArrayList([]u8){};
    errdefer {
        for (paths_list.items) |p| allocator.free(p);
        paths_list.deinit(allocator);
    }
    try paths_list.append(allocator, path_rel);

    if (terminal) {
        if (try prompt_materializer.renderedPromptExists(allocator, notes_root_abs, input.stack, item_dir_name)) {
            try appendPathUnique(allocator, &paths_list, try prompt_materializer.renderedPromptRel(allocator, input.stack, item_dir_name));
        }
        try appendTranscriptPathIfPresent(allocator, notes_root_abs, input.stack, item_dir_name, input.result_transcript_path, &paths_list);
        if (input.output_packet) |packet| {
            try appendNotesRootWorkdirPaths(allocator, notes_root_abs, packet, &paths_list);
        }
        if (target_status == .completed) {
            if (item.thread) |thread_ref| {
                const thread_rel = try updateThreadFromItemResult(allocator, notes_root_abs, input.stack, item_dir_name, thread_ref.name, input, item.result);
                try appendPathUnique(allocator, &paths_list, thread_rel);
            }
        }
    }

    const verb: []const u8 = switch (input.to) {
        .running => "running",
        .completed => "completed",
        .failed => "failed",
        .canceled => "canceled",
        .blocked => "blocked",
        .paused => "paused",
        .queued => "queued",
    };
    const subject = try std.fmt.allocPrint(allocator, "item: {s} → {s}", .{ input.id, verb });
    const body_str = try std.fmt.allocPrint(allocator, "stack: {s}\nitem: {s}\nidentity: {s}\napi: {s}\n", .{ input.stack, input.id, ident.identity, ident.api_path });
    const target = try std.fmt.allocPrint(allocator, "stack/{s}/item/{s}", .{ input.stack, input.id });
    const details = try allocator.alloc(audit.DetailKV, 0);

    return .{
        .allocator = allocator,
        .paths = try paths_list.toOwnedSlice(allocator),
        .commit_subject = subject,
        .commit_body = body_str,
        .audit_action = .dispatch_harness,
        .audit_target = target,
        .audit_details = details,
        .detail_storage = try allocator.alloc(u8, 0),
    };
}

pub fn applyCreateThread(
    allocator: std.mem.Allocator,
    notes_root_abs: []const u8,
    ident: IdentityCtx,
    input: CreateThreadInput,
) Error!MutationOutput {
    if (!storage.isValidStackName(input.stack)) return error.InvalidName;
    if (!stack_thread.isValidName(input.name)) return error.InvalidName;
    const stack_abs = try std.fs.path.join(allocator, &.{ notes_root_abs, "stacks", input.stack });
    defer allocator.free(stack_abs);
    if (!dirExists(stack_abs)) return error.NotFound;

    const rel = try threadRel(allocator, input.stack, input.name);
    errdefer allocator.free(rel);
    const abs = try std.fs.path.join(allocator, &.{ notes_root_abs, rel });
    defer allocator.free(abs);
    if (fileExists(abs)) return error.AlreadyExists;
    const dir_abs = try std.fs.path.join(allocator, &.{ stack_abs, "threads" });
    defer allocator.free(dir_abs);
    try std.fs.cwd().makePath(dir_abs);

    var ts_buf: [40]u8 = undefined;
    const now = input.created_at_override orelse audit.nowRfc3339Millis(&ts_buf);
    var thread: stack_thread.Thread = .{
        .arena = std.heap.ArenaAllocator.init(allocator),
        .name = input.name,
        .created_at = now,
        .updated_at = now,
        .status = .active,
    };
    defer thread.deinit();
    const aa = thread.arena.allocator();
    thread.name = try aa.dupe(u8, input.name);
    thread.created_at = try aa.dupe(u8, now);
    thread.updated_at = try aa.dupe(u8, now);
    const has_target = input.target_provider != null or input.target_model != null or input.target_match != null;
    if (has_target) {
        var target: stack_thread.Target = .{};
        if (input.target_provider) |s| target.provider = try aa.dupe(u8, s);
        if (input.target_model) |s| target.model = try aa.dupe(u8, s);
        target.match = input.target_match;
        thread.target = target;
    }

    try writeThreadFile(allocator, abs, &thread);
    return threadMutationOutput(allocator, ident, input.stack, input.name, rel, .create_thread, "create");
}

pub fn applyPatchThread(
    allocator: std.mem.Allocator,
    notes_root_abs: []const u8,
    ident: IdentityCtx,
    input: PatchThreadInput,
) Error!MutationOutput {
    if (!storage.isValidStackName(input.stack)) return error.InvalidName;
    if (!stack_thread.isValidName(input.name)) return error.InvalidName;
    if (input.patches.len == 0) return error.BadThreadValue;
    const stack_abs = try std.fs.path.join(allocator, &.{ notes_root_abs, "stacks", input.stack });
    defer allocator.free(stack_abs);
    if (!dirExists(stack_abs)) return error.NotFound;

    const rel = try threadRel(allocator, input.stack, input.name);
    errdefer allocator.free(rel);
    const abs = try std.fs.path.join(allocator, &.{ notes_root_abs, rel });
    defer allocator.free(abs);
    var thread = try readThreadFile(allocator, abs);
    defer thread.deinit();
    if (!std.mem.eql(u8, thread.name, input.name)) return error.ValidationFailed;

    try applyThreadPatches(&thread, input.patches);
    var ts_buf: [40]u8 = undefined;
    thread.updated_at = try thread.arena.allocator().dupe(u8, audit.nowRfc3339Millis(&ts_buf));
    try writeThreadFile(allocator, abs, &thread);
    return threadMutationOutput(allocator, ident, input.stack, input.name, rel, .update_thread, "patch");
}

pub fn applyArchiveThread(
    allocator: std.mem.Allocator,
    notes_root_abs: []const u8,
    ident: IdentityCtx,
    stack: []const u8,
    name: []const u8,
) Error!MutationOutput {
    if (!storage.isValidStackName(stack)) return error.InvalidName;
    if (!stack_thread.isValidName(name)) return error.InvalidName;
    const stack_abs = try std.fs.path.join(allocator, &.{ notes_root_abs, "stacks", stack });
    defer allocator.free(stack_abs);
    if (!dirExists(stack_abs)) return error.NotFound;

    const rel = try threadRel(allocator, stack, name);
    errdefer allocator.free(rel);
    const abs = try std.fs.path.join(allocator, &.{ notes_root_abs, rel });
    defer allocator.free(abs);
    var thread = try readThreadFile(allocator, abs);
    defer thread.deinit();
    if (!std.mem.eql(u8, thread.name, name)) return error.ValidationFailed;
    thread.status = .archived;
    var ts_buf: [40]u8 = undefined;
    thread.updated_at = try thread.arena.allocator().dupe(u8, audit.nowRfc3339Millis(&ts_buf));
    try writeThreadFile(allocator, abs, &thread);
    return threadMutationOutput(allocator, ident, stack, name, rel, .archive_thread, "archive");
}

// ---------- pause / resume / config patch ----------

pub fn applySetPaused(
    allocator: std.mem.Allocator,
    notes_root_abs: []const u8,
    ident: IdentityCtx,
    stack: []const u8,
    paused: bool,
) Error!MutationOutput {
    if (!storage.isValidStackName(stack)) return error.InvalidName;
    const stack_abs = try std.fs.path.join(allocator, &.{ notes_root_abs, "stacks", stack });
    defer allocator.free(stack_abs);
    if (!dirExists(stack_abs)) return error.NotFound;
    const cfg_path_rel = try stackConfigRel(allocator, stack);
    errdefer allocator.free(cfg_path_rel);
    const cfg_path_abs = try std.fs.path.join(allocator, &.{ notes_root_abs, cfg_path_rel });
    defer allocator.free(cfg_path_abs);

    try patchStackTomlBool(allocator, cfg_path_abs, "paused", paused);

    var paths_list = std.ArrayList([]u8){};
    errdefer {
        for (paths_list.items) |p| allocator.free(p);
        paths_list.deinit(allocator);
    }
    try paths_list.append(allocator, cfg_path_rel);

    const verb: []const u8 = if (paused) "pause" else "resume";
    const subject = try std.fmt.allocPrint(allocator, "stack: {s} {s}", .{ verb, stack });
    const body = try std.fmt.allocPrint(allocator, "stack: {s}\nidentity: {s}\napi: {s}\n", .{ stack, ident.identity, ident.api_path });
    const target = try std.fmt.allocPrint(allocator, "stack/{s}", .{stack});
    const details = try allocator.alloc(audit.DetailKV, 0);

    return .{
        .allocator = allocator,
        .paths = try paths_list.toOwnedSlice(allocator),
        .commit_subject = subject,
        .commit_body = body,
        .audit_action = if (paused) .pause_stack else .resume_stack,
        .audit_target = target,
        .audit_details = details,
        .detail_storage = try allocator.alloc(u8, 0),
    };
}

/// A single key=value config patch. Recognized keys correspond to fields of
/// stack_config.StackConfig.
pub const ConfigPatch = struct {
    key: []const u8,
    value: []const u8,
};

pub fn applyConfigPatch(
    allocator: std.mem.Allocator,
    notes_root_abs: []const u8,
    ident: IdentityCtx,
    stack: []const u8,
    patches: []const ConfigPatch,
) Error!MutationOutput {
    if (!storage.isValidStackName(stack)) return error.InvalidName;
    const stack_abs = try std.fs.path.join(allocator, &.{ notes_root_abs, "stacks", stack });
    defer allocator.free(stack_abs);
    if (!dirExists(stack_abs)) return error.NotFound;

    const cfg_rel = try stackConfigRel(allocator, stack);
    errdefer allocator.free(cfg_rel);
    const cfg_abs = try std.fs.path.join(allocator, &.{ notes_root_abs, cfg_rel });
    defer allocator.free(cfg_abs);

    // Read current.
    var existing: ?[]u8 = null;
    defer if (existing) |e| allocator.free(e);
    if (std.fs.cwd().openFile(cfg_abs, .{})) |f| {
        defer f.close();
        const stat = try f.stat();
        const buf = try allocator.alloc(u8, stat.size);
        _ = try f.readAll(buf);
        existing = buf;
    } else |_| {}

    // Apply each patch.
    var current: []const u8 = if (existing) |e| e else "";
    var owned_current: ?[]u8 = null;
    defer if (owned_current) |c| allocator.free(c);

    for (patches) |p| {
        const validated_value = try validateConfigValue(allocator, p.key, p.value);
        defer allocator.free(validated_value);
        const next = try patchTomlKeyString(allocator, current, p.key, validated_value);
        if (owned_current) |c| allocator.free(c);
        owned_current = next;
        current = next;
    }

    // Write back.
    {
        var f = try std.fs.cwd().createFile(cfg_abs, .{ .truncate = true });
        defer f.close();
        try f.writeAll(current);
    }

    var paths_list = std.ArrayList([]u8){};
    errdefer {
        for (paths_list.items) |p| allocator.free(p);
        paths_list.deinit(allocator);
    }
    try paths_list.append(allocator, cfg_rel);

    const subject = try std.fmt.allocPrint(allocator, "stack: configure {s}", .{stack});
    const body = try std.fmt.allocPrint(allocator, "stack: {s}\nidentity: {s}\napi: {s}\n", .{ stack, ident.identity, ident.api_path });
    const target = try std.fmt.allocPrint(allocator, "stack/{s}", .{stack});
    const details = try allocator.alloc(audit.DetailKV, 0);

    return .{
        .allocator = allocator,
        .paths = try paths_list.toOwnedSlice(allocator),
        .commit_subject = subject,
        .commit_body = body,
        .audit_action = .update_stack_config,
        .audit_target = target,
        .audit_details = details,
        .detail_storage = try allocator.alloc(u8, 0),
    };
}

// ---------- helpers ----------

pub fn stackDirRel(allocator: std.mem.Allocator, stack: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "stacks/{s}", .{stack});
}

pub fn stackConfigRel(allocator: std.mem.Allocator, stack: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "stacks/{s}/stack.toml", .{stack});
}

pub fn itemDirName(allocator: std.mem.Allocator, id: []const u8, slug: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}-{s}", .{ id, slug });
}

pub fn itemMetaRel(allocator: std.mem.Allocator, stack: []const u8, dir_name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "stacks/{s}/{s}/meta.toml", .{ stack, dir_name });
}

pub fn threadRel(allocator: std.mem.Allocator, stack: []const u8, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "stacks/{s}/threads/{s}.toml", .{ stack, name });
}

const WriteItemOpts = struct {
    prompt_body: ?[]const u8 = null,
    target_provider: ?[]const u8 = null,
    target_model: ?[]const u8 = null,
    target_match: ?item_mod.Match = null,
    target_workdir: ?[]const u8 = null,
    input_items: ?[]const []const u8 = null,
    input_files: ?[]const []const u8 = null,
    input_commits: ?[]const []const u8 = null,
    input_mode: ?item_mod.InputMode = null,
    thread_name: ?[]const u8 = null,
    thread_mode: ?item_mod.ThreadMode = null,
    parents: ?[]const []const u8 = null,
    sleep_until: ?[]const u8 = null,
    created_at_override: ?[]const u8 = null,
    commit_stack_dir: bool = false,
};

fn writeItem(
    allocator: std.mem.Allocator,
    notes_root_abs: []const u8,
    ident: IdentityCtx,
    action: audit.Action,
    stack: []const u8,
    id: []const u8,
    kind: item_mod.Kind,
    slug: []const u8,
    opts: WriteItemOpts,
) Error!MutationOutput {
    // Validate kind requirements.
    switch (kind) {
        .prompt, .review => {
            // Need at least one [target] field (or default to all match=any).
            // Per design: prompt/review items require [target]. We synthesize
            // one if the caller didn't supply any field.
        },
        .sleep => {
            if (opts.sleep_until == null) return error.ValidationFailed;
        },
        else => {},
    }

    // Build the directory + files.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var ts_buf: [40]u8 = undefined;
    const now = opts.created_at_override orelse audit.nowRfc3339Millis(&ts_buf);

    // Item directory.
    const dir_name = try itemDirName(aa, id, slug);
    const dir_abs = try std.fs.path.join(aa, &.{ notes_root_abs, "stacks", stack, dir_name });

    // Build meta.toml via item_mod.write so we use canonical key order.
    var item: item_mod.Item = .{
        .arena = std.heap.ArenaAllocator.init(allocator),
        .id = id,
        .slug = slug,
        .kind = kind,
        .status = .queued,
        .created_at = now,
        .updated_at = now,
    };
    defer item.deinit();
    const ia = item.arena.allocator();
    item.id = try ia.dupe(u8, id);
    item.slug = try ia.dupe(u8, slug);
    item.created_at = try ia.dupe(u8, now);
    item.updated_at = try ia.dupe(u8, now);
    if (opts.parents) |ps| {
        const arr = try ia.alloc([]const u8, ps.len);
        for (ps, 0..) |p, i| {
            if (!item_mod.isValidId(p)) return error.ValidationFailed;
            arr[i] = try ia.dupe(u8, p);
        }
        item.parents = arr;
    }
    var thread_defaults: ?stack_thread.Thread = null;
    defer if (thread_defaults) |*th| th.deinit();
    if (opts.thread_name) |name| {
        if (!stack_thread.isValidName(name)) return error.ValidationFailed;
        const thread_abs = try std.fs.path.join(aa, &.{ notes_root_abs, "stacks", stack, "threads", try std.fmt.allocPrint(aa, "{s}.toml", .{name}) });
        thread_defaults = try readThreadFile(allocator, thread_abs);
        if (thread_defaults.?.status != .active) return error.ValidationFailed;
    }
    // Build [target] table if any field is set or kind requires it.
    const thread_target = if (thread_defaults) |th| th.target else null;
    const has_thread_target = if (thread_target) |t| t.provider != null or t.model != null or t.match != null else false;
    const has_any_target = opts.target_provider != null or opts.target_model != null or
        opts.target_match != null or opts.target_workdir != null or has_thread_target;
    if (has_any_target or kind == .prompt or kind == .review or kind == .compact) {
        var t: item_mod.Target = .{};
        if (opts.target_provider) |s| {
            t.provider = try ia.dupe(u8, s);
        } else if (thread_target) |tt| {
            if (tt.provider) |s| t.provider = try ia.dupe(u8, s);
        }
        if (opts.target_model) |s| {
            t.model = try ia.dupe(u8, s);
        } else if (thread_target) |tt| {
            if (tt.model) |s| t.model = try ia.dupe(u8, s);
        }
        if (opts.target_match) |m| {
            t.match = m;
        } else if (thread_target) |tt| {
            if (tt.match) |m| t.match = switch (m) {
                .exact => .exact,
                .compatible => .compatible,
                .any => .any,
            };
        }
        if (t.match == null) t.match = .any;
        if (opts.target_workdir) |s| t.workdir = try ia.dupe(u8, s);
        item.target = t;
    }
    if (kind == .sleep) {
        item.sleep = .{ .until = try ia.dupe(u8, opts.sleep_until.?) };
    }
    const has_inputs = (opts.input_items != null and opts.input_items.?.len > 0) or
        (opts.input_files != null and opts.input_files.?.len > 0) or
        (opts.input_commits != null and opts.input_commits.?.len > 0) or
        opts.input_mode != null;
    if (has_inputs) {
        var inp: item_mod.Inputs = .{ .mode = opts.input_mode orelse .append };
        if (opts.input_items) |ids| {
            const arr = try ia.alloc([]const u8, ids.len);
            for (ids, 0..) |input_id, i| {
                if (!item_mod.isValidId(input_id)) return error.ValidationFailed;
                arr[i] = try ia.dupe(u8, input_id);
            }
            inp.items = arr;
        }
        if (opts.input_files) |paths| {
            const arr = try ia.alloc([]const u8, paths.len);
            for (paths, 0..) |path, i| {
                if (!item_mod.isValidInputFilePath(path)) return error.ValidationFailed;
                arr[i] = try ia.dupe(u8, path);
            }
            inp.files = arr;
        }
        if (opts.input_commits) |commits| {
            const arr = try ia.alloc([]const u8, commits.len);
            for (commits, 0..) |commit, i| arr[i] = try ia.dupe(u8, commit);
            inp.commits = arr;
        }
        item.inputs = inp;
    }
    if (opts.thread_name) |name| {
        if (!item_mod.isValidThreadName(name)) return error.ValidationFailed;
        if (opts.thread_mode) |mode| switch (mode) {
            .fresh, .@"resume" => {},
            .@"continue", .fork => return error.ValidationFailed,
        };
        item.thread = .{
            .name = try ia.dupe(u8, name),
            .mode = opts.thread_mode orelse if (thread_defaults) |*th| if (threadHasSession(th)) .@"resume" else .fresh else .fresh,
        };
    } else if (opts.thread_mode != null) {
        return error.ValidationFailed;
    }
    if (kind == .clear) {
        item.clear_present = true;
    }

    // Run validation to confirm shape.
    var vd: item_mod.ValidationDiagnostic = .{};
    item_mod.validate(&item, &vd) catch return error.ValidationFailed;

    // Serialize and write.
    try std.fs.cwd().makePath(dir_abs);
    var meta_buf = std.ArrayList(u8){};
    defer meta_buf.deinit(allocator);
    try item_mod.write(&item, meta_buf.writer(allocator));
    const meta_abs = try std.fs.path.join(aa, &.{ dir_abs, "meta.toml" });
    {
        var f = try std.fs.cwd().createFile(meta_abs, .{ .truncate = true });
        defer f.close();
        try f.writeAll(meta_buf.items);
    }
    // Optional prompt body.
    var prompt_rel: ?[]const u8 = null;
    if (opts.prompt_body) |body| {
        const prompt_path_abs = try std.fs.path.join(aa, &.{ dir_abs, "prompt.md" });
        var f = try std.fs.cwd().createFile(prompt_path_abs, .{ .truncate = true });
        defer f.close();
        try f.writeAll(body);
        prompt_rel = try std.fmt.allocPrint(aa, "stacks/{s}/{s}/prompt.md", .{ stack, dir_name });
    }

    // Build output.
    const meta_rel = try itemMetaRel(allocator, stack, dir_name);
    var paths_list = std.ArrayList([]u8){};
    errdefer {
        for (paths_list.items) |p| allocator.free(p);
        paths_list.deinit(allocator);
    }
    if (opts.commit_stack_dir) {
        allocator.free(meta_rel);
        const stack_rel = try stackDirRel(allocator, stack);
        try paths_list.append(allocator, stack_rel);
    } else {
        try paths_list.append(allocator, meta_rel);
        if (prompt_rel) |pr| {
            try paths_list.append(allocator, try allocator.dupe(u8, pr));
        }
    }

    const verb = if (action == .insert_item) "insert" else "append";
    const subject = try std.fmt.allocPrint(allocator, "stack: {s} {s}-{s}", .{ verb, id, slug });
    const body_str = try std.fmt.allocPrint(allocator, "stack: {s}\nitem: {s}\nidentity: {s}\napi: {s}\n", .{ stack, id, ident.identity, ident.api_path });
    const target = try std.fmt.allocPrint(allocator, "stack/{s}/item/{s}", .{ stack, id });

    const details_buf = try allocator.alloc(u8, id.len);
    @memcpy(details_buf, id);
    const details = try allocator.alloc(audit.DetailKV, 1);
    details[0] = .{ .key = "id", .value = details_buf };

    return .{
        .allocator = allocator,
        .paths = try paths_list.toOwnedSlice(allocator),
        .commit_subject = subject,
        .commit_body = body_str,
        .audit_action = action,
        .audit_target = target,
        .audit_details = details,
        .detail_storage = details_buf,
    };
}

fn dirExists(path: []const u8) bool {
    var d = std.fs.cwd().openDir(path, .{}) catch return false;
    d.close();
    return true;
}

fn fileExists(path: []const u8) bool {
    var f = std.fs.cwd().openFile(path, .{}) catch return false;
    f.close();
    return true;
}

fn appendPathUnique(allocator: std.mem.Allocator, paths: *std.ArrayList([]u8), owned_path: []u8) !void {
    for (paths.items) |p| {
        if (std.mem.eql(u8, p, owned_path)) {
            allocator.free(owned_path);
            return;
        }
    }
    try paths.append(allocator, owned_path);
}

fn appendTranscriptPathIfPresent(
    allocator: std.mem.Allocator,
    notes_root_abs: []const u8,
    stack: []const u8,
    item_dir_name: []const u8,
    result_transcript_path: ?[]const u8,
    paths: *std.ArrayList([]u8),
) !void {
    _ = result_transcript_path;
    const rel = try std.fmt.allocPrint(allocator, "stacks/{s}/{s}/transcript.jsonl", .{ stack, item_dir_name });
    errdefer allocator.free(rel);
    const abs = try std.fs.path.join(allocator, &.{ notes_root_abs, rel });
    defer allocator.free(abs);
    if (!fileExists(abs)) {
        allocator.free(rel);
        return;
    }
    try appendPathUnique(allocator, paths, rel);
}

fn appendNotesRootWorkdirPaths(
    allocator: std.mem.Allocator,
    notes_root_abs: []const u8,
    packet: output_packet.PacketInput,
    paths: *std.ArrayList([]u8),
) !void {
    const after = packet.workdir_after orelse return;
    const root = after.root orelse return;
    if (!std.mem.eql(u8, root, notes_root_abs)) return;
    for (packet.changed_paths) |p| {
        if (std.fs.path.isAbsolute(p) or !item_mod.isValidInputFilePath(p) or isInternalGitPath(p)) continue;
        try appendPathUnique(allocator, paths, try allocator.dupe(u8, p));
    }
}

fn isInternalGitPath(path: []const u8) bool {
    return std.mem.eql(u8, path, ".git") or std.mem.startsWith(u8, path, ".git/");
}

const ExpandedInputs = struct {
    input_items: ?[]const []const u8 = null,
    input_files: ?[]const []const u8 = null,
    input_commits: ?[]const []const u8 = null,
    input_mode: ?item_mod.InputMode = null,
};

fn validateExpandedRoutineStep(
    allocator: std.mem.Allocator,
    notes_root_abs: []const u8,
    stack: []const u8,
    step: *const routine_mod.Step,
    effective_thread_mode: ?item_mod.ThreadMode,
    allow_missing_thread: bool,
    id: []const u8,
    parents: []const []const u8,
    inputs: ExpandedInputs,
    created_at_override: ?[]const u8,
) Error!void {
    if (step.kind == .sleep) return error.ValidationFailed;

    var item: item_mod.Item = .{
        .arena = std.heap.ArenaAllocator.init(allocator),
        .id = id,
        .slug = step.slug,
        .kind = step.kind,
        .status = .queued,
        .created_at = "",
        .updated_at = "",
    };
    defer item.deinit();
    const aa = item.arena.allocator();

    var ts_buf: [40]u8 = undefined;
    const now = created_at_override orelse audit.nowRfc3339Millis(&ts_buf);
    item.id = try aa.dupe(u8, id);
    item.slug = try aa.dupe(u8, step.slug);
    item.created_at = try aa.dupe(u8, now);
    item.updated_at = try aa.dupe(u8, now);

    if (parents.len > 0) {
        const arr = try aa.alloc([]const u8, parents.len);
        for (parents, 0..) |parent_id, i| arr[i] = try aa.dupe(u8, parent_id);
        item.parents = arr;
    }

    var thread_defaults: ?stack_thread.Thread = null;
    defer if (thread_defaults) |*th| th.deinit();
    if (step.thread) |thread_name| {
        const thread_abs = try std.fs.path.join(allocator, &.{ notes_root_abs, "stacks", stack, "threads", try std.fmt.allocPrint(aa, "{s}.toml", .{thread_name}) });
        defer allocator.free(thread_abs);
        thread_defaults = readThreadFile(allocator, thread_abs) catch |e| switch (e) {
            error.NotFound => if (allow_missing_thread) null else return error.ValidationFailed,
            else => return error.ValidationFailed,
        };
        if (thread_defaults) |*th| {
            if (th.status != .active) return error.ValidationFailed;
        }
    }

    const thread_target = if (thread_defaults) |th| th.target else null;
    const has_thread_target = if (thread_target) |t| t.provider != null or t.model != null or t.match != null else false;
    if (has_thread_target or step.kind == .prompt or step.kind == .review or step.kind == .compact) {
        var target: item_mod.Target = .{};
        if (thread_target) |tt| {
            if (tt.provider) |s| target.provider = try aa.dupe(u8, s);
        }
        if (thread_target) |tt| {
            if (tt.model) |s| target.model = try aa.dupe(u8, s);
        }
        if (thread_target) |tt| {
            if (tt.match) |m| target.match = switch (m) {
                .exact => .exact,
                .compatible => .compatible,
                .any => .any,
            };
        }
        if (target.match == null) target.match = .any;
        item.target = target;
    }

    const has_inputs = (inputs.input_items != null and inputs.input_items.?.len > 0) or
        (inputs.input_files != null and inputs.input_files.?.len > 0) or
        (inputs.input_commits != null and inputs.input_commits.?.len > 0) or
        inputs.input_mode != null;
    if (has_inputs) {
        var inp: item_mod.Inputs = .{ .mode = inputs.input_mode orelse .append };
        if (inputs.input_items) |ids| {
            const arr = try aa.alloc([]const u8, ids.len);
            for (ids, 0..) |input_id, i| arr[i] = try aa.dupe(u8, input_id);
            inp.items = arr;
        }
        if (inputs.input_files) |paths| {
            const arr = try aa.alloc([]const u8, paths.len);
            for (paths, 0..) |path, i| arr[i] = try aa.dupe(u8, path);
            inp.files = arr;
        }
        if (inputs.input_commits) |commits| {
            const arr = try aa.alloc([]const u8, commits.len);
            for (commits, 0..) |commit, i| arr[i] = try aa.dupe(u8, commit);
            inp.commits = arr;
        }
        item.inputs = inp;
    }

    if (step.thread) |name| {
        item.thread = .{
            .name = try aa.dupe(u8, name),
            .mode = effective_thread_mode orelse if (thread_defaults) |*th| if (threadHasSession(th)) .@"resume" else .fresh else .fresh,
        };
    }
    if (step.kind == .clear) item.clear_present = true;

    var vd: item_mod.ValidationDiagnostic = .{};
    item_mod.validate(&item, &vd) catch return error.ValidationFailed;
}

fn threadHasSession(thread: *const stack_thread.Thread) bool {
    const thread_state = thread.state orelse return false;
    return thread_state.last_session_id != null;
}

fn appendUniqueThreadName(
    allocator: std.mem.Allocator,
    names: *std.ArrayList([]const u8),
    name: []const u8,
) !void {
    for (names.items) |existing| {
        if (std.mem.eql(u8, existing, name)) return;
    }
    try names.append(allocator, name);
}

fn createRoutineThread(
    allocator: std.mem.Allocator,
    notes_root_abs: []const u8,
    stack: []const u8,
    name: []const u8,
    created_at_override: ?[]const u8,
) Error![]u8 {
    const rel = try threadRel(allocator, stack, name);
    errdefer allocator.free(rel);
    const abs = try std.fs.path.join(allocator, &.{ notes_root_abs, rel });
    defer allocator.free(abs);
    if (fileExists(abs)) return rel;
    const dir_abs = try std.fs.path.join(allocator, &.{ notes_root_abs, "stacks", stack, "threads" });
    defer allocator.free(dir_abs);
    try std.fs.cwd().makePath(dir_abs);

    var ts_buf: [40]u8 = undefined;
    const now = created_at_override orelse audit.nowRfc3339Millis(&ts_buf);
    var thread: stack_thread.Thread = .{
        .arena = std.heap.ArenaAllocator.init(allocator),
        .name = name,
        .created_at = now,
        .updated_at = now,
        .status = .active,
    };
    defer thread.deinit();
    const aa = thread.arena.allocator();
    thread.name = try aa.dupe(u8, name);
    thread.created_at = try aa.dupe(u8, now);
    thread.updated_at = try aa.dupe(u8, now);
    try writeThreadFile(allocator, abs, &thread);
    return rel;
}

fn readThreadFile(allocator: std.mem.Allocator, abs: []const u8) Error!stack_thread.Thread {
    var f = std.fs.cwd().openFile(abs, .{}) catch |e| switch (e) {
        error.FileNotFound => return error.NotFound,
        else => return e,
    };
    defer f.close();
    const stat = try f.stat();
    const src = try allocator.alloc(u8, stat.size);
    defer allocator.free(src);
    const n = try f.readAll(src);
    var diag: stack_thread.ParseDiagnostic = .{};
    return stack_thread.parseSlice(allocator, src[0..n], &diag) catch return error.ValidationFailed;
}

fn writeThreadFile(allocator: std.mem.Allocator, abs: []const u8, thread: *const stack_thread.Thread) Error!void {
    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);
    try stack_thread.write(thread, out.writer(allocator));
    var f = try std.fs.cwd().createFile(abs, .{ .truncate = true });
    defer f.close();
    try f.writeAll(out.items);
}

fn applyThreadPatches(thread: *stack_thread.Thread, patches: []const ThreadPatch) Error!void {
    const arena = thread.arena.allocator();
    for (patches) |p| {
        if (std.mem.eql(u8, p.key, "status")) {
            const value = p.value orelse return error.BadThreadValue;
            thread.status = stack_thread.Status.fromString(value) orelse return error.BadThreadValue;
        } else if (std.mem.eql(u8, p.key, "target.provider")) {
            var target = thread.target orelse stack_thread.Target{};
            target.provider = if (p.value) |v| try arena.dupe(u8, v) else null;
            thread.target = target;
        } else if (std.mem.eql(u8, p.key, "target.model")) {
            var target = thread.target orelse stack_thread.Target{};
            target.model = if (p.value) |v| try arena.dupe(u8, v) else null;
            thread.target = target;
        } else if (std.mem.eql(u8, p.key, "target.match")) {
            var target = thread.target orelse stack_thread.Target{};
            target.match = if (p.value) |v| stack_thread.Match.fromString(v) orelse return error.BadThreadValue else null;
            thread.target = target;
        } else if (std.mem.eql(u8, p.key, "state.last_item_id")) {
            var st = thread.state orelse stack_thread.State{};
            st.last_item_id = if (p.value) |v| try arena.dupe(u8, v) else null;
            thread.state = st;
        } else if (std.mem.eql(u8, p.key, "state.last_harness")) {
            var st = thread.state orelse stack_thread.State{};
            st.last_harness = if (p.value) |v| try arena.dupe(u8, v) else null;
            thread.state = st;
        } else if (std.mem.eql(u8, p.key, "state.last_session_id")) {
            var st = thread.state orelse stack_thread.State{};
            st.last_session_id = if (p.value) |v| try arena.dupe(u8, v) else null;
            thread.state = st;
        } else if (std.mem.eql(u8, p.key, "state.last_session_file")) {
            var st = thread.state orelse stack_thread.State{};
            st.last_session_file = if (p.value) |v| try arena.dupe(u8, v) else null;
            thread.state = st;
        } else if (std.mem.eql(u8, p.key, "state.last_transcript_path")) {
            var st = thread.state orelse stack_thread.State{};
            st.last_transcript_path = if (p.value) |v| try arena.dupe(u8, v) else null;
            thread.state = st;
        } else {
            return error.BadThreadKey;
        }
    }
}

fn updateThreadFromItemResult(
    allocator: std.mem.Allocator,
    notes_root_abs: []const u8,
    stack: []const u8,
    item_dir_name: []const u8,
    thread_name: []const u8,
    input: RuntimeTransitionInput,
    result: ?item_mod.Result,
) Error![]u8 {
    if (!stack_thread.isValidName(thread_name)) return error.ValidationFailed;
    const rel = try threadRel(allocator, stack, thread_name);
    errdefer allocator.free(rel);
    const abs = try std.fs.path.join(allocator, &.{ notes_root_abs, rel });
    defer allocator.free(abs);
    var thread = try readThreadFile(allocator, abs);
    defer thread.deinit();

    const arena = thread.arena.allocator();
    var st = thread.state orelse stack_thread.State{};
    st.last_item_id = try arena.dupe(u8, input.id);
    if (result) |r| {
        if (r.harness) |s| st.last_harness = try arena.dupe(u8, s);
        if (r.session_id) |s| st.last_session_id = try arena.dupe(u8, s);
        if (r.session_file) |s| st.last_session_file = try arena.dupe(u8, s);
        if (r.transcript_path) |s| {
            if (std.fs.path.isAbsolute(s) and std.mem.startsWith(u8, s, notes_root_abs)) {
                var start = notes_root_abs.len;
                if (s.len > start and (s[start] == '/' or s[start] == '\\')) start += 1;
                st.last_transcript_path = try arena.dupe(u8, s[start..]);
            } else if (std.mem.eql(u8, s, "../transcript.jsonl")) {
                st.last_transcript_path = try std.fmt.allocPrint(arena, "stacks/{s}/{s}/transcript.jsonl", .{ stack, item_dir_name });
            } else {
                st.last_transcript_path = try arena.dupe(u8, s);
            }
        }
    }
    thread.state = st;
    var ts_buf: [40]u8 = undefined;
    thread.updated_at = try arena.dupe(u8, audit.nowRfc3339Millis(&ts_buf));
    try writeThreadFile(allocator, abs, &thread);
    return rel;
}

fn threadMutationOutput(
    allocator: std.mem.Allocator,
    ident: IdentityCtx,
    stack: []const u8,
    name: []const u8,
    rel: []u8,
    action: audit.Action,
    verb: []const u8,
) Error!MutationOutput {
    var paths_list = std.ArrayList([]u8){};
    errdefer {
        for (paths_list.items) |p| allocator.free(p);
        paths_list.deinit(allocator);
    }
    try paths_list.append(allocator, rel);
    const subject = try std.fmt.allocPrint(allocator, "thread: {s} {s}", .{ verb, name });
    const body = try std.fmt.allocPrint(allocator, "stack: {s}\nthread: {s}\nidentity: {s}\napi: {s}\n", .{ stack, name, ident.identity, ident.api_path });
    const target = try std.fmt.allocPrint(allocator, "stack/{s}/thread/{s}", .{ stack, name });
    const details = try allocator.alloc(audit.DetailKV, 0);
    return .{
        .allocator = allocator,
        .paths = try paths_list.toOwnedSlice(allocator),
        .commit_subject = subject,
        .commit_body = body,
        .audit_action = action,
        .audit_target = target,
        .audit_details = details,
        .detail_storage = try allocator.alloc(u8, 0),
    };
}

/// Compute the next numeric item id by scanning `<stack_abs>/` for
/// existing `<id>-<slug>` directories. Returns `max + 1` (or 1 if empty).
fn computeNextItemIdInt(allocator: std.mem.Allocator, stack_abs: []const u8) Error!u32 {
    var d = std.fs.openDirAbsolute(stack_abs, .{ .iterate = true }) catch return error.NotFound;
    defer d.close();
    var max: u32 = 0;
    var it = d.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind != .directory) continue;
        const dash = std.mem.indexOfScalar(u8, entry.name, '-') orelse continue;
        const id_str = entry.name[0..dash];
        if (!item_mod.isValidId(id_str)) continue;
        const n = std.fmt.parseInt(u32, id_str, 10) catch continue;
        if (n > max) max = n;
    }
    _ = allocator;
    return max + 1;
}

const ItemDir = struct {
    id: u32,
    name: []u8,
    slug: []const u8,
};

fn renumberItemsFrom(allocator: std.mem.Allocator, stack_abs: []const u8, start_id: u32) Error!void {
    var d = std.fs.openDirAbsolute(stack_abs, .{ .iterate = true }) catch return error.NotFound;
    defer d.close();

    var items = std.ArrayList(ItemDir){};
    defer {
        for (items.items) |it| allocator.free(it.name);
        items.deinit(allocator);
    }

    var it = d.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind != .directory) continue;
        const dash = std.mem.indexOfScalar(u8, entry.name, '-') orelse continue;
        const id_str = entry.name[0..dash];
        if (!item_mod.isValidId(id_str)) continue;
        const id = std.fmt.parseInt(u32, id_str, 10) catch continue;
        if (id < start_id) continue;
        const name_owned = try allocator.dupe(u8, entry.name);
        try items.append(allocator, .{
            .id = id,
            .name = name_owned,
            .slug = name_owned[dash + 1 ..],
        });
    }

    std.mem.sort(ItemDir, items.items, {}, itemDirIdDesc);

    for (items.items) |entry| {
        const new_id = entry.id + 1;
        var new_id_buf: [16]u8 = undefined;
        const new_id_str = try std.fmt.bufPrint(&new_id_buf, "{d:0>4}", .{new_id});
        const old_abs = try std.fs.path.join(allocator, &.{ stack_abs, entry.name });
        defer allocator.free(old_abs);
        const new_name = try std.fmt.allocPrint(allocator, "{s}-{s}", .{ new_id_str, entry.slug });
        defer allocator.free(new_name);
        const new_abs = try std.fs.path.join(allocator, &.{ stack_abs, new_name });
        defer allocator.free(new_abs);
        try std.fs.cwd().rename(old_abs, new_abs);
        try rewriteItemId(allocator, new_abs, new_id_str);
    }
}

fn itemDirIdDesc(_: void, a: ItemDir, b: ItemDir) bool {
    return a.id > b.id;
}

fn rewriteItemId(allocator: std.mem.Allocator, item_dir_abs: []const u8, new_id: []const u8) Error!void {
    const meta_abs = try std.fs.path.join(allocator, &.{ item_dir_abs, "meta.toml" });
    defer allocator.free(meta_abs);
    var f = std.fs.cwd().openFile(meta_abs, .{}) catch return error.NotFound;
    defer f.close();
    const stat = try f.stat();
    const src = try allocator.alloc(u8, stat.size);
    defer allocator.free(src);
    const n = try f.readAll(src);
    var diag: item_mod.ParseDiagnostic = .{};
    var parsed = item_mod.parseSlice(allocator, src[0..n], &diag) catch return error.ValidationFailed;
    defer parsed.deinit();
    parsed.id = try parsed.arena.allocator().dupe(u8, new_id);

    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);
    try item_mod.write(&parsed, out.writer(allocator));
    var wf = try std.fs.cwd().createFile(meta_abs, .{ .truncate = true });
    defer wf.close();
    try wf.writeAll(out.items);
}

/// Find an existing item directory named `<id>-...` under stack_abs. Returns
/// a caller-owned slice (the directory entry name); null if not found.
fn findItemDir(allocator: std.mem.Allocator, stack_abs: []const u8, id: []const u8) Error!?[]u8 {
    var d = std.fs.openDirAbsolute(stack_abs, .{ .iterate = true }) catch return error.NotFound;
    defer d.close();
    var it = d.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind != .directory) continue;
        const dash = std.mem.indexOfScalar(u8, entry.name, '-') orelse continue;
        if (std.mem.eql(u8, entry.name[0..dash], id)) {
            return try allocator.dupe(u8, entry.name);
        }
    }
    return null;
}

/// Read `stack.toml`, replace (or insert) `<key> = <true|false>`, write back.
fn patchStackTomlBool(allocator: std.mem.Allocator, path_abs: []const u8, key: []const u8, value: bool) !void {
    var existing: []u8 = "";
    var owned = false;
    if (std.fs.cwd().openFile(path_abs, .{})) |f| {
        defer f.close();
        const stat = try f.stat();
        existing = try allocator.alloc(u8, stat.size);
        owned = true;
        _ = try f.readAll(existing);
    } else |_| {}
    defer if (owned) allocator.free(existing);

    const v_str: []const u8 = if (value) "true" else "false";
    const out = try patchTomlKeyRaw(allocator, existing, key, v_str);
    defer allocator.free(out);

    var f = try std.fs.cwd().createFile(path_abs, .{ .truncate = true });
    defer f.close();
    try f.writeAll(out);
}

/// Patch a top-level `<key> = <value>` line. `value` is emitted verbatim
/// (caller is responsible for any needed quoting). Returns a new caller-owned
/// buffer.
fn patchTomlKeyRaw(allocator: std.mem.Allocator, source: []const u8, key: []const u8, value: []const u8) ![]u8 {
    var out = std.ArrayList(u8){};
    errdefer out.deinit(allocator);

    var replaced = false;
    var i: usize = 0;
    while (i < source.len) {
        // Find end of line.
        var eol = i;
        while (eol < source.len and source[eol] != '\n') eol += 1;
        const line = source[i..eol];
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!replaced and isKeyLine(trimmed, key)) {
            try out.writer(allocator).print("{s} = {s}", .{ key, value });
            replaced = true;
        } else {
            try out.appendSlice(allocator, line);
        }
        if (eol < source.len) {
            try out.append(allocator, '\n');
            i = eol + 1;
        } else {
            break;
        }
    }
    if (!replaced) {
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.append(allocator, '\n');
        try out.writer(allocator).print("{s} = {s}\n", .{ key, value });
    }
    return try out.toOwnedSlice(allocator);
}

/// Variant that writes a value as either a string or raw depending on key
/// semantics; for booleans / integers / continuity we strip quotes.
fn patchTomlKeyString(allocator: std.mem.Allocator, source: []const u8, key: []const u8, value: []const u8) ![]u8 {
    // For known scalar bool/int keys we keep the raw value; for strings we
    // emit a TOML-quoted string. The caller already validated the value.
    if (std.mem.eql(u8, key, "paused")) {
        return patchTomlKeyRaw(allocator, source, key, value);
    } else if (std.mem.eql(u8, key, "max_concurrent_per_stack")) {
        return patchTomlKeyRaw(allocator, source, key, value);
    } else if (std.mem.eql(u8, key, "continuity")) {
        const quoted = try std.fmt.allocPrint(allocator, "\"{s}\"", .{value});
        defer allocator.free(quoted);
        return patchTomlKeyRaw(allocator, source, key, quoted);
    } else if (std.mem.eql(u8, key, "description") or std.mem.eql(u8, key, "default_workdir")) {
        const quoted = try tomlQuotedString(allocator, value);
        defer allocator.free(quoted);
        return patchTomlKeyRaw(allocator, source, key, quoted);
    }
    return error.BadConfigKey;
}

fn validateConfigValue(allocator: std.mem.Allocator, key: []const u8, value: []const u8) ![]u8 {
    if (std.mem.eql(u8, key, "paused")) {
        if (!std.mem.eql(u8, value, "true") and !std.mem.eql(u8, value, "false")) return error.BadConfigValue;
        return allocator.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "max_concurrent_per_stack")) {
        const n = std.fmt.parseInt(i64, value, 10) catch return error.BadConfigValue;
        if (n < 1) return error.BadConfigValue;
        return allocator.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "continuity")) {
        if (stack_config.Continuity.fromString(value) == null) return error.BadConfigValue;
        return allocator.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "description") or std.mem.eql(u8, key, "default_workdir")) {
        return allocator.dupe(u8, value);
    }
    return error.BadConfigKey;
}

fn isKeyLine(trimmed: []const u8, key: []const u8) bool {
    if (trimmed.len <= key.len) return false;
    if (!std.mem.startsWith(u8, trimmed, key)) return false;
    // After the key must come whitespace then '='.
    var i = key.len;
    if (i >= trimmed.len) return false;
    if (trimmed[i] != ' ' and trimmed[i] != '\t' and trimmed[i] != '=') return false;
    while (i < trimmed.len and (trimmed[i] == ' ' or trimmed[i] == '\t')) i += 1;
    return i < trimmed.len and trimmed[i] == '=';
}

test "applyRuntimeTransition: terminal transition records commit output paths" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmp.dir.realpath(".", &root_buf);
    try tmp.dir.makePath("stacks/demo/0001-hello");
    {
        var f = try tmp.dir.createFile("stacks/demo/0001-hello/meta.toml", .{ .truncate = true });
        defer f.close();
        try f.writeAll(
            \\id = "0001"
            \\slug = "hello"
            \\kind = "prompt"
            \\status = "running"
            \\created_at = 2026-05-10T14:00:00Z
            \\updated_at = 2026-05-10T14:00:00Z
            \\
            \\[target]
            \\match = "any"
            \\
        );
    }
    {
        var f = try tmp.dir.createFile("stacks/demo/0001-hello/transcript.jsonl", .{ .truncate = true });
        defer f.close();
        try f.writeAll("{\"kind\":\"message\"}\n");
    }
    try tmp.dir.makePath("notes");
    {
        var f = try tmp.dir.createFile("notes/decision.md", .{ .truncate = true });
        defer f.close();
        try f.writeAll("done\n");
    }
    var snap = output_packet.WorkdirSnapshot{
        .allocator = a,
        .kind = .git,
        .root = @constCast(root),
    };

    var out = try applyRuntimeTransition(a, root, .{ .identity = "system", .api_path = "test" }, .{
        .stack = "demo",
        .id = "0001",
        .to = .completed,
        .result_harness = "fake",
        .result_transcript_path = "../transcript.jsonl",
        .result_completed_at = "2026-05-17T12:00:00.000Z",
        .output_packet = .{
            .stack = "demo",
            .item_id = "0001",
            .status = "completed",
            .changed_paths = &.{"notes/decision.md"},
            .workdir_after = &snap,
        },
    });
    defer out.deinit();

    try std.testing.expectEqual(@as(usize, 3), out.paths.len);
    try std.testing.expect(pathListContains(out.paths, "stacks/demo/0001-hello/meta.toml"));
    try std.testing.expect(pathListContains(out.paths, "stacks/demo/0001-hello/transcript.jsonl"));
    try std.testing.expect(pathListContains(out.paths, "notes/decision.md"));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("stacks/demo/0001-hello/output", .{}));
}

test "applyRuntimeTransition: terminal transition includes rendered prompt path when present" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmp.dir.realpath(".", &root_buf);
    try tmp.dir.makePath("stacks/demo/0001-hello");
    {
        var f = try tmp.dir.createFile("stacks/demo/0001-hello/meta.toml", .{ .truncate = true });
        defer f.close();
        try f.writeAll(
            \\id = "0001"
            \\slug = "hello"
            \\kind = "prompt"
            \\status = "running"
            \\created_at = 2026-05-10T14:00:00Z
            \\updated_at = 2026-05-10T14:00:00Z
            \\
            \\[target]
            \\match = "any"
            \\
        );
    }
    {
        var f = try tmp.dir.createFile("stacks/demo/0001-hello/rendered_prompt.md", .{ .truncate = true });
        defer f.close();
        try f.writeAll("rendered");
    }

    var out = try applyRuntimeTransition(a, root, .{ .identity = "system", .api_path = "test" }, .{
        .stack = "demo",
        .id = "0001",
        .to = .completed,
        .result_harness = "fake",
        .result_completed_at = "2026-05-17T12:00:00.000Z",
    });
    defer out.deinit();
    try std.testing.expect(pathListContains(out.paths, "stacks/demo/0001-hello/rendered_prompt.md"));
}

test "applyCreateThread writes thread file path" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmp.dir.realpath(".", &root_buf);
    try tmp.dir.makePath("stacks/demo");

    var out = try applyCreateThread(a, root, .{ .identity = "local", .api_path = "test" }, .{
        .stack = "demo",
        .name = "admin",
        .target_provider = "openai",
        .target_model = "gpt-5",
        .target_match = .compatible,
        .created_at_override = "2026-05-17T12:00:00.000Z",
    });
    defer out.deinit();

    try std.testing.expectEqual(@as(usize, 1), out.paths.len);
    try std.testing.expectEqualStrings("stacks/demo/threads/admin.toml", out.paths[0]);
    var f = try tmp.dir.openFile("stacks/demo/threads/admin.toml", .{});
    defer f.close();
    const stat = try f.stat();
    const buf = try a.alloc(u8, stat.size);
    defer a.free(buf);
    _ = try f.readAll(buf);
    try std.testing.expect(std.mem.indexOf(u8, buf, "name = \"admin\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf, "match = \"compatible\"") != null);
}

test "applyRuntimeTransition updates named thread on completion" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmp.dir.realpath(".", &root_buf);
    try tmp.dir.makePath("stacks/demo/0001-hello");
    try tmp.dir.makePath("stacks/demo/threads");
    {
        var f = try tmp.dir.createFile("stacks/demo/0001-hello/meta.toml", .{ .truncate = true });
        defer f.close();
        try f.writeAll(
            \\id = "0001"
            \\slug = "hello"
            \\kind = "prompt"
            \\status = "running"
            \\created_at = 2026-05-10T14:00:00Z
            \\updated_at = 2026-05-10T14:00:00Z
            \\
            \\[target]
            \\match = "any"
            \\
            \\[thread]
            \\name = "admin"
            \\mode = "fresh"
            \\
        );
    }
    {
        var f = try tmp.dir.createFile("stacks/demo/threads/admin.toml", .{ .truncate = true });
        defer f.close();
        try f.writeAll(
            \\version = 1
            \\name = "admin"
            \\created_at = 2026-05-17T12:00:00.000Z
            \\updated_at = 2026-05-17T12:00:00.000Z
            \\status = "active"
            \\
        );
    }

    var out = try applyRuntimeTransition(a, root, .{ .identity = "system", .api_path = "test" }, .{
        .stack = "demo",
        .id = "0001",
        .to = .completed,
        .result_harness = "codex",
        .result_session_id = "th-1",
        .result_session_file = "~/.codex/sessions/1.jsonl",
        .result_transcript_path = "../transcript.jsonl",
        .result_completed_at = "2026-05-17T12:01:00.000Z",
    });
    defer out.deinit();
    try std.testing.expect(pathListContains(out.paths, "stacks/demo/threads/admin.toml"));

    var f = try tmp.dir.openFile("stacks/demo/threads/admin.toml", .{});
    defer f.close();
    const stat = try f.stat();
    const buf = try a.alloc(u8, stat.size);
    defer a.free(buf);
    _ = try f.readAll(buf);
    try std.testing.expect(std.mem.indexOf(u8, buf, "[state]") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf, "last_item_id = \"0001\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf, "last_harness = \"codex\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf, "last_session_id = \"th-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf, "last_transcript_path = \"stacks/demo/0001-hello/transcript.jsonl\"") != null);
}

fn pathListContains(paths: []const []const u8, needle: []const u8) bool {
    for (paths) |p| if (std.mem.eql(u8, p, needle)) return true;
    return false;
}

fn writeTomlString(w: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            else => try w.writeByte(c),
        }
    }
}

fn tomlQuotedString(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out = std.ArrayList(u8){};
    errdefer out.deinit(allocator);
    try out.append(allocator, '"');
    try writeTomlString(out.writer(allocator), s);
    try out.append(allocator, '"');
    return try out.toOwnedSlice(allocator);
}

// ---------- tests ----------

test "validateNewStackName: ok and reject" {
    try validateNewStackName("foo");
    try validateNewStackName("foo-bar");
    try std.testing.expectError(error.InvalidName, validateNewStackName("Foo"));
    try std.testing.expectError(error.InvalidName, validateNewStackName(""));
    try std.testing.expectError(error.InvalidName, validateNewStackName(".stako"));
    try std.testing.expectError(error.NameReserved, validateNewStackName("stacks"));
    try std.testing.expectError(error.NameReserved, validateNewStackName("state"));
}

test "applyCreateStack: writes stack.toml" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("stacks");
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = try tmp.dir.realpath(".", &buf);

    var out = try applyCreateStack(a, abs, .{ .api_path = "POST /stacks" }, .{
        .name = "demo",
        .description = "test",
        .created_at_override = "2026-05-10T14:00:00Z",
        .continuity = .chain,
    });
    defer out.deinit();

    try std.testing.expectEqual(@as(usize, 1), out.paths.len);
    try std.testing.expectEqualStrings("stacks/demo/stack.toml", out.paths[0]);
    try std.testing.expectEqualStrings("create_stack", out.audit_action.slug());
    try std.testing.expectEqualStrings("stack/demo", out.audit_target);

    // File exists with expected content.
    var f = try tmp.dir.openFile("stacks/demo/stack.toml", .{});
    defer f.close();
    const stat = try f.stat();
    const contents = try a.alloc(u8, stat.size);
    defer a.free(contents);
    _ = try f.readAll(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, "description = \"test\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "continuity = \"chain\"") != null);
}

test "applyCreateStack: rejects duplicate" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("stacks/demo");
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = try tmp.dir.realpath(".", &buf);

    try std.testing.expectError(error.AlreadyExists, applyCreateStack(a, abs, .{ .api_path = "POST /stacks" }, .{
        .name = "demo",
    }));
}

test "applyAppendItem: writes meta.toml with next id" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("stacks/demo");
    {
        var f = try tmp.dir.createFile("stacks/demo/stack.toml", .{ .truncate = true });
        defer f.close();
        try f.writeAll("description = \"x\"\ncreated_at = 2026-05-10T14:00:00Z\n");
    }
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = try tmp.dir.realpath(".", &buf);

    var out = try applyAppendItem(a, abs, .{ .api_path = "POST /stacks/demo/items" }, .{
        .stack = "demo",
        .kind = "prompt",
        .slug = "hello",
        .target_provider = "anthropic",
        .target_match = .compatible,
        .created_at_override = "2026-05-10T14:00:00Z",
    });
    defer out.deinit();

    try std.testing.expectEqual(@as(usize, 1), out.paths.len);
    try std.testing.expectEqualStrings("stacks/demo/0001-hello/meta.toml", out.paths[0]);

    var f = try tmp.dir.openFile("stacks/demo/0001-hello/meta.toml", .{});
    defer f.close();
    const stat = try f.stat();
    const contents = try a.alloc(u8, stat.size);
    defer a.free(contents);
    _ = try f.readAll(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, "id = \"0001\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "status = \"queued\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "[target]") != null);
}

test "applyAppendItem: second item picks 0002" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("stacks/demo/0001-first");
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = try tmp.dir.realpath(".", &buf);

    var out = try applyAppendItem(a, abs, .{ .api_path = "x" }, .{
        .stack = "demo",
        .kind = "prompt",
        .slug = "second",
        .target_match = .any,
        .created_at_override = "2026-05-10T14:00:00Z",
    });
    defer out.deinit();
    try std.testing.expectEqualStrings("stacks/demo/0002-second/meta.toml", out.paths[0]);
}

test "applyInsertItem: renumbers reference item and writes new item before it" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("stacks/demo/0001-first");
    {
        var f = try tmp.dir.createFile("stacks/demo/0001-first/meta.toml", .{ .truncate = true });
        defer f.close();
        try f.writeAll(
            \\id = "0001"
            \\slug = "first"
            \\kind = "prompt"
            \\status = "queued"
            \\created_at = 2026-05-10T14:00:00Z
            \\updated_at = 2026-05-10T14:00:00Z
            \\
            \\[target]
            \\match = "any"
            \\
        );
    }
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = try tmp.dir.realpath(".", &buf);

    var out = try applyInsertItem(a, abs, .{ .api_path = "x" }, .{
        .stack = "demo",
        .ref = "0001",
        .kind = "prompt",
        .slug = "inserted",
        .target_match = .any,
        .created_at_override = "2026-05-10T14:00:00Z",
    });
    defer out.deinit();
    try std.testing.expectEqualStrings("stacks/demo", out.paths[0]);

    try tmp.dir.access("stacks/demo/0001-inserted/meta.toml", .{});
    try tmp.dir.access("stacks/demo/0002-first/meta.toml", .{});

    var f = try tmp.dir.openFile("stacks/demo/0002-first/meta.toml", .{});
    defer f.close();
    const stat = try f.stat();
    const contents = try a.alloc(u8, stat.size);
    defer a.free(contents);
    _ = try f.readAll(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, "id = \"0002\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "slug = \"first\"") != null);
}

test "applySetPaused: flips stack.toml without touching items" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("stacks/demo/0001-hi");
    {
        var f = try tmp.dir.createFile("stacks/demo/stack.toml", .{ .truncate = true });
        defer f.close();
        try f.writeAll("description = \"x\"\npaused = false\n");
    }
    {
        var f = try tmp.dir.createFile("stacks/demo/0001-hi/meta.toml", .{ .truncate = true });
        defer f.close();
        try f.writeAll(
            \\id = "0001"
            \\slug = "hi"
            \\kind = "prompt"
            \\status = "queued"
            \\created_at = 2026-05-10T14:00:00Z
            \\updated_at = 2026-05-10T14:00:00Z
            \\
            \\[target]
            \\match = "any"
            \\
        );
    }
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = try tmp.dir.realpath(".", &buf);

    var out = try applySetPaused(a, abs, .{ .api_path = "POST /stacks/demo/pause" }, "demo", true);
    defer out.deinit();
    try std.testing.expectEqualStrings("stacks/demo/stack.toml", out.paths[0]);

    // stack.toml now says paused = true.
    var f = try tmp.dir.openFile("stacks/demo/stack.toml", .{});
    defer f.close();
    const stat = try f.stat();
    const contents = try a.alloc(u8, stat.size);
    defer a.free(contents);
    _ = try f.readAll(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, "paused = true") != null);

    // Item is untouched.
    var fi = try tmp.dir.openFile("stacks/demo/0001-hi/meta.toml", .{});
    defer fi.close();
    const istat = try fi.stat();
    const icontents = try a.alloc(u8, istat.size);
    defer a.free(icontents);
    _ = try fi.readAll(icontents);
    try std.testing.expect(std.mem.indexOf(u8, icontents, "status = \"queued\"") != null);
}

test "applyTransition: cancel queued item" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("stacks/demo/0001-hi");
    {
        var f = try tmp.dir.createFile("stacks/demo/0001-hi/meta.toml", .{ .truncate = true });
        defer f.close();
        try f.writeAll(
            \\id = "0001"
            \\slug = "hi"
            \\kind = "prompt"
            \\status = "queued"
            \\created_at = 2026-05-10T14:00:00Z
            \\updated_at = 2026-05-10T14:00:00Z
            \\
            \\[target]
            \\match = "any"
            \\
        );
    }
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = try tmp.dir.realpath(".", &buf);

    var out = try applyTransition(a, abs, .{ .api_path = "POST /...cancel" }, .{
        .stack = "demo",
        .id = "0001",
        .transition = .cancel,
    });
    defer out.deinit();
    try std.testing.expectEqualStrings("cancel_item", out.audit_action.slug());

    var f = try tmp.dir.openFile("stacks/demo/0001-hi/meta.toml", .{});
    defer f.close();
    const stat = try f.stat();
    const contents = try a.alloc(u8, stat.size);
    defer a.free(contents);
    _ = try f.readAll(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, "status = \"canceled\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "canceled_by = \"user:local\"") != null);
}

test "applyTransition: retry only valid from blocked" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("stacks/demo/0001-hi");
    {
        var f = try tmp.dir.createFile("stacks/demo/0001-hi/meta.toml", .{ .truncate = true });
        defer f.close();
        try f.writeAll(
            \\id = "0001"
            \\slug = "hi"
            \\kind = "prompt"
            \\status = "queued"
            \\created_at = 2026-05-10T14:00:00Z
            \\updated_at = 2026-05-10T14:00:00Z
            \\
            \\[target]
            \\match = "any"
            \\
        );
    }
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = try tmp.dir.realpath(".", &buf);

    try std.testing.expectError(error.InvalidStateTransition, applyTransition(a, abs, .{ .api_path = "x" }, .{
        .stack = "demo",
        .id = "0001",
        .transition = .retry,
    }));
}

test "applyConfigPatch: paused via patch" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("stacks/demo");
    {
        var f = try tmp.dir.createFile("stacks/demo/stack.toml", .{ .truncate = true });
        defer f.close();
        try f.writeAll("paused = false\n");
    }
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = try tmp.dir.realpath(".", &buf);

    var out = try applyConfigPatch(a, abs, .{ .api_path = "POST cfg" }, "demo", &.{
        .{ .key = "paused", .value = "true" },
        .{ .key = "continuity", .value = "chain" },
    });
    defer out.deinit();

    var f = try tmp.dir.openFile("stacks/demo/stack.toml", .{});
    defer f.close();
    const stat = try f.stat();
    const contents = try a.alloc(u8, stat.size);
    defer a.free(contents);
    _ = try f.readAll(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, "paused = true") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "continuity = \"chain\"") != null);
}

test "applyConfigPatch: TOML-escapes string values" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("stacks/demo");
    {
        var f = try tmp.dir.createFile("stacks/demo/stack.toml", .{ .truncate = true });
        defer f.close();
        try f.writeAll("description = \"old\"\n");
    }
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = try tmp.dir.realpath(".", &buf);

    var out = try applyConfigPatch(a, abs, .{ .api_path = "POST cfg" }, "demo", &.{
        .{ .key = "description", .value = "quoted \"and\" backslash \\ newline\n" },
    });
    defer out.deinit();

    var f = try tmp.dir.openFile("stacks/demo/stack.toml", .{});
    defer f.close();
    const stat = try f.stat();
    const contents = try a.alloc(u8, stat.size);
    defer a.free(contents);
    _ = try f.readAll(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, "description = \"quoted \\\"and\\\" backslash \\\\ newline\\n\"") != null);
}
