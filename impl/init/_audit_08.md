# Audit — Milestone 8: Provider Status and Gemini

Baseline: 7e617e0. Tests: 436/436 via `zig build test --summary all`.

Modules audited:
- `src/provider_status.zig` (348 LOC)
- `src/cli_auth.zig` (277 LOC)
- M8-relevant slices of `src/cli.zig` (parseAuthArgs, runAuth, AuthArgs/AuthAction, printAuthUsage)
- M8-relevant slices of `src/daemon.zig` (matchRoute for `/providers`, `respondProvidersList`, `respondProviderGet`)
- M8-relevant slice of `src/runtime.zig` (`providerStatus`, preflight at line 389-404, `status_cache`)
- `src/harness_dispatch.zig` (`harnessToProvider`, `factory` gemini-deferred branch)

M8 tests audited:
- `src/provider_status.zig` inline unit tests (lines 292-347): 6 tests
- `src/cli_auth.zig` inline unit tests (lines 254-276): 2 tests
- `src/cli.zig` parser tests (lines 1006-1051): 7 tests
- `test/cli_tests.zig` lines 582-670: 5 end-to-end tests (status, short alias, single provider, --json, signout)
- `test/daemon_tests.zig` lines 506-619: 6 tests on `/providers` endpoints
- `src/daemon.zig` line 2337-2345: `matchRoute` providers test
- `src/harness_dispatch.zig` lines 179-225: factory/provider mapping tests including "gemini deliberately deferred"

## Execution traces

**`stako auth status` happy path.** `main.zig` calls `cli.dispatch` → `runAuth` (cli.zig:513) → `parseAuthArgs` returns `{ action = .status }` → `cli_auth.run` (cli_auth.zig:12). Because action != .signout, the HTTP client opens (cli_auth.zig:22). `runStatus` GETs `/providers` (cli_auth.zig:46). The daemon's `respondProvidersList` (daemon.zig:1207) calls `provider_status.probeAll` (provider_status.zig:116), allocates a 3-element `Status` slice, probes anthropic/openai/google via `probe` which dispatches to `probeAnthropic`/`probeOpenai`/`probeGemini`. Each probe runs `binaryOnPath` (PATH scan + statFile, no subprocess), `envSet` on `$ANTHROPIC_API_KEY` / `$OPENAI_API_KEY`, and `homeFileExists` on `~/.claude/.credentials.json` / `~/.codex/auth.json`. JSON is serialized via `writeJsonList` (depth-aware string escaping at provider_status.zig:279) and returned. CLI's `renderList` then prints a header and one row per provider using `findJsonStringField`/`findJsonRawField` to peel fields out of the per-object slice.

**`stako auth anthropic` flow.** Parser hits the "provider shortcut" branch (cli.zig:462) since "anthropic" is not an `AuthAction` keyword. `runOne` (cli_auth.zig:62) builds path `/providers/anthropic` and GETs it. Daemon's `matchRoute` (daemon.zig:541-546) extracts the name and dispatches to `respondProviderGet` (daemon.zig:1220). `Provider.fromString("anthropic")` accepts both canonical slug and harness aliases ("claude"). The single-status response is rendered by `renderOne` (cli_auth.zig:199), which prints labeled lines for every field including `blocked_reason` (only when present).

**`stako auth signout` path (post-refactor).** Parser produces `{ action = .signout, provider_name = "..." }`. `cli_auth.run` (cli_auth.zig:18) short-circuits **before** `http_client.open`, calling `runSignout` directly. `runSignout` (cli_auth.zig:88) writes a stable "not supported in v1" message to stderr and returns exit code 1. The post-refactor early-return is correct: signout never touches the daemon, never opens a socket, and works even with a bogus `--root`. This is verified by `cli: auth signout always exits non-zero with helpful note` (cli_tests.zig:662) which passes `--root /path/that/does/not/exist` and still sees the "signout not supported" message rather than a config-load error.

