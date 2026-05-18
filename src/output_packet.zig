//! Legacy output-packet readers plus workdir snapshot helpers.
//!
//! New terminal item output is the stack commit itself. The remaining packet
//! helpers support old item directories and keep workdir snapshot logic
//! independent from stack VCS. Workdir snapshots use git only inside the
//! target workdir and never stage, commit, clean, or rewrite anything there.

const std = @import("std");
const events = @import("events.zig");
const item_mod = @import("item.zig");
const toml = @import("toml.zig");

pub const WorkdirKind = enum {
    git,
    none,
    unknown,

    pub fn toString(self: WorkdirKind) []const u8 {
        return switch (self) {
            .git => "git",
            .none => "none",
            .unknown => "unknown",
        };
    }
};

pub const WorkdirSnapshot = struct {
    allocator: std.mem.Allocator,
    kind: WorkdirKind,
    root: ?[]u8 = null,
    head: ?[]u8 = null,
    dirty: bool = false,
    status: [][]u8 = &.{},

    pub fn deinit(self: *WorkdirSnapshot) void {
        if (self.root) |s| self.allocator.free(s);
        if (self.head) |s| self.allocator.free(s);
        for (self.status) |s| self.allocator.free(s);
        if (self.status.len > 0) self.allocator.free(self.status);
        self.* = .{ .allocator = self.allocator, .kind = .unknown };
    }
};

pub const PacketInput = struct {
    stack: []const u8,
    item_id: []const u8,
    status: []const u8,
    completed_at: ?[]const u8 = null,
    result: item_mod.Result = .{},
    thread_name: ?[]const u8 = null,
    thread_mode: ?item_mod.ThreadMode = null,
    resume_session_id: ?[]const u8 = null,
    summary: ?[]const u8 = null,
    changed_paths: []const []const u8 = &.{},
    workdir_before: ?*const WorkdirSnapshot = null,
    workdir_after: ?*const WorkdirSnapshot = null,
};

pub const Manifest = struct {
    arena: std.heap.ArenaAllocator,
    version: i64 = 0,
    stack: ?[]const u8 = null,
    item: ?[]const u8 = null,
    status: ?[]const u8 = null,
    completed_at: ?[]const u8 = null,
    result: item_mod.Result = .{},
    thread_name: ?[]const u8 = null,
    thread_mode: ?item_mod.ThreadMode = null,
    resume_session_id: ?[]const u8 = null,
    workdir_kind: ?WorkdirKind = null,
    workdir_root: ?[]const u8 = null,
    workdir_head_before: ?[]const u8 = null,
    workdir_head_after: ?[]const u8 = null,
    workdir_dirty_before: ?bool = null,
    workdir_dirty_after: ?bool = null,

    pub fn deinit(self: *Manifest) void {
        self.arena.deinit();
    }
};

pub fn itemOutputDirRel(allocator: std.mem.Allocator, stack: []const u8, item_dir_name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "stacks/{s}/{s}/output", .{ stack, item_dir_name });
}

pub fn itemOutputSummaryRel(allocator: std.mem.Allocator, stack: []const u8, item_dir_name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "stacks/{s}/{s}/output/summary.md", .{ stack, item_dir_name });
}

pub fn itemOutputManifestRel(allocator: std.mem.Allocator, stack: []const u8, item_dir_name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "stacks/{s}/{s}/output/manifest.toml", .{ stack, item_dir_name });
}

pub fn itemOutputChangedPathsRel(allocator: std.mem.Allocator, stack: []const u8, item_dir_name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "stacks/{s}/{s}/output/changed_paths.txt", .{ stack, item_dir_name });
}

