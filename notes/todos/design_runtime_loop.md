# Design Runtime Loop

## Scope

The runtime layer turns queued stack items into running subprocesses. In v1 it is organized as one independent worker loop per stack, plus a daemon-level supervisor that owns shared resources.

`design_execution_harness.md` covers what happens after spawn. `design_state_machine.md` covers status transitions. This doc covers the loop that triggers them.

## Decided

- One worker loop per stack directory under `<notes-root>/stacks/`.
- The daemon supervisor owns stack discovery, the shared session manager, the global concurrency semaphore, provider capability probes, and fanout of wake events to stack loops.
- Each stack loop is **event-driven**, not polling. It wakes on:
  - A committed mutation affecting that stack.
  - A subprocess exit for that stack.
  - A timer firing for that stack.
  - Daemon startup.
- Within a stack, the loop is lowest-ID-first and respects `stack.toml.paused`.
- Across stacks, independence is the default: one blocked/paused/busy stack does not delay another. The only shared limit is `max_concurrent_total`.

## Tick Algorithm

A stack-loop "tick" runs after any wake-up event for that stack:

```
on_stack_tick(stack):
    1. drain timer wheel: items whose sleep_until ≤ now → paused → queued
    2. if stack.paused: stop
    3. while stack.running_count < stack.max_concurrent_per_stack:
         if global running slots are full: stop
         next = first eligible queued item in this stack
         if next is None: stop
         decision = routing_preflight(next)
         if decision.blocked:
             apply_transition(next, "blocked", reason=decision.reason)
             continue
         acquire global slot
         spawn(next)                 # session manager spawns subprocess
         apply_transition(next, "running")
    4. arm next timer wake at min(item.sleep_until) over paused sleep items in this stack
```

This is intentionally simple. No priority queues, no scoring, no fairness bandaids. Stack independence is the fairness model.

## Wake Sources

| Source | Triggers | Behavior |
|---|---|---|
| Mutation queue | append / insert / status / pause / resume / stack-config change | Push wake event to the affected stack after mutation commits |
| Session manager | subprocess exit, transcript flush | Release global slot, then push wake event to that item's stack |
| Stack timer wheel | sleep-item timer | Push wake event to that stack |
| Daemon supervisor | startup, provider capability re-probe, stack creation | Start/wake relevant stack loops |

Each stack loop coalesces wake events: many wakes between ticks produce one tick.

## Routing Preflight

Called inside the tick, before `spawn`. Returns either `proceed(decision)` or `blocked(reason)`.

Checks, in order (short-circuit on first failure):

1. **Stack-level**: `allowed_harnesses` permits the routed harness. Reason: `harness_denied`.
2. **Workdir**: resolved workdir is on `config.toml`'s `workdir.allowlist`. Reason: `workdir_denied`.
3. **Harness availability**: adapter is enabled (e.g. gemini probe passed). Reason: `harness_unavailable`.
4. **Credentials**: required credential file exists and is readable. Reason: `auth_missing`.
5. **Model capability**: requested model is one the adapter recognizes (claude: claude-* models; codex: gpt-* / o-* models; gemini: gemini-* models). Reason: `model_unsupported`.
6. **Authorization** (milestone 10+): calling identity has `stack.<name>.run` and `provider.<provider>` capabilities. Reason: `capability_denied`.

A failed preflight transitions the item to `blocked` with the reason. The user can fix the underlying problem and `POST .../retry` back to `queued` to retry.

## Continuity Resolution

When the stack has `continuity = "chain"`:

- Before spawning item `N`, look at item `N-1` (last terminal item in the stack with the same routed harness).
- If `N-1` has a recorded `[result].session_id`, pass it to `adapter.invocation(..., session_resume_id = ...)`.
- If the prior item used a different harness, no resume; start fresh.

Item-level `[target].fresh_session = true` overrides and forces a fresh session even on a chained stack.

## Sleep Items

Sleep items (`kind = "sleep"`) follow this path:

