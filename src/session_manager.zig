//! Session manager (milestone 6).
//!
//! Owns the registry of live subprocess sessions. Each item that the
//! runtime decides to run gets a `Session` here; on exit, the session
//! deletes its runtime file, publishes a terminal `session_ended` event,
//! and asks the mutation queue to write the terminal status transition.
//!
//! Design constraints honored:
//!
//!   - The runtime is NOT a second writer: every status change goes through
//!     the same `mutation_queue.Queue` the HTTP mutation surface uses, with
//!     a new internal `runtime_transition` request kind that the API path
//!     can't reach.
//!   - One item ↔ one subprocess.
//!   - Stdout / stderr are pumped on dedicated threads through the adapter.
//!     Normalized events fan out to the transcript file and SSE hub before
//!     status transitions are requested.
//!   - Cancellation escalates SIGINT → SIGTERM → SIGKILL per
//!     `design_execution_harness.md`.
//!
//! Test-friendliness: pump threads are deterministically joined by
//! `waitAll`; the test harness can also call `cancelAndEscalate` with
//! custom grace timings to keep wall-clock low.

const std = @import("std");
const adapter_mod = @import("adapter.zig");
const events = @import("events.zig");
const transcript_mod = @import("transcript.zig");
const sse_mod = @import("sse.zig");
const audit = @import("audit.zig");
const runtime_file = @import("runtime_file.zig");
const mutation_queue = @import("mutation_queue.zig");

pub const Error = error{
    SpawnFailed,
    AlreadyRunning,
    NotFound,
    OutOfMemory,
} || std.fs.File.OpenError;

const RunOutcome = struct {
    canceled: std.atomic.Value(bool) = .init(false),
    finished: std.atomic.Value(bool) = .init(false),
};

pub const Session = struct {
    allocator: std.mem.Allocator,
    manager: *Manager,
    stack: []u8,
    item_id: []u8,
    item_dir_abs: []u8,
    harness_name: []u8,
    adapter: adapter_mod.Adapter,
    child: std.process.Child,
    transcript: transcript_mod.Writer,
    started_at: []u8 = "",

    outcome: *RunOutcome,
    session_id: []u8 = "",
    session_id_mutex: std.Thread.Mutex = .{},

    stdout_thread: ?std.Thread = null,
    stderr_thread: ?std.Thread = null,

    fn deinit(self: *Session) void {
        if (self.stdout_thread) |t| {
            t.join();
            self.stdout_thread = null;
        }
        if (self.stderr_thread) |t| {
            t.join();
            self.stderr_thread = null;
        }
        self.transcript.deinit();
        self.adapter.deinit(self.allocator);
        self.allocator.free(self.stack);
        self.allocator.free(self.item_id);
        self.allocator.free(self.item_dir_abs);
        self.allocator.free(self.harness_name);
        if (self.session_id.len > 0) self.allocator.free(self.session_id);
        if (self.started_at.len > 0) self.allocator.free(self.started_at);
        self.allocator.destroy(self.outcome);
    }
};

