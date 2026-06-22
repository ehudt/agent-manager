#!/usr/bin/env bash
# Case 13: Claude session whose main turn has stopped (hook wrote waiting_input)
# but a background agent/task is still running. The agent pane pins a
# "Waiting for N background … to finish" banner; the resolver must refine
# waiting_input -> waiting_background for Claude sessions, and fall back to
# waiting_background even when the hook went silent. Non-Claude agents and
# running sessions are never scanned.

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lab.sh"

lab_init
trap lab_cleanup EXIT

DIR="$LAB_DIR/proj"
real=$(lab_register lab-bg "$DIR")

# Drive the banner scan: override the pane probe so this case controls whether
# Claude's background banner is "on screen" without a real tmux pane.
BANNER=false
_state_pane_has_background_wait() { $BANNER; }

# 1. Stop fired (waiting_input) + banner on screen -> waiting_background.
printf 'waiting_input' > "$AM_STATE_DIR/lab-bg"
BANNER=true
state=$(probe_resolve lab-bg claude "$real")
lab_assert "waiting_background" "$state" "waiting_input + banner -> waiting_background"

# Same via the bulk (status-bar) path.
state=$(probe_resolve_bulk lab-bg claude "$real")
lab_assert "waiting_background" "$state" "bulk: waiting_input + banner -> waiting_background"

# 2. Banner gone (background work done) -> back to waiting_input.
BANNER=false
state=$(probe_resolve lab-bg claude "$real")
lab_assert "waiting_input" "$state" "waiting_input + no banner -> waiting_input"

# 3. Non-Claude agent: banner is Claude-specific, never scanned.
BANNER=true
state=$(probe_resolve lab-bg codex "$real")
lab_assert "waiting_input" "$state" "non-claude agent not refined to waiting_background"

# 4. Running session is busy by definition — banner ignored.
printf 'running' > "$AM_STATE_DIR/lab-bg"
BANNER=true
state=$(probe_resolve lab-bg claude "$real")
lab_assert "running" "$state" "running hook not refined to waiting_background"

# 5. Hook silent + banner -> waiting_background (fallback path).
rm -f "$AM_STATE_DIR/lab-bg"
BANNER=true
state=$(probe_resolve lab-bg claude "$real")
lab_assert "waiting_background" "$state" "hook silent + banner -> waiting_background"

# 6. Hook silent + no banner -> unknown.
BANNER=false
state=$(probe_resolve lab-bg claude "$real")
lab_assert "unknown" "$state" "hook silent + no banner -> unknown"

lab_report
