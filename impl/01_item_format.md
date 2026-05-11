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

## Implementation notes

**TOML parser choice: minimal in-repo implementation (`src/toml.zig`).**

The `meta.toml` schema is fully under our control and uses only a tiny subset
of TOML: top-level scalar keys, single-level `[table]` headers, strings,
integers, booleans, RFC3339 datetimes, and string arrays. No inline tables,
no arrays-of-tables, no dotted keys, no multiline strings. A hand-rolled
parser fits in ~250 lines and is easier to keep round-trip-stable than wiring
in a third-party library (datetime literals in particular are stored as their
literal source text so the writer emits them verbatim). This also avoids
adding a `build.zig.zon` dependency for a one-off internal need. If/when we
need richer TOML for `stack.toml` or `config.toml`, we revisit; the schema
needs there are similarly narrow.

**Round-trip strategy.** The writer emits keys in a canonical order. Fixtures
are authored in that same order, so read → write is byte-stable for every
fixture in the test suite. A second-pass test (`read → write → read → write`)
guarantees that even if a hand-edited file deviated from canonical order, the
writer output is a fixed point.

**Status transitions.** The state-machine table from
`todos/design_state_machine.md` lives in `src/state.zig` as
`VALID_TRANSITIONS` with `isValidTransition(from, to)`. Tests cover every
valid pair plus a representative set of invalid ones. The validator does not
itself check transitions because that requires a *prior* status; transition
enforcement is the daemon's job in a later milestone — see the design doc.

**Workdir allowlist.** Parsed but not enforced here; the plan calls out that
allowlist checking lands in milestone 6. The `prompt_with_workdir` fixture
exercises the parse path.
