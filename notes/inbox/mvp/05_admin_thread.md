# 05 - Admin Thread

## Goal

Define the conventional stack admin thread: a durable agent context that
periodically evaluates stack commits and decides whether to proceed, append
follow-ups, or stop.

This should be built out of stack threads, commit outputs, prompt inputs, and
routines. Avoid a separate scheduler unless the simple approach fails.

## Convention

Each stack may have a thread named `admin`.

The admin thread is responsible for:

- reading recent completed item commits
- deciding whether the stack is done or needs more work
- appending routine invocations or individual prompts through the normal API
- writing its own decision as an ordinary committed file when needed

Nothing about `admin` should bypass auth, policy, stack locks, VCS, audit, or
normal runtime transitions.

## Admin Prompt Shape

Use a routine rather than a hardcoded runtime mode:

```toml
version = 1
name = "admin-review"
description = "Review recent stack results and decide what to do next."

[[step]]
name = "evaluate"
slug = "admin-evaluate"
kind = "prompt"
thread = "admin"
thread_mode = "resume"
prompt_file = "admin-review/evaluate.md"
```

The prompt materializer should provide registered inputs:

- recent completed item paths and commits
- relevant changed files
- current stack item statuses
- optionally current git commit

The admin's response should be normal text. If it needs to append items, it
should use the authorized local API/MCP surface once that exists for agents.
Before MCP exists, the admin can produce a plan file only.

## MVP Without Agent-Side Mutations

The first implementation can stop before giving the admin agent write access:

1. Admin routine runs.
2. It ingests prior item and commit context.
3. It writes a decision file when needed:
   - proceed
   - needs follow-up
   - done
4. Human or later MCP layer turns that into mutations.

This proves thread continuity and output ingestion without introducing an
agent write loop too early.

## Agent-Side Mutation Phase

Once MCP/API mutation from agents is ready:

- Give admin identity narrowly scoped capabilities:
  - read its stack
  - append to its stack
  - run approved routines
- Admin writes follow-up prompts through `StackClient` via daemon API.
- Each mutation is audited as admin identity.
- Denied writes must not produce stack files.

## Loop Control

Avoid infinite loops:

- Admin routine is manually invoked or appended by an explicit policy.
- A completed admin item does not automatically append another admin item.
- Later scheduler may support:
  - `run admin after N completed items`
  - `run admin after stack idle for duration`
  - `max admin iterations`

## Implementation Steps

1. Add built-in routine template examples under `routines/`.
2. Add admin prompt template.
3. Add a helper to register recent completed items as prompt inputs.
4. Add optional `StackClient.ensureThread(stack, "admin")`.
5. Add tests around admin routine expansion.
6. Later: add agent-side mutation permission tests once MCP/API tools exist.

## Tests

- Admin thread can be created by convention.
- Admin routine appends a prompt targeting `admin`.
- Admin prompt ingests selected prior item commit context.
- Admin completion updates `threads/admin.toml`.
- No automatic requeue loop occurs.

## Acceptance Criteria

- A stack can have a persistent admin thread.
- The admin can evaluate commits with continuity.
- The implementation remains ordinary stack items and mutations.
