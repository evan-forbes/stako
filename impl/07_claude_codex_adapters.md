# 07 — Claude and Codex Adapters

## Goal

Attach the real required harnesses to the runtime core: Claude Code and Codex CLI both run queued `prompt` and `review` items end-to-end through subprocess adapters, using the same session manager, transcript writer, SSE stream, and terminal commit path from milestone 6.

## Design Reference

- `../todos/design_execution_harness.md`
- `../todos/design_runtime_loop.md`
- `../todos/design_state_machine.md`
- `../todos/design_stack_config.md`
- `../todos/design_stack_item_format.md`
- `../todos/route_stack_items.md`
- `../todos/research_provider_sign_in.md`

## Credential Assumption

This milestone may inherit credentials from existing Claude Code and Codex CLI installs or API-key environment/config. It does not attempt to own subscription sign-in flows. Milestone 8 adds provider status commands and clearer auth diagnostics.

## Steps

1. Keep adapter plumbing shared:
   - No session-manager fork per provider.
   - No provider-specific transcript writer.
   - No provider-specific SSE path.
2. Implement the Claude adapter:
   - Invocation: `claude -p <prompt> --output-format stream-json --verbose --include-partial-messages`.
   - Map Claude stream-json events into the normalized event schema.
   - Translate `Edit`/`Write` tool calls into `file_changed`; `Bash` into `command_executed`.
   - Capture Claude session ID and native session file path into terminal `[result]` when available.
3. Implement the Codex adapter:
   - Invocation: `codex exec --json <prompt>`.
   - Map `thread.*`, `turn.*`, `error`, and `item.*` events into the normalized event schema.
   - Translate `item.file_change` and `item.command_execution` into the same normalized event kinds as Claude.
   - Capture Codex session ID and native session file path into terminal `[result]` when available.
4. Add adapter-specific preflight:
   - Binary exists and supports the required structured-output mode.
   - Existing CLI credential or API-key fallback appears usable.
   - Requested model/capability is recognized by the adapter.
5. Support `review` items as fresh-session prompt executions for both adapters.
6. Leave continuity/resume conservative:
   - Record session IDs now.
   - Resume may be used only if both adapters prove reliable in tests.
   - `compact` and `clear` remain deferred if resume behavior is not stable.
7. Tests:
   - Fake Claude and fake Codex binaries emit scripted JSONL; expected normalized transcripts match exactly.
   - One real Claude and one real Codex smoke test, gated behind real-credential flags.
   - Adapter parse failures block/fail with pinned reason codes.
   - Claude and Codex runs both produce terminal `[result]` metadata.

## Acceptance

- Claude-routed and Codex-routed prompt items both run end-to-end and produce normalized `transcript.jsonl`.
- Review items run in fresh sessions for both required adapters.
- The same event schema drives transcripts and SSE for both adapters.
- Provider-specific code stays behind adapter interfaces; session management and transcript handling remain shared.
- Adding Gemini does not require duplicating session-manager, transcript, SSE, or transition logic.

## Out of Scope

- Gemini adapter.
- Daemon-owned OAuth/subscription sign-in flows.
- `compact` and `clear` behavior unless both adapters' resume behavior is already proven stable.
- MCP tools.
- Automatic commits in external workdir repositories.
