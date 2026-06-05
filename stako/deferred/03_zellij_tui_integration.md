# Zellij TUI Integration Design

## Problem

Stako is zellij-first, but the operator experience is still manual: start the stack, attach to zellij, inspect tabs, run status commands, and recover stuck prompts by hand. The desired workflow is one zellij session with the Stako TUI on the first tab and agent threads on subsequent tabs.

## Goals

- Open or attach to a zellij session for a stack.
- Put a Stako TUI/control surface in the first tab.
- Keep one durable zellij tab per thread.
- Show graph status, blocked reasons, result paths, and live actions.
- Allow manual creation of a new stack from a prompt folder while already inside zellij.

## Second-Pass Review

The TUI should be a client of the runtime model, not a second scheduler. The best first version is a zellij-aware control surface that reads structured status and invokes Stako commands for mutations. Once status, graph scheduling, and path metadata are solid, the TUI becomes much simpler and less risky.

The zellij integration should also be split into two pieces:

- session orchestration: create or attach session, create control tab, ensure thread tabs
- TUI application: render graph, paths, runtime state, and invoke actions

This separation matters because `stako open` is useful even before a full TUI exists.

## Proposed Commands

```sh
stako tui [--root PATH]
stako tui <stack> [--root PATH]
stako open <prompt-folder> [--root PATH] [--cwd PATH] [--name NAME]
stako open <stack> [--root PATH]
```

`stako open` should:

1. Infer stack configuration from the prompt folder.
2. Create the stack if needed.
3. Start or attach to the zellij session.
4. Ensure the first tab runs the TUI.
5. Ensure thread tabs exist for the stack.

If the argument is an existing directory, `open` uses prompt-folder mode. If it is a stack name, it opens the existing stack.

## Zellij Ownership Model

Stako should record enough zellij metadata to avoid taking over unrelated sessions:

```toml
session_name = "stako-discovery-gen"
control_tab_name = "stako"
owner = "stako"
created_at = "2026-06-04T12:34:56Z"
```

Thread metadata should record tab and pane ids, but pane ids should be treated as recoverable runtime handles. If a pane id is stale, Stako should rediscover by tab name or recreate the tab when no prompt is running.

Session naming should avoid collisions with user-created zellij sessions. A good default is `stako-<stack-name>`, with a stored value so later commands do not recalculate differently.

## TUI Screens

| Screen | Purpose |
|---|---|
| Stack list | Select stacks under the current root and see running/blocked/complete counts. |
| Stack graph | Main view: nodes, dependencies, status, thread assignment, and ready/blocked state. |
| Prompt detail | Prompt body, rendered prompt path, result path, done marker, zellij tab, logs. |
| Insert follow-up | Pick a prompt file or create a placeholder, choose gated targets, add `after` / `inputs`. |
| Directory view | Show prompt folder, stack root, agent cwd, worktree, and artifact roots. |
| Harness view | Show each thread's harness, command argv, requested model, resolved model, and model warnings. |
| Runtime view | Runner process, watch mode, zellij session name, thread tabs, stuck delivery warnings. |

The TUI should be a client of core runtime APIs. It should not own scheduling or mutate files directly except through Stako commands or daemon endpoints.

## Action Model

The first TUI should support actions that map to existing or planned commands:

| TUI Action | Backing Command/API |
|---|---|
| Open stack | `stako open <stack>` |
| Start/resume runner | `stako start <stack>` or `stako start <stack> --watch` |
| Stop runner | `stako stop <stack>` |
| Insert follow-up | `stako inject` / `stako flup` |
| Focus thread tab | zellij focus action when reliable |
| Show output | store output/result paths, not pane text as truth |
| Show paths | `stako paths <stack>` |

The TUI should not offer destructive actions such as deleting runs until the graph mutation API and audit trail are mature.

## Zellij Layout

Recommended tab layout:

```text
tab 1: stako tui
tab 2: implementer
tab 3: checker
tab 4: reviewer
...
```

The TUI should know each thread's tab name and expose quick attach/focus actions. If zellij supports sending a focus command reliably, Stako can focus a thread tab from the TUI. Otherwise, the TUI should still display the exact tab names.

## Manual-First Workflow

The desired daily workflow can be supported incrementally:

1. Operator opens zellij manually.
2. Operator runs `stako tui` in the first tab.
3. TUI can create or select a stack from a prompt folder.
4. TUI starts the runner, which creates thread tabs in the same session.

This avoids requiring perfect zellij session bootstrapping before the TUI is useful.

## Integration Details

- The stack config should record the zellij session name.
- Thread metadata should record the zellij tab name.
- The runner should treat pane dumps as debug output only.
- Completion must remain filesystem-based through `result.md` and `done`.
- The TUI should surface action delivery state for `new`, `clear`, and `compact`, because prior runs showed prompt delivery can race after slash commands.

Structured data needed by the TUI:

- graph nodes and edges
- computed readiness and blocked reasons
- path configuration
- runner PID and watch mode
- zellij session, tab, and pane handles
- thread harness, command argv, requested model, and resolved model
- prompt result path, done marker path, and output path
- delivery phase for running prompts

This should come from `status --json`, `graph --json`, `paths --json`, or a small daemon API. Shelling out to text status is acceptable only for a prototype.

## TUI Library Direction

The implementation should pick a Zig TUI library only after the structured CLI/API is available. The first prototype can even be line-oriented if that accelerates the data model. A polished TUI is valuable, but the scheduling and mutation logic must not depend on it.

Selection criteria:

- works with Zig 0.15.2
- handles terminal resize
- supports keyboard navigation and tables/lists
- does not require owning the zellij session
- can be tested with deterministic snapshots or model-level tests

## Implementation Plan

1. Add structured `status --json`, graph output, and path output.
2. Add stack metadata for zellij session name, control tab name, and thread tab names.
3. Add `stako open <stack>` to attach/create the zellij session and ensure the control tab.
4. Add `stako open <prompt-folder>` by composing folder planning, stack creation, and zellij opening.
5. Add a read-only TUI prototype that consumes structured status.
6. Add graph navigation and prompt detail views.
7. Add harness/model display using the shared resolver and structured status from `deferred/08_harness_model_support.md`.
8. Add follow-up insertion UI backed by `stako inject`.
9. Add runner controls backed by `start --watch` and `stop`.
10. Add zellij focus/attach integration where reliable.
11. Add warnings for missing tabs, stale panes, stuck running prompts, and action delivery uncertainty.

## Test Plan

- `stako open <prompt-folder>` creates or selects the expected stack and records session metadata.
- `stako open <stack>` attaches to an existing stack without re-planning prompts.
- Stale pane ids are detected and recovered when no prompt is running.
- Stako refuses to take over a zellij session that lacks the Stako ownership marker.
- TUI model tests render graph status from structured fixtures.
- Follow-up insertion from the TUI calls the same mutation path as the CLI.

## Acceptance Criteria

- Running `stako open ./stako/my-stack` lands the user in a zellij session with a Stako control tab.
- The TUI shows the graph and blocked reasons without reading pane text as source of truth.
- The TUI can inject a follow-up and link it to a gated prompt.
- The TUI displays path configuration clearly enough to catch root/cwd/worktree mistakes before start.
- The TUI shows omitted model values as harness defaults and shows nickname resolution when a model is set.