pub const Manager = struct {
    allocator: std.mem.Allocator,
    notes_root_abs: []const u8,
    hub: ?*sse_mod.Hub,
    audit_writer: *audit.Writer,
    queue: *mutation_queue.Queue,

    mutex: std.Thread.Mutex = .{},
    sessions: std.ArrayList(*Session) = .{},
    finished: std.ArrayList(*Session) = .{},

    max_concurrent: usize = 8,
    running_count: usize = 0,
    slot_cv: std.Thread.Condition = .{},

    shutdown_requested: std.atomic.Value(bool) = .init(false),

    pub fn init(
        allocator: std.mem.Allocator,
        notes_root_abs: []const u8,
        hub: ?*sse_mod.Hub,
        audit_writer: *audit.Writer,
        queue: *mutation_queue.Queue,
    ) Manager {
        return .{
            .allocator = allocator,
            .notes_root_abs = notes_root_abs,
            .hub = hub,
            .audit_writer = audit_writer,
            .queue = queue,
        };
    }

    pub fn deinit(self: *Manager) void {
        self.requestShutdown();
        self.waitAll();
        self.mutex.lock();
        for (self.finished.items) |s| {
            s.deinit();
            self.allocator.destroy(s);
        }
        self.finished.deinit(self.allocator);
        // Any session that somehow survived in `sessions` (shouldn't happen
        // after waitAll, but be defensive) gets cleaned here.
        for (self.sessions.items) |s| {
            s.deinit();
            self.allocator.destroy(s);
        }
        self.sessions.deinit(self.allocator);
        self.mutex.unlock();
    }

    pub fn requestShutdown(self: *Manager) void {
        self.shutdown_requested.store(true, .seq_cst);
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.sessions.items) |s| {
            s.outcome.canceled.store(true, .seq_cst);
            sendSigint(s.child.id);
        }
        self.slot_cv.broadcast();
    }

    /// Block until every session has reaped.
    pub fn waitAll(self: *Manager) void {
        while (true) {
            self.mutex.lock();
            if (self.sessions.items.len == 0) {
                self.mutex.unlock();
                return;
            }
            const snap = self.allocator.dupe(*Session, self.sessions.items) catch {
                self.mutex.unlock();
                std.Thread.sleep(10 * std.time.ns_per_ms);
                continue;
            };
            self.mutex.unlock();
            defer self.allocator.free(snap);
            for (snap) |s| {
                // Pump threads finish themselves; we just join them.
                if (s.stdout_thread) |t| {
                    t.join();
                    s.stdout_thread = null;
                }
                if (s.stderr_thread) |t| {
                    t.join();
                    s.stderr_thread = null;
                }
            }
        }
    }

    pub const SpawnInput = struct {
        stack: []const u8,
        item_id: []const u8,
        item_dir_abs: []const u8,
        harness: []const u8,
        argv: []const []const u8,
        cwd: ?[]const u8 = null,
        adapter: adapter_mod.Adapter,
    };

    pub fn spawn(self: *Manager, input: SpawnInput) Error!*Session {
        if (self.shutdown_requested.load(.seq_cst)) return error.SpawnFailed;

        // Block until a global slot is free.
        self.mutex.lock();
        for (self.sessions.items) |s| {
            if (std.mem.eql(u8, s.stack, input.stack) and std.mem.eql(u8, s.item_id, input.item_id)) {
                self.mutex.unlock();
                return error.AlreadyRunning;
            }
        }
        while (self.running_count >= self.max_concurrent and !self.shutdown_requested.load(.seq_cst)) {
            self.slot_cv.wait(&self.mutex);
        }
        if (self.shutdown_requested.load(.seq_cst)) {
            self.mutex.unlock();
            return error.SpawnFailed;
        }
        self.running_count += 1;
        self.mutex.unlock();
        errdefer {
            self.mutex.lock();
            self.running_count -= 1;
            self.slot_cv.signal();
            self.mutex.unlock();
        }

        // Dup argv into a flat buffer.
        const argv_owned = try self.allocator.alloc([]const u8, input.argv.len);
        defer self.allocator.free(argv_owned);
        var argv_storage = std.ArrayList(u8){};
        defer argv_storage.deinit(self.allocator);
        // We need each argv[i] to be a stable slice for the spawn call. Use
        // separate allocations and free them all after spawn.
        var spawn_argv_slices = std.ArrayList([]u8){};
        defer {
            for (spawn_argv_slices.items) |s| self.allocator.free(s);
            spawn_argv_slices.deinit(self.allocator);
        }
        for (input.argv, 0..) |a, i| {
            const dup = try self.allocator.dupe(u8, a);
            try spawn_argv_slices.append(self.allocator, dup);
            argv_owned[i] = dup;
        }

        var child = std.process.Child.init(argv_owned, self.allocator);
        if (input.cwd) |c| child.cwd = c;
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        child.spawn() catch return error.SpawnFailed;

        var t = transcript_mod.Writer.init(self.allocator, input.item_dir_abs) catch {
            _ = child.kill() catch {};
            _ = child.wait() catch {};
            return error.SpawnFailed;
        };
        errdefer t.deinit();

        const outcome = try self.allocator.create(RunOutcome);
        outcome.* = .{};
        errdefer self.allocator.destroy(outcome);

        const sess = try self.allocator.create(Session);
        errdefer self.allocator.destroy(sess);

        var ts_buf: [40]u8 = undefined;
        const start_ts = audit.nowRfc3339Millis(&ts_buf);
        const start_ts_owned = try self.allocator.dupe(u8, start_ts);

        sess.* = .{
            .allocator = self.allocator,
            .manager = self,
            .stack = try self.allocator.dupe(u8, input.stack),
            .item_id = try self.allocator.dupe(u8, input.item_id),
            .item_dir_abs = try self.allocator.dupe(u8, input.item_dir_abs),
            .harness_name = try self.allocator.dupe(u8, input.harness),
            .adapter = input.adapter,
            .child = child,
            .transcript = t,
            .started_at = start_ts_owned,
            .outcome = outcome,
        };

        // Runtime file.
        runtime_file.write(self.allocator, self.notes_root_abs, input.stack, input.item_id, .{
            .pid = child.id,
            .harness = input.harness,
            .started_at = start_ts,
            .transcript_path = sess.transcript.path,
            .session_id = "",
        }) catch {};

        // Register before starting pumps so cancel() can find it.
        self.mutex.lock();
        self.sessions.append(self.allocator, sess) catch {
            self.mutex.unlock();
            _ = sess.child.kill() catch {};
            _ = sess.child.wait() catch {};
            sess.deinit();
            self.allocator.destroy(sess);
            return error.OutOfMemory;
        };
        self.mutex.unlock();

        // Audit: dispatch_harness.
        const target = std.fmt.allocPrint(self.allocator, "stack/{s}/item/{s}", .{ input.stack, input.item_id }) catch return sess;
        defer self.allocator.free(target);
        self.audit_writer.append(.{
            .identity = "system",
            .action = .dispatch_harness,
            .target = target,
            .outcome = .allowed,
        }) catch {};

        // Apply queued → running through the shared mutation queue.
        applyTransition(self.queue, .{
            .stack = input.stack,
            .id = input.item_id,
            .to = .running,
        });

        // Emit a daemon-side session_started event with start metadata.
        {
            var b = std.ArrayList(u8){};
            defer b.deinit(self.allocator);
            try b.writer(self.allocator).print("{{\"harness\":\"{s}\",\"started_at\":\"{s}\"}}", .{ input.harness, start_ts });
            const data_owned = try b.toOwnedSlice(self.allocator);
            defer self.allocator.free(data_owned);
            const ev: events.Event = .{
                .stack = sess.stack,
                .item = sess.item_id,
                .kind = .session_started,
                .data_json = data_owned,
            };
            sess.transcript.append(ev) catch {};
            if (sess.manager.hub) |h| h.publish(ev) catch {};
        }

        sess.stdout_thread = std.Thread.spawn(.{}, stdoutPump, .{sess}) catch null;
        sess.stderr_thread = std.Thread.spawn(.{}, stderrPump, .{sess}) catch null;
        return sess;
    }

    pub fn cancel(self: *Manager, stack: []const u8, item_id: []const u8) Error!void {
        const s = self.findSessionByKey(stack, item_id) orelse return error.NotFound;
        s.outcome.canceled.store(true, .seq_cst);
        sendSigint(s.child.id);
    }

    pub fn cancelAndEscalate(
        self: *Manager,
        stack: []const u8,
        item_id: []const u8,
        sigint_grace_ms: u64,
        sigterm_grace_ms: u64,
    ) Error!void {
        try self.cancel(stack, item_id);
        const s = self.findSessionByKey(stack, item_id) orelse return;

        var start = std.time.milliTimestamp();
        while (true) {
            if (!isAlive(s.child.id)) return;
            const elapsed: u64 = @intCast(@max(@as(i64, 0), std.time.milliTimestamp() - start));
            if (elapsed >= sigint_grace_ms) break;
            std.Thread.sleep(20 * std.time.ns_per_ms);
        }
        sendSigterm(s.child.id);
        start = std.time.milliTimestamp();
        while (true) {
            if (!isAlive(s.child.id)) return;
            const elapsed: u64 = @intCast(@max(@as(i64, 0), std.time.milliTimestamp() - start));
            if (elapsed >= sigterm_grace_ms) break;
            std.Thread.sleep(20 * std.time.ns_per_ms);
        }
        sendSigkill(s.child.id);
    }

    pub fn findSessionByKey(self: *Manager, stack: []const u8, item_id: []const u8) ?*Session {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.sessions.items) |s| {
            if (std.mem.eql(u8, s.stack, stack) and std.mem.eql(u8, s.item_id, item_id)) return s;
        }
        return null;
    }

    /// Called by `onExitMain` after the terminal transition. Moves the
    /// session from `sessions` to `finished` (joined later in `deinit`).
    fn markFinished(self: *Manager, sess: *Session) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var i: usize = 0;
        while (i < self.sessions.items.len) : (i += 1) {
            if (self.sessions.items[i] == sess) {
                _ = self.sessions.orderedRemove(i);
                self.finished.append(self.allocator, sess) catch {};
                if (self.running_count > 0) self.running_count -= 1;
                self.slot_cv.signal();
                return;
            }
        }
    }
};

