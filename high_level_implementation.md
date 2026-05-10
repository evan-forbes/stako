# High-Level Implementation

This document covers *how* the daemon, web view, CLI, provider dispatch, and local workflow get built. The *what* lives in `design.md`.

## Build Order

1. Stack item file format (per-item directory, `meta.toml` schema).
2. On-disk layout + `organo init` (creates one `stacks/` directory and `.organo/` under the notes root).
3. Daemon skeleton: start/stop, loopback HTTP server, local bearer token, read/list/show endpoints.
4. CLI client wrapping those read endpoints, with short aliases and short flags for common inspection/debugging commands.
5. Mutation endpoints: append, insert, retry, cancel, supersede, pause, resume, stack config — wired to the single-writer queue and version-control commits.
6. Runtime core: per-stack runtime loops, state machine integration, fake adapter execution, transcript capture, SSE, cancellation, and restart behavior.
7. Claude and Codex adapters: real subprocess support for both required harnesses against the runtime core.
8. Provider status and expansion: auth/status probing for Claude and Codex, API-key or official-CLI credential reuse, and Gemini as a best-effort bonus if its CLI supports the needed structured mode.
9. HTML rendering for stack and item pages.
10. Authorization layer for local identities and future MCP/scheduled callers.

Each step should produce something the user can poke at locally before moving on.

## Language

**Zig is the target for the daemon. No fallback.** Reasoning:

- Avoids TypeScript dependency-graph risk for a tool intended to run business-critical workflows.
- Strong control over memory, startup, and binary distribution.
- Single-language commitment keeps the build, the bug surface, and the contributor model coherent.

If Zig library coverage is thin in a given area (HTTP server, TLS, OAuth/PKCE, HTML rendering), the response is to write the missing piece, vendor an existing library, or shell out to a helper — not to switch languages.

**TypeScript is rejected** for the daemon process itself. The Python wrapper and any web-frontend enhancements may use other languages, since they are clients.

## Daemon Architecture Sketch

```
+------------------+      +------------------+
| CLI / web / curl |  →   |   HTTP server    |
|                  |      |   (loopback)     |
+------------------+      +---------+--------+
                                    |
                          +---------v---------+
                          |  Auth / capability|
                          |  check            |
                          +---------+---------+
                                    |
                          +---------v---------+
                          |  Stack runtime    |
                          |  (per-stack loops,|
                          |  queue, state)    |
                          +----+----+---------+
                               |    |
                +--------------+    +--------------+
                |                                  |
       +--------v--------+              +----------v---------+
       | Stack store     |              | Provider dispatch  |
       | (filesystem,    |              | (Claude, Codex,    |
       |  versioned)     |              |  Gemini bonus)     |
       +-----------------+              +--------------------+
```

Single-process for v1. No external database. Filesystem is the source of truth; in-memory state is rebuildable from disk. The daemon is expected to stay running; it owns one independent worker loop per stack plus shared supervision for mutation serialization, provider slots, and live events.

## Stack Storage

- One directory per item: `<notes-root>/stacks/<name>/<numeric-id>-<slug>/`.
- Per-stack ID space: each stack counts independently from `0001`.
- `meta.toml` for routing, status, lifecycle.
- `prompt.md` (or `body.md`) for content.
- Sibling files for transcripts, follow-ups, attachments.
- A per-stack `index.toml` may be added later if scanning the directory becomes too slow; not v1.

All v1 stacks live under the single `<notes-root>/stacks/` directory. There are no separate project/global stack roots yet. Stack directories live under the notes repository so they version-control with everything else. Daemon state (config, credentials, runtime files, PID, log) lives in a sibling `<notes-root>/.organo/` that is gitignored except for `config.toml`.

## HTTP API Shape (Initial)

Resource-style, JSON request/response, HTML for browser-Accept. All non-2xx responses share one error body shape — schema in `todos/design_errors_and_audit.md`.

```
GET    /stacks
POST   /stacks                             # create a new named stack
GET    /stacks/{name}
GET    /stacks/{name}/config               # read stack.toml
POST   /stacks/{name}/config               # patch stack.toml
GET    /stacks/{name}/items
GET    /stacks/{name}/items/{id}
POST   /stacks/{name}/items                # append
POST   /stacks/{name}/items/{id}/insert    # insert before/after
POST   /stacks/{name}/items/{id}/retry     # blocked -> queued
POST   /stacks/{name}/items/{id}/cancel
POST   /stacks/{name}/items/{id}/supersede
POST   /stacks/{name}/pause
POST   /stacks/{name}/resume
GET    /stacks/{name}/events               # SSE stream
```

