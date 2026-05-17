//! Version control wrapper (milestone 5).
//!
//! Shells out to the system `git` binary. Used by the mutation queue to
//! commit per-mutation changes inside the notes repo. v1 only commits
//! locally — no remote pushes, no branch creation.
//!
//! See `todos/design_version_control.md`.

const std = @import("std");

pub const Error = error{
    GitNotFound,
    NotARepo,
    GitFailed,
    HasMergeConflicts,
    HasDirtyTarget,
    OutOfMemory,
};

pub const CommitOptions = struct {
    /// Paths to `git add` before committing, relative to repo root.
    paths: []const []const u8,
    /// Commit subject (first line). Convention: `<scope>: <action> <subject>`.
    subject: []const u8,
    /// Optional body. May be multi-line; included verbatim after a blank line.
    body: ?[]const u8 = null,
    /// Author / committer name (`-c user.name=...`).
    author_name: []const u8 = "stako daemon",
    /// Author / committer email (`-c user.email=...`).
    author_email: []const u8 = "stako@local",
};

/// Return value of `commit`. `committed = false` means no changes were staged
/// (working tree was already clean against the indexed files); this lets the
/// daemon distinguish a no-op mutation from a real one.
pub const CommitResult = struct {
    committed: bool,
    /// Short SHA (7 chars) when `committed` is true; empty otherwise.
    short_sha: [12]u8 = std.mem.zeroes([12]u8),
    short_sha_len: u8 = 0,
};

/// Verify the directory contains a `.git` (file or dir) and `git status`
/// works. Returns error.NotARepo if the directory isn't a repo.
pub fn assertRepo(allocator: std.mem.Allocator, repo_root: []const u8) Error!void {
    var dir = std.fs.openDirAbsolute(repo_root, .{}) catch return error.NotARepo;
    defer dir.close();
    dir.access(".git", .{}) catch return error.NotARepo;
    // Use a no-op git command to confirm git is on PATH.
    const out = runGit(allocator, repo_root, &.{ "rev-parse", "--git-dir" }, false) catch |e| switch (e) {
        error.GitNotFound => return error.GitNotFound,
        else => return error.NotARepo,
    };
    allocator.free(out);
}

/// Refuse if the repo has merge conflicts (unmerged paths). Used at daemon
/// startup per the design doc.
pub fn assertNoMergeConflicts(allocator: std.mem.Allocator, repo_root: []const u8) Error!void {
    // `git diff --name-only --diff-filter=U` lists unmerged paths.
    const out = try runGit(allocator, repo_root, &.{ "diff", "--name-only", "--diff-filter=U" }, true);
    defer allocator.free(out);
    if (out.len > 0) return error.HasMergeConflicts;
}

/// Refuse if any of `paths` is currently dirty in the working tree —
/// specifically, has unstaged or staged-but-uncommitted edits to a TRACKED
/// path. Untracked paths (`??` in porcelain) are NOT considered dirty,
/// because a mutation that creates a new item must be allowed to write a
/// brand-new file.
pub fn assertPathsClean(
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    paths: []const []const u8,
) Error!void {
    if (paths.len == 0) return;
    var argv = std.ArrayList([]const u8){};
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{ "status", "--porcelain", "--" });
    for (paths) |p| try argv.append(allocator, p);
    const out = try runGit(allocator, repo_root, argv.items, true);
    defer allocator.free(out);
    if (out.len == 0) return;
    // Parse porcelain output line-by-line; a line starting with "??" is
    // untracked and tolerated.
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |line| {
        if (line.len < 2) continue;
        if (line[0] == '?' and line[1] == '?') continue;
        return error.HasDirtyTarget;
    }
}

