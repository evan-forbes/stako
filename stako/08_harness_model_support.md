# Harness and Model Support Design

## Problem

Stako currently stores one required thread field:

```toml
command = "codex"
```

That works for `codex` and `claude` when the harness default model is acceptable, but it does not give Stako a clear way to:

- launch additional harnesses such as `gemini` and `opencode`
- specify a model per thread
- use short, stable model nicknames instead of long provider model ids
- leave the model unset and let the harness choose its own default
- pass model flags as separate argv entries rather than as a fragile shell string

Stako should treat harness launch as structured configuration while keeping existing thread files valid.

## Goals

- Add first-class support for `gemini` and `opencode` alongside `codex` and `claude`.
- Add optional per-thread model selection.
- Provide easy model nicknames such as `fast`, `pro`, `flash`, `sonnet`, or `opus`.
- Resolve nicknames per harness, because the same nickname can map to different concrete models for different CLIs.
- Preserve current `command = "codex"` and `command = "claude"` thread files.
- Avoid shell parsing. Zellij thread launch should receive a concrete argv list.
- Make model selection visible in status, TUI, rendered prompt context, and audit metadata.

## Non-Goals

- Stako does not manage provider authentication.
- Stako does not guarantee that a configured model exists for the user's account.
- Stako does not fetch or update model catalogs in the first implementation.
- Stako does not force every harness to choose a model. Omitted `model` means "use the harness default."
- Stako does not need to support every CLI flag before supporting model selection.

## Current CLI Facts

At the time of this design pass:

- Gemini CLI documents `--model` / `-m` for startup model selection and also exposes built-in aliases such as `auto`, `pro`, `flash`, and `flash-lite`.
- OpenCode documents `--model` / `-m` for TUI and `run`, with model ids in `provider/model` form, and has `opencode models` to inspect available models.

Codex and Claude model flag behavior should be verified against local installed CLIs during implementation, but the Stako design should not depend on hard-coded shell strings either way.

Sources:

- Gemini CLI reference: <https://github.com/google-gemini/gemini-cli/blob/main/docs/cli/cli-reference.md>
- OpenCode CLI reference: <https://opencode.ai/docs/it/cli/>

## Proposed Thread Front Matter

Minimal compatible form:

```toml
+++
type = "thread"
thread = "builder"
command = "gemini"
model = "pro"
+++
```

Optional model omitted:

```toml
+++
type = "thread"
thread = "reviewer"
command = "opencode"
+++
```

Existing files still work:

```toml
+++
type = "thread"
thread = "builder"
command = "codex"
+++
```

Recommended future explicit form:

```toml
+++
type = "thread"
thread = "reviewer"
harness = "opencode"
model = "sonnet"
+++
```

The first implementation can keep `command` required and add optional `model`.
`harness` can be added as an optional alias when command wrappers become common.

## Compatibility Rules

| Front Matter | Meaning |
|---|---|
| `command = "codex"` | Launch `codex`; no model flag. |
| `command = "codex"`, `model = "fast"` | Launch `codex` with the model resolved through Codex aliases. |
| `command = "gemini"`, `model = "flash"` | Launch `gemini --model <resolved flash model>`. |
| `command = "opencode"`, `model = "anthropic/claude-sonnet-4.5"` | Launch `opencode --model anthropic/claude-sonnet-4.5`. |
| `command = "/path/to/wrapper"` | Launch wrapper; no model flag unless `harness` identifies a known adapter. |
| `command = "/path/to/wrapper"`, `harness = "gemini"`, `model = "pro"` | Launch wrapper with Gemini-style model args. |
| `model` set on unknown harness | Error unless a config entry defines the model flag shape. |

This keeps raw command compatibility while making model behavior explicit and testable.

## Harness Adapter Model

Add a small adapter layer that resolves thread launch configuration into argv:

```text
Thread config -> Harness adapter -> argv entries passed after zellij `--`
```

Example resolutions:

```text
command=gemini, model=flash
=> ["gemini", "--model", "gemini-2.5-flash"]

command=opencode, model=sonnet
=> ["opencode", "--model", "anthropic/claude-sonnet-4.5"]

command=claude, model unset
=> ["claude"]
```

The adapter should have:

- `harness`: canonical name, for example `codex`, `claude`, `gemini`, `opencode`, or `custom`
- `executable`: first argv entry, defaulting to `command`
- `model_arg`: usually `--model`, omitted when model is unset
- `model_aliases`: per-harness nickname map
- `settle_delay`: optional delivery timing hint for slash-command actions
- `supports_actions`: whether `new`, `clear`, and `compact` are known to work

The launch path in `src/zellij.zig` should move from appending one `command` string to appending a resolved argv slice. This is necessary because `zellij action new-tab -- <cmd> <arg> ...` can pass flags safely when they are separate argv entries.

## Model Nicknames

Nicknames should be per harness. A single global alias table is too ambiguous because `pro` under Gemini and `pro` under Codex may mean different concrete models.

Suggested default alias shape:

```toml
[models.gemini]
auto = "auto"
pro = "pro"
flash = "flash"
flash-lite = "flash-lite"

[models.opencode]
sonnet = "anthropic/claude-sonnet-4.5"
opus = "anthropic/claude-opus-4.5"
gpt = "openai/gpt-5"

[models.codex]
fast = "gpt-5-codex-mini"
deep = "gpt-5-codex"

[models.claude]
sonnet = "sonnet"
opus = "opus"
```

These defaults should be treated as examples until verified during implementation. The important behavior is that users can override them.

## Config Placement

Model aliases can live in stack or root config. Recommended search order:

