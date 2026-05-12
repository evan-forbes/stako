# Audit — Milestone 3: Daemon Skeleton

Baseline: bf6e8f3. Modules audited: `src/config.zig`, `src/local_token.zig`, `src/errors.zig`, `src/storage.zig`, `src/daemon.zig`. Tests audited: `test/daemon_tests.zig` (24 tests) plus in-file `test` blocks in each module (config 6, local_token 4, errors 4, storage 5, daemon 8).

Baseline confirmed: `zig build test --summary all` → 373/373 pass.

## Execution traces

**Trace A — clean daemon startup.** `daemon.start(allocator, opts)` calls `realpath` on `notes_root`, dupes it (`abs_owned`), then `config_mod.loadFromRoot` builds a `Config` (arena-backed) by reading `.organo/config.toml` then `.organo/config.local.toml` and overlaying. `local_token.ensureAndLoad` opens `.organo/local_token` if present, else generates a fresh 64-hex token with `std.crypto.random.bytes(&raw[32])` and writes it with `mode = 0o600`. Then `isLoopbackHost(opts.host)` is checked (after the token write). `std.net.Address.parseIp + addr.listen` binds the socket; the bound port is captured via `server.listen_address.in.getPort()`. If not ephemeral, `writePidFile` writes `pid\nport\nts\n` with mode `0o600` (refusing if existing pid is alive); `openLogFile` opens append-mode `daemon.log`. `storage.Reader.init` resolves notes_root again. `vcs.assertNoMergeConflicts` runs only if a real `.git` is present. `audit.Writer.init` is lazy. Then `mutation_queue.Queue.init` constructs the queue (with `undefined` audit_writer until startWorker). The Daemon struct is built and `logLine` writes a banner. Returns. `startWorker` then wires `queue.audit_writer = &self.audit_writer`, starts the worker thread, and emits the `daemon_started` audit event.

**Trace B — Bearer-auth on a mutation request.** `serveOne` accepts, calls `handleConnection` which sets up stack-allocated read/write 16K bufs, builds a `std.http.Server` over a `net_reader/net_writer`. `receiveHead` parses headers. `routeWithOwnership` calls `matchRoute` to classify; for non-SSE routes it forwards to `route`. `route` matches POST, promotes the route, checks `isMutationRoute`, then `verifyAuth`: iterates headers with `iterateHeaders()`, matches `authorization` case-insensitively, requires a `Bearer ` (case-insensitive ASCII-7) prefix followed by a token. `std.mem.trim` strips inner whitespace, then `token.verify` does an O(n) XOR fold *after* an O(1) length check. On success, `policy.resolveLocal(&self.config)` resolves the identity to `local` (or the synthetic full-access identity when `[identity.local]` is undeclared), `policy.evaluate` returns `.allow`, and the dispatch lands in the handler (`handleCreateStack`, `handleAppendItem`, ...). The handler reads the body (`readRequestBody`) under a 256 KiB cap, parses JSON, submits a `mutation_queue.Request`, blocks on `submitAndWait`, and responds via `respondMutationOk`/`respondMutationError`.

