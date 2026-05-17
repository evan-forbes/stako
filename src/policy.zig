//! Capability policy evaluator (milestone 10).
//!
//! Resolves `(identity, action, target) -> allow | deny(reason)` for every
//! sensitive daemon action. See `todos/design_authorization.md` for the
//! motivation and `todos/design_errors_and_audit.md` for the failure
//! vocabulary (`identity_required` 401, `capability_denied` 403).
//!
//! ## Capability slug schema
//!
//! - `*` — wildcard, all actions allowed (typical local-user default).
//! - `stack.create` — create new stacks.
//! - `stack.<name>.<verb>` — per-stack action where `<verb>` ∈
//!   `append`, `insert`, `retry`, `cancel`, `supersede`, `pause`, `resume`,
//!   `config`. The name may be `*` (any stack). The verb may be `*`
//!   (any verb on the named stack).
//! - `provider.<name>` — dispatch through a provider; `<name>` ∈
//!   `anthropic`, `openai`, `google`. The name may be `*` (any provider).
//!
//! Unknown slugs are ignored (forward-compat: new capabilities can ship
//! without breaking older daemons that haven't learned them yet, since
//! the policy is allow-list semantics — an unknown grant simply doesn't
//! match anything).
//!
//! ## Identity model
//!
//! Identities are declared as `[identity.<name>]` tables in
//! `.stako/config.toml` (or `config.local.toml`). The `capabilities`
//! array is the only field that matters for the policy evaluator.
//!
//! The local mutation token (`.stako/local_token`) always resolves to
//! the `local` identity. If the user has not declared `[identity.local]`
//! in their config files, the policy defaults to full access (`*`) so
//! the v1 single-user flow keeps working without ceremony. Once a user
//! *does* declare `[identity.local]`, their list is authoritative — they
//! get exactly the capabilities they wrote, no implicit `*`.
//!
//! Future MCP/scheduled-job identities follow the same pattern: declare
//! the table, list the capabilities, present the matching credential
//! (out of scope for v1 — only the local token is wired).
//!
//! ## Out of scope (per the plan)
//!
//! - MCP transport layer.
//! - Container isolation.
//! - Capability inference from prompt content.
//! - Time-bound capabilities.

const std = @import("std");
const config_mod = @import("config.zig");

/// Sensitive actions the policy evaluator gates. Matches the audit action
/// vocabulary so denials and allowances share one set of slugs.
pub const Action = enum {
    create_stack,
    read_stack,
    append_item,
    insert_item,
    retry_item,
    cancel_item,
    supersede_item,
    pause_stack,
    resume_stack,
    update_stack_config,
    /// A harness/provider dispatch attempt; gated by `provider.<name>`.
    dispatch_harness,

    pub fn slug(self: Action) []const u8 {
        return switch (self) {
            .create_stack => "create_stack",
            .read_stack => "read_stack",
            .append_item => "append_item",
            .insert_item => "insert_item",
            .retry_item => "retry_item",
            .cancel_item => "cancel_item",
            .supersede_item => "supersede_item",
            .pause_stack => "pause_stack",
            .resume_stack => "resume_stack",
            .update_stack_config => "update_stack_config",
            .dispatch_harness => "dispatch_harness",
        };
    }

    /// The stack-action "verb" portion of a capability slug
    /// (`stack.<name>.<verb>`). Not applicable to `create_stack` or
    /// `dispatch_harness`.
    fn stackVerb(self: Action) ?[]const u8 {
        return switch (self) {
            .append_item => "append",
            .read_stack => "read",
            .insert_item => "insert",
            .retry_item => "retry",
            .cancel_item => "cancel",
            .supersede_item => "supersede",
            .pause_stack => "pause",
            .resume_stack => "resume",
            .update_stack_config => "config",
            .create_stack, .dispatch_harness => null,
        };
    }
};

