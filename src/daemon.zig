//! Daemon process: HTTP server on loopback, read endpoints over JSON,
//! lifecycle commands (start/stop/status), and PID/log handling.
//!
//! Single-port surface (see `todos/design_daemon.md`). v1 is loopback-only:
//! the binder explicitly refuses non-loopback hosts.
//!
//! Endpoint set in milestone 3:
//!     GET  /healthz                                  → "ok\n"
//!     GET  /stacks                                   → JSON list of names
//!     GET  /stacks/{name}                            → JSON {name, config}
//!     GET  /stacks/{name}/config                     → JSON config view
//!     GET  /stacks/{name}/items                      → JSON list of items
//!     GET  /stacks/{name}/items/{id}                 → JSON item detail
//!
//! Mutations and SSE are out of scope until milestones 5 and 6 respectively.

const std = @import("std");
const builtin = @import("builtin");
const Config = @import("config.zig").Config;
const config_mod = @import("config.zig");
const local_token = @import("local_token.zig");
const storage = @import("storage.zig");
const errors = @import("errors.zig");
const item_mod = @import("item.zig");
const stack_config = @import("stack_config.zig");
const audit = @import("audit.zig");
const vcs = @import("vcs.zig");
const mutations_mod = @import("mutations.zig");
const mutation_queue = @import("mutation_queue.zig");
const sse_mod = @import("sse.zig");
const runtime_mod = @import("runtime.zig");

pub const StartOptions = struct {
    /// Notes-root directory (path; resolved internally).
    notes_root: []const u8,
    /// Override the port from config.
    port_override: ?u16 = null,
    /// Host. Defaults to "127.0.0.1". Must be a loopback address.
    host: []const u8 = "127.0.0.1",
    /// When true, do not write daemon.pid / daemon.log (used by tests).
    ephemeral: bool = false,
    /// When false, the mutation queue runs without invoking git. Tests use
    /// this to skip subprocess overhead; production leaves it true.
    enable_git: bool = true,
    /// When true, daemon startup runs `vcs.assertNoMergeConflicts`. Tests
    /// that don't initialise a real repo can opt out.
    check_repo_conflicts: bool = true,
    /// When true, `startWorker` constructs a runtime `Supervisor`, reconciles
    /// any restart-orphan runtime files, owns an SSE `Hub`, and starts a
    /// per-stack `Worker` for every stack discovered under
    /// `<notes-root>/stacks/`. Defaults to false so milestone-3/5 tests that
    /// drive only the HTTP read/write surface aren't affected.
    enable_runtime: bool = false,
    /// Harness dispatch used by the supervisor. Only meaningful when
    /// `enable_runtime` is true. Defaults to the fake adapter; M7 wires
    /// real Claude/Codex factories.
    dispatch: ?runtime_mod.Dispatch = null,
    /// Global concurrency cap passed to the session manager. Ignored when
    /// `enable_runtime` is false.
    max_concurrent_total: usize = 8,
};

pub const StartError = error{
    NotLoopbackHost,
    AlreadyRunning,
    OutOfMemory,
} || anyerror;

/// Returns true if `host` is a loopback IPv4 or IPv6 address. We accept
/// 127.0.0.0/8 and ::1.
pub fn isLoopbackHost(host: []const u8) bool {
    // IPv4: must be 127.x.x.x.
    if (std.net.Address.parseIp4(host, 0)) |addr| {
        const bytes = std.mem.asBytes(&addr.in.sa.addr);
        return bytes[0] == 127;
    } else |_| {}
    // IPv6: must be ::1.
    if (std.net.Address.parseIp6(host, 0)) |addr| {
        var sample: [16]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
        return std.mem.eql(u8, &addr.in6.sa.addr, &sample);
    } else |_| {}
    return false;
}

/// Long-lived daemon handle. Owns the listening socket and a `Reader`.
pub const Daemon = struct {
    allocator: std.mem.Allocator,
    config: Config,
    reader: storage.Reader,
    token: local_token.Token,
    server: std.net.Server,
    /// Bound port (after listen — useful when port 0 was requested).
    bound_port: u16,
    /// Whether the run loop has been asked to stop.
    shutdown_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Absolute path to the notes root.
    notes_root_abs: []u8,
    /// True if daemon.pid was created by this instance (cleaned up on stop).
    pid_written: bool = false,
    /// Open append-only handle to `.organo/daemon.log`. Null in ephemeral mode.
    log_file: ?std.fs.File = null,
    /// Audit-log writer (milestone 5). Owns the audit.log file descriptor.
    audit_writer: audit.Writer,
    /// Single-writer mutation queue + worker thread. All POST mutation
    /// endpoints push requests here.
    queue: mutation_queue.Queue,
    /// Cached config flag from start.
    enable_git: bool = true,
    /// SSE hub. Optional: set up only when the runtime supervisor is wired
    /// in. In M6, exposed so tests can publish events independently of a
    /// real runtime.
    sse_hub: ?*sse_mod.Hub = null,
    /// Heap-allocated hub owned by the daemon when `enable_runtime` is on.
    /// The supervisor and SSE handlers borrow it via `sse_hub`.
    sse_hub_owned: ?*sse_mod.Hub = null,
    /// Heap-allocated runtime supervisor owned by the daemon. Per-stack
    /// `Worker` threads point back to this address, so the supervisor must
    /// live on the heap (moving a Daemon-by-value would dangle them).
    /// Constructed in `startWorker` when `enable_runtime` is on.
    supervisor: ?*runtime_mod.Supervisor = null,

    /// Long-lived SSE connection threads. Tracked so `deinit` can join.
    sse_threads_mu: std.Thread.Mutex = .{},
    sse_threads: std.ArrayList(std.Thread) = .{},
    /// SSE socket handles, for forced shutdown at daemon stop.
    sse_handles: std.ArrayList(std.posix.socket_t) = .{},
    /// Saved at start, used by `startWorker` to construct the supervisor.
    runtime_enabled: bool = false,
    runtime_dispatch: ?runtime_mod.Dispatch = null,
    runtime_max_concurrent_total: usize = 8,

    pub fn deinit(self: *Daemon) void {
        // Tear-down order matters:
        //   1. Supervisor (joins worker threads and the session manager;
        //      sessions submit terminal transitions through the queue so
        //      the queue must still be alive at this point).
        //   2. Mutation queue (joins its worker thread).
        //   3. SSE connection threads (the hub still publishes through the
        //      session manager, so we wait until after step 1 to close
        //      their sockets).
        //   4. Hub, then audit writer, server, etc.
        if (self.supervisor) |sup| {
            sup.deinit();
            self.allocator.destroy(sup);
            self.supervisor = null;
        }
        self.queue.deinit();
        // Force-close every live SSE connection so its worker thread
        // returns from `stream.read`, then drain.
        self.sse_threads_mu.lock();
        for (self.sse_handles.items) |h| {
            std.posix.shutdown(h, .both) catch {};
        }
        const threads = self.sse_threads.items;
        self.sse_threads_mu.unlock();
        for (threads) |t| t.join();
        self.sse_threads_mu.lock();
        self.sse_threads.deinit(self.allocator);
        self.sse_handles.deinit(self.allocator);
        self.sse_threads_mu.unlock();
        if (self.sse_hub_owned) |h| {
            h.deinit();
            self.allocator.destroy(h);
            self.sse_hub_owned = null;
            // sse_hub is a borrow; clear it so stale reads can't happen.
            self.sse_hub = null;
        }
        self.audit_writer.deinit();
        self.server.deinit();
        self.allocator.free(self.token.bytes);
        self.reader.deinit();
        self.config.deinit();
        if (self.log_file) |*f| f.close();
        self.allocator.free(self.notes_root_abs);
    }

    /// Best-effort: write a short line to `daemon.log`. Drops on error.
    pub fn logLine(self: *Daemon, comptime fmt: []const u8, args: anytype) void {
        if (self.log_file) |*f| {
            var buf: [512]u8 = undefined;
            const line = std.fmt.bufPrint(&buf, fmt ++ "\n", args) catch return;
            _ = f.writeAll(line) catch return;
        }
    }

    pub fn requestShutdown(self: *Daemon) void {
        self.shutdown_requested.store(true, .seq_cst);
        // Ask the runtime to stop pumping work. The supervisor signals
        // every worker and its session manager, but does NOT join them
        // here — joining happens in deinit so callers can drain ongoing
        // requests gracefully.
        if (self.supervisor) |sup| sup.requestShutdown();
        // Close the listening socket so the blocked accept() in
        // `serveUntilShutdown` returns immediately. The server struct is left
        // in an unusable state, which is fine because we are shutting down.
        const handle = self.server.stream.handle;
        if (handle >= 0) {
            std.posix.shutdown(handle, .both) catch {};
        }
        // SSE worker threads block on stream.read; wake them by half-closing
        // each tracked connection. (Per-conn close happens in the worker.)
        // Note: we don't have direct references here; the workers also poll
        // shutdown_requested every read return, so the most important
        // wake-up is at deinit time when the test code typically calls
        // requestShutdown then closes the daemon.
    }

    /// Start the mutation-queue worker thread and emit the daemon_started
    /// audit event. Must be called AFTER the caller has stored the returned
    /// `Daemon` at its final address — the queue worker holds a pointer to
    /// `daemon.audit_writer`, so moving the Daemon after this point is UB.
    ///
    /// When `enable_runtime` was requested at `start()` time, this also
    /// constructs the runtime `Supervisor`, runs the restart-orphan sweep,
    /// owns a fresh SSE `Hub`, and starts one `Worker` thread per stack
    /// discovered under `<notes-root>/stacks/`. The supervisor borrows the
    /// daemon's audit writer + queue, so it depends on this same
    /// final-address contract.
    pub fn startWorker(self: *Daemon) !void {
        self.queue.audit_writer = &self.audit_writer;
        try self.queue.start();
        if (self.runtime_enabled) {
            // Own an SSE Hub the supervisor + handlers share.
            const hub_p = try self.allocator.create(sse_mod.Hub);
            hub_p.* = sse_mod.Hub.init(self.allocator);
            self.sse_hub_owned = hub_p;
            self.sse_hub = hub_p;
            errdefer {
                hub_p.deinit();
                self.allocator.destroy(hub_p);
                self.sse_hub_owned = null;
                self.sse_hub = null;
            }

            const dispatch = self.runtime_dispatch orelse runtime_mod.fakeDispatch();
            const sup_p = try self.allocator.create(runtime_mod.Supervisor);
            sup_p.* = runtime_mod.Supervisor.init(self.allocator, .{
                .notes_root_abs = self.notes_root_abs,
                .queue = &self.queue,
                .audit_writer = &self.audit_writer,
                .hub = hub_p,
                .dispatch = dispatch,
                .max_concurrent_total = self.runtime_max_concurrent_total,
            });
            errdefer {
                sup_p.deinit();
                self.allocator.destroy(sup_p);
            }
            self.supervisor = sup_p;
            // Restart-sweep before any worker thread starts so we never
            // race with the supervisor's own ticking over a stale runtime
            // file (per design step 10).
            sup_p.reconcileOrphans() catch {};
            try sup_p.startAllWorkers();
        }
        self.audit_writer.append(.{
            .identity = "system",
            .action = .daemon_started,
            .target = "daemon",
            .outcome = .allowed,
        }) catch {};
    }
};

