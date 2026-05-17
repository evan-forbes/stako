# Follow-Up — Test Coverage for `daemon.zig` and `session_manager.zig`

Picks up the gaps surfaced by `_audit_summary.md` that the per-milestone audit passes deferred. Sequenced to start **after** the in-flight `daemon.zig` refactor lands — these tests should pin behavior of the post-refactor code, not chase a moving target.

Baseline at start: 462/462 (matches `_audit_summary.md`). Target: ≥495/495 (+33), all green with `zig build test --summary all`.

## Why these and not others

`_audit_summary.md` lists only three substantive coverage gaps remaining:

1. **`daemon.zig` (~2,327 LOC, 10 in-file tests)** — biggest, most-depended-on, least-directly-tested module. Refactor sits exactly here.
2. **`session_manager.zig` (723 LOC, 0 in-file tests)** — sole owner of live child-process state, hit only transitively. Carries one known correctness bug (unbounded line buffer).
3. **Dispatch denial audit-log line** — `runtime.zig:235-247` logs `outcome=allowed` for transitions the policy callback rejected. One-line bug, but it has no E2E test pinning the correct outcome.

Gemini adapter is intentionally out of scope (deferred at the milestone level).

## Sequencing

| # | Pass | Pre-req | Adds tests | Notes |
|---|---|---|---|---|
| F1 | Dispatch denial audit-log fix + E2E | none | +3 | Smallest, validates the runtime↔policy seam survives the refactor. Do first to catch any regressions the refactor introduced here. |
| F2 | `session_manager.zig` baseline unit + line-buffer cap | F1 | +12 | Includes the OOM-risk fix (cap + drop-with-counter). |
| F3 | `daemon.zig` HTTP plumbing coverage | refactor merged | +12 | Targets the post-refactor module shape. |
| F4 | `daemon.zig` SSE gate matrix | F3 | +6 | Small standalone matrix; folded after F3 to share fixtures. |

Each pass = one audit/findings subagent followed by one fix/implement subagent, mirroring the existing milestone audit pattern. Land each pass as its own commit so they can be reverted independently.

## F1 — Dispatch denial audit-log fix

**Bug.** `src/runtime.zig:235-247` writes `outcome=allowed` to the audit log even when `runtimePolicyCheck` returned a denial; only the transition is suppressed.

**Steps.**
1. Audit subagent: trace the runtime tick path from `runtime.zig:235` through `policy.evaluate` to the audit writer. Confirm the denial branch and identify which `audit.event` enum value should be emitted (likely the same one used by `auditDenied` in `daemon.zig`).
2. Fix subagent:
   - Switch the denial branch to emit `outcome=denied` with the reason string from `policy.evaluate`.
   - Add `test/runtime_tests.zig` cases:
     - **dispatch_denied_emits_denied_audit_line**: policy denies a queued→running transition; assert one denied line, zero allowed lines, item stays queued.
     - **dispatch_allowed_still_emits_allowed**: regression guard.
     - **dispatch_denial_does_not_break_supervisor_tick**: subsequent ticks still process other items.

**Acceptance.** +3 tests; grep for `outcome=allowed` in `runtime.zig` returns zero matches inside denial branches; smoke stack still completes end-to-end.

## F2 — `session_manager.zig` baseline + OOM-risk fix

**Bugs / gaps.** Zero in-file tests. `_audit_summary.md` flags the unbounded stdout/stderr line buffer.

**Steps.**
1. Audit subagent: map every public function in `session_manager.zig` to which test currently exercises it (likely only `runtime_tests.zig` transitively). Identify the line-buffer growth path and pick a cap (proposal: 1 MiB per stream per session, then drop with a counter exposed via the existing transcript/audit channel).
2. Fix subagent — add `src/session_manager.zig` in-file tests:
   - **spawn_and_reap_clean_exit** (fake harness, asserts session state transitions)
   - **spawn_and_reap_nonzero_exit**
   - **sigint_then_sigterm_escalation** (already covered via runtime; add a *direct* unit test)
   - **stdout_line_under_cap_passes_through**
   - **stdout_line_at_cap_truncates_with_counter** ← pins the fix
   - **stderr_line_at_cap_truncates_with_counter**
   - **partial_line_at_eof_is_flushed**
   - **utf8_split_across_read_boundary**
   - **child_writes_then_immediately_exits** (race: read drain vs. reap)
   - **concurrent_sessions_independent** (two sessions, no cross-talk in line buffers)
   - **deinit_kills_running_child**
   - **deinit_idempotent**
