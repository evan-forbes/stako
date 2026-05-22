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
const output_packet = @import("output_packet.zig");
const routine_mod = @import("routine.zig");
const stack_config = @import("stack_config.zig");
const stack_thread = @import("stack_thread.zig");
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
    bad_thread_key,
    bad_thread_value,
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

    pub fn appendRoutine(self: *Stack, ident: mutations.IdentityCtx, input: mutations.AppendRoutineInput) MutationResult {
        return self.runMutationLocked(ident, .{ .append_routine = input });
    }

    pub fn insertItem(self: *Stack, ident: mutations.IdentityCtx, input: mutations.InsertItemInput) MutationResult {
        return self.runMutationLocked(ident, .{ .insert_item = input });
    }

    pub fn transitionItem(self: *Stack, ident: mutations.IdentityCtx, input: mutations.TransitionInput) MutationResult {
        return self.runMutationLocked(ident, .{ .transition = input });
    }

    pub fn updateItemPrompt(self: *Stack, ident: mutations.IdentityCtx, input: mutations.UpdateItemPromptInput) MutationResult {
        return self.runMutationLocked(ident, .{ .update_item_prompt = input });
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

    pub fn createThread(self: *Stack, ident: mutations.IdentityCtx, input: mutations.CreateThreadInput) MutationResult {
        if (!std.mem.eql(u8, input.stack, self.name)) return .{ .err = .validation_failed };
        return self.runMutationLocked(ident, .{ .create_thread = input });
    }

    pub fn patchThread(self: *Stack, ident: mutations.IdentityCtx, name: []const u8, patches: []const mutations.ThreadPatch) MutationResult {
        return self.runMutationLocked(ident, .{ .patch_thread = .{ .stack = self.name, .name = name, .patches = patches } });
    }

    pub fn archiveThread(self: *Stack, ident: mutations.IdentityCtx, name: []const u8) MutationResult {
        return self.runMutationLocked(ident, .{ .archive_thread = .{ .stack = self.name, .name = name } });
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

    pub fn listThreads(self: *const StackClient, name: []const u8) ![]storage.ThreadSummary {
        var reader = try storage.Reader.init(self.registry.allocator, self.registry.notes_root_abs);
        defer reader.deinit();
        return reader.listThreads(name);
    }

    pub fn freeThreadList(self: *const StackClient, list: []storage.ThreadSummary) void {
        var reader = storage.Reader{
            .allocator = self.registry.allocator,
            .notes_root_abs = @constCast(self.registry.notes_root_abs),
        };
        reader.freeThreadList(list);
    }

    pub fn readThread(self: *const StackClient, name: []const u8, thread_name: []const u8) !stack_thread.Thread {
        var reader = try storage.Reader.init(self.registry.allocator, self.registry.notes_root_abs);
        defer reader.deinit();
        return reader.readThread(name, thread_name);
    }

    pub fn listRoutines(self: *const StackClient) ![]storage.RoutineSummary {
        var reader = try storage.Reader.init(self.registry.allocator, self.registry.notes_root_abs);
        defer reader.deinit();
        return reader.listRoutines();
    }

    pub fn freeRoutineList(self: *const StackClient, list: []storage.RoutineSummary) void {
        var reader = storage.Reader{
            .allocator = self.registry.allocator,
            .notes_root_abs = @constCast(self.registry.notes_root_abs),
        };
        reader.freeRoutineList(list);
    }

    pub fn readRoutine(self: *const StackClient, name: []const u8) !routine_mod.Routine {
        var reader = try storage.Reader.init(self.registry.allocator, self.registry.notes_root_abs);
        defer reader.deinit();
        return reader.readRoutine(name);
    }

    pub fn readItem(self: *const StackClient, name: []const u8, id: []const u8) !item_mod.Item {
        var reader = try storage.Reader.init(self.registry.allocator, self.registry.notes_root_abs);
        defer reader.deinit();
        return reader.readItem(name, id);
    }

    pub fn readItemOutputSummary(self: *const StackClient, name: []const u8, id: []const u8) ![]u8 {
        const item_dir = try findItemDirForRead(self.registry.allocator, self.registry.notes_root_abs, name, id);
        defer self.registry.allocator.free(item_dir);
        const path = try std.fs.path.join(self.registry.allocator, &.{ self.registry.notes_root_abs, "stacks", name, item_dir, "output", "summary.md" });
        defer self.registry.allocator.free(path);
        return output_packet.readSummary(self.registry.allocator, path);
    }

    pub fn readItemOutputManifest(self: *const StackClient, name: []const u8, id: []const u8) !output_packet.Manifest {
        const item_dir = try findItemDirForRead(self.registry.allocator, self.registry.notes_root_abs, name, id);
        defer self.registry.allocator.free(item_dir);
        const path = try std.fs.path.join(self.registry.allocator, &.{ self.registry.notes_root_abs, "stacks", name, item_dir, "output", "manifest.toml" });
        defer self.registry.allocator.free(path);
        return output_packet.readManifest(self.registry.allocator, path);
    }

    pub fn recentCompletedItemInputs(self: *const StackClient, name: []const u8, limit: usize) ![][]const u8 {
        const items = try self.listItems(name);
        defer self.freeItemList(items);

        var out = std.ArrayList([]const u8){};
        errdefer {
            for (out.items) |id| self.registry.allocator.free(id);
            out.deinit(self.registry.allocator);
        }

        var i = items.len;
        while (i > 0 and out.items.len < limit) {
            i -= 1;
            const summary = items[i];
            if (!std.mem.eql(u8, summary.status, "completed")) continue;
            try out.append(self.registry.allocator, try self.registry.allocator.dupe(u8, summary.id));
        }
        std.mem.reverse([]const u8, out.items);
        return out.toOwnedSlice(self.registry.allocator);
    }

    pub fn freeStringList(self: *const StackClient, list: []const []const u8) void {
        for (list) |s| self.registry.allocator.free(s);
        self.registry.allocator.free(list);
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

    pub fn appendRoutine(self: *const StackClient, stack_name: []const u8, input: mutations.AppendRoutineInput) MutationResult {
        const st = self.registry.getStack(stack_name) orelse return .{ .err = .not_found };
        return st.appendRoutine(self.ident(), input);
    }

    pub fn insertItem(self: *const StackClient, stack_name: []const u8, input: mutations.InsertItemInput) MutationResult {
        const st = self.registry.getStack(stack_name) orelse return .{ .err = .not_found };
        return st.insertItem(self.ident(), input);
    }

    pub fn transitionItem(self: *const StackClient, stack_name: []const u8, input: mutations.TransitionInput) MutationResult {
        const st = self.registry.getStack(stack_name) orelse return .{ .err = .not_found };
        return st.transitionItem(self.ident(), input);
    }

    pub fn updateItemPrompt(self: *const StackClient, stack_name: []const u8, input: mutations.UpdateItemPromptInput) MutationResult {
        const st = self.registry.getStack(stack_name) orelse return .{ .err = .not_found };
        return st.updateItemPrompt(self.ident(), input);
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

    pub fn createThread(self: *const StackClient, stack_name: []const u8, input: mutations.CreateThreadInput) MutationResult {
        const st = self.registry.getStack(stack_name) orelse return .{ .err = .not_found };
        return st.createThread(self.ident(), input);
    }

    pub fn ensureThread(self: *const StackClient, stack_name: []const u8, input: mutations.CreateThreadInput) MutationResult {
        if (!std.mem.eql(u8, stack_name, input.stack)) return .{ .err = .validation_failed };
        var existing = self.readThread(stack_name, input.name) catch |e| switch (e) {
            error.NotFound => return self.createThread(stack_name, input),
            error.BadThreadName => return .{ .err = .invalid_name },
            else => return .{ .err = .internal },
        };
        existing.deinit();
        return noOpThreadResult(self.registry.allocator, self.ident(), stack_name, input.name);
    }

    pub fn patchThread(self: *const StackClient, stack_name: []const u8, thread_name: []const u8, patches: []const mutations.ThreadPatch) MutationResult {
        const st = self.registry.getStack(stack_name) orelse return .{ .err = .not_found };
        return st.patchThread(self.ident(), thread_name, patches);
    }

    pub fn archiveThread(self: *const StackClient, stack_name: []const u8, thread_name: []const u8) MutationResult {
        const st = self.registry.getStack(stack_name) orelse return .{ .err = .not_found };
        return st.archiveThread(self.ident(), thread_name);
    }
};

const MutationKind = union(enum) {
    create_stack: mutations.CreateStackInput,
    append_item: mutations.AppendItemInput,
    append_routine: mutations.AppendRoutineInput,
    insert_item: mutations.InsertItemInput,
    transition: mutations.TransitionInput,
    update_item_prompt: mutations.UpdateItemPromptInput,
    pause_stack: struct { stack: []const u8 },
    resume_stack: struct { stack: []const u8 },
    config_patch: struct { stack: []const u8, patches: []const mutations.ConfigPatch },
    runtime_transition: mutations.RuntimeTransitionInput,
    create_thread: mutations.CreateThreadInput,
    patch_thread: struct { stack: []const u8, name: []const u8, patches: []const mutations.ThreadPatch },
    archive_thread: struct { stack: []const u8, name: []const u8 },

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
            .append_routine => |inp| mutations.applyAppendRoutine(allocator, notes_root_abs, ident, inp),
            .insert_item => |inp| mutations.applyInsertItem(allocator, notes_root_abs, ident, inp),
            .transition => |inp| mutations.applyTransition(allocator, notes_root_abs, ident, inp),
            .update_item_prompt => |inp| mutations.applyUpdateItemPrompt(allocator, notes_root_abs, ident, inp),
            .pause_stack => |p| mutations.applySetPaused(allocator, notes_root_abs, ident, p.stack, true),
            .resume_stack => |p| mutations.applySetPaused(allocator, notes_root_abs, ident, p.stack, false),
            .config_patch => |p| mutations.applyConfigPatch(allocator, notes_root_abs, ident, p.stack, p.patches),
            .runtime_transition => |inp| mutations.applyRuntimeTransition(allocator, notes_root_abs, ident, inp),
            .create_thread => |inp| mutations.applyCreateThread(allocator, notes_root_abs, ident, inp),
            .patch_thread => |p| mutations.applyPatchThread(allocator, notes_root_abs, ident, .{ .stack = p.stack, .name = p.name, .patches = p.patches }),
            .archive_thread => |p| mutations.applyArchiveThread(allocator, notes_root_abs, ident, p.stack, p.name),
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

    fn threadPreflight(self: MutationKind) ?struct { stack: []const u8, name: []const u8 } {
        return switch (self) {
            .patch_thread => |p| .{ .stack = p.stack, .name = p.name },
            .archive_thread => |p| .{ .stack = p.stack, .name = p.name },
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
            .update_item_prompt => |inp| .{ .stack = inp.stack, .id = inp.id },
            else => null,
        };
    }

    fn runtimeThreadPreflight(self: MutationKind) ?ItemTarget {
        return switch (self) {
            .runtime_transition => |inp| if (inp.to == .completed) .{ .stack = inp.stack, .id = inp.id } else null,
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
    if (kind.runtimeThreadPreflight()) |target| {
        try appendRuntimeThreadPreflight(allocator, notes_root_abs, &out, target.stack, target.id);
    }
    if (kind.threadPreflight()) |target| {
        try out.append(allocator, try mutations.threadRel(allocator, target.stack, target.name));
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

fn appendRuntimeThreadPreflight(
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
        if (!std.mem.eql(u8, entry.name[0..dash], id)) continue;

        const meta_abs = try std.fs.path.join(allocator, &.{ stack_abs, entry.name, "meta.toml" });
        defer allocator.free(meta_abs);
        var meta_file = std.fs.cwd().openFile(meta_abs, .{}) catch return;
        defer meta_file.close();
        const stat = try meta_file.stat();
        const src = try allocator.alloc(u8, stat.size);
        defer allocator.free(src);
        const n = try meta_file.readAll(src);
        var diag: item_mod.ParseDiagnostic = .{};
        var parsed = item_mod.parseSlice(allocator, src[0..n], &diag) catch return;
        defer parsed.deinit();
        if (parsed.thread) |thread_ref| {
            if (item_mod.isValidThreadName(thread_ref.name)) {
                try out.append(allocator, try mutations.threadRel(allocator, stack_name, thread_ref.name));
            }
        }
        return;
    }
}

fn findItemDirForRead(allocator: std.mem.Allocator, notes_root_abs: []const u8, stack_name: []const u8, id: []const u8) ![]u8 {
    const stack_abs = try std.fs.path.join(allocator, &.{ notes_root_abs, "stacks", stack_name });
    defer allocator.free(stack_abs);
    var d = try std.fs.openDirAbsolute(stack_abs, .{ .iterate = true });
    defer d.close();
    var it = d.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .directory) continue;
        const dash = std.mem.indexOfScalar(u8, entry.name, '-') orelse continue;
        if (std.mem.eql(u8, entry.name[0..dash], id)) return allocator.dupe(u8, entry.name);
    }
    return error.NotFound;
}

fn noOpThreadResult(allocator: std.mem.Allocator, ident: mutations.IdentityCtx, stack_name: []const u8, thread_name: []const u8) MutationResult {
    const paths = allocator.alloc([]u8, 0) catch return .{ .err = .internal };
    errdefer allocator.free(paths);
    const subject = std.fmt.allocPrint(allocator, "thread: ensure {s}", .{thread_name}) catch return .{ .err = .internal };
    errdefer allocator.free(subject);
    const body = std.fmt.allocPrint(allocator, "stack: {s}\nthread: {s}\nidentity: {s}\napi: {s}\n", .{ stack_name, thread_name, ident.identity, ident.api_path }) catch return .{ .err = .internal };
    errdefer allocator.free(body);
    const target = std.fmt.allocPrint(allocator, "stack/{s}/thread/{s}", .{ stack_name, thread_name }) catch return .{ .err = .internal };
    errdefer allocator.free(target);
    const details = allocator.alloc(audit.DetailKV, 0) catch return .{ .err = .internal };
    errdefer allocator.free(details);
    const detail_storage = allocator.alloc(u8, 0) catch {
        allocator.free(details);
        return .{ .err = .internal };
    };
    return .{ .ok = .{ .output = .{
        .allocator = allocator,
        .paths = paths,
        .commit_subject = subject,
        .commit_body = body,
        .audit_action = .create_thread,
        .audit_target = target,
        .audit_details = details,
        .detail_storage = detail_storage,
        .no_op = true,
    } } };
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
        error.BadThreadKey => .bad_thread_key,
        error.BadThreadValue => .bad_thread_value,
        else => .internal,
    };
}

test "StackClient: create stack, append item, and pause" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("state");
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

test "StackClient: create, patch, archive, and read thread" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("state");
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

    switch (client.createThread("demo", .{
        .stack = "demo",
        .name = "admin",
        .created_at_override = "2026-05-17T12:00:00.000Z",
    })) {
        .ok => |ok_value| {
            var ok = ok_value;
            defer ok.deinit();
        },
        .err => return error.UnexpectedMutationFailure,
    }

    const threads = try client.listThreads("demo");
    defer client.freeThreadList(threads);
    try std.testing.expectEqual(@as(usize, 1), threads.len);
    try std.testing.expectEqualStrings("admin", threads[0].name);

    const patches = [_]mutations.ThreadPatch{
        .{ .key = "target.provider", .value = "openai" },
        .{ .key = "target.match", .value = "compatible" },
    };
    switch (client.patchThread("demo", "admin", &patches)) {
        .ok => |ok_value| {
            var ok = ok_value;
            defer ok.deinit();
        },
        .err => return error.UnexpectedMutationFailure,
    }

    var thread = try client.readThread("demo", "admin");
    defer thread.deinit();
    try std.testing.expectEqualStrings("openai", thread.target.?.provider.?);
    try std.testing.expectEqual(stack_thread.Match.compatible, thread.target.?.match.?);

    switch (client.archiveThread("demo", "admin")) {
        .ok => |ok_value| {
            var ok = ok_value;
            defer ok.deinit();
        },
        .err => return error.UnexpectedMutationFailure,
    }
    var archived = try client.readThread("demo", "admin");
    defer archived.deinit();
    try std.testing.expectEqual(stack_thread.Status.archived, archived.status);
}

test "StackClient: ensureThread creates admin thread by convention and is idempotent" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("state");
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = try tmp.dir.realpath(".", &buf);

    var aw = try audit.Writer.init(a, abs);
    defer aw.deinit();

    var reg = try StackRegistry.init(a, abs, &aw, false);
    defer reg.deinit();
    const client = reg.localClient("local", "test");

    switch (client.createStack(.{ .name = "demo", .created_at_override = "2026-05-10T14:00:00Z" })) {
        .ok => |ok_value| {
            var ok = ok_value;
            defer ok.deinit();
        },
        .err => return error.UnexpectedMutationFailure,
    }

    switch (client.ensureThread("demo", .{
        .stack = "demo",
        .name = "admin",
        .created_at_override = "2026-05-17T12:00:00.000Z",
    })) {
        .ok => |ok_value| {
            var ok = ok_value;
            defer ok.deinit();
            try std.testing.expect(!ok.output.no_op);
        },
        .err => return error.UnexpectedMutationFailure,
    }

    switch (client.ensureThread("demo", .{
        .stack = "demo",
        .name = "admin",
        .created_at_override = "2026-05-17T12:00:00.000Z",
    })) {
        .ok => |ok_value| {
            var ok = ok_value;
            defer ok.deinit();
            try std.testing.expect(ok.output.no_op);
        },
        .err => return error.UnexpectedMutationFailure,
    }

    var thread = try client.readThread("demo", "admin");
    defer thread.deinit();
    try std.testing.expectEqualStrings("admin", thread.name);
}

test "admin routine targets admin thread and ingests recent completed items" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("state");
    try tmp.dir.makePath("routines");
    try tmp.dir.makePath("prompts/admin-review");
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = try tmp.dir.realpath(".", &buf);

    {
        var f = try tmp.dir.createFile("routines/admin-review.toml", .{ .truncate = true });
        defer f.close();
        try f.writeAll(
            \\version = 1
            \\description = "Review recent stack results and decide what to do next."
            \\thread = "admin"
            \\
            \\[[step]]
            \\prompts = ["../prompts/admin-review/evaluate.md"]
            \\
        );
    }
    {
        var f = try tmp.dir.createFile("prompts/admin-review/evaluate.md", .{ .truncate = true });
        defer f.close();
        try f.writeAll("Evaluate the registered item commits.\n");
    }

    var aw = try audit.Writer.init(a, abs);
    defer aw.deinit();

    var reg = try StackRegistry.init(a, abs, &aw, false);
    defer reg.deinit();
    const client = reg.localClient("local", "test");

    switch (client.createStack(.{ .name = "demo", .created_at_override = "2026-05-10T14:00:00Z" })) {
        .ok => |ok_value| {
            var ok = ok_value;
            defer ok.deinit();
        },
        .err => return error.UnexpectedMutationFailure,
    }
    switch (client.ensureThread("demo", .{
        .stack = "demo",
        .name = "admin",
        .created_at_override = "2026-05-17T12:00:00.000Z",
    })) {
        .ok => |ok_value| {
            var ok = ok_value;
            defer ok.deinit();
        },
        .err => return error.UnexpectedMutationFailure,
    }

    try writeCompletedItem(&tmp.dir, "0001", "plan");
    try writeCompletedItem(&tmp.dir, "0002", "build");
    try writeQueuedItem(&tmp.dir, "0003", "todo");

    const inputs = try client.recentCompletedItemInputs("demo", 8);
    defer client.freeStringList(inputs);
    try std.testing.expectEqual(@as(usize, 2), inputs.len);
    try std.testing.expectEqualStrings("0001", inputs[0]);
    try std.testing.expectEqualStrings("0002", inputs[1]);

    var routine = try client.readRoutine("admin-review");
    defer routine.deinit();
    switch (client.appendRoutine("demo", .{
        .stack = "demo",
        .routine = &routine,
        .input_items = inputs,
        .created_at_override = "2026-05-17T12:00:00.000Z",
    })) {
        .ok => |ok_value| {
            var ok = ok_value;
            defer ok.deinit();
            try std.testing.expect(pathListContains(ok.output.paths, "stacks/demo/0004-evaluate/meta.toml"));
        },
        .err => return error.UnexpectedMutationFailure,
    }

    var admin_item = try client.readItem("demo", "0004");
    defer admin_item.deinit();
    try std.testing.expectEqualStrings("admin", admin_item.thread.?.name);
    try std.testing.expectEqual(item_mod.ThreadMode.fresh, admin_item.thread.?.mode);
    try std.testing.expectEqualStrings("0001", admin_item.inputs.?.items.?[0]);
    try std.testing.expectEqualStrings("0002", admin_item.inputs.?.items.?[1]);

    const item_dir = try std.fs.path.join(a, &.{ abs, "stacks/demo/0004-evaluate" });
    defer a.free(item_dir);
    const rendered = try @import("prompt_materializer.zig").resolvePrompt(a, abs, "demo", &admin_item, item_dir);
    defer a.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "stacks/demo/0001-plan") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "stacks/demo/0002-build") != null);

    switch (client.runtimeTransitionItem("demo", .{ .stack = "demo", .id = "0004", .to = .running })) {
        .ok => |ok_value| {
            var ok = ok_value;
            defer ok.deinit();
        },
        .err => return error.UnexpectedMutationFailure,
    }
    switch (client.runtimeTransitionItem("demo", .{
        .stack = "demo",
        .id = "0004",
        .to = .completed,
        .result_harness = "codex",
        .result_session_id = "admin-session",
        .result_completed_at = "2026-05-17T12:01:00.000Z",
        .output_packet = .{
            .stack = "demo",
            .item_id = "0004",
            .status = "completed",
            .summary = "needs follow-up\nReview item 0002.",
        },
    })) {
        .ok => |ok_value| {
            var ok = ok_value;
            defer ok.deinit();
        },
        .err => return error.UnexpectedMutationFailure,
    }

    var thread = try client.readThread("demo", "admin");
    defer thread.deinit();
    try std.testing.expectEqualStrings("0004", thread.state.?.last_item_id.?);
    try std.testing.expectEqualStrings("admin-session", thread.state.?.last_session_id.?);

    const items_after = try client.listItems("demo");
    defer client.freeItemList(items_after);
    try std.testing.expectEqual(@as(usize, 4), items_after.len);

    switch (client.appendRoutine("demo", .{
        .stack = "demo",
        .routine = &routine,
        .input_items = inputs,
        .created_at_override = "2026-05-17T12:02:00.000Z",
    })) {
        .ok => |ok_value| {
            var ok = ok_value;
            defer ok.deinit();
        },
        .err => return error.UnexpectedMutationFailure,
    }

    var second_admin_item = try client.readItem("demo", "0005");
    defer second_admin_item.deinit();
    try std.testing.expectEqualStrings("admin", second_admin_item.thread.?.name);
    try std.testing.expectEqual(item_mod.ThreadMode.@"resume", second_admin_item.thread.?.mode);
}

