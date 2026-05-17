# Audit — Milestone 1: Stack Item File Format

Baseline: bc0b56e. Modules audited: `src/toml.zig`, `src/state.zig`, `src/item.zig`. Tests audited: `test/item_format_tests.zig` plus the in-file `test` blocks in each module. Fixtures audited: every directory under `test/fixtures/items/` and every file under `test/fixtures/items_invalid/`.

## Execution traces

**Trace A: round-trip of `prompt_basic`.** `parseFile` opens `meta.toml`, stats it, allocates a heap buffer, calls `readAll`, then `parseSlice`. `parseSlice` invokes `toml.parse` (which builds a `Document` with its own arena that owns *raw* parsed key/value strings) and then walks `doc.entries.items` once, duping each consumed string from the toml arena into a freshly-initialized `item.arena`. The two arenas are independent: when `doc.deinit()` runs via `defer`, the strings in `item` are unaffected because they were duped, not aliased. After the walk, `parseSlice` promotes the local target/requires/result locals into the optional fields on `item` based on which `[table]` headers `doc.hasTable` saw. Finally the post-loop required-field check at lines 346–351 fires `error.MissingField` if any top-level required scalar is absent. `write` then emits keys in a canonical order; the fixture is authored in that order, so round-trip is byte-stable. The second-pass test confirms the writer is a fixed point.

**Trace B: negative `bad_datetime.toml` (`created_at = "yesterday"`).** TOML parses the value as a `string` (it begins with `"`). The parseSlice top-level dispatcher sees `key == "created_at"` and calls `requireDatetime`, which returns `error.BadType` because the union tag is `.string`, not `.datetime`. The diagnostic field is set to `created_at`. Note the test name says "invalid datetime" but the actual returned error is `BadType` — the contract here is that any string-typed datetime field fails the type check at parse time, while a *datetime-shaped* literal that doesn't actually match RFC3339 (the "negative: invalid datetime shape (validator)" inline test) is caught later by `isRfc3339` returning `error.InvalidDatetime` in the validator.

**Trace C: empty `[clear]` table.** The toml parser appends `"clear"` to `doc.tables` when it sees `[clear]`, but produces no entries because there are no `key = value` lines beneath it. `parseSlice` sets `have_clear_table = doc.hasTable("clear") = true` and leaves `clear_has_body = false`. After the loop, `item.clear_present = true`, `item.clear_has_body = false`. Validator's `.clear` arm sees `!item.clear_has_body` and passes. The writer's `if (item.clear_present) try w.writeAll("\n[clear]\n");` emits the empty header, matching the fixture byte-for-byte.

**Trace D: invalid pair in `state.zig`.** `state.isValidTransition(.queued, .queued)` short-circuits to `false` via the `from == to` guard at line 76. Any not-listed pair iterates `VALID_TRANSITIONS` (12 entries) and returns false. The exhaustive test "invalid transitions are every unlisted pair" verifies the symmetric difference: every pair not in `VALID_TRANSITIONS` is rejected. The companion test in `item_format_tests.zig` is a redundant but useful anchor in case `state.zig`'s in-file tests get extracted.

## Blocking

None.

## Important

- **`item.zig:135-152`** — `ParseError` declares variants that the parser never returns. `InvalidStateTransition`, `InvalidIdFormat`, `InvalidSlugFormat`, `InvalidParentId`, `InvalidDatetime`, `MissingSleepTable`, `MissingTargetTable`, and `UnexpectedTable` are all reachable only from `validate()`, which has its own separate `ValidationError` set. A caller writing `catch |e| switch (e) { ... }` on `parseSlice`'s result will see dead arms and be misled about what the parser can fail with. Either prune `ParseError` to the seven errors actually returned (`Toml`, `MissingField`, `UnknownKind`, `UnknownStatus`, `UnknownMatch`, `InvalidSleep`, `BadType`, `OutOfMemory`) or fold parse-time and validation-time errors into one unified set used consistently — but the current state is misleading.

