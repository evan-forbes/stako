# 01 — Stack Item File Format

## Goal

Lock in the on-disk schema for stack items. Produce a typed Zig representation with reader, writer, and validator. Provide a fixture set every later milestone can read against without a running daemon.

## Design Reference

- `../todos/design_stack_item_format.md`
- `../todos/design_state_machine.md` (status enum + valid transitions)

## Steps

1. Pick a TOML parser/writer for Zig (vendor or use std-adjacent — decide and record here).
2. Define the typed struct(s) for `meta.toml` covering: top-level fields, `[target]`, `[requires]`, kind-specific tables (`[sleep]`, `[clear]`, optional others), and terminal `[result]` metadata.
3. Implement reader: file path → typed struct, with explicit validation errors.
4. Implement writer: typed struct → file content, round-trip-stable (same logical document after read→write).
5. Implement validator: required fields per kind, status enum bounds, ID/slug shape, parent-ID format, valid status-transition table from `design_state_machine.md`.
6. Write fixture set:
   - One item per kind (`prompt`, `compact`, `clear`, `sleep`, `review`). `compact` and `clear` are schema-reserved here; behavior lands only after adapter resume semantics are stable.
   - One example per terminal status (`completed`, `canceled`, `failed`, `superseded`).
   - One review item with `parents = ["0005"]`.
7. Round-trip tests for every fixture.
8. Negative tests: missing required field, unknown kind, malformed status, invalid datetime, out-of-allowlist workdir reference (workdir validation itself lands in milestone 6; here we just confirm the field is parsed).

## Acceptance

- Typed schema exists in code.
- Round-trip tests pass for every fixture.
- Validator rejects each negative-test case with a clear error message.
- Fixtures live under `test/fixtures/items/` and are reusable by later milestones.

## Out of Scope (deferred)

- No daemon yet. Standalone library code only.
- No HTML rendering — fixtures are byte-for-byte TOML.
- No version control commits.