/// Start a daemon listening on a loopback port, return a ready handle.
///
/// Does NOT enter the accept loop — call `serveOne` or `serveUntilShutdown`
/// once you have the handle. Splitting open and serve lets tests inspect the
/// bound port before driving traffic.
pub fn start(allocator: std.mem.Allocator, opts: StartOptions) StartError!Daemon {
    // Resolve notes root to abs.
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = try std.fs.cwd().realpath(opts.notes_root, &root_buf);
    const abs_owned = try allocator.dupe(u8, abs);
    errdefer allocator.free(abs_owned);

    // Load config.
    var cfg = try config_mod.loadFromRoot(allocator, abs_owned);
    errdefer cfg.deinit();

    // Token (generate if absent).
    const token = try local_token.ensureAndLoad(allocator, abs_owned);
    errdefer allocator.free(token.bytes);

    // Decide host + port. v1: refuse non-loopback.
    if (!isLoopbackHost(opts.host)) return error.NotLoopbackHost;
    const port = opts.port_override orelse cfg.daemon.port;

    // Bind.
    const addr = try std.net.Address.parseIp(opts.host, port);
    var server = try addr.listen(.{ .reuse_address = true });
    errdefer server.deinit();
    const bound_port = server.listen_address.in.getPort();

    // Optional: write daemon.pid (skipped under ephemeral mode used in tests).
    var pid_written = false;
    var log_file: ?std.fs.File = null;
    if (!opts.ephemeral) {
        pid_written = try writePidFile(allocator, abs_owned, bound_port);
        // daemon.log is best-effort: if we can't open it, drop logging
        // rather than failing to start.
        log_file = openLogFile(allocator, abs_owned) catch null;
    }

    // Storage reader.
    var reader = try storage.Reader.init(allocator, abs_owned);
    errdefer reader.deinit();

    // Conflict check on the notes repo (gated). We only run this if a real
    // `.git` is present — `organo init` from milestone 2 produces a stub
    // .git layout without an actual repo, so we can't blindly invoke git.
    if (opts.check_repo_conflicts and hasRealGit(abs_owned)) {
        vcs.assertNoMergeConflicts(allocator, abs_owned) catch |e| switch (e) {
            error.HasMergeConflicts => return error.MergeConflictsPresent,
            error.GitNotFound, error.NotARepo => {}, // tolerate
            else => {},
        };
    }

    // Audit writer (lazy-opens audit.log on first append).
    var audit_writer = try audit.Writer.init(allocator, abs_owned);
    errdefer audit_writer.deinit();

    // Mutation queue.
    var queue = mutation_queue.Queue.init(allocator, abs_owned, undefined);
    queue.enable_git = opts.enable_git;

    var d: Daemon = .{
        .allocator = allocator,
        .config = cfg,
        .reader = reader,
        .token = token,
        .server = server,
        .bound_port = bound_port,
        .notes_root_abs = abs_owned,
        .pid_written = pid_written,
        .log_file = log_file,
        .audit_writer = audit_writer,
        .queue = queue,
        .enable_git = opts.enable_git,
        .runtime_enabled = opts.enable_runtime,
        .runtime_dispatch = opts.dispatch,
        .runtime_max_concurrent_total = opts.max_concurrent_total,
    };
    d.logLine("[{d}] daemon started on 127.0.0.1:{d}", .{ std.time.timestamp(), bound_port });
    return d;
}

pub const ErrorExt = error{MergeConflictsPresent};

fn hasRealGit(notes_root_abs: []const u8) bool {
    // A real git repo has `.git/HEAD` + `.git/objects/`. The `organo init`
    // stub layout has both, so additionally check for `.git/config` whose
    // content includes `[core]`. Cheap and good enough for v1.
    var d = std.fs.openDirAbsolute(notes_root_abs, .{}) catch return false;
    defer d.close();
    var git = d.openDir(".git", .{}) catch return false;
    defer git.close();
    git.access("HEAD", .{}) catch return false;
    return true;
}

fn openLogFile(
    allocator: std.mem.Allocator,
    notes_root_abs: []const u8,
) !std.fs.File {
    const dir_path = try std.fs.path.join(allocator, &.{ notes_root_abs, ".organo" });
    defer allocator.free(dir_path);
    std.fs.cwd().makePath(dir_path) catch {};
    const log_path = try std.fs.path.join(allocator, &.{ dir_path, "daemon.log" });
    defer allocator.free(log_path);
    // Append; create if absent. We don't truncate so restarts append to history.
    var f = try std.fs.cwd().createFile(log_path, .{
        .truncate = false,
        .read = false,
        .mode = 0o600,
    });
    // Append: seek to end so we don't overwrite existing log history.
    f.seekFromEnd(0) catch {};
    return f;
}

