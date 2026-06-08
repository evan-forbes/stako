# stako

Stako is a tiny queue runner for coding agents, built around one `plan.toml`
graph.

The model is deliberately small:

- A **stack** is one `plan.toml` — the only graph. There is no state file.
- A **thread** is a long-lived agent session in a zellij tab. It sets a harness
  `command` (`claude` or `codex`) and an optional `default` body.
- A **prompt** node targets one thread. Same-thread nodes run one at a time;
  different-thread nodes run in parallel.
- **`blocked_by`** is the only edge: a node waits for the named nodes and
  receives their `result.md` files as inputs.
- **Status is computed**, never stored, from the plan plus run markers plus an
  append-only `events.jsonl` log.

Stako stores the graph on disk, starts one zellij tab per thread, and pastes
rendered prompts into the relevant tab. Durable content moves between threads
through per-node `result.md` files; completion is a per-node `done` marker, not
zellij pane text. Result quality is classified from the top of `result.md`:
`stako-status: done` satisfies dependents, while `stako-status: blocked` and
`stako-status: failed` are terminal but do not satisfy `blocked_by`.

## Install

Prerequisites:

- Zig 0.15.2
- `zellij`
- the agent CLI you want to run, usually `codex` or `claude`
- Python 3.9+ (only for the plan-authoring library)

```sh
make build
make install            # installs the stako binary to ~/.local/bin
make skill              # symlinks the bundled skill for Codex and Claude
make install-python     # installs the `stako` Python library globally
```

`make install-python` prefers `pipx`, then `pip --user`; on an
externally-managed interpreter with neither, it links the package editable via a
`.pth` in your user site so `import stako` works globally. Override the binary it
shells out to with `STAKO_BIN`.

## Quick start

Author a plan with Python (best for repetitive loops):

```python
from stako import Stack, prompts

with Stack("my-work", cwd="~/src/my-repo") as s:
    impl   = s.thread("impl",   command="codex")
    review = s.thread("review", command="claude")
    cursor = s.cursor()

    for task in s.glob("plans/*.md"):
        i = impl(cursor, prompts.implementer, task, new=cursor.empty)
        review(prompts.code_quality, i)
        cursor = cursor.advance(i)
```

Running the script writes `plan.toml` and calls `stako new`. Or hand-author a
folder and create the stack yourself:

```sh
stako plan ./my-folder       # validate + preview
stako new  ./my-folder --cwd ~/src/my-repo
stako start my-work --watch  # resident: deliver ready nodes, pick up injects live
stako status my-work
stako attach my-work
stako stop my-work           # end the watch runner
```

`--cwd` is the directory the agent threads launch in — the repository they work
on. It is resolved to an absolute path when the stack is created, so it does not
depend on where you later run `stako start`. It can also live in the plan header.

## The plan

A `plan.toml` declares threads once and nodes once; edges are `blocked_by`,
referenced by name.

```toml
name = "review-loop"
cwd  = "~/src/my-repo"           # agent cwd; relative paths resolve from this file

[[thread]]
name = "impl"
command = "codex"

[[thread]]
name = "reviewer"
command = "claude"

[[prompt]]
name = "impl-1"
thread = "impl"
action = "new"                   # new | clear | compact, sent before the body
use = "prompts/implementer.md"   # a reusable library body
with = ["plans/auth.md"]         # extra body inputs (files or inline strings)
# no blocked_by -> ready immediately

[[prompt]]
name = "review-1"
thread = "reviewer"
use = "prompts/code_quality.md"
blocked_by = ["impl-1"]          # waits for impl-1 and reads its result.md
```

Node fields:

- `name` (required): unique; the handle other nodes target with `blocked_by`.
- `thread` (required): which thread runs it.
- `use` / `with` / `body`: the body. `use` is a library prompt path, `with` is a
  list of extra file paths or inline strings, `body` is an inline string. With
  none, the thread `default` is used.
