# stako

Stako is a tiny queue runner for coding agents.

The model is deliberately small:

- A **stack** is a queue of prompt files.
- A **thread** is one long-lived agent session in a zellij tab.
- Each prompt targets one thread.
- Prompts on the same thread run one at a time.
- Prompts on different threads may run in parallel unless they declare `after`.
- A thread prompt is prepended every time a prompt is delivered, including after `new`, `clear`, and `compact` actions.

Stako stores the queue on disk, starts one zellij tab per thread, and pastes prompts into the relevant tab. Durable content moves between threads through per-prompt `result.md` files, and completion is signaled by a per-run `done` marker file, not by zellij pane text.

## Install

Prerequisites:

- Zig 0.15.2
- `zellij`
- the agent CLI you want to run, usually `codex` or `claude`

```sh
make build
make install
make skill
```

`make skill` installs the bundled Stako skill for Codex and Claude by symlinking `skills/stako`.

## Quick Start

Create a stack:

```sh
stako new my-work --command codex
```

Write a thread prompt:

```md
+++
type = "thread"
thread = "builder"
+++

You are working in the user's repository.
Read the task, make the requested change, run the relevant checks, and report the result.
```

Write a prompt:

```md
+++
id = "001-plan"
thread = "builder"
+++

Inspect the repository and write a short implementation plan.
```

Queue both files:

```sh
stako add my-work builder.md 001-plan.md
```

Start the stack:

```sh
stako start my-work
```

`start` watches the stack until it is idle: it polls running prompts for their `done` marker, delivers newly unblocked prompts, and exits when nothing is running or ready.

Attach to the zellij session:

```sh
stako attach my-work
```

Inspect status and output:

```sh
stako status my-work
stako output my-work 001-plan
```

`stako output` is raw pane dump output for debugging. Downstream prompts read `result.md` files.

## Prompt Files

All input files are Markdown with TOML front matter delimited by `+++`.

Thread files define reusable per-thread behavior:

```md
+++
type = "thread"
thread = "reviewer"
+++

Review the latest implementation for correctness, missing tests, and unnecessary complexity.
Do not make code changes unless explicitly asked.
```

Prompt files define queued work:

```md
+++
id = "002-review"
thread = "reviewer"
after = ["001-plan"]
inputs = ["001-plan"]
+++

Review the plan and call out concrete risks before implementation starts.
```

Fields:

- `id`: unique prompt id within the stack. Use sortable ids such as `001-plan`, `002-implement`, `003-review`.
- `thread`: target thread name.
- `after`: optional list of prompt ids that must complete first.
- `inputs`: optional list of prompt ids whose `result.md` files should be passed to this prompt. Inputs also block until the source prompt completes.
- `action`: optional thread action: `none`, `new`, `clear`, or `compact`.

`action` sends the matching slash command before the prompt body:

- `new` sends `/new`
- `clear` sends `/clear`
- `compact` sends `/compact`

The rendered prompt is always:

1. stack prompt from `stack.md`
2. target thread prompt
3. input result file paths from `inputs`
4. queued prompt body
5. result file instructions
6. completion marker instructions

Every run has a predetermined durable result file and completion marker:

```text
<root>/stacks/<stack>/runs/<prompt-id>/result.md
<root>/stacks/<stack>/runs/<prompt-id>/done
```

The agent must write the final downstream handoff content to `result.md`, then create `done`. The marker can be empty, but it must not exist before the result is complete. If `done` exists but `result.md` is missing, Stako marks the run `failed` with `missing_result_file`.

## Sync And Parallel

Parallelism is implicit. If two queued prompts target different threads and have no unmet dependencies, `stako start` can deliver both.

Synchronization is explicit:

```md
+++
id = "003-review"
thread = "reviewer"
after = ["002-implement"]
+++

Review the implementation produced by 002-implement.
```

Same-thread prompts are serialized. Different-thread prompts block when `after` or `inputs` says they block.

Content handoff is explicit with `inputs`:

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

When this prompt is delivered, Stako includes the absolute path to:

```text
<root>/stacks/<stack>/runs/003-review/result.md
```

The builder reads that file. Stako does not scrape the reviewer pane to decide what content matters.

To wire a source prompt into a target prompt:

```sh
stako link 003-review.md 004-address-review.md --pre-cmd compact
```

`link` rewrites the target prompt front matter so `after` and `inputs` include the source prompt id and `action` is set to the requested pre-command.

## CLI

```sh
stako new <stack> [--command codex] [--root PATH]
stako add <stack> <thread-or-prompt.md...> [--root PATH]
stako link <source-prompt.md> <target-prompt.md> [--pre-cmd compact]
stako start <stack> [--root PATH]
stako attach <stack>
stako status <stack> [--root PATH]
stako output <stack> <prompt-id> [--root PATH]
```

The default root is `~/stako`.

## Current Limits

- Queue order is insertion order. Prompt ids are still used as stable names and dependency targets.
- Raw output is captured by dumping the zellij pane for debugging. Completion and durable handoff content are filesystem based: `done` and `result.md`.

## Development

```sh
make build
make test
zig build -Doptimize=ReleaseFast test
```