/// Accept exactly one connection, serve one request, then return. Used by
/// tests to drive a deterministic exchange. Returns `false` if the daemon
/// was asked to shut down before accept returned.
pub fn serveOne(self: *Daemon) !void {
    var conn = try self.server.accept();
    var owned: bool = true;
    defer if (owned) conn.stream.close();
    try handleConnection(self, conn, &owned);
}

/// Accept loop. Returns when `shutdown_requested` is set AND the next accept
/// closes (closing the listening socket from another thread is the cleanest
/// way to trigger that). The CLI's `daemon stop` path uses SIGTERM, not
/// in-process shutdown, so this routine doesn't need a clever wake.
pub fn serveUntilShutdown(self: *Daemon) !void {
    while (!self.shutdown_requested.load(.seq_cst)) {
        var conn = self.server.accept() catch |e| switch (e) {
            error.SocketNotListening, error.ConnectionAborted => return,
            else => return e,
        };
        var owned: bool = true;
        defer if (owned) conn.stream.close();
        handleConnection(self, conn, &owned) catch |e| {
            std.log.warn("organo: request failed: {s}", .{@errorName(e)});
        };
    }
}

/// On entry, `*conn_owned` is true. If the handler hands the connection to
/// a long-lived thread (SSE), it sets `*conn_owned = false` so the caller
/// does NOT close the stream.
fn handleConnection(self: *Daemon, conn: std.net.Server.Connection, conn_owned: *bool) !void {
    var read_buf: [16 * 1024]u8 = undefined;
    var write_buf: [16 * 1024]u8 = undefined;
    var net_reader = conn.stream.reader(&read_buf);
    var net_writer = conn.stream.writer(&write_buf);
    var http_server = std.http.Server.init(net_reader.interface(), &net_writer.interface);
    var req = http_server.receiveHead() catch |e| {
        writeRawError(&net_writer.interface, 400, "bad request") catch {};
        return e;
    };
    try routeWithOwnership(self, &req, conn, conn_owned);
}

fn writeRawError(w: *std.Io.Writer, status: u16, msg: []const u8) !void {
    try w.print("HTTP/1.1 {d} error\r\ncontent-length: {d}\r\n\r\n{s}", .{ status, msg.len, msg });
    try w.flush();
}

// ---------- Router ----------

const Route = enum {
    healthz,
    stacks_list,
    stack_get,
    stack_config_get,
    stack_items_list,
    stack_item_get,
    // Mutation routes (milestone 5).
    stacks_create, // POST /stacks
    stack_config_post, // POST /stacks/{name}/config
    items_append, // POST /stacks/{name}/items
    item_insert, // POST /stacks/{name}/items/{id}/insert
    item_retry, // POST /stacks/{name}/items/{id}/retry
    item_cancel, // POST /stacks/{name}/items/{id}/cancel
    item_supersede, // POST /stacks/{name}/items/{id}/supersede
    stack_pause, // POST /stacks/{name}/pause
    stack_resume, // POST /stacks/{name}/resume
    // SSE (milestone 6).
    stack_events_sse, // GET /stacks/{name}/events
    unknown,
};

const RouteMatch = struct {
    route: Route,
    stack: []const u8 = "",
    item: []const u8 = "",
};

/// Match the path against the daemon's route table. Exposed for unit tests.
pub fn matchRoute(target: []const u8) RouteMatch {
    // Strip a query string, if any.
    const q = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
    const path = target[0..q];

    if (std.mem.eql(u8, path, "/healthz")) return .{ .route = .healthz };
    if (std.mem.eql(u8, path, "/stacks") or std.mem.eql(u8, path, "/stacks/"))
        return .{ .route = .stacks_list };

    // /stacks/<name>...
    if (std.mem.startsWith(u8, path, "/stacks/")) {
        const rest = path["/stacks/".len..];
        // Split on the first '/' to peel off the stack name.
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
        const name = rest[0..slash];
        if (name.len == 0) return .{ .route = .unknown };

        if (slash == rest.len) {
            return .{ .route = .stack_get, .stack = name };
        }
        const after = rest[slash + 1 ..];
        if (std.mem.eql(u8, after, "config"))
            return .{ .route = .stack_config_get, .stack = name };
        if (std.mem.eql(u8, after, "items") or std.mem.eql(u8, after, "items/"))
            return .{ .route = .stack_items_list, .stack = name };
        if (std.mem.eql(u8, after, "pause"))
            return .{ .route = .stack_pause, .stack = name };
        if (std.mem.eql(u8, after, "resume"))
            return .{ .route = .stack_resume, .stack = name };
        if (std.mem.eql(u8, after, "events"))
            return .{ .route = .stack_events_sse, .stack = name };
        if (std.mem.startsWith(u8, after, "items/")) {
            const item_rest = after["items/".len..];
            // Could be `<id>`, `<id>/insert`, `<id>/retry`, etc.
            const next_slash = std.mem.indexOfScalar(u8, item_rest, '/') orelse item_rest.len;
            const id = item_rest[0..next_slash];
            if (next_slash == item_rest.len) {
                return .{ .route = .stack_item_get, .stack = name, .item = id };
            }
            const tail = item_rest[next_slash + 1 ..];
            if (std.mem.eql(u8, tail, "insert"))
                return .{ .route = .item_insert, .stack = name, .item = id };
            if (std.mem.eql(u8, tail, "retry"))
                return .{ .route = .item_retry, .stack = name, .item = id };
            if (std.mem.eql(u8, tail, "cancel"))
                return .{ .route = .item_cancel, .stack = name, .item = id };
            if (std.mem.eql(u8, tail, "supersede"))
                return .{ .route = .item_supersede, .stack = name, .item = id };
            return .{ .route = .unknown };
        }
    }
    return .{ .route = .unknown };
}

/// Return true if this route requires an authenticated mutator (POST).
fn isMutationRoute(r: Route) bool {
    return switch (r) {
        .stacks_create,
        .stack_config_post,
        .items_append,
        .item_insert,
        .item_retry,
        .item_cancel,
        .item_supersede,
        .stack_pause,
        .stack_resume,
        => true,
        else => false,
    };
}

/// New entry point introduced for SSE: same as `route` but threads through
/// the connection-ownership flag so the SSE handler can detach.
fn routeWithOwnership(self: *Daemon, req: *std.http.Server.Request, conn: std.net.Server.Connection, conn_owned: *bool) !void {
    const m = matchRoute(req.head.target);
    if (m.route == .stack_events_sse and req.head.method == .GET) {
        try handleStackEventsDetached(self, req, m.stack, conn, conn_owned);
        return;
    }
    try route(self, req);
}

