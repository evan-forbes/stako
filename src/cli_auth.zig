//! `stako auth ...` implementation (milestone 8).
//!
//! Wraps the daemon's `GET /providers` and `GET /providers/{name}` read
//! endpoints. Mirrors `cli_stack.zig`'s "daemon JSON → human rendering"
//! pattern. The CLI never probes providers locally — all data comes from
//! the daemon so a single source of truth governs availability.

const std = @import("std");
const cli = @import("cli.zig");
const http_client = @import("http_client.zig");

pub fn run(
    allocator: std.mem.Allocator,
    args: cli.AuthArgs,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    if (args.action == .signout) {
        return try runSignout(args, stdout, stderr);
    }

    var client = http_client.open(allocator, .{
        .root = args.flags.root,
        .port_override = args.flags.port_override,
        .verbose = args.flags.verbose,
    }) catch |e| {
        try stderr.print("stako auth: failed to prepare client: {s}\n", .{@errorName(e)});
        return 1;
    };
    defer client.deinit();

    switch (args.action) {
        .status => return try runStatus(allocator, &client, args.flags, stdout, stderr),
        .provider => return try runOne(allocator, &client, args, stdout, stderr),
        .signout => unreachable,
    }
}

fn runStatus(
    allocator: std.mem.Allocator,
    client: *http_client.Client,
    flags: cli.ApiFlags,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    var resp = http_client.get(client, "/providers") catch |e| {
        return reportClientError(e, client, "/providers", stderr);
    };
    defer resp.deinit();
    if (resp.status != 200) {
        return reportApiError(resp.status, resp.body, "/providers", flags.verbose, stderr);
    }
    if (flags.json) {
        try stdout.writeAll(resp.body);
        try stdout.writeAll("\n");
        return 0;
    }
    try renderList(allocator, resp.body, stdout);
    return 0;
}

fn runOne(
    allocator: std.mem.Allocator,
    client: *http_client.Client,
    args: cli.AuthArgs,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    const path = try std.fmt.allocPrint(allocator, "/providers/{s}", .{args.provider_name});
    defer allocator.free(path);

    var resp = http_client.get(client, path) catch |e| {
        return reportClientError(e, client, path, stderr);
    };
    defer resp.deinit();
    if (resp.status != 200) {
        return reportApiError(resp.status, resp.body, path, args.flags.verbose, stderr);
    }
    if (args.flags.json) {
        try stdout.writeAll(resp.body);
        try stdout.writeAll("\n");
        return 0;
    }
    try renderOne(resp.body, stdout);
    return 0;
}

fn runSignout(
    args: cli.AuthArgs,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    // `--json` callers (scripted invocations) get a stable JSON envelope on
    // stdout so they don't have to parse the human prose. Exit code stays 1
    // either way. See audit I3.
    if (args.flags.json) {
        try stdout.print(
            "{{\"error\":\"not_supported\",\"action\":\"signout\",\"provider\":\"{s}\"," ++
                "\"message\":\"stako does not own provider subscription tokens; sign out via the provider's own CLI or unset the API-key env var\"}}\n",
            .{args.provider_name},
        );
        return 1;
    }
    try stderr.print(
        "stako auth: signout not supported for `{s}` in v1.\n" ++
            "  stako doesn't own provider subscription tokens; sign out via the\n" ++
            "  provider's own CLI (e.g. `claude logout`, `codex logout`) or unset\n" ++
            "  the API-key env var.\n",
        .{args.provider_name},
    );
    return 1;
}

// ---------- error reporting (shared shape with cli_stack.zig) ----------

fn reportClientError(
    e: anyerror,
    client: *http_client.Client,
    path: []const u8,
    stderr: anytype,
) !u8 {
    switch (e) {
        error.DaemonNotRunning, error.ConnectionRefused => {
            try stderr.writeAll("stako: daemon not started; try `stako daemon start`\n");
            if (client.verbose) {
                try stderr.print("  attempted: http://{s}:{d}{s}\n", .{ client.host, client.port, path });
            }
            return 1;
        },
        else => {
            try stderr.print("stako auth: request failed: {s}\n", .{@errorName(e)});
            if (client.verbose) {
                try stderr.print("  attempted: http://{s}:{d}{s}\n", .{ client.host, client.port, path });
            }
            return 1;
        },
    }
}

