//! Loopback HTTP client used by the CLI to talk to the local daemon.
//!
//! The daemon is loopback-only (see `todos/design_daemon.md`), so this client
//! is deliberately minimal: it speaks HTTP/1.1 over a raw TCP connection,
//! supports a tiny Bearer-token header for future mutation requests, and parses
//! responses just enough to surface `(status, body)` to the caller.
//!
//! We avoid `std.http.Client` here because (a) we don't need redirects, TLS,
//! chunked decoding beyond what the daemon emits, or connection pooling, and
//! (b) the existing daemon tests use the same raw socket pattern, so the
//! framing assumptions are already validated.
//!
//! Port resolution order (highest priority first):
//!   1. `Opts.port_override` (`--port/-p` on the CLI).
//!   2. `STAKO_PORT` environment variable.
//!   3. `<root>/.stako/config.local.toml` daemon.port.
//!   4. `<root>/.stako/config.toml` daemon.port.
//!   5. Builtin default (7421, via Config defaults).

const std = @import("std");
const config_mod = @import("config.zig");
const local_token = @import("local_token.zig");

/// We use `anyerror` for the public surface because the combined error set of
/// network + file + config-loading is broad and unlikely to be exhaustively
/// matched by callers — they all funnel through the same `reportClientError`
/// path in `cli_stack.zig`. The narrow sentinel cases (`DaemonNotRunning`,
/// `BadResponse`, etc.) are still returned by name; everything else is
/// stringified via `@errorName`.
pub const ClientError = anyerror;

/// CLI-visible knobs that select the daemon endpoint.
pub const Opts = struct {
    /// Notes root used to read config and the local token. Resolves relative
    /// paths against the cwd at call time.
    root: []const u8,
    /// `--port/-p` override (highest priority).
    port_override: ?u16 = null,
    /// Loopback host. Defaults to 127.0.0.1.
    host: []const u8 = "127.0.0.1",
    /// When true, errors include the resolved URL and port.
    verbose: bool = false,
    /// Per-read receive timeout. 0 disables (waits forever). The default keeps
    /// a stalled daemon from hanging the CLI indefinitely; ctrl-C is the
    /// fallback the user shouldn't need to reach for.
    read_timeout_ms: u32 = 10_000,
};

/// A resolved client, ready to issue requests. Owns no sockets — each
/// `request` opens and closes its own TCP connection.
pub const Client = struct {
    allocator: std.mem.Allocator,
    host: []const u8,
    port: u16,
    /// `null` when there's no `.stako/local_token` (e.g. user pointed
    /// `--root` at a non-initialized directory). Read endpoints don't require
    /// the token; we keep it loaded so milestone 5's mutation calls work
    /// without further plumbing.
    token: ?[]u8 = null,
    verbose: bool = false,
    read_timeout_ms: u32 = 10_000,

    pub fn deinit(self: *Client) void {
        if (self.token) |t| self.allocator.free(t);
    }
};

pub const Response = struct {
    allocator: std.mem.Allocator,
    status: u16,
    body: []u8,

    pub fn deinit(self: *Response) void {
        self.allocator.free(self.body);
    }
};

/// Build a `Client` from CLI options. Reads config.toml + config.local.toml
/// (tolerant of missing files) and optionally the local token. Caller owns
/// the returned client and must call `deinit`.
pub fn open(allocator: std.mem.Allocator, opts: Opts) ClientError!Client {
    // Port resolution.
    var port: u16 = 7421;
    // Missing `.stako/` is the common case (user invokes from outside an
    // initialized notes root and overrides everything via flags/env). Other
    // load errors — malformed TOML, wrong types, `PortOutOfRange` — must
    // surface; otherwise we silently downgrade to the default port and the
    // user sees a confusing "daemon not started" against a daemon that's
    // actually listening on the configured port.
    blk: {
        var cfg = config_mod.loadFromRoot(allocator, opts.root) catch |e| switch (e) {
            error.FileNotFound, error.NotDir => break :blk,
            else => return e,
        };
        defer cfg.deinit();
        port = cfg.daemon.port;
    }
    // STAKO_PORT env override.
    if (std.process.getEnvVarOwned(allocator, "STAKO_PORT")) |val| {
        defer allocator.free(val);
        if (std.fmt.parseInt(u16, val, 10)) |p| {
            port = p;
        } else |_| {
            return error.BadFlagValue;
        }
    } else |e| switch (e) {
        error.EnvironmentVariableNotFound => {},
        else => return e,
    }
    if (opts.port_override) |p| port = p;

    // Token (optional). If `.stako/local_token` exists, use it. Otherwise
    // we proceed without one — read endpoints don't require it.
    var token_owned: ?[]u8 = null;
    if (loadTokenIfPresent(allocator, opts.root)) |t| {
        token_owned = t;
    } else |_| {}

    return .{
        .allocator = allocator,
        .host = opts.host,
        .port = port,
        .token = token_owned,
        .verbose = opts.verbose,
        .read_timeout_ms = opts.read_timeout_ms,
    };
}

