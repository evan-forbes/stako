//! Claude Code adapter (milestone 7).
//!
//! Parses the JSONL emitted by `claude -p <prompt> --output-format stream-json
//! --verbose --include-partial-messages` and maps each event onto stako's
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
const adapter_json = @import("adapter_json.zig");
const events = @import("events.zig");

const stripEol = adapter_json.stripEol;
const findStringValue = adapter_json.findStringValue;
const findTopLevelStringValue = adapter_json.findTopLevelStringValue;
const findObjectValue = adapter_json.findObjectValue;
const findArrayValue = adapter_json.findArrayValue;
const findMatchingBraceEnd = adapter_json.findMatchingBraceEnd;
const jsonEscape = adapter_json.jsonEscape;
const writeParsedJsonStringContent = adapter_json.writeParsedJsonStringContent;

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
    /// `Bash` tool_use ids that have not yet seen a matching `tool_result`.
    /// We use this to defer the `command_executed` emission until the real
    /// exit signal (`is_error`) arrives, since the `tool_use` line itself
    /// carries no exit code. Keyed by tool_use id; value is the duplicated
    /// command string.
    pending_bash: std.StringHashMapUnmanaged([]u8) = .{},

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        if (self.session_id.len > 0) allocator.free(self.session_id);
        if (self.model.len > 0) allocator.free(self.model);
        if (self.session_file.len > 0) allocator.free(self.session_file);
        var it = self.pending_bash.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        self.pending_bash.deinit(allocator);
    }
};

const ClaudeEventType = enum {
    system,
    assistant,
    user,
    stream_event,
    result,
    unknown,

    fn fromString(s: []const u8) ClaudeEventType {
        if (std.mem.eql(u8, s, "system")) return .system;
        if (std.mem.eql(u8, s, "assistant")) return .assistant;
        if (std.mem.eql(u8, s, "user")) return .user;
        if (std.mem.eql(u8, s, "stream_event")) return .stream_event;
        if (std.mem.eql(u8, s, "result")) return .result;
        return .unknown;
    }
};

const ClaudeStreamEventType = enum {
    message_start,
    content_block_delta,
    message_stop,
    unknown,

    fn fromString(s: []const u8) ClaudeStreamEventType {
        if (std.mem.eql(u8, s, "message_start")) return .message_start;
        if (std.mem.eql(u8, s, "content_block_delta")) return .content_block_delta;
        if (std.mem.eql(u8, s, "message_stop")) return .message_stop;
        return .unknown;
    }
};

