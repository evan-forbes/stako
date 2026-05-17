# Audit — Milestone 7: Claude and Codex Adapters

Baseline: e0be1e4. Modules audited: src/claude_adapter.zig (997 LOC, 12 in-file tests), src/codex_adapter.zig (845 LOC, 11 in-file tests), src/harness_dispatch.zig (291 LOC, 8 in-file tests). Tests audited: test/adapter_tests.zig (12 integration tests including 2 gated real-credential smokes). Full suite: 418/418 green via `zig build test --summary all`.

## Execution traces

**Claude session, spawn → first event → tool-use → result.** Runtime preflight (runtime.zig:312) maps `target.provider="anthropic"` to harness `"claude"` via `harness_dispatch.providerToHarness` (harness_dispatch.zig:42), confirms `claude` is in `allowed_harnesses`, calls `factory(allocator,"claude")` (harness_dispatch.zig:69) which returns a `claude_adapter.create` instance (claude_adapter.zig:59). `buildArgv` (harness_dispatch.zig:89) reads `prompt.md` from the item dir (falls back to slug when missing), composes a 7-element argv: `["claude","-p",<prompt>,"--output-format","stream-json","--verbose","--include-partial-messages"]` (harness_dispatch.zig:137-153). `Manager.spawn` dupes the argv strings, hands them to `std.process.Child.init(argv_owned,…)` (session_manager.zig:228) — no shell, no concatenation. The child's stdout flows through `stdoutPump` → `processStdoutLine` → `adapter.parseLine`. The first line `{"type":"system","subtype":"init","session_id":"sess-...","model":"claude-opus-4-7","cwd":"…"}` is parsed by the `system` branch (claude_adapter.zig:176-197): the `subtype:"init"` guard fires once (gated by `seen_init`), the adapter stores `session_id`, `model` and the optional `session_file` into its `State`, then calls `emitSessionStarted` which writes `{"harness":"claude","model":"…","session":"<sid>","cwd":"…"}`. session_manager.zig:517-524 reads back the `session` value into `s.session_id` so later events get the right session tag. A `stream_event.message_start` advances `turn_index` and emits `turn_started`; a `content_block_delta.text_delta` emits `message_chunk`; a full `assistant` line with a `tool_use` block named `Edit` triggers `projectAssistantBlock` (claude_adapter.zig:421-447) which emits both a `tool_call` (carrying the raw `input` object as `args`) and a `file_changed` with `op="modify"` (`Write` → `"create"`, `MultiEdit` → `"modify"`). A `Bash` tool_use emits `tool_call` + `command_executed{exit:0}` (the exit_code is a placeholder — the real exit only arrives later in the matching `user.tool_result`, which is currently mapped to `tool_result` but not used to rewrite the prior `command_executed`). Finally `{"type":"result",...}` refreshes session_id, captures `session_file` if present, and emits a terminal `message` carrying the `result` text. `onExit` (claude_adapter.zig:118) composes `session_ended` with `exit_code`, `terminal_status` (canceled / completed / failed), `session_id`, `session_file`, `model`. `session_manager.onExitMain` (session_manager.zig:572-661) extracts the three string fields from `data_json`, dupes them into locals that outlive the event, and submits the runtime transition with `result_harness=s.harness_name`, `result_session_id`, `result_session_file`, `result_model`, `result_transcript_path=sess.transcript.path`, `result_exit_code`, `result_completed_at=audit.nowRfc3339Millis(…)` — which lands in `meta.toml`'s `[result]` block via `mutations.zig:549` and `item.zig:455-464`.

