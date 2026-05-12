//! Canonical HTTP error responder.
//!
//! All non-2xx JSON responses share one body shape per
//! `todos/design_errors_and_audit.md`:
//!
//!     {"error": {"code": "<slug>", "message": "<human>", "details": {...}}}
//!
//! Every endpoint funnels through `respond` here; ad-hoc error bodies are
//! disallowed. Each error `code` slug has a fixed status mapping (see the
//! status-code table in the design doc).

const std = @import("std");

/// All error code slugs that ship with milestone 3. The slug → status table
/// below uses this enum so the compiler catches misses when new codes are
/// added. New codes never change the meaning of existing codes.
pub const Code = enum {
    // Validation / shape.
    validation_failed,
    invalid_kind,
    invalid_status_transition,
    unknown_field,
    // Authorization.
    identity_required,
    capability_denied,
    // HTTP method.
    method_not_allowed,
    // State / concurrency.
    not_found,
    conflict,
    state_conflict,
    vcs_conflict,
    // Preflight / runtime.
    harness_unavailable,
    harness_denied,
    auth_missing,
    workdir_denied,
    model_unsupported,
    harness_unsupported_capability,
    no_session_to_compact,
    spawn_failed,
    // Daemon.
    daemon_starting,
    harness_disabled,
    internal,

    pub fn slug(self: Code) []const u8 {
        return switch (self) {
            .validation_failed => "validation_failed",
            .invalid_kind => "invalid_kind",
            .invalid_status_transition => "invalid_status_transition",
            .unknown_field => "unknown_field",
            .identity_required => "identity_required",
            .capability_denied => "capability_denied",
            .method_not_allowed => "method_not_allowed",
            .not_found => "not_found",
            .conflict => "conflict",
            .state_conflict => "state_conflict",
            .vcs_conflict => "vcs_conflict",
            .harness_unavailable => "harness_unavailable",
            .harness_denied => "harness_denied",
            .auth_missing => "auth_missing",
            .workdir_denied => "workdir_denied",
            .model_unsupported => "model_unsupported",
            .harness_unsupported_capability => "harness_unsupported_capability",
            .no_session_to_compact => "no_session_to_compact",
            .spawn_failed => "spawn_failed",
            .daemon_starting => "daemon_starting",
            .harness_disabled => "harness_disabled",
            .internal => "internal",
        };
    }

    /// Mapping from code slug to HTTP status (see the table in
    /// `design_errors_and_audit.md`).
    pub fn httpStatus(self: Code) u16 {
        return switch (self) {
            .validation_failed, .invalid_kind, .invalid_status_transition, .unknown_field => 400,
            .identity_required => 401,
            .capability_denied => 403,
            .not_found => 404,
            .method_not_allowed => 405,
            .conflict, .state_conflict, .vcs_conflict => 409,
            .harness_unavailable, .harness_denied, .auth_missing, .workdir_denied, .model_unsupported, .harness_unsupported_capability, .no_session_to_compact, .spawn_failed => 422,
            .internal => 500,
            .daemon_starting, .harness_disabled => 503,
        };
    }
};

/// A `(key, value)` pair for the `details` object. `value` is emitted as a
/// JSON-encoded string; structured-value support can be added later.
pub const DetailKV = struct {
    key: []const u8,
    value: []const u8,
};

/// Write the canonical JSON error body to `w`. Returns the serialized bytes
/// in the caller-supplied buffer or via the writer's own buffer.
pub fn writeBody(w: anytype, code: Code, message: []const u8, details: []const DetailKV) !void {
    try w.writeAll("{\"error\":{\"code\":\"");
    try writeJsonString(w, code.slug());
    try w.writeAll("\",\"message\":\"");
    try writeJsonString(w, message);
    try w.writeAll("\"");
    if (details.len > 0) {
        try w.writeAll(",\"details\":{");
        for (details, 0..) |d, i| {
            if (i != 0) try w.writeAll(",");
            try w.writeAll("\"");
            try writeJsonString(w, d.key);
            try w.writeAll("\":\"");
            try writeJsonString(w, d.value);
            try w.writeAll("\"");
        }
        try w.writeAll("}");
    }
    try w.writeAll("}}");
}

pub fn writeJsonString(w: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0...0x08, 0x0b, 0x0c, 0x0e...0x1f => {
                var buf: [6]u8 = undefined;
                const hex = "0123456789abcdef";
                buf[0] = '\\';
                buf[1] = 'u';
                buf[2] = '0';
                buf[3] = '0';
                buf[4] = hex[(c >> 4) & 0xf];
                buf[5] = hex[c & 0xf];
                try w.writeAll(&buf);
            },
            else => try w.writeByte(c),
        }
    }
}

// ---------- unit tests ----------

test "Code: every code has a slug round-trip" {
    inline for (@typeInfo(Code).@"enum".fields) |f| {
        const c: Code = @enumFromInt(f.value);
        try std.testing.expectEqualStrings(f.name, c.slug());
    }
}

test "Code: httpStatus mapping (spot check)" {
    try std.testing.expectEqual(@as(u16, 404), Code.not_found.httpStatus());
    try std.testing.expectEqual(@as(u16, 400), Code.validation_failed.httpStatus());
    try std.testing.expectEqual(@as(u16, 401), Code.identity_required.httpStatus());
    try std.testing.expectEqual(@as(u16, 403), Code.capability_denied.httpStatus());
    try std.testing.expectEqual(@as(u16, 409), Code.state_conflict.httpStatus());
    try std.testing.expectEqual(@as(u16, 422), Code.workdir_denied.httpStatus());
    try std.testing.expectEqual(@as(u16, 500), Code.internal.httpStatus());
    try std.testing.expectEqual(@as(u16, 503), Code.daemon_starting.httpStatus());
}

test "writeBody: minimal (no details)" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeBody(&w, .not_found, "stack 'nope' not found", &.{});
    const got = buf[0..w.end];
    try std.testing.expectEqualStrings(
        "{\"error\":{\"code\":\"not_found\",\"message\":\"stack 'nope' not found\"}}",
        got,
    );
}

test "writeBody: with details" {
    var buf: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeBody(&w, .capability_denied, "identity x lacks y", &.{
        .{ .key = "identity", .value = "codex-local" },
        .{ .key = "capability", .value = "stack.default.append" },
    });
    const got = buf[0..w.end];
    try std.testing.expectEqualStrings(
        "{\"error\":{\"code\":\"capability_denied\",\"message\":\"identity x lacks y\",\"details\":{\"identity\":\"codex-local\",\"capability\":\"stack.default.append\"}}}",
        got,
    );
}

test "writeJsonString: escapes" {
    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeJsonString(&w, "a\"b\\c\nd\te");
    try std.testing.expectEqualStrings("a\\\"b\\\\c\\nd\\te", buf[0..w.end]);
}
