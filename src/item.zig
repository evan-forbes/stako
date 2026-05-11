//! Stack item file format: typed schema, reader, writer, and validator.
//!
//! See:
//!   - `todos/design_stack_item_format.md` for the schema and item kinds.
//!   - `todos/design_state_machine.md` for the status enum.
//!
//! Round-trip strategy: read produces an `Item` plus an arena for owned
//! string storage. Write emits keys in a canonical, hand-coded order. Fixtures
//! are authored in that canonical order, so read→write is byte-stable for
//! every fixture in the test suite.

const std = @import("std");
const toml = @import("toml.zig");
const state = @import("state.zig");

pub const Status = state.Status;

pub const Kind = enum {
    prompt,
    compact,
    clear,
    sleep,
    review,

    pub fn fromString(s: []const u8) ?Kind {
        const map = .{
            .{ "prompt", Kind.prompt },
            .{ "compact", Kind.compact },
            .{ "clear", Kind.clear },
            .{ "sleep", Kind.sleep },
            .{ "review", Kind.review },
        };
        inline for (map) |pair| {
            if (std.mem.eql(u8, s, pair[0])) return pair[1];
        }
        return null;
    }

    pub fn toString(self: Kind) []const u8 {
        return switch (self) {
            .prompt => "prompt",
            .compact => "compact",
            .clear => "clear",
            .sleep => "sleep",
            .review => "review",
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
    workdir: ?[]const u8 = null,
};

pub const Requires = struct {
    tools: ?[]const []const u8 = null,
    capabilities: ?[]const []const u8 = null,
    max_context_tokens: ?i64 = null,
};

pub const Sleep = struct {
    until: []const u8, // RFC3339 datetime literal
};

/// `clear` has no fields per design doc, but the table itself signals
/// "this item has clear semantics". The presence flag is tracked on Item.
pub const Clear = struct {};

pub const Result = struct {
    harness: ?[]const u8 = null,
    model: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    session_file: ?[]const u8 = null,
    transcript_path: ?[]const u8 = null,
    exit_code: ?i64 = null,
    completed_at: ?[]const u8 = null,
};

pub const Item = struct {
    // Owning arena for any owned strings/slices in this Item; freed by deinit.
    arena: std.heap.ArenaAllocator,

    // Top-level required fields.
    id: []const u8,
    slug: []const u8,
    kind: Kind,
    status: Status,
    created_at: []const u8,
    updated_at: []const u8,

    // Optional top-level fields.
    parents: ?[]const []const u8 = null,
    blocked_reason: ?[]const u8 = null,
    failed_reason: ?[]const u8 = null,
    canceled_by: ?[]const u8 = null,
    superseded_by: ?[]const u8 = null,

    // Optional tables. `clear_present` is true iff `[clear]` appeared.
    target: ?Target = null,
    requires: ?Requires = null,
    sleep: ?Sleep = null,
    clear_present: bool = false,
    result: ?Result = null,

    pub fn deinit(self: *Item) void {
        self.arena.deinit();
    }
};

pub const ParseError = error{
    Toml,
    MissingField,
    UnknownKind,
    UnknownStatus,
    UnknownMatch,
    InvalidDatetime,
    InvalidIdFormat,
    InvalidSlugFormat,
    InvalidParentId,
    InvalidStateTransition,
    InvalidSleep,
    MissingSleepTable,
    MissingTargetTable,
    UnexpectedTable,
    BadType,
    OutOfMemory,
};

pub const ParseDiagnostic = struct {
    err: ParseError = error.Toml,
    /// Static description of what went wrong. Lifetime is process-wide
    /// (string literal).
    message: []const u8 = "",
    /// Field/table name relevant to the error, if any. May be empty.
    field: []const u8 = "",

    pub fn format(self: ParseDiagnostic, w: anytype) !void {
        try w.print("{s}: {s}", .{ @errorName(self.err), self.message });
        if (self.field.len > 0) try w.print(" (field: {s})", .{self.field});
    }
};

// ---------- reader ----------

pub fn parseSlice(
    allocator: std.mem.Allocator,
    source: []const u8,
    diag: *ParseDiagnostic,
) ParseError!Item {
    var doc = toml.parse(allocator, source) catch |e| {
        diag.* = .{ .err = ParseError.Toml, .message = "TOML parse failed", .field = @errorName(e) };
        return error.Toml;
    };
    defer doc.deinit();

    var item: Item = .{
        .arena = std.heap.ArenaAllocator.init(allocator),
        .id = "",
        .slug = "",
        .kind = .prompt,
        .status = .queued,
        .created_at = "",
        .updated_at = "",
    };
    errdefer item.deinit();
    const arena = item.arena.allocator();

    var have_id = false;
    var have_slug = false;
    var have_kind = false;
    var have_status = false;
    var have_created = false;
    var have_updated = false;

    var target_provider: ?[]const u8 = null;
    var target_model: ?[]const u8 = null;
    var target_match: ?Match = null;
    var target_workdir: ?[]const u8 = null;
    const have_target = doc.hasTable("target");

    var req_tools: ?[]const []const u8 = null;
    var req_caps: ?[]const []const u8 = null;
    var req_mct: ?i64 = null;
    const have_requires = doc.hasTable("requires");

    var sleep_until: ?[]const u8 = null;
    const have_sleep_table = doc.hasTable("sleep");

    const have_clear_table = doc.hasTable("clear");

    var result_obj = Result{};
    const have_result = doc.hasTable("result");

    for (doc.entries.items) |e| {
        if (std.mem.eql(u8, e.table, "")) {
            if (std.mem.eql(u8, e.key, "id")) {
                item.id = try arena.dupe(u8, try requireString(e.value, "id", diag));
                have_id = true;
            } else if (std.mem.eql(u8, e.key, "slug")) {
                item.slug = try arena.dupe(u8, try requireString(e.value, "slug", diag));
                have_slug = true;
            } else if (std.mem.eql(u8, e.key, "kind")) {
                const s = try requireString(e.value, "kind", diag);
                item.kind = Kind.fromString(s) orelse {
                    diag.* = .{ .err = ParseError.UnknownKind, .message = "unknown kind value", .field = "kind" };
                    return error.UnknownKind;
                };
                have_kind = true;
            } else if (std.mem.eql(u8, e.key, "status")) {
                const s = try requireString(e.value, "status", diag);
                item.status = Status.fromString(s) orelse {
                    diag.* = .{ .err = ParseError.UnknownStatus, .message = "unknown status value", .field = "status" };
                    return error.UnknownStatus;
                };
                have_status = true;
            } else if (std.mem.eql(u8, e.key, "created_at")) {
                item.created_at = try arena.dupe(u8, try requireDatetime(e.value, "created_at", diag));
                have_created = true;
            } else if (std.mem.eql(u8, e.key, "updated_at")) {
                item.updated_at = try arena.dupe(u8, try requireDatetime(e.value, "updated_at", diag));
                have_updated = true;
            } else if (std.mem.eql(u8, e.key, "parents")) {
                const arr = try requireStringArray(e.value, "parents", diag);
                item.parents = try dupeStringArray(arena, arr);
            } else if (std.mem.eql(u8, e.key, "blocked_reason")) {
                item.blocked_reason = try arena.dupe(u8, try requireString(e.value, "blocked_reason", diag));
            } else if (std.mem.eql(u8, e.key, "failed_reason")) {
                item.failed_reason = try arena.dupe(u8, try requireString(e.value, "failed_reason", diag));
            } else if (std.mem.eql(u8, e.key, "canceled_by")) {
                item.canceled_by = try arena.dupe(u8, try requireString(e.value, "canceled_by", diag));
            } else if (std.mem.eql(u8, e.key, "superseded_by")) {
                item.superseded_by = try arena.dupe(u8, try requireString(e.value, "superseded_by", diag));
            } else {
                // Unknown top-level keys are tolerated for forward-compatibility.
            }
        } else if (std.mem.eql(u8, e.table, "target")) {
            if (std.mem.eql(u8, e.key, "provider")) {
                target_provider = try arena.dupe(u8, try requireString(e.value, "target.provider", diag));
            } else if (std.mem.eql(u8, e.key, "model")) {
                target_model = try arena.dupe(u8, try requireString(e.value, "target.model", diag));
            } else if (std.mem.eql(u8, e.key, "match")) {
                const s = try requireString(e.value, "target.match", diag);
                target_match = Match.fromString(s) orelse {
                    diag.* = .{ .err = ParseError.UnknownMatch, .message = "unknown target.match value", .field = "target.match" };
                    return error.UnknownMatch;
                };
            } else if (std.mem.eql(u8, e.key, "workdir")) {
                target_workdir = try arena.dupe(u8, try requireString(e.value, "target.workdir", diag));
            }
        } else if (std.mem.eql(u8, e.table, "requires")) {
            if (std.mem.eql(u8, e.key, "tools")) {
                const arr = try requireStringArray(e.value, "requires.tools", diag);
                req_tools = try dupeStringArray(arena, arr);
            } else if (std.mem.eql(u8, e.key, "capabilities")) {
                const arr = try requireStringArray(e.value, "requires.capabilities", diag);
                req_caps = try dupeStringArray(arena, arr);
            } else if (std.mem.eql(u8, e.key, "max_context_tokens")) {
                req_mct = try requireInt(e.value, "requires.max_context_tokens", diag);
            }
        } else if (std.mem.eql(u8, e.table, "sleep")) {
            if (std.mem.eql(u8, e.key, "until")) {
                sleep_until = try arena.dupe(u8, try requireDatetime(e.value, "sleep.until", diag));
            }
        } else if (std.mem.eql(u8, e.table, "clear")) {
            // clear table is empty per design — any keys here are ignored.
        } else if (std.mem.eql(u8, e.table, "result")) {
            if (std.mem.eql(u8, e.key, "harness")) {
                result_obj.harness = try arena.dupe(u8, try requireString(e.value, "result.harness", diag));
            } else if (std.mem.eql(u8, e.key, "model")) {
                result_obj.model = try arena.dupe(u8, try requireString(e.value, "result.model", diag));
            } else if (std.mem.eql(u8, e.key, "session_id")) {
                result_obj.session_id = try arena.dupe(u8, try requireString(e.value, "result.session_id", diag));
            } else if (std.mem.eql(u8, e.key, "session_file")) {
                result_obj.session_file = try arena.dupe(u8, try requireString(e.value, "result.session_file", diag));
            } else if (std.mem.eql(u8, e.key, "transcript_path")) {
                result_obj.transcript_path = try arena.dupe(u8, try requireString(e.value, "result.transcript_path", diag));
            } else if (std.mem.eql(u8, e.key, "exit_code")) {
                result_obj.exit_code = try requireInt(e.value, "result.exit_code", diag);
            } else if (std.mem.eql(u8, e.key, "completed_at")) {
                result_obj.completed_at = try arena.dupe(u8, try requireDatetime(e.value, "result.completed_at", diag));
            }
        }
        // Tables we don't know about are accepted but ignored. The schema
        // forbids `[[arrays of tables]]`; the TOML parser doesn't produce them.
    }

    // Promote presence flags.
    if (have_target) {
        item.target = Target{
            .provider = target_provider,
            .model = target_model,
            .match = target_match,
            .workdir = target_workdir,
        };
    }
    if (have_requires) {
        item.requires = Requires{
            .tools = req_tools,
            .capabilities = req_caps,
            .max_context_tokens = req_mct,
        };
    }
    if (have_sleep_table) {
        if (sleep_until == null) {
            diag.* = .{ .err = ParseError.InvalidSleep, .message = "sleep table missing `until`", .field = "sleep.until" };
            return error.InvalidSleep;
        }
        item.sleep = Sleep{ .until = sleep_until.? };
    }
    item.clear_present = have_clear_table;
    if (have_result) item.result = result_obj;

    // Required-field check (kind-independent for top level).
    if (!have_id) return missing(diag, "id");
    if (!have_slug) return missing(diag, "slug");
    if (!have_kind) return missing(diag, "kind");
    if (!have_status) return missing(diag, "status");
    if (!have_created) return missing(diag, "created_at");
    if (!have_updated) return missing(diag, "updated_at");

    return item;
}

pub fn parseFile(
    allocator: std.mem.Allocator,
    path: []const u8,
    diag: *ParseDiagnostic,
) !Item {
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const stat = try file.stat();
    const buf = try allocator.alloc(u8, stat.size);
    defer allocator.free(buf);
    const read = try file.readAll(buf);
    return parseSlice(allocator, buf[0..read], diag);
}

fn missing(diag: *ParseDiagnostic, field: []const u8) ParseError {
    diag.* = .{ .err = ParseError.MissingField, .message = "missing required field", .field = field };
    return error.MissingField;
}

fn requireString(v: toml.Value, field: []const u8, diag: *ParseDiagnostic) ![]const u8 {
    if (v != .string) {
        diag.* = .{ .err = ParseError.BadType, .message = "expected string", .field = field };
        return error.BadType;
    }
    return v.string;
}

fn requireInt(v: toml.Value, field: []const u8, diag: *ParseDiagnostic) !i64 {
    if (v != .integer) {
        diag.* = .{ .err = ParseError.BadType, .message = "expected integer", .field = field };
        return error.BadType;
    }
    return v.integer;
}

fn requireDatetime(v: toml.Value, field: []const u8, diag: *ParseDiagnostic) ![]const u8 {
    if (v != .datetime) {
        diag.* = .{ .err = ParseError.BadType, .message = "expected datetime", .field = field };
        return error.BadType;
    }
    return v.datetime;
}

fn requireStringArray(v: toml.Value, field: []const u8, diag: *ParseDiagnostic) ![]const []const u8 {
    if (v != .string_array) {
        diag.* = .{ .err = ParseError.BadType, .message = "expected string array", .field = field };
        return error.BadType;
    }
    return v.string_array;
}

fn dupeStringArray(arena: std.mem.Allocator, src: []const []const u8) ![]const []const u8 {
    const out = try arena.alloc([]const u8, src.len);
    for (src, 0..) |s, i| out[i] = try arena.dupe(u8, s);
    return out;
}

// ---------- writer ----------

/// Serialize `item` to the writer in a canonical key order so that any item
/// read via `parseSlice` and then written produces a stable byte sequence.
pub fn write(item: *const Item, w: anytype) !void {
    // Top-level required fields, in canonical order.
    try writeKV(w, "id", .{ .string = item.id });
    try writeKV(w, "slug", .{ .string = item.slug });
    try writeKV(w, "kind", .{ .string = item.kind.toString() });
    try writeKV(w, "status", .{ .string = item.status.toString() });
    try writeKV(w, "created_at", .{ .datetime = item.created_at });
    try writeKV(w, "updated_at", .{ .datetime = item.updated_at });

    if (item.parents) |p| {
        try writeKVArray(w, "parents", p);
    }
    if (item.blocked_reason) |s| try writeKV(w, "blocked_reason", .{ .string = s });
    if (item.failed_reason) |s| try writeKV(w, "failed_reason", .{ .string = s });
    if (item.canceled_by) |s| try writeKV(w, "canceled_by", .{ .string = s });
    if (item.superseded_by) |s| try writeKV(w, "superseded_by", .{ .string = s });

    if (item.target) |t| {
        try w.writeAll("\n[target]\n");
        if (t.provider) |v| try writeKV(w, "provider", .{ .string = v });
        if (t.model) |v| try writeKV(w, "model", .{ .string = v });
        if (t.match) |v| try writeKV(w, "match", .{ .string = v.toString() });
        if (t.workdir) |v| try writeKV(w, "workdir", .{ .string = v });
    }
    if (item.requires) |r| {
        try w.writeAll("\n[requires]\n");
        if (r.tools) |v| try writeKVArray(w, "tools", v);
        if (r.capabilities) |v| try writeKVArray(w, "capabilities", v);
        if (r.max_context_tokens) |n| try writeKV(w, "max_context_tokens", .{ .integer = n });
    }
    if (item.sleep) |s| {
        try w.writeAll("\n[sleep]\n");
        try writeKV(w, "until", .{ .datetime = s.until });
    }
    if (item.clear_present) {
        try w.writeAll("\n[clear]\n");
    }
    if (item.result) |r| {
        try w.writeAll("\n[result]\n");
        if (r.harness) |v| try writeKV(w, "harness", .{ .string = v });
        if (r.model) |v| try writeKV(w, "model", .{ .string = v });
        if (r.session_id) |v| try writeKV(w, "session_id", .{ .string = v });
        if (r.session_file) |v| try writeKV(w, "session_file", .{ .string = v });
        if (r.transcript_path) |v| try writeKV(w, "transcript_path", .{ .string = v });
        if (r.exit_code) |n| try writeKV(w, "exit_code", .{ .integer = n });
        if (r.completed_at) |v| try writeKV(w, "completed_at", .{ .datetime = v });
    }
}

const WriteVal = union(enum) {
    string: []const u8,
    integer: i64,
    datetime: []const u8,
};

fn writeKV(w: anytype, key: []const u8, v: WriteVal) !void {
    try w.writeAll(key);
    try w.writeAll(" = ");
    switch (v) {
        .string => |s| try toml.writeString(w, s),
        .integer => |n| try w.print("{d}", .{n}),
        .datetime => |s| try w.writeAll(s),
    }
    try w.writeByte('\n');
}

fn writeKVArray(w: anytype, key: []const u8, items: []const []const u8) !void {
    try w.writeAll(key);
    try w.writeAll(" = ");
    try toml.writeStringArray(w, items);
    try w.writeByte('\n');
}

// ---------- validator ----------

pub const ValidationError = error{
    InvalidIdFormat,
    InvalidSlugFormat,
    InvalidParentId,
    InvalidDatetime,
    MissingSleepTable,
    MissingTargetTable,
    InvalidSleep,
    SleepHasBody,
    ClearHasBody,
    InvalidStateTransition,
};

pub const ValidationDiagnostic = struct {
    err: ValidationError = error.InvalidIdFormat,
    message: []const u8 = "",
    field: []const u8 = "",
};

/// Validate semantic constraints on a parsed item:
///   - id is 4-or-more digits, zero-padded
///   - slug is non-empty, kebab-case (lowercase ascii letters/digits/dashes)
///   - parents (if present) are well-formed id strings
///   - created_at/updated_at are RFC3339-shaped
///   - kind-specific required tables exist (per design)
///   - sleep.until is RFC3339-shaped
///
/// Status enum bounds are enforced by the parser; transitions are not
/// validated here because that requires a prior-state context — see
/// `state.isValidTransition`.
pub fn validate(item: *const Item, diag: *ValidationDiagnostic) ValidationError!void {
    if (!isValidId(item.id)) {
        diag.* = .{ .err = error.InvalidIdFormat, .message = "id must be 4+ ascii digits, zero-padded", .field = "id" };
        return error.InvalidIdFormat;
    }
    if (!isValidSlug(item.slug)) {
        diag.* = .{ .err = error.InvalidSlugFormat, .message = "slug must be lowercase kebab-case [a-z0-9-]", .field = "slug" };
        return error.InvalidSlugFormat;
    }
    if (!isRfc3339(item.created_at)) {
        diag.* = .{ .err = error.InvalidDatetime, .message = "not RFC3339 datetime", .field = "created_at" };
        return error.InvalidDatetime;
    }
    if (!isRfc3339(item.updated_at)) {
        diag.* = .{ .err = error.InvalidDatetime, .message = "not RFC3339 datetime", .field = "updated_at" };
        return error.InvalidDatetime;
    }
    if (item.parents) |ps| {
        for (ps) |p| {
            if (!isValidId(p)) {
                diag.* = .{ .err = error.InvalidParentId, .message = "parent id must be 4+ ascii digits", .field = "parents" };
                return error.InvalidParentId;
            }
        }
    }

    // Kind-specific structural constraints.
    switch (item.kind) {
        .prompt, .review => {
            if (item.target == null) {
                diag.* = .{ .err = error.MissingTargetTable, .message = "prompt/review items require [target]", .field = "target" };
                return error.MissingTargetTable;
            }
        },
        .compact => {
            if (item.target == null) {
                diag.* = .{ .err = error.MissingTargetTable, .message = "compact items require [target] (harness only)", .field = "target" };
                return error.MissingTargetTable;
            }
        },
        .sleep => {
            if (item.sleep == null) {
                diag.* = .{ .err = error.MissingSleepTable, .message = "sleep items require [sleep] with `until`", .field = "sleep" };
                return error.MissingSleepTable;
            }
            if (!isRfc3339(item.sleep.?.until)) {
                diag.* = .{ .err = error.InvalidDatetime, .message = "sleep.until must be RFC3339", .field = "sleep.until" };
                return error.InvalidDatetime;
            }
        },
        .clear => {
            // No structural requirements beyond top-level.
        },
    }

    // Workdir presence is parsed but its allowlist check is deferred to
    // milestone 6 per the plan. The validator only confirms the field is a
    // string (already enforced by the parser).
}

pub fn isValidId(id: []const u8) bool {
    if (id.len < 4) return false;
    for (id) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

pub fn isValidSlug(slug: []const u8) bool {
    if (slug.len == 0) return false;
    if (slug[0] == '-' or slug[slug.len - 1] == '-') return false;
    var prev_dash = false;
    for (slug) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '-';
        if (!ok) return false;
        if (c == '-' and prev_dash) return false;
        prev_dash = (c == '-');
    }
    return true;
}

/// Minimal RFC3339 shape check: YYYY-MM-DDTHH:MM:SS(.fff)?(Z|[+-]HH:MM)
pub fn isRfc3339(s: []const u8) bool {
    if (s.len < 20) return false;
    // Date part
    for (0..4) |i| if (!std.ascii.isDigit(s[i])) return false;
    if (s[4] != '-') return false;
    for (5..7) |i| if (!std.ascii.isDigit(s[i])) return false;
    if (s[7] != '-') return false;
    for (8..10) |i| if (!std.ascii.isDigit(s[i])) return false;
    if (s[10] != 'T' and s[10] != 't' and s[10] != ' ') return false;
    for (11..13) |i| if (!std.ascii.isDigit(s[i])) return false;
    if (s[13] != ':') return false;
    for (14..16) |i| if (!std.ascii.isDigit(s[i])) return false;
    if (s[16] != ':') return false;
    for (17..19) |i| if (!std.ascii.isDigit(s[i])) return false;
    var i: usize = 19;
    if (i < s.len and s[i] == '.') {
        i += 1;
        var any = false;
        while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) any = true;
        if (!any) return false;
    }
    if (i >= s.len) return false;
    if (s[i] == 'Z' or s[i] == 'z') {
        return i + 1 == s.len;
    }
    if (s[i] == '+' or s[i] == '-') {
        if (i + 6 != s.len) return false;
        for ((i + 1)..(i + 3)) |j| if (!std.ascii.isDigit(s[j])) return false;
        if (s[i + 3] != ':') return false;
        for ((i + 4)..(i + 6)) |j| if (!std.ascii.isDigit(s[j])) return false;
        return true;
    }
    return false;
}

// ---------- unit tests (internal) ----------

test "isValidId" {
    try std.testing.expect(isValidId("0001"));
    try std.testing.expect(isValidId("12345"));
    try std.testing.expect(!isValidId("001")); // too short
    try std.testing.expect(!isValidId("00a1"));
    try std.testing.expect(!isValidId(""));
}

test "isValidSlug" {
    try std.testing.expect(isValidSlug("hello"));
    try std.testing.expect(isValidSlug("fix-router-validation"));
    try std.testing.expect(isValidSlug("a-b-c1"));
    try std.testing.expect(!isValidSlug(""));
    try std.testing.expect(!isValidSlug("-leading"));
    try std.testing.expect(!isValidSlug("trailing-"));
    try std.testing.expect(!isValidSlug("double--dash"));
    try std.testing.expect(!isValidSlug("UpperCase"));
    try std.testing.expect(!isValidSlug("space here"));
    try std.testing.expect(!isValidSlug("snake_case"));
}

test "isRfc3339" {
    try std.testing.expect(isRfc3339("2026-05-10T14:32:00Z"));
    try std.testing.expect(isRfc3339("2026-05-10T14:32:00.123Z"));
    try std.testing.expect(isRfc3339("2026-05-10T14:32:00+02:00"));
    try std.testing.expect(isRfc3339("2026-05-10T14:32:00-08:00"));
    try std.testing.expect(!isRfc3339("2026-05-10"));
    try std.testing.expect(!isRfc3339("yesterday"));
    try std.testing.expect(!isRfc3339("2026-05-10T14:32:00")); // missing offset
}
