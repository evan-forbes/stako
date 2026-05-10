# Modify Neovim Markdown Workflow

## Original Todo

- Add link-following support.
- Add auto-wrap support.
- Add tab or fuzzy completion for indexed links.
- Add a toggle for index completion.

## Design Context

Organo should integrate tightly with Neovim Markdown workflows. The editor should make notes and indexes easy to navigate and update without requiring the user to leave the writing flow.

## Research Before Implementation

- Identify the current Markdown plugin or Neovim setup to modify.
- Determine whether existing plugins already provide link following, wrapping, and completion that can be configured instead of rewritten.
- Define how Neovim discovers the canonical Organo notes repository.
- Determine the completion source format for indexed links and tags.
- Determine how indexing should be triggered from Neovim: on save, explicit command, macro, or deferred job.
- Define toggle behavior for index completion so it does not interfere with normal writing.
- Check how link-following should handle generated Markdown links, source tag syntax, missing notes, and new-note creation.

## Planning Notes

- Neovim should call Organo services rather than duplicating indexing logic.
- Completion should be fast enough for large note repositories.
- Toggle state should be visible but not noisy.
- Auto-wrap should respect Markdown lists, code blocks, headings, and existing formatting.

## Implementation Plan Draft

- Document the current Neovim Markdown workflow.
- Define Organo CLI commands or local APIs needed by Neovim.
- Implement link-following behavior for normal Markdown links and Organo source syntax.
- Implement completion source backed by the index.
- Add a command or keybinding to toggle Organo index completion.
- Add a save hook or explicit mapping to trigger indexing.
- Test with representative notes, tags, project files, and stack files.

## Acceptance Criteria

- Links can be followed from Neovim.
- Indexed notes/tags can be completed through tab or fuzzy completion.
- Completion can be toggled on and off.
- Auto-wrap works without corrupting Markdown structures.
- Neovim-triggered indexing integrates with Organo indexing service.

## Dependencies

- Indexing automation.
- Tag syntax decision.
- Project structure.
- Extracted `ligi` indexes or replacement index format.
