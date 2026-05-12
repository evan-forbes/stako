//! Production harness dispatch (milestone 7).
//!
//! Wires `runtime.Dispatch` to the real Claude and Codex adapters. The
//! factory returns the adapter that matches the harness name passed by the
//! routing preflight; `build_argv` builds the provider's structured-output
//! invocation; routing decisions are made by the supervisor's existing
//! preflight using `allowed_harnesses` + (per item) `target.provider`.
//!
//! Mapping of organo provider/harness names to CLI binaries:
//!
//!   provider "anthropic"  ↔ harness "claude" ↔ binary `claude`
//!   provider "openai"     ↔ harness "codex"  ↔ binary `codex`
//!
//! v1 invocations:
//!
//!   claude -p <prompt> --output-format stream-json --verbose --include-partial-messages
//!   codex exec --json <prompt>
//!
//! Prompt source: the item directory's `prompt.md`. If missing or empty, the
//! prompt defaults to the item's slug. Real provider tests will rely on the
//! prompt.md path; mock tests bypass this entirely by passing a custom
//! `build_argv` that runs the fake-harness `cat_jsonl.sh` script.

const std = @import("std");
const adapter_mod = @import("adapter.zig");
const runtime_mod = @import("runtime.zig");
const item_mod = @import("item.zig");
const claude_adapter = @import("claude_adapter.zig");
const codex_adapter = @import("codex_adapter.zig");
const fake_adapter = @import("fake_adapter.zig");
const provider_status = @import("provider_status.zig");

pub const Names = struct {
    pub const claude: []const u8 = "claude";
    pub const codex: []const u8 = "codex";
    pub const gemini: []const u8 = "gemini";
    pub const fake: []const u8 = "fake";
};

/// Map an item's `target.provider` (string id) to the canonical harness
/// name used elsewhere. Returns null when no provider was specified.
pub fn providerToHarness(provider: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, provider, "anthropic")) return Names.claude;
    if (std.mem.eql(u8, provider, "openai")) return Names.codex;
    if (std.mem.eql(u8, provider, "claude")) return Names.claude;
    if (std.mem.eql(u8, provider, "codex")) return Names.codex;
    if (std.mem.eql(u8, provider, "google")) return Names.gemini;
    if (std.mem.eql(u8, provider, "gemini")) return Names.gemini;
    return null;
}

/// Inverse mapping: harness name → the canonical provider slug used in
/// `provider_status` / routing. Returns null for unknown harnesses (e.g.
/// "fake").
pub fn harnessToProvider(harness: []const u8) ?provider_status.Provider {
    if (std.mem.eql(u8, harness, Names.claude)) return .anthropic;
    if (std.mem.eql(u8, harness, Names.codex)) return .openai;
    if (std.mem.eql(u8, harness, Names.gemini)) return .google;
    return null;
}

/// Adapter factory. Returns null when the requested harness is unknown.
///
/// M8 NOTE: this is purely "do we know how to build the adapter object";
/// it does NOT include the binary-presence preflight. The supervisor calls
/// `provider_status.probe(...)` separately so it can distinguish
/// "harness wholly unknown" from "binary missing on this machine" and emit
/// the right canonical reason slug.
pub fn factory(allocator: std.mem.Allocator, harness: []const u8) anyerror!?adapter_mod.Adapter {
    if (std.mem.eql(u8, harness, Names.claude)) {
        return try claude_adapter.create(allocator);
    } else if (std.mem.eql(u8, harness, Names.codex)) {
        return try codex_adapter.create(allocator);
    } else if (std.mem.eql(u8, harness, Names.fake)) {
        return try fake_adapter.create(allocator);
    }
    // gemini: deliberately not wired into the factory in v1 — the adapter is
    // deferred (see `provider_status.zig` and design_execution_harness.md).
    // Returning null here means the routing preflight blocks gemini-routed
    // items with `harness_unavailable`.
    return null;
}

