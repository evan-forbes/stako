# 05 — Mutations, Queue, and Version Control

## Goal

Make stacks useful before real harness execution lands: create stacks, append/insert items, retry blocked items, cancel or supersede work, pause/resume stacks, patch `stack.toml`, serialize all writes through one daemon-owned mutation queue, and commit stack-repo changes.

## Design Reference

- `../todos/implement_stacks.md`
- `../todos/design_version_control.md`
- `../todos/design_daemon.md`
- `../todos/design_state_machine.md`
- `../todos/design_errors_and_audit.md`
- `../todos/design_stack_config.md`
- `../todos/implement_cli_client.md`

## Steps

1. Implement the single-writer queue inside the daemon. Every mutation endpoint pushes a request; one worker drains it. Per-stack runtime loops wake from committed mutation events, but all disk writes still serialize through this worker.
2. Enforce the milestone-3 local bearer token on every non-GET HTTP endpoint. Missing or wrong token returns `identity_required` / `capability_denied` shape as appropriate; full per-identity policy waits until milestone 10.
3. Add the git wrapper for the notes repo only. Shelling out to `git` is fine for v1.
4. Add the audit log writer: append-only NDJSON to `.stako/audit.log`, perms 0600, no rotation in v1. Log allowed mutations and daemon lifecycle events. Denied authorization entries land in milestone 10.
5. Implement mutation endpoints, each wired to the queue:
   - `POST /stacks`
   - `POST /stacks/{name}/items`
   - `POST /stacks/{name}/items/{id}/insert`
   - `POST /stacks/{name}/items/{id}/retry`
   - `POST /stacks/{name}/items/{id}/cancel`
   - `POST /stacks/{name}/items/{id}/supersede`
   - `POST /stacks/{name}/pause`
   - `POST /stacks/{name}/resume`
   - `POST /stacks/{name}/config`
6. Implement `apply_transition` if it has not already landed with the item-format library:
   - Status writes only happen through this function.
   - API-callable transitions are limited to cancel, supersede, and blocked retry.
   - Internal transitions (`running`, `completed`, `failed`, `blocked`) are rejected over HTTP.
7. Implement stack creation:
   - Validate name: kebab-case, not reserved, not already present.
   - Create only under `<notes-root>/stacks/<name>/`.
   - Write `stack.toml` with defaults plus accepted request fields.
8. After each successful mutation, stage and commit only the affected stack files in the notes repo with the template from `design_version_control.md`.
9. Add conflict checks:
   - Refuse daemon startup if the notes repo has merge conflicts.
   - Reject a mutation if a targeted stack file has uncommitted user edits.
10. Add CLI mutation commands with short forms:
    - `stako stack new <name>` / `stako s new <name>`
    - `stako stack add <name> <kind> -t ... [-f ...]` / `stako s add ...`
    - `stako stack insert <name> <ref> ...` / `stako s ins ...`
    - `stako stack retry <name> <id>` / `stako s rt ...`
    - `stako stack cancel <name> <id>` / `stako s cx ...`
    - `stako stack supersede <name> <id> <replacement-id>` / `stako s sup ...`
    - `stako stack pause|resume <name>` / `stako s p|r <name>`
    - `stako stack config <name> --set key=value` / `stako s cfg <name> -s key=value`
11. Tests:
    - One mutation -> exactly one commit + one audit-log line.
    - Two simultaneous mutation requests -> serialized; both succeed; commit/audit order matches queue order.
    - Bad/missing local token rejects every non-GET endpoint.
    - `POST /stacks` then `GET /stacks` includes the created stack.
    - Pausing a stack flips only `stack.toml`; it does not alter item statuses.
    - Conflict-state startup and targeted dirty-file mutation both fail cleanly.

## Acceptance

- All v1 mutation endpoints work end-to-end through the CLI.
- Every non-GET endpoint requires the local token.
- `.stako/audit.log` records one NDJSON line per successful mutation with the schema from `design_errors_and_audit.md`.
- Commit grouping matches one user-visible mutation per commit.
- Half-failed mutations leave the repo clean: no staged changes, no partial commits, no audit-log line.
- The daemon never auto-commits arbitrary harness workdir changes.

## Out of Scope

- MCP-driven mutations.
- Per-identity capability checks.
- Remote pushes.
- Automatic commits in external workdir repositories.
