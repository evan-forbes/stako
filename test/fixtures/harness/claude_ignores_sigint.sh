#!/usr/bin/env bash
# Fake harness that ignores SIGINT (escalation-required scenario).
#
# Used by milestone 6's cancellation tests: the runtime is expected to
# escalate SIGINT → SIGTERM → SIGKILL when a process refuses to exit on
# SIGINT alone. The script prints an event then loops forever, swallowing
# SIGINT. SIGTERM is honored (bash exits and trap on EXIT removes children).
set -u
trap '' INT
trap 'exit 0' TERM
echo '{"kind":"session_started","data":{"harness":"claude","model":"claude-opus-4-7","session":"sess-stubborn"}}'
# Busy-wait so we stay in bash's signal-handling context and SIGTERM is
# delivered promptly to the bash PID we hold.
while true; do
  sleep 0.05
done
