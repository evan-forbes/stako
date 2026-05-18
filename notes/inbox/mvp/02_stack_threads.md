# 02 - Stack Threads

## Goal

Add named durable stack threads: persistent agent contexts that items can
target. By default every prompt still runs fresh. A thread is requested only
when an item explicitly names one.

Terminology:

- Runtime session: one subprocess execution of one item.
- Stack thread: durable metadata that points future items at an existing
  harness-side session when supported.

## On-Disk Layout

Threads live under each stack:

```text
stacks/<stack>/
  stack.toml
  threads/
    admin.toml
    implementer.toml
```

Thread file:

```toml
version = 1
name = "admin"
created_at = 2026-05-17T12:00:00.000Z
updated_at = 2026-05-17T12:00:00.000Z
status = "active"                 # active | archived

[target]
provider = "openai"
model = "gpt-5"
match = "compatible"

[state]
last_item_id = "0007"
last_harness = "codex"
last_session_id = "..."
last_session_file = "~/.codex/sessions/..."
last_transcript_path = "stacks/demo/0007-review/transcript.jsonl"
```

Threads are stack content, not daemon runtime state. They should be committed
like other stack mutations.

## Item Schema

Add optional `[thread]` to item metadata:

```toml
[thread]
name = "admin"
mode = "resume"       # fresh | resume | continue | fork
```

Semantics:

- omitted `[thread]`: current behavior, fresh subprocess session
- `mode = "fresh"`: run in a fresh session but update the named thread after
  successful terminal completion
- `mode = "resume"`: resume the thread's known `last_session_id`
- `mode = "continue"`: use provider-specific "continue latest" behavior when
  available; generally less deterministic than resume
- `mode = "fork"`: branch from the thread session when provider supports it

For MVP, implement `fresh` and `resume` first. Reserve `continue` and `fork`
in the parser if cheap, but block them until runtime support exists.

## Stack API

Add `StackClient` methods:

- `listThreads(stack)`
- `readThread(stack, name)`
- `createThread(stack, input)`
- `patchThread(stack, name, patches)`
- `archiveThread(stack, name)`
- internal `updateThreadResult(stack, name, item_result)`

Mutation behavior:

- thread create/patch/archive lock the owning stack mutex
- update on item completion runs in the same terminal mutation as `[result]`
  and terminal commit writes
- VCS/audit behavior matches existing stack mutations

## Validation

Thread names should follow stack-name style:

- lowercase letters, digits, `-`, `_`
- no leading/trailing separators
- no `.` path components

Thread target provider/model is optional. If present, it acts as defaults for
items that omit target fields. Item target fields win.

## Implementation Steps

1. Add `src/stack_thread.zig`.
   - schema structs
   - parser/writer
   - name validation

2. Extend `item.zig`.
   - `ThreadRef` struct
   - parse/write `[thread]`
   - validation

3. Extend `mutations.zig`.
   - apply create/patch/archive thread
   - include thread files in changed paths

4. Extend `stack.zig`.
   - public `StackClient` methods
   - internal thread update during terminal transition

5. Extend storage readers.
   - list/read thread files
   - tolerate missing `threads/`

## Tests

- Thread file parse/write round-trip.
- Invalid thread names rejected.
- Creating a thread commits `threads/<name>.toml`.
- Item with omitted `[thread]` parses like old items.
- Item with `[thread]` writes byte-stable TOML.
- Terminal item update records last session in the named thread.

## Acceptance Criteria

- Named threads are visible and versioned on disk.
- They do not affect runtime behavior until `03_thread_runtime_resume.md`.
- Existing stacks with no `threads/` directory keep working.
