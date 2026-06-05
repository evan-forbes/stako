# Unified Implementation Plan

## Purpose

This plan turns the active design docs into an engineering sequence. It assumes
`09_unified_authoring_model.md` is the architecture source of truth and treats
`deferred/03_zellij_tui_integration.md` and
`deferred/08_harness_model_support.md` as later work.

The implementation should land in small, testable slices. Each slice should leave
the CLI usable and avoid requiring a TUI or model resolver to validate progress.

## Phase 0: Baseline and Test Harness

Goal: stand up fixtures and helpers for the new `plan.toml` model. There is no
backwards-compatibility path — the scattered-edge / front-matter flow is
replaced, not kept alongside.

Tasks:

1. Add fixtures for a minimal `plan.toml` stack.
2. Remove or quarantine the old scattered-edge / front-matter code paths so no
   new work targets them.
3. Add test helpers for temporary stack roots, fake prompt folders, fake zellij,
   and marker creation.
4. Add a small `events.jsonl` test helper that can append and replay events.

Exit criteria:

- Tests can create a scratch stack without touching the user's real Stako root.
- Fixtures cover ready, blocked, running, completed, and failed node states.
- No code path depends on the old front-matter graph format.

## Phase 1: Plan Schema and Validation

Goal: parse and validate the single graph.

Tasks:

1. Implement `plan.toml` parsing:
   - header: `name`, `cwd`/`agent_cwd`, `root`/`stack_root`, `prompt_folder`,
     `paths`
   - `[[thread]]`: `name`, required `command`, optional `default`
   - `[[prompt]]`: `name`, `thread`, `use`, `with`, `body`, `action`,
     `blocked_by`, `raw`, optional future-safe unknown fields
2. Validate:
   - unique thread names
   - unique node names
   - valid node and thread names
   - every node references an existing thread
   - every blocker references an existing node
   - no cycles
   - `action` is one of `new`, `clear`, `compact`
   - referenced body files exist
3. Keep parser and validator independent from zellij/runtime code.

Exit criteria:

- `zig build test` has focused tests for good plans, missing threads, missing
  blockers, duplicate names, cycles, invalid actions, and missing body files.
- No scheduler changes are required yet.

## Phase 2: Folder Planner and Path Model

Goal: make `stako plan <folder>` the shared dry-run path for creation and later
open/add flows.

Tasks:

1. Add planner data type containing:
   - resolved stack name
   - prompt folder
   - stack root
   - agent cwd
   - primary worktree
   - declared worktrees
   - artifact roots
   - parsed plan graph
   - warnings and validation errors
2. Implement deterministic path inference:
   - CLI flags override plan header
   - plan header overrides inference
   - prompt folders under `<repo>/stako/<stack>` infer `<repo>` as `agent_cwd`
   - org-level Stako roots can point at sibling worktrees
3. Add `stako plan <prompt-folder>` text output.
4. Add `stako plan <prompt-folder> --json`.
5. Add lightweight body-path warnings for suspicious relative paths.

Exit criteria:

- `stako plan` writes nothing.
- Plan output shows stack name, stack root, prompt folder, agent cwd, threads,
  nodes, blockers, and warnings.
- Prompt-folder-as-cwd mistakes are caught before runtime.

## Phase 3: Runtime Projection and Status

Goal: compute runtime state from plan, markers, and events.

Tasks:

1. Add `events.jsonl` append/replay support.
2. Define event types:
   - `runner_started`
   - `scheduled`
   - `delivered`
   - `completed`
   - `failed`
   - `injected`
   - `runner_stopped`
3. Compute node status:
   - `completed` from `done` plus `result.md`
   - `failed` from failure events or `done` without result
   - `running` from delivered-without-terminal event
   - `queued` otherwise
4. Compute thread occupancy from running nodes.
5. Add `stako status` over the computed projection.
6. Add `stako status --json`.

Exit criteria:

- Status does not rely on zellij pane text.
- Status explains ready, waiting-thread, blocked-dependency, invalid-graph,
  running, completed, failed, and terminal-blocked cases.
- JSON output is stable enough for scripts and future TUI work.

## Phase 4: Rendering and Delivery

Goal: make delivered bytes previewable and auditable.

Tasks:

1. Implement `stako render <stack> <node>`.
2. Compose rendered prompts in this order:
   - action
   - body from `use`, `with`, `body`, or thread `default`
   - input result paths derived from `blocked_by`
   - output contract for `result.md` and `done`
   - path and FLUP context when available
3. Write delivered bytes to `runs/<node>/rendered.md`.
4. Append `scheduled` and `delivered` events with rendered path, action, and
   input paths.