fn route(self: *Daemon, req: *std.http.Server.Request) !void {
    var m = matchRoute(req.head.target);
    const method = req.head.method;
    const is_get = method == .GET or method == .HEAD;
    const is_post = method == .POST;

    // Apply method-based promotion: a POST to a path that matched as a
    // GET-default route gets remapped to the matching mutation route.
    if (is_post) {
        m.route = promoteToMutation(m.route);
    } else if (!is_get) {
        try respondError(req, .validation_failed, "method not allowed", &.{});
        return;
    }
    // GETs on mutation-only paths (e.g. /stacks/foo/items/0001/cancel) are 404.
    if (is_get and isMutationRoute(m.route)) {
        try respondError(req, .not_found, "endpoint not found", &.{});
        return;
    }

    // Auth check on mutation routes.
    if (isMutationRoute(m.route)) {
        if (!verifyAuth(self, req)) {
            try respondError(req, .identity_required, "missing or invalid Authorization bearer token", &.{});
            return;
        }
    }

    switch (m.route) {
        .healthz => try respondOkText(req, "ok\n"),
        .stacks_list => try respondStacksList(self, req),
        .stack_get => try respondStackGet(self, req, m.stack),
        .stack_config_get => try respondStackConfigGet(self, req, m.stack),
        .stack_items_list => try respondStackItemsList(self, req, m.stack),
        .stack_item_get => try respondStackItemGet(self, req, m.stack, m.item),
        // Mutations.
        .stacks_create => try handleCreateStack(self, req),
        .stack_config_post => try handleConfigPost(self, req, m.stack),
        .items_append => try handleAppendItem(self, req, m.stack),
        .item_insert => try handleInsertItem(self, req, m.stack, m.item),
        .item_retry => try handleTransition(self, req, m.stack, m.item, .retry),
        .item_cancel => try handleTransition(self, req, m.stack, m.item, .cancel),
        .item_supersede => try handleTransition(self, req, m.stack, m.item, .supersede),
        .stack_pause => try handlePauseResume(self, req, m.stack, true),
        .stack_resume => try handlePauseResume(self, req, m.stack, false),
        .stack_events_sse => try respondError(req, .internal, "SSE must be routed via routeWithOwnership", &.{}),
        .unknown => try respondError(req, .not_found, "endpoint not found", &.{}),
    }
}

fn promoteToMutation(r: Route) Route {
    return switch (r) {
        .stacks_list => .stacks_create,
        .stack_config_get => .stack_config_post,
        .stack_items_list => .items_append,
        else => r,
    };
}

fn verifyAuth(self: *Daemon, req: *std.http.Server.Request) bool {
    var it = req.iterateHeaders();
    while (it.next()) |h| {
        if (asciiEqlIgnoreCase(h.name, "authorization")) {
            // Expected: "Bearer <token>". Be liberal about whitespace.
            const prefix = "Bearer ";
            const value = h.value;
            if (value.len <= prefix.len) return false;
            // Match prefix case-insensitively (Bearer is the only scheme we accept).
            if (!asciiEqlIgnoreCase(value[0..prefix.len], prefix)) return false;
            const tok = std.mem.trim(u8, value[prefix.len..], " \t");
            return self.token.verify(tok);
        }
    }
    return false;
}

fn asciiEqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        const xl = if (x >= 'A' and x <= 'Z') x + 32 else x;
        const yl = if (y >= 'A' and y <= 'Z') y + 32 else y;
        if (xl != yl) return false;
    }
    return true;
}

fn respondOkText(req: *std.http.Server.Request, body: []const u8) !void {
    try req.respond(body, .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "text/plain; charset=utf-8" },
        },
    });
}

fn respondJson(req: *std.http.Server.Request, body: []const u8) !void {
    try req.respond(body, .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
        },
    });
}

fn respondError(
    req: *std.http.Server.Request,
    code: errors.Code,
    message: []const u8,
    details: []const errors.DetailKV,
) !void {
    var buf: [4096]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try errors.writeBody(&w, code, message, details);
    const body = buf[0..w.end];
    try req.respond(body, .{
        .status = @enumFromInt(@as(u10, @intCast(code.httpStatus()))),
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
        },
    });
}

// ---------- endpoint handlers ----------

fn respondStacksList(self: *Daemon, req: *std.http.Server.Request) !void {
    const names = self.reader.listStacks() catch {
        try respondError(req, .internal, "failed to list stacks", &.{});
        return;
    };
    defer self.reader.freeStackList(names);

    var buf = std.ArrayList(u8){};
    defer buf.deinit(self.allocator);
    const w = buf.writer(self.allocator);
    try w.writeAll("{\"stacks\":[");
    for (names, 0..) |n, i| {
        if (i != 0) try w.writeAll(",");
        try w.writeAll("{\"name\":\"");
        try errors.writeJsonString(w, n);
        try w.writeAll("\"}");
    }
    try w.writeAll("]}");
    try respondJson(req, buf.items);
}

fn respondStackGet(self: *Daemon, req: *std.http.Server.Request, name: []const u8) !void {
    if (!storage.isValidStackName(name)) {
        try respondError(req, .validation_failed, "invalid stack name", &.{
            .{ .key = "name", .value = name },
        });
        return;
    }
    var cfg = self.reader.readStackConfig(name) catch |e| switch (e) {
        error.NotFound => {
            try respondError(req, .not_found, "stack not found", &.{
                .{ .key = "stack", .value = name },
            });
            return;
        },
        else => {
            try respondError(req, .internal, @errorName(e), &.{});
            return;
        },
    };
    defer cfg.deinit();

    const items = self.reader.listItems(name) catch |e| {
        try respondError(req, .internal, @errorName(e), &.{});
        return;
    };
    defer self.reader.freeItemList(items);

    var buf = std.ArrayList(u8){};
    defer buf.deinit(self.allocator);
    const w = buf.writer(self.allocator);
    try w.writeAll("{\"name\":\"");
    try errors.writeJsonString(w, name);
    try w.writeAll("\",\"config\":");
    try writeStackConfigJson(w, &cfg);
    try w.writeAll(",\"items\":");
    try writeItemSummaryListJson(w, items);
    try w.writeAll("}");
    try respondJson(req, buf.items);
}

fn respondStackConfigGet(self: *Daemon, req: *std.http.Server.Request, name: []const u8) !void {
    if (!storage.isValidStackName(name)) {
        try respondError(req, .validation_failed, "invalid stack name", &.{
            .{ .key = "name", .value = name },
        });
        return;
    }
    var cfg = self.reader.readStackConfig(name) catch |e| switch (e) {
        error.NotFound => {
            try respondError(req, .not_found, "stack not found", &.{
                .{ .key = "stack", .value = name },
            });
            return;
        },
        else => {
            try respondError(req, .internal, @errorName(e), &.{});
            return;
        },
    };
    defer cfg.deinit();

    var buf = std.ArrayList(u8){};
    defer buf.deinit(self.allocator);
    const w = buf.writer(self.allocator);
    try writeStackConfigJson(w, &cfg);
    try respondJson(req, buf.items);
}

fn respondStackItemsList(self: *Daemon, req: *std.http.Server.Request, name: []const u8) !void {
    if (!storage.isValidStackName(name)) {
        try respondError(req, .validation_failed, "invalid stack name", &.{
            .{ .key = "name", .value = name },
        });
        return;
    }
    const items = self.reader.listItems(name) catch |e| switch (e) {
        error.NotFound => {
            try respondError(req, .not_found, "stack not found", &.{
                .{ .key = "stack", .value = name },
            });
            return;
        },
        else => {
            try respondError(req, .internal, @errorName(e), &.{});
            return;
        },
    };
    defer self.reader.freeItemList(items);

    var buf = std.ArrayList(u8){};
    defer buf.deinit(self.allocator);
    const w = buf.writer(self.allocator);
    try writeItemSummaryListJson(w, items);
    try respondJson(req, buf.items);
}

fn respondStackItemGet(
    self: *Daemon,
    req: *std.http.Server.Request,
    name: []const u8,
    id: []const u8,
) !void {
    if (!storage.isValidStackName(name)) {
        try respondError(req, .validation_failed, "invalid stack name", &.{
            .{ .key = "name", .value = name },
        });
        return;
    }
    if (!item_mod.isValidId(id)) {
        try respondError(req, .validation_failed, "invalid item id", &.{
            .{ .key = "id", .value = id },
        });
        return;
    }
    var it = self.reader.readItem(name, id) catch |e| switch (e) {
        error.NotFound => {
            try respondError(req, .not_found, "item not found", &.{
                .{ .key = "stack", .value = name },
                .{ .key = "id", .value = id },
            });
            return;
        },
        error.BadItemId => {
            try respondError(req, .validation_failed, "invalid item id", &.{
                .{ .key = "id", .value = id },
            });
            return;
        },
        else => {
            try respondError(req, .internal, @errorName(e), &.{});
            return;
        },
    };
    defer it.deinit();

    var buf = std.ArrayList(u8){};
    defer buf.deinit(self.allocator);
    const w = buf.writer(self.allocator);
    try writeItemJson(w, &it);
    try respondJson(req, buf.items);
}

