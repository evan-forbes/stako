# 00 - Commit Outputs

## Goal

Treat the stack commit produced by a terminal item transition as the durable
output. Summaries, decisions, and other handoff files are ordinary files only
when the prompt chooses to write them.

## Contract

- `meta.toml` records terminal status and `[result]`.
- `transcript.jsonl` records normalized adapter events.
- `rendered_prompt.md` records the exact prompt sent to the harness when the
  runtime materializes inputs.
- Any prompt-written notes or summaries are committed as normal changed files
  when they are in the notes-root workdir.
- External workdir changes are detected for context but are not committed by
  Stako.

## Implementation Steps

1. Stop writing `output/` packet files on terminal transition.
2. Include terminal metadata, transcript, rendered prompt, thread updates, and
   notes-root workdir changes in the terminal mutation commit.
3. Make prompt inputs refer to prior item paths and commit history instead of
   a fixed summary file.
4. Keep legacy output read endpoints tolerant of old item directories, but do
   not make new runtime behavior depend on them.

## Tests

- Terminal transition commits item metadata and transcript paths.
- Notes-root files written by the prompt can be included in the terminal commit.
- Registered item inputs render prior item path and commit-history guidance.
- Existing items without prompt inputs continue to run unchanged.

## Acceptance Criteria

- Downstream handoff can be expressed as item ids, file paths, and commits.
- No new completed item requires `output/summary.md`.
- A summary is just a file chosen by the prompt.
