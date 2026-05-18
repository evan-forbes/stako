# Writing Stako Routines

Stako keeps prompts and routines separate:

- Prompt files go in `~/stako/prompts/`.
- Routine files go in `~/stako/routines/`.
- A routine file is `~/stako/routines/<routine-name>.toml`.

Routine names come from the filename, so `~/stako/routines/planning.toml` defines the `planning` routine. A routine is an ordered list of steps.

```toml
thread = "admin"

[[step]]
prompts = ["../prompts/planning/prefix.md", "../prompts/planning/body.md"]

[[step]]
command = "compact"

[[step]]
thread = "builder"
prompts = ["../prompts/planning/build.md"]
```

Rules for agents:

- Put reusable prompt text in prompt files, not inside routine TOML.
- Use `prompts = [...]` to combine multiple prompt files into one prompt item.
- Prompt paths are relative to the routine file; from `~/stako/routines/`, use `../prompts/...`.
- Set `thread = "..."` at the root when every step uses the same thread.
- Add a step-level `thread = "..."` only when that step needs a different thread.
- Use `command = "compact"` for compact steps. `command = "/compact"` is accepted, but bare `/compact` is not TOML.
- Do not edit stack item metadata directly. Append routines with `stako add <routine> <stack>` or `stako add -r <routine> -s <stack>`.