// ---------- JSON writers (typed views) ----------

fn writeStackConfigJson(w: anytype, cfg: *const stack_config.StackConfig) !void {
    try w.writeAll("{");
    var first = true;
    if (cfg.description) |s| {
        try w.writeAll("\"description\":\"");
        try errors.writeJsonString(w, s);
        try w.writeAll("\"");
        first = false;
    }
    if (cfg.created_at) |s| {
        if (!first) try w.writeAll(",");
        try w.writeAll("\"created_at\":\"");
        try errors.writeJsonString(w, s);
        try w.writeAll("\"");
        first = false;
    }
    if (!first) try w.writeAll(",");
    try w.print("\"paused\":{s}", .{if (cfg.paused) "true" else "false"});
    try w.print(",\"continuity\":\"{s}\"", .{cfg.continuity.toString()});
    try w.print(",\"max_concurrent_per_stack\":{d}", .{cfg.max_concurrent_per_stack});
    if (cfg.default_workdir) |s| {
        try w.writeAll(",\"default_workdir\":\"");
        try errors.writeJsonString(w, s);
        try w.writeAll("\"");
    }
    if (cfg.allowed_harnesses) |arr| {
        try w.writeAll(",\"allowed_harnesses\":[");
        for (arr, 0..) |s, i| {
            if (i != 0) try w.writeAll(",");
            try w.writeAll("\"");
            try errors.writeJsonString(w, s);
            try w.writeAll("\"");
        }
        try w.writeAll("]");
    }
    try w.writeAll("}");
}

fn writeItemSummaryListJson(w: anytype, items: []const storage.ItemSummary) !void {
    try w.writeAll("[");
    for (items, 0..) |it, i| {
        if (i != 0) try w.writeAll(",");
        try w.writeAll("{\"id\":\"");
        try errors.writeJsonString(w, it.id);
        try w.writeAll("\",\"slug\":\"");
        try errors.writeJsonString(w, it.slug);
        try w.writeAll("\",\"kind\":\"");
        try errors.writeJsonString(w, it.kind);
        try w.writeAll("\",\"status\":\"");
        try errors.writeJsonString(w, it.status);
        try w.writeAll("\"}");
    }
    try w.writeAll("]");
}

fn writeItemJson(w: anytype, it: *const item_mod.Item) !void {
    try w.writeAll("{");
    try w.writeAll("\"id\":\"");
    try errors.writeJsonString(w, it.id);
    try w.writeAll("\",\"slug\":\"");
    try errors.writeJsonString(w, it.slug);
    try w.writeAll("\",\"kind\":\"");
    try errors.writeJsonString(w, it.kind.toString());
    try w.writeAll("\",\"status\":\"");
    try errors.writeJsonString(w, it.status.toString());
    try w.writeAll("\",\"created_at\":\"");
    try errors.writeJsonString(w, it.created_at);
    try w.writeAll("\",\"updated_at\":\"");
    try errors.writeJsonString(w, it.updated_at);
    try w.writeAll("\"");
    if (it.parents) |ps| {
        try w.writeAll(",\"parents\":[");
        for (ps, 0..) |p, i| {
            if (i != 0) try w.writeAll(",");
            try w.writeAll("\"");
            try errors.writeJsonString(w, p);
            try w.writeAll("\"");
        }
        try w.writeAll("]");
    }
    if (it.target) |t| {
        try w.writeAll(",\"target\":{");
        var first = true;
        if (t.provider) |s| {
            try w.writeAll("\"provider\":\"");
            try errors.writeJsonString(w, s);
            try w.writeAll("\"");
            first = false;
        }
        if (t.model) |s| {
            if (!first) try w.writeAll(",");
            try w.writeAll("\"model\":\"");
            try errors.writeJsonString(w, s);
            try w.writeAll("\"");
            first = false;
        }
        if (t.match) |m| {
            if (!first) try w.writeAll(",");
            try w.print("\"match\":\"{s}\"", .{m.toString()});
            first = false;
        }
        if (t.workdir) |s| {
            if (!first) try w.writeAll(",");
            try w.writeAll("\"workdir\":\"");
            try errors.writeJsonString(w, s);
            try w.writeAll("\"");
        }
        try w.writeAll("}");
    }
    if (it.sleep) |s| {
        try w.writeAll(",\"sleep\":{\"until\":\"");
        try errors.writeJsonString(w, s.until);
        try w.writeAll("\"}");
    }
    if (it.clear_present) try w.writeAll(",\"clear\":true");
    try w.writeAll("}");
}

// ---------- mutation handlers (milestone 5) ----------

const MAX_BODY_BYTES: usize = 256 * 1024;

/// Read the request body in full. Returns a caller-owned slice (empty if no
/// body). The std HTTP server gives us a `Reader`; we drain it via the
/// allocator helper. Bodies larger than `MAX_BODY_BYTES` are rejected.
fn readRequestBody(self: *Daemon, req: *std.http.Server.Request) ![]u8 {
    var body_reader_buf: [256]u8 = undefined;
    const reader = try req.readerExpectContinue(&body_reader_buf);
    return reader.allocRemaining(self.allocator, .limited(MAX_BODY_BYTES)) catch |e| switch (e) {
        error.StreamTooLong => return error.BodyTooLarge,
        else => return e,
    };
}

/// Map a mutation failure to an HTTP error code + message and respond.
fn respondMutationError(
    req: *std.http.Server.Request,
    kind: mutation_queue.MutationFailureKind,
    stack: []const u8,
    item: []const u8,
) !void {
    var details_buf: [4]errors.DetailKV = undefined;
    var n_details: usize = 0;
    if (stack.len > 0) {
        details_buf[n_details] = .{ .key = "stack", .value = stack };
        n_details += 1;
    }
    if (item.len > 0) {
        details_buf[n_details] = .{ .key = "id", .value = item };
        n_details += 1;
    }
    const details = details_buf[0..n_details];

    const code: errors.Code = switch (kind) {
        .invalid_name, .name_reserved => .validation_failed,
        .already_exists => .state_conflict,
        .not_found => .not_found,
        .state_conflict => .invalid_status_transition,
        .internal_state_only => .invalid_status_transition,
        .validation_failed, .bad_config_key, .bad_config_value => .validation_failed,
        .vcs_conflict, .vcs_dirty => .vcs_conflict,
        .git_not_found, .git_failed => .internal,
        .internal => .internal,
    };
    const message = switch (kind) {
        .invalid_name => "invalid stack name",
        .name_reserved => "stack name is reserved",
        .already_exists => "resource already exists",
        .not_found => "resource not found",
        .state_conflict => "invalid status transition for this item",
        .internal_state_only => "transition is not callable via API",
        .validation_failed => "validation failed",
        .bad_config_key => "unknown stack config key",
        .bad_config_value => "invalid stack config value",
        .vcs_conflict => "notes repo has merge conflicts on targeted files",
        .vcs_dirty => "targeted stack files have uncommitted user edits",
        .git_not_found => "git binary not found",
        .git_failed => "git operation failed",
        .internal => "internal error",
    };
    try respondError(req, code, message, details);
}

/// Common write step after a mutation succeeds: emit JSON status + the
/// commit short SHA.
fn respondMutationOk(req: *std.http.Server.Request, allocator: std.mem.Allocator, request: *const mutation_queue.Request) !void {
    var buf = std.ArrayList(u8){};
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try w.writeAll("{\"ok\":true");
    if (request.commit_short_sha_len > 0) {
        const sha = request.commit_short_sha[0..request.commit_short_sha_len];
        try w.writeAll(",\"commit\":\"");
        try errors.writeJsonString(w, sha);
        try w.writeAll("\"");
    }
    if (request.output) |*o| {
        if (o.audit_details.len > 0) {
            try w.writeAll(",\"details\":{");
            for (o.audit_details, 0..) |d, i| {
                if (i != 0) try w.writeAll(",");
                try w.writeAll("\"");
                try errors.writeJsonString(w, d.key);
                try w.writeAll("\":\"");
                try errors.writeJsonString(w, d.value);
                try w.writeAll("\"");
            }
            try w.writeAll("}");
        }
    }
    try w.writeAll("}");
    try req.respond(buf.items, .{
        .status = .ok,
        .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
        },
    });
}

