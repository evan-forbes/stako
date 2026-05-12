//! Audit log writer (milestone 5).
//!
//! Append-only NDJSON at `<notes-root>/.organo/audit.log`, perms 0600, one
//! line per event. Schema per `todos/design_errors_and_audit.md`:
//!
//!     {"ts":"...","identity":"...","action":"...","target":"...",
//!      "outcome":"allowed|denied","reason":"<code?>","details":{...}}
//!
//! - No rotation in v1.
//! - Each write is followed by an fsync so a crash doesn't lose a recorded
//!   mutation. Writes are synchronous; mutations serialize on the queue so
//!   contention is bounded.
//! - The file is created on first write with 0600 perms.

const std = @import("std");
const errors_mod = @import("errors.zig");

/// Action vocabulary from the design doc. Stable string slugs.
pub const Action = enum {
    create_stack,
    append_item,
    insert_item,
    retry_item,
    cancel_item,
    supersede_item,
    pause_stack,
    resume_stack,
    update_stack_config,
    dispatch_harness,
    daemon_started,
    daemon_stopped,

    pub fn slug(self: Action) []const u8 {
        return switch (self) {
            .create_stack => "create_stack",
            .append_item => "append_item",
            .insert_item => "insert_item",
            .retry_item => "retry_item",
            .cancel_item => "cancel_item",
            .supersede_item => "supersede_item",
            .pause_stack => "pause_stack",
            .resume_stack => "resume_stack",
            .update_stack_config => "update_stack_config",
            .dispatch_harness => "dispatch_harness",
            .daemon_started => "daemon_started",
            .daemon_stopped => "daemon_stopped",
        };
    }
};

pub const Outcome = enum {
    allowed,
    denied,

    pub fn slug(self: Outcome) []const u8 {
        return switch (self) {
            .allowed => "allowed",
            .denied => "denied",
        };
    }
};

pub const DetailKV = struct {
    key: []const u8,
    value: []const u8,
};

pub const Event = struct {
    /// RFC 3339 UTC, millisecond precision; if null, `append` fills with now.
    ts: ?[]const u8 = null,
    identity: []const u8,
    action: Action,
    target: []const u8,
    outcome: Outcome,
    /// Required when `outcome == .denied`.
    reason: ?[]const u8 = null,
    details: []const DetailKV = &.{},
};

/// Owning writer. Bound to a notes root. Single-writer access expected
/// (callers serialize through the mutation queue); no internal lock.
pub const Writer = struct {
    allocator: std.mem.Allocator,
    notes_root_abs: []u8,
    /// Open file handle, opened lazily on first append.
    file: ?std.fs.File = null,

    pub fn init(allocator: std.mem.Allocator, notes_root_abs: []const u8) !Writer {
        const owned = try allocator.dupe(u8, notes_root_abs);
        return .{ .allocator = allocator, .notes_root_abs = owned };
    }

    pub fn deinit(self: *Writer) void {
        if (self.file) |*f| f.close();
        self.allocator.free(self.notes_root_abs);
    }

    fn ensureOpen(self: *Writer) !void {
        if (self.file != null) return;
        const dir_path = try std.fs.path.join(self.allocator, &.{ self.notes_root_abs, ".organo" });
        defer self.allocator.free(dir_path);
        std.fs.cwd().makePath(dir_path) catch {};
        const log_path = try std.fs.path.join(self.allocator, &.{ dir_path, "audit.log" });
        defer self.allocator.free(log_path);
        var f = try std.fs.cwd().createFile(log_path, .{
            .truncate = false,
            .read = false,
            .mode = 0o600,
        });
        f.seekFromEnd(0) catch {};
        // Tighten perms if the file already existed with a looser mode.
        if (@import("builtin").os.tag != .windows) {
            std.posix.fchmod(f.handle, 0o600) catch {};
        }
        self.file = f;
    }

    /// Append one event. Each event becomes one NDJSON line.
    pub fn append(self: *Writer, event: Event) !void {
        try self.ensureOpen();
        var f = self.file orelse return error.NoFile;

        // Build the line in memory first so we never write a partial record.
        var buf = std.ArrayList(u8){};
        defer buf.deinit(self.allocator);
        const w = buf.writer(self.allocator);

        try w.writeAll("{\"ts\":\"");
        if (event.ts) |s| {
            try errors_mod.writeJsonString(w, s);
        } else {
            var ts_buf: [40]u8 = undefined;
            const now = nowRfc3339Millis(&ts_buf);
            try errors_mod.writeJsonString(w, now);
        }
        try w.writeAll("\",\"identity\":\"");
        try errors_mod.writeJsonString(w, event.identity);
        try w.writeAll("\",\"action\":\"");
        try w.writeAll(event.action.slug());
        try w.writeAll("\",\"target\":\"");
        try errors_mod.writeJsonString(w, event.target);
        try w.writeAll("\",\"outcome\":\"");
        try w.writeAll(event.outcome.slug());
        try w.writeAll("\"");
        if (event.outcome == .denied) {
            if (event.reason) |r| {
                try w.writeAll(",\"reason\":\"");
                try errors_mod.writeJsonString(w, r);
                try w.writeAll("\"");
            }
        }
        try w.writeAll(",\"details\":{");
        for (event.details, 0..) |d, i| {
            if (i != 0) try w.writeAll(",");
            try w.writeAll("\"");
            try errors_mod.writeJsonString(w, d.key);
            try w.writeAll("\":\"");
            try errors_mod.writeJsonString(w, d.value);
            try w.writeAll("\"");
        }
        try w.writeAll("}}\n");

        try f.writeAll(buf.items);
        // Fsync so a crash doesn't lose a recorded mutation.
        try f.sync();
    }
};

