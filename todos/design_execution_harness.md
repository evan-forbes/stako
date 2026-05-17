# Design Execution Harness

## Scope

The harness layer is what actually runs a `prompt` (or `review`) stack item: it takes a prompt, a working directory, a routed provider/model, and a tool surface, and drives a multi-turn loop where the model emits tool calls, the harness executes them, and feeds results back until the task is complete.

This is the same job that Claude Code, Codex CLI, and Gemini CLI do. Stako's daemon owns the queue, the routing decision, session management, and event normalization; each underlying CLI owns its own model/tool loop. We wrap, we do not reimplement.

## Decided

- **Core v1 wraps two CLIs as subprocesses**: `claude` (Claude Code) and `codex` (Codex CLI). Gemini is a bonus adapter if the installed CLI exposes reliable structured output. No native model loop in v1.
- Each item runs as its own subprocess.
- The daemon parses each CLI's structured (JSONL) output through a **per-harness adapter** that emits a normalized event stream.
- All emitted events flow into (a) a per-item JSONL transcript and (b) SSE to subscribed clients. Same event stream, two sinks.
- A **session manager** inside the daemon tracks live subprocesses, owns the parent end of stdin/stdout pipes, and maps subprocess events to item IDs.
- **Concurrency model**: independent per-stack worker loops; sequential within a stack by default; intra-stack parallelism is opt-in per stack via a stack-level flag; a daemon-level global slot limit prevents unbounded subprocess fanout.
- Transcript files live inside the item directory by default. An item may opt out (e.g. for very noisy runs) and write to `<notes-root>/.stako/runs/<stack>/<id>/` instead.
- Live PID/session state lives under `<notes-root>/.stako/runtime/<stack>/<id>.toml`, not in tracked item metadata. Terminal harness result metadata is copied into `meta.toml` under `[result]`.
- Workdir allow-list comes from `workdir.allowlist` in `config.toml`; items requesting a workdir outside it are rejected before spawn.

## Supported Harnesses (concrete invocations)

Confirmed against current docs (May 2026). These are the exact flags v1 will use.

### Claude Code (`@anthropic-ai/claude-code`)

- **Invocation**: `claude -p "<prompt>" --output-format stream-json --verbose --include-partial-messages`
- **Output**: JSONL on stdout. Event types: `system` (init), `assistant` (message), `user` (tool result back to model), `tool_use`, partial-message deltas, `result` (final).
- **Resume**: `--resume <id>`, `--continue` (most recent in cwd), `--session-id <UUID>` to set, `--fork-session` to branch.
- **Sessions on disk**: `~/.claude/projects/<encoded-cwd>/<session-uuid>.jsonl`.
- **Quirks**: `--output-format stream-json` requires `--verbose`. `--include-partial-messages` requires both `-p` and `stream-json`. CLI `--help` is documented as incomplete; treat current docs as authoritative.

### Codex CLI (`@openai/codex`)

- **Invocation**: `codex exec --json "<prompt>"`
- **Output**: JSONL on stdout. Event types: `thread.started`, `turn.started`, `turn.completed`, `turn.failed`, `error`, and `item.*` items (agent message, reasoning, command execution, file change, MCP tool call, web search, plan update).
- **Resume**: `codex exec resume --last` or `codex exec resume <SESSION_ID>`.
- **Sessions on disk**: `~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<id>.jsonl` (some builds compress as `.jsonl.zst`).
- **Quirks**: `--ephemeral` disables rollout writes. Older interactive REPL has no JSON mode — `codex exec` is the only path we use.

### Gemini CLI (`@google/gemini-cli`) — Bonus

