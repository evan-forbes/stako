# Unified Authoring and Execution Model

## Problem

Three docs describe overlapping mechanics for the same thing — turning intent
into a runnable stack:

- `02_prompt_folder_workflow.md` infers a stack from a folder of prompt files
  whose dependency edges live in scattered front matter.
- `05_graph_execution_model.md` reconstructs a graph from that scattered front
  matter at load time and schedules over it.
- `07_python_plan_api.md` used to be framed as a front-matter generator; it is
  now a `plan.toml` emitter.

The dependency structure is therefore authored in N files, reconstructed at
runtime, and re-emitted by a second tool. That is the bookkeeping the whole
roadmap is trying to delete. This doc unifies the three: the graph is authored
exactly once in a single human-readable `plan.toml`, and runtime state is never
stored as a second copy of the graph — it is computed from the plan plus
filesystem completion markers plus an append-only event log. There is no
backwards-compatibility requirement, so we choose the right shape.

## Goals

- One authoring surface for the dependency graph, readable at a glance.
- No duplicated graph: `plan.toml` is the only place threads and edges live.
- A single relational primitive (`blocked_by`) instead of `order` + `after` +
  `inputs`.
- Express handle-style loops (implement, two reviews, two fixes) with no
  hand-written edges, while still allowing arbitrary edges.
- Give the user visible, controllable rendered prompts.
- Make the Python API one emitter of the plan, not a parallel format.

## Field Partition

The decisive cut is *what kind of fact each field is*, not which file it lands
in. Every field has exactly one home; nothing is defined twice, so there is no
precedence rule to get wrong.

| Fact kind | Fields | Home |
|---|---|---|
| Prompt-local | body (`use`/`with`/inline), `action`, `raw` | the node entry in `plan.toml` |
| Thread-local | `command`, `default` | the thread entry in `plan.toml` |
| Relational | `blocked_by` | the node entry in `plan.toml` |
| Runtime | status, timestamps, rendered text, failures | computed / `events.jsonl` / `runs/` |

Relational facts hurt most when scattered (read N files to see the loop) and
under injection (the order-inversion deadlock in `01_followup_injection.md` is a
relational fact stored locally). They live once, in the plan.

## One Graph, No State File

There is no compiled state file. The graph is `plan.toml`. Everything else a
runner needs is either on the filesystem already or appended to a log:

| Artifact | Role | Mutability |
|---|---|---|
| `plan.toml` | the graph: threads + nodes + `blocked_by` | edited only on authoring or injection |
| `runs/<node>/rendered.md` | exact bytes delivered to the agent | written once at delivery |
| `runs/<node>/result.md`, `runs/<node>/done` | durable output + completion marker | written once by the agent |
| `events.jsonl` | append-only structured history | appended, never rewritten |
| `runner.pid` | runner liveness for `stako stop` | tiny, replaced on start |

**Status is computed, not stored.** For each node: `completed` if `done` exists,
`running` if a `delivered` event exists without a later `completed`/`failed`,
otherwise `queued`; a queued node is `ready` when every `blocked_by` is completed
and its thread is idle. The graph never carries `status = "running"` churn, so
`plan.toml` stays stable. The only writes to `plan.toml` are deliberate graph
changes (authoring or `stako inject`), never status transitions.

Runtime artifacts (`runs/`, `events.jsonl`, `runner.pid`) live under the stack
root and are not git-tracked. See `04_directory_worktree_model.md` for the
root/cwd/worktree split.

## Folder Roles and Plan Lifecycle

The reusable, git-tracked source is *not* a stack:

- `prompts/` — reusable prompt bodies referenced by `use`; the thread-level
  building blocks. One library serves many plans.
- `python/` — reusable Python *patterns* (e.g. the implement → review → fix
  loop) that emit a `plan.toml` from a chosen prompt set and plan set.

A `stako/<name>/` folder is a plan *instance*: a generated (or hand-authored)
`plan.toml`, its plan inputs, and runtime artifacts. Instances are not tracked;
the pattern and the prompt library that produce them are.

