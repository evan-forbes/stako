# Audit — Milestone 5: Mutations and VCS

Baseline: cd96d23. Tests: 402/402 passing via `zig build test --summary all`.

Modules audited:
- `src/audit.zig` (301 lines)
- `src/vcs.zig` (381 lines)
- `src/mutations.zig` (1475 lines)
- `src/mutation_queue.zig` (481 lines)
- Plus the M5 handler surface in `src/daemon.zig` (handlers + `respondMutationError`/`respondMutationOk`)
- Plus interactions with `src/session_manager.zig` (the only other audit-log writer / queue submitter)

Tests audited:
- `test/mutation_tests.zig` (10 tests — full E2E via HTTP)
- In-module unit tests in `src/audit.zig`, `src/vcs.zig`, `src/mutations.zig`, `src/mutation_queue.zig`

## Execution traces

**Plan note on "hand-rolled git":** the audit brief mentions hand-rolled git
object writing. The actual code shells out to the system `git` binary
(`vcs.zig:207 runGit` via `std.process.Child`). This matches plan step 3
("Shelling out to `git` is fine for v1"). There is no hand-rolled object
encoding to byte-spot-check; the "git object format spot-check" dimension
therefore becomes "does the shell invocation pass the right args and surface
the right errors" — covered below.

**Happy-path E2E (HTTP create_stack):**
`POST /stacks` enters `handleCreateStack`
(`src/daemon.zig:1641`) → reads/parses body → builds
`mutations_mod.CreateStackInput` → constructs `mutation_queue.Request{
.kind = .create_stack, .ident = {api_path="POST /stacks"} }` →
`self.queue.submitAndWait(&request)` (`src/daemon.zig:1692`) → enqueue
under `Queue.mutex`, signal `cv`, wait on `req.done_cv`
(`src/mutation_queue.zig:165-192`). Worker thread `workerMain`
(`src/mutation_queue.zig:205`) dequeues, calls `processOne`
(`src/mutation_queue.zig:217`): (1) `computePreflightPaths` returns empty
for create_stack so no `assertPathsClean` runs; (2) dispatch table at
line 247-278 calls `mutations.applyCreateStack`, which validates name,
checks `dirExists`, writes `stacks/<name>/stack.toml`, and returns a
`MutationOutput` with `paths`, `commit_subject`, `commit_body`,
`audit_action=.create_stack`, `audit_target="stack/<name>"`; (3)
`skip_commit` is false → `vcs.commit` is invoked (stage, check for staged
changes, write `.git/STAKO_COMMIT_MSG`, `git commit`, capture short SHA);
(4) `audit_writer.append` writes one NDJSON line (with fsync). Worker
signals `done_cv`; handler returns the response with `{"ok":true,"commit":"<sha>"}`.

**Commit-fails E2E (vcs.commit returns error.GitFailed):**
Same path until step 3 of `processOne`. Inside `vcs.commit` (`src/vcs.zig:96`)
the sequence is: `git add -- <paths>` (line 108) → `hasStagedChanges` (line
113) → write `.git/STAKO_COMMIT_MSG` → `git commit ...`. If any `runGit`
returns `error.GitFailed`, `vcs.commit` propagates it. In the queue's
handler (`mutation_queue.zig:306-314`): `vcs.rollbackPaths` is invoked
(which only `git reset HEAD -- <paths>`; no working-tree restore),
`out.deinit()` frees the MutationOutput, and `req.err` is set to
`.git_failed`. **The mutator's on-disk writes are NOT reverted.** The audit
guard at line 322 means no audit line is written for the failure. The
handler returns `respondMutationError(.git_failed, ...)` → 500 Internal.
The next mutation against the same paths will see them dirty
(uncommitted-edits preflight) and be rejected with `vcs_dirty` → 409 with
`code: vcs_conflict`.

**Single-writer pause + concurrent serialize (E2E from tests):**
The "two concurrent requests serialize" test (`test/mutation_tests.zig:410`)
spawns two HTTP client threads, each posting `POST /stacks`. Both enqueue
through `submitAndWait`; the FIFO under `Queue.mutex` makes the worker
process them sequentially. Both stacks exist on disk after the run, and
the audit log contains exactly the two `target: stack/<name>` lines. The
test confirms the single-writer guarantee at the integration boundary.

