# Prompt Folder Workflow Design

> Updated by `09_unified_authoring_model.md`: the prompt folder contains
> `plan.toml`, which *is* the dependency graph. Folder/path inference and
> previewability below apply to that plan; there is no second manifest or
> scattered prompt front matter.

## Problem

The main input to Stako should be a folder every time: a `plan.toml`, reusable
prompt bodies, supporting files, and a `flups/` workspace. Today users have to
manually coordinate stack name, root, cwd, prompt files, and optional flags. That
creates mistakes, especially when the prompt folder is under `stako/` but the
agents need to work in the repository root.

## Goals

- Make `stako new <prompt-folder>` the primary workflow.
- Infer stack name, stack root, agent cwd, thread declarations, graph nodes, and
  prompt-library files.
- Keep explicit flags for unusual cases.
- Make the inferred values visible before work starts.
- Support one Stako root per org, while allowing stacks to point at repos and worktrees nearby.
- Validate thread commands before zellij tabs are launched.

## Second-Pass Review

Folder-first is the right default because it aligns with how stacks are authored: the operator prepares a directory of thread prompts, queued prompts, and supporting files, then asks Stako to run it. The current name-first CLI should remain for compatibility, but an existing directory argument should select folder mode.

The most important design requirement is previewability. Stako should never
silently infer the prompt folder as the agent cwd. `stako plan <prompt-folder>`
should be the shared implementation behind `new` and later `open`, and it should
print the exact graph, paths, and thread commands before any runtime state is
created.

## Compatibility Rules

`stako new` can support both forms without ambiguity:

| Input | Interpretation |
|---|---|
| Existing directory | Prompt-folder mode. |
| Non-existing path with path separators | Error unless `--create-folder` is supplied. |
| Bare valid name | Existing stack-name mode. |
| Bare valid name plus `--from <folder>` | Create named stack from prompt folder. |

This avoids breaking current scripts while making the folder path the normal interactive workflow.

## Proposed CLI

```sh
stako new <prompt-folder> [--name NAME] [--root PATH] [--cwd PATH]
stako new <name> --from <prompt-folder> [--root PATH] [--cwd PATH]
stako add <stack> <prompt-folder> [--root PATH]
stako plan <prompt-folder> [--name NAME] [--root PATH] [--cwd PATH]
```

`stako plan` performs inference and validation without writing. `stako new` writes the stack after showing or logging the resolved paths.

## Inference Rules

Given:

```sh
stako new ./stako/discovery-gen
```

Stako should infer:

- `prompt_folder`: absolute path to `./stako/discovery-gen`.
- `stack_name`: folder basename, here `discovery-gen`, unless `--name` is supplied.
- `root`: nearest enclosing `stako/` directory when present, otherwise `~/stako`, unless `--root` is supplied.
- `cwd`: nearest Git worktree root that contains the prompt folder's parent, unless `--cwd` is supplied.
- `threads`: `[[thread]]` entries from `plan.toml`.
- `nodes`: `[[prompt]]` entries from `plan.toml`, in emit order.

The inferred `cwd` should be the directory where agents can read and write the target code, not the prompt folder.

## Inference Algorithm

The implementation should make inference deterministic:

1. Resolve `prompt_folder` to an absolute real path.
2. Load required `plan.toml` from the prompt folder.
3. Resolve explicit CLI flags, which override compatible plan header fields.
4. Infer `stack_name` from `--name`, plan `name`, then folder basename.
5. Infer `root` from `--root`, plan `root`, nearest enclosing `stako` directory,
   then default notes root.
6. Infer `agent_cwd` from `--cwd`, plan `cwd`/`agent_cwd`, nearest Git worktree
   root of the prompt folder, then the current process cwd only with a warning.
7. Resolve prompt-library paths referenced by `use` and `with`.
8. Validate thread commands, node names, thread references, `blocked_by` edges,
   cycles, and path fields.

If `prompt_folder` is under `<repo>/stako/<stack-name>`, the nearest Git worktree root should be `<repo>`, not `<repo>/stako/<stack-name>`.

## Planned Model Output

`stako plan` should have a human-readable default and a machine-readable form:

```sh
stako plan ./stako/discovery-gen
stako plan ./stako/discovery-gen --json
```

Human output should include:

```text
stack name: discovery-gen
prompt folder: /abs/repo/stako/discovery-gen
stack root: /abs/repo/stako
agent cwd: /abs/repo
threads: implementer(codex), checker(codex), reviewer(claude)
nodes: 010-plan ready, 020-implement blocked_by=010-plan, 030-check blocked_by=020-implement
warnings: none
```

`new`, `add`, and `open` should call the same planner so path and validation behavior cannot drift.

## Folder Layout

