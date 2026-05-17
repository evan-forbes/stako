# Implement TUI Client (Follow-Up)

## Scope

A formal TUI can come after the CLI and web view prove the workflow. It must be a client of the daemon API and must not duplicate runtime logic.

## Preconditions

- CLI inspection/debugging commands are ergonomic enough for daily use.
- Web view handles live status/transcript inspection.
- API endpoints and error shapes are stable.

## Planned Surface

- Stack list.
- Stack detail with live updates.
- Item detail with transcript.
- Pause/resume/cancel/retry.
- Stack-config display and minimal edits.
- Audit-log tail if it proves useful.

## Design Notes

- Revisit `backlog/research_zig_tui_options.md` before selecting a TUI library.
- Prefer reusing the CLI's HTTP client and output models.
- No TUI-only runtime features.

## Out of Scope

- Inline harness control beyond cancel.
- Separate daemon/runtime implementation.