**Runtime transition E2E (session manager → queue):**
The session manager wraps its transitions in
`applyTransition(queue, RuntimeTransitionInput)`
(`src/session_manager.zig:434`) which constructs a
`Request{ .kind = .runtime_transition, .ident = {"system","runtime"} }`
and calls `submitAndWait`. This routes through the same single-writer
worker. For `to=.running` the queue suppresses both the commit AND the
audit append (`mutation_queue.zig:292-300, 322`); for terminal
(completed/failed/canceled) it commits and audits once.

## Single-writer discipline

**Confirmed.** A repo-wide grep of `apply{CreateStack,AppendItem,InsertItem,Transition,RuntimeTransition,SetPaused,ConfigPatch}` finds only:

- Definitions in `src/mutations.zig`
- Calls from inside `Queue.processOne` (`src/mutation_queue.zig:248-278`)
- In-module unit tests (which intentionally bypass the queue to test the
  pure mutator in isolation; not a production callsite)

No HTTP handler, CLI command, runtime worker, or session manager calls a
mutator directly. The session manager has its own `applyTransition`
helper (`src/session_manager.zig:434`) that builds a `Request` and submits
through the queue — this name shadows the mutation name but routes through
the single-writer worker.

Conclusion: production code has exactly one writer (the queue's worker
thread). The unit tests at `src/mutations.zig:1147-1475` call mutators
directly with their own allocator; they don't subvert single-writer
in production, only in pure unit tests.

## Rollback semantics

**Actual behaviour on `vcs.commit` failure** (verified at
`src/mutation_queue.zig:306-314` and `src/vcs.zig:171-186`):

- **Index:** `git reset HEAD -- <paths>` is run via `vcs.rollbackPaths`.
  Errors are swallowed (`catch {}`). Result: staged changes are unstaged.
- **Working tree:** NOT restored. The on-disk file overwritten by the
  mutator stays as-is. `vcs.zig:184-185` explicitly documents this:
  "For untracked / dirty workspace files we don't auto-discard — too
  risky. The mutation worker is expected to remove temp files itself on
  error." But the mutation worker does NOT do this either — `processOne`
  just calls `rollbackPaths` and returns.
