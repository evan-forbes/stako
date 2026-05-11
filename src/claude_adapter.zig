//! Claude Code adapter (milestone 7).
//!
//! Parses the JSONL emitted by `claude -p <prompt> --output-format stream-json
//! --verbose --include-partial-messages` and maps each event onto organo's
//! normalized event schema (see `events.zig`).
//!
//! Mapping table (claude → normalized):
//!
//!   {"type":"system","subtype":"init",...}      → session_started
//!   {"type":"stream_event","event":{"type":"message_start",...}}    → turn_started
//!   {"type":"stream_event","event":{"type":"content_block_delta",
//!        "delta":{"type":"text_delta","text":"..."}}}                → message_chunk
//!   {"type":"assistant","message":{...content:[{type:"text",...}]}}  → message
//!   {"type":"assistant","message":{...content:[
//!        {type:"tool_use",name:"Edit"/"Write",input:{file_path:..}}]}}
//!                                                                    → tool_call + file_changed
//!   {"type":"assistant","message":{...content:[
//!        {type:"tool_use",name:"Bash",input:{command:..}}]}}          → tool_call + command_executed
//!   {"type":"user","message":{...content:[{type:"tool_result",...}]}}→ tool_result
//!   {"type":"stream_event","event":{"type":"message_stop"}}          → turn_completed
//!   {"type":"result",...}                                            → message (final) + session_started extras
//!   any unknown line                                                 → error (recoverable)
//!
//! The adapter is conservative: when input is malformed JSON or unrecognized,
//! it returns a single non-terminal `error` event so the session continues
//! and the rest of the stream can be parsed.
//!
//! `session_started` carries `harness:"claude"`, the captured `session` id,
//! and (when known) the model. `session_ended` is produced by `on_exit`.
//!
//! Cancellation is NOT this adapter's concern — the session manager owns
//! signal escalation via `cancelAndEscalate`.

const std = @import("std");
const adapter = @import("adapter.zig");
const events = @import("events.zig");