- **`item_format_tests.zig`** — No test exercises a *datetime-shaped* but semantically invalid `sleep.until`. `2026-99-99T00:00:00Z` (or any out-of-range month/day/hour) parses as a TOML datetime literal and then must be rejected by `validate()` via `isRfc3339`. The plan's step 8 calls for "invalid datetime" coverage; the existing inline test only covers an invalid `created_at`. Add a sleep-specific case so the kind-specific datetime path is anchored. (The `isRfc3339` unit test in `item.zig` covers the predicate directly, but the integration through `validate()` for the `[sleep]` arm is untested.)

- **`item.zig:287-292`** — Any unknown key under `[sleep]` is silently rolled into a single `sleep_has_extra_body` boolean. The validator then reports `SleepHasBody` with `field = "sleep"`. The diagnostic message loses which key was the offender — making the error unhelpful for a user who typo'd `untill`. At minimum, record the first unknown key name on the Item (or in the diagnostic) so the validator can surface it.

## Minor

- **`toml.zig:142`** — `if (i < source.len and source[i] == '\n') i += 1 else if (i < source.len) { return error.TrailingGarbage; }` (and the identical pattern at line 169) packs an `if-else` into one expression statement. It's correct but reads strangely; a small `if/else if/else` block would be easier to scan. The check pattern is duplicated between table-header trailing logic and key/value trailing logic — could be extracted into a `consumeLineEnd` helper.

- **`toml.zig:304`** — `parseStringArray` returns `error.UnterminatedArray` when the actual condition is "expected `,` or `]` after string". `UnexpectedCharacter` is a closer fit semantically.

- **`toml.zig:225-234`** — `looksLikeDatetime` only checks the leading `YYYY-MM-DD` ten characters. A pathological token like `0123-67-89garbage` is accepted as a datetime by the TOML layer and only rejected by `isRfc3339` at validation time. Functionally fine (the validator catches it), but a one-line tightening (require either end-of-token at 10 or `T`/`t`/space at index 10) would push the rejection earlier with a clearer error.

- **`item.zig:222-312`** — The flat `if/else if` chain dispatching on `(table, key)` is long but readable; it does not warrant abstracting into a table-driven structure at this size. Mentioning so the next reader doesn't reflexively "refactor" it.

- **`item.zig:466-470`** — `WriteVal` duplicates `toml.Value` minus a couple variants. Two near-identical value unions in one module is a minor papercut; consider reusing `toml.Value` with an emitter dispatch.

- **`item.zig:407-411`** — `dupeStringArray` always re-dupes strings that are already in the toml arena into the item arena. That copy is required (separate lifetimes), but the function name doesn't make that ownership transfer explicit. Renaming to `cloneIntoArena` or adding a one-line comment would help.

- **`item.zig:597-599`** — `targetHasAnyField` will need updating any time `Target` gains a field; a `@typeInfo`-driven check would be self-maintaining. Currently a four-field hand-list. Fine, but flagged for when Target grows.

- **`state.zig:95-99`** — "valid transitions match transition table" is a tautology (it iterates `VALID_TRANSITIONS` and asserts each pair is valid; `isValidTransition` linear-scans the same table). The test does not protect against any plausible regression. The "invalid transitions are every unlisted pair" test below it is the load-bearing one.

- **`item_format_tests.zig:404-436`** — "state machine: full transition matrix matches design" hand-lists the same 12 transitions a second time. If this is intentional (anchoring an external invariant in the test file even if `VALID_TRANSITIONS` drifts), add a comment to that effect. Otherwise, drop it as duplicated work.

- **`item.zig:154-166`** — `ParseDiagnostic.format` uses `@errorName(self.err)`. Fine, but `field` is documented as "may be empty"; surface the empty-vs-present distinction in `format` more explicitly (current code does check `self.field.len > 0`, so this is just a comment cleanup nit).

- **`item.zig:601-607`** — `isValidId` accepts any 4-or-more-digit string. The design says "zero-padded numeric identifier (`0001`, `0002`, ...)". `"99999999"` is allowed; so is `"0000"`. Neither is incorrect per the rule as currently written (zero-padded to *minimum* 4), but worth confirming the intent — should `"00000"` be valid? If yes, current code is right; if the intent was exactly 4 digits and any further digits arrive only when 10000+ items exist in one stack, that constraint is undocumented.

- **`item.zig:609-620`** — `isValidSlug` has no maximum length. Practically fine since filenames cap at OS-dependent limits, but a max (say 64) would defend against accidental wall-of-text slugs.

