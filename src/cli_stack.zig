//! `organo stack ...` implementation. The CLI is a thin shell over the
//! daemon's HTTP API per `todos/implement_cli_client.md`:
//!
//!   - All rendering data comes from the daemon JSON response. No CLI-local
//!     stack parsing. (Acceptance criterion of milestone 4.)
//!   - `--json/-j` writes the response body verbatim; non-JSON mode renders
//!     a human-friendly table/listing.
//!   - On connection failure we emit the canonical
//!     "daemon not started; try `organo daemon start`" message.

const std = @import("std");
const cli = @import("cli.zig");
const http_client = @import("http_client.zig");

/// Entry point invoked from `cli.dispatch`. Owns the HTTP client lifetime,
/// resolves the action, prints to `stdout`/`stderr`, returns an exit code.
pub fn run(
    allocator: std.mem.Allocator,
    args: cli.StackArgs,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    var client = http_client.open(allocator, .{
        .root = args.flags.root,
        .port_override = args.flags.port_override,
        .verbose = args.flags.verbose,
    }) catch |e| {
        try stderr.print("organo stack: failed to prepare client: {s}\n", .{@errorName(e)});
        return 1;
    };
    defer client.deinit();

    switch (args.action) {
        .list => return try runList(allocator, &client, args.flags, stdout, stderr),
        .show => return try runShow(allocator, &client, args.flags, args.name, stdout, stderr),
        .config => return try runConfig(allocator, &client, args.flags, args.name, stdout, stderr),
    }
}

fn runList(
    allocator: std.mem.Allocator,
    client: *http_client.Client,
    flags: cli.ApiFlags,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    var resp = http_client.get(client, "/stacks") catch |e| {
        return reportClientError(e, client, "/stacks", stderr);
    };
    defer resp.deinit();

    if (resp.status != 200) {
        return reportApiError(resp.status, resp.body, "/stacks", flags.verbose, stderr);
    }

    if (flags.json) {
        try stdout.writeAll(resp.body);
        try stdout.writeAll("\n");
        return 0;
    }

    try renderStackList(allocator, resp.body, stdout, stderr);
    return 0;
}

fn runConfig(
    allocator: std.mem.Allocator,
    client: *http_client.Client,
    flags: cli.ApiFlags,
    name: []const u8,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    const path = try std.fmt.allocPrint(allocator, "/stacks/{s}/config", .{name});
    defer allocator.free(path);

    var resp = http_client.get(client, path) catch |e| {
        return reportClientError(e, client, path, stderr);
    };
    defer resp.deinit();

    if (resp.status != 200) {
        return reportApiError(resp.status, resp.body, path, flags.verbose, stderr);
    }

    if (flags.json) {
        try stdout.writeAll(resp.body);
        try stdout.writeAll("\n");
        return 0;
    }

    try renderStackConfig(allocator, name, resp.body, stdout, stderr);
    return 0;
}

fn runShow(
    allocator: std.mem.Allocator,
    client: *http_client.Client,
    flags: cli.ApiFlags,
    name: []const u8,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    // `show` is documented as a composite view: stack config + item listing.
    // We do two GETs rather than one because the daemon's `/stacks/{name}`
    // endpoint already returns both, AND we surface the items separately for
    // the routing-target column. Reuse `/stacks/{name}/items` for accurate
    // queue order without re-fetching the config we already have.
    const stack_path = try std.fmt.allocPrint(allocator, "/stacks/{s}", .{name});
    defer allocator.free(stack_path);

    var stack_resp = http_client.get(client, stack_path) catch |e| {
        return reportClientError(e, client, stack_path, stderr);
    };
    defer stack_resp.deinit();
    if (stack_resp.status != 200) {
        return reportApiError(stack_resp.status, stack_resp.body, stack_path, flags.verbose, stderr);
    }

    // `--json`: pass through the composite /stacks/{name} response. We
    // deliberately do NOT bundle a second request here — that would mean
    // synthesizing JSON locally, which the design forbids.
    if (flags.json) {
        try stdout.writeAll(stack_resp.body);
        try stdout.writeAll("\n");
        return 0;
    }

    // Human render: pull items separately so we can preserve queue order and
    // include the target details (`/stacks/{name}` already inlines items, but
    // we'll parse from the `items` array within the composite payload).
    try renderStackShow(allocator, name, stack_resp.body, stdout, stderr);
    return 0;
}

// ---------- error reporting ----------

