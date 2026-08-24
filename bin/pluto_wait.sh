#!/usr/bin/env bash
# Blocks until PlutoMCP pokes this notebook's wake FIFO, or times out.
# Run this in the background (e.g. Bash's run_in_background) instead of
# blocking an MCP `read(wait_seconds=…)` call -- see the pluto-workflow skill.
#
# Usage: pluto_wait.sh <notebook-id> [timeout-seconds]
#
#   Exit 0        something changed -- go call `read`.
#   Exit nonzero  timed out, or something's wrong (bad usage, can't open the
#                 pipe) -- either way, no signal arrived; decide for yourself.
#
# Safe to kill at any point (give up, task changed, whatever): this holds no
# lock and does no cleanup the OS doesn't already do on exit. The FIFO itself
# outlives this process either way, and is swept by `stop`.
#
# POSIX only (macOS, Linux) -- mkfifo has no Windows equivalent.

set -u

notebook_id="${1:?usage: pluto_wait.sh <notebook-id> [timeout-seconds]}"
timeout="${2:-300}"

dir="${TMPDIR:-/tmp}/plutomcp/$notebook_id"
fifo="$dir/wake"

mkdir -p "$dir" && { mkfifo "$fifo" 2>/dev/null || [ -p "$fifo" ]; } || exit 1

exec 3<>"$fifo"   # read+write open never blocks on a FIFO, even with no writer yet
read -t "$timeout" -N 1 _ <&3   # -N 1: exactly one byte: the wake is one byte, no newline
status=$?
exec 3<&-
exit "$status"
