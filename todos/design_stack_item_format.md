# Design Stack Item Format

## Scope

Define the on-disk layout for stack items. The daemon, CLI, and web view depend on this schema. Follow-up clients such as MCP and Python wrappers must use the same schema.

## Decided

- One directory per item: `stacks/<name>/<id>-<slug>/`.
- `<id>` is a zero-padded numeric identifier (`0001`, `0002`, ...). IDs are append-only; canceled items keep their ID. **ID space is per-stack**, not global — each stack's counter is independent so stacks rename and move without coordination.
- `<slug>` is a short, kebab-case human label.
- `meta.toml` carries routing, status, and lifecycle metadata. Nested tables (`[target]`, `[requires]`, kind-specific tables) are allowed; flat-key constraint is rejected.
- Item kind is a `kind = "..."` field in `meta.toml`, not a separate file type. The body filename may vary by kind, but the metadata format is uniform.
- `prompt.md` (or alternate body file per kind) carries the prompt text.
- Sibling files in the directory hold transcripts, attachments, follow-up notes, and any kind-specific outputs.
- The directory is the source of truth. HTML is rendered from it.
- Follow-up items reference their origin via a `parents = ["<id>"]` list in `meta.toml` (no symlinks).

## To Decide

- Whether `prompt.md` is required for every kind or only for `prompt` and `review`.
- Body filename convention for non-prompt kinds: `body.md`, `<kind>.toml`, or kind-specific names.
- Whether transcript output lives in the item directory or a sibling `runs/` tree (see `design_execution_harness.md`).

## Runtime State

Live runtime state is not stored in tracked `meta.toml`. While an item is running, the daemon writes a gitignored runtime file at:

```
<notes-root>/.organo/runtime/<stack>/<item-id>.toml
```

That file holds the live subprocess handle: PID, harness, started-at timestamp, harness-side session ID, and transcript path. It is atomic-replaced by the daemon and deleted when the item reaches a terminal status.

Tracked completion metadata goes in `meta.toml` under `[result]` after the run ends. This keeps the notes repo clean while work is running and avoids committing PID/session ephemera.

## meta.toml Sketch

```toml
id          = "0007"
slug        = "fix-router-validation"
kind        = "prompt"        # prompt | compact | clear | sleep | review
status      = "queued"        # queued | running | paused | blocked | failed | completed | canceled | superseded
created_at  = 2026-05-10T14:32:00Z
updated_at  = 2026-05-10T14:32:00Z

parents     = ["0005"]        # if this item was inserted by another (e.g. review follow-up)

[target]
# omit a field to leave it unset
provider    = "anthropic"
model       = "claude-opus-4-7"
match       = "exact"         # exact | compatible | any  (was previously named "fallback")
# workdir   = "/path/to/repo" # optional per-item override of stack-level default_workdir;
                              # must still be on workdir.allowlist (see design_stack_config.md)

[requires]
tools              = ["shell", "edit"]
capabilities       = ["stack.read", "stack.append"]
max_context_tokens = 200000

# kind-specific tables, present only when relevant
# [sleep]
# until = 2026-05-10T16:00:00Z
#
# [clear]
# (no fields; clear is a single semantic operation — see Item Kinds below)

# [result] is written after terminal status.
# [result]
# harness         = "claude"                # claude | codex | gemini
# model           = "claude-opus-4-7"
# session_id      = "9b1e2f88-..."          # harness-side session identifier (for resume)
# session_file    = "~/.claude/projects/<encoded-cwd>/9b1e2f88-....jsonl"
# transcript_path = "transcript.jsonl"      # relative to the item directory
# exit_code       = 0
# completed_at    = 2026-05-10T14:32:29Z
```

TOML notes:

- Use TOML's native datetime type for `created_at` / `updated_at` / `sleep_until`.
- Empty/unset fields are represented by omission, not by a `null` sentinel (TOML has no null).
- Kind-specific data lives in its own named table (`[sleep]`, `[clear]`, etc.) so a flat `meta.toml` reader doesn't have to know every kind to round-trip.