/// Stage `paths` and commit with `subject` (and optional `body`). Returns
/// `committed = false` if there was nothing to commit after add.
pub fn commit(
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    opts: CommitOptions,
) Error!CommitResult {
    if (opts.paths.len == 0) return error.GitFailed;

    // Stage. Use `git add -- <paths>`. `-A` would touch unrelated files.
    var add_argv = std.ArrayList([]const u8){};
    defer add_argv.deinit(allocator);
    try add_argv.appendSlice(allocator, &.{ "add", "--" });
    for (opts.paths) |p| try add_argv.append(allocator, p);
    const add_out = try runGit(allocator, repo_root, add_argv.items, true);
    allocator.free(add_out);

    // Check if there is anything to commit (`git diff --cached --quiet`
    // exits 0 if no staged changes, 1 if there are staged changes).
    const has_staged = try hasStagedChanges(allocator, repo_root);
    if (!has_staged) {
        return .{ .committed = false };
    }

    // Compose the commit message.
    var msg = std.ArrayList(u8){};
    defer msg.deinit(allocator);
    try msg.appendSlice(allocator, opts.subject);
    if (opts.body) |b| {
        try msg.append(allocator, '\n');
        try msg.append(allocator, '\n');
        try msg.appendSlice(allocator, b);
    }

    // Commit, passing identity inline so we don't depend on the user's git
    // global config. `-c user.useConfigOnly=true` would be cleaner but
    // requires more careful sequencing; `-c user.name=...` is sufficient.
    const name_arg = try std.fmt.allocPrint(allocator, "user.name={s}", .{opts.author_name});
    defer allocator.free(name_arg);
    const email_arg = try std.fmt.allocPrint(allocator, "user.email={s}", .{opts.author_email});
    defer allocator.free(email_arg);

    // We pass the message via a file to avoid argv escaping pitfalls.
    const msg_path = try std.fs.path.join(allocator, &.{ repo_root, ".git", "STAKO_COMMIT_MSG" });
    defer allocator.free(msg_path);
    {
        var f = std.fs.cwd().createFile(msg_path, .{ .truncate = true, .mode = 0o600 }) catch return error.GitFailed;
        defer f.close();
        f.writeAll(msg.items) catch return error.GitFailed;
    }
    defer std.fs.cwd().deleteFile(msg_path) catch {};

    // Note: we need the message path relative to the repo root because we cd
    // into it. `.git/STAKO_COMMIT_MSG` works.
    const commit_argv = [_][]const u8{
        "-c", name_arg,
        "-c", email_arg,
        "commit", "--no-gpg-sign", "--allow-empty-message", "-F", ".git/STAKO_COMMIT_MSG",
    };
    const commit_out = try runGit(allocator, repo_root, &commit_argv, true);
    defer allocator.free(commit_out);

    // Get short SHA.
    var res: CommitResult = .{ .committed = true };
    const sha_out = runGit(allocator, repo_root, &.{ "rev-parse", "--short=7", "HEAD" }, true) catch {
        return res;
    };
    defer allocator.free(sha_out);
    const trimmed = std.mem.trim(u8, sha_out, " \t\r\n");
    const n = @min(trimmed.len, res.short_sha.len);
    std.mem.copyForwards(u8, res.short_sha[0..n], trimmed[0..n]);
    res.short_sha_len = @intCast(n);
    return res;
}

/// Roll back: reset the index for `paths` AND restore the working tree so
/// the on-disk state matches HEAD for those paths. Used on commit failure
/// to leave the tree clean per acceptance criteria.
///
/// For each path:
///   * `git reset HEAD -- <path>` unstages anything we just `git add`ed.
///   * If HEAD has the path, `git checkout HEAD -- <path>` restores the
///     pre-mutation bytes. If HEAD doesn't (the mutator created a new
///     file), we delete the on-disk file/tree so a retry can re-create.
pub fn rollbackPaths(
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    paths: []const []const u8,
) Error!void {
    if (paths.len == 0) return;
    var reset_argv = std.ArrayList([]const u8){};
    defer reset_argv.deinit(allocator);
    try reset_argv.appendSlice(allocator, &.{ "reset", "HEAD", "--" });
    for (paths) |p| try reset_argv.append(allocator, p);
    if (runGit(allocator, repo_root, reset_argv.items, false)) |out| {
        allocator.free(out);
    } else |_| {}

    for (paths) |p| {
        const checkout_argv = [_][]const u8{ "checkout", "HEAD", "--", p };
        if (runGit(allocator, repo_root, &checkout_argv, true)) |out| {
            allocator.free(out);
        } else |_| {
            const abs = std.fs.path.join(allocator, &.{ repo_root, p }) catch continue;
            defer allocator.free(abs);
            std.fs.cwd().deleteTree(abs) catch {};
            removeEmptyParentsUpTo(allocator, repo_root, p);
        }
    }
}