There is exactly **one canonical `plan.toml` per stack**, under the stack root.
When `stako new` is given a separate source folder it normalizes that source into
the stack-root `plan.toml` once (resolving `use` and path fields to absolute);
when the source folder *is* the stack root it normalizes in place. The source
copy is an input consumed once, never a second live graph. Thereafter the
stack-root `plan.toml` is the only graph and `stako inject` mutates it. `use`
paths resolve against the prompt-library root (a path role in
`04_directory_worktree_model.md`), so the same `prompts/` serves every plan.

## The `blocked_by` Primitive

There is one edge type. `blocked_by = ["node-name", ...]` means: **do not run
until those nodes are complete, and receive their `result.md` paths as inputs.**
This collapses the former `order`, `after`, and `inputs`:

- `order` is gone. Nothing is sorted; readiness is "are my blockers done."
- `after` and `inputs` merge — waiting on a node and reading its result are the
  same relationship in every real case. A pure ordering wait without data is a
  rare `{ name = "x", wait_only = true }` entry.

**Scheduler rule:** for each idle thread, run the earliest-emitted node whose
`blocked_by` are all complete. Ties break on emit order (a node's position in
`plan.toml`). That is the whole scheduler; it is the readiness model of
`05_graph_execution_model.md` with one edge kind.

Nodes are referenced by name, so adding or injecting a node never renumbers
anything.

## Plan Format

```toml
# stako/refactor-loop/plan.toml
name = "refactor-loop"
cwd  = "../.."          # agent cwd; relative paths resolve from this file

# Threads are declared once. The active plan keeps `command` required.
[[thread]]
name = "impl"
command = "codex"

[[thread]]
name = "reviewer_a"
command = "claude"

[[thread]]
name = "reviewer_b"
command = "codex"

# Nodes. Edges are blocked_by, referenced by name.
[[prompt]]
name = "impl-1"
thread = "impl"
action = "new"
use = "prompts/implement.md"      # reusable library body
with = ["plans/auth.md"]          # extra body inputs appended to the body
# no blocked_by -> ready immediately

[[prompt]]
name = "review-a-1"
thread = "reviewer_a"
action = "new"
use = "prompts/review.md"
blocked_by = ["impl-1"]           # waits for impl-1, receives its result.md

[[prompt]]
name = "review-b-1"
thread = "reviewer_b"
action = "new"
use = "prompts/review.md"
blocked_by = ["impl-1"]

[[prompt]]
name = "fix-a-1"
thread = "impl"
action = "compact"
use = "prompts/fix.md"
blocked_by = ["review-a-1"]

[[prompt]]
name = "fix-b-1"
thread = "impl"
action = "compact"
use = "prompts/fix.md"
blocked_by = ["review-b-1"]
```

Node fields:

- `name` (required): unique; the handle other nodes target with `blocked_by`.
- `thread` (required): which thread runs it.
- `use` (library prompt path) and/or `with` (extra inline/file body inputs)
  and/or `body` (inline string); none uses the thread `default`.
- `action` (optional): `new` | `clear` | `compact`, sent before the body.
- `blocked_by` (optional): names of nodes to wait for and read results from.
- `raw` (optional): when true, deliver the body verbatim with no auto-contract.

Thread fields in the active implementation are `name`, required `command`, and
optional `default` body for bare calls. Optional `model`, harness adapters,
Gemini/OpenCode support, and nickname resolution are deferred to
`deferred/08_harness_model_support.md` so the graph/folder/runtime core can land
without depending on model selection.

The reusable prompt library (`prompts/*.md`) is plain bodies with no Stako front
matter, reused across nodes and stacks — the same idea as the `discovery-gen`
prompts.

## Authoring with Python

The Python API is one emitter of `plan.toml`. Threads are callables; handles are
the values they return; **actions are per-call flags**, not staged thread state —
this removes the class of error where an action meant for the next prompt is
attached to a handle.

