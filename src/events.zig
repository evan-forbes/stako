//! Normalized event schema (milestone 6).
//!
//! All harness adapters convert provider-specific events into this schema.
//! The daemon emits exactly this schema both to per-item `transcript.jsonl`
//! files and to SSE subscribers. See `todos/design_execution_harness.md` for
//! the canonical schema definition.
//!
//! Each event line on the wire is a single JSON object with the top-level
//! shape:
//!
//!     {"v":1,"ts":"...","stack":"...","item":"...","session":"...","kind":"...","data":{...}}
//!
//! `session` may be empty when no session id is yet known (e.g. the very
//! first `session_started` event for some adapters).

const std = @import("std");
const errors_mod = @import("errors.zig");

/// Stable event-kind vocabulary. New kinds may be added; existing kinds
/// never change meaning.
pub const Kind = enum {
    session_started,
    turn_started,
    message_chunk,
    message,
    tool_call,
    tool_result,
    file_changed,
    command_executed,
    turn_completed,
    @"error",
    session_ended,

    pub fn toString(self: Kind) []const u8 {
        return switch (self) {
            .session_started => "session_started",
            .turn_started => "turn_started",
            .message_chunk => "message_chunk",
            .message => "message",
            .tool_call => "tool_call",
            .tool_result => "tool_result",
            .file_changed => "file_changed",
            .command_executed => "command_executed",
            .turn_completed => "turn_completed",
            .@"error" => "error",
            .session_ended => "session_ended",
        };
    }

    pub fn fromString(s: []const u8) ?Kind {
        const map = .{
            .{ "session_started", Kind.session_started },
            .{ "turn_started", Kind.turn_started },
            .{ "message_chunk", Kind.message_chunk },
            .{ "message", Kind.message },
            .{ "tool_call", Kind.tool_call },
            .{ "tool_result", Kind.tool_result },
            .{ "file_changed", Kind.file_changed },
            .{ "command_executed", Kind.command_executed },
            .{ "turn_completed", Kind.turn_completed },
            .{ "error", Kind.@"error" },
            .{ "session_ended", Kind.session_ended },
        };
        inline for (map) |pair| {
            if (std.mem.eql(u8, s, pair[0])) return pair[1];
        }
        return null;
    }
};

/// Terminal status reported in `session_ended.data.terminal_status`.
pub const TerminalStatus = enum {
    completed,
    failed,
    canceled,

    pub fn toString(self: TerminalStatus) []const u8 {
        return switch (self) {
            .completed => "completed",
            .failed => "failed",
            .canceled => "canceled",
        };
    }
};

/// A pre-serialized event. The adapter constructs an `Event` and hands it to
/// the session manager, which writes it both to disk and to live subscribers.
/// `data_json` is the already-formatted JSON object literal (with the
/// surrounding braces) — adapters serialize once and reuse the bytes.
pub const Event = struct {
    /// RFC 3339 UTC, millisecond precision. Filled by the session manager
    /// at emit time if left null by the adapter.
    ts: ?[]const u8 = null,
    stack: []const u8,
    item: []const u8,
    /// Harness-side session ID; empty for pre-init events.
    session: []const u8 = "",
    kind: Kind,
    /// Pre-serialized JSON object literal, including braces. May be `"{}"`.
    data_json: []const u8 = "{}",
};

/// Serialize an `Event` to `w`. Writes one JSON object terminated by '\n'.
/// `ts_now` is used when `event.ts == null`; pass `null` if you want the
/// caller to fill it in.
pub fn writeEvent(w: anytype, event: Event, ts_now: ?[]const u8) !void {
    try w.writeAll("{\"v\":1,\"ts\":\"");
    if (event.ts) |s| {
        try errors_mod.writeJsonString(w, s);
    } else if (ts_now) |s| {
        try errors_mod.writeJsonString(w, s);
    } else {
        try w.writeAll("");
    }
    try w.writeAll("\",\"stack\":\"");
    try errors_mod.writeJsonString(w, event.stack);
    try w.writeAll("\",\"item\":\"");
    try errors_mod.writeJsonString(w, event.item);
    try w.writeAll("\",\"session\":\"");
    try errors_mod.writeJsonString(w, event.session);
    try w.writeAll("\",\"kind\":\"");
    try w.writeAll(event.kind.toString());
    try w.writeAll("\",\"data\":");
    if (event.data_json.len == 0) {
        try w.writeAll("{}");
    } else {
        try w.writeAll(event.data_json);
    }
    try w.writeAll("}\n");
}

/// Parsed-form of an Event, used by tests and by SSE clients that want to
/// inspect rather than relay.
pub const ParsedEvent = struct {
    v: u32,
    ts: []const u8,
    stack: []const u8,
    item: []const u8,
    session: []const u8,
    kind: Kind,
    /// JSON object (with braces) for the `data` field.
    data_json: []const u8,
};

