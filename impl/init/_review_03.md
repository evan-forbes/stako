# Milestone 3 Review

Diff range: 801d452..46ac594

## Blocking

(none)

## Non-blocking

- `src/daemon.zig:142` — `pid_written = try writePidFile(...)` has no matching `errdefer removePidFile(...)`. If `openLogFile` later returns a non-recoverable error, or if `storage.Reader.init` at line 149 fails (e.g. OOM in `allocator.dupe`), the PID file is left on disk and the next start refuses with `AlreadyRunning` until manually cleaned up. Same goes for `log_file` opened at line 145: no `errdefer f.close()`, so subsequent failures leak the file handle.
- `src/local_token.zig:16` and `src/daemon.zig:38-42` — `TokenError = anyerror` and `StartError = ... || anyerror` widen the error set to the universe. Tests have to spell every concrete error they expect (e.g. `error.BadShape`, `error.AlreadyRunning`, `error.NotLoopbackHost`) and callers cannot exhaustively switch. Closing these sets would also surface bugs at compile time. Defensible because the surface is small in milestone 3, but worth tightening before milestone 5 starts checking the token on mutations.
- `src/daemon.zig:333` — `@enumFromInt(@as(u10, @intCast(code.httpStatus())))` is a four-cast tower around a u16→u10 narrowing. Since `httpStatus()` returns only documented values (400/401/403/404/409/422/500/503), all fit in u10, but the idiomatic Zig fix is to have `errors.Code.httpStatus()` return `std.http.Status` directly and drop the cast. Also avoids a debug panic if a future code maps to ≥ 1024.
- `src/daemon.zig:145` — `daemon.log` open failure is silently swallowed (`openLogFile(...) catch null`). Defensible per the design (log is best-effort, mode 0600, append). Worth a stderr warning so users discover permission issues without scraping the source. Optional.
- `src/daemon.zig:130` — production callers can pass `--port 0` via the CLI (`parseDaemonArgs` accepts any u16). The plan calls out `port_override = 0` as test-only; the test path uses `ephemeral = true` to skip the PID file, but a foreground daemon with `--port 0` would still write a real PID file with whatever ephemeral port the kernel picked. Not harmful, just surprising. Either document or reject `--port 0` outside of `ephemeral` mode.
- `src/daemon.zig:688` — `std.os.linux.getpid()` ties the daemon to Linux, while the rest of the file uses portable `std.posix.kill`, etc. The codebase otherwise has `if (@import("builtin").os.tag == .windows) return;` guards (signal handlers, chmod). If non-Linux is in scope, use `std.posix.getpid()`. If Linux-only is fine for v1, add a compile-time `comptime { if (...) @compileError(...) }` or comment.
- `src/daemon.zig:660-691` — `writePidFile` has a read-then-write TOCTOU window: two daemons started concurrently can both see no live PID, both write the file, and the second clobbers the first. v1 use is local single-user, so not exploitable, but a `createFile(.exclusive = true)` retry would close the window without much effort.
- `src/daemon.zig:228` — `writeRawError` writes a malformed status line: `HTTP/1.1 {d} error\r\n...` uses the literal reason phrase "error" for every status, which is harmless but odd. Use `req.respond` with `.status` instead so the stdlib emits a proper phrase. Only fires on `receiveHead` failure (bad client framing) so rarely hit.
- `src/daemon.zig:288` — read paths return `validation_failed` (400) for non-GET methods. Per the design table, HTTP 405 ("method not allowed") is normally what's expected here; the error vocabulary just doesn't have a slug for it yet. Since milestone 5 will replace this with real mutation handlers, mostly harmless, but worth a `// TODO milestone 5` comment.
- `src/local_token.zig:51` — `createFile(.mode = 0o600)` on Linux honors the mode bit, but if the parent dir was created by `makePath` it inherits the user's umask. The design doc requires the directory `.stako/credentials/` to be `0700`; `.stako/` itself isn't specified, but the local_token sits there. The token file mode is right; just confirm nothing else relies on `.stako/` being 0700.
- `src/daemon.zig:96-105` — `requestShutdown` calls `std.posix.shutdown(handle, .both)` to wake a blocked accept. Combined with the signal handler in `cli.zig`, this is the right pattern, but the handler runs on whatever thread caught the signal; `Daemon.server.stream.handle` is read without synchronization. In practice the handle word is small enough for a torn read to be impossible on aligned u32/i32, but the comment doesn't explain why this is safe. Worth a one-line comment.
- `src/daemon.zig:42` — `StartError = error{...} || anyerror`. The named error set is shadowed by `anyerror`, so the enumeration is purely cosmetic. Either drop the named errors or drop `anyerror`.

## Deferred-confirmed