**Gemini factory-returns-null behavior.** `probeGemini` (provider_status.zig:190) always returns `available=false`, `blocked_reason="harness_unavailable"`, regardless of binary presence. The `harness_dispatch.factory` (harness_dispatch.zig:69-82) falls through for the `gemini` harness and returns null. The supervisor's preflight (runtime.zig:374) treats null factory as `harness_unavailable`. When `enable_provider_preflight=true` (set in production via cli.zig:546), the per-provider preflight (runtime.zig:389-404) **also** blocks gemini via `status.available=false` → `harness_unavailable`. The two paths agree on the same canonical slug. `factory: gemini harness deliberately deferred (returns null)` test (harness_dispatch.zig:194) and `daemon: GET /providers/google marks gemini deferred` test (daemon_tests.zig:532) pin both halves.

## Provider abstraction

The "abstraction" is intentionally lightweight: a `Provider` enum with `slug`/`harnessName`/`binaryName` accessors, and a `Status` POD struct with eleven `[]const u8`/bool/enum fields. There is no vtable, no `interface`-style dispatch — the per-provider probe is three sibling functions inside one file. For 2.5 providers (Claude, Codex, deferred Gemini), this is the right call: a vtable would be ceremony.

Contract each provider satisfies:
- `binary_name`: the binary on PATH.
- `harness_name`: stako's internal label (`claude`/`codex`/`gemini`).
- `available`: true ↔ binary on PATH AND adapter wired.
- `auth`: best-effort from env var + `~/.config` credential files.
- `blocked_reason`: empty when available+signed_in, else one of `harness_unavailable`/`auth_missing`. Vocabulary matches `errors.Code`.
- `login_hint`: human command (no secrets).
- `credential_env`: the *name* of the env var stako sets when invoking the harness, never the value.

The shape is also consumed by routing preflight (runtime.zig:389-404), so adding a new provider needs four code touches: `Provider` enum entry, `probeFoo` sibling, `harnessToProvider` arm, and `harness_dispatch.factory` arm. That's load-bearing, not ceremony.

One minor gap relative to the plan's step 2: the plan asked for `auth_status()`, `credential_env()`, `capabilities()`, `login_hint()` *methods*. The implementation uses *fields* of `Status`. Equivalent ergonomics in Zig; arguably cleaner. The `capabilities()` part has no corresponding field — capabilities are handled by the `Adapter.supports(cap)` API on the live adapter (runtime.zig:378). Worth a doc-comment note.

## Real-credentials gating

Confirmed: real-credentials tests skip cleanly by default and run when set.

- Mechanism: `STAKO_WITH_REAL_CREDENTIALS` env var, parsed by `realCredentialsEnabled` (`test/adapter_tests.zig:788-798`). Accepts `1`, `all`, or comma-separated provider list (e.g. `anthropic,openai`).
- Default (env unset): tests print `[skipped: real-credentials gate (anthropic)]` / `(openai)` and return 0. Test output at run time: `Build Summary: 26/26 steps succeeded; 436/436 tests passed`, with two `[skipped:]` lines.
- Skipped tests: `real claude smoke @integration:provider:anthropic` (adapter_tests.zig:800-871) and `real codex smoke @integration:provider:openai` (adapter_tests.zig:873-end).

**Deviation from spec:** `impl/00_test_strategy.md` lines 75-87 calls for a `--with-real-credentials[=anthropic|openai]` *flag* parsed by `helpers/capability_flag.zig`. The actual implementation uses the `STAKO_WITH_REAL_CREDENTIALS` env var; there is no `test/helpers/capability_flag.zig` (only `test/helpers/fake_harness.zig` exists). Functionally equivalent; documentation-vs-implementation drift. Acknowledged in `build.zig:248`.

## Blocking

None.

## Important

**I1. `auth status` table header is printed before the body parse succeeds.** `renderList` (cli_auth.zig:163) prints the column header *first*, then attempts to find the `"providers":[` marker. If the marker is missing (cli_auth.zig:156), it falls back to `stdout.writeAll(body)` — so the user sees a column header *followed by* the raw daemon body, which is confusing. The fallback should also suppress the header, or the header should be printed only inside the success branch. Low impact in practice (the daemon always emits the marker) but the contract surface for "unexpected body" is muddled.

