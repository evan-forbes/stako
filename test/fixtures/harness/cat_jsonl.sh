#!/usr/bin/env bash
# Tiny fake harness that prints a JSONL fixture to stdout, line by line,
# then exits 0. The fixture path is passed as the first argv. Used as a
# stand-in for the real `claude` / `codex` binary in milestone-6 tests.
set -eu
if [ $# -lt 1 ]; then
  echo "usage: cat_jsonl.sh <fixture.jsonl>" >&2
  exit 2
fi
cat "$1"
