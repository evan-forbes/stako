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
    failed,

    pub fn name(self: Status) []const u8 {
        return @tagName(self);
    }

    pub fn isTerminal(self: Status) bool {
        return self == .completed or self == .failed;
    }
};

/// Filesystem completion markers for one node's `runs/<node>/` directory.
pub const Marker = struct {
    done: bool,
    result: bool,
};

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
    if (marker.done) return if (marker.result) .completed else .failed;
    var s: Status = .queued;
    for (log) |ev| {
        if (!std.mem.eql(u8, ev.node, node_name)) continue;
        switch (ev.event) {
            .delivered => s = .running,
            .completed, .failed => s = .failed,
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

test "delivered without terminal marker is running; nothing is queued" {
    const delivered = [_]events.Event{.{ .event = .delivered, .node = "n" }};
    try testing.expectEqual(Status.running, try statusFor(one_node, "n", &.{.{ .done = false, .result = false }}, &delivered));
    try testing.expectEqual(Status.queued, try statusFor(one_node, "n", &.{.{ .done = false, .result = false }}, &.{}));
}

test "a failed event without a done marker is failed" {
    const log = [_]events.Event{ .{ .event = .delivered, .node = "n" }, .{ .event = .failed, .node = "n", .reason = "timeout" } };
    try testing.expectEqual(Status.failed, try statusFor(one_node, "n", &.{.{ .done = false, .result = false }}, &log));
}

test "a completed event without the done marker is an inconsistent failure" {
    // The runner only emits `completed` after writing `done`, so a `completed`
    // event with no `done` marker means the marker was lost. It must not be
    // `completed` (no durable result.md to hand downstream) and must not be a
    // perpetual `running`; it is a terminal `failed`.
    const log = [_]events.Event{ .{ .event = .delivered, .node = "n" }, .{ .event = .completed, .node = "n", .result = "runs/n/result.md" } };
    try testing.expectEqual(Status.failed, try statusFor(one_node, "n", &.{.{ .done = false, .result = false }}, &log));
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
}
