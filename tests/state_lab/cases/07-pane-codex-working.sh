#!/usr/bin/env bash
# Case 07: Codex pane "Working (Xs ...)" -> running; otherwise waiting_input.

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lab.sh"

lab_init
trap lab_cleanup EXIT

DIR="$LAB_DIR/proj"
real=$(lab_register lab-ggg "$DIR" codex)
lab_tmux_start lab-ggg "$real"

lab_pane_paint lab-ggg <<'EOF'
• Working (12s • esc to interrupt)
EOF
lab_assert "running" "$(probe_pane lab-ggg codex)" \
    "codex: Working indicator -> running"

lab_pane_paint lab-ggg <<'EOF'
ready for next command
>
EOF
lab_assert "waiting_input" "$(probe_pane lab-ggg codex)" \
    "codex: no Working indicator -> waiting_input"

lab_report