fn reportClientError(
    e: anyerror,
    client: *http_client.Client,
    path: []const u8,
    stderr: anytype,
) !u8 {
    switch (e) {
        error.DaemonNotRunning, error.ConnectionRefused => {
            try stderr.writeAll("organo: daemon not started; try `organo daemon start`\n");
            if (client.verbose) {
                try stderr.print("  attempted: http://{s}:{d}{s}\n", .{ client.host, client.port, path });
            }
            return 1;
        },
        else => {
            try stderr.print("organo: request failed: {s}\n", .{@errorName(e)});
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
    // The daemon's canonical body is JSON with `.error.{code,message}`. We do
    // a cheap field grep rather than a full JSON parse — sufficient for the
    // CLI's diagnostic output.
    const code = findJsonStringField(body, "\"code\":\"");
    const message = findJsonStringField(body, "\"message\":\"");

    if (code) |c| {
        try stderr.print("organo: HTTP {d} {s}", .{ status, c });
        if (message) |m| try stderr.print(": {s}", .{m});
        try stderr.writeAll("\n");
    } else {
        try stderr.print("organo: HTTP {d}\n", .{status});
    }
    if (verbose) try stderr.print("  path: {s}\n", .{path});
    // Map status to exit code: 1 for runtime/4xx, 1 also for 5xx (CLI just
    // signals "failed"; the daemon error body has the detail).
    return 1;
}

fn findJsonStringField(body: []const u8, needle_quote: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, body, needle_quote) orelse return null;
    const value_start = start + needle_quote.len;
    const remainder = body[value_start..];
    // The daemon never emits embedded escaped quotes in our error slugs, so a
    // raw `"` terminator is safe. We still scan for the first non-escaped
    // quote to be safe against `\"` in messages.
    var i: usize = 0;
    while (i < remainder.len) : (i += 1) {
        if (remainder[i] == '\\' and i + 1 < remainder.len) {
            i += 1; // skip the escaped char
            continue;
        }
        if (remainder[i] == '"') return remainder[0..i];
    }
    return null;
}

// ---------- renderers ----------

fn renderStackList(
    allocator: std.mem.Allocator,
    body: []const u8,
    stdout: anytype,
    stderr: anytype,
) !void {
    // Body shape: {"stacks":[{"name":"foo"},{"name":"bar"}]}
    var names = std.ArrayList([]const u8){};
    defer names.deinit(allocator);

    var i: usize = 0;
    while (i < body.len) {
        const key = "\"name\":\"";
        const pos = std.mem.indexOfPos(u8, body, i, key) orelse break;
        const start = pos + key.len;
        const end = std.mem.indexOfScalarPos(u8, body, start, '"') orelse break;
        try names.append(allocator, body[start..end]);
        i = end + 1;
    }

    if (names.items.len == 0) {
        try stdout.writeAll("(no stacks)\n");
        return;
    }
    try stdout.print("{s}\n", .{"NAME"});
    for (names.items) |n| try stdout.print("{s}\n", .{n});
    _ = stderr;
}

fn renderStackConfig(
    allocator: std.mem.Allocator,
    name: []const u8,
    body: []const u8,
    stdout: anytype,
    stderr: anytype,
) !void {
    _ = allocator;
    _ = stderr;
    try stdout.print("stack: {s}\n", .{name});
    if (findJsonStringField(body, "\"description\":\"")) |s| try stdout.print("  description:    {s}\n", .{s});
    if (findJsonStringField(body, "\"created_at\":\"")) |s| try stdout.print("  created_at:     {s}\n", .{s});
    if (findJsonStringField(body, "\"continuity\":\"")) |s| try stdout.print("  continuity:     {s}\n", .{s});
    // booleans / numbers: search for the unquoted value.
    if (findJsonRawField(body, "\"paused\":")) |s| try stdout.print("  paused:         {s}\n", .{s});
    if (findJsonRawField(body, "\"max_concurrent_per_stack\":")) |s| try stdout.print("  max_concurrent: {s}\n", .{s});
    if (findJsonStringField(body, "\"default_workdir\":\"")) |s| try stdout.print("  default_workdir:{s}\n", .{s});
    var arr_buf: [16][]const u8 = undefined;
    if (extractJsonStringArray(body, "\"allowed_harnesses\":[", &arr_buf) catch null) |arr| {
        try stdout.writeAll("  allowed_harnesses: ");
        for (arr, 0..) |h, j| {
            if (j != 0) try stdout.writeAll(", ");
            try stdout.writeAll(h);
        }
        try stdout.writeAll("\n");
    }
}

fn renderStackShow(
    allocator: std.mem.Allocator,
    name: []const u8,
    body: []const u8,
    stdout: anytype,
    stderr: anytype,
) !void {
    // Composite payload: {"name":"...","config":{...},"items":[{...},...]}
    // Render the config block, then items in queue order with status badges.
    try renderStackConfig(allocator, name, body, stdout, stderr);
    try stdout.writeAll("\n");

    // Find the items array. It's the last field; scan for `"items":[`.
    const items_marker = "\"items\":[";
    const items_pos = std.mem.indexOf(u8, body, items_marker) orelse {
        try stdout.writeAll("(items array missing in response)\n");
        return;
    };
    const items_payload = body[items_pos + items_marker.len ..];
    // Each item is delimited by braces; scan a flat object at a time. This is
    // a deliberate, narrow JSON walker — the items list is shallow.
    var entries = std.ArrayList(Entry){};
    defer entries.deinit(allocator);

    var i: usize = 0;
    while (i < items_payload.len) {
        // Skip whitespace + commas + the closing ']' that terminates the array.
        while (i < items_payload.len and (items_payload[i] == ' ' or items_payload[i] == ',')) i += 1;
        if (i >= items_payload.len or items_payload[i] == ']') break;
        if (items_payload[i] != '{') break;

        // Find the matching closing brace (flat: no nested objects in this
        // summary view).
        var depth: usize = 0;
        var end: usize = i;
        while (end < items_payload.len) : (end += 1) {
            const c = items_payload[end];
            if (c == '{') depth += 1;
            if (c == '}') {
                depth -= 1;
                if (depth == 0) {
                    end += 1;
                    break;
                }
            }
        }
        const obj = items_payload[i..end];
        const id = findJsonStringField(obj, "\"id\":\"") orelse "?";
        const slug = findJsonStringField(obj, "\"slug\":\"") orelse "";
        const kind = findJsonStringField(obj, "\"kind\":\"") orelse "";
        const status = findJsonStringField(obj, "\"status\":\"") orelse "";
        try entries.append(allocator, .{ .id = id, .slug = slug, .kind = kind, .status = status });
        i = end;
    }

    if (entries.items.len == 0) {
        try stdout.writeAll("(no items)\n");
        return;
    }
    // Header.
    try stdout.print("{s:<6} {s:<10} {s:<10} {s}\n", .{ "ID", "KIND", "STATUS", "SLUG" });
    for (entries.items) |e| {
        try stdout.print("{s:<6} {s:<10} {s:<10} {s}\n", .{ e.id, e.kind, e.status, e.slug });
    }
}

const Entry = struct {
    id: []const u8,
    slug: []const u8,
    kind: []const u8,
    status: []const u8,
};

/// Find a non-string JSON value (boolean, number, null) following `key`.
/// Returns the value text up to the next `,` or `}`.
fn findJsonRawField(body: []const u8, key: []const u8) ?[]const u8 {
    const pos = std.mem.indexOf(u8, body, key) orelse return null;
    var i = pos + key.len;
    // Skip whitespace.
    while (i < body.len and body[i] == ' ') i += 1;
    const start = i;
    while (i < body.len) : (i += 1) {
        const c = body[i];
        if (c == ',' or c == '}') break;
    }
    return std.mem.trim(u8, body[start..i], " \t");
}

/// Extract `["a","b",...]` after `prefix`. Writes element slices (borrowed
/// from `body`) into `out` and returns a sub-slice covering them. The caller
/// owns the storage; element slices remain valid as long as `body` does.
fn extractJsonStringArray(
    body: []const u8,
    prefix: []const u8,
    out: []([]const u8),
) ![]const []const u8 {
    const pos = std.mem.indexOf(u8, body, prefix) orelse return error.NotFound;
    var i = pos + prefix.len;
    var n: usize = 0;
    while (i < body.len) {
        while (i < body.len and (body[i] == ' ' or body[i] == ',')) i += 1;
        if (i >= body.len) break;
        if (body[i] == ']') break;
        if (body[i] != '"') break;
        i += 1;
        const start = i;
        while (i < body.len and body[i] != '"') i += 1;
        if (n >= out.len) break;
        out[n] = body[start..i];
        n += 1;
        if (i < body.len) i += 1; // step past closing quote
    }
    return out[0..n];
}

// ---------- unit tests ----------

test "findJsonStringField: simple" {
    const body = "{\"code\":\"not_found\",\"message\":\"hello\"}";
    try std.testing.expectEqualStrings("not_found", findJsonStringField(body, "\"code\":\"").?);
    try std.testing.expectEqualStrings("hello", findJsonStringField(body, "\"message\":\"").?);
    try std.testing.expect(findJsonStringField(body, "\"missing\":\"") == null);
}

test "findJsonRawField: number/bool" {
    const body = "{\"paused\":false,\"max\":42,\"x\":null}";
    try std.testing.expectEqualStrings("false", findJsonRawField(body, "\"paused\":").?);
    try std.testing.expectEqualStrings("42", findJsonRawField(body, "\"max\":").?);
    try std.testing.expectEqualStrings("null", findJsonRawField(body, "\"x\":").?);
}

test "extractJsonStringArray: parses harness list" {
    const body = "...\"allowed_harnesses\":[\"claude\",\"codex\"],...";
    var buf: [16][]const u8 = undefined;
    const arr = try extractJsonStringArray(body, "\"allowed_harnesses\":[", &buf);
    try std.testing.expectEqual(@as(usize, 2), arr.len);
    try std.testing.expectEqualStrings("claude", arr[0]);
    try std.testing.expectEqualStrings("codex", arr[1]);
}