pub const TerminalReason = enum {
    completed,
    failed,
    canceled,
};

fn applyTransition(queue: *mutation_queue.Queue, input: mutation_queue.RuntimeTransitionInput) void {
    var req = mutation_queue.Request{
        .kind = .{ .runtime_transition = input },
        .ident = .{ .identity = "system", .api_path = "runtime" },
    };
    queue.submitAndWait(&req);
    if (req.output) |*o| o.deinit();
}

fn stdoutPump(s: *Session) void {
    defer s.outcome.finished.store(true, .seq_cst);
    if (s.child.stdout) |stdout| {
        var read_buf: [4096]u8 = undefined;
        var line_buf = std.ArrayList(u8){};
        defer line_buf.deinit(s.allocator);
        while (true) {
            const n = stdout.read(&read_buf) catch break;
            if (n == 0) break;
            line_buf.appendSlice(s.allocator, read_buf[0..n]) catch break;
            while (true) {
                const nl = std.mem.indexOfScalar(u8, line_buf.items, '\n') orelse break;
                const line = line_buf.items[0 .. nl + 1];
                processStdoutLine(s, line);
                const remaining = line_buf.items[nl + 1 ..];
                std.mem.copyForwards(u8, line_buf.items, remaining);
                line_buf.shrinkRetainingCapacity(remaining.len);
            }
        }
    }
    onExitMain(s);
}

