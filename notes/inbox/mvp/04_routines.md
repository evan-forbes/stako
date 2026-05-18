# 04 - Routines

## Goal

Add routines: named sets of prompts/items that can be appended to a stack in
one mutation.

A routine is not a workflow engine. It is batch item creation with explicit
ordering, parent links, thread references, targets, and inputs.

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
name = "planning"
description = "Research the task and write an implementation plan."

[[step]]
name = "research"
slug = "research-approach"
kind = "prompt"
prompt = "Research the codebase and identify the implementation shape."
thread = "admin"
thread_mode = "resume"

[step.target]
provider = "openai"
match = "compatible"

[[step]]
name = "write-plan"
slug = "write-plan"
kind = "prompt"
prompt_file = "prompts/write-plan.md"
after = ["research"]
inputs_from = ["research"]
thread = "admin"
thread_mode = "resume"
```

Notes:

- `step.name` is local to the routine invocation.
- `after` controls expansion order and parent links.
- `inputs_from` expands to generated item ids from earlier steps and writes
  item `[inputs]`.
- `prompt` and `prompt_file` are mutually exclusive.
- Template variables can wait unless there is an immediate need.

## Mutation Semantics

Add `Stack.appendRoutine(stack, routine, opts)`.

The mutation should:

1. Lock the target stack.
2. Parse and validate the routine.
3. Allocate all item ids up front.
4. Expand each step to a normal item write.
5. Write parent references and inputs using allocated ids.
6. Commit once.
7. Audit once with action `append_routine`.
8. Wake workers once after commit.

If any step fails validation, write nothing.

## Execution Semantics

Initial routine execution relies on existing queue order.

- Steps are appended in topological order.
- With `max_concurrent_per_stack = 1`, this gives sequential execution.
- Parent links are traceability only unless dependency blocking is added later.

If a stack allows parallelism, routine steps can run in parallel unless the
runtime later enforces `parents`/`inputs_from` dependencies. For MVP, document
that sequential routines should run on stacks with per-stack concurrency `1`.

## Implementation Steps

1. Add `src/routine.zig`.
   - parse/write routine TOML
   - validate step graph
   - resolve prompt body from inline or file

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
- Invalid step graph rejects cycles.
- Missing prompt file rejects routine append.
- Append routine writes N item directories in one commit.
- `after` creates parent links.
- `inputs_from` creates `[inputs].items`.
- Failed validation leaves the stack unchanged.
- Worker wake fires once.

## Acceptance Criteria

- A planning or implementation routine can be appended atomically.
- Routine output is ordinary stack items; no special runtime path is needed.
- A user can inspect all generated prompts before or after execution.

