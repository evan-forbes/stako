# Audit — Milestone 9: HTML Rendering

Baseline: 28ebf51. Modules audited: `src/html.zig`, plus the daemon glue
(`src/daemon.zig` HTML response paths and form-token auth). Tests audited:
`test/html_tests.zig`. Snapshot fixtures audited:
`test/fixtures/html/{index,stack,item_running,item_queued}.html`.

Baseline tests run locally: 447/447 passing (`zig build test --summary all`).

## Execution traces

### Rendering a stack with 0 items
- `renderStack` at `src/html.zig:161` is called with `input.items.len == 0`.
- Header: `writeHeader(w, "stack: <name>")` → `<title>` text escaped.
- Crumbs at line 170–172: stack name double-escaped (once on `/stacks/<name>` href, once on the trailing trail text).
- Config block at lines 186–213 emits paused/continuity/concurrency/running fields. Optional `description` / `default_workdir` / `allowed_harnesses` are escaped.
- Items block at line 217: takes the `<p><em>No items yet.</em></p>` branch. Footer follows.
- No allocation beyond the streaming `ArrayList` writer. No leaks possible — items slice is empty.

### Rendering with mixed item states (queued/running/blocked)
- `renderStack` enters the `<table>` branch at line 220.
- For each item: id, slug, kind, status are all funneled through `escape`. The status badge at line 233 (`writeStatusBadge`) escapes status into both the `class` attribute (`status-<x>`) AND the visible text. Because the status string lands inside the `class` attribute, malformed status text (which can't occur — `isValidStatus` gates it earlier in storage) would still be quote-safe via `&quot;` / `&#39;`.
- Same item row produces an anchor `<a href="/stacks/<name>/items/<id>">` where both `<name>` and `<id>` are escaped.
- No allocations are made inside the loop besides ArrayList growth.

### Rendering a stack with `paused = true`
- `renderStack` at line 192–194: branches to `<span class="badge status-paused">paused</span>` for the config-summary `paused` field. The literal "paused" is a static string — no escape required.
- When `local_token` is supplied (loopback path), `writeStackControls` at line 246 reads `paused` and emits `<form action="/stacks/<name>/resume">` with button "Resume stack". The form action constant is one of two static literals (`"pause"` / `"resume"`) selected by the boolean, so no dynamic action-path injection is possible.

### Mutation form submission round-trip (browser → daemon)
- Test `daemon: HTML stack page embeds working pause form` at `test/html_tests.zig:664` covers this end-to-end: GET the HTML stack page → scrape `_token` value from the rendered `<input>` → POST it back as `application/x-www-form-urlencoded` body → expect 200.
- Auth gate: `daemon.zig:680` checks `isMutationRoute`. If `verifyAuth` (header bearer) fails, `verifyAuthFormBody` at `daemon.zig:829` is called.
- Body parser scans for `_token=...`, percent-decodes the value (`formUrlDecode`), then `self.token.verify(decoded)` (constant-time compare in `local_token.zig:22`). On match the body is returned to the dispatcher; on miss the request is rejected with `identity_required`.
- `test/html_tests.zig:606` confirms the rejection path returns 401 with `code: identity_required`.
- `test/html_tests.zig:632` confirms the success path returns 200 with `ok: true`.

## XSS audit

Every dynamic value that reaches HTML is enumerated below. Format:
`file:line — value — escaped?`.

### `renderIndex` (src/html.zig:120)
- `src/html.zig:126` — title `"stako"` (static literal). Static, escape unnecessary but `writeHeader` runs `escape` anyway.
- `src/html.zig:135` — stack name into `href` attribute → `escape(w, name)`. **Escaped.**
- `src/html.zig:137` — stack name into anchor text → `escape(w, name)`. **Escaped.**

### `renderStack` (src/html.zig:161)
- `src/html.zig:168` — title contains `input.name` via `bufPrint`; passed to `writeHeader` which `escape`s it. **Escaped.** (Note: bufPrint fallback is `input.name` itself when the buffer is too small; still escaped.)
- `src/html.zig:171` — name in nav crumbs → `escape`. **Escaped.**
- `src/html.zig:174` — name in `<h1>` → `escape`. **Escaped.**
- `src/html.zig:182` — name into `writeStackControls` form action; the function at `src/html.zig:251` calls `escape(w, name)`. **Escaped.**
- `src/html.zig:182` — `token` into `value="..."` attribute; `writeStackControls` calls `escape(w, token)` at line 255. **Escaped.**
- `src/html.zig:189` — `config.description` (operator-controlled) → `escape`. **Escaped.**
- `src/html.zig:196` — `config.continuity.toString()` → enum-derived static string, but routed through `escape` anyway. **Escaped (defensively).**
- `src/html.zig:198` — `config.max_concurrent_per_stack` is `usize`; rendered with `{d}` — integer, no HTML metacharacters possible. **Safe (numeric).**
- `src/html.zig:199` — `running_count` — same as above. **Safe (numeric).**
- `src/html.zig:202` — `config.default_workdir` → `escape`. **Escaped.**
- `src/html.zig:209` — each `allowed_harnesses` element → `escape`. **Escaped.**
- `src/html.zig:223–232` — item id (href and text), slug, kind, status — all → `escape`. **Escaped** (4 sites per row).
- `src/html.zig:233` — item status into `writeStatusBadge` → escapes status in both class attribute and badge text (lines 295–298). **Escaped.**

### `writeStackControls` (src/html.zig:246)
- `src/html.zig:251` — stack name in form action → `escape`. **Escaped.**
- `src/html.zig:253` — `action_path` is one of two static literals `"pause"` / `"resume"` — never user-controlled. **Safe (static).**
- `src/html.zig:255` — `token` → `escape`. **Escaped.**
- `src/html.zig:257` — `button_label` is one of two static literals. **Safe (static).**

### `writeItemControls` (src/html.zig:265)
- `src/html.zig:275`, `src/html.zig:284` — stack name → `escape`. **Escaped.**
- `src/html.zig:277`, `src/html.zig:286` — item id → `escape`. **Escaped.**
- `src/html.zig:279`, `src/html.zig:288` — token → `escape`. **Escaped.**
- Form action path suffix (`/cancel`, `/retry`) is static. **Safe.**

### `writeStatusBadge` (src/html.zig:294)
- `src/html.zig:296` — status in class attribute → `escape`. **Escaped.**
- `src/html.zig:298` — status as text → `escape`. **Escaped.**

### `renderItem` (src/html.zig:322)
- `src/html.zig:329–333` — title via bufPrint of `stack` + `item.id`; fallback `input.item.id`. Passed to `writeHeader` → escaped. **Escaped.**
- `src/html.zig:336` — stack name in crumbs href → `escape`. **Escaped.**
- `src/html.zig:338` — stack name as crumbs anchor text → `escape`. **Escaped.**
- `src/html.zig:340` — item id in crumbs → `escape`. **Escaped.**
- `src/html.zig:343` — item id in `<h1>` → `escape`. **Escaped.**
- `src/html.zig:345` — item slug in `<h1>` → `escape`. **Escaped.**
- `src/html.zig:351` — `item.kind.toString()` (enum) → `escape`. **Escaped (defensively).**
- `src/html.zig:354` — `item.status.toString()` (enum) into `writeStatusBadge` → escaped in attribute and text.
- `src/html.zig:357` — `item.created_at` (RFC3339 text from TOML, validated upstream but treated as untrusted here) → `escape`. **Escaped.**
- `src/html.zig:360` — `item.updated_at` → `escape`. **Escaped.**
- `src/html.zig:367–371` — for each parent id: stack name in href → `escape`, parent id in href → `escape`, parent id as text → `escape`. **Escaped (3 sites/row).**
- `src/html.zig:381` — `target.provider` (user-controlled string) → `escape`. **Escaped.**
- `src/html.zig:387` — `target.model` → `escape`. **Escaped.**
- `src/html.zig:393` — `target.match.toString()` (enum) → `escape`. **Escaped.**
- `src/html.zig:399` — `target.workdir` → `escape`. **Escaped.**
- `src/html.zig:405` — `blocked_reason` (error message, possibly from harness) → `escape`. **Escaped.**
- `src/html.zig:409` — `failed_reason` (same source) → `escape`. **Escaped.**
- `src/html.zig:420` — `item.status.toString()` passed to `writeItemControls` (status compared against constants; never written to HTML by that helper beyond via the comparisons).
- `src/html.zig:426` — `prompt_body` (user-authored markdown, fully untrusted) inside `<pre>` → `escape`. **Escaped.** Snapshot test `daemon: GET /stacks/smoke/items/0001` at `test/html_tests.zig:398` explicitly asserts a `<em>` token in the prompt is rendered as `&lt;em&gt;`.
- `src/html.zig:448` — stack name embedded in inline JS `EventSource` URL string → `escape`. **Escaped.** (Note: emitted inside a `<script>` block, so escaping `<` and `&` here is necessary to prevent `</script>` injection; the renderer does it.)
- `src/html.zig:455` — `input.item.id` embedded as a JS string literal via `writeJsStringLiteral`. The helper at `src/html.zig:512` escapes `"`, `\`, `\n`, `\r`, `\t`, `<`, `>`, `&`, and any `< 0x20` byte. **Escaped — and `<`/`>`/`&` are converted to `\uXXXX` so even a `</script>` payload in the item id can't break out.**

### `renderTranscript` (src/html.zig:485)
- `src/html.zig:494` — `p.kind.toString()` (enum) → `escape`. **Escaped.**
- `src/html.zig:496` — `p.ts` (RFC3339 text from event line) → `escape`. **Escaped.**
- `src/html.zig:502` — `p.data_json` (the raw JSON object literal from transcript.jsonl; may carry assistant-text fields with anything in them) inside `<pre>` → `escape`. **Escaped.** Snapshot test verifies `&quot;` in the rendered output.

### Tally
- **Total dynamic values rendered to HTML/JS: 39** (see enumeration above).
- **Escaped: 39.**
- **Unescaped: 0.**

This is a Blocking-class concern by audit policy if any unescaped insertion is found. Zero found.

## Token handling

- The `_token` value is the daemon's `Daemon.token.bytes` (`src/daemon.zig:1313`, `:1398`), which `local_token.zig` produces as 64 lowercase hex characters by construction. **Hex by construction; nothing to escape, but the renderer still escapes every dynamic value as defense in depth** (`src/html.zig:255`, `:279`, `:288`).
- A snapshot test (`test/html_tests.zig:576`) deliberately feeds a hostile token value (`x"><script>alert(1)</script>`) and asserts no `<script>` survives in the output — confirming the defensive escape is exercised.
- The token is rendered **only** inside `<input type="hidden" name="_token" value="...">`. It is **never** placed in:
  - URLs (form `action` URLs are loopback paths without query strings).
  - Log output (no `std.log`/`std.debug.print` references to `token.bytes` anywhere in `src/`).
  - HTTP response headers or error bodies.
- The token reaches the page only when `local_token: ?[]const u8` is non-null on `StackPageInput` / `ItemPageInput`. The daemon currently always passes it for HTML responses (`daemon.zig:1313`, `:1398`); the comment notes the loopback-only invariant. The daemon's listen socket is loopback (`isLoopbackHost` gate verified in milestone 10 audit territory).
- Constant-time verify on the receive side (`local_token.zig:22`).
- The form path accepts URL-encoded `%XX` and `+→space` (defensive, `daemon.zig:878`), even though the canonical rendered token is plain hex. No leak risk; the decoded value goes only into `Token.verify`.

**Token handling: clean.**

## Snapshot test mechanism

- Snapshot helper: `assertSnapshot` at `test/html_tests.zig:35`.
- Behavior per call:
  1. `makePath(EXPECTED_DIR)` — `test/fixtures/html/`.
  2. **Always** write `<name>.actual` next to the expected file so a failure leaves a diffable artifact (`test/html_tests.zig:46`).
  3. If `STAKO_UPDATE_HTML_SNAPSHOTS` env var is set and non-empty / non-`"0"`, overwrite `<name>` and return (regeneration mode).
  4. Otherwise read `<name>` and `expectEqualStrings` (byte-equality). On miss, prints the paths and returns `error.SnapshotMismatch`.
- `.actual` files persist after the test run by design (so the dev can diff them).
- **`.gitignore` covers them**: `.gitignore` line 5 is `test/fixtures/html/*.actual`. Verified `git status` would not see them.
- Currently `test/fixtures/html/` contains both `.html` (committed) and `.html.actual` (gitignored) for the 4 snapshots. The snapshot files are tiny (≤1.5 KB each) and one-line-per-page; structure is sane.
- The `.expected`/`.actual` pair convention is a well-known idiom and matches the snapshot-tests row in the test-strategy table (`impl/00_test_strategy.md:115`).

**One minor note**: the snapshot mismatch path uses `std.debug.print` (correct for diagnostics) and `return error.SnapshotMismatch`, which is fine. The helper does not attempt to print a diff itself — relies on the dev running `diff <expected> <actual>` after the test fails. That is acceptable for the file sizes involved (≤1.5 KB) and matches the comment style.

## Form state gating

- **Pause toggles on `config.paused`**: `src/html.zig:248–249`. `action_path` is `"resume"` when paused, `"pause"` otherwise; same for `button_label`. Exactly one button surfaces per page. Test coverage: `test/html_tests.zig:467` confirms the running stack renders the pause-form and no resume-form is present.
- **Cancel only for queued/paused/blocked**: `src/html.zig:266–268` (`show_cancel = status == "queued" or "paused" or "blocked"`). Test coverage: `test/html_tests.zig:523` (queued → cancel form rendered), `test/html_tests.zig:550` (running → no `<form>` at all).
- **Retry only for blocked**: `src/html.zig:269` (`show_retry = status == "blocked"`). No direct unit test for the blocked state, but the truth-table is documented in the test at `test/html_tests.zig:550` and aligned with the `mutations.applyTransition` contract.

Truth-table alignment with `mutations.applyTransition`: the source comment explicitly cross-references that file (`src/html.zig:264`). Spot-check: the plan text in `impl/09_html_rendering.md:30` says "Cancel running item", but mutations rejects cancel-from-running; the test at `test/html_tests.zig:550` calls out this deliberate divergence. **Plan-text vs implementation divergence is documented and the implementation is consistent with the mutation layer's truth table.**

**Gating: correct.**

## Blocking

_None._ The original M9 reviewer's concern about missing mutation forms is resolved by commit `c7992ef`; XSS escaping is consistent across every dynamic insertion.

## Important

1. **`renderTranscript` skips malformed lines silently** (`src/html.zig:492`).
   When `events.parseEvent` returns null (invalid kind, malformed JSON, partial line), the line is dropped and `count` is not incremented. If a transcript happens to contain only malformed lines, the user sees "No events recorded.", which is misleading — actual events exist on disk but none are parseable.
   - File:line: `src/html.zig:492`.
   - Suggested fix: emit a single trailing `<li><em>(N unparseable lines skipped)</em></li>` when the skipped count is non-zero, or distinguish "no lines at all" from "lines present but unparseable". Low-cost change.
   - Severity: Important (not Blocking — no security implication, but obscures a real diagnostic surface).

2. **CSP `script-src 'unsafe-inline'` is necessary today; document the precondition for removing it**
   (`src/daemon.zig:1241`).
   The inline SSE bootstrap at `src/html.zig:443–477` needs `'unsafe-inline'`. The CSP is *otherwise* tight (`default-src 'none'`, `form-action 'self'`, `base-uri 'none'`). This is the right trade-off for v1, but the constraint is invisible — a future contributor adding a sha256 hash or nonce wouldn't realize the cost is having to coordinate the hash with every renderItem call. A one-line comment in `respondHtml` noting why `'unsafe-inline'` is currently load-bearing (and how to move to nonces if desired) would lock in the rationale.
   - File:line: `src/daemon.zig:1241`.
   - Severity: Important (documentation; defense-in-depth posture clarity).

3. **`enable_sse` gate ignores non-`running` items that may still receive events**
   (`src/daemon.zig:1385`). `enable_sse = self.sse_hub != null and it.status == .running`. But an item can transition from `running` → `completed`/`failed` while the user has the page open — the page won't subscribe at all if it loaded post-terminal, but for `queued`/`blocked` items it also won't subscribe, even though the SSE stream emits `item_status` events for those. Status-change events to a queued item (e.g. queued → running) would update other clients but not this one until reload.
   - File:line: `src/daemon.zig:1385`.
   - Suggested fix: subscribe for any non-terminal status (`queued`, `running`, `paused`, `blocked`), not just `running`.
   - Severity: Important (user-visible UX gap; not security).

## Minor

1. **`isMutationRoute`-style truth table is duplicated between `html.zig` and `mutations.zig`**.
   `writeItemControls` hard-codes "queued"/"paused"/"blocked" status strings via `std.mem.eql` (`src/html.zig:266–269`). The source-of-truth for what cancel/retry will accept lives in `mutations.applyTransition`. If the mutation layer ever opens cancel for `running` (or closes it for `paused`), the rendered controls drift silently.
   - File:line: `src/html.zig:266`.
   - Suggested fix: expose `mutations.canCancel(status)` / `mutations.canRetry(status)` predicates and call them from the HTML renderer. Mild DRY win; alignment becomes test-enforced.

2. **Title `bufPrint` fallback hides a tiny structural drift** (`src/html.zig:168`, `:329`).
   When `bufPrint` fails (slug+id+stack > 256 bytes for the item, > 247 bytes for the stack), the title silently becomes just the unprefixed name. Both fall through to `writeHeader → escape`, so safety is preserved, but the title-fallback is a quiet UX regression. A `catch unreachable` or assert (stack names are storage-name-validated and < 64 chars; ids are 4 digits; slugs validated short) would be reasonable. Low impact.

3. **Helpers `writeStackControls` / `writeItemControls` mirror each other but aren't unified**.
   Both emit `<form method="POST" action="/stacks/.../[suffix]"><input type="hidden" name="_token" value="..."><button>...</button></form>`. A single `writeMutationForm(w, action, token, label)` would shave ~25 lines and one duplicate `escape` call per form. Mild DRY note; current readability is fine.

4. **CSS is one long Zig multi-line string literal** (`src/html.zig:56–104`).
   For v1 hand-written stylesheet this is the right call. Future iteration could move it to a `.css` file embedded via `@embedFile`, which would let `:hover`/`@media` blocks live in a real CSS editor. Not a defect, just a tomorrow-marker.

5. **`writeFooter` literal `"stako daemon"` is escaping-safe but inconsistent with `writeHeader`'s escaping discipline**.
   The string is a static literal, so escape isn't needed; calling it out only because every other dynamic site here is escaped through the helper. Pure consistency note.

6. **`acceptHeaderWantsHtml` uses `parseQThousand` returning `u16` 0..1000 stored as `q`**. The bias `if (s[0] == '0')` followed by digit-scan handles `0`, `0.x`, `0.xx`, `0.xxx` but the test case `q=0.500` parses to exactly 500. Looks correct; coverage at lines 667–671 in html.zig matches. Not a finding.

7. **`renderTranscript` references `@import("events.zig")` inside the function body** (`src/html.zig:486`). Lazy import is unusual style here — other modules import at file top. Cosmetic.

## Coverage gaps

1. **No snapshot test for a `paused = true` stack page**. The pause/resume gating logic at `src/html.zig:248` swaps between two action paths; the snapshot only covers the `paused = false` branch (via the committed smoke fixture). A second snapshot fixture for a paused stack (the test-strategy doc references `stacks/paused/` already) would lock in the resume-form rendering.

2. **No snapshot test for a blocked-status item**. `writeItemControls`'s retry branch (`src/html.zig:282`) is exercised structurally by the `show_retry` boolean but the rendered output isn't snapshotted. A fixture item with `status = blocked` and a non-null `blocked_reason` would cover both the controls block and the meta KV row at `src/html.zig:403`.

3. **No snapshot test that includes `enable_sse = true`**. The inline `<script>` block emits `~25 lines` of static JS plus two dynamic insertions (`stack` name and `item.id`). Currently only the renderItem function-body covers it; a snapshot would catch accidental edits to the SSE bootstrap.

4. **No HTML test covers an item with a hostile prompt body or hostile slug end-to-end through the daemon**. There's `escape: hostile item slug never breaks out` (`src/html.zig:692`) for the escaper unit, and the smoke fixture's prompt contains an `<em>` token for the e2e path, but a fixture item with a slug/id containing `<>"'&` plus a daemon GET round-trip would be the most defensive test.

5. **No test for the `parents` rendering branch with multi-parent items**. The loop at `src/html.zig:364–375` would render comma-joined anchor lists; only the smoke item 0002 with a single parent is exercised.

6. **No assertion that `.actual` files are removed/cleaned up between runs**. They're regenerated on every run (truncate-create) and gitignored, so no leak. A doc-comment in `assertSnapshot` that this is intentional would help.

7. **No test for the CSP header on the `/stacks/<name>` and item HTML routes**. Only `/` is tested at `test/html_tests.zig:420`. The CSP is set by a shared helper (`respondHtml`), so the coverage gap is theoretical — but if someone routes a future HTML response without going through `respondHtml`, the test won't catch it.

8. **Index page with many stacks**. The current snapshot is one stack. No regression test for the `<ul>` rendering with many entries (the unit test at `test/html_tests.zig:682` covers the link shape but isn't a snapshot).

## Strengths

1. **Single chokepoint for HTML escape**: the module's module-doc (`src/html.zig:14–16`) explicitly forbids `writeRaw` for dynamic data, and every dynamic insertion routes through `escape`. The discipline holds across all 39 dynamic sites I enumerated. The convention is enforceable by grep.

2. **JS-context separation**: the inline SSE script's dynamic item id uses `writeJsStringLiteral` (`src/html.zig:512`), which escapes `<`, `>`, `&` as `<`/`>`/`&`. This prevents `</script>` injection even if an item id sneaked past validation — a level of defense most server-renders skip.

3. **Defense-in-depth on the token**: the token is hex-by-construction, but the renderer escapes it anyway. The hostile-token unit test at `test/html_tests.zig:576` ensures the discipline can't regress.

4. **Token-rejection symmetry**: the daemon-level tests at `test/html_tests.zig:606` and `:632` form a true positive/negative pair on the form-token auth path. Plus the round-trip test at `:664` confirms what's rendered is exactly what verifies — no escaping drift.

5. **Snapshot mechanism is unambiguous**: writes `.actual` regardless of pass/fail, supports `STAKO_UPDATE_HTML_SNAPSHOTS=1` for regen, gitignored. Easy to live with.

6. **Truth-table alignment with mutation layer is explicit**: `src/html.zig:264` cross-references `mutations.applyTransition`, and the diverging-from-plan case (no cancel for running) is called out in a test comment (`test/html_tests.zig:550`). The "why we ignore the plan here" decision is fossilized in code, not just memory.

7. **Plain HTML forms**: the controls work with JS disabled (the SSE updates are the only JS), per plan acceptance criterion 3. The form method is `POST`, the action is a URL the daemon already routes, and the token goes in a hidden field — completely vanilla.

8. **Content-Security-Policy is set on every HTML response** with `default-src 'none'`, `form-action 'self'`, `base-uri 'none'`. The only relaxation is `'unsafe-inline'` for the SSE bootstrap. Tight by default.

9. **Streaming writer interface**: `renderIndex`/`renderStack`/`renderItem` all take an `*std.ArrayList(u8)` and write into it with no intermediate allocations besides ArrayList growth. The page renders are O(input size) memory.

10. **`Accept`-header negotiation is comprehensive**: `q=` weights are honored, case-insensitive matching, missing-header defaults to JSON for programmatic clients. The unit tests at `src/html.zig:641–671` cover the corners.
