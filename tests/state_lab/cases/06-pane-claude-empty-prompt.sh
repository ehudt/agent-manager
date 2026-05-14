#!/usr/bin/env bash
# Case 06: Claude pane showing empty `❯` prompt with no spinner => waiting_input
# (positive test, complements the regression for stuck-running detection).

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lab.sh"

lab_init
trap lab_cleanup EXIT

DIR="$LAB_DIR/proj"
real=$(lab_register lab-fff "$DIR")
lab_tmux_start lab-fff "$real"

# Paint Claude's idle frame: empty `❯` on its own line.
lab_pane_paint lab-fff <<'EOF'
some prior output
─────────────────────────────────
❯
─────────────────────────────────
opus | main | $0.10
EOF

state=$(probe_pane lab-fff claude)
lab_assert "waiting_input" "$state" \
    "_state_from_pane (claude): empty ❯ prompt -> waiting_input"

# Same pane with active spinner overrides: running
lab_pane_paint lab-fff <<'EOF'
· Thinking…
❯
EOF
state=$(probe_pane lab-fff claude)
lab_assert "running" "$state" \
    "_state_from_pane (claude): spinner present overrides empty ❯ -> running"

lab_report
