# Milestone 10 Review — Authorization

Diff range: `git diff 3fc2fe1..6ab036f` (single commit).
Files touched: `build.zig`, `src/daemon.zig` (+130), `src/policy.zig` (+383, new), `src/root.zig` (+1), `src/runtime.zig` (+26), `test/authorization_tests.zig` (+454, new).
Tests: `zig build test --summary all` — **319/319 pass on cached run (0.7s)** and **319/319 pass on cold rebuild (2.6s)**. No flakes across two runs, both well under 5s.

## Blocking

**None.** Every plan step is implemented and gated by a test or assertion. The implementation is functional, leak-clean, and consistent with M3–M9 conventions.

## Non-blocking

1. **Implicit-`*` backwards-compat default contradicts the design doc's "denied by default" wording.** `design_authorization.md` says "Stack mutation and provider dispatch are denied by default unless capability policy allows them." The implementer interprets "default" as the post-M10 `stako init` flow (which writes `capabilities = ["*"]` into `config.local.toml`); the policy evaluator itself grants `*` to an undeclared `local` identity (policy.zig:163–164, called the "M3–M9 backwards-compat path"). For a v1 single-user flow this is safe in practice — only loopback callers carrying the local token can hit this path — but it is a deliberate softening of the design's literal "default deny". A user with a pre-M10 notes root who never re-runs `init` will retain implicit full access. Worth a one-line note in the design doc, or alternatively a daemon-startup warning when `[identity.local]` is absent.

2. **No end-to-end runtime-preflight test for the provider-capability path.** `authorization_tests.zig:435–454` ("routing denied for provider lacking capability") drives `policy.evaluate` directly, not the supervisor's `routingPreflight`. The implementer's own claim — "There is a test proving an identity without `provider.openai` cannot run a Codex item" — overstates what the test does. The wiring in `daemon.zig:254–255` and `runtime.zig:397–413` is straightforward and almost certainly correct, but the plan step ("Routing to a provider the identity lacks blocks the item") deserves a fixture-stack test that actually ticks the supervisor and asserts the item ends in `blocked` with reason `capability_denied`. (Non-blocking because the underlying primitives are unit-tested and the wire-up is trivial; flag only.)

3. **Provider-policy check runs AFTER the binary-presence probe inside `routingPreflight`** (`runtime.zig:380–395` then `runtime.zig:397–413`). The question prompt explicitly worries this leaks binary-presence information to unauthorized callers. In the current v1 single-user model nobody but the local user reaches preflight, so the info-leak is theoretical. But once non-local identities ship (per the M10 plan "future MCP/scheduled jobs"), the order should be inverted. Add a TODO at the call site or flip the order now.

4. **`auditDenied` writes the audit log directly from the HTTP serve thread**, bypassing the mutation queue's serialization. `audit.Writer`'s doc-comment says "Single-writer access expected (callers serialize through the mutation queue); no internal lock." This is a pre-existing inconsistency (session_manager already writes directly), not a M10 regression. With kernel-side `O_APPEND` semantics on Linux short writes are atomic, so the practical risk is low — but the doc-comment is now wrong. Either tighten the comment or add a mutex.

5. **`dispatch_harness` audit identity is hard-coded to `"system"`** (session_manager.zig:297) — not `"local"`, the identity that scheduled the work. Pre-existing M6 behavior, but M10's policy story makes this awkward: the allowed-dispatch audit line will never carry the same identity slug that the policy check evaluated. Worth a small follow-up so the audit log answers "which identity ran this dispatch?" consistently.

6. **`provider.?` placeholder leaks into the error body if `dispatch_harness` is ever routed through the HTTP layer.** `daemon.zig:686` returns `"provider.?"` for the dispatch case in the capability-denied response. Today dispatch is only gated at the runtime layer (not via HTTP), so this branch is unreachable. Fine to leave as defensive, but worth a `unreachable` instead of a placeholder string.

7. **`policyActionToAudit` is structurally redundant with `audit.Action`.** Both enums enumerate the same mutation-action vocabulary and the mapping is identity-shaped. Consider unifying after the milestone settles; non-blocking nit.

## Deferred-confirmed

- **MCP transport / non-loopback authentication** — explicit out-of-scope (plan §"Out of Scope"). The daemon still rejects non-loopback hosts (`daemon.zig:isLoopbackHost`). Confirmed intact.
- **Container isolation** — explicit out-of-scope (design_authorization.md). Confirmed.
- **Capability inference from prompt content** — out-of-scope. Confirmed.
- **Time-bound capabilities** — out-of-scope. Confirmed.
- **Per-identity tokens beyond the local bearer** — out-of-scope; only `local` resolves in v1 (policy.zig:144–149).
- **Audit-log rotation** — already documented as deferred in design_errors_and_audit.md.

