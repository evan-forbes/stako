# Runtime Reliability Backlog

## Purpose

This document captures non-duplicate issues from the previous run that are not fully covered by the main design docs. The intent is to keep these actionable instead of burying them in an incident log.

## Second-Pass Review

These issues should not wait for the deferred TUI. Several are runtime or CLI
fixes that reduce operator pain immediately. The best sequencing is:

1. Fix scheduler readiness and blocked-reason status.
2. Fix completed-stack mutation hangs.
3. Add watch mode and PID tracking.
4. Add delivery phases and timeouts for action-bearing prompts.
5. Expose enough structured zellij/runtime data for later visual-settling UX.

Each issue below names the primary layer so implementation work can stay focused.

## Issue: Idle Exit With Incomplete Work

### Observed Behavior

`stako start` exits when it finds no immediately deliverable work. During the prior run this made a scheduling deadlock look like normal idleness. It also meant the operator had to relaunch Stako after adding new prompts.

### Design Direction

Add a resident mode:

```sh
stako start <stack> --watch
```

In watch mode, Stako stays alive, watches stack mutations and completion markers, and re-evaluates the graph after changes. Non-watch mode can keep the current "run until idle" behavior.

Layer: `cli.zig` for flag parsing, `zellij.zig` runtime loop for behavior, store state for runner metadata.

Precise behavior:

- Without `--watch`, `start` runs until no prompts are running or ready, then exits with an idle reason.
- With `--watch`, `start` stays alive until stopped, even when no work is currently ready.
- Watch mode wakes on filesystem changes when supported, or polls at a low interval.
- Watch mode records PID and start time.
- `status` distinguishes `idle_no_ready_work`, `idle_waiting_dependencies`, and `watching`.

### Implementation Plan

1. Add a filesystem watcher or low-cost polling loop scoped to one stack root.
2. Wake the scheduler on prompt mutation, result completion, and stack config changes.
3. Log clear idle reasons when no work is deliverable.
4. Show watch-mode state in `stako status`.

### Tests

- Non-watch mode exits after no ready/running work.
- Watch mode stays alive across an idle interval.
- Adding a prompt during watch mode triggers a scheduler pass.
- Completion marker creation during watch mode triggers dependency release.

## Issue: `stako add` Hangs on Fully Completed Stack

### Observed Behavior

After every prompt in a stack completed, `stako add` spun indefinitely before printing per-prompt output. Adding to a fresh stack worked.

### Design Direction

Completed stacks must remain mutable. A stack can be complete at one point in time and later receive post-stack follow-ups.

Layer: store mutation and CLI reporting.

Precise behavior:

- Adding a new prompt to an all-completed stack returns promptly.
- Existing completed prompts are reported as existing/completed, not rewritten.
- New post-stack prompts get `queued` status and append after existing nodes in
  `plan.toml`.
- Validation must work when every existing node is terminal.

### Implementation Plan

1. Add a regression test that loads a fully completed stack and adds one prompt.
2. Audit stack load/init loops for assumptions that at least one prompt is non-terminal.
3. Ensure graph recomputation handles all-terminal node sets.
4. Add timeout-free progress logging around stack load and validation.

### Tests

- Add one new prompt to a stack where every existing run is completed.
- Add a prompt that depends on a completed prompt.
- Add a duplicate prompt id whose existing run is completed; report existing/completed.
- Add to an empty stack with only thread files.

## Issue: Action Delivery Race

### Observed Behavior

Prompts with `action = "new"`, `action = "clear"`, or `action = "compact"` intermittently lost the actual prompt after Stako sent the slash command. The agent pane idled while Stako considered the prompt running.

### Design Direction

Prompt delivery should have an explicit handshake. Stako should not mark a prompt running merely because it sent bytes to zellij.

Possible mechanisms:

- Wait for the agent pane to settle after a slash command before sending the
  rendered prompt.
- Use a paste bracket or conservative send delay, with command-specific tuning
  deferred to the harness/model work.
- Ask the agent to echo a delivery token into the result directory before starting work.
- Detect lack of progress and transition to `delivery_failed` instead of remaining `running` forever.

Layer: runtime delivery state, zellij adapter, status output.

Precise behavior:

- A prompt with `action != none` enters `delivering_action`.
- After the action settle step, it enters `delivering_prompt`.
- After prompt delivery acknowledgement or best-effort completion, it enters `running`.
- If acknowledgement is not available, use a conservative settle delay plus a
  timeout.
- If delivery fails, mark `failed` with `delivery_failed` or `delivery_timeout`.

This needs a new delivery status field or an expanded prompt status enum. A separate `delivery_phase` field is probably better because `running` remains the high-level state.

### Implementation Plan

1. Split delivery into phases: action sent, prompt sent, delivery acknowledged, running.
2. Add conservative command/action settle delays for slash commands as a
   short-term mitigation.
