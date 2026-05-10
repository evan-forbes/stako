# Design Version Control

## Scope

The daemon commits stack mutations and harness-produced stack artifacts to the notes git repository automatically. Stack history must be replayable. Commit grouping must reflect the unit of work, not the order in which file writes happened.

## Decided

- Stack directories live under the notes git repository (`<notes-root>/stacks/<name>/...`). They commit alongside everything else.
- The daemon is the only automated writer of stack files. Hand-edits by the user remain possible through normal editor flows.
- Each API mutation call → one commit. Multi-step daemon-internal operations group into a single commit when they exist; review follow-up grouping is deferred until MCP follow-ups exist.
- Daemon state under `<notes-root>/.organo/` is gitignored except for `config.toml`.

## Commit Grouping Rules

| Operation | Commit grouping |
|---|---|
| `append_item` | One commit containing the new item directory |
| `insert_item` | One commit; if existing IDs shift, the renames are in the same commit |
| `retry_item` / `cancel_item` / `supersede_item` | One commit touching only `meta.toml` |
| `pause_stack` / `resume_stack` | One commit touching `stack.toml` |
| `update_stack_config` | One commit touching `stack.toml` |
| Harness run (item completion) | One commit per item containing transcript and terminal `meta.toml` status/result update in the notes repo |
| Review item adding follow-ups | Deferred until MCP follow-up; core v1 reviews commit transcript/status only |

If an API call fails partway through, the daemon rolls back staged changes; no half-commits.

### Runtime state is not tracked

Live PID/session state lives under `.organo/runtime/`, which is gitignored. Runtime files are daemon state, not notes history. Tracked `meta.toml` receives only stable terminal metadata under `[result]` after a run completes or fails.

This avoids dirtying the notes repo for every running item and keeps conflict checks simple: targeted stack files are either clean or intentionally changed by the state writer.

## Commit Message Format

```
<scope>: <action> <subject>

stack: <stack-name>
item: <id>
identity: <calling-identity>
api: <endpoint>
```

Examples:

```
stack: append 0007-fix-router-validation

stack: default
item: 0007
identity: claude-local
api: POST /stacks/default/items
```

```
stack: complete 0005-route-prompts

stack: default
item: 0005
identity: harness:claude
api: harness-run
```

Scope vocabulary: `stack` for queue-shape mutations, `item` for content/status changes inside an existing item, `auth` for credential changes (under `.organo/config.toml` if those get committed at all).

## Hand-Edit Reconciliation

Hand-edits happen outside the daemon and produce normal user commits. The daemon does not need to detect them, but:

- The daemon reloads from disk on every API call that reads the stack, so user-committed edits are visible immediately.
- If the daemon has an in-memory view that conflicts with on-disk state (someone hand-edited while a mutation was in flight), the disk state wins and the in-memory cache is rebuilt.
- The daemon does not auto-commit user hand-edits; the user does that through their normal git workflow.

## Conflict Handling

- The daemon refuses to start if the notes repo has unresolved merge conflicts.
- A mutation against a stack with uncommitted user changes in the same files is rejected with a clear error (asking the user to commit or stash first).
- Two daemon-driven mutations cannot conflict because of the single-writer queue.

## Workdir Repos

If a stack item's harness workdir is a separate git repo (likely — most projects live outside the notes repo):

- The daemon does **not** auto-commit in that workdir in v1.
- The transcript records observed file-change events where the harness exposes them.
- External project commits remain the user's or harness's responsibility.
- A later design may add opt-in workdir commits, but it must define ownership, conflict handling, and an explicit manifest of changed paths.

## To Decide

- Whether to include the daemon-internal request ID in commit messages for traceability.

### Resolved (was: To Decide)

- **Push to remote**: never automatic. The daemon only commits locally. Remote pushes are an explicit user action via normal `git`.
- **Branch management**: the daemon never creates, switches, or deletes branches. All commits land on whatever branch is currently checked out. The user manages branching with normal `git` commands.
- **Status-only commit squashing**: not squashed. Each status transition produces its own commit. Aggregation is a backlog feature if churn becomes a problem.

## Implementation Plan

1. Add a git wrapper inside the daemon (shell out to `git` or vendor a Zig git library — `git` subprocess is fine for v1).
2. Wrap every mutation API endpoint in a transaction: preflight dirty/conflict check → write temp files and atomic-replace → stage exact affected paths → commit → audit → release writer.
3. Implement commit message templates per operation.
4. Add the conflict-detection startup check.
5. Add harness-completion commits for notes-repo artifacts only (`transcript.jsonl`, terminal `meta.toml` with `[result]`).
6. Add tests that assert one mutation = one commit, harness completion = one notes-repo commit, and no external workdir commit is attempted.

## Acceptance Criteria

- Every mutation results in exactly one commit in the notes repo.
- Harness completion produces one notes-repo commit for transcript/status/result metadata.
- The daemon does not commit external workdir repos in v1.
- Half-failed mutations leave no commits and no staged state.
- The daemon refuses to operate on a repo with merge conflicts.

## Dependencies

- `design_daemon.md`
- `implement_stacks.md` (mutation API)
- `design_execution_harness.md` (harness completion → commit)
- `design_init_and_layout.md` (gitignore content, repo structure)
- `design_stack_config.md` (stack.toml changes generate commits)
- `design_state_machine.md` (one commit per transition)
