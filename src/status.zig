//! Computed runtime status. There is no stored status: each node's state is
//! derived from the graph plus filesystem completion markers plus the event
//! log, exactly as `09_unified_authoring_model.md` specifies. This module is the
//! pure projection; the store gathers markers and events from disk and the
//! scheduler turns these statuses into deliverable work.

const std = @import("std");
const plan = @import("plan.zig");
const events = @import("events.zig");

pub const Status = enum {
    queued,
    running,
    completed,
    blocked,
    failed,

    pub fn name(self: Status) []const u8 {
        return @tagName(self);
    }

    pub fn isTerminal(self: Status) bool {
        return self == .completed or self == .blocked or self == .failed;
    }
};

pub const Verdict = enum {
    none,
    pass,
    followups,
    fail,
};

pub const ResultClassification = struct {
    status: Status,
    verdict: Verdict = .none,
};

/// Filesystem completion markers for one node's `runs/<node>/` directory.
pub const Marker = struct {
    done: bool,
    result: bool,
    /// Result bytes when the caller read them. `null` means the caller only
    /// knows the file exists, which keeps older unit tests and probes simple.
    result_text: ?[]const u8 = null,
};

/// Classify a durable result body. Structured headers are preferred; legacy
/// first-line tokens remain accepted for older prompts.
pub fn classifyResult(text: []const u8) ResultClassification {
    const first = firstLine(text);
    const trimmed = std.mem.trim(u8, first, " \t\r");
    if (startsWithIgnoreCase(trimmed, "stako-status:")) {
        const value = std.mem.trim(u8, trimmed["stako-status:".len..], " \t\r");
        var verdict: Verdict = .none;
        if (secondStructuredLine(text)) |line| {
            const vline = std.mem.trim(u8, line, " \t\r");
            if (startsWithIgnoreCase(vline, "stako-verdict:")) {
                const v = std.mem.trim(u8, vline["stako-verdict:".len..], " \t\r");
                if (std.ascii.eqlIgnoreCase(v, "pass")) verdict = .pass;
                if (std.ascii.eqlIgnoreCase(v, "followups")) verdict = .followups;
                if (std.ascii.eqlIgnoreCase(v, "fail")) verdict = .fail;
            }
        }
        if (std.ascii.eqlIgnoreCase(value, "done")) return .{ .status = .completed, .verdict = verdict };
        if (std.ascii.eqlIgnoreCase(value, "blocked")) return .{ .status = .blocked, .verdict = verdict };
        if (std.ascii.eqlIgnoreCase(value, "failed")) return .{ .status = .failed, .verdict = verdict };
        return .{ .status = .failed, .verdict = verdict };
    }

    if (std.mem.eql(u8, trimmed, "PASS")) return .{ .status = .completed, .verdict = .pass };
    if (std.mem.eql(u8, trimmed, "FOLLOWUPS REQUIRED")) return .{ .status = .blocked, .verdict = .followups };
    if (std.mem.startsWith(u8, trimmed, "BLOCKED")) return .{ .status = .blocked };
    if (std.mem.eql(u8, trimmed, "FAILED") or std.mem.eql(u8, trimmed, "FAIL")) return .{ .status = .failed, .verdict = .fail };
    if (std.mem.trim(u8, text, " \t\r\n").len != 0) return .{ .status = .completed };
    return .{ .status = .failed };
}

/// Compute status for every node, parallel to `plan.nodes`. `markers` is
/// parallel to `plan.nodes`; `events` is the whole log. Caller owns the slice.
pub fn computeAlloc(
    gpa: std.mem.Allocator,
    p: *const plan.Plan,
    markers: []const Marker,
    log: []const events.Event,
) ![]Status {
    // Caller owns returned memory.
    std.debug.assert(markers.len == p.nodes.len);
    const out = try gpa.alloc(Status, p.nodes.len);
    for (p.nodes, 0..) |node, i| {
        out[i] = nodeStatus(markers[i], node.name, log);
    }
    return out;
}

