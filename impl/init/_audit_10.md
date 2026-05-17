# Audit — Milestone 10: Authorization

Baseline: 2c8d0c4. Modules audited: `src/policy.zig`, plus the
authorization integration in `src/daemon.zig` (route gate, identity
resolution, denial-audit, error rendering, `runtimePolicyCheck` callback,
form-body auth) and `src/runtime.zig` (routing preflight policy hook).
Adjacent code consulted for correctness: `src/config.zig`,
`src/errors.zig`, `src/audit.zig`, `src/mutations.zig`,
`src/mutation_queue.zig`, `src/session_manager.zig`, `src/init.zig`.
Tests audited: `test/authorization_tests.zig` and the unit tests inside
`src/policy.zig`.

Baseline tests run locally: 456/456 passing (`zig build test --summary all`).

## Execution traces

### Legitimate authorized request — POST /stacks/foo/items with full access
1. `serveOne` → `route` (`src/daemon.zig:639`).
2. `matchRoute("/stacks/foo/items")` → `Route.stack_items_list`,
   `m.stack = "foo"` (`src/daemon.zig:527`).
3. POST promotes to `.items_append` (`promoteToMutation` at line 807).
4. `isMutationRoute` is true → bearer header parsed by `verifyAuth`
   (line 977-992). Trim-tolerant, scheme `Bearer` matched
   case-insensitively, token verified via `local_token.Token.verify`.
5. `policy.resolveLocal(&self.config)` returns
   `{ name = "local", explicitly_declared = true, entry = &cfg.identities[i] }`
   when `[identity.local]` is present (the post-`init` default).
6. `routeToPolicyAction(.items_append) = .append_item` (line 613-625).
7. `target = .{ .stack = "foo" }` (line 707).
8. `policy.evaluate(id, .append_item, target)` (policy.zig:154):
   - id non-null and explicitly_declared, so the implicit-`*` fallback
     short-circuit is skipped.
   - Loops capabilities; the first `"*"` hit returns `.allow`
     (policy.zig:169).
9. Falls through to `handleAppendItem` (line 765).

### Legitimate denied request — POST /stacks/other/pause when identity holds only `stack.mine.pause`
1. Same path as above through `verifyAuth` (success — token verified).
2. `policy.resolveLocal` returns the explicit local identity with
   `capabilities = ["stack.mine.pause"]`.
3. `action = .pause_stack`, `target = .{ .stack = "other" }`.
4. `evaluate` enters the `else` branch (policy.zig:181), `verb = "pause"`.
5. `matchesStackCapability("stack.mine.pause", "other", "pause")`:
   - prefix matches, `rest = "mine.pause"`, `dot = 4`,
     `cap_stack = "mine"`, `cap_verb = "pause"`.
   - `stack_matches = false` (cap_stack ≠ `"other"` and ≠ `"*"`).
   - Returns false (policy.zig:211).
6. No further caps → `.capability_denied`.
7. `auditDenied` (daemon.zig:949) writes one audit line: identity
   `"local"`, action `pause_stack`, target `stack/other`, outcome
   `denied`, reason `capability_denied`.
8. `respondError(.capability_denied, "identity lacks required
   capability", details=[identity=local, capability=stack.other.pause])`
   → HTTP 403 with the canonical JSON shape (errors.zig:100-119).
9. No on-disk side effect: handler never runs.

### Forging a scope via crafted token / form value
1. Bearer header path: `verifyAuth` extracts the token from
   `Authorization: Bearer <hex>` and runs it through
   `local_token.Token.verify`. The header carries no identity name; the
   token always resolves through `resolveLocal` to identity `"local"`.
   There is no path by which an attacker can claim a different identity
   name over the loopback API in v1.
2. Form-body path: `verifyAuthFormBody` (daemon.zig:829) only extracts
   `_token=<hex>`; the field name is fixed and never substituted for an
   identity name. URL decoding tolerates `+`/`%XX` but the decoded value
   feeds `Token.verify`; a forged token fails the constant-time compare.