**Trace C — Malformed `config.local.toml`.** `loadFromRoot` opens the file, allocs `stat.size` bytes off the arena, `readAll`s, calls `applyLayer(arena, &cfg, bytes, .local)`. `applyLayer` invokes `toml.parse(arena, source) catch return error.Toml`. If the TOML fails (e.g. unterminated string), the function returns `error.Toml`, bubbled up through `start()` which returns the error without cleaning the PID file (see Blocking #2). If the TOML parses but `[daemon] port = "9000"` (string instead of integer), `applyDaemonField` short-circuits to `error.BadType`. No tests exercise either `error.Toml` or `error.BadType`.

**Trace D — `GET /stacks/does-not-exist`.** `matchRoute` returns `RouteMatch{ .route = .stack_get, .stack = "does-not-exist" }`. `route` sees `is_get`, dispatches to `respondStackGet`. `storage.isValidStackName("does-not-exist")` → true. `reader.readStackConfig("does-not-exist")` opens `<root>/stacks/does-not-exist/`, fails with `error.FileNotFound`, which the switch in `openStackDir` maps to `error.NotFound`. The catch block in `respondStackGet` calls `respondError(req, .not_found, "stack not found", &.{.{.key="stack", .value="does-not-exist"}})`. `errors.writeBody` emits `{"error":{"code":"not_found","message":"stack not found","details":{"stack":"does-not-exist"}}}` and `req.respond` writes the 404. Test "daemon: GET unknown stack returns 404 with canonical error body" anchors this.

## Blocking

- **Blocking** — `src/daemon.zig:787-829` (`verifyAuthFormBody`) — **memory leak on malformed form-body `_token`**. `const decoded = formUrlDecode(self.allocator, val) catch return null;` on line 819 returns `null` (not an error), so the `errdefer self.allocator.free(body)` on line 805 does *not* fire. The 256 KiB body buffer is leaked every time a browser-form POST arrives with an invalid `%XX` escape inside `_token`. The body is also leaked when an inner `try out.append(...)` inside `formUrlDecode` returns `OutOfMemory` (caught the same way). Replace `catch return null` with `catch { self.allocator.free(body); return null; }` or convert the function so the body is freed in one place. The leak is only triggered by a deliberately malformed request, but it is unbounded over the lifetime of the daemon and is exactly the kind of thing a browser misclick can hit.

- **Blocking** — `src/daemon.zig:316-324, 333-339, 342` — **PID file is leaked on every error path between `writePidFile` and `return`**. After `pid_written = try writePidFile(...)` on line 320, no `errdefer if (pid_written) removePidFile(...) catch {}` is registered. Subsequent failures in `storage.Reader.init` (327), `vcs.assertNoMergeConflicts` returning `error.HasMergeConflicts` (335), or `audit.Writer.init` (342) all return `error` while leaving `daemon.pid` on disk pointing at the still-alive `start()` caller's PID. The next `start()` then refuses with `error.AlreadyRunning` even though no daemon is actually running. Also, `Daemon.deinit` never removes the PID file even on a clean exit — the design says "daemon.pid behaves per the design doc across start/stop/restart", but only the `stop()` SIGTERM path calls `removePidFile`. A `Daemon.deinit` (in-process shutdown, ctrl-C handler) leaves the file behind. The `log_file` opened at line 323 has the same gap: it leaks on errors between line 323 and the `return d;`.

## Important

- **Important** — `src/daemon.zig:298-307` — **Token file generated even when the host is non-loopback.** `local_token.ensureAndLoad` runs on line 303; the loopback check is on line 307. A `start({ host = "0.0.0.0" })` that fails fast with `error.NotLoopbackHost` still wrote `.organo/local_token` if it was absent. Plan step 5 says the daemon should "refuse to bind on non-loopback addresses — explicit check, with a test" and acceptance criterion 5 ties to "fails fast with a clear error". A side effect on a fail-fast path is at minimum surprising. Move the loopback check to the top of `start()` (or at least before any disk write).

- **Important** — `src/daemon.zig:2162` — `std.os.linux.getpid()` is Linux-specific. macOS/BSD targets fail to compile. Use `std.posix.getpid()` or `std.c.getpid()`. The rest of the daemon uses `std.posix` consistently (e.g. `std.posix.kill`, `std.posix.shutdown`); this is the lone Linux-direct call.

- **Important** — `src/local_token.zig:34-58` — **No re-tightening of perms on existing token files.** When the file is already present, `ensureAndLoad` opens it for read and trusts the existing mode. If a user accidentally widened perms (e.g. `chmod 644 .organo/local_token`), the daemon does not re-`fchmod` to `0o600`. The init flow guarantees fresh tokens are written with 0600, but `init` is allowed to be skipped (per the docstring on line 11–13: "the daemon only generates the token if absent (e.g. when a user spins up the daemon against a directory that predates organo's init flow)") — exactly the case where the perms might be wrong. A one-line `std.posix.fchmod(f.handle, 0o600)` (after open) closes this. Also: no test asserts the generated file actually has mode 0o600.

- **Important** — `src/daemon.zig:148-191` (`Daemon.deinit`) — **no `daemon_stopped` audit event.** Design `todos/design_errors_and_audit.md` says daemon lifecycle events include `daemon_started` *and* `daemon_stopped`. `audit.Action` declares the enum variant (line 31 of audit.zig). `daemon_started` is emitted at the bottom of `startWorker`; nothing emits `daemon_stopped`. Add it as the first or last step in `deinit` (best-effort, same swallow-on-error pattern as the start emit).

- **Important** — `src/daemon.zig:608-618` — **POST/PUT/DELETE to non-mutation paths fall through inconsistently.** A POST to `/healthz` hits `promoteToMutation(.healthz)` which returns `.healthz` unchanged, then `isMutationRoute(.healthz)` is false, then the switch lands on `.healthz => respondOkText(...)`. So POST /healthz returns 200 "ok". Similarly POST /providers, POST /providers/{name}, POST /, POST /static/style.css all happily serve. The plan says "GET /healthz" — there's nothing in the routing surface that pins these to GET. Either pre-check method per route (`if (m.route == .healthz and !is_get) ...`) or invert the check to "GET-only routes reject POST". Conversely PUT/DELETE to ANY route hits `respondError(req, .validation_failed, "method not allowed", ...)` with status 400 — but `validation_failed → 400` is the wrong code for "method not allowed"; HTTP semantics call for 405. The `errors.Code` enum has no `method_not_allowed` slug.

- **Important** — coverage — `test/daemon_tests.zig` has **no test for `config.toml` parse failure or type mismatch**. `config.zig` returns `error.Toml` (line 111) and `error.BadType` (lines 157, 160, 163, 172, 202, 205, 208) on real malformed input but no fixture exercises them. The plan's audit-dimension 2 explicitly calls out "Malformed config files". A single test that writes `[daemon]\nport = "abc"\n` to `config.local.toml` and asserts `error.BadType` from `loadFromRoot` would close the gap.

- **Important** — coverage — **No test for port already in use.** Plan's audit dimension 2 calls out "Port binding errors". A test that opens a TCP listener on a port, then calls `daemon.start(.{ .port_override = that_port })` and asserts `error.AddressInUse` (or whatever Zig's stdlib surfaces) is missing.

