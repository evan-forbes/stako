//! Codex CLI adapter (milestone 7).
//!
//! Parses the JSONL emitted by `codex exec --json <prompt>` and maps each
//! event onto organo's normalized event schema (see `events.zig`).
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
const events = @import("events.zig");

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

    if (std.mem.eql(u8, type_str, "thread.started")) {
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
    } else if (std.mem.eql(u8, type_str, "turn.started")) {
        try emitTurnStarted(allocator, &out, st);
        st.turn_index += 1;
    } else if (std.mem.eql(u8, type_str, "turn.completed")) {
        try emitTurnCompleted(allocator, &out, st);
    } else if (std.mem.eql(u8, type_str, "turn.failed")) {
        const msg = findStringValue(findObjectValue(line, "\"error\":") orelse "{}", "\"message\":") orelse "turn_failed";
        try emitError(allocator, &out, msg, false);
    } else if (std.mem.eql(u8, type_str, "error") or std.mem.eql(u8, type_str, "thread.error")) {
        const msg = findStringValue(line, "\"message\":") orelse "error";
        try emitError(allocator, &out, msg, true);
    } else if (std.mem.eql(u8, type_str, "item.completed") or std.mem.eql(u8, type_str, "item.updated")) {
        const item = findObjectValue(line, "\"item\":") orelse {
            return out.toOwnedSlice(allocator);
        };
        const item_type = findStringValue(item, "\"item_type\":") orelse "";
        if (std.mem.eql(u8, item_type, "agent_message")) {
            const text = findStringValue(item, "\"text\":") orelse "";
            try emitMessage(allocator, &out, text, "assistant");
        } else if (std.mem.eql(u8, item_type, "reasoning")) {
            const text = findStringValue(item, "\"text\":") orelse "";
            try emitMessage(allocator, &out, text, "reasoning");
        } else if (std.mem.eql(u8, item_type, "command_execution")) {
            const cmd = findStringValue(item, "\"command\":") orelse "";
            const exit_code = findIntValue(item, "\"exit_code\":") orelse 0;
            const call_id = findStringValue(item, "\"id\":") orelse "";
            // Build args object: {"command":"..."}.
            var argbuf = std.ArrayList(u8){};
            defer argbuf.deinit(allocator);
            try argbuf.writer(allocator).writeAll("{\"command\":\"");
            try writeParsedJsonStringContent(argbuf.writer(allocator), cmd);
            try argbuf.writer(allocator).writeAll("\"}");
            try emitToolCall(allocator, &out, "command_execution", argbuf.items, call_id);
            try emitCommandExecuted(allocator, &out, cmd, @intCast(exit_code));
        } else if (std.mem.eql(u8, item_type, "file_change")) {
            const call_id = findStringValue(item, "\"id\":") orelse "";
            // Emit a single tool_call summary + per-change file_changed.
            try emitToolCall(allocator, &out, "file_change", "{}", call_id);
            if (findArrayValue(item, "\"changes\":")) |arr| {
                try emitFileChangesFromArray(allocator, &out, arr);
            } else if (findStringValue(item, "\"path\":")) |p| {
                const kind = findStringValue(item, "\"kind\":") orelse "modify";
                try emitFileChanged(allocator, &out, p, mapCodexFileKind(kind));
            }
        }
        // Other item_types (mcp_tool_call, web_search, plan_update) are not
        // projected to normalized kinds in v1.
    } else {
        try emitError(allocator, &out, "adapter_unknown_event", true);
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

// ---------- shared JSON micro-parsers (duplicated from claude_adapter to
// keep each adapter self-contained; the helpers are small enough that
// dragging them through a shared module isn't worth the indirection in v1) ----------

fn stripEol(raw: []const u8) []const u8 {
    var line = raw;
    if (line.len > 0 and line[line.len - 1] == '\n') line = line[0 .. line.len - 1];
    if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
    return line;
}

fn findStringValue(src: []const u8, key_with_colon: []const u8) ?[]const u8 {
    var search_from: usize = 0;
    while (search_from < src.len) {
        const idx = std.mem.indexOf(u8, src[search_from..], key_with_colon) orelse return null;
        const abs = search_from + idx;
        if (abs > 0) {
            const c = src[abs - 1];
            if (c != ',' and c != '{' and c != ' ' and c != '\t' and c != '\n' and c != '[') {
                search_from = abs + 1;
                continue;
            }
        }
        var i = abs + key_with_colon.len;
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
    return null;
}

fn findTopLevelStringValue(src: []const u8, key_with_colon: []const u8) ?[]const u8 {
    var i: usize = 0;
    var depth: usize = 0;
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
            if (depth == 1 and std.mem.startsWith(u8, src[i..], key_with_colon)) {
                var j = i + key_with_colon.len;
                while (j < src.len and (src[j] == ' ' or src[j] == '\t')) j += 1;
                if (j >= src.len or src[j] != '"') return null;
                j += 1;
                const start = j;
                while (j < src.len) : (j += 1) {
                    if (src[j] == '\\') {
                        j += 1;
                        continue;
                    }
                    if (src[j] == '"') return src[start..j];
                }
                return null;
            }
            in_str = true;
            continue;
        }
        if (c == '{' or c == '[') depth += 1;
        if (c == '}' or c == ']') {
            if (depth == 0) return null;
            depth -= 1;
        }
    }
    return null;
}

