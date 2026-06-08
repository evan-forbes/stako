//! The append-only execution log, `events.jsonl`: one JSON object per line
//! recording what the runner did. It is audit history and the source for the
//! `running` part of computed status — never a second copy of the graph. This
//! module serializes and parses the line format; opening and appending to the
//! file under the stack root is the store's job (see `09_unified_authoring_model.md`).

const std = @import("std");

const log = std.log.scoped(.events);

pub const Kind = enum {
    runner_started,
    scheduled,
    delivered,
    completed,
    blocked,
    failed,
    injected,
    /// Operator cleared a node's run artifacts so it re-runs (see `stako reset`).
    /// Resets computed status back to queued, overriding earlier delivered/
    /// completed/failed events because it is the latest event for the node.
    reset,
    runner_stopped,
};

/// One logged event. Fields beyond `ts`/`event` are optional and only emitted
/// when set, so each event kind carries just what it needs. The same struct is
/// used for writing and for `std.json` parsing (missing keys fall back to the
/// defaults below).
pub const Event = struct {
    ts: []const u8 = "",
    event: Kind,
    node: []const u8 = "",
    thread: []const u8 = "",
    action: []const u8 = "",
    /// Path to the delivered bytes (`runs/<node>/rendered.md`).
    rendered: []const u8 = "",
    /// Path to the produced result (`runs/<node>/result.md`).
    result: []const u8 = "",
    /// Human-readable failure or status reason.
    reason: []const u8 = "",
    /// Input result paths rendered into a delivered prompt.
    inputs: []const []const u8 = &.{},
    pid: ?i64 = null,
    watch: ?bool = null,
};

/// Serialize one event as a single JSONL line (trailing newline included).
pub fn writeLine(w: *std.Io.Writer, ev: Event) std.Io.Writer.Error!void {
    try w.writeAll("{\"ts\":");
    try writeJsonString(w, ev.ts);
    try w.writeAll(",\"event\":\"");
    try w.writeAll(@tagName(ev.event));
    try w.writeByte('"');
    try writeOptStr(w, "node", ev.node);
    try writeOptStr(w, "thread", ev.thread);
    try writeOptStr(w, "action", ev.action);
    try writeOptStr(w, "rendered", ev.rendered);
    try writeOptStr(w, "result", ev.result);
    try writeOptStr(w, "reason", ev.reason);
    if (ev.inputs.len != 0) {
        try w.writeAll(",\"inputs\":[");
        for (ev.inputs, 0..) |inp, i| {
            if (i != 0) try w.writeByte(',');
            try writeJsonString(w, inp);
        }
        try w.writeByte(']');
    }
    if (ev.pid) |p| try w.print(",\"pid\":{d}", .{p});
    if (ev.watch) |b| try w.print(",\"watch\":{}", .{b});
    try w.writeAll("}\n");
}

/// Parse a whole `events.jsonl` body. Every returned slice points into `arena`,
/// so free it by resetting the arena. Blank lines are skipped. The only silently
/// tolerated corruption is a crash-truncated final line — the last segment of a
/// body that does not end in a newline, i.e. an append cut off mid-write. Any
/// *interior* line that fails to parse is real corruption that would skew status,
/// so it is logged with its line number (and skipped) rather than swallowed.
pub fn loadAlloc(arena: std.mem.Allocator, source: []const u8) error{OutOfMemory}![]Event {
    var list: std.ArrayList(Event) = .empty;
    const ends_with_newline = source.len == 0 or source[source.len - 1] == '\n';
    var line_no: usize = 0;
    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |line| {
        line_no += 1;
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        const ev = std.json.parseFromSliceLeaky(Event, arena, trimmed, .{ .ignore_unknown_fields = true }) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                const is_partial_tail = !ends_with_newline and it.peek() == null;
                if (!is_partial_tail) log.warn("skipping unparseable events.jsonl line {d}", .{line_no});
                continue;
            },
        };
        try list.append(arena, ev);
    }
    return list.toOwnedSlice(arena);
}

/// Format an RFC3339 UTC timestamp into `buf`, which must hold at least 20
/// bytes. Returns the written slice.
pub fn formatTimestamp(buf: []u8, epoch_secs: i64) []const u8 {
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(epoch_secs) };
    const year_day = es.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        @as(u16, month_day.day_index) + 1,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
        ds.getSecondsIntoMinute(),
    }) catch unreachable; // buf sized for the fixed-width format
}

/// Current wall-clock RFC3339 timestamp written into `buf` (>= 20 bytes).
pub fn now(buf: []u8) []const u8 {
    return formatTimestamp(buf, std.time.timestamp());
}

