//! `stako stack ...` implementation. The CLI is a thin shell over the
//! daemon's HTTP API per `todos/implement_cli_client.md`:
//!
//!   - All rendering data comes from the daemon JSON response. No CLI-local
//!     stack parsing. (Acceptance criterion of milestone 4.)
//!   - `--json/-j` writes the response body verbatim; non-JSON mode renders
//!     a human-friendly table/listing.
//!   - On connection failure we emit the canonical
//!     "daemon not started; try `stako daemon start`" message.

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
        try stderr.print("stako stack: failed to prepare client: {s}\n", .{@errorName(e)});
        return 1;
    };
    defer client.deinit();

    switch (args.action) {
        .list => return try runList(allocator, &client, args.flags, stdout, stderr),
        .show => return try runShow(allocator, &client, args.flags, args.name, stdout, stderr),
        .config => {
            if (args.set_count == 0) {
                return try runConfig(allocator, &client, args.flags, args.name, stdout, stderr);
            }
            return try runConfigSet(allocator, &client, args, stdout, stderr);
        },
        .new => return try runNew(allocator, &client, args, stdout, stderr),
        .add => return try runAdd(allocator, &client, args, stdout, stderr),
        .insert => return try runInsert(allocator, &client, args, stdout, stderr),
        .retry => return try runTransition(allocator, &client, args, "retry", stdout, stderr),
        .cancel => return try runTransition(allocator, &client, args, "cancel", stdout, stderr),
        .supersede => return try runSupersede(allocator, &client, args, stdout, stderr),
        .pause => return try runPauseResume(allocator, &client, args, true, stdout, stderr),
        .@"resume" => return try runPauseResume(allocator, &client, args, false, stdout, stderr),
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
    // The daemon's `/stacks/{name}` returns a composite payload (config +
    // inlined items in queue order), so a single GET suffices.
    const stack_path = try std.fmt.allocPrint(allocator, "/stacks/{s}", .{name});
    defer allocator.free(stack_path);

    var stack_resp = http_client.get(client, stack_path) catch |e| {
        return reportClientError(e, client, stack_path, stderr);
    };
    defer stack_resp.deinit();
    if (stack_resp.status != 200) {
        return reportApiError(stack_resp.status, stack_resp.body, stack_path, flags.verbose, stderr);
    }

    if (flags.json) {
        try stdout.writeAll(stack_resp.body);
        try stdout.writeAll("\n");
        return 0;
    }

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
            try stderr.writeAll("stako: daemon not started; try `stako daemon start`\n");
            if (client.verbose) {
                try stderr.print("  attempted: http://{s}:{d}{s}\n", .{ client.host, client.port, path });
            }
            return 1;
        },
        error.TransportTimeout => {
            try stderr.writeAll("stako: daemon did not respond in time\n");
            if (client.verbose) {
                try stderr.print("  attempted: http://{s}:{d}{s}\n", .{ client.host, client.port, path });
            }
            return 1;
        },
        else => {
            try stderr.print("stako: request failed: {s}\n", .{@errorName(e)});
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
        try stderr.print("stako: HTTP {d} {s}", .{ status, c });
        if (message) |m| try stderr.print(": {s}", .{m});
        try stderr.writeAll("\n");
    } else {
        try stderr.print("stako: HTTP {d}\n", .{status});
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
    // Body shape: {"stacks":[{"name":"foo"},{"name":"bar"}, ...]}.
    // A previous version substring-grepped for `"name":"`, which would match
    // any future sibling object whose key is also `name`. Walk the actual
    // JSON instead.
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch {
        try stderr.writeAll("stako: malformed daemon response\n");
        return;
    };
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) {
        try stderr.writeAll("stako: malformed daemon response\n");
        return;
    }
    const stacks = root.object.get("stacks") orelse {
        try stdout.writeAll("(no stacks)\n");
        return;
    };
    if (stacks != .array or stacks.array.items.len == 0) {
        try stdout.writeAll("(no stacks)\n");
        return;
    }
    try stdout.writeAll("NAME\n");
    for (stacks.array.items) |entry| {
        if (entry != .object) continue;
        const name_v = entry.object.get("name") orelse continue;
        if (name_v != .string) continue;
        try stdout.print("{s}\n", .{name_v.string});
    }
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
    if (findJsonStringField(body, "\"default_workdir\":\"")) |s| try stdout.print("  default_workdir: {s}\n", .{s});
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

// ---------- mutation runners (milestone 5) ----------

fn runNew(
    allocator: std.mem.Allocator,
    client: *http_client.Client,
    args: cli.StackArgs,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    // POST /stacks with body {"name": "<name>"}.
    var body = std.ArrayList(u8){};
    defer body.deinit(allocator);
    const w = body.writer(allocator);
    try w.writeAll("{\"name\":\"");
    try writeJsonStr(w, args.name);
    try w.writeAll("\"}");
    return try postAndReport(client, "/stacks", body.items, args.flags, stdout, stderr);
}

