# Follow-Up Injection Design

> Updated by `09_unified_authoring_model.md`: injection appends a node to
> `plan.toml`, optionally adds that node to a queued target's `blocked_by`, and
> records the mutation in append-only `events.jsonl`. There is no `meta.toml`, no
> `injection.toml`, no `order`, and no separate `after`/`inputs` split.

## Problem

Agents often discover work that must happen before an existing queued prompt can
safely proceed. In prior runs these follow-ups, or FLUPs, were added manually and
then wired into existing prompts by hand. That failed because insertion order and
dependency order diverged.

Stako needs a first-class graph mutation mechanism that agents can call while a
stack is running.

## Goals

- Let agents add new prompt body files while a stack is running.
- Append a corresponding graph node to `plan.toml`.
- Gate an existing queued target by adding the new node to its `blocked_by`.
- Preserve durable content handoff through `runs/<node>/result.md`.
- Make injected work auditable: who inserted it, why, what it gates, and which
  result files it will feed through `blocked_by`.

## Non-Goals

- Do not retroactively gate prompts that are already delivered, running,
  completed, failed, or terminally blocked.
- Do not let agents hand-edit runtime state.
- Do not add a second metadata file for the graph.

## Proposed CLI

```sh
stako inject <stack> <prompt.md> --gates <target-node> --reason TEXT [--from <source-node>] [--thread NAME] [--root PATH]
stako flup <stack> <prompt.md> --from <source-node> --gates <target-node> --reason TEXT [--thread NAME] [--root PATH]
stako link <stack> <source-node> <target-node> [--root PATH]
```

`inject` is the agent-facing primitive:

1. Validate the prompt body file.
2. Choose or validate the target thread.
3. Append a new `[[prompt]]` node to `plan.toml`.
4. If `--from` is supplied, set the new node's `blocked_by` to include it.
5. Add the new node name to the queued gated target's `blocked_by`.
6. Append an audit event to `events.jsonl`.
7. Wake a watch runner if present, otherwise print the next operator command.

`flup` is an explicit alias for the common discovered-work case. It requires
`--from` and `--reason` so agent-created work carries provenance.

`link` is the low-level edge mutation: add `source-node` to `target-node`'s
`blocked_by`.

## Mutation Rules

| Operation | Allowed Target Status | Behavior |
|---|---|---|
| Add follow-up node | Any stack state | Appends a queued node with a unique name. |
| Gate target with follow-up | `queued` only | Adds follow-up name to target `blocked_by`. |
| Add post-stack follow-up | Completed source allowed | Appends a queued node blocked by completed work. |
| Gate running target | Never | Return `target_already_delivered`. |
| Gate completed target | Never | Suggest creating a new dependent prompt instead. |
| Mutate failed target | Not by default | A separate retry/unblock command should own this. |

The CLI should print exactly what changed:

```text
inserted 035-flup-domain-separation thread=implementer
linked 035-flup-domain-separation -> 040-freeze blocked_by=true
target 040-freeze now blocked_by=035-flup-domain-separation
```

## Prompt Node Shape

The injected prompt body lives under the prompt folder, usually `flups/`:

```text
stako/<stack>/flups/035-flup-domain-separation.md
```

Stako appends a graph node:

```toml
[[prompt]]
name = "035-flup-domain-separation"
thread = "implementer"
use = "flups/035-flup-domain-separation.md"
blocked_by = ["030-check"]

[prompt.provenance]
kind = "follow_up"
created_at = "2026-06-04T12:34:56Z"
created_by = "agent"
created_by_thread = "checker"
created_by_prompt = "030-check"
reason = "Domain separation must be settled before wire-format freeze."
gates = ["040-freeze"]
```

The event log records the same mutation in machine-readable form:

```jsonl
{"event":"injected","node":"035-flup-domain-separation","from":"030-check","gates":["040-freeze"],"reason":"Domain separation must be settled before wire-format freeze."}
```

## Scheduling Requirement

This feature depends on the graph scheduling change in
`05_graph_execution_model.md`: for each idle thread, Stako must scan for the
first ready node instead of stalling on the first queued node. With name-based
`blocked_by` edges and no persisted `order`, appending a follow-up cannot create
the old renumbering problem.

## Agent Workflow

When an agent discovers required follow-up work:

1. Write a prompt body under the prompt folder, usually `flups/<name>.md`.
2. Run:

   ```sh
   stako inject <stack> flups/<name>.md --from <current-node> --gates <target-node> --reason "<why>"
   ```

3. Mention the injected node in its own `result.md`.
4. If the follow-up is optional or post-stack, create a new dependent node rather
   than gating an existing target.

Agents should not hand-edit `plan.toml` directly unless the prompt explicitly
asks them to author a stack. If a required edge cannot be expressed with the CLI,
that is a Stako bug.

## Agent Context Delivery

Rendered prompts should include enough context for safe agent-side mutation:

- stack name
- stack root
- current node name
- current thread
- prompt folder
- `flups/` path
- whether agent-side mutation is allowed

Example contract text:

```text
If you discover required follow-up work before another queued prompt can run,
write a prompt under <prompt-folder>/flups/ and run:
stako inject <stack> <file> --root <root> --from <current-node> --gates <target-node> --reason <text>
```

If Stako does not know the prompt folder or agent-side mutations are disabled,
the contract should tell agents to report follow-ups in `result.md` for the
operator.

## Store Requirements

Injection needs store operations that current file-level linking does not
provide:

- read the plan by node name
- compute current node status from plan + events + markers
- append a new node
- update a queued node's `blocked_by`
- validate uniqueness, missing endpoints, cycles, and target status
- write the plan atomically
- append an audit event
- wake the runner if present

Atomicity should use a stack-local mutation lock and write-rename behavior for
`plan.toml`. If Stako cannot commit the full graph change, it should leave the
plan unchanged.

Unknown TOML preservation matters because `plan.toml` is user-authored. If a
lossless TOML writer is too large for the first version, limit mutation to
append-only node insertion plus simple queued-target `blocked_by` edits and
refuse complex rewrites until the writer can preserve unknown fields.

## Implementation Plan

1. Land `plan.toml` parsing, graph validation, computed status, and first-ready
   scheduling.
2. Add stack-local mutation locking.
3. Add store helpers for appending nodes and editing queued-node `blocked_by`.
4. Implement `stako link <stack> <source-node> <target-node>`.
5. Implement `stako inject` as a checked composition of append node plus link.
6. Record injection audit data in `events.jsonl` and optional node provenance.
7. Add runner wake behavior: signal a resident `--watch` runner when present;
   otherwise print `run stako start <stack>`.
8. Add agent prompt contract text that explains how to report or create FLUPs.

## Test Plan

- Injecting before a queued target updates target `blocked_by` atomically.
- Injecting before a running target fails with `target_already_delivered`.
- Injecting after a completed source creates a new queued post-stack follow-up.
- Duplicate follow-up name is rejected before any target is mutated.
- Cycle-producing injection is rejected before any file is changed.
- A target that has not been delivered renders with the new input result path at
  delivery time.
- Two simultaneous injections serialize through the stack lock.
- Runner wake behavior works in watch mode and prints a clear instruction
  outside watch mode.

## Acceptance Criteria

- Injecting a follow-up before a gated target cannot create an order-inversion
  deadlock.
- The target prompt's `blocked_by` is updated atomically.
- `stako status` shows the injected prompt and explains that the target is
  blocked on it.
- Insertion works when the stack is idle, running, or completed.
- Audit metadata is visible from status or event-log inspection.