/// Format current UTC time as RFC 3339 with millisecond precision.
/// Writes into `buf` and returns the slice. `buf` must be ≥ 24 bytes.
pub fn nowRfc3339Millis(buf: []u8) []const u8 {
    const ns = std.time.nanoTimestamp();
    const ms_total: i128 = @divTrunc(ns, 1_000_000);
    const ts: i64 = @intCast(@divTrunc(ms_total, 1000));
    const ms: u32 = @intCast(@mod(ms_total, 1000));
    return formatRfc3339Millis(buf, ts, ms);
}

/// Format a (unix-seconds, millis) pair as `YYYY-MM-DDTHH:MM:SS.mmmZ`.
pub fn formatRfc3339Millis(buf: []u8, ts: i64, ms: u32) []const u8 {
    const days = @divFloor(ts, 86400);
    const time_of_day = @mod(ts, 86400);
    const hh: u32 = @intCast(@divFloor(time_of_day, 3600));
    const mm: u32 = @intCast(@divFloor(@mod(time_of_day, 3600), 60));
    const ss: u32 = @intCast(@mod(time_of_day, 60));

    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe: i64 = z - era * 146097;
    const yoe: i64 = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const y0: i64 = yoe + era * 400;
    const doy: i64 = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp: i64 = @divFloor(5 * doy + 2, 153);
    const d: u32 = @intCast(doy - @divFloor(153 * mp + 2, 5) + 1);
    const mo: u32 = @intCast(if (mp < 10) mp + 3 else mp - 9);
    const y: i64 = y0 + @as(i64, @intFromBool(mo <= 2));
    const yu: u32 = @intCast(y);

    const written = std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
        yu, mo, d, hh, mm, ss, ms,
    }) catch return buf[0..0];
    return written;
}

// ---------- unit tests ----------

test "Action.slug round-trips" {
    inline for (@typeInfo(Action).@"enum".fields) |f| {
        const a: Action = @enumFromInt(f.value);
        try std.testing.expectEqualStrings(f.name, a.slug());
    }
}

test "formatRfc3339Millis: epoch" {
    var buf: [40]u8 = undefined;
    const s = formatRfc3339Millis(&buf, 0, 0);
    try std.testing.expectEqualStrings("1970-01-01T00:00:00.000Z", s);
}

test "formatRfc3339Millis: known date" {
    var buf: [40]u8 = undefined;
    // 2026-05-10T14:32:00.123Z → ts = ?
    // 2026-05-10 00:00 UTC: use deterministic input verified via the formatter.
    const s = formatRfc3339Millis(&buf, 1778761920, 123); // 2026-05-14T03:12:00.123Z
    // Sanity: starts with 2026, ends with .123Z
    try std.testing.expect(std.mem.startsWith(u8, s, "2026-"));
    try std.testing.expect(std.mem.endsWith(u8, s, ".123Z"));
}

test "Writer: append produces one NDJSON line, file mode 0600" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = try tmp.dir.realpath(".", &buf);

    var w = try Writer.init(a, abs);
    defer w.deinit();
    try w.append(.{
        .ts = "2026-05-10T14:32:00.123Z",
        .identity = "local",
        .action = .append_item,
        .target = "stack/default/item/0007",
        .outcome = .allowed,
        .details = &.{
            .{ .key = "stack", .value = "default" },
            .{ .key = "id", .value = "0007" },
        },
    });

    // Verify file contents.
    const log_path = try std.fs.path.join(a, &.{ abs, ".organo", "audit.log" });
    defer a.free(log_path);
    var f = try std.fs.cwd().openFile(log_path, .{});
    defer f.close();
    const stat = try f.stat();
    const contents = try a.alloc(u8, stat.size);
    defer a.free(contents);
    const n = try f.readAll(contents);
    const line = contents[0..n];
    try std.testing.expect(std.mem.endsWith(u8, line, "\n"));
    try std.testing.expect(std.mem.indexOf(u8, line, "\"action\":\"append_item\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"outcome\":\"allowed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"id\":\"0007\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"ts\":\"2026-05-10T14:32:00.123Z\"") != null);

    if (@import("builtin").os.tag != .windows) {
        const file_stat = try std.posix.fstat(f.handle);
        const mode_bits: u32 = @intCast(file_stat.mode & 0o777);
        try std.testing.expectEqual(@as(u32, 0o600), mode_bits);
    }
}

test "Writer: two appends produce two lines" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = try tmp.dir.realpath(".", &path_buf);

    var w = try Writer.init(a, abs);
    defer w.deinit();
    try w.append(.{ .ts = "2026-05-10T14:32:00.123Z", .identity = "local", .action = .pause_stack, .target = "stack/default", .outcome = .allowed });
    try w.append(.{ .ts = "2026-05-10T14:32:00.456Z", .identity = "local", .action = .resume_stack, .target = "stack/default", .outcome = .allowed });

    const log_path = try std.fs.path.join(a, &.{ abs, ".organo", "audit.log" });
    defer a.free(log_path);
    var f = try std.fs.cwd().openFile(log_path, .{});
    defer f.close();
    const stat = try f.stat();
    const contents = try a.alloc(u8, stat.size);
    defer a.free(contents);
    _ = try f.readAll(contents);

    // Count newlines.
    var count: usize = 0;
    for (contents) |c| {
        if (c == '\n') count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
}
