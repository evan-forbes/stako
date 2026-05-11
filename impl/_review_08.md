# Milestone 8 Review

Diff range: 22f26f6..f39f3f8

## Blocking

(none)

## Non-blocking

- `src/cli_auth.zig:148` — `renderList` accepts an `allocator` parameter that
  is immediately `_ = allocator;`'d. Dead arg; could be dropped.
- `src/cli_auth.zig:158` — Local `var first = true;` is set but only ever
  written; the "no providers reported" branch uses it but the loop never
  resets it after the first iteration so the "(no providers reported)"
  message can never fire when the body has any content. Behaviorally fine
  (empty `{"providers":[]}` would still print the header without rows),
  but the `first` tracking is misleading dead-ish code.
- `src/provider_status.zig:138-189` — Anthropic/Codex auth detection treats
  the *existence* of `~/.claude/` or `~/.codex/` (directory, even if empty)
  as `signed_in`. A user who installed and uninstalled, or ran the CLI once
  to bootstrap a config dir without authenticating, would be reported as
  signed_in with note "reusing existing Claude/Codex CLI credentials".
  Acceptable for v1 (the design explicitly accepts filesystem-only auth
  detection without subprocess) but worth tightening — narrow to the
  documented credential file paths only and stop falling back to the bare
  dir.
- `src/runtime.zig:91-100` — `providerStatus()` caches probe results for
  the supervisor's lifetime. If a user installs a missing provider CLI
  while the daemon is running, they must restart the daemon to clear the
  cache. The design (`design_execution_harness.md` "Gemini capability
  probe") explicitly says "Probe result is cached for the daemon's
  lifetime; re-probe on startup catches upgrades", so this matches spec —
  noting it only as a usability sharp edge.
- `src/harness_dispatch.zig:107-110` — `buildArgv` for an unknown harness
  returns `/usr/bin/true` as a no-op fallback. Comment says preflight
  should have already blocked this case; if preflight ever drifts, this
  would silently mark items completed instead of failing loudly. Defense-
  in-depth would `return error.UnknownHarness;` here, but the comment is
  honest and preflight does block it today, so non-blocking.
- `src/cli.zig:454-463` — `parseAuthArgs` rejects an unrecognized first
  positional gracefully by treating it as a provider name, but if the
  daemon doesn't recognize the name the user gets a generic 404 with the
  raw provider string echoed back. Acceptable but the CLI could
  pre-validate against `Provider.fromString` and emit a friendlier
  message client-side; currently it just round-trips the server reply.
- `src/cli_auth.zig:84-98` — `runSignout` never hits the daemon. This
  matches the implementer's claim; the user-facing message is good. Worth
  noting: the daemon's audit log therefore has no record of a signout
  attempt. v1 daemon doesn't own subscription tokens, so there is no
  "credential state" to mutate — no security smell. If a future milestone
  makes the daemon a credential store, this surface must be reworked to
  go through the queue.

## Deferred-confirmed

- **Gemini scaffolded with factory returning null** — Confirmed deferred,
  legitimately. Plan step 7 says "Gemini failing does not block milestone
  acceptance for Claude/Codex." Plan Acceptance bullet 3 explicitly
  permits "either working end-to-end or explicitly disabled with a clear
  reason". `harness_dispatch.factory("gemini")` returns null;
  `provider_status.probeGemini` returns `available=false` with a stable
  note; gemini-routed items land in `blocked` with `harness_unavailable`.
  The design doc was amended at `todos/design_execution_harness.md:49`
  with a dated M8 update describing the deferral and the future un-defer
  path. Legitimately deferred.
- **Plan step 8 (`compact`/`clear` revisit)** — Plan literally says "If
  this threatens the milestone, defer it explicitly rather than
  half-implementing." No code or doc change for compact/clear in this
  diff, but the plan permits a no-op decision. Recommendation: the
  decision-to-defer is not explicitly written down anywhere — the
  implementer chose silence. Treating this as deferred-confirmed because
  the plan's escape hatch is wide; flagging as a documentation gap (a
  one-line note in `_status.md` would have made this airtight). Not
  blocking.

## Acceptance criteria

- **`organo auth status` accurately reports Claude and Codex availability.**
  MET — CLI test `cli: auth status renders header + every provider row`
  exercises the full path; daemon test
  `daemon: GET /providers/anthropic surfaces signed_in/signed_out fields`
  pins the JSON shape; provider probe distinguishes binary_present, env
  key, and CLI credential dir.
- **Claude and Codex routed items use one credential-resolution path
  instead of hidden ad-hoc logic.** MET — `provider_status.probe` is the
  one entry point, called by both the supervisor (cached) and the daemon
  HTTP endpoint. `harness_dispatch.harnessToProvider` is the single
  harness↔provider map, used by the preflight.