- **Audit:** NOT written. The audit append branch at line 322 only runs
  after a successful commit (the `op_err` early-return at line 283-286
  and the commit-failure path's `return` at line 313 both bypass it).
- **HTTP response:** `respondMutationError(req, .git_failed, ...)` → 500
  Internal with `{"code":"internal","message":"git operation failed"}`.

**Compared to acceptance criteria** (`impl/05_mutations_and_vcs.md:68`):
"Half-failed mutations leave the repo clean: no staged changes, no
partial commits, no audit-log line." Two of three are met — staged
changes and audit-log are clean, no partial commits exist — but the
**working tree is NOT clean.** The user is left with on-disk file edits
that the daemon thinks were rolled back. A retry of the same mutation is
then rejected by the dirty-target preflight (`mutation_queue.zig:228-230`,
`vcs.assertPathsClean`) with `vcs_dirty` → 409, with no obvious recovery
path through the API.

For `create_stack` failures specifically, `applyCreateStack` writes
`stacks/<name>/` and `stacks/<name>/stack.toml` (`mutations.zig:121-167`).
On commit failure, the directory remains; a retry returns
`error.AlreadyExists` → 409. There's no API path to clean up.

For `insert_item` / `append_item` failures, the new directory + meta.toml
remain on disk; future appends will skip past the orphaned id (since
`computeNextItemIdInt` only scans for max id), but the on-disk state has
a queued item the user never asked for.

For runtime `transition` failures (e.g. cancel/supersede), the meta.toml
was rewritten with the new status before the commit; commit failure
leaves the status flipped on disk with no audit line and no commit. The
runtime worker will then act on the new status on next tick.

## Git object format spot-check

Not applicable — the implementation shells out to `git`. The relevant
shell-out correctness checks:

- `git add -- <paths>` (`vcs.zig:106-108`): uses `--` so paths starting
  with `-` aren't treated as flags. Good.
- `git diff --cached --quiet` (`vcs.zig:192`): used to detect "no staged
  changes" via exit code 0 vs 1. Good — relies on documented git CLI
  contract.
- Commit identity is set via `-c user.name=...` / `-c user.email=...`
  (`vcs.zig:131-134, 148-152`). This avoids requiring a global config.
  Defaults are `"stako daemon" / "stako@local"`.
- Commit message is passed via `-F .git/STAKO_COMMIT_MSG`
  (`vcs.zig:137-152`) to dodge argv-escaping issues. The file is created
  with `truncate=true, mode=0o600` and `deleteFile` is deferred. Good.
  `--allow-empty-message` and `--no-gpg-sign` are set defensively.
- `env_map = null` is set on the child process (`vcs.zig:223`) — but
  ONLY in `runGit`; `runGitFull` (`vcs.zig:261-269`) does NOT set
  `env_map = null`. Behavioural inconsistency: `runGitFull` inherits the
  parent's environment, which may include GIT_DIR, GIT_INDEX_FILE,
  GIT_AUTHOR_NAME, GPG_TTY, etc. Important but not blocking — see below.
- Spawning catches `error.FileNotFound` → `error.GitNotFound` and
  everything else → `error.GitFailed`. The stdout/stderr buffers are
  capped at 8 MiB (`vcs.zig:234`) which is fine for v1.

## Blocking

**B1. Working-tree rollback omitted on commit failure** — see
"Rollback semantics" above. `mutation_queue.zig:306-314` +
`vcs.zig:171-186`. The acceptance text says "leave the repo clean";
files modified or created by the mutator stay on disk after a commit
failure, and the system has no path to clean them up. For
`applyCreateStack` this leaves a dangling stack directory that blocks
re-tries with `already_exists`. For `applyInsertItem`/`applyAppendItem`
it leaves an extra committed-looking item on disk. For
`applyTransition` it flips item status on disk without committing —
the runtime then runs on a status no commit reflects.

Suggested remediation strategy (not implementing in this audit):
- For new-directory mutators (create_stack, append_item, insert_item),
  record the created paths and `deleteTree` them on commit failure.
- For in-place rewrites (transition, runtime_transition, set_paused,
  config_patch), read+stash the old bytes before write and restore
  them on commit failure (alternatively run `git checkout -- <path>`).
- The current `vcs.rollbackPaths` already documents the omission; the
  fix belongs either in the queue worker or as a new
  `vcs.rollbackPathsHard` that runs `git checkout HEAD -- <paths>` on
  tracked paths.

**B2. Audit-log writer is documented single-writer but called from
multiple threads concurrently** — `audit.zig:80-82` says "Single-writer
access expected (callers serialize through the mutation queue); no
internal lock." but real callers include:

- the queue worker thread (`mutation_queue.zig:323`)
- the session manager spawn thread (`session_manager.zig:292`,
  `dispatch_harness` at spawn time, OUTSIDE the queue)
- the HTTP accept thread (`daemon.zig:950` `auditDenied`, called from
  `verifyAuth` paths before submission)
- the daemon main thread (`daemon.zig:187` `daemon_stopped`,
  `daemon.zig:294` `daemon_started`)

`Writer.append` does `f.writeAll(buf.items)` + `f.sync()` with no mutex.
The file is opened without O_APPEND (`audit.zig:105` createFile sets no
append flag); the offset was seeked to end once on open
(`audit.zig:110`). Concurrent `writeAll` calls from multiple threads can
interleave bytes, especially under multi-syscall partial writes, and
even single-call writes share an offset that two threads can race to
advance.

In practice, single-line writes are usually one short `write(2)` syscall
and the kernel advances the offset atomically per syscall, so the
default-case behaviour is "no interleaving but unspecified ordering".
That's a real race regardless: the unit tests don't exercise the
multi-thread case, and any line larger than the kernel's
single-write threshold (~1 MB on most Linuxes) would split, allowing
interleaving. Even at small sizes, the contract documented in the
source is materially false.

Suggested fix: either add a `std.Thread.Mutex` to `Writer`, or open the
file with O_APPEND (then writes are kernel-atomic up to PIPE_BUF/4 KiB
for filesystem writes that fit one syscall).

## Important

**I1. `vcs.rollbackPaths` doc-comment misleads about working-tree
restore** — `src/vcs.zig:169-186`. The header comment says "reset the
index for `paths` and discard any working-tree changes to them" but the
implementation only resets the index. Either (a) implement the
working-tree restore (`git checkout HEAD -- <paths>`) or (b) fix the
comment. Tying into B1.

**I2. `runGitFull` does not clear `env_map`, `runGit` does** —
`src/vcs.zig:222-223` vs `:261-269`. `runGitFull` is only used for
`git diff --cached --quiet` today, but inconsistency invites bugs as
new call sites land. Either set `env_map = null` in both or pick a
single helper. (`-c user.name`/`user.email` only override the config
identity; they do not override environment variables like
`GIT_AUTHOR_NAME`.)

**I3. `audit_writer` initialized with `undefined` in the queue and
later patched in `startWorker`** — `src/daemon.zig:373` does
`mutation_queue.Queue.init(allocator, abs_owned, undefined)`, and
`daemon.zig:255` writes `self.queue.audit_writer = &self.audit_writer`
in `startWorker`. The `undefined` sentinel is unsafe if any code path
ever reads it before `startWorker` runs. Today the queue's worker
thread is also started inside `startWorker`, so nothing dereferences
the field — but the invariant is fragile. Either: (a) accept the
pointer at `Queue.init` time (require the caller to provide a stable
`*audit.Writer` before the daemon struct is even built — possible if
the audit writer is heap-allocated), or (b) replace `undefined` with
a `null` pointer plus a runtime assert.

**I4. Audit emits `dispatch_harness` for ALL runtime transitions
including terminal completed/failed/canceled** —
`src/mutations.zig:602` hard-codes `audit_action = .dispatch_harness`
inside `applyRuntimeTransition`. The Action enum has no
`item_completed` / `item_failed` / `item_canceled_runtime`, so terminal
state changes are logged as if they were dispatch events. This is a
semantic regression from `design_errors_and_audit.md`'s intent and
makes audit-log analysis harder. Possible v1 fix: derive the action
from `input.to` (e.g. `.completed → .item_completed`); requires Action
enum additions.

**I5. Memory-leak risk in mutator output construction** — multiple
mutator functions allocate the parts of `MutationOutput` (subject /
body / target / details / detail_storage) without complete errdefer
coverage. Examples:
- `applyCreateStack` `mutations.zig:184-194`: `details = try allocator.alloc(audit.DetailKV, 0)` has no errdefer; if `detail_storage` alloc fails, `details` leaks.
- `applyTransition` `mutations.zig:451-455`: NONE of subject/body/target/details has an errdefer; if `target` or `details` alloc fails, the earlier strings leak.
- `applyRuntimeTransition` `mutations.zig:592-595`: same pattern; no errdefers on subject/body/target/details.
- `applyConfigPatch` and `applySetPaused`: missing errdefer on the
  later allocs too.

The leaks are zero-byte (for `details = alloc(DetailKV, 0)`) or
small (subject/body/target are short formatted strings), and OOM is
rare, but `std.testing.allocator` will catch them as leaks if an
allocation-fault-injection test is ever added.

**I6. `mutation_queue.MutationFailureKind.vcs_conflict` is dead** —
the enum value is defined at `mutation_queue.zig:104` and the daemon
mapping handles it at `daemon.zig:1581`, but no codepath sets it. All
preflight conflicts use `.vcs_dirty` instead. Either remove
`vcs_conflict` or use it (e.g. if `assertNoMergeConflicts` is run
per-mutation in addition to startup).

**I7. `Queue.submitAndWait` race on `closed`** — if the queue is
closed BETWEEN the caller's append (`mutation_queue.zig:176`) and the
worker dequeue, the worker's `dequeueOne` will pop the item (because
`items.len > 0`), process it, and signal. But if the queue's worker
thread has already exited (e.g. queue closed before any worker
started), the appended request is never processed and `submitAndWait`
deadlocks. The "no worker started yet" case is only theoretical if
`startWorker` is always called before any submission — which the
daemon enforces — but the Queue API doesn't.