/// Best-effort parse of one serialized event line. Borrows from `line` —
/// no allocation. Trailing '\n' is tolerated.
pub fn parseEvent(line: []const u8) ?ParsedEvent {
    var src = line;
    if (src.len > 0 and src[src.len - 1] == '\n') src = src[0 .. src.len - 1];
    if (src.len < 2 or src[0] != '{') return null;

    var v: u32 = 0;
    var ts: []const u8 = "";
    var stack_s: []const u8 = "";
    var item_s: []const u8 = "";
    var session_s: []const u8 = "";
    var kind_s: []const u8 = "";
    var data_json: []const u8 = "{}";

    // Naive field scanner: locate each key by prefix and parse the value
    // accordingly. Adequate for our well-formed canonical output.
    if (findStringField(src, "\"ts\":")) |s| ts = s;
    if (findStringField(src, "\"stack\":")) |s| stack_s = s;
    if (findStringField(src, "\"item\":")) |s| item_s = s;
    if (findStringField(src, "\"session\":")) |s| session_s = s;
    if (findStringField(src, "\"kind\":")) |s| kind_s = s;
    if (findIntField(src, "\"v\":")) |n| v = @intCast(n);
    if (findObjectField(src, "\"data\":")) |s| data_json = s;

    const kind = Kind.fromString(kind_s) orelse return null;
    return .{
        .v = v,
        .ts = ts,
        .stack = stack_s,
        .item = item_s,
        .session = session_s,
        .kind = kind,
        .data_json = data_json,
    };
}

fn findStringField(src: []const u8, key_with_colon: []const u8) ?[]const u8 {
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

fn findIntField(src: []const u8, key_with_colon: []const u8) ?i64 {
    const idx = std.mem.indexOf(u8, src, key_with_colon) orelse return null;
    var i = idx + key_with_colon.len;
    while (i < src.len and (src[i] == ' ' or src[i] == '\t')) i += 1;
    const start = i;
    while (i < src.len and (std.ascii.isDigit(src[i]) or src[i] == '-')) i += 1;
    return std.fmt.parseInt(i64, src[start..i], 10) catch null;
}

fn findObjectField(src: []const u8, key_with_colon: []const u8) ?[]const u8 {
    const idx = std.mem.indexOf(u8, src, key_with_colon) orelse return null;
    var i = idx + key_with_colon.len;
    while (i < src.len and (src[i] == ' ' or src[i] == '\t')) i += 1;
    if (i >= src.len or src[i] != '{') return null;
    var depth: usize = 0;
    const start = i;
    var in_str = false;
    var escape = false;
    while (i < src.len) : (i += 1) {
        const c = src[i];
        if (escape) {
            escape = false;
            continue;
        }
        if (in_str) {
            if (c == '\\') {
                escape = true;
            } else if (c == '"') {
                in_str = false;
            }
            continue;
        }
        if (c == '"') {
            in_str = true;
            continue;
        }
        if (c == '{') depth += 1;
        if (c == '}') {
            depth -= 1;
            if (depth == 0) return src[start .. i + 1];
        }
    }
    return null;
}

// ---------- tests ----------

test "Kind: round-trip" {
    inline for (@typeInfo(Kind).@"enum".fields) |f| {
        const k: Kind = @enumFromInt(f.value);
        const s = k.toString();
        try std.testing.expectEqual(k, Kind.fromString(s).?);
    }
}

test "writeEvent: minimal session_started" {
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeEvent(&w, .{
        .ts = "2026-05-10T14:32:00.123Z",
        .stack = "smoke",
        .item = "0001",
        .session = "abc-123",
        .kind = .session_started,
        .data_json = "{\"harness\":\"claude\",\"model\":\"claude-opus-4-7\"}",
    }, null);
    const got = buf[0..w.end];
    try std.testing.expectEqualStrings(
        "{\"v\":1,\"ts\":\"2026-05-10T14:32:00.123Z\",\"stack\":\"smoke\",\"item\":\"0001\",\"session\":\"abc-123\",\"kind\":\"session_started\",\"data\":{\"harness\":\"claude\",\"model\":\"claude-opus-4-7\"}}\n",
        got,
    );
}

test "parseEvent: round-trip" {
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeEvent(&w, .{
        .ts = "2026-05-10T14:32:00.500Z",
        .stack = "demo",
        .item = "0042",
        .session = "sess-9",
        .kind = .message,
        .data_json = "{\"text\":\"hello\",\"role\":\"assistant\"}",
    }, null);
    const got = buf[0..w.end];
    const p = parseEvent(got) orelse return error.ParseFailed;
    try std.testing.expectEqual(@as(u32, 1), p.v);
    try std.testing.expectEqualStrings("2026-05-10T14:32:00.500Z", p.ts);
    try std.testing.expectEqualStrings("demo", p.stack);
    try std.testing.expectEqualStrings("0042", p.item);
    try std.testing.expectEqualStrings("sess-9", p.session);
    try std.testing.expectEqual(Kind.message, p.kind);
    try std.testing.expectEqualStrings("{\"text\":\"hello\",\"role\":\"assistant\"}", p.data_json);
}

test "parseEvent: nested object in data" {
    const line = "{\"v\":1,\"ts\":\"2026-05-10T14:00:00.000Z\",\"stack\":\"s\",\"item\":\"0001\",\"session\":\"\",\"kind\":\"tool_call\",\"data\":{\"tool\":\"Bash\",\"args\":{\"cmd\":\"echo hi\"},\"call_id\":\"x1\"}}\n";
    const p = parseEvent(line) orelse return error.ParseFailed;
    try std.testing.expectEqual(Kind.tool_call, p.kind);
    try std.testing.expectEqualStrings(
        "{\"tool\":\"Bash\",\"args\":{\"cmd\":\"echo hi\"},\"call_id\":\"x1\"}",
        p.data_json,
    );
}

test "parseEvent: invalid kind returns null" {
    const line = "{\"v\":1,\"ts\":\"x\",\"stack\":\"s\",\"item\":\"i\",\"session\":\"\",\"kind\":\"unknown\",\"data\":{}}\n";
    try std.testing.expect(parseEvent(line) == null);
}
