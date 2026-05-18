# 01 - Prompt Inputs

## Goal

Make cross-item handoff explicit and generic. A prompt should be able to say
which previous items, files, or commits it consumes, and the runtime should
materialize the actual prompt sent to the harness as a file.

This avoids hidden transcript scraping and makes the exact model input
inspectable after the fact.

## On-Disk Schema

Extend item `meta.toml` with an optional `[inputs]` table:

```toml
[inputs]
items = ["0001", "0002"]                         # item commit context
files = ["notes/demo/decision.md"]
commits = ["abc1234"]                            # informational in v1
mode = "append"                                  # append | prepend
```

Rules:

- `items` references item ids in the same stack.
- `files` are paths relative to notes root unless explicitly absolute.
- `commits` are recorded for traceability but do not auto-expand in v1.
- omitted `[inputs]` means the prompt body is sent exactly as today.

Add a runtime-created prompt file:

```text
stacks/<stack>/<id>-<slug>/rendered_prompt.md
```

This file is tracked and committed with the terminal output. It records exactly
what was sent to the harness for auditability.

## Prompt Materialization

Before dispatch:

1. Read the base item prompt from `prompt.md` or fallback to slug.
2. Resolve `[inputs]`.
3. Build a deterministic rendered prompt:

```markdown
<base prompt>

---

## Registered Inputs

### Item 0001

Source: stacks/demo/0001-plan

Use this item as relevant context. Inspect the notes git history for commits
touching `stacks/demo/0001-plan` and surrounding commits when the task needs
the prior item's output details.

### File stacks/demo/notes/context.md

<file contents>
```

If `mode = "prepend"`, put registered inputs before the base prompt.

If an input is missing:

- block the item before spawn with `input_missing`
- do not silently omit it

If an input is too large:

- v1 should enforce a simple byte cap
- block with `input_too_large`
- later compaction/summarization can relax this

## Implementation Steps

1. Extend `item.zig`.
   - add `Inputs` struct
   - parse/write `[inputs]`
   - validate ids and relative path syntax

2. Extend append/insert inputs.
   - add optional `input_items`, `input_files`, `input_commits`, `input_mode`
   - keep existing API behavior when omitted

3. Add `src/prompt_materializer.zig`.
   - `resolvePrompt(...)`
   - `renderPrompt(...)`
   - explicit max byte cap
   - deterministic headings and path ordering

4. Update runtime preflight.
   - resolve inputs before adapter factory/spawn
   - block with `input_missing` or `input_too_large`

5. Update harness dispatch.
   - `build_argv` should consume `rendered_prompt.md` when present
   - existing `prompt.md` fallback remains for old items/tests

6. Commit rendered prompt.
   - Include `rendered_prompt.md` in terminal stack mutation commit, not at
     spawn time, to avoid tracked running-state churn.

## Tests

- Omitted `[inputs]` preserves current prompt argv.
- Input item renders item path and commit-history guidance.
- Missing input item blocks with `input_missing`.
- Missing input file blocks with `input_missing`.
- Large input blocks with `input_too_large`.
- Rendered prompt is deterministic and committed on terminal transition.

## Acceptance Criteria

- A later item can ingest prior item context by id without knowing the item
  directory slug.
- The exact prompt sent to the harness is inspectable from disk.
- Existing prompt items without inputs continue to run unchanged.
