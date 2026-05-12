#!/usr/bin/env bash
# Long-running fake harness that DOES exit on SIGINT.
#
# Used by milestone 6 audit coverage to exercise the mid-session
# daemon-shutdown path: the daemon's `Manager.requestShutdown` sends SIGINT
# only, so a script intended to be reaped that way must honor it.
# Prints one normalized event, then blocks until SIGINT.
set -u
trap 'exit 130' INT
echo '{"kind":"session_started","data":{"harness":"claude","model":"claude-opus-4-7","session":"sess-mid"}}'
while true; do
  sleep 0.05
done
