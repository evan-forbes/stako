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

pub const StartOptions = struct {
    /// Notes-root directory (path; resolved internally).
    notes_root: []const u8,
    /// Override the port from config.
    port_override: ?u16 = null,
    /// Host. Defaults to "127.0.0.1". Must be a loopback address.
    host: []const u8 = "127.0.0.1",
    /// When true, do not write daemon.pid / daemon.log (used by tests).
    ephemeral: bool = false,
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

    pub fn deinit(self: *Daemon) void {
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
        // Close the listening socket so the blocked accept() in
        // `serveUntilShutdown` returns immediately. The server struct is left
        // in an unusable state, which is fine because we are shutting down.
        const handle = self.server.stream.handle;
        if (handle >= 0) {
            std.posix.shutdown(handle, .both) catch {};
        }
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
    };
    d.logLine("[{d}] daemon started on 127.0.0.1:{d}", .{ std.time.timestamp(), bound_port });
    return d;
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
    defer conn.stream.close();
    try handleConnection(self, conn);
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
        defer conn.stream.close();
        handleConnection(self, conn) catch |e| {
            std.log.warn("organo: request failed: {s}", .{@errorName(e)});
        };
    }
}

fn handleConnection(self: *Daemon, conn: std.net.Server.Connection) !void {
    var read_buf: [16 * 1024]u8 = undefined;
    var write_buf: [16 * 1024]u8 = undefined;
    var net_reader = conn.stream.reader(&read_buf);
    var net_writer = conn.stream.writer(&write_buf);
    var http_server = std.http.Server.init(net_reader.interface(), &net_writer.interface);
    var req = http_server.receiveHead() catch |e| {
        writeRawError(&net_writer.interface, 400, "bad request") catch {};
        return e;
    };
    try route(self, &req);
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
        if (std.mem.startsWith(u8, after, "items/")) {
            const id = after["items/".len..];
            // Reject anything past `/items/<id>`.
            if (std.mem.indexOfScalar(u8, id, '/') != null) return .{ .route = .unknown };
            return .{ .route = .stack_item_get, .stack = name, .item = id };
        }
    }
    return .{ .route = .unknown };
}

fn route(self: *Daemon, req: *std.http.Server.Request) !void {
    const m = matchRoute(req.head.target);
    // All milestone-3 endpoints are read-only; reject non-GET on read paths.
    if (m.route != .unknown and req.head.method != .GET and req.head.method != .HEAD) {
        try respondError(req, .validation_failed, "method not allowed (read-only in milestone 3)", &.{});
        return;
    }

    switch (m.route) {
        .healthz => try respondOkText(req, "ok\n"),
        .stacks_list => try respondStacksList(self, req),
        .stack_get => try respondStackGet(self, req, m.stack),
        .stack_config_get => try respondStackConfigGet(self, req, m.stack),
        .stack_items_list => try respondStackItemsList(self, req, m.stack),
        .stack_item_get => try respondStackItemGet(self, req, m.stack, m.item),
        .unknown => try respondError(req, .not_found, "endpoint not found", &.{}),
    }
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