3. Identity-name field in `details` of the 403 body and in audit lines
   comes from `id.name` (literal `"local"` from `resolveLocal`) — not
   from the request. The token cannot make the daemon log a different
   identity.
4. Capability strings live only in `.stako/config.toml` /
   `config.local.toml`, both on the local filesystem. There is no
   network path by which a caller can add or modify capabilities.

### Implicit-* fallback engaged (no [identity.local] in config files)
1. `policy.resolveLocal` calls `cfg.findIdentity("local")`
   (config.zig:43) → `null`.
2. Returns `{ name = "local", explicitly_declared = false, entry = null }`.
3. In `policy.evaluate`, after the null-identity check, line 164:
   `if (!id.explicitly_declared) return .{ .allow = {} };`
4. Every action allowed without further inspection.

This path is reachable in two practical situations:
- Pre-M10 deployments that never ran `stako init` against the M10
  schema (no `config.local.toml` containing `[identity.local]`).
- Manual configs that omit `[identity.local]` from both committed and
  local files.

After `stako init` (writeConfigLocal at init.zig:429-433), the local
layer always writes `[identity.local] capabilities = ["*"]`, so a fresh
v1 install lands on the *explicit* `"*"` path, not the implicit
fallback. The implicit-`*` path is therefore a narrow back-compat
shim, not the default for new users.

## Scope-string parser

The parser is `matchesProviderCapability` (policy.zig:195) and
`matchesStackCapability` (policy.zig:202), called from
`policy.evaluate` (policy.zig:168).

Accepted forms:
- `*` — matched literally as the cap loop's first check at
  policy.zig:169. Allows every action.
- `stack.create` — matched literally inside the
  `.create_stack` arm at policy.zig:172. Only enables stack creation.
- `stack.<name>.<verb>` — matched by `matchesStackCapability` at
  policy.zig:202-212. Both pieces can be `*`. Verb must be one of
  `append|insert|retry|cancel|supersede|pause|resume|config` (mapped
  from `Action.stackVerb` at policy.zig:84-96).
- `stack.*.<verb>` — `cap_stack = "*"` matches any stack name.
- `stack.<name>.*` — `cap_verb = "*"` matches any stack verb.
- `stack.*.*` — wildcards both axes (still does NOT allow `create_stack`;
  that requires `stack.create` or the global `*`).
- `provider.<name>` — matched by `matchesProviderCapability`. `<name>`
  may be `*` or a concrete provider slug.
- `provider.*` — matches any provider on `dispatch_harness`.

Silently ignored (forward-compat, not an error):
- Any unrecognized prefix, e.g. `future.foo.bar`, `stacks.foo.append`
  (note the trailing `s` — different prefix). Tested at policy.zig:383.

Rejected forms (parser yields no match; falls through to default-deny):
- `stack.<name>` with no `.<verb>` (no inner dot in `rest` →
  `lastIndexOfScalar` returns null at policy.zig:206).
- `stack.<name>.<verb>.<extra>` — actually NOT rejected. The parser
  uses `lastIndexOfScalar(u8, rest, '.')`, so `stack.demo.foo.append`
  would parse as `cap_stack = "demo.foo"`, `cap_verb = "append"`.
  Stack names are constrained by `storage.isValidStackName` to
  `[a-z0-9_-]+`, so `demo.foo` never matches a real stack and the
  effect is "this cap matches nothing" — fail-closed. This is a parser
  *quirk* (no rejection of malformed forms) but not a security hole.
- Case-sensitive throughout: `Stack.demo.append` will not match because
  `startsWith(u8, cap, "stack.")` is byte-exact. Same for `Provider.*`
  and `STACK.CREATE`. Consistent with the design's lowercase schema.
- Empty strings, `stack.`, `stack..append`, `stack.demo.`, `provider.` —
  all fall through to no-match because either the prefix check fails,
  the dot scan misses, or one of the two sides is empty (and empty
  never equals a real stack/verb/provider). Fail-closed.

