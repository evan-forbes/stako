# stako

Stako keeps a visible notes root at `~/stako`, serves it through a loopback daemon, and queues prompt, thread, and routine work as stack items. Prompt items are rendered with the Stako I/O contract and registered item/file/commit inputs. Completed work is the commit produced by the item, so summaries and decisions are ordinary files only when the prompt chooses to write them.

```text
~/stako
  stacks/<stack>/<item>/
  routines/<routine>.toml
  routines/<routine>/
  config.toml
  state/
```

## Usage

```sh
zig build
zig build test
./zig-out/bin/stako init --yes
./zig-out/bin/stako daemon start
```

Run CLI commands from another terminal while the daemon is serving:

```sh
./zig-out/bin/stako stack list
./zig-out/bin/stako stack show default
./zig-out/bin/stako stack add default prompt --target any --prompt-file /path/to/prompt.md --slug first-pass
./zig-out/bin/stako auth status
./zig-out/bin/stako routine list
./zig-out/bin/stako routine show admin-review
```

Daemon-backed commands accept `--root <path>`, `--port <n>`, `--json`, and `--verbose`. `STAKO_PORT` can provide the port when a root-local config is unavailable.
