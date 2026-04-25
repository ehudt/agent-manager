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

    # --- PostToolUse does NOT clobber waiting_input (race protection) ---
    # Claude Code may deliver a delayed PostToolUse from a previous turn after
    # Stop has already written waiting_input. That must not revert the state.
    printf 'waiting_input' > "$state_dir/am-abc123"
    run_hook "{\"hook_event_name\":\"PostToolUse\",\"cwd\":\"$real_project_dir\"}"
    state=$(cat "$state_dir/am-abc123" 2>/dev/null || echo "")
    assert_eq "waiting_input" "$state" "PostToolUse: does not clobber waiting_input"

    # --- PostToolUse does NOT clobber waiting_permission ---
    printf 'waiting_permission' > "$state_dir/am-abc123"
    run_hook "{\"hook_event_name\":\"PostToolUse\",\"cwd\":\"$real_project_dir\"}"
    state=$(cat "$state_dir/am-abc123" 2>/dev/null || echo "")
    assert_eq "waiting_permission" "$state" "PostToolUse: does not clobber waiting_permission"

    # --- PostToolUse does NOT clobber waiting_custom ---
    printf 'waiting_custom' > "$state_dir/am-abc123"
    run_hook "{\"hook_event_name\":\"PostToolUse\",\"cwd\":\"$real_project_dir\"}"
    state=$(cat "$state_dir/am-abc123" 2>/dev/null || echo "")
    assert_eq "waiting_custom" "$state" "PostToolUse: does not clobber waiting_custom"

    # --- UserPromptSubmit DOES override waiting_input (explicit user action) ---
    printf 'waiting_input' > "$state_dir/am-abc123"
    run_hook "{\"hook_event_name\":\"UserPromptSubmit\",\"cwd\":\"$real_project_dir\"}"
    state=$(cat "$state_dir/am-abc123" 2>/dev/null || echo "")
    assert_eq "running" "$state" "UserPromptSubmit: overrides waiting_input"

    # --- Duplicate cwd: AM_SESSION_NAME disambiguates which session to update ---
    # Two am sessions can share a cwd (e.g., multiple Claude instances in the
    # same repo). Without AM_SESSION_NAME the hook would blindly pick the first
    # match and keep overwriting the wrong session's state file forever.
    local dup_registry="$tmp_dir/dup.json"
    jq -n --arg dir "$real_project_dir" \
        '{sessions: {
            "am-first":  {name: "am-first",  directory: $dir, branch: "main", agent_type: "claude", task: "t1"},
            "am-second": {name: "am-second", directory: $dir, branch: "main", agent_type: "claude", task: "t2"}
         }}' > "$dup_registry"

    rm -f "$state_dir/am-first" "$state_dir/am-second"
    AM_REGISTRY="$dup_registry" AM_STATE_DIR="$state_dir" AM_SESSION_NAME="am-second" \
        "$hook_script" <<< "{\"hook_event_name\":\"UserPromptSubmit\",\"cwd\":\"$real_project_dir\"}"
    assert_eq ""        "$(cat "$state_dir/am-first"  2>/dev/null || echo)" "AM_SESSION_NAME: first session untouched"
    assert_eq "running" "$(cat "$state_dir/am-second" 2>/dev/null || echo)" "AM_SESSION_NAME: targeted session updated"

    # --- AM_SESSION_NAME pointing at non-existent session → no write ---
    rm -f "$state_dir/am-first" "$state_dir/am-second"
    AM_REGISTRY="$dup_registry" AM_STATE_DIR="$state_dir" AM_SESSION_NAME="am-bogus" \
        "$hook_script" <<< "{\"hook_event_name\":\"UserPromptSubmit\",\"cwd\":\"$real_project_dir\"}"
    assert_eq "" "$(cat "$state_dir/am-first"  2>/dev/null || echo)" "AM_SESSION_NAME bogus: first session untouched"
    assert_eq "" "$(cat "$state_dir/am-second" 2>/dev/null || echo)" "AM_SESSION_NAME bogus: second session untouched"

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

_ensure_state_lib_sourced() {
    if [[ "$(type -t _state_from_hook)" != "function" ]]; then
        set +u
        source "$LIB_DIR/utils.sh"
        source "$LIB_DIR/tmux.sh"
        source "$LIB_DIR/registry.sh"
        source "$LIB_DIR/state.sh"
        set -u
    fi
}

test_state_from_hook_reads_file() {
    _ensure_state_lib_sourced
    local state_dir
    state_dir=$(mktemp -d)
    printf 'waiting_permission' > "$state_dir/am-test01"

    local result
    result=$(AM_STATE_DIR="$state_dir" _state_from_hook "am-test01")
    assert_eq "waiting_permission" "$result" "_state_from_hook reads state file"
    rm -rf "$state_dir"
}

test_state_from_hook_missing_file() {
    _ensure_state_lib_sourced
    local state_dir
    state_dir=$(mktemp -d)

    local result
    result=$(AM_STATE_DIR="$state_dir" _state_from_hook "am-nonexist")
    assert_eq "" "$result" "_state_from_hook returns empty for missing file"
    rm -rf "$state_dir"
}

