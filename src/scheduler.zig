const std = @import("std");
const store = @import("store.zig");

pub fn readyRunsAlloc(allocator: std.mem.Allocator, runs: []const store.PromptRun) ![]const []const u8 {
    // Caller owns returned memory.
    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |id| allocator.free(id);
        out.deinit(allocator);
    }

    for (runs) |run| {
        if (run.status != .queued) continue;
        if (!depsComplete(runs, run.after)) continue;
        if (!depsComplete(runs, run.inputs)) continue;
        if (!firstQueuedOnThread(runs, &run)) continue;
        try out.append(allocator, try allocator.dupe(u8, run.id));
    }
    return out.toOwnedSlice(allocator);
}

fn depsComplete(runs: []const store.PromptRun, deps: []const []const u8) bool {
    for (deps) |dep| {
        var found = false;
        for (runs) |run| {
            if (!std.mem.eql(u8, run.id, dep)) continue;
            found = true;
            if (run.status != .completed) return false;
            break;
        }
        if (!found) return false;
    }
    return true;
}

fn firstQueuedOnThread(runs: []const store.PromptRun, target: *const store.PromptRun) bool {
    for (runs) |run| {
        if (!std.mem.eql(u8, run.thread, target.thread)) continue;
        if (std.mem.eql(u8, run.id, target.id)) return true;
        if (run.status == .queued or run.status == .running or run.status == .blocked) return false;
    }
    return true;
}

test "same-thread prompts serialize while different threads can start together" {
    const a = std.testing.allocator;
    var runs = [_]store.PromptRun{
        fakeRun(a, "a", "builder", 1, .queued, &.{}),
        fakeRun(a, "b", "builder", 2, .queued, &.{}),
        fakeRun(a, "c", "reviewer", 3, .queued, &.{}),
    };
    defer for (&runs) |*r| r.deinit();

    const ready = try readyRunsAlloc(a, &runs);
    defer {
        for (ready) |id| a.free(id);
        a.free(ready);
    }
    try std.testing.expectEqual(@as(usize, 2), ready.len);
    try std.testing.expectEqualStrings("a", ready[0]);
    try std.testing.expectEqualStrings("c", ready[1]);
}

test "after dependency blocks until dependency completes" {
    const a = std.testing.allocator;
    var runs = [_]store.PromptRun{
        fakeRun(a, "plan", "planner", 1, .running, &.{}),
        fakeRun(a, "impl", "builder", 2, .queued, &.{"plan"}),
    };
    defer for (&runs) |*r| r.deinit();

    {
        const ready = try readyRunsAlloc(a, &runs);
        defer freeReady(a, ready);
        try std.testing.expectEqual(@as(usize, 0), ready.len);
    }

    runs[0].status = .completed;
    {
        const ready = try readyRunsAlloc(a, &runs);
        defer freeReady(a, ready);
        try std.testing.expectEqual(@as(usize, 1), ready.len);
        try std.testing.expectEqualStrings("impl", ready[0]);
    }
}

test "input result blocks until source prompt completes" {
    const a = std.testing.allocator;
    var runs = [_]store.PromptRun{
        fakeRunWithInputs(a, "review", "reviewer", 1, .running, &.{}, &.{}),
        fakeRunWithInputs(a, "impl", "builder", 2, .queued, &.{}, &.{"review"}),
    };
    defer for (&runs) |*r| r.deinit();

    {
        const ready = try readyRunsAlloc(a, &runs);
        defer freeReady(a, ready);
        try std.testing.expectEqual(@as(usize, 0), ready.len);
    }

    runs[0].status = .completed;
    {
        const ready = try readyRunsAlloc(a, &runs);
        defer freeReady(a, ready);
        try std.testing.expectEqual(@as(usize, 1), ready.len);
        try std.testing.expectEqualStrings("impl", ready[0]);
    }
}

fn fakeRun(a: std.mem.Allocator, id: []const u8, thread: []const u8, order: u64, status: store.PromptStatus, deps: []const []const u8) store.PromptRun {
    return fakeRunWithInputs(a, id, thread, order, status, deps, &.{});
}

fn fakeRunWithInputs(a: std.mem.Allocator, id: []const u8, thread: []const u8, order: u64, status: store.PromptStatus, deps: []const []const u8, inputs: []const []const u8) store.PromptRun {
    return .{
        .allocator = a,
        .id = a.dupe(u8, id) catch unreachable,
        .thread = a.dupe(u8, thread) catch unreachable,
        .action = .none,
        .after = dupeDeps(a, deps),
        .inputs = dupeDeps(a, inputs),
        .order = order,
        .status = status,
        .snapshot = a.dupe(u8, "") catch unreachable,
        .rendered = a.dupe(u8, "") catch unreachable,
        .output = a.dupe(u8, "") catch unreachable,
    };
}

fn dupeDeps(a: std.mem.Allocator, deps: []const []const u8) []const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (deps) |dep| out.append(a, a.dupe(u8, dep) catch unreachable) catch unreachable;
    return out.toOwnedSlice(a) catch unreachable;
}

fn freeReady(a: std.mem.Allocator, ready: []const []const u8) void {
    for (ready) |id| a.free(id);
    a.free(ready);
}
