# Milestone 1 Review

Diff range: 31de9a2..b613693

## Blocking

(none)

## Non-blocking

- `test/fixtures/items_invalid/` — invalid fixtures live in a sibling tree rather than under the strategy-doc's `test/fixtures/items/`. 00_test_strategy.md doesn't actually mandate a location for negative fixtures, but keeping them under a subdir of `items/` (e.g. `items/_invalid/`) would keep all item fixtures co-located.
- `src/item.zig:174` — `parseSlice` swallows the inner TOML parse error name into `diag.field` (uses `field` for the error name instead of the offending source field). It works but conflates two semantic slots; consider a separate `inner_err` or extending `ParseDiagnostic.message`.
- `src/item.zig:194-258` — unknown top-level keys are silently tolerated for "forward-compatibility." That's defensible but means typos like `created-at` instead of `created_at` would surface only as `MissingField` rather than a more useful "unknown key". Worth a TODO comment at minimum.
- `src/toml.zig:196-203` — any value token starting with `t`/`f` other than the literal words `true`/`false` returns `InvalidBoolean`, which is slightly misleading if the user meant a bare identifier. Acceptable for our fixed schema; not user-facing yet.
- `src/toml.zig:165-171` — `if … i += 1 else if (i < source.len) return error.TrailingGarbage` returns `TrailingGarbage` after consuming a lone `\r` without `\n`. Harmless because we don't author CR-only files, but the error is opaque if it ever fires.
- `test/item_format_tests.zig:217-225` — the negative "invalid datetime" test asserts `error.BadType`, not `error.InvalidDatetime`. The `2026-05-10T14:32` shape case (line 227) covers the latter via the validator. Both behaviors are sensible, but the diagnostic for a quoted `"yesterday"` says "expected datetime" — slightly indirect for the user-facing "invalid datetime" criterion in the plan.
- `src/item.zig:179-187` — placeholder values (`.id = ""`, `.kind = .prompt`, …) used before overwriting can mask bugs in error paths. They're harmless because the required-field check guarantees they're overwritten on success, but a sentinel like `.kind = undefined` would surface misuse.
- `test/fixtures/items/compact_chained/meta.toml` — compact fixture has only `[target]` with `provider`; design says provider/model are "inherited from stack continuity" for compact. Not wrong here (schema-reserved kind, behavior deferred), but a comment in the fixture noting why no model is set would help future readers.
- `src/state.zig:60-73` — `VALID_TRANSITIONS` listing is correct but doesn't capture the "restart-orphan" subtype of `running → failed`. The transition table is collapsed to (from,to) pairs, which is what the daemon needs, but the design table lists `running → failed` twice with different triggers. Worth a comment if a future reviewer wonders why one row got dropped.

## Deferred-confirmed

- **Daemon, HTML rendering, version-control commits**: explicitly listed as out-of-scope in the plan's "Out of Scope" section. No code touches them in the diff. Legitimate deferrals.
- **Workdir allowlist enforcement**: plan says workdir is parsed but not validated in this milestone; allowlist check lands in milestone 6. The `prompt_with_workdir` fixture exercises the parse path; validator accepts it. Legitimate deferral, plan explicitly calls this out.
- **`apply_transition` / transition enforcement in the validator**: the implementation note in the plan states "The validator does not itself check transitions because that requires a *prior* status; transition enforcement is the daemon's job in a later milestone." The `state.isValidTransition` predicate is present and tested. Legitimate deferral.
- **`compact` and `clear` runtime behavior**: schema-reserved here, runtime semantics deferred. Plan step 6 explicitly calls this out. Legitimate.
- **File I/O for writer**: only `write(item, writer)` exists; no `writeFile`. The plan doesn't strictly require a file-level writer, but later milestones will need one. Non-blocking for milestone 1.

## Acceptance criteria

- **Typed schema exists in code** — MET. `src/item.zig` defines `Item`, `Target`, `Requires`, `Sleep`, `Clear`, `Result`, `Kind`, `Match`; `src/state.zig` defines `Status`. All non-trivial fields are properly typed and optional where the design allows.
- **Round-trip tests pass for every fixture** — MET. `test/item_format_tests.zig` has both first-pass byte-stable round-trip (`fixtures: round-trip byte-stable`) and second-pass fixed-point round-trip (`read→write→read→write`) tests across all 11 fixtures. `zig build test` reports 34/34 passing.
- **Validator rejects each negative-test case with a clear error message** — MET. Negative fixtures (`missing_id`, `unknown_kind`, `bad_status`, `bad_datetime`, `bad_id`, `bad_slug`, `bad_parent`, `sleep_missing_until`, `prompt_no_target`) all have matching tests; each populates a `ParseDiagnostic` or `ValidationDiagnostic` with a typed error and field name. The "invalid datetime" case routes via `BadType` rather than `InvalidDatetime` for the quoted-string variant, with a second test case covering the malformed-shape variant via the validator.
- **Fixtures live under `test/fixtures/items/` and are reusable by later milestones** — MET. All eleven positive fixtures live under `test/fixtures/items/<name>/meta.toml` (plus `prompt.md` where the kind requires a body). Negative fixtures live under a sibling `test/fixtures/items_invalid/`, which is consistent with the strategy doc (which doesn't specify where negative fixtures go) but slightly off-spec if `test/fixtures/items/` is read strictly. The fixture format is byte-stable.
