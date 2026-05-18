//! Integration tests for `stako init`.
//!
//! Wired into `zig build test` via build.zig. Each test runs against a fresh
//! temp directory under the OS temp dir; nothing on disk under the repo is
//! mutated. Fixture snapshots live in `test/fixtures/notes_roots/empty_initialized/`
//! and are byte-stable (deterministic timestamp + RNG seed).

const std = @import("std");
const stako = @import("stako");
const init_mod = stako.init;
const stack_config = stako.stack_config;
const item_mod = stako.item;

/// A scratch directory under the system temp dir, removed on `deinit`.
const Scratch = struct {
    allocator: std.mem.Allocator,
    abs_path: []u8,

    fn create(allocator: std.mem.Allocator, name_hint: []const u8) !Scratch {
        const tmp = std.posix.getenv("TMPDIR") orelse "/tmp";
        var ts_buf: [32]u8 = undefined;
        const ts = std.time.nanoTimestamp();
        const ts_str = try std.fmt.bufPrint(&ts_buf, "{d}", .{ts});
        const path = try std.fs.path.join(allocator, &.{ tmp, "stako-test" });
        defer allocator.free(path);
        try std.fs.cwd().makePath(path);

        const dir_name = try std.fmt.allocPrint(allocator, "{s}-{s}", .{ name_hint, ts_str });
        defer allocator.free(dir_name);
        const full = try std.fs.path.join(allocator, &.{ path, dir_name });
        try std.fs.cwd().makePath(full);
        return .{ .allocator = allocator, .abs_path = full };
    }

    fn deinit(self: *Scratch) void {
        // best-effort cleanup
        std.fs.cwd().deleteTree(self.abs_path) catch {};
        self.allocator.free(self.abs_path);
    }

    fn dir(self: *Scratch) !std.fs.Dir {
        return std.fs.openDirAbsolute(self.abs_path, .{ .iterate = true });
    }
};

fn fileExists(d: *std.fs.Dir, rel: []const u8) bool {
    d.access(rel, .{}) catch return false;
    return true;
}

fn readAll(allocator: std.mem.Allocator, d: *std.fs.Dir, rel: []const u8) ![]u8 {
    var f = try d.openFile(rel, .{});
    defer f.close();
    const stat = try f.stat();
    const buf = try allocator.alloc(u8, stat.size);
    const n = try f.readAll(buf);
    return buf[0..n];
}

fn fileMode(d: *std.fs.Dir, rel: []const u8) !u32 {
    if (@import("builtin").os.tag == .windows) return 0o644;
    var f = try d.openFile(rel, .{});
    defer f.close();
    const stat = try f.stat();
    return @intCast(stat.mode & 0o777);
}

fn dirMode(d: *std.fs.Dir, rel: []const u8) !u32 {
    if (@import("builtin").os.tag == .windows) return 0o755;
    var sub = try d.openDir(rel, .{});
    defer sub.close();
    const stat = try sub.stat();
    return @intCast(stat.mode & 0o777);
}

test "init: on a fresh empty dir creates the documented layout" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "fresh");
    defer s.deinit();

    var report = try init_mod.run(a, .{
        .root = s.abs_path,
        .yes = true,
        .quiet = true,
        .now_override = "2026-05-10T14:00:00Z",
        .rng_seed_override = 0xDEADBEEFCAFE,
    });
    defer report.deinit();

    var d = try s.dir();
    defer d.close();

    // Directories.
    try std.testing.expect(fileExists(&d, "stacks"));
    try std.testing.expect(fileExists(&d, "stacks/default"));
    try std.testing.expect(fileExists(&d, "prompts"));
    try std.testing.expect(fileExists(&d, "prompts/admin-review"));
    try std.testing.expect(fileExists(&d, "routines"));
    try std.testing.expect(fileExists(&d, "state"));

    // Files.
    try std.testing.expect(fileExists(&d, "stacks/default/stack.toml"));
    try std.testing.expect(fileExists(&d, "prompts/admin-review/evaluate.md"));
    try std.testing.expect(fileExists(&d, "routines/admin-review.toml"));
    try std.testing.expect(fileExists(&d, "AGENTS.md"));
    try std.testing.expect(fileExists(&d, "config.toml"));
    try std.testing.expect(fileExists(&d, "state/local_token"));
    try std.testing.expect(fileExists(&d, ".gitignore"));
    try std.testing.expect(fileExists(&d, ".git"));
}

