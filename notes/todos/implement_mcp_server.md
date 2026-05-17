# Implement MCP Server (Follow-Up)

## Scope

Expose stack operations as MCP tools after the HTTP/CLI runtime and authorization layer are stable. MCP is not part of the core v1 implementation ladder.

## Preconditions

- Mutation queue and VCS commits are implemented.
- Local token and per-identity authorization are implemented.
- Error wrapper and audit-log writer are stable.

## Planned Surface

- `list_stacks`
- `read_stack`
- `read_item`
- `append_item`
- `insert_item`
- `retry_item`
- `cancel_item`
- `supersede_item`
- `pause_stack`
- `resume_stack`

## Rules

- Tool implementations call the same internal mutation API as HTTP/CLI.
- Tool listing is filtered by the calling identity's capabilities.
- Tool errors use the canonical MCP error envelope from `design_errors_and_audit.md`.
- MCP mutations produce the same commits and audit-log entries as HTTP mutations.

## Out of Scope

- OAuth-style MCP identity flows.
- Stdio transport.
- Delete/edit item tools.
