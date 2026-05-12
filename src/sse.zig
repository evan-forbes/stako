//! Server-Sent Events multiplexer (milestone 6).
//!
//! One `Hub` per daemon. Each stack-level event stream is a separate
//! subscriber list. A subscriber is a callback (a closure that owns a
//! socket or a memory buffer); the hub fans out each emitted event by
//! calling every active subscriber.
//!
//! Per design (`design_web_view.md`): no replay buffer in v1; subscribers
//! only see events from connection time. The hub is event-bus-pattern, not
//! a queue — a slow subscriber doesn't back up other subscribers, but it
//! does block the publishing thread for the duration of its callback. The
//! session manager runs its own writer thread per session, so blocking
//! across SSE subscribers only affects that one session's pacing.

const std = @import("std");
const events = @import("events.zig");
const audit = @import("audit.zig");

pub const Sink = struct {
    /// Pointer to an arbitrary per-subscriber state.
    ctx: *anyopaque,
    /// Called once per event. Returning an error removes the subscriber.
    write_fn: *const fn (ctx: *anyopaque, line: []const u8) anyerror!void,
};

pub const Subscription = struct {
    id: u64,
    stack: []u8,
    sink: Sink,
    active: bool = true,
    ref_count: usize = 0,
};

/// Hub state. Safe to access from multiple threads under its internal mutex.
pub const Hub = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    subs: std.ArrayList(*Subscription) = .{},
    retired: std.ArrayList(*Subscription) = .{},
    next_id: u64 = 1,

    pub fn init(allocator: std.mem.Allocator) Hub {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Hub) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.subs.items) |s| {
            while (s.ref_count > 0) self.cond.wait(&self.mutex);
            self.destroySubscription(s);
        }
        for (self.retired.items) |s| {
            while (s.ref_count > 0) self.cond.wait(&self.mutex);
            self.destroySubscription(s);
        }
        self.subs.deinit(self.allocator);
        self.retired.deinit(self.allocator);
    }

    /// Subscribe to one stack's events. Caller owns the returned pointer
    /// and must call `unsubscribe` (or wait for `deinit`).
    pub fn subscribe(self: *Hub, stack: []const u8, sink: Sink) !*Subscription {
        const sub = try self.allocator.create(Subscription);
        errdefer self.allocator.destroy(sub);
        sub.* = .{
            .id = 0,
            .stack = try self.allocator.dupe(u8, stack),
            .sink = sink,
        };
        errdefer self.allocator.free(sub.stack);

        self.mutex.lock();
        defer self.mutex.unlock();
        sub.id = self.next_id;
        self.next_id += 1;
        try self.subs.append(self.allocator, sub);
        return sub;
    }

    pub fn unsubscribe(self: *Hub, sub: *Subscription) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.removeActiveLocked(sub)) {
            sub.active = false;
        } else if (!self.removeRetiredLocked(sub)) {
            return;
        }
        while (sub.ref_count > 0) self.cond.wait(&self.mutex);
        self.destroySubscription(sub);
    }

    /// Publish a single event to all subscribers of `event.stack`. Errors
    /// from sinks remove that subscriber from the list silently.
    ///
    /// Sink contract — IMPORTANT for future sink authors:
    /// The sink callback (`Sink.write_fn`) is invoked WITHOUT the hub
    /// mutex held, but the subscription's `ref_count` is bumped before the
    /// callback runs. The subscription pointer and its sink context stay
    /// valid for the duration of the callback. However, the sink MUST NOT
    /// call `Hub.unsubscribe` on its own subscription from inside the
    /// callback: `unsubscribe` waits on `ref_count` to reach zero, and the
    /// publish-side ref is still held — that would deadlock the publishing
    /// thread forever. To "self-cancel" from a sink, return an error from
    /// `write_fn`; the hub will retire the subscription itself.
    pub fn publish(self: *Hub, event: events.Event) !void {
        var sse_line = std.ArrayList(u8){};
        defer sse_line.deinit(self.allocator);
        // SSE protocol: `data: <json>\n\n`.
        try sse_line.appendSlice(self.allocator, "data: ");
        var ts_buf: [40]u8 = undefined;
        const ts_now = audit.nowRfc3339Millis(&ts_buf);
        var raw = std.ArrayList(u8){};
        defer raw.deinit(self.allocator);
        try events.writeEvent(raw.writer(self.allocator), event, ts_now);
        // The serialized event ends with '\n'; strip it before the SSE blank
        // line terminator.
        var raw_line = raw.items;
        if (raw_line.len > 0 and raw_line[raw_line.len - 1] == '\n') raw_line = raw_line[0 .. raw_line.len - 1];
        try sse_line.appendSlice(self.allocator, raw_line);
        try sse_line.appendSlice(self.allocator, "\n\n");

        // Snapshot subscriber pointers under the mutex and bump refcounts
        // before releasing it. Unsubscribe waits for those refs to drain, so
        // the subscription and its sink context stay valid during callbacks.
        self.mutex.lock();
        var snapshot = self.allocator.alloc(*Subscription, self.subs.items.len) catch {
            self.mutex.unlock();
            return;
        };
        defer self.allocator.free(snapshot);
        var n: usize = 0;
        for (self.subs.items) |s| {
            if (s.active and std.mem.eql(u8, s.stack, event.stack)) {
                s.ref_count += 1;
                snapshot[n] = s;
                n += 1;
            }
        }
        self.mutex.unlock();

        for (snapshot[0..n]) |s| {
            const failed = if (s.sink.write_fn(s.sink.ctx, sse_line.items)) |_| false else |_| true;
            self.releasePublishedSubscription(s, failed);
        }
    }

    fn releasePublishedSubscription(self: *Hub, sub: *Subscription, failed: bool) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (failed and sub.active and self.removeActiveLocked(sub)) {
            sub.active = false;
            self.retired.append(self.allocator, sub) catch {};
        }
        sub.ref_count -= 1;
        if (sub.ref_count == 0) self.cond.broadcast();
    }

    fn removeActiveLocked(self: *Hub, sub: *Subscription) bool {
        return removeFromList(&self.subs, sub);
    }

    fn removeRetiredLocked(self: *Hub, sub: *Subscription) bool {
        return removeFromList(&self.retired, sub);
    }

    fn removeFromList(list: *std.ArrayList(*Subscription), sub: *Subscription) bool {
        var i: usize = 0;
        while (i < list.items.len) : (i += 1) {
            if (list.items[i] == sub) {
                _ = list.orderedRemove(i);
                return true;
            }
        }
        return false;
    }

    fn destroySubscription(self: *Hub, sub: *Subscription) void {
        self.allocator.free(sub.stack);
        self.allocator.destroy(sub);
    }
};

