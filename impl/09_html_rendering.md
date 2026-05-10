# 09 — HTML Rendering

## Goal

The same daemon serves browser-friendly HTML pages for stacks and items, with live updates over SSE. No SPA, no JS bundler.

## Design Reference

- `../todos/design_web_view.md`
- `../todos/design_runtime_loop.md`
- `../todos/design_execution_harness.md`

## Steps

1. Add `Accept`-header negotiation on existing read endpoints: return HTML when the client asks for it, JSON when `Accept: application/json` is set.
2. Templating decision: start with hand-written formatting; lift to comptime templates only once duplication appears. Record the decision in `design_web_view.md`.
3. Implement pages:
   - `/` — stack list.
   - `/stacks/{name}` — stack detail: item table, status, target, paused state, running count.
   - `/stacks/{name}/items/{id}` — item detail: meta, body, transcript.
4. Serve one hand-written stylesheet from a known daemon path. No Tailwind CDN dependency unless deliberately chosen and recorded.
5. SSE:
   - Render initial transcript/status snapshot on page load.
   - Subscribe to `/stacks/{name}/events`.
   - Patch DOM nodes by stack/item/event id.
   - Pages remain useful without JavaScript.
6. Browser mutation controls may be minimal:
   - Pause/resume stack.
   - Cancel running item.
   - Retry blocked item.
   - These POSTs must include the local mutation token; no ambient loopback POSTs.
7. Tests:
   - Snapshot tests on rendered HTML from fixtures.
   - Manual smoke test of live updates against Claude/Codex fake harnesses.
   - Mutation-token rejection test for browser POST helpers.

## Acceptance

- Browser can navigate all v1 pages.
- A running prompt item updates its status badge and transcript live without page reload.
- Pages render usefully without JavaScript.
- The same routes return JSON when `Accept: application/json` is set.
- Browser mutation POSTs are token-protected.

## Out of Scope

- Rich browser editing.
- Browser session/cookie handling beyond the local mutation token.
- TUI parity.