pub fn writePacket(
    allocator: std.mem.Allocator,
    notes_root_abs: []const u8,
    stack: []const u8,
    item_dir_name: []const u8,
    input: PacketInput,
) ![][]u8 {
    const output_rel = try itemOutputDirRel(allocator, stack, item_dir_name);
    defer allocator.free(output_rel);
    const output_abs = try std.fs.path.join(allocator, &.{ notes_root_abs, output_rel });
    defer allocator.free(output_abs);
    try std.fs.cwd().makePath(output_abs);

    const summary_rel = try itemOutputSummaryRel(allocator, stack, item_dir_name);
    errdefer allocator.free(summary_rel);
    const manifest_rel = try itemOutputManifestRel(allocator, stack, item_dir_name);
    errdefer allocator.free(manifest_rel);
    const changed_rel = try itemOutputChangedPathsRel(allocator, stack, item_dir_name);
    errdefer allocator.free(changed_rel);

    {
        const path_abs = try std.fs.path.join(allocator, &.{ notes_root_abs, summary_rel });
        defer allocator.free(path_abs);
        var f = try std.fs.cwd().createFile(path_abs, .{ .truncate = true });
        defer f.close();
        const summary = normalizedSummary(input.summary);
        try f.writeAll(summary);
    }
    {
        const path_abs = try std.fs.path.join(allocator, &.{ notes_root_abs, changed_rel });
        defer allocator.free(path_abs);
        var f = try std.fs.cwd().createFile(path_abs, .{ .truncate = true });
        defer f.close();
        for (input.changed_paths) |p| {
            try f.writeAll(p);
            try f.writeAll("\n");
        }
    }
    {
        const path_abs = try std.fs.path.join(allocator, &.{ notes_root_abs, manifest_rel });
        defer allocator.free(path_abs);
        var f = try std.fs.cwd().createFile(path_abs, .{ .truncate = true });
        defer f.close();
        var buf: [4096]u8 = undefined;
        var fw = f.writer(&buf);
        try writeManifest(&fw.interface, input);
        try fw.interface.flush();
    }

    var paths = try allocator.alloc([]u8, 3);
    paths[0] = summary_rel;
    paths[1] = manifest_rel;
    paths[2] = changed_rel;
    return paths;
}

pub fn readManifest(allocator: std.mem.Allocator, path_abs: []const u8) !Manifest {
    var f = try std.fs.cwd().openFile(path_abs, .{});
    defer f.close();
    const stat = try f.stat();
    const src = try allocator.alloc(u8, stat.size);
    defer allocator.free(src);
    const n = try f.readAll(src);

    var doc = try toml.parse(allocator, src[0..n]);
    defer doc.deinit();

    var out = Manifest{ .arena = std.heap.ArenaAllocator.init(allocator) };
    errdefer out.deinit();
    const arena = out.arena.allocator();
    for (doc.entries.items) |e| {
        if (std.mem.eql(u8, e.table, "")) {
            if (std.mem.eql(u8, e.key, "version") and e.value == .integer) out.version = e.value.integer;
            if (std.mem.eql(u8, e.key, "stack") and e.value == .string) out.stack = try arena.dupe(u8, e.value.string);
            if (std.mem.eql(u8, e.key, "item") and e.value == .string) out.item = try arena.dupe(u8, e.value.string);
            if (std.mem.eql(u8, e.key, "status") and e.value == .string) out.status = try arena.dupe(u8, e.value.string);
            if (std.mem.eql(u8, e.key, "completed_at") and e.value == .datetime) out.completed_at = try arena.dupe(u8, e.value.datetime);
        } else if (std.mem.eql(u8, e.table, "result")) {
            if (std.mem.eql(u8, e.key, "harness") and e.value == .string) out.result.harness = try arena.dupe(u8, e.value.string);
            if (std.mem.eql(u8, e.key, "model") and e.value == .string) out.result.model = try arena.dupe(u8, e.value.string);
            if (std.mem.eql(u8, e.key, "session_id") and e.value == .string) out.result.session_id = try arena.dupe(u8, e.value.string);
            if (std.mem.eql(u8, e.key, "session_file") and e.value == .string) out.result.session_file = try arena.dupe(u8, e.value.string);
            if (std.mem.eql(u8, e.key, "transcript_path") and e.value == .string) out.result.transcript_path = try arena.dupe(u8, e.value.string);
            if (std.mem.eql(u8, e.key, "exit_code") and e.value == .integer) out.result.exit_code = e.value.integer;
            if (std.mem.eql(u8, e.key, "completed_at") and e.value == .datetime) out.result.completed_at = try arena.dupe(u8, e.value.datetime);
        } else if (std.mem.eql(u8, e.table, "thread")) {
            if (std.mem.eql(u8, e.key, "name") and e.value == .string) out.thread_name = try arena.dupe(u8, e.value.string);
            if (std.mem.eql(u8, e.key, "mode") and e.value == .string) out.thread_mode = item_mod.ThreadMode.fromString(e.value.string);
            if (std.mem.eql(u8, e.key, "resume_session_id") and e.value == .string) out.resume_session_id = try arena.dupe(u8, e.value.string);
        } else if (std.mem.eql(u8, e.table, "workdir")) {
            if (std.mem.eql(u8, e.key, "kind") and e.value == .string) {
                out.workdir_kind = if (std.mem.eql(u8, e.value.string, "git"))
                    .git
                else if (std.mem.eql(u8, e.value.string, "none"))
                    .none
                else
                    .unknown;
            }
            if (std.mem.eql(u8, e.key, "root") and e.value == .string) out.workdir_root = try arena.dupe(u8, e.value.string);
            if (std.mem.eql(u8, e.key, "head_before") and e.value == .string) out.workdir_head_before = try arena.dupe(u8, e.value.string);
            if (std.mem.eql(u8, e.key, "head_after") and e.value == .string) out.workdir_head_after = try arena.dupe(u8, e.value.string);
            if (std.mem.eql(u8, e.key, "dirty_before") and e.value == .boolean) out.workdir_dirty_before = e.value.boolean;
            if (std.mem.eql(u8, e.key, "dirty_after") and e.value == .boolean) out.workdir_dirty_after = e.value.boolean;
        }
    }
    return out;
}

