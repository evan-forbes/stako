//! Status enum and transition table for stack items.
//!
//! Canonical source: `todos/design_state_machine.md`. This module owns the
//! Zig representation; the validator and (later) the daemon must consult
//! `isValidTransition` before writing any new status.

const std = @import("std");

pub const Status = enum {
    queued,
    running,
    paused,
    blocked,
    failed,
    completed,
    canceled,
    superseded,

    pub fn fromString(s: []const u8) ?Status {
        const map = .{
            .{ "queued", Status.queued },
            .{ "running", Status.running },
            .{ "paused", Status.paused },
            .{ "blocked", Status.blocked },
            .{ "failed", Status.failed },
            .{ "completed", Status.completed },
            .{ "canceled", Status.canceled },
            .{ "superseded", Status.superseded },
        };
        inline for (map) |pair| {
            if (std.mem.eql(u8, s, pair[0])) return pair[1];
        }
        return null;
    }

    pub fn toString(self: Status) []const u8 {
        return switch (self) {
            .queued => "queued",
            .running => "running",
            .paused => "paused",
            .blocked => "blocked",
            .failed => "failed",
            .completed => "completed",
            .canceled => "canceled",
            .superseded => "superseded",
        };
    }

    pub fn isTerminal(self: Status) bool {
        return switch (self) {
            .completed, .failed, .canceled, .superseded => true,
            else => false,
        };
    }
};

/// Transitions listed verbatim from `design_state_machine.md`. The trigger
/// column is informational only at this layer; transitions are validated
/// purely on (from, to) pairs.
pub const VALID_TRANSITIONS = [_]struct { from: Status, to: Status }{
    .{ .from = .queued, .to = .running },
    .{ .from = .queued, .to = .blocked },
    .{ .from = .queued, .to = .canceled },
    .{ .from = .queued, .to = .superseded },
    .{ .from = .queued, .to = .paused },
    .{ .from = .running, .to = .completed },
    .{ .from = .running, .to = .failed },
    .{ .from = .running, .to = .canceled },
    .{ .from = .paused, .to = .queued },
    .{ .from = .paused, .to = .canceled },
    .{ .from = .blocked, .to = .queued },
    .{ .from = .blocked, .to = .canceled },
};

pub fn isValidTransition(from: Status, to: Status) bool {
    if (from == to) return false; // identity transitions are not "transitions"
    for (VALID_TRANSITIONS) |t| {
        if (t.from == from and t.to == to) return true;
    }
    return false;
}

test "status round-trip via string" {
    inline for (.{ "queued", "running", "paused", "blocked", "failed", "completed", "canceled", "superseded" }) |name| {
        const s = Status.fromString(name).?;
        try std.testing.expectEqualStrings(name, s.toString());
    }
}

test "unknown status string returns null" {
    try std.testing.expect(Status.fromString("hello") == null);
    try std.testing.expect(Status.fromString("") == null);
}

test "valid transitions" {
    try std.testing.expect(isValidTransition(.queued, .running));
    try std.testing.expect(isValidTransition(.queued, .canceled));
    try std.testing.expect(isValidTransition(.running, .completed));
    try std.testing.expect(isValidTransition(.running, .failed));
    try std.testing.expect(isValidTransition(.running, .canceled));
    try std.testing.expect(isValidTransition(.paused, .queued));
    try std.testing.expect(isValidTransition(.blocked, .queued));
}

test "invalid transitions" {
    // No transitions out of terminals.
    try std.testing.expect(!isValidTransition(.completed, .queued));
    try std.testing.expect(!isValidTransition(.failed, .queued));
    try std.testing.expect(!isValidTransition(.canceled, .running));
    try std.testing.expect(!isValidTransition(.superseded, .queued));
    // No direct queued -> completed.
    try std.testing.expect(!isValidTransition(.queued, .completed));
    // No direct queued -> failed.
    try std.testing.expect(!isValidTransition(.queued, .failed));
    // No running -> queued.
    try std.testing.expect(!isValidTransition(.running, .queued));
    // No paused -> running directly (must re-queue first).
    try std.testing.expect(!isValidTransition(.paused, .running));
    // Identity.
    try std.testing.expect(!isValidTransition(.queued, .queued));
}

test "terminal predicate" {
    try std.testing.expect(Status.completed.isTerminal());
    try std.testing.expect(Status.failed.isTerminal());
    try std.testing.expect(Status.canceled.isTerminal());
    try std.testing.expect(Status.superseded.isTerminal());
    try std.testing.expect(!Status.queued.isTerminal());
    try std.testing.expect(!Status.running.isTerminal());
    try std.testing.expect(!Status.paused.isTerminal());
    try std.testing.expect(!Status.blocked.isTerminal());
}
