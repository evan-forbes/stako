# Design Web View

## Scope

The daemon renders HTML directly for browser clients. No SPA, no JS bundler, no separate frontend build step in v1. A small amount of vanilla JS handles live updates over SSE.

This file owns the page set, templating choice, and SSE event protocol for the browser.

## Decided

- Server-rendered HTML from inside the daemon. Same single port as the JSON API and SSE stream.
- HTML vs JSON is selected by `Accept` header on the same routes.
- Live updates use SSE. No WebSockets in v1.
- Styling: one hand-written stylesheet served from the daemon. No Tailwind, no CDN.
- No client-side router. Each page is a server-rendered HTML document.

## Pages (v1)

| Path | View |
|---|---|
| `/` | Daemon home — list of stacks, daemon health, signed-in providers |
| `/stacks/{name}` | Stack detail — items in order with status badges, target, last update |
| `/stacks/{name}/items/{id}` | Item detail — meta.toml fields, prompt body, live transcript, follow-ups |
| `/auth` | Provider sign-in status and start-sign-in links |
| `/healthz` | Plain text, daemon-internal |

Each page accepts `Accept: application/json` and returns JSON instead of HTML for programmatic clients.

## Templating

Three options ranked by recommended order:

1. **Zig comptime templates** — strings with `{{ }}` placeholders compiled into render functions at build time. Fast, type-checked, zero runtime dependency. Requires writing or vendoring a small templating helper.
2. **Hand-written string formatting** — `std.fmt.allocPrint` with embedded snippets. Simplest, but fragile as pages grow.
3. **Embedded template engine** — bring in a Zig template library. Unnecessary dependency for v1.

Recommendation: start with option 2 for the first one or two pages, lift to option 1 once duplication appears. Never adopt option 3 unless options 1/2 hit a real wall.

## SSE Protocol

The browser opens `GET /stacks/{name}/events` with `Accept: text/event-stream`. The daemon emits newline-delimited events. The event `data` is exactly the normalized event schema defined in `design_execution_harness.md` — same wire format, two sinks (transcript JSONL on disk, SSE in the browser).

```
event: session_started
data: {"v":1,"ts":"2026-05-10T14:32:00.123Z","stack":"default","item":"0007","session":"9b1e...","kind":"session_started","data":{"harness":"claude","model":"claude-opus-4-7","cwd":"/home/evan/code/foo"}}

event: tool_call
data: {"v":1,"ts":"...","stack":"default","item":"0007","session":"9b1e...","kind":"tool_call","data":{"tool":"edit","call_id":"c1","args":{"path":"src/foo.zig"}}}

event: message_chunk
data: {"v":1,"ts":"...","stack":"default","item":"0007","session":"9b1e...","kind":"message_chunk","data":{"text":"...","role":"assistant"}}
```

The `event:` SSE field equals the normalized `kind`. The `data:` payload is the full normalized envelope.

### Harness events (from `design_execution_harness.md`)

`session_started`, `turn_started`, `message_chunk`, `message`, `tool_call`, `tool_result`, `file_changed`, `command_executed`, `turn_completed`, `error`, `session_ended`.

### Daemon-level events (not from the harness)

These do not come from a subprocess and do not have `session` fields:

- `item_status` — status transitions (`queued` → `running` → `completed` etc.).
- `item_appended` / `item_inserted` / `item_removed` — queue mutations.
- `stack_paused` / `stack_resumed`.
- `routing_decision` — when an item leaves `queued` and lands on a concrete provider/model.

The browser updates DOM nodes by item ID. Initial page load includes a snapshot; SSE provides deltas only.

A global stream `/events` may also exist (see "To Decide") — same schema, just unfiltered across stacks.

## To Decide

- Whether `/stacks/{name}/events` is the only SSE stream, or whether there is also a daemon-wide `/events`.
- Static asset serving (single CSS file, maybe one JS file) — bundled into the daemon binary at compile time or served from `<notes-root>/.organo/static/`.

### Resolved (was: To Decide)

- **Edit-in-browser**: minimal controls only in v1 (pause/resume/cancel/retry). Heavier editing happens via the CLI or text editor against the underlying files.
- **Browser auth**: trust loopback in v1; no cookie session. Revisit when public exposure lands.

## SSE-on-Page-Load Story

When a browser loads `/stacks/{name}/items/{id}` mid-run:

1. Server renders the page from the item directory's current state, including the full transcript JSONL up to "now". The HTML includes a `<script>` tag with the last-event byte offset (or transcript-line count) so the client knows where the snapshot ends.
2. Client opens `GET /stacks/{name}/events` with SSE.
3. Daemon sends only events emitted after the snapshot's cutoff. The client appends them to the rendered transcript.

This avoids both a replay buffer in the daemon and the gap that would otherwise exist between snapshot rendering and SSE subscription. The transcript JSONL is the source of truth; SSE is a tail.

For completed items, no SSE is needed — the snapshot is final.

## Implementation Plan

1. Add `/healthz` plus the SSE endpoint shell.
2. Add `/` (stack list) and `/stacks/{name}` (stack detail), HTML only.
3. Wire the first SSE event type (`item_status`) end-to-end against fixtures.
4. Add `/stacks/{name}/items/{id}` (item detail).
5. Add live transcript rendering (forward harness events).
6. Add `/auth` once provider-status commands land.

## Acceptance Criteria

- All v1 pages render against the fixture set without the runtime.
- SSE stream delivers status transitions to a browser without polling.
- A browser tab shows a `prompt` item moving from `queued` → `running` → `completed` live.
- Pages stay usable without JavaScript for read-only inspection (SSE adds live updates only).
- No client-side build step.

## Dependencies

- `design_daemon.md`
- `design_stack_item_format.md`
- `design_execution_harness.md` (event source for transcript streaming)
- `design_authorization.md` (eventual auth model for browser sessions)
