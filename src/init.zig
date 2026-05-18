//! `stako init` — bootstrap a notes-root layout.
//!
//! Layout (created under `<root>/`):
//!   - `stacks/default/stack.toml`
//!   - `prompts/`
//!   - `routines/`
//!   - `AGENTS.md`              (concise guide for agents editing this root)
//!   - `config.toml`            (gitignored)
//!   - `state/local_token`      (gitignored, perms 0600)
//!   - `.gitignore`             (entries appended; existing lines preserved)
//!
//! Idempotency:
//!   - The directory layout is created if missing; existing dirs are left
//!     alone.
//!   - `config.toml` and `stacks/default/stack.toml` are NEVER overwritten
//!     if present.
//!   - `state/local_token` is generated once and never rewritten.
//!   - `.gitignore` lines are appended only if absent.
//!
//! Re-running on an initialized root reports zero changes.

const std = @import("std");
const stack_config = @import("stack_config.zig");

pub const Options = struct {
    /// Absolute or cwd-relative path to the notes root. Caller resolves
    /// "cwd default vs --root flag" before calling.
    root: []const u8,
    /// When true: skip prompts; auto `git init` non-git roots; proceed inside
    /// existing git repos without asking. When false: skip git init (the
    /// layout itself is still created). CLI exposes this as `--yes`/`-y`;
    /// tests always pass true.
    yes: bool = true,
    /// When true: emit only PASS/FAIL summary rather than per-line creates.
    /// Tests pass true to keep test output uncluttered.
    quiet: bool = false,
    /// Override `created_at` for `stack.toml`. Lets tests produce byte-stable
    /// snapshots. Production callers pass `null` to use the current UTC time.
    now_override: ?[]const u8 = null,
    /// Optional: override the random source used for `local_token`. Tests
    /// pass a deterministic seed; production uses the OS RNG.
    rng_seed_override: ?u64 = null,
};

pub const Report = struct {
    /// True if the root was a brand-new git repo we just initialized.
    git_initialized: bool = false,
    /// True if the root was already inside an existing git repo (stako
    /// layout will join that history, with a warning).
    inside_existing_git: bool = false,
    /// Items created on this run (paths relative to the notes root).
    created: std.ArrayList([]const u8) = .empty,
    /// Items that were already present and left untouched.
    already_present: std.ArrayList([]const u8) = .empty,
    /// Backing allocator; freed by deinit().
    allocator: std.mem.Allocator,
    /// Arena holding owned strings for `created`/`already_present`.
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Report) void {
        self.created.deinit(self.allocator);
        self.already_present.deinit(self.allocator);
        self.arena.deinit();
    }

    pub fn changeCount(self: *const Report) usize {
        var n: usize = self.created.items.len;
        if (self.git_initialized) n += 1;
        return n;
    }
};

/// Error union covering filesystem and allocator failures. We keep this as
/// `anyerror` in practice via `try`/`!` inference; the named alias is here
/// for documentation purposes only.
pub const InitError = error{
    RootNotADirectory,
    PathTypeMismatch,
};

/// The gitignore lines added by init.
pub const GITIGNORE_LINES = [_][]const u8{
    "config.toml",
    "state/",
};

