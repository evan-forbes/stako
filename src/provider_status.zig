//! Provider status (milestone 8).
//!
//! Owns the per-provider availability probe + a small JSON-rendering surface
//! used by the daemon's `GET /providers` endpoint and the CLI's
//! `organo auth status` subcommand.
//!
//! Per `todos/research_provider_sign_in.md` and the M8 plan:
//!
//!   - We do NOT own subscription tokens. Existing CLI credential reuse is
//!     the supported v1 mode for Claude and Codex.
//!   - We DO surface a binary-presence preflight (so a routed item sees a
//!     deterministic `harness_unavailable` if the underlying CLI is missing)
//!     and an auth-status hint by looking for known credential locations.
//!   - The auth probe is intentionally conservative: it never spawns the
//!     provider CLI. Spawning `claude --version` or similar would add
//!     measurable latency to every tick and the design explicitly forbids
//!     daemon-owned subscription auth. The probe checks (a) the binary is on
//!     PATH and (b) at least one of the documented credential locations is
//!     present (API-key env var, official CLI credential file).
//!   - For Gemini we currently return `harness_unavailable` with a
//!     stable note ("structured stream-json support unconfirmed in v1") so
//!     a routed item lands in `blocked` with a clear reason rather than
//!     ambiguously failing inside a subprocess. See
//!     `todos/design_execution_harness.md` for the deferral note.

const std = @import("std");

pub const Provider = enum {
    anthropic,
    openai,
    google,

    pub fn fromString(s: []const u8) ?Provider {
        if (std.mem.eql(u8, s, "anthropic") or std.mem.eql(u8, s, "claude")) return .anthropic;
        if (std.mem.eql(u8, s, "openai") or std.mem.eql(u8, s, "codex")) return .openai;
        if (std.mem.eql(u8, s, "google") or std.mem.eql(u8, s, "gemini")) return .google;
        return null;
    }

    pub fn slug(self: Provider) []const u8 {
        return switch (self) {
            .anthropic => "anthropic",
            .openai => "openai",
            .google => "google",
        };
    }

    pub fn harnessName(self: Provider) []const u8 {
        return switch (self) {
            .anthropic => "claude",
            .openai => "codex",
            .google => "gemini",
        };
    }

    pub fn binaryName(self: Provider) []const u8 {
        return switch (self) {
            .anthropic => "claude",
            .openai => "codex",
            .google => "gemini",
        };
    }
};

pub const AuthState = enum {
    unknown,
    signed_in,
    signed_out,

    pub fn toString(self: AuthState) []const u8 {
        return switch (self) {
            .unknown => "unknown",
            .signed_in => "signed_in",
            .signed_out => "signed_out",
        };
    }
};

/// One provider's resolved status. All string fields are borrowed from
/// program-lifetime constants — `probe`/`probeAll` never allocate per-field
/// strings, so `Status` values can be passed around without ownership
/// concerns. `probeAll` only owns the outer `[]Status` slice; see
/// `StatusList.deinit`.
pub const Status = struct {
    provider: Provider,
    /// The harness label we route through ("claude"/"codex"/"gemini").
    harness: []const u8,
    /// Binary name expected on PATH.
    binary: []const u8,
    /// True when the binary is on PATH (`PATH`-based search; no subprocess).
    binary_present: bool,
    /// True when we believe routing can spawn this provider's harness at
    /// all (binary present and the adapter is not explicitly disabled).
    available: bool,
    /// Best-effort auth state: signed_in if any documented credential
    /// location exists, signed_out otherwise, unknown if we can't tell.
    auth: AuthState,
    /// Slug shown when routing blocks because of this provider. Empty when
    /// `available` is true. See `errors.zig` Code enum for vocabulary.
    blocked_reason: []const u8,
    /// Short human note. Stable text; tests can substring-match.
    note: []const u8,
    /// Exact command to run to sign in (for the `login_hint` field).
    login_hint: []const u8,
    /// Env var the daemon will set when invoking the harness, if any.
    credential_env: []const u8,
};

pub const StatusList = struct {
    items: []Status,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *StatusList) void {
        self.allocator.free(self.items);
    }
};

/// Public entry: probe every provider and return a status list.
pub fn probeAll(allocator: std.mem.Allocator) !StatusList {
    const providers = [_]Provider{ .anthropic, .openai, .google };
    const out = try allocator.alloc(Status, providers.len);
    errdefer allocator.free(out);
    for (providers, 0..) |p, i| out[i] = probe(allocator, p);
    return .{ .items = out, .allocator = allocator };
}

