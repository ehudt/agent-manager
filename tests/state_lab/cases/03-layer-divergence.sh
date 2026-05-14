#!/usr/bin/env bash
# Case 03: hook=running must fall through to pane permission detection.
#
# Both call sites — agent_get_state (am list --json) and the status-bar
# bulk path — go through _state_resolve. Locks in Phase 1.3 (no
# ▸-in-sidebar / ●-in-browser divergence) and Phase 2 (one resolver).

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lab.sh"

lab_init
trap lab_cleanup EXIT

DIR="$LAB_DIR/proj"
real=$(lab_register lab-ccc "$DIR")

# Live tmux session — needed for pane probes.
lab_tmux_start lab-ccc "$real"

# Paint a Claude permission prompt into the pane.
lab_pane_paint lab-ccc <<'EOF'
Edit file foo.txt?
Do you want to proceed?
  1. Yes
  2. No
EOF

# Hook says running (e.g. PostToolUse already fired)
mkdir -p "$AM_STATE_DIR"
printf 'running' > "$AM_STATE_DIR/lab-ccc"

a=$(probe_agent_get_state lab-ccc)
b=$(probe_resolve lab-ccc claude "$real")
c=$(probe_resolve_bulk lab-ccc claude "$real")

echo "----- layers -----" >&2
probe_all lab-ccc claude >&2
echo "------------------" >&2

lab_assert "waiting_permission" "$a" \
    "agent_get_state: pane permission prompt wins over running hook"
lab_assert "waiting_permission" "$b" \
    "_state_resolve (non-bulk): hook=running falls through to pane permission"
lab_assert "waiting_permission" "$c" \
    "_state_resolve (bulk): hook=running falls through to pane permission"

lab_report
