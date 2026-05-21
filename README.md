# stako

Stako is a stack-based meta-harness for coding agents. You queue prompts and routines onto a stack, and stako drives them through the harnesses you already use (Claude Code, Codex). Inputs and outputs travel as git commits, so the work stays visible and revertable.

## Setup (once)

**Prerequisites:** `claude` and `codex` on your `PATH` and signed in, plus a Zig toolchain to build from source.

```sh
make install         # build stako, install to $HOME/.local/bin
stako init           # bootstrap ~/stako with the standard layout
stako daemon start   # serve the loopback API (leave running)
```

`init` creates `~/stako/` with `prompts/` and `routines/` directories, `stacks/default/stack.toml`, an `AGENTS.md` primer, a documented `config.toml`, and a local auth token under `state/`. Confirm provider sign-in with `stako auth status`. Run the commands below in another terminal while the daemon runs.

## Human CLI authoring

### 1. Create a stack

A stack lives at `~/stako/stacks/<name>/`. Every step it runs produces a commit in the notes-root git repo, scoped to that stack's files. Inputs you register on an item (file, commit, or prior item) become explicit context the agent sees.

```sh
stako new add-rate-limiter
```

### 2. Write prompts

Prompts live in `~/stako/prompts/` as plain markdown. Tell the agent what to read, what to do, and what to write back.

```text
~/stako/prompts/rate-limiter/
  implement.md
  review.md
```

### 3. Write a routine

A routine in `~/stako/routines/<name>.toml` is an ordered list of steps that apply prompts. Steps on the same thread run in one agent context. A step can switch threads to run on a different harness.

> **Threads** are persistent agent sessions scoped to a stack. Same-thread steps share one running context. Different-thread steps run in their own contexts.

`~/stako/routines/implement-and-review.toml`:

```toml
[[step]]
thread = "builder"
prompts = ["../prompts/rate-limiter/implement.md"]

[[step]]
thread = "claude-review"
prompts = ["../prompts/rate-limiter/review.md"]

[[step]]
thread = "codex-review"
prompts = ["../prompts/rate-limiter/review.md"]
```

The builder writes the implementation commit. Each reviewer reads that commit on its own thread, so Claude and Codex give independent audits.

### 4. Queue it and start

```sh
stako add implement-and-review add-rate-limiter
stako start add-rate-limiter
stako stack show add-rate-limiter
```

`add` appends the routine to the stack. `start` resumes execution. `stack show` displays items and status.

## Python SDK

```sh
pip install ./sdk/python
```

A thin local client for generated workflows: it writes prompt and routine source files under the notes root, then calls the daemon API for stack creation, thread targeting, queueing, prompt edits, re-runs, and start/resume. It never edits stack state on disk — the daemon owns that.

```python
from stako import Client, Prompt, Routine, Stack

client = Client(root="~/stako")

routine = (
    Routine("implement-and-review")
    # Declare each thread once with its provider/model; steps target it by name.
    .thread("builder", provider="openai", model="gpt-5")
    .thread("reviewer", provider="anthropic")
    # Each .prompt(...) appends one step, in order. Chain as many as you need.
    .prompt(
        Prompt.combine(
            Prompt.text("Read the registered inputs."),
            Prompt.from_file("docs/rate-limiter-notes.md"),
        ),
        thread="builder",
    )
    .prompt(
        "Review the builder's commit for correctness and missing tests.",
        thread="reviewer",
    )
    # Add a new step any time — here a second builder pass that sees the review.
    .prompt("Address the reviewer's findings and commit the fix.", thread="builder")
    # .compact(...) appends a step that condenses that thread's context so a long
    # session keeps running without overflowing the harness's context window.
    .compact(thread="builder")
)

Stack(client, "add-rate-limiter").create().add(routine).start()
```

This materializes one file per prompt step (compact steps carry no file):

```text
~/stako/prompts/generated/implement-and-review/step-0001.md
~/stako/prompts/generated/implement-and-review/step-0002.md
~/stako/prompts/generated/implement-and-review/step-0003.md
~/stako/routines/implement-and-review.toml
```

The same client edits and inspects work after it is queued:

```python
stack = client.stack("add-rate-limiter")
stack.get_prompt("0001")                  # current prompt text, or None
stack.edit_prompt("0001", "Revised …")    # overwrite a queued item in place
stack.rerun("0002", "Try again, but …")   # fork a finished item with a new prompt
```

## HTTP API (write your own client)

The SDK is a thin wrapper over a loopback JSON API; drive stako from any language:

