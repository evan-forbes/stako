# Agent instructions for stako

Stako is a Zig CLI + daemon — a stack-based meta-harness that drives `claude` and `codex` through queued prompts/routines. Inputs and outputs are git commits.

## Toolchain

- Zig **0.15.2** (pinned in `build.zig.zon`). Do not assume 0.16 patterns; the skill below targets 0.15.x.
- Build/run via `make build`, `make test`. Underneath that's `zig build` / `zig build test`.
- Run a single test: `./zig-out/bin/<test-bin> --test-filter "<name>"`.

## Use the Zig skill

When writing, reviewing, or debugging any Zig file, load `.claude/skills/zig/SKILL.md` (Codex: `.codex/skills/zig/SKILL.md`) and follow its breaking-changes table and quick-fixes index. The `references/` directory has 51 std-library docs scoped to 0.15.x — open the relevant one rather than guessing API shapes.

If you hit a compile error, check the Quick Fixes table in `SKILL.md` first.

## Non-negotiable Zig rules

These are the patterns that, when violated, make the codebase hard to read. Honor them on every edit:

1. **Container init:** `var list: std.ArrayList(T) = .empty;` — never `.{}`. Use `.init` only for stateful types (`DebugAllocator`, `ArenaAllocator`).
2. **Format methods:** custom formatters use `{f}`; signature is `fn format(self, w: *std.Io.Writer) std.Io.Writer.Error!void`.
3. **I/O:** provide a buffer, take `.interface`, and **always `try writer.flush()`** before the function returns.
4. **`@typeInfo` fields are lowercase:** `.@"struct"`, `.@"enum"`, `.int`, `.slice`, `.pointer`. PascalCase is a compile error.
5. **Build system:** `b.addExecutable(.{ .name, .root_module = b.createModule(.{...}) })`. `root_source_file` is gone.
6. **Removed — do not emit:** `usingnamespace`, `async`/`await`, `BoundedArray`, `std.fifo.LinearFifo`, `@setCold`, `@fence`.
7. **Memory by contract:** name allocator params `gpa` (caller frees), `arena` (bulk-free at scope exit), `scratch` (never escapes). Functions returning owned memory get the **`Alloc` suffix** and a `// Caller owns returned memory` doc line.
8. **`defer`/`errdefer` adjacent to acquisition** — same statement group, not the bottom of the function. Multi-step init needs `errdefer` after each allocation.
9. **Errors:** explicit error sets, never `anyerror`. `orelse return error.MissingX` over `.?`. `if (opt) |v|` over unwrap-then-use.
10. **Generics:** `comptime T: type` over `anytype` unless genuinely accepting any type (callbacks, `std.debug.print`-style).

## Organization

- **Larger cohesive files are idiomatic.** Tests next to impl, comptime generics at file scope, visibility via `pub`. Match the std-lib's style — `std/mem.zig` is thousands of lines and that's correct. Don't split into many tiny files; don't extract helpers that have one caller.
- **Per-module scoped logger:** `const log = std.log.scoped(.session_manager);` at the top of every module that logs.
- **Comments only for non-obvious why.** No restating what the code does. No "added for X" / "used by Y" — that rots.

## Before declaring done

Run, in order:
1. `zig fmt src/ test/`
2. `make build` (or `zig build`) — must succeed
3. `make test` (or `zig build test`) — must pass
4. For correctness-sensitive changes: `zig build -Doptimize=ReleaseFast test` (UB checks fire under optimization)

Never ask the model to do `zig fmt`'s job. Never claim done before `zig build` exits clean.
