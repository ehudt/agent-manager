#!/usr/bin/env bash
# Case 03: divergence between the three state-detection paths.
#
# Three implementations exist today:
#   A. agent_get_state           (lib/state.sh)     — used by `am list --json`
#   B. _agent_get_state_fast     (lib/state.sh)     — internal lean variant
#   C. _fast_state               (lib/status-bar)   — used by the tmux strip
#
# They differ in priority order. The most consequential gap is C: the
# status-bar short-circuits on ANY hook value, while A and B only short-
# circuit for non-running hook values and otherwise still run pane checks
# (so permission prompts can be detected mid-tool-call).
#
# This case sets up: hook=running + pane content matching a permission
# prompt. A returns waiting_permission; C returns running. That divergence
# is the visible "▸ in status bar while ● in browser" bug.

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lab.sh"
# shellcheck disable=SC1090
source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/status-bar.shim.sh" 2>/dev/null || true

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
b=$(probe_fast_state lab-ccc claude "$real")

echo "----- layers -----" >&2
probe_all lab-ccc claude >&2
echo "------------------" >&2

lab_assert "waiting_permission" "$a" \
    "agent_get_state: pane permission prompt wins over running hook"

# _agent_get_state_fast falls through to pane when hook=running, so it
# should also catch the prompt.
lab_assert "waiting_permission" "$b" \
    "_agent_get_state_fast: hook=running falls through to pane permission check"

# NOTE: A status-bar reproduction is intentionally not asserted here
# because lib/status-bar is a script (not a sourceable function library)
# and short-circuits on any hook value. Tracked in the consolidation plan.

lab_report
