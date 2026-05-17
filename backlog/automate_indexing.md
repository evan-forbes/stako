# Automate Indexing

## Original Todo

- Preserve a manual indexing command.
- Add automatic indexing for a single notes repository.
- Evaluate triggers such as file save events, Neovim macros, scheduled jobs, and agent actions.
- Ensure indexed links become normal Markdown links.

## Design Context

Indexing should make the note graph navigable without constant manual maintenance. Stako should preserve manual indexing for explicit control, but automatic indexing should become the default path.

The indexed output must remain portable Markdown. Source notation can be Stako-specific, but generated links should resolve as normal Markdown links.

## Research Before Implementation

- Identify every generated index artifact Stako needs: tag pages, backlinks, project indexes, note indexes, stack indexes, or search metadata.
- Determine whether indexing should be incremental, full-rebuild, or hybrid.
- Benchmark expected repository sizes and acceptable indexing latency.
- Decide whether generated index files are committed, cached, or both.
- Research reliable file-save triggers across Neovim, filesystem watchers, scheduled jobs, and agent actions.
- Define conflict behavior if indexing runs while a user or agent is editing files.
- Define how indexing failure should surface in TUI, CLI, and editor workflows.

## Planning Notes

- Manual command should remain the recovery path.
- Automatic indexing should be idempotent.
- Indexing should be safe to run repeatedly and should avoid noisy commits when nothing changes.
- Agent-triggered indexing must go through authorization checks.
- Neovim integration should be able to request indexing without knowing indexing internals.

## Implementation Plan Draft

- Implement indexing as a core service with a stable command interface.
- Add a dry-run mode that reports changed index artifacts.
- Add a manual command for full repository indexing.
- Add incremental indexing once the generated artifacts and dependency graph are understood.
- Add file-save trigger support through Neovim integration.
- Add scheduled trigger support through a small runner.
- Add agent-triggered indexing through the capability model.
- Emit an indexing event that version-control automation can consume.

## Acceptance Criteria

- Manual indexing command works for the canonical notes repository.
- Automatic indexing can be triggered by at least one editor or filesystem path.
- Running indexing twice with no source changes produces no file changes.
- Generated links are normal Markdown links.
- Indexing can report success, no-op, and failure states.

## Dependencies

- Extracted `ligi` indexing behavior.
- Tag syntax decision.
- Project structure decision.
- Version-control automation for post-index commits.
- Auth design for agent-triggered indexing.
