# Directory and Worktree Model Design

> Updated by `09_unified_authoring_model.md`: the path *roles* below
> (`agent_cwd`, worktrees, artifact roots) are unchanged, but they live in the
> `plan.toml` header rather than a separate `state/paths.toml`. Runtime artifacts
> (`runs/`, `events.jsonl`, `runner.pid`) live under the stack root. Read the role
> definitions and validation here; read 09 for where they are stored.

## Problem

Prior runs repeatedly hit path confusion:

- `--cwd` must be the repository root, not the prompt folder.
- Prompt bodies referenced files outside the repo, such as a neighboring `art/` directory.
- Worktrees and org-level Stako roots were not explicit.
- Symlinks were used as one-off fixes for paths that should have been modeled.

Stako needs a clear directory model that separates prompt storage, stack state, agent working directory, and artifact roots.

## Concepts

| Concept | Meaning |
|---|---|
| Prompt folder | Source Markdown files used to create or extend a stack. |
| Stack root | Stako's durable state root, containing `stacks/<name>/runs/...`. |
| Stack name | Stable name under the stack root. |
| Agent cwd | Directory where zellij thread commands launch; usually a Git worktree root. |
| Worktree | A Git working tree agents may read/write. |
| Artifact root | Nearby durable content directory agents may read/write, such as `art/`. |

These should be independently configurable. The prompt folder is not automatically the agent cwd.

## Second-Pass Review

This plan is foundational because every other feature depends on knowing where things live. The best solution is to separate paths by role and store the resolved absolute values in stack metadata at creation time. Runtime code should not need to infer the repo root again when delivering a prompt.

The prior failure mode was not just "wrong cwd"; it was that several path roles
were collapsed into one mental slot. Stako should make those roles visible in
`plan`, `paths`, `status`, and status JSON; the deferred TUI can consume the same
data later.

## Path Invariants

- `stack_root` is where Stako stores durable runtime state.
- `prompt_folder` is where the plan and its inputs live.
- `prompt_library` is the shared root that node `use` paths resolve against; one
  library serves many stacks and is tracked independently of any stack.
- `agent_cwd` is where zellij thread commands launch.
- `primary_worktree` is the Git worktree containing `agent_cwd`, when one exists.
- `artifact_roots` are additional declared locations, not implicit search paths.
- Every persisted path is absolute.
- Relative paths in manifests are resolved from the prompt folder.
- Relative paths in prompt bodies are interpreted by agents from `agent_cwd`, so Stako should warn when they appear to point somewhere else.

The current `cwd` field can remain as a compatibility alias for `agent_cwd`, but new docs and APIs should use `agent_cwd`.

## Proposed Plan Header

```toml
# plan.toml
name = "discovery"
prompt_folder = "/home/evan/src/valar/zakura-p2p-stako/stako/discovery-gen"
stack_root = "/home/evan/src/valar/zakura-p2p-stako/stako"
agent_cwd = "/home/evan/src/valar/zakura-p2p-stako"
primary_worktree = "/home/evan/src/valar/zakura-p2p-stako"

[paths]
worktrees = [
  "/home/evan/src/valar/zakura-p2p-stako",
]
artifact_roots = [
  "/home/evan/src/valar/art",
]
```

Prompt files can then refer to declared aliases instead of fragile relative paths:

```text
Read {artifact:zakura/discovery/plan.md}
Work in {worktree:zakura-p2p-stako}
```

Alias rendering can be a later feature. The first step is to store and validate the paths explicitly.

## Metadata Placement

The stack's durable path metadata lives in the `plan.toml` header. Runtime files
live next to the plan under the stack root:

```text
<stack_root>/stacks/<stack-name>/plan.toml
<stack_root>/stacks/<stack-name>/runs/
<stack_root>/stacks/<stack-name>/events.jsonl
<stack_root>/stacks/<stack-name>/runner.pid
```

Recommended normalized header:

```toml
name = "discovery"
prompt_folder = "/abs/repo/stako/discovery-gen"
stack_root = "/abs/repo/stako"
agent_cwd = "/abs/repo"
primary_worktree = "/abs/repo"

[paths]
artifact_roots = ["/abs/art"]
worktrees = ["/abs/repo"]
```