pub fn readSummary(allocator: std.mem.Allocator, path_abs: []const u8) ![]u8 {
    var f = try std.fs.cwd().openFile(path_abs, .{});
    defer f.close();
    const stat = try f.stat();
    const buf = try allocator.alloc(u8, stat.size);
    errdefer allocator.free(buf);
    _ = try f.readAll(buf);
    return buf;
}

pub fn snapshotWorkdir(allocator: std.mem.Allocator, cwd: ?[]const u8) !WorkdirSnapshot {
    const wd = cwd orelse return .{ .allocator = allocator, .kind = .none };
    const root_out = runGit(allocator, wd, &.{ "rev-parse", "--show-toplevel" }, true) catch |e| switch (e) {
        error.GitNotFound => return .{ .allocator = allocator, .kind = .unknown },
        else => return .{ .allocator = allocator, .kind = .none },
    };
    defer allocator.free(root_out);
    const root_trimmed = std.mem.trim(u8, root_out, " \t\r\n");
    if (root_trimmed.len == 0) return .{ .allocator = allocator, .kind = .none };
    const root = try allocator.dupe(u8, root_trimmed);
    errdefer allocator.free(root);

    const head = blk: {
        const head_out = runGit(allocator, root, &.{ "rev-parse", "HEAD" }, true) catch break :blk null;
        defer allocator.free(head_out);
        const trimmed = std.mem.trim(u8, head_out, " \t\r\n");
        if (trimmed.len == 0) break :blk null;
        break :blk try allocator.dupe(u8, trimmed);
    };
    errdefer if (head) |h| allocator.free(h);

    const status_out = runGit(allocator, root, &.{ "status", "--porcelain", "--untracked-files=all" }, true) catch |e| {
        if (head) |h| allocator.free(h);
        allocator.free(root);
        switch (e) {
            error.GitNotFound => return .{ .allocator = allocator, .kind = .unknown },
            else => return .{ .allocator = allocator, .kind = .none },
        }
    };
    defer allocator.free(status_out);
    const status = try parseStatusLines(allocator, status_out);
    errdefer {
        for (status) |s| allocator.free(s);
        allocator.free(status);
    }

    return .{
        .allocator = allocator,
        .kind = .git,
        .root = root,
        .head = head,
        .dirty = status.len > 0,
        .status = status,
    };
}