const ClaudeContentBlockType = enum {
    text,
    tool_use,
    tool_result,
    unknown,

    fn fromString(s: []const u8) ClaudeContentBlockType {
        if (std.mem.eql(u8, s, "text")) return .text;
        if (std.mem.eql(u8, s, "tool_use")) return .tool_use;
        if (std.mem.eql(u8, s, "tool_result")) return .tool_result;
        return .unknown;
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
    // Drop any deferred Bash command entries that never saw a matching
    // `tool_result`. The session is ending so we can't recover the real exit
    // code; rather than emit fabricated `command_executed` events with a
    // synthetic exit, we silently discard them — the corresponding `tool_call`
    // event was already emitted at parse time and remains in the transcript.
    {
        var it = st.pending_bash.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        st.pending_bash.clearAndFree(allocator);
    }
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

    const type_str = findTopLevelStringValue(line, "\"type\":") orelse return emitErrorList(allocator, "adapter_parse_error");

    // Build a growing list. We free already-built events on error.
    var out = std.ArrayList(adapter.OwnedEvent){};
    errdefer {
        for (out.items) |oe| adapter.freeOwned(allocator, oe);
        out.deinit(allocator);
    }

    switch (ClaudeEventType.fromString(type_str)) {
        .system => {
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
        },
        .assistant => {
            // Full assistant message landed. The `message.content` array may
            // contain text blocks and/or tool_use blocks.
            const msg = findObjectValue(line, "\"message\":") orelse {
                return out.toOwnedSlice(allocator);
            };
            // Parse `content` array.
            if (findArrayValue(msg, "\"content\":")) |arr| {
                try emitAssistantContent(allocator, &out, st, arr);
            }
        },
        .user => {
            // user-from-cli message — typically carries `tool_result` blocks.
            const msg = findObjectValue(line, "\"message\":") orelse {
                return out.toOwnedSlice(allocator);
            };
            if (findArrayValue(msg, "\"content\":")) |arr| {
                try emitToolResults(allocator, &out, st, arr);
            }
        },
        .stream_event => {
            // Partial-message stream-event passthrough. We only project the
            // most useful kinds: `message_start`, `content_block_delta` (text),
            // `message_stop`.
            const inner = findObjectValue(line, "\"event\":") orelse {
                return out.toOwnedSlice(allocator);
            };
            const ev_type = findStringValue(inner, "\"type\":") orelse "";
            switch (ClaudeStreamEventType.fromString(ev_type)) {
                .message_start => {
                    try emitTurnStarted(allocator, &out, st);
                    st.turn_index += 1;
                },
                .content_block_delta => {
                    const delta = findObjectValue(inner, "\"delta\":") orelse "{}";
                    const dtype = findStringValue(delta, "\"type\":") orelse "";
                    if (std.mem.eql(u8, dtype, "text_delta")) {
                        const t = findStringValue(delta, "\"text\":") orelse "";
                        try emitMessageChunk(allocator, &out, t, "assistant");
                    }
                },
                .message_stop => try emitTurnCompleted(allocator, &out, st),
                .unknown => {},
            }
        },
        .result => {
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
        },
        .unknown => try emitError(allocator, &out, "adapter_unknown_event"),
    }

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
        try writeParsedJsonStringContent(w, st.model);
        try w.writeAll("\"");
    }
    if (st.session_id.len > 0) {
        try w.writeAll(",\"session\":\"");
        try writeParsedJsonStringContent(w, st.session_id);
        try w.writeAll("\"");
    }
    if (cwd_opt) |c| {
        try w.writeAll(",\"cwd\":\"");
        try writeParsedJsonStringContent(w, c);
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
    try writeParsedJsonStringContent(w, text);
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
        try projectAssistantBlock(allocator, out, st, obj);
        i = obj_end;
    }
}

fn projectAssistantBlock(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(adapter.OwnedEvent),
    st: *State,
    block: []const u8,
) !void {
    switch (ClaudeContentBlockType.fromString(findStringValue(block, "\"type\":") orelse "")) {
        .text => {
            const text = findStringValue(block, "\"text\":") orelse return;
            try emitMessage(allocator, out, text, "assistant");
        },
        .tool_use => {
            const tool = findStringValue(block, "\"name\":") orelse return;
            const call_id = findStringValue(block, "\"id\":") orelse "";
            const inp_obj = findObjectValue(block, "\"input\":") orelse "{}";
            try emitToolCall(allocator, out, tool, inp_obj, call_id);
            if (std.mem.eql(u8, tool, "Edit") or std.mem.eql(u8, tool, "Write") or std.mem.eql(u8, tool, "MultiEdit")) {
                const path = findStringValue(inp_obj, "\"file_path\":") orelse "";
                const op: []const u8 = if (std.mem.eql(u8, tool, "Write")) "create" else "modify";
                try emitFileChanged(allocator, out, path, op);
            } else if (std.mem.eql(u8, tool, "Bash")) {
                const cmd = findStringValue(inp_obj, "\"command\":") orelse "";
                if (call_id.len > 0) {
                    const key = try allocator.dupe(u8, call_id);
                    errdefer allocator.free(key);
                    const val = try allocator.dupe(u8, cmd);
                    errdefer allocator.free(val);
                    const gop = try st.pending_bash.getOrPut(allocator, key);
                    if (gop.found_existing) {
                        allocator.free(key);
                        allocator.free(gop.value_ptr.*);
                        gop.value_ptr.* = val;
                    } else {
                        gop.key_ptr.* = key;
                        gop.value_ptr.* = val;
                    }
                } else {
                    try emitCommandExecuted(allocator, out, cmd, 0);
                }
            }
        },
        .tool_result, .unknown => {},
    }
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

fn emitToolResults(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(adapter.OwnedEvent),
    st: *State,
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
        if (ClaudeContentBlockType.fromString(findStringValue(obj, "\"type\":") orelse "") == .tool_result) {
            const id = findStringValue(obj, "\"tool_use_id\":") orelse "";
            const content = findStringValue(obj, "\"content\":") orelse "";
            const is_error = isErrorBool(obj);
            const ok = !is_error;
            try emitToolResultEvent(allocator, out, id, content, ok);
            // If we deferred a `command_executed` for this tool_use id (Bash),
            // emit it now with the real exit code derived from `is_error`.
            if (id.len > 0) {
                if (st.pending_bash.fetchRemove(id)) |kv| {
                    defer allocator.free(kv.key);
                    defer allocator.free(kv.value);
                    const exit_code: i32 = if (is_error) 1 else 0;
                    try emitCommandExecuted(allocator, out, kv.value, exit_code);
                }
            }
        }
        i = obj_end;
    }
}

