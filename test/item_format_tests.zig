//! Round-trip and negative tests against fixtures in test/fixtures/items{,_invalid}/.
//!
//! Wired into `zig build test` via build.zig. Tests run from the build root,
//! so all fixture paths are relative to it.

const std = @import("std");
const organo = @import("organo");
const item = organo.item;
const state = organo.state;

const FIXTURES = "test/fixtures/items";
const INVALID = "test/fixtures/items_invalid";

const FIXTURE_NAMES = [_][]const u8{
    "prompt_basic",
    "compact_chained",
    "clear",
    "sleep_future",
    "sleep_elapsed",
    "review_with_parent",
    "terminal_completed",
    "terminal_failed",
    "terminal_canceled",
    "terminal_superseded",
    "prompt_with_workdir",
};

fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var f = try std.fs.cwd().openFile(path, .{});
    defer f.close();
    const stat = try f.stat();
    const buf = try allocator.alloc(u8, stat.size);
    const n = try f.readAll(buf);
    return buf[0..n];
}

test "fixtures: parse and validate succeed" {
    const allocator = std.testing.allocator;
    for (FIXTURE_NAMES) |name| {
        var path_buf: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}/meta.toml", .{ FIXTURES, name });
        const src = try readFile(allocator, path);
        defer allocator.free(src);

        var diag: item.ParseDiagnostic = .{};
        var parsed = item.parseSlice(allocator, src, &diag) catch |e| {
            std.debug.print("parse failed for {s}: {s} ({s}) field={s}\n", .{ name, @errorName(e), diag.message, diag.field });
            return e;
        };
        defer parsed.deinit();

        var vd: item.ValidationDiagnostic = .{};
        item.validate(&parsed, &vd) catch |e| {
            std.debug.print("validate failed for {s}: {s} ({s}) field={s}\n", .{ name, @errorName(e), vd.message, vd.field });
            return e;
        };
    }
}

test "fixtures: round-trip byte-stable" {
    const allocator = std.testing.allocator;
    for (FIXTURE_NAMES) |name| {
        var path_buf: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}/meta.toml", .{ FIXTURES, name });
        const src = try readFile(allocator, path);
        defer allocator.free(src);

        var diag: item.ParseDiagnostic = .{};
        var parsed = try item.parseSlice(allocator, src, &diag);
        defer parsed.deinit();

        var out = std.ArrayList(u8){};
        defer out.deinit(allocator);
        try item.write(&parsed, out.writer(allocator));

        if (!std.mem.eql(u8, src, out.items)) {
            std.debug.print(
                "round-trip mismatch for {s}\n--- input ---\n{s}\n--- output ---\n{s}\n",
                .{ name, src, out.items },
            );
            return error.RoundTripMismatch;
        }
    }
}

test "fixtures: second-pass round-trip is stable (read→write→read→write)" {
    // Even if the source were not in canonical form, the writer output must
    // be a fixed point: writing the parsed output again must equal it.
    const allocator = std.testing.allocator;
    for (FIXTURE_NAMES) |name| {
        var path_buf: [256]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}/meta.toml", .{ FIXTURES, name });
        const src = try readFile(allocator, path);
        defer allocator.free(src);

        var diag: item.ParseDiagnostic = .{};
        var parsed1 = try item.parseSlice(allocator, src, &diag);
        defer parsed1.deinit();
        var out1 = std.ArrayList(u8){};
        defer out1.deinit(allocator);
        try item.write(&parsed1, out1.writer(allocator));

        var parsed2 = try item.parseSlice(allocator, out1.items, &diag);
        defer parsed2.deinit();
        var out2 = std.ArrayList(u8){};
        defer out2.deinit(allocator);
        try item.write(&parsed2, out2.writer(allocator));

        try std.testing.expectEqualStrings(out1.items, out2.items);
    }
}

test "fixture prompt_basic: field values" {
    const allocator = std.testing.allocator;
    const src = try readFile(allocator, FIXTURES ++ "/prompt_basic/meta.toml");
    defer allocator.free(src);
    var diag: item.ParseDiagnostic = .{};
    var p = try item.parseSlice(allocator, src, &diag);
    defer p.deinit();

    try std.testing.expectEqualStrings("0001", p.id);
    try std.testing.expectEqualStrings("prompt-basic", p.slug);
    try std.testing.expectEqual(item.Kind.prompt, p.kind);
    try std.testing.expectEqual(state.Status.queued, p.status);
    try std.testing.expect(p.target != null);
    try std.testing.expectEqualStrings("anthropic", p.target.?.provider.?);
    try std.testing.expectEqual(item.Match.exact, p.target.?.match.?);
    try std.testing.expect(p.requires != null);
    try std.testing.expectEqual(@as(i64, 200000), p.requires.?.max_context_tokens.?);
    try std.testing.expectEqual(@as(usize, 2), p.requires.?.tools.?.len);
    try std.testing.expectEqualStrings("shell", p.requires.?.tools.?[0]);
}