**Codex session, spawn → thread.created → item.completed → turn.completed.** Symmetric. `target.provider="openai"` → harness `"codex"` → argv `["codex","exec","--json",<prompt>]` (harness_dispatch.zig:155-167). First line `{"type":"thread.started","thread_id":"th-…","model":"gpt-5"}` enters the `thread.started` branch (codex_adapter.zig:163-179), stores `session_id`/`model`/optional `session_file`, gates `seen_thread_started` so re-emitted thread.started lines don't re-emit `session_started`, then emits `session_started{harness:"codex","model":…,"session":…}`. `turn.started` emits `turn_started` and bumps `turn_index`; `item.completed` with `item_type:"reasoning"` emits `message{role:"reasoning"}`; `command_execution` emits `tool_call{tool:"command_execution",args:{"command":…},call_id}` + `command_executed{cmd,exit}` where the exit is parsed via `findIntValue`; `file_change` emits a single `tool_call{tool:"file_change",args:"{}"}` followed by one `file_changed` per element in the `changes` array, mapping `create|add`→`"create"`, `delete|remove`→`"delete"`, anything else→`"modify"` (codex_adapter.zig:234). `agent_message` emits `message{role:"assistant"}`. `turn.completed` emits `turn_completed`. `turn.failed` extracts `error.message` (codex_adapter.zig:186) and emits a **non-recoverable** error; `error`/`thread.error` emit a recoverable error. On exit, `session_ended` carries `terminal_status`, `session_id`, optional `session_file`, `model`. All six `[result]` fields land the same way as Claude (see below).

**Malformed-JSON line behavior.** Each adapter strips `\r\n`/`\n` then calls `findTopLevelStringValue(line, "\"type\":")`. When that returns null — either no `"type"` key, or input that doesn't parse as JSON at all (e.g. `"trailing junk"`) — `parseLine` returns a single recoverable `error` event with payload `{"message":"adapter_parse_error","recoverable":true}` (claude) or the same with `recoverable:true` (codex). `findTopLevelStringValue` walks the line manually tracking string-state, escape-state, and depth, so `{"payload":{"type":"nested"},"type":"system",…}` correctly returns `"system"` (test "top-level type wins over nested type fields"). `{}` parses, sees no `type`, returns `null` from `findTopLevelStringValue` and yields one error. **Unknown top-level type** (a vendor adding a new event kind) yields one recoverable `error` event with slug `"adapter_unknown_event"` (claude_adapter.zig:254, codex_adapter.zig:228). Empty line returns 0 events. Empty `assistant.message.content[]` array iterates and breaks immediately (0 events). Adapter.parseLine never panics on truncated input; `findMatchingBraceEnd` returns null on unbalanced braces and the caller skips that block.

**Subprocess argv composition.** Both adapters build their argv as a `[][]u8` of separately-allocated, separately-duped strings (harness_dispatch.zig:137-167). The prompt is **one** argv slot, never concatenated. `Manager.spawn` calls `std.process.Child.init(argv_owned, allocator)` (session_manager.zig:228) which under Zig uses `execvpe`-equivalent system calls — no `/bin/sh -c`, no string interpolation, no shell metacharacter expansion. Embedded `;`, `&&`, `$VAR`, backticks, newlines and quotes are all preserved verbatim as a single argument. `child.cwd` is set from `proceed.cwd` (which is gated by `runtime.workdirAllowed`/`pathWithin`) — and is passed as a raw filesystem path, not interpolated into argv.

## Argv safety

Confirmed argv-only. No shell, no string concatenation into a composite command, no `popen`/`system`/`sh -c`. Each argv element is duped into its own buffer in `buildClaudeArgv`/`buildCodexArgv` (harness_dispatch.zig:137-167) and again in `Manager.spawn` (session_manager.zig:222-226). The spawn call is:

```zig
var child = std.process.Child.init(argv_owned, self.allocator);
if (input.cwd) |c| child.cwd = c;
child.stdin_behavior = .Ignore;
child.stdout_behavior = .Pipe;
child.stderr_behavior = .Pipe;
child.spawn() catch return error.SpawnFailed;
```

at session_manager.zig:228-233. The prompt slot (argv[2] for Claude, argv[3] for Codex) is whatever bytes `prompt.md` contained, trimmed of trailing newlines (harness_dispatch.zig:127-134) — newlines/quotes/backslashes/semicolons inside the prompt body are passed verbatim and do **not** affect the shell because there is no shell. The `cwd` slot is filesystem-only and is checked against `workdir_allowlist` via realpath canonicalization + `pathWithin` (runtime.zig:517-527) before reaching spawn. No environment variables are appended on the harness side; the daemon's env is inherited as-is.

The only place that touches argv after construction is `Manager.spawn`'s dup loop. There is no place where any argv element is joined with spaces, written into a buffer with format-string interpolation that the OS later parses as a command line, or fed to `popen`/`std.fs.openProc`/etc. Confirmed via `grep -rn "sh -c\|system(\|popen\|Process\\.run" src/` — only `child.spawn()` on `std.process.Child` is used for harness execution.