// ---------- tests ----------

const CaptureCtx = struct {
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    fail_after: ?usize = null,
    writes: usize = 0,
};

fn captureWrite(ctx: *anyopaque, line: []const u8) anyerror!void {
    const c: *CaptureCtx = @ptrCast(@alignCast(ctx));
    if (c.fail_after) |limit| if (c.writes >= limit) return error.SinkFailure;
    try c.buf.appendSlice(c.allocator, line);
    c.writes += 1;
}

test "Hub: subscribe + publish + unsubscribe" {
    const a = std.testing.allocator;
    var hub = Hub.init(a);
    defer hub.deinit();

    var buf = std.ArrayList(u8){};
    defer buf.deinit(a);
    var ctx = CaptureCtx{ .buf = &buf, .allocator = a };
    const sub = try hub.subscribe("demo", .{ .ctx = &ctx, .write_fn = captureWrite });

    try hub.publish(.{
        .ts = "2026-05-10T14:00:00.000Z",
        .stack = "demo",
        .item = "0001",
        .kind = .session_started,
        .data_json = "{\"harness\":\"fake\"}",
    });
    try std.testing.expect(std.mem.startsWith(u8, buf.items, "data: "));
    try std.testing.expect(std.mem.endsWith(u8, buf.items, "\n\n"));
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"kind\":\"session_started\"") != null);

    hub.unsubscribe(sub);
    buf.clearRetainingCapacity();
    try hub.publish(.{
        .ts = "2026-05-10T14:00:00.001Z",
        .stack = "demo",
        .item = "0001",
        .kind = .message,
    });
    // No subscriber → no bytes.
    try std.testing.expectEqual(@as(usize, 0), buf.items.len);
}

test "Hub: subscriber for different stack is not notified" {
    const a = std.testing.allocator;
    var hub = Hub.init(a);
    defer hub.deinit();

    var buf = std.ArrayList(u8){};
    defer buf.deinit(a);
    var ctx = CaptureCtx{ .buf = &buf, .allocator = a };
    _ = try hub.subscribe("other", .{ .ctx = &ctx, .write_fn = captureWrite });

    try hub.publish(.{
        .stack = "demo",
        .item = "0001",
        .kind = .session_started,
    });
    try std.testing.expectEqual(@as(usize, 0), buf.items.len);
}

test "Hub: failing sink is auto-removed" {
    const a = std.testing.allocator;
    var hub = Hub.init(a);
    defer hub.deinit();

    var buf = std.ArrayList(u8){};
    defer buf.deinit(a);
    var ctx = CaptureCtx{ .buf = &buf, .allocator = a, .fail_after = 1 };
    const sub = try hub.subscribe("demo", .{ .ctx = &ctx, .write_fn = captureWrite });

    try hub.publish(.{ .stack = "demo", .item = "0001", .kind = .session_started });
    try hub.publish(.{ .stack = "demo", .item = "0001", .kind = .message });
    // Second publish should have triggered SinkFailure → subscriber removed.
    try std.testing.expectEqual(@as(usize, 0), hub.subs.items.len);
    hub.unsubscribe(sub);
}