fn processStdoutLine(s: *Session, line: []const u8) void {
    const owned = s.adapter.parseLine(s.allocator, line) catch {
        return;
    };
    defer s.allocator.free(owned);
    for (owned) |oe| {
        defer adapter_mod.freeOwned(s.allocator, oe);
        var event = oe.ev;
        event.stack = s.stack;
        event.item = s.item_id;
        if (event.kind == .session_started) {
            if (extractSessionId(event.data_json)) |sid| {
                s.session_id_mutex.lock();
                if (s.session_id.len > 0) s.allocator.free(s.session_id);
                s.session_id = s.allocator.dupe(u8, sid) catch &.{};
                s.session_id_mutex.unlock();
                event.session = sid;
            }
        } else if (event.session.len == 0) {
            s.session_id_mutex.lock();
            event.session = s.session_id;
            s.session_id_mutex.unlock();
        }
        s.transcript.append(event) catch {};
        if (s.manager.hub) |h| h.publish(event) catch {};
    }
}

fn stderrPump(s: *Session) void {
    if (s.child.stderr) |stderr| {
        var read_buf: [4096]u8 = undefined;
        var line_buf = std.ArrayList(u8){};
        defer line_buf.deinit(s.allocator);
        while (true) {
            const n = stderr.read(&read_buf) catch break;
            if (n == 0) break;
            line_buf.appendSlice(s.allocator, read_buf[0..n]) catch break;
            while (true) {
                const nl = std.mem.indexOfScalar(u8, line_buf.items, '\n') orelse break;
                const line = line_buf.items[0 .. nl + 1];
                processStderrLine(s, line);
                const remaining = line_buf.items[nl + 1 ..];
                std.mem.copyForwards(u8, line_buf.items, remaining);
                line_buf.shrinkRetainingCapacity(remaining.len);
            }
        }
    }
}

