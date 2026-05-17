# Stako Todo Index

This directory breaks the original `organization_agent.md` todo list into one file per workstream. Each todo file should accumulate the research, decisions, implementation notes, dependencies, and acceptance criteria needed before coding starts.

## Todo Files

- [Research Zig TUI Options](research_zig_tui_options.md)
- [Extract Useful `ligi` Features](extract_ligi_features.md)
- [Automate Indexing](automate_indexing.md)
- [Automate Version Control](automate_version_control.md)
- [Design Authorization](design_authorization.md)
- [Research Provider Sign-In](research_provider_sign_in.md)
- [Plan Pi-Level Functionality](plan_pi_level_functionality.md)
- [Route Stack Items](route_stack_items.md)
- [Decide Tag Syntax](decide_tag_syntax.md)
- [Modify Neovim Markdown Workflow](modify_neovim_markdown_workflow.md)
- [Define Project Structure](define_project_structure.md)
- [Implement Stacks](implement_stacks.md)

## Cross-Cutting Requirements

- Stako has one canonical notes repository.
- Prompts, agent definitions, project plans, stacks, indexes, and tags live beside notes.
- Auth, containers, sync, version control, indexing, model providers, and stack routing are first-class features.
- Stack items must be routable to a specific agent, model, provider, or compatible-provider policy.
- Work should be implemented as a minimal core with modular integrations rather than a large inherited command surface.
