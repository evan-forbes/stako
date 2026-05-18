# stako

Stako keeps a visible notes root at `~/stako`, serves it through a loopback daemon, and queues prompt, thread, and routine work as stack items. Prompt items are rendered with the Stako I/O contract and registered item/file/commit inputs. Completed work is the commit produced by the item, so summaries and decisions are ordinary files only when the prompt chooses to write them.

```text
~/stako
  stacks/<stack>/<item>/
  prompts/<prompt>.md
  routines/<routine>.toml
  config.toml
  state/
```

## Usage

```sh
make           # build (zig-out/bin/stako)
make test      # run the full test suite
make install   # install to $HOME/.local/bin (override with PREFIX=...)
stako init --yes
stako daemon start
```

Run CLI commands from another terminal while the daemon is serving:

```sh
./zig-out/bin/stako stack list
./zig-out/bin/stako stack show default
./zig-out/bin/stako stack add default prompt --target any --prompt-file /path/to/prompt.md --slug first-pass
./zig-out/bin/stako new demo
./zig-out/bin/stako add planning demo
./zig-out/bin/stako add -r planning -s demo
./zig-out/bin/stako start demo
./zig-out/bin/stako auth status
./zig-out/bin/stako routine list
./zig-out/bin/stako routine show admin-review
```

Daemon-backed commands accept `--root <path>`, `--port <n>`, `--json`, and `--verbose`. `STAKO_PORT` can provide the port when a root-local config is unavailable.

## Routines

Prompts live under `~/stako/prompts/`. Routines live under `~/stako/routines/` and are ordered lists of steps:

```toml
thread = "admin"

[[step]]
prompts = ["../prompts/prefix.md", "../prompts/body.md", "../prompts/suffix.md"]

[[step]]
command = "compact"

[[step]]
prompts = ["../prompts/followup.md"]
```

Each `prompts = [...]` step combines those prompt files in order into one prompt item. A step can override the root thread with `thread = "name"`. Use `command = "compact"` for compact steps; `command = "/compact"` is also accepted.