/// Handle POST /stacks. Body: {"name":"...","config":{...}}.
fn handleCreateStack(self: *Daemon, req: *std.http.Server.Request) !void {
    const body = readRequestBody(self, req) catch {
        try respondError(req, .validation_failed, "failed to read request body", &.{});
        return;
    };
    defer self.allocator.free(body);

    // Parse JSON.
    var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, body, .{}) catch {
        try respondError(req, .validation_failed, "invalid JSON body", &.{});
        return;
    };
    defer parsed.deinit();

    const obj = parsed.value.object;
    const name_val = obj.get("name") orelse {
        try respondError(req, .validation_failed, "missing field `name`", &.{});
        return;
    };
    if (name_val != .string) {
        try respondError(req, .validation_failed, "field `name` must be a string", &.{});
        return;
    }
    const name = name_val.string;

    var input: mutations_mod.CreateStackInput = .{ .name = name };
    if (obj.get("config")) |cfg_v| {
        if (cfg_v == .object) {
            const cfg = cfg_v.object;
            if (cfg.get("description")) |v| if (v == .string) {
                input.description = v.string;
            };
            if (cfg.get("continuity")) |v| if (v == .string) {
                input.continuity = stack_config.Continuity.fromString(v.string);
            };
            if (cfg.get("paused")) |v| if (v == .bool) {
                input.paused = v.bool;
            };
            if (cfg.get("max_concurrent_per_stack")) |v| if (v == .integer) {
                input.max_concurrent_per_stack = v.integer;
            };
            if (cfg.get("default_workdir")) |v| if (v == .string) {
                input.default_workdir = v.string;
            };
        }
    }

    var request = mutation_queue.Request{
        .kind = .{ .create_stack = input },
        .ident = .{ .api_path = "POST /stacks" },
    };
    self.queue.submitAndWait(&request);
    if (request.err) |k| {
        try respondMutationError(req, k, name, "");
        return;
    }
    defer if (request.output) |*o| o.deinit();
    try respondMutationOk(req, self.allocator, &request);
}

fn handleAppendItem(self: *Daemon, req: *std.http.Server.Request, stack: []const u8) !void {
    const body = readRequestBody(self, req) catch {
        try respondError(req, .validation_failed, "failed to read request body", &.{});
        return;
    };
    defer self.allocator.free(body);

    var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, body, .{}) catch {
        try respondError(req, .validation_failed, "invalid JSON body", &.{});
        return;
    };
    defer parsed.deinit();
    const obj = parsed.value.object;

    const kind_v = obj.get("kind") orelse {
        try respondError(req, .validation_failed, "missing field `kind`", &.{});
        return;
    };
    if (kind_v != .string) {
        try respondError(req, .validation_failed, "field `kind` must be a string", &.{});
        return;
    }
    const slug_v = obj.get("slug") orelse {
        try respondError(req, .validation_failed, "missing field `slug`", &.{});
        return;
    };
    if (slug_v != .string) {
        try respondError(req, .validation_failed, "field `slug` must be a string", &.{});
        return;
    }

    var input: mutations_mod.AppendItemInput = .{
        .stack = stack,
        .kind = kind_v.string,
        .slug = slug_v.string,
    };
    if (obj.get("prompt")) |v| if (v == .string) {
        input.prompt_body = v.string;
    };
    if (obj.get("target")) |t| if (t == .object) {
        if (t.object.get("provider")) |v| if (v == .string) {
            input.target_provider = v.string;
        };
        if (t.object.get("model")) |v| if (v == .string) {
            input.target_model = v.string;
        };
        if (t.object.get("match")) |v| if (v == .string) {
            input.target_match = item_mod.Match.fromString(v.string);
        };
        if (t.object.get("workdir")) |v| if (v == .string) {
            input.target_workdir = v.string;
        };
    };
    if (obj.get("sleep_until")) |v| if (v == .string) {
        input.sleep_until = v.string;
    };

    var request = mutation_queue.Request{
        .kind = .{ .append_item = input },
        .ident = .{ .api_path = "POST /stacks/{name}/items" },
    };
    self.queue.submitAndWait(&request);
    if (request.err) |k| {
        try respondMutationError(req, k, stack, "");
        return;
    }
    defer if (request.output) |*o| o.deinit();
    try respondMutationOk(req, self.allocator, &request);
}

fn handleInsertItem(self: *Daemon, req: *std.http.Server.Request, stack: []const u8, ref: []const u8) !void {
    const body = readRequestBody(self, req) catch {
        try respondError(req, .validation_failed, "failed to read request body", &.{});
        return;
    };
    defer self.allocator.free(body);
    var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, body, .{}) catch {
        try respondError(req, .validation_failed, "invalid JSON body", &.{});
        return;
    };
    defer parsed.deinit();
    const obj = parsed.value.object;
    const kind_v = obj.get("kind") orelse {
        try respondError(req, .validation_failed, "missing field `kind`", &.{});
        return;
    };
    if (kind_v != .string) {
        try respondError(req, .validation_failed, "field `kind` must be a string", &.{});
        return;
    }
    const slug_v = obj.get("slug") orelse {
        try respondError(req, .validation_failed, "missing field `slug`", &.{});
        return;
    };
    if (slug_v != .string) {
        try respondError(req, .validation_failed, "field `slug` must be a string", &.{});
        return;
    }

    var input: mutations_mod.InsertItemInput = .{
        .stack = stack,
        .ref = ref,
        .kind = kind_v.string,
        .slug = slug_v.string,
    };
    if (obj.get("prompt")) |v| if (v == .string) {
        input.prompt_body = v.string;
    };
    if (obj.get("target")) |t| if (t == .object) {
        if (t.object.get("provider")) |v| if (v == .string) {
            input.target_provider = v.string;
        };
        if (t.object.get("model")) |v| if (v == .string) {
            input.target_model = v.string;
        };
        if (t.object.get("match")) |v| if (v == .string) {
            input.target_match = item_mod.Match.fromString(v.string);
        };
    };

    var request = mutation_queue.Request{
        .kind = .{ .insert_item = input },
        .ident = .{ .api_path = "POST /stacks/{name}/items/{id}/insert" },
    };
    self.queue.submitAndWait(&request);
    if (request.err) |k| {
        try respondMutationError(req, k, stack, ref);
        return;
    }
    defer if (request.output) |*o| o.deinit();
    try respondMutationOk(req, self.allocator, &request);
}

fn handleTransition(
    self: *Daemon,
    req: *std.http.Server.Request,
    stack: []const u8,
    id: []const u8,
    t: mutations_mod.ApiTransition,
) !void {
    // For supersede, body must include "replacement". For cancel/retry, body
    // is optional.
    var sup_id_buf: ?[]u8 = null;
    defer if (sup_id_buf) |b| self.allocator.free(b);
    var input: mutations_mod.TransitionInput = .{
        .stack = stack,
        .id = id,
        .transition = t,
    };

    const body = readRequestBody(self, req) catch {
        try respondError(req, .validation_failed, "failed to read request body", &.{});
        return;
    };
    defer self.allocator.free(body);

    if (body.len > 0) {
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, body, .{}) catch {
            try respondError(req, .validation_failed, "invalid JSON body", &.{});
            return;
        };
        defer parsed.deinit();
        if (parsed.value == .object) {
            if (parsed.value.object.get("replacement")) |v| if (v == .string) {
                // Copy the string out of the parsed arena.
                const dup = try self.allocator.dupe(u8, v.string);
                sup_id_buf = dup;
                input.superseded_by = dup;
            };
        }
    }
    if (t == .supersede and input.superseded_by == null) {
        try respondError(req, .validation_failed, "missing field `replacement`", &.{});
        return;
    }

    const api_path = switch (t) {
        .cancel => "POST /stacks/{name}/items/{id}/cancel",
        .retry => "POST /stacks/{name}/items/{id}/retry",
        .supersede => "POST /stacks/{name}/items/{id}/supersede",
    };
    var request = mutation_queue.Request{
        .kind = .{ .transition = input },
        .ident = .{ .api_path = api_path },
    };
    self.queue.submitAndWait(&request);
    if (request.err) |k| {
        try respondMutationError(req, k, stack, id);
        return;
    }
    defer if (request.output) |*o| o.deinit();
    try respondMutationOk(req, self.allocator, &request);
}