test "fixture review_with_parent: parent id parsed" {
    const allocator = std.testing.allocator;
    const src = try readFile(allocator, FIXTURES ++ "/review_with_parent/meta.toml");
    defer allocator.free(src);
    var diag: item.ParseDiagnostic = .{};
    var p = try item.parseSlice(allocator, src, &diag);
    defer p.deinit();
    try std.testing.expect(p.parents != null);
    try std.testing.expectEqual(@as(usize, 1), p.parents.?.len);
    try std.testing.expectEqualStrings("0005", p.parents.?[0]);
}

test "fixture clear: clear table is recorded" {
    const allocator = std.testing.allocator;
    const src = try readFile(allocator, FIXTURES ++ "/clear/meta.toml");
    defer allocator.free(src);
    var diag: item.ParseDiagnostic = .{};
    var p = try item.parseSlice(allocator, src, &diag);
    defer p.deinit();
    try std.testing.expect(p.clear_present);
    try std.testing.expectEqual(item.Kind.clear, p.kind);
}

test "fixture terminal_completed: result block populated" {
    const allocator = std.testing.allocator;
    const src = try readFile(allocator, FIXTURES ++ "/terminal_completed/meta.toml");
    defer allocator.free(src);
    var diag: item.ParseDiagnostic = .{};
    var p = try item.parseSlice(allocator, src, &diag);
    defer p.deinit();
    try std.testing.expectEqual(state.Status.completed, p.status);
    try std.testing.expect(p.result != null);
    try std.testing.expectEqual(@as(i64, 0), p.result.?.exit_code.?);
    try std.testing.expectEqualStrings("claude", p.result.?.harness.?);
}

test "fixture prompt_with_workdir: workdir is parsed (allowlist not checked in this milestone)" {
    const allocator = std.testing.allocator;
    const src = try readFile(allocator, FIXTURES ++ "/prompt_with_workdir/meta.toml");
    defer allocator.free(src);
    var diag: item.ParseDiagnostic = .{};
    var p = try item.parseSlice(allocator, src, &diag);
    defer p.deinit();
    try std.testing.expect(p.target != null);
    try std.testing.expect(p.target.?.workdir != null);
    try std.testing.expectEqualStrings("/some/not-allowlisted/path", p.target.?.workdir.?);
    // Validator should also accept it; allowlist check is milestone 6.
    var vd: item.ValidationDiagnostic = .{};
    try item.validate(&p, &vd);
}

// ---------- negative tests ----------

test "negative: missing required field id" {
    const allocator = std.testing.allocator;
    const src = try readFile(allocator, INVALID ++ "/missing_id.toml");
    defer allocator.free(src);
    var diag: item.ParseDiagnostic = .{};
    const r = item.parseSlice(allocator, src, &diag);
    try std.testing.expectError(error.MissingField, r);
    try std.testing.expectEqualStrings("id", diag.field);
}

test "negative: unknown kind" {
    const allocator = std.testing.allocator;
    const src = try readFile(allocator, INVALID ++ "/unknown_kind.toml");
    defer allocator.free(src);
    var diag: item.ParseDiagnostic = .{};
    const r = item.parseSlice(allocator, src, &diag);
    try std.testing.expectError(error.UnknownKind, r);
}

test "negative: malformed status" {
    const allocator = std.testing.allocator;
    const src = try readFile(allocator, INVALID ++ "/bad_status.toml");
    defer allocator.free(src);
    var diag: item.ParseDiagnostic = .{};
    const r = item.parseSlice(allocator, src, &diag);
    try std.testing.expectError(error.UnknownStatus, r);
}

test "negative: invalid datetime" {
    // created_at = "yesterday" is a string, not a datetime literal. The
    // parser rejects this at the type-check layer with BadType.
    const allocator = std.testing.allocator;
    const src = try readFile(allocator, INVALID ++ "/bad_datetime.toml");
    defer allocator.free(src);
    var diag: item.ParseDiagnostic = .{};
    const r = item.parseSlice(allocator, src, &diag);
    try std.testing.expectError(error.BadType, r);
    try std.testing.expectEqualStrings("created_at", diag.field);
}