/// Target descriptor. Different actions look at different fields; the
/// evaluator picks the right subset.
pub const Target = union(enum) {
    /// `create_stack` target: the new stack name.
    stack_create: []const u8,
    /// Per-stack mutation target.
    stack: []const u8,
    /// Per-provider dispatch target. The provider slug must be one of
    /// `anthropic`, `openai`, `google` (or `*` to match any).
    provider: []const u8,
};

pub const Decision = union(enum) {
    allow: void,
    /// `identity_required` (401) — no identity resolved at all.
    identity_required: void,
    /// `capability_denied` (403) — identity resolved but lacks the cap.
    /// The caller computes the human-friendly slug for the error
    /// response; the evaluator does not return a slice because the
    /// natural way to compose one (`std.fmt.bufPrint` on a stack
    /// buffer) would dangle the moment `evaluate` returns.
    capability_denied: void,
};

/// Resolve an asserted identity name + verify the supplied credential.
///
/// In v1 the daemon only accepts the local mutation token, which always
/// resolves to the `local` identity. Future MCP/scheduled flows extend
/// this function with their own identity → credential lookup.
pub const IdentityResolution = struct {
    /// Resolved identity name. `"local"` for the loopback user.
    name: []const u8,
    /// Whether the user declared `[identity.local]` themselves. When
    /// false (the default), the policy evaluator grants full access for
    /// backwards-compat with the milestone-3 single-token mechanism.
    explicitly_declared: bool,
    /// The identity entry from config, if declared. Borrowed; same
    /// lifetime as the `Config` it came from.
    entry: ?*const config_mod.Identity,
};

/// Resolve the local-bearer-token credential to the `local` identity.
/// Always returns `local` — the token is the only v1 authenticator. The
/// caller is expected to have already verified the token against
/// `local_token.Token.verify` before reaching this function.
pub fn resolveLocal(cfg: *const config_mod.Config) IdentityResolution {
    if (cfg.findIdentity("local")) |e| {
        return .{ .name = "local", .explicitly_declared = true, .entry = e };
    }
    return .{ .name = "local", .explicitly_declared = false, .entry = null };
}

/// Evaluate the policy. The `identity` may be `null`, in which case the
/// decision is `identity_required` — the caller renders that as HTTP 401
/// and an audit-log denial entry.
pub fn evaluate(
    identity: ?IdentityResolution,
    action: Action,
    target: Target,
) Decision {
    const id = identity orelse return .{ .identity_required = {} };

    // Backwards-compat: the local identity, when not explicitly declared
    // in config, retains full access. Existing milestone-3..9 deployments
    // never wrote `[identity.local]`; their behavior must not regress.
    if (!id.explicitly_declared) return .{ .allow = {} };

    const caps = if (id.entry) |e| (e.capabilities orelse &.{}) else &.{};

    for (caps) |c| {
        if (std.mem.eql(u8, c, "*")) return .{ .allow = {} };
        switch (action) {
            .create_stack => {
                if (std.mem.eql(u8, c, "stack.create")) return .{ .allow = {} };
            },
            .dispatch_harness => {
                const provider = switch (target) {
                    .provider => |p| p,
                    else => return .{ .capability_denied = {} },
                };
                if (matchesProviderCapability(c, provider)) return .{ .allow = {} };
            },
            else => {
                const verb = action.stackVerb() orelse return .{ .capability_denied = {} };
                const stack_name = switch (target) {
                    .stack => |s| s,
                    .stack_create => |s| s,
                    else => return .{ .capability_denied = {} },
                };
                if (matchesStackCapability(c, stack_name, verb)) return .{ .allow = {} };
            },
        }
    }
    return .{ .capability_denied = {} };
}

fn matchesProviderCapability(cap: []const u8, provider: []const u8) bool {
    const prefix = "provider.";
    if (!std.mem.startsWith(u8, cap, prefix)) return false;
    const name = cap[prefix.len..];
    return std.mem.eql(u8, name, "*") or std.mem.eql(u8, name, provider);
}