fn reportApiError(
    status: u16,
    body: []const u8,
    path: []const u8,
    verbose: bool,
    stderr: anytype,
) !u8 {
    const code = findJsonStringField(body, "\"code\":\"");
    const message = findJsonStringField(body, "\"message\":\"");
    if (code) |c| {
        try stderr.print("stako auth: HTTP {d} {s}", .{ status, c });
        if (message) |m| try stderr.print(": {s}", .{m});
        try stderr.writeAll("\n");
    } else {
        try stderr.print("stako auth: HTTP {d}\n", .{status});
    }
    if (verbose) try stderr.print("  path: {s}\n", .{path});
    return 1;
}

// ---------- renderers ----------

fn renderList(allocator: std.mem.Allocator, body: []const u8, stdout: anytype) !void {
    _ = allocator;
    // Body: {"providers":[{...},{...},...]}
    //
    // The header is printed only after we've located the `providers` array
    // marker; otherwise an unexpected body (e.g. a daemon-side regression
    // that drops the envelope) would print a column header followed by raw
    // JSON, which is confusing. See audit I1.
    const marker = "\"providers\":[";
    const start = std.mem.indexOf(u8, body, marker) orelse {
        try stdout.writeAll(body);
        try stdout.writeAll("\n");
        return;
    };
    var i: usize = start + marker.len;
    var first = true;
    try stdout.print("{s:<12} {s:<8} {s:<10} {s:<14} {s}\n", .{ "PROVIDER", "HARNESS", "BINARY", "AUTH", "NOTE" });
    while (i < body.len) {
        while (i < body.len and (body[i] == ' ' or body[i] == ',')) i += 1;
        if (i >= body.len or body[i] == ']') break;
        if (body[i] != '{') break;
        var depth: usize = 0;
        var end: usize = i;
        while (end < body.len) : (end += 1) {
            const c = body[end];
            if (c == '{') depth += 1;
            if (c == '}') {
                depth -= 1;
                if (depth == 0) {
                    end += 1;
                    break;
                }
            }
        }
        const obj = body[i..end];
        try renderRow(obj, stdout);
        i = end;
        first = false;
    }
    if (first) try stdout.writeAll("(no providers reported)\n");
}

fn renderRow(obj: []const u8, stdout: anytype) !void {
    const provider = findJsonStringField(obj, "\"provider\":\"") orelse "?";
    const harness = findJsonStringField(obj, "\"harness\":\"") orelse "?";
    const binary_present = findJsonRawField(obj, "\"binary_present\":") orelse "?";
    const auth = findJsonStringField(obj, "\"auth\":\"") orelse "?";
    const note = findJsonStringField(obj, "\"note\":\"") orelse "";
    const bin_label: []const u8 = if (std.mem.eql(u8, binary_present, "true")) "present" else "missing";
    try stdout.print("{s:<12} {s:<8} {s:<10} {s:<14} {s}\n", .{ provider, harness, bin_label, auth, note });
}

fn renderOne(body: []const u8, stdout: anytype) !void {
    const provider = findJsonStringField(body, "\"provider\":\"") orelse "?";
    const harness = findJsonStringField(body, "\"harness\":\"") orelse "?";
    const binary = findJsonStringField(body, "\"binary\":\"") orelse "?";
    const binary_present = findJsonRawField(body, "\"binary_present\":") orelse "false";
    const available = findJsonRawField(body, "\"available\":") orelse "false";
    const auth = findJsonStringField(body, "\"auth\":\"") orelse "unknown";
    const note = findJsonStringField(body, "\"note\":\"") orelse "";
    const hint = findJsonStringField(body, "\"login_hint\":\"") orelse "";
    const env = findJsonStringField(body, "\"credential_env\":\"") orelse "";

    try stdout.print("provider:        {s}\n", .{provider});
    try stdout.print("  harness:       {s}\n", .{harness});
    try stdout.print("  binary:        {s} ({s})\n", .{ binary, if (std.mem.eql(u8, binary_present, "true")) "present" else "missing" });
    try stdout.print("  available:     {s}\n", .{available});
    try stdout.print("  auth:          {s}\n", .{auth});
    try stdout.print("  credential_env:{s}\n", .{env});
    if (findJsonStringField(body, "\"blocked_reason\":\"")) |r| {
        try stdout.print("  blocked_reason:{s}\n", .{r});
    }
    try stdout.print("  note:          {s}\n", .{note});
    try stdout.print("  login_hint:    {s}\n", .{hint});
}

// ---------- shared JSON helpers (mirrored from cli_stack.zig) ----------