test "negative: invalid datetime shape (validator)" {
    // A datetime that parses as TOML datetime by lookalike-prefix but fails
    // the stricter RFC3339 check at validation time.
    const allocator = std.testing.allocator;
    const src =
        \\id = "0001"
        \\slug = "bad-datetime-shape"
        \\kind = "prompt"
        \\status = "queued"
        \\created_at = 2026-05-10T14:32
        \\updated_at = 2026-05-10T14:32:00Z
        \\
        \\[target]
        \\provider = "anthropic"
        \\
    ;
    var diag: item.ParseDiagnostic = .{};
    var p = try item.parseSlice(allocator, src, &diag);
    defer p.deinit();
    var vd: item.ValidationDiagnostic = .{};
    const r = item.validate(&p, &vd);
    try std.testing.expectError(error.InvalidDatetime, r);
    try std.testing.expectEqualStrings("created_at", vd.field);
}

test "negative: invalid id format (validator)" {
    const allocator = std.testing.allocator;
    const src = try readFile(allocator, INVALID ++ "/bad_id.toml");
    defer allocator.free(src);
    var diag: item.ParseDiagnostic = .{};
    var p = try item.parseSlice(allocator, src, &diag);
    defer p.deinit();
    var vd: item.ValidationDiagnostic = .{};
    const r = item.validate(&p, &vd);
    try std.testing.expectError(error.InvalidIdFormat, r);
}

test "negative: invalid slug format (validator)" {
    const allocator = std.testing.allocator;
    const src = try readFile(allocator, INVALID ++ "/bad_slug.toml");
    defer allocator.free(src);
    var diag: item.ParseDiagnostic = .{};
    var p = try item.parseSlice(allocator, src, &diag);
    defer p.deinit();
    var vd: item.ValidationDiagnostic = .{};
    const r = item.validate(&p, &vd);
    try std.testing.expectError(error.InvalidSlugFormat, r);
}

test "negative: invalid parent id (validator)" {
    const allocator = std.testing.allocator;
    const src = try readFile(allocator, INVALID ++ "/bad_parent.toml");
    defer allocator.free(src);
    var diag: item.ParseDiagnostic = .{};
    var p = try item.parseSlice(allocator, src, &diag);
    defer p.deinit();
    var vd: item.ValidationDiagnostic = .{};
    const r = item.validate(&p, &vd);
    try std.testing.expectError(error.InvalidParentId, r);
}

test "negative: sleep table missing until" {
    const allocator = std.testing.allocator;
    const src = try readFile(allocator, INVALID ++ "/sleep_missing_until.toml");
    defer allocator.free(src);
    var diag: item.ParseDiagnostic = .{};
    const r = item.parseSlice(allocator, src, &diag);
    try std.testing.expectError(error.InvalidSleep, r);
}

test "negative: prompt without target table (validator)" {
    const allocator = std.testing.allocator;
    const src = try readFile(allocator, INVALID ++ "/prompt_no_target.toml");
    defer allocator.free(src);
    var diag: item.ParseDiagnostic = .{};
    var p = try item.parseSlice(allocator, src, &diag);
    defer p.deinit();
    var vd: item.ValidationDiagnostic = .{};
    const r = item.validate(&p, &vd);
    try std.testing.expectError(error.MissingTargetTable, r);
}

// ---------- state transition table (separately covered in src/state.zig
// but we re-anchor the canonical-transitions invariant here too) ----------

test "state machine: full transition matrix matches design" {
    const Status = state.Status;
    // Every (from -> to) listed as valid in design_state_machine.md
    const valid_pairs = [_]struct { from: Status, to: Status }{
        .{ .from = .queued, .to = .running },
        .{ .from = .queued, .to = .blocked },
        .{ .from = .queued, .to = .canceled },
        .{ .from = .queued, .to = .superseded },
        .{ .from = .queued, .to = .paused },
        .{ .from = .running, .to = .completed },
        .{ .from = .running, .to = .failed },
        .{ .from = .running, .to = .canceled },
        .{ .from = .paused, .to = .queued },
        .{ .from = .paused, .to = .canceled },
        .{ .from = .blocked, .to = .queued },
        .{ .from = .blocked, .to = .canceled },
    };
    for (valid_pairs) |p| try std.testing.expect(state.isValidTransition(p.from, p.to));

    // A sample of explicitly-invalid transitions.
    try std.testing.expect(!state.isValidTransition(.completed, .running));
    try std.testing.expect(!state.isValidTransition(.failed, .running));
    try std.testing.expect(!state.isValidTransition(.canceled, .queued));
    try std.testing.expect(!state.isValidTransition(.superseded, .completed));
    try std.testing.expect(!state.isValidTransition(.queued, .completed));
    try std.testing.expect(!state.isValidTransition(.queued, .failed));
    try std.testing.expect(!state.isValidTransition(.running, .queued));
    try std.testing.expect(!state.isValidTransition(.running, .paused));
    try std.testing.expect(!state.isValidTransition(.running, .blocked));
    try std.testing.expect(!state.isValidTransition(.paused, .running));
    try std.testing.expect(!state.isValidTransition(.paused, .blocked));
    try std.testing.expect(!state.isValidTransition(.blocked, .running));
}