- **Invocation**: `gemini -p "<prompt>" --output-format stream-json`
- **Output**: JSONL on stdout. Event types: `init`, `message`, `tool_use`, `tool_result`, `error`, `result`. (Streaming mode landed Oct 2025 in PR #10883.)
- **Resume**: not documented for headless mode. **Treated as unsupported in v1** — gemini items always start fresh sessions; `compact` items targeted at gemini are blocked if they require resume/compact support.
- **Sessions on disk**: not authoritatively documented; assume opaque.
- **Quirks**: **important** — some shipped builds may not wire `--output-format`. The daemon runs a capability probe and disables the gemini adapter with a clear status message if the flag is missing. Routing an item to gemini in that state lands it in `blocked` with `harness_unavailable`. Gemini support does not block core Claude/Codex acceptance.

> **M8 update (2026-05-10):** Gemini ended up *deferred* in v1, not just probe-gated. The `gemini` CLI was not present in the reference dev environment when M8 landed, and `--output-format stream-json` could not be empirically verified end-to-end. `harness_dispatch.factory("gemini")` deliberately returns `null` so a gemini-routed item lands in `blocked` with `harness_unavailable` (instead of failing inside a partial adapter). The `provider_status` surface returns the google/gemini record with `available=false` and a stable note ("structured stream-json mode unconfirmed; adapter deferred"). A future milestone can flip this by (a) writing a real `gemini_adapter.zig` that maps the streaming JSON to the normalized schema, (b) updating `harness_dispatch.factory()` to return it, and (c) flipping `available=true` in `provider_status.probeGemini` once a real capability probe passes. Until then, `stako auth status` (and `GET /providers`) is the canonical place users see that gemini is intentionally off.

## Normalized Event Schema

All three adapters convert their CLI's events into this normalized schema. The daemon emits exactly this schema to SSE and writes exactly this schema to the per-item transcript JSONL.

Top-level shape:

```json
{
  "v": 1,
  "ts": "2026-05-10T14:32:00.123Z",
  "stack": "default",
  "item": "0007",
  "session": "9b1e2f88-...",
  "kind": "<event-kind>",
  "data": { /* kind-specific */ }
}
```

Event kinds:

| `kind` | Emitted when | `data` fields |
|---|---|---|
| `session_started` | Subprocess spawned and adapter saw its init event | `harness` (claude/codex/gemini), `model`, `cwd` |
| `turn_started` | A model turn begins | `turn` (sequence number) |
| `message_chunk` | Streaming token delta | `text`, `role` (`assistant` / `reasoning`) |
| `message` | A complete assistant message landed | `text`, `role` |
| `tool_call` | The model invoked a tool | `tool`, `args` (opaque object), `call_id` |
| `tool_result` | A tool returned to the model | `call_id`, `ok` (bool), `output` (text, possibly truncated) |
| `file_changed` | A file was created/modified/deleted by a tool | `path`, `op` (`create`/`modify`/`delete`), `bytes` |
| `command_executed` | A shell command ran | `cmd`, `exit`, `stdout_truncated`, `stderr_truncated` |
| `turn_completed` | A model turn ended without error | `turn`, `usage` (opaque object) |
| `error` | Non-terminal error reported by the harness | `message`, `recoverable` (bool) |
| `session_ended` | Subprocess exited | `exit_code`, `terminal_status` (`completed` / `failed` / `canceled`) |

Notes:

- `data` is allowed to carry adapter-specific extras under a `_raw` key so nothing is lost. The standardized fields above are what UIs read.
- `file_changed` and `command_executed` are *normalized projections* of what the underlying CLI exposes. Claude exposes file/command activity through `tool_use` of `Edit`/`Write`/`Bash`; codex has explicit `item.file_change` / `item.command_execution`; gemini reports tool activity through `tool_use` with provider-specific tool names. Adapters do this translation.
- If an adapter cannot reliably emit a normalized kind (e.g. gemini doesn't expose enough info to populate `file_changed`), it omits that kind and emits the underlying `tool_call` only.

## Per-Harness Adapter Contract

An adapter is a small module per harness. Each implements:

```
struct Adapter {
    name: enum { claude, codex, gemini },

    invocation(item, workdir, creds, session_resume_id?) -> argv + env

    parse_line(raw_stdout_line) -> []NormalizedEvent
    parse_stderr_line(raw_stderr_line) -> []NormalizedEvent   // typically just errors

    on_exit(exit_code, ran_to_completion: bool) -> NormalizedEvent  // emits session_ended

    supports(capability) -> bool
        // capabilities: resume, compact, clear, partial_messages, file_change_events
}
```

The adapter is stateless across items (one item, one adapter instance). It may keep small per-session state in memory (e.g. last assistant message ID for streaming continuation) but everything durable lives in the daemon's session manager.

A new harness is added by writing a new adapter plus provider credential resolver. Session management, transcript writing, SSE, and state transitions do not change.

## Session Manager

A component inside the daemon. Owns:

- A registry of live subprocess sessions, keyed by `(stack, item_id)`.
- For each session: PID, harness name, start time, child stdin/stdout/stderr handles, adapter instance, transcript file handle.
- Global concurrent-slot accounting in cooperation with the daemon supervisor (see Concurrency Model below).

API (in-process):

```
spawn(item) -> session
cancel(session, signal) -> ()
list() -> [session]
get(stack, item_id) -> session?
```

State on disk (so the daemon can recover after a restart):

- Every item with `status = "running"` has a runtime file at `.stako/runtime/<stack>/<id>.toml` holding PID, harness, started_at, transcript path, and harness-side session ID if known.
- On daemon startup, the session manager walks all running items and matching runtime files, then marks them `failed` with reason `daemon_restart_orphan`. Re-adoption is deliberately deferred.

## Concurrency Model

Defaults:

- **Across stacks**: independent worker loops. Different stacks may run at the same time.
- **Within a stack**: sequential. One item at a time per stack.
- **Global cap**: configured by `max_concurrent_total`.

Tunable via `config.toml`:

```toml
[runtime]
max_concurrent_total    = 8        # cap across all stacks
max_concurrent_per_stack = 1       # default 1; raise to allow intra-stack parallelism
```

A stack may override `max_concurrent_per_stack` for itself via `stack.toml`'s `max_concurrent_per_stack` field. See `design_stack_config.md`.

When `max_concurrent_total` is reached, stack loops leave newly eligible items in `queued` until a slot opens.

## Session Continuity (compact / clear / resume)

How stako's `compact`, `clear`, and follow-up items map onto the wrapped harnesses:

- **Within a stack, by default, items run independent subprocess sessions.** No automatic resume.
- **A stack may set `continuity = "chain"`** in its config, meaning each item that targets the same harness resumes the prior session ID (recorded in the prior item's `[result]` table).
- **`compact` item**: deferred unless Claude/Codex auth and basic prompt execution are stable. Where unsupported, it blocks with a canonical reason rather than silently no-oping.
- **`clear` item**: future items in the stack do not resume; they start fresh. Recorded as a state transition on the stack.
- **`review` item**: by default, runs in a fresh session even when continuity is on, since review prompts shouldn't drag the implementation transcript into the reviewer's context.

The adapter's `supports(capability)` advertises which of these are real for each harness; routing preflight rejects items whose continuity needs the routed harness can't meet.

## Transcript Capture

Each item directory grows a `transcript.jsonl` containing the normalized event stream. This is the canonical record; it is what the chat view reads.

Additionally, the underlying harness's native session file (claude's `~/.claude/projects/...` file, codex's `~/.codex/sessions/...` file) is recorded by reference in `meta.toml`'s `[result]` table so the user can replay the raw session in the original tool if they want.

Optional `transcript.md` (rendered Markdown summary of the JSONL) can be generated post-run for nicer diffs. Default for v1: JSONL only; Markdown summary is a later enhancement.

## Architecture

```
daemon
 ├─ supervisor
 │   ├─ session manager  ─────────────┐
 │   │   • registry of live procs     │
 │   │   • global slot accounting     │
 │   │   • restart-orphan sweep       │
 │   └─ stack workers                 │
 │       └─ one loop per stack        │
 │                                    │
 └─ stack worker picks queued item     │
     ├─ routing decision               │
     ├─ workdir resolution             │
     ├─ credentials injection          │
     └─ adapter.invocation() ─────────►│
                                       │
            subprocess (claude/codex, gemini bonus)
                ├─ stdout JSONL  ──► adapter.parse_line ──► normalized events
                ├─ stderr        ──► adapter.parse_stderr_line
                └─ exit          ──► adapter.on_exit

            normalized events fan out to:
                • transcript.jsonl (per item)
                • SSE stream (per stack and global)
                • daemon's runtime state machine (status transitions)
```

## Working Directory Model

A stack declares a default `workdir`. An item may override. The daemon validates against `workdir.allowlist` before spawn. The subprocess inherits this as its `cwd`. Tool calls inside the subprocess are scoped by the underlying harness, not by stako.

## Credentials Injection

- Per-provider credentials live under `<notes-root>/.stako/credentials/<provider>/`.
- The session manager sets only the env vars the routed harness needs, scoped to the routed provider. No cross-pollination of provider tokens across subprocesses.
- For claude: typically `ANTHROPIC_API_KEY`, subscription session token, or existing Claude Code CLI credentials, exact mechanism per `research_provider_sign_in.md`.
- For codex: `OPENAI_API_KEY`, subscription session, or existing Codex CLI auth, exact mechanism per `research_provider_sign_in.md`.
- For gemini: Google credential resolution if the adapter is promoted; exact mechanism per `research_provider_sign_in.md`.

## Resolved (was: To Decide)

- **Stack-level config** lives at `<notes-root>/stacks/<name>/stack.toml`. Schema in `design_stack_config.md`.
- **Daemon-restart-orphan policy**: orphans are marked `failed` with reason `daemon_restart_orphan`. Recoverable reattach is a backlog feature.
- **Mid-execution interrupt**: SIGINT first, 5 second grace, then SIGTERM. Final status `canceled`.
- **Transcript Markdown summary**: deferred. v1 is JSONL only.
- **Gemini capability probe**: runs only when Gemini support is enabled or a Gemini-routed item appears. Probe result is cached for the daemon's lifetime; re-probe on startup catches gemini upgrades.

## Implementation Plan

1. Define the normalized event schema as Zig types; write JSON round-trip tests.
2. Define the adapter interface and shared adapter helpers.
3. Implement a fake adapter first so runtime behavior can be tested without provider CLIs.
4. Build the session manager with one global concurrent slot first. Wire `.stako/runtime/<stack>/<id>.toml` writes/reads and terminal `[result]` metadata.
5. Implement independent per-stack worker loops that use the shared session manager.
6. Wire SSE: session manager → SSE multiplexer → per-stack streams.
7. Wire transcript JSONL writes.
8. Add daemon-restart sweep that marks running items failed with `daemon_restart_orphan`.
9. Lift concurrent slots from 1 to `max_concurrent_total` from config.
10. Implement the **claude adapter** end-to-end.
11. Implement the **codex adapter** end-to-end against the same contract.
12. Attempt the **gemini adapter** after Claude/Codex are stable; keep it disabled if the capability probe fails.
13. Add mid-execution interrupt support.
14. Defer `compact` and `clear` unless the core adapter work is already stable.

## Acceptance Criteria

- A claude-routed `prompt` item runs end-to-end, transcript JSONL contains the normalized event stream, SSE emits live updates, item lands in `completed`.
- The same end-to-end works for codex.
- For gemini, either (a) the same end-to-end works, or (b) capability probe fails cleanly, the adapter disables itself, and gemini-routed items go to `blocked` with a clear reason. Gemini does not block Claude/Codex acceptance.
- Two items in different stacks run concurrently without interleaving in transcripts or SSE streams.
- An item with `max_concurrent_per_stack = 2` overridden at the stack level runs two of its items in parallel.
- Daemon restart with running items leaves the system in a consistent state (marked failed; no zombie PIDs, no half-written transcripts).
- Canceling an item sends SIGINT, waits, escalates to SIGTERM, ends the subprocess, and transitions the item to `canceled` with a `session_ended` event.
- A new harness can be added by writing one adapter file with no other daemon changes (verified by audit, not necessarily a fourth harness in v1).

## Dependencies

- `design_daemon.md`
- `design_stack_item_format.md` (`[result]` metadata and runtime-file contract)
- `design_stack_config.md` (continuity, max_concurrent_per_stack, allowed_harnesses)
- `design_state_machine.md` (running ↔ terminal transitions)
- `design_runtime_loop.md` (dequeue, preflight, spawn cycle)
- `design_web_view.md` (SSE schema must match the normalized events)
- `route_stack_items.md`
- `research_provider_sign_in.md`
- `design_authorization.md`
- `design_init_and_layout.md` (workdir allow-list, credentials path, runtime config)
- `design_version_control.md` (commit timing for file-change events and transcript writes)
- `design_errors_and_audit.md` (blocked reasons, harness dispatch audit entries)