5. Add conservative delivery phases for action-bearing prompts:
   - action sent
   - prompt sent
   - running
   - delivery failed/timeout

Exit criteria:

- `stako render` output matches `runs/<node>/rendered.md`.
- Every delivered prompt has an event-log reference.
- Action-bearing prompts cannot silently lose the body without a delivery error.

## Phase 5: Scheduler

Goal: remove the prior follow-up deadlock class.

Tasks:

1. Build graph readiness from the runtime projection.
2. For each idle thread, scan queued nodes in plan emit order.
3. Deliver the first ready node and skip blocked nodes.
4. Ensure running nodes occupy their thread until terminal status.
5. Add regression tests for a blocked earlier node and a ready later node on the
   same thread.

Exit criteria:

- A blocked node early in plan order does not prevent a later ready node on the
  same idle thread from running.
- Completed blockers render their `result.md` paths into dependent prompts.

## Phase 6: Folder-First Creation and Add

Goal: create and extend stacks from prompt folders.

Tasks:

1. Implement `stako new <prompt-folder>`.
2. Implement `stako new <name> --from <prompt-folder>`.
3. Normalize and persist `plan.toml` under the stack root.
4. Prepare `runs/` lazily or eagerly without creating a second graph copy.
5. Implement `stako add <stack> <prompt-folder>` for explicit new nodes or plan
   fragments.
6. Fix the completed-stack add path so all-terminal stacks can receive new work.

Exit criteria:

- Folder-first creation is the default interactive workflow.
- Completed stacks can receive post-stack follow-ups without hanging.
- `flups/` is never auto-enqueued.

## Phase 7: Safe Graph Mutation and FLUPs

Goal: let agents and operators extend a running graph without manual edits.

Tasks:

1. Add stack-local mutation lock.
2. Add append-node helper.
3. Add queued-target `blocked_by` edit helper.
4. Implement `stako link <stack> <source-node> <target-node>`.
5. Implement `stako inject`.
6. Implement `stako flup` as the provenance-requiring shorthand.
7. Add runner wake behavior.
8. Render agent instructions for creating or reporting follow-ups.

Exit criteria:

- Injection before a queued target atomically updates the target blockers.
- Injection before a running/completed target fails clearly.
- Injected nodes appear in status with provenance/audit visibility.

## Phase 8: Resident Runtime

Goal: reduce babysitting and unsafe process handling.

Tasks:

1. Add `stako start --watch`.
2. Add `runner.pid` with stack identity, start time, and watch mode.
3. Add `stako stop <stack>` with stale PID and process-identity checks.
4. Wake on graph mutation and completion marker changes.
5. Print clear idle reasons in non-watch mode.

Exit criteria:

- Watch mode stays alive across idle intervals.
- Mutations and completions trigger scheduler passes.
- Operators can stop a runner without shell pattern matching.

## Phase 9: Python Plan API

Goal: provide an authoring helper once the folder-first path is real.

Tasks:

1. Implement the stdlib-only Python package.
2. Emit `plan.toml`, prompt-library files, and examples.
3. Add `dry_run` and argv-style CLI shell-out.
4. Add install target and README/skill docs.
5. Validate generated folders with `stako plan`.

Exit criteria:

- The example Python loop produces a folder accepted by `stako plan` and
  `stako new`.
- The Python package adds no runtime dependency to the Zig CLI.

## Deferred Phase A: Harness and Model Support

Source: `deferred/08_harness_model_support.md`.

Start this after phases 1-6 are stable. It should add optional `model`, harness
adapters, Gemini/OpenCode support, model nicknames, and argv-based launch without
changing graph semantics.

## Deferred Phase B: Zellij TUI

Source: `deferred/03_zellij_tui_integration.md`.

Start this after status JSON, mutation commands, watch mode, PID metadata, and
zellij session metadata are stable. The TUI should consume existing APIs and
never duplicate scheduler or mutation logic.

## Cross-Phase Test Requirements

Every Zig implementation phase should run:

1. `zig fmt src/ test/`
2. `make build`
3. `make test`

Correctness-sensitive graph/scheduler/mutation changes should also run:

```sh
zig build -Doptimize=ReleaseFast test
```

## Final Acceptance

- The graph is authored once in `plan.toml`.
- `blocked_by` is the only active edge.
- Folder planning prevents root/cwd/worktree confusion.
- Status is computed and explains blockers.
- Rendered prompts are previewable and auditable.
- The scheduler dispatches ready work per idle thread.
- Agents can inject required follow-ups safely.
- Runtime watch/stop behavior removes manual restart and unsafe kill patterns.
- Deferred TUI and harness/model plans remain available without blocking the core
  implementation.