pub const State = struct {
    session_id: []u8 = "",
    /// Most recent model string seen; copied into `session_started` data and
    /// returned at exit time via `on_exit`.
    model: []u8 = "",
    /// Native session JSONL path (claude writes one under
    /// ~/.claude/projects/<encoded-cwd>/<session-uuid>.jsonl). We don't try
    /// to compute the encoded-cwd here; we just record what the CLI tells
    /// us when it reports a session_id, and let the session manager attach
    /// it to the terminal `[result]` block via the runtime file write.
    session_file: []u8 = "",
    turn_index: u32 = 0,
    seen_init: bool = false,

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
        .name = "claude",
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
        .clear => true,
        .partial_messages => true,
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
        try jsonEscape(w, st.session_id);
        try w.writeAll("\"");
    }
    if (st.session_file.len > 0) {
        try w.writeAll(",\"session_file\":\"");
        try jsonEscape(w, st.session_file);
        try w.writeAll("\"");
    }
    if (st.model.len > 0) {
        try w.writeAll(",\"model\":\"");
        try jsonEscape(w, st.model);
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

    const type_str = findStringValue(line, "\"type\":") orelse return emitErrorList(allocator, "adapter_parse_error");

    // Build a growing list. We free already-built events on error.
    var out = std.ArrayList(adapter.OwnedEvent){};
    errdefer {
        for (out.items) |oe| adapter.freeOwned(allocator, oe);
        out.deinit(allocator);
    }

    if (std.mem.eql(u8, type_str, "system")) {
        // {"type":"system","subtype":"init","session_id":"...","model":"...","cwd":"..."}
        const subtype = findStringValue(line, "\"subtype\":") orelse "";
        if (std.mem.eql(u8, subtype, "init") and !st.seen_init) {
            if (findStringValue(line, "\"session_id\":")) |sid| {
                if (st.session_id.len > 0) allocator.free(st.session_id);
                st.session_id = try allocator.dupe(u8, sid);
            }
            if (findStringValue(line, "\"model\":")) |m| {
                if (st.model.len > 0) allocator.free(st.model);
                st.model = try allocator.dupe(u8, m);
            }
            if (findStringValue(line, "\"session_file\":")) |sf| {
                if (st.session_file.len > 0) allocator.free(st.session_file);
                st.session_file = try allocator.dupe(u8, sf);
            }
            st.seen_init = true;
            const cwd_opt = findStringValue(line, "\"cwd\":");
            try emitSessionStarted(allocator, &out, st, cwd_opt);
        }
        // Other system subtypes (e.g. "tool_result" wrappers) are not
        // emitted as normalized events in v1.
    } else if (std.mem.eql(u8, type_str, "assistant")) {
        // Full assistant message landed. The `message.content` array may
        // contain text blocks and/or tool_use blocks.
        const msg = findObjectValue(line, "\"message\":") orelse {
            return out.toOwnedSlice(allocator);
        };
        // Parse `content` array.
        if (findArrayValue(msg, "\"content\":")) |arr| {
            try emitAssistantContent(allocator, &out, st, arr);
        }
    } else if (std.mem.eql(u8, type_str, "user")) {
        // user-from-cli message — typically carries `tool_result` blocks.
        const msg = findObjectValue(line, "\"message\":") orelse {
            return out.toOwnedSlice(allocator);
        };
        if (findArrayValue(msg, "\"content\":")) |arr| {
            try emitToolResults(allocator, &out, arr);
        }
    } else if (std.mem.eql(u8, type_str, "stream_event")) {
        // Partial-message stream-event passthrough. We only project the
        // most useful kinds: `message_start`, `content_block_delta` (text),
        // `message_stop`.
        const inner = findObjectValue(line, "\"event\":") orelse {
            return out.toOwnedSlice(allocator);
        };
        const ev_type = findStringValue(inner, "\"type\":") orelse "";
        if (std.mem.eql(u8, ev_type, "message_start")) {
            try emitTurnStarted(allocator, &out, st);
            st.turn_index += 1;
        } else if (std.mem.eql(u8, ev_type, "content_block_delta")) {
            // delta.{type:text_delta, text:"..."}
            const delta = findObjectValue(inner, "\"delta\":") orelse "{}";
            const dtype = findStringValue(delta, "\"type\":") orelse "";
            if (std.mem.eql(u8, dtype, "text_delta")) {
                const t = findStringValue(delta, "\"text\":") orelse "";
                try emitMessageChunk(allocator, &out, t, "assistant");
            }
        } else if (std.mem.eql(u8, ev_type, "message_stop")) {
            try emitTurnCompleted(allocator, &out, st);
        }
    } else if (std.mem.eql(u8, type_str, "result")) {
        // Final wrapper. Emit a final `message` carrying `result` text if
        // any, plus a turn_completed if we haven't seen one. Promote a
        // session_id refresh and capture session_file if present.
        if (findStringValue(line, "\"session_id\":")) |sid| {
            if (st.session_id.len > 0) allocator.free(st.session_id);
            st.session_id = try allocator.dupe(u8, sid);
        }
        if (findStringValue(line, "\"session_file\":")) |sf| {
            if (st.session_file.len > 0) allocator.free(st.session_file);
            st.session_file = try allocator.dupe(u8, sf);
        }
        if (findStringValue(line, "\"result\":")) |text| {
            try emitMessage(allocator, &out, text, "assistant");
        }
    }
    // Other types ("error", system non-init, etc) are silently dropped.

    return out.toOwnedSlice(allocator);
}

