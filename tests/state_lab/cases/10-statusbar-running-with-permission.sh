#!/usr/bin/env bash
# Case 10: status-bar (bulk) path must surface a pane permission prompt
# even when the hook state file says `running`.
#
# Locks in Phase 1.3: the status-bar previously short-circuited on ANY
# hook value, so a permission_prompt painted during a tool call (hook
# already at `running` from PostToolUse) was masked. After Phase 2 the
# status-bar shares _state_resolve with agent_get_state; both must agree.

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lab.sh"

lab_init
trap lab_cleanup EXIT

DIR="$LAB_DIR/proj"
real=$(lab_register lab-jjj "$DIR")

# Paint a Claude permission prompt.
lab_pane_paint lab-jjj <<'EOF'
Edit foo.txt?
Do you want to proceed?
  1. Yes
  2. No
EOF

# Hook fired most recently at PostToolUse → running.
mkdir -p "$AM_STATE_DIR"
printf 'running' > "$AM_STATE_DIR/lab-jjj"

state=$(probe_resolve_bulk lab-jjj claude "$real")

echo "----- layers -----" >&2
probe_all lab-jjj claude >&2
echo "------------------" >&2

lab_assert "waiting_permission" "$state" \
    "status-bar bulk path: hook=running falls through to pane permission prompt"

lab_report