/// Resolve `root` and run `stako init`. Caller owns the returned report.
pub fn run(allocator: std.mem.Allocator, opts: Options) !Report {
    std.fs.cwd().makePath(opts.root) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };

    // Open the notes root (must already exist as a directory).
    var root_dir = std.fs.cwd().openDir(opts.root, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound, error.NotDir => return error.RootNotADirectory,
        else => return e,
    };
    defer root_dir.close();

    var report: Report = .{
        .allocator = allocator,
        .arena = std.heap.ArenaAllocator.init(allocator),
    };
    errdefer report.deinit();
    const r_arena = report.arena.allocator();

    // 1. Git status: existing repo, parent-repo, or no repo at all.
    const git_state = try detectGit(&root_dir, opts.root, allocator);
    if (git_state == .repo_here) {
        // Already a git repo in this dir; nothing to do for git.
    } else if (git_state == .parent_repo) {
        // Design decision (resolved-was-to-decide section): proceed and let
        // the CLI layer surface a warning to the user.
        report.inside_existing_git = true;
    } else if (opts.yes) {
        try gitInitHere(&root_dir);
        report.git_initialized = true;
    } else {
        // Without --yes we still go ahead and create the layout, but the CLI
        // layer is expected to have prompted; for now treat unattended-no-flag
        // as "skip git init". The init step itself doesn't depend on git.
    }

    // 2. Directory layout.
    try ensureDir(&root_dir, "stacks", &report, r_arena);
    try ensureDir(&root_dir, "stacks/default", &report, r_arena);
    try ensureDir(&root_dir, "prompts", &report, r_arena);
    try ensureDir(&root_dir, "prompts/admin-review", &report, r_arena);
    try ensureDir(&root_dir, "routines", &report, r_arena);
    try ensureDir(&root_dir, "state", &report, r_arena);

    // 3. stacks/default/stack.toml — write defaults if absent.
    {
        const now = opts.now_override orelse blk: {
            const ts = std.time.timestamp();
            const buf = try formatIsoUtc(r_arena, ts);
            break :blk buf;
        };
        try writeFileIfAbsent(
            &root_dir,
            "stacks/default/stack.toml",
            &report,
            r_arena,
            .{ .stack_defaults = .{ .created_at = now } },
            null,
        );
    }

    // 4. Built-in admin routine and prompt assets.
    try writeFileIfAbsent(
        &root_dir,
        "routines/admin-review.toml",
        &report,
        r_arena,
        .{ .admin_routine = {} },
        null,
    );
    try writeFileIfAbsent(
        &root_dir,
        "prompts/admin-review/evaluate.md",
        &report,
        r_arena,
        .{ .admin_prompt = {} },
        null,
    );

    // 5. AGENTS.md — concise primer agents discover at the root.
    try writeFileIfAbsent(
        &root_dir,
        "AGENTS.md",
        &report,
        r_arena,
        .{ .agents_md = {} },
        null,
    );

    // 6. config.toml — single per-root config file, gitignored.
    try writeFileIfAbsent(
        &root_dir,
        "config.toml",
        &report,
        r_arena,
        .{ .config = {} },
        null,
    );

    // 7. state/local_token — generated once, perms 0600, gitignored.
    // Token bytes are produced lazily inside writeFileIfAbsent so we don't
    // burn kernel entropy on idempotent re-init runs.
    try writeFileIfAbsent(
        &root_dir,
        "state/local_token",
        &report,
        r_arena,
        .{ .local_token = opts.rng_seed_override },
        0o600,
    );

    // 8. .gitignore — append missing lines.
    try appendGitignoreLines(&root_dir, &report, r_arena);

    return report;
}

// ---------- helpers ----------

const GitState = enum { repo_here, parent_repo, none };

fn detectGit(root_dir: *std.fs.Dir, root_path: []const u8, allocator: std.mem.Allocator) !GitState {
    // .git in the notes root itself.
    if (statExists(root_dir, ".git")) return .repo_here;

    // Look at ancestors: real-path the root, then walk up checking for .git.
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const real = std.fs.cwd().realpath(root_path, &path_buf) catch return .none;

    // Walk up using dirname. We allocate a mutable copy to manipulate.
    var cur = try allocator.dupe(u8, real);
    defer allocator.free(cur);

    while (true) {
        const parent = std.fs.path.dirname(cur) orelse break;
        if (parent.len == 0) break;
        if (std.mem.eql(u8, parent, cur)) break;

        var d = std.fs.openDirAbsolute(parent, .{}) catch break;
        defer d.close();
        d.access(".git", .{}) catch {
            // Not here, climb.
            const new_cur = try allocator.dupe(u8, parent);
            allocator.free(cur);
            cur = new_cur;
            continue;
        };
        return .parent_repo;
    }
    return .none;
}

