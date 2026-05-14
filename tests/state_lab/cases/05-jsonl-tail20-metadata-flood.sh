#!/usr/bin/env bash
# Case 05: _state_from_jsonl reads only `tail -20` lines and greps for
# assistant|user|queue-operation. If Claude appends 20+ metadata rows
# (file-history-snapshot, last-prompt, ai-title, system, attachment) after
# the last meaningful turn, the meaningful entry falls outside the tail
# window and the state derivation fails. This is exactly what we saw on
# the real green-wekapp jsonl on 2026-05-13.

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lab.sh"

lab_init
trap lab_cleanup EXIT

DIR="$LAB_DIR/proj"
real=$(lab_register lab-eee "$DIR")

# Build a JSONL where the last meaningful entry is end_turn, followed by
# 25 metadata rows. Today's `tail -20` cannot see the end_turn.
lines=(
    "$(jsonl_user_text 'kick off')"
    "$(jsonl_assistant_end_turn)"
)
for _ in $(seq 1 25); do
    lines+=("$(jsonl_file_history)")
    lines+=("$(jsonl_system 'meta')")
done

lab_jsonl "$real" sess1 "${lines[@]}" >/dev/null

state=$(probe_jsonl "$real")
echo "----- probes -----" >&2
printf '  jsonl total lines: %d\n' "$(wc -l < "$(_state_jsonl_path "$real")")" >&2
printf '  _state_from_jsonl: %s\n' "$state" >&2
echo "------------------" >&2

# Real conversation is end_turn -> waiting_input, but tail -20 misses it.
lab_xfail "waiting_input" "$state" \
    "tail -20 window must include the last meaningful entry — needs grep across whole file or larger window"

lab_report
