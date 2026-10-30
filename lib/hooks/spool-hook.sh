#!/bin/sh
# lib/hooks/spool-hook.sh - Agent hook for agents running inside a container
# sandbox. The sandbox cannot see am's state dir, registry or tmux, so this
# hook only spools the event: the payload on stdin becomes one file in the
# directory this script lives in (the session's hook spool, the one host
# directory the sandbox provider mounts), and lib/hooks/hook-relay on the
# host feeds it to state-hook.sh. POSIX sh and coreutils only: it runs in
# whatever image the sandbox uses.
#
# Files are written as <epoch-ns>.<pid>.tmp and renamed to .json, so the
# relay never reads half a payload, and the names sort in arrival order.
# Never fails the agent's tool call: every error exits 0.
spool=${0%/*}
[ -d "$spool" ] || exit 0
ts=$(date +%s%N 2>/dev/null)
case "$ts" in *N|"") ts=$(date +%s)000000000 ;; esac
f="$spool/$ts.$$"
cat > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f.json" 2>/dev/null
rm -f "$f.tmp" 2>/dev/null
exit 0
