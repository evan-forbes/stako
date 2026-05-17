# 04 — CLI (Read Path)

## Goal

The first non-browser API client. It is optimized for casual inspection and debugging: common commands are short, common flags have short aliases, and all output can switch to raw JSON for scripts.

## Design Reference

- `../todos/implement_cli_client.md`
- `../todos/design_daemon.md`

## Steps

1. Argument parser: support the canonical command names and short aliases:
   - `stako stack list` and `stako s ls`
   - `stako stack show <name>` and `stako s sh <name>`
   - `stako stack config <name>` and `stako s cfg <name>`
   - `stako daemon status` and `stako d st`
2. HTTP client wrapper: resolve daemon port from `config.local.toml` (falling back to `config.toml`); allow `STAKO_PORT` env-var override; consistent error reporting on connect failures.
3. Implement `stack list`: GET `/stacks`, render as a human-readable table.
4. Implement `stack show <name>`: GET `/stacks/{name}` plus `/stacks/{name}/items`, render items in queue order with status badges and routing target.
5. Implement `stack config <name>`: GET `/stacks/{name}/config`, render stack settings.
6. Add output/debug flags:
   - `--json`, `-j`: pass-through of the daemon response unchanged.
   - `--root`, `-r`: override notes root for local config/token discovery.
   - `--port`, `-p`: override daemon port.
   - `--verbose`, `-v`: include request URL and daemon connection details on errors.
7. Read `.stako/local_token` and prepare the HTTP client to send it on future non-GET requests. This milestone does not need it for read endpoints, but the plumbing should not be reworked in milestone 5.
8. Tests: spawn daemon against fixtures, run CLI as subprocess, assert both canonical and short aliases.

## Acceptance

- All read commands work against a running daemon.
- `--json` / `-j` produces machine-readable output without extra formatting.
- A clear error message when the daemon isn't running ("daemon not started; try `stako daemon start`").
- No CLI-local stack-parsing logic — all rendering is from API response data.
- Every common command and flag added in this milestone has a documented short equivalent.

## Out of Scope (deferred)

- `add`, `insert`, `status`, `pause`, `resume` — wait for milestone 5's mutation endpoints.
- `auth` — milestone 8.
- Interactive prompts.
