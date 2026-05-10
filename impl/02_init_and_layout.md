# 02 — Init and Layout

## Goal

Implement `organo init` and produce a valid notes-root layout. After this milestone, a fresh directory can be turned into an organo workspace in one command.

## Design Reference

- `../todos/design_init_and_layout.md`
- `../todos/design_stack_config.md` (default stack's stack.toml)

## Steps

1. CLI scaffolding: a single binary (`organo`) with subcommand routing. Just enough parser to dispatch `init` for now.
2. Resolve `--root` flag and cwd default.
3. Detect whether the root is a git repo; prompt or auto-init based on `--yes`.
4. Create the layout: `stacks/default/`, `stacks/default/stack.toml` (defaults), `.organo/`, `.organo/credentials/` with perms 0700, and `.organo/runtime/`.
5. Generate `.organo/local_token` if absent, perms 0600. Never rewrite it on subsequent `init` runs.
6. Write `.organo/config.toml` (committed defaults) and `.organo/config.local.toml` (per-machine: port, workdir allowlist, local-user identity) per `design_init_and_layout.md`.
7. Write/append `.gitignore` lines (including `config.local.toml`, `local_token`, `runtime/`, `audit.log`, etc.), idempotent.
8. Print a summary table of what was created vs. present.
9. Idempotency tests: run init twice, assert second run reports zero changes and preserves the same `local_token`.
10. Negative tests: init inside a directory whose parent is a git repo — emit a warning, continue (or refuse — pick one and lock it here).

## Acceptance

- `organo init` on a fresh empty directory produces the documented layout.
- Re-running is a no-op with a clear "already initialized" message.
- `config.toml` is valid TOML and parseable by milestone 1's reader (sanity check).
- `.organo/credentials/` exists with perms 0700.
- `.organo/runtime/` exists, is gitignored, and is empty after init.
- `.organo/local_token` exists with perms 0600, is gitignored, and survives idempotent init unchanged.

## Out of Scope (deferred)

- No daemon process management yet (that's milestone 3).
- No identity registration UI — identities are hand-edited into `config.toml` until a later milestone justifies otherwise.
- No provider status or credential files yet (that's milestone 8).
