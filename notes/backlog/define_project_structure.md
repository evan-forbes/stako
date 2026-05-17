# Define Project Structure

## Original Todo

- Clarify project path conventions.
- Use `notes/a/proj` for active projects.
- Define the meaning of other short path prefixes used for tags or indexes.

## Design Context

Projects are the core unit of active work. Stako assumes one canonical notes repository, and active projects are expected to live under:

```text
notes/a/proj
```

The `a` prefix means active. Other short prefixes or path segments may represent tags, indexes, archives, references, or other note categories.

## Research Before Implementation

- Inventory current notes repository layout and existing prefix conventions.
- Define which paths are durable user-authored notes and which are generated indexes.
- Determine where prompts, agent definitions, project plans, stacks, indexes, and tags should live.
- Define how project-local stacks relate to the global stack.
- Decide how active, paused, completed, archived, and reference projects are represented.
- Determine whether project metadata should live in frontmatter, sidecar files, directory names, or index files.
- Define migration requirements from existing layouts.

## Planning Notes

- The path model must stay simple enough to remember.
- Generated files should be distinguishable from hand-authored files.
- Project paths should work well with indexing, Neovim completion, and version control.
- Stack files should be easy to locate from a project.

## Implementation Plan Draft

- Write a repository layout spec.
- Define required top-level directories and prefix meanings.
- Define project metadata fields.
- Define generated index locations.
- Define stack locations for global and project stacks.
- Add validation rules for repository layout.
- Update indexing, stack runtime, and Neovim docs to use the same layout.

## Acceptance Criteria

- `notes/a/proj` convention is documented.
- Short prefix meanings are documented.
- Prompt, agent, stack, project, tag, and index locations are documented.
- Generated and user-authored files are clearly distinguished.
- Migration or compatibility notes exist for current notes.

## Dependencies

- Stack runtime.
- Indexing automation.
- Tag syntax decision.
- Neovim workflow.
