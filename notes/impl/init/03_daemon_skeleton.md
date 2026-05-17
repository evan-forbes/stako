# 03 — Daemon Skeleton

## Goal

Stand up the daemon process: loopback bind on a single port, `/healthz`, read endpoints backed by the fixture set from milestone 1, JSON output, and the local request token that later mutation endpoints must require. No mutations, no execution, no HTML yet.

## Design Reference

- `../todos/design_daemon.md`
- `../todos/design_init_and_layout.md` (PID/log file locations, config split)
- `../todos/design_errors_and_audit.md` (HTTP error shape applies from milestone 3 onward)

## Steps

1. Pick the Zig HTTP server approach: vendor an existing one or build minimally on `std.http`. Record the decision in `design_daemon.md`.
2. **Config loader**: read `config.toml` first, then layer `config.local.toml` on top per `design_init_and_layout.md`. Last-write-wins per leaf key for scalars; the `[identity.*]` tables are replaced wholesale (not merged) so a local identity entry shadows rather than partially overrides. Surface a typed `Config` struct to the rest of the daemon.
3. **Local request token**:
   - Generate `.stako/local_token` on init or daemon start if absent, perms 0600.
   - CLI reads it and sends `Authorization: Bearer <token>` for every non-GET request once mutation endpoints exist.
   - Browser mutation forms later embed a per-page token derived from the same local secret; read-only GETs remain open on loopback.
   - Milestone 3 only creates/loads the token and exposes an internal verifier; milestone 5 enforces it on mutations.
4. **HTTP error responder helper**: a single function that takes `(code_slug, message, details?)` and returns the canonical body `{error: {code, message, details}}` plus the right HTTP status from the mapping table in `design_errors_and_audit.md`. Every endpoint uses it; ad-hoc error bodies are not allowed. Include the slug → status table as a compile-time map.
5. Implement `stako daemon start`: load config via step 2, bind loopback on the configured port, write `daemon.pid`, redirect logs to `daemon.log`. Refuse to start if PID file points to a live process.
6. Implement `stako daemon stop`: read PID, send SIGTERM, wait, remove PID file on confirmed exit. (Subprocess-cleanup semantics land in milestone 6; for milestone 3 the daemon has no children.)
7. Implement `stako daemon status`: report running/stopped, port, uptime.
8. `GET /healthz` — plain text "ok".
9. Implement the storage reader: list stacks (scan only `<notes-root>/stacks/`), list items per stack, read one item.
10. Add JSON read endpoints:
   - `GET /stacks`
   - `GET /stacks/{name}`
   - `GET /stacks/{name}/config`
   - `GET /stacks/{name}/items`
   - `GET /stacks/{name}/items/{id}`
11. Wire the error responder into the read path: `not_found` for unknown stacks/items, `validation_failed` for malformed path params.
12. Plumb fixtures: tests start the daemon against a temp notes root populated from milestone 1's fixtures.
13. Refuse to bind on non-loopback addresses — explicit check, with a test.

## Acceptance

- Daemon starts on a clean init'd directory and serves `/healthz`.
- All read endpoints return well-formed JSON for fixture data.
- A `config.local.toml` value (e.g. `port`) overrides the `config.toml` value; an `[identity.local]` table in `config.local.toml` fully replaces the same-named identity from `config.toml` rather than merging fields.
- `.stako/local_token` exists with perms 0600, is stable across restarts, and the daemon can validate it for future mutation requests.
- A `GET /stacks/does-not-exist` returns the canonical error body with `code = "not_found"` and HTTP 404.
- `daemon.pid` and `daemon.log` behave per the design doc across start/stop/restart.
- Attempt to bind a non-loopback host fails fast with a clear error using the same error body shape.

## Out of Scope (deferred)

- No HTML responses (milestone 9).
- No mutations (milestone 5).
- No SSE yet (skeleton landed but no events to emit until execution exists).
- No per-identity authorization (milestone 10) — for now every read is allowed, but mutation-token plumbing exists before mutations are added.