**I8. Queue `deinit` leaks pending requests if worker never started**
— same scenario as I7. `Queue.deinit` calls `close` + `items.deinit`
but does not signal `done_cv` on enqueued (but unprocessed) requests.
Callers waiting in `submitAndWait` would block forever. Not reachable
through current call graph but easy to trip with a future test.

## Minor

**M1. `mutation_queue.Request` is allocated on the caller's stack** —
HTTP handlers do `var request = mutation_queue.Request{...}; queue.submitAndWait(&request)`. The queue captures `&request` and the
worker writes through that pointer. If the caller's frame ever
unwinds before the worker signals done (impossible with the current
synchronous wait, but a future async/cancellation path could break
this), we get a UAF. Today this is safe because `submitAndWait` blocks
on `done_cv`. Worth a code comment.

**M2. `computePreflightPaths` for transitions does a directory scan
under the mutation queue's worker** — `mutation_queue.zig:375-391`
opens the stack directory and iterates entries to find the
`<id>-<slug>` directory. The mutator (`applyTransition`) then does the
same scan via `findItemDir` (`mutations.zig:996-1008`). Two scans per
transition. Trivial cost at v1 scale, but DRY: a single helper that
returns both the matching dir name and the path would be cleaner.

**M3. `commit` writes `.git/STAKO_COMMIT_MSG` and immediately deletes
it** — `vcs.zig:137-144`. If two commits race (they can't today
because of single-writer queue, but the helper is public), they'd
trample the file. Worth a note that this helper is queue-only.

