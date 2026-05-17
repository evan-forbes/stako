//! In-process stack domain API.
//!
//! The durable source of truth remains the notes root on disk. A `Stack`
//! owns only process-local coordination for one stack: its name, the notes
//! root borrow, mutation mutex, VCS/audit configuration, and the post-mutation
//! wake hook. Reads intentionally re-open disk through `storage.Reader`.

const std = @import("std");
const audit = @import("audit.zig");
const item_mod = @import("item.zig");
const mutations = @import("mutations.zig");
const stack_config = @import("stack_config.zig");
const storage = @import("storage.zig");
const vcs = @import("vcs.zig");

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

pub const RuntimeTargetStatus = mutations.RuntimeStatus;
pub const RuntimeTransitionInput = mutations.RuntimeTransitionInput;

pub const StackResult = struct {
    output: mutations.MutationOutput,
    commit_short_sha: [12]u8 = std.mem.zeroes([12]u8),
    commit_short_sha_len: u8 = 0,
    created_item_id: ?[]const u8 = null,

    pub fn deinit(self: *StackResult) void {
        self.output.deinit();
        self.created_item_id = null;
    }
};

pub const MutationResult = union(enum) {
    ok: StackResult,
    err: MutationFailureKind,
};

pub const PostCommitHook = *const fn (ctx: ?*anyopaque, stack_name: []const u8) void;

pub const Stack = struct {
    allocator: std.mem.Allocator,
    name: []u8,
    notes_root_abs: []const u8,
    mutex: std.Thread.Mutex = .{},
    enable_git: bool = true,
    audit_writer: ?*audit.Writer = null,
    post_commit_ctx: ?*anyopaque = null,
    post_commit_fn: ?PostCommitHook = null,

    pub fn init(
        allocator: std.mem.Allocator,
        name: []const u8,
        notes_root_abs: []const u8,
        audit_writer: ?*audit.Writer,
        enable_git: bool,
    ) !Stack {
        return .{
            .allocator = allocator,
            .name = try allocator.dupe(u8, name),
            .notes_root_abs = notes_root_abs,
            .enable_git = enable_git,
            .audit_writer = audit_writer,
        };
    }

    pub fn deinit(self: *Stack) void {
        self.allocator.free(self.name);
    }

    pub fn appendItem(self: *Stack, ident: mutations.IdentityCtx, input: mutations.AppendItemInput) MutationResult {
        return self.runMutationLocked(ident, .{ .append_item = input });
    }

    pub fn insertItem(self: *Stack, ident: mutations.IdentityCtx, input: mutations.InsertItemInput) MutationResult {
        return self.runMutationLocked(ident, .{ .insert_item = input });
    }

    pub fn transitionItem(self: *Stack, ident: mutations.IdentityCtx, input: mutations.TransitionInput) MutationResult {
        return self.runMutationLocked(ident, .{ .transition = input });
    }

    pub fn runtimeTransitionItem(self: *Stack, ident: mutations.IdentityCtx, input: mutations.RuntimeTransitionInput) MutationResult {
        return self.runMutationLocked(ident, .{ .runtime_transition = input });
    }

    pub fn setPaused(self: *Stack, ident: mutations.IdentityCtx, paused: bool) MutationResult {
        return self.runMutationLocked(ident, if (paused)
            .{ .pause_stack = .{ .stack = self.name } }
        else
            .{ .resume_stack = .{ .stack = self.name } });
    }

    pub fn patchConfig(self: *Stack, ident: mutations.IdentityCtx, patches: []const mutations.ConfigPatch) MutationResult {
        return self.runMutationLocked(ident, .{ .config_patch = .{ .stack = self.name, .patches = patches } });
    }

    fn runMutationLocked(self: *Stack, ident: mutations.IdentityCtx, kind: MutationKind) MutationResult {
        self.mutex.lock();
        defer self.mutex.unlock();

        const result = runMutation(
            self.allocator,
            self.notes_root_abs,
            self.enable_git,
            self.audit_writer,
            ident,
            kind,
        );
        if (result == .ok) {
            if (self.post_commit_fn) |hook| hook(self.post_commit_ctx, self.name);
        }
        return result;
    }
};

