# Python Plan API Design

> Reframed by `09_unified_authoring_model.md`: the Python API emits a single
> central `plan.toml`, not scattered prompt front matter. Handle data flow
> compiles to `blocked_by`, and `new`/`clear`/`compact` are per-call flags.

## Problem

Authoring Stako stacks by hand means writing the same dependency graph,
threading result handoffs, and keeping node names straight. For a multi-step loop
such as implement, review, fix, the bookkeeping can dominate the actual intent.

We want a small Python API whose only job is to turn concise imperative code into
a correct prompt folder: `plan.toml`, reusable prompt bodies, and optional
supporting files. The Python layer owns no runtime.

## Goals

- Let an agent or operator describe a stack as ordinary Python control flow.
- Emit the same `plan.toml` that hand-authored folders use.
- Derive `blocked_by` automatically from handle data flow.
- Map `new`/`clear`/`compact` to per-node `action`.
- Supply default bodies for common review and fix calls.
- Stay dependency-free and installable locally.
- Add no runtime concepts to Stako.

## Non-Goals

- The Python API does not run agents.
- It does not inspect zellij panes.
- It does not own graph mutation after a stack is running.
- It does not define harness/model resolution; that is deferred.
- It does not define a second dependency language. It emits `plan.toml`.

## Proposed Python API

```python
from stako import Stack, prompt

with Stack("refactor-auth", cwd="../..", out="stako/refactor-auth") as s:
    impl = s.thread(
        "implementer",
        command="codex",
        default="Implement the requested change, run checks, and write result.md.",
    )
    review = s.thread(
        "reviewer",
        command="claude",
        default="Review the input result files for correctness and missing tests.",
    )

    implement = prompt("prompts/implement.md")
    review_body = prompt("prompts/review.md")
    fix = prompt("prompts/fix.md")

    for plan in s.glob("plans/*.md"):
        a = impl(implement, plan, new=True)
        b = review(review_body, a, new=True)
        impl(fix, b, compact=True)
```

On clean context exit, the API writes `plan.toml` and referenced prompt-library
files, then optionally shells out to:

```text
stako plan <out>
stako new <out>
```

or:

```text
stako add <stack> <out>
```

Nothing touches disk until the block succeeds, unless the caller explicitly asks
for dry-run materialization.

## Call Semantics

A `Thread` is callable. Each call appends one graph node and returns a `Handle`
that later calls can consume.

- `s.thread(name, command="claude", default=None)` registers a thread once.
- `t(*args, use=None, body=None, action=None, new=False, clear=False,
  compact=False, name=None)` builds one prompt node.
- `prompt(path)` returns a reusable body reference.
- File/path/string args become body inputs.
- Each `Handle` arg becomes a `blocked_by` entry.
- `new=True`, `clear=True`, and `compact=True` compile to `action`.
- With no body args, the thread's `default` is used.

Same-thread ordering follows the unified model:

- Consecutive calls on the same thread do not automatically create
  `blocked_by`.
- Thread occupancy serializes ready work at runtime.
- If Python source order matters as a data dependency, pass the previous handle
  into the next call or use `with s.step():` barrier sugar.

This avoids writing artificial edges while keeping imperative dependencies
explicit.

## Stack Options

Recommended constructor:

```python
Stack(
    name: str,
    cwd: str | None = None,
    root: str | None = None,
    out: str | None = None,
    dry_run: bool = False,
    create: bool = True,
)
```

- `name`: stack name and prompt folder basename when `out` is omitted.
- `cwd`: agent cwd written to the `plan.toml` header.
- `root`: Stako root written to the header or passed to the CLI.
- `out`: prompt folder to materialize.
- `dry_run`: writes files and prints commands, but does not queue.
- `create`: when false, materializes and adds to an existing stack.

Thread options in the active implementation are only `name`, required `command`,
and optional `default`. Optional `model` and harness adapter fields are deferred
to `deferred/08_harness_model_support.md`.

## Generated Plan

The example above emits one graph:

