//! Codex CLI adapter (milestone 7).
//!
//! Parses the JSONL emitted by `codex exec --json <prompt>` and maps each
//! event onto stako's normalized event schema (see `events.zig`).
//!
//! Mapping table (codex → normalized):
//!
//!   {"type":"thread.started","thread_id":"..."}                  → session_started
//!   {"type":"turn.started"}                                      → turn_started
//!   {"type":"item.completed","item":{"item_type":"agent_message",
//!        "text":"..."}}                                          → message
//!   {"type":"item.completed","item":{"item_type":"reasoning",
//!        "text":"..."}}                                          → message (role=reasoning)
//!   {"type":"item.completed","item":{"item_type":"command_execution",
//!        "command":"...","exit_code":N}}                          → tool_call + command_executed
//!   {"type":"item.completed","item":{"item_type":"file_change",
//!        "changes":[{"path":"...","kind":"create|update|delete"}]}}
//!                                                                → tool_call + file_changed (per change)
//!   {"type":"turn.completed","usage":{...}}                      → turn_completed
//!   {"type":"turn.failed","error":{"message":"..."}}              → error (non-recoverable)
//!   {"type":"error","message":"..."}                             → error (recoverable)
//!   {"type":"thread.error","message":"..."}                      → error (recoverable)
//!   any unknown line                                             → error (recoverable)
//!
//! On exit, `session_ended` carries the captured Codex thread_id as
//! `session_id`. The native Codex rollout file path can be set externally
//! (the CLI doesn't print it; M8 may emit it via a status probe).

const std = @import("std");
const adapter = @import("adapter.zig");
const adapter_json = @import("adapter_json.zig");
const events = @import("events.zig");

const stripEol = adapter_json.stripEol;
const findStringValue = adapter_json.findStringValue;
const findTopLevelStringValue = adapter_json.findTopLevelStringValue;
const findIntValue = adapter_json.findIntValue;
const findObjectValue = adapter_json.findObjectValue;
const findArrayValue = adapter_json.findArrayValue;
const findMatchingBraceEnd = adapter_json.findMatchingBraceEnd;
const jsonEscape = adapter_json.jsonEscape;
const writeParsedJsonStringContent = adapter_json.writeParsedJsonStringContent;

pub const State = struct {
    session_id: []u8 = "",
    model: []u8 = "",
    session_file: []u8 = "",
    turn_index: u32 = 0,
    seen_thread_started: bool = false,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        if (self.session_id.len > 0) allocator.free(self.session_id);
        if (self.model.len > 0) allocator.free(self.model);
        if (self.session_file.len > 0) allocator.free(self.session_file);
    }
};

const CodexEventType = enum {
    thread_started,
    turn_started,
    turn_completed,
    turn_failed,
    @"error",
    thread_error,
    item_started,
    item_completed,
    item_updated,
    unknown,

    fn fromString(s: []const u8) CodexEventType {
        if (std.mem.eql(u8, s, "thread.started")) return .thread_started;
        if (std.mem.eql(u8, s, "turn.started")) return .turn_started;
        if (std.mem.eql(u8, s, "turn.completed")) return .turn_completed;
        if (std.mem.eql(u8, s, "turn.failed")) return .turn_failed;
        if (std.mem.eql(u8, s, "error")) return .@"error";
        if (std.mem.eql(u8, s, "thread.error")) return .thread_error;
        if (std.mem.eql(u8, s, "item.started")) return .item_started;
        if (std.mem.eql(u8, s, "item.completed")) return .item_completed;
        if (std.mem.eql(u8, s, "item.updated")) return .item_updated;
        return .unknown;
    }
};

const CodexItemType = enum {
    agent_message,
    reasoning,
    command_execution,
    file_change,
    unknown,

    fn fromString(s: []const u8) CodexItemType {
        if (std.mem.eql(u8, s, "agent_message")) return .agent_message;
        if (std.mem.eql(u8, s, "reasoning")) return .reasoning;
        if (std.mem.eql(u8, s, "command_execution")) return .command_execution;
        if (std.mem.eql(u8, s, "file_change")) return .file_change;
        return .unknown;
    }
};