/// Compose argv for the routed harness.
///
/// `item_dir_abs` is the absolute path to the item's directory (where
/// `prompt.md` lives). On error or missing prompt, the slug is used as a
/// fallback prompt so the subprocess at least has a non-empty argument.
pub fn buildArgv(
    allocator: std.mem.Allocator,
    harness: []const u8,
    item: *const item_mod.Item,
    item_dir_abs: []const u8,
) anyerror![][]u8 {
    const prompt = try resolvePrompt(allocator, item, item_dir_abs);
    errdefer allocator.free(prompt);

    if (std.mem.eql(u8, harness, Names.claude)) {
        return buildClaudeArgv(allocator, prompt);
    } else if (std.mem.eql(u8, harness, Names.codex)) {
        return buildCodexArgv(allocator, prompt);
    } else {
        return error.UnsupportedHarness;
    }
}

fn resolvePrompt(
    allocator: std.mem.Allocator,
    item: *const item_mod.Item,
    item_dir_abs: []const u8,
) ![]u8 {
    const path = try std.fs.path.join(allocator, &.{ item_dir_abs, "prompt.md" });
    defer allocator.free(path);
    var f = std.fs.cwd().openFile(path, .{}) catch |e| switch (e) {
        error.FileNotFound => return allocator.dupe(u8, item.slug),
        else => return e,
    };
    defer f.close();
    const stat = try f.stat();
    const buf = try allocator.alloc(u8, stat.size);
    errdefer allocator.free(buf);
    const n = try f.readAll(buf);
    if (n == 0) {
        allocator.free(buf);
        return allocator.dupe(u8, item.slug);
    }
    // Trim trailing newline for tidier argv.
    var end = n;
    while (end > 0 and (buf[end - 1] == '\n' or buf[end - 1] == '\r')) end -= 1;
    if (end == 0) {
        allocator.free(buf);
        return allocator.dupe(u8, item.slug);
    }
    return try allocator.realloc(buf, end);
}

fn buildClaudeArgv(allocator: std.mem.Allocator, prompt_owned: []u8) ![][]u8 {
    // We will hand the prompt as a single argv slot.
    var out = std.ArrayList([]u8){};
    errdefer {
        for (out.items) |s| allocator.free(s);
        out.deinit(allocator);
        allocator.free(prompt_owned);
    }
    try out.append(allocator, try allocator.dupe(u8, "claude"));
    try out.append(allocator, try allocator.dupe(u8, "-p"));
    try out.append(allocator, prompt_owned);
    try out.append(allocator, try allocator.dupe(u8, "--output-format"));
    try out.append(allocator, try allocator.dupe(u8, "stream-json"));
    try out.append(allocator, try allocator.dupe(u8, "--verbose"));
    try out.append(allocator, try allocator.dupe(u8, "--include-partial-messages"));
    return out.toOwnedSlice(allocator);
}

fn buildCodexArgv(allocator: std.mem.Allocator, prompt_owned: []u8) ![][]u8 {
    var out = std.ArrayList([]u8){};
    errdefer {
        for (out.items) |s| allocator.free(s);
        out.deinit(allocator);
        allocator.free(prompt_owned);
    }
    try out.append(allocator, try allocator.dupe(u8, "codex"));
    try out.append(allocator, try allocator.dupe(u8, "exec"));
    try out.append(allocator, try allocator.dupe(u8, "--json"));
    try out.append(allocator, prompt_owned);
    return out.toOwnedSlice(allocator);
}

/// Pre-built `Dispatch` ready to plug into the supervisor / daemon.
pub fn dispatch() runtime_mod.Dispatch {
    return .{
        .factory = factory,
        .build_argv = buildArgv,
    };
}

// ---------- tests ----------

test "providerToHarness: anthropic -> claude, openai -> codex" {
    try std.testing.expectEqualStrings("claude", providerToHarness("anthropic").?);
    try std.testing.expectEqualStrings("codex", providerToHarness("openai").?);
    try std.testing.expectEqualStrings("gemini", providerToHarness("google").?);
    try std.testing.expectEqualStrings("gemini", providerToHarness("gemini").?);
    try std.testing.expect(providerToHarness("unknown") == null);
}