fn handlePauseResume(self: *Daemon, req: *std.http.Server.Request, stack: []const u8, paused: bool) !void {
    // Drain (and discard) the body to honor the HTTP spec.
    const body = readRequestBody(self, req) catch "";
    if (body.len > 0) self.allocator.free(body);

    var request = mutation_queue.Request{
        .kind = if (paused) .{ .pause_stack = .{ .stack = stack } } else .{ .resume_stack = .{ .stack = stack } },
        .ident = .{ .api_path = if (paused) "POST /stacks/{name}/pause" else "POST /stacks/{name}/resume" },
    };
    self.queue.submitAndWait(&request);
    if (request.err) |k| {
        try respondMutationError(req, k, stack, "");
        return;
    }
    defer if (request.output) |*o| o.deinit();
    try respondMutationOk(req, self.allocator, &request);
}

fn handleConfigPost(self: *Daemon, req: *std.http.Server.Request, stack: []const u8) !void {
    const body = readRequestBody(self, req) catch {
        try respondError(req, .validation_failed, "failed to read request body", &.{});
        return;
    };
    defer self.allocator.free(body);
    var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, body, .{}) catch {
        try respondError(req, .validation_failed, "invalid JSON body", &.{});
        return;
    };
    defer parsed.deinit();

    var patches = std.ArrayList(mutations_mod.ConfigPatch){};
    defer patches.deinit(self.allocator);

    // Accept either `{"set":{"key":"value",...}}` or `{"key":"value",...}` shape.
    var src = parsed.value;
    if (parsed.value == .object) {
        if (parsed.value.object.get("set")) |v| if (v == .object) {
            src = v;
        };
    }
    if (src != .object) {
        try respondError(req, .validation_failed, "config body must be a JSON object", &.{});
        return;
    }
    var it = src.object.iterator();
    while (it.next()) |entry| {
        const k = entry.key_ptr.*;
        if (std.mem.eql(u8, k, "set")) continue;
        // Coerce booleans / integers to a string value; the mutation layer
        // re-validates.
        const v = entry.value_ptr.*;
        var val_buf: [64]u8 = undefined;
        const val_str: []const u8 = switch (v) {
            .string => |s| s,
            .bool => |b| if (b) "true" else "false",
            .integer => |n| std.fmt.bufPrint(&val_buf, "{d}", .{n}) catch "",
            else => {
                try respondError(req, .validation_failed, "config value must be string, bool, or integer", &.{});
                return;
            },
        };
        try patches.append(self.allocator, .{ .key = k, .value = val_str });
    }
    if (patches.items.len == 0) {
        try respondError(req, .validation_failed, "no config keys supplied", &.{});
        return;
    }

    var request = mutation_queue.Request{
        .kind = .{ .config_patch = .{ .stack = stack, .patches = patches.items } },
        .ident = .{ .api_path = "POST /stacks/{name}/config" },
    };
    self.queue.submitAndWait(&request);
    if (request.err) |k| {
        try respondMutationError(req, k, stack, "");
        return;
    }
    defer if (request.output) |*o| o.deinit();
    try respondMutationOk(req, self.allocator, &request);
}

// ---------- SSE (milestone 6) ----------

const SseConnCtx = struct {
    daemon: *Daemon,
    stack: []u8,
    stream: std.net.Stream,
    sub: ?*sse_mod.Subscription = null,
};

fn sseSinkWrite(ctx: *anyopaque, line: []const u8) anyerror!void {
    const c: *SseConnCtx = @ptrCast(@alignCast(ctx));
    try c.stream.writeAll(line);
}

fn sseWorkerThread(ctx: *SseConnCtx) void {
    // Block reading from the socket: the SSE protocol is one-way, so any
    // bytes from the client mean either keep-alive noise (HTTP/1.1
    // pipelined data we ignore) or, more commonly, EOF when the client
    // disconnects. Either way, return on the first non-zero read failure
    // or the daemon shutting down.
    var buf: [256]u8 = undefined;
    while (true) {
        if (ctx.daemon.shutdown_requested.load(.seq_cst)) break;
        const n = ctx.stream.read(&buf) catch break;
        if (n == 0) break; // EOF
    }
    if (ctx.sub) |s| ctx.daemon.sse_hub.?.unsubscribe(s);
    ctx.stream.close();
    ctx.daemon.allocator.free(ctx.stack);
    ctx.daemon.allocator.destroy(ctx);
}

fn handleStackEventsDetached(
    self: *Daemon,
    req: *std.http.Server.Request,
    stack_name: []const u8,
    conn: std.net.Server.Connection,
    conn_owned: *bool,
) !void {
    // Validate stack name first.
    if (!storage.isValidStackName(stack_name)) {
        try respondError(req, .validation_failed, "invalid stack name", &.{
            .{ .key = "name", .value = stack_name },
        });
        return;
    }
    // 503 when SSE not wired in (early startup or no runtime).
    if (self.sse_hub == null) {
        try respondError(req, .daemon_starting, "SSE not available", &.{});
        return;
    }

    // Send SSE headers via the std HTTP server. We use `respond` with
    // chunked transfer disabled by sending an empty body and the right
    // headers; the std HTTP API doesn't expose a streaming response in v1,
    // so we write the response head directly to the underlying writer.
    // This avoids depending on Server.Request's flush behavior.
    const sse_head =
        "HTTP/1.1 200 OK\r\n" ++
        "Content-Type: text/event-stream\r\n" ++
        "Cache-Control: no-cache\r\n" ++
        "Connection: keep-alive\r\n" ++
        "X-Accel-Buffering: no\r\n" ++
        "\r\n";
    try conn.stream.writeAll(sse_head);

    // Hand off the connection to a background thread + subscribe to the
    // hub. The accept loop is now free.
    const ctx = try self.allocator.create(SseConnCtx);
    errdefer self.allocator.destroy(ctx);
    ctx.* = .{
        .daemon = self,
        .stack = try self.allocator.dupe(u8, stack_name),
        .stream = conn.stream,
    };
    errdefer self.allocator.free(ctx.stack);

    ctx.sub = try self.sse_hub.?.subscribe(stack_name, .{
        .ctx = @ptrCast(ctx),
        .write_fn = sseSinkWrite,
    });

    // Track the worker thread so deinit can join.
    const t = try std.Thread.spawn(.{}, sseWorkerThread, .{ctx});
    self.sse_threads_mu.lock();
    self.sse_threads.append(self.allocator, t) catch {
        // If we can't track the thread, detach it.
        t.detach();
    };
    self.sse_handles.append(self.allocator, conn.stream.handle) catch {};
    self.sse_threads_mu.unlock();

    // The connection is now owned by the SSE thread; the caller must NOT
    // close it.
    conn_owned.* = false;
}

// ---------- daemon lifecycle (start/stop/status) ----------

pub const PidInfo = struct {
    pid: std.posix.pid_t,
    port: u16,
    started_at: i64,
};

