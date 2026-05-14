#!/usr/bin/env bash
# Case 11: for every fixture scenario, agent_get_state and the bulk
# status-bar path must return the same state. Locks in Phase 2 — the
# consolidated _state_resolve is the single source of truth, and any
# future divergence between the two call sites fails CI.

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lab.sh"

lab_init
trap lab_cleanup EXIT

DIR="$LAB_DIR/proj"

# Scenarios -----------------------------------------------------------------
# Format: name | agent | hook | pane | jsonl_lines (|-separated, optional)

_run_scenario() {
    local name="$1" agent="$2" hook="$3" pane="$4" jsonl_lines="${5:-}"
    local session="lab-s-$name"
    local real
    real=$(lab_register "$session" "$DIR/$name" "$agent")

    # Always paint something so the lab considers the session alive
    # (tmux_session_exists override gates on LAB_PANE_CONTENT presence).
    lab_pane_paint "$session" "${pane:-(no pane content)}"

    if [[ -n "$hook" ]]; then
        mkdir -p "$AM_STATE_DIR"
        printf '%s' "$hook" > "$AM_STATE_DIR/$session"
    fi

    if [[ -n "$jsonl_lines" ]]; then
        local OLD_IFS="$IFS"; IFS='|'
        # shellcheck disable=SC2206
        local arr=($jsonl_lines)
        IFS="$OLD_IFS"
        lab_jsonl "$real" "$name" "${arr[@]}" >/dev/null
        # Also tag the registry with the claude_session_id so the resolver
        # targets this jsonl deterministically.
        registry_update "$session" claude_session_id "$name"
    fi

    local a b
    a=$(probe_agent_get_state "$session")
    b=$(probe_resolve_bulk "$session" "$agent" "$real")
    lab_assert "$a" "$b" "paths agree: $name (a=$a b=$b)"
}

# Claude: hook terminal short-circuits identically on both paths
_run_scenario hook-wait-input   claude waiting_input      "" ""
_run_scenario hook-wait-perm    claude waiting_permission "" ""
_run_scenario hook-wait-custom  claude waiting_custom     "" ""

# Claude: hook=running + pane permission prompt -> waiting_permission
_run_scenario hook-run-perm     claude running \
$'Edit foo?\nDo you want to proceed?\n  1. Yes\n  2. No\n' ""

# Claude: no hook, pane empty prompt -> waiting_input
_run_scenario pane-empty        claude "" $'\n❯ \n' ""

# Claude: no hook, jsonl end_turn -> waiting_input
_run_scenario jsonl-end-turn    claude "" "" \
"$(jsonl_user_text 'hi')|$(jsonl_assistant_end_turn)"

# Claude: no hook, jsonl tool_use -> running
_run_scenario jsonl-tool-use    claude "" "" \
"$(jsonl_user_text 'go')|$(jsonl_assistant_tool_use)"

# Codex: Working indicator -> running
_run_scenario codex-working     codex "" $'\n• Working (3s • esc to interrupt)\n' ""

# Codex: idle prompt -> waiting_input
_run_scenario codex-idle        codex "" $'\nready for input\n' ""

lab_report
