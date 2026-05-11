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
const stack_config = @import("stack_config.zig");
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
    ".organo", "stacks", ".git",
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
    const file_rel = try std.fmt.allocPrint(allocator, "stacks/{s}/stack.toml", .{input.name});
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
    const body = try std.fmt.allocPrint(allocator,
        "stack: {s}\nidentity: {s}\napi: {s}\n", .{ input.name, ident.identity, ident.api_path });
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
    /// Parents (e.g. for review items).
    parents: ?[]const []const u8 = null,
    /// Sleep `until` (RFC3339); required when kind=sleep.
    sleep_until: ?[]const u8 = null,
    /// When non-null, override `created_at` (for deterministic fixtures).
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
        .parents = input.parents,
        .sleep_until = input.sleep_until,
        .created_at_override = input.created_at_override,
    });
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

    // v1: insert means "insert before ref" but we only support inserting at
    // the front; otherwise the user is expected to append. We pick the next
    // id as max(existing)+1 — same as append — and reject if it would sort
    // after `ref`. Renumbering existing items is a future enhancement (the
    // commit grouping rule in design_version_control.md already permits it).
    const next_id_int = try computeNextItemIdInt(allocator, stack_abs);
    var id_buf: [16]u8 = undefined;
    const new_id = try std.fmt.bufPrint(&id_buf, "{d:0>4}", .{next_id_int});

    const ref_int = std.fmt.parseInt(u32, input.ref, 10) catch return error.ValidationFailed;
    if (next_id_int >= ref_int) {
        // The new id wouldn't sort before ref. v1: reject.
        return error.ValidationFailed;
    }

    return writeItem(allocator, notes_root_abs, ident, .insert_item, input.stack, new_id, kind, input.slug, .{
        .prompt_body = input.prompt_body,
        .target_provider = input.target_provider,
        .target_model = input.target_model,
        .target_match = input.target_match,
        .target_workdir = input.target_workdir,
        .parents = input.parents,
        .sleep_until = input.sleep_until,
        .created_at_override = input.created_at_override,
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
    const path_rel = try std.fmt.allocPrint(allocator, "stacks/{s}/{s}/meta.toml", .{ input.stack, item_dir_name });
    var paths_list = std.ArrayList([]u8){};
    errdefer {
        for (paths_list.items) |p| allocator.free(p);
        paths_list.deinit(allocator);
    }
    try paths_list.append(allocator, path_rel);

    const subject = try std.fmt.allocPrint(allocator, "item: {s} {s}", .{ verb, input.id });
    const body = try std.fmt.allocPrint(allocator,
        "stack: {s}\nitem: {s}\nidentity: {s}\napi: {s}\n", .{ input.stack, input.id, ident.identity, ident.api_path });
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
    const cfg_path_rel = try std.fmt.allocPrint(allocator, "stacks/{s}/stack.toml", .{stack});
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
    const body = try std.fmt.allocPrint(allocator,
        "stack: {s}\nidentity: {s}\napi: {s}\n", .{ stack, ident.identity, ident.api_path });
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

    const cfg_rel = try std.fmt.allocPrint(allocator, "stacks/{s}/stack.toml", .{stack});
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
    const body = try std.fmt.allocPrint(allocator,
        "stack: {s}\nidentity: {s}\napi: {s}\n", .{ stack, ident.identity, ident.api_path });
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

const WriteItemOpts = struct {
    prompt_body: ?[]const u8 = null,
    target_provider: ?[]const u8 = null,
    target_model: ?[]const u8 = null,
    target_match: ?item_mod.Match = null,
    target_workdir: ?[]const u8 = null,
    parents: ?[]const []const u8 = null,
    sleep_until: ?[]const u8 = null,
    created_at_override: ?[]const u8 = null,
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
    const dir_name = try std.fmt.allocPrint(aa, "{s}-{s}", .{ id, slug });
    const dir_abs = try std.fs.path.join(aa, &.{ notes_root_abs, "stacks", stack, dir_name });
    try std.fs.cwd().makePath(dir_abs);

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
    // Build [target] table if any field is set or kind requires it.
    const has_any_target = opts.target_provider != null or opts.target_model != null or
        opts.target_match != null or opts.target_workdir != null;
    if (has_any_target or kind == .prompt or kind == .review or kind == .compact) {
        var t: item_mod.Target = .{};
        if (opts.target_provider) |s| t.provider = try ia.dupe(u8, s);
        if (opts.target_model) |s| t.model = try ia.dupe(u8, s);
        t.match = opts.target_match orelse .any;
        if (opts.target_workdir) |s| t.workdir = try ia.dupe(u8, s);
        item.target = t;
    }
    if (kind == .sleep) {
        item.sleep = .{ .until = try ia.dupe(u8, opts.sleep_until.?) };
    }
    if (kind == .clear) {
        item.clear_present = true;
    }

    // Run validation to confirm shape.
    var vd: item_mod.ValidationDiagnostic = .{};
    item_mod.validate(&item, &vd) catch return error.ValidationFailed;

    // Serialize and write.
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
    const meta_rel = try std.fmt.allocPrint(allocator, "stacks/{s}/{s}/meta.toml", .{ stack, dir_name });
    var paths_list = std.ArrayList([]u8){};
    errdefer {
        for (paths_list.items) |p| allocator.free(p);
        paths_list.deinit(allocator);
    }
    try paths_list.append(allocator, meta_rel);
    if (prompt_rel) |pr| {
        try paths_list.append(allocator, try allocator.dupe(u8, pr));
    }

    const verb = if (action == .insert_item) "insert" else "append";
    const subject = try std.fmt.allocPrint(allocator, "stack: {s} {s}-{s}", .{ verb, id, slug });
    const body_str = try std.fmt.allocPrint(allocator,
        "stack: {s}\nitem: {s}\nidentity: {s}\napi: {s}\n", .{ stack, id, ident.identity, ident.api_path });
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
        const quoted = try std.fmt.allocPrint(allocator, "\"{s}\"", .{value});
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
        _ = std.fmt.parseInt(i64, value, 10) catch return error.BadConfigValue;
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

// ---------- tests ----------

test "validateNewStackName: ok and reject" {
    try validateNewStackName("foo");
    try validateNewStackName("foo-bar");
    try std.testing.expectError(error.InvalidName, validateNewStackName("Foo"));
    try std.testing.expectError(error.InvalidName, validateNewStackName(""));
    try std.testing.expectError(error.NameReserved, validateNewStackName(".organo"));
    try std.testing.expectError(error.NameReserved, validateNewStackName("stacks"));
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
