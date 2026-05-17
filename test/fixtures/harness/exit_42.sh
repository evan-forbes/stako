#!/usr/bin/env bash
# Tiny fake harness: prints one valid session_started, then exits 42.
# Used by session_manager nonzero-exit tests.
set -u
echo '{"kind":"session_started","data":{"harness":"claude","model":"claude-opus-4-7","session":"sess-fail"}}'
exit 42
