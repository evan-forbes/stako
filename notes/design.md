# Stako Design

Stako is a stack runtime: a daemon that operates persistent queues of agent work, exposes them over a local API, and renders them as a web view. A CLI is the first client of that API.

This document is intentionally narrow. Everything outside this scope (indexing, tags, calendar/sync, project structure, ligi extraction, Neovim plugin, public-internet exposure) lives in `backlog/`.

## Core Concept: Stacks

A stack is a persisted, ordered queue of agent work. It functions like a ralph-style loop: items are dequeued, executed against a configured target, and the agent may insert new items back into the queue.

Stacks are the only first-class durable concept in this scope. Everything else exists to operate, observe, or feed stacks.

### Stack Items

Each stack item is a directory on disk:

```
<notes-root>/stacks/<name>/<id>-<slug>/
  meta.toml      # routing + status + lifecycle metadata
  prompt.md      # the prompt body (or other content type, per kind)
  ...            # optional attachments, transcripts, follow-up notes
```

The directory layout is the source of truth. HTML is a render target, not a storage format.

Per-stack ID space (each stack counts from `0001` independently). Daemon state lives under a sibling `<notes-root>/.stako/` (config, credentials, PID, log) so the user-visible `stacks/` tree stays clean and version-controllable.

The exact schema for `meta.toml` is defined in `todos/design_stack_item_format.md`. The on-disk layout decision lives in `todos/design_init_and_layout.md`. Per-stack settings (continuity, intra-stack concurrency, pause state) live in `<notes-root>/stacks/<name>/stack.toml` per `todos/design_stack_config.md`.

### Stack Layout

V1 has one stack root: `<notes-root>/stacks/`. The default stack and every named stack live directly under that directory. Project/global stack types may return later as conventions or metadata, but they do not get separate roots in the current build.

### Item Kinds

- **Prompt.** Submit a prompt to a target (model/provider/agent).
- **Compact.** Compact the running session (in chained stacks).
- **Clear.** Mark subsequent items as starting fresh sessions.
- **Sleep.** Wait for a duration or until a trigger fires.
- **Review.** Run an agent review pass. Follow-up insertion through MCP is deferred until the MCP follow-up lands.

### Routing

Each item declares a target: agent, model, provider, or a policy that selects a compatible provider. Routing detail lives in `todos/route_stack_items.md`.

The runtime validates routing before execution against:

- Provider availability (signed in, healthy).
- Model capability (context, tool support).
- Local capability/auth policy.

### Mutation Rules

Agents can only mutate stacks through a fixed action set:

- Append item.
- Insert item before/after a referenced item.
- Retry blocked items, cancel items, or supersede items.
- Pause or resume the stack.

Direct file edits by agents are not permitted; mutations go through the daemon API so authorization, validation, and version-control commits are uniform.

## The Daemon

A long-running process that owns the stack runtime and exposes it.

### Responsibilities

- Read and write stack directories on disk.
- Run independent per-stack execution loops (dequeue → preflight → spawn → record result). Loop semantics in `todos/design_runtime_loop.md`; status transitions in `todos/design_state_machine.md`.
- **Run the harness layer**: each prompt item executes inside a real agent loop with code-modifying tools (shell, edit, read, etc.), comparable to what Claude Code or Codex run. The daemon delegates to wrapped CLIs (Claude and Codex in core v1; Gemini as a bonus adapter) via a per-harness adapter. Design lives in `todos/design_execution_harness.md`.
- Expose an HTTP API for clients (CLI, web view, scripts). Error shape and audit-log format in `todos/design_errors_and_audit.md`.
- Render HTML views of stacks and items.
- Probe provider status, reuse supported official-CLI/API-key credentials, and dispatch through the resolved provider state.
- Group related stack mutations into version-control commits.

### Network Surface

- Binds loopback only in the first iteration.
- No remote auth in v1. Mutating loopback requests still require a local token; localhost alone is not treated as authorization.
- Public-internet exposure is in `backlog/expose_public_internet.md`.

### Language

Zig is the implementation language for the daemon. TypeScript is rejected (dependency risk). No fallback language — if Zig library coverage proves thin in places (HTTP, OAuth/PKCE, HTML rendering), close the gap by writing what's missing rather than switching languages.

A formal TUI is a follow-up. The CLI is the daily inspection/debugging surface, and the web view ships because the daemon already needs browser-readable status pages.

## Clients

All clients speak to the daemon over its local API. The daemon is the only automated writer of stack files; user hand-edits still happen through the normal editor/git workflow.

### Web View

The daemon renders HTML directly. No separate frontend build step in v1. Pages cover:

- Stack list.
- Stack detail (items in order, status, routing target, last result).
- Item detail (prompt body, transcript, follow-ups).
- Live updates as the stack runs (server-sent events or websocket — decision deferred).

### CLI

First non-browser client. Surfaces:

- `stako init` — set up the notes repo / stack directory.
- `stako auth status` / `stako auth <provider>` — provider status and login hints.
- `stako daemon start|stop|status` — manage the daemon process.
- `stako stack list|show <name>` — inspect.
- `stako stack add <name> <kind> [...]` — append items.
- `stako stack pause|resume <name>` — control execution.

The CLI is intentionally thin — it formats requests to the daemon's HTTP API and prints responses. It should remain ergonomic for casual daily use: common commands and flags need short aliases.

### MCP Server

Deferred. The follow-up plan lives in `todos/implement_mcp_server.md`. When implemented, MCP must call the same daemon mutation path as HTTP/CLI and use the same authorization layer.

### Python Wrapper

Deferred. The follow-up plan lives in `todos/implement_python_wrapper.md`.

## Provider Status

Core scope starts with official CLI credential reuse and API-key fallback:

- Anthropic / Claude Code.
- OpenAI / Codex CLI.

Gemini is a bonus provider if its CLI supports the required structured mode.

The goal is to use existing monthly plans where the official CLI already supports them, without making daemon-owned OAuth/PKCE a v1 blocker. Some providers actively resist non-first-party clients; research lives in `todos/research_provider_sign_in.md`.

Pay-per-token API keys remain supported as a baseline.

## Authorization

Even local-only, mutating requests need a local token so ambient loopback POSTs are not trusted. The later capability model supports future MCP/scheduled callers:

- Which stacks an identity may read.
- Which stacks an identity may mutate.
- Which mutation actions are allowed (append vs. insert vs. cancel).
- Which providers/models a routed item may target.

Container isolation is deferred until non-local exposure is on the table. Capability checks at the API layer are not.

Detail lives in `todos/design_authorization.md`.

## Version Control

The daemon commits stack mutations automatically. Related mutations within a single API call become one commit; unrelated mutations become separate commits. The stack directory must always be in a clean, replayable state.

Commit grouping is a daemon responsibility, not a client responsibility.

The daemon does not auto-commit arbitrary harness workdir changes in v1. External project commits require a later explicit design.

## Out Of Scope (Backlog)

The following ideas were part of earlier stako drafts and are explicitly out of scope for the current build. They remain in `backlog/` for later:

- Indexing automation.
- Tag syntax decisions.
- Project directory structure.
- Calendar/sync integrations.
- Neovim Markdown plugin work.
- Ligi feature extraction.
- Pi-level harness research (superseded by the daemon design).
- Zig TUI library research / implementation.
- MCP server implementation.
- Python wrapper.
- Public-internet exposure.

Re-opening any of these requires a deliberate scope expansion, not silent inclusion.