fn loadTokenIfPresent(
    allocator: std.mem.Allocator,
    notes_root: []const u8,
) !?[]u8 {
    const path = try std.fs.path.join(allocator, &.{ notes_root, ".stako", "local_token" });
    defer allocator.free(path);
    var f = std.fs.cwd().openFile(path, .{}) catch return null;
    defer f.close();
    const stat = try f.stat();
    if (stat.size == 0) return null;
    const buf = try allocator.alloc(u8, stat.size);
    errdefer allocator.free(buf);
    const n = try f.readAll(buf);
    var end = n;
    while (end > 0 and (buf[end - 1] == '\n' or buf[end - 1] == '\r')) end -= 1;
    if (end == 0) {
        allocator.free(buf);
        return null;
    }
    // Shrink to the trimmed length.
    if (end < buf.len) {
        const trimmed = try allocator.dupe(u8, buf[0..end]);
        allocator.free(buf);
        return trimmed;
    }
    return buf;
}

/// Issue a GET against `path` (no body). Caller owns the returned `Response`.
pub fn get(self: *const Client, path: []const u8) ClientError!Response {
    return request(self, "GET", path, null);
}

/// Issue a request. `body` is sent verbatim with a content-length header;
/// `null` body means no body and no `content-length`.
pub fn request(
    self: *const Client,
    method: []const u8,
    path: []const u8,
    body: ?[]const u8,
) ClientError!Response {
    const addr = std.net.Address.parseIp(self.host, self.port) catch
        return error.BadHost;
    var stream = std.net.tcpConnectToAddress(addr) catch |e| switch (e) {
        error.ConnectionRefused => return error.DaemonNotRunning,
        else => return e,
    };
    defer stream.close();

    if (self.read_timeout_ms > 0) {
        // SO_RCVTIMEO bounds each `stream.read` call so a hung daemon can't
        // pin the CLI indefinitely. Failure to set the option (older kernel,
        // unusual platform) is non-fatal: the read loop's error handling
        // still catches EOF; a slow-but-progressing daemon stays usable.
        const tv = std.posix.timeval{
            .sec = @intCast(self.read_timeout_ms / 1000),
            .usec = @intCast((self.read_timeout_ms % 1000) * 1000),
        };
        std.posix.setsockopt(
            stream.handle,
            std.posix.SOL.SOCKET,
            std.posix.SO.RCVTIMEO,
            std.mem.asBytes(&tv),
        ) catch {};
    }

    // Compose the request.
    var req_buf = std.ArrayList(u8){};
    defer req_buf.deinit(self.allocator);
    const w = req_buf.writer(self.allocator);
    try w.print("{s} {s} HTTP/1.1\r\n", .{ method, path });
    try w.print("Host: {s}:{d}\r\n", .{ self.host, self.port });
    try w.writeAll("Connection: close\r\n");
    try w.writeAll("Accept: application/json\r\n");
    if (self.token) |t| {
        try w.print("Authorization: Bearer {s}\r\n", .{t});
    }
    if (body) |b| {
        try w.print("Content-Length: {d}\r\n", .{b.len});
        try w.writeAll("Content-Type: application/json\r\n");
        try w.writeAll("\r\n");
        try w.writeAll(b);
    } else {
        try w.writeAll("\r\n");
    }
    try stream.writeAll(req_buf.items);

    // Read the full response.
    var resp_buf = std.ArrayList(u8){};
    errdefer resp_buf.deinit(self.allocator);
    var tmp: [4096]u8 = undefined;
    while (true) {
        const n = stream.read(&tmp) catch |e| switch (e) {
            // A receive-timeout firing means the daemon stopped sending mid
            // response. Surface it rather than passing a truncated body to
            // `parseResponse`, which would silently accept any framing that
            // happens to align (no Content-Length, chunk boundary, …).
            error.WouldBlock => return error.TransportTimeout,
            // EOF — Zig 0.15 reports clean stream end as ConnectionResetByPeer
            // on some Linux flavors; we cannot distinguish "clean RST" from
            // "abrupt mid-body RST" cheaply, so we accept it as EOF and let
            // parseResponse's framing checks (Content-Length, chunked) catch
            // mid-body truncation when those headers are present.
            error.ConnectionResetByPeer => break,
            else => return error.TransportError,
        };
        if (n == 0) break;
        try resp_buf.appendSlice(self.allocator, tmp[0..n]);
        // Cap at 8 MiB to prevent runaway response accumulation.
        if (resp_buf.items.len > 8 * 1024 * 1024) break;
    }
    const raw = try resp_buf.toOwnedSlice(self.allocator);
    defer self.allocator.free(raw);

    return parseResponse(self.allocator, raw);
}