1. prompt-folder manifest aliases
2. stack-local aliases
3. root-level aliases, for example `<root>/models.toml`
4. built-in aliases

Example prompt-folder manifest:

```toml
[threads.builder]
command = "gemini"
model = "flash"

[threads.reviewer]
command = "opencode"
model = "sonnet"

[models.opencode]
sonnet = "anthropic/claude-sonnet-4.5"
```

The resolved concrete model should be persisted in run/thread metadata so later status output does not change if the alias table changes.

## Optional Model Semantics

The model field is optional by design.

- If `model` is omitted, Stako launches the harness without a model flag.
- If `model` is set to a known nickname, Stako resolves it to a concrete model string.
- If `model` is set to an unknown nickname, Stako can either pass it through as a concrete model or warn depending on config.
- If `model` is set but the harness has no known model argument shape, Stako returns a validation error.

Recommended behavior:

```text
known harness + unknown model string => pass through with a warning if aliases exist
unknown harness + model set          => error
unknown harness + model unset        => launch command unchanged
```

This allows concrete provider model ids without forcing every id into a registry.

## CLI Additions

Helpful commands:

```sh
stako harnesses
stako models [--harness NAME]
stako model resolve <harness> <nickname-or-model>
stako plan <prompt-folder>
```

`stako plan` should print each thread with:

- thread name
- harness
- command argv
- requested model
- resolved model
- whether model is omitted
- warnings for unknown aliases or unsupported model flags

Example:

```text
thread builder:
  harness: gemini
  argv: gemini --model gemini-2.5-flash
  model: flash -> gemini-2.5-flash

thread reviewer:
  harness: opencode
  argv: opencode
  model: <harness default>
```

## TUI Implications

The TUI should show harness and model as first-class thread attributes:

```text
builder   gemini    flash -> gemini-2.5-flash
reviewer  opencode  default
checker   codex     fast -> gpt-5-codex-mini
```

Useful TUI actions:

- choose harness for a new thread
- choose a model nickname or leave model unset
- inspect resolved argv before stack creation
- warn when a model is set for an unsupported custom harness
- show delivery timing hints for harnesses with action race risk

The TUI should call the same resolver used by `stako plan`; it should not duplicate alias resolution.

## Python API Implications

The Python front-matter API should accept an optional model:

```python
impl = s.thread("implementer", command="gemini", model="flash")
review = s.thread("reviewer", command="opencode")
```

Generated front matter should omit `model` when `None`:

```toml
+++
type = "thread"
thread = "reviewer"
command = "opencode"
+++
```

When a model is present, it should write exactly the nickname or concrete model requested by the script. Stako resolves it during planning/addition.

## Store Changes

Thread metadata should gain:

```toml
command = "gemini"
model = "flash"
resolved_model = "gemini-2.5-flash"
harness = "gemini"
argv = ["gemini", "--model", "gemini-2.5-flash"]
```

The first implementation can avoid persisting `argv` if it can be recomputed from immutable persisted fields, but `resolved_model` should be persisted once a stack is planned or created.

Parsing changes:

- `src/prompt.zig`: parse optional `model` and optional `harness` for thread files.
- `src/store.zig`: persist optional model fields and resolved harness metadata.
- `src/zellij.zig`: launch tabs with resolved argv slices instead of a single command.
- `src/cli.zig`: include harness/model in `status`; add model validation in `add`/`new`.

## Validation Rules

- Thread `command` remains required for the first migration.
- `model` must be a non-empty string when present.
- `harness` must be a valid name when present.
- Built-in harness names: `codex`, `claude`, `gemini`, `opencode`.
- A model on a custom harness requires a configured `model_arg`.
- Resolved argv must contain at least one element.
- The first argv element must not be empty.
- Stako should not split `command` on spaces. If users need wrappers, use a wrapper executable path or a future structured `argv` field.

## Implementation Plan

1. Add optional thread `model` and `harness` parsing while preserving existing required `command`.
2. Add a harness resolver module that returns canonical harness, requested model, resolved model, model source, and argv.
3. Add built-in adapters for `codex`, `claude`, `gemini`, and `opencode`.
4. Add alias config loading from stack/root config with built-in fallbacks.
5. Change zellij tab launch to accept resolved argv slices.
6. Persist resolved harness/model metadata in thread state.
7. Print harness/model details in `status` and structured status JSON.
8. Extend folder planner to validate thread harness/model config before stack creation.
9. Update the Python API design/implementation to accept optional `model`.
10. Add TUI fields and picker actions after the read-only TUI exists.

## Test Plan

- Existing thread files with only `command = "codex"` still parse and launch as `["codex"]`.
- `command = "gemini"`, `model = "flash"` resolves to separate argv entries and does not shell-split.
- `command = "opencode"`, `model = "anthropic/claude-sonnet-4.5"` passes through the concrete provider model.
- `command = "opencode"` with no model launches without `--model`.
- `model` on an unknown command errors unless a harness adapter is configured.
- Alias overrides in prompt-folder or stack config beat built-in aliases.
- `stako plan` prints requested and resolved model values.
- `status --json` includes harness, requested model, resolved model, and argv.
- Zellij fake adapter tests assert full argv, not only executable name.
- Python-generated thread files omit `model` when `None` and include it when set.

## Acceptance Criteria

- A stack can define threads for `codex`, `claude`, `gemini`, and `opencode`.
- Any thread can omit `model` and use the harness default.
- Known model nicknames resolve per harness and appear in `stako plan`.
- Zellij receives model flags as argv entries, not as one shell string.
- The TUI and status output make harness and model choice visible before work starts.
