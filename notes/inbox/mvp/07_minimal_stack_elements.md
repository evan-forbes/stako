# Minimal Stack Elements

Stack execution should distinguish authored intent from runtime bookkeeping.

## Concepts

- A stack element is one queued authored TOML spec.
- A thread is the durable agent/provider/session target.
- A prompt is a portable Markdown or text fragment.
- A command is a special operation against a thread.

## Element TOML

Prompt element:

```toml
thread = "admin"
prompts = [
  "prompts/context.md",
  "prompts/review.md",
]
```

Command element:

```toml
thread = "admin"
command = "compact"
```

Rules:

- `thread` is required.
- Exactly one of `prompts` or `command` is required.
- `prompts` is ordered and non-empty.
- `command` is one of `compact`, `clear`, or `new`.
- Elements do not author `slug`, `kind`, `step`, `target`, `mode`, provider, or model.

Pointing at a thread means resuming that thread by default when it has known session state.

## Threads

Thread files own provider and session details. Stack elements only name a thread.

The existing durable thread schema still carries runtime metadata, but the intended minimal authored shape is:

```toml
provider = "codex"
session = "..."
status = "active"
```

Optional:

```toml
model = "..."
description = "..."
```

## Prompts

Prompt files are plain Markdown/text. Optional TOML frontmatter is allowed:

```markdown
+++
title = "review recent work"
+++

Review the latest stack outputs...
```

Frontmatter is metadata only. Routing belongs to the stack element.

Before submission, `prompts = ["a.md", "b.md"]` is materialized into one deterministic rendered prompt by concatenating prompt bodies in order with `---` separators. The rendered prompt is runtime output, not something users must author.

## Routines

Routines are expansion templates for stack elements:

```toml
thread = "admin"

[[step]]
prompts = ["../prompts/admin-review/evaluate.md"]
```

Ordering is source order unless dependencies are explicitly added later.

## Current Boundary

Routines now accept only minimal `[[step]]` entries. Queue `meta.toml` still stores runtime bookkeeping fields until the on-disk queue is split into authored element specs plus separate runtime records.
