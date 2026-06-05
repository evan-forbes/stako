# Stako Roadmap Summary

## Purpose

This directory now has one active architecture and one active implementation
sequence. `09_unified_authoring_model.md` is the source of truth for the design:
a stack is authored as a single `plan.toml` graph, runtime state is computed from
filesystem markers and `events.jsonl`, and follow-ups mutate that one graph.

The deferred folder contains useful follow-on work that should not shape the
first implementation pass.

## Active Docs

| Doc | Role |
|---|---|
| `01_followup_injection.md` | Safe graph mutation and agent-created follow-ups. |
| `02_prompt_folder_workflow.md` | Folder-first `plan.toml` workflow and planner behavior. |
| `04_directory_worktree_model.md` | Path roles: prompt folder, stack root, agent cwd, worktrees, artifact roots. |
| `05_graph_execution_model.md` | Readiness and scheduling semantics over the graph. |
| `06_runtime_reliability_backlog.md` | Runtime fixes that matter before UI work. |
| `07_python_plan_api.md` | Python authoring helper that emits `plan.toml`. |
| `09_unified_authoring_model.md` | Canonical architecture: one graph, one edge, computed status. |
| `10_unified_implementation_plan.md` | Engineering sequence for landing the active design. |

## Deferred Docs

| Doc | Why Deferred |
|---|---|
| `deferred/03_zellij_tui_integration.md` | Needs stable planner, status JSON, mutation APIs, and runner metadata first. |
| `deferred/08_harness_model_support.md` | Useful, but not required for the graph/folder/runtime core. Keep current required `command` first; add `model`/nickname resolution later. |

## Cohesion Review

The plans now align on these decisions:

- The graph is authored once in `plan.toml`.
- `blocked_by` is the only active dependency edge. It means both "wait for this
  node" and "render this node's `result.md` path as input."
- Prompt body files are library content. They do not carry dependency front
  matter.
- Runtime status is computed from `plan.toml`, `runs/<node>/done`,
  `runs/<node>/result.md`, and `events.jsonl`.
- `events.jsonl` is append-only audit history, not a second graph.
- Path roles live in the `plan.toml` header and are persisted as resolved
  absolute values when a stack is created.
- Follow-up injection appends a prompt node to `plan.toml` and may add that node
  to a queued target's `blocked_by`.
- The current `command` field remains the active thread harness field. Optional
  `model`, harness nicknames, Gemini, OpenCode, and picker UI are deferred.
- TUI work is presentation and control-plane work. It starts after `status
  --json`, mutation commands, watch mode, and zellij metadata are stable.

## Conflicts Resolved

Older drafts used `after`, `inputs`, `order`, per-run `meta.toml`, and optional
`stack.toml` manifests. Those are no longer active design choices.

Mapping:

| Older Idea | Active Replacement |
|---|---|
| Prompt front matter `after` | `blocked_by` in `plan.toml` |
| Prompt front matter `inputs` | `blocked_by` in `plan.toml`; input paths rendered from blockers |
| Insertion `order` | emit order in `plan.toml` only as a tie-breaker |
| Per-run `meta.toml` graph copy | no graph copy; compute from `plan.toml` and markers |
| `stack.toml` plus prompt files | `plan.toml` as the folder manifest and graph |
| TUI-owned mutations | CLI/store mutation API first; TUI calls it later |
| Harness/model resolver in core milestone | deferred after graph/folder/runtime core |

## Source Inputs

- Current Stako model: a stack is a prompt queue, a thread is a long-lived agent
  session in a zellij tab, and durable handoff is through
  `runs/<id>/result.md`.
- User workflow goal: point Stako at a folder of prompts, infer stack
  name/root/cwd, then optionally override with flags.
- Prior-run notes:
  `/home/evan/src/valar/zakura-p2p-stako/stako/issues_and_improvements.md`.

## Implementation Shape

The highest-value path is:

1. Define and validate `plan.toml`.
2. Build a folder planner that resolves paths and previews the graph.
3. Compute status/readiness from plan + filesystem + events.
4. Render prompts from plan nodes and write `runs/<node>/rendered.md`.
5. Schedule the first ready node per idle thread.
6. Add safe graph mutation and `stako inject`.
7. Add resident runtime behavior: watch, PID, stop, and clear idle reasons.
8. Add the Python authoring helper as a plan emitter.
9. Revisit deferred TUI and harness/model work.

See `10_unified_implementation_plan.md` for the detailed engineering breakdown.

## Acceptance Criteria

- `stako plan <prompt-folder>` validates a `plan.toml`, resolves path roles, and
  explains graph problems before runtime state is created.
- `stako new <prompt-folder>` creates a stack with the correct stack root and
  agent cwd, not the prompt folder by accident.
- `stako status` explains queued readiness and blockers.
- A blocked node early in the plan does not prevent a later ready node on the
  same idle thread from running.
- Every delivered prompt is captured in `runs/<node>/rendered.md` and referenced
  from `events.jsonl`.
- An agent can create a follow-up under `flups/` and use `stako inject` to gate a
  queued target without manual metadata edits.
- Completed stacks can receive post-stack follow-up nodes.
