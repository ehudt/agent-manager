#!/usr/bin/env bash
# Case 01b: mirror of case 01 — same Bug 1, opposite direction.
#
# Active conversation is mid-tool-use (running). A fresher stub jsonl in
# the same project directory ends in end_turn. Today _state_jsonl_path
# picks the stub by mtime, so state reports waiting_input for a session
# that is actually running. This is symptom (b) from the user's report:
# `am list --json` shows all sessions as waiting_input even though one
# is running.

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lab.sh"

lab_init
trap lab_cleanup EXIT

DIR="$LAB_DIR/proj"
real=$(lab_register lab-aab "$DIR")

# Active session: last meaningful entry is tool_use => running
LAB_JSONL_AGE_SECS=120 lab_jsonl "$real" active \
    "$(jsonl_user_text 'do the thing')" \
    "$(jsonl_assistant_tool_use)" >/dev/null

# Shadow session: ends in end_turn, fresher mtime
lab_jsonl "$real" shadow \
    "$(jsonl_user_text 'unrelated probe')" \
    "$(jsonl_assistant_end_turn)" >/dev/null

state=$(probe_jsonl "$real")
echo "  picked jsonl: $(_state_jsonl_path "$real")" >&2
echo "  _state_from_jsonl: $state" >&2

# Active is mid-tool-use; correct answer is running.
lab_xfail "running" "$state" \
    "running session must not be reported waiting_input when a fresher end_turn stub jsonl exists in same dir"

lab_report