fn matchesStackCapability(cap: []const u8, stack_name: []const u8, verb: []const u8) bool {
    const prefix = "stack.";
    if (!std.mem.startsWith(u8, cap, prefix)) return false;
    const rest = cap[prefix.len..];
    const dot = std.mem.lastIndexOfScalar(u8, rest, '.') orelse return false;
    const cap_stack = rest[0..dot];
    const cap_verb = rest[dot + 1 ..];
    const stack_matches = std.mem.eql(u8, cap_stack, "*") or std.mem.eql(u8, cap_stack, stack_name);
    const verb_matches = std.mem.eql(u8, cap_verb, "*") or std.mem.eql(u8, cap_verb, verb);
    return stack_matches and verb_matches;
}

// ---------- unit tests ----------

const testing = std.testing;

fn cfgFromToml(allocator: std.mem.Allocator, src: []const u8) !config_mod.Config {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath(".stako");
    var f = try tmp.dir.createFile(".stako/config.toml", .{ .truncate = true });
    defer f.close();
    try f.writeAll(src);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs = try tmp.dir.realpath(".", &buf);
    return config_mod.loadFromRoot(allocator, abs);
}

test "evaluate: no identity → identity_required" {
    const d = evaluate(null, .append_item, .{ .stack = "default" });
    try testing.expect(d == .identity_required);
}

test "evaluate: undeclared local identity has full access (backwards-compat)" {
    const a = testing.allocator;
    var cfg = try cfgFromToml(a, ""); // no identity tables
    defer cfg.deinit();
    const id = resolveLocal(&cfg);
    try testing.expect(!id.explicitly_declared);
    try testing.expectEqualStrings("local", id.name);
    try testing.expect(evaluate(id, .append_item, .{ .stack = "default" }) == .allow);
    try testing.expect(evaluate(id, .create_stack, .{ .stack_create = "anything" }) == .allow);
    try testing.expect(evaluate(id, .dispatch_harness, .{ .provider = "openai" }) == .allow);
}

test "evaluate: explicit `*` capability allows everything" {
    const a = testing.allocator;
    var cfg = try cfgFromToml(a,
        \\[identity.local]
        \\capabilities = ["*"]
        \\
    );
    defer cfg.deinit();
    const id = resolveLocal(&cfg);
    try testing.expect(id.explicitly_declared);
    try testing.expect(evaluate(id, .append_item, .{ .stack = "default" }) == .allow);
    try testing.expect(evaluate(id, .dispatch_harness, .{ .provider = "anthropic" }) == .allow);
}

test "evaluate: stack.<name>.<verb> matches the exact action+stack" {
    const a = testing.allocator;
    var cfg = try cfgFromToml(a,
        \\[identity.local]
        \\capabilities = ["stack.demo.append"]
        \\
    );
    defer cfg.deinit();
    const id = resolveLocal(&cfg);
    try testing.expect(evaluate(id, .append_item, .{ .stack = "demo" }) == .allow);
    try testing.expect(evaluate(id, .append_item, .{ .stack = "other" }) == .capability_denied);
    try testing.expect(evaluate(id, .cancel_item, .{ .stack = "demo" }) == .capability_denied);
}

test "evaluate: stack.*.<verb> matches any stack for that verb" {
    const a = testing.allocator;
    var cfg = try cfgFromToml(a,
        \\[identity.local]
        \\capabilities = ["stack.*.cancel"]
        \\
    );
    defer cfg.deinit();
    const id = resolveLocal(&cfg);
    try testing.expect(evaluate(id, .cancel_item, .{ .stack = "x" }) == .allow);
    try testing.expect(evaluate(id, .cancel_item, .{ .stack = "y" }) == .allow);
    try testing.expect(evaluate(id, .pause_stack, .{ .stack = "x" }) == .capability_denied);
}

