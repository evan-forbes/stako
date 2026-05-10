# Implementation Plans

One file per milestone in `../high_level_implementation.md`'s build order. Each file states the goal, the steps, the acceptance bar, and what is explicitly out of scope until a later milestone.

Designs (the *what*) live in `../todos/`. Implementation plans here are the *how* and the *in-what-order*.

## Milestones

| # | File | Status |
|---|---|---|
| 0 | [`00_test_strategy.md`](00_test_strategy.md) | conventions — applies to every milestone |
| 1 | [`01_item_format.md`](01_item_format.md) | pending |
| 2 | [`02_init_and_layout.md`](02_init_and_layout.md) | pending |
| 3 | [`03_daemon_skeleton.md`](03_daemon_skeleton.md) | pending |
| 4 | [`04_cli_read.md`](04_cli_read.md) | pending |
| 5 | [`05_mutations_and_vcs.md`](05_mutations_and_vcs.md) | pending |
| 6 | [`06_runtime_core.md`](06_runtime_core.md) | pending |
| 7 | [`07_claude_codex_adapters.md`](07_claude_codex_adapters.md) | pending |
| 8 | [`08_provider_status_and_gemini.md`](08_provider_status_and_gemini.md) | pending |
| 9 | [`09_html_rendering.md`](09_html_rendering.md) | pending |
| 10 | [`10_authorization.md`](10_authorization.md) | pending |

## Conventions

- Each milestone produces something the user can poke at locally.
- A milestone is not "complete" until its acceptance criteria pass.
- When a milestone reveals that a design doc is wrong or insufficient, update the design first, then continue implementation.
- If a milestone needs to defer something to land its acceptance criteria, the deferred item gets a `## Deferred to milestone N` section in this file — not a silent omission.

## Deferred Follow-Ups

- MCP server implementation lives in `../todos/implement_mcp_server.md`.
- TUI client implementation lives in `../todos/implement_tui_client.md`.
- Python wrapper implementation lives in `../todos/implement_python_wrapper.md`.
