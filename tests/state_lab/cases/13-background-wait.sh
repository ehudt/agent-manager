#!/usr/bin/env bash
# Case 13: background work end to end through the real hook script. Claude
# Code ≥2.1 reports still-running background work in the Stop payload's
# background_tasks array — the hook writes background directly, and the
# resolver reads it ungated (the ✳ title carries no busy/waiting
# information). When the background work finishes, Stop re-fires with a
# pruned array and the state self-heals to ready.
#
# Keep (docs/test-value-plan.md 3c): these two steps are the only assertions
# in the repo where the real hook writes the file the real _state_resolve
# reads. tests/test_state_hooks.sh checks the hook's output and
# tests/test_state.sh writes the resolver's input with printf, so a two-sided
# drift (the hook's state vocabulary changes and test_state_hooks is updated
# to match, lib/state.sh is not) passes both and fails only here. The
# resolver-only rows this case used to carry (busy glyph, non-Claude agents,
# hook silent, stale running) live in test_state_title_glyph.

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lab.sh"

lab_init
trap lab_cleanup EXIT

DIR="$LAB_DIR/proj"
real=$(lab_register lab-bg "$DIR")

TITLE_WAIT='✳ Implement the feature'

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

lab_report