Case-sensitivity surprise: nothing about the schema is documented as
case-sensitive in the schema doc-comment (policy.zig:8-22). A user who
writes `stack.Demo.append` in their TOML will silently get no matches.
Minor finding.

## Authorization truth table

(Computed by reading `policy.evaluate` against every Action; ✓ = allow,
✗ = capability_denied. The "no identity" column is `identity_required`
for every action; not listed below for clarity.)

| Cap pattern         | create_stack | append/insert/retry/cancel/supersede on stack X | pause/resume/config on stack X | dispatch to provider Y |
|---------------------|--------------|--------------------------------------------------|--------------------------------|------------------------|
| (undeclared local)  | ✓ (implicit-*) | ✓ | ✓ | ✓ |
| `*`                 | ✓ | ✓ | ✓ | ✓ |
| `stack.create`      | ✓ | ✗ | ✗ | ✗ |
| `stack.X.append`    | ✗ | ✓ append only on X; ✗ other verbs/stacks | ✗ | ✗ |
| `stack.*.append`    | ✗ | ✓ append on any stack; ✗ other verbs | ✗ | ✗ |
| `stack.X.*`         | ✗ | ✓ any verb on X; ✗ other stacks | ✓ pause/resume/config on X | ✗ |
| `stack.*.*`         | ✗ | ✓ any verb on any stack | ✓ pause/resume/config any stack | ✗ |
| `provider.Y`        | ✗ | ✗ | ✗ | ✓ Y only |
| `provider.*`        | ✗ | ✗ | ✗ | ✓ any provider |
| `[]` (empty list)   | ✗ | ✗ | ✗ | ✗ |
| `["future.x"]`      | ✗ | ✗ | ✗ | ✗ |

Plan reference: the design (`todos/design_authorization.md`) lists
identity types and the abstract capability axes (stack reads,
mutations, provider routing, daemon control) but does not commit to a
single literal truth table. The implementation table matches every
documented bullet:
- Per-stack mutation gating (each mutation route has a distinct verb).
- Provider routing as a capability, not an ambient global.
- Default-deny on no-match.
- `*` literal as full access.
- `stack.create` as the global create gate (per the implementation's
  policy.zig:9-16 schema doc).

Observation: there is no separate `read` capability — the milestone-10
read endpoints (`/stacks`, `/stacks/<name>`, etc.) are not gated by
`isMutationRoute` and so flow past the auth check entirely. The plan
says "Local CLI/web uses the local token and maps to `identity.local`
by default" and lists *sensitive* actions; reads are intentionally
ungated in v1 since the daemon is loopback-only. Noted as a coverage
observation, not a finding.

## Implicit-* fallback

Engages precisely when `cfg.findIdentity("local")` returns null —
i.e., no `[identity.local]` table exists in either layer of
`.stako/config.toml` or `.stako/config.local.toml`. Confirmed at
`policy.resolveLocal` (policy.zig:144-149) and
`policy.evaluate` (policy.zig:164).

Engaged for: pre-M10 deployments that never wrote an identity block,
plus any user who deletes `[identity.local]` from both layers. Tested
end-to-end at `test/authorization_tests.zig:363-400` and unit-tested
at policy.zig:235-245.

Safety analysis:
- The fallback only grants access when **the user has already
  successfully verified the local bearer token** (verifyAuth returned
  true at daemon.zig:681). The token sits under `.stako/local_token`
  with 0600 perms (per the M3 design) and the daemon binds loopback
  only. So implicit-`*` does not widen the trust boundary beyond what
  M3-M9 already had.
- Backwards-compat scope is narrow: `init` always writes
  `[identity.local]` to `config.local.toml` (init.zig:429-433), so
  every freshly-initialized notes root lands on the **explicit `"*"`**
  path, not the implicit path. Users would have to actively delete the
  block to engage the fallback.
- The flag carries through as `explicitly_declared = false` and is the
  ONLY discriminator: `evaluate` consults nothing else before
  returning `.allow`. There is no second-order path that could leak.
- The fallback never opens MCP/non-local identities (those resolve via
  paths that have not shipped — `resolveLocal` is the only resolver in
  v1).