```python
from stako import Stack, prompt

with Stack("refactor-loop", cwd="../..", out=".") as s:
    impl       = s.thread("impl",       command="codex")
    reviewer_a = s.thread("reviewer_a", command="claude")
    reviewer_b = s.thread("reviewer_b", command="codex")

    implement = prompt("prompts/implement.md")
    review    = prompt("prompts/review.md")
    fix       = prompt("prompts/fix.md")

    for plan in s.glob("plans/*.md"):
        i  = impl(implement, plan, new=True)   # implement the plan, fresh session
        a  = reviewer_a(review, i, new=True)   # review i (claude)
        b  = reviewer_b(review, i, new=True)   # review i — parallel to a
        f  = impl(fix, a, compact=True)        # compact, fix per review a
        f2 = impl(fix, b, compact=True)        # compact, fix per review b
```

Call semantics:

- Non-handle args (a `prompt(...)` ref, a file path, a string) build the body.
- Each handle arg becomes a `blocked_by` entry (and therefore an input).
- `new`/`clear`/`compact` are per-call flags compiling to `action`.
- The API tracks each handle's producing node and each call's consumed handles,
  so it derives `blocked_by` from data flow and can verify no node reads an input
  that will not exist.

Iterations serialize naturally: every iteration reuses the same three threads, so
thread occupancy orders them; no cross-iteration edges are written. `f` and `f2`
share `impl`, so they run in emit order on one compacted session without naming
each other.

On clean context exit the API writes `plan.toml` (and copies any inline bodies),
then shells out to `stako new` / `stako add`. A script error writes nothing.

## Steps as Optional Sugar

The handle model above is the core. For genuinely phased work, `with s.step():`
groups calls into a barrier — every node in a step gets `blocked_by` = all nodes
of the previous step — so the simple "do, review, do, review" case needs no
handles at all. Steps compile to the same `blocked_by`; they are convenience, not
a second model.

## The Rendered Prompt

The bytes an agent receives are composed by Stako at delivery, in order:

1. **Action** — `/new` | `/clear` | `/compact` when set, with the delivery
   settle handling from `06_runtime_reliability_backlog.md`.
2. **Body** — the resolved `use` file, plus `with`/inline additions, or the
   thread `default`.
3. **Inputs contract** — the `runs/<blocked_by>/result.md` paths to read.
4. **Output contract** — write `runs/<node>/result.md` beginning with
   `stako-status: done|blocked|failed`, create `done`, then stop.

Because this is spread across the library prompt, the node, and Stako's template,
it must be visible and controllable:

- `stako render <stack> <node>` prints the exact composed bytes before any run.
- At delivery Stako writes those bytes verbatim to `runs/<node>/rendered.md`, and
  the `delivered` event in `events.jsonl` references that file plus the inputs and
  action used. The rendered prompt is therefore always in the structured log.
- `raw = true` on a node bypasses the auto-contract for full manual control; the
  contract template is overridable per thread or stack.

A later TUI/GUI reads `runs/<node>/rendered.md` and `events.jsonl` to show
exactly what each agent was given. That TUI work is deferred; until then
`stako render` and `stako status` cover the same data.

## Execution Log

Stako appends one JSON object per line to `events.jsonl` as work happens:

```jsonl
{"ts":"2026-06-04T12:00:00Z","event":"scheduled","node":"impl-1","thread":"impl"}
{"ts":"2026-06-04T12:00:01Z","event":"delivered","node":"impl-1","thread":"impl","action":"new","rendered":"runs/impl-1/rendered.md","inputs":[]}
{"ts":"2026-06-04T12:03:10Z","event":"completed","node":"impl-1","result":"runs/impl-1/result.md"}
{"ts":"2026-06-04T12:03:11Z","event":"blocked","node":"checker-1","reason":"result_blocked"}
{"ts":"2026-06-04T12:03:11Z","event":"scheduled","node":"review-a-1","thread":"reviewer_a"}
{"ts":"2026-06-04T12:03:12Z","event":"delivered","node":"review-a-1","thread":"reviewer_a","action":"new","rendered":"runs/review-a-1/rendered.md","inputs":["runs/impl-1/result.md"]}
```

Append-only: no atomic-rewrite dance, full history (including every rendered
prompt and every failure reason), and a replayable audit trail. Injection,
runner start/stop, and delivery failures (`06`) all land here.