pub const StackRegistry = struct {
    allocator: std.mem.Allocator,
    notes_root_abs: []const u8,
    enable_git: bool = true,
    audit_writer: ?*audit.Writer = null,
    post_commit_ctx: ?*anyopaque = null,
    post_commit_fn: ?PostCommitHook = null,

    mutex: std.Thread.Mutex = .{},
    stacks: std.StringHashMapUnmanaged(*Stack) = .{},

    pub fn init(
        allocator: std.mem.Allocator,
        notes_root_abs: []const u8,
        audit_writer: ?*audit.Writer,
        enable_git: bool,
    ) !StackRegistry {
        var reg: StackRegistry = .{
            .allocator = allocator,
            .notes_root_abs = notes_root_abs,
            .audit_writer = audit_writer,
            .enable_git = enable_git,
        };
        errdefer reg.deinit();

        var reader = try storage.Reader.init(allocator, notes_root_abs);
        defer reader.deinit();
        const names = try reader.listStacks();
        defer reader.freeStackList(names);
        for (names) |name| {
            _ = try reg.installStackAssumeUnlocked(name);
        }
        return reg;
    }

    pub fn deinit(self: *StackRegistry) void {
        self.mutex.lock();
        var it = self.stacks.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.stacks.deinit(self.allocator);
        self.mutex.unlock();
    }

    pub fn setPostCommitHook(self: *StackRegistry, ctx: ?*anyopaque, hook: ?PostCommitHook) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.post_commit_ctx = ctx;
        self.post_commit_fn = hook;
        var it = self.stacks.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.post_commit_ctx = ctx;
            entry.value_ptr.*.post_commit_fn = hook;
        }
    }

    pub fn setAuditWriter(self: *StackRegistry, writer: ?*audit.Writer) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.audit_writer = writer;
        var it = self.stacks.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.audit_writer = writer;
        }
    }

    pub fn localClient(self: *StackRegistry, identity: []const u8, api_path: []const u8) StackClient {
        return .{
            .registry = self,
            .identity = identity,
            .api_path = api_path,
        };
    }

    fn getStack(self: *StackRegistry, name: []const u8) ?*Stack {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.stacks.get(name);
    }

    fn installStackAssumeUnlocked(self: *StackRegistry, name: []const u8) !*Stack {
        const p = try self.allocator.create(Stack);
        errdefer self.allocator.destroy(p);
        p.* = try Stack.init(self.allocator, name, self.notes_root_abs, self.audit_writer, self.enable_git);
        p.post_commit_ctx = self.post_commit_ctx;
        p.post_commit_fn = self.post_commit_fn;
        errdefer p.deinit();
        try self.stacks.put(self.allocator, p.name, p);
        return p;
    }
};

