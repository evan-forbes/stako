# Design MCP Server (Follow-Up)

## Scope

The daemon may later host an MCP server so Claude Code, Codex, and similar harnesses can read and mutate stacks as tools. MCP is deferred out of the core implementation ladder; `implement_mcp_server.md` tracks the follow-up. MCP-connected agents are first-class identities in the authorization model. The MCP surface should tunnel over the same single HTTP port as the rest of the daemon when implemented.

## Decided

- The daemon implements an MCP server, exposing stack operations as tools, after core HTTP/CLI and authorization are stable.
- Transport: MCP-over-HTTP (Streamable HTTP transport per current MCP spec). No stdio transport in the first MCP follow-up — the daemon is a persistent process, not a per-invocation child.
- Same single port as the JSON API and HTML pages; MCP lives under a dedicated path prefix (e.g. `/mcp`).
- MCP-connected agents authenticate as named identities; each identity carries a capability list per `design_authorization.md`.
- Tool implementations call the daemon's internal mutation API, the same path the HTTP and CLI clients use. No parallel logic.

## Tool Surface (v1)

| Tool | Purpose |
|---|---|
| `list_stacks` | Enumerate stacks visible to this identity |
| `read_stack` | Stack metadata + ordered item list |
| `read_item` | Full item: `meta.toml` fields, prompt body, transcript pointer |
| `append_item` | Add a new item to the end of a stack |
| `insert_item` | Insert an item before/after a referenced ID |
| `retry_item` | Transition a blocked item back to queued (subject to state machine rules) |
| `cancel_item` | Cancel a non-terminal item (subject to state machine rules) |
| `supersede_item` | Mark an item superseded by a replacement (subject to state machine rules) |
| `pause_stack` / `resume_stack` | Stack-level pause toggle |

Notably absent in v1:

- No `delete_item` (use `canceled` / `superseded` instead — preserves history).
- No `edit_item` (mutations are status-only; to change a prompt, supersede with a new item).
- No daemon-control tools (start/stop/restart). Daemon lifecycle is the human operator's job.

## Identity Model

MCP clients connect with an identity assertion (config-file mapping for v1; OAuth-style flows are backlog). Identities are declared in `config.toml` (or `config.local.toml` for machine-specific ones) — see `design_init_and_layout.md` for the canonical schema and load-order rules.

Capability strings follow `stack.<name>.<action>` shape. Action values: `read`, `append`, `insert`, `status`, `pause` (covers pause and resume), and `provider.<provider>` for routing-target restrictions.

## To Decide

- Exact MCP transport endpoints — confirm against the latest Streamable HTTP transport spec.
- Session lifecycle: do MCP sessions persist across browser-style connections, or is each connection ephemeral.

### Resolved (was: To Decide)

- **`list_tools` filtering by identity**: yes — only return tools the calling identity has capability for. Hides mutation tools from read-only identities.
- **`read_item` transcript handling**: metadata and prompt body are inline; transcript is a pointer URL. Agents fetch it separately if they need it. Prevents huge MCP responses for long-running items.
- **Error shape**: see `design_errors_and_audit.md`. Capability denials and validation errors are distinguishable from daemon-internal errors via a code prefix in the text block plus a structured resource block.

## Implementation Plan

1. Read the current MCP spec; pin a target spec version.
2. Implement MCP handshake + `list_tools` against a static identity list.
3. Implement the read tools (`list_stacks`, `read_stack`, `read_item`).
4. Implement the mutation tools, all routed through the daemon's single-writer queue.
5. Wire capability checks into each tool entry point (same check as the HTTP API).
6. Add audit-log entries for every MCP-driven mutation.
7. Add an integration test where a real Claude Code instance connects and appends an item.

## Acceptance Criteria

- A spec-compliant MCP server is reachable on the daemon's HTTP port.
- Claude Code and Codex can each connect, list tools, read stacks, and mutate stacks within their capability list.
- Identities with no mutation capability cannot mutate (verified by tests).
- All MCP-driven mutations appear in version-control commits like any other mutation.
- The tool set advertised to an identity matches its allowed capabilities.

## Dependencies

- `design_daemon.md`
- `design_authorization.md`
- `design_stack_item_format.md`
- `design_init_and_layout.md` (canonical identity/capability config schema)
- `design_errors_and_audit.md` (MCP error shape, audit log for mutations)
- `implement_stacks.md` (mutation API)
- `design_version_control.md` (commit behavior for MCP-driven changes)
