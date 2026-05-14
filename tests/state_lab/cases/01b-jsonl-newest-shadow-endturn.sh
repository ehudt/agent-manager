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

# Hook payload from the active conversation tags the session with its
# session_id so state derivation targets active.jsonl.
lab_hook lab-aab '{"hook_event_name":"PostToolUse","session_id":"active"}'

state=$(probe_jsonl "$real" lab-aab)
echo "  claude_session_id (sidecar): $(cat "$AM_STATE_DIR/lab-aab.sid" 2>/dev/null || echo '(none)')" >&2
echo "  resolved jsonl: $(_state_jsonl_path "$real" lab-aab)" >&2
echo "  _state_from_jsonl: $state" >&2

# Active is mid-tool-use; correct answer is running.
lab_assert "running" "$state" \
    "running session must not be reported waiting_input when a fresher end_turn stub jsonl exists in same dir"

lab_report