Verdict: **safe** as a backwards-compat shim. It is narrowly scoped
(local-token-only, single identity name, full file-system control
required). I recommend a follow-up to log a one-time warning when the
fallback engages and/or to plan a deprecation window once M10 has
shipped widely — see Minor below.

## Fail-closed analysis

Every error path in `policy.evaluate` returns `.capability_denied` or
`.identity_required`, never `.allow`:

- Null identity → `.identity_required` (policy.zig:159).
- `dispatch_harness` with non-`.provider` target (mismatch) →
  `.capability_denied` (policy.zig:177).
- Non-create / non-dispatch action with a null `stackVerb` (no Action
  enum value currently exercises this since `create_stack` and
  `dispatch_harness` are filtered earlier, but defensive code at
  policy.zig:182 returns `.capability_denied` if reached).
- Non-create / non-dispatch action with a non-stack target →
  `.capability_denied` (policy.zig:186).
- Cap loop exhausted with no match → `.capability_denied`
  (policy.zig:192).
- Capability string with bad shape (`startsWith` fails, `lastIndexOfScalar`
  returns null, empty piece, unknown prefix) → match function returns
  false → loop continues → eventual `.capability_denied`.

Daemon-side error paths preserve fail-closed semantics:
- Token verify failure → `respondError(.identity_required, ...)`
  (daemon.zig:689, 696).
- `verifyAuthFormBody` returns null on any miss (wrong content-type,
  missing `_token`, decode error, verify mismatch) — handler treats it
  as auth-failure (daemon.zig:692-698).
- `routeToPolicyAction` returning null falls back to `.append_item`
  for the audit-line action label (daemon.zig:688, 695). The null case
  cannot happen because the call site is gated by `isMutationRoute`,
  but the fallback choice is benign (no logic depends on it).
- Audit-write failures inside `auditDenied` are swallowed
  (daemon.zig:974) so a stuck audit-file never converts a 401/403
  into a 500. The HTTP denial still goes out.
- Runtime callback `runtimePolicyCheck` (daemon.zig:922-928): if
  `ctx` is null, returns true (allow). This null branch is
  unreachable in practice — the daemon passes `@ptrCast(self)` at
  daemon.zig:281, which is never null. But the *defensive* default
  here is **allow** rather than deny. Important finding.

Decision rendering in daemon.zig:741 includes an `unreachable` for the
`identity_required` arm — defensible because the bearer-token check
already returned 401 above, so the `evaluate` call cannot see a null
identity. If a future refactor calls `evaluate` with a null identity
inside this switch, the `unreachable` becomes a crash; that is
fail-loud, which is acceptable.

`cap_buf` formatting (daemon.zig:735) has a `catch "stack.?.?"`
fallback for a too-small fixed buffer; the fallback is *informational*
only — the 403 still ships and the policy decision is already made.

## Blocking
**None.** Every authorization decision flows through `policy.evaluate`,
every error path returns deny, the bearer-token verification is
mandatory before the policy check on mutation routes, and there is no
network path by which a caller can forge an identity name. The
implicit-`*` fallback is narrow and gated by token verification.

## Important

1. **`runtimePolicyCheck` defaults to allow on null ctx**
   (`src/daemon.zig:922-928`). The function checks
   `const self_any = ctx orelse return true;` — if the context pointer
   is null, dispatch is *allowed*. Today the daemon installs
   `@ptrCast(self)` (line 281) which is never null, but the
   defensive default for an authorization callback should be **deny,
   not allow**. Recommend `return false;` plus an assertion/log if
   the context is ever observed null. Fail-closed default for the
   callback type matters even though the current caller never trips
   it.

