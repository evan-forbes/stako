# 06 — Runtime Core

## Goal

Prove the daemon runtime without real provider CLIs: independent per-stack loops, the shared session manager, fake adapter execution, transcript capture, SSE, cancellation, restart recovery, and terminal commits. Claude/Codex adapter details wait until milestone 7.

## Design Reference

- `../todos/design_execution_harness.md`
- `../todos/design_runtime_loop.md`
- `../todos/design_state_machine.md`
- `../todos/design_stack_config.md`
- `../todos/design_stack_item_format.md`
- `../todos/design_web_view.md`
- `../todos/design_errors_and_audit.md`
- `../todos/design_version_control.md`

## Steps

1. Define the normalized event schema as Zig types. JSON round-trip tests cover every event kind.
2. Define the adapter interface against a fake adapter first:
   - `invocation(item, workdir, creds, session_resume_id?)`
   - `parse_line(raw_stdout_line)`
   - `parse_stderr_line(raw_stderr_line)`
   - `on_exit(exit_code, ran_to_completion)`
   - `supports(capability)`
3. Add the fake adapter/script harness:
   - Emits deterministic JSONL events.
   - Can complete, fail, hang, ignore SIGINT, and emit malformed JSON for tests.
   - Uses the same adapter contract real harnesses will use.
4. Implement the session manager:
   - Shared across the daemon; owns live subprocess registry, stdout/stderr pumps, transcript file handles, and global concurrency slots.
   - One item maps to one subprocess.
   - Writes `.stako/runtime/<stack>/<id>.toml` while running.
   - Streams normalized events to `transcript.jsonl` and SSE.
   - On exit, deletes the runtime file, writes terminal `[result]` metadata, transitions to terminal status, then asks the state writer to commit tracked artifacts.
5. Clarify writer ownership in code:
   - Stack metadata, status, config, audit, and git commits go through the single state writer.
   - Transcript append is owned by the session manager.
   - Terminal status commits happen only after transcript close.
6. Implement independent per-stack runtime loops:
   - One worker loop per stack directory under `<notes-root>/stacks/`.
   - Each loop owns that stack's ordering, pause behavior, sleep timers, and lowest-id-first dequeue.
   - The daemon supervisor owns stack discovery, shared session manager, shared global slot semaphore, and wake fanout.
7. Routing preflight with fake-adapter capabilities:
   - Stack `allowed_harnesses`.
   - Workdir allowlist.
   - Harness availability.
   - Model/capability recognition.
   - Authorization placeholder passes for the local identity until milestone 10.
   - Failures transition the item to `blocked` with a canonical reason code.
8. Sleep items:
   - If `until <= now`, transition directly to `completed`.
   - If `until > now`, transition to `paused`, arm that stack loop's timer, then transition `paused -> queued -> completed` when elapsed.
9. SSE multiplexer:
   - Per-stack stream at `/stacks/{name}/events`.
   - No replay buffer in v1; subscribers see events from connection time.
10. Restart and shutdown:
    - On daemon startup, running items with runtime files are failed with `daemon_restart_orphan`; runtime files are deleted.
    - `stako daemon stop` asks the session manager to cleanly stop every live subprocess before the daemon exits.
11. Tests:
    - Fake adapter transcripts match expected normalized JSONL exactly.
    - Two stacks run independently: pausing one does not block the other.
    - Global and per-stack concurrency limits are honored.
    - Cancellation and daemon shutdown terminate subprocesses and land the correct status.
    - Restart with stale runtime files fails orphans deterministically and leaves `.stako/runtime/` clean.

## Acceptance

- Prompt items can run end-to-end through the fake adapter and produce normalized `transcript.jsonl`.
- Per-stack loops operate independently while respecting the daemon's global session limit.
- Runtime files are gitignored daemon state, not tracked `meta.toml`.
- Terminal tracked artifacts commit as one harness-completion commit per item.
- SSE receives the same normalized event schema as transcripts.
- A paused stack does not dispatch new work, and other stacks continue.
- No Claude/Codex/Gemini adapter behavior is required in this milestone.

## Out of Scope

- Real Claude, Codex, or Gemini adapters.
- Provider sign-in or provider status UX.
- `compact` and `clear` behavior beyond schema preservation.
- MCP tools.
- Automatic commits in external workdir repositories.
