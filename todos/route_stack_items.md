# Route Stack Items

## Original Todo

- Support routing stack items to a specific model, provider, or agent.
- Define stack item metadata for routing fields.
- Validate requested routing targets against auth, container policy, provider availability, and model capability.

## Design Context

Each stack item should be able to declare its execution target. The target may be a specific agent, a specific model, a specific provider, or a policy that lets Organo choose among compatible providers.

Routing is a cross-cutting feature. It depends on stack files, provider integrations, agent definitions, authorization, container policy, and the CLI/web surfaces that let a user inspect or override routing. TUI routing inspection is deferred.

## Research Before Implementation

- Define which routing forms are required:
  - Exact agent.
  - Exact provider.
  - Exact model.
  - Provider plus model.
  - Agent plus preferred provider/model.
  - Policy-based selection among compatible targets.
- Define provider metadata needed by the router: provider id, auth state, supported models, context windows, tool support, multimodal support, rate limits, cost/budget metadata, account-plan restrictions, and availability.
- Define agent metadata needed by the router: supported tools, required capabilities, preferred models, preferred providers, context requirements, container requirements, and denied providers or models.
- Define stack item metadata needed by the router: requested agent, requested provider, requested model, match policy (`exact` / `compatible` / `any`), required tools, required capabilities, max context, max budget, priority, timeout, and allowed execution environment.
- Determine how routing should behave when the requested provider is signed out, unavailable, blocked by policy, or missing the requested model.
- Determine whether `match = "compatible"` and `match = "any"` selection is automatic, user-confirmed, or forbidden by default.
- Define how routing failures should be recorded in stack state and version control.
- Define how routing decisions should appear in CLI, web, logs, and stack Markdown.

## Decisions To Make

- Whether `agent`, `provider`, and `model` are simple string ids or structured references.
- Routing metadata lives in `meta.toml` inside the per-item directory (decided in `design_stack_item_format.md`). What stays open: the exact field shape and whether agent/provider/model are simple strings or structured references.
- Whether user intent is strict by default. For example, `model: gpt-x` may mean "must use this model" or "prefer this model".
- Whether `match` policies are global, stack-level, item-level, or all three.
- Whether budget and context constraints are hard limits or routing preferences.
- Whether an agent can change its own routing metadata after creation.
- Whether routing decisions are committed as stack mutations or only logged as runtime state.

## Planning Notes

- The router should fail closed. If Organo cannot prove a target is allowed and available, the item should not run.
- Routing validation should happen before expensive context assembly.
- In v1, local-token callers use a full-access local identity, so provider availability can be checked during preflight. Once milestone-10 identities exist, capability denial should happen before revealing provider-specific credential details.
- A stack item routed to an agent still needs final model/provider resolution unless the agent definition fully specifies it.
- Provider/model routing should not bypass agent capability restrictions.
- Agent routing should not bypass provider account restrictions.

## Implementation Plan Draft

- Define a routing schema shared by stack items, agent definitions, and provider metadata.
- Define a routing resolution function that takes a stack item, stack context, agent registry, provider registry, auth policy, and container policy.
- Return a structured routing decision with selected agent, provider, model, tools, capabilities, limits, and fallback status.
- Add routing preflight validation before stack execution.
- Add clear failure reasons for unauthorized, unavailable, unsupported capability, insufficient context, over budget, and no compatible target.
- Add route inspection commands for the CLI. TUI commands wait for the TUI follow-up.
- Add tests for `match = "exact"`, `match = "compatible"`, `match = "any"`, denied provider access, denied model access, denied tool capability, and unavailable provider.
- Integrate routing decision output with stack logs and version-control commit metadata where appropriate.

## Acceptance Criteria

- A stack item can request a specific agent, provider, model, or compatible-provider policy.
- Routing decisions are deterministic for the same inputs.
- Unauthorized targets are rejected before execution.
- Unavailable providers or models produce clear blocked stack states.
- `match` policy behavior is explicit and test-covered for each value.
- The selected execution target is visible to the user before or during execution.
- Routing metadata lives in the per-item `meta.toml` and round-trips cleanly.

## Dependencies

- `design_stack_item_format.md`
- `research_provider_sign_in.md`
- `design_authorization.md`
- `design_daemon.md` (router lives in the daemon)
- `design_runtime_loop.md` (canonical preflight order and blocked reasons)
- `design_errors_and_audit.md` (blocked reason vocabulary)
- `implement_cli_client.md` (route inspection commands)
