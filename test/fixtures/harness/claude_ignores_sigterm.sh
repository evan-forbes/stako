#!/usr/bin/env bash
# Fake harness that ignores both SIGINT and SIGTERM (SIGKILL-required).
#
# Used by milestone 6 audit coverage: exercises the second escalation step
# in `Manager.cancelAndEscalate` (SIGTERM → SIGKILL). Mirrors
# `claude_ignores_sigint.sh` but additionally swallows SIGTERM so the bash
# child stays alive until SIGKILL.
set -u
trap '' INT
trap '' TERM
echo '{"kind":"session_started","data":{"harness":"claude","model":"claude-opus-4-7","session":"sess-very-stubborn"}}'
while true; do
  sleep 0.05
done