test "init: creates the requested notes root when it does not exist" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "create-root-parent");
    defer s.deinit();

    const root = try std.fs.path.join(a, &.{ s.abs_path, "stako" });
    defer a.free(root);

    var report = try init_mod.run(a, .{
        .root = root,
        .yes = true,
        .quiet = true,
        .now_override = "2026-05-10T14:00:00Z",
        .rng_seed_override = 0x123456,
    });
    defer report.deinit();

    var d = try std.fs.openDirAbsolute(root, .{ .iterate = true });
    defer d.close();
    try std.testing.expect(fileExists(&d, "stacks/default/stack.toml"));
    try std.testing.expect(fileExists(&d, "config.toml"));
}

test "init: local_token has 0600 (POSIX)" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "perms");
    defer s.deinit();

    var report = try init_mod.run(a, .{
        .root = s.abs_path,
        .yes = true,
        .quiet = true,
        .now_override = "2026-05-10T14:00:00Z",
        .rng_seed_override = 0xBEEF,
    });
    defer report.deinit();

    var d = try s.dir();
    defer d.close();

    try std.testing.expectEqual(@as(u32, 0o600), try fileMode(&d, "state/local_token"));
}

test "init: rerunning is a no-op (zero created items, local_token preserved)" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "idem");
    defer s.deinit();

    var r1 = try init_mod.run(a, .{
        .root = s.abs_path,
        .yes = true,
        .quiet = true,
        .now_override = "2026-05-10T14:00:00Z",
        .rng_seed_override = 0xA11CE,
    });
    defer r1.deinit();
    try std.testing.expect(r1.created.items.len > 0);

    var d = try s.dir();
    defer d.close();
    const token_before = try readAll(a, &d, "state/local_token");
    defer a.free(token_before);

    var r2 = try init_mod.run(a, .{
        .root = s.abs_path,
        .yes = true,
        .quiet = true,
        .now_override = "2026-05-10T14:00:00Z",
        .rng_seed_override = 0xA11CE,
    });
    defer r2.deinit();
    try std.testing.expectEqual(@as(usize, 0), r2.created.items.len);
    try std.testing.expect(!r2.git_initialized);

    const token_after = try readAll(a, &d, "state/local_token");
    defer a.free(token_after);
    try std.testing.expectEqualSlices(u8, token_before, token_after);
}

test "init: rerunning with a different seed does NOT rotate local_token" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "no-rotate");
    defer s.deinit();

    var r1 = try init_mod.run(a, .{
        .root = s.abs_path,
        .yes = true,
        .quiet = true,
        .now_override = "2026-05-10T14:00:00Z",
        .rng_seed_override = 0x1111,
    });
    defer r1.deinit();

    var d = try s.dir();
    defer d.close();
    const token_before = try readAll(a, &d, "state/local_token");
    defer a.free(token_before);

    var r2 = try init_mod.run(a, .{
        .root = s.abs_path,
        .yes = true,
        .quiet = true,
        .now_override = "2026-05-10T14:00:00Z",
        .rng_seed_override = 0x9999, // different
    });
    defer r2.deinit();

    const token_after = try readAll(a, &d, "state/local_token");
    defer a.free(token_after);
    try std.testing.expectEqualSlices(u8, token_before, token_after);
}

test "init: directory path occupied by file is rejected" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "dir-collision");
    defer s.deinit();

    var d = try s.dir();
    defer d.close();
    var f = try d.createFile("state", .{ .truncate = true });
    f.close();

    try std.testing.expectError(error.PathTypeMismatch, init_mod.run(a, .{
        .root = s.abs_path,
        .yes = true,
        .quiet = true,
        .now_override = "2026-05-10T14:00:00Z",
        .rng_seed_override = 0x1234,
    }));
}

test "init: file path occupied by directory is rejected" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "file-collision");
    defer s.deinit();

    var d = try s.dir();
    defer d.close();
    try d.makePath("state/local_token");

    try std.testing.expectError(error.PathTypeMismatch, init_mod.run(a, .{
        .root = s.abs_path,
        .yes = true,
        .quiet = true,
        .now_override = "2026-05-10T14:00:00Z",
        .rng_seed_override = 0x1234,
    }));
}

test "init: config.toml is valid TOML and parseable by the milestone-1 reader" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "config-parse");
    defer s.deinit();

    var report = try init_mod.run(a, .{
        .root = s.abs_path,
        .yes = true,
        .quiet = true,
        .now_override = "2026-05-10T14:00:00Z",
        .rng_seed_override = 0xC0FFEE,
    });
    defer report.deinit();

    var d = try s.dir();
    defer d.close();

    // Sanity check: the milestone-1 toml reader can lex the file.
    const src = try readAll(a, &d, "config.toml");
    defer a.free(src);
    var doc = try stako.toml.parse(a, src);
    defer doc.deinit();
    try std.testing.expect(doc.entries.items.len > 0);
    // It should contain a `daemon.loopback_only = true` entry.
    var found_loopback = false;
    for (doc.entries.items) |e| {
        if (std.mem.eql(u8, e.table, "daemon") and std.mem.eql(u8, e.key, "loopback_only")) {
            try std.testing.expect(e.value.boolean);
            found_loopback = true;
        }
    }
    try std.testing.expect(found_loopback);
}