2. **Dispatch denial audit shape**
   (`src/runtime.zig:235-247` → `src/mutation_queue.zig:340-349`).
   When the routing preflight returns `.blocked = "capability_denied"`,
   the daemon writes one audit line:
   `action=dispatch_harness, outcome=allowed, target=stack/X/item/Y`
   with no `reason` field and no `details` carrying the blocked reason.
   The plan's step 5 says "Record allowed and **denied** sensitive
   actions" — but the dispatch denial is recorded as `allowed`
   (because the *blocked-transition mutation* itself succeeded). The
   only signal that the dispatch was denied lives in the item's
   `blocked_reason` field on disk, not in the audit log. Recommend
   emitting a parallel `auditDenied`-style entry with
   `outcome=denied, reason=capability_denied` so the audit log is the
   single source of truth for "this identity was denied dispatch to
   provider X at time T". Mutation-side denials (e.g.
   `POST /stacks/foo/items`) already do this correctly at
   daemon.zig:714.

3. **No end-to-end test of the runtime dispatch policy callback**.
   `test/authorization_tests.zig:435-454` documents this gap in its
   own comment: "Drive the policy callback directly, since wiring a
   full supervisor for this case would require a real fixture stack."
   The test only exercises `policy.evaluate` against a `provider.*`
   capability; it does not verify that
   (a) the daemon installs `runtimePolicyCheck` at the right point
   (daemon.zig:280-282) and
   (b) the supervisor actually invokes it during a routing tick
   (runtime.zig:411-422) and
   (c) the denied item lands with `blocked_reason = "capability_denied"`.
   Recommend extending the runtime test suite (`test/runtime_tests.zig`)
   with a fake-harness path that queues an item routed to a provider
   the local identity lacks, then asserts the item transitions to
   `blocked` with the expected reason. The integration plumbing is
   load-bearing and currently untested as a wired system.

## Minor

1. **Case-sensitivity of capability strings is undocumented**
   (`src/policy.zig:8-22`). The schema doc-comment shows lowercase
   tokens but never says "case sensitive". `stack.Demo.append` will
   silently match nothing because `startsWith(u8, cap, "stack.")` is
   byte-exact and `eql` is byte-exact. Add a sentence to the schema
   comment.

2. **Malformed capability strings are silently ignored rather than
   logged**. `stack.demo.append.extra` (extra dot), `stacks.demo.append`
   (plural prefix), and `Stack.demo.append` (wrong case) all fall
   through to "matches nothing". This is the intended forward-compat
   behavior (policy.zig:20-22 documents it for forward-compat). But
   for a user mistyping `stacks.default.append` and getting locked out
   with no clue, a one-time "unrecognized capability slug" warning at
   daemon-startup would shorten the debug loop. Optional.

3. **`cap_buf` truncation fallback yields `stack.?.?`**
   (`src/daemon.zig:735`). A 256-byte buffer plus an extremely long
   stack name yields a generic error string in the 403 details. This
   is non-load-bearing (the policy decision is already made), but the
   fallback should at least include the verb so the client can react.
   Trivial.

4. **`auditDenied` target buffer also fixed at 256**
   (`src/daemon.zig:960-967`). A stack name + item id totaling 240+
   bytes degrades the audit-log target to literal `"daemon"`. Stack
   names are bounded by `isValidStackName` (no explicit length limit
   exists, but the filesystem will reject paths longer than
   `NAME_MAX`). Realistically not an issue; flag for awareness.

5. **Implicit-`*` fallback has no deprecation/warning path**. The
   shim is intentional and well-documented, but a user who removed
   `[identity.local]` (e.g., during a config refactor) silently
   re-engages full access. Recommend emitting a single
   `[warn]`-level log line on the first request that engages the
   implicit fallback (or at daemon startup if neither layer carries
   `[identity.local]`) so the operator notices.

6. **`Action.stackVerb` and the cap-rendering switch in daemon.zig:723-733
   duplicate the verb table**. Two separate enums-to-string maps for
   the same set of (action → verb) edges. If a new action is added,
   both must change. Tiny DRY/KISS nit.

7. **`policy.evaluate` is O(scopes) per call** — fine for the v1
   single-identity, ~10-cap-typical workload. No caching, no
   pre-parsing. Memory pressure is zero because the cap strings live
   in `Config.arena` for the daemon's lifetime. Good.

## Coverage gaps

