# Implement Stacks

## Scope

A stack is a persisted, ordered queue of agent work, owned and operated by the stako daemon. Stack items are stored as per-item directories on disk. The daemon is the only writer; core clients (CLI and web view) mutate stacks through its HTTP API. MCP and Python wrapper clients are follow-ups that must use the same API.

Detailed sub-todos:

- File format: `design_stack_item_format.md`
- Routing: `route_stack_items.md`
- Daemon architecture: `design_daemon.md`
- CLI client: `implement_cli_client.md`
- Authorization: `design_authorization.md`

This file owns the stack runtime as a whole.

## Decided

- Stack items are directories: `stacks/<name>/<id>-<slug>/` with `meta.toml` and `prompt.md` (or other body file per kind). The directory layout is the source of truth.
- HTML is a render target only, not storage.
- Multiple stacks supported: a default stack plus arbitrary named stacks, all under the single `<notes-root>/stacks/` root. Project/global stack classes are deferred.
- Mutations go through a fixed action set (append, insert, retry blocked item, cancel, supersede, pause, resume) — direct file edits by agents are not permitted.
- The daemon commits stack mutations automatically.

## Open Questions

- Trigger model for external events (webhooks, file watches): out of scope for v1. The daemon-internal scheduler covers sleep timers; everything else is manual via the API.

### Resolved here, see other docs

- **Status enum** — canonical list in `design_stack_item_format.md`.
- **State transitions** — canonical table in `design_state_machine.md`.
- **Runtime loop semantics** — `design_runtime_loop.md`.
- **Kind values vs file types** — kinds are `kind = "..."` in `meta.toml`; not separate file types.
- **Mutation concurrency** — single-writer queue inside the daemon. All mutation requests serialize through one goroutine-equivalent. No file locking, no optimistic retries.
- **Routing field names** — `match = "exact" | "compatible" | "any"` (renamed from `fallback`).
- **Review follow-ups** — deferred until the MCP follow-up. Core v1 review items produce transcripts; they do not auto-insert follow-up items.
- **Mid-execution interrupt** — SIGINT first, 5s grace, then SIGTERM. (`design_execution_harness.md`.)
- **`compact` / `clear` semantics** — kind-specific tables and dispatch behavior in `design_stack_item_format.md` Item Kinds; harness-side mapping in `design_execution_harness.md` Session Continuity.
- **`route` kind** — removed from v1.

## Implementation Plan

1. Land `design_stack_item_format.md` so the on-disk schema is fixed.
2. Implement read-side first: list stacks, list items, show item.
3. Add mutation API: create stack, append, insert, retry, cancel, supersede, pause, resume, stack config.
4. Wire mutations to the single-writer queue and version-control commits.
5. Implement the runtime state machine and per-stack worker loops against a fake adapter.
6. Implement prompt-item execution against Claude and Codex.
7. Add routing preflight (per `route_stack_items.md`).
8. Add `sleep` and `review` item handling. `compact`/`clear` remain schema-reserved unless resume behavior is proven stable.
9. Add tests for state transitions, pause/resume, per-stack loop independence, and commit grouping.

## Acceptance Criteria

- Stacks are persisted as per-item directories under the notes repository.
- Multiple stacks (default and named) are supported with the same format under the single `stacks/` root.
- The daemon is the only writer to stack files; clients mutate through the HTTP API.
- Stack items can target a specific agent, provider, model, or compatible-provider policy.
- Invalid routing requests are rejected before execution.
- Follow-up insertion by agents is deferred until MCP exists.
- Pausing and resuming can be triggered manually through the API/CLI.
- Stack modifications are committed as coherent version-control units.

## Dependencies

- `design_stack_item_format.md`
- `design_daemon.md`
- `route_stack_items.md`
- `design_authorization.md`
- `research_provider_sign_in.md`
