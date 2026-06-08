# P2P Bug Finder Prompts

These prompt bodies are meant to be used as Stako thread defaults or node
`use` bodies when auditing pre-production P2P and RPC code.

Suggested graph:

1. `entrypoint_researcher.md` runs first and writes
   `security_audit/entrypoints.jsonl`.
2. One or more `trace_entrypoint.md` nodes each take one entrypoint record or
   entrypoint id and write a trace plus `security_audit/trace_findings.jsonl`.
3. `oom_finder.md` can run after entrypoint discovery or in parallel with
   tracing. It writes `security_audit/allocation_sites.jsonl`.
4. `vulnerability_finder.md` reads the accumulated artifacts and writes
   `security_audit/candidate_vulnerabilities.jsonl` plus a concise Markdown
   triage.
5. One or more `replicate_finding.md` nodes each take one candidate and attempt
   a production-shaped reproduction, usually integration or end-to-end where the
   repo supports it.

The prompts intentionally separate inventory from analysis. The first pass
should be broad and mechanical; later agents can then divide work by stable
entrypoint id without rediscovering the surface area.

Use `append_jsonl.py` when possible:

```sh
python3 /home/evan/src/evan-forbes/stako.large-refactor/prompts/bug_finder/append_jsonl.py \
  --path security_audit/entrypoints.jsonl \
  --kind entrypoint \
  --id p2p-blocksync-getblocks \
  --field surface=p2p \
  --field file=src/net/blocksync.rs \
  --field handler=handle_get_blocks \
  --note "Inbound peer-controlled request path."
```

The helper keeps the format flexible: pass repeated `--field key=value`, repeated
`--note`, or a complete object with `--json '{"key": "value"}'`.