/// Parse status line + body. Tolerates simple chunked / content-length /
/// connection-close framing; in practice the daemon always uses one of those
/// two (content-length when std.http.Server knows the body up front, or
/// connection-close).
pub fn parseResponse(allocator: std.mem.Allocator, raw: []const u8) ClientError!Response {
    const head_end = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return error.BadResponse;
    const head = raw[0..head_end];
    const body_start: usize = head_end + 4;

    // Status line: "HTTP/1.1 <code> <reason>".
    const sp1 = std.mem.indexOfScalar(u8, head, ' ') orelse return error.BadResponse;
    const after = head[sp1 + 1 ..];
    const sp2 = std.mem.indexOfScalar(u8, after, ' ') orelse after.len;
    const code = std.fmt.parseInt(u16, after[0..sp2], 10) catch return error.BadResponse;

    // Detect Transfer-Encoding and Content-Length.
    var chunked = false;
    var content_length: ?usize = null;
    var it = std.mem.splitSequence(u8, head, "\r\n");
    _ = it.next(); // skip status line
    while (it.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        if (asciiEqlIgnoreCase(name, "transfer-encoding") and asciiEqlIgnoreCase(value, "chunked")) {
            chunked = true;
        } else if (asciiEqlIgnoreCase(name, "content-length")) {
            content_length = std.fmt.parseInt(usize, value, 10) catch return error.BadResponse;
        }
    }

    const body_raw = raw[body_start..];
    var body_owned: []u8 = undefined;
    if (chunked) {
        body_owned = try decodeChunked(allocator, body_raw);
    } else if (content_length) |len| {
        if (body_raw.len < len) return error.BadResponse;
        body_owned = try allocator.dupe(u8, body_raw[0..len]);
    } else {
        body_owned = try allocator.dupe(u8, body_raw);
    }
    return .{ .allocator = allocator, .status = code, .body = body_owned };
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

/// Minimal chunked decoder: reads `<hex>\r\n<bytes>\r\n` chunks until a zero
/// chunk. Trailers are ignored.
fn decodeChunked(allocator: std.mem.Allocator, src: []const u8) ![]u8 {
    var out = std.ArrayList(u8){};
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < src.len) {
        const eol = std.mem.indexOfPos(u8, src, i, "\r\n") orelse break;
        // Chunk size in hex; the line may contain ";extension" — we ignore it.
        const size_end = std.mem.indexOfScalarPos(u8, src, i, ';') orelse eol;
        const hex = std.mem.trim(u8, src[i..@min(size_end, eol)], " \t");
        const sz = std.fmt.parseInt(usize, hex, 16) catch return error.BadResponse;
        i = eol + 2;
        if (sz == 0) break;
        if (i + sz > src.len) return error.BadResponse;
        try out.appendSlice(allocator, src[i .. i + sz]);
        i += sz;
        // Each chunk is followed by CRLF.
        if (i + 2 <= src.len) i += 2;
    }
    return out.toOwnedSlice(allocator);
}

// ---------- unit tests ----------

test "parseResponse: simple 200" {
    const a = std.testing.allocator;
    const raw = "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: 13\r\n\r\n{\"ok\":true}\r\n";
    var r = try parseResponse(a, raw);
    defer r.deinit();
    try std.testing.expectEqual(@as(u16, 200), r.status);
    try std.testing.expectEqualStrings("{\"ok\":true}\r\n", r.body);
}

test "parseResponse: content-length trims trailing bytes" {
    const a = std.testing.allocator;
    const raw = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nokignored";
    var r = try parseResponse(a, raw);
    defer r.deinit();
    try std.testing.expectEqualStrings("ok", r.body);
}

test "parseResponse: 404 with JSON body" {
    const a = std.testing.allocator;
    const raw = "HTTP/1.1 404 not found\r\ncontent-length: 30\r\n\r\n{\"error\":{\"code\":\"not_found\"}}";
    var r = try parseResponse(a, raw);
    defer r.deinit();
    try std.testing.expectEqual(@as(u16, 404), r.status);
    try std.testing.expect(std.mem.indexOf(u8, r.body, "\"not_found\"") != null);
}

test "parseResponse: chunked decoding" {
    const a = std.testing.allocator;
    // Two chunks: "Hello, " (7=0x7) and "world!" (6=0x6), then 0-chunk.
    const raw = "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n7\r\nHello, \r\n6\r\nworld!\r\n0\r\n\r\n";
    var r = try parseResponse(a, raw);
    defer r.deinit();
    try std.testing.expectEqual(@as(u16, 200), r.status);
    try std.testing.expectEqualStrings("Hello, world!", r.body);
}

test "parseResponse: rejects garbage" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.BadResponse, parseResponse(a, "not http"));
}

test "parseResponse: rejects content-length larger than the body we received" {
    const a = std.testing.allocator;
    const raw = "HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\nshort";
    try std.testing.expectError(error.BadResponse, parseResponse(a, raw));
}

test "asciiEqlIgnoreCase" {
    try std.testing.expect(asciiEqlIgnoreCase("Content-Type", "content-type"));
    try std.testing.expect(asciiEqlIgnoreCase("ABC", "abc"));
    try std.testing.expect(!asciiEqlIgnoreCase("ABC", "abcd"));
}