**I2. `--root` and other API flags on `auth signout` are silently ignored.** The parser accepts `--root`, `--port`, `--verbose`, `--json` for signout (cli.zig:425-453, the loop accepts the flags unconditionally before the switch on `out.action`), but `runSignout` ignores all of them. Tests confirm this is intentional (`cli: auth signout always exits non-zero with helpful note` passes a bogus root). Worth either documenting in `printAuthUsage` or rejecting the flags for `signout` at parse time. Minor UX surprise.

**I3. `--json` is also silently ignored on signout.** Same root cause as I2. The signout-stderr message is plain text; a scripted caller running `stako auth signout anthropic --json` will get exit 1 and no JSON. Either honor `--json` (emit a `{"error":"not_supported"}` JSON envelope) or reject at parse time.

## Minor

**M1. `findJsonStringField`/`findJsonRawField` return the *first* occurrence.** The CLI relies on flat JSON shape — there's no nesting in `/providers` responses today. If a future field carries a JSON-encoded sub-object (e.g. capabilities), these helpers would mis-parse. Tracked elsewhere in M7's audit (deferred Bash exit / depth-1 JSON helpers). Not exploitable now.

**M2. `provider_status.binaryOnPath` accepts any PATH segment including relative paths.** A relative entry like `./bin` would be resolved against the daemon's cwd, which could differ from the user's. Not a security issue but a minor surprise. The daemon's cwd is the notes root, so `./bin` would look there. Either skip non-absolute PATH entries or document the behavior.

**M3. `homeFileExists` requires `stat.size > 0`.** This is a deliberate "don't be fooled by an empty placeholder" heuristic but could miss a legitimate zero-byte credential file. Unlikely; documented behavior would help.

**M4. `Provider.fromString` accepts both the canonical slug and the harness alias** (e.g. `"claude"` → `.anthropic`). That's friendly, but the daemon's route alias means `GET /providers/claude` and `GET /providers/anthropic` are equivalent. The tests confirm `gemini` ↔ `google` aliasing works (daemon_tests.zig:550). Worth ensuring `note` text never confuses users about which canonical slug their auth state corresponds to. Current text is clear enough.

**M5. `probeGemini` ignores the `binary_present` flag for setting `auth`.** Even if `gemini` is on PATH and a `~/.config/gcloud/...` style credential file exists, `auth` stays `unknown`. This is correct per "deferred" policy but could be more explicit in the note.

**M6. `printAuthUsage` lists `--json` for signout but signout ignores it.** See I3. Documentation/implementation drift.

**M7. `renderRow` and `renderOne` truncate long values via `{s:<12}` etc.** The fixed-width format pads but does not truncate. Long notes will spill into the next column. Today's notes are short; consider an explicit width cap if notes grow.

**M8. Test seam: `probe` takes `allocator` but ignores it** (`provider_status.zig:128: _ = allocator;`). Future expansion (e.g. reading credential file contents) would need it, so keeping the signature is fine. Worth a doc comment.

**M9. `cli_auth.runSignout` has unused `stdout` parameter** (cli_auth.zig:93: `_ = stdout;`). Cosmetic.

**M10. Strings inside `Status` are static (program-lifetime) constants** — `probeAll` only allocates the *array of structs*, not the inner strings. The `_ = allocator` in `probe` confirms this. The `StatusList.deinit` correctly frees only the outer slice. No leaks observed. The doc-comment ("Strings are borrowed from constants (or owned by the caller's arena when produced via `probeAll`)") is slightly misleading — strings are *always* borrowed from constants in v1; arena ownership never happens. Worth tightening.

## Coverage gaps

**C1. No CLI test for `stako auth bogus-provider` (404 path).** The daemon test pins `GET /providers/bogus → 404` (daemon_tests.zig:589), but the CLI's `reportApiError` formatting for 404 isn't exercised on the auth subcommand. The stack-subcommand mirror is tested but the auth path could regress independently.

**C2. No CLI test for daemon-down on `auth status`.** The `reportClientError`'s `DaemonNotRunning, ConnectionRefused` branch is exercised by stack tests (cli_tests.zig:354) but not by auth tests. Coverage of a copy-pasted code path.

**C3. No CLI test for `auth status --verbose` printing URL on error.** The `--verbose` flag is parsed for auth but only consulted by `reportClientError`/`reportApiError` paths, which are auth-untested.