- `action` (optional): `new` | `clear` | `compact`, sent before the body.
- `blocked_by` (optional): node names to wait for and read `result.md` from.
- `raw = true` (optional): deliver the body verbatim with no auto-contract.

`use` paths resolve against the prompt folder (made absolute at `stako new`
time), so one `prompts/` library serves many plans.

## Python plan API

`from stako import Stack, prompt, prompts`.

- `s.thread(name, command="claude", default=None)` registers a thread and
  returns a callable.
- Calling a thread appends one node and returns a **handle**:
  - a `prompts.*` ref or `prompt("path.md")` is the body (`use`);
  - a **handle** or **cursor** argument becomes `blocked_by` (and therefore an input);
  - a file path or string becomes an extra body input (`with`);
  - `new` / `clear` / `compact` are per-call actions; `label="..."` suffixes the
    node name; `raw=True` skips the contract.
- `s.cursor(*deps)` creates a dependency cursor from zero or more handles or
  cursors. `cursor.advance(*deps)` returns a new cursor whose tail is only
  `deps`; `cursor.join(*deps)` fans in the current cursor plus more deps.
- `s.glob("plans/*.md")` returns sorted absolute paths.
- `with s.step():` groups calls into a barrier: every node in a step is
  `blocked_by` every node of the previous step.

Consecutive calls on the same thread add no hidden edges — thread occupancy
orders them. On clean `with` exit the library writes `plan.toml` and runs
`stako new`; an exception in the block writes nothing. `dry_run=True` writes the
file and prints the exact command without queueing.

The bundled prompt library (an implement → review → check loop) is reached by
nickname:

| Nickname | Role |
|---|---|
| `prompts.implementer` | implement a work slice and write `result.md` |
| `prompts.code_quality` | review correctness, elegance, completeness |
| `prompts.security` | review abuse-resistance and untrusted input |
| `prompts.performance` | review allocation, bounds, and scaling |
| `prompts.checker` | reconcile reviews into `pass` / `followups` verdicts |

The raw bodies live in `prompts/*.md`; `prompts.names()` lists what is available.
Nested prompt bodies are available with bracket lookup, for example
`prompts["bug_finder/entrypoint_researcher"]`. Set `STAKO_PROMPTS` to point the
registry at a different library directory.

## Sync and parallel

Parallelism is implicit: two nodes on different threads with no unmet
`blocked_by` can both be delivered. Synchronization is explicit via `blocked_by`,
which both waits for a node and passes its `result.md` path as an input. When a
review node is `blocked_by = ["impl-1"]`, the reviewer receives the absolute path
to `runs/impl-1/result.md`; Stako does not scrape the implementer's pane.

Wire an edge into an existing plan with:

```sh
stako link <stack> impl-1 review-1   # adds impl-1 to review-1's blocked_by
```

## Rendered prompt and the result contract

The bytes an agent receives are composed at delivery, in order:

1. **action** — `/new` | `/clear` | `/compact` when set
2. **body** — the resolved `use` file, plus `with`/`body`, or the thread `default`
3. **inputs contract** — the `runs/<blocked_by>/result.md` paths to read
4. **output contract** — write `runs/<node>/result.md`, create `done`, then stop

The exact bytes are written to `runs/<node>/rendered.md` and referenced from the
`delivered` event in `events.jsonl`. Preview them before any run with:

```sh
stako render <stack> <node>
```

Every run has predetermined durable paths:

```text
<root>/stacks/<stack>/runs/<node>/result.md
<root>/stacks/<stack>/runs/<node>/done
```

The agent writes the final handoff content to `result.md`, then creates `done`,
then stops. The marker can be empty, but must not exist before the result is
complete. The first result line should be `stako-status: done`,
`stako-status: blocked`, or `stako-status: failed`; an optional second line may
be `stako-verdict: pass`, `stako-verdict: followups`, or `stako-verdict: fail`.
Legacy first lines `PASS`, `FOLLOWUPS REQUIRED`, `BLOCKED`, `FAILED`, and
`FAIL` are still classified for compatibility. `done` without `result.md` makes
the run `failed`.