/// Walk up `rel_path` from its dirname toward (but not including) `repo_root`,
/// removing each directory if it is empty. Stops at the first non-empty dir.
fn removeEmptyParentsUpTo(allocator: std.mem.Allocator, repo_root: []const u8, rel_path: []const u8) void {
    var current = std.fs.path.dirname(rel_path) orelse return;
    while (current.len > 0) {
        const abs = std.fs.path.join(allocator, &.{ repo_root, current }) catch return;
        defer allocator.free(abs);
        std.fs.deleteDirAbsolute(abs) catch return;
        current = std.fs.path.dirname(current) orelse return;
    }
}

fn hasStagedChanges(allocator: std.mem.Allocator, repo_root: []const u8) Error!bool {
    // `git diff --cached --quiet` returns 1 when staged changes exist, 0
    // otherwise. We rely on the run helper returning whether the exit code
    // was non-zero.
    const result = runGitFull(allocator, repo_root, &.{ "diff", "--cached", "--quiet" }, true, true) catch |e| return e;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    return result.exit_code != 0;
}

const RunFull = struct {
    exit_code: u8,
    stdout: []u8,
    stderr: []u8,
};

/// Spawn `git <args>` in `repo_root`. Captures stdout & stderr. When
/// `error_on_nonzero` is true and exit code != 0, returns `error.GitFailed`
/// after freeing the buffers (so callers don't need to leak-clean on failure).
fn runGit(
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    args: []const []const u8,
    error_on_nonzero: bool,
) Error![]u8 {
    var argv = std.ArrayList([]const u8){};
    defer argv.deinit(allocator);
    try argv.append(allocator, "git");
    for (args) |a| try argv.append(allocator, a);

    var child = std.process.Child.init(argv.items, allocator);
    child.cwd = repo_root;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    // Disable interactive prompts.
    child.env_map = null;

    child.spawn() catch |e| switch (e) {
        error.FileNotFound => return error.GitNotFound,
        else => return error.GitFailed,
    };

    var stdout_buf = std.ArrayList(u8){};
    defer stdout_buf.deinit(allocator);
    var stderr_buf = std.ArrayList(u8){};
    defer stderr_buf.deinit(allocator);
    child.collectOutput(allocator, &stdout_buf, &stderr_buf, 8 * 1024 * 1024) catch return error.GitFailed;

    const term = child.wait() catch return error.GitFailed;
    const exit_code: u8 = switch (term) {
        .Exited => |c| c,
        else => 1,
    };
    if (error_on_nonzero and exit_code != 0) {
        return error.GitFailed;
    }
    return stdout_buf.toOwnedSlice(allocator);
}

fn runGitFull(
    allocator: std.mem.Allocator,
    repo_root: []const u8,
    args: []const []const u8,
    capture_stdout: bool,
    capture_stderr: bool,
) Error!RunFull {
    _ = capture_stdout;
    _ = capture_stderr;
    var argv = std.ArrayList([]const u8){};
    defer argv.deinit(allocator);
    try argv.append(allocator, "git");
    for (args) |a| try argv.append(allocator, a);

    var child = std.process.Child.init(argv.items, allocator);
    child.cwd = repo_root;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.env_map = null;

    child.spawn() catch |e| switch (e) {
        error.FileNotFound => return error.GitNotFound,
        else => return error.GitFailed,
    };

    var stdout_buf = std.ArrayList(u8){};
    errdefer stdout_buf.deinit(allocator);
    var stderr_buf = std.ArrayList(u8){};
    errdefer stderr_buf.deinit(allocator);
    child.collectOutput(allocator, &stdout_buf, &stderr_buf, 8 * 1024 * 1024) catch return error.GitFailed;

    const term = child.wait() catch return error.GitFailed;
    const exit_code: u8 = switch (term) {
        .Exited => |c| c,
        else => 1,
    };
    return .{
        .exit_code = exit_code,
        .stdout = try stdout_buf.toOwnedSlice(allocator),
        .stderr = try stderr_buf.toOwnedSlice(allocator),
    };
}

