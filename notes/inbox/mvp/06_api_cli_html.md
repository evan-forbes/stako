# 06 - API, CLI, And HTML Surfaces

## Goal

Expose outputs, threads, and routines through the existing user surfaces
without changing existing endpoint response bodies.

New features should be additive.

## HTTP API

Add JSON endpoints:

```text
GET  /stacks/{stack}/items/{id}/output
GET  /stacks/{stack}/items/{id}/output/summary   # legacy only

GET  /stacks/{stack}/threads
POST /stacks/{stack}/threads
GET  /stacks/{stack}/threads/{name}
POST /stacks/{stack}/threads/{name}
POST /stacks/{stack}/threads/{name}/archive

GET  /routines
GET  /routines/{name}
POST /stacks/{stack}/routines/{name}
```

Mutation endpoints must use existing authorization/policy flow.

Policy action mapping:

- read output: stack read
- list/read threads: stack read
- create/patch/archive thread: stack config/update or new thread action
- append routine: stack append

Add new actions only if the current capability vocabulary becomes ambiguous.

## Existing Append/Insert JSON

Extend request bodies additively:

```json
{
  "kind": "prompt",
  "slug": "follow-up",
  "prompt": "...",
  "thread": "admin",
  "thread_mode": "resume",
  "inputs": {
    "items": ["0001"],
    "files": ["notes/demo/decision.md"],
    "mode": "append"
  }
}
```

Omitted fields preserve current behavior.

## CLI

Add commands:

```text
stako stack output <stack> <id>
stako stack threads <stack>
stako stack thread show <stack> <name>
stako stack thread create <stack> <name> [--provider ...] [--model ...]
stako stack thread archive <stack> <name>

stako routine list
stako routine show <name>
stako stack run-routine <stack> <name>

stako stack add <stack> prompt --thread admin --thread-mode resume --input-item 0001
```

Keep short aliases only where they are likely to be used daily.

## HTML

Stack page:

- show thread list summary if any
- show routines as available actions later

Item page:

- show output summary after terminal completion
- show changed paths
- show rendered prompt link when present
- show thread name/mode when present

Thread page:

- show target defaults
- show last item/session/result
- link to last transcript/output

Routine page:

- show expanded steps read-only
- optional form to append routine to a stack

## SSE

Do not change existing event schema.

Optional additive events later:

- `output_written`
- `thread_updated`
- `routine_appended`

Initial MVP can rely on existing item status events and clients can refetch.

## Tests

- Existing endpoint JSON response snapshots stay unchanged.
- Legacy output endpoints read old packet files when present.
- Thread endpoints enforce read/mutation capabilities.
- Append item with thread/input fields writes matching item metadata.
- Routine endpoint appends multiple items in one commit.
- HTML snapshots cover item output and thread detail.

## Acceptance Criteria

- Users can create threads, append threaded prompts, inspect outputs, and run
  routines without hand-editing files.
- Existing clients remain compatible.
- Auth denial paths do not write files.