pub const StackClient = struct {
    registry: *StackRegistry,
    identity: []const u8,
    api_path: []const u8,

    fn ident(self: *const StackClient) mutations.IdentityCtx {
        return .{ .identity = self.identity, .api_path = self.api_path };
    }

    pub fn listStacks(self: *const StackClient) ![][]const u8 {
        var reader = try storage.Reader.init(self.registry.allocator, self.registry.notes_root_abs);
        defer reader.deinit();
        return reader.listStacks();
    }

    pub fn freeStackList(self: *const StackClient, list: [][]const u8) void {
        var reader = storage.Reader{
            .allocator = self.registry.allocator,
            .notes_root_abs = @constCast(self.registry.notes_root_abs),
        };
        reader.freeStackList(list);
    }

    pub fn readStackConfig(self: *const StackClient, name: []const u8) !stack_config.StackConfig {
        var reader = try storage.Reader.init(self.registry.allocator, self.registry.notes_root_abs);
        defer reader.deinit();
        return reader.readStackConfig(name);
    }

    pub fn listItems(self: *const StackClient, name: []const u8) ![]storage.ItemSummary {
        var reader = try storage.Reader.init(self.registry.allocator, self.registry.notes_root_abs);
        defer reader.deinit();
        return reader.listItems(name);
    }

    pub fn freeItemList(self: *const StackClient, list: []storage.ItemSummary) void {
        var reader = storage.Reader{
            .allocator = self.registry.allocator,
            .notes_root_abs = @constCast(self.registry.notes_root_abs),
        };
        reader.freeItemList(list);
    }

    pub fn readItem(self: *const StackClient, name: []const u8, id: []const u8) !item_mod.Item {
        var reader = try storage.Reader.init(self.registry.allocator, self.registry.notes_root_abs);
        defer reader.deinit();
        return reader.readItem(name, id);
    }

    pub fn readStack(self: *const StackClient, name: []const u8) !struct {
        config: stack_config.StackConfig,
        items: []storage.ItemSummary,
    } {
        var cfg = try self.readStackConfig(name);
        errdefer cfg.deinit();
        const items = try self.listItems(name);
        return .{ .config = cfg, .items = items };
    }

    pub fn createStack(self: *const StackClient, input: mutations.CreateStackInput) MutationResult {
        var hook_ctx: ?*anyopaque = null;
        var hook_fn: ?PostCommitHook = null;
        var created_name: []const u8 = "";

        self.registry.mutex.lock();
        const result = blk: {
            if (self.registry.stacks.get(input.name) != null) break :blk MutationResult{ .err = .already_exists };
            const out = runMutation(
                self.registry.allocator,
                self.registry.notes_root_abs,
                self.registry.enable_git,
                self.registry.audit_writer,
                self.ident(),
                .{ .create_stack = input },
            );
            if (out == .ok) {
                _ = self.registry.installStackAssumeUnlocked(input.name) catch {
                    var ok = out.ok;
                    ok.deinit();
                    break :blk MutationResult{ .err = .internal };
                };
                hook_ctx = self.registry.post_commit_ctx;
                hook_fn = self.registry.post_commit_fn;
                created_name = input.name;
            }
            break :blk out;
        };
        self.registry.mutex.unlock();

        if (result == .ok) {
            if (hook_fn) |hook| hook(hook_ctx, created_name);
        }
        return result;
    }

    pub fn appendItem(self: *const StackClient, stack_name: []const u8, input: mutations.AppendItemInput) MutationResult {
        const st = self.registry.getStack(stack_name) orelse return .{ .err = .not_found };
        return st.appendItem(self.ident(), input);
    }

    pub fn insertItem(self: *const StackClient, stack_name: []const u8, input: mutations.InsertItemInput) MutationResult {
        const st = self.registry.getStack(stack_name) orelse return .{ .err = .not_found };
        return st.insertItem(self.ident(), input);
    }

    pub fn transitionItem(self: *const StackClient, stack_name: []const u8, input: mutations.TransitionInput) MutationResult {
        const st = self.registry.getStack(stack_name) orelse return .{ .err = .not_found };
        return st.transitionItem(self.ident(), input);
    }

    pub fn runtimeTransitionItem(self: *const StackClient, stack_name: []const u8, input: mutations.RuntimeTransitionInput) MutationResult {
        const st = self.registry.getStack(stack_name) orelse return .{ .err = .not_found };
        return st.runtimeTransitionItem(self.ident(), input);
    }

    pub fn setPaused(self: *const StackClient, stack_name: []const u8, paused: bool) MutationResult {
        const st = self.registry.getStack(stack_name) orelse return .{ .err = .not_found };
        return st.setPaused(self.ident(), paused);
    }

    pub fn patchConfig(self: *const StackClient, stack_name: []const u8, patches: []const mutations.ConfigPatch) MutationResult {
        const st = self.registry.getStack(stack_name) orelse return .{ .err = .not_found };
        return st.patchConfig(self.ident(), patches);
    }
};