/// Best-effort: initialise a real repo at `root` with `git init` so the
/// daemon can commit into it. Used by tests; the production `stako init`
/// produces the same layout via its bespoke writer.
pub fn ensureRealRepo(allocator: std.mem.Allocator, repo_root: []const u8) Error!void {
    var dir = std.fs.openDirAbsolute(repo_root, .{}) catch return error.NotARepo;
    defer dir.close();
    // If a `.git` directory exists and contains `HEAD`, assume it's a real repo.
    var git_dir = dir.openDir(".git", .{}) catch {
        // No .git: run `git init`.
        const out = try runGit(allocator, repo_root, &.{ "init", "--quiet", "--initial-branch=main" }, true);
        allocator.free(out);
        return;
    };
    git_dir.close();
    // Verify `git status` works; if not, re-init.
    _ = runGit(allocator, repo_root, &.{ "status", "--porcelain" }, true) catch {
        const out = try runGit(allocator, repo_root, &.{ "init", "--quiet", "--initial-branch=main" }, true);
        allocator.free(out);
    };
}

// ---------- tests ----------

test "assertRepo: detects non-repo" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = try tmp.dir.realpath(".", &buf);
    try std.testing.expectError(error.NotARepo, assertRepo(a, abs));
}

test "ensureRealRepo + commit: round-trip works" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = try tmp.dir.realpath(".", &buf);

    try ensureRealRepo(a, abs);
    try assertRepo(a, abs);
    try assertNoMergeConflicts(a, abs);

    // Drop a file and commit.
    {
        var f = try tmp.dir.createFile("hello.txt", .{ .truncate = true });
        defer f.close();
        try f.writeAll("hi\n");
    }
    const res = try commit(a, abs, .{
        .paths = &.{"hello.txt"},
        .subject = "test: add hello",
        .body = "stack: test\nidentity: local\n",
    });
    try std.testing.expect(res.committed);
    try std.testing.expect(res.short_sha_len > 0);

    // Second commit with no changes is a no-op.
    const res2 = try commit(a, abs, .{
        .paths = &.{"hello.txt"},
        .subject = "test: no-op",
    });
    try std.testing.expectEqual(false, res2.committed);
}

test "rollbackPaths: restores tracked file edits and removes new files" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = try tmp.dir.realpath(".", &buf);

    try ensureRealRepo(a, abs);
    {
        var f = try tmp.dir.createFile("tracked.txt", .{ .truncate = true });
        defer f.close();
        try f.writeAll("original\n");
    }
    _ = try commit(a, abs, .{ .paths = &.{"tracked.txt"}, .subject = "init" });

    // Mutator-equivalent: edit a tracked file AND create a new file under a
    // brand-new subdirectory. Stage both, then roll back.
    {
        var f = try tmp.dir.createFile("tracked.txt", .{ .truncate = true });
        defer f.close();
        try f.writeAll("mutated\n");
    }
    try tmp.dir.makePath("stacks/new");
    {
        var f = try tmp.dir.createFile("stacks/new/stack.toml", .{ .truncate = true });
        defer f.close();
        try f.writeAll("description = \"x\"\n");
    }
    const stage_out = try runGit(a, abs, &.{ "add", "--", "tracked.txt", "stacks/new/stack.toml" }, true);
    a.free(stage_out);

    try rollbackPaths(a, abs, &.{ "tracked.txt", "stacks/new/stack.toml" });

    // Tracked file restored to HEAD content.
    {
        var f = try tmp.dir.openFile("tracked.txt", .{});
        defer f.close();
        var rb: [64]u8 = undefined;
        const n = try f.readAll(&rb);
        try std.testing.expectEqualStrings("original\n", rb[0..n]);
    }
    // New file removed and its empty parent directory cleaned up.
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("stacks/new/stack.toml", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access("stacks/new", .{}));
    // Index is clean.
    const status_out = try runGit(a, abs, &.{ "status", "--porcelain" }, true);
    defer a.free(status_out);
    try std.testing.expectEqual(@as(usize, 0), status_out.len);
}

test "assertPathsClean: detects modified file" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = try tmp.dir.realpath(".", &buf);

    try ensureRealRepo(a, abs);
    {
        var f = try tmp.dir.createFile("a.txt", .{ .truncate = true });
        defer f.close();
        try f.writeAll("orig\n");
    }
    _ = try commit(a, abs, .{
        .paths = &.{"a.txt"},
        .subject = "test: add a",
    });

    // Modify the file but don't commit.
    {
        var f = try tmp.dir.createFile("a.txt", .{ .truncate = true });
        defer f.close();
        try f.writeAll("modified\n");
    }
    try std.testing.expectError(error.HasDirtyTarget, assertPathsClean(a, abs, &.{"a.txt"}));
    // Unrelated path is fine.
    try assertPathsClean(a, abs, &.{"unrelated.txt"});
}