**C4. No test for `runtime.providerStatus` cache behavior.** The cache (`status_cache_mu` + `status_cache`) is populated lazily and never invalidated; the lock is taken every call. A test that hits `providerStatus(p)` twice and asserts the second call doesn't re-probe (e.g. by faking PATH between calls) would lock down the contract.

**C5. No test for the per-provider preflight blocking `auth_missing`.** runtime.zig:402 returns `.{ .blocked = "auth_missing" }` when `status.auth == .signed_out`. There's a test where `enable_provider_preflight=false`, but no test that exercises `signed_out` + preflight-enabled and asserts the canonical slug surfaces on the routed item. Without this, the slug could silently change.

**C6. No test for OOM on `provider_status.probeAll`.** The allocator failure path returns `error.OutOfMemory` → daemon's `respondProvidersList` (daemon.zig:1208) catches *any* error and responds 500. Smoke-fine.

**C7. No CLI test asserting credentials are not echoed.** A regression where the implementation accidentally prints `$ANTHROPIC_API_KEY` value (instead of the env var name) would not be caught by current tests. A test like "set ANTHROPIC_API_KEY=sk-test-fake-12345, run `stako auth status`, assert `sk-test` not in stdout/stderr" would lock down the security contract. (See "Strengths" — today the implementation does not read the value, but the regression is silent.)

**C8. No test for `GET /providers` JSON shape against a schema** — only substring `indexOf` checks. A serialization regression (e.g. forgetting to escape a quote in `note`) would slip past the current tests as long as the substring still matches.

**C9. No test for `Provider.fromString` accepting empty string** — falls through to `null`, which is correct but worth a one-liner.

## Strengths

**S1. Credential safety is excellent.** The implementation reads `getenv(NAME)` only to test `.len > 0` and never copies the value (provider_status.zig:230-232). The `credential_env` field surfaces only the *name* of the env var. The `note` text uses only static constants. The login_hint contains a `sk-ant-...` *example* placeholder string but never any user secret. Audit log entries never reference provider credentials. Zero leakage paths.

**S2. The post-refactor signout flow is correct.** Bypassing `http_client.open` for signout means the command works with no daemon, no notes root, no config — exactly the right ergonomics for a "we can't do this anyway" message. Verified by the `--root /path/that/does/not/exist` test (cli_tests.zig:665).

**S3. The "no subprocess for probes" choice is well-documented and well-aligned with the runtime.** The module's header (provider_status.zig:14-19) explains why naive `claude --version` probes would add latency on every tick. The `Supervisor.status_cache` (runtime.zig:90-108) further caches the already-cheap probe for the supervisor's lifetime. This is a deliberate, documented tradeoff that matches the design's "don't pay per-tick syscall cost" goal.

**S4. The Gemini deferral is consistent across three layers.** `probeGemini` returns `available=false` (provider_status.zig:195-209). `factory` returns null (harness_dispatch.zig:74-82). The runtime preflight blocks both via the same `harness_unavailable` slug (runtime.zig:374, 397). All three are pinned by tests. A routed gemini item lands in `blocked` with a stable, greppable reason.

**S5. Read-endpoint auth bypass for `/providers` is intentional and tested.** `daemon: GET /providers is a read endpoint (no auth required)` (daemon_tests.zig:605) confirms unauthenticated callers can list providers. This is correct: provider status is not sensitive information.

**S6. The CLI mirrors `cli_stack.zig`'s shape so error handling is uniform.** `reportClientError`, `reportApiError`, `findJsonStringField`, `findJsonRawField` are copy-paste mirrors of the stack module. Slight DRY hit, but the alternative (a shared cli_common.zig) would need to be added now without enough callers to justify it. KISS for the current scope.

**S7. The `Provider.fromString` aliasing (`"claude"` → `.anthropic`, `"gemini"` → `.google`) is consistent across CLI, daemon route, and runtime dispatch.** Tests pin all three layers.

**S8. The deferred-gemini decision is clearly distinct from "binary missing".** A user with `gemini` on PATH will still see `available=false` with the note "structured stream-json mode unconfirmed; adapter deferred", not a misleading "missing" message (provider_status.zig:203-206). Sharp diagnostic UX.
