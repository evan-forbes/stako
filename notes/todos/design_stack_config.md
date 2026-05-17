# Design Stack Config

## Scope

Per-stack settings that don't belong in any single item's `meta.toml` and aren't daemon-global. Lives at `<notes-root>/stacks/<name>/stack.toml`. Owned by the daemon's writer; hand-editable; committed alongside the rest of the stack directory.

This file is the canonical location for the open questions other docs deferred to "stack-level config":

- session continuity (`continuity = "chain"`)
- intra-stack concurrency override (`max_concurrent_per_stack`)
- the stack-level pause flag
- default workdir for items in this stack
- allowed harnesses (optional restriction)

## Decided

- One `stack.toml` per stack at `<notes-root>/stacks/<name>/stack.toml`.
- File is committed.
- Missing `stack.toml` ⇒ all defaults; the file is created lazily when the first non-default setting is applied.
- The daemon is the only writer. The single-writer queue covers `stack.toml` mutations the same way it covers item mutations.
- `paused = true | false` lives here; the item-level `paused` status is for items waiting on their own trigger (sleep timer, external signal). The stack-level pause is a separate concept.

## stack.toml Sketch

```toml
# Optional metadata for the stack itself.
description       = "default stack"
created_at        = 2026-05-10T14:00:00Z

# Stack-level execution flag. When true, the runtime loop skips this stack
# entirely. Items keep their own status; only the loop is gated.
paused            = false

# Continuity model for items within this stack:
#   "fresh" — every item starts a new harness session (default)
#   "chain" — each item may resume the prior item's result session ID when
#             the same harness is routed to and the adapter proves resume is
#             reliable. compact/clear remain deferred until then.
continuity        = "fresh"

# Override the global max_concurrent_per_stack (default 1).
max_concurrent_per_stack = 1

# Default workdir for items in this stack. Items may still override per
# item in their meta.toml [target] table. The resolved workdir must
# still pass workdir.allowlist in config.toml.
default_workdir   = "~/code/my-project"

# Optional restriction. If present, items routed to a harness not on
# this list land in `blocked` at preflight with reason `harness_denied`.
# Omit to allow all installed harnesses.
allowed_harnesses = ["claude", "codex"]
```

## Field Semantics

| Field | Required | Default | Effect |
|---|---|---|---|
| `description` | no | — | Free-text. Surfaced in CLI / web view. |
| `created_at` | no | first-write timestamp | Documentation only. |
| `paused` | no | `false` | Stack-level execution gate. Independent of per-item status. |
| `continuity` | no | `"fresh"` | `fresh` \| `chain`. Drives session resume across items. |
| `max_concurrent_per_stack` | no | global default (1) | Overrides the `config.toml` global for this stack only. |
| `default_workdir` | no | — | Inherited by items that don't set their own `[target].workdir`. |
| `allowed_harnesses` | no | all installed | Stack-scoped allowlist. Empty list = "all installed". |

Unknown fields are preserved on write (round-trip-safe) but trigger a warning at daemon startup.

## Interaction with `meta.toml`

- An item's `[target].workdir` overrides `stack.toml`'s `default_workdir`.
- An item's resolved harness must satisfy `allowed_harnesses` if that list is set.
- `continuity = "chain"` does not force resume unless the routed adapter supports it reliably — an individual item may opt out by setting `[target].fresh_session = true` (rare; mostly for review items).

## API Surface

```
POST   /stacks                      # create a new named stack
GET    /stacks/{name}/config        # returns stack.toml as JSON / HTML
POST   /stacks/{name}/config        # patches one or more fields atomically
POST   /stacks/{name}/pause         # sets paused = true
POST   /stacks/{name}/resume        # sets paused = false
```

`POST /stacks` accepts `{ "name": "<stack-name>", "config": { ... } }`. It creates `<notes-root>/stacks/<name>/` and writes `stack.toml` with the given config layered over defaults. Returns the created config. Rejects requests for stacks that already exist with `state_conflict`.

`pause`/`resume` are sugar for setting `paused`; they exist because the action is common and worth a dedicated commit message scope (see `design_version_control.md`).

## Implementation Plan

1. Define the typed struct in Zig alongside `meta.toml`'s reader/writer.
2. Implement reader/writer with round-trip tests against fixtures.
3. Wire stack-level `paused` into the runtime loop (loop skips paused stacks).
4. Wire `continuity` into session-resume logic in the harness layer.
5. Wire `max_concurrent_per_stack` into the session manager's slot accounting.
6. Wire `allowed_harnesses` into the routing preflight.
7. Wire `default_workdir` into the item-resolution step before spawn.
8. Add `GET /stacks/{name}/config` and `POST /stacks/{name}/config`.

## Acceptance Criteria

- A stack with `paused = true` does not pick up new items even when its queue has them.
- Setting `continuity = "chain"` makes consecutive items targeting the same harness eligible to reuse the prior `[result].session_id` when the adapter supports reliable resume.
- A stack with `max_concurrent_per_stack = 2` runs two items in parallel; lowering it to 1 mid-run does not interrupt running items.
- An item routed to a harness not in `allowed_harnesses` lands in `blocked` before spawn.
- An item with no `[target].workdir` inherits `default_workdir` from `stack.toml`.

## Dependencies

- `design_stack_item_format.md` (for `meta.toml` interactions)
- `design_execution_harness.md` (continuity, allowed_harnesses, concurrency)
- `design_runtime_loop.md` (pause semantics)
- `design_version_control.md` (commit messages for stack-config changes)
