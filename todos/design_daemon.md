# Design Daemon

## Scope

The stako daemon is the single process that owns the stack runtime, exposes it over HTTP, renders HTML views, and dispatches to model providers. The CLI and web browser are the core v1 clients. MCP and Python wrapper clients are follow-ups.

## Decided

- Single process, loopback-only network surface in v1.
- Filesystem is the source of truth; in-memory state is rebuildable from disk.
- Zig is the implementation language for the daemon. No fallback language — gaps in Zig's HTTP/auth/templating ecosystem are closed by writing or vendoring what's missing.
- HTTP is the only transport in v1. No gRPC, no Unix sockets.
- **Single HTTP port** for the API, HTML pages, and SSE stream. Path-based routing within that port; no separate binds.
- The HTTP API serves both JSON (for programmatic clients) and HTML (for browsers) via `Accept` negotiation.
- Browser live updates use SSE.
- **Single-writer queue** for all stack mutations. Mutation requests serialize through the daemon; no file locking, no optimistic-retry loops.
- Stack execution is delegated to a **harness layer** (see `design_execution_harness.md`). The daemon owns the queue, per-stack worker loops, routing, version control, and process lifecycle; the harness owns the model/tool loop that actually modifies code.

## To Decide

- HTML templating approach: hand-written string formatting, embedded template engine, or compile-time templates (Zig comptime).
- Whether daemon-owned provider credentials are ever worth supporting beyond official-CLI reuse and API-key config.

### Resolved (was: To Decide)

- **HTTP framework** (milestone 3): build minimally on `std.http.Server` from the Zig standard library, accepting connections via `std.net.Server` and dispatching with a small hand-written router. No external HTTP dependency in v1. Rationale: the surface area is small (loopback only, well under a dozen endpoints), `std.http` covers HTTP/1.1 request parsing and response framing, and avoiding a `build.zig.zon` dependency keeps the toolchain self-contained for now. If/when SSE or multipart needs grow past what the stdlib types support cleanly, revisit.

### Resolved (was: To Decide)

- **`stako daemon stop` mid-execution behavior**: send SIGINT to all running subprocesses, wait the configured grace period, send SIGTERM, then exit. Items that exited cleanly land in `completed`/`canceled`/`failed` per their adapter's `on_exit`. Items still alive after SIGTERM are marked `failed` with reason `daemon_shutdown`. See `design_execution_harness.md`.

### Resolved here, see other docs

- **Process supervision** — plain background process; PID file and log file under `<notes-root>/.stako/`. systemd is a user concern, not a daemon dependency. (See `design_init_and_layout.md`.)
- **Port count** — single port (decided above).
- **Mutation concurrency** — single-writer queue (decided above).

## Surfaces

```
HTTP API  (loopback)
├── JSON endpoints     → CLI, curl/scripts
├── HTML endpoints     → web browser
└── SSE stream         → live updates

Stack runtime  (internal)
├── one worker loop per stack
├── state machine
├── router
├── version-control writer
└── provider dispatch

Storage  (filesystem, under notes-root)
├── stacks/<name>/<id>-<slug>/       # user-visible, version-controlled
└── .stako/
    ├── config.toml                   # daemon config, identity-capability map
    ├── credentials/                  # provider tokens, restrictive perms, gitignored
    ├── runtime/                      # live per-item subprocess state, gitignored
    ├── daemon.pid
    └── daemon.log
```

## HTTP Endpoints (Initial)

```
GET    /stacks
POST   /stacks                          # create a new stack (stack.toml init)
GET    /stacks/{name}
GET    /stacks/{name}/config            # read stack.toml
POST   /stacks/{name}/config            # patch stack.toml
GET    /stacks/{name}/items
GET    /stacks/{name}/items/{id}
POST   /stacks/{name}/items
POST   /stacks/{name}/items/{id}/insert
POST   /stacks/{name}/items/{id}/retry
POST   /stacks/{name}/items/{id}/cancel
POST   /stacks/{name}/items/{id}/supersede
POST   /stacks/{name}/pause
POST   /stacks/{name}/resume
GET    /stacks/{name}/events            # SSE
GET    /healthz
```

## Implementation Plan

1. HTTP server skeleton with `/healthz`.
2. Storage reader: list stacks, list items, show item, all backed by fixtures.
3. JSON read endpoints.
4. HTML read endpoints (server-rendered).
5. SSE skeleton.
6. Mutation endpoints with version-control writes.
7. State machine + per-stack runtime loops against a fake adapter.
8. Provider dispatch for Claude and Codex end-to-end.
9. Provider status probes and Gemini bonus adapter.
10. HTML rendering.
11. Authorization middleware.

## Acceptance Criteria

- The daemon starts, binds loopback, and serves `/healthz`.
- Reading stacks and items from a fixture set works for both JSON and HTML clients.
- Prompt items can execute end-to-end against Claude and Codex.
- Mutations are reflected on disk and committed.
- The daemon refuses to bind on non-loopback interfaces.

## Dependencies

- `design_stack_item_format.md`
- `route_stack_items.md`
- `research_provider_sign_in.md`
- `design_authorization.md`
- `design_execution_harness.md`
- `design_init_and_layout.md`
- `design_web_view.md`
- `design_version_control.md`
- `design_state_machine.md`
- `design_runtime_loop.md`
- `design_stack_config.md`
- `design_errors_and_audit.md`
- `implement_cli_client.md` (for the first non-browser client)
