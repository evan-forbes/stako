//! Per-running-item runtime state on disk (milestone 6).
//!
//! Path: `<notes-root>/.organo/runtime/<stack>/<id>.toml`.
//!
//! This is *daemon state*, not tracked notes content. Items in `running`
//! status have a corresponding runtime file; on a clean shutdown the file
//! is deleted before the daemon exits. On an unclean restart, surviving
//! files indicate orphaned items and the daemon transitions them to
//! `failed` with reason `daemon_restart_orphan`.
//!
//! See `todos/design_execution_harness.md` ("Session Manager → State on disk").

const std = @import("std");
const audit = @import("audit.zig");

pub const RuntimeFile = struct {
    /// PID of the harness subprocess; 0 if not yet known.
    pid: std.posix.pid_t = 0,
    /// Harness name, e.g. "claude", "codex", "fake".
    harness: []const u8 = "",
    /// RFC3339 UTC start time.
    started_at: []const u8 = "",
    /// Path (absolute) to the transcript file the session manager is writing to.
    transcript_path: []const u8 = "",
    /// Harness-side session ID; empty when unknown.
    session_id: []const u8 = "",
};

pub fn dirPath(allocator: std.mem.Allocator, notes_root_abs: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ notes_root_abs, ".organo", "runtime" });
}

pub fn stackDirPath(allocator: std.mem.Allocator, notes_root_abs: []const u8, stack: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ notes_root_abs, ".organo", "runtime", stack });
}

pub fn filePath(allocator: std.mem.Allocator, notes_root_abs: []const u8, stack: []const u8, id: []const u8) ![]u8 {
    const file_name = try std.fmt.allocPrint(allocator, "{s}.toml", .{id});
    defer allocator.free(file_name);
    return std.fs.path.join(allocator, &.{ notes_root_abs, ".organo", "runtime", stack, file_name });
}

/// Atomically write a runtime file: write to `<file>.tmp` then rename.
pub fn write(
    allocator: std.mem.Allocator,
    notes_root_abs: []const u8,
    stack: []const u8,
    id: []const u8,
    rf: RuntimeFile,
) !void {
    const dir = try stackDirPath(allocator, notes_root_abs, stack);
    defer allocator.free(dir);
    try std.fs.cwd().makePath(dir);

    const path = try filePath(allocator, notes_root_abs, stack, id);
    defer allocator.free(path);

    var buf = std.ArrayList(u8){};
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try w.print("pid = {d}\n", .{rf.pid});
    try w.writeAll("harness = \"");
    try writeTomlStr(w, rf.harness);
    try w.writeAll("\"\nstarted_at = ");
    try w.writeAll(rf.started_at);
    try w.writeAll("\ntranscript_path = \"");
    try writeTomlStr(w, rf.transcript_path);
    try w.writeAll("\"\nsession_id = \"");
    try writeTomlStr(w, rf.session_id);
    try w.writeAll("\"\n");

    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(tmp_path);

    {
        var f = try std.fs.cwd().createFile(tmp_path, .{ .truncate = true, .mode = 0o600 });
        defer f.close();
        try f.writeAll(buf.items);
    }
    try std.fs.cwd().rename(tmp_path, path);
}

pub fn deleteFor(
    allocator: std.mem.Allocator,
    notes_root_abs: []const u8,
    stack: []const u8,
    id: []const u8,
) !void {
    const path = try filePath(allocator, notes_root_abs, stack, id);
    defer allocator.free(path);
    std.fs.cwd().deleteFile(path) catch |e| switch (e) {
        error.FileNotFound => {},
        else => return e,
    };
}

pub const Parsed = struct {
    arena: std.heap.ArenaAllocator,
    rf: RuntimeFile,

    pub fn deinit(self: *Parsed) void {
        self.arena.deinit();
    }
};

/// Load and parse a runtime file. Returns null if the file is absent.
pub fn read(
    allocator: std.mem.Allocator,
    notes_root_abs: []const u8,
    stack: []const u8,
    id: []const u8,
) !?Parsed {
    const path = try filePath(allocator, notes_root_abs, stack, id);
    defer allocator.free(path);
    var f = std.fs.cwd().openFile(path, .{}) catch |e| switch (e) {
        error.FileNotFound => return null,
        else => return e,
    };
    defer f.close();
    const stat = try f.stat();
    const buf = try allocator.alloc(u8, stat.size);
    defer allocator.free(buf);
    _ = try f.readAll(buf);

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const aa = arena.allocator();
    var rf: RuntimeFile = .{};

    var it = std.mem.splitScalar(u8, buf, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const k = std.mem.trim(u8, line[0..eq], " \t");
        var v_raw = std.mem.trim(u8, line[eq + 1 ..], " \t");
        // Strip enclosing quotes if present.
        if (v_raw.len >= 2 and v_raw[0] == '"' and v_raw[v_raw.len - 1] == '"') {
            v_raw = v_raw[1 .. v_raw.len - 1];
        }
        if (std.mem.eql(u8, k, "pid")) {
            rf.pid = std.fmt.parseInt(std.posix.pid_t, v_raw, 10) catch 0;
        } else if (std.mem.eql(u8, k, "harness")) {
            rf.harness = try aa.dupe(u8, v_raw);
        } else if (std.mem.eql(u8, k, "started_at")) {
            rf.started_at = try aa.dupe(u8, v_raw);
        } else if (std.mem.eql(u8, k, "transcript_path")) {
            rf.transcript_path = try aa.dupe(u8, v_raw);
        } else if (std.mem.eql(u8, k, "session_id")) {
            rf.session_id = try aa.dupe(u8, v_raw);
        }
    }
    return .{ .arena = arena, .rf = rf };
}