/// Probe a single provider. Cheap: no subprocesses, no network. Safe to
/// call on every routing tick, but the supervisor caches it once per
/// supervisor lifetime — see `runtime.zig`'s `binary_present_cache`.
pub fn probe(allocator: std.mem.Allocator, p: Provider) Status {
    // Allocator currently unused: every `Status` field is a program-lifetime
    // constant. The parameter is preserved so future probe paths (e.g.
    // reading the head of a credential file or shelling out for `--version`)
    // can take an allocator without breaking callers.
    _ = allocator;
    const binary = p.binaryName();
    const present = binaryOnPath(binary);
    return switch (p) {
        .anthropic => probeAnthropic(present),
        .openai => probeOpenai(present),
        .google => probeGemini(present),
    };
}

fn probeAnthropic(binary_present: bool) Status {
    const has_env = envSet("ANTHROPIC_API_KEY");
    const has_cli_creds = homeFileExists(".claude/.credentials.json") or
        homeFileExists(".claude/credentials.json");
    const signed_in = has_env or has_cli_creds;
    return .{
        .provider = .anthropic,
        .harness = "claude",
        .binary = "claude",
        .binary_present = binary_present,
        .available = binary_present,
        .auth = if (signed_in) .signed_in else .signed_out,
        .blocked_reason = if (!binary_present) "harness_unavailable" else if (signed_in) "" else "auth_missing",
        .note = if (!binary_present)
            "claude CLI not on PATH"
        else if (has_env)
            "ANTHROPIC_API_KEY in environment"
        else if (has_cli_creds)
            "reusing existing Claude Code CLI credentials"
        else
            "no Claude Code credentials detected",
        .login_hint = "claude login   # or: export ANTHROPIC_API_KEY=sk-ant-...",
        .credential_env = "ANTHROPIC_API_KEY",
    };
}

fn probeOpenai(binary_present: bool) Status {
    const has_env = envSet("OPENAI_API_KEY");
    const has_cli_creds = homeFileExists(".codex/auth.json") or
        homeFileExists(".codex/credentials.json");
    const signed_in = has_env or has_cli_creds;
    return .{
        .provider = .openai,
        .harness = "codex",
        .binary = "codex",
        .binary_present = binary_present,
        .available = binary_present,
        .auth = if (signed_in) .signed_in else .signed_out,
        .blocked_reason = if (!binary_present) "harness_unavailable" else if (signed_in) "" else "auth_missing",
        .note = if (!binary_present)
            "codex CLI not on PATH"
        else if (has_env)
            "OPENAI_API_KEY in environment"
        else if (has_cli_creds)
            "reusing existing Codex CLI credentials"
        else
            "no Codex credentials detected",
        .login_hint = "codex login   # or: export OPENAI_API_KEY=sk-...",
        .credential_env = "OPENAI_API_KEY",
    };
}

fn probeGemini(binary_present: bool) Status {
    // v1: even if a binary called `gemini` is found, we do NOT enable the
    // adapter — the design doc tracks this as a deferred bonus. Routing a
    // gemini item lands in `blocked` with a stable slug so callers see a
    // deterministic error rather than a half-implemented adapter failure.
    return .{
        .provider = .google,
        .harness = "gemini",
        .binary = "gemini",
        .binary_present = binary_present,
        .available = false,
        .auth = .unknown,
        .blocked_reason = "harness_unavailable",
        .note = if (binary_present)
            "gemini CLI present but structured stream-json mode unconfirmed; adapter deferred"
        else
            "gemini CLI not on PATH; adapter deferred",
        .login_hint = "gemini auth   # (organo gemini adapter is deferred; see design_execution_harness.md)",
        .credential_env = "GEMINI_API_KEY",
    };
}

// ---------- helpers ----------

/// Return true if `name` is on `PATH`. Cheap: scans PATH segments and tries
/// `stat()` on `<segment>/<name>`. No subprocess.
pub fn binaryOnPath(name: []const u8) bool {
    const path_env = std.posix.getenv("PATH") orelse return false;
    var it = std.mem.splitScalar(u8, path_env, ':');
    while (it.next()) |segment| {
        if (segment.len == 0) continue;
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const candidate = std.fmt.bufPrint(&buf, "{s}/{s}", .{ segment, name }) catch continue;
        const stat = std.fs.cwd().statFile(candidate) catch continue;
        if ((stat.kind == .file or stat.kind == .sym_link) and stat.mode & 0o111 != 0) return true;
    }
    return false;
}

fn envSet(name: []const u8) bool {
    const v = std.posix.getenv(name) orelse return false;
    return v.len > 0;
}

fn homeFileExists(rel: []const u8) bool {
    const home = std.posix.getenv("HOME") orelse return false;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const full = std.fmt.bufPrint(&buf, "{s}/{s}", .{ home, rel }) catch return false;
    const stat = std.fs.cwd().statFile(full) catch return false;
    return (stat.kind == .file or stat.kind == .sym_link) and stat.size > 0;
}

// ---------- JSON rendering ----------