## [result] block end-to-end

All 6 fields confirmed populated from `session_ended` payload + session_manager surroundings:

| field | source | extraction site | sink |
|---|---|---|---|
| `harness` | Session field set at spawn time from `SpawnInput.harness` (session_manager.zig:273) | `s.harness_name` | session_manager.zig:650 → `result_harness` → mutations.zig → `[result].harness` (item.zig:457) |
| `session_id` | adapter `State.session_id` written into `session_ended.data_json`'s `"session_id"` field by `onExit` (claude_adapter.zig:133-137; codex_adapter.zig:121-125) | `extractJsonString(ev.data_json, "\"session_id\":")` (session_manager.zig:599) with fallback to `s.session_id` snooped at session_started (session_manager.zig:632-641) | `result_session_id` → `[result].session_id` (item.zig:459) |
| `session_file` | adapter `State.session_file` written into `session_ended.data_json`'s `"session_file"` (claude_adapter.zig:138-142; codex_adapter.zig:126-130). Claude populates it from system.init's `session_file` field if vendor ever adds one (claude_adapter.zig:188-191) and from `result.session_file` (claude_adapter.zig:246-249); Codex populates from `thread.started.session_file` (codex_adapter.zig:172-175). | `extractJsonString(ev.data_json, "\"session_file\":")` (session_manager.zig:602) | `result_session_file` → `[result].session_file` (item.zig:460) |
| `model` | adapter `State.model` from system.init (Claude) or thread.started (Codex), written into `session_ended.data_json`'s `"model"` (claude_adapter.zig:143-147; codex_adapter.zig:131-135) | `extractJsonString(ev.data_json, "\"model\":")` (session_manager.zig:605) | `result_model` → `[result].model` (item.zig:458) |
| `exit_code` | computed by `session_manager.onExitMain` from `Child.Term` (session_manager.zig:576-580); also written into `session_ended.data_json`'s `"exit_code"` by the adapter | `s.allocator`-level local `exit_code: i32` | `result_exit_code` → `[result].exit_code` (item.zig:462) |
| `completed_at` | `audit.nowRfc3339Millis(&ts_buf)` (session_manager.zig:644) — generated at terminal time, not from adapter | local `completed_at` | `result_completed_at` → `[result].completed_at` (item.zig:463) |

Additional fields populated alongside the canonical 6: `transcript_path` (from `sess.transcript.path`, session_manager.zig:654 → item.zig:461). Tests `m7 result block: claude scripted run records session_id + harness in meta.toml [result]` (adapter_tests.zig:387-460) and the Codex counterpart (adapter_tests.zig:462-533) assert `harness`, `session_id`, `model`, and `exit_code` on disk after a scripted end-to-end run.

**Malformed session_ended path.** If `onExit` itself fails (returns an error), `maybe_ev` is null (session_manager.zig:584 swallows with `catch null`), `result_*_owned` stay null, the `[result]` block is emitted with only the always-populated fields (`harness`, `exit_code`, `completed_at`, `transcript_path`). If the adapter writes a malformed `data_json` (e.g. unterminated quote), the local `extractJsonString` returns null per field and the `[result]` block loses just those fields — no crash, no leak.

## Stream-JSON event coverage

### Claude (`claude_adapter.zig`)

