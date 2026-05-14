#!/usr/bin/env bash
# Case 01: _state_jsonl_path picks newest jsonl by mtime, regardless of which
# Claude conversation actually owns the tmux pane. Repros bug seen on
# am-6bb668 (2026-05-13): pane attached to session whose last entry was
# `end_turn` (waiting_input), but a fresher stub jsonl (user-only) in the
# same project directory shadowed it -> state reported as `running`.

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lab.sh"

lab_init
trap lab_cleanup EXIT

DIR="$LAB_DIR/proj"
real=$(lab_register lab-aaa "$DIR")

# Active session: last meaningful entry is end_turn => waiting_input
LAB_JSONL_AGE_SECS=120 lab_jsonl "$real" active \
    "$(jsonl_user_text 'first prompt')" \
    "$(jsonl_assistant_end_turn)" >/dev/null

# Shadow session: only user/system entries, but fresher mtime. Real-world
# trigger: subagent / sidechain / cancelled new session in the same dir.
lab_jsonl "$real" shadow \
    "$(jsonl_system 'boot')" \
    "$(jsonl_user_text 'queued but not answered')" >/dev/null

# Simulate Claude firing a hook that carries the active conversation's
# session_id. state-hook.sh persists it to a per-session sidecar file
# ($AM_STATE_DIR/<session>.sid), after which state derivation targets
# active.jsonl instead of the newest-mtime shadow.
lab_hook lab-aaa '{"hook_event_name":"Stop","session_id":"active"}'

state=$(probe_jsonl "$real" lab-aaa)

echo "----- probes -----" >&2
printf '  claude_session_id (sidecar): %s\n' \
    "$(cat "$AM_STATE_DIR/lab-aaa.sid" 2>/dev/null || echo '(none)')" >&2
printf '  resolved jsonl: %s\n' "$(_state_jsonl_path "$real" lab-aaa)" >&2
printf '  newest jsonl (mtime fallback): %s\n' "$(_state_jsonl_path "$real")" >&2
printf '  _state_from_jsonl: %s\n' "$state" >&2
echo "------------------" >&2

# Active conversation ended end_turn -> waiting_input. After the fix,
# _state_jsonl_path resolves the active jsonl via claude_session_id and
# ignores the fresher stub.
lab_assert "waiting_input" "$state" \
    "active conversation ended end_turn — should report waiting_input even if a fresher stub jsonl exists in same dir"

lab_report