fn gitInitHere(root_dir: *std.fs.Dir) !void {
    // Minimal git init: just create .git/ with the bare minimum so the
    // directory is recognized as a repo. We DON'T shell out to `git`
    // because milestone 2 doesn't take a process-spawn dependency. A real
    // commit is not required by the milestone-2 acceptance criteria — the
    // gitignore/layout is.
    //
    // Layout matches what `git init` produces, trimmed to what makes the
    // directory a valid repo for `git status` purposes.
    try root_dir.makePath(".git/objects/info");
    try root_dir.makePath(".git/objects/pack");
    try root_dir.makePath(".git/refs/heads");
    try root_dir.makePath(".git/refs/tags");

    try writeAtomic(root_dir, ".git/HEAD", "ref: refs/heads/main\n");
    try writeAtomic(root_dir, ".git/config", "[core]\n" ++
        "\trepositoryformatversion = 0\n" ++
        "\tfilemode = true\n" ++
        "\tbare = false\n" ++
        "\tlogallrefupdates = true\n");
    try writeAtomic(root_dir, ".git/description", "Unnamed repository; edit this file 'description' to name the repository.\n");
}

fn statExists(dir: *std.fs.Dir, sub: []const u8) bool {
    dir.access(sub, .{}) catch return false;
    return true;
}

fn ensureDir(
    root_dir: *std.fs.Dir,
    rel: []const u8,
    report: *Report,
    arena: std.mem.Allocator,
) !void {
    var existing = root_dir.openDir(rel, .{}) catch |e| switch (e) {
        error.FileNotFound => {
            try root_dir.makePath(rel);
            try report.created.append(report.allocator, try arena.dupe(u8, rel));
            return;
        },
        error.NotDir => return error.PathTypeMismatch,
        else => return e,
    };
    existing.close();
    try report.already_present.append(report.allocator, try arena.dupe(u8, rel));
}

fn fileExistsStrict(root_dir: *std.fs.Dir, rel: []const u8) !bool {
    var f = root_dir.openFile(rel, .{}) catch |e| switch (e) {
        error.FileNotFound => return false,
        error.IsDir, error.NotDir => return error.PathTypeMismatch,
        else => return e,
    };
    defer f.close();
    const stat = try f.stat();
    if (stat.kind != .file) return error.PathTypeMismatch;
    return true;
}

fn appendCreated(report: *Report, arena: std.mem.Allocator, rel: []const u8) !void {
    try report.created.append(report.allocator, try arena.dupe(u8, rel));
}

fn appendAlreadyPresent(report: *Report, arena: std.mem.Allocator, rel: []const u8) !void {
    try report.already_present.append(report.allocator, try arena.dupe(u8, rel));
}

fn ensureWritableFileAbsent(root_dir: *std.fs.Dir, rel: []const u8) !bool {
    if (try fileExistsStrict(root_dir, rel)) return false;
    if (std.fs.path.dirname(rel)) |parent| {
        var parent_dir = root_dir.openDir(parent, .{}) catch |e| switch (e) {
            error.FileNotFound, error.NotDir => return error.PathTypeMismatch,
            else => return e,
        };
        parent_dir.close();
    }
    return true;
}

/// On POSIX, chmod a path under `root_dir` to `mode`. No-op on non-POSIX.
/// Works on both files and directories via `fchmodat`.
fn chmodIfPosix(root_dir: *std.fs.Dir, rel: []const u8, mode: u32) !void {
    if (@import("builtin").os.tag == .windows) return;
    try std.posix.fchmodat(root_dir.fd, rel, @intCast(mode), 0);
}

const FileSpec = union(enum) {
    stack_defaults: struct { created_at: []const u8 },
    admin_routine,
    admin_prompt,
    agents_md,
    config,
    /// Generated lazily inside `writeFileIfAbsent` to avoid wasted entropy
    /// when the file already exists.
    local_token: ?u64,
    raw: []const u8,
};

