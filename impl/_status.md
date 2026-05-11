# Milestone Execution Status

Tracks progress through the implement → review → fix loop for milestones 1–10.

**Toolchain:** Zig 0.15.2.

**Baseline commit:** initial design-docs commit + `zig init` scaffold (see `git log`).

| # | Plan | Implement SHA | Blocking found | Fix SHA | Unresolved | Deferred | Notes |
|---|---|---|---|---|---|---|---|
| 1 | 01_item_format.md | b613693 | 0 | — | 0 | 0 | 9 non-blocking; all 4 acceptance criteria MET |
| 2 | 02_init_and_layout.md | d6216e9 | 0 | — | 0 | 0 | 16 non-blocking; 59/59 tests; smoke-stack fixture deferred (M2 plan doesn't require it, 00 strategy doc inconsistency) |
| 3 | 03_daemon_skeleton.md | 46ac594 | 0 | — | 0 | 0 | 11 non-blocking; 103/103 tests; std.http.Server + hand router |
| 4 | 04_cli_read.md | 8137551 | 0 | — | 0 | 0 | initial impl had test hang (use-after-return in extractJsonStringArray); fixed in finalize pass; 135/135 tests, 13 non-blocking nits |
| 5 | 05_mutations_and_vcs.md | 886f9ff | 0 | — | 0 | 0 | 16 non-blocking; 172/172 tests; 5/6 acceptance fully MET, rollback-on-commit-failure partial |
| 6 | 06_runtime_core.md | e12ac69 | 1 | c2c76ae | 0 | 0 | blocker: daemon never started Supervisor; fix wired it into startWorker; 206/206 tests; 6 non-blocking remain |
| 7 | 07_claude_codex_adapters.md | 6f9af37 | 2 | b054686 | 0 | 0 | session_ended → [result] block was missing; fix wires it + 2 adapter [result] tests; 242/242 tests; 7 non-blocking remain |
| 8 | 08_provider_status_and_gemini.md | f39f3f8 | 0 | — | 0 | 0 | 7 non-blocking; 273/273 tests; Gemini scaffolded only (factory→null, documented in design_execution_harness.md) |
| 9 | 09_html_rendering.md | 558535f | 1 | c7992ef | 0 | 0 | blocker: step 6 browser mutation controls missing; fix wired pause/resume/cancel/retry + token in form; 301/301 tests |
| 10 | 10_authorization.md | 6ab036f | 0 | — | 0 | 0 | 7 non-blocking; 319/319 tests, no flakes; identity model parses [identity.<name>] from config.toml; backwards-compat implicit-* for undeclared local |
