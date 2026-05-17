# Milestone 6 Review

Diff range: 2c4c4d0..e12ac69

## Blocking

- `src/daemon.zig:106-130` — Daemon does not own or start a `runtime.Supervisor`. `Worker.start()`/`Supervisor.ensureWorker` exist but no production code path constructs a Supervisor, calls `ensureWorker`, runs the worker thread, or invokes `reconcileOrphans` on startup. Plan step 6 (independent per-stack runtime loops) and step 10 (restart sweep before first tick) explicitly require this; plan acceptance criteria "Prompt items can run end-to-end through the fake adapter" and "Per-stack loops operate independently" are only demonstrated by tests that call `tickStack` directly. Without daemon-side wiring, milestone 7's real adapters will land into a runtime that nothing drives, and `stako daemon stop` cannot cleanly stop live subprocesses (no Supervisor → no `requestShutdown` chain → no SIGINT to children). The plan's "Restart and shutdown" step 10 is unfulfilled in production code.

## Non-blocking

- `src/sse.zig:89-104` — SSE serialization emits only `data: <json>\n\n`. `todos/design_web_view.md` lines 41-54 calls for `event: <kind>\ndata: <json>\n\n`. The kind is recoverable from the payload, so EventSource still works in dispatch-by-message mode, but the design's `event:` lane is missing.
- `src/mutations.zig:610` — terminal `runtime_transition → completed/failed/canceled` audits as `dispatch_harness`. Per `design_errors_and_audit.md` line 136, `dispatch_harness` is for the running transition. Terminal harness completion has no canonical audit action defined yet; the implementer reused dispatch_harness so the audit isn't lost, but the action slug is technically incorrect on terminal lines.
- `src/session_manager.zig:338-364` — `cancelAndEscalate` has no production-default grace timings (every caller in the codebase is a test). Design says 5s SIGINT grace; once the daemon wires the Supervisor, real values need to be plumbed (default constants or config keys).
- `src/session_manager.zig:346-364` — Small TOCTOU window between `isAlive` and `sendSigterm`/`sendSigkill`. If the reaped child's PID is recycled by the kernel after `child.wait()` returns and before we signal, we could signal a wrong process. Acceptable for v1; document the assumption.
- `src/runtime.zig:188-221` — sleep-elapsed transitions `queued → running → completed` because `state.zig` does not list `queued → completed` as valid. Functional but creates a spurious commit-skipped `running` flip and the audit/dispatch_harness log line, even though no subprocess actually runs. Cleaner: extend the state machine to allow `queued → completed` for sleep items, or special-case the sleep path.
- `/tmp/stako-test-*` directories from prior milestones still accumulate (CLI, daemon, mutation test scratches). The milestone-6 `stako-test-runtime/` scratch IS cleaned. Pre-existing; not introduced by M6 but worth noting since the test-strategy doc says no leftovers.

## Deferred-confirmed

1. **Per-stack worker thread auto-start** — **BLOCKING** (see above). The plan's step 6 is "Implement independent per-stack runtime loops"; the algorithm exists but it does not run as part of the daemon. M7 will plug real adapters into a runtime that the daemon does not actually drive. Test-side `tickStack` calls do not satisfy "the runtime runs autonomously."
2. **Sleep timer arm path** — **deferred-confirmed**. The plan step 8 says "If `until > now`, transition to `paused`, arm that stack loop's timer, then transition `paused → queued → completed` when elapsed." `design_runtime_loop.md` "Sleep Items" (lines 82-92) supports the same path. The implementer's "leave queued, re-evaluate on next tick" is a defensible simplification only IF a worker is alive and being woken — which it currently is not (see issue 1). Once workers run, future-dated sleep items will not progress without external `tickStack` triggers. Acceptable as v1 simplification IF the timer wheel is the very next step after worker wiring; otherwise it becomes a correctness gap.
3. **Continuity (chain) resolution** — **deferred-confirmed**. The numbered steps in `impl/06_runtime_core.md` do not include continuity resolution. `design_runtime_loop.md` "Continuity Resolution" (lines 72-80) describes the feature, and `design_runtime_loop.md`'s own implementation plan step 6 lists it ("Wire continuity resolution") — but that's the design-doc's plan, not the milestone's. M6's plan step 2 mentions the adapter's `session_resume_id?` parameter but no step wires it up. Legitimately deferred to a later milestone (likely M7 when claude/codex adapters need it).

## Acceptance criteria

- Prompt items can run end-to-end through the fake adapter and produce normalized `transcript.jsonl` — MET via test `runtime: end-to-end fake run produces transcript and completes item`. Algorithmically correct, but only when test code calls `tickStack` directly.
- Per-stack loops operate independently while respecting the daemon's global session limit — PARTIALLY MET. Tests show `tickStack` per-stack independence and `max_concurrent_total = 1` semaphore behavior. NOT MET as an end-to-end daemon property because the daemon doesn't own a Supervisor.
- Runtime files are gitignored daemon state, not tracked `meta.toml` — MET. `runtime_file.zig` writes under `.stako/runtime/` and the M2 init step already gitignores `.stako/`.
- Terminal tracked artifacts commit as one harness-completion commit per item — MET. `mutation_queue.zig:292-300` skips commits for runtime `→ running`; terminal transitions commit normally. The `dispatch_harness` audit action is reused for terminal transitions (non-blocking nit above).
- SSE receives the same normalized event schema as transcripts — MET (same `events.writeEvent`). Missing `event:` lane is a non-blocking deviation.
- A paused stack does not dispatch new work, and other stacks continue — MET via tests `runtime: paused stack does NOT dispatch` and `runtime: two stacks dispatch independently`.
- No Claude/Codex/Gemini adapter behavior is required in this milestone — MET.