pub fn changedPathsFromSnapshots(
    allocator: std.mem.Allocator,
    before: ?*const WorkdirSnapshot,
    after: ?*const WorkdirSnapshot,
) ![][]u8 {
    const b = before orelse return allocator.alloc([]u8, 0);
    const a = after orelse return allocator.alloc([]u8, 0);
    if (b.kind != .git or a.kind != .git) return allocator.alloc([]u8, 0);
    if (b.root == null or a.root == null or !std.mem.eql(u8, b.root.?, a.root.?)) return allocator.alloc([]u8, 0);

    var out = std.ArrayList([]u8){};
    errdefer {
        for (out.items) |p| allocator.free(p);
        out.deinit(allocator);
    }

    for (a.status) |line| {
        const path = statusPath(line);
        if (path.len > 0 and !containsPath(out.items, path)) {
            try out.append(allocator, try allocator.dupe(u8, path));
        }
    }

    if (b.head != null and a.head != null and !std.mem.eql(u8, b.head.?, a.head.?)) {
        const range = try std.fmt.allocPrint(allocator, "{s}..{s}", .{ b.head.?, a.head.? });
        defer allocator.free(range);
        const diff_out = runGit(allocator, a.root.?, &.{ "diff", "--name-only", range }, true) catch "";
        const free_diff = diff_out.len > 0;
        defer if (free_diff) allocator.free(diff_out);
        var it = std.mem.splitScalar(u8, diff_out, '\n');
        while (it.next()) |raw| {
            const p = std.mem.trim(u8, raw, " \t\r");
            if (p.len > 0 and !containsPath(out.items, p)) try out.append(allocator, try allocator.dupe(u8, p));
        }
    }

    std.mem.sort([]u8, out.items, {}, lessThanOwnedString);
    return out.toOwnedSlice(allocator);
}

pub fn summaryFromTranscript(allocator: std.mem.Allocator, transcript_path: []const u8) !?[]u8 {
    var f = std.fs.cwd().openFile(transcript_path, .{}) catch return null;
    defer f.close();
    const stat = try f.stat();
    const src = try allocator.alloc(u8, stat.size);
    defer allocator.free(src);
    const n = try f.readAll(src);

    var best: ?[]u8 = null;
    errdefer if (best) |b| allocator.free(b);
    var it = std.mem.splitScalar(u8, src[0..n], '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const ev = events.parseEvent(line) orelse continue;
        if (ev.kind != .message) continue;
        const text = extractJsonString(ev.data_json, "\"text\":") orelse
            extractJsonString(ev.data_json, "\"message\":") orelse
            extractJsonString(ev.data_json, "\"result\":") orelse
            continue;
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len == 0) continue;
        if (best) |old| allocator.free(old);
        best = try allocator.dupe(u8, trimmed);
    }
    return best;
}

fn writeManifest(w: anytype, input: PacketInput) !void {
    try w.writeAll("version = 1\n");
    try writeStringKv(w, "stack", input.stack);
    try writeStringKv(w, "item", input.item_id);
    try writeStringKv(w, "status", input.status);
    if (input.completed_at) |s| try writeDatetimeKv(w, "completed_at", s);

    try w.writeAll("\n[result]\n");
    if (input.result.harness) |s| try writeStringKv(w, "harness", s);
    if (input.result.model) |s| try writeStringKv(w, "model", s);
    if (input.result.session_id) |s| try writeStringKv(w, "session_id", s);
    if (input.result.session_file) |s| try writeStringKv(w, "session_file", s);
    if (input.result.transcript_path) |s| try writeStringKv(w, "transcript_path", s);
    if (input.result.exit_code) |n| try w.print("exit_code = {d}\n", .{n});
    if (input.result.completed_at) |s| try writeDatetimeKv(w, "completed_at", s);

    if (input.thread_name) |name| {
        try w.writeAll("\n[thread]\n");
        try writeStringKv(w, "name", name);
        if (input.thread_mode) |mode| try writeStringKv(w, "mode", mode.toString());
        if (input.resume_session_id) |sid| try writeStringKv(w, "resume_session_id", sid);
    }

    const before = input.workdir_before;
    const after = input.workdir_after;
    if (before != null or after != null) {
        const kind = if (after) |a| a.kind else before.?.kind;
        try w.writeAll("\n[workdir]\n");
        try writeStringKv(w, "kind", kind.toString());
        if (after) |a| if (a.root) |s| try writeStringKv(w, "root", s);
        if (before) |b| {
            if (b.head) |s| try writeStringKv(w, "head_before", s);
            try w.print("dirty_before = {s}\n", .{if (b.dirty) "true" else "false"});
        }
        if (after) |a| {
            if (a.head) |s| try writeStringKv(w, "head_after", s);
            try w.print("dirty_after = {s}\n", .{if (a.dirty) "true" else "false"});
        }
    }
}

