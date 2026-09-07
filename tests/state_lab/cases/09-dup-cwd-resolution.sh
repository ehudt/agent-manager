#!/usr/bin/env bash
# Case 09: hook session-resolution when two registry entries share a cwd.
# The hook resolves its session from positive pane signals only
# (AM_SESSION_NAME, else TMUX_PANE). A process that carries neither is not
# in an am pane — an agent started by hand in the same directory — and
# writes nothing, however many am sessions its cwd hosts. There is no
# directory-based fallback; this lab pins that.

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lab.sh"

lab_init
trap lab_cleanup EXIT

DIR="$LAB_DIR/proj"
lab_register lab-iii1 "$DIR" >/dev/null
lab_register lab-iii2 "$DIR" >/dev/null
real=$(cd "$DIR" && pwd -P)

# 1. AM_SESSION_NAME names exactly one session
lab_hook lab-iii2 "{\"hook_event_name\":\"Stop\",\"stop_hook_active\":false,\"cwd\":\"$real\"}"
lab_assert "ready"     "$(probe_hook lab-iii2)" "AM_SESSION_NAME=lab-iii2 -> writes lab-iii2"
lab_assert "<missing>" "$(probe_hook lab-iii1)" "AM_SESSION_NAME=lab-iii2 -> lab-iii1 untouched"

# 2. Neither AM_SESSION_NAME nor TMUX_PANE: not an am pane. Both sessions
#    stay untouched even though the payload's cwd is their directory.
rm -f "$AM_STATE_DIR"/lab-iii*
AM_SESSION_NAME="" TMUX_PANE="" AM_REGISTRY="$AM_REGISTRY" AM_STATE_DIR="$AM_STATE_DIR" \
    "$PROJECT_DIR/lib/hooks/state-hook.sh" \
    <<< "{\"hook_event_name\":\"Stop\",\"stop_hook_active\":false,\"session_id\":\"stranger\",\"cwd\":\"$real\"}"
lab_assert "<missing>" "$(probe_hook lab-iii1)" "no pane signal -> lab-iii1 untouched"
lab_assert "<missing>" "$(probe_hook lab-iii2)" "no pane signal -> lab-iii2 untouched"
lab_assert "false" "$(test -f "$AM_STATE_DIR/lab-iii1.sid" -o -f "$AM_STATE_DIR/lab-iii2.sid" && echo true || echo false)" \
    "no pane signal -> no sid sidecar for either session"

lab_report