The schema must be:

- Hand-editable without breaking.
- Diff-friendly (stable key order, no trailing-whitespace traps).
- Round-trippable through the daemon's writer (writing then reading produces the same logical document).

## Item Kinds (canonical)

| `kind` | Body file | Required tables | Behavior |
|---|---|---|---|
| `prompt` | `prompt.md` | `[target]` | Standard: dispatch to a harness, run to completion. |
| `compact` | optional `prompt.md` (rendered as compact instructions) | `[target]` (harness only; provider/model inherited from stack continuity) | Reserved in the schema. Execution is deferred until Claude/Codex resume support is proven. |
| `clear` | none | none | Marks subsequent items in the stack as fresh-session. No subprocess spawn. Completes immediately. |
| `sleep` | none | `[sleep]` with `until` | Pure timer item. See Sleep below. |
| `review` | `prompt.md` | `[target]` | Runs as an ordinary harness subprocess in a fresh session (overrides stack `continuity`). Automatic follow-up insertion via MCP is deferred until the MCP follow-up lands. |

`route` was removed from v1 — its responsibilities (preflight, routing decisions) are handled by the runtime loop directly. It can return in a later milestone if a concrete use case appears.

### Sleep

```toml
kind   = "sleep"
status = "queued"

[sleep]
until  = 2026-05-10T16:00:00Z
```

Lifecycle:

1. Loop dequeues the item.
2. If `until ≤ now` → straight to `completed` (reason `already_elapsed`).
3. Otherwise → `paused` until the timer fires, then re-enqueued and run (which is just a status transition to `completed`).

Sleep items have no body file and never spawn subprocesses.

### Review

Review items behave like prompt items at the harness level — same dispatch, same transcript capture. Differences:

- The review always runs in a fresh harness session (even when the stack has `continuity = "chain"`).
- In core v1, review items produce a transcript like any other prompt item. Automatic insertion of review follow-ups is deferred to the MCP follow-up.
- If review-triggered follow-up insertion returns in a later MCP milestone, that later design must define commit grouping for the review result plus inserted items.

### Compact / Clear

Both are routed at the stack level rather than as standalone API operations because they only make sense in a stack's session-continuity context:

- `compact` needs the stack to have `continuity = "chain"` and a prior resumable `[result].session_id`. Items routed against a non-chained stack land in `blocked` with reason `no_session_to_compact`.
- `clear` is a marker item: it transitions to `completed` immediately and the runtime loop treats subsequent items in the stack as `fresh_session = true` regardless of `continuity`.

## Status Values (canonical)

This file is the source of truth for status values. Other docs reference it.

| status | meaning |
|---|---|
| `queued` | accepted, waiting for the runtime to pick it up |
| `running` | currently being executed by the harness |
| `paused` | item-level suspension (e.g. waiting on an external trigger or sleep timer) |
| `blocked` | cannot start — routing target unavailable, auth missing, capability denied, or precondition unmet |
| `failed` | execution attempted but ended in error |
| `completed` | terminal success |
| `canceled` | terminal — user or agent withdrew the item before completion |
| `superseded` | terminal — replaced by a newer item that covers the same work |

`paused` and `blocked` differ on cause: `paused` is intentional waiting; `blocked` means the runtime tried and refused. Stack-level pause is a separate flag on the stack, not an item status.

## Implementation Plan

1. Write the schema as a typed struct in Zig.
2. Write a fixture set covering each kind and several status transitions.
3. Implement reader, validator, and writer with round-trip tests.
4. Document the schema in this file once stable.

## Acceptance Criteria

- A typed schema exists in code with reader, writer, and validator.
- Round-trip tests pass on the fixture set.
- The HTML renderer can produce a stack-detail and item-detail page from fixtures alone, without the runtime.
- The CLI can `add` and `show` items against fixtures.

## Dependencies

- `implement_stacks.md`
- `route_stack_items.md` (target schema)
- `design_authorization.md` (capabilities list)
