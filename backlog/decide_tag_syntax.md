# Decide Tag Syntax

## Original Todo

- Compare `[[t/tag_name]]` with alternatives like `[t/]`.
- Check Markdown linter behavior.
- Decide the source tag syntax.
- Ensure indexing outputs normal Markdown links.

## Design Context

Tags are a lightweight way to organize and traverse notes. `ligi` currently uses a format like `[[t/tag_name]]`, but a lighter syntax may avoid Markdown linter noise. Regardless of source syntax, indexed output should be normal Markdown links.

## Research Before Implementation

- Document current `ligi` tag parsing behavior.
- List candidate source syntaxes and examples.
- Test candidate syntaxes against common Markdown linters and editor tooling.
- Determine whether the syntax should support nested tags, spaces, aliases, display labels, and multiple tags per line.
- Determine how tags should compile into normal Markdown links.
- Determine whether tag pages live under a dedicated index path or project-local paths.
- Check how tag syntax interacts with Obsidian-style links, standard Markdown links, and Neovim completion.

## Planning Notes

- Source syntax should be fast to type.
- Generated output should stay portable Markdown.
- The syntax should avoid false positives in prose and code blocks.
- Indexing should be the only component that needs to understand the source tag syntax deeply.

## Implementation Plan Draft

- Create a syntax comparison table.
- Add parser fixtures for each candidate syntax.
- Choose the source syntax.
- Define generated Markdown output format.
- Update indexing parser design.
- Update Neovim completion requirements.
- Update `high_level_implementation.md` with the syntax decision.

## Acceptance Criteria

- Tag syntax decision is documented.
- Markdown linter behavior is documented.
- Parser fixtures cover common and edge cases.
- Indexing can emit normal Markdown links for tags.
- Neovim integration plan reflects the selected syntax.

## Dependencies

- `ligi` feature extraction.
- Indexing automation.
- Neovim Markdown workflow.
- Project structure for tag/index paths.