1. **No end-to-end test of `runtimePolicyCheck`** — see Important #3.
   The runtime hook is the only path that enforces `provider.X` for
   live dispatch; today it has only a direct-call unit test.

2. **No test for `[identity.local]` declared without a `capabilities`
   key**. `e.capabilities == null` → `caps = &.{}` (policy.zig:166)
   → every action denied. This is the right behavior (fail-closed)
   but is uncovered. Add a test that seeds
   `[identity.local]\ntype = "user"\n` (no `capabilities`) and
   asserts an `append_item` is denied.

3. **No test for capability strings with `*` in a non-supported
   position**, e.g. `"*.append"` (no `stack.` prefix), `"stack.*"`
   (missing verb), `"*."` (degenerate). All fall through to
   default-deny in the source today; covered implicitly by "unknown
   slugs ignored" but not explicitly enumerated.

4. **No test for the form-body auth path producing the canonical
   denial body**. M9 tests cover the form-body auth path for *valid*
   tokens; M10 should cover form-body with `[identity.local]
   capabilities = []` to verify the 403 JSON shape matches the
   JSON-bearer path.

5. **No test for a stack name containing only-illegal characters
   passing through to the policy evaluator** — actually `route` calls
   `matchRoute` which yields `m.stack = "<illegal>"` and the policy
   evaluator runs against it. The downstream handler then
   `isValidStackName`-rejects with 400 anyway, but the policy
   evaluator receives the illegal name first. Confirm this is
   intentional (it is — early auth/policy is by design) and add a
   test.

6. **No test that a denied mutation leaves zero git activity**. The
   existing "no item directory was created" test (line 222-229) is
   filesystem-only. If a future change accidentally pushes a denied
   mutation through the queue before checking policy, a git commit
   would land. Add a test that asserts `git log --oneline` is empty
   after a denied mutation against a real (M2-style) repo.

## Strengths

1. **Single chokepoint**. Every mutation request flows through the
   `if (isMutationRoute(m.route))` block at daemon.zig:680-747, which
   is the only place that calls `policy.evaluate`. There is no
   secondary "skip the policy for this special case" path.

2. **Action-to-verb mapping is centralized** in `Action.stackVerb`
   (policy.zig:84-96). Adding a new mutation action requires touching
   the policy module and the daemon, but the mapping itself is
   data-driven inside `policy.zig`.

3. **`evaluate` does not allocate**. No heap, no error union. Returns
   a tagged enum. Trivially correct under OOM.

4. **`Decision` deliberately omits the per-call capability slug**
   (policy.zig:115-120 comment). The author identified the dangling-
   slice trap and pushed slug rendering to the caller. Good design.

5. **Cap-string parser is two short functions** (12 + 11 lines).
   Easy to audit. No regex, no DSL, no precompilation. Reads exactly
   like its documentation.

6. **Identity name is hardcoded in `resolveLocal`**. There is no
   request-supplied "claim this identity" path in v1. The bearer
   token is the only authenticator and the identity name is always
   `"local"`, eliminating the forge-an-identity-name class of bug.

7. **Fail-closed defaults are pervasive**. Empty cap list → deny.
   Unknown slug → deny. Wrong target shape → deny. Loop falls off
   the end → deny. Only the documented implicit-`*` shim allows
   without a matching cap.

8. **Backwards-compat path is explicit and tested**. The
   `explicitly_declared` flag is the single discriminator for the
   shim, the integration test at authorization_tests.zig:363-400
   nails the no-identity-block scenario, and the unit test at
   policy.zig:235-245 covers the policy-level case.

9. **`init` writes the explicit `[identity.local] capabilities = ["*"]`
   block** (init.zig:429-433). New deployments never engage the
   implicit-`*` path; the shim only catches legacy roots and manually
   stripped configs.

10. **Audit-log denial path uses the same vocabulary as HTTP errors**.
    Reason `capability_denied` / `identity_required` is shared between
    `errors.Code` and the `auditDenied` writer. Per plan step 5,
    verified at daemon.zig:688, 714 and at the integration tests.