- **Base URL:** `http://127.0.0.1:<port>` — `port` is `[daemon].port` in `<root>/config.toml` (default 7421).
- **Auth:** every request needs `Authorization: Bearer <token>`, where `<token>` is the contents of `<root>/state/local_token`.
- **Errors:** non-2xx responses carry `{"error":{"code":…,"message":…}}`.

| Method & path | Purpose |
| --- | --- |
| `POST /stacks` `{"name"}` | create a stack |
| `POST /stacks/{s}/threads` `{"name","target"}` | declare a thread (do this before items target it) |
| `POST /stacks/{s}/routines/{r}` `{"inputs"?}` | queue routine `r` (must already exist on disk) |
| `POST /stacks/{s}/items` | append one item (body below) |
| `POST /stacks/{s}/resume` | start / resume execution |
| `GET  /stacks/{s}` | stack, items, and status |
| `GET  /stacks/{s}/items/{id}` | item detail (inputs, thread, result) |
| `GET  /stacks/{s}/items/{id}/rendered-prompt` | exact text sent to the harness (`?meta=1` → size only) |
| `GET  /stacks/{s}/items/{id}/output` | committed output |
| `POST /stacks/{s}/items/{id}/prompt` `{"prompt"}` | edit a **queued** item's prompt in place |
| `GET  /stacks/{s}/events` | SSE stream of run events |

Append-item body — only `kind` and `slug` are required:

```json
{
  "kind": "prompt",
  "slug": "implement",
  "prompt": "Read the inputs and implement the change.",
  "thread": {"name": "builder", "mode": "fresh"},
  "inputs": {"items": ["0001"], "files": ["docs/spec.md"], "mode": "append"},
  "parents": ["0001"]
}
```

`thread.mode` (and the top-level `thread_mode`) is one of `fresh`, `resume`, `continue`, `fork`; `inputs.mode` is `append` or `prepend`. To insert before an existing item instead of appending, `POST /stacks/{s}/items/{id}/insert` with the same body.

## How fixups happen

A review prompt that finds something to fix writes a new prompt file and runs:

```sh
stako add fix add-rate-limiter
```

`fix.toml` is a one-step routine that runs the new prompt on the `builder` thread. The builder picks it up in its existing context, commits the fix, and the next reviewer in the stack sees it. The loop continues until reviewers stop appending.

## Inspecting work

The daemon serves a web UI at the same address as the API — open `http://127.0.0.1:<port>/` in a browser (default port 7421). Pages are the same routes as the JSON API; a browser gets HTML, a client sending `Accept: application/json` gets JSON.

- **`/`** — every stack.
- **`/stacks/<name>`** — the stack's items, config, and threads. Status badges update live over SSE as sessions start and finish, and queued prompts can be edited inline.
- **`/stacks/<name>/items/<id>`** — the item's prompt, the **rendered prompt** (the exact text passed to the harness, i.e. the input), the output summary, changed paths, and a live transcript of the run.
- **`/stacks/<name>/threads/<thread>`** — the thread's provider/model plus a table of every item that ran on it, each linking straight to that item's **input** (rendered prompt) and **output**. This is the per-thread input/output view.

Headless, the same data comes from `stako stack thread show <stack> <thread>` (the thread's items), `stako stack item <stack> <id> [--prompt | --rendered]` (one item), and the JSON/SSE endpoints above.

## CLI reference

```sh
stako init [--root <path>] [--quiet]
stako daemon start|stop|status
stako new <stack>
stako add <routine> <stack> [--input-item <id> | --input-file <path> | --input-commit <sha>]
stako start <stack>
stako stack list|show|config|pause|resume <stack>
stako stack threads <stack>
stako stack thread show <stack> <thread>
stako stack item <stack> <id> [--prompt | --rendered]
stako stack edit-prompt <stack> <id> [--prompt-file <f> | --prompt <text> | --stdin]
stako stack rerun <stack> <id> [--prompt-file <f> | --prompt <text> | --stdin] [--thread-mode <m>]
stako routine list|show [<name>]
stako auth status [<provider>]
```

Daemon-backed commands accept `--root <path>`, `--port <n>`, `--json`, and `--verbose`. `STAKO_PORT` overrides the port when no local config is present.

`edit-prompt` overwrites a **queued** item's prompt in place (with no source flag it opens `$EDITOR` seeded with the current prompt). `rerun` forks a finished item: it appends a new item with the edited prompt, copying the original's thread and recording lineage via `parents`. `item --rendered` shows the exact text passed to the harness once an item has run. See **Inspecting work** above for the web UI and per-thread views.

## Building from source

```sh
make            # build (zig-out/bin/stako)
make test       # run the full test suite
make install    # install to $HOME/.local/bin (override with PREFIX=...)
```