## Status

`stako status` computes the view from `plan.toml` + `runs/` markers +
`events.jsonl`:

- per node: computed status (`queued`/`running`/`completed`/`blocked`/`failed`)
  and, for queued nodes, readiness and the `blocked_by` it is waiting on.
  `blocked` and `failed` are terminal but do not satisfy dependents.
- per thread: idle or which node is running
- runner: pid and watch mode from `runner.pid`

`stako status --json` emits that computed view — the single structured surface
that `03`, `05`, and `06` each asked for separately. A refined LLM-facing schema
can be added later without introducing a stored second copy of the graph.

## Injection

`stako inject` appends a `[[prompt]]` node to `plan.toml` and, if it gates an
existing queued node, adds its name to that node's `blocked_by`. Because edges
are by name and there is no `order`, appending cannot create an inversion and
nothing is renumbered. The mutation is recorded in `events.jsonl`. This is the
mechanism `01_followup_injection.md` needs, with `plan.toml` as the only graph.

## Relationship to Other Docs

Supersedes storage/authoring decisions in:

- `02` — the prompt folder still exists, but its manifest *is* `plan.toml`, the
  single graph; the old "front matter wins" rule is dropped.
- `05` — the scheduler/readiness model stands, reduced to one `blocked_by` edge;
  there is no compiled state file and no `order`; status is computed.
- `07` — reframed as a `plan.toml` emitter with handle/cursor-derived
  `blocked_by` and per-call actions.

Composes with, and adjusts:

- `01` — injection appends to `plan.toml`; nothing to renumber.
- `04` — path roles live in the `plan.toml` header; runtime artifacts under the
  stack root.
- `deferred/08` — the active plan reserves thread-local extension points for
  `model`/`harness`, but implementation should keep only `command` until the core
  graph/folder/runtime path is stable.

## Implementation Plan

1. Define the `plan.toml` schema and parser: header, `[[thread]]` with required
   `command`, and `[[prompt]]` with `use`/`with`/`body`, `action`,
   `blocked_by`, `raw`.
2. Build the in-memory graph and a `blocked_by`-only readiness/scheduler pass
   (replacing `order`).
3. Implement prompt rendering (action + body + inputs + output contract), write
   `runs/<node>/rendered.md`, and add `stako render`.
4. Add the `events.jsonl` appender and the `runner.pid` file.
5. Implement `stako status` and `stako status --json` as computed projections.
6. Move `stako inject` to append to `plan.toml` + log the mutation.
7. Build the Python API: callable threads, handle/cursor-derived `blocked_by`,
   per-call actions, prompt library refs, `plan.toml` emission, `stako` shell-out.
8. Add `with s.step()` sugar over `blocked_by`.
9. Update README and `skills/stako/SKILL.md` for the plan + library + render flow.

## Test Plan

- A handle chain compiles to the expected `blocked_by` graph and runs in order.
- A cursor loop compiles to serialized iterations without serializing unrelated
  reviewers inside an iteration.
- Two reviewers blocked on one implement node run in parallel; two fixes block on
  their respective reviews.
- `blocked_by` waits and passes the blocker's `result.md` path as an input.
- Status is computed correctly from markers, result classification, and log with
  no stored status.
- `stako render` output equals the bytes written to `runs/<node>/rendered.md`.
- `raw = true` delivers the body with no contract appended.
- `events.jsonl` records a rendered reference and inputs for every delivery.
- Injecting a node appends to `plan.toml` and cannot create an inversion.
- The Python API and a hand-written `plan.toml` produce the same graph.

## Acceptance Criteria

- The graph is authored once in `plan.toml`; there is no second stored copy.
- `blocked_by` is the only edge; `order`/`after`/`inputs` are gone.
- Status is computed from plan + filesystem + `events.jsonl`.
- Every delivered prompt is captured verbatim in `runs/<node>/rendered.md` and
  referenced from the log, and is previewable with `stako render`.
- The Python loop and hand-authoring produce the same `plan.toml`.
- Reusable library prompts and per-thread commands are expressible without
  duplicating bodies or wiring.