test "runtime completion preflights named thread file" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = try tmp.dir.realpath(".", &buf);
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

    const paths = try computePreflightPaths(a, abs, .{ .runtime_transition = .{
        .stack = "demo",
        .id = "0001",
        .to = .completed,
    } });
    defer freePreflightPaths(a, paths);
    try std.testing.expect(!pathListContains(paths, "stacks/demo/0001-hello/meta.toml"));
    try std.testing.expect(pathListContains(paths, "stacks/demo/threads/admin.toml"));
}

test "runtime terminal transition commits over uncommitted running snapshot" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("state");
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = try tmp.dir.realpath(".", &buf);
    try vcs.ensureRealRepo(a, abs);

    var aw = try audit.Writer.init(a, abs);
    defer aw.deinit();

    var reg = try StackRegistry.init(a, abs, &aw, true);
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
        .prompt_body = "say hello",
        .created_at_override = "2026-05-10T14:00:00Z",
    })) {
        .ok => |ok_value| {
            var ok = ok_value;
            defer ok.deinit();
        },
        .err => return error.UnexpectedMutationFailure,
    }

    switch (client.runtimeTransitionItem("demo", .{ .stack = "demo", .id = "0001", .to = .running })) {
        .ok => |ok_value| {
            var ok = ok_value;
            defer ok.deinit();
        },
        .err => return error.UnexpectedMutationFailure,
    }

    const meta_rel = "stacks/demo/0001-hello/meta.toml";
    try std.testing.expectError(error.HasDirtyTarget, vcs.assertPathsClean(a, abs, &.{meta_rel}));

    switch (client.runtimeTransitionItem("demo", .{
        .stack = "demo",
        .id = "0001",
        .to = .completed,
        .result_harness = "codex",
        .result_session_id = "session-1",
        .result_completed_at = "2026-05-10T14:01:00Z",
    })) {
        .ok => |ok_value| {
            var ok = ok_value;
            defer ok.deinit();
        },
        .err => return error.UnexpectedMutationFailure,
    }

    try vcs.assertPathsClean(a, abs, &.{meta_rel});
    var f = try tmp.dir.openFile(meta_rel, .{});
    defer f.close();
    const stat = try f.stat();
    const contents = try a.alloc(u8, stat.size);
    defer a.free(contents);
    _ = try f.readAll(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, "status = \"completed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "session_id = \"session-1\"") != null);
}

