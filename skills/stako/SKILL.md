---
name: stako
description: Use when creating, queueing, inspecting, or repairing Stako stacks, routines, prompts, daemon-backed runs, Python SDK workflows, or Claude/Codex multi-agent implementation and review loops. Helps run Stako with minimal impact on unrelated work.
---

# Stako

Stako is a stack-based meta-harness for coding agents. It queues prompts and routines onto named stacks, runs them through Claude Code or Codex, and records inputs and outputs as commits in the Stako notes-root git repo.

## Minimal-Impact Rules

- Treat Stako as an orchestration layer. Do not edit the user's application repo unless the Stako task explicitly asks for that.
- Prefer a unique stack name derived from the task, for example `add-rate-limiter` or `review-api-auth`.
- Write new prompts under `<root>/prompts/` and new routines under `<root>/routines/`; avoid modifying existing prompts or routines unless the user asked to revise them.
- Do not delete stacks, state, transcripts, prompts, routines, auth tokens, or notes-root history unless explicitly requested.
- Check status before changing runtime state: `stako daemon status`, `stako auth status`, and `stako stack show <stack>` when the stack may already exist.
- If the daemon is already running, leave it running. If it is stopped and a run is requested, start it with `stako daemon start`.
- When reworking a completed item, prefer `stako stack rerun` or a follow-up prompt/routine over mutating prior outputs.
- Before relying on exact CLI/API details, read this repo's `README.md`; it is the source of truth for current Stako commands.

## Setup Check

Use these checks before queueing work:

```sh
stako daemon status
stako auth status
stako routine list
stako stack list
```

If Stako has not been initialized, use:

```sh
stako init
stako daemon start
```

The default root is `~/stako`. Daemon-backed commands accept `--root <path>`, `--port <n>`, `--json`, and `--verbose`; `STAKO_PORT` overrides the port when no local config is present.

## Basic Workflow

1. Create a stack:

```sh
stako new <stack>
```

2. Add prompt markdown under `<root>/prompts/<topic>/`.

3. Add a routine TOML under `<root>/routines/<routine>.toml`:

```toml
[[step]]
thread = "builder"
prompts = ["../prompts/<topic>/implement.md"]

[[step]]
thread = "reviewer"
prompts = ["../prompts/<topic>/review.md"]
```

4. Queue and run it:

```sh
stako add <routine> <stack>
stako start <stack>
```

5. Inspect progress and artifacts:

```sh
stako stack show <stack>
stako stack threads <stack>
stako stack thread show <stack> <thread>
stako stack item <stack> <id>
stako stack item <stack> <id> --rendered
```

The web UI is served by the daemon at `http://127.0.0.1:<port>/`, usually port `7421`.

## Inputs and Follow-Ups

Attach explicit context when queueing a routine:

```sh
stako add <routine> <stack> --input-file <path>
stako add <routine> <stack> --input-item <id>
stako add <routine> <stack> --input-commit <sha>
```

For queued work, edit the prompt in place only when that is the intended operation:

```sh
stako stack edit-prompt <stack> <id> --prompt-file <file>
```

For completed work, fork a new item instead:

```sh
stako stack rerun <stack> <id> --prompt-file <file>
```

For review/fix loops, add a short fix prompt and queue it on the builder thread so the next reviewer sees the new commit.

## Python SDK

Use the SDK when generating workflows programmatically or when one-off shell materialization would be clumsy:

```python
from stako import Client, Prompt, Routine, Stack

client = Client(root="~/stako")

routine = (
    Routine("implement-and-review")
    .thread("builder", provider="openai", model="gpt-5")
    .thread("reviewer", provider="anthropic")
    .prompt(Prompt.from_file("docs/task.md"), thread="builder")
    .prompt("Review the builder's commit for correctness.", thread="reviewer")
)

Stack(client, "task-stack").create().add(routine).start()
```

The SDK writes prompt and routine source files under the notes root, then calls the daemon API. The daemon owns stack state on disk.

### Parameterize scripts with a params TOML — never build a CLI

When a script needs inputs, take them from a **params TOML**, not a hand-written `argparse`/`click` CLI. Two tables, and only these two:

- `[stako]` — SDK-typed and validated: `root`, `port`, `host`, `stack`, and `[stako.inputs]` (`files`, `items`, `commits`, `mode`). Unknown keys here error out.
- `[params]` — the script's own free-form values, passed through untouched.

Any other top-level key is rejected. Load with `Params.load()`, which reads the path from `argv[1]` and falls back to `$STAKO_PARAMS`:

```python
from stako import Params, Routine

params = Params.load()              # argv[1], else $STAKO_PARAMS
stack = params.target_stack()       # Client + stack resolved from [stako]

routine = (
    Routine("implement")
    .thread("builder", provider="anthropic")
    .prompt(f"Implement {params.get('target_module')}.", thread="builder")
)
stack.add(routine, inputs=params.stako.inputs).start()
```

```toml
[stako]
root  = "~/stako"
stack = "add-rate-limiter"
[stako.inputs]
files = ["docs/notes.md"]

[params]               # anything the script defines
target_module = "ratelimit"
```

Run it as `python script.py params.toml`. Keep stako-relevant fields under `[stako]` so they stay typed; put everything script-specific under `[params]`.

## HTTP API

Use the loopback JSON API for custom clients. Read `<root>/state/local_token`, send `Authorization: Bearer <token>`, and use the daemon port from `<root>/config.toml`.

Common endpoints:

- `POST /stacks` creates a stack.
- `POST /stacks/{s}/threads` declares a thread.
- `POST /stacks/{s}/routines/{r}` queues a routine already present on disk.
- `POST /stacks/{s}/items` appends one item.
- `POST /stacks/{s}/resume` starts or resumes execution.
- `GET /stacks/{s}` inspects stack state.
- `GET /stacks/{s}/items/{id}/rendered-prompt` shows exact harness input.
- `GET /stacks/{s}/items/{id}/output` shows committed output.
- `GET /stacks/{s}/events` streams SSE run events.

## Prompting Guidance

- Tell the agent what to read, what to do, and what to write back.
- Register important inputs explicitly with `--input-file`, `--input-item`, or `--input-commit` instead of assuming ambient context.
- Use separate threads for independent reviews so Claude and Codex do not share one running context.
- Keep repair prompts narrow: identify the item or commit to inspect, list the required fix, and ask for validation.