| Event line | Fields extracted | Emits | In-file test | adapter_tests.zig test |
|---|---|---|---|---|
| `{"type":"system","subtype":"init",…}` | `session_id`, `model`, `cwd`, `session_file` (vendor-future) | `session_started{harness,model,session,cwd}` | "claude: system init -> session_started…" (line 832) | "claude adapter parses claude_stream.jsonl…" (line 157) |
| `{"type":"stream_event","event":{"type":"message_start",…}}` | none beyond type | `turn_started{turn:N}` + bump `turn_index` | "claude: stream_event message_start…" (line 846) | yes — claude_stream.jsonl line 2 |
| `{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":…}}}` | `text` | `message_chunk{text,role:"assistant"}` | yes (line 846) | yes — 2 chunks asserted (line 185) |
| `{"type":"stream_event","event":{"type":"message_stop"}}` | none | `turn_completed{turn,usage:{}}` | yes (line 846) | yes — count asserted (line 188) |
| `{"type":"assistant","message":{"content":[{type:"text",text:…}]}}` | content[].text | `message{text,role:"assistant"}` | "claude: assistant message with text block…" (line 868) | yes — fixture line 5 |
| `{"type":"assistant",…content:[{type:"tool_use",name:"Edit"\|"Write"\|"MultiEdit",input:{file_path:…}}]}` | name, id, input.file_path | `tool_call` + `file_changed{path,op}` (op=create for Write else modify) | "claude: tool_use Edit -> tool_call + file_changed" (line 880) | indirectly via fixtures |
| `{"type":"assistant",…content:[{type:"tool_use",name:"Bash",input:{command:…}}]}` | input.command | `tool_call` + `command_executed{cmd,exit:0}` | "claude: tool_use Bash -> tool_call + command_executed" (line 894) | yes |
| `{"type":"user","message":{"content":[{type:"tool_result","tool_use_id":…,"content":…}]}}` | tool_use_id, content | `tool_result{call_id,ok:true,output}` | none in-file — gap | not asserted |
| `{"type":"result","subtype":"success"\|"error",…}` | session_id, session_file, result | `message{text,role:"assistant"}` if `result` is present, plus session-id/file refresh | "claude: result line refreshes session id…" (line 952) | yes — fixture line 7 |
| Unknown top-level `type` | n/a | recoverable `error{adapter_unknown_event}` | "claude: unknown top-level event…" (line 988) | "m7 claude adapter: each malformed line…" (line 764) |
| Malformed JSON | n/a | recoverable `error{adapter_parse_error}` | "claude: malformed line yields recoverable error" (line 907) | covered by malformed-line test |

### Codex (`codex_adapter.zig`)

| Event line | Fields extracted | Emits | In-file test | adapter_tests.zig test |
|---|---|---|---|---|
| `{"type":"thread.started","thread_id":…,"model":…}` | thread_id, model, session_file (vendor-future) | `session_started{harness,model,session}` | "codex: thread.started -> session_started…" (line 710) | "codex adapter parses codex_stream.jsonl…" (line 191) |
| `{"type":"turn.started"}` | none | `turn_started{turn:N}` + bump | "codex: turn.started + turn.completed" (line 722) | yes |
| `{"type":"turn.completed","usage":{…}}` | none | `turn_completed{turn,usage:{}}` | yes (line 722) | yes |
| `{"type":"turn.failed","error":{"message":…}}` | error.message via nested `findStringValue` | `error{message,recoverable:false}` | "codex: turn.failed -> error (non-recoverable)" (line 778) | not in end-to-end fixture |
| `{"type":"error","message":…}` / `{"type":"thread.error","message":…}` | message | `error{message,recoverable:true}` | none in-file — gap | not asserted (gap) |
| `{"type":"item.completed","item":{"item_type":"agent_message","text":…}}` | text | `message{role:"assistant"}` | "codex: agent_message item -> message" (line 738) | yes — fixture line 6 |
| `{"type":"item.completed","item":{"item_type":"reasoning","text":…}}` | text | `message{role:"reasoning"}` | none in-file — gap | yes — fixture line 3 (counted as one of the 2 messages) |
| `{"type":"item.completed","item":{"item_type":"command_execution","id":…,"command":…,"exit_code":…}}` | id, command, exit_code | `tool_call` + `command_executed` | "codex: command_execution…" (line 749) | yes |
| `{"type":"item.completed","item":{"item_type":"file_change","id":…,"changes":[…]}}` | id, changes[].path, changes[].kind | `tool_call` + N × `file_changed` | "codex: file_change with changes array…" (line 761) | yes |
| `{"type":"item.updated",…}` | same as item.completed | same | none in-file — gap | not asserted (alias case) |
| Unknown top-level `type` | n/a | recoverable `error{adapter_unknown_event}` | "codex: unknown top-level event…" (line 836) | not asserted in adapter_tests |
| Malformed JSON | n/a | recoverable `error{adapter_parse_error}` | "codex: malformed line yields recoverable error" (line 789) | not asserted in adapter_tests |

## Blocking

None.

## Important

