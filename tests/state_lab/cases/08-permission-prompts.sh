#!/usr/bin/env bash
# Case 08: pane-content permission prompt detection (claude + codex).

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lab.sh"

lab_init
trap lab_cleanup EXIT

DIR="$LAB_DIR/proj"
real=$(lab_register lab-hhh "$DIR")
lab_tmux_start lab-hhh "$real"

# Claude permission prompt
lab_pane_paint lab-hhh <<'EOF'
Do you want to proceed?
  1. Yes
  2. No, tell Claude what to change
EOF
lab_assert "waiting_permission" "$(probe_pane lab-hhh claude)" \
    "claude: 'Do you want to proceed?' -> waiting_permission"

# Codex command-approval prompt
lab_pane_paint lab-hhh <<'EOF'
Would you like to run the following command?
$ rm -rf /tmp/foo
Press enter to confirm or esc to cancel
EOF
lab_assert "waiting_permission" "$(probe_pane lab-hhh codex)" \
    "codex: command approval -> waiting_permission"

# Claude plan-approval (waiting_custom)
lab_pane_paint lab-hhh <<'EOF'
Plan:
  step 1
  step 2
Would you like to proceed?
  1. Yes, use auto mode
  2. Manually approve each step
EOF
lab_assert "waiting_custom" "$(probe_pane lab-hhh claude)" \
    "claude: plan-approval -> waiting_custom"

lab_report