The planner may accept relative path fields in source `plan.toml`, but created
stack metadata should store resolved absolute paths so delivery never repeats
cwd inference.

## Validation Rules

- `agent_cwd` must exist and be a directory.
- If `agent_cwd` is inside a Git worktree, record the worktree root.
- `prompt_folder` may be inside or outside the worktree.
- `artifact_roots` must exist unless explicitly created by `stako new --create-paths`.
- Every path stored in stack metadata is absolute.
- Stako should warn when prompt bodies contain relative paths that do not resolve from `agent_cwd`.

Additional validation:

- `stack_root` must be writable before creating a stack.
- `prompt_folder` must be readable and should be writable if agent-side FLUP creation is enabled.
- `agent_cwd` should not be inside the prompt folder unless explicitly allowed.
- Declared `worktrees` must be Git worktrees or must be marked as plain directories.
- A per-prompt cwd override must be within a declared worktree unless explicitly allowed.
- Artifact roots should be listed in rendered prompt context so agents know they are intentional.

## Worktree Support

Worktrees matter because a stack may be created under an org-level Stako directory while agents work in a repo-specific worktree. Stako should support:

- Multiple declared worktrees per stack.
- A primary `agent_cwd`.
- Per-prompt cwd override for tasks that intentionally target a different worktree.
- Status output showing which worktree each prompt uses.

Per-prompt cwd overrides should be explicit and validated before delivery.

Recommended node field for a cwd override:

```toml
[[prompt]]
name = "050-update-artifact"
thread = "builder"
cwd = "{worktree:zakura-p2p-stako-discovery}"
```

For the first implementation, use absolute paths or manifest aliases resolved during `new`/`add`. Do not resolve aliases dynamically at delivery time unless the stack metadata is immutable enough to make that deterministic.

## Worktree Detection

Git detection should use commands equivalent to:

```sh
git -C <path> rev-parse --show-toplevel
git -C <path> rev-parse --git-common-dir
```

The planner should walk upward from the prompt folder and from the current cwd. If the prompt folder is under a repo's `stako/` directory, the repo root should win. If no Git worktree is found, require `--cwd` in strict mode or warn in permissive mode.

## Prompt Reference Warnings

Stako does not need a full Markdown parser to catch useful path mistakes. A first pass can scan prompt bodies for path-looking tokens:

- `../`
- `./`
- `/home/`
- known sibling names such as `art/` when declared in the manifest

Warnings should be advisory, not blocking, unless a prompt explicitly declares
required paths in `plan.toml`.

Future node field:

```toml
[[prompt]]
name = "050-use-artifact"
thread = "builder"
requires_paths = ["{artifact:design/spec.md}", "{worktree:repo/src/main.zig}"]
```

## Implementation Plan

1. Add a `PathConfig` data type with `prompt_folder`, `stack_root`, `agent_cwd`, `primary_worktree`, `worktrees`, and `artifact_roots`.
2. Teach folder planning and stack creation to persist `PathConfig` in the
   normalized `plan.toml` header, while keeping `cwd` as an alias for
   `agent_cwd`.
3. Add Git worktree detection during folder-first planning.
4. Add `stako paths <stack>` to print path roles and warnings.
5. Render path context into prompts so agents know the intended cwd, prompt folder, stack root, and artifact roots.
6. Add lightweight prompt-body path warnings.
7. Add optional alias rendering for declared worktrees and artifact roots.
8. Add per-prompt cwd override support with validation and status display.

## Test Plan

- `agent_cwd` is stored as an absolute path and survives running `stako start` from another directory.
- Prompt folder under `<repo>/stako/<name>` infers `<repo>` as `agent_cwd`.
- Org-level stack root can point agents at a sibling repo worktree.
- Sibling artifact root is stored and shown without requiring symlinks.
- Missing artifact root fails unless `--create-paths` or equivalent is supplied.
- Per-prompt cwd override outside declared worktrees is rejected.
- `stako paths` shows every path role and any path warnings.

## Acceptance Criteria

- `stako plan <prompt-folder>` shows prompt folder, stack root, stack name, agent cwd, worktree root, and artifact roots.
- Stako no longer requires symlinks to make common sibling artifact directories visible.
- Prompt delivery uses the declared agent cwd, not the prompt folder.
- Worktree mistakes are detected before agents start editing files.