/// Look for a top-level `"is_error":true` flag inside a tool_result object.
fn isErrorBool(obj: []const u8) bool {
    var i: usize = 0;
    var depth: usize = 0;
    var in_str = false;
    var escape = false;
    const key = "\"is_error\":";
    while (i < obj.len) : (i += 1) {
        const c = obj[i];
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
            if (depth == 1 and std.mem.startsWith(u8, obj[i..], key)) {
                var j = i + key.len;
                while (j < obj.len and (obj[j] == ' ' or obj[j] == '\t')) j += 1;
                return j < obj.len and obj[j] == 't';
            }
            in_str = true;
            continue;
        }
        if (c == '{' or c == '[') depth += 1;
        if (c == '}' or c == ']') {
            if (depth == 0) return false;
            depth -= 1;
        }
    }
    return false;
}

fn emitToolResultEvent(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(adapter.OwnedEvent),
    call_id: []const u8,
    output: []const u8,
    ok: bool,
) !void {
    var buf = std.ArrayList(u8){};
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try w.writeAll("{\"call_id\":\"");
    try writeParsedJsonStringContent(w, call_id);
    try w.writeAll("\",\"ok\":");
    try w.writeAll(if (ok) "true" else "false");
    try w.writeAll(",\"output\":\"");
    try writeParsedJsonStringContent(w, output);
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

fn emitError(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(adapter.OwnedEvent),
    msg: []const u8,
) !void {
    var buf = std.ArrayList(u8){};
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try w.writeAll("{\"message\":\"");
    try jsonEscape(w, msg);
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

test "claude: tool_use Bash defers command_executed until tool_result" {
    const a = std.testing.allocator;
    var ad = try create(a);
    defer ad.deinit(a);
    // 1) tool_use only emits a tool_call — no command_executed yet.
    const tu_line = "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"id\":\"tu_2\",\"name\":\"Bash\",\"input\":{\"command\":\"echo hi\"}}]}}\n";
    {
        const evs = try ad.parseLine(a, tu_line);
        defer adapter.freeOwnedSlice(a, evs);
        try std.testing.expectEqual(@as(usize, 1), evs.len);
        try std.testing.expectEqual(events.Kind.tool_call, evs[0].ev.kind);
    }
    // 2) tool_result with is_error=false → tool_result + command_executed{exit:0}.
    const tr_line = "{\"type\":\"user\",\"message\":{\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"tu_2\",\"content\":\"hi\\n\",\"is_error\":false}]}}\n";
    {
        const evs = try ad.parseLine(a, tr_line);
        defer adapter.freeOwnedSlice(a, evs);
        try std.testing.expectEqual(@as(usize, 2), evs.len);
        try std.testing.expectEqual(events.Kind.tool_result, evs[0].ev.kind);
        try std.testing.expect(std.mem.indexOf(u8, evs[0].ev.data_json, "\"ok\":true") != null);
        try std.testing.expectEqual(events.Kind.command_executed, evs[1].ev.kind);
        try std.testing.expect(std.mem.indexOf(u8, evs[1].ev.data_json, "\"cmd\":\"echo hi\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, evs[1].ev.data_json, "\"exit\":0") != null);
    }
}

test "claude: tool_use Bash failure surfaces exit from is_error=true" {
    const a = std.testing.allocator;
    var ad = try create(a);
    defer ad.deinit(a);
    const tu_line = "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"id\":\"tu_fail\",\"name\":\"Bash\",\"input\":{\"command\":\"false\"}}]}}\n";
    {
        const evs = try ad.parseLine(a, tu_line);
        defer adapter.freeOwnedSlice(a, evs);
        try std.testing.expectEqual(@as(usize, 1), evs.len);
        try std.testing.expectEqual(events.Kind.tool_call, evs[0].ev.kind);
    }
    const tr_line = "{\"type\":\"user\",\"message\":{\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"tu_fail\",\"content\":\"err\",\"is_error\":true}]}}\n";
    {
        const evs = try ad.parseLine(a, tr_line);
        defer adapter.freeOwnedSlice(a, evs);
        try std.testing.expectEqual(@as(usize, 2), evs.len);
        try std.testing.expectEqual(events.Kind.tool_result, evs[0].ev.kind);
        try std.testing.expect(std.mem.indexOf(u8, evs[0].ev.data_json, "\"ok\":false") != null);
        try std.testing.expectEqual(events.Kind.command_executed, evs[1].ev.kind);
        try std.testing.expect(std.mem.indexOf(u8, evs[1].ev.data_json, "\"exit\":1") != null);
    }
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

test "claude: top-level type wins over nested type fields" {
    const a = std.testing.allocator;
    var ad = try create(a);
    defer ad.deinit(a);
    const line = "{\"payload\":{\"type\":\"not-top-level\"},\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"sess-ordered\",\"model\":\"claude-opus-4-7\"}\n";
    const evs = try ad.parseLine(a, line);
    defer adapter.freeOwnedSlice(a, evs);
    try std.testing.expectEqual(@as(usize, 1), evs.len);
    try std.testing.expectEqual(events.Kind.session_started, evs[0].ev.kind);
    try std.testing.expect(std.mem.indexOf(u8, evs[0].ev.data_json, "\"session\":\"sess-ordered\"") != null);
}

test "claude: escaped provider strings preserve JSON semantics" {
    const a = std.testing.allocator;
    var ad = try create(a);
    defer ad.deinit(a);
    const line = "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"quote: \\\"ok\\\"\"}]}}\n";
    const evs = try ad.parseLine(a, line);
    defer adapter.freeOwnedSlice(a, evs);
    try std.testing.expectEqual(@as(usize, 1), evs.len);
    try std.testing.expectEqual(events.Kind.message, evs[0].ev.kind);
    try std.testing.expect(std.mem.indexOf(u8, evs[0].ev.data_json, "\"text\":\"quote: \\\"ok\\\"\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, evs[0].ev.data_json, "\\\\\\\"ok") == null);
}

test "claude: unknown top-level event emits recoverable error" {
    const a = std.testing.allocator;
    var ad = try create(a);
    defer ad.deinit(a);
    const evs = try ad.parseLine(a, "{\"type\":\"future.event\",\"data\":{}}\n");
    defer adapter.freeOwnedSlice(a, evs);
    try std.testing.expectEqual(@as(usize, 1), evs.len);
    try std.testing.expectEqual(events.Kind.@"error", evs[0].ev.kind);
    try std.testing.expect(std.mem.indexOf(u8, evs[0].ev.data_json, "\"recoverable\":true") != null);
}

test "claude: findStringValue ignores nested same-name keys (depth-1 only)" {
    // Regression for the audit-flagged first-positional bug: a buried
    // `"session_id":` inside a nested object must NOT be returned in place of
    // the top-level `"session_id":`.
    const line = "{\"type\":\"system\",\"subtype\":\"init\",\"details\":{\"session_id\":\"buried\"},\"session_id\":\"top\",\"model\":\"claude-opus-4-7\"}\n";
    const got = findStringValue(line, "\"session_id\":") orelse return error.NotFound;
    try std.testing.expectEqualStrings("top", got);
}

test "claude: parseLine prefers top-level session_id over nested buried one" {
    const a = std.testing.allocator;
    var ad = try create(a);
    defer ad.deinit(a);
    const line = "{\"type\":\"system\",\"subtype\":\"init\",\"details\":{\"session_id\":\"buried\"},\"session_id\":\"top\",\"model\":\"claude-opus-4-7\"}\n";
    const evs = try ad.parseLine(a, line);
    defer adapter.freeOwnedSlice(a, evs);
    try std.testing.expectEqual(@as(usize, 1), evs.len);
    try std.testing.expectEqual(events.Kind.session_started, evs[0].ev.kind);
    try std.testing.expect(std.mem.indexOf(u8, evs[0].ev.data_json, "\"session\":\"top\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, evs[0].ev.data_json, "buried") == null);
}

test "claude: user.tool_result maps to tool_result event with output" {
    const a = std.testing.allocator;
    var ad = try create(a);
    defer ad.deinit(a);
    const line = "{\"type\":\"user\",\"message\":{\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"tu_1\",\"content\":\"ok\"}]}}\n";
    const evs = try ad.parseLine(a, line);
    defer adapter.freeOwnedSlice(a, evs);
    try std.testing.expectEqual(@as(usize, 1), evs.len);
    try std.testing.expectEqual(events.Kind.tool_result, evs[0].ev.kind);
    try std.testing.expect(std.mem.indexOf(u8, evs[0].ev.data_json, "\"call_id\":\"tu_1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, evs[0].ev.data_json, "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, evs[0].ev.data_json, "\"output\":\"ok\"") != null);
}

test "claude: assistant message with mixed text + tool_use emits both in order" {
    const a = std.testing.allocator;
    var ad = try create(a);
    defer ad.deinit(a);
    const line = "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"Editing now.\"},{\"type\":\"tool_use\",\"id\":\"tu_mix\",\"name\":\"Edit\",\"input\":{\"file_path\":\"/tmp/m.zig\"}}]}}\n";
    const evs = try ad.parseLine(a, line);
    defer adapter.freeOwnedSlice(a, evs);
    // Expected: message (from text) + tool_call (from tool_use) + file_changed.
    try std.testing.expectEqual(@as(usize, 3), evs.len);
    try std.testing.expectEqual(events.Kind.message, evs[0].ev.kind);
    try std.testing.expectEqual(events.Kind.tool_call, evs[1].ev.kind);
    try std.testing.expectEqual(events.Kind.file_changed, evs[2].ev.kind);
}

test "claude: parseStderrLine emits one recoverable error per non-empty line" {
    const a = std.testing.allocator;
    var ad = try create(a);
    defer ad.deinit(a);
    const evs = try ad.parseStderrLine(a, "panic: borked\n");
    defer adapter.freeOwnedSlice(a, evs);
    try std.testing.expectEqual(@as(usize, 1), evs.len);
    try std.testing.expectEqual(events.Kind.@"error", evs[0].ev.kind);
    try std.testing.expect(std.mem.indexOf(u8, evs[0].ev.data_json, "panic: borked") != null);
    try std.testing.expect(std.mem.indexOf(u8, evs[0].ev.data_json, "\"recoverable\":true") != null);
}

test "claude: parseStderrLine empty line yields zero events" {
    const a = std.testing.allocator;
    var ad = try create(a);
    defer ad.deinit(a);
    const evs = try ad.parseStderrLine(a, "\n");
    defer adapter.freeOwnedSlice(a, evs);
    try std.testing.expectEqual(@as(usize, 0), evs.len);
}

test "claude: on_exit clean exit + ran_to_completion=false → canceled" {
    const a = std.testing.allocator;
    var ad = try create(a);
    defer ad.deinit(a);
    const exit_ev = try ad.onExit(a, 0, false);
    defer adapter.freeOwned(a, exit_ev);
    try std.testing.expect(std.mem.indexOf(u8, exit_ev.ev.data_json, "\"terminal_status\":\"canceled\"") != null);
}
