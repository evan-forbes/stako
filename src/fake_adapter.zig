//! Fake adapter (milestone 6).
//!
//! Used by milestone 6/7 tests to exercise the runtime without depending on
//! a real provider CLI. The adapter consumes JSONL lines on stdout where
//! each line is the `data` field of a single normalized event, prefixed by
//! a kind tag:
//!
//!     {"kind":"session_started","data":{"harness":"fake","model":"m"}}
//!     {"kind":"message","data":{"text":"hello","role":"assistant"}}
//!     {"kind":"turn_completed","data":{"turn":0}}
//!
//! That is, the fake adapter is the "no normalization needed" case: the
//! fixture file already speaks the normalized schema, minus the daemon-
//! supplied envelope fields (`v`, `ts`, `stack`, `item`, `session`).
//!
//! The scripted fake binary itself lives in
//! `test/helpers/fake_harness.zig` — it simply `cat`s the fixture JSONL to
//! stdout with optional sleeps and exit codes, plus a "ignore SIGINT" mode
//! for the cancellation-escalation tests.

const std = @import("std");
const adapter = @import("adapter.zig");
const adapter_json = @import("adapter_json.zig");
const events = @import("events.zig");

const stripEol = adapter_json.stripEol;
const findStringValue = adapter_json.findStringValue;
const findObjectValue = adapter_json.findObjectValue;
const jsonEscape = adapter_json.jsonEscape;

pub const State = struct {
    /// Most-recent session_id parsed from `session_started.data.session`.
    session_id: []u8 = "",
    /// Whether session_started has been emitted yet.
    seen_session_start: bool = false,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        if (self.session_id.len > 0) allocator.free(self.session_id);
    }
};

pub fn create(allocator: std.mem.Allocator) !adapter.Adapter {
    const st = try allocator.create(State);
    st.* = .{};
    return .{
        .name = "fake",
        .impl = @ptrCast(st),
        .vtable = &vtable,
    };
}

const vtable: adapter.Adapter.VTable = .{
    .parse_line = parseLine,
    .parse_stderr_line = parseStderrLine,
    .on_exit = onExit,
    .supports = supports,
    .deinit = deinitFn,
};

fn parseLine(impl: *anyopaque, allocator: std.mem.Allocator, raw: []const u8) anyerror![]adapter.OwnedEvent {
    const st: *State = @ptrCast(@alignCast(impl));
    const line = stripEol(raw);
    if (line.len == 0) return allocator.alloc(adapter.OwnedEvent, 0);

    // Extract `kind` (string) and `data` (object substring) directly from
    // the raw line. Avoids depending on Stringify writer API stability.
    const kind_str = findStringValue(line, "\"kind\":") orelse return emitError(allocator, "adapter_parse_error");
    const kind = events.Kind.fromString(kind_str) orelse return emitError(allocator, "adapter_parse_error");
    const data_substr: []const u8 = findObjectValue(line, "\"data\":") orelse "{}";
    const storage = try allocator.dupe(u8, data_substr);

    // Pull session id from `session_started.data.session` so subsequent
    // events can carry it.
    if (kind == .session_started) {
        if (findStringValue(data_substr, "\"session\":")) |sid| {
            if (st.session_id.len > 0) allocator.free(st.session_id);
            st.session_id = try allocator.dupe(u8, sid);
        }
        st.seen_session_start = true;
    }

    const arr = try allocator.alloc(adapter.OwnedEvent, 1);
    arr[0] = .{
        .ev = .{
            .stack = "",
            .item = "",
            .session = st.session_id,
            .kind = kind,
            .data_json = storage,
        },
        .storage = storage,
    };
    return arr;
}

fn parseStderrLine(impl: *anyopaque, allocator: std.mem.Allocator, raw: []const u8) anyerror![]adapter.OwnedEvent {
    const st: *State = @ptrCast(@alignCast(impl));
    const line = stripEol(raw);
    if (line.len == 0) return allocator.alloc(adapter.OwnedEvent, 0);
    // Wrap as a non-terminal error event. Attach the captured session id so
    // the event is self-describing even before session_manager rewrites the
    // envelope — keeps the adapter contract consistent with parseLine.
    var buf = std.ArrayList(u8){};
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try w.writeAll("{\"message\":\"");
    try jsonEscape(w, line);
    try w.writeAll("\",\"recoverable\":true}");
    const storage = try buf.toOwnedSlice(allocator);
    const arr = try allocator.alloc(adapter.OwnedEvent, 1);
    arr[0] = .{
        .ev = .{
            .stack = "",
            .item = "",
            .session = st.session_id,
            .kind = .@"error",
            .data_json = storage,
        },
        .storage = storage,
    };
    return arr;
}

