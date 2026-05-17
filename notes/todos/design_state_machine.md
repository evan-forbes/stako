# Design State Machine

## Scope

The status values an item can take, the transitions between them, who is allowed to trigger each, and the side effects each transition produces. The status enum itself is defined in `design_stack_item_format.md`; this file is the canonical source for transition rules.

## Status Values

(Re-listed for convenience; canonical definitions live in `design_stack_item_format.md`.)

`queued` · `running` · `paused` · `blocked` · `failed` · `completed` · `canceled` · `superseded`

Terminal statuses: `completed`, `failed`, `canceled`, `superseded`.

## Transition Table

| From | To | Trigger | Side effects |
|---|---|---|---|
| `queued` | `running` | runtime loop picks the item | spawn subprocess; write `.stako/runtime/<stack>/<id>.toml`; emit `session_started` |
| `queued` | `blocked` | routing preflight fails | write `meta.toml.blocked_reason`; commit; emit `item_status` |
| `queued` | `canceled` | API call (user / agent) | commit |
| `queued` | `superseded` | API call (user / agent) | commit; record `superseded_by` in `meta.toml` |
| `queued` | `paused` | item kind = `sleep` whose timer hasn't expired at dequeue time | write `meta.toml.sleep_until` if not already; no spawn |
| `running` | `completed` | subprocess exits 0 and adapter `on_exit` reports clean | delete runtime file; write `[result]`; flush transcript; commit |
| `running` | `failed` | subprocess exits non-zero / adapter reports error | delete runtime file; write `[result]`; flush transcript; commit |
| `running` | `canceled` | API call (user / agent) | send SIGINT → grace → SIGTERM; delete runtime file; flush transcript; commit |
| `running` | `failed` | daemon restart with stale runtime file | delete runtime file; reason = `daemon_restart_orphan`; commit |
| `paused` | `queued` | sleep timer expires / external trigger fires | re-enqueue at original position |
| `paused` | `canceled` | API call | commit |
| `blocked` | `queued` | API call (user manually retries) | clear `blocked_reason`; commit |
| `blocked` | `canceled` | API call | commit |
| `failed` | (terminal) | — | no automatic retry; user can append a new item via the API |
| `completed` | (terminal) | — | — |
| `canceled` | (terminal) | — | — |
| `superseded` | (terminal) | — | — |

Anything not listed is **not a valid transition** and the daemon rejects it.

## Who Can Trigger What

| Transition trigger | Allowed callers |
|---|---|
| `queued → running` | Runtime loop only (internal). No API endpoint sets `running` directly. |
| `queued → blocked` | Runtime loop's preflight, or routing layer. Not user-settable. |
| `running → completed` | Adapter `on_exit` (internal). Not user-settable. |
| `running → failed` | Adapter `on_exit` or restart sweep (internal). Not user-settable. |
| `* → canceled` | User / authorized agent via `POST /items/{id}/cancel`. Always allowed from any non-terminal state. |
| `* → superseded` | User / authorized agent via `POST /items/{id}/supersede`. |
| `blocked → queued` | User / authorized agent via `POST /items/{id}/retry`. |
| `paused → queued` | Runtime loop (timer expiry) or API trigger fire. |

This means the API exposes only a subset of transitions to clients; the rest are daemon-internal.

## Stack-Level Pause

Stack-level `paused = true` (see `design_stack_config.md`) is **independent** of item status. A paused stack:

- Does not move items from `queued` to `running` (the loop skips it).
- Does **not** interrupt items already `running`. They run to completion.
- Does **not** change any item's status field.

To stop a `running` item on a paused stack, cancel that item explicitly.

## Concurrency and Ordering

- Within a stack, items dequeue in `id` ascending order, skipping non-`queued` items.
- A `queued` item is eligible to dequeue iff no item earlier in the queue is `queued` or `paused`. (`failed`/`completed`/`canceled`/`superseded` are skipped.)
- Exception: when `max_concurrent_per_stack > 1`, the loop may dequeue multiple eligible items at once.
- Across stacks, the loop is independent. Concurrency is bounded by `max_concurrent_total` from `config.toml`.

## Reasons / Diagnostic Fields

Transitions that carry a reason write it into `meta.toml`:

| Status | Field | Examples |
|---|---|---|
| `blocked` | `blocked_reason` | `harness_unavailable`, `auth_missing`, `workdir_denied`, `capability_denied`, `harness_denied`, `model_unsupported`, `harness_unsupported_capability`, `no_session_to_compact` |
| `failed` | `failed_reason` | `subprocess_nonzero_exit`, `adapter_parse_error`, `daemon_restart_orphan`, `timeout` |
| `canceled` | `canceled_by` | `user`, `agent:<identity>`, `system` |
| `superseded` | `superseded_by` | `<replacement-item-id>` |

All reasons are short slug strings (machine-parseable) plus an optional `*_message` long-form field for human consumption.

## Restart Recovery

On daemon startup (see `design_execution_harness.md` and `design_runtime_loop.md`):

1. Scan items with `status = "running"` and matching `.stako/runtime/<stack>/<id>.toml` files.
2. If the runtime file records a live PID that matches the recorded `started_at`, mark the item `failed` with reason `daemon_restart_orphan`. (v1 simplification; recoverable reattach is a later milestone.)
3. Delete the runtime file and commit terminal metadata.
4. Resume the runtime loop normally.

`paused` items with elapsed `sleep_until` are re-queued during the same sweep.

## Implementation Plan

1. Define `Status` enum and `Transition` table as Zig types.
2. Implement `apply_transition(item, new_status, reason?) -> Result` — the only path that writes status to disk.
3. Reject invalid transitions with a typed error.
4. Wire `apply_transition` into every code path that changes status (runtime loop, harness adapter, API mutation endpoints).
5. Tests: every valid transition + every invalid transition gets a test.

## Acceptance Criteria

- The daemon never writes a status field except through `apply_transition`.
- Invalid transitions return a clear error to the API caller and produce no disk write.
- Restart recovery deterministically reaches a consistent state.
- Reason fields are populated for every non-trivial transition.

## Dependencies

- `design_stack_item_format.md` (status enum + reason fields in `meta.toml`)
- `design_execution_harness.md` (running ↔ terminal transitions)
- `design_runtime_loop.md` (queued ↔ running, paused ↔ queued)
- `design_stack_config.md` (stack-level pause)
- `design_version_control.md` (commits per transition)
- `design_authorization.md` (who can call which API transitions)