test_state_from_hook_stale_file() {
    _ensure_state_lib_sourced
    local state_dir
    state_dir=$(mktemp -d)
    printf 'waiting_input' > "$state_dir/am-test01"
    # Backdate the file by 5 minutes
    touch -t "$(date -v-5M '+%Y%m%d%H%M.%S' 2>/dev/null \
        || date -d '5 minutes ago' '+%Y%m%d%H%M.%S')" "$state_dir/am-test01"

    local result
    result=$(AM_STATE_DIR="$state_dir" _state_from_hook "am-test01")
    assert_eq "" "$result" "_state_from_hook returns empty for stale file (>3m)"
    rm -rf "$state_dir"
}

test_state_from_hook_invalid_state() {
    _ensure_state_lib_sourced
    local state_dir
    state_dir=$(mktemp -d)
    printf 'bogus_state' > "$state_dir/am-test01"

    local result
    result=$(AM_STATE_DIR="$state_dir" _state_from_hook "am-test01")
    assert_eq "" "$result" "_state_from_hook rejects invalid state values"
    rm -rf "$state_dir"
}

_ensure_install_lib_sourced() {
    if [[ "$(type -t _install_claude_hooks)" != "function" ]]; then
        # Extract just the function from install.sh (can't source the whole file
        # because it has set -euo pipefail and runs install logic at top level)
        eval "$(sed -n '/^_install_claude_hooks()/,/^}/p' "$PROJECT_DIR/scripts/install.sh")"
    fi
}

test_install_hooks_into_empty_settings() {
    _ensure_install_lib_sourced
    local tmp_dir
    tmp_dir=$(mktemp -d)
    local settings="$tmp_dir/empty-settings.json"
    echo '{}' > "$settings"

    _install_claude_hooks "$settings" "$PROJECT_DIR/lib/hooks/state-hook.sh"

    local stop_count
    stop_count=$(jq '.hooks.Stop | length' "$settings")
    assert_eq "1" "$stop_count" "Stop hook installed"

    local notif_count
    notif_count=$(jq '.hooks.Notification | length' "$settings")
    assert_eq "3" "$notif_count" "3 Notification hooks installed"

    local upsub_count
    upsub_count=$(jq '.hooks.UserPromptSubmit | length' "$settings")
    assert_eq "1" "$upsub_count" "UserPromptSubmit hook installed"

    local post_count
    post_count=$(jq '.hooks.PostToolUse | length' "$settings")
    assert_eq "1" "$post_count" "PostToolUse hook installed"
}

test_install_hooks_preserves_existing() {
    _ensure_install_lib_sourced
    local tmp_dir
    tmp_dir=$(mktemp -d)
    local settings="$tmp_dir/existing-settings.json"
    cat > "$settings" <<'JSON'
{"hooks":{"PreCompact":[{"matcher":"","hooks":[{"type":"command","command":"echo existing"}]}],"UserPromptSubmit":[{"matcher":"","hooks":[{"type":"command","command":"echo user-hook"}]}]}}
JSON

    _install_claude_hooks "$settings" "$PROJECT_DIR/lib/hooks/state-hook.sh"

    # Existing hooks preserved
    local precompact_count
    precompact_count=$(jq '.hooks.PreCompact | length' "$settings")
    assert_eq "1" "$precompact_count" "existing PreCompact hook preserved"

    # Existing UserPromptSubmit hook preserved + ours added
    local upsub_count
    upsub_count=$(jq '.hooks.UserPromptSubmit | length' "$settings")
    assert_eq "2" "$upsub_count" "existing + new UserPromptSubmit hooks"

    # Verify the existing one is first (untouched)
    local existing_cmd
    existing_cmd=$(jq -r '.hooks.UserPromptSubmit[0].hooks[0].command' "$settings")
    assert_eq "echo user-hook" "$existing_cmd" "existing UserPromptSubmit hook unchanged"
}

test_install_hooks_idempotent() {
    _ensure_install_lib_sourced
    local tmp_dir
    tmp_dir=$(mktemp -d)
    local settings="$tmp_dir/idem-settings.json"
    echo '{}' > "$settings"

    _install_claude_hooks "$settings" "$PROJECT_DIR/lib/hooks/state-hook.sh"
    _install_claude_hooks "$settings" "$PROJECT_DIR/lib/hooks/state-hook.sh"

    local stop_count
    stop_count=$(jq '.hooks.Stop | length' "$settings")
    assert_eq "1" "$stop_count" "idempotent: Stop hook not duplicated"

    local notif_count
    notif_count=$(jq '.hooks.Notification | length' "$settings")
    assert_eq "3" "$notif_count" "idempotent: Notification hooks not duplicated"
}

run_state_hooks_tests() {
    _run_test test_state_hooks
    _run_test test_state_from_hook_reads_file
    _run_test test_state_from_hook_missing_file
    _run_test test_state_from_hook_stale_file
    _run_test test_state_from_hook_invalid_state
    _run_test test_install_hooks_into_empty_settings
    _run_test test_install_hooks_preserves_existing
    _run_test test_install_hooks_idempotent
}

if [[ -z "${_AM_TEST_RUNNER:-}" ]]; then
    set -uo pipefail
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helpers.sh"
    check_deps
    run_state_hooks_tests
    test_report
fi