fn writeOptStr(w: *std.Io.Writer, key: []const u8, value: []const u8) std.Io.Writer.Error!void {
    if (value.len == 0) return;
    try w.writeByte(',');
    try writeJsonString(w, key);
    try w.writeByte(':');
    try writeJsonString(w, value);
}

fn writeJsonString(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        else => if (c < 0x20) try w.print("\\u{x:0>4}", .{c}) else try w.writeByte(c),
    };
    try w.writeByte('"');
}

// ---------- tests ----------

test "round-trip a delivered event through write and load" {
    const a = std.testing.allocator;
    var w: std.Io.Writer.Allocating = .init(a);
    defer w.deinit();

    try writeLine(&w.writer, .{
        .ts = "2026-06-04T12:00:01Z",
        .event = .delivered,
        .node = "impl-1",
        .thread = "impl",
        .action = "new",
        .rendered = "runs/impl-1/rendered.md",
        .inputs = &.{ "runs/a/result.md", "runs/b/result.md" },
    });

    const line = w.written();
    try std.testing.expect(std.mem.endsWith(u8, line, "}\n"));

    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const evs = try loadAlloc(arena.allocator(), line);
    try std.testing.expectEqual(@as(usize, 1), evs.len);
    try std.testing.expectEqual(Kind.delivered, evs[0].event);
    try std.testing.expectEqualStrings("impl-1", evs[0].node);
    try std.testing.expectEqualStrings("new", evs[0].action);
    try std.testing.expectEqual(@as(usize, 2), evs[0].inputs.len);
    try std.testing.expectEqualStrings("runs/b/result.md", evs[0].inputs[1]);
}

test "load skips blank lines and tolerates unknown fields" {
    const a = std.testing.allocator;
    const src =
        \\{"ts":"t","event":"runner_started","pid":42,"watch":true}
        \\
        \\{"ts":"t","event":"completed","node":"impl-1","result":"runs/impl-1/result.md","future":"x"}
        \\
    ;
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const evs = try loadAlloc(arena.allocator(), src);
    try std.testing.expectEqual(@as(usize, 2), evs.len);
    try std.testing.expectEqual(Kind.runner_started, evs[0].event);
    try std.testing.expectEqual(@as(i64, 42), evs[0].pid.?);
    try std.testing.expectEqual(true, evs[0].watch.?);
    try std.testing.expectEqual(Kind.completed, evs[1].event);
    try std.testing.expectEqualStrings("runs/impl-1/result.md", evs[1].result);
}

test "a crash-truncated final line is tolerated" {
    const a = std.testing.allocator;
    // No trailing newline: the last append was cut off mid-write by a crash.
    const src =
        "{\"ts\":\"t\",\"event\":\"delivered\",\"node\":\"n\"}\n" ++
        "{\"ts\":\"t\",\"event\":\"comp";
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const evs = try loadAlloc(arena.allocator(), src);
    try std.testing.expectEqual(@as(usize, 1), evs.len);
    try std.testing.expectEqual(Kind.delivered, evs[0].event);
}

test "interior corruption is skipped but surrounding events still load" {
    const a = std.testing.allocator;
    // The middle line is corrupt but newline-terminated, so it is interior
    // corruption (logged, not silent) and the later event must still load.
    const src =
        "{\"ts\":\"t\",\"event\":\"runner_started\"}\n" ++
        "{ this is not json\n" ++
        "{\"ts\":\"t\",\"event\":\"completed\",\"node\":\"n\",\"result\":\"runs/n/result.md\"}\n";
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const evs = try loadAlloc(arena.allocator(), src);
    try std.testing.expectEqual(@as(usize, 2), evs.len);
    try std.testing.expectEqual(Kind.runner_started, evs[0].event);
    try std.testing.expectEqual(Kind.completed, evs[1].event);
}

test "format a known timestamp" {
    var buf: [24]u8 = undefined;
    // 2021-01-01T00:00:00Z = 1609459200
    try std.testing.expectEqualStrings("2021-01-01T00:00:00Z", formatTimestamp(&buf, 1609459200));
}

test "json string escaping" {
    const a = std.testing.allocator;
    var w: std.Io.Writer.Allocating = .init(a);
    defer w.deinit();
    try writeLine(&w.writer, .{ .ts = "t", .event = .failed, .node = "n", .reason = "broke: \"x\"\nline" });
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const evs = try loadAlloc(arena.allocator(), w.written());
    try std.testing.expectEqualStrings("broke: \"x\"\nline", evs[0].reason);
}