Browser GETs return HTML. JSON clients send `Accept: application/json`. This is the simplest dual-render strategy and avoids a separate templating service.

Single port for the API, HTML, and SSE. Mutation requests serialize through a single-writer queue inside the daemon.

## Web View

- Server-rendered HTML. No SPA, no JS bundler in v1.
- A small amount of vanilla JS for live updates over SSE.
- Tailwind via CDN or a single hand-written stylesheet — decision when the first page lands.

The view is for inspection and lightweight editing. Heavy editing happens through the CLI or a text editor against the underlying files (with daemon validation on save).

## CLI

The CLI is a thin shell around the HTTP API. It should not duplicate stack-runtime logic.

Early CLI commands:

- `organo init`
- `organo daemon start|stop|status`
- `organo stack list`
- `organo stack show <name>`

By step 5:

- `organo stack add <name> <kind> -t ... [-f ...]`
- `organo stack insert <name> <ref> ...`
- `organo stack retry <name> <id>`
- `organo stack cancel <name> <id>`
- `organo stack supersede <name> <id> <replacement-id>`
- `organo stack pause|resume <name>`

Common commands and flags must have short forms. The CLI is a casual daily interface, not just an admin surface.

Auth/status commands land alongside provider-status probing.

## MCP Server

Deferred. MCP is a follow-up design in `todos/implement_mcp_server.md`, not part of the core implementation ladder. When it returns, it must use the same mutation queue and authorization layer as HTTP/CLI.

## Python Wrapper

Deferred. A Python wrapper can be useful after the HTTP API stabilizes, but it is not a core v1 milestone.

## Provider Status

Core v1 wraps official CLIs, so provider support starts with probing and reusing credentials those CLIs already know how to manage. API keys remain a fallback for any provider where subscription auth is not available or is too brittle to own directly.

Required targets:

- **Anthropic / Claude Code**.
- **OpenAI / Codex CLI**.

Bonus target:

- **Google Gemini** subscription, if the CLI exposes reliable structured output and auth behavior.

Daemon-owned subscription sign-in is a later enhancement unless a provider exposes a stable flow that is cheap to support. OAuth/PKCE archaeology must not block the core runtime.

## Authorization

Mutating loopback requests use a local bearer token from the first mutation milestone onward; do not rely on "localhost is safe" for POST endpoints. The later authorization layer adds per-identity capabilities for future MCP/scheduled callers:

- Per-identity capability lists (which stacks, which actions).
- Routing target restrictions (which providers/models an identity can route to).
- Mutation validation before disk writes.

Container isolation is out of scope for local-only v1.

## Version Control

The daemon commits stack mutations and terminal harness artifacts:

- One API mutation call → one commit.
- Multi-step internal changes → one commit grouping the related changes. Review follow-up grouping is deferred until MCP follow-ups exist.
- One harness completion → one commit containing the final tracked item metadata and transcript.
- Commit messages are generated from the action and item identifiers.

Live runtime state is daemon state under `.organo/runtime/`, not tracked stack metadata. Hand-edits to stack files outside the daemon should still produce commits via the standard editor flow; the daemon does not need to detect them. The daemon does not auto-commit arbitrary harness workdir changes in v1. Workdir commits require an explicit later design because the daemon cannot safely infer ownership of external project changes.

## Testing Strategy

- Unit tests for the routing validator and state machine.
- Integration tests that drive the HTTP API end-to-end against a temp directory.
- A smoke-test stack fixture used by both manual testing and integration tests.
- Claude and Codex integrations get contract tests gated behind a real-credential flag. Gemini tests are optional until the adapter is promoted out of bonus scope.

## What This Document Is Not

- Not a calendar/sync plan.
- Not a Neovim plan.
- Not a tag-syntax plan.
- Not a project-directory plan.
- Not a public-exposure plan.
- Not an MCP server implementation plan.
- Not a TUI plan.
- Not a Python wrapper plan.

Those are in `backlog/`. Do not silently scope-creep them back in.
