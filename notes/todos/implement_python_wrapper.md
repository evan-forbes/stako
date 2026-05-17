# Implement Python Wrapper (Follow-Up)

## Scope

A small Python wrapper can be useful for scripts and integration tests once the HTTP API stabilizes. It is not part of the core implementation ladder.

## Planned Surface

- `Client(port=None, root=None)`
- Read methods for stacks, stack config, and items.
- Mutation methods for create/append/insert/retry/cancel/supersede/pause/resume/config.
- Typed exceptions mapped from `error.code`.
- Optional SSE iterator.

## Rules

- The wrapper speaks only to the daemon HTTP API.
- It does not read or write stack files directly, except perhaps an optional audit-log tail helper.
- It should stay single-file or very small until there is real pressure to package it.

## Out of Scope

- Async API.
- PyPI packaging.
- Reimplementing CLI behavior.
