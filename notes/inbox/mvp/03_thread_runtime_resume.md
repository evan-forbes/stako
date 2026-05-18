# 03 - Thread Runtime Resume

## Goal

Wire stack threads into runtime execution so an item can run against an
existing harness-side session.

This plan should be implemented after thread files parse/write cleanly.

## Runtime Resolution

For each queued item:

1. Read item and stack config.
2. Resolve optional item `[thread]`.
3. If item names a thread, read `threads/<name>.toml`.
4. Merge target fields:
   - item target provider/model/match/workdir wins
   - thread target provider/model/match fills missing item fields
   - stack defaults fill remaining fields
5. Resolve thread mode:
   - omitted thread: fresh
   - `fresh`: fresh execution, update thread after completion
   - `resume`: require `state.last_session_id`

## Preflight Failures

Add stable blocked reasons:

- `thread_not_found`
- `thread_archived`
- `thread_no_session`
- `thread_mode_unsupported`

Existing blocked behavior should remain unchanged for non-threaded items.

## Adapter Capability

Use existing `adapter.Capability.resume`.

Runtime preflight must check:

- requested mode needs resume support
- selected adapter supports `.resume`
- thread has a compatible `last_harness` when exact resume is required

If a thread was last run by `claude`, do not resume it with `codex` unless a
future migration feature exists. Block with `thread_mode_unsupported` or a
more specific `thread_harness_mismatch` if that clarity is worth adding.

## Invocation Changes

The current dispatch path builds argv from:

- harness
- item
- item directory

Extend it to accept execution context:

```zig
pub const ExecutionContext = struct {
    rendered_prompt_path: ?[]const u8,
    thread_name: ?[]const u8,
    thread_mode: ThreadMode = .fresh,
    resume_session_id: ?[]const u8,
};
```

Then update harness argv builders:

- Claude fresh: current invocation.
- Claude resume: `claude -p <prompt> --resume <id> --output-format stream-json --verbose --include-partial-messages`
- Codex fresh: current invocation.
- Codex resume: `codex exec resume <id> --json <prompt>` if supported by the installed CLI.
- Fake resume: echo deterministic session metadata for tests.

If the exact Codex flag order differs, verify against current CLI docs or
local `codex exec --help` before implementing. Keep the adapter-specific
shape inside `harness_dispatch.zig`, not the runtime loop.

## Thread Update On Completion

On terminal transition:

- if item has `[thread]` and status is `completed`, update thread state:
  - `last_item_id`
  - `last_harness`
  - `last_session_id`
  - `last_session_file`
  - `last_transcript_path`
  - `updated_at`
- if item failed/canceled, do not advance `last_session_id`
- still write the terminal item commit

Open question: should a failed resumed item update `last_item_id` for audit
without updating `last_session_id`? Initial recommendation: no, keep thread
state pointing at the last known-good completed item.

## Implementation Steps

1. Add runtime `ThreadExecution` resolution helper.
2. Extend `routingPreflight` to include thread validation.
3. Extend `ProceedInfo` with thread execution context.
4. Extend `runtime.Dispatch.build_argv` signature.
5. Update real and fake dispatch builders.
6. Update session manager spawn input/session with thread fields.
7. Update terminal transition to pass thread update data.
8. Update restart-orphan logic to avoid advancing thread state.

## Tests

- Fresh non-thread item uses old argv.
- Thread `fresh` item updates thread after completion.
- Thread `resume` item passes session id to fake/real argv builder.
- Missing thread blocks with `thread_not_found`.
- Archived thread blocks with `thread_archived`.
- Resume with no session blocks with `thread_no_session`.
- Adapter without resume support blocks with `thread_mode_unsupported`.
- Failed/canceled threaded item does not advance thread state.

## Acceptance Criteria

- A named thread can carry session continuity across multiple prompt items.
- Defaults remain fresh-session and behavior-compatible.
- Resume decisions are visible in item output manifests and thread files.
