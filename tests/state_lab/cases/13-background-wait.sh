#!/usr/bin/env bash
# Case 13: background work + title glyph, end to end through the real hook
# script. Claude Code ≥2.1 reports still-running background work in the Stop
# payload's background_tasks array — the hook writes background
# directly, and the resolver reads it ungated (the ✳ title carries no
# busy/waiting information). When the background work finishes, Stop re-fires
# with a pruned array and the state self-heals to ready. No pane
# content is ever scanned.

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lab.sh"

lab_init
trap lab_cleanup EXIT

DIR="$LAB_DIR/proj"
real=$(lab_register lab-bg "$DIR")

TITLE_WAIT='✳ Implement the feature'
TITLE_BUSY='⠂ Implement the feature'

# 1. Stop with a running background shell -> hook writes background;
#    attention glyph passes it through.
lab_hook lab-bg '{"hook_event_name":"Stop","background_tasks":[{"id":"b1","type":"shell","status":"running","description":"sleep"}]}'
lab_assert "background" "$(probe_hook lab-bg)" \
    "Stop + running background_tasks -> hook file background"
state=$(probe_resolve_titled lab-bg claude "$real" "$TITLE_WAIT")
lab_assert "background" "$state" "attention glyph + background passes through"

# 2. Background work finished: Stop re-fires with a pruned array -> self-heals.
lab_hook lab-bg '{"hook_event_name":"Stop","background_tasks":[]}'
state=$(probe_resolve_titled lab-bg claude "$real" "$TITLE_WAIT")
lab_assert "ready" "$state" "Stop re-fire with empty background_tasks -> ready"

# 3. Wrap-up turn: file still holds a waiting state but Claude's spinner is
#    up (title busy) -> running wins; the next Stop rewrites the file.
printf 'background' > "$AM_STATE_DIR/lab-bg"
state=$(probe_resolve_titled lab-bg claude "$real" "$TITLE_BUSY")
lab_assert "running" "$state" "busy glyph + background -> running (wrap-up turn)"

# 4. Non-Claude agents never consult the title.
printf 'ready' > "$AM_STATE_DIR/lab-bg"
state=$(probe_resolve_titled lab-bg codex "$real" "$TITLE_BUSY")
lab_assert "ready" "$state" "non-claude ignores busy title, uses hook"

# 5. Hook silent (fresh session at the first prompt) + attention glyph ->
#    ready instead of unknown.
rm -f "$AM_STATE_DIR/lab-bg"
state=$(probe_resolve_titled lab-bg claude "$real" "$TITLE_WAIT")
lab_assert "ready" "$state" "hook silent + attention glyph -> ready"

# 6. Hook silent + no glyph signal -> unknown (fallback preserved).
state=$(probe_resolve_titled lab-bg claude "$real" "myhost.local")
lab_assert "unknown" "$state" "hook silent + no glyph -> unknown"

# 7. Stale 'running' + ✳ title -> still running: since Claude Code 2.1.234
#    "✳ <task>" stays painted through live turns (no busy glyph exists), so
#    ✳ must not flip a running turn to ready; the hook's Stop moves
#    the state forward (a ctrl-b backgrounded turn fires its own Stop on
#    ≥2.1.237 — live lab s6).
printf 'running' > "$AM_STATE_DIR/lab-bg"
lab_hook_age lab-bg 600
state=$(probe_resolve_titled lab-bg claude "$real" "$TITLE_WAIT")
lab_assert "running" "$state" "✳ + stale running -> running (✳ carries no busy/waiting info)"
lab_assert "running" "$(probe_hook lab-bg)" "state file left untouched (no self-heal rewrite)"

lab_report