test "init: stack.toml round-trips through stack_config" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "stack-parse");
    defer s.deinit();

    var report = try init_mod.run(a, .{
        .root = s.abs_path,
        .yes = true,
        .quiet = true,
        .now_override = "2026-05-10T14:00:00Z",
        .rng_seed_override = 0xFEEDFACE,
    });
    defer report.deinit();

    var d = try s.dir();
    defer d.close();
    const src = try readAll(a, &d, "stacks/default/stack.toml");
    defer a.free(src);

    var cfg = try stack_config.parseSlice(a, src);
    defer cfg.deinit();
    try std.testing.expectEqualStrings("default stack", cfg.description.?);
    try std.testing.expectEqualStrings("2026-05-10T14:00:00Z", cfg.created_at.?);
    try std.testing.expectEqual(stack_config.Continuity.fresh, cfg.continuity);
    try std.testing.expectEqual(false, cfg.paused);
}

test "init: .gitignore contains all required stako lines" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "gitignore");
    defer s.deinit();

    var report = try init_mod.run(a, .{
        .root = s.abs_path,
        .yes = true,
        .quiet = true,
        .now_override = "2026-05-10T14:00:00Z",
        .rng_seed_override = 0x42,
    });
    defer report.deinit();

    var d = try s.dir();
    defer d.close();
    const gi = try readAll(a, &d, ".gitignore");
    defer a.free(gi);

    inline for (init_mod.GITIGNORE_LINES) |line| {
        if (std.mem.indexOf(u8, gi, line) == null) {
            std.debug.print("missing .gitignore line: {s}\n", .{line});
            return error.MissingGitignoreLine;
        }
    }
}

test "init: appends to a pre-existing .gitignore without duplicating" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "gitignore-append");
    defer s.deinit();

    // Pre-create a .gitignore with one of the stako lines + some user content.
    {
        var d_pre = try std.fs.openDirAbsolute(s.abs_path, .{});
        defer d_pre.close();
        var f = try d_pre.createFile(".gitignore", .{ .truncate = true });
        defer f.close();
        try f.writeAll("node_modules/\nstate/\n");
    }

    var report = try init_mod.run(a, .{
        .root = s.abs_path,
        .yes = true,
        .quiet = true,
        .now_override = "2026-05-10T14:00:00Z",
        .rng_seed_override = 0x7,
    });
    defer report.deinit();

    var d = try s.dir();
    defer d.close();
    const gi = try readAll(a, &d, ".gitignore");
    defer a.free(gi);

    // The user line should still be there.
    try std.testing.expect(std.mem.indexOf(u8, gi, "node_modules/") != null);
    // The pre-existing stako line should appear exactly once.
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, gi, '\n');
    while (it.next()) |line| {
        if (std.mem.eql(u8, std.mem.trim(u8, line, " \t\r"), "state/")) count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
    // Other required lines should now be present.
    try std.testing.expect(std.mem.indexOf(u8, gi, "config.toml") != null);
}

test "init: inside an existing parent git repo emits a warning but proceeds" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "parent-git");
    defer s.deinit();

    // Create a sub-directory whose parent has a .git.
    {
        var d = try std.fs.openDirAbsolute(s.abs_path, .{});
        defer d.close();
        try d.makePath(".git");
        try d.makePath("notes");
    }
    const notes = try std.fs.path.join(a, &.{ s.abs_path, "notes" });
    defer a.free(notes);

    var report = try init_mod.run(a, .{
        .root = notes,
        .yes = true,
        .quiet = true,
        .now_override = "2026-05-10T14:00:00Z",
        .rng_seed_override = 0x5,
    });
    defer report.deinit();

    try std.testing.expect(report.inside_existing_git);
    try std.testing.expect(!report.git_initialized);
    try std.testing.expect(report.created.items.len > 0);
}

test "init: yes=false skips auto git init on a non-git root" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "no-yes");
    defer s.deinit();

    var report = try init_mod.run(a, .{
        .root = s.abs_path,
        .yes = false,
        .quiet = true,
        .now_override = "2026-05-10T14:00:00Z",
        .rng_seed_override = 0x88,
    });
    defer report.deinit();
    try std.testing.expect(!report.git_initialized);

    var d = try s.dir();
    defer d.close();
    // .git was not created, but the rest of the layout was.
    try std.testing.expect(!fileExists(&d, ".git"));
    try std.testing.expect(fileExists(&d, "state/local_token"));
    try std.testing.expect(fileExists(&d, "stacks/default/stack.toml"));
}