fn writeCompletedItem(dir: *std.fs.Dir, id: []const u8, slug: []const u8) !void {
    var path_buf: [128]u8 = undefined;
    const item_dir = try std.fmt.bufPrint(&path_buf, "stacks/demo/{s}-{s}", .{ id, slug });
    try dir.makePath(item_dir);
    try writeItemMeta(dir, id, slug, "completed");
}

fn writeQueuedItem(dir: *std.fs.Dir, id: []const u8, slug: []const u8) !void {
    var path_buf: [128]u8 = undefined;
    const item_dir = try std.fmt.bufPrint(&path_buf, "stacks/demo/{s}-{s}", .{ id, slug });
    try dir.makePath(item_dir);
    try writeItemMeta(dir, id, slug, "queued");
}

fn writeItemMeta(dir: *std.fs.Dir, id: []const u8, slug: []const u8, status: []const u8) !void {
    var path_buf: [128]u8 = undefined;
    const meta = try std.fmt.bufPrint(&path_buf, "stacks/demo/{s}-{s}/meta.toml", .{ id, slug });
    var f = try dir.createFile(meta, .{ .truncate = true });
    defer f.close();
    var content_buf: [512]u8 = undefined;
    const content = try std.fmt.bufPrint(&content_buf,
        \\id = "{s}"
        \\slug = "{s}"
        \\kind = "prompt"
        \\status = "{s}"
        \\created_at = 2026-05-10T14:00:00Z
        \\updated_at = 2026-05-10T14:00:00Z
        \\
        \\[target]
        \\match = "any"
        \\
    , .{ id, slug, status });
    try f.writeAll(content);
}

fn pathListContains(paths: []const []const u8, needle: []const u8) bool {
    for (paths) |p| if (std.mem.eql(u8, p, needle)) return true;
    return false;
}
