#!/usr/bin/env bash
# Fake harness that exercises the LINE_BUF_CAP (1 MiB) overflow path:
# emits one valid session_started, then 1.5 MiB of 'x' with no newline,
# then a clean session_ended terminator and exits 0. The pump should
# drop the run-on payload and emit one `error` event into the transcript.
set -u
echo '{"kind":"session_started","data":{"harness":"claude","model":"claude-opus-4-7","session":"sess-bigline"}}'
# 1.5 MiB of 'x' with no newlines. head -c + tr is far faster than awk.
head -c 1572864 </dev/zero | tr '\0' 'x'
printf '\n'
echo '{"kind":"session_ended","data":{"terminal_status":"completed","exit_code":0}}'
exit 0
