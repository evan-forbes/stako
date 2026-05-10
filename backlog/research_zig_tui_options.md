# Research Zig TUI Options

## Original Todo

- Research fast, robust, efficient, and smooth Zig TUI libraries.
- Review existing Zig TUI applications such as Flow and Zig git-management tools.
- Choose the best generic-usecase Zig TUI library.
- Record the selected library as an implementation decision in `high_level_implementation.md`.

## Design Context

Organo should provide a highly modular and minimal TUI harness similar to Codex or Claude Code, but with deeper customization for project-specific agents, stacks, and notes workflows. A TypeScript implementation may be faster to bootstrap from existing tools, but the current design treats dependency risk as a serious concern for company-critical usage.

Zig is the preferred candidate for the core harness and TUI if the ecosystem can support a smooth enough interface.

## Research Before Implementation

- List current Zig TUI libraries and terminal UI frameworks.
- Identify which libraries support keyboard-heavy workflows, alternate screen mode, mouse events, resize handling, scrollable panes, forms, split views, command palettes, and streaming logs.
- Review real Zig TUI applications for smoothness, architecture, maintenance health, and portability.
- Specifically inspect Flow and any known Zig git-management TUIs.
- Check how each candidate handles terminal rendering performance, input latency, Unicode width, color themes, and shell integration.
- Check whether the library can support a Codex-like layout: transcript, prompt box, sidebar/status area, stack queue, provider/model selector, and action menus.
- Check dependency footprint and whether the library itself pulls in risky or unstable dependencies.
- Compare the effort of using a Zig TUI library against building the first prototype in TypeScript and later porting to Zig.

## Planning Notes

- The TUI does not need to own business logic. It should be a thin surface over core Organo services.
- The core should expose stable commands/events so a future non-TUI client can reuse the same behavior.
- The TUI library decision should happen before committing to long-lived UI architecture, but it should not block documenting the stack, auth, indexing, or provider contracts.

## Implementation Plan Draft

- Create a research matrix with candidates, links, maintenance status, feature support, risks, and example apps.
- Build a small spike for the top one or two candidates.
- Spike must render a transcript pane, queue pane, text input, status footer, and provider/model selector.
- Test terminal resize, long text wrapping, keyboard shortcuts, streaming updates, and focus movement.
- Decide whether the first Organo TUI should be Zig-native, TypeScript-first, or a CLI-only core with TUI delayed.
- Record the decision in `high_level_implementation.md`.

## Acceptance Criteria

- A selected TUI library or an explicit decision to defer the TUI library choice.
- Documented rationale that accounts for performance, robustness, dependency risk, maintainability, and feature fit.
- A minimal spike proving the selected option can support the expected Organo layout.
- `high_level_implementation.md` updated with the decision.

## Dependencies

- The Pi-level functionality plan should inform required TUI features.
- Stack runtime requirements should inform queue and routing UI needs.
- Provider routing requirements should inform provider/model selector needs.