- **Important** — coverage — **No test for concurrent requests.** `test/daemon_tests.zig` uses `serveOne` driven sequentially. The accept loop (`serveUntilShutdown`) is not exercised, nor is overlapping connections. With per-connection 32 KiB of stack (`read_buf` + `write_buf`), there is no fan-out test that exposes whether two clients can be served back-to-back without state bleed.

- **Important** — coverage — **No test for `daemon_mod.stop`.** The "PID file is written and removed across start/stop cycle" test manually calls `removePidFile` because `stop()` would SIGTERM the test process. A fork-and-stop test (or a test that spawns the installed binary, as `cli_tests.zig` does for `daemon start`) would close the gap. Right now `stop`'s timeout-and-SIGKILL path, its `ProcessNotFound → not_running` branch, and the grace-period polling loop are all uncovered.

## Minor

- **Minor** — `src/daemon.zig:437-441` — `read_buf` and `write_buf` are 16 KiB each on the stack of `handleConnection`. 32 KiB/connection is generous for loopback HTTP/1.1. If an SSE detach happens, the buffers vanish (they were used only by `receiveHead`); fine. If a future change spawns a thread per connection rather than serving inline, this is 32 KiB × N — flag for awareness but no action needed now.

- **Minor** — `src/daemon.zig:921-936` (`verifyAuth`) — the "Bearer " prefix is matched against an exact-length window (`value[0..prefix.len]`), so `"Bearer\tTOKEN"` (RFC-legal alternative whitespace) fails the prefix compare. RFC 7235 allows one-or-more SP/HTAB between the scheme and credentials. Tighten with `std.mem.indexOfAny(u8, value, " \t")` to find the scheme/credential boundary. Loopback-only daemon makes this practically a non-issue.

- **Minor** — `src/local_token.zig:22-28` — `Token.verify` early-returns on length mismatch *before* the constant-time XOR fold. The doc-comment claims "constant-time compare to avoid leaking the prefix length", which is technically still true once both inputs are the same length, but a stronger phrasing is "length-then-content compare; length is checked in cleartext". Pedantic — flagged because the comment slightly oversells the property.

- **Minor** — `src/daemon.zig:677-697` — the capability-slug renderer uses `std.fmt.bufPrint(&cap_buf, ...) catch "stack.?.?"`. On any error (which only happens if `cap_buf` is too small for the formatted slug), the user sees a literal `stack.?.?` in the response. Either size the buffer to fit the longest possible slug (stack-name max + verb-max ≈ 64 + 20 chars; current 256 is more than enough), or surface the error as a 500 — the silent placeholder is worse than either. Currently 256 bytes is fine for any realistic stack name; flagging for forward-compat.