3. Implement the cap. Reuse the existing `audit.Writer` for the drop counter to avoid a new channel.

**Acceptance.** +12 tests; in-file tests run via `zig build test --summary all`; stress test from M5/B2 still flake-free (sanity, since we're touching adjacent code).

## F3 — `daemon.zig` HTTP plumbing

**Run only after the in-flight refactor merges.** Pin behavior of the post-refactor module, not the pre-refactor one.

**Steps.**
1. Audit subagent: re-inventory `daemon.zig` after the refactor — which functions moved, which routes are now table-driven, what's still in the giant switch. Re-confirm the gap list still applies.
2. Fix subagent — add to `test/daemon_tests.zig` (or new `test/daemon_plumbing_tests.zig` if the file is already large):
   - **chunked_transfer_encoding_request_body** (POST with `Transfer-Encoding: chunked`)
   - **chunked_transfer_encoding_rejected_when_unsupported** (if we don't support it, pin the 411/501)
   - **stale_pidfile_recovered_on_startup** (write a pidfile pointing at a dead PID, daemon starts cleanly)
   - **stale_pidfile_with_live_unrelated_pid_refuses_start**
   - **pidfile_removed_on_clean_exit** (regression for M3/B2)
   - **provider_status_cache_hit_E2E** (two `GET /providers/<x>/status` calls; second served from cache; assert ≤1 underlying probe)
   - **provider_status_cache_invalidated_on_credentials_change**
   - **auth_missing_preflight_returns_structured_error_E2E** (full request → response; not just the policy unit test)
   - **auth_missing_preflight_does_not_dispatch** (item stays queued; no audit-allowed line)
   - **content_length_zero_post_handled**
   - **request_larger_than_buffer_rejected_cleanly**
   - **header_case_insensitive_lookup** (regression guard for any refactor)

**Acceptance.** +12 tests; routes table re-inventoried in the audit subagent's notes; no new `daemon.zig:NNN` deep-link comments in test files (tests should bind to public behavior, not line numbers).

## F4 — SSE `enable_sse` gate matrix

**Gap.** SSE gate only tested for `running` items. Behavior for `queued`/`blocked`/`paused` is unspecified.

**Steps.**
1. First, a short design decision (not a subagent): what *should* the gate return for non-running statuses? Two reasonable choices: (a) 404 — only running items have streams, or (b) 200 with `event: status\ndata: {status}\n\n` snapshot then close. Pick (a) unless the HTML view depends on (b); confirm by grepping `html.zig` for SSE consumer.
2. Fix subagent — add to `test/runtime_tests.zig` SSE section:
   - **sse_for_queued_item_returns_404** (or chosen behavior)
   - **sse_for_blocked_item_returns_404**
   - **sse_for_paused_item_returns_404**
   - **sse_for_completed_item_returns_404**
   - **sse_for_failed_item_returns_404**
   - **sse_for_running_item_streams** (regression guard for the existing happy path)

**Acceptance.** +6 tests; one design line in this file recording the chosen gate behavior and why.

## Out of scope

- Gemini adapter coverage (deferred at the milestone level).
- Stack/StackRegistry struct direct tests — adequately covered transitively via mutations + HTTP layer per the audit.
- New CI configuration. The existing `zig build test` step picks up everything added here.
- Coverage tooling / line-coverage targets. Decisions stay per-module, per `00_test_strategy.md`.

## Rollback plan

Each pass is one commit. If F3 turns out to be chasing the refactor, revert F3's commit; F1/F2/F4 are independent and stay.