fn processStderrLine(s: *Session, line: []const u8) void {
    const owned = s.adapter.parseStderrLine(s.allocator, line) catch return;
    defer s.allocator.free(owned);
    for (owned) |oe| {
        defer adapter_mod.freeOwned(s.allocator, oe);
        var event = oe.ev;
        event.stack = s.stack;
        event.item = s.item_id;
        s.session_id_mutex.lock();
        if (event.session.len == 0) event.session = s.session_id;
        s.session_id_mutex.unlock();
        s.transcript.append(event) catch {};
        if (s.manager.hub) |h| h.publish(event) catch {};
    }
}

fn onExitMain(s: *Session) void {
    const term = s.child.wait() catch return;
    const exit_code: i32 = switch (term) {
        .Exited => |c| @as(i32, c),
        .Signal => |c| -@as(i32, @intCast(c)),
        else => 1,
    };
    const canceled = s.outcome.canceled.load(.seq_cst);
    const ran_to_completion = !canceled and term == .Exited;

    const ev = s.adapter.onExit(s.allocator, exit_code, ran_to_completion) catch return;
    {
        defer adapter_mod.freeOwned(s.allocator, ev);
        var event = ev.ev;
        event.stack = s.stack;
        event.item = s.item_id;
        s.session_id_mutex.lock();
        if (event.session.len == 0) event.session = s.session_id;
        s.session_id_mutex.unlock();
        s.transcript.append(event) catch {};
        if (s.manager.hub) |h| h.publish(event) catch {};
    }

    runtime_file.deleteFor(s.allocator, s.manager.notes_root_abs, s.stack, s.item_id) catch {};

    const tag: mutation_queue.RuntimeTargetStatus = blk: {
        if (canceled) break :blk .canceled;
        if (exit_code == 0) break :blk .completed;
        break :blk .failed;
    };
    var input: mutation_queue.RuntimeTransitionInput = .{
        .stack = s.stack,
        .id = s.item_id,
        .to = tag,
    };
    if (tag == .failed) input.failed_reason = "subprocess_nonzero_exit";
    if (tag == .canceled) input.canceled_by = "system";
    applyTransition(s.manager.queue, input);

    s.manager.markFinished(s);
}

fn extractSessionId(data_json: []const u8) ?[]const u8 {
    const key = "\"session\":\"";
    const idx = std.mem.indexOf(u8, data_json, key) orelse return null;
    var i = idx + key.len;
    const start = i;
    while (i < data_json.len) : (i += 1) {
        if (data_json[i] == '"') return data_json[start..i];
    }
    return null;
}

fn sendSigint(pid: std.posix.pid_t) void {
    std.posix.kill(pid, std.posix.SIG.INT) catch {};
}
fn sendSigterm(pid: std.posix.pid_t) void {
    std.posix.kill(pid, std.posix.SIG.TERM) catch {};
}
fn sendSigkill(pid: std.posix.pid_t) void {
    std.posix.kill(pid, std.posix.SIG.KILL) catch {};
}
fn isAlive(pid: std.posix.pid_t) bool {
    std.posix.kill(pid, 0) catch |e| switch (e) {
        error.ProcessNotFound => return false,
        else => return true,
    };
    return true;
}