test "evaluate: stack.<name>.* matches any verb for that stack" {
    const a = testing.allocator;
    var cfg = try cfgFromToml(a,
        \\[identity.local]
        \\capabilities = ["stack.demo.*"]
        \\
    );
    defer cfg.deinit();
    const id = resolveLocal(&cfg);
    try testing.expect(evaluate(id, .append_item, .{ .stack = "demo" }) == .allow);
    try testing.expect(evaluate(id, .pause_stack, .{ .stack = "demo" }) == .allow);
    try testing.expect(evaluate(id, .update_stack_config, .{ .stack = "demo" }) == .allow);
    try testing.expect(evaluate(id, .append_item, .{ .stack = "other" }) == .capability_denied);
}

test "evaluate: long stack names are matched structurally" {
    const a = testing.allocator;
    const long_stack = "this-is-a-long-stack-name-that-used-to-overflow-the-fixed-policy-probe-buffer-because-it-keeps-going-past-one-hundred-twenty-eight-bytes";
    const src = try std.fmt.allocPrint(a,
        \\[identity.local]
        \\capabilities = ["stack.{s}.append"]
        \\
    , .{long_stack});
    defer a.free(src);
    var cfg = try cfgFromToml(a, src);
    defer cfg.deinit();
    const id = resolveLocal(&cfg);
    try testing.expect(evaluate(id, .append_item, .{ .stack = long_stack }) == .allow);
    try testing.expect(evaluate(id, .cancel_item, .{ .stack = long_stack }) == .capability_denied);
}

test "evaluate: create_stack requires stack.create or *" {
    const a = testing.allocator;
    var cfg = try cfgFromToml(a,
        \\[identity.local]
        \\capabilities = ["stack.*.append"]
        \\
    );
    defer cfg.deinit();
    const id = resolveLocal(&cfg);
    const d = evaluate(id, .create_stack, .{ .stack_create = "newone" });
    try testing.expect(d == .capability_denied);

    var cfg2 = try cfgFromToml(a,
        \\[identity.local]
        \\capabilities = ["stack.create"]
        \\
    );
    defer cfg2.deinit();
    const id2 = resolveLocal(&cfg2);
    try testing.expect(evaluate(id2, .create_stack, .{ .stack_create = "newone" }) == .allow);
}

test "evaluate: provider.<name> gates dispatch_harness" {
    const a = testing.allocator;
    var cfg = try cfgFromToml(a,
        \\[identity.local]
        \\capabilities = ["provider.anthropic"]
        \\
    );
    defer cfg.deinit();
    const id = resolveLocal(&cfg);
    try testing.expect(evaluate(id, .dispatch_harness, .{ .provider = "anthropic" }) == .allow);
    try testing.expect(evaluate(id, .dispatch_harness, .{ .provider = "openai" }) == .capability_denied);
}

test "evaluate: provider.* matches any provider" {
    const a = testing.allocator;
    var cfg = try cfgFromToml(a,
        \\[identity.local]
        \\capabilities = ["provider.*"]
        \\
    );
    defer cfg.deinit();
    const id = resolveLocal(&cfg);
    try testing.expect(evaluate(id, .dispatch_harness, .{ .provider = "anthropic" }) == .allow);
    try testing.expect(evaluate(id, .dispatch_harness, .{ .provider = "openai" }) == .allow);
    try testing.expect(evaluate(id, .dispatch_harness, .{ .provider = "google" }) == .allow);
}

test "evaluate: empty capabilities array denies everything" {
    const a = testing.allocator;
    var cfg = try cfgFromToml(a,
        \\[identity.local]
        \\capabilities = []
        \\
    );
    defer cfg.deinit();
    const id = resolveLocal(&cfg);
    try testing.expect(evaluate(id, .append_item, .{ .stack = "default" }) == .capability_denied);
    try testing.expect(evaluate(id, .create_stack, .{ .stack_create = "x" }) == .capability_denied);
    try testing.expect(evaluate(id, .dispatch_harness, .{ .provider = "anthropic" }) == .capability_denied);
}

