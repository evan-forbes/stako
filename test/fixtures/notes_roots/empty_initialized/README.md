# empty_initialized fixture

Byte-stable snapshot of `organo init` on an empty directory with a fixed
timestamp (`2026-05-10T14:00:00Z`) and fixed RNG seed (`0x6F7267616E6F00`).

Some files are renamed in this fixture tree so git itself does not gitignore
them when the fixture is committed:

| In a real notes root            | In this fixture                       |
|---------------------------------|---------------------------------------|
| `.gitignore`                    | `dot_gitignore`                       |
| `.organo/local_token`           | `.organo/local_token.expected`        |
| `.organo/config.local.toml`     | `.organo/config.local.toml.expected`  |

Tests consume the rename map via `FIXTURE_FILES` in `test/init_tests.zig`.

If the schema changes, regenerate with:

    organo init --root <empty-dir> --now=2026-05-10T14:00:00Z --seed=0x6F7267616E6F00

and copy the files in, applying the renames above.
