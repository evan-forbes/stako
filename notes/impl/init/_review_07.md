# Milestone 7 Review

Diff range: 2259238..6f9af37

## Blocking

- `src/session_manager.zig:526-533` — `onExitMain` builds the terminal `RuntimeTransitionInput` with only `failed_reason` / `canceled_by`; it never extracts the adapter's captured `session_id`/`session_file`/`model`/`harness`/`exit_code` from the `session_ended` event into `result_session_id` / `result_session_file` / `result_harness` / `result_model` / `result_exit_code` / `result_transcript_path` / `result_completed_at`. The mutation queue and `mutations.applyRuntimeTransition` both already accept these fields (`src/mutation_queue.zig:60-66`, `src/mutations.zig:509-567`), so the entire `[result]` block remains empty on Claude/Codex completion. This violates plan steps 2 and 3 ("Capture Claude session ID and native session file path into terminal `[result]` when available", same for Codex) and plan acceptance "Claude and Codex runs both produce terminal `[result]` metadata."

- `test/adapter_tests.zig` — none of the M7 end-to-end tests assert anything about `meta.toml`'s `[result]` block (e.g. `session_id = "sess-claude-real"` or `harness = "claude"` under `[result]`). The transcript contains the session id, but the persistent terminal metadata in `meta.toml` is what the plan acceptance requires. The tests therefore cannot detect the gap above and effectively under-cover plan step 7's fourth bullet ("Claude and Codex runs both produce terminal `[result]` metadata").

## Non-blocking

- `src/runtime.zig:330-332` — the harness-availability probe creates and immediately destroys a real adapter via the factory just to check return-non-null. For `claude`/`codex`/`fake` this is cheap, but it allocates a `State` per tick per queued item; consider a lighter `factory.supports(name)` predicate or memoize on the supervisor.

- `src/harness_dispatch.zig:65-87` — `buildArgv` returns a `/usr/bin/true` argv for unknown harnesses. Preflight should already have blocked this case, so the dead fallback hides bugs. Returning `error.UnknownHarness` would surface a misroute as `spawn_failed` rather than a silent zero-event run.

- `src/claude_adapter.zig` and `src/codex_adapter.zig` — the JSON micro-parsers are duplicated almost verbatim (~140 lines each). Codex notes this explicitly ("duplicated from claude_adapter to keep each adapter self-contained"). With Gemini coming in M8, a small shared `json_scan.zig` is overdue.

- `src/claude_adapter.zig:436-443` — `Edit` always maps to `"modify"` and `Write` to `"create"`; an `Edit` that creates a new file is rare but possible. Not a blocker for v1.

- `src/claude_adapter.zig:441-442` — `emitCommandExecuted` always reports `exit:0` for `Bash` tool_use because the actual exit comes back later as a `tool_result`. The downstream consumer cannot trust this `exit` field. Document or remove.

- `src/codex_adapter.zig:207-211` — `argbuf` for the command_execution tool_call arg object uses separate `writer(allocator)` calls; if any of those errored mid-build the `argbuf` is `defer .deinit`-ed correctly, but the pattern is fragile. Minor.

- `src/session_manager.zig:189` — `spawn` checks `shutdown_requested` once before grabbing the slot but the slot wait loop also rechecks; correct, but the early return at line 189 races with concurrent `requestShutdown`. The recheck after wake (line 202) closes the window.

- `test/adapter_tests.zig:594-597` — `realCredentialsEnabled` accepts `"1"` or `"all"` or a CSV list. The 00 strategy doc spec is a CLI flag `--with-real-credentials[=anthropic|...]`. See deferred section.

## Deferred-confirmed

1. **Adapter preflight binary/version probes — BLOCKING GAP, not legitimately deferred.** Plan step 4 explicitly states: "Add adapter-specific preflight: Binary exists and supports the required structured-output mode. Existing CLI credential or API-key fallback appears usable. Requested model/capability is recognized by the adapter." None of these are implemented in `harness_dispatch.zig` or `runtime.zig:routingPreflight`. The factory probe checks adapter-module availability, which is always true for claude/codex/fake — it does not probe the binary on PATH. When the binary is missing, the runtime gets `spawn_failed` from `std.process.Child.spawn`, not the design's intended `harness_unavailable`. design_runtime_loop.md preflight check #3 (`harness_unavailable`) is therefore unreachable for the real CLIs. The implementer's deferral note ("deferred to M8 Provider status commands") conflates an M7 routing-preflight reason with an M8 surfacing command. **Move to Blocking if the team agrees with the design doc.** Listed here so the team can choose.

2. **Continuity resume via captured `session_id` — legitimately deferred.** Plan step 6 says "Record session IDs now. Resume may be used only if both adapters prove reliable in tests. `compact` and `clear` remain deferred if resume behavior is not stable." The plan does not require `--resume` plumbing. HOWEVER: "Record session IDs now" requires the session_id to land in `meta.toml[result]` for continuity to work later. Because the `[result]` block isn't written (see Blocking above), the recorded-session-ids-for-later-resume promise is also broken. The deferral framing is fine; the underlying recording mechanism is not.

