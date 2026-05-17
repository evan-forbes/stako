# Milestone 9 Review

Diff range: fd9a4a4..558535f

## Blocking

- **Plan step 6 (browser mutation controls) is not implemented.** The plan
  text reads verbatim: "Browser mutation controls may be minimal:
  Pause/resume stack. Cancel running item. Retry blocked item. These POSTs
  must include the local mutation token; no ambient loopback POSTs." This
  asks for UI buttons that POST to the M5 endpoints with the local mutation
  token. No such forms/buttons are rendered on any page: searches for
  `<form`, `<button`, `cancel`, `retry`, `pause`, `resume` in `src/html.zig`
  and the four committed snapshots find nothing. The deferral comment ("the
  underlying mutation endpoints already exist from M5") misreads the plan —
  the M5 endpoints exist, but step 6 asks the *renderer* to surface controls
  that drive them. Together with step 7's "Mutation-token rejection test
  for browser POST helpers" (also absent), this is the bulk of acceptance
  criterion "Browser mutation POSTs are token-protected." There is nothing
  to be token-protected at the browser layer. Mark blocking; either
  implement minimal pause/resume/cancel/retry forms with a hidden token
  field (or `Authorization` header via fetch + a one-shot token-bootstrap
  meta) and a 401-on-missing-token test, or formally narrow the acceptance
  criterion in the plan and re-record the deferral.

## Non-blocking

- `/auth` page is intentionally deferred. The plan's step 3 explicitly
  enumerates only three pages (`/`, `/stacks/{name}`,
  `/stacks/{name}/items/{id}`); the design doc lists `/auth` as v1 but the
  M9 plan implementation doesn't. Accept the deferral *per the plan*, but
  note that the acceptance criterion "Browser can navigate all v1 pages"
  reads against the design table — `/auth` will need its own milestone
  before that line is honestly true. File a follow-up.
- `src/html.zig:158` — Title `bufPrint` falls back to `input.name` on
  overflow (256 bytes). Harmless in practice (stack names are validated to
  fit), but the fallback path skips the "stack: " prefix silently. Minor.
- `src/html.zig:359-394` — The inline SSE script writes the stack name and
  item id into JS string literals via `escape()`, which emits HTML entities
  (e.g. `&#39;`). Inside `<script>` the parser doesn't decode entities, so
  the JS string ends up containing the literal characters `&` `#` `3` `9`
  `;` — not the apostrophe the source data had. For the validated stack-
  name and item-id alphabets (`[a-z0-9_-]` and `[0-9]+`) neither character
  class needs escaping at all, so the bug is currently invisible. If the
  validation alphabet ever widens, the JS-string interpolation will silently
  mis-render. Consider a tiny JSON-encoder helper (`JSON.parse` on a
  data-attribute) instead of embedding strings inline.
- `src/html.zig:56-100` — `STYLE_CSS` is fixed content but
  `respondStyleCss` does not emit an `ETag` or `Last-Modified`. `Cache-
  Control: max-age=300` is fine for v1 but a refresh after a binary upgrade
  needs a hard reload. Minor.
- `todos/design_web_view.md` was not updated to record the "option 2:
  hand-written formatting" decision the plan asks for in step 2 ("Record
  the decision in `design_web_view.md`"). The doc already documents the
  recommended order, so the record is implicit, but the plan asks for an
  explicit note.
- `test/html_tests.zig:91-95` — Per-test temp roots use
  `std.time.nanoTimestamp()` as a uniqueness suffix; in parallel test
  runners two threads can collide. Today the html test step is single-
  process so this doesn't bite, but it's a brittle pattern relative to the
  `test/fixtures/notes_roots/` convention used elsewhere. Non-blocking.
- The committed `.expected` files have no trailing newline (single-line
  HTML documents). That's deliberate — byte-for-byte snapshot match — but
  any editor with "ensure newline at EOF" will churn them on save. Minor.

## Deferred-confirmed

- `/auth` page — accepted per plan step 3. Surface as a follow-up before
  promoting "v1 pages" in the design doc to "shipped".

## Acceptance criteria

- "Browser can navigate all v1 pages." — Partial. `/`, `/stacks/{name}`,
  `/stacks/{name}/items/{id}` render. `/auth` is missing (deferred per
  plan, but the design lists it as v1).
- "A running prompt item updates its status badge and transcript live
  without page reload." — Met by design. The SSE wiring at
  `src/daemon.zig:1053` enables the inline script when `sse_hub != null`
  and `it.status == .running`; the script patches `[data-status]` and
  appends `<li>` rows to `ul.transcript` via `textContent`. End-to-end SSE
  liveness is not directly snapshot-tested but the SSE machinery from M6
  is exercised separately and the script only does benign DOM patches.
- "Pages render usefully without JavaScript." — Met. Four snapshots are
  rendered with `enable_sse = false` and cover the full transcript +
  status + meta state.
- "The same routes return JSON when `Accept: application/json` is set." —
  Met. `test/html_tests.zig:382-396` confirms `/stacks/smoke` returns JSON
  with no `Accept` header, and the `acceptHeaderWantsHtml` table is
  exercised by the unit tests in `src/html.zig:475-494`.
- "Browser mutation POSTs are token-protected." — NOT MET. No browser
  mutation POST surface exists; see blocking issue above.

## Other notes

- `zig build test --summary all` passes 293/293 in ~0.7s wall time. Well
  under the 5-second budget.
- HTML escape coverage: every dynamic insertion in `src/html.zig`
  (stack names, slugs, item ids, kind/status enum strings, target fields,
  blocked/failed reasons, parent ids, prompt body, transcript ts/kind,
  transcript `data_json`, description, default_workdir, allowed_harnesses
  entries) runs through `escape()`. The escape helper covers `< > & " '`.
  All attribute values are double-quoted and the escape neuters single +
  double quotes alike, so attribute injection is closed. The committed
  prompt body in the smoke fixture deliberately contains `<em>...</em>`
  and the snapshot pins the output to `&lt;em&gt;` — verified at
  `test/fixtures/html/item_running.html:3` and asserted in
  `test/html_tests.zig:414-415`.
- Static asset path: `/static/style.css` is matched before `/stacks/...`
  in `matchRoute` and the two prefixes are disjoint. A stack literally
  named `static` would live at `/stacks/static`, not `/static/...`, so
  there is no collision.
- No `/home/...` paths leak into committed HTML. The `/tmp/stako-smoke-
  workdir` string visible in `stack.html` is a deterministic literal from
  the committed `stack.toml`, not a machine path.
- `.actual` snapshot artifacts are listed in `.gitignore`
  (`test/fixtures/html/*.actual`).
- The smoke stack fixture (`test/fixtures/stacks/smoke/`) matches what
  `impl/00_test_strategy.md` describes — `continuity = "chain"`,
  `allowed_harnesses = ["claude", "codex"]`, item 0001 with
  `provider = "anthropic"` `match = "exact"`, item 0002 with
  `match = "compatible"` and `parents = ["0001"]`.
- No changes to `src/storage.zig`, `src/item.zig`, `src/transcript.zig`,
  `src/events.zig`, `src/sse.zig`, `src/mutations.zig`,
  `src/mutation_queue.zig`, or `src/audit.zig`. M9 is correctly read-only
  on the server side.
- Test cleanup: `SmokeRoot.deinit` deletes its per-test subdir under
  `/tmp/stako-test-html`. The base dir is left empty between runs, which
  matches the pattern used by prior milestones.
