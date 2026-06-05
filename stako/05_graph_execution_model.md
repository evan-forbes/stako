# Graph Execution Model Design

> Updated by `09_unified_authoring_model.md`: the graph lives in authored
> `plan.toml`; `blocked_by` is the only edge; status is computed from
> `plan.toml`, filesystem markers, and append-only `events.jsonl`.

## Problem

Stako currently behaves like an insertion-ordered queue with dependency checks.
That is too weak for multi-agent work. A stack should execute as a graph: prompt
nodes target thread lanes, blockers define readiness, and the scheduler selects
ready work instead of stalling on the first blocked node.

## Goals

- Treat `[[prompt]].name` as the graph node id.
- Treat `blocked_by` as the only blocking edge and input edge.
- Keep per-thread serialization.
- Allow ready later nodes to run when an earlier node is blocked.
- Detect cycles and missing dependencies before delivery.
- Make status graph-native and machine-readable.

## Core Decisions

- `blocked_by = ["x"]` means the target waits for `x` and receives
  `runs/x/result.md` in the rendered prompt.
- There is no persisted `order`. A node's position in `plan.toml` is only the
  deterministic tie-breaker among ready nodes on the same idle thread.
- Same-thread serialization is enforced by thread occupancy: a thread with a
  running node cannot receive another node.
- A blocked queued node must not prevent a later ready queued node on the same
  idle thread from running.
- Cycle and missing-edge checks run at every graph mutation boundary.
- Stored runtime state stays small. `queued` plus computed readiness is better
  than persisting temporary blocked states.

## Readiness States

Readiness is computed from the full graph:

| Computed State | Meaning |
|---|---|
| `ready` | All blockers are completed and the thread is idle. |
| `waiting_thread` | Blockers are complete but another node is running on the same thread. |
| `blocked_dependency` | One or more blockers are not completed. |
| `invalid_graph` | A blocker is missing or a cycle exists. |
| `running` | A delivered event exists without a completion/failure. |
| `completed` | `done` and `result.md` exist. |
| `failed` | Runtime failure was observed or logged. |
| `terminal_blocked` | Cannot run because an upstream dependency failed. |

## Scheduler Semantics

For each idle thread, dispatch the earliest-emitted queued node that is ready.
Skip blocked queued nodes and continue scanning for another ready node on that
thread. If the thread already has a running node, dispatch nothing for it.

Pseudo-code:

```text
for each known thread:
  if any node on thread is running:
    continue

  candidates = queued nodes for thread in plan emit order
  for candidate in candidates:
    readiness = compute_readiness(candidate)
    if readiness == ready:
      deliver(candidate)
      break
```

This preserves deterministic execution while avoiding the prior follow-up
deadlock class.

## Status Model

`stako status` should expose computed readiness:

```text
queued ready
queued blocked: blocked_by 035-flup-domain-separation
queued invalid: missing dependency 090-final-review
queued invalid: cycle detected through 040-freeze
```

`stako status --json` should include enough data for CLI, scripts, and deferred
UI work:

```json
{
  "name": "040-freeze",
  "thread": "builder",
  "status": "queued",
  "readiness": "blocked_dependency",
  "blocked_by": ["035-flup-domain-separation"],
  "result_path": "runs/040-freeze/result.md",
  "done_path": "runs/040-freeze/done"
}
```

## Graph Mutations

Stako needs atomic graph mutations:

- Append node.
- Remove queued node.
- Add edge by adding a source node to target `blocked_by`.
- Remove edge from a queued target.
- Retry failed or terminally blocked node.

Every mutation validates:

- Unique node names.
- Existing edge endpoints.
- No cycles.
- Thread exists.
- Action is supported.
- Target status allows the requested mutation.

## API Shape

Add a graph layer rather than scattering readiness logic:

```text
plan.load() -> Plan
graph.build(plan, events, markers) -> Graph
graph.validate(Graph) -> []ValidationError
graph.readiness(Graph, node_name) -> Readiness
graph.readyByThread(Graph) -> []ReadyDispatch
```

The graph model does not read zellij panes. It consumes `plan.toml`,
`events.jsonl`, and completion/result markers.

## Deferred UI Implications

The deferred TUI can show:

- Nodes grouped by thread.
- `blocked_by` edges.
- Ready nodes.
- Blocked reasons.
- Follow-up injections and gated targets.
- Result path availability.

The UI should consume `status --json` or a graph JSON command. It should not own
readiness logic.

## Implementation Plan

1. Parse `plan.toml` into threads, nodes, and `blocked_by` edges.
2. Build graph validation for duplicate names, missing threads, missing blockers,
   and cycles.
3. Compute node status from `events.jsonl` plus `runs/<node>/done` and
   `runs/<node>/result.md`.
4. Implement readiness states over the computed graph.
5. Replace same-thread queue gating with first-ready-per-idle-thread scheduling.
6. Print readiness and blockers in `stako status`.
7. Add `stako status --json`.
8. Reuse the same graph layer in `start`, `render`, `inject`, and watch mode.

## Test Plan

- Scheduler dispatches a later ready node on the same thread when an earlier
  queued node is blocked.
- Scheduler dispatches nothing on a thread with any running node.
- `blocked_by` waits and renders blocker `result.md` paths.
- Missing blockers report `invalid_graph` and are rejected by mutations.
- Cycle validation rejects `a -> b -> a`.
- Status output includes exact blocking node names.
- JSON status includes nodes, readiness, thread, status, result path, done path,
  and blocker names.

## Acceptance Criteria

- A blocked node early in plan order does not prevent a later ready node on the
  same thread from running.
- The prior injected-FLUP deadlock is covered by a regression test.
- Status explains each queued node's readiness.
- Graph validation rejects cycles before the runner can enter a bad state.
- Deferred UI work can render graph nodes and dependencies from structured
  output without duplicating scheduler logic.