**M4. Hardcoded `8 * 1024 * 1024` stdout/stderr cap for git
processes** — `vcs.zig:234, 275`. Bare numeric literal twice; extract
to a named const.

**M5. Audit `Writer.deinit` closes the file but does not flush** —
`audit.zig:93-96`. Every `append` already syncs, so all data on disk
is durable, but the comment should note this so future readers don't
add buffering and forget to flush.

**M6. `Action.slug` is a manual switch** — `audit.zig:33-48`. Twelve
arms, each `.foo => "foo"`. `@tagName(self)` would replace the
function with zero risk of name drift. Same for `Outcome.slug` and
`mutations_mod.ApiTransition` verbs.

**M7. `nowRfc3339Millis` is reimplemented from M2** — `audit.zig:171`
duplicates calendar math that already lives in M2's storage helpers
(grep finds similar code in `src/storage.zig` for the same purpose).
Worth consolidating, but format-correctness is verified by tests.

**M8. `formatRfc3339Millis` falls back to `buf[0..0]` on bufPrint
failure** — `audit.zig:201`. Silent truncation. Should at least
return an obvious sentinel like `"1970-01-01T00:00:00.000Z"` or
propagate the error.

**M9. Audit JSON building in `Writer.append` reimplements the same
key/value scaffolding as `errors.respondError`** — both walk arrays
of `DetailKV`-ish structs and emit `{"key":"value",...}`. A
`writeJsonObject(w, keys, values)` helper would DRY both. Not
load-bearing.

**M10. The `details` field in audit lines is always emitted, even
when empty** — `audit.zig:152-161` always writes `,"details":{}`. The
design doc (`todos/design_errors_and_audit.md`) treats `details` as
optional. Either drop empty details or document the choice. Snapshot
tests would notice if this ever drifts.

**M11. `validateConfigValue` allocates+frees a value copy on every
patch** — `mutations.zig:1088-1103`. For string-typed values the alloc
is a `dupe(value)` that the caller frees immediately. Could return a
non-owned slice for non-string keys to skip the dance.

**M12. `applyConfigPatch` reads `stack.toml` but never re-validates
that the file is well-formed TOML** — `mutations.zig:680-688` reads
the file into a buffer and patches it byte-by-byte via
`patchTomlKeyRaw`. A user who hand-edited their `stack.toml` to be
invalid TOML would have their edit preserved verbatim plus a new
appended key. Not catastrophic (next read would fail loudly) but
worth a note that patches don't validate the surrounding file.

## Coverage gaps

**G1. No test exercises the commit-failure rollback path.** The audit
brief's "what happens on `vcs.commit` failure" question has no
integration test. Coverage hole; given that the actual rollback is
incomplete (B1) this is doubly bad — the bug would be obvious if any
test wrote a mutator-then-commit-fail scenario and checked working-tree
cleanliness. Suggested: corrupt `.git/index` or revoke write
permission on `.git/objects`, run a mutation, assert response error +
clean working tree.

