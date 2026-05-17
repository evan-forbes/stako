# Design Errors and Audit

## Scope

How the daemon reports errors over HTTP and future MCP, and how it records sensitive actions to an audit log. This file is the source of truth.

## HTTP Error Shape

All non-2xx JSON responses share one body shape:

```json
{
  "error": {
    "code": "capability_denied",
    "message": "identity 'codex-local' lacks capability 'stack.default.append'",
    "details": {
      "identity": "codex-local",
      "capability": "stack.default.append"
    }
  }
}
```

| Field | Required | Notes |
|---|---|---|
| `error.code` | yes | Short slug (snake_case). Stable across versions. |
| `error.message` | yes | Human-readable. May reword across versions. |
| `error.details` | no | Object with code-specific fields. Stable per-code. |

For HTML clients, the same error renders as a page with the same fields in a `<dl>`.

### Status Code Mapping

| HTTP status | `error.code` family | Used for |
|---|---|---|
| 400 | `validation_failed`, `invalid_kind`, `invalid_status_transition` | Malformed request body, unknown kinds, invalid transitions |
| 401 | `identity_required` | Calls that need an identity assertion and don't have one |
| 403 | `capability_denied` | Identity is known but lacks the capability |
| 404 | `not_found` | Stack, item, or endpoint missing |
| 409 | `conflict`, `state_conflict`, `vcs_conflict` | Single-writer queue conflicts, dirty repo, item already terminal |
| 422 | `harness_unavailable`, `auth_missing`, `workdir_denied`, `model_unsupported`, `harness_unsupported_capability`, `no_session_to_compact` | Preflight-style refusals exposed as immediate errors instead of `blocked` items |
| 500 | `internal` | Unexpected daemon failure; should be rare and logged |
| 503 | `daemon_starting`, `harness_disabled` | Daemon up but not ready |

`error.code` is what programmatic clients branch on. Status codes are a coarser axis for HTTP-aware middleware.

## MCP Error Shape

MCP errors map onto the MCP spec's tool-result error shape. The daemon distinguishes two classes:

1. **Capability denials and validation errors** (the calling agent did something disallowed). MCP `isError: true` plus a structured `content` block:

   ```json
   {
     "isError": true,
     "content": [
       {
         "type": "text",
         "text": "capability_denied: identity 'codex-local' lacks capability 'stack.default.append'"
       },
       {
         "type": "resource",
         "resource": {
           "uri": "stako://errors/capability_denied",
           "mimeType": "application/json",
           "text": "{\"code\":\"capability_denied\",\"identity\":\"codex-local\",\"capability\":\"stack.default.append\"}"
         }
       }
     ]
   }
   ```

2. **Daemon-internal errors** (the daemon itself failed). Same shape, `code = "internal"`. The agent should not retry these without changes.

The text block always starts with `<code>: <message>` so simple LLM-side parsing works. The structured resource block carries the same `details` object as the HTTP shape.

This separation lets a calling agent distinguish "I asked wrong, fix the call" from "the daemon is broken, escalate" without inspecting status codes.

## Error Codes (Initial Set)

Stable across versions. New codes may be added; existing codes never change meaning.

### Validation / shape

- `validation_failed` — request body fails schema validation.
- `invalid_kind` — unknown item kind.
- `invalid_status_transition` — requested status transition is not in `design_state_machine.md`'s transition table.
- `unknown_field` — request body has a field the endpoint doesn't accept (strict in v1).

### Authorization

- `identity_required` — no identity asserted on an endpoint that needs one.
- `capability_denied` — identity known, capability missing.

### State / concurrency

- `not_found` — resource missing.
- `conflict` — generic single-writer-queue conflict (rare; usually a more specific code applies).
- `state_conflict` — operation requires a different current state (e.g. cancel a `completed` item).
- `vcs_conflict` — the notes repo has uncommitted user edits to a file the mutation touches.

### Preflight / runtime

