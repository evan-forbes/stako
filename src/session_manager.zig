//! Session manager (milestone 6).
//!
//! Owns the registry of live subprocess sessions. Each item that the
//! runtime decides to run gets a `Session` here; on exit, the session
//! publishes a terminal `session_ended` event and asks the stack API to
//! write the terminal status transition.
//!
//! Design constraints honored:
//!
//!   - The runtime is NOT a second writer: every status change goes through
//!     the same in-process `StackClient` path the HTTP mutation surface uses,
//!     with an internal runtime transition method that the API path can't
//!     reach.
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
const item_mod = @import("item.zig");
const output_packet = @import("output_packet.zig");
const stack_mod = @import("stack.zig");

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
    adapter_owned: bool = true,
    child: std.process.Child,
    transcript: transcript_mod.Writer,
    started_at: []u8 = "",

    outcome: *RunOutcome,
    session_id: []u8 = "",
    session_id_mutex: std.Thread.Mutex = .{},
    thread_name: ?[]u8 = null,
    thread_mode: item_mod.ThreadMode = .fresh,
    resume_session_id: ?[]u8 = null,
    workdir_before: ?output_packet.WorkdirSnapshot = null,

    stdout_thread: ?std.Thread = null,
    stderr_thread: ?std.Thread = null,
    wait_thread: ?std.Thread = null,

    fn deinit(self: *Session) void {
        if (self.wait_thread) |t| {
            t.join();
            self.wait_thread = null;
        }
        joinPumpThreads(self);
        self.transcript.deinit();
        if (self.adapter_owned) self.adapter.deinit(self.allocator);
        self.allocator.free(self.stack);
        self.allocator.free(self.item_id);
        self.allocator.free(self.item_dir_abs);
        self.allocator.free(self.harness_name);
        if (self.session_id.len > 0) self.allocator.free(self.session_id);
        if (self.thread_name) |s| self.allocator.free(s);
        if (self.resume_session_id) |s| self.allocator.free(s);
        if (self.workdir_before) |*snap| snap.deinit();
        if (self.started_at.len > 0) self.allocator.free(self.started_at);
        self.allocator.destroy(self.outcome);
    }
};

