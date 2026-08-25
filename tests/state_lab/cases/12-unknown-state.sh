#!/usr/bin/env bash
# Case 12: hook-silent agent. ps-tree says it's an agent (not a shell), but
# no hook file exists. Resolver must return `unknown` rather than lying with
# `running`.

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lab.sh"

lab_init
trap lab_cleanup EXIT

DIR="$LAB_DIR/proj"
real=$(lab_register lab-unk "$DIR")

# Pretend session exists but is not a shell — overrides do this when content
# is painted. Just need lab to treat the session as alive.
LAB_PANE_CONTENT[lab-unk]="(opaque)"

# No hook file exists.
rm -f "$AM_STATE_DIR/lab-unk"

state=$(probe_resolve lab-unk claude "$real")
lab_assert "unknown" "$state" "agent alive, hook silent -> unknown"

# Stale running hook stays running: Claude is read ungated (Stop /
# UserPromptSubmit are turn-boundary events; long turns routinely outlive
# any staleness window, and process exit drops the pane to a shell).
mkdir -p "$AM_STATE_DIR"
printf 'running' > "$AM_STATE_DIR/lab-unk"
lab_hook_age lab-unk 600
state=$(probe_resolve lab-unk claude "$real")
lab_assert "running" "$state" "stale running hook -> running (ungated)"

# Fresh ready hook -> ready (sanity check).
printf 'ready' > "$AM_STATE_DIR/lab-unk"
state=$(probe_resolve lab-unk claude "$real")
lab_assert "ready" "$state" "fresh ready hook -> ready"

lab_report
