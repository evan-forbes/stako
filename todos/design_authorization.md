# Design Authorization

## Original Todo

- Define the agent capability model.
- Restrict agent actions with code-level permissions.
- Add container-level isolation.
- Keep auth and containers modular but first class.

## Design Context

Even with the daemon bound to loopback in v1, mutating requests need a local token, and future non-user callers need authorization. MCP-connected agents, scheduled jobs, and other automation are distinct identities calling the daemon's API, and they should not all have full access to every stack and every provider.

Container isolation is **out of scope for v1** — it is a meaningful project of its own and is not required while the daemon is local-only. It moves to backlog when public exposure does. The capability model at the API layer is in scope now.

## Research Before Implementation

- Enumerate the capabilities the daemon currently exposes:
  - Stack reads (per stack name).
  - Stack mutations (append, insert, retry, cancel, supersede, pause, resume).
  - Provider routing (per provider, per model).
  - Daemon control (start/stop/restart).
- Define identity types: the local user, named future MCP-connected agents, scheduled jobs.
- Define how each identity authenticates to the loopback API. (Loopback alone is not identity — multiple agents share it.)
- Define credential scoping: provider tokens are not ambient globals. An identity must hold the relevant capability to dispatch through a given provider.
- Define audit log requirements for sensitive actions (provider calls, stack mutations, status changes).
- Define how authorization failures appear in CLI output, web view, and stack logs.

## Planning Notes

- The capability model is enforced by the daemon at the API layer; clients are not trusted.
- Routing must validate the requested provider/model target against the calling identity's capabilities.
- Provider access is a capability, not an ambient global credential.
- Stack item metadata may declare requested capabilities, but runtime policy at the daemon makes the final decision.
- Container isolation is deferred (backlog). Do not design the v1 capability model in a way that depends on containers existing.

## Implementation Plan Draft

- Define a capability schema for identities, stacks, and providers.
- Implement a policy evaluator that resolves a request (identity + action + target) to allow/deny.
- Add policy checks on every mutation endpoint and every provider dispatch.
- Add an audit log for denied and allowed sensitive actions.
- Add tests for denied stack mutations, denied provider routing, and least-privilege allowed flows.

## Acceptance Criteria

- Capability model covers all daemon-exposed actions in v1.
- Stack mutation and provider dispatch are denied by default unless capability policy allows them.
- Provider credentials are not exposed to identities lacking the capability.
- Auth decisions are logged.

## Dependencies

- `design_daemon.md`
- `route_stack_items.md`
- `research_provider_sign_in.md`