3. **Native session-file path captured in `meta.toml[result]` — partially correct.** True that `claude -p` does not print the encoded-cwd path; both adapters capture `session_file` only if it appears in the stream (rare). The plan accepts "when available" so the rare-capture stance is plan-conformant. But the path that *is* available (the adapter state) is still never copied into `meta.toml[result].session_file` because the broader `[result]`-population wiring is missing (Blocking #1). So the "we can't always get the path" claim is true, while the "when we do get it, we record it" claim is currently false.

4. **`STAKO_WITH_REAL_CREDENTIALS` env var vs `--with-real-credentials` CLI flag — minor deviation from 00_test_strategy.md.** The strategy doc specifies `zig build test -- --with-real-credentials[=...]` and lists `helpers/capability_flag.zig` as the parser. The implementation uses an env var (`test/adapter_tests.zig:587-597`). Behaviorally equivalent for skip/run, but the mechanism diverges. Acceptable as v1 expedient if 00_test_strategy.md is updated; otherwise should be aligned in M8.

## Acceptance criteria

- **Claude-routed and Codex-routed prompt items both run end-to-end and produce normalized `transcript.jsonl`** — MET. Both `m7 runtime: claude/codex adapter end-to-end` tests assert the transcript contains `harness:"claude/codex"`, `session:...`, `kind:message`, `kind:session_ended`, `terminal_status:completed`.

- **Review items run in fresh sessions for both required adapters** — PARTIALLY MET. `m7 review item routes the same way as prompt (fresh session)` asserts the review item completes via claude. The "fresh session" property (no `--resume`) is implicit because no resume plumbing exists at all yet — i.e., review is fresh because everything is fresh. No codex review test. Plan says "Support review items as fresh-session prompt executions for both adapters" — codex coverage is missing.

- **The same event schema drives transcripts and SSE for both adapters** — MET. Both adapters emit through `adapter.OwnedEvent`/`events.Kind`; `session_manager.processStdoutLine` writes the same event to `transcript.append` and `hub.publish`.

- **Provider-specific code stays behind adapter interfaces; session management and transcript handling remain shared** — MET. `session_manager.zig` and `transcript.zig` are unchanged structurally; the adapters are pure parsers behind `adapter.Adapter`.

- **Adding Gemini does not require duplicating session-manager, transcript, SSE, or transition logic** — MET by audit. A Gemini adapter would only need a new `*_adapter.zig` plus a `harness_dispatch.providerToHarness` entry plus a `factory` arm. Caveat: it would also re-duplicate the JSON micro-parsers (see Non-blocking).

- **Claude and Codex runs both produce terminal `[result]` metadata** — NOT MET. See Blocking #1: `onExitMain` never passes `result_*` fields into the runtime transition, so the `[result]` table is never written despite the adapter state holding session_id/model/session_file.

- **Fake Claude and fake Codex binaries emit scripted JSONL; expected normalized transcripts match exactly** — MET. `test/fixtures/harness/claude_stream.jsonl` and `codex_stream.jsonl` are exercised via `cat_jsonl.sh`; the two "parses ... into expected normalized events" tests assert exact event-kind counts.

- **One real Claude and one real Codex smoke test, gated behind real-credential flags** — MET (with the env-var deviation noted in Deferred #4). `real claude smoke @integration:provider:anthropic` and `real codex smoke @integration:provider:openai` are present, skip cleanly under the default test run, and are tagged.

- **Adapter parse failures block/fail with pinned reason codes** — MET. `emitErrorList` emits `{"message":"adapter_parse_error","recoverable":true}`; malformed-line tests assert exactly one `error` event with `"recoverable":true`.

- **Build: `zig build test --summary all` reports 240 pass, real-credential tests skipped, well under 5s** — MET. Clean rebuild: 2.3s wall; cached: 0.65s. 240/240 pass with `[skipped: real-credentials gate (anthropic)]` and `[skipped: real-credentials gate (openai)]` printed. No zombie `claude`/`codex`/`cat_jsonl` processes after two consecutive test runs.

- **Subprocess hygiene (argv only, no sh -c, FDs closed, no zombies)** — MET. `session_manager.spawn` uses `std.process.Child.init(argv, ...)` directly; `stdin_behavior = .Ignore`, stdout/stderr `.Pipe`; child reaped via `s.child.wait()` in `onExitMain`; `requestShutdown` SIGINTs all running children. Verified no `claude_stream|codex_stream|cat_jsonl` orphans after `zig build test` repeats.

- **Routing precedence: (1) target.provider mapped via allowed_harnesses, (2) first allowed, (3) fake; denied → `harness_denied`** — MET. `src/runtime.zig:261-310` implements exactly this; `m7 routing: item.target.provider denied when stack excludes the mapped harness` asserts `status = "blocked"` with `blocked_reason = "harness_denied"`.