fn runAdd(
    allocator: std.mem.Allocator,
    client: *http_client.Client,
    args: cli.StackArgs,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    // POST /stacks/{name}/items with body {kind, slug, target?, prompt?}.
    const path = try std.fmt.allocPrint(allocator, "/stacks/{s}/items", .{args.name});
    defer allocator.free(path);
    const body = buildItemBody(allocator, args, stderr) catch |e| switch (e) {
        error.PromptFileReadFailed => return 1,
        else => return e,
    };
    defer allocator.free(body);
    return try postAndReport(client, path, body, args.flags, stdout, stderr);
}

fn runInsert(
    allocator: std.mem.Allocator,
    client: *http_client.Client,
    args: cli.StackArgs,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    const path = try std.fmt.allocPrint(allocator, "/stacks/{s}/items/{s}/insert", .{ args.name, args.ref });
    defer allocator.free(path);
    const body = buildItemBody(allocator, args, stderr) catch |e| switch (e) {
        error.PromptFileReadFailed => return 1,
        else => return e,
    };
    defer allocator.free(body);
    return try postAndReport(client, path, body, args.flags, stdout, stderr);
}

const BuildItemBodyError = error{PromptFileReadFailed} || anyerror;

fn buildItemBody(allocator: std.mem.Allocator, args: cli.StackArgs, stderr: anytype) BuildItemBodyError![]u8 {
    var prompt_buf: ?[]u8 = null;
    defer if (prompt_buf) |p| allocator.free(p);
    if (args.prompt_file.len > 0) {
        prompt_buf = readPromptFile(allocator, args.prompt_file) catch |e| {
            try stderr.print("stako: failed to read --prompt-file: {s}\n", .{@errorName(e)});
            return error.PromptFileReadFailed;
        };
    }

    var body = std.ArrayList(u8){};
    errdefer body.deinit(allocator);
    const w = body.writer(allocator);
    try w.writeAll("{");
    try w.writeAll("\"kind\":\"");
    try writeJsonStr(w, args.kind);
    try w.writeAll("\"");
    const slug = if (args.slug.len > 0) args.slug else deriveDefaultSlug(args.kind, args.prompt_file);
    try w.writeAll(",\"slug\":\"");
    try writeJsonStr(w, slug);
    try w.writeAll("\"");
    try writeTargetFieldFromShorthand(w, args.target);
    if (prompt_buf) |p| {
        try w.writeAll(",\"prompt\":\"");
        try writeJsonStr(w, p);
        try w.writeAll("\"");
    }
    try w.writeAll("}");
    return try body.toOwnedSlice(allocator);
}

fn runTransition(
    allocator: std.mem.Allocator,
    client: *http_client.Client,
    args: cli.StackArgs,
    verb: []const u8,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    const path = try std.fmt.allocPrint(allocator, "/stacks/{s}/items/{s}/{s}", .{ args.name, args.item_id, verb });
    defer allocator.free(path);
    return try postAndReport(client, path, "{}", args.flags, stdout, stderr);
}

fn runSupersede(
    allocator: std.mem.Allocator,
    client: *http_client.Client,
    args: cli.StackArgs,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    const path = try std.fmt.allocPrint(allocator, "/stacks/{s}/items/{s}/supersede", .{ args.name, args.item_id });
    defer allocator.free(path);
    const body = try buildSupersedeBody(allocator, args.replacement);
    defer allocator.free(body);
    return try postAndReport(client, path, body, args.flags, stdout, stderr);
}

fn buildSupersedeBody(allocator: std.mem.Allocator, replacement: []const u8) ![]u8 {
    var body = std.ArrayList(u8){};
    errdefer body.deinit(allocator);
    const w = body.writer(allocator);
    try w.writeAll("{\"replacement\":\"");
    try writeJsonStr(w, replacement);
    try w.writeAll("\"}");
    return try body.toOwnedSlice(allocator);
}

fn runPauseResume(
    allocator: std.mem.Allocator,
    client: *http_client.Client,
    args: cli.StackArgs,
    paused: bool,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    const verb: []const u8 = if (paused) "pause" else "resume";
    const path = try std.fmt.allocPrint(allocator, "/stacks/{s}/{s}", .{ args.name, verb });
    defer allocator.free(path);
    return try postAndReport(client, path, "{}", args.flags, stdout, stderr);
}

fn runConfigSet(
    allocator: std.mem.Allocator,
    client: *http_client.Client,
    args: cli.StackArgs,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    const path = try std.fmt.allocPrint(allocator, "/stacks/{s}/config", .{args.name});
    defer allocator.free(path);
    var body = std.ArrayList(u8){};
    defer body.deinit(allocator);
    const w = body.writer(allocator);
    try w.writeAll("{");
    var first = true;
    var i: usize = 0;
    while (i < args.set_count) : (i += 1) {
        const pair = args.set_pairs[i];
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse {
            try stderr.writeAll("stako: --set must be key=value\n");
            return 2;
        };
        if (!first) try w.writeAll(",");
        first = false;
        try w.writeAll("\"");
        try writeJsonStr(w, pair[0..eq]);
        try w.writeAll("\":\"");
        try writeJsonStr(w, pair[eq + 1 ..]);
        try w.writeAll("\"");
    }
    try w.writeAll("}");
    return try postAndReport(client, path, body.items, args.flags, stdout, stderr);
}

