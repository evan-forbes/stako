# Implement CLI Client

## Scope

The `stako` CLI is a thin shell over the daemon's HTTP API. It is the first non-browser client. It does not duplicate stack-runtime logic, does not read or write stack files directly, and does not embed provider integrations — all of that lives in the daemon.

## Decided

- Same binary as the daemon; subcommands route to local-process work (`init`, `daemon`) or to API calls (everything else).
- Uses the same loopback HTTP API the web view uses. JSON requests with `Accept: application/json`.
- No interactive prompts in v1 beyond auth flows. Scriptable from the start.
- Common commands and flags have short equivalents. The CLI is a daily casual interface, not only an administrative API wrapper.

## Commands (v1)

```
stako init                          # create the notes/stack directory layout
stako daemon start [--port N]
stako daemon stop
stako daemon status
stako d start|stop|st               # short daemon aliases

stako stack list
stako stack show <name>
stako stack config <name>
stako s ls                          # short stack list
stako s sh <name>                   # short stack show
stako s cfg <name>                  # short stack config
stako stack add <name> <kind> [-t ...] [-f ...]
stako stack insert <name> <ref> ...
stako stack retry <name> <id>
stako stack cancel <name> <id>
stako stack supersede <name> <id> <replacement-id>
stako stack pause <name>
stako stack resume <name>
stako s add|ins|rt|cx|sup|p|r|cfg ...

stako auth <provider>               # provider login hint or official-CLI handoff
stako auth status
stako a <provider>
stako a st
```

## To Decide

- Whether `stako stack add` reads prompt body from stdin when `--prompt-file -` is passed.

### Resolved (was: To Decide)

- **Output format**: human-readable default; `--json` flag returns the daemon's JSON response unchanged.
- **Daemon discovery**: read port from `config.local.toml` (falling back to `config.toml`); allow `STAKO_PORT` env-var override. No daemon-discovery protocol; loopback + known port.
- **Subcommand shape**: keep formal groups (`stack`, `daemon`, `auth`) and provide short aliases (`s`, `d`, `a`).
- **Common short flags**: `--json/-j`, `--root/-r`, `--port/-p`, `--target/-t`, `--prompt-file/-f`, `--set/-s`, `--verbose/-v`.

## Implementation Plan

1. Argument parser.
2. HTTP client wrapper with consistent error reporting.
3. `init` (local-only filesystem work).
4. `daemon start|stop|status` (process management).
5. `stack list|show` against fixture data through the daemon.
6. `stack add|insert|retry|cancel|supersede|pause|resume` once mutation endpoints land.
7. `auth status` and provider login hints once provider status probes land.
8. Keep a CLI snapshot/help test that fails if a common command or flag lacks a short form.

## Acceptance Criteria

- All v1 commands exist and produce useful output or errors.
- The CLI produces no output that the daemon's HTTP API didn't return (no parallel logic).
- Scriptable: every command supports machine-readable output.
- Ergonomic: common commands and flags have documented short forms.
- `stako init` is idempotent.
- Auth commands use daemon provider-status logic and never create a CLI-local credential store.

## Dependencies

- `design_daemon.md`
- `design_stack_item_format.md`
- `research_provider_sign_in.md`