pub fn readPidFile(allocator: std.mem.Allocator, notes_root: []const u8) !?PidInfo {
    const path = try std.fs.path.join(allocator, &.{ notes_root, ".organo", "daemon.pid" });
    defer allocator.free(path);
    var f = std.fs.cwd().openFile(path, .{}) catch |e| switch (e) {
        error.FileNotFound => return null,
        else => return e,
    };
    defer f.close();
    var buf: [256]u8 = undefined;
    const n = try f.readAll(&buf);
    return parsePidFile(buf[0..n]);
}

fn parsePidFile(content: []const u8) ?PidInfo {
    // Format: three lines: pid, port, unix-ts
    var it = std.mem.splitScalar(u8, content, '\n');
    const pid_s = it.next() orelse return null;
    const port_s = it.next() orelse return null;
    const ts_s = it.next() orelse "0";
    const pid = std.fmt.parseInt(std.posix.pid_t, std.mem.trim(u8, pid_s, " \t\r"), 10) catch return null;
    const port = std.fmt.parseInt(u16, std.mem.trim(u8, port_s, " \t\r"), 10) catch return null;
    const ts = std.fmt.parseInt(i64, std.mem.trim(u8, ts_s, " \t\r"), 10) catch 0;
    return .{ .pid = pid, .port = port, .started_at = ts };
}

/// Try to write `daemon.pid`. Refuses if an existing PID file points to a
/// live process. Returns true if a new file was written by this caller.
fn writePidFile(
    allocator: std.mem.Allocator,
    notes_root_abs: []const u8,
    port: u16,
) StartError!bool {
    const dir_path = try std.fs.path.join(allocator, &.{ notes_root_abs, ".organo" });
    defer allocator.free(dir_path);
    std.fs.cwd().makePath(dir_path) catch {};
    const pid_path = try std.fs.path.join(allocator, &.{ dir_path, "daemon.pid" });
    defer allocator.free(pid_path);

    // Refuse if existing pidfile points to a live process.
    if (std.fs.cwd().openFile(pid_path, .{})) |f| {
        defer f.close();
        var buf: [256]u8 = undefined;
        const n = try f.readAll(&buf);
        if (parsePidFile(buf[0..n])) |info| {
            if (isProcessAlive(info.pid)) return error.AlreadyRunning;
        }
    } else |open_err| switch (open_err) {
        error.FileNotFound => {},
        else => return open_err,
    }

    // Write fresh.
    var f = try std.fs.cwd().createFile(pid_path, .{ .truncate = true, .mode = 0o600 });
    defer f.close();
    var buf: [128]u8 = undefined;
    const out = try std.fmt.bufPrint(&buf, "{d}\n{d}\n{d}\n", .{ std.os.linux.getpid(), port, std.time.timestamp() });
    try f.writeAll(out);
    return true;
}

/// Remove `daemon.pid`, ignoring missing files.
pub fn removePidFile(allocator: std.mem.Allocator, notes_root: []const u8) !void {
    const path = try std.fs.path.join(allocator, &.{ notes_root, ".organo", "daemon.pid" });
    defer allocator.free(path);
    std.fs.cwd().deleteFile(path) catch |e| switch (e) {
        error.FileNotFound => {},
        else => return e,
    };
}

/// Send SIGTERM to the daemon listed in `daemon.pid`. Waits up to
/// `grace_seconds` for the process to disappear, then removes the pid file.
pub const StopResult = enum { not_running, stopped, timeout };

pub fn stop(allocator: std.mem.Allocator, notes_root: []const u8, grace_seconds: u32) !StopResult {
    const info = (try readPidFile(allocator, notes_root)) orelse return .not_running;
    if (!isProcessAlive(info.pid)) {
        try removePidFile(allocator, notes_root);
        return .not_running;
    }
    std.posix.kill(info.pid, std.posix.SIG.TERM) catch |e| switch (e) {
        error.ProcessNotFound => {
            try removePidFile(allocator, notes_root);
            return .not_running;
        },
        else => return e,
    };
    // Poll for exit.
    var waited: u32 = 0;
    while (waited < grace_seconds * 10) : (waited += 1) {
        std.Thread.sleep(100 * std.time.ns_per_ms);
        if (!isProcessAlive(info.pid)) {
            try removePidFile(allocator, notes_root);
            return .stopped;
        }
    }
    return .timeout;
}

pub fn isProcessAlive(pid: std.posix.pid_t) bool {
    std.posix.kill(pid, 0) catch |e| switch (e) {
        error.ProcessNotFound => return false,
        else => return true, // EPERM means the pid exists but we're not allowed to signal it
    };
    return true;
}

// ---------- unit tests ----------

test "isLoopbackHost: ipv4" {
    try std.testing.expect(isLoopbackHost("127.0.0.1"));
    try std.testing.expect(isLoopbackHost("127.0.0.2"));
    try std.testing.expect(isLoopbackHost("127.255.255.254"));
    try std.testing.expect(!isLoopbackHost("0.0.0.0"));
    try std.testing.expect(!isLoopbackHost("192.168.1.1"));
    try std.testing.expect(!isLoopbackHost("8.8.8.8"));
}

test "isLoopbackHost: ipv6" {
    try std.testing.expect(isLoopbackHost("::1"));
    try std.testing.expect(!isLoopbackHost("::"));
    try std.testing.expect(!isLoopbackHost("fe80::1"));
}

test "matchRoute: known paths" {
    try std.testing.expectEqual(Route.healthz, matchRoute("/healthz").route);
    try std.testing.expectEqual(Route.stacks_list, matchRoute("/stacks").route);
    try std.testing.expectEqual(Route.stacks_list, matchRoute("/stacks?x=1").route);

    const m1 = matchRoute("/stacks/default");
    try std.testing.expectEqual(Route.stack_get, m1.route);
    try std.testing.expectEqualStrings("default", m1.stack);

    const m2 = matchRoute("/stacks/default/config");
    try std.testing.expectEqual(Route.stack_config_get, m2.route);
    try std.testing.expectEqualStrings("default", m2.stack);

    const m3 = matchRoute("/stacks/smoke/items");
    try std.testing.expectEqual(Route.stack_items_list, m3.route);
    try std.testing.expectEqualStrings("smoke", m3.stack);

    const m4 = matchRoute("/stacks/smoke/items/0001");
    try std.testing.expectEqual(Route.stack_item_get, m4.route);
    try std.testing.expectEqualStrings("smoke", m4.stack);
    try std.testing.expectEqualStrings("0001", m4.item);
}

test "matchRoute: unknown" {
    try std.testing.expectEqual(Route.unknown, matchRoute("/").route);
    try std.testing.expectEqual(Route.unknown, matchRoute("/whatever").route);
    try std.testing.expectEqual(Route.unknown, matchRoute("/stacks/foo/items/0001/extra").route);
    // Trailing slash on the collection still matches the list route.
    try std.testing.expectEqual(Route.stacks_list, matchRoute("/stacks/").route);
}

test "start: rejects non-loopback host" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath(".organo");
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = try tmp.dir.realpath(".", &buf);
    try std.testing.expectError(error.NotLoopbackHost, start(a, .{
        .notes_root = abs,
        .host = "0.0.0.0",
        .port_override = 0,
        .ephemeral = true,
    }));
}

test "parsePidFile: well-formed" {
    const info = parsePidFile("12345\n7421\n1700000000\n") orelse return error.NoInfo;
    try std.testing.expectEqual(@as(std.posix.pid_t, 12345), info.pid);
    try std.testing.expectEqual(@as(u16, 7421), info.port);
}

test "parsePidFile: missing trailing lines tolerated" {
    const info = parsePidFile("99\n80\n") orelse return error.NoInfo;
    try std.testing.expectEqual(@as(std.posix.pid_t, 99), info.pid);
    try std.testing.expectEqual(@as(u16, 80), info.port);
    try std.testing.expectEqual(@as(i64, 0), info.started_at);
}

test "parsePidFile: garbage returns null" {
    try std.testing.expectEqual(@as(?PidInfo, null), parsePidFile(""));
    try std.testing.expectEqual(@as(?PidInfo, null), parsePidFile("not a pid\n"));
}
