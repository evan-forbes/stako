---
name: stako
description: Use when creating, queueing, inspecting, or repairing Stako stacks in the zellij-first workflow. Stako runs prompt queues on durable agent threads backed by zellij tabs.
---

# Stako

Stako is a small queue runner for coding agents.

Core model:

- A stack is a queue of prompt files.
- A thread is one long-lived agent session in a zellij tab.
- Each prompt targets one thread.
- Same-thread prompts run serially.
- Different-thread prompts may run in parallel unless a prompt declares `after` or `inputs`.
- The thread prompt is prepended every time work is sent to that thread, including after `new`, `clear`, and `compact`.
- Durable content moves between threads through per-prompt `result.md` files, and completion is signaled by per-run `done` marker files. Do not use zellij pane text as handoff or completion content.

Before relying on exact CLI details, read this repo's `README.md`; it is the source of truth for the current branch.

## Minimal-Impact Rules

- Treat Stako as an orchestration layer. Do not edit the user's application repo unless the queued prompt explicitly asks for that.
- Prefer a short stack name derived from the task, for example `add-rate-limiter`.
- Prefer sortable prompt ids: `001-plan`, `002-implement`, `003-review`.
- Do not delete stack state, zellij tabs, prompts, outputs, or notes-root history unless explicitly asked.
- Check `stako status <stack>` before changing an existing stack.
- Use `after = [...]` for required synchronization. Let independent prompts target separate threads without dependencies.
- Use `inputs = [...]` when a prompt must read another prompt's durable result file. `inputs` also blocks until the source prompt completes.
- Prefer `stako link <source.md> <target.md> --pre-cmd compact` to wire review-output-to-implementation-input handoffs.
- Keep thread prompts stable and role-oriented. Put task-specific detail in queued prompts.

## Basic Workflow

Create a stack:

```sh
stako new <stack> --command codex --cwd /path/to/repo
```

`--cwd` is the directory the agent threads launch in (the repo they work on),
resolved to an absolute path at creation time. Omit it to inherit the directory
`stako start` runs from.

Write a thread file:

```md
+++
type = "thread"
thread = "builder"
+++

You are the implementation thread.
Read the prompt, make the requested change, run checks, and report the result.
```

`--command` on the stack is the default harness command for every thread. A thread can override it:

```md
+++
type = "thread"
thread = "reviewer"
command = "claude"
+++

Review the implementation for correctness and missing tests.
```

Write a prompt file:

```md
+++
id = "001-implement"
thread = "builder"
+++

Implement the requested change.
```

Queue files:

```sh
stako add <stack> builder.md 001-implement.md
```

Start or resume ready work:

```sh
stako start <stack>
```

`stako start` keeps polling and delivering work until the stack is idle.

Inspect and attach:

```sh
stako status <stack>
stako attach <stack>
stako output <stack> 001-implement
```

`stako output` is raw pane dump output for debugging. Downstream prompts read `result.md` files.

## Prompt Front Matter

Thread and prompt files use TOML front matter delimited by `+++`.

Thread fields:

- `type = "thread"`: marks the file as a thread file.
- `thread`: target thread name.
- `command`: optional harness command for this thread, for example `claude`; defaults to the stack command from `stako new`.

Required fields:

- `id`: unique id in the stack.
- `thread`: target thread name.

Optional fields:

- `after`: list of prompt ids that must complete first.
- `inputs`: list of prompt ids whose `result.md` files should be passed to this prompt.
- `action`: `none`, `new`, `clear`, or `compact`.

Actions send a slash command before the rendered prompt:

- `new` sends `/new`
- `clear` sends `/clear`
- `compact` sends `/compact`

The rendered prompt is stack prompt, then thread prompt, then input result file paths, then prompt body, then the result-file contract, then the completion marker instruction.

Every run has a predetermined durable result file and completion marker:

```text
<root>/stacks/<stack>/runs/<prompt-id>/result.md
<root>/stacks/<stack>/runs/<prompt-id>/done
```

Agents must write the final downstream handoff content to `result.md`, then create `done`. The marker can be empty, but it must not exist before the result is complete. If `done` exists but `result.md` is missing, Stako marks the run `failed` with `missing_result_file`.

## Sync And Parallel

Stako's blocking rule is intentionally simple:

- Prompts on the same thread are serial.
- Prompts on different threads are eligible to run together.
- `after = ["some-id"]` blocks until `some-id` is completed.
- `inputs = ["some-id"]` passes the absolute path to `runs/some-id/result.md` and also blocks until `some-id` is completed.

Example reviewer prompt that waits for implementation:

```md
+++
id = "003-review"
thread = "reviewer"
after = ["002-implement"]
+++

Review the implementation produced by 002-implement.
```

Example implementation prompt that receives only the review result:

```md
+++
id = "004-address-review"
thread = "builder"
after = ["003-review"]
inputs = ["003-review"]
action = "compact"
+++

Address the reviewer findings.
```

Wire that front matter mechanically with:

```sh
stako link 003-review.md 004-address-review.md --pre-cmd compact
```

## Current CLI

```sh
stako new <stack> [--command codex] [--cwd PATH] [--root PATH]
stako add <stack> <thread-or-prompt.md...> [--root PATH]
stako link <source-prompt.md> <target-prompt.md> [--pre-cmd compact]
stako start <stack> [--root PATH]
stako attach <stack>
stako status <stack> [--root PATH]
stako output <stack> <prompt-id> [--root PATH]
```

The default root is `~/stako`.

## Current Limits

- Queue order is insertion order. Prompt ids are stable names and dependency targets.
- Raw output capture dumps the zellij pane for debugging. Completion and durable handoff content are filesystem based: `done` and `result.md`.