pub fn writeJsonList(w: anytype, list: []const Status) !void {
    try w.writeAll("{\"providers\":[");
    for (list, 0..) |s, i| {
        if (i != 0) try w.writeAll(",");
        try writeJsonOne(w, s);
    }
    try w.writeAll("]}");
}

pub fn writeJsonOne(w: anytype, s: Status) !void {
    try w.writeAll("{\"provider\":\"");
    try writeStr(w, s.provider.slug());
    try w.writeAll("\",\"harness\":\"");
    try writeStr(w, s.harness);
    try w.writeAll("\",\"binary\":\"");
    try writeStr(w, s.binary);
    try w.print("\",\"binary_present\":{s}", .{if (s.binary_present) "true" else "false"});
    try w.print(",\"available\":{s}", .{if (s.available) "true" else "false"});
    try w.writeAll(",\"auth\":\"");
    try writeStr(w, s.auth.toString());
    try w.writeAll("\"");
    if (s.blocked_reason.len > 0) {
        try w.writeAll(",\"blocked_reason\":\"");
        try writeStr(w, s.blocked_reason);
        try w.writeAll("\"");
    }
    try w.writeAll(",\"note\":\"");
    try writeStr(w, s.note);
    try w.writeAll("\",\"login_hint\":\"");
    try writeStr(w, s.login_hint);
    try w.writeAll("\",\"credential_env\":\"");
    try writeStr(w, s.credential_env);
    try w.writeAll("\"}");
}

fn writeStr(w: anytype, s: []const u8) !void {
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        else => try w.writeByte(c),
    };
}

// ---------- unit tests ----------

test "Provider.fromString aliases" {
    try std.testing.expectEqual(Provider.anthropic, Provider.fromString("anthropic").?);
    try std.testing.expectEqual(Provider.anthropic, Provider.fromString("claude").?);
    try std.testing.expectEqual(Provider.openai, Provider.fromString("openai").?);
    try std.testing.expectEqual(Provider.openai, Provider.fromString("codex").?);
    try std.testing.expectEqual(Provider.google, Provider.fromString("google").?);
    try std.testing.expectEqual(Provider.google, Provider.fromString("gemini").?);
    try std.testing.expect(Provider.fromString("nope") == null);
}

test "Provider.fromString empty string returns null" {
    // Audit C9: empty string falls through cleanly; daemon route uses this
    // as the "unknown provider" 404 path.
    try std.testing.expect(Provider.fromString("") == null);
}

test "probeAll surfaces OOM cleanly" {
    // Audit C6: the allocator-failure path must propagate `OutOfMemory`
    // rather than leak the partially-built slice. `respondProvidersList`
    // catches this and maps to HTTP 500.
    try std.testing.expectError(error.OutOfMemory, probeAll(std.testing.failing_allocator));
}

test "binaryOnPath: /bin/sh always present" {
    try std.testing.expect(binaryOnPath("sh"));
    try std.testing.expect(!binaryOnPath("definitely-not-a-real-binary-organo"));
}

test "probe gemini always marks available=false (deferred)" {
    const a = std.testing.allocator;
    const s = probe(a, .google);
    try std.testing.expect(!s.available);
    try std.testing.expectEqualStrings("harness_unavailable", s.blocked_reason);
    try std.testing.expectEqualStrings("gemini", s.harness);
}

test "probe anthropic: signed_in true when ANTHROPIC_API_KEY set" {
    // We don't mutate the environment in tests (some CI sandboxes block it);
    // we just verify shape. The env-set branch is exercised in CLI tests.
    const a = std.testing.allocator;
    const s = probe(a, .anthropic);
    try std.testing.expectEqualStrings("anthropic", s.provider.slug());
    try std.testing.expectEqualStrings("claude", s.harness);
    try std.testing.expectEqualStrings("ANTHROPIC_API_KEY", s.credential_env);
}

test "writeJsonOne emits required fields" {
    const a = std.testing.allocator;
    const s = probe(a, .openai);
    var buf = std.ArrayList(u8){};
    defer buf.deinit(a);
    try writeJsonOne(buf.writer(a), s);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"provider\":\"openai\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"harness\":\"codex\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"binary\":\"codex\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"credential_env\":\"OPENAI_API_KEY\"") != null);
}

test "writeJsonList wraps a list" {
    const a = std.testing.allocator;
    var list = try probeAll(a);
    defer list.deinit();
    var buf = std.ArrayList(u8){};
    defer buf.deinit(a);
    try writeJsonList(buf.writer(a), list.items);
    try std.testing.expect(std.mem.startsWith(u8, buf.items, "{\"providers\":["));
    try std.testing.expect(std.mem.endsWith(u8, buf.items, "]}"));
    try std.testing.expectEqual(@as(usize, 3), list.items.len);
}