1. Dequeued like any other item.
2. Preflight checks: workdir is irrelevant; only check that `[sleep].until` is present and parseable.
3. If `until > now`: transition to `paused`, record `until` on the item, arm the timer.
4. If `until ≤ now`: transition straight to `completed` with reason `already_elapsed`.
5. When the timer fires, transition `paused → queued`. Next tick re-dequeues; preflight passes; the item runs (no subprocess; it just transitions to `completed`).

Sleep items themselves do not spawn subprocesses. They are pure timers.

## Review Items

Review items run as ordinary harness subprocesses, but the loop has one extra rule:

- A `review` item runs in a fresh harness session regardless of the stack's `continuity` setting (so the reviewer's context is not polluted by the implementation transcript).
- Automatic follow-up insertion is deferred until the MCP follow-up. In core v1, review items produce transcripts only.

## Cancellation

A cancel request is a mutation that may delegate to the session manager:

- If the item is `queued`, `paused`, or `blocked`, the mutation queue applies `apply_transition(item, "canceled")` immediately.
- If the item is `running`, the mutation queue records the cancel request and asks the session manager to stop the subprocess. The terminal `running -> canceled` transition happens after the subprocess is reaped and transcript output is flushed.
- Adapter `on_exit` fires → session manager releases the global slot and pushes a wake event → the stack loop proceeds.

The stack loop does not directly send signals; it observes the post-cancel state.

## Restart

On daemon startup, before the loop ticks for the first time:

1. Recovery sweep (per `design_state_machine.md` and `design_execution_harness.md`): orphaned `running` items with runtime files → `failed`.
2. Sleep sweep per stack: re-queue any `paused` sleep whose `[sleep].until` has elapsed.
3. Provider capability probes owned by the daemon supervisor.
4. Start one loop per stack under `<notes-root>/stacks/`.
5. Send each stack one startup wake.

## Backpressure and Failure

- If `spawn` itself fails (e.g. workdir disappeared, file descriptor exhaustion), transition the item to `failed` with reason `spawn_failed` and proceed to the next tick. Do not block the loop.
- If a stack consistently produces blocking items, only that stack loop spends time on them. Other stack loops continue independently.

## Observability

Stack loops emit events on each significant action, mirroring `design_web_view.md`'s daemon-level SSE events:

- `routing_decision` — when an item leaves `queued`.
- `item_status` — every transition.
- `stack_paused` / `stack_resumed` — on stack-level pause changes.
- `loop_idle` — when a tick finishes with nothing to do. (Optional; useful for debugging.)

## Implementation Plan

1. Implement daemon supervisor: stack discovery, stack-loop lifecycle, shared session manager, global slot semaphore.
2. Implement per-stack wake channels.
3. Implement per-stack timer wheels for sleep items.
4. Implement the stack tick algorithm above against fixtures (no real subprocesses).
5. Wire routing preflight checks one at a time.
6. Wire continuity resolution.
7. Wire stack-level pause.
8. Wire restart recovery into the startup sequence.
8. Tests:
- Multiple independent stacks with mixed pause states.
   - Concurrency caps (per-stack + global).
   - Sleep timer firing.
   - Cancel mid-tick.
   - Restart with stale running items.

## Acceptance Criteria

- Stack loops are event-driven; idle CPU usage is near zero with no work pending.
- A mutation that adds a queued item wakes that stack's loop within the wake-coalescing window (≤ 50ms).
- Concurrency caps are honored.
- Sleep items advance through `queued → paused → queued → completed`.
- Cancellation of a `running` item does not stall the loop.
- Restart recovery completes before the first tick.
- A paused or blocked stack does not prevent another stack from dispatching work.

## Dependencies

- `design_state_machine.md` (transitions the loop applies)
- `design_execution_harness.md` (spawn, on_exit, capabilities)
- `design_stack_config.md` (paused, continuity, max_concurrent_per_stack)
- `design_stack_item_format.md` (item kinds, sleep timer field)
- `design_daemon.md` (single-writer queue)
- `design_errors_and_audit.md` (blocked reasons, audit log)