- **Minor** — `src/daemon.zig:841` — `formUrlDecode` uses `i + 2 < s.len` which off-by-ones on `%XX` at the very tail. For len-3 input `"%FF"`, `i=0`, condition `0 + 2 < 3 = true` → OK. But for len-2 `"%F"` or len-4 `"a%FG"` at `i=2`, the condition `2 + 2 < 4 = false` silently falls into the else-branch and appends `%` literally instead of raising `error.InvalidEscape`. Forgiving by design, but the docstring says `%XX → byte`, not "or appended literally on malformed input". Consider `i + 2 <= s.len - 1` *and* explicit error on short tail.

- **Minor** — `src/config.zig:110` — `_ = layer;` parameter is unused. The function signature carries the `Layer` discriminant but does nothing with it. If the design has truly converged on "scalars last-write-wins, identity tables replace-wholesale, applied identically per layer", drop the parameter. If layer-specific logic is anticipated (e.g. "local can't redefine `loopback_only`"), wire it now.

- **Minor** — `src/storage.zig:60-74` — `openStacksDir` and `openStackDir` both `std.fs.path.join` and `openDirAbsolute`. They could share a `joinUnder` helper to avoid the two-line duplication. Trivial.

- **Minor** — `src/storage.zig:165-178` — `readItem` scans the directory linearly looking for `<id>-<slug>/`. For a stack with thousands of items, every read is O(n). Plan says "v1 only reads"; if item counts stay small this is fine. Cache opportunity flagged for future.

- **Minor** — `src/errors.zig:96-115` — `writeBody` accepts a flat `[]const DetailKV` and emits every value as a JSON-string-encoded value. A details object with a numeric value (`{"port": 7421}`) cannot be expressed correctly — it would emit `{"port":"7421"}` if the caller stringifies, with the wrong type for clients that parse strictly. No M3 endpoint hits this today, but the deferred "structured-value support can be added later" comment is the canonical TODO marker. Flagging.

- **Minor** — `src/errors.zig:73-84` — `httpStatus` returns `u16`, but `respondError` (daemon.zig:977) needs `std.http.Status` (a `u10`-backed enum). The cast `@enumFromInt(@as(u10, @intCast(code.httpStatus())))` is correct but visually noisy. Return `std.http.Status` from `httpStatus` directly to drop the cast pyramid. Trivial.

- **Minor** — `src/daemon.zig:1503-1515` (`readRequestBody`) — `body_reader_buf: [256]u8` is on the stack of the function; the reader holds a pointer to it during `allocRemaining`. Make sure the reader doesn't outlive the function (it doesn't — `allocRemaining` is synchronous). Comment-worthy but not buggy.

- **Minor** — `src/daemon.zig:367` — `logLine` is called via `d.logLine(...)` on a local variable just before `return d`. The format args are formatted to a 512-byte buffer and written via `f.writeAll(line) catch return`. This is fine; flagging that the `comptime fmt` parameter is unnecessary for the call site (only one call site, with a fixed format string). No action.

- **Minor** — `src/daemon.zig:2206-2212` (`isProcessAlive`) — Returns `true` for any kill-error other than `ProcessNotFound`. EPERM treats the PID as alive (correct); EINVAL would also treat as alive (incorrect, but EINVAL only fires for sig values out of range, and we always pass 0). Comment-worthy.

- **Minor** — `src/daemon.zig:2196-2202` (`stop`) — busy-poll with 100 ms sleep × `grace_seconds * 10` iterations. Works, but the `i64` `waited` overflow check is implicit (waited capped at `grace_seconds * 10`). For `grace_seconds = 5`, total wait is 50 × 100 ms = 5 s — matches design.

- **Minor** — `src/storage.zig:139-141` — `isValidId` / `isValidSlug` are used to *skip* malformed directories. A test that drops a `Bad-Dir-Name/` into a stack and verifies `listItems` ignores it (instead of failing or surfacing it) would lock in the policy. Currently no such test.

## Coverage gaps

- **Malformed `config.toml` / `config.local.toml`** — `error.Toml`, `error.BadType` (string-when-int expected, etc.), and the `loopback_only`-non-bool path are all unanchored. See Important.

- **Port already in use** — `start()` should surface this as a startable error (`error.AddressInUse`). No test. See Important.

- **`daemon_stopped` audit event** — design says it's emitted; nothing emits it; no test asserts it appears in the audit log on shutdown.

- **`daemon_mod.stop` end-to-end** — no test of `stop`'s SIGTERM-and-poll path, ProcessNotFound-after-pidfile-stale path, or grace-period timeout path. See Important.