3. Add a delivery timeout that marks the prompt `failed` with reason `delivery_timeout`.
4. Surface delivery phase in status JSON for CLI and deferred TUI consumers.
5. Add tests around phase transitions with a fake zellij adapter.

### Tests

- Fake adapter receives action before prompt.
- Prompt status is not set to `running` until prompt delivery phase finishes.
- Delivery failure marks run failed with a delivery reason.
- `action = "none"` bypasses action phase.
- Harness-specific delay configuration is parsed and applied.

## Issue: Pane Spinner After Done Marker

### Observed Behavior

Agents sometimes continued their visible turn after writing `result.md` and `done`. Stako correctly marked completion from the filesystem, but the pane still looked busy.

### Design Direction

Completion remains filesystem-based. The thread prompt should also instruct
agents to end their turn immediately after creating the done marker. Status JSON
should distinguish "Stako complete" from "pane visually settled" so a deferred
TUI can show that accurately.

Layer: prompt rendering and status JSON.

Precise behavior:

- `done` plus `result.md` remains the only completion source.
- Stako may record `completed_at` when it observes completion.
- Pane dumps can continue for debugging but should be labeled as visual/debug state.
- Thread boilerplate should explicitly ask the agent to stop after creating `done`.

### Implementation Plan

1. Update generated thread boilerplate to say: write result, create done marker, then end the turn.
2. Add status fields for `completed_at` and optional `pane_last_dump_at`.
3. Avoid treating pane spinner text as a source of truth.

### Tests

- Prompt rendering includes explicit result/done/stop instructions.
- Completion with result and done marks completed even if pane dump is unchanged.
- Missing result with done still marks failed.

## Issue: Poor Blocked-Reason Visibility

### Observed Behavior

`stako status` printed queued prompts uniformly even when metadata contained enough information to explain why a prompt was blocked.

### Design Direction

Status should compute and display readiness for every queued prompt. This overlaps with `05_graph_execution_model.md`, but it is valuable enough to track independently as a UX fix.

Layer: scheduler/readiness and CLI status.

Precise behavior:

- Every queued prompt has a computed readiness in status.
- Blocked dependencies include id and current status.
- Failed dependencies transition dependents to terminal `blocked`.
- Non-terminal blocked dependencies remain `queued` with computed blocked reason.

### Implementation Plan

1. Add a readiness computation over the graph.
2. Print blocked dependencies by id and status.
3. Include plan-order/readiness diagnostics until graph scheduling removes the
   old inversion failure mode.
4. Add JSON status output for scripts and deferred TUI consumption.

### Tests

- Queued prompt blocked by running dependency prints that dependency id.
- Queued prompt blocked by missing dependency reports invalid graph.
- Prompt blocked by failed dependency becomes terminal blocked.
- JSON status includes readiness and blocked ids.

## Issue: Unsafe Process-Kill Pattern

### Observed Behavior

Using `pkill -f 'stako start <stack>'` can match the shell command itself and kill the shell before follow-up commands run.

### Design Direction

Stako should provide its own stop command and PID tracking.

Layer: CLI and runtime metadata.

Precise behavior:

- `stako start --watch` records a runner PID file.
- `stako stop <stack>` reads the PID file, verifies the process still appears to be the Stako runner for this stack, then signals it.
- Stale PID files are removed or reported.
- `status` shows runner PID, stale/running state, and watch mode.

### Implementation Plan

1. Record runner PID in stack runtime metadata.
2. Add `stako stop <stack>`.
3. Add stale PID detection.
4. Show runner PID and watch mode in status.

### Tests

- Stop command rejects missing PID file cleanly.
- Stop command detects stale PID.
- Stop command refuses to kill a process that does not match stack runner metadata.
- Status shows runner state.

## Additional Non-Duplicate Issue: Zellij Session Conflict Ambiguity

### Observed Behavior

Stako records a basic ownership marker, but operators need clearer feedback when a zellij session with the same name exists and is not owned by Stako.

### Design Direction

Session ownership should be explicit in runtime metadata and status. Stako should avoid attaching automation to unrelated sessions unless the user passes a force/adopt flag.

Layer: zellij adapter and runtime metadata.

### Implementation Plan

1. Store session name, owner marker, and created timestamp.
2. On start/open, detect existing sessions without Stako ownership.
3. Print a clear error with `--session-name` or `--adopt-session` guidance.
4. Surface ownership in `status`.

### Tests

- Existing unowned session causes `SessionConflict`.
- Existing owned session is reused.
- Stale metadata with no zellij session recreates safely.

## Acceptance Criteria

- Completed stacks can accept new prompts.
- Watch mode keeps a stack responsive to new graph mutations.
- Action-bearing prompts either deliver reliably or fail with a clear delivery error.
- Status explains blocked queued work.
- Operators can stop a runner without shell pattern matching.
