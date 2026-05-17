# Extract Useful `ligi` Features

## Original Todo

- Identify the `ligi` features Stako should keep.
- Keep indexing, tags, inbox behavior if useful, and short CLI flags where they fit.
- Remove or avoid unnecessary commands.
- Avoid a user-facing `init` command if Stako can initialize automatically.
- Enforce a single canonical notes repository instead of scattered art directories.
- Design an abstraction path for reusing `ligi` functionality without importing its bloat.

## Design Context

`ligi` was a useful first attempt, especially around tags, indexing, and inbox behavior. Stako should preserve those good ideas while avoiding the accumulated command surface and scattered directory model.

Stako assumes one canonical notes repository. Initialization should usually be automatic once the repository path is known.

## Research Before Implementation

- Inventory the current `ligi` command surface and mark each command as keep, replace, automate, defer, or discard.
- Identify the concrete implementation modules behind indexing, tags, inbox behavior, and short flags.
- Determine whether `ligi` code can be imported cleanly or whether behavior should be reimplemented from documented examples.
- Document existing `ligi` data formats, indexes, generated files, and tag conventions.
- Check how `ligi` discovers art or notes directories and define what must change for a single notes repository.
- Identify any assumptions that would make `ligi` functionality unsafe to reuse directly.

## Planning Notes

- First extraction target is indexing for one notes repository.
- Manual indexing remains available, but automatic indexing should be designed early.
- Inbox behavior should be preserved only if it still fits the simplified model.
- Short flags are acceptable where they stay ergonomic and do not imply a large command set.
- A user-facing `init` command should not be required for normal usage.

## Implementation Plan Draft

- Write a `ligi` feature inventory document.
- Extract or recreate the indexing data model first.
- Define a minimal Stako CLI surface around indexing and repository detection.
- Add compatibility tests using sample notes from `ligi`.
- Remove dependencies on scattered art directories.
- Design migration behavior for existing `ligi` users if needed.
- Update `high_level_implementation.md` with the kept and discarded feature list.

## Acceptance Criteria

- Clear keep/replace/defer/discard decision for every relevant `ligi` feature.
- Minimal Stako indexing path works against a single notes repository.
- Manual indexing command exists.
- No required scattered notes or art directories.
- Initialization can happen automatically in the normal workflow.

## Dependencies

- Tag syntax decision affects how much of `ligi` tag parsing can be reused.
- Project structure decision affects repository layout and indexing assumptions.
- Indexing automation depends on the extracted indexing core.