fn writeFileIfAbsent(
    root_dir: *std.fs.Dir,
    rel: []const u8,
    report: *Report,
    arena: std.mem.Allocator,
    spec: FileSpec,
    posix_mode: ?u32,
) !void {
    if (!try ensureWritableFileAbsent(root_dir, rel)) {
        try appendAlreadyPresent(report, arena, rel);
        return;
    }

    // Build content in a buffer first so we can write atomically.
    var buf = std.ArrayList(u8){};
    defer buf.deinit(arena);
    const w = buf.writer(arena);
    switch (spec) {
        .stack_defaults => |sd| try stack_config.writeDefaults(w, sd.created_at),
        .admin_routine => try writeAdminRoutine(w),
        .admin_prompt => try writeAdminPrompt(w),
        .agents_md => try writeAgentsMd(w),
        .config => try writeConfig(w),
        .local_token => |seed| {
            const token = try generateLocalToken(arena, seed);
            try w.writeAll(token);
        },
        .raw => |s| try w.writeAll(s),
    }

    try writeAtomic(root_dir, rel, buf.items);
    if (@import("builtin").os.tag != .windows) {
        if (posix_mode) |m| {
            try std.posix.fchmodat(root_dir.fd, rel, @intCast(m), 0);
        }
    }

    try appendCreated(report, arena, rel);
}

fn writeAtomic(root_dir: *std.fs.Dir, rel: []const u8, content: []const u8) !void {
    // Ensure parent dirs exist.
    if (std.fs.path.dirname(rel)) |parent| {
        if (parent.len > 0) try root_dir.makePath(parent);
    }
    // Write-to-temp + rename gives a half-or-nothing guarantee against crash
    // or SIGKILL mid-write: a torn `local_token` would permanently break auth,
    // and a torn `config.toml` would break daemon startup. The temp name is
    // co-located with the target so `rename` stays within one filesystem.
    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_rel = blk: {
        var rng_bytes: [4]u8 = undefined;
        std.crypto.random.bytes(&rng_bytes);
        break :blk try std.fmt.bufPrint(
            &tmp_buf,
            "{s}.stako-tmp-{x}{x}{x}{x}",
            .{ rel, rng_bytes[0], rng_bytes[1], rng_bytes[2], rng_bytes[3] },
        );
    };
    {
        var f = try root_dir.createFile(tmp_rel, .{ .truncate = true, .exclusive = true });
        defer f.close();
        try f.writeAll(content);
        f.sync() catch {};
    }
    root_dir.rename(tmp_rel, rel) catch |e| {
        root_dir.deleteFile(tmp_rel) catch {};
        return e;
    };
}

fn writeAdminRoutine(w: anytype) !void {
    try w.writeAll(
        \\version = 1
        \\description = "Review recent stack results and decide what to do next."
        \\thread = "admin"
        \\
        \\[[step]]
        \\prompts = ["../prompts/admin-review/evaluate.md"]
        \\
    );
}

fn writeAdminPrompt(w: anytype) !void {
    try w.writeAll(
        \\Review the registered item and commit inputs from recent stack work.
        \\
        \\Write any useful decision, summary, or follow-up notes as ordinary files in the workdir or notes tree. Use one of these decision labels when you write a decision:
        \\
        \\- proceed
        \\- needs follow-up
        \\- done
        \\
        \\Include the evidence that led to the decision and any recommended follow-up prompts. Do not modify stack metadata directly.
        \\
    );
}

fn writeAgentsMd(w: anytype) !void {
    try w.writeAll(
        \\# Agents guide
        \\
        \\This is a stako notes root. Stako queues prompt work onto stacks and
        \\runs it through coding-agent harnesses.
        \\
        \\## Layout
        \\
        \\- `prompts/<name>.md` — reusable prompt text.
        \\- `routines/<name>.toml` — ordered steps that combine prompts.
        \\- `stacks/<stack>/` — work queues.
        \\
        \\## Writing prompts
        \\
        \\Plain markdown. Tell the agent what to read, what to do, and what
        \\to write back. Keep prose in prompt files, not in routine TOML.
        \\Multi-file prompts are conventional: split a long prompt into
        \\`prompts/<routine>/intro.md`, `body.md`, etc.
        \\
        \\## Writing routines
        \\
        \\A routine is `routines/<name>.toml` with one or more `[[step]]`
        \\blocks. Prompt paths are relative to the routine file.
        \\
        \\```toml
        \\thread = "admin"
        \\
        \\[[step]]
        \\prompts = ["../prompts/planning/intro.md", "../prompts/planning/body.md"]
        \\
        \\[[step]]
        \\command = "compact"
        \\
        \\[[step]]
        \\thread = "builder"
        \\prompts = ["../prompts/planning/build.md"]
        \\```
        \\
        \\- `prompts = [...]` concatenates those files into one prompt item.
        \\- Set root `thread = "..."` for the default; override per-step when needed.
        \\- Use `command = "compact"` for compact steps.
        \\
        \\## Running stako
        \\
        \\```sh
        \\stako daemon start                 # serve the loopback API
        \\stako new <stack>                  # create a stack
        \\stako add <routine> <stack>        # append a routine to it
        \\stako start <stack>                # resume execution
        \\stako stack show <stack>           # inspect items + status
        \\stako routine list                 # list available routines
        \\```
        \\
        \\Do not edit stack item metadata by hand — go through `stako add` /
        \\`stako start` so the daemon stays consistent.
        \\
    );
}

