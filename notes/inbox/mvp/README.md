# MVP Plans

Ordered implementation plans for the next stako layer:

1. `00_commit_outputs.md` - commits as item outputs and handoff records.
2. `01_prompt_inputs.md` - explicit input registration and rendered prompts.
3. `02_stack_threads.md` - durable named stack threads.
4. `03_thread_runtime_resume.md` - runtime resume/continue/fork dispatch.
5. `04_routines.md` - batch prompt/routine expansion.
6. `05_admin_thread.md` - conventional stack admin thread and self-feeding loops.
7. `06_api_cli_html.md` - client surfaces for commits, threads, and routines.
8. `07_minimal_stack_elements.md` - minimal authored element, prompt, command, routine, and thread shape.

The order matters. Commit outputs give later items something stable to inspect.
Prompt input materialization makes ingestion explicit. Threads then become
durable routing metadata over that model. Runtime resume wires threads into
adapters. Routines use all of the above to submit multiple coordinated items.
The admin thread is last because it is a convention built out of threads,
commits, and routines rather than a separate scheduler.

Global constraints:

- Keep the on-disk stack/item schema backward compatible.
- Omitted new fields must preserve today's fresh-session behavior.
- All automated writes go through `StackClient`/`Stack` mutation methods.
- Preserve existing HTTP response bodies for existing endpoints.
- Preserve auth/policy checks, VCS/audit behavior, and adapter event output.
- Live runtime state is in-memory only; surviving `running` items at restart are swept to `failed/daemon_restart_orphan`.
- Do not auto-commit arbitrary external workdir changes.
