# Design Init and Layout

## Scope

`organo init` bootstraps a notes directory for organo use: the layout it produces, the daemon config it writes, the gitignore rules, and the conventions other components rely on. This file is the on-disk contract.

## Decided

- The notes root contains both user-visible content and a daemon state subtree.
- User-visible stack content lives at `<notes-root>/stacks/<name>/`.
- Daemon state lives at `<notes-root>/.organo/`, gitignored except for `config.toml`.
- `organo init` is idempotent: re-running on an already-initialized root is a no-op (plus a confirmation message).
- The notes root must be a git repository. If it is not, `organo init` initializes one (after confirmation when run interactively).
- **Init inside an existing git repo**: proceed without auto `git init`, print a warning that the organo layout will join the existing repo's history.
- **Default stack creation**: eager at `init` time. `stacks/default/` is created with an empty `stack.toml` carrying defaults.
- **Config split**: `config.toml` is committed (project-wide defaults: identity capability map, provider credential-mode preferences). `config.local.toml` is per-machine and gitignored (port, workdir allowlist, machine-specific identities, daemon paths). The daemon reads both; `config.local.toml` values override `config.toml` values when both are present.
- **Credentials layout**: one file per provider at `.organo/credentials/<provider>/auth.toml`, perms `0600`. Directory perms `0700`.
- **Local mutation token**: `.organo/local_token`, perms `0600`, generated once and gitignored. CLI and browser mutation requests use it so loopback POST endpoints are not ambiently writable by any local web page.
- **Runtime state**: `.organo/runtime/`, gitignored, holds live per-item subprocess state. It is daemon-owned and may be deleted/rebuilt during restart recovery.

## Layout

```
<notes-root>/
├── .git/
├── .gitignore
├── stacks/
│   ├── default/                 # created eagerly at init
│   │   └── stack.toml           # committed; see design_stack_config.md
│   └── <other-stacks>/
└── .organo/
    ├── config.toml              # committed: project-wide defaults
    ├── config.local.toml        # gitignored: per-machine overrides
    ├── credentials/             # gitignored, permissions 0700
    │   └── <provider>/
    │       └── auth.toml        # permissions 0600
    ├── local_token              # gitignored, permissions 0600
    ├── runtime/                 # gitignored live item state
    ├── runs/                    # gitignored (transcript overflow, optional)
    ├── audit.log                # gitignored; format in design_errors_and_audit.md
    ├── daemon.pid               # gitignored
    └── daemon.log               # gitignored
```

`.gitignore` lines added by init:

```
.organo/config.local.toml
.organo/credentials/
.organo/local_token
.organo/runtime/
.organo/runs/
.organo/audit.log
.organo/audit.log.*
.organo/daemon.pid
.organo/daemon.log
```

`config.toml` is committed: it captures the project-wide identity-capability map and daemon defaults that should be part of project history. `config.local.toml` is per-machine and overrides `config.toml` at load time; it carries port, workdir allowlist, and machine-specific identities so multiple machines sharing the notes repo don't fight over the same file.

## config.toml Sketch (committed)

```toml
[daemon]
loopback_only  = true              # v1 invariant; flipping it is a backlog change
default_stack  = "default"

# Project-wide identities. Machine-specific identities go in config.local.toml.
[identity.claude-local]
type           = "mcp"
description    = "local Claude Code"
capabilities   = [
  "stack.default.read",
  "stack.default.append",
  "stack.default.insert",
]

[identity.codex-local]
type           = "mcp"
description    = "local Codex"
capabilities   = [
  "stack.default.read",
]

[provider.anthropic]
auth_kind      = "subscription"    # or "api-key"
# tokens live under .organo/credentials/, never in config.toml

[provider.gemini]
auth_kind      = "subscription"    # optional bonus provider; disabled unless probe passes

[provider.openai]
auth_kind      = "subscription"
```

## config.local.toml Sketch (per-machine, gitignored)

```toml
[daemon]
port           = 7421

[workdir]
allowlist = [
  "~/code",
  "~/notes",
]

# The local user identity is per-machine. Capabilities = ["*"] gives the
# local CLI/web full access on this machine. Other machines have their own.
[identity.local]
type           = "user"
description    = "the local user (CLI, web view) on this machine"
capabilities   = ["*"]
```

The `workdir.allowlist` constrains where the harness may run; items requesting a workdir outside this list are blocked at routing.

Load order: `config.toml` first, then `config.local.toml` is merged on top, last-write-wins per leaf key. Identities with the same name are replaced (not merged) so per-machine overrides are unambiguous.

## organo init Behavior

1. Resolve the notes root (cwd, override via `--root <path>`).
2. If the root is not a git repo, prompt to `git init` it (or proceed automatically when `--yes`).
3. Create the layout above if pieces are missing. Never overwrite an existing `config.toml`.
4. Generate `.organo/local_token` if absent. Never rewrite it once created.
5. Add the gitignore lines (idempotent — check before appending).
6. Print a summary of what was created vs. already present.
7. Exit zero.

## Daemon Lifecycle on Disk

- `organo daemon start` writes `daemon.pid` and appends to `daemon.log`. If `daemon.pid` already exists and the PID is alive, refuse to start (print the existing PID and port).
- `organo daemon stop` reads `daemon.pid`, sends SIGTERM, waits for the process to exit, then removes the PID file. SIGKILL after a configurable grace period.
- `organo daemon status` reads `daemon.pid` and reports running/stopped plus port and uptime.

systemd integration is not a v1 dependency — users who want unit-managed daemons can write their own unit file.

## To Decide

- Whether `config.toml` should support `include = "<path>"` so identity lists can be split across files (separate from the `config.local.toml` split; for very large identity rosters).
- Whether `organo init` writes a starter `README.md` describing the layout, or leaves that to the user.

### Resolved (was: To Decide)

- **Default stack creation**: eager at `init`.
- **Credentials layout**: per-provider directory under `.organo/credentials/<provider>/auth.toml`.
- **Notes root inside an existing git repo**: proceed, warn that the layout joins the existing repo's history.

## Implementation Plan

1. Implement layout creation and idempotent gitignore-append.
2. Implement the `config.toml` writer with a sensible default.
3. Implement `daemon.pid` / `daemon.log` handling and the `start/stop/status` commands.
4. Implement workdir-allowlist parsing and validation.
5. Add tests for re-running `init`, init on a non-git directory, init on an already-initialized root.

## Acceptance Criteria

- A fresh directory becomes a valid organo notes root in one command.
- Re-running `init` is safe and reports no changes.
- The daemon refuses to bind on a non-loopback interface as long as `loopback_only = true`.
- The PID file accurately reflects daemon state across start/stop cycles.
- Items requesting a workdir outside `workdir.allowlist` are rejected before harness launch.

## Dependencies

- `design_daemon.md`
- `design_authorization.md` (identity/capability schema)
- `design_version_control.md` (gitignore policy)
- `design_execution_harness.md` (workdir allowlist consumer)
- `design_stack_config.md` (the stack.toml created with each stack)
- `design_errors_and_audit.md` (audit log path, gitignore entries)
- `implement_cli_client.md` (the `init` and `daemon` subcommands)
