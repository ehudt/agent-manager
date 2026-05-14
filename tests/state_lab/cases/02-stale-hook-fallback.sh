#!/usr/bin/env bash
# Case 02: hook state file older than 180s should be ignored; falls through
# to JSONL. Verifies the staleness gate works AND that the fallback reaches
# the right answer when only one JSONL exists.

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lab.sh"

lab_init
trap lab_cleanup EXIT

DIR="$LAB_DIR/proj"
real=$(lab_register lab-bbb "$DIR")

# Hook says running but mtime is 10 minutes ago — should be discarded.
mkdir -p "$AM_STATE_DIR"
printf 'running' > "$AM_STATE_DIR/lab-bbb"
lab_hook_age lab-bbb 600

# JSONL ends end_turn -> waiting_input
lab_jsonl "$real" sess1 \
    "$(jsonl_user_text 'hi')" \
    "$(jsonl_assistant_end_turn)" >/dev/null

# Direct unit checks
hook=$(_state_from_hook lab-bbb)
lab_assert "" "$hook" "_state_from_hook: stale hook returns empty"

jsonl=$(_state_from_jsonl "$real")
lab_assert "waiting_input" "$jsonl" "_state_from_jsonl: end_turn -> waiting_input"

lab_report