fn writeConfig(w: anytype) !void {
    try w.writeAll(
        \\# config.toml — per-root stako config. Gitignored.
        \\
        \\[daemon]
        \\loopback_only = true
        \\default_stack = "default"
        \\port = 7421
        \\
        \\[workdir]
        \\# Items requesting a workdir outside this list are blocked at routing.
        \\# Add absolute paths; tilde-expansion is performed at load time.
        \\allowlist = []
        \\
        \\# Identities. Capabilities are scope strings like
        \\# "stack.<name>.read" or "*".
        \\[identity.local]
        \\type = "user"
        \\description = "the local user (CLI, web view) on this machine"
        \\capabilities = ["*"]
        \\
        \\[identity.claude-local]
        \\type = "mcp"
        \\description = "local Claude Code"
        \\capabilities = ["stack.default.read", "stack.default.append", "stack.default.insert"]
        \\
        \\[identity.codex-local]
        \\type = "mcp"
        \\description = "local Codex"
        \\capabilities = ["stack.default.read"]
        \\
        \\[provider.anthropic]
        \\auth_kind = "subscription"
        \\
        \\[provider.openai]
        \\auth_kind = "subscription"
        \\
    );
}

fn appendGitignoreLines(
    root_dir: *std.fs.Dir,
    report: *Report,
    arena: std.mem.Allocator,
) !void {
    const path = ".gitignore";
    // Read the existing file (if any). Lifetime: arena-backed, freed with the
    // report's arena — no per-slice free since `existing` is a subslice of
    // the alloc and freeing it directly would mismatch the alloc size.
    var existing: []const u8 = "";

    if (statExists(root_dir, path)) {
        var f = try root_dir.openFile(path, .{});
        defer f.close();
        const stat = try f.stat();
        const buf = try arena.alloc(u8, stat.size);
        const n = try f.readAll(buf);
        existing = buf[0..n];
    }

    // Determine which lines are missing.
    var missing = std.ArrayList([]const u8){};
    defer missing.deinit(arena);
    for (GITIGNORE_LINES) |line| {
        if (!gitignoreContainsLine(existing, line)) {
            try missing.append(arena, line);
        }
    }

    if (missing.items.len == 0) {
        try report.already_present.append(report.allocator, try arena.dupe(u8, path));
        return;
    }

    // Compose new contents = existing + (optional newline) + new lines.
    var out = std.ArrayList(u8){};
    defer out.deinit(arena);
    if (existing.len > 0) {
        try out.appendSlice(arena, existing);
        if (existing[existing.len - 1] != '\n') try out.append(arena, '\n');
        // Add a blank-line separator if the file isn't empty AND doesn't
        // already end in a blank line — so manual edits are visually distinct.
        if (!endsWithBlankLine(existing)) try out.append(arena, '\n');
        try out.appendSlice(arena, "# stako\n");
    } else {
        try out.appendSlice(arena, "# stako\n");
    }
    for (missing.items) |line| {
        try out.appendSlice(arena, line);
        try out.append(arena, '\n');
    }

    try writeAtomic(root_dir, path, out.items);

    // Report as "created" if we just made the file, else as "modified". We
    // don't have a separate bucket for "modified"; lump it into `created`
    // because the change-count must be > 0.
    try report.created.append(report.allocator, try arena.dupe(u8, path));
}