- Mutation endpoints (POST /stacks, POST /items, etc.) — out of scope per plan ("Mutation endpoints with version-control writes" is milestone 5).
- SSE — out of scope per plan ("No SSE yet").
- HTML responses — out of scope per plan (milestone 9).
- Per-identity authorization on read endpoints — out of scope per plan ("for now every read is allowed"). The token loader exists and the verifier is implemented (constant-time), as required.
- Audit log writes — design doc says "Synchronous in v1" wired into mutations / dispatch; nothing in milestone 3 generates audit events (read calls are explicitly not logged per the design).
- `stako daemon stop` mid-execution semantics (SIGINT → grace → SIGTERM to children) — design says this lands with the harness layer in milestone 6; milestone 3 daemon has no children to clean up.
- Background-fork mode — `DaemonArgs.foreground = true` is hardcoded; the plan didn't require backgrounding, so foreground-only is fine.

## Acceptance criteria

- **Daemon starts on a clean init'd directory and serves `/healthz`** — MET. `test "daemon: /healthz returns 200 ok"` constructs an init'd scratch root and checks for `ok\n`.
- **All read endpoints return well-formed JSON for fixture data** — MET. `daemon_tests.zig` exercises `/stacks`, `/stacks/{name}`, `/stacks/{name}/config`, `/stacks/{name}/items`, `/stacks/{name}/items/{id}` with substring assertions on the JSON body; storage.zig reuses `item.zig` and `stack_config.zig` parsers.
- **`config.local.toml` value overrides `config.toml` value; `[identity.<name>]` is replaced wholesale** — MET. `config.zig` tests cover both: `loadFromRoot: layered with config.toml + config.local.toml` (port override) and `loadFromRoot: identity tables replace wholesale, not merge` (no field merging, non-shadowed identity survives).
- **`.stako/local_token` exists with perms 0600, is stable across restarts, validatable for future mutation requests** — MET. `init.zig` writes the token with `posix_mode = 0o600`; `local_token.zig` ensures the file isn't rewritten on re-load; `Token.verify` does constant-time comparison. `daemon: token is generated/loaded on start and verifies` covers the daemon-side load.
- **`GET /stacks/does-not-exist` returns canonical error body with `code = "not_found"` and HTTP 404** — MET. `daemon: GET unknown stack returns 404 with canonical error body` asserts both status and the `"code":"not_found"` plus `"details":{"stack":"does-not-exist"}` shape.
- **`daemon.pid` and `daemon.log` behave per the design across start/stop/restart** — MET. Tests cover PID write+remove cycle and `AlreadyRunning` when the recorded pid is the running test process; `daemon: daemon.log is created on non-ephemeral start` verifies the log file exists and is non-empty.
- **Attempt to bind a non-loopback host fails fast with a clear error using the same error body shape** — MET (with one caveat). `start` returns `error.NotLoopbackHost` before reaching `addr.listen`. The "same error body shape" applies to HTTP responses only — there's no HTTP body for a fail-to-bind because the daemon never bound. The plan's intent (refuse non-loopback) is satisfied; the error-body language is irrelevant pre-bind.

## Plan steps 1–13

1. **HTTP framework decision recorded** — MET. `todos/design_daemon.md` gained a "Resolved (was: To Decide)" entry pointing to `std.http.Server` + hand-written router.
2. **Config loader: layer `config.toml` then `config.local.toml`, identities replaced wholesale** — MET (`src/config.zig`).
3. **Local request token (generate, 0600, verifier for future mutations)** — MET (`src/local_token.zig`, `init.zig` writes during `init`).
4. **HTTP error responder helper with compile-time slug→status map** — MET (`src/errors.zig`, `Code.httpStatus()` is a `switch` the compiler exhaustively checks).
5. **`stako daemon start` (bind, write PID, redirect logs, refuse running)** — MET (`src/cli.zig` `runDaemon` + `src/daemon.zig` `start`/`writePidFile`/`openLogFile`).
6. **`stako daemon stop` (SIGTERM, wait, remove PID)** — MET (`daemon.zig` `stop`).
7. **`stako daemon status`** — MET (`cli.zig` reports running/stopped + pid/port/uptime).
8. **`GET /healthz` plain text "ok"** — MET (`respondOkText("ok\n")`).
9. **Storage reader (list stacks under `<notes-root>/stacks/`, items, single item) reusing item/stack-config parsers** — MET (`src/storage.zig` calls `item_mod.parseSlice` and `stack_config.parseSlice`, no re-parse).
10. **JSON read endpoints (`/stacks`, `/stacks/{name}`, `/stacks/{name}/config`, `/stacks/{name}/items`, `/stacks/{name}/items/{id}`)** — MET (handlers in `daemon.zig`).
11. **Error responder wired into read path: `not_found` for unknown, `validation_failed` for malformed path params** — MET.
12. **Fixtures: tests start daemon against a temp notes root with milestone-1 fixtures** — MET via `Scratch` + `initNotesRoot` + `seedDemoStack`. Strictly speaking it constructs an equivalent stack inline rather than copying `test/fixtures/items/...`, but the schema matches milestone-1 and reuses milestone-1's parsers. Could be tightened to read from `test/fixtures/` directly for snapshot-style assertions.
13. **Refuse non-loopback binds with a test** — MET (`daemon: rejects non-loopback host fast` + `start: rejects non-loopback host` in daemon.zig).