pub fn create(allocator: std.mem.Allocator) !adapter.Adapter {
    const st = try allocator.create(State);
    st.* = .{};
    return .{
        .name = "codex",
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

fn deinitFn(impl: *anyopaque, allocator: std.mem.Allocator) void {
    const st: *State = @ptrCast(@alignCast(impl));
    st.deinit(allocator);
    allocator.destroy(st);
}

fn supports(impl: *anyopaque, cap: adapter.Capability) bool {
    _ = impl;
    return switch (cap) {
        .@"resume" => true,
        .compact => false,
        .clear => false,
        .partial_messages => false,
        .file_change_events => true,
    };
}

fn parseStderrLine(impl: *anyopaque, allocator: std.mem.Allocator, raw: []const u8) anyerror![]adapter.OwnedEvent {
    _ = impl;
    const line = stripEol(raw);
    if (line.len == 0) return allocator.alloc(adapter.OwnedEvent, 0);
    if (std.mem.eql(u8, line, "Reading additional input from stdin...")) {
        return allocator.alloc(adapter.OwnedEvent, 0);
    }
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
    try w.writeAll("{\"exit_code\":");
    try w.print("{d}", .{exit_code});
    try w.writeAll(",\"terminal_status\":\"");
    try w.writeAll(terminal.toString());
    try w.writeAll("\"");
    if (st.session_id.len > 0) {
        try w.writeAll(",\"session_id\":\"");
        try writeParsedJsonStringContent(w, st.session_id);
        try w.writeAll("\"");
    }
    if (st.session_file.len > 0) {
        try w.writeAll(",\"session_file\":\"");
        try writeParsedJsonStringContent(w, st.session_file);
        try w.writeAll("\"");
    }
    if (st.model.len > 0) {
        try w.writeAll(",\"model\":\"");
        try writeParsedJsonStringContent(w, st.model);
        try w.writeAll("\"");
    }
    try w.writeAll("}");
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

fn parseLine(impl: *anyopaque, allocator: std.mem.Allocator, raw: []const u8) anyerror![]adapter.OwnedEvent {
    const st: *State = @ptrCast(@alignCast(impl));
    const line = stripEol(raw);
    if (line.len == 0) return allocator.alloc(adapter.OwnedEvent, 0);

    const type_str = findTopLevelStringValue(line, "\"type\":") orelse return emitErrorList(allocator, "adapter_parse_error", true);

    var out = std.ArrayList(adapter.OwnedEvent){};
    errdefer {
        for (out.items) |oe| adapter.freeOwned(allocator, oe);
        out.deinit(allocator);
    }

    switch (CodexEventType.fromString(type_str)) {
        .thread_started => {
            if (findStringValue(line, "\"thread_id\":")) |tid| {
                if (st.session_id.len > 0) allocator.free(st.session_id);
                st.session_id = try allocator.dupe(u8, tid);
            }
            if (findStringValue(line, "\"model\":")) |m| {
                if (st.model.len > 0) allocator.free(st.model);
                st.model = try allocator.dupe(u8, m);
            }
            if (findStringValue(line, "\"session_file\":")) |sf| {
                if (st.session_file.len > 0) allocator.free(st.session_file);
                st.session_file = try allocator.dupe(u8, sf);
            }
            if (!st.seen_thread_started) {
                st.seen_thread_started = true;
                try emitSessionStarted(allocator, &out, st);
            }
        },
        .turn_started => {
            try emitTurnStarted(allocator, &out, st);
            st.turn_index += 1;
        },
        .turn_completed => try emitTurnCompleted(allocator, &out, st),
        .turn_failed => {
            const msg = findStringValue(findObjectValue(line, "\"error\":") orelse "{}", "\"message\":") orelse "turn_failed";
            try emitError(allocator, &out, msg, false);
        },
        .@"error", .thread_error => {
            const msg = findStringValue(line, "\"message\":") orelse "error";
            try emitError(allocator, &out, msg, true);
        },
        .item_started => {},
        .item_completed, .item_updated => {
            const item = findObjectValue(line, "\"item\":") orelse {
                return out.toOwnedSlice(allocator);
            };
            switch (CodexItemType.fromString(findStringValue(item, "\"item_type\":") orelse "")) {
                .agent_message => {
                    const text = findStringValue(item, "\"text\":") orelse "";
                    try emitMessage(allocator, &out, text, "assistant");
                },
                .reasoning => {
                    const text = findStringValue(item, "\"text\":") orelse "";
                    try emitMessage(allocator, &out, text, "reasoning");
                },
                .command_execution => {
                    const cmd = findStringValue(item, "\"command\":") orelse "";
                    const exit_code = findIntValue(item, "\"exit_code\":") orelse 0;
                    const call_id = findStringValue(item, "\"id\":") orelse "";
                    var argbuf = std.ArrayList(u8){};
                    defer argbuf.deinit(allocator);
                    try argbuf.writer(allocator).writeAll("{\"command\":\"");
                    try writeParsedJsonStringContent(argbuf.writer(allocator), cmd);
                    try argbuf.writer(allocator).writeAll("\"}");
                    try emitToolCall(allocator, &out, "command_execution", argbuf.items, call_id);
                    try emitCommandExecuted(allocator, &out, cmd, @intCast(exit_code));
                },
                .file_change => {
                    const call_id = findStringValue(item, "\"id\":") orelse "";
                    try emitToolCall(allocator, &out, "file_change", "{}", call_id);
                    if (findArrayValue(item, "\"changes\":")) |arr| {
                        try emitFileChangesFromArray(allocator, &out, arr);
                    } else if (findStringValue(item, "\"path\":")) |p| {
                        const kind = findStringValue(item, "\"kind\":") orelse "modify";
                        try emitFileChanged(allocator, &out, p, mapCodexFileKind(kind));
                    }
                },
                .unknown => {},
            }
        },
        .unknown => try emitUnknownEvent(allocator, &out, type_str),
    }

    return out.toOwnedSlice(allocator);
}

fn mapCodexFileKind(k: []const u8) []const u8 {
    if (std.mem.eql(u8, k, "create") or std.mem.eql(u8, k, "add")) return "create";
    if (std.mem.eql(u8, k, "delete") or std.mem.eql(u8, k, "remove")) return "delete";
    return "modify";
}

fn emitFileChangesFromArray(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(adapter.OwnedEvent),
    arr_with_brackets: []const u8,
) !void {
    if (arr_with_brackets.len == 0 or arr_with_brackets[0] != '[') return;
    var i: usize = 1;
    while (i < arr_with_brackets.len) {
        while (i < arr_with_brackets.len and (arr_with_brackets[i] == ' ' or arr_with_brackets[i] == ',' or arr_with_brackets[i] == '\t' or arr_with_brackets[i] == '\n')) i += 1;
        if (i >= arr_with_brackets.len or arr_with_brackets[i] == ']') break;
        if (arr_with_brackets[i] != '{') {
            i += 1;
            continue;
        }
        const obj_start = i;
        const obj_end = findMatchingBraceEnd(arr_with_brackets, obj_start) orelse break;
        const obj = arr_with_brackets[obj_start..obj_end];
        const path = findStringValue(obj, "\"path\":") orelse "";
        const kind = findStringValue(obj, "\"kind\":") orelse "modify";
        try emitFileChanged(allocator, out, path, mapCodexFileKind(kind));
        i = obj_end;
    }
}

fn emitSessionStarted(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(adapter.OwnedEvent),
    st: *State,
) !void {
    var buf = std.ArrayList(u8){};
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try w.writeAll("{\"harness\":\"codex\"");
    if (st.model.len > 0) {
        try w.writeAll(",\"model\":\"");
        try writeParsedJsonStringContent(w, st.model);
        try w.writeAll("\"");
    }
    if (st.session_id.len > 0) {
        try w.writeAll(",\"session\":\"");
        try writeParsedJsonStringContent(w, st.session_id);
        try w.writeAll("\"");
    }
    try w.writeAll("}");
    const storage = try buf.toOwnedSlice(allocator);
    try out.append(allocator, .{
        .ev = .{
            .stack = "",
            .item = "",
            .session = st.session_id,
            .kind = .session_started,
            .data_json = storage,
        },
        .storage = storage,
    });
}

fn emitTurnStarted(allocator: std.mem.Allocator, out: *std.ArrayList(adapter.OwnedEvent), st: *State) !void {
    var buf = std.ArrayList(u8){};
    errdefer buf.deinit(allocator);
    try buf.writer(allocator).print("{{\"turn\":{d}}}", .{st.turn_index});
    const storage = try buf.toOwnedSlice(allocator);
    try out.append(allocator, .{
        .ev = .{
            .stack = "",
            .item = "",
            .session = st.session_id,
            .kind = .turn_started,
            .data_json = storage,
        },
        .storage = storage,
    });
}

fn emitTurnCompleted(allocator: std.mem.Allocator, out: *std.ArrayList(adapter.OwnedEvent), st: *State) !void {
    var buf = std.ArrayList(u8){};
    errdefer buf.deinit(allocator);
    const turn_idx: u32 = if (st.turn_index == 0) 0 else st.turn_index - 1;
    try buf.writer(allocator).print("{{\"turn\":{d},\"usage\":{{}}}}", .{turn_idx});
    const storage = try buf.toOwnedSlice(allocator);
    try out.append(allocator, .{
        .ev = .{
            .stack = "",
            .item = "",
            .session = st.session_id,
            .kind = .turn_completed,
            .data_json = storage,
        },
        .storage = storage,
    });
}

fn emitMessage(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(adapter.OwnedEvent),
    text: []const u8,
    role: []const u8,
) !void {
    var buf = std.ArrayList(u8){};
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try w.writeAll("{\"text\":\"");
    try writeParsedJsonStringContent(w, text);
    try w.writeAll("\",\"role\":\"");
    try w.writeAll(role);
    try w.writeAll("\"}");
    const storage = try buf.toOwnedSlice(allocator);
    try out.append(allocator, .{
        .ev = .{
            .stack = "",
            .item = "",
            .kind = .message,
            .data_json = storage,
        },
        .storage = storage,
    });
}

fn emitToolCall(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(adapter.OwnedEvent),
    tool: []const u8,
    args_obj_with_braces: []const u8,
    call_id: []const u8,
) !void {
    var buf = std.ArrayList(u8){};
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try w.writeAll("{\"tool\":\"");
    try writeParsedJsonStringContent(w, tool);
    try w.writeAll("\",\"args\":");
    if (args_obj_with_braces.len == 0) try w.writeAll("{}") else try w.writeAll(args_obj_with_braces);
    try w.writeAll(",\"call_id\":\"");
    try writeParsedJsonStringContent(w, call_id);
    try w.writeAll("\"}");
    const storage = try buf.toOwnedSlice(allocator);
    try out.append(allocator, .{
        .ev = .{
            .stack = "",
            .item = "",
            .kind = .tool_call,
            .data_json = storage,
        },
        .storage = storage,
    });
}

fn emitFileChanged(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(adapter.OwnedEvent),
    path: []const u8,
    op: []const u8,
) !void {
    var buf = std.ArrayList(u8){};
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try w.writeAll("{\"path\":\"");
    try writeParsedJsonStringContent(w, path);
    try w.writeAll("\",\"op\":\"");
    try jsonEscape(w, op);
    try w.writeAll("\",\"bytes\":0}");
    const storage = try buf.toOwnedSlice(allocator);
    try out.append(allocator, .{
        .ev = .{
            .stack = "",
            .item = "",
            .kind = .file_changed,
            .data_json = storage,
        },
        .storage = storage,
    });
}

fn emitCommandExecuted(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(adapter.OwnedEvent),
    cmd: []const u8,
    exit_code: i32,
) !void {
    var buf = std.ArrayList(u8){};
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try w.writeAll("{\"cmd\":\"");
    try writeParsedJsonStringContent(w, cmd);
    try w.writeAll("\",\"exit\":");
    try w.print("{d}", .{exit_code});
    try w.writeAll(",\"stdout_truncated\":false,\"stderr_truncated\":false}");
    const storage = try buf.toOwnedSlice(allocator);
    try out.append(allocator, .{
        .ev = .{
            .stack = "",
            .item = "",
            .kind = .command_executed,
            .data_json = storage,
        },
        .storage = storage,
    });
}

fn emitError(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(adapter.OwnedEvent),
    msg: []const u8,
    recoverable: bool,
) !void {
    var buf = std.ArrayList(u8){};
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try w.writeAll("{\"message\":\"");
    try writeParsedJsonStringContent(w, msg);
    try w.writeAll("\",\"recoverable\":");
    try w.writeAll(if (recoverable) "true" else "false");
    try w.writeAll("}");
    const storage = try buf.toOwnedSlice(allocator);
    try out.append(allocator, .{
        .ev = .{
            .stack = "",
            .item = "",
            .kind = .@"error",
            .data_json = storage,
        },
        .storage = storage,
    });
}

fn emitUnknownEvent(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(adapter.OwnedEvent),
    type_str: []const u8,
) !void {
    var buf = std.ArrayList(u8){};
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try w.writeAll("{\"message\":\"adapter_unknown_event\",\"event_type\":\"");
    try writeParsedJsonStringContent(w, type_str);
    try w.writeAll("\",\"recoverable\":true}");
    const storage = try buf.toOwnedSlice(allocator);
    try out.append(allocator, .{
        .ev = .{
            .stack = "",
            .item = "",
            .kind = .@"error",
            .data_json = storage,
        },
        .storage = storage,
    });
}

fn emitErrorList(allocator: std.mem.Allocator, slug: []const u8, recoverable: bool) ![]adapter.OwnedEvent {
    var buf = std.ArrayList(u8){};
    errdefer buf.deinit(allocator);
    try buf.writer(allocator).print("{{\"message\":\"{s}\",\"recoverable\":{s}}}", .{ slug, if (recoverable) "true" else "false" });
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

test "codex: thread.started -> session_started with id + model" {
    const a = std.testing.allocator;
    var ad = try create(a);
    defer ad.deinit(a);
    const evs = try ad.parseLine(a, "{\"type\":\"thread.started\",\"thread_id\":\"th-1\",\"model\":\"gpt-5\"}\n");
    defer adapter.freeOwnedSlice(a, evs);
    try std.testing.expectEqual(@as(usize, 1), evs.len);
    try std.testing.expectEqual(events.Kind.session_started, evs[0].ev.kind);
    try std.testing.expect(std.mem.indexOf(u8, evs[0].ev.data_json, "\"harness\":\"codex\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, evs[0].ev.data_json, "\"session\":\"th-1\"") != null);
}

test "codex: turn.started + turn.completed" {
    const a = std.testing.allocator;
    var ad = try create(a);
    defer ad.deinit(a);
    {
        const evs = try ad.parseLine(a, "{\"type\":\"turn.started\"}\n");
        defer adapter.freeOwnedSlice(a, evs);
        try std.testing.expectEqual(events.Kind.turn_started, evs[0].ev.kind);
    }
    {
        const evs = try ad.parseLine(a, "{\"type\":\"turn.completed\",\"usage\":{}}\n");
        defer adapter.freeOwnedSlice(a, evs);
        try std.testing.expectEqual(events.Kind.turn_completed, evs[0].ev.kind);
    }
}

test "codex: agent_message item -> message" {
    const a = std.testing.allocator;
    var ad = try create(a);
    defer ad.deinit(a);
    const evs = try ad.parseLine(a, "{\"type\":\"item.completed\",\"item\":{\"item_type\":\"agent_message\",\"text\":\"Hi from codex.\"}}\n");
    defer adapter.freeOwnedSlice(a, evs);
    try std.testing.expectEqual(@as(usize, 1), evs.len);
    try std.testing.expectEqual(events.Kind.message, evs[0].ev.kind);
    try std.testing.expect(std.mem.indexOf(u8, evs[0].ev.data_json, "\"text\":\"Hi from codex.\"") != null);
}

test "codex: command_execution -> tool_call + command_executed" {
    const a = std.testing.allocator;
    var ad = try create(a);
    defer ad.deinit(a);
    const evs = try ad.parseLine(a, "{\"type\":\"item.completed\",\"item\":{\"item_type\":\"command_execution\",\"id\":\"ce_1\",\"command\":\"ls\",\"exit_code\":0}}\n");
    defer adapter.freeOwnedSlice(a, evs);
    try std.testing.expectEqual(@as(usize, 2), evs.len);
    try std.testing.expectEqual(events.Kind.tool_call, evs[0].ev.kind);
    try std.testing.expectEqual(events.Kind.command_executed, evs[1].ev.kind);
    try std.testing.expect(std.mem.indexOf(u8, evs[1].ev.data_json, "\"cmd\":\"ls\"") != null);
}

test "codex: file_change with changes array -> file_changed per change" {
    const a = std.testing.allocator;
    var ad = try create(a);
    defer ad.deinit(a);
    const evs = try ad.parseLine(a, "{\"type\":\"item.completed\",\"item\":{\"item_type\":\"file_change\",\"id\":\"fc_1\",\"changes\":[{\"path\":\"a.zig\",\"kind\":\"update\"},{\"path\":\"b.zig\",\"kind\":\"create\"}]}}\n");
    defer adapter.freeOwnedSlice(a, evs);
    // tool_call + 2 file_changed
    try std.testing.expectEqual(@as(usize, 3), evs.len);
    try std.testing.expectEqual(events.Kind.tool_call, evs[0].ev.kind);
    try std.testing.expectEqual(events.Kind.file_changed, evs[1].ev.kind);
    try std.testing.expectEqual(events.Kind.file_changed, evs[2].ev.kind);
    try std.testing.expect(std.mem.indexOf(u8, evs[1].ev.data_json, "\"path\":\"a.zig\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, evs[1].ev.data_json, "\"op\":\"modify\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, evs[2].ev.data_json, "\"path\":\"b.zig\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, evs[2].ev.data_json, "\"op\":\"create\"") != null);
}

test "codex: turn.failed -> error (non-recoverable)" {
    const a = std.testing.allocator;
    var ad = try create(a);
    defer ad.deinit(a);
    const evs = try ad.parseLine(a, "{\"type\":\"turn.failed\",\"error\":{\"message\":\"context_overflow\"}}\n");
    defer adapter.freeOwnedSlice(a, evs);
    try std.testing.expectEqual(events.Kind.@"error", evs[0].ev.kind);
    try std.testing.expect(std.mem.indexOf(u8, evs[0].ev.data_json, "\"recoverable\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, evs[0].ev.data_json, "context_overflow") != null);
}

test "codex: malformed line yields recoverable error" {
    const a = std.testing.allocator;
    var ad = try create(a);
    defer ad.deinit(a);
    const evs = try ad.parseLine(a, "garbage\n");
    defer adapter.freeOwnedSlice(a, evs);
    try std.testing.expectEqual(@as(usize, 1), evs.len);
    try std.testing.expectEqual(events.Kind.@"error", evs[0].ev.kind);
    try std.testing.expect(std.mem.indexOf(u8, evs[0].ev.data_json, "\"recoverable\":true") != null);
}

test "codex: on_exit success carries session_id + model in data" {
    const a = std.testing.allocator;
    var ad = try create(a);
    defer ad.deinit(a);
    const evs = try ad.parseLine(a, "{\"type\":\"thread.started\",\"thread_id\":\"th-xyz\",\"model\":\"gpt-5\"}\n");
    adapter.freeOwnedSlice(a, evs);
    const ev = try ad.onExit(a, 0, true);
    defer adapter.freeOwned(a, ev);
    try std.testing.expect(std.mem.indexOf(u8, ev.ev.data_json, "\"terminal_status\":\"completed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ev.ev.data_json, "\"session_id\":\"th-xyz\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ev.ev.data_json, "\"model\":\"gpt-5\"") != null);
}

test "codex: top-level type wins over nested type fields" {
    const a = std.testing.allocator;
    var ad = try create(a);
    defer ad.deinit(a);
    const evs = try ad.parseLine(a, "{\"item\":{\"type\":\"not-top-level\"},\"type\":\"thread.started\",\"thread_id\":\"th-ordered\",\"model\":\"gpt-5\"}\n");
    defer adapter.freeOwnedSlice(a, evs);
    try std.testing.expectEqual(@as(usize, 1), evs.len);
    try std.testing.expectEqual(events.Kind.session_started, evs[0].ev.kind);
    try std.testing.expect(std.mem.indexOf(u8, evs[0].ev.data_json, "\"session\":\"th-ordered\"") != null);
}

test "codex: escaped provider strings preserve JSON semantics" {
    const a = std.testing.allocator;
    var ad = try create(a);
    defer ad.deinit(a);
    const evs = try ad.parseLine(a, "{\"type\":\"item.completed\",\"item\":{\"item_type\":\"agent_message\",\"text\":\"quote: \\\"ok\\\"\"}}\n");
    defer adapter.freeOwnedSlice(a, evs);
    try std.testing.expectEqual(@as(usize, 1), evs.len);
    try std.testing.expectEqual(events.Kind.message, evs[0].ev.kind);
    try std.testing.expect(std.mem.indexOf(u8, evs[0].ev.data_json, "\"text\":\"quote: \\\"ok\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, evs[0].ev.data_json, "\\\\\\\"ok") == null);
}

test "codex: unknown top-level event emits recoverable error" {
    const a = std.testing.allocator;
    var ad = try create(a);
    defer ad.deinit(a);
    const evs = try ad.parseLine(a, "{\"type\":\"future.event\",\"data\":{}}\n");
    defer adapter.freeOwnedSlice(a, evs);
    try std.testing.expectEqual(@as(usize, 1), evs.len);
    try std.testing.expectEqual(events.Kind.@"error", evs[0].ev.kind);
    try std.testing.expect(std.mem.indexOf(u8, evs[0].ev.data_json, "\"recoverable\":true") != null);
}

test "codex: error event with top-level message emits recoverable error" {
    const a = std.testing.allocator;
    var ad = try create(a);
    defer ad.deinit(a);
    const evs = try ad.parseLine(a, "{\"type\":\"error\",\"message\":\"transient\"}\n");
    defer adapter.freeOwnedSlice(a, evs);
    try std.testing.expectEqual(@as(usize, 1), evs.len);
    try std.testing.expectEqual(events.Kind.@"error", evs[0].ev.kind);
    try std.testing.expect(std.mem.indexOf(u8, evs[0].ev.data_json, "\"recoverable\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, evs[0].ev.data_json, "transient") != null);
}

test "codex: thread.error event emits recoverable error" {
    const a = std.testing.allocator;
    var ad = try create(a);
    defer ad.deinit(a);
    const evs = try ad.parseLine(a, "{\"type\":\"thread.error\",\"message\":\"backoff\"}\n");
    defer adapter.freeOwnedSlice(a, evs);
    try std.testing.expectEqual(@as(usize, 1), evs.len);
    try std.testing.expectEqual(events.Kind.@"error", evs[0].ev.kind);
    try std.testing.expect(std.mem.indexOf(u8, evs[0].ev.data_json, "\"recoverable\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, evs[0].ev.data_json, "backoff") != null);
}

test "codex: error event prefers top-level message over nested buried one" {
    // Regression for the audit-flagged first-positional bug.
    const a = std.testing.allocator;
    var ad = try create(a);
    defer ad.deinit(a);
    const evs = try ad.parseLine(a, "{\"type\":\"error\",\"details\":{\"message\":\"buried\"},\"message\":\"actual\"}\n");
    defer adapter.freeOwnedSlice(a, evs);
    try std.testing.expectEqual(@as(usize, 1), evs.len);
    try std.testing.expectEqual(events.Kind.@"error", evs[0].ev.kind);
    try std.testing.expect(std.mem.indexOf(u8, evs[0].ev.data_json, "actual") != null);
    try std.testing.expect(std.mem.indexOf(u8, evs[0].ev.data_json, "buried") == null);
}

test "codex: findStringValue ignores nested same-name keys (depth-1 only)" {
    const line = "{\"type\":\"error\",\"details\":{\"message\":\"buried\"},\"message\":\"actual\"}";
    const got = findStringValue(line, "\"message\":") orelse return error.NotFound;
    try std.testing.expectEqualStrings("actual", got);
}

test "codex: item.updated emits the same projection as item.completed" {
    const a = std.testing.allocator;
    var ad = try create(a);
    defer ad.deinit(a);
    const evs = try ad.parseLine(a, "{\"type\":\"item.updated\",\"item\":{\"item_type\":\"agent_message\",\"text\":\"streamed.\"}}\n");
    defer adapter.freeOwnedSlice(a, evs);
    try std.testing.expectEqual(@as(usize, 1), evs.len);
    try std.testing.expectEqual(events.Kind.message, evs[0].ev.kind);
    try std.testing.expect(std.mem.indexOf(u8, evs[0].ev.data_json, "\"text\":\"streamed.\"") != null);
}

test "codex: reasoning item maps to message with role=reasoning" {
    const a = std.testing.allocator;
    var ad = try create(a);
    defer ad.deinit(a);
    const evs = try ad.parseLine(a, "{\"type\":\"item.completed\",\"item\":{\"item_type\":\"reasoning\",\"text\":\"thinking\"}}\n");
    defer adapter.freeOwnedSlice(a, evs);
    try std.testing.expectEqual(@as(usize, 1), evs.len);
    try std.testing.expectEqual(events.Kind.message, evs[0].ev.kind);
    try std.testing.expect(std.mem.indexOf(u8, evs[0].ev.data_json, "\"role\":\"reasoning\"") != null);
}

test "codex: parseStderrLine emits one recoverable error per non-empty line" {
    const a = std.testing.allocator;
    var ad = try create(a);
    defer ad.deinit(a);
    const evs = try ad.parseStderrLine(a, "boom\n");
    defer adapter.freeOwnedSlice(a, evs);
    try std.testing.expectEqual(@as(usize, 1), evs.len);
    try std.testing.expectEqual(events.Kind.@"error", evs[0].ev.kind);
    try std.testing.expect(std.mem.indexOf(u8, evs[0].ev.data_json, "boom") != null);
    try std.testing.expect(std.mem.indexOf(u8, evs[0].ev.data_json, "\"recoverable\":true") != null);
}

test "codex: parseStderrLine ignores stdin informational line" {
    const a = std.testing.allocator;
    var ad = try create(a);
    defer ad.deinit(a);
    const evs = try ad.parseStderrLine(a, "Reading additional input from stdin...\n");
    defer adapter.freeOwnedSlice(a, evs);
    try std.testing.expectEqual(@as(usize, 0), evs.len);
}

test "codex: parseStderrLine empty line yields zero events" {
    const a = std.testing.allocator;
    var ad = try create(a);
    defer ad.deinit(a);
    const evs = try ad.parseStderrLine(a, "\n");
    defer adapter.freeOwnedSlice(a, evs);
    try std.testing.expectEqual(@as(usize, 0), evs.len);
}

test "codex: item.started is non-semantic" {
    const a = std.testing.allocator;
    var ad = try create(a);
    defer ad.deinit(a);
    const evs = try ad.parseLine(a, "{\"type\":\"item.started\",\"item\":{\"item_type\":\"reasoning\"}}\n");
    defer adapter.freeOwnedSlice(a, evs);
    try std.testing.expectEqual(@as(usize, 0), evs.len);
}

test "codex: unknown event reports event type" {
    const a = std.testing.allocator;
    var ad = try create(a);
    defer ad.deinit(a);
    const evs = try ad.parseLine(a, "{\"type\":\"turn.weird\"}\n");
    defer adapter.freeOwnedSlice(a, evs);
    try std.testing.expectEqual(@as(usize, 1), evs.len);
    try std.testing.expectEqual(events.Kind.@"error", evs[0].ev.kind);
    try std.testing.expect(std.mem.indexOf(u8, evs[0].ev.data_json, "\"message\":\"adapter_unknown_event\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, evs[0].ev.data_json, "\"event_type\":\"turn.weird\"") != null);
}

test "codex: on_exit clean exit + ran_to_completion=false → canceled" {
    const a = std.testing.allocator;
    var ad = try create(a);
    defer ad.deinit(a);
    const exit_ev = try ad.onExit(a, 0, false);
    defer adapter.freeOwned(a, exit_ev);
    try std.testing.expect(std.mem.indexOf(u8, exit_ev.ev.data_json, "\"terminal_status\":\"canceled\"") != null);
}