fn writeStringKv(w: anytype, key: []const u8, value: []const u8) !void {
    try w.writeAll(key);
    try w.writeAll(" = ");
    try toml.writeString(w, value);
    try w.writeByte('\n');
}

fn writeDatetimeKv(w: anytype, key: []const u8, value: []const u8) !void {
    try w.writeAll(key);
    try w.writeAll(" = ");
    try w.writeAll(value);
    try w.writeByte('\n');
}

fn normalizedSummary(summary: ?[]const u8) []const u8 {
    if (summary) |s| {
        const trimmed = std.mem.trim(u8, s, " \t\r\n");
        if (trimmed.len > 0) return trimmed;
    }
    return "Item completed without a final assistant summary.\n\nTranscript: ../transcript.jsonl\n";
}

fn parseStatusLines(allocator: std.mem.Allocator, src: []const u8) ![][]u8 {
    var out = std.ArrayList([]u8){};
    errdefer {
        for (out.items) |s| allocator.free(s);
        out.deinit(allocator);
    }
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimRight(u8, raw, "\r");
        if (line.len == 0) continue;
        try out.append(allocator, try allocator.dupe(u8, line));
    }
    return out.toOwnedSlice(allocator);
}

fn containsPath(paths: []const []u8, needle: []const u8) bool {
    for (paths) |p| if (std.mem.eql(u8, p, needle)) return true;
    return false;
}

fn statusPath(line: []const u8) []const u8 {
    if (line.len <= 3) return "";
    const raw = std.mem.trim(u8, line[3..], " \t");
    if (std.mem.indexOf(u8, raw, " -> ")) |idx| return raw[idx + 4 ..];
    return raw;
}

fn lessThanOwnedString(_: void, a: []u8, b: []u8) bool {
    return std.mem.lessThan(u8, a, b);
}

const GitRunError = error{ GitNotFound, GitFailed, OutOfMemory };

fn runGit(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    args: []const []const u8,
    error_on_nonzero: bool,
) GitRunError![]u8 {
    var argv = std.ArrayList([]const u8){};
    defer argv.deinit(allocator);
    try argv.append(allocator, "git");
    for (args) |a| try argv.append(allocator, a);

    var child = std.process.Child.init(argv.items, allocator);
    child.cwd = cwd;
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
    defer stderr_buf.deinit(allocator);
    child.collectOutput(allocator, &stdout_buf, &stderr_buf, 8 * 1024 * 1024) catch return error.GitFailed;
    const term = child.wait() catch return error.GitFailed;
    const exit_code: u8 = switch (term) {
        .Exited => |c| c,
        else => 1,
    };
    if (error_on_nonzero and exit_code != 0) return error.GitFailed;
    return stdout_buf.toOwnedSlice(allocator);
}

fn extractJsonString(src: []const u8, key_with_colon: []const u8) ?[]const u8 {
    const idx = std.mem.indexOf(u8, src, key_with_colon) orelse return null;
    var i = idx + key_with_colon.len;
    while (i < src.len and (src[i] == ' ' or src[i] == '\t')) i += 1;
    if (i >= src.len or src[i] != '"') return null;
    i += 1;
    const start = i;
    while (i < src.len) : (i += 1) {
        if (src[i] == '\\') {
            i += 1;
            continue;
        }
        if (src[i] == '"') return src[start..i];
    }
    return null;
}

test "output_packet: non-git workdir snapshots as none" {
    const a = std.testing.allocator;
    const base = try std.fmt.allocPrint(a, "/tmp/stako-output-packet-{d}", .{std.time.nanoTimestamp()});
    defer a.free(base);
    try std.fs.cwd().makePath(base);
    defer std.fs.cwd().deleteTree(base) catch {};
    var snap = try snapshotWorkdir(a, base);
    defer snap.deinit();
    try std.testing.expectEqual(WorkdirKind.none, snap.kind);
}