A stack folder holds the plan and its inputs. Reusable prompt bodies live in a
shared library *outside* the stack and are referenced by `use`; `stako/` folders
are for plans, not prompt libraries (see `09_unified_authoring_model.md`):

```text
prompts/                # shared, reusable library (tracked; serves many stacks)
  implement.md
  review.md
  fix.md

stako/<stack-name>/     # one plan instance
  plan.toml             # the graph
  plans/                # the implementation-plan inputs for this stack
    auth.md
    storage.md
  flups/                # agent-created follow-ups
```

For a small one-off, prompt bodies may sit beside the plan and be referenced by
relative `use` paths:

```text
stako/<stack-name>/
  plan.toml
  implement.md
  review.md
```

Scanning rules:

- `plan.toml` is required in folder mode and is the graph.
- `use` paths resolve against the prompt-library root (default `prompts/`), so the
  same bodies serve many stacks; bodies beside the plan are referenced by relative
  path.
- `flups/**/*.md` are not auto-enqueued during `new`; they are a workspace for
  discovered follow-ups and become graph nodes only through `stako inject` or an
  explicit plan edit.
- Files not referenced by the plan are ignored but may be listed as assets in
  plan output.

## Plan Manifest

Folder inference should be overrideable with the `plan.toml` header:

```toml
# stako/<stack-name>/plan.toml
name = "discovery"
cwd = "../.."

[paths]
artifact_roots = ["../art"]
worktrees = ["../zakura-p2p-stako", "../zakura-p2p-stako-discovery"]
```

Relative paths are resolved from the prompt folder, then stored as absolute paths
in the created stack. `plan.toml` is not optional in folder mode because it is
the graph, but path fields can remain minimal and let inference fill gaps.

Recommended fields:

```toml
name = "discovery"
cwd = "../.."
root = ".."

[paths]
artifact_roots = ["../../../art"]
worktrees = ["../.."]

[[thread]]
name = "implementer"
command = "codex"

[[prompt]]
name = "010-plan"
thread = "implementer"
use = "prompts/implement.md"
```

There is no manifest-vs-front-matter precedence rule because prompt files are
plain bodies and relational fields live only in `plan.toml`.

## Creation Behavior

`stako new <prompt-folder>` should:

1. Run the planner.
2. Refuse to continue on validation errors.
3. Create the stack directory.
4. Normalize the source `plan.toml` into the single canonical `plan.toml` under
   the stack root, resolving `use` and path fields to absolute. The source copy
   is consumed once, never kept as a second live graph.
5. Prepare runtime directories without creating a second graph copy.
6. Print the resulting stack name, root, cwd, thread count, and node count.

`stako add <stack> <prompt-folder>` should:

1. Run the same scanner.
2. Add new plan nodes or merge an explicit follow-up plan fragment.
3. Skip or report already-known completed/running prompts without hanging.
4. Never auto-enqueue `flups/` unless the operator explicitly asks for it.

## Implementation Plan

1. Add a planner data type that contains resolved paths, stack name, plan graph,
   referenced body files, warnings, and validation errors.
2. Add a prompt-folder scanner that finds `plan.toml`, referenced library files,
   and ignored assets.
3. Add path inference for stack name, Stako root, and Git worktree cwd.
4. Add `plan.toml` parsing with CLI flags taking precedence over compatible
   header values.
5. Add `stako plan <prompt-folder>` with text and JSON output.
6. Change `stako new` to accept either a stack name or a prompt folder, preferring folder mode when the argument is an existing directory.
7. Implement `stako new <name> --from <prompt-folder>` for explicit naming.
8. Teach `stako add <stack> <prompt-folder>` to reuse scanner output and avoid
   auto-adding `flups/`.
9. Store prompt folder and resolved path metadata for later agent-side follow-up insertion.

## Test Plan

- Folder under repo infers repo root as agent cwd.
- Folder outside repo requires explicit `--cwd` or emits a warning/error depending on strictness.
- Explicit `--name`, `--root`, and `--cwd` override plan header values and
  inference.
- Flat folder and nested prompt-library layout both work.
- `flups/` files are ignored on initial `new` unless explicitly included.
- Duplicate node names fail in `plan` and `new`.
- Missing thread and missing dependency fail in `plan` and `new`.
- `stako new <name>` remains compatible with the existing workflow.
- `stako new ./missing/path` errors clearly instead of creating a surprising stack name.

## Acceptance Criteria

- `stako new ./stako/my-stack` creates stack `my-stack` with agent cwd set to the containing repo root.
- `stako plan` prints the exact root, cwd, stack name, threads, prompts, and dependency problems.
- Explicit `--root`, `--cwd`, and `--name` override inferred values.
- Prompt-folder mode prevents the common mistake of using the prompt directory as the agent cwd.
