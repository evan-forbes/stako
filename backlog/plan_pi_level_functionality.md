# Plan Pi-Level Functionality

## Original Todo

- Research `pi` functionality.
- Write a high-level plan for reaching comparable behavior.
- Design a minimal TUI harness similar to Codex or Claude Code.
- Store prompts and agent definitions alongside notes.

## Design Context

Stako should borrow useful ideas from `pi` while avoiding a large TypeScript dependency graph as the long-term foundation. The desired result is a minimal, modular, customizable agent harness that supports specific agents with low overhead.

Prompts and agent definitions should live in the notes repository with the rest of Stako state.

## Research Before Implementation

- Inventory `pi` features by workflow: chat, agent definitions, provider selection, model selection, tools, prompt storage, sessions, context loading, file operations, and stack-like behavior.
- Identify which features are essential for Stako and which are out of scope.
- Compare `pi` behavior with Codex and Claude Code style workflows.
- Determine how prompts and agent definitions should be represented as Markdown files.
- Identify required agent metadata: supported tools, preferred providers/models, context requirements, capability restrictions, budget/context limits, and routing hints.
- Determine how agents load notes as context without creating excessive overhead.
- Define session persistence and transcript storage requirements.

## Planning Notes

- The harness should be provider-agnostic.
- Agent configuration should be data in the notes repository, not hard-coded into the binary.
- The TUI should be a replaceable client over the harness.
- Stack routing needs agent definitions to expose enough metadata for matching and validation.

## Implementation Plan Draft

- Write a `pi` feature comparison document.
- Define Stako's minimum viable agent harness.
- Define Markdown schemas for prompts, agents, sessions, and transcripts.
- Define the provider/model/tool routing contract.
- Implement a CLI-first harness before deep TUI polish if that reduces risk.
- Add one sample agent definition and one sample prompt file.
- Add tests or fixtures proving that agent definitions can be loaded from the notes repository.

## Acceptance Criteria

- Clear list of `pi`-level features Stako will support.
- Clear list of deferred or rejected `pi` features.
- Agent and prompt file formats are documented.
- Agent metadata supports stack routing.
- A minimal harness can load an agent definition and execute a prompt through a provider integration.

## Dependencies

- Provider sign-in research.
- Authorization design.
- Stack runtime.
- Zig TUI decision.