test "evaluate: unknown capability slugs are silently ignored" {
    const a = testing.allocator;
    var cfg = try cfgFromToml(a,
        \\[identity.local]
        \\capabilities = ["future.capability.we.dont.know", "stack.demo.append"]
        \\
    );
    defer cfg.deinit();
    const id = resolveLocal(&cfg);
    try testing.expect(evaluate(id, .append_item, .{ .stack = "demo" }) == .allow);
    try testing.expect(evaluate(id, .append_item, .{ .stack = "other" }) == .capability_denied);
}

// Coverage gap #2 (audit_10): `[identity.local]` declared but no
// `capabilities` key. `Identity.capabilities` is `null` in that case;
// `evaluate` must fall through to `caps = &.{}` and deny every action.
test "evaluate: declared identity without capabilities key denies all" {
    const a = testing.allocator;
    var cfg = try cfgFromToml(a,
        \\[identity.local]
        \\type = "user"
        \\
    );
    defer cfg.deinit();
    const id = resolveLocal(&cfg);
    try testing.expect(id.explicitly_declared);
    try testing.expect(id.entry != null);
    try testing.expect(id.entry.?.capabilities == null);
    try testing.expect(evaluate(id, .append_item, .{ .stack = "default" }) == .capability_denied);
    try testing.expect(evaluate(id, .create_stack, .{ .stack_create = "x" }) == .capability_denied);
    try testing.expect(evaluate(id, .dispatch_harness, .{ .provider = "anthropic" }) == .capability_denied);
}

// Coverage gap #3 (audit_10): wildcard `*` in non-supported positions.
// These slugs fail every match function and fall through to default-deny.
test "evaluate: wildcards in unsupported positions fall through to deny" {
    const a = testing.allocator;
    var cfg = try cfgFromToml(a,
        \\[identity.local]
        \\capabilities = ["*.append", "stack.*", "*.", "stack.", "provider."]
        \\
    );
    defer cfg.deinit();
    const id = resolveLocal(&cfg);
    // None of these caps grant anything; default-deny applies.
    try testing.expect(evaluate(id, .append_item, .{ .stack = "demo" }) == .capability_denied);
    try testing.expect(evaluate(id, .pause_stack, .{ .stack = "demo" }) == .capability_denied);
    try testing.expect(evaluate(id, .create_stack, .{ .stack_create = "x" }) == .capability_denied);
    try testing.expect(evaluate(id, .dispatch_harness, .{ .provider = "anthropic" }) == .capability_denied);
}

// Coverage gap #5 (audit_10): policy evaluates against the raw stack-name
// from the route match (e.g. `<illegal>` containing characters that
// `storage.isValidStackName` rejects). Confirm policy still runs and
// returns the expected default-deny — the handler layer rejects with 400
// only after policy has been consulted.
test "evaluate: illegal stack names flow through policy and deny by default" {
    const a = testing.allocator;
    var cfg = try cfgFromToml(a,
        \\[identity.local]
        \\capabilities = ["stack.demo.append"]
        \\
    );
    defer cfg.deinit();
    const id = resolveLocal(&cfg);
    // The route matcher would supply this stack-name verbatim; policy
    // must not match the capability and must deny.
    try testing.expect(evaluate(id, .append_item, .{ .stack = "Bad/Name!" }) == .capability_denied);
    try testing.expect(evaluate(id, .append_item, .{ .stack = "" }) == .capability_denied);
    // `stack.*.append` still matches even a structurally-invalid name —
    // the policy evaluator is name-agnostic by design, the handler layer
    // rejects 400 after policy.
    var cfg2 = try cfgFromToml(a,
        \\[identity.local]
        \\capabilities = ["stack.*.append"]
        \\
    );
    defer cfg2.deinit();
    const id2 = resolveLocal(&cfg2);
    try testing.expect(evaluate(id2, .append_item, .{ .stack = "Bad/Name!" }) == .allow);
}