const MutationKind = union(enum) {
    create_stack: mutations.CreateStackInput,
    append_item: mutations.AppendItemInput,
    insert_item: mutations.InsertItemInput,
    transition: mutations.TransitionInput,
    pause_stack: struct { stack: []const u8 },
    resume_stack: struct { stack: []const u8 },
    config_patch: struct { stack: []const u8, patches: []const mutations.ConfigPatch },
    runtime_transition: mutations.RuntimeTransitionInput,

    const ItemTarget = struct {
        stack: []const u8,
        id: []const u8,
    };

    fn apply(
        self: MutationKind,
        allocator: std.mem.Allocator,
        notes_root_abs: []const u8,
        ident: mutations.IdentityCtx,
    ) !mutations.MutationOutput {
        return switch (self) {
            .create_stack => |inp| mutations.applyCreateStack(allocator, notes_root_abs, ident, inp),
            .append_item => |inp| mutations.applyAppendItem(allocator, notes_root_abs, ident, inp),
            .insert_item => |inp| mutations.applyInsertItem(allocator, notes_root_abs, ident, inp),
            .transition => |inp| mutations.applyTransition(allocator, notes_root_abs, ident, inp),
            .pause_stack => |p| mutations.applySetPaused(allocator, notes_root_abs, ident, p.stack, true),
            .resume_stack => |p| mutations.applySetPaused(allocator, notes_root_abs, ident, p.stack, false),
            .config_patch => |p| mutations.applyConfigPatch(allocator, notes_root_abs, ident, p.stack, p.patches),
            .runtime_transition => |inp| mutations.applyRuntimeTransition(allocator, notes_root_abs, ident, inp),
        };
    }

    fn skipsCommit(self: MutationKind) bool {
        return switch (self) {
            .runtime_transition => |inp| inp.to == .running,
            else => false,
        };
    }

    fn stackConfigPreflight(self: MutationKind) ?[]const u8 {
        return switch (self) {
            .pause_stack => |p| p.stack,
            .resume_stack => |p| p.stack,
            .config_patch => |p| p.stack,
            else => null,
        };
    }

    fn stackDirPreflight(self: MutationKind) ?[]const u8 {
        return switch (self) {
            .insert_item => |inp| inp.stack,
            else => null,
        };
    }

    fn itemMetaPreflight(self: MutationKind) ?ItemTarget {
        return switch (self) {
            .transition => |inp| .{ .stack = inp.stack, .id = inp.id },
            .runtime_transition => |inp| .{ .stack = inp.stack, .id = inp.id },
            else => null,
        };
    }
};

fn runMutation(
    allocator: std.mem.Allocator,
    notes_root_abs: []const u8,
    enable_git: bool,
    audit_writer: ?*audit.Writer,
    ident: mutations.IdentityCtx,
    kind: MutationKind,
) MutationResult {
    if (enable_git) {
        const preflight_paths = computePreflightPaths(allocator, notes_root_abs, kind) catch {
            return .{ .err = .internal };
        };
        defer freePreflightPaths(allocator, preflight_paths);
        if (preflight_paths.len > 0) {
            if (vcs.assertPathsClean(allocator, notes_root_abs, preflight_paths)) |_| {} else |e| switch (e) {
                error.HasDirtyTarget => return .{ .err = .vcs_dirty },
                error.GitNotFound => return .{ .err = .git_not_found },
                else => return .{ .err = .git_failed },
            }
        }
    }

    const out = kind.apply(allocator, notes_root_abs, ident) catch |e| {
        return .{ .err = mutationErrorToKind(e) };
    };
    const skip_commit = kind.skipsCommit();

    var result = StackResult{
        .output = out,
        .created_item_id = findCreatedItemId(out.audit_details),
    };

    if (enable_git and !skip_commit) {
        const commit_res = vcs.commit(allocator, notes_root_abs, .{
            .paths = sliceConst(out.paths),
            .subject = out.commit_subject,
            .body = out.commit_body,
        }) catch |e| {
            vcs.rollbackPaths(allocator, notes_root_abs, sliceConst(out.paths)) catch {};
            result.deinit();
            return .{ .err = switch (e) {
                error.GitNotFound => .git_not_found,
                else => .git_failed,
            } };
        };
        result.commit_short_sha_len = commit_res.short_sha_len;
        std.mem.copyForwards(u8, &result.commit_short_sha, &commit_res.short_sha);
    }

    if (!skip_commit) {
        if (audit_writer) |aw| {
            aw.append(.{
                .identity = ident.identity,
                .action = out.audit_action,
                .target = out.audit_target,
                .outcome = .allowed,
                .details = out.audit_details,
            }) catch {};
        }
    }

    return .{ .ok = result };
}