fn findIntValue(src: []const u8, key_with_colon: []const u8) ?i64 {
    var search_from: usize = 0;
    while (search_from < src.len) {
        const idx = std.mem.indexOf(u8, src[search_from..], key_with_colon) orelse return null;
        const abs = search_from + idx;
        if (abs > 0) {
            const c = src[abs - 1];
            if (c != ',' and c != '{' and c != ' ' and c != '\t' and c != '\n' and c != '[') {
                search_from = abs + 1;
                continue;
            }
        }
        var i = abs + key_with_colon.len;
        while (i < src.len and (src[i] == ' ' or src[i] == '\t')) i += 1;
        const start = i;
        while (i < src.len and (std.ascii.isDigit(src[i]) or src[i] == '-')) i += 1;
        return std.fmt.parseInt(i64, src[start..i], 10) catch null;
    }
    return null;
}

fn findObjectValue(src: []const u8, key_with_colon: []const u8) ?[]const u8 {
    var search_from: usize = 0;
    while (search_from < src.len) {
        const idx = std.mem.indexOf(u8, src[search_from..], key_with_colon) orelse return null;
        const abs = search_from + idx;
        if (abs > 0) {
            const c = src[abs - 1];
            if (c != ',' and c != '{' and c != ' ' and c != '\t' and c != '\n' and c != '[') {
                search_from = abs + 1;
                continue;
            }
        }
        var i = abs + key_with_colon.len;
        while (i < src.len and (src[i] == ' ' or src[i] == '\t')) i += 1;
        if (i >= src.len or src[i] != '{') return null;
        const end = findMatchingBraceEnd(src, i) orelse return null;
        return src[i..end];
    }
    return null;
}

fn findArrayValue(src: []const u8, key_with_colon: []const u8) ?[]const u8 {
    var search_from: usize = 0;
    while (search_from < src.len) {
        const idx = std.mem.indexOf(u8, src[search_from..], key_with_colon) orelse return null;
        const abs = search_from + idx;
        if (abs > 0) {
            const c = src[abs - 1];
            if (c != ',' and c != '{' and c != ' ' and c != '\t' and c != '\n' and c != '[') {
                search_from = abs + 1;
                continue;
            }
        }
        var i = abs + key_with_colon.len;
        while (i < src.len and (src[i] == ' ' or src[i] == '\t')) i += 1;
        if (i >= src.len or src[i] != '[') return null;
        const start = i;
        var depth: usize = 0;
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
            if (c == '[') depth += 1;
            if (c == ']') {
                depth -= 1;
                if (depth == 0) return src[start .. i + 1];
            }
        }
        return null;
    }
    return null;
}

fn findMatchingBraceEnd(src: []const u8, start: usize) ?usize {
    if (start >= src.len or src[start] != '{') return null;
    var depth: usize = 0;
    var i = start;
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
            if (depth == 0) return i + 1;
        }
    }
    return null;
}

fn jsonEscape(w: anytype, s: []const u8) !void {
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        else => try w.writeByte(c),
    };
}

fn writeParsedJsonStringContent(w: anytype, s: []const u8) !void {
    try w.writeAll(s);
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
