//! Durable stack thread file format.
//!
//! Thread files live at `stacks/<stack>/threads/<name>.toml`. They are stack
//! content, parsed and written canonically like item metadata.

const std = @import("std");
const toml = @import("toml.zig");

pub const Status = enum {
    active,
    archived,

    pub fn fromString(s: []const u8) ?Status {
        if (std.mem.eql(u8, s, "active")) return .active;
        if (std.mem.eql(u8, s, "archived")) return .archived;
        return null;
    }

    pub fn toString(self: Status) []const u8 {
        return switch (self) {
            .active => "active",
            .archived => "archived",
        };
    }
};

pub const Match = enum {
    exact,
    compatible,
    any,

    pub fn fromString(s: []const u8) ?Match {
        if (std.mem.eql(u8, s, "exact")) return .exact;
        if (std.mem.eql(u8, s, "compatible")) return .compatible;
        if (std.mem.eql(u8, s, "any")) return .any;
        return null;
    }

    pub fn toString(self: Match) []const u8 {
        return switch (self) {
            .exact => "exact",
            .compatible => "compatible",
            .any => "any",
        };
    }
};

pub const Target = struct {
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
    match: ?Match = null,
};

pub const State = struct {
    last_item_id: ?[]const u8 = null,
    last_harness: ?[]const u8 = null,
    last_session_id: ?[]const u8 = null,
    last_session_file: ?[]const u8 = null,
    last_transcript_path: ?[]const u8 = null,
};

pub const Thread = struct {
    arena: std.heap.ArenaAllocator,

    version: i64 = 1,
    name: []const u8,
    created_at: []const u8,
    updated_at: []const u8,
    status: Status = .active,
    target: ?Target = null,
    state: ?State = null,

    pub fn deinit(self: *Thread) void {
        self.arena.deinit();
    }
};

pub const ParseError = error{
    Toml,
    MissingField,
    BadType,
    UnknownStatus,
    UnknownMatch,
    InvalidName,
    InvalidVersion,
    OutOfMemory,
};

pub const ParseDiagnostic = struct {
    err: ParseError = error.Toml,
    message: []const u8 = "",
    field: []const u8 = "",
};

pub fn isValidName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (name[0] == '.' or name[0] == '-' or name[0] == '_') return false;
    if (name[name.len - 1] == '-' or name[name.len - 1] == '_') return false;
    var prev_sep = false;
    for (name) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '-' or c == '_';
        if (!ok) return false;
        const sep = c == '-' or c == '_';
        if (sep and prev_sep) return false;
        prev_sep = sep;
    }
    return true;
}