fn findCreatedItemId(details: []const audit.DetailKV) ?[]const u8 {
    for (details) |d| {
        if (std.mem.eql(u8, d.key, "id")) return d.value;
    }
    return null;
}

fn computePreflightPaths(
    allocator: std.mem.Allocator,
    notes_root_abs: []const u8,
    kind: MutationKind,
) ![][]u8 {
    var out = std.ArrayList([]u8){};
    errdefer {
        for (out.items) |p| allocator.free(p);
        out.deinit(allocator);
    }
    if (kind.stackConfigPreflight()) |stack_name| {
        try out.append(allocator, try mutations.stackConfigRel(allocator, stack_name));
    }
    if (kind.stackDirPreflight()) |stack_name| {
        try out.append(allocator, try mutations.stackDirRel(allocator, stack_name));
    }
    if (kind.itemMetaPreflight()) |target| {
        try appendItemMetaPreflight(allocator, notes_root_abs, &out, target.stack, target.id);
    }
    return out.toOwnedSlice(allocator);
}

fn appendItemMetaPreflight(
    allocator: std.mem.Allocator,
    notes_root_abs: []const u8,
    out: *std.ArrayList([]u8),
    stack_name: []const u8,
    id: []const u8,
) !void {
    const stack_abs = try std.fs.path.join(allocator, &.{ notes_root_abs, "stacks", stack_name });
    defer allocator.free(stack_abs);
    var d = std.fs.openDirAbsolute(stack_abs, .{ .iterate = true }) catch return;
    defer d.close();
    var it = d.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind != .directory) continue;
        const dash = std.mem.indexOfScalar(u8, entry.name, '-') orelse continue;
        if (std.mem.eql(u8, entry.name[0..dash], id)) {
            try out.append(allocator, try mutations.itemMetaRel(allocator, stack_name, entry.name));
            break;
        }
    }
}

fn freePreflightPaths(allocator: std.mem.Allocator, paths: [][]u8) void {
    for (paths) |p| allocator.free(p);
    allocator.free(paths);
}

fn sliceConst(s: [][]u8) []const []const u8 {
    return @ptrCast(s);
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

test "StackClient: create stack, append item, and pause" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath(".stako");
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = try tmp.dir.realpath(".", &buf);

    var aw = try audit.Writer.init(a, abs);
    defer aw.deinit();

    var reg = try StackRegistry.init(a, abs, &aw, false);
    defer reg.deinit();
    const client = reg.localClient("local", "test");

    switch (client.createStack(.{
        .name = "demo",
        .created_at_override = "2026-05-10T14:00:00Z",
    })) {
        .ok => |ok_value| {
            var ok = ok_value;
            defer ok.deinit();
        },
        .err => return error.UnexpectedMutationFailure,
    }

    switch (client.appendItem("demo", .{
        .stack = "demo",
        .kind = "prompt",
        .slug = "hello",
        .prompt_body = "hello",
        .target_match = .any,
        .created_at_override = "2026-05-10T14:00:00Z",
    })) {
        .ok => |ok_value| {
            var ok = ok_value;
            defer ok.deinit();
            try std.testing.expectEqualStrings("0001", ok.created_item_id orelse "");
        },
        .err => return error.UnexpectedMutationFailure,
    }

    switch (client.setPaused("demo", true)) {
        .ok => |ok_value| {
            var ok = ok_value;
            defer ok.deinit();
        },
        .err => return error.UnexpectedMutationFailure,
    }

    var cfg = try client.readStackConfig("demo");
    defer cfg.deinit();
    try std.testing.expect(cfg.paused);

    const items = try client.listItems("demo");
    defer client.freeItemList(items);
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqualStrings("0001", items[0].id);
}