fn findJsonStringField(body: []const u8, needle_quote: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, body, needle_quote) orelse return null;
    const value_start = start + needle_quote.len;
    const remainder = body[value_start..];
    var i: usize = 0;
    while (i < remainder.len) : (i += 1) {
        if (remainder[i] == '\\' and i + 1 < remainder.len) {
            i += 1;
            continue;
        }
        if (remainder[i] == '"') return remainder[0..i];
    }
    return null;
}

fn findJsonRawField(body: []const u8, key: []const u8) ?[]const u8 {
    const pos = std.mem.indexOf(u8, body, key) orelse return null;
    var i = pos + key.len;
    while (i < body.len and body[i] == ' ') i += 1;
    const start = i;
    while (i < body.len) : (i += 1) {
        const c = body[i];
        if (c == ',' or c == '}') break;
    }
    return std.mem.trim(u8, body[start..i], " \t");
}

// ---------- unit tests ----------

test "renderRow grep: provider + auth in output" {
    const a = std.testing.allocator;
    var buf = std.ArrayList(u8){};
    defer buf.deinit(a);
    const obj = "{\"provider\":\"anthropic\",\"harness\":\"claude\",\"binary\":\"claude\",\"binary_present\":true,\"available\":true,\"auth\":\"signed_in\",\"note\":\"reusing creds\",\"login_hint\":\"x\",\"credential_env\":\"ANTHROPIC_API_KEY\"}";
    try renderRow(obj, buf.writer(a));
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "anthropic") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "claude") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "signed_in") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "present") != null);
}

test "renderList suppresses header when providers marker is absent" {
    // Audit I1: the column header must not appear before raw-body fallback
    // — otherwise a daemon regression that drops the envelope would print
    // a header followed by random JSON, which is confusing.
    const a = std.testing.allocator;
    var buf = std.ArrayList(u8){};
    defer buf.deinit(a);
    const body = "{\"unexpected\":\"shape\"}";
    try renderList(a, body, buf.writer(a));
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "PROVIDER") == null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "HARNESS") == null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "unexpected") != null);
}

test "renderList prints header when providers marker is present" {
    const a = std.testing.allocator;
    var buf = std.ArrayList(u8){};
    defer buf.deinit(a);
    const body = "{\"providers\":[]}";
    try renderList(a, body, buf.writer(a));
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "PROVIDER") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "(no providers reported)") != null);
}

test "runSignout --json emits a not_supported envelope on stdout" {
    // Audit I3: scripted callers that pass `--json` get a stable JSON
    // envelope on stdout while exit code remains 1.
    const a = std.testing.allocator;
    var out = std.ArrayList(u8){};
    defer out.deinit(a);
    var err = std.ArrayList(u8){};
    defer err.deinit(a);
    const args = cli.AuthArgs{
        .action = .signout,
        .provider_name = "anthropic",
        .flags = .{ .json = true },
    };
    const code = try runSignout(args, out.writer(a), err.writer(a));
    try std.testing.expectEqual(@as(u8, 1), code);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"error\":\"not_supported\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"provider\":\"anthropic\"") != null);
    // Human prose should NOT appear in JSON mode.
    try std.testing.expect(std.mem.indexOf(u8, err.items, "signout not supported") == null);
}

test "runSignout (no --json) prints human prose to stderr" {
    const a = std.testing.allocator;
    var out = std.ArrayList(u8){};
    defer out.deinit(a);
    var err = std.ArrayList(u8){};
    defer err.deinit(a);
    const args = cli.AuthArgs{
        .action = .signout,
        .provider_name = "openai",
        .flags = .{},
    };
    const code = try runSignout(args, out.writer(a), err.writer(a));
    try std.testing.expectEqual(@as(u8, 1), code);
    try std.testing.expect(std.mem.indexOf(u8, err.items, "signout not supported") != null);
    try std.testing.expect(std.mem.indexOf(u8, err.items, "openai") != null);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "renderOne grep: every field appears on its own line" {
    const a = std.testing.allocator;
    var buf = std.ArrayList(u8){};
    defer buf.deinit(a);
    const body = "{\"provider\":\"google\",\"harness\":\"gemini\",\"binary\":\"gemini\",\"binary_present\":false,\"available\":false,\"auth\":\"unknown\",\"blocked_reason\":\"harness_unavailable\",\"note\":\"deferred\",\"login_hint\":\"see docs\",\"credential_env\":\"GEMINI_API_KEY\"}";
    try renderOne(body, buf.writer(a));
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "provider:        google") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "harness:       gemini") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "blocked_reason:harness_unavailable") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "available:     false") != null);
}
