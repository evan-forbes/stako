# Automate Version Control

## Original Todo

- Commit automatically after indexing.
- Commit after stack file additions or edits.
- Group directly related multi-file changes into one commit.

## Design Context

Version control should be automatic around meaningful note operations. Index regeneration, stack edits, project plan changes, and related multi-file updates should create coherent commits that preserve history without forcing the user to think about routine bookkeeping.

## Research Before Implementation

- Define which Stako operations should create commits automatically.
- Define which operations should never auto-commit without explicit confirmation.
- Decide how to group related file changes into a unit of work.
- Determine how to avoid committing unrelated user changes in a dirty working tree.
- Define behavior for merge conflicts, detached HEAD, untracked repos, missing Git, and remote sync failures.
- Decide whether commit messages should be generated from operation metadata, stack item metadata, or agent summaries.
- Determine how automated commits interact with sync providers.

## Planning Notes

- Commit grouping should follow a logical unit of work, not one commit per file.
- Automated commits need a staging boundary so unrelated work is not swept in.
- Stack changes are especially important because stack state is durable workflow state.
- Index commits should be skipped when indexing is a no-op.

## Implementation Plan Draft

- Create an internal version-control service with explicit file lists and operation metadata.
- Add a dry-run mode that shows what would be committed.
- Require callers to provide changed paths or an operation-scoped change manifest.
- Generate predictable commit messages by operation type.
- Add guardrails for dirty working trees.
- Integrate with indexing events and stack runtime events.
- Add tests for no-op commits, unrelated dirty files, grouped changes, and failure states.

## Acceptance Criteria

- Indexing can trigger an automated commit only when index files changed.
- Stack creation and stack edits can trigger coherent commits.
- Unrelated working-tree changes are not committed.
- Commit messages identify the Stako operation.
- Failures leave the working tree understandable and recoverable.

## Dependencies

- Indexing automation.
- Stack runtime.
- Project structure.
- Auth model if agents can trigger commits.
