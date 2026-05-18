# 04 - Routines

## Goal

Add routines: named sets of prompts/items that can be appended to a stack in
one mutation.

A routine is not a workflow engine. It is batch element creation with explicit
thread references and ordered prompt lists.

## On-Disk Layout

Start with committed repo-level routines:

```text
routines/
  planning.toml
  implement-from-plan.toml
```

Routine files are outside `stacks/` because they are reusable templates.

Schema:

```toml
version = 1
description = "Research the task and write an implementation plan."
thread = "admin"

[[step]]
prompts = ["../prompts/planning/research.md"]

[[step]]
prompts = ["../prompts/planning/write-plan.md"]
```

Notes:

- a root or step-level `thread` is required and owns provider/session selection.
- `prompts` is required for prompt elements and is resolved in order.
- `command` may replace `prompts` for thread operations such as `compact`,
  `clear`, or `new`.
- Template variables can wait unless there is an immediate need.

## Mutation Semantics

Add `Stack.appendRoutine(stack, routine, opts)`.

The mutation should:

1. Lock the target stack.
2. Parse and validate the routine.
3. Allocate all item ids up front.
4. Expand each element to a normal item write.
5. Register caller-provided inputs on each generated prompt item.
6. Commit once.
7. Audit once with action `append_routine`.
8. Wake workers once after commit.

If any element fails validation, write nothing.

## Execution Semantics

Initial routine execution relies on existing queue order.

- Elements are appended in source order.
- With `max_concurrent_per_stack = 1`, this gives sequential execution.

If a stack allows parallelism, routine elements can run in parallel unless the
runtime later enforces dependencies. For MVP, document
that sequential routines should run on stacks with per-stack concurrency `1`.

## Implementation Steps

1. Add `src/routine.zig`.
   - parse/write routine TOML
   - resolve prompt bodies from ordered `prompts`

2. Add routine discovery.
   - `StackClient.listRoutines`
   - `StackClient.readRoutine`
   - routines root is `<notes-root>/routines`

3. Add append routine mutation.
   - either new low-level `mutations.applyAppendRoutine`
   - or a `Stack` method that calls item write helpers under one lock/commit

4. Extend policy.
   - routine append requires stack append capability
   - optional future capability: `stack.<name>.routine.<routine>`

5. Extend daemon route later in `06_api_cli_html.md`.

## Tests

- Routine parser round-trip.
- Missing thread rejects the routine.
- Legacy fields such as `[[step]]`, `kind`, `slug`, `target`, and `thread_mode`
  are rejected.
- Missing prompt file rejects routine append.
- Append routine writes N item directories in one commit.
- Failed validation leaves the stack unchanged.
- Worker wake fires once.

## Acceptance Criteria

- A planning or implementation routine can be appended atomically.
- Routine output is ordinary stack items; no special runtime path is needed.
- A user can inspect all generated prompts before or after execution.
