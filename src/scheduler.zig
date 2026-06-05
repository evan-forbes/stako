//! Scheduling over the `plan.toml` graph. Readiness is derived from computed
//! status: for each idle thread, deliver the earliest-emitted node whose
//! `blocked_by` are all complete. A blocked earlier node on a thread is skipped
//! rather than blocking it — this is what removes the prior follow-up deadlock.

const std = @import("std");
const plan = @import("plan.zig");
const status = @import("status.zig");

/// Indices into `p.nodes` that should be delivered now. At most one node per
/// thread is returned per pass; the next pass picks up the next once that one is
/// running. Caller owns the returned slice.
pub fn deliverableAlloc(gpa: std.mem.Allocator, p: *const plan.Plan, statuses: []const status.Status) ![]usize {
    // Caller owns returned memory.
    var out: std.ArrayList(usize) = .empty;
    errdefer out.deinit(gpa);
    for (p.nodes, 0..) |*node, i| {
        if (statuses[i] != .queued) continue;
        if (!status.threadIdle(p, statuses, node.thread)) continue;
        if (!status.blockersComplete(p, statuses, node)) continue;
        if (threadAlreadyChosen(p, out.items, node.thread)) continue;
        try out.append(gpa, i);
    }
    return out.toOwnedSlice(gpa);
}

fn threadAlreadyChosen(p: *const plan.Plan, chosen: []const usize, thread: []const u8) bool {
    for (chosen) |idx| {
        if (std.mem.eql(u8, p.nodes[idx].thread, thread)) return true;
    }
    return false;
}

// ---------- tests ----------

const deliverable_plan =
    \\[[thread]]
    \\name = "impl"
    \\command = "codex"
    \\
    \\[[thread]]
    \\name = "other"
    \\command = "codex"
    \\
    \\[[prompt]]
    \\name = "a"
    \\thread = "impl"
    \\blocked_by = ["x"]
    \\
    \\[[prompt]]
    \\name = "b"
    \\thread = "impl"
    \\
    \\[[prompt]]
    \\name = "x"
    \\thread = "other"
    \\
;

test "deliverable skips a blocked earlier node for a ready later node on the same thread" {
    const a = std.testing.allocator;
    var p = try plan.parse(a, deliverable_plan);
    defer p.deinit();

    // All queued: a is blocked by x (incomplete), b is ready, x is ready.
    {
        const statuses = [_]status.Status{ .queued, .queued, .queued };
        const got = try deliverableAlloc(a, &p, &statuses);
        defer a.free(got);
        try std.testing.expectEqual(@as(usize, 2), got.len);
        try std.testing.expectEqualStrings("b", p.nodes[got[0]].name);
        try std.testing.expectEqualStrings("x", p.nodes[got[1]].name);
    }

    // x completed: a's blocker is satisfied, so a (earliest on impl) becomes the
    // single deliverable for that thread; b waits behind it.
    {
        const statuses = [_]status.Status{ .queued, .queued, .completed };
        const got = try deliverableAlloc(a, &p, &statuses);
        defer a.free(got);
        try std.testing.expectEqual(@as(usize, 1), got.len);
        try std.testing.expectEqualStrings("a", p.nodes[got[0]].name);
    }
}

test "a running node makes its thread ineligible" {
    const a = std.testing.allocator;
    var p = try plan.parse(a, deliverable_plan);
    defer p.deinit();
    // b running on impl: no impl node is deliverable; x on other still is.
    const statuses = [_]status.Status{ .queued, .running, .queued };
    const got = try deliverableAlloc(a, &p, &statuses);
    defer a.free(got);
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expectEqualStrings("x", p.nodes[got[0]].name);
}