/// Status for a single node. The filesystem completion marker is the *only*
/// thing that can make a node `completed`: `done` with a result is `completed`,
/// `done` without one is `failed`. Without a `done` marker we fall to the event
/// log, which supplies the non-terminal `running` state.
///
/// A `completed` event reaches this loop only when the `done` marker is absent —
/// but the runner writes `done` *before* it ever emits `completed`, so that
/// combination is an inconsistency (a lost/clobbered marker), not a live node.
/// Projecting it as `failed` is correct on both counts: it is terminal, so the
/// runner stops polling a stale artifact state instead of treating the node as
/// running forever; and `failed` never satisfies a blocker, so it cannot unblock
/// downstream work without a durable `result.md`.
pub fn nodeStatus(marker: Marker, node_name: []const u8, log: []const events.Event) Status {
    if (marker.done) {
        if (!marker.result) return .failed;
        if (marker.result_text) |text| return classifyResult(text).status;
        return .completed;
    }
    var s: Status = .queued;
    for (log) |ev| {
        if (!std.mem.eql(u8, ev.node, node_name)) continue;
        switch (ev.event) {
            .delivered => s = .running,
            .blocked => s = .blocked,
            .completed, .failed => s = .failed,
            .reset => s = .queued,
            else => {},
        }
    }
    return s;
}

/// True when no node on `thread` is currently running.
pub fn threadIdle(p: *const plan.Plan, statuses: []const Status, thread: []const u8) bool {
    for (p.nodes, 0..) |node, i| {
        if (statuses[i] == .running and std.mem.eql(u8, node.thread, thread)) return false;
    }
    return true;
}

/// True when every blocker of `node` is `completed`.
pub fn blockersComplete(p: *const plan.Plan, statuses: []const Status, node: *const plan.Node) bool {
    for (node.blocked_by) |b| {
        const idx = indexOf(p, b) orelse return false;
        if (statuses[idx] != .completed) return false;
    }
    return true;
}

fn indexOf(p: *const plan.Plan, name: []const u8) ?usize {
    for (p.nodes, 0..) |node, i| {
        if (std.mem.eql(u8, node.name, name)) return i;
    }
    return null;
}

fn firstLine(text: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    return text[0..end];
}

fn secondStructuredLine(text: []const u8) ?[]const u8 {
    const first_end = std.mem.indexOfScalar(u8, text, '\n') orelse return null;
    const rest = text[first_end + 1 ..];
    const second_end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
    return rest[0..second_end];
}

fn startsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return haystack.len >= needle.len and std.ascii.eqlIgnoreCase(haystack[0..needle.len], needle);
}

// ---------- tests ----------

const testing = std.testing;

fn statusFor(src: []const u8, node: []const u8, markers: []const Marker, log: []const events.Event) !Status {
    var p = try plan.parse(testing.allocator, src);
    defer p.deinit();
    const statuses = try computeAlloc(testing.allocator, &p, markers, log);
    defer testing.allocator.free(statuses);
    const idx = indexOf(&p, node).?;
    return statuses[idx];
}

const one_node =
    \\[[thread]]
    \\name = "impl"
    \\command = "codex"
    \\
    \\[[prompt]]
    \\name = "n"
    \\thread = "impl"
    \\
;

test "done with result is completed; done without result is failed" {
    try testing.expectEqual(Status.completed, try statusFor(one_node, "n", &.{.{ .done = true, .result = true }}, &.{}));
    try testing.expectEqual(Status.failed, try statusFor(one_node, "n", &.{.{ .done = true, .result = false }}, &.{}));
}

test "result classifier maps structured and legacy outputs" {
    try testing.expectEqual(Status.completed, classifyResult("stako-status: done\nstako-verdict: pass\nPASS\n").status);
    try testing.expectEqual(Verdict.pass, classifyResult("stako-status: done\nstako-verdict: pass\nPASS\n").verdict);
    try testing.expectEqual(Status.blocked, classifyResult("stako-status: blocked\nstako-verdict: followups\n").status);
    try testing.expectEqual(Status.failed, classifyResult("stako-status: failed\n").status);
    try testing.expectEqual(Status.completed, classifyResult("PASS\nlooks good\n").status);
    try testing.expectEqual(Status.blocked, classifyResult("FOLLOWUPS REQUIRED\nfix x\n").status);
    try testing.expectEqual(Status.blocked, classifyResult("BLOCKED waiting on access\n").status);
    try testing.expectEqual(Status.failed, classifyResult("FAIL\n").status);
    try testing.expectEqual(Status.completed, classifyResult("legacy result text\n").status);
    try testing.expectEqual(Status.failed, classifyResult("").status);
}