fn onExit(impl: *anyopaque, allocator: std.mem.Allocator, exit_code: i32, ran_to_completion: bool) anyerror!adapter.OwnedEvent {
    const st: *State = @ptrCast(@alignCast(impl));
    var buf = std.ArrayList(u8){};
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);
    const terminal: events.TerminalStatus = blk: {
        if (!ran_to_completion) break :blk .canceled;
        if (exit_code == 0) break :blk .completed;
        break :blk .failed;
    };
    try w.print("{{\"exit_code\":{d},\"terminal_status\":\"{s}\"}}", .{ exit_code, terminal.toString() });
    const storage = try buf.toOwnedSlice(allocator);
    return .{
        .ev = .{
            .stack = "",
            .item = "",
            .session = st.session_id,
            .kind = .session_ended,
            .data_json = storage,
        },
        .storage = storage,
    };
}

fn supports(impl: *anyopaque, cap: adapter.Capability) bool {
    _ = impl;
    return switch (cap) {
        .@"resume" => true,
        .compact => false,
        .clear => true,
        .partial_messages => true,
        .file_change_events => true,
    };
}

fn deinitFn(impl: *anyopaque, allocator: std.mem.Allocator) void {
    const st: *State = @ptrCast(@alignCast(impl));
    st.deinit(allocator);
    allocator.destroy(st);
}

fn emitError(allocator: std.mem.Allocator, slug: []const u8) ![]adapter.OwnedEvent {
    var buf = std.ArrayList(u8){};
    errdefer buf.deinit(allocator);
    try buf.writer(allocator).print("{{\"message\":\"{s}\",\"recoverable\":false}}", .{slug});
    const storage = try buf.toOwnedSlice(allocator);
    const arr = try allocator.alloc(adapter.OwnedEvent, 1);
    arr[0] = .{
        .ev = .{
            .stack = "",
            .item = "",
            .kind = .@"error",
            .data_json = storage,
        },
        .storage = storage,
    };
    return arr;
}

// ---------- tests ----------

test "parseLine: session_started then message" {
    const a = std.testing.allocator;
    var ad = try create(a);
    defer ad.deinit(a);

    const evs1 = try ad.parseLine(a, "{\"kind\":\"session_started\",\"data\":{\"harness\":\"fake\",\"model\":\"m\",\"session\":\"sess-1\"}}\n");
    defer adapter.freeOwnedSlice(a, evs1);
    try std.testing.expectEqual(@as(usize, 1), evs1.len);
    try std.testing.expectEqual(events.Kind.session_started, evs1[0].ev.kind);
    try std.testing.expect(std.mem.indexOf(u8, evs1[0].ev.data_json, "\"session\":\"sess-1\"") != null);

    const evs2 = try ad.parseLine(a, "{\"kind\":\"message\",\"data\":{\"text\":\"hello\",\"role\":\"assistant\"}}\n");
    defer adapter.freeOwnedSlice(a, evs2);
    try std.testing.expectEqual(events.Kind.message, evs2[0].ev.kind);
    // Subsequent event carries the captured session_id.
    try std.testing.expectEqualStrings("sess-1", evs2[0].ev.session);
}

test "parseLine: malformed yields an error event" {
    const a = std.testing.allocator;
    var ad = try create(a);
    defer ad.deinit(a);

    const evs = try ad.parseLine(a, "not json\n");
    defer adapter.freeOwnedSlice(a, evs);
    try std.testing.expectEqual(@as(usize, 1), evs.len);
    try std.testing.expectEqual(events.Kind.@"error", evs[0].ev.kind);
}

test "onExit: success -> session_ended.completed" {
    const a = std.testing.allocator;
    var ad = try create(a);
    defer ad.deinit(a);
    const ev = try ad.onExit(a, 0, true);
    defer adapter.freeOwned(a, ev);
    try std.testing.expectEqual(events.Kind.session_ended, ev.ev.kind);
    try std.testing.expect(std.mem.indexOf(u8, ev.ev.data_json, "\"terminal_status\":\"completed\"") != null);
}

test "onExit: non-zero exit -> failed" {
    const a = std.testing.allocator;
    var ad = try create(a);
    defer ad.deinit(a);
    const ev = try ad.onExit(a, 2, true);
    defer adapter.freeOwned(a, ev);
    try std.testing.expect(std.mem.indexOf(u8, ev.ev.data_json, "\"terminal_status\":\"failed\"") != null);
}

test "onExit: not ran_to_completion -> canceled" {
    const a = std.testing.allocator;
    var ad = try create(a);
    defer ad.deinit(a);
    const ev = try ad.onExit(a, 130, false);
    defer adapter.freeOwned(a, ev);
    try std.testing.expect(std.mem.indexOf(u8, ev.ev.data_json, "\"terminal_status\":\"canceled\"") != null);
}