## Run, watch, and recover

`stako start` delivers ready prompts and polls running ones. By default it
returns once the stack is idle; `--watch` keeps it resident as a daemon that
re-reads `plan.toml` every tick, so `stako inject`/`stako reset` take effect
**without a restart**, and a currently running node is polled rather than
re-delivered. The runner holds no cached graph — it re-derives status from
`plan.toml` + run markers + `events.jsonl` each tick. It records `runner.pid`
(pid, start time, watch); `stako stop` reads it, verifies the process is the
stack's runner, and signals it.

When a node wedges (e.g. a large paste whose submit never registered — the runner
retries Enter once, but the long tail is yours to recover):

```sh
stako redeliver <stack> <node>   # re-send the rendered prompt to its pane
stako reset <stack> <node>       # clear its run artifacts; it re-queues (and a watch runner re-delivers)
stako complete <stack> <node> [--result FILE]  # force-finish it from a file or stdin
```

`stako output <stack> <node>` recaptures a running node's pane when a live pane
is available, updates `runs/<node>/output.md`, and prints it. Use
`stako output <stack> <node> --snapshot` for the stored snapshot only.

## Status and history

`stako status` computes the view from `plan.toml` + run markers + `events.jsonl`:
per-node status (`queued`/`running`/`completed`/`blocked`/`failed`) with readiness and the
`blocked_by` a queued node is waiting on, which node each thread is running, the
attached runner's liveness, and a `(stalled?)` hint for a running node whose pane
has been quiet too long. `stako status --json` emits the same view as JSON.

`events.jsonl` is append-only: one JSON object per delivery, completion, blocked
result, failure, injection, reset, and runner start/stop. It is audit history and the source for
the `running` part of computed status — never a second copy of the graph.

## Inject follow-ups

```sh
stako inject <stack> <node> --thread T [--use F | --body B] [--with f1,f2] [--action A] \
  [--blocked-by a,b] [--gate target] [--raw]
```

`inject` appends a `[[prompt]]` node to `plan.toml`; `--gate target` also adds the
new node to `target`'s `blocked_by`. `--with` attaches extra body inputs (files or
inline strings, repeatable or comma-separated). Because edges are by name and
there is no ordering, appending cannot invert dependencies or renumber anything.
`--use` paths are validated before mutation. The mutation is recorded in
`events.jsonl`; any live runner picks it up on its next tick. If no live runner
is present, the command prints the exact `stako start <stack> --watch` command to
continue.

## CLI

```sh
stako plan <prompt-folder> [--name N] [--root P] [--cwd P] [--json]
stako new <prompt-folder> [--name N] [--root P] [--cwd P]
stako new <name> --from <prompt-folder> [--root P] [--cwd P]
stako status <stack> [--root P] [--json]
stako render <stack> <node> [--root P]
stako inject <stack> <node> --thread T [--use F|--body B] [--with f1,f2] [--action A] [--blocked-by a,b] [--gate target] [--raw] [--root P]
stako link <stack> <source-node> <target-node> [--root P]
stako start <stack> [--watch] [--root P]
stako stop <stack> [--root P]
stako attach <stack>
stako output <stack> <node> [--snapshot] [--root P]
stako redeliver <stack> <node> [--force] [--root P]
stako complete <stack> <node> [--result FILE] [--root P]
stako reset <stack> <node> [--root P]
```

The default root is `~/stako`. Runtime artifacts (`runs/`, `events.jsonl`,
`runner.pid`) live under the stack root and are not git-tracked.

## Development

```sh
make build
make test
zig build -Doptimize=ReleaseFast test
python3 -m unittest discover -s python/tests   # Python plan API tests
```