- **PID file removed on clean deinit** — currently it isn't (Blocking #2). A test that asserts `daemon.pid` is absent after `Daemon.deinit` would have caught the missing cleanup.

- **Token file perms on disk** — no test asserts the generated `.organo/local_token` actually has mode `0o600`. The init-flow tests check it; the daemon-generation path does not.

- **Bearer-auth negative paths via HTTP** — `verifyAuth` returning false on missing header, wrong scheme ("Basic"), wrong token, and the form-body fallback are all logically tested in M5/M10 tests but not in `daemon_tests.zig` (M3 owns auth-plumbing per plan step 3 but only verifies via in-process `token.verify` call at line 423). The form-body auth path's `_token` malformed-escape (which triggers the Blocking #1 leak) is not anchored by any test.

- **POST to a GET-only path** — POST /healthz, POST /providers, etc. No test pins the HTTP surface against accidental method-promotion (see Important).

- **`Accept: text/html` content negotiation on read endpoints** — anchored by `html_tests.zig` (M9), but `daemon_tests.zig` doesn't include the M3-era assertion that absent-`Accept` defaults to JSON.

- **Concurrent requests** — see Important.

- **Empty `local_token` file** — `readToken` checks `stat.size == 0` and returns `BadShape`. Anchored by "ensureAndLoad: rejects short uppercase and overlong token files" (which doesn't actually cover empty, despite the name; the three contents tested are short-not-empty, mixed-case, and overlong). A truly empty file isn't tested.

## Strengths

- **Routing data structure is appropriate.** `matchRoute` is a hand-rolled prefix-match function — under a dozen endpoints, O(1) dispatch, no premature abstraction into a table-driven router. The `Route` enum with `promoteToMutation` cleanly separates GET-default routes from their POST counterparts. The choice (per `design_daemon.md`) to build on `std.http.Server` rather than vendor a framework pays off — the entire HTTP surface fits in one file and the abstractions are exactly the standard library ones.

- **Error responder is a real funnel.** Every endpoint goes through `respondError → errors.writeBody`. The slug-to-status mapping is a single `switch` (`errors.Code.httpStatus`) and the slug round-trip test (`Code: every code has a slug round-trip`) uses `@typeInfo` reflection — any new enum variant without a slug arm is a compile error. Exactly what the plan asked for.

- **Layered config with replace-not-merge identities is tested.** The "identity tables replace wholesale, not merge" test pins the design's specific semantics (`design_init_and_layout.md` line 118). The committed-vs-local layering is explicit and the per-layer accumulator in `applyLayer` is the right shape — scalar last-write-wins, identity table replacement.

- **Constant-time token compare.** `Token.verify` does the right thing (modulo the length-leak nit). The 64-hex shape constraint is strict (`isHexLike` rejects uppercase, non-hex, and wrong-length input) and the test set covers each of those negative cases.

- **Tear-down ordering in `Daemon.deinit` is documented and correct.** The four-step comment at lines 148-157 spells out why supervisor → queue → SSE threads → hub → audit → server is the right order. The supervisor is on the heap precisely because workers point back to it; the comment makes the alignment requirement explicit. The hub-ownership split (`sse_hub` as a borrow, `sse_hub_owned` as the owning pointer) is the right way to model "M6+ owns the hub, M3 doesn't have one".

- **Path-traversal defense at the storage layer.** `isValidStackName` rejects `.hidden`, `-leading`, `_leading`, trailing separators, double separators, and uppercase. `../bad` and `with space` are in the test set. The route handlers double-check via `storage.isValidStackName` before passing the name down. Combined with `openDirAbsolute(join(notes_root_abs, "stacks", stack))`, this is hardened against `?stack=../../etc`.

- **Connection-ownership flag pattern.** The `routeWithOwnership` indirection threads a `conn_owned: *bool` through to the SSE handler so the caller knows whether to close the stream. Cleaner than a `union(enum) { close, detach }` return because the standard read-path handlers stay simple.

- **`storage.Reader` parses `meta.toml` per-item only enough to populate `ItemSummary`** and frees the full Item immediately. The list operation doesn't hold every item parse in memory at once — relevant once item counts grow.

- **The `Connection: close` test harness pattern in `daemon_tests.zig`** plus the `serveOne` split lets every test drive exactly one HTTP exchange deterministically. No flakiness from races between `accept` and shutdown.