test "done marker classifies result quality" {
    try testing.expectEqual(Status.blocked, try statusFor(one_node, "n", &.{.{ .done = true, .result = true, .result_text = "FOLLOWUPS REQUIRED\n" }}, &.{}));
    try testing.expectEqual(Status.failed, try statusFor(one_node, "n", &.{.{ .done = true, .result = true, .result_text = "" }}, &.{}));
}

test "delivered without terminal marker is running; nothing is queued" {
    const delivered = [_]events.Event{.{ .event = .delivered, .node = "n" }};
    try testing.expectEqual(Status.running, try statusFor(one_node, "n", &.{.{ .done = false, .result = false }}, &delivered));
    try testing.expectEqual(Status.queued, try statusFor(one_node, "n", &.{.{ .done = false, .result = false }}, &.{}));
}

test "a failed event without a done marker is failed" {
    const log = [_]events.Event{ .{ .event = .delivered, .node = "n" }, .{ .event = .failed, .node = "n", .reason = "timeout" } };
    try testing.expectEqual(Status.failed, try statusFor(one_node, "n", &.{.{ .done = false, .result = false }}, &log));
}

test "a blocked event without a done marker is blocked" {
    const log = [_]events.Event{ .{ .event = .delivered, .node = "n" }, .{ .event = .blocked, .node = "n", .reason = "result_blocked" } };
    try testing.expectEqual(Status.blocked, try statusFor(one_node, "n", &.{.{ .done = false, .result = false }}, &log));
}

test "a completed event without the done marker is an inconsistent failure" {
    // The runner only emits `completed` after writing `done`, so a `completed`
    // event with no `done` marker means the marker was lost. It must not be
    // `completed` (no durable result.md to hand downstream) and must not be a
    // perpetual `running`; it is a terminal `failed`.
    const log = [_]events.Event{ .{ .event = .delivered, .node = "n" }, .{ .event = .completed, .node = "n", .result = "runs/n/result.md" } };
    try testing.expectEqual(Status.failed, try statusFor(one_node, "n", &.{.{ .done = false, .result = false }}, &log));
}

test "a reset event after a terminal event returns the node to queued" {
    // `stako reset` deletes the run markers and appends a `reset` event. With the
    // markers gone the projection replays the log, and `reset` — being the last
    // event for the node — overrides the earlier delivered/completed.
    const after_completed = [_]events.Event{
        .{ .event = .delivered, .node = "n" },
        .{ .event = .completed, .node = "n", .result = "runs/n/result.md" },
        .{ .event = .reset, .node = "n" },
    };
    try testing.expectEqual(Status.queued, try statusFor(one_node, "n", &.{.{ .done = false, .result = false }}, &after_completed));

    // A redelivery after the reset makes it running again.
    const redelivered = after_completed ++ [_]events.Event{.{ .event = .delivered, .node = "n" }};
    try testing.expectEqual(Status.running, try statusFor(one_node, "n", &.{.{ .done = false, .result = false }}, &redelivered));
}

test "thread idle and blockers-complete helpers" {
    const src =
        \\[[thread]]
        \\name = "impl"
        \\command = "codex"
        \\
        \\[[prompt]]
        \\name = "a"
        \\thread = "impl"
        \\
        \\[[prompt]]
        \\name = "b"
        \\thread = "impl"
        \\blocked_by = ["a"]
        \\
    ;
    var p = try plan.parse(testing.allocator, src);
    defer p.deinit();

    // a running, b queued: thread is busy, b's blocker not complete.
    {
        const statuses = [_]Status{ .running, .queued };
        try testing.expect(!threadIdle(&p, &statuses, "impl"));
        try testing.expect(!blockersComplete(&p, &statuses, p.nodeByName("b").?));
    }
    // a completed: thread idle, b's blocker complete.
    {
        const statuses = [_]Status{ .completed, .queued };
        try testing.expect(threadIdle(&p, &statuses, "impl"));
        try testing.expect(blockersComplete(&p, &statuses, p.nodeByName("b").?));
    }
    // blocked and failed are terminal but do not satisfy downstream blockers.
    {
        const blocked_statuses = [_]Status{ .blocked, .queued };
        try testing.expect(threadIdle(&p, &blocked_statuses, "impl"));
        try testing.expect(!blockersComplete(&p, &blocked_statuses, p.nodeByName("b").?));
        const failed_statuses = [_]Status{ .failed, .queued };
        try testing.expect(threadIdle(&p, &failed_statuses, "impl"));
        try testing.expect(!blockersComplete(&p, &failed_statuses, p.nodeByName("b").?));
    }
}