fn gitignoreContainsLine(haystack: []const u8, needle: []const u8) bool {
    var it = std.mem.splitScalar(u8, haystack, '\n');
    while (it.next()) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \t\r");
        if (trimmed.len == 0) continue;
        if (trimmed[0] == '#') continue;
        if (std.mem.eql(u8, trimmed, needle)) return true;
    }
    return false;
}

fn endsWithBlankLine(s: []const u8) bool {
    if (s.len < 2) return false;
    return s[s.len - 1] == '\n' and s[s.len - 2] == '\n';
}

fn generateLocalToken(arena: std.mem.Allocator, seed_override: ?u64) ![]const u8 {
    var raw: [32]u8 = undefined;
    if (seed_override) |seed| {
        var prng = std.Random.DefaultPrng.init(seed);
        prng.random().bytes(&raw);
    } else {
        std.crypto.random.bytes(&raw);
    }
    // Hex-encode (64 chars) + trailing newline for readability.
    var out = try arena.alloc(u8, raw.len * 2 + 1);
    const hex = "0123456789abcdef";
    for (raw, 0..) |b, i| {
        out[i * 2 + 0] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0x0f];
    }
    out[raw.len * 2] = '\n';
    return out;
}

fn formatIsoUtc(arena: std.mem.Allocator, ts: i64) ![]const u8 {
    // Convert UNIX timestamp to YYYY-MM-DDTHH:MM:SSZ. Algorithm: Howard
    // Hinnant's civil_from_days, condensed.
    const days = @divFloor(ts, 86400);
    const time_of_day = @mod(ts, 86400);
    const hh: u32 = @intCast(@divFloor(time_of_day, 3600));
    const mm: u32 = @intCast(@divFloor(@mod(time_of_day, 3600), 60));
    const ss: u32 = @intCast(@mod(time_of_day, 60));

    // days since 1970-01-01 -> civil date.
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe: i64 = z - era * 146097; // [0, 146096]
    const yoe: i64 = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const y0: i64 = yoe + era * 400;
    const doy: i64 = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp: i64 = @divFloor(5 * doy + 2, 153);
    const d: u32 = @intCast(doy - @divFloor(153 * mp + 2, 5) + 1);
    const m: u32 = @intCast(if (mp < 10) mp + 3 else mp - 9);
    const y: i64 = y0 + @as(i64, @intFromBool(m <= 2));

    // The Zig integer formatter prints a leading '+' for signed integers; we
    // only ever feed it dates after 1970, so cast year to u32 to avoid that.
    const yu: u32 = @intCast(y);
    var scratch: [64]u8 = undefined;
    const written = try std.fmt.bufPrint(&scratch, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{ yu, m, d, hh, mm, ss });
    return try arena.dupe(u8, written);
}

// ---------- internal unit tests ----------

test "gitignoreContainsLine matches exact lines" {
    const existing = "node_modules/\nstate/\n# comment\n";
    try std.testing.expect(gitignoreContainsLine(existing, "state/"));
    try std.testing.expect(gitignoreContainsLine(existing, "node_modules/"));
    try std.testing.expect(!gitignoreContainsLine(existing, "config.toml"));
    try std.testing.expect(!gitignoreContainsLine(existing, "# comment"));
}

test "formatIsoUtc: known epoch" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const s = try formatIsoUtc(ar.allocator(), 0);
    try std.testing.expectEqualStrings("1970-01-01T00:00:00Z", s);
    const s2 = try formatIsoUtc(ar.allocator(), 1747008000); // 2025-05-12T00:00:00Z
    try std.testing.expectEqualStrings("2025-05-12T00:00:00Z", s2);
}

test "generateLocalToken: deterministic from seed, hex+newline shape" {
    var ar = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ar.deinit();
    const t1 = try generateLocalToken(ar.allocator(), 0xCAFEBABE);
    const t2 = try generateLocalToken(ar.allocator(), 0xCAFEBABE);
    try std.testing.expectEqualStrings(t1, t2);
    try std.testing.expectEqual(@as(usize, 65), t1.len); // 64 hex + 1 newline
    try std.testing.expectEqual(@as(u8, '\n'), t1[64]);
    for (t1[0..64]) |c| {
        const ok = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f');
        try std.testing.expect(ok);
    }
}
