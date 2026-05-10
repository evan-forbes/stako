# 08 — Provider Status and Gemini Bonus

## Goal

Make provider availability visible and predictable: Claude and Codex get status probing, clear auth diagnostics, and official-CLI/API-key credential reuse. Gemini is attempted as a bonus adapter without blocking the required Claude/Codex runtime.

## Design Reference

- `../todos/research_provider_sign_in.md`
- `../todos/design_execution_harness.md`
- `../todos/design_stack_config.md`
- `../todos/design_stack_item_format.md`
- `../todos/design_runtime_loop.md`
- `../todos/implement_cli_client.md`

## Steps

1. Complete the provider research matrix for Anthropic, OpenAI/Codex, and Google/Gemini:
   - Supported official CLI auth mechanisms.
   - API-key fallback.
   - CLI credential reuse constraints.
   - Subscription compatibility.
   - ToS or practical rejection notes.
2. Add a provider status interface:
   - `auth_status()`
   - `credential_env()`
   - `capabilities()`
   - `login_hint()` for the exact official command or config needed when signed out.
3. Add CLI auth/status commands with short aliases:
   - `organo auth status` / `organo a st`
   - `organo auth <provider>` / `organo a <provider>`
   - `organo auth signout <provider>` / `organo a out <provider>` only where signout is safe and provider-supported.
4. Implement Anthropic/Claude status:
   - Prefer existing Claude Code CLI auth detection.
   - API-key fallback is acceptable.
   - If daemon-owned subscription auth is infeasible, document why and keep existing-CLI credential reuse as the supported mode.
5. Implement OpenAI/Codex status:
   - Prefer existing Codex CLI auth detection.
   - API-key fallback is acceptable.
   - Existing Codex CLI auth reuse is acceptable if daemon-owned auth is brittle.
6. Turn on provider-aware routing diagnostics:
   - Signed-out provider -> item `blocked` with `auth_missing`.
   - Disabled adapter -> `harness_unavailable`.
   - Unsupported model/capability -> `model_unsupported` or `harness_unsupported_capability`.
7. Attempt Gemini adapter and auth as a bonus:
   - Probe `gemini --output-format stream-json -p "ok"`.
   - If the installed CLI supports structured output, implement `parse_line`.
   - If not, mark Gemini disabled and surface a clear status in `organo auth status`.
   - Gemini failing does not block milestone acceptance for Claude/Codex.
8. Revisit `compact` and `clear` only if Claude/Codex resume behavior is stable:
   - `clear` is daemon-level: complete immediately and force the next item fresh.
   - `compact` requires `continuity = "chain"` and a prior session id.
   - Unsupported adapters block with a canonical reason.
   - If this threatens the milestone, defer it explicitly rather than half-implementing.
9. Tests:
   - Mock provider-status flows in CI.
   - Real Claude and Codex credential/status tests gated behind real-credential flags.
   - Gemini test is advisory/optional until promoted.
   - Routing preflight reason codes are pinned in tests.

## Acceptance

- `organo auth status` accurately reports Claude and Codex availability.
- Claude and Codex routed items use one credential-resolution path instead of hidden ad-hoc logic.
- Gemini is either working end-to-end or explicitly disabled with a clear reason; it is not a source of ambiguous runtime failure.
- Provider-specific code stays behind provider/adapter interfaces; session management and transcript handling remain shared.
- Daemon-owned OAuth/subscription token storage is not required for v1.

## Out of Scope

- Per-identity provider scoping. That lands in milestone 10.
- Daemon-owned OAuth/PKCE unless a provider exposes a stable, cheap flow.
- Background token refresh unless a provider forces it.
- Making Gemini mandatory.
- Native non-subprocess harnesses.