fn postAndReport(
    client: *http_client.Client,
    path: []const u8,
    body: []const u8,
    flags: cli.ApiFlags,
    stdout: anytype,
    stderr: anytype,
) !u8 {
    var resp = http_client.request(client, "POST", path, body) catch |e| {
        return reportClientError(e, client, path, stderr);
    };
    defer resp.deinit();
    if (resp.status < 200 or resp.status >= 300) {
        return reportApiError(resp.status, resp.body, path, flags.verbose, stderr);
    }
    if (flags.json) {
        try stdout.writeAll(resp.body);
        try stdout.writeAll("\n");
        return 0;
    }
    // Human view: print "ok" plus the commit SHA if present.
    if (findJsonStringField(resp.body, "\"commit\":\"")) |sha| {
        try stdout.print("stako: ok (commit {s})\n", .{sha});
    } else {
        try stdout.writeAll("stako: ok\n");
    }
    return 0;
}

fn writeJsonStr(w: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            else => try w.writeByte(c),
        }
    }
}

/// `target` shorthand: `provider[/model]` or "any"/"compatible"/"exact"
/// (the latter sets `match` only). Empty target string emits nothing.
fn writeTargetFieldFromShorthand(w: anytype, target: []const u8) !void {
    if (target.len == 0) return;
    try w.writeAll(",\"target\":{");
    if (std.mem.eql(u8, target, "any") or std.mem.eql(u8, target, "compatible") or std.mem.eql(u8, target, "exact")) {
        try w.print("\"match\":\"{s}\"", .{target});
        try w.writeAll("}");
        return;
    }
    const slash = std.mem.indexOfScalar(u8, target, '/');
    const provider = if (slash) |i| target[0..i] else target;
    try w.writeAll("\"provider\":\"");
    try writeJsonStr(w, provider);
    try w.writeAll("\"");
    if (slash) |i| {
        const model = target[i + 1 ..];
        try w.writeAll(",\"model\":\"");
        try writeJsonStr(w, model);
        try w.writeAll("\"");
    }
    try w.writeAll(",\"match\":\"compatible\"}");
}

fn deriveDefaultSlug(kind: []const u8, prompt_file: []const u8) []const u8 {
    if (prompt_file.len > 0) {
        const base = std.fs.path.basename(prompt_file);
        const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse base.len;
        if (dot > 0 and dot <= 30 and isAllKebabCase(base[0..dot])) return base[0..dot];
    }
    return kind;
}

fn isAllKebabCase(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '-';
        if (!ok) return false;
    }
    return true;
}

fn readPromptFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var f = try std.fs.cwd().openFile(path, .{});
    defer f.close();
    const stat = try f.stat();
    if (stat.size > 1024 * 1024) return error.PromptFileTooLarge;
    const buf = try allocator.alloc(u8, stat.size);
    errdefer allocator.free(buf);
    const n = try f.readAll(buf);
    // The file may have shrunk between stat and read (concurrent editor save).
    // Without truncating to `n` the tail is uninitialized memory.
    if (n < buf.len) return try allocator.realloc(buf, n);
    return buf;
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

test "buildItemBody: insert/add payload includes prompt and escapes strings" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var f = try tmp.dir.createFile("prompt-body.md", .{ .truncate = true });
    try f.writeAll("hello \"quoted\"\\path\n");
    f.close();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try tmp.dir.realpath(".", &dir_buf);
    const prompt_path = try std.fs.path.join(a, &.{ dir, "prompt-body.md" });
    defer a.free(prompt_path);

    var stderr_buf: std.Io.Writer.Allocating = .init(a);
    defer stderr_buf.deinit();
    const body = try buildItemBody(a, .{
        .action = .insert,
        .name = "demo",
        .ref = "0001",
        .kind = "prompt",
        .target = "anthropic/claude",
        .prompt_file = prompt_path,
    }, &stderr_buf.writer);
    defer a.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"kind\":\"prompt\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"slug\":\"prompt-body\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"provider\":\"anthropic\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"model\":\"claude\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"prompt\":\"hello \\\"quoted\\\"\\\\path\\n\"") != null);
}

test "buildItemBody: kind is JSON escaped" {
    const a = std.testing.allocator;
    var stderr_buf: std.Io.Writer.Allocating = .init(a);
    defer stderr_buf.deinit();
    const body = try buildItemBody(a, .{
        .action = .add,
        .name = "demo",
        .kind = "bad\"kind",
        .slug = "explicit",
    }, &stderr_buf.writer);
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"kind\":\"bad\\\"kind\"") != null);
}

test "buildSupersedeBody: replacement is JSON escaped" {
    const a = std.testing.allocator;
    const body = try buildSupersedeBody(a, "00\"\\\\01");
    defer a.free(body);
    try std.testing.expectEqualStrings("{\"replacement\":\"00\\\"\\\\\\\\01\"}", body);
}
