# stako

Stako is a stack-based meta-harness for coding agents. You queue prompts and routines onto a stack, and stako drives them through the harnesses you already use (Claude Code, Codex). Inputs and outputs travel as git commits, so the work stays visible and revertable.

## Getting started

This guide assumes you already have `claude` and `codex` on your `PATH` and signed in.

### 1. Install and init

```sh
make install                   # builds and installs to $HOME/.local/bin
stako init                     # bootstraps ~/stako with the standard layout
stako daemon start             # serves the loopback API
```

`init` creates `~/stako/` with empty `prompts/` and `routines/` directories, `stacks/default/stack.toml`, an `AGENTS.md` primer, a documented `config.toml`, and a local auth token. Run subsequent commands in another terminal.

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

## Programmatic Python authoring

The Python SDK is a thin local client for generated workflows. It writes prompt and routine source files under the notes root, then uses the daemon API for stack creation, thread targeting, queue mutation, and start/resume. It does not edit stack item metadata directly.

```python
from stako import Client, Prompt, Routine, Stack

client = Client(root="~/stako")

routine = (
    Routine("implement-and-review")
    .thread("builder", provider="openai", model="gpt-5")
    .thread("reviewer", provider="anthropic")
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
    .compact(thread="builder")
)

Stack(client, "add-rate-limiter").create().add(routine).start()
```

This materializes files like:

```text
~/stako/prompts/generated/implement-and-review/step-0001.md
~/stako/prompts/generated/implement-and-review/step-0002.md
~/stako/routines/implement-and-review.toml
```

## How fixups happen

A review prompt that finds something to fix writes a new prompt file and runs:

```sh
stako add fix add-rate-limiter
```

`fix.toml` is a one-step routine that runs the new prompt on the `builder` thread. The builder picks it up in its existing context, commits the fix, and the next reviewer in the stack sees it. The loop continues until reviewers stop appending.

## CLI reference

```sh
stako init [--root <path>] [--yes] [--quiet]
stako daemon start|stop|status
stako new <stack>
stako add <routine> <stack> [--input-item <id> | --input-file <path> | --input-commit <sha>]
stako start <stack>
stako stack list|show|config|pause|resume <stack>
stako routine list|show [<name>]
stako auth status [<provider>]
```

Daemon-backed commands accept `--root <path>`, `--port <n>`, `--json`, and `--verbose`. `STAKO_PORT` overrides the port when no local config is present.

## Building from source

```sh
make            # build (zig-out/bin/stako)
make test       # run the full test suite
make install    # install to $HOME/.local/bin (override with PREFIX=...)
```
