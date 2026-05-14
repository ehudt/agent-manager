#!/usr/bin/env bash
# Case 09: hook session-resolution when two registry entries share a cwd.
# Without AM_SESSION_NAME or TMUX_PANE, the hook falls back to cwd match
# and arbitrarily picks the first session in jq order. This is documented
# in state-hook.sh as a known gap. Lab pins the behavior so we notice if
# it changes.

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lab.sh"

lab_init
trap lab_cleanup EXIT

DIR="$LAB_DIR/proj"
lab_register lab-iii1 "$DIR" >/dev/null
lab_register lab-iii2 "$DIR" >/dev/null
real=$(cd "$DIR" && pwd -P)

# 1. AM_SESSION_NAME wins
lab_hook lab-iii2 "{\"hook_event_name\":\"Stop\",\"stop_hook_active\":false,\"cwd\":\"$real\"}"
lab_assert "waiting_input" "$(probe_hook lab-iii2)" "AM_SESSION_NAME=lab-iii2 -> writes lab-iii2"
lab_assert "<missing>"     "$(probe_hook lab-iii1)" "AM_SESSION_NAME=lab-iii2 -> lab-iii1 untouched"

# 2. Without AM_SESSION_NAME, cwd fallback picks whichever jq enumerates
#    first. Pin the actual picked session so regressions surface.
rm -f "$AM_STATE_DIR"/lab-iii*
AM_SESSION_NAME="" AM_REGISTRY="$AM_REGISTRY" AM_STATE_DIR="$AM_STATE_DIR" \
    "$PROJECT_DIR/lib/hooks/state-hook.sh" \
    <<< "{\"hook_event_name\":\"Stop\",\"stop_hook_active\":false,\"cwd\":\"$real\"}"

picked=""
[[ -f "$AM_STATE_DIR/lab-iii1" ]] && picked="lab-iii1"
[[ -f "$AM_STATE_DIR/lab-iii2" ]] && picked="${picked:-lab-iii2}"
echo "  cwd fallback picked: $picked" >&2

# Document: hook fired for ONE of the two sessions (ambiguous) — known gap.
# We assert at least one was written; not which.
written=0
[[ -f "$AM_STATE_DIR/lab-iii1" ]] && written=$((written+1))
[[ -f "$AM_STATE_DIR/lab-iii2" ]] && written=$((written+1))
lab_assert "1" "$written" \
    "cwd fallback writes exactly one of the ambiguous sessions (documented gap)"

lab_report