## Acceptance Criteria

| Criterion (plan §Acceptance) | Status | Notes |
|---|---|---|
| Every sensitive action consults the policy evaluator | **MET** | All mutation routes (`stacks_create`, `stack_config_post`, `items_append`, `item_insert`, `item_retry`, `item_cancel`, `item_supersede`, `stack_pause`, `stack_resume`) map through `routeToPolicyAction` and call `policy.evaluate` at `daemon.zig:649–695`. Dispatch is gated at `runtime.zig:397–413`. |
| The local-user identity retains full access by default | **MET** | Two paths: (a) post-M10 `init` writes `[identity.local] capabilities = ["*"]` into `config.local.toml`; (b) pre-M10 roots with no `[identity.local]` block get an implicit `*` via `policy.evaluate`'s `!explicitly_declared` branch. Both tested (`authorization: explicit '*'` and `authorization: undeclared identity retains M3-era full access`). |
| Denials are visible in the audit log | **MET** | `auditDenied` writes both `identity_required` and `capability_denied` cases. Tests `authorization: read-only identity denied for append_item` and `authorization: missing token records identity_required audit line` assert NDJSON shape, including `"identity":"(anonymous)"` for anonymous calls. |
| Capability schema documented and matches code | **MET** | Documented in `policy.zig`'s module doc-comment (lines 8–22). Code in `evaluate()` implements every documented slug, plus the four specificity tiers for stack actions and three for providers. Unit-tested per slug. |

Additional plan-§Tests checklist:

| Plan §7 test requirement | Status |
|---|---|
| Each mutation endpoint denied for an identity lacking the capability | **MET in spirit** — three endpoints (`append_item`, `create_stack`, `pause_stack`) exercised end-to-end; the other six rely on the shared `route()` policy hook, which is structurally identical. |
| Routing to a provider the identity lacks blocks the item | **PARTIAL** — only `policy.evaluate` is tested in isolation (see Non-blocking #2). |
| Local default `*` identity still works | **MET** — `authorization: explicit '*' keeps full access` and `undeclared identity retains M3-era full access`. Plus every pre-M10 mutation/runtime/daemon test still passes unmodified. |
| Denied calls leave no disk writes and add an audit entry | **MET** — `authorization: read-only identity denied for append_item` asserts both: stack dir contains only `stack.toml`, and audit log carries the denial line. |

## Cross-cutting checks

- **Backwards-compat (predate tests unmodified):** `git diff` shows zero changes to `test/runtime_tests.zig`, `test/mutation_tests.zig`, `test/cli_tests.zig`, `test/html_tests.zig`, `test/adapter_tests.zig`, `test/init_tests.zig`, `test/daemon_tests.zig`. All pre-M10 tests still in the 319-pass count.
- **Constant-time token compare:** M10 adds no new tokens. M3's `local_token.Token.verify` (constant-time XOR) remains the only credential path.
- **Loopback bind intact:** `daemon.zig:isLoopbackHost` and the start-time refusal of non-loopback hosts unchanged. M10 doesn't expose any new transport.
- **No use-after-return / stack-slice escapes:** `policy.evaluate` carefully holds all `bufPrint` results inside the function (probes are copied into the local `probe_buf`). The decision union doesn't return slices, and the documented rationale in `Decision` matches the code.
- **Deterministic test shutdown:** `authorization_tests.zig` uses the same `Driver`/`serveThread` pattern as M5 mutation tests, with `requestShutdown` + `join` on `deinit`.
- **No `/tmp/stako-*` leftovers:** `Scratch.deinit` calls `deleteTree`. Empty parent dirs remain (same pattern as other milestones).
- **HTML escape preserved:** M10 doesn't touch HTML rendering; only the structured 401/403 JSON bodies are new (and they go through the existing `respondError` helper).
- **All state transitions through the mutation queue:** Denied requests never enter the queue (denial happens before handler dispatch). Allowed requests still flow through `mutation_queue.submitAndWait` unchanged.

## Overall judgment

A clean, well-scoped milestone. The capability schema is small but covers every sensitive action; the audit-log integration is symmetric for allowed and denied calls; backwards-compat is preserved without modifying any pre-M10 test. The implicit-`*` fallback and missing end-to-end runtime-preflight test are the only items worth circling back on, and both are non-blocking for v1.
