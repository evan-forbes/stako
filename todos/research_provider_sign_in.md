# Research Provider Status

## Original Todo

- Research how to sign into many model providers.
- Prefer using existing monthly plans where possible instead of pay-per-token APIs.
- Investigate provider restrictions.
- Study how other tools implement provider authentication.
- Ensure provider integrations expose enough information for stack routing.

## Design Context

Organo prefers using existing monthly subscriptions where the official CLI already supports them, while keeping pay-per-token API keys as a baseline fallback. Stack routing must be able to send individual items to a chosen provider, model, agent, or compatible-provider policy.

The core target list is narrow:

- **Anthropic / Claude Code**.
- **OpenAI / Codex CLI**.

Gemini is a bonus target: try it if the CLI exposes reliable structured output and auth behavior, but do not let it block Claude/Codex support.

Daemon-owned subscription auth is not required for v1. API-key auth remains a baseline fallback for any provider where official-CLI credential reuse is infeasible.

## Research Before Implementation

- For Anthropic, OpenAI/Codex, and optional Gemini, document:
  - Official CLI auth/status behavior.
  - Supported auth mechanisms only where they are documented and stable (OAuth, PKCE, browser session, device code).
  - Plan compatibility (which subscription tiers can drive non-first-party clients).
  - Endpoint shape used by the official CLI / first-party client.
  - Rate limits and account-plan restrictions.
  - Terms-of-service constraints around third-party clients.
- Study how `pi`, Claude Code, Codex CLI, and similar tools authenticate. Note which approaches are viable for organo and which are not.
- Decide where monthly-plan usage is technically and legally appropriate per provider. Document anything explicitly rejected.
- Decide credential resolution strategy per provider (official CLI reuse first, API-key fallback, daemon-owned storage only if stable and cheap).
- Define provider metadata needed for routing: provider id, account id, available models, context length, tool support, multimodal support, rate limits, estimated cost, auth state, and policy restrictions.
- Determine how provider health is checked before executing a stack item.

## Planning Notes

- Provider integrations should be modular.
- Routing should not assume every model is available through the same API shape.
- Provider status and credential resolution must integrate with authorization so credentials are not globally available to every agent.
- The router needs enough metadata to reject impossible or unauthorized routing requests before execution.
- Any provider mechanism that conflicts with provider rules should be documented as rejected.

## Implementation Plan Draft

- Create a provider capability matrix.
- Define a provider integration interface.
- Define a credential resolution interface.
- Define provider/model discovery metadata.
- Implement Claude and Codex status checks first to validate the interface.
- Add a routing preflight that checks provider availability, model availability, auth, capability requirements, and budget/context limits.
- Only add daemon-owned or nonstandard sign-in mechanisms after research confirms they are acceptable and maintainable.

## Acceptance Criteria

- Provider research matrix exists.
- Provider integration interface includes routing metadata.
- Auth model can restrict provider credential access.
- Claude and Codex can be detected or configured cleanly.
- Stack routing can validate provider/model availability before execution.

## Dependencies

- `design_authorization.md`
- `route_stack_items.md`
- `design_daemon.md` (provider dispatch lives in the daemon)
