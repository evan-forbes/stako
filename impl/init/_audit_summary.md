# Audit Pass — End-of-Run Summary

Run window: 2026-05-11.
Baseline: `e67229d` (chore: review feedback) — 350/350 tests.
Final: `abd2ada` (milestone 10 audit: status row) — **462/462 tests** (+112).

Each milestone got one **full-module audit** subagent followed by one **fix** subagent. No retry was needed — every fix subagent landed cleanly on the first pass. Audits live in `impl/_audit_NN.md`; fix commits land between status rows in the git log.

## Findings by milestone

| #  | Module surface                                | Blocking | Important (fix/total) | Minor (fix/total) | Coverage (add/found) | Tests +N | Fix SHA   |
|----|-----------------------------------------------|----------|-----------------------|-------------------|----------------------|----------|-----------|
| 1  | toml, state, item                             | 0        | 3/3                   | 1/11              | 6/7                  | +8       | `36dd8e5` |
| 2  | cli, init, stack_config, main                 | **2**    | 4/5                   | 3/10              | 10/10                | +15      | `5f8b0e5` |
| 3  | config, local_token, errors, storage, daemon  | **2**    | 3/8                   | 0/14              | 10/10                | +16      | `42bf5b1` |
| 4  | cli_stack, http_client                        | 0        | 6/6                   | 5/11              | 9/12                 | +13      | `8cbaef7` |
| 5  | audit, vcs, mutations, mutation_queue         | **2**    | 3/8                   | 0/12              | 5/11                 | +5       | `031493c` |
| 6  | events, adapter, fake_adapter, transcript, sse, runtime_file, session_manager, runtime | 0 | 4/4 | 0/11 | 11/10 (incl. fixture) | +11 | `0889fbb` |
| 7  | claude_adapter, codex_adapter, harness_dispatch | 0      | 4/5                   | 0/8               | 11/11                | +18      | `9e61339` |
| 8  | provider_status, cli_auth                     | 0        | 3/3                   | 2/10              | 7/9                  | +11      | `3ec4b2d` |
| 9  | html (+ fixtures)                             | 0        | 1/3                   | 0/7               | 8/8 + 4 fixtures     | +9       | `39234aa` |
| 10 | policy (+ defense-in-depth daemon.zig:922)    | 0        | 1/3                   | 0/7               | 5/6                  | +6       | `9f4f59b` |
| **Total** |                                       | **6**    | **32/48**             | **11/101**        | **82/94**            | **+112** |           |

All 6 blocking findings were fixed.

## What the blocking findings actually were

- **M2/B1** — `parsed.yes or true` tautology: `--yes` flag was discarded; non-interactive mode was the only reachable path despite the help text saying otherwise.
- **M2/B2** — `--quiet` parsed and threaded through but never honored in `printReport`.
- **M3/B1** — Form-body buffer leak: `catch return null` after `formUrlDecode` skipped the `errdefer` for the 256 KiB body buffer; any malformed `%XX` in `_token` leaked the body.
- **M3/B2** — PID file leaked on every error path between `writePidFile` and successful return; `Daemon.deinit` never removed it on clean exit either.
- **M5/B1** — Working-tree rollback was a misnomer: `vcs.rollbackPaths` only `git reset HEAD --`d the index. The mutator's on-disk file writes were never reverted, so retries hit `vcs_dirty`/`already_exists` with no recovery path.
- **M5/B2** — `audit.Writer` documented as single-writer but called concurrently from 4+ threads (queue worker, session manager spawn, HTTP accept for `auditDenied`, daemon main) — no mutex, no `O_APPEND`. Lines could interleave under load.

The 8-thread × 32-append stress test added for M5/B2 ran 10 consecutive iterations without a single interleave or flake.

## Other notable correctness fixes (Important tier)

- **M3** — Loopback host check moved before any disk writes; `local_token` re-`fchmod`'d to 0600 on every load; 405 routing for `POST /healthz` etc.
- **M4** — Transport read-loop now surfaces non-EOF errors as `TransportError` / `TransportTimeout` instead of treating them as clean EOF. `SO_RCVTIMEO` per-read with a 10s default. Config-load swallow narrowed (malformed TOML now propagates). `renderStackList` swapped substring grep for `std.json.parseFromSlice`.
- **M5** — `Queue.audit_writer` made `?*Writer` instead of `undefined`; pre-existing leak in `rollbackPaths` (git-reset output slice never freed) fixed alongside.
- **M6** — Spawn-cleanup ownership flags (`transcript_in_local`, `outcome_in_local`, `sess_owned`) eliminated a double-free on the `sessions.append` OOM path. `mutation_queue` got a `post_commit_fn` hook; the daemon installs `Supervisor.wakeAllWorkers()` so transitions don't wait up to 100 ms on the poll cycle. **SSE flake**: confirmed `std.http.Server` is purely synchronous (no background fd interaction); applied defense-in-depth flush of the SSE 200-OK head through `req.server.out` before the worker thread takes over. 30 pre-fix runs had 1 flake; 30 + 10 post-fix runs had 0.
- **M7** — `findStringValue` was first-positional (depth-unaware): a buried `"message"` inside a nested object was returned before the top-level `"message"`. Reworked to depth-1-only walks. Claude `Bash` synthetic `command_executed` events were emitting `exit:0` placeholder before the real `tool_result` arrived — now deferred until the matching `tool_result` and `is_error` is mapped to exit code.
- **M9** — `renderTranscript` silently dropped unparseable lines; now emits an `<li class="transcript-skipped">(N unparseable line(s) skipped)</li>` summary so corrupt transcripts don't render identically to empty ones.
- **M10** — `runtimePolicyCheck` defaulted to **allow** on null context. Currently unreachable, but the wrong default for an authz callback. Flipped to deny.

