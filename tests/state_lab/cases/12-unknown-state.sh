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

# Stale running hook also leads to unknown.
mkdir -p "$AM_STATE_DIR"
printf 'running' > "$AM_STATE_DIR/lab-unk"
lab_hook_age lab-unk 600
state=$(probe_resolve lab-unk claude "$real")
lab_assert "unknown" "$state" "stale running hook -> unknown"

# Fresh waiting_input hook -> waiting_input (sanity check).
printf 'waiting_input' > "$AM_STATE_DIR/lab-unk"
state=$(probe_resolve lab-unk claude "$real")
lab_assert "waiting_input" "$state" "fresh waiting_input hook -> waiting_input"

lab_report