fn emitSessionStarted(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(adapter.OwnedEvent),
    st: *State,
    cwd_opt: ?[]const u8,
) !void {
    var buf = std.ArrayList(u8){};
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try w.writeAll("{\"harness\":\"claude\"");
    if (st.model.len > 0) {
        try w.writeAll(",\"model\":\"");
        try jsonEscape(w, st.model);
        try w.writeAll("\"");
    }
    if (st.session_id.len > 0) {
        try w.writeAll(",\"session\":\"");
        try jsonEscape(w, st.session_id);
        try w.writeAll("\"");
    }
    if (cwd_opt) |c| {
        try w.writeAll(",\"cwd\":\"");
        try jsonEscape(w, c);
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

fn emitTurnStarted(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(adapter.OwnedEvent),
    st: *State,
) !void {
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

fn emitTurnCompleted(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(adapter.OwnedEvent),
    st: *State,
) !void {
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
    try jsonEscape(w, text);
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

fn emitMessageChunk(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(adapter.OwnedEvent),
    text: []const u8,
    role: []const u8,
) !void {
    var buf = std.ArrayList(u8){};
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try w.writeAll("{\"text\":\"");
    try jsonEscape(w, text);
    try w.writeAll("\",\"role\":\"");
    try w.writeAll(role);
    try w.writeAll("\"}");
    const storage = try buf.toOwnedSlice(allocator);
    try out.append(allocator, .{
        .ev = .{
            .stack = "",
            .item = "",
            .kind = .message_chunk,
            .data_json = storage,
        },
        .storage = storage,
    });
}

fn emitAssistantContent(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(adapter.OwnedEvent),
    st: *State,
    arr_with_brackets: []const u8,
) !void {
    _ = st;
    // Iterate top-level objects in the array.
    var i: usize = 0;
    if (arr_with_brackets.len == 0 or arr_with_brackets[0] != '[') return;
    i = 1;
    while (i < arr_with_brackets.len) {
        // Skip whitespace / commas.
        while (i < arr_with_brackets.len and (arr_with_brackets[i] == ' ' or arr_with_brackets[i] == ',' or arr_with_brackets[i] == '\t' or arr_with_brackets[i] == '\n')) i += 1;
        if (i >= arr_with_brackets.len or arr_with_brackets[i] == ']') break;
        if (arr_with_brackets[i] != '{') {
            i += 1;
            continue;
        }
        const obj_start = i;
        const obj_end = findMatchingBraceEnd(arr_with_brackets, obj_start) orelse break;
        const obj = arr_with_brackets[obj_start..obj_end];
        try projectAssistantBlock(allocator, out, obj);
        i = obj_end;
    }
}

fn projectAssistantBlock(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(adapter.OwnedEvent),
    block: []const u8,
) !void {
    const btype = findStringValue(block, "\"type\":") orelse return;
    if (std.mem.eql(u8, btype, "text")) {
        const text = findStringValue(block, "\"text\":") orelse return;
        try emitMessage(allocator, out, text, "assistant");
    } else if (std.mem.eql(u8, btype, "tool_use")) {
        const tool = findStringValue(block, "\"name\":") orelse return;
        const call_id = findStringValue(block, "\"id\":") orelse "";
        const inp_obj = findObjectValue(block, "\"input\":") orelse "{}";
        // Always emit a tool_call.
        try emitToolCall(allocator, out, tool, inp_obj, call_id);
        // Project to file_changed / command_executed.
        if (std.mem.eql(u8, tool, "Edit") or std.mem.eql(u8, tool, "Write") or std.mem.eql(u8, tool, "MultiEdit")) {
            const path = findStringValue(inp_obj, "\"file_path\":") orelse "";
            const op: []const u8 = if (std.mem.eql(u8, tool, "Write")) "create" else "modify";
            try emitFileChanged(allocator, out, path, op);
        } else if (std.mem.eql(u8, tool, "Bash")) {
            const cmd = findStringValue(inp_obj, "\"command\":") orelse "";
            try emitCommandExecuted(allocator, out, cmd, 0);
        }
    }
    // tool_result handled in `user` message path.
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
    try jsonEscape(w, tool);
    try w.writeAll("\",\"args\":");
    if (args_obj_with_braces.len == 0) try w.writeAll("{}") else try w.writeAll(args_obj_with_braces);
    try w.writeAll(",\"call_id\":\"");
    try jsonEscape(w, call_id);
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
    try jsonEscape(w, path);
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
    try jsonEscape(w, cmd);
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

fn emitToolResults(
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
        const btype = findStringValue(obj, "\"type\":") orelse "";
        if (std.mem.eql(u8, btype, "tool_result")) {
            const id = findStringValue(obj, "\"tool_use_id\":") orelse "";
            const content = findStringValue(obj, "\"content\":") orelse "";
            try emitToolResultEvent(allocator, out, id, content);
        }
        i = obj_end;
    }
}

fn emitToolResultEvent(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(adapter.OwnedEvent),
    call_id: []const u8,
    output: []const u8,
) !void {
    var buf = std.ArrayList(u8){};
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try w.writeAll("{\"call_id\":\"");
    try jsonEscape(w, call_id);
    try w.writeAll("\",\"ok\":true,\"output\":\"");
    try jsonEscape(w, output);
    try w.writeAll("\"}");
    const storage = try buf.toOwnedSlice(allocator);
    try out.append(allocator, .{
        .ev = .{
            .stack = "",
            .item = "",
            .kind = .tool_result,
            .data_json = storage,
        },
        .storage = storage,
    });
}

fn emitErrorList(allocator: std.mem.Allocator, slug: []const u8) ![]adapter.OwnedEvent {
    var buf = std.ArrayList(u8){};
    errdefer buf.deinit(allocator);
    try buf.writer(allocator).print("{{\"message\":\"{s}\",\"recoverable\":true}}", .{slug});
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

// ---------- shared JSON micro-parsers ----------

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
        // Ensure the byte before the key is `,` or `{` or whitespace (so we
        // don't match `"foo_session_id":` when scanning for `"session_id":`).
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

/// Given `src` and an index pointing to a `{`, find the index just past the
/// matching `}`. Returns null if unbalanced.
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

// ---------- tests ----------

test "claude: system init -> session_started with model + session" {
    const a = std.testing.allocator;
    var ad = try create(a);
    defer ad.deinit(a);
    const line = "{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"sess-1\",\"model\":\"claude-opus-4-7\",\"cwd\":\"/tmp\"}\n";
    const evs = try ad.parseLine(a, line);
    defer adapter.freeOwnedSlice(a, evs);
    try std.testing.expectEqual(@as(usize, 1), evs.len);
    try std.testing.expectEqual(events.Kind.session_started, evs[0].ev.kind);
    try std.testing.expect(std.mem.indexOf(u8, evs[0].ev.data_json, "\"harness\":\"claude\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, evs[0].ev.data_json, "\"model\":\"claude-opus-4-7\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, evs[0].ev.data_json, "\"session\":\"sess-1\"") != null);
}

test "claude: stream_event message_start + content_block_delta + message_stop" {
    const a = std.testing.allocator;
    var ad = try create(a);
    defer ad.deinit(a);
    {
        const evs = try ad.parseLine(a, "{\"type\":\"stream_event\",\"event\":{\"type\":\"message_start\",\"message\":{}}}\n");
        defer adapter.freeOwnedSlice(a, evs);
        try std.testing.expectEqual(events.Kind.turn_started, evs[0].ev.kind);
    }
    {
        const evs = try ad.parseLine(a, "{\"type\":\"stream_event\",\"event\":{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"Hi\"}}}\n");
        defer adapter.freeOwnedSlice(a, evs);
        try std.testing.expectEqual(events.Kind.message_chunk, evs[0].ev.kind);
        try std.testing.expect(std.mem.indexOf(u8, evs[0].ev.data_json, "\"text\":\"Hi\"") != null);
    }
    {
        const evs = try ad.parseLine(a, "{\"type\":\"stream_event\",\"event\":{\"type\":\"message_stop\"}}\n");
        defer adapter.freeOwnedSlice(a, evs);
        try std.testing.expectEqual(events.Kind.turn_completed, evs[0].ev.kind);
    }
}

test "claude: assistant message with text block -> message event" {
    const a = std.testing.allocator;
    var ad = try create(a);
    defer ad.deinit(a);
    const line = "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"Hello, world!\"}]}}\n";
    const evs = try ad.parseLine(a, line);
    defer adapter.freeOwnedSlice(a, evs);
    try std.testing.expectEqual(@as(usize, 1), evs.len);
    try std.testing.expectEqual(events.Kind.message, evs[0].ev.kind);
    try std.testing.expect(std.mem.indexOf(u8, evs[0].ev.data_json, "\"text\":\"Hello, world!\"") != null);
}

test "claude: tool_use Edit -> tool_call + file_changed" {
    const a = std.testing.allocator;
    var ad = try create(a);
    defer ad.deinit(a);
    const line = "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"id\":\"tu_1\",\"name\":\"Edit\",\"input\":{\"file_path\":\"/tmp/x.zig\",\"old_string\":\"a\",\"new_string\":\"b\"}}]}}\n";
    const evs = try ad.parseLine(a, line);
    defer adapter.freeOwnedSlice(a, evs);
    try std.testing.expectEqual(@as(usize, 2), evs.len);
    try std.testing.expectEqual(events.Kind.tool_call, evs[0].ev.kind);
    try std.testing.expectEqual(events.Kind.file_changed, evs[1].ev.kind);
    try std.testing.expect(std.mem.indexOf(u8, evs[1].ev.data_json, "\"path\":\"/tmp/x.zig\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, evs[1].ev.data_json, "\"op\":\"modify\"") != null);
}

test "claude: tool_use Bash -> tool_call + command_executed" {
    const a = std.testing.allocator;
    var ad = try create(a);
    defer ad.deinit(a);
    const line = "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"id\":\"tu_2\",\"name\":\"Bash\",\"input\":{\"command\":\"echo hi\"}}]}}\n";
    const evs = try ad.parseLine(a, line);
    defer adapter.freeOwnedSlice(a, evs);
    try std.testing.expectEqual(@as(usize, 2), evs.len);
    try std.testing.expectEqual(events.Kind.tool_call, evs[0].ev.kind);
    try std.testing.expectEqual(events.Kind.command_executed, evs[1].ev.kind);
    try std.testing.expect(std.mem.indexOf(u8, evs[1].ev.data_json, "\"cmd\":\"echo hi\"") != null);
}

test "claude: malformed line yields recoverable error" {
    const a = std.testing.allocator;
    var ad = try create(a);
    defer ad.deinit(a);
    const evs = try ad.parseLine(a, "not json at all\n");
    defer adapter.freeOwnedSlice(a, evs);
    try std.testing.expectEqual(@as(usize, 1), evs.len);
    try std.testing.expectEqual(events.Kind.@"error", evs[0].ev.kind);
    try std.testing.expect(std.mem.indexOf(u8, evs[0].ev.data_json, "\"recoverable\":true") != null);
}

test "claude: on_exit success records session_id, model, terminal_status" {
    const a = std.testing.allocator;
    var ad = try create(a);
    defer ad.deinit(a);
    // Prime session_id and model via system init.
    const init_line = "{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"sess-xyz\",\"model\":\"claude-opus-4-7\",\"cwd\":\"/tmp\"}\n";
    const evs = try ad.parseLine(a, init_line);
    adapter.freeOwnedSlice(a, evs);
    const exit_ev = try ad.onExit(a, 0, true);
    defer adapter.freeOwned(a, exit_ev);
    try std.testing.expectEqual(events.Kind.session_ended, exit_ev.ev.kind);
    try std.testing.expect(std.mem.indexOf(u8, exit_ev.ev.data_json, "\"terminal_status\":\"completed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, exit_ev.ev.data_json, "\"session_id\":\"sess-xyz\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, exit_ev.ev.data_json, "\"model\":\"claude-opus-4-7\"") != null);
}

test "claude: on_exit canceled when not ran_to_completion" {
    const a = std.testing.allocator;
    var ad = try create(a);
    defer ad.deinit(a);
    const exit_ev = try ad.onExit(a, 130, false);
    defer adapter.freeOwned(a, exit_ev);
    try std.testing.expect(std.mem.indexOf(u8, exit_ev.ev.data_json, "\"terminal_status\":\"canceled\"") != null);
}

test "claude: on_exit nonzero exit -> failed" {
    const a = std.testing.allocator;
    var ad = try create(a);
    defer ad.deinit(a);
    const exit_ev = try ad.onExit(a, 2, true);
    defer adapter.freeOwned(a, exit_ev);
    try std.testing.expect(std.mem.indexOf(u8, exit_ev.ev.data_json, "\"terminal_status\":\"failed\"") != null);
}

test "claude: result line refreshes session id and emits final message" {
    const a = std.testing.allocator;
    var ad = try create(a);
    defer ad.deinit(a);
    const evs = try ad.parseLine(a, "{\"type\":\"result\",\"subtype\":\"success\",\"session_id\":\"sess-final\",\"result\":\"All done.\"}\n");
    defer adapter.freeOwnedSlice(a, evs);
    try std.testing.expectEqual(@as(usize, 1), evs.len);
    try std.testing.expectEqual(events.Kind.message, evs[0].ev.kind);
    try std.testing.expect(std.mem.indexOf(u8, evs[0].ev.data_json, "\"text\":\"All done.\"") != null);
}