pub const Orphan = struct {
    stack: []u8,
    id: []u8,
    parsed: ?Parsed = null,
};

/// Walk `.organo/runtime/` and return one Orphan per file found. Caller
/// frees via `freeOrphans`.
pub fn listAll(
    allocator: std.mem.Allocator,
    notes_root_abs: []const u8,
) ![]Orphan {
    const dir_path = try dirPath(allocator, notes_root_abs);
    defer allocator.free(dir_path);

    var out = std.ArrayList(Orphan){};
    errdefer {
        for (out.items) |*o| freeOrphan(allocator, o);
        out.deinit(allocator);
    }

    var root = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound, error.NotDir => return out.toOwnedSlice(allocator),
        else => return e,
    };
    defer root.close();

    var stack_it = root.iterate();
    while (try stack_it.next()) |stack_entry| {
        if (stack_entry.kind != .directory) continue;
        const stack_abs = try std.fs.path.join(allocator, &.{ dir_path, stack_entry.name });
        defer allocator.free(stack_abs);
        var sd = std.fs.openDirAbsolute(stack_abs, .{ .iterate = true }) catch continue;
        defer sd.close();
        var it = sd.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .file) continue;
            // Expect `<id>.toml`.
            if (!std.mem.endsWith(u8, entry.name, ".toml")) continue;
            const id_part = entry.name[0 .. entry.name.len - ".toml".len];
            const parsed = read(allocator, notes_root_abs, stack_entry.name, id_part) catch null;
            try out.append(allocator, .{
                .stack = try allocator.dupe(u8, stack_entry.name),
                .id = try allocator.dupe(u8, id_part),
                .parsed = parsed,
            });
        }
    }
    return out.toOwnedSlice(allocator);
}

pub fn freeOrphans(allocator: std.mem.Allocator, orphans: []Orphan) void {
    for (orphans) |*o| freeOrphan(allocator, o);
    allocator.free(orphans);
}

fn freeOrphan(allocator: std.mem.Allocator, o: *Orphan) void {
    allocator.free(o.stack);
    allocator.free(o.id);
    if (o.parsed) |*p| p.deinit();
}

fn writeTomlStr(w: anytype, s: []const u8) !void {
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

test "write + read round-trip" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = try tmp.dir.realpath(".", &buf);

    try write(a, abs, "demo", "0007", .{
        .pid = 12345,
        .harness = "fake",
        .started_at = "2026-05-10T14:00:00.000Z",
        .transcript_path = "/tmp/x/transcript.jsonl",
        .session_id = "sess-9",
    });

    var p = (try read(a, abs, "demo", "0007")).?;
    defer p.deinit();
    try std.testing.expectEqual(@as(std.posix.pid_t, 12345), p.rf.pid);
    try std.testing.expectEqualStrings("fake", p.rf.harness);
    try std.testing.expectEqualStrings("/tmp/x/transcript.jsonl", p.rf.transcript_path);
    try std.testing.expectEqualStrings("sess-9", p.rf.session_id);
}

test "listAll finds orphans across stacks" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = try tmp.dir.realpath(".", &buf);

    try write(a, abs, "alpha", "0001", .{ .pid = 1, .harness = "fake", .started_at = "x", .transcript_path = "/t/a/0001/t.jsonl" });
    try write(a, abs, "beta", "0002", .{ .pid = 2, .harness = "fake", .started_at = "y", .transcript_path = "/t/b/0002/t.jsonl" });

    const orphans = try listAll(a, abs);
    defer freeOrphans(a, orphans);
    try std.testing.expectEqual(@as(usize, 2), orphans.len);
    // We don't depend on directory iteration order, but both must show.
    var got_alpha = false;
    var got_beta = false;
    for (orphans) |o| {
        if (std.mem.eql(u8, o.stack, "alpha") and std.mem.eql(u8, o.id, "0001")) got_alpha = true;
        if (std.mem.eql(u8, o.stack, "beta") and std.mem.eql(u8, o.id, "0002")) got_beta = true;
    }
    try std.testing.expect(got_alpha and got_beta);
}

test "deleteFor removes the file" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = try tmp.dir.realpath(".", &buf);

    try write(a, abs, "demo", "0009", .{ .pid = 7, .harness = "fake", .started_at = "x", .transcript_path = "x" });
    try deleteFor(a, abs, "demo", "0009");
    try std.testing.expect((try read(a, abs, "demo", "0009")) == null);
}

test "audit module reachable" {
    _ = audit.Action.dispatch_harness;
}
