#!/usr/bin/env bash
# Case 13: background work + title glyph, end to end through the real hook
# script. Claude Code ≥2.1 reports still-running background work in the Stop
# payload's background_tasks array — the hook writes waiting_background
# directly, and the resolver's title-glyph layer passes it through while the
# attention glyph (✳) is up. When the background work finishes, Stop re-fires
# with a pruned array and the state self-heals to waiting_input. No pane
# content is ever scanned.

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lab.sh"

lab_init
trap lab_cleanup EXIT

DIR="$LAB_DIR/proj"
real=$(lab_register lab-bg "$DIR")

TITLE_WAIT='✳ Implement the feature'
TITLE_BUSY='⠂ Implement the feature'

# 1. Stop with a running background shell -> hook writes waiting_background;
#    attention glyph passes it through.
lab_hook lab-bg '{"hook_event_name":"Stop","background_tasks":[{"id":"b1","type":"shell","status":"running","description":"sleep"}]}'
lab_assert "waiting_background" "$(probe_hook lab-bg)" \
    "Stop + running background_tasks -> hook file waiting_background"
state=$(probe_resolve_titled lab-bg claude "$real" "$TITLE_WAIT")
lab_assert "waiting_background" "$state" "attention glyph + waiting_background passes through"

# 2. Background work finished: Stop re-fires with a pruned array -> self-heals.
lab_hook lab-bg '{"hook_event_name":"Stop","background_tasks":[]}'
state=$(probe_resolve_titled lab-bg claude "$real" "$TITLE_WAIT")
lab_assert "waiting_input" "$state" "Stop re-fire with empty background_tasks -> waiting_input"

# 3. Wrap-up turn: file still holds a waiting state but Claude's spinner is
#    up (title busy) -> running wins; the next Stop rewrites the file.
printf 'waiting_background' > "$AM_STATE_DIR/lab-bg"
state=$(probe_resolve_titled lab-bg claude "$real" "$TITLE_BUSY")
lab_assert "running" "$state" "busy glyph + waiting_background -> running (wrap-up turn)"

# 4. Non-Claude agents never consult the title.
printf 'waiting_input' > "$AM_STATE_DIR/lab-bg"
state=$(probe_resolve_titled lab-bg codex "$real" "$TITLE_BUSY")
lab_assert "waiting_input" "$state" "non-claude ignores busy title, uses hook"

# 5. Hook silent (fresh session at the first prompt) + attention glyph ->
#    waiting_input instead of unknown.
rm -f "$AM_STATE_DIR/lab-bg"
state=$(probe_resolve_titled lab-bg claude "$real" "$TITLE_WAIT")
lab_assert "waiting_input" "$state" "hook silent + attention glyph -> waiting_input"

# 6. Hook silent + no glyph signal -> unknown (fallback preserved).
state=$(probe_resolve_titled lab-bg claude "$real" "myhost.local")
lab_assert "unknown" "$state" "hook silent + no glyph -> unknown"

# 7. Stale 'running' left behind by a backgrounded turn + attention glyph ->
#    waiting_input, and the file is self-healed so its mtime stamps the
#    waiting-entry time.
printf 'running' > "$AM_STATE_DIR/lab-bg"
lab_hook_age lab-bg 600
state=$(probe_resolve_titled lab-bg claude "$real" "$TITLE_WAIT")
lab_assert "waiting_input" "$state" "attention glyph + stale running -> waiting_input"
lab_assert "waiting_input" "$(probe_hook lab-bg)" "state file self-healed to waiting_input"

lab_report