## Security posture

- **M3** — Bearer token storage tightened (0600 enforced on every load).
- **M9** — XSS audit: 39 dynamic insertions across `renderIndex`/`renderStack`/`renderItem`/`renderTranscript`/the inline SSE bootstrap. All 39 escape; the hostile-token test directly exercises defense-in-depth. `_token` is hex-by-construction, escaped on render, never leaked into URLs or logs.
- **M10** — Fail-closed analysis: every error branch in `policy.evaluate` returns deny. Implicit-`*` fallback (for backwards compat with un-declared `[identity.local]`) only engages when the bearer token is already verified; fresh `stako init` always writes the explicit block so new installs never use the shim. UAR scan (a relic of M4's prior bug pattern) explicitly performed in M4 audit — clean.

## Cross-milestone debt surfaced

These items were flagged during one audit but live in another milestone's module surface; per the one-pass scope rule, they were not fixed:

| Surfaced in | Lives in              | Item                                                              |
|-------------|-----------------------|-------------------------------------------------------------------|
| M4          | M3 (daemon)           | Stale-pid integration test (would require fork/exec of installed binary) |
| M4          | M3 (daemon)           | Chunked transfer-encoding end-to-end (daemon only Content-Lengths today) |
| M5          | cross-cutting         | Errdefer leak audit across 6 mutator functions (OOM-only) |
| M5          | cross-cutting         | Dead `vcs_conflict` error variant (touches daemon error mapping) |
| M7          | M6 (session_manager)  | **Unbounded stdout/stderr line buffer** — real OOM risk if a vendor CLI emits a multi-MB line; cap at 1 MiB and emit `error_event` when exceeded |
| M8          | M6 (runtime)          | `runtime.providerStatus` cache E2E test                            |
| M8          | M6 (runtime)          | `auth_missing` preflight E2E test                                  |
| M9          | M3 (daemon)           | CSP `unsafe-inline` rationale comment near `daemon.zig:1241`       |
| M9          | M3 (daemon)           | `enable_sse` gate widening (only fires for `running` items today; queued/blocked/paused on page open don't get live updates) at `daemon.zig:1385` |
| M10         | M6 (runtime)          | Dispatch denial audit-log entry: `runtime.zig:235-247` logs `outcome=allowed` for blocked transitions; plan step 5 expects a parallel `denied` line |
| M10         | M6 (runtime)          | E2E test of `runtimePolicyCheck` callback being wired and invoked through a real supervisor tick |

The pattern: cross-cutting debt clusters in **session_manager / runtime / daemon** — the three modules with the most consumers. A focused follow-up pass on those three would clear most of the deferred important items.

## Skipped Minor findings

89 of 101 Minor findings were left alone — they are docstring polish, single-line naming nits, micro-DRY opportunities, and similar low-value style work. They live in the individual `_audit_NN.md` docs if anyone wants to triage them later, but they aren't worth burning attention on individually.

## Process notes (for future audit passes)

- **Full-module audit was the right depth.** The audit subagents found real bugs that the original diff-only reviews missed — the M5 rollback gap and M5 audit race were both in code that had been "reviewed" during initial milestone construction, but only emerged when an auditor traced execution end-to-end.
- **Single-pass fix worked.** No retry-fix subagent was needed. The audit docs were structured enough that fix subagents could act on them without further guidance.
- **Cross-milestone discipline mattered.** The "stay inside this milestone's modules" rule prevented the loop from sprawling. The cross-cutting debt list above is the durable record of what got pushed.
- **Context budget held.** Orchestrator carried ~20 subagent reports (~400 tokens each) plus tool overhead — well under context limits, no compaction. State-in-files (audit docs, status table, git history) absorbed everything else.
- **Test growth**: 350 → 462 (+112, +32%) without breaking any existing test. Heavier coverage on negative paths, concurrency stress, and snapshot fixtures.
