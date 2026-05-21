# Agents guide

This is a stako notes root. Stako queues prompts and routines onto
named stacks, then drives coding-agent harnesses through the local
daemon. Inputs and outputs are recorded as git commits.

## Safe mutation

- Write prompt source files under `prompts/`.
- Write routine TOML under `routines/`.
- Create stacks with `stako new <stack>`.
- Queue work with `stako add <routine> <stack>`.
- Resume work with `stako start <stack>`.

Do not edit stack item metadata by hand. Stack state under
`stacks/<stack>/` is daemon-owned; use the CLI or loopback API for
queue changes, starts, retries, cancellations, and thread updates.

## Writing prompts

Prompt files are plain markdown. Put the instructions, context, and
expected outputs in prompt files, not in routine TOML. Long prompts
can be split across multiple files and combined by a routine step.

## Writing routines

A routine is `routines/<name>.toml` with one or more `[[step]]`
blocks. Prompt paths are relative to the routine file. Each step
runs on a named thread; steps with the same thread reuse that agent
session when possible. Provider, model, and related routing settings
belong to the thread, not to individual steps.

```toml
thread = "builder"

[[step]]
prompts = ["../prompts/example/implement.md"]

[[step]]
thread = "reviewer"
prompts = ["../prompts/example/review.md"]

[[step]]
thread = "builder"
command = "compact"
```

Create another stack with `stako new <name>` when work needs its
own queue, thread history, and config.

## Driving stako programmatically

Besides the CLI, stako exposes a loopback JSON API on
`http://127.0.0.1:<port>` (`[daemon].port` in `config.toml`,
default 7421). Authenticate with the header
`Authorization: Bearer <token>`, the contents of
`state/local_token`. The `stako` Python SDK wraps it:

```python
from stako import Client, Routine, Stack

c = Client(root="~/stako")
r = Routine("fix").thread("builder").prompt("Fix the test.", thread="builder")
Stack(c, "default").add(r).start()
```

Key endpoints: `POST /stacks`, `POST /stacks/{s}/threads`,
`POST /stacks/{s}/routines/{r}`, `POST /stacks/{s}/items`,
`POST /stacks/{s}/resume`, `GET /stacks/{s}` (status),
`GET /stacks/{s}/events` (SSE).

## Common commands

```sh
stako daemon start
stako new <stack>
stako add <routine> <stack>
stako start <stack>
stako stack show <stack>
stako routine list
```