1. **Claude `Bash` tool_use emits `command_executed{exit:0}` before the real exit is known.** claude_adapter.zig:441-444 projects a `Bash` tool_use to a synthetic `command_executed` immediately, hardcoding `exit:0`. The real exit code only arrives later in a matching `user.tool_result` block, which is currently mapped to a separate `tool_result` event but **never used to amend the earlier `command_executed`**. Downstream consumers reading the transcript will see commands always reporting success. The plan (07_claude_codex_adapters.md step 2, "Translate … `Bash` into `command_executed`") doesn't explicitly require honoring the tool_result exit, but this silently drops correctness data. Either (a) defer the `command_executed` emission until tool_result arrives by buffering by `id`, or (b) drop the synthetic `command_executed` and only emit it from `tool_result` parsing.

2. **`findStringValue` picks the first key match in scan order, not the lexical top-level key.** claude_adapter.zig:633-662 (and the duplicate at codex_adapter.zig:494) scans `std.mem.indexOf` for the key, gating only on the immediately-preceding byte (`, { [ space`). For `{"type":"error","data":{"message":"nested"},"message":"top"}`, the codex `error` branch (codex_adapter.zig:188-190) would return `"nested"`. The codex `turn.failed` branch is safer because it isolates to the `error` object first (codex_adapter.zig:186). Same trap exists in claude's `system.init` extraction for `session_id`/`model`/`cwd` — if a vendor adds a nested object containing `"session_id":"…"` before the top-level one, the adapter would capture the wrong value. **Concrete reproducer for codex** (not asserted by any current test): `{"type":"error","details":{"message":"buried"},"message":"actual"}` → adapter emits `error{message:"buried"}`. The fix is small: in the `error`/`thread.error` branch use a top-level scan (`findTopLevelStringValue`) like the `type` lookup, or scope to the parent object explicitly.

3. **Claude adapter's `writeParsedJsonStringContent` is misleadingly named and slightly fragile.** claude_adapter.zig:826-828 and codex_adapter.zig:704-706 both just call `w.writeAll(s)` — they neither parse nor re-escape. The implicit contract is "the input is already the inside-of-quotes bytes from a valid JSON string in the source line, so re-emitting it between quotes is well-formed". This holds for `\"`, `\\`, `\n` etc. because the parser's `findStringValue` preserves the escapes verbatim. But the function name suggests it *handles* something. Rename to `writeRawEscapedJson` (or inline + comment). Also: `jsonEscape` (claude_adapter.zig:815-824) is used for *unescaped* host strings (e.g. the error slug "adapter_parse_error" — though those are ASCII-only). The mix-and-match isn't wrong, just easy to get wrong on the next change.

4. **Codex `error`/`thread.error` malformed-line path is untested at the integration layer.** codex_adapter.zig:188-190 has no in-file unit test that asserts a normal `{"type":"error","message":"foo"}` produces `error{recoverable:true,message:"foo"}`. The `turn.failed` test (line 778) only exercises the nested-error-object path. adapter_tests.zig doesn't assert on this either. Easy to add.

5. **Stdout/stderr line buffer is unbounded.** session_manager.zig:472-487 (stdout) and 537-553 (stderr) grow `line_buf` until a newline arrives. A malformed Claude/Codex producing a multi-MB line without `\n` would consume memory until OOM. This is technically M6 territory but it becomes more material under M7 because real CLIs occasionally emit very long lines (e.g. dumping a large file via Bash). Either cap with a circuit breaker (`if (line_buf.items.len > MAX_LINE) { kill_and_fail; }`) or stream-parse rather than line-batch. Not a regression — it was always there — but M7 makes it production-relevant.

## Minor

1. **Claude `result` event with no `result` field emits nothing.** claude_adapter.zig:250-252 only emits a final message if `result` is present. The adapter also doesn't emit a `turn_completed` here even though the docstring at line 240 says "plus a turn_completed if we haven't seen one" — the code is missing the fallback. Vendor variation where `result` arrives without a prior `message_stop` would skip turn_completed.

2. **`emitCommandExecuted` always writes `"stdout_truncated":false,"stderr_truncated":false`** without observation (claude_adapter.zig:517, codex_adapter.zig:426). These are placeholder fields the adapter has no way to populate at parse time — that's fine, but document the limitation in the docstring of `events.command_executed.data` so consumers don't trust them.