pub fn parseSlice(
    allocator: std.mem.Allocator,
    source: []const u8,
    diag: *ParseDiagnostic,
) ParseError!Thread {
    var doc = toml.parse(allocator, source) catch |e| {
        diag.* = .{ .err = error.Toml, .message = "TOML parse failed", .field = @errorName(e) };
        return error.Toml;
    };
    defer doc.deinit();

    var thread: Thread = .{
        .arena = std.heap.ArenaAllocator.init(allocator),
        .name = "",
        .created_at = "",
        .updated_at = "",
    };
    errdefer thread.deinit();
    const arena = thread.arena.allocator();

    var have_version = false;
    var have_name = false;
    var have_created = false;
    var have_updated = false;
    var have_status = false;

    var target = Target{};
    const have_target = doc.hasTable("target");
    var state = State{};
    const have_state = doc.hasTable("state");

    for (doc.entries.items) |e| {
        if (std.mem.eql(u8, e.table, "")) {
            if (std.mem.eql(u8, e.key, "version")) {
                thread.version = try requireInt(e.value, "version", diag);
                if (thread.version != 1) {
                    diag.* = .{ .err = error.InvalidVersion, .message = "unsupported thread version", .field = "version" };
                    return error.InvalidVersion;
                }
                have_version = true;
            } else if (std.mem.eql(u8, e.key, "name")) {
                thread.name = try arena.dupe(u8, try requireString(e.value, "name", diag));
                have_name = true;
            } else if (std.mem.eql(u8, e.key, "created_at")) {
                thread.created_at = try arena.dupe(u8, try requireDatetime(e.value, "created_at", diag));
                have_created = true;
            } else if (std.mem.eql(u8, e.key, "updated_at")) {
                thread.updated_at = try arena.dupe(u8, try requireDatetime(e.value, "updated_at", diag));
                have_updated = true;
            } else if (std.mem.eql(u8, e.key, "status")) {
                const s = try requireString(e.value, "status", diag);
                thread.status = Status.fromString(s) orelse {
                    diag.* = .{ .err = error.UnknownStatus, .message = "unknown status", .field = "status" };
                    return error.UnknownStatus;
                };
                have_status = true;
            }
        } else if (std.mem.eql(u8, e.table, "target")) {
            if (std.mem.eql(u8, e.key, "provider")) {
                target.provider = try arena.dupe(u8, try requireString(e.value, "target.provider", diag));
            } else if (std.mem.eql(u8, e.key, "model")) {
                target.model = try arena.dupe(u8, try requireString(e.value, "target.model", diag));
            } else if (std.mem.eql(u8, e.key, "match")) {
                const s = try requireString(e.value, "target.match", diag);
                target.match = Match.fromString(s) orelse {
                    diag.* = .{ .err = error.UnknownMatch, .message = "unknown target.match", .field = "target.match" };
                    return error.UnknownMatch;
                };
            }
        } else if (std.mem.eql(u8, e.table, "state")) {
            if (std.mem.eql(u8, e.key, "last_item_id")) {
                state.last_item_id = try arena.dupe(u8, try requireString(e.value, "state.last_item_id", diag));
            } else if (std.mem.eql(u8, e.key, "last_harness")) {
                state.last_harness = try arena.dupe(u8, try requireString(e.value, "state.last_harness", diag));
            } else if (std.mem.eql(u8, e.key, "last_session_id")) {
                state.last_session_id = try arena.dupe(u8, try requireString(e.value, "state.last_session_id", diag));
            } else if (std.mem.eql(u8, e.key, "last_session_file")) {
                state.last_session_file = try arena.dupe(u8, try requireString(e.value, "state.last_session_file", diag));
            } else if (std.mem.eql(u8, e.key, "last_transcript_path")) {
                state.last_transcript_path = try arena.dupe(u8, try requireString(e.value, "state.last_transcript_path", diag));
            }
        }
    }

    if (!have_version) return missing(diag, "version");
    if (!have_name) return missing(diag, "name");
    if (!have_created) return missing(diag, "created_at");
    if (!have_updated) return missing(diag, "updated_at");
    if (!have_status) return missing(diag, "status");
    if (!isValidName(thread.name)) {
        diag.* = .{ .err = error.InvalidName, .message = "invalid thread name", .field = "name" };
        return error.InvalidName;
    }
    if (have_target) thread.target = target;
    if (have_state) thread.state = state;
    return thread;
}

pub fn write(thread: *const Thread, w: anytype) !void {
    try w.writeAll("version = 1\n");
    try writeStringKv(w, "name", thread.name);
    try w.writeAll("created_at = ");
    try w.writeAll(thread.created_at);
    try w.writeByte('\n');
    try w.writeAll("updated_at = ");
    try w.writeAll(thread.updated_at);
    try w.writeByte('\n');
    try writeStringKv(w, "status", thread.status.toString());

    if (thread.target) |t| {
        try w.writeAll("\n[target]\n");
        if (t.provider) |s| try writeStringKv(w, "provider", s);
        if (t.model) |s| try writeStringKv(w, "model", s);
        if (t.match) |m| try writeStringKv(w, "match", m.toString());
    }

    if (thread.state) |s| {
        try w.writeAll("\n[state]\n");
        if (s.last_item_id) |v| try writeStringKv(w, "last_item_id", v);
        if (s.last_harness) |v| try writeStringKv(w, "last_harness", v);
        if (s.last_session_id) |v| try writeStringKv(w, "last_session_id", v);
        if (s.last_session_file) |v| try writeStringKv(w, "last_session_file", v);
        if (s.last_transcript_path) |v| try writeStringKv(w, "last_transcript_path", v);
    }
}