## Coverage gaps

- **Sleep with malformed-but-datetime-shaped `until`** — see Important. No test currently routes through the `kind = .sleep` validator arm with a bad `isRfc3339` value.
- **Empty `parents = []` array** — the parser accepts it, and `validate` iterates zero times. No test asserts either behavior. The design example shows `parents = ["0005"]`; if `[]` should be rejected, that needs a test; if it's tolerated, that should be explicit.
- **Compact item missing `[target]` entirely** — only "missing provider on target" is tested. The case where the whole `[target]` table is absent for a compact item hits a different validator branch (`item.target == null`) and is uncovered.
- **Review item without `[target]`** — the validator's `.review` arm requires `[target]` (it's grouped with `.prompt`), but no negative fixture covers it. `prompt_no_target.toml` exercises the prompt arm; the review path is structurally the same but separately uncovered.
- **Terminal status without `[result]`** — design says `[result]` is written after running-→terminal transitions (`completed`/`failed`) but not for `queued`-→terminal transitions (`canceled`/`superseded`). The validator does not enforce this asymmetry. The fixtures match the design correctly, but no test asserts that a `completed` item *without* `[result]` would be flagged, or that a `canceled` item *with* `[result]` would also be accepted. The plan does not explicitly call for this, so this may be deliberate deferral — flagging for awareness.
- **TOML round-trip with comments** — `parseSlice` strips comments, and the writer emits none. No test demonstrates the documented "second-pass fixed-point" property starting from a hand-edited (commented) source. The existing second-pass test starts from fixtures that are already comment-free, so it doesn't exercise the comment-stripping path.
- **Unicode in string values** — `parseString` handles ASCII escape sequences (`\n`, `\t`, `\r`, `\"`, `\\`) and rejects unknown escapes, but does not implement TOML's `\uXXXX` / `\UXXXXXXXX` Unicode escapes. Raw UTF-8 bytes pass through (the parser is byte-oriented), so values like `slug = "héllo"` would round-trip — but the writer would emit the bytes verbatim, not as escapes, which is fine for TOML. No test confirms this path. If non-ASCII content is unsupported, document it; if supported, add a fixture.
- **`isValidTransition` reflexive identity** — the guard `if (from == to) return false` is unanchored by any test; the in-file test "invalid transitions are every unlisted pair" does cover `(.queued, .queued)` etc. transitively, but a dedicated identity test would be cheap and make the intent explicit.

## Strengths

- **Arena ownership story is clean.** Every owned string in `Item` lives in a single arena owned by the Item itself; `Item.deinit` is one line. The toml `Document`'s arena is fully decoupled — its lifetime ends at `defer doc.deinit()` and no slice from it survives into the returned `Item`. No errdefer landmines, no aliasing across arenas.
- **Canonical key-order writer + fixture authoring contract.** The fact that fixtures are written in canonical order, and the second-pass test verifies fixed-point output, is the right invariant to enforce. It will keep diffs clean as the schema grows.
- **`isRfc3339` actually checks numeric ranges**, including a leap-year-aware February bound (`isRfc3339("2026-02-29T...")` rejects, `isRfc3339("2028-02-29T...")` accepts). That's better than most hand-rolled date validators.
- **Diagnostic structs (`ParseDiagnostic`, `ValidationDiagnostic`)** keep the error union narrow (the `error{...}` set is short) while still surfacing per-field context for tests. The pattern scales: every test asserts on `vd.field`, which is more durable than asserting on error variants alone.
- **`state.zig`'s exhaustive "every unlisted pair" test** is the right shape for a transition table: it builds a Cartesian product via `@typeInfo` reflection and asserts the rejection invariant, so any new `Status` variant added without updating `VALID_TRANSITIONS` automatically participates. The matching `kind = "..."` enum lacks an equivalent reflection test, but the state machine one is exemplary.
- **Forward-compat tolerance on unknown top-level keys and unknown table contents** (with the deliberate exception of `[sleep]` and `[clear]`, which are strict) is the right trade-off for a long-lived on-disk schema.
- **The fixture set actually covers every kind and every terminal status, plus `prompt_with_workdir` for the deferred allowlist path.** It matches the plan's step 6 acceptance criteria one-for-one.