test "harnessToProvider: round-trip through known names" {
    try std.testing.expectEqual(provider_status.Provider.anthropic, harnessToProvider("claude").?);
    try std.testing.expectEqual(provider_status.Provider.openai, harnessToProvider("codex").?);
    try std.testing.expectEqual(provider_status.Provider.google, harnessToProvider("gemini").?);
    try std.testing.expect(harnessToProvider("fake") == null);
}

test "factory: gemini harness deliberately deferred (returns null)" {
    const a = std.testing.allocator;
    const ad = try factory(a, "gemini");
    if (ad) |x| {
        x.deinit(a);
        return error.UnexpectedAdapter;
    }
}

test "factory: claude harness returns a claude adapter" {
    const a = std.testing.allocator;
    const ad = (try factory(a, "claude")) orelse return error.NoAdapter;
    defer ad.deinit(a);
    try std.testing.expectEqualStrings("claude", ad.name);
}

test "factory: codex harness returns a codex adapter" {
    const a = std.testing.allocator;
    const ad = (try factory(a, "codex")) orelse return error.NoAdapter;
    defer ad.deinit(a);
    try std.testing.expectEqualStrings("codex", ad.name);
}

test "factory: unknown harness returns null" {
    const a = std.testing.allocator;
    const ad = try factory(a, "no-such-harness");
    if (ad) |x| {
        x.deinit(a);
        return error.UnexpectedAdapter;
    }
}

test "buildArgv: claude shape" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var it = item_mod.Item{
        .arena = std.heap.ArenaAllocator.init(a),
        .id = "0001",
        .slug = "say-hi",
        .kind = .prompt,
        .status = .queued,
        .created_at = "2026-05-10T14:00:00Z",
        .updated_at = "2026-05-10T14:00:00Z",
    };
    defer it.deinit();
    // No prompt.md on disk → falls back to slug.
    const argv = try buildArgv(a, "claude", &it, "/nonexistent-dir-9001");
    defer {
        for (argv) |s| a.free(s);
        a.free(argv);
    }
    try std.testing.expectEqualStrings("claude", argv[0]);
    try std.testing.expectEqualStrings("-p", argv[1]);
    try std.testing.expectEqualStrings("say-hi", argv[2]);
    try std.testing.expectEqualStrings("--output-format", argv[3]);
    try std.testing.expectEqualStrings("stream-json", argv[4]);
    try std.testing.expectEqualStrings("--verbose", argv[5]);
    try std.testing.expectEqualStrings("--include-partial-messages", argv[6]);
}

test "buildArgv: codex shape" {
    const a = std.testing.allocator;
    var it = item_mod.Item{
        .arena = std.heap.ArenaAllocator.init(a),
        .id = "0001",
        .slug = "say-hi",
        .kind = .prompt,
        .status = .queued,
        .created_at = "2026-05-10T14:00:00Z",
        .updated_at = "2026-05-10T14:00:00Z",
    };
    defer it.deinit();
    const argv = try buildArgv(a, "codex", &it, "/nonexistent-dir-9002");
    defer {
        for (argv) |s| a.free(s);
        a.free(argv);
    }
    try std.testing.expectEqualStrings("codex", argv[0]);
    try std.testing.expectEqualStrings("exec", argv[1]);
    try std.testing.expectEqualStrings("--json", argv[2]);
    try std.testing.expectEqualStrings("say-hi", argv[3]);
}

test "buildArgv: unknown harness fails instead of running a no-op" {
    const a = std.testing.allocator;
    var it = item_mod.Item{
        .arena = std.heap.ArenaAllocator.init(a),
        .id = "0001",
        .slug = "say-hi",
        .kind = .prompt,
        .status = .queued,
        .created_at = "2026-05-10T14:00:00Z",
        .updated_at = "2026-05-10T14:00:00Z",
    };
    defer it.deinit();
    try std.testing.expectError(error.UnsupportedHarness, buildArgv(a, "unknown", &it, "/nonexistent-dir-9003"));
}