test "output_packet: git snapshots produce sorted tracked and untracked changed paths" {
    const a = std.testing.allocator;
    const base = try std.fmt.allocPrint(a, "/tmp/stako-output-packet-git-{d}", .{std.time.nanoTimestamp()});
    defer a.free(base);
    try std.fs.cwd().makePath(base);
    defer std.fs.cwd().deleteTree(base) catch {};

    const tracked = try std.fs.path.join(a, &.{ base, "b.txt" });
    defer a.free(tracked);
    {
        var f = try std.fs.cwd().createFile(tracked, .{ .truncate = true });
        defer f.close();
        try f.writeAll("before\n");
    }
    const untracked = try std.fs.path.join(a, &.{ base, "a.txt" });
    defer a.free(untracked);

    var out = try runGit(a, base, &.{ "init", "--quiet", "--initial-branch=main" }, true);
    a.free(out);
    out = try runGit(a, base, &.{ "add", "--", "b.txt" }, true);
    a.free(out);
    out = try runGit(a, base, &.{ "-c", "user.name=stako test", "-c", "user.email=stako@test", "commit", "--quiet", "--no-gpg-sign", "-m", "init" }, true);
    a.free(out);

    var before = try snapshotWorkdir(a, base);
    defer before.deinit();

    {
        var f = try std.fs.cwd().createFile(tracked, .{ .truncate = true });
        defer f.close();
        try f.writeAll("after\n");
    }
    {
        var f = try std.fs.cwd().createFile(untracked, .{ .truncate = true });
        defer f.close();
        try f.writeAll("new\n");
    }

    var after = try snapshotWorkdir(a, base);
    defer after.deinit();
    const paths = try changedPathsFromSnapshots(a, &before, &after);
    defer {
        for (paths) |p| a.free(p);
        a.free(paths);
    }
    try std.testing.expectEqual(@as(usize, 2), paths.len);
    try std.testing.expectEqualStrings("a.txt", paths[0]);
    try std.testing.expectEqualStrings("b.txt", paths[1]);
}

test "output_packet: after-snapshot dirty paths are reported even when dirty before" {
    const a = std.testing.allocator;
    const base = try std.fmt.allocPrint(a, "/tmp/stako-output-packet-dirty-before-{d}", .{std.time.nanoTimestamp()});
    defer a.free(base);
    try std.fs.cwd().makePath(base);
    defer std.fs.cwd().deleteTree(base) catch {};

    const tracked = try std.fs.path.join(a, &.{ base, "same.txt" });
    defer a.free(tracked);
    {
        var f = try std.fs.cwd().createFile(tracked, .{ .truncate = true });
        defer f.close();
        try f.writeAll("committed\n");
    }

    var out = try runGit(a, base, &.{ "init", "--quiet", "--initial-branch=main" }, true);
    a.free(out);
    out = try runGit(a, base, &.{ "add", "--", "same.txt" }, true);
    a.free(out);
    out = try runGit(a, base, &.{ "-c", "user.name=stako test", "-c", "user.email=stako@test", "commit", "--quiet", "--no-gpg-sign", "-m", "init" }, true);
    a.free(out);

    {
        var f = try std.fs.cwd().createFile(tracked, .{ .truncate = true });
        defer f.close();
        try f.writeAll("dirty before\n");
    }

    var before = try snapshotWorkdir(a, base);
    defer before.deinit();

    {
        var f = try std.fs.cwd().createFile(tracked, .{ .truncate = true });
        defer f.close();
        try f.writeAll("dirty after\n");
    }

    var after = try snapshotWorkdir(a, base);
    defer after.deinit();
    const paths = try changedPathsFromSnapshots(a, &before, &after);
    defer {
        for (paths) |p| a.free(p);
        a.free(paths);
    }

    try std.testing.expectEqual(@as(usize, 1), paths.len);
    try std.testing.expectEqualStrings("same.txt", paths[0]);
}
