#!/usr/bin/env bash
# tests/test_state_hooks.sh - Tests for lib/hooks/state-hook.sh

test_state_hooks() {
    $SUMMARY_MODE || echo "=== Testing lib/hooks/state-hook.sh ==="

    if ! command -v jq &>/dev/null; then
        skip_test "state hook tests (jq not installed)"
        echo ""
        return
    fi

    local hook_script="$PROJECT_DIR/lib/hooks/state-hook.sh"
    if [[ ! -x "$hook_script" ]]; then
        skip_test "state hook tests (script not found or not executable)"
        echo ""
        return
    fi

    # Set up isolated temp dirs
    local tmp_dir registry_dir state_dir
    tmp_dir=$(mktemp -d)
    registry_dir="$tmp_dir/registry"
    state_dir="$tmp_dir/state"
    mkdir -p "$registry_dir" "$state_dir"

    local registry="$registry_dir/sessions.json"
    local test_project_dir="$tmp_dir/myproject"
    mkdir -p "$test_project_dir"
    local real_project_dir
    real_project_dir=$(cd "$test_project_dir" && pwd -P)

    # Build a minimal registry with one session
    jq -n \
        --arg session "am-abc123" \
        --arg dir "$real_project_dir" \
        '{sessions: {($session): {name: $session, directory: $dir, branch: "main", agent_type: "claude", task: "test task"}}}' \
        > "$registry"

    # Helper: run hook with given JSON input
    run_hook() {
        local input="$1"
        AM_REGISTRY="$registry" AM_STATE_DIR="$state_dir" \
            "$hook_script" <<< "$input"
    }

    # --- Stop hook writes waiting_input ---
    rm -f "$state_dir/am-abc123"
    run_hook "{\"hook_event_name\":\"Stop\",\"stop_hook_active\":false,\"cwd\":\"$real_project_dir\"}"
    local state
    state=$(cat "$state_dir/am-abc123" 2>/dev/null || echo "")
    assert_eq "waiting_input" "$state" "Stop hook: writes waiting_input"

    # --- stop_hook_active=true is a no-op ---
    rm -f "$state_dir/am-abc123"
    run_hook "{\"hook_event_name\":\"Stop\",\"stop_hook_active\":true,\"cwd\":\"$real_project_dir\"}"
    state=$(cat "$state_dir/am-abc123" 2>/dev/null || echo "")
    assert_eq "" "$state" "Stop hook (stop_hook_active=true): no state written"

    # --- Notification[permission_prompt] writes waiting_permission ---
    rm -f "$state_dir/am-abc123"
    run_hook "{\"hook_event_name\":\"Notification\",\"notification_type\":\"permission_prompt\",\"cwd\":\"$real_project_dir\"}"
    state=$(cat "$state_dir/am-abc123" 2>/dev/null || echo "")
    assert_eq "waiting_permission" "$state" "Notification[permission_prompt]: writes waiting_permission"

    # --- Notification[elicitation_dialog] writes waiting_custom ---
    rm -f "$state_dir/am-abc123"
    run_hook "{\"hook_event_name\":\"Notification\",\"notification_type\":\"elicitation_dialog\",\"cwd\":\"$real_project_dir\"}"
    state=$(cat "$state_dir/am-abc123" 2>/dev/null || echo "")
    assert_eq "waiting_custom" "$state" "Notification[elicitation_dialog]: writes waiting_custom"

    # --- Notification[idle_prompt] writes waiting_input ---
    rm -f "$state_dir/am-abc123"
    run_hook "{\"hook_event_name\":\"Notification\",\"notification_type\":\"idle_prompt\",\"cwd\":\"$real_project_dir\"}"
    state=$(cat "$state_dir/am-abc123" 2>/dev/null || echo "")
    assert_eq "waiting_input" "$state" "Notification[idle_prompt]: writes waiting_input"

    # --- UserPromptSubmit writes running ---
    rm -f "$state_dir/am-abc123"
    run_hook "{\"hook_event_name\":\"UserPromptSubmit\",\"cwd\":\"$real_project_dir\"}"
    state=$(cat "$state_dir/am-abc123" 2>/dev/null || echo "")
    assert_eq "running" "$state" "UserPromptSubmit: writes running"

    # --- PostToolUse writes running ---
    rm -f "$state_dir/am-abc123"
    run_hook "{\"hook_event_name\":\"PostToolUse\",\"cwd\":\"$real_project_dir\"}"
    state=$(cat "$state_dir/am-abc123" 2>/dev/null || echo "")
    assert_eq "running" "$state" "PostToolUse: writes running"

    # --- No matching session → no state file written ---
    rm -f "$state_dir/am-abc123"
    local other_dir="$tmp_dir/other_project"
    mkdir -p "$other_dir"
    run_hook "{\"hook_event_name\":\"Stop\",\"stop_hook_active\":false,\"cwd\":\"$other_dir\"}"
    state=$(cat "$state_dir/am-abc123" 2>/dev/null || echo "")
    assert_eq "" "$state" "No matching session: no state file written"

    # --- Unknown event → no state file written ---
    rm -f "$state_dir/am-abc123"
    run_hook "{\"hook_event_name\":\"SomeUnknownEvent\",\"cwd\":\"$real_project_dir\"}"
    state=$(cat "$state_dir/am-abc123" 2>/dev/null || echo "")
    assert_eq "" "$state" "Unknown event: no state file written"

    rm -rf "$tmp_dir"

    $SUMMARY_MODE || echo ""
}

run_state_hooks_tests() {
    _run_test test_state_hooks
}

if [[ -z "${_AM_TEST_RUNNER:-}" ]]; then
    set -uo pipefail
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helpers.sh"
    check_deps
    run_state_hooks_tests
    test_report
fi
