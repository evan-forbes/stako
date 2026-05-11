//! Per-item transcript JSONL writer (milestone 6).
//!
//! Each running item gets a `transcript.jsonl` next to its `meta.toml`.
//! The session manager opens one Writer per session, calls `append` for
//! each normalized event, then `close` on exit.
//!
//! v1: events are flushed (write+sync) per append so a crash mid-run leaves
//! a recoverable partial transcript. Writes are funneled through a single
//! mutex so SSE replay (in a later milestone) and direct file readers can
//! safely observe the file mid-run.

const std = @import("std");
const events = @import("events.zig");
const audit = @import("audit.zig");

pub const Writer = struct {
    allocator: std.mem.Allocator,
    file: std.fs.File,
    /// Absolute path on disk.
    path: []u8,
    mutex: std.Thread.Mutex = .{},

    pub fn init(
        allocator: std.mem.Allocator,
        item_dir_abs: []const u8,
    ) !Writer {
        std.fs.cwd().makePath(item_dir_abs) catch {};
        const path = try std.fs.path.join(allocator, &.{ item_dir_abs, "transcript.jsonl" });
        errdefer allocator.free(path);
        const f = try std.fs.cwd().createFile(path, .{
            .truncate = false,
            .read = false,
            .mode = 0o600,
        });
        f.seekFromEnd(0) catch {};
        return .{ .allocator = allocator, .file = f, .path = path };
    }

    pub fn deinit(self: *Writer) void {
        self.file.close();
        self.allocator.free(self.path);
    }

    /// Append one event. `ts_buf` must be ≥ 24 bytes; the writer fills it
    /// with `now` if `event.ts == null`.
    pub fn append(self: *Writer, event: events.Event) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var line = std.ArrayList(u8){};
        defer line.deinit(self.allocator);
        var ts_buf: [40]u8 = undefined;
        const ts_now = audit.nowRfc3339Millis(&ts_buf);
        try events.writeEvent(line.writer(self.allocator), event, ts_now);
        try self.file.writeAll(line.items);
        self.file.sync() catch {};
    }
};

// ---------- tests ----------

test "Writer: append + read back" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = try tmp.dir.realpath(".", &buf);
    const item_dir = try std.fs.path.join(a, &.{ abs, "0001-x" });
    defer a.free(item_dir);
    try std.fs.cwd().makePath(item_dir);

    var w = try Writer.init(a, item_dir);
    defer w.deinit();
    try w.append(.{
        .ts = "2026-05-10T14:00:00.000Z",
        .stack = "demo",
        .item = "0001",
        .kind = .session_started,
        .data_json = "{\"harness\":\"fake\"}",
    });
    try w.append(.{
        .ts = "2026-05-10T14:00:00.500Z",
        .stack = "demo",
        .item = "0001",
        .kind = .message,
        .data_json = "{\"text\":\"hi\"}",
    });

    // Read back.
    const t_path = try std.fs.path.join(a, &.{ item_dir, "transcript.jsonl" });
    defer a.free(t_path);
    var f = try std.fs.cwd().openFile(t_path, .{});
    defer f.close();
    const stat = try f.stat();
    const contents = try a.alloc(u8, stat.size);
    defer a.free(contents);
    _ = try f.readAll(contents);
    var nl_count: usize = 0;
    for (contents) |c| if (c == '\n') {
        nl_count += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), nl_count);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"kind\":\"session_started\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "\"kind\":\"message\"") != null);
}