pub const Manager = struct {
    allocator: std.mem.Allocator,
    notes_root_abs: []const u8,
    hub: ?*sse_mod.Hub,
    audit_writer: *audit.Writer,
    stack_registry: *stack_mod.StackRegistry,

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
        stack_registry: *stack_mod.StackRegistry,
    ) Manager {
        return .{
            .allocator = allocator,
            .notes_root_abs = notes_root_abs,
            .hub = hub,
            .audit_writer = audit_writer,
            .stack_registry = stack_registry,
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
                if (s.wait_thread) |t| {
                    t.join();
                    s.wait_thread = null;
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
        thread_name: ?[]const u8 = null,
        thread_mode: item_mod.ThreadMode = .fresh,
        resume_session_id: ?[]const u8 = null,
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
        var slot_owned = true;
        errdefer if (slot_owned) {
            self.mutex.lock();
            self.running_count -= 1;
            self.slot_cv.signal();
            self.mutex.unlock();
        };

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

        var workdir_before = output_packet.snapshotWorkdir(self.allocator, input.cwd) catch null;
        errdefer if (workdir_before) |*snap| snap.deinit();

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
        // Ownership of the transcript Writer transfers to `sess.transcript`
        // once `sess.*` is initialized below. Until then, an early-exit must
        // close the file via the local `t`. After sess is initialized we
        // null this out and rely on `Session.deinit()` instead — see
        // `transcript_in_local`.
        var transcript_in_local = true;
        errdefer if (transcript_in_local) t.deinit();

        const outcome = try self.allocator.create(RunOutcome);
        outcome.* = .{};
        // Ownership transfers to `sess.outcome` after `sess.*` init. Same
        // pattern as the transcript handle above.
        var outcome_in_local = true;
        errdefer if (outcome_in_local) self.allocator.destroy(outcome);

        const sess = try self.allocator.create(Session);
        // Ownership of the Session pointer transfers to either:
        //   (a) the Manager's `sessions` list (registered branch below), or
        //   (b) the local manual-cleanup branch on append-failure.
        // While `sess_owned` is true the errdefer destroys the pointer.
        var sess_owned = true;
        errdefer if (sess_owned) self.allocator.destroy(sess);

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
            .thread_name = if (input.thread_name) |s| try self.allocator.dupe(u8, s) else null,
            .thread_mode = input.thread_mode,
            .resume_session_id = if (input.resume_session_id) |s| try self.allocator.dupe(u8, s) else null,
            .workdir_before = workdir_before,
        };
        workdir_before = null;
        // Resources are now owned by `sess` — let `sess.deinit()` handle
        // them and prevent the local errdefers from double-freeing.
        transcript_in_local = false;
        outcome_in_local = false;

        // Register before starting pumps so cancel() can find it.
        self.mutex.lock();
        self.sessions.append(self.allocator, sess) catch {
            self.mutex.unlock();
            _ = sess.child.kill() catch {};
            _ = sess.child.wait() catch {};
            // `sess.deinit()` handles transcript + outcome + duped strings.
            // The adapter is owned by the caller on this failure path.
            sess.adapter_owned = false;
            sess.deinit();
            self.allocator.destroy(sess);
            sess_owned = false;
            return error.OutOfMemory;
        };
        // The Manager's `sessions` list now owns the pointer. From here on
        // any error path must go through `cleanupRegisteredSpawnFailure`,
        // which handles both list removal and `sess` destruction.
        sess_owned = false;
        self.mutex.unlock();

        // Audit: dispatch_harness.
        if (std.fmt.allocPrint(self.allocator, "stack/{s}/item/{s}", .{ input.stack, input.item_id })) |target| {
            defer self.allocator.free(target);
            self.audit_writer.append(.{
                .identity = "system",
                .action = .dispatch_harness,
                .target = target,
                .outcome = .allowed,
            }) catch {};
        } else |_| {}

        // Apply queued → running through the shared stack API.
        applyTransition(self.stack_registry, .{
            .stack = input.stack,
            .id = input.item_id,
            .to = .running,
        });

        // Emit a daemon-side session_started event with start metadata.
        {
            var b = std.ArrayList(u8){};
            defer b.deinit(self.allocator);
            b.writer(self.allocator).print("{{\"harness\":\"{s}\",\"started_at\":\"{s}\"}}", .{ input.harness, start_ts }) catch {};
            if (b.toOwnedSlice(self.allocator)) |data_owned| {
                defer self.allocator.free(data_owned);
                const ev: events.Event = .{
                    .stack = sess.stack,
                    .item = sess.item_id,
                    .kind = .session_started,
                    .data_json = data_owned,
                };
                sess.transcript.append(ev) catch {};
                if (sess.manager.hub) |h| h.publish(ev) catch {};
            } else |_| {}
        }

        sess.stdout_thread = std.Thread.spawn(.{}, stdoutPump, .{sess}) catch {
            self.cleanupRegisteredSpawnFailure(sess);
            slot_owned = false;
            return error.SpawnFailed;
        };
        sess.stderr_thread = std.Thread.spawn(.{}, stderrPump, .{sess}) catch {
            self.cleanupRegisteredSpawnFailure(sess);
            slot_owned = false;
            return error.SpawnFailed;
        };
        sess.wait_thread = std.Thread.spawn(.{}, waitForExit, .{sess}) catch {
            self.cleanupRegisteredSpawnFailure(sess);
            slot_owned = false;
            return error.SpawnFailed;
        };
        slot_owned = false;
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

    fn cleanupRegisteredSpawnFailure(self: *Manager, sess: *Session) void {
        _ = sess.child.kill() catch {};
        _ = sess.child.wait() catch {};
        joinPumpThreads(sess);

        self.mutex.lock();
        var i: usize = 0;
        while (i < self.sessions.items.len) : (i += 1) {
            if (self.sessions.items[i] == sess) {
                _ = self.sessions.orderedRemove(i);
                break;
            }
        }
        if (self.running_count > 0) self.running_count -= 1;
        self.slot_cv.signal();
        self.mutex.unlock();

        sess.adapter_owned = false;
        sess.deinit();
        self.allocator.destroy(sess);
    }
};

pub const TerminalReason = enum {
    completed,
    failed,
    canceled,
};

fn applyTransition(registry: *stack_mod.StackRegistry, input: stack_mod.RuntimeTransitionInput) void {
    const client = registry.localClient("system", "runtime");
    switch (client.runtimeTransitionItem(input.stack, input)) {
        .ok => |ok_value| {
            var ok = ok_value;
            ok.deinit();
        },
        .err => {},
    }
}

/// Cap on a single line's buffered length. A vendor CLI emitting a
/// multi-megabyte run-on line without a newline would otherwise grow the
/// pump's per-stream `ArrayList(u8)` unboundedly — once a payload exceeds
/// this we drop the partial line and emit one `error` event so the UI
/// records the loss instead of silently swallowing it. 1 MiB comfortably
/// fits every legitimate adapter line we've measured.
pub const LINE_BUF_CAP: usize = 1 * 1024 * 1024;

/// Bounded line accumulator for the stdout/stderr pumps. Reuses
/// `std.ArrayList(u8)` for storage; the cap is enforced at every `push`
/// call. When the buffered partial line (everything after the last `\n`)
/// would exceed `cap`, the partial line is dropped wholesale and
/// `drop_bytes` accumulates the dropped count; `overflow_pending` is set
/// so the pump can emit exactly one `error` event per drop and then
/// reset.
pub const LineBuffer = struct {
    allocator: std.mem.Allocator,
    cap: usize,
    buf: std.ArrayList(u8) = .{},
    drop_bytes: u64 = 0,
    overflow_pending: bool = false,

    pub fn deinit(self: *LineBuffer) void {
        self.buf.deinit(self.allocator);
    }

    /// Append `chunk`, then enforce the cap. Complete lines already
    /// present before the cap was hit remain in the buffer and can be
    /// drained by `drainLines`; only the trailing partial line is
    /// dropped on overflow.
    pub fn push(self: *LineBuffer, chunk: []const u8) !void {
        try self.buf.appendSlice(self.allocator, chunk);
        if (self.buf.items.len <= self.cap) return;
        const partial_start: usize = blk: {
            if (std.mem.lastIndexOfScalar(u8, self.buf.items, '\n')) |last_nl| {
                break :blk last_nl + 1;
            } else {
                break :blk 0;
            }
        };
        const partial_len = self.buf.items.len - partial_start;
        if (partial_len <= self.cap) return;
        self.drop_bytes += @as(u64, partial_len);
        self.buf.shrinkRetainingCapacity(partial_start);
        self.overflow_pending = true;
    }

    /// Pop and return the next complete line (including the trailing
    /// `\n`) as a slice borrowed from the internal buffer. The returned
    /// slice is valid only until the next mutating call on this
    /// LineBuffer; copy if you need it to outlive `drainLine`.
    pub fn drainLine(self: *LineBuffer) ?[]const u8 {
        const nl = std.mem.indexOfScalar(u8, self.buf.items, '\n') orelse return null;
        return self.buf.items[0 .. nl + 1];
    }

    /// Advance past the most recently returned line. Call exactly once
    /// after each `drainLine` whose return value the caller has finished
    /// consuming.
    pub fn consumeDrainedLine(self: *LineBuffer) void {
        const nl = std.mem.indexOfScalar(u8, self.buf.items, '\n') orelse return;
        const remaining = self.buf.items[nl + 1 ..];
        std.mem.copyForwards(u8, self.buf.items, remaining);
        self.buf.shrinkRetainingCapacity(remaining.len);
    }

    /// Read-and-clear the overflow flag.
    pub fn takeOverflow(self: *LineBuffer) bool {
        const v = self.overflow_pending;
        self.overflow_pending = false;
        return v;
    }
};

fn stdoutPump(s: *Session) void {
    defer s.outcome.finished.store(true, .seq_cst);
    if (s.child.stdout) |stdout| pumpStream(s, stdout, .stdout, processStdoutLine);
}

const StreamLabel = enum { stdout, stderr };

fn pumpStream(
    s: *Session,
    file: std.fs.File,
    stream: StreamLabel,
    line_cb: *const fn (*Session, []const u8) void,
) void {
    var read_buf: [4096]u8 = undefined;
    var lb = LineBuffer{ .allocator = s.allocator, .cap = LINE_BUF_CAP };
    defer lb.deinit();
    while (true) {
        const n = file.read(&read_buf) catch break;
        if (n == 0) break;
        lb.push(read_buf[0..n]) catch break;
        while (lb.drainLine()) |line| {
            line_cb(s, line);
            lb.consumeDrainedLine();
        }
        if (lb.takeOverflow()) emitLineBufOverflow(s, stream, lb.drop_bytes);
    }
}

fn emitLineBufOverflow(s: *Session, stream: StreamLabel, dropped_total: u64) void {
    var data_buf = std.ArrayList(u8){};
    defer data_buf.deinit(s.allocator);
    data_buf.writer(s.allocator).print(
        "{{\"message\":\"line_buf_overflow\",\"stream\":\"{s}\",\"dropped_bytes_total\":{d},\"cap_bytes\":{d},\"recoverable\":true}}",
        .{ @tagName(stream), dropped_total, LINE_BUF_CAP },
    ) catch return;
    const data_owned = data_buf.toOwnedSlice(s.allocator) catch return;
    defer s.allocator.free(data_owned);
    const ev: events.Event = .{
        .stack = s.stack,
        .item = s.item_id,
        .kind = .@"error",
        .data_json = data_owned,
    };
    s.transcript.append(ev) catch {};
    if (s.manager.hub) |h| h.publish(ev) catch {};
}

fn waitForExit(s: *Session) void {
    const term = s.child.wait() catch null;
    joinPumpThreads(s);
    onExitMain(s, term);
}

fn joinPumpThreads(s: *Session) void {
    if (s.stdout_thread) |t| {
        t.join();
        s.stdout_thread = null;
    }
    if (s.stderr_thread) |t| {
        t.join();
        s.stderr_thread = null;
    }
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
    if (s.child.stderr) |stderr| pumpStream(s, stderr, .stderr, processStderrLine);
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

fn onExitMain(s: *Session, term_opt: ?std.process.Child.Term) void {
    defer s.manager.markFinished(s);

    const term = term_opt orelse std.process.Child.Term{ .Unknown = 1 };
    const exit_code: i32 = switch (term) {
        .Exited => |c| @as(i32, c),
        .Signal => |c| -@as(i32, @intCast(c)),
        else => 1,
    };
    const canceled = s.outcome.canceled.load(.seq_cst);
    const ran_to_completion = !canceled and term == .Exited;

    const maybe_ev = s.adapter.onExit(s.allocator, exit_code, ran_to_completion) catch null;
    // Snapshot adapter-captured `[result]` fields from the session_ended
    // payload BEFORE freeing the event. Each adapter emits a JSON object on
    // `data_json` whose keys are stable (`session_id`, `session_file`,
    // `model`, `exit_code`) — see claude_adapter.onExit and
    // codex_adapter.onExit. The borrowed slices below become invalid once
    // the event storage is freed, so we dupe them into local buffers that
    // outlive the apply call.
    var result_sid_owned: ?[]u8 = null;
    var result_sf_owned: ?[]u8 = null;
    var result_model_owned: ?[]u8 = null;
    defer if (result_sid_owned) |x| s.allocator.free(x);
    defer if (result_sf_owned) |x| s.allocator.free(x);
    defer if (result_model_owned) |x| s.allocator.free(x);
    if (maybe_ev) |ev| {
        if (extractJsonString(ev.ev.data_json, "\"session_id\":")) |x| {
            result_sid_owned = s.allocator.dupe(u8, x) catch null;
        }
        if (extractJsonString(ev.ev.data_json, "\"session_file\":")) |x| {
            result_sf_owned = s.allocator.dupe(u8, x) catch null;
        }
        if (extractJsonString(ev.ev.data_json, "\"model\":")) |x| {
            result_model_owned = s.allocator.dupe(u8, x) catch null;
        }
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

    const tag: stack_mod.RuntimeTargetStatus = blk: {
        if (canceled) break :blk .canceled;
        if (exit_code == 0) break :blk .completed;
        break :blk .failed;
    };

    // Compose terminal `[result]` block from the adapter's captured state.
    // Fall back to the session_id snooped from `session_started` if the
    // session_ended payload omitted it.
    var sid_fallback_owned: ?[]u8 = null;
    defer if (sid_fallback_owned) |x| s.allocator.free(x);
    s.session_id_mutex.lock();
    if (result_sid_owned == null and s.session_id.len > 0) {
        sid_fallback_owned = s.allocator.dupe(u8, s.session_id) catch null;
    }
    s.session_id_mutex.unlock();
    const sid_for_result: ?[]const u8 = blk: {
        if (result_sid_owned) |x| break :blk x;
        if (sid_fallback_owned) |x| break :blk x;
        break :blk null;
    };

    var ts_buf: [40]u8 = undefined;
    const completed_at = audit.nowRfc3339Millis(&ts_buf);

    var input: stack_mod.RuntimeTransitionInput = .{
        .stack = s.stack,
        .id = s.item_id,
        .to = tag,
        .result_harness = s.harness_name,
        .result_model = if (result_model_owned) |x| x else null,
        .result_session_id = sid_for_result,
        .result_session_file = if (result_sf_owned) |x| x else null,
        .result_transcript_path = "../transcript.jsonl",
        .result_exit_code = @as(i64, exit_code),
        .result_completed_at = completed_at,
    };
    const summary_owned: ?[]u8 = output_packet.summaryFromTranscript(s.allocator, s.transcript.path) catch null;
    defer if (summary_owned) |x| s.allocator.free(x);
    var workdir_after = output_packet.snapshotWorkdir(s.allocator, null) catch null;
    if (s.workdir_before) |before| {
        if (before.root) |root| {
            if (workdir_after) |*snap| snap.deinit();
            workdir_after = output_packet.snapshotWorkdir(s.allocator, root) catch null;
        }
    }
    defer if (workdir_after) |*snap| snap.deinit();
    const changed_paths = output_packet.changedPathsFromSnapshots(
        s.allocator,
        if (s.workdir_before) |*snap| snap else null,
        if (workdir_after) |*snap| snap else null,
    ) catch &.{};
    defer {
        for (changed_paths) |p| s.allocator.free(p);
        if (changed_paths.len > 0) s.allocator.free(changed_paths);
    }
    input.output_packet = .{
        .stack = s.stack,
        .item_id = s.item_id,
        .status = tag.toStatus().toString(),
        .completed_at = completed_at,
        .result = .{
            .harness = s.harness_name,
            .model = if (result_model_owned) |x| x else null,
            .session_id = sid_for_result,
            .session_file = if (result_sf_owned) |x| x else null,
            .transcript_path = "../transcript.jsonl",
            .exit_code = @as(i64, exit_code),
            .completed_at = completed_at,
        },
        .thread_name = if (s.thread_name) |x| x else null,
        .thread_mode = if (s.thread_name != null) s.thread_mode else null,
        .resume_session_id = if (s.resume_session_id) |x| x else null,
        .summary = if (summary_owned) |x| x else null,
        .changed_paths = changed_paths,
        .workdir_before = if (s.workdir_before) |*snap| snap else null,
        .workdir_after = if (workdir_after) |*snap| snap else null,
    };
    if (tag == .failed) input.failed_reason = "subprocess_nonzero_exit";
    if (tag == .canceled) input.canceled_by = "system";
    applyTransition(s.manager.stack_registry, input);
}

/// Extract a JSON string value for `key_with_colon` (e.g. `"\"foo\":"`)
/// from a flat-ish JSON object. Skips escaped quotes inside the value.
/// Returns the inner string slice borrowed from `src`, or null if absent.
fn extractJsonString(src: []const u8, key_with_colon: []const u8) ?[]const u8 {
    var search_from: usize = 0;
    while (search_from < src.len) {
        const idx = std.mem.indexOf(u8, src[search_from..], key_with_colon) orelse return null;
        const abs = search_from + idx;
        if (abs > 0) {
            const c = src[abs - 1];
            if (c != ',' and c != '{' and c != ' ' and c != '\t' and c != '\n' and c != '[') {
                search_from = abs + 1;
                continue;
            }
        }
        var i = abs + key_with_colon.len;
        while (i < src.len and (src[i] == ' ' or src[i] == '\t')) i += 1;
        if (i >= src.len or src[i] != '"') return null;
        i += 1;
        const start = i;
        while (i < src.len) : (i += 1) {
            if (src[i] == '\\') {
                i += 1;
                continue;
            }
            if (src[i] == '"') return src[start..i];
        }
        return null;
    }
    return null;
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

// ---------- F2 (follow-up): LineBuffer unit tests ----------

fn drainAllForTest(allocator: std.mem.Allocator, lb: *LineBuffer, out: *std.ArrayList([]u8)) !void {
    while (lb.drainLine()) |line| {
        const dup = try allocator.dupe(u8, line);
        try out.append(allocator, dup);
        lb.consumeDrainedLine();
    }
}

fn freeDrainedForTest(allocator: std.mem.Allocator, lines: *std.ArrayList([]u8)) void {
    for (lines.items) |s| allocator.free(s);
    lines.deinit(allocator);
}

test "LineBuffer: chunk without newline accumulates without producing a line" {
    const a = std.testing.allocator;
    var lb = LineBuffer{ .allocator = a, .cap = 1024 };
    defer lb.deinit();
    try lb.push("partial");
    try std.testing.expect(lb.drainLine() == null);
    try std.testing.expectEqual(@as(u64, 0), lb.drop_bytes);
    try std.testing.expect(!lb.overflow_pending);
}

test "LineBuffer: a single complete line drains exactly once" {
    const a = std.testing.allocator;
    var lb = LineBuffer{ .allocator = a, .cap = 1024 };
    defer lb.deinit();
    try lb.push("hello\n");
    var out = std.ArrayList([]u8){};
    defer freeDrainedForTest(a, &out);
    try drainAllForTest(a, &lb, &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqualStrings("hello\n", out.items[0]);
    try std.testing.expect(lb.drainLine() == null);
}

test "LineBuffer: multiple newlines in one chunk drain in order" {
    const a = std.testing.allocator;
    var lb = LineBuffer{ .allocator = a, .cap = 1024 };
    defer lb.deinit();
    try lb.push("one\ntwo\nthree\n");
    var out = std.ArrayList([]u8){};
    defer freeDrainedForTest(a, &out);
    try drainAllForTest(a, &lb, &out);
    try std.testing.expectEqual(@as(usize, 3), out.items.len);
    try std.testing.expectEqualStrings("one\n", out.items[0]);
    try std.testing.expectEqualStrings("two\n", out.items[1]);
    try std.testing.expectEqualStrings("three\n", out.items[2]);
}

test "LineBuffer: partial line accumulates across pushes then drains on newline" {
    const a = std.testing.allocator;
    var lb = LineBuffer{ .allocator = a, .cap = 1024 };
    defer lb.deinit();
    try lb.push("hel");
    try lb.push("lo wor");
    try std.testing.expect(lb.drainLine() == null);
    try lb.push("ld\n");
    var out = std.ArrayList([]u8){};
    defer freeDrainedForTest(a, &out);
    try drainAllForTest(a, &lb, &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqualStrings("hello world\n", out.items[0]);
}

test "LineBuffer: oversized partial line is dropped, drop_bytes advances, overflow flag set" {
    const a = std.testing.allocator;
    var lb = LineBuffer{ .allocator = a, .cap = 16 };
    defer lb.deinit();
    try lb.push("xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx");
    try std.testing.expectEqual(@as(u64, 32), lb.drop_bytes);
    try std.testing.expect(lb.takeOverflow());
    try std.testing.expect(!lb.takeOverflow());
    try lb.push("ok\n");
    var out = std.ArrayList([]u8){};
    defer freeDrainedForTest(a, &out);
    try drainAllForTest(a, &lb, &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqualStrings("ok\n", out.items[0]);
}

test "LineBuffer: complete lines before an oversized partial are preserved" {
    const a = std.testing.allocator;
    var lb = LineBuffer{ .allocator = a, .cap = 16 };
    defer lb.deinit();
    try lb.push("good\n");
    try lb.push("yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy");
    try std.testing.expectEqual(@as(u64, 64), lb.drop_bytes);
    try std.testing.expect(lb.takeOverflow());
    var out = std.ArrayList([]u8){};
    defer freeDrainedForTest(a, &out);
    try drainAllForTest(a, &lb, &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqualStrings("good\n", out.items[0]);
}

test "LineBuffer: UTF-8 byte split across pushes is preserved byte-for-byte" {
    const a = std.testing.allocator;
    var lb = LineBuffer{ .allocator = a, .cap = 1024 };
    defer lb.deinit();
    try lb.push(&.{ 0x63, 0x61, 0x66, 0xC3 });
    try lb.push(&.{ 0xA9, 0x0A });
    var out = std.ArrayList([]u8){};
    defer freeDrainedForTest(a, &out);
    try drainAllForTest(a, &lb, &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqualSlices(u8, &.{ 0x63, 0x61, 0x66, 0xC3, 0xA9, 0x0A }, out.items[0]);
}

test "LineBuffer: drop_bytes is cumulative across multiple overflows" {
    const a = std.testing.allocator;
    var lb = LineBuffer{ .allocator = a, .cap = 8 };
    defer lb.deinit();
    try lb.push("aaaaaaaaaaaaaaaa");
    _ = lb.takeOverflow();
    try lb.push("ok\n");
    var first = std.ArrayList([]u8){};
    defer freeDrainedForTest(a, &first);
    try drainAllForTest(a, &lb, &first);
    try lb.push("bbbbbbbbbbbbbbbbbbbbbbbb");
    try std.testing.expectEqual(@as(u64, 40), lb.drop_bytes);
    try std.testing.expect(lb.takeOverflow());
}

test "LineBuffer: chunk exactly at cap with a terminating newline does not drop" {
    const a = std.testing.allocator;
    var lb = LineBuffer{ .allocator = a, .cap = 16 };
    defer lb.deinit();
    try lb.push("xxxxxxxxxxxxxxx\n");
    try std.testing.expectEqual(@as(u64, 0), lb.drop_bytes);
    try std.testing.expect(!lb.overflow_pending);
    var out = std.ArrayList([]u8){};
    defer freeDrainedForTest(a, &out);
    try drainAllForTest(a, &lb, &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
}