test "init: existing stack.toml is never overwritten" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "stack-no-clobber");
    defer s.deinit();

    {
        var d = try std.fs.openDirAbsolute(s.abs_path, .{});
        defer d.close();
        try d.makePath("stacks/default");
        var f = try d.createFile("stacks/default/stack.toml", .{ .truncate = true });
        defer f.close();
        try f.writeAll("# hand-edited\ndescription = \"keep me\"\n");
    }

    var report = try init_mod.run(a, .{
        .root = s.abs_path,
        .yes = true,
        .quiet = true,
        .now_override = "2026-05-10T14:00:00Z",
        .rng_seed_override = 0x66,
    });
    defer report.deinit();

    var d = try s.dir();
    defer d.close();
    const src = try readAll(a, &d, "stacks/default/stack.toml");
    defer a.free(src);
    try std.testing.expect(std.mem.indexOf(u8, src, "# hand-edited") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "keep me") != null);
}

test "init: existing config.toml is never overwritten" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "no-clobber");
    defer s.deinit();

    // Pre-seed config.toml with custom content.
    {
        var d = try std.fs.openDirAbsolute(s.abs_path, .{});
        defer d.close();
        var f = try d.createFile("config.toml", .{ .truncate = true });
        defer f.close();
        try f.writeAll("# user-edited\n[daemon]\ndefault_stack = \"mine\"\n");
    }

    var report = try init_mod.run(a, .{
        .root = s.abs_path,
        .yes = true,
        .quiet = true,
        .now_override = "2026-05-10T14:00:00Z",
        .rng_seed_override = 0x6,
    });
    defer report.deinit();

    var d = try s.dir();
    defer d.close();
    const src = try readAll(a, &d, "config.toml");
    defer a.free(src);
    try std.testing.expect(std.mem.indexOf(u8, src, "# user-edited") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "default_stack = \"mine\"") != null);
}

// ---------- byte-stable fixture snapshot ----------
//
// The fixture under `test/fixtures/notes_roots/empty_initialized/` captures
// the output of `stako init` on an empty dir with a fixed timestamp and
// fixed RNG seed. Later milestones consume this fixture; if the output ever
// changes we want the diff to surface here so it's a deliberate update.

const FIXTURE_NOW = "2026-05-10T14:00:00Z";
const FIXTURE_SEED: u64 = 0x6F7267616E6F00; // ascii "stako\0"

/// Map of (actual file under the initialized root) → (committed fixture path).
/// We rename a few files in the fixture tree so they don't get caught by git's
/// own ignore matching when committed (e.g. a literal `.gitignore` or
/// `config.local.toml` inside a fixture dir gets ignored by recursive matches).
const FixtureMap = struct { actual: []const u8, fixture: []const u8 };
const FIXTURE_FILES = [_]FixtureMap{
    .{ .actual = "stacks/default/stack.toml", .fixture = "stacks/default/stack.toml" },
    .{ .actual = "config.toml", .fixture = "config.toml.expected" },
    .{ .actual = "state/local_token", .fixture = "state/local_token.expected" },
    .{ .actual = ".gitignore", .fixture = "dot_gitignore" },
};

test "fixture: empty_initialized matches committed snapshot (byte-for-byte)" {
    const a = std.testing.allocator;
    var s = try Scratch.create(a, "fixture-snap");
    defer s.deinit();

    var report = try init_mod.run(a, .{
        .root = s.abs_path,
        .yes = true,
        .quiet = true,
        .now_override = FIXTURE_NOW,
        .rng_seed_override = FIXTURE_SEED,
    });
    defer report.deinit();

    var d = try s.dir();
    defer d.close();
    inline for (FIXTURE_FILES) |map| {
        const actual = try readAll(a, &d, map.actual);
        defer a.free(actual);
        const fixture_path = "test/fixtures/notes_roots/empty_initialized/" ++ map.fixture;
        var expected_file = std.fs.cwd().openFile(fixture_path, .{}) catch |e| {
            std.debug.print("missing fixture file: {s}: {s}\n", .{ fixture_path, @errorName(e) });
            return e;
        };
        defer expected_file.close();
        const stat = try expected_file.stat();
        const expected = try a.alloc(u8, stat.size);
        defer a.free(expected);
        _ = try expected_file.readAll(expected);
        if (!std.mem.eql(u8, actual, expected)) {
            std.debug.print(
                "fixture mismatch for {s} vs {s}\n--- expected ({d} bytes) ---\n{s}\n--- actual ({d} bytes) ---\n{s}\n",
                .{ map.actual, map.fixture, expected.len, expected, actual.len, actual },
            );
            return error.FixtureMismatch;
        }
    }
}