```toml
name = "refactor-auth"
cwd = "../.."

[[thread]]
name = "implementer"
command = "codex"
default = "Implement the requested change, run checks, and write result.md."

[[thread]]
name = "reviewer"
command = "claude"
default = "Review the input result files for correctness and missing tests."

[[prompt]]
name = "010-implementer"
thread = "implementer"
action = "new"
use = "prompts/implement.md"
with = ["plans/auth.md"]

[[prompt]]
name = "020-reviewer"
thread = "reviewer"
action = "new"
use = "prompts/review.md"
blocked_by = ["010-implementer"]

[[prompt]]
name = "030-implementer"
thread = "implementer"
action = "compact"
use = "prompts/fix.md"
blocked_by = ["020-reviewer"]
```

Handle arguments produce `blocked_by`; they do not emit separate `after` or
`inputs` fields.

## Steps as Sugar

For phased work, `with s.step():` groups calls into a barrier. Every node in a
step is blocked by every node in the previous step. Steps compile to ordinary
`blocked_by`; they are not a second runtime model.

Example:

```python
with Stack("audit", cwd="../..") as s:
    impl = s.thread("impl", command="codex")
    review = s.thread("review", command="claude")

    with s.step():
        a = impl("Implement item A")
        b = impl("Implement item B")

    with s.step():
        review("Review all implementations", a, b)
```

## Naming

- A monotonic counter allocates node names in steps of ten:
  `010-implementer`, `020-reviewer`, `030-implementer`.
- Names are sanitized to satisfy Stako node-name rules.
- Optional labels can suffix names: `impl("...", label="parse")` becomes
  `010-implementer-parse`.
- Collision or invalid-name errors fail before files are written.

## CLI Integration

The `stako` binary is resolved from `PATH`, overridable with `STAKO_BIN`.
Subprocess execution uses argument arrays with `shell=False`.

Preferred folder-first commands:

```text
stako plan <out>
stako new <out> [--root ROOT] [--cwd CWD]
```

or:

```text
stako add <stack> <out> [--root ROOT]
```

`dry_run=True` writes files and prints the exact argv-style commands without
queueing.

## Error Handling

Errors should fail before queueing whenever possible:

- invalid stack, thread, or node name
- duplicate generated node name
- missing file passed to `prompt` or `glob`
- missing command
- multiple actions on one call
- handle from another stack
- subprocess command failure

Recommended materialization strategy:

1. Render all plan data in memory.
2. Validate names and dependencies.
3. Write to a temporary directory.
4. Rename into `out` if durable output is requested.
5. Run Stako commands.

## Packaging and Install

- New top-level `python/` directory: `pyproject.toml` plus a single stdlib-only
  `stako/__init__.py`, targeting Python 3.9+.
- `make install-python` runs `pipx install --force ./python` with a documented
  fallback.
- No third-party dependencies.

## Skill and README Updates

- README gains a "Python Plan API" section with the loop example and install
  command.
- `skills/stako/SKILL.md` gains a short "Python loops" subsection telling agents
  to prefer the Python API for repetitive multi-step stacks and to let handle
  data flow generate `blocked_by`.

## Implementation Plan

1. Implement in-memory `Stack`, `Thread`, `PromptRef`, and `Handle` models.
2. Add name sanitization, label support, and monotonic node allocation.
3. Implement handle-derived `blocked_by`.
4. Implement per-call `new`, `clear`, and `compact` action flags.
5. Emit `plan.toml` plus prompt-library files.
6. Implement temp-then-rename materialization.
7. Implement `STAKO_BIN`, `--root`, `--cwd`, `create`, and `dry_run` CLI handling.
8. Add `pyproject.toml` and `make install-python`.
9. Add an example loop under `stako/`.
10. Update README and `skills/stako/SKILL.md`.

## Test Plan

- Rendering emits parseable `plan.toml`.
- Handle arguments add `blocked_by`.
- Consecutive same-thread calls do not add hidden edges.
- Step barriers compile to `blocked_by`.
- `compact`, `clear`, and `new` apply only to the current call.
- Duplicate sanitized names fail.
- Labels are sanitized and included in node names.
- `dry_run=True` writes files and prints exact argv-style commands without
  queueing.
- Context-manager exceptions queue nothing.
- Generated folder passes `stako plan`.

## Acceptance Criteria

- The loop example produces a prompt folder that `stako plan` and `stako new`
  accept without edits.
- `blocked_by` edges and action values match the Python data flow and call flags.
- Allocated node names are unique, sortable, and valid.
- `dry_run=True` writes files and prints exact Stako commands without queueing.
- The package installs locally with no third-party dependencies, and README and
  the Stako skill document the workflow.
