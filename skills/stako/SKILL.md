---
name: stako
description: Use when creating, queueing, inspecting, or repairing Stako stacks. Stako runs a plan.toml graph of prompts on durable agent threads backed by zellij tabs.
---

# Stako

Stako runs one `plan.toml` graph: threads are long-lived agent sessions (zellij
tabs), prompts are nodes that target a thread, and `blocked_by` is the only edge.

Core model:

- A **stack** is one `plan.toml`. It is the only graph; there is no state file.
- A **thread** is a durable agent session in a zellij tab. It sets a `command`
  (`claude` or `codex`) and an optional `default` body.
- A **prompt** node targets one thread. Same-thread nodes run serially;
  different-thread nodes run in parallel.
- **`blocked_by = ["node", ...]`** is the only relationship: wait for those
  nodes, and receive their `result.md` paths as inputs. (No `after`/`inputs`/`order`.)
- **Status is computed**, never stored: `done`+`result.md` is classified from
  the top of `result.md`; `stako-status: done` satisfies dependents, while
  `stako-status: blocked` and `stako-status: failed` are terminal but do not.
  A `delivered` event with no terminal is running; otherwise the node is queued.
  `events.jsonl` is append-only history.
- Durable handoff is `runs/<node>/result.md`; completion is `runs/<node>/done`.
  Zellij pane text is debug only — never handoff or completion.

## Write a plan with Python (preferred for loops)

The `stako` Python library emits `plan.toml` from concise code. Threads are
callables; each call appends a node and returns a handle; passing a handle or
cursor into a later call becomes its `blocked_by`. The reusable prompt library is
reached by nickname: `prompts.implementer`, `prompts.code_quality`,
`prompts.security`, `prompts.performance`, `prompts.checker` (each becomes a
node's `use` body).

```python
from stako import Stack, prompts

with Stack("review-loop", cwd="~/src/myrepo") as s:
    impl     = s.thread("impl",     command="codex")
    quality  = s.thread("quality",  command="claude")
    security = s.thread("security", command="claude")
    checker  = s.thread("checker",  command="claude")
    cursor   = s.cursor()

    for task in s.glob("plans/*.md"):
        i   = impl(cursor, prompts.implementer, task, new=cursor.empty)
        q   = quality(prompts.code_quality, i)           # i (handle) -> blocked_by
        sec = security(prompts.security, i)              # parallel to q
        c   = checker(prompts.checker, q, sec)           # blocked on both reviews
        cursor = cursor.advance(c)                       # serialize only iterations
```

Call args: a `prompts.*` ref (or `prompt("path.md")`) is the body (`use`); a
handle or cursor is a `blocked_by`; a file path or string is an extra body input
(`with`). `s.cursor(*deps)` creates a cursor from handles/cursors;
`cursor.advance(*deps)` keeps only a new tail; `cursor.join(*deps)` fans in.
`new`/`clear`/`compact` are per-call actions. `s.step():` groups calls so each
node is blocked by every node of the previous step. On clean exit the library
writes `plan.toml` and runs `stako new`; an exception writes nothing.
`dry_run=True` writes the file and prints the command without queueing.

## Or hand-author plan.toml

```toml
name = "review-loop"
cwd  = "~/src/myrepo"          # agent cwd; relative paths resolve from this file

[[thread]]
name = "impl"
command = "codex"

[[thread]]
name = "reviewer"
command = "claude"

[[prompt]]
name = "impl-1"
thread = "impl"
action = "new"                 # new | clear | compact, sent before the body
use = "prompts/implementer.md" # library body; or `with = [...]`, or `body = "..."`
# no blocked_by -> ready immediately

[[prompt]]
name = "review-1"
thread = "reviewer"
use = "prompts/code_quality.md"
blocked_by = ["impl-1"]        # waits for impl-1 and reads its result.md
```

Node fields: `name` (unique), `thread` (required), one of `use`/`with`/`body`
(else the thread `default`), optional `action`, `blocked_by`, and `raw = true`
(deliver the body verbatim, no auto-contract).

## Run and inspect

```sh
stako plan <folder>               # validate + preview a plan.toml folder
stako new <folder> [--cwd P]      # normalize into <root>/stacks/<name>/plan.toml
stako start <stack> [--watch]     # deliver ready nodes; --watch stays resident
stako stop <stack>                # signal the watch runner (via runner.pid)
stako status <stack> [--json]     # computed per-node/thread/runner view
stako render <stack> <node>       # exact bytes that will be delivered
stako attach <stack>              # attach the zellij session
stako output <stack> <node>       # live recapture for running nodes, else snapshot
stako output <stack> <node> --snapshot
```

The default root is `~/stako`. `--cwd` is the repo the agents work in, resolved
to an absolute path at `new` time.

`start` re-reads `plan.toml` and recomputes status every tick — it caches no
graph. So `--watch` is a daemon that picks up `inject`/`reset` live, polls (never
re-delivers) running nodes, and on restart reuses existing zellij tabs instead of
duplicating them. Non-watch runners also reload each tick while alive. It records
`runner.pid`; `stako stop` ends it cleanly.

## Inject follow-ups

```sh
stako inject <stack> <node> --thread T [--use F | --body B] [--with f1,f2] [--action A] \
  [--blocked-by a,b] [--gate target] [--raw]
stako link <stack> <source-node> <target-node>
```

`inject` appends a node to `plan.toml`; `--gate target` also adds the new node to
`target`'s `blocked_by`. `--with` adds extra body inputs (files or inline strings,
repeatable or comma-separated). `link` adds an existing source to a target's
`blocked_by`. Edges are by name, so injection never renumbers or inverts anything.
`--use` paths are validated before mutation. Any live runner applies the change
on its next tick; otherwise the CLI prints the exact `stako start <stack>
--watch` command to continue.

## Recover a wedged node

```sh
stako redeliver <stack> <node> [--force]        # re-send the prompt to its pane
stako reset <stack> <node>                       # clear run artifacts; re-queues it
stako complete <stack> <node> [--result FILE]    # force-finish from a file or stdin
```

`reset` deletes `runs/<node>/{done,result.md,output.md,...}` and logs a `reset`
event, so status recomputes to queued and a `--watch` runner re-delivers it.
`redeliver` refuses a completed node without `--force`. `status` flags a running
node whose pane has been quiet too long as a possible stall.

## Rendered prompt and the result contract

Each delivery composes, in order: **action** → **body** (`use` + `with` + `body`,
or thread `default`) → **inputs contract** (`blocked_by` result.md paths) →
**output contract**. The exact bytes are written to `runs/<node>/rendered.md` and
referenced from `events.jsonl`; preview them with `stako render`.

The agent must write durable handoff to `runs/<node>/result.md`, then create
`runs/<node>/done`, then stop. Start the result with `stako-status: done`,
`stako-status: blocked`, or `stako-status: failed`; optional
`stako-verdict: pass|followups|fail` may follow. Legacy `PASS`,
`FOLLOWUPS REQUIRED`, `BLOCKED`, `FAILED`, and `FAIL` first lines are accepted.
`done` without `result.md` is a `failed` run.

## Rules

- Treat Stako as orchestration; do not edit the user's repo unless a queued
  prompt asks for it.
- Prefer a short stack name (`add-rate-limiter`) and let node names auto-allocate.
- Put role/standing behavior in the thread (`default` or a `prompts.*` body);
  put task specifics in the node.
- Check `stako status <stack>` before changing a running stack. Don't delete
  stack state, tabs, or runs unless asked.