- **Gemini is either working end-to-end or explicitly disabled with a
  clear reason; it is not a source of ambiguous runtime failure.** MET —
  Factory returns null; status reports `available=false` and stable note
  "structured stream-json mode unconfirmed; adapter deferred"; preflight
  emits `harness_unavailable` blocked reason; M8 update added to
  `design_execution_harness.md`. Runtime test `m8 routing: gemini-routed
  item blocks with harness_unavailable when preflight enabled` proves the
  end-to-end behavior.
- **Provider-specific code stays behind provider/adapter interfaces;
  session management and transcript handling remain shared.** MET —
  `provider_status.zig` is the only new provider-aware module; the
  supervisor, session manager, and transcript writer are untouched.
- **Daemon-owned OAuth/subscription token storage is not required for v1.**
  MET — No token storage was added; signout deliberately doesn't go
  through the daemon and the help text explains why (defer to the
  provider's own CLI or unset env vars).

## Other check notes

- **Build wiring**: `zig build test --summary all` → 22/22 steps; 273/273
  tests passed in ~422 ms longest single step. Matches the brief's "273
  pass under 5s" expectation.
- **Default-off preflight**: `daemon.StartOptions.enable_provider_preflight`
  and `runtime.Options.enable_provider_preflight` both default `false`.
  All pre-M8 runtime tests (M6, M7) construct the supervisor without
  setting the flag — confirmed by grep over `test/runtime_tests.zig`
  matches. Daemon tests use `startEphemeralDaemon` which doesn't set it.
  Regression test `m8 routing: preflight disabled allows the fake-harness
  path to run as before` explicitly pins this behavior.
- **HTTP endpoint auth**: `/providers` and `/providers/{name}` are GETs;
  the daemon only calls `verifyAuth` when `isMutationRoute(route)` is
  true (daemon.zig:590). GET reads remain unauthenticated, matching M5.
  Response bodies never include the actual API-key value or session
  token — only `credential_env` (the *name* of the env var,
  `ANTHROPIC_API_KEY`/`OPENAI_API_KEY`/`GEMINI_API_KEY`) and a boolean
  `auth` state. No leak.
- **404 / error paths**: `/providers/bogus` returns 404 with
  `{"error":{"code":"not_found","message":"unknown provider", ...}}`,
  pinned by `daemon: GET /providers/bogus returns 404`. Matches
  `design_errors_and_audit.md` shape and status mapping.
- **Auth probe scope vs. research_provider_sign_in.md**: The research doc
  does not mandate subprocess-based `auth status`/`whoami` calls. It
  lists "Official CLI auth/status behavior" as something to *document*,
  not to *invoke*. The "no subprocess" choice is documented in
  `provider_status.zig:14-19` (file-level doc comment) and is consistent
  with the research-doc decision "Decide credential resolution strategy
  per provider (official CLI reuse first, API-key fallback, daemon-owned
  storage only if stable and cheap)". Expired-credentials false positive
  is acceptable for v1 (only surfaces when the user runs the harness,
  which will then fail with the provider's own error).
- **Anti-patterns**:
  - No use-after-return / stack-slice escapes: `Status` strings are all
    `[]const u8` to string literals stored in the binary (note,
    login_hint, blocked_reason are compile-time selected literals); no
    arena/stack pointers leak.
  - Mutation-queue: preflight blocks via `mutation_queue.Request{ .kind =
    .runtime_transition }` exactly as M6/M7 — no direct file writes from
    the new code paths.
  - Subprocess: provider probe is purely PATH scan + `statFile`. No
    `Child.spawn` anywhere in the new code (verified by grep). The
    file-level doc comment in `provider_status.zig:14-19` documents the
    "no subprocess" decision.
  - Test threads: existing daemon `Driver` shutdown path used unchanged;
    new tests use `sm.waitAll()` for runtime tests and rely on
    `Driver.deinit` for daemon tests. Deterministic.
  - No /tmp/organo-* leftovers after a fresh `zig build test`; previous
    runs left empty dirs but no files.
- **CLI surface vs. plan step 3**:
  - `organo auth status` / `organo a st` — MET (parser test pins both).
  - `organo auth <provider>` / `organo a <provider>` — MET (parser test
    pins shortcut; runtime test pins single-provider rendering).
  - `organo auth signout <provider>` / `organo a out <provider>` — MET
    in surface terms (parser accepts both), but the runner stably emits
    "signout not supported in v1" with exit 1. Plan says "only where
    signout is safe and provider-supported" — v1 supports neither, so
    the runtime always reports unsupported. Acceptable; the help text in
    `printAuthUsage` documents this honestly.