fn missing(diag: *ParseDiagnostic, field: []const u8) ParseError {
    diag.* = .{ .err = error.MissingField, .message = "missing required field", .field = field };
    return error.MissingField;
}

fn requireString(v: toml.Value, field: []const u8, diag: *ParseDiagnostic) ParseError![]const u8 {
    if (v != .string) {
        diag.* = .{ .err = error.BadType, .message = "expected string", .field = field };
        return error.BadType;
    }
    return v.string;
}

fn requireDatetime(v: toml.Value, field: []const u8, diag: *ParseDiagnostic) ParseError![]const u8 {
    if (v != .datetime) {
        diag.* = .{ .err = error.BadType, .message = "expected datetime", .field = field };
        return error.BadType;
    }
    return v.datetime;
}

fn requireInt(v: toml.Value, field: []const u8, diag: *ParseDiagnostic) ParseError!i64 {
    if (v != .integer) {
        diag.* = .{ .err = error.BadType, .message = "expected integer", .field = field };
        return error.BadType;
    }
    return v.integer;
}

fn writeStringKv(w: anytype, key: []const u8, value: []const u8) !void {
    try w.writeAll(key);
    try w.writeAll(" = ");
    try toml.writeString(w, value);
    try w.writeByte('\n');
}

test "isValidName" {
    try std.testing.expect(isValidName("admin"));
    try std.testing.expect(isValidName("impl_2"));
    try std.testing.expect(isValidName("review-thread"));
    try std.testing.expect(!isValidName(""));
    try std.testing.expect(!isValidName("."));
    try std.testing.expect(!isValidName(".."));
    try std.testing.expect(!isValidName(".hidden"));
    try std.testing.expect(!isValidName("bad.name"));
    try std.testing.expect(!isValidName("bad/path"));
    try std.testing.expect(!isValidName("-bad"));
    try std.testing.expect(!isValidName("bad_"));
    try std.testing.expect(!isValidName("double--bad"));
    try std.testing.expect(!isValidName("Upper"));
}

test "parse/write round trip" {
    const src =
        \\version = 1
        \\name = "admin"
        \\created_at = 2026-05-17T12:00:00.000Z
        \\updated_at = 2026-05-17T12:00:00.000Z
        \\status = "active"
        \\
        \\[target]
        \\provider = "openai"
        \\model = "gpt-5"
        \\match = "compatible"
        \\
        \\[state]
        \\last_item_id = "0007"
        \\last_harness = "codex"
        \\last_session_id = "th-1"
        \\last_session_file = "~/.codex/sessions/1.jsonl"
        \\last_transcript_path = "stacks/demo/0007-review/transcript.jsonl"
        \\
    ;
    var diag: ParseDiagnostic = .{};
    var parsed = try parseSlice(std.testing.allocator, src, &diag);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("admin", parsed.name);
    try std.testing.expectEqual(Status.active, parsed.status);
    try std.testing.expectEqual(Match.compatible, parsed.target.?.match.?);
    try std.testing.expectEqualStrings("th-1", parsed.state.?.last_session_id.?);

    var out = std.ArrayList(u8){};
    defer out.deinit(std.testing.allocator);
    try write(&parsed, out.writer(std.testing.allocator));
    try std.testing.expectEqualStrings(src, out.items);
}

test "parse rejects invalid embedded name" {
    const src =
        \\version = 1
        \\name = "../admin"
        \\created_at = 2026-05-17T12:00:00.000Z
        \\updated_at = 2026-05-17T12:00:00.000Z
        \\status = "active"
        \\
    ;
    var diag: ParseDiagnostic = .{};
    const result = parseSlice(std.testing.allocator, src, &diag);
    try std.testing.expectError(error.InvalidName, result);
    try std.testing.expectEqualStrings("name", diag.field);
}