3. **DRY: the JSON micro-parser is duplicated wholesale.** claude_adapter.zig:624-828 and codex_adapter.zig:483-706 contain the same `stripEol`, `findStringValue`, `findTopLevelStringValue`, `findObjectValue`, `findArrayValue`, `findMatchingBraceEnd`, `jsonEscape`, `writeParsedJsonStringContent` (~200 LOC each). The codex file even documents this at line 483-485. Moving these into a new `src/adapter_json.zig` would shrink each adapter by ~25%, make fix #2 above a one-touch change, and centralize the test surface. Currently any parser tweak (e.g. fix issue #2) requires two edits and two test sweeps. This is the right time to extract because (a) M8 will need the same helpers for Gemini and (b) the bug-fix surface keeps growing.

4. **`emitToolCall` `args` injection is raw-pass-through.** claude_adapter.zig:455-465 writes `"args":` followed directly by the source `input` object's bytes (with braces). If the input object contains a UTF-8 BOM or other oddity the source provider chose to emit, the adapter passes it through verbatim. Probably fine — the transcript is consumed as JSON downstream and a downstream JSON parser will accept whatever the source produced — but worth noting that the adapter has zero defense against a vendor emitting malformed JSON inside `input`.

5. **Codex `mapCodexFileKind` doesn't recognize `"modify"` or `"update"` explicitly** (codex_adapter.zig:234-238). The fallback is `"modify"`, which happens to be correct for `update`, but the code reads as "anything not create/delete is a modify" — that's fragile if the vendor adds `"rename"` (which is neither). Either accept-listed-set with explicit fallback to a new `"other"` op, or document the catch-all explicitly.

6. **`emitTurnCompleted` reports `turn-1` as the "current" turn** (claude_adapter.zig:327, codex_adapter.zig:317). The math `if (st.turn_index == 0) 0 else st.turn_index - 1` is correct given that `turn_index` is bumped on `turn.started`, but it's not obvious at a glance. A one-line comment "`turn_index` is pre-bumped at message_start; the just-completed turn is one less" would help.

7. **Test "buildArgv: claude shape" passes a non-arena-initialized `Item.arena` field** but uses `defer it.deinit()` which calls `arena.deinit()` on an arena that was never used to allocate anything past init. Works, but the Item struct construction (test/adapter_tests.zig:230-238 in claude_adapter test, and the analogous `harness_dispatch.zig:230-239`) is somewhat misleading because the arena is constructed even though no `arena`-backed strings are involved — the test reads string literals from comptime. Minor.

8. **`real claude smoke @integration:provider:anthropic` shells out to `claude --version` to detect the binary** (adapter_tests.zig:809-818). The error path on missing-binary prints `[skipped: `claude` not on PATH]` to stderr but doesn't `return` after the print — wait, it does, line 814 returns inside the `spawn() catch {…}`. OK, fine. Same pattern for codex. Negligible.

## Coverage gaps

1. **Claude `user.tool_result` mapping has no unit test.** claude_adapter.zig:208-215 and `emitToolResults` (line 530-555) are exercised only indirectly. Add a unit test: `{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tu_1","content":"ok"}]}}` → `tool_result{call_id:"tu_1",ok:true,output:"ok"}`.

2. **Claude `assistant.message` with multiple content blocks** (text + tool_use in the same message) is not tested. The fixture has only one block per assistant line. Vendor regularly emits mixed blocks. Add a test asserting that 2 events are emitted in source order.

3. **Codex `error` and `thread.error` simple form** not unit-tested (see Important #4).

4. **Codex `item.updated` alias** not tested (codex_adapter.zig:191). The adapter accepts both `item.completed` and `item.updated` as the trigger but no test exercises the `item.updated` path.

5. **Stderr-line-from-subprocess path** (`parseStderrLine` in both adapters, lines 94-116 / 82-104) has no unit test. The function always returns one recoverable error per non-empty line — but the test surface is zero. A one-line test would protect against an accidental regression that silently swallows stderr.

6. **`onExit` with `ran_to_completion=false AND exit_code=0`** (e.g. timeout-canceled cleanly) is partially covered ("canceled when not ran_to_completion" tests use exit_code=130). The combination of clean exit + canceled flag is unusual but should be asserted to lock in the precedence rule (`canceled` wins).

7. **`result` event with neither `result` nor a prior `message_stop`** — see Minor #1. No test.

8. **Argv escaping of pathological prompts** — no test asserts that a `prompt.md` containing `"$(rm -rf /)"`, newlines, embedded NULs, or 100KB+ size is passed through as a single argv element. Add a buildArgv test that reads a prompt.md with a literal newline and a `$(…)` substring and asserts `argv[2]` is the exact contents.

9. **`cwd` path traversal in adapter argv** — `harness_dispatch.buildArgv` doesn't take a `cwd` argument; cwd is set later by the spawn. There's no test asserting that the adapter never injects the cwd into argv. The current implementation can't (cwd isn't passed in), but a guard test ensures a future refactor doesn't add one.

