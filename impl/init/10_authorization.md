# 10 — Authorization

## Goal

Turn the local-token model into a capability-checked identity model for future MCP, scheduled jobs, and narrower local automation. The local user keeps full access by default.

## Design Reference

- `../todos/design_authorization.md`
- `../todos/design_errors_and_audit.md`
- `../todos/design_init_and_layout.md`

## Steps

1. Implement the capability schema parser for `config.toml` and `config.local.toml` identity entries.
2. Implement the policy evaluator: `(identity, action, target) -> allow | deny(reason)`.
3. Wire policy checks into:
   - Mutation endpoints.
   - Harness dispatch/provider routing.
   - Future non-local clients through a small middleware boundary.
4. Identity assertion:
   - Local CLI/web uses the local token and maps to `identity.local` by default.
   - Other identities are config-declared but not exposed over MCP until that follow-up ships.
5. Audit log:
   - Record allowed and denied sensitive actions.
   - Denials use the same reason code vocabulary as HTTP errors and blocked items.
6. Failure UX:
   - Capability denials use `capability_denied` (HTTP 403).
   - Missing identity/token uses `identity_required` (HTTP 401).
   - Routing denials set blocked reason `capability_denied`.
7. Tests:
   - Each mutation endpoint denied for an identity lacking the capability.
   - Routing to a provider the identity lacks blocks the item.
   - Local default `*` identity still works.
   - Denied calls leave no disk writes and add an audit entry.

## Acceptance

- Every sensitive action consults the policy evaluator.
- The local-user identity retains full access by default.
- Denials are visible in the audit log.
- The capability schema is documented and matches what the code accepts.

## Out of Scope

- MCP server.
- Container isolation.
- Capability inference from prompt content.
- Time-bound capabilities.