**G2. No test exercises a mutator failure (e.g. mutator returns
error after writing some files).** `applyInsertItem` calls
`renumberItemsFrom` which renames directories one-at-a-time; if a
rename fails midway, the stack is left half-renumbered. No test
exercises this; no rollback exists either.

**G3. No test for the audit-writer concurrent-append scenario.** B2's
race would not be caught by current tests. A test with N threads
concurrently calling `audit_writer.append` and counting newlines would
detect any interleaving / loss.

**G4. No test for runtime_transition skip-commit behaviour.** The
queue's special case for `to=.running` (no commit, no audit) is
documented but untested. The session_manager integration tests in
M6/M7 may indirectly cover it, but a dedicated unit test in
`mutation_queue.zig` would lock the contract.

**G5. No test for `vcs_dirty` followed by `git checkout HEAD --`
recovery.** A reasonable user recovery flow ("user fixes the dirty
edit then retries") has no integration coverage.

**G6. No test for `assertNoMergeConflicts` returning
`error.GitNotFound`** — only the happy path is tested in `vcs.zig`'s
in-module tests. Important for the daemon-start path which tolerates
this.

**G7. No test for `MutationFailureKind.vcs_conflict`** (because it's
dead, see I6).

**G8. No test for transitions on a `running` item (the path that
returns `InvalidStateTransition` in `applyTransition`,
`mutations.zig:379-381`).** The plan explicitly calls out that mid-run
cancel via the mutation queue is rejected; should have a test.

**G9. No test for body-too-large** (`MAX_BODY_BYTES` =
256 KiB, `daemon.zig:1549-1552`). Sending a 1 MiB body should yield a
clean 4xx rather than a misleading `failed to read request body`
generic 400. Today's mapping returns
`{"code":"validation_failed","message":"failed to read request body"}` for
`BodyTooLarge`, which is misleading.

**G10. No test for the `runGit` 8 MiB stdout/stderr cap.** Hard to
trigger naturally, but if a future `git log` invocation is added to
the audit path it could cap out.

**G11. No test that the daemon-startup `assertNoMergeConflicts` path
runs only when `hasRealGit` returns true.** The check is gated to
avoid running on the `stako init`-stub layout; coverage of the gate
itself would be useful.

## Strengths

- The single-writer discipline is **clean and verifiable** by grep —
  one file owns all mutation dispatch (`mutation_queue.zig:248-278`),
  and the session manager submits via the same queue.
- The `MutationOutput` shape is **uniform across all mutators**: paths,
  commit_subject, commit_body, audit_action, audit_target,
  audit_details — making the queue's `processOne` body short and
  readable. Good separation: the mutators are pure, the queue
  orchestrates side-effects, the handlers just glue HTTP.
- Test coverage of the **happy paths is thorough**: one-mutation-one-commit-one-audit
  is explicitly asserted; `auditLineCount` + `countCommits` give
  cardinality assertions, not just shape ones.
- `assertPathsClean` correctly **distinguishes untracked from dirty**
  (`vcs.zig:71-92`) — required for append/insert which write
  brand-new files.
- The commit-message path uses `-F .git/STAKO_COMMIT_MSG` to
  **avoid argv escaping**; `--no-gpg-sign` and
  `--allow-empty-message` are set defensively.
- The runtime `queued → running` skip-commit-and-skip-audit special
  case is **correctly localized** to the queue (a single `if` block,
  with the audit-skip clearly tied to the commit-skip) and matches
  the design intent (don't flood git history with intermediate state
  flips).
- `applyConfigPatch` correctly **TOML-escapes** description /
  default_workdir values (covered by the `TOML-escapes string values`
  test).
- The HTTP handlers correctly use **`defer if (request.output) |*o| o.deinit()`**
  consistently — no leak of mutator output buffers across the success
  path.
- `respondMutationError` and `respondMutationOk` are **single helpers**
  used by every mutation handler; no duplicated JSON-building.
- The merge-conflict startup refusal is **end-to-end tested**
  (`test/mutation_tests.zig:521`) including the cleanup of the
  forged conflicted state.