10. **`harness_dispatch.factory` returning errors** (e.g. OOM on `claude_adapter.create`) is not tested. The test asserts the success path and the null-on-unknown-harness path. A failing-allocator test would protect the supervisor's null-vs-error distinction.

11. **`buildArgv` with a `prompt.md` of size 0 vs. size > 0 but whitespace-only**. `resolvePrompt` (harness_dispatch.zig:107-135) trims trailing CR/LF and falls back to slug only if `end == 0`. A prompt.md containing only `"   "` (three spaces) would yield `"   "` as the prompt — probably fine, but no test pins the behavior.

## Strengths

1. **Argv-only execution is comprehensively enforced.** Two separate hops (buildArgv → spawn) both treat each element as an opaque byte slice. No code path in M7 builds a shell command. The adapter's `Invocation` struct (adapter.zig:84-102) exists but is unused in M7 — the production path passes argv directly through `Dispatch.build_argv` → `Manager.spawn` so even the unused struct can't introduce shell injection.

2. **Defensive parser policy is consistent.** Both adapters follow the same contract: malformed line → one recoverable error event; unknown event type → one recoverable error event; missing required field → silently emit fewer events (never crash, never throw). The session manager treats `parseLine` errors as "drop this line and continue" (session_manager.zig:508-510), so vendor surprises can't tear down a session.

3. **State capture is fault-tolerant.** Claude tracks session_id from *both* `system.init` and `result` events (claude_adapter.zig:179-194 and 242-249). If the vendor stops emitting one, the other still populates `[result].session_id`. Codex tracks the thread_id under a `seen_thread_started` guard to avoid double-emitting `session_started` if `thread.started` is repeated.

4. **The `[result]` block path has a fallback layer** (session_manager.zig:632-641): if the adapter's `session_ended.data_json` omits `session_id` somehow, the session_manager falls back to the `s.session_id` it snooped from the `session_started` event. This means `[result].session_id` is populated even if the adapter's onExit is buggy, as long as `session_started` arrived once.

5. **Provider/harness mapping is bidirectional and tested.** `providerToHarness` and `harnessToProvider` (harness_dispatch.zig:42-60) are both tested for round-trips (harness_dispatch.zig:179-192). Aliases (`"claude"` / `"anthropic"`) work without code duplication.

6. **Real-credential tests are properly gated.** `realCredentialsEnabled` (adapter_tests.zig:788-798) reads `STAKO_WITH_REAL_CREDENTIALS`, supports `"1"`, `"all"`, or a comma-separated list, and prints a `[skipped: …]` line on the unset path so CI logs read cleanly. The 30-second wall-clock cap (adapter_tests.zig:864) prevents a hung provider from blocking CI.

7. **Memory ownership is clean.** Every `emit*` helper builds an `ArrayList(u8)`, runs `toOwnedSlice`, and stores the slice as both `data_json` and `storage` so a single `freeOwned` cleanup frees the right bytes. `errdefer` chains in `parseLine` correctly free already-appended events on a mid-line error (claude_adapter.zig:171-174). The `State` struct's `deinit` frees `session_id`/`model`/`session_file` precisely once each.

8. **Test fixture format is byte-stable** (`claude_stream.jsonl`, `codex_stream.jsonl`) — both files are 7-line JSONL with explicit `session_id`/`model` values that propagate to `[result]` block assertions. The fixture format matches the real vendor output closely enough that adapter logic exercises real-world parse patterns.

9. **End-to-end coverage is strong.** Six adapter_tests.zig cases run a full Supervisor.tickStack against scripted JSONL, verifying both `meta.toml.status=completed` and `[result]` block fields land correctly. Routing tests cover: provider→harness mapping, harness-denied, capability-denied (clear on codex), review-without-target falling back to first allowed harness, and the malformed-input guardrail.