- `harness_unavailable` — adapter disabled (e.g. gemini probe failed).
- `harness_denied` — stack-level `allowed_harnesses` doesn't include the routed harness.
- `auth_missing` — required credential file absent.
- `workdir_denied` — workdir outside `workdir.allowlist`.
- `model_unsupported` — model not recognized by the routed adapter.
- `harness_unsupported_capability` — routed adapter exists but cannot satisfy an item capability such as compact/resume.
- `no_session_to_compact` — compact requested but no prior resumable session exists.
- `spawn_failed` — subprocess failed to launch.

### Daemon

- `daemon_starting` — daemon up but startup recovery not complete.
- `harness_disabled` — adapter is intentionally disabled for this daemon (e.g. config flag).
- `internal` — unexpected; check `daemon.log`.

When an item lands in `blocked` rather than failing the API call, the same code populates `blocked_reason` in `meta.toml`. The vocabulary is shared.

## Audit Log

Path: `<notes-root>/.stako/audit.log`.

Format: append-only NDJSON, one line per event:

```json
{"ts":"2026-05-10T14:32:00.123Z","identity":"claude-local","action":"append_item","target":"stack/default","outcome":"allowed","details":{"item":"0007","via":"mcp"}}
{"ts":"2026-05-10T14:33:01.456Z","identity":"codex-local","action":"append_item","target":"stack/default","outcome":"denied","reason":"capability_denied","details":{"capability":"stack.default.append","via":"mcp"}}
```

| Field | Required | Notes |
|---|---|---|
| `ts` | yes | RFC 3339 UTC, millisecond precision. |
| `identity` | yes | The asserted identity for the call. `local` for the implicit loopback user. |
| `action` | yes | One of: `create_stack`, `append_item`, `insert_item`, `retry_item`, `cancel_item`, `supersede_item`, `pause_stack`, `resume_stack`, `update_stack_config`, `dispatch_harness`, `daemon_started`, `daemon_stopped`. |
| `target` | yes | Free-form, but conventional: `stack/<name>`, `stack/<name>/item/<id>`, `harness/<name>`. |
| `outcome` | yes | `allowed` \| `denied`. |
| `reason` | when `denied` | Error code from the table above. |
| `details` | no | Action-specific extras. Always an object. |

### What gets logged

- Every mutation (`create_stack`, `append`, `insert`, `set_status`, `pause`, `resume`, `update_stack_config`).
- Every harness dispatch (a `running` transition — captures provider/model/identity actually used).
- Every denied call at the authorization layer.
- Daemon lifecycle events: `daemon_started`, `daemon_stopped` (with version + config hash).

Read-only API calls are **not** logged in v1. (Volume vs. value: too noisy, low forensic worth.)

### Rotation and Permissions

- File mode: `0600`. The daemon creates it on first write.
- v1: no rotation. Users can rotate manually if it grows. (Backlog: size-based rotation under `audit.log.1`, `audit.log.2`.)
- The audit log is **gitignored**: it's per-machine forensic data, not project history. Add to `design_init_and_layout.md`'s gitignore list.

## Implementation Plan

1. Define the error struct in Zig with `code`, `message`, `details`. One renderer for JSON, one for HTML.
2. Define a `respond_error(status, code, message, details)` helper used by every endpoint.
3. Define the MCP error wrapper that consumes the same struct when the MCP follow-up lands.
4. Define the audit-log writer: append + fsync per event. Synchronous in v1.
5. Wire the writer into the single-writer queue (mutations) and the runtime loop (`dispatch_harness`).
6. Wire denied-call logging into the authorization middleware once milestone 10 lands.
7. Tests: every error code produces the documented shape for active surfaces (JSON and HTML in core v1; MCP when that follow-up lands). Audit-log NDJSON round-trips.

## Acceptance Criteria

- Every non-2xx HTTP response in v1 matches the error shape; no ad-hoc error bodies.
- Future MCP-connected agents can distinguish `capability_denied` from `internal` without inspecting transport.
- Audit log captures every mutation and every harness dispatch.
- `error.code` values are stable; tests pin the documented vocabulary.

## Dependencies

- `design_daemon.md` (HTTP surface)
- `design_mcp_server.md` (MCP surface)
- `design_state_machine.md` (transition validation reuses these codes)
- `design_authorization.md` (capability-check call sites)
- `design_init_and_layout.md` (audit-log path, gitignore entry)
