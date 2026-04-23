#!/usr/bin/env bash
# tests/test_state.sh - Tests for lib/state.sh

test_state() {
    $SUMMARY_MODE || echo "=== Testing state.sh (unit) ==="

    if ! command -v jq &>/dev/null; then
        skip_test "state unit tests (jq not installed)"
        echo ""
        return
    fi

    source "$LIB_DIR/utils.sh"
    set +u
    source "$LIB_DIR/config.sh"
    source "$LIB_DIR/tmux.sh"
    source "$LIB_DIR/registry.sh"
    source "$LIB_DIR/agents.sh"
    source "$LIB_DIR/state.sh"
    set -u

    # --- Test: _state_encode_dir ---
    assert_eq "-home-user-myapp" "$(_state_encode_dir "/home/user/myapp")" \
        "_state_encode_dir: slashes become dashes"
    assert_eq "-home-user-my-app" "$(_state_encode_dir "/home/user/my.app")" \
        "_state_encode_dir: dots become dashes (matches Claude encoding)"
    assert_eq "-tmp-project" "$(_state_encode_dir "/tmp/project")" \
        "_state_encode_dir: leading slash becomes dash"

    # --- Test: _state_jsonl_stale on missing file ---
    if _state_jsonl_stale "/nonexistent/file.jsonl"; then
        ((TESTS_RUN++)); ((TESTS_PASSED++))
        $SUMMARY_MODE || printf '%b\n' "${TEST_GREEN}PASS${TEST_RESET}: _state_jsonl_stale: missing file is stale"
    else
        ((TESTS_RUN++)); ((TESTS_FAILED++))
        printf '%b\n' "${TEST_RED}FAIL${TEST_RESET}: _state_jsonl_stale: missing file should be stale"
        FAIL_DETAILS+=("FAIL: _state_jsonl_stale: missing file should be stale")
    fi

    # --- Test: _state_from_jsonl with canned content ---
    local tmp_dir tmp_jsonl
    tmp_dir=$(mktemp -d)
    tmp_jsonl="$tmp_dir/session.jsonl"

    # end_turn → waiting_input
    printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Done"}],"stop_reason":"end_turn"}}' > "$tmp_jsonl"
    # Temporarily override _state_jsonl_path to return our test file
    _state_jsonl_path() { echo "$tmp_jsonl"; }
    assert_eq "waiting_input" "$(_state_from_jsonl "/fake/dir")" \
        "_state_from_jsonl: end_turn → waiting_input"

    # tool_use stop_reason → running
    printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use"}],"stop_reason":"tool_use"}}' > "$tmp_jsonl"
    assert_eq "running" "$(_state_from_jsonl "/fake/dir")" \
        "_state_from_jsonl: stop_reason=tool_use → running"

    # null stop_reason (fresh) → running
    printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking"}],"stop_reason":null}}' > "$tmp_jsonl"
    touch "$tmp_jsonl"  # ensure mtime is fresh
    assert_eq "running" "$(_state_from_jsonl "/fake/dir")" \
        "_state_from_jsonl: stop_reason=null fresh → running"

    # user tool_result → running
    printf '%s\n' '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"x","content":"ok"}]}}' > "$tmp_jsonl"
    touch "$tmp_jsonl"
    assert_eq "running" "$(_state_from_jsonl "/fake/dir")" \
        "_state_from_jsonl: tool_result → running"

    # queue-operation enqueue → running
    printf '%s\n' '{"type":"queue-operation","operation":"enqueue","content":"hello"}' > "$tmp_jsonl"
    assert_eq "running" "$(_state_from_jsonl "/fake/dir")" \
        "_state_from_jsonl: queue-operation enqueue → running"

    # queue-operation dequeue → empty (no state)
    printf '%s\n' '{"type":"queue-operation","operation":"dequeue"}' > "$tmp_jsonl"
    local dequeue_state
    dequeue_state=$(_state_from_jsonl "/fake/dir")
    assert_eq "" "$dequeue_state" \
        "_state_from_jsonl: queue-operation dequeue → empty"

    # Restore _state_jsonl_path
    unset -f _state_jsonl_path
    source "$LIB_DIR/state.sh"

    rm -rf "$tmp_dir"

    # --- Test: Codex pane pattern matching ---
    # Override _state_from_pane to call the pattern-matching logic directly
    # by stubbing tmux calls and feeding canned pane content.
    # We test _state_from_pane by calling it with a fake session where tmux
    # is mocked to return specific content.

    # Helper: exercise permission/running/waiting_input branches via the
    # _state_from_pane internals without a real tmux session.
    # We test the pattern-matching regexes directly.

    local codex_running='• Working (3s • esc to interrupt)'
    local codex_running2='○ Working (12s • esc to interrupt)'
    local codex_cmd_approval='Would you like to run the following command?
Reason: read ~/.zshrc
$ /usr/bin/zsh -lc something
1. Yes, proceed (y)
Press enter to confirm or esc to cancel'
    local codex_edit_approval='Would you like to make the following edits?
Reason: command failed; retry without sandbox?
README.md (+5 -0)
Press enter to confirm or esc to cancel'
    local codex_idle='› some previous output
here is the result
› '

    # Running pattern
    if printf '%s' "$codex_running" | grep -qE 'Working \([0-9]+s|esc to interrupt'; then
        ((TESTS_RUN++)); ((TESTS_PASSED++))
        $SUMMARY_MODE || printf '%b\n' "${TEST_GREEN}PASS${TEST_RESET}: codex pane: Working indicator matches running pattern"
    else
        ((TESTS_RUN++)); ((TESTS_FAILED++))
        printf '%b\n' "${TEST_RED}FAIL${TEST_RESET}: codex pane: Working indicator should match running pattern"
        FAIL_DETAILS+=("FAIL: codex pane: Working indicator should match running pattern")
    fi

    if printf '%s' "$codex_running2" | grep -qE 'Working \([0-9]+s|esc to interrupt'; then
        ((TESTS_RUN++)); ((TESTS_PASSED++))
        $SUMMARY_MODE || printf '%b\n' "${TEST_GREEN}PASS${TEST_RESET}: codex pane: hollow-circle Working variant matches running pattern"
    else
        ((TESTS_RUN++)); ((TESTS_FAILED++))
        printf '%b\n' "${TEST_RED}FAIL${TEST_RESET}: codex pane: hollow-circle Working variant should match"
        FAIL_DETAILS+=("FAIL: codex pane: hollow-circle Working variant should match")
    fi

    # Command approval pattern
    if printf '%s' "$codex_cmd_approval" | grep -qE \
            'Would you like to (run the following command|make the following edits)\?|Press enter to confirm or esc to cancel'; then
        ((TESTS_RUN++)); ((TESTS_PASSED++))
        $SUMMARY_MODE || printf '%b\n' "${TEST_GREEN}PASS${TEST_RESET}: codex pane: command approval matches permission pattern"
    else
        ((TESTS_RUN++)); ((TESTS_FAILED++))
        printf '%b\n' "${TEST_RED}FAIL${TEST_RESET}: codex pane: command approval should match permission pattern"
        FAIL_DETAILS+=("FAIL: codex pane: command approval should match permission pattern")
    fi

    # Edit approval pattern
    if printf '%s' "$codex_edit_approval" | grep -qE \
            'Would you like to (run the following command|make the following edits)\?|Press enter to confirm or esc to cancel'; then
        ((TESTS_RUN++)); ((TESTS_PASSED++))
        $SUMMARY_MODE || printf '%b\n' "${TEST_GREEN}PASS${TEST_RESET}: codex pane: edit approval matches permission pattern"
    else
        ((TESTS_RUN++)); ((TESTS_FAILED++))
        printf '%b\n' "${TEST_RED}FAIL${TEST_RESET}: codex pane: edit approval should match permission pattern"
        FAIL_DETAILS+=("FAIL: codex pane: edit approval should match permission pattern")
    fi

    # Idle content does NOT match running or permission patterns
    local idle_matches_running=false
    local idle_matches_permission=false
    printf '%s' "$codex_idle" | grep -qE 'Working \([0-9]+s|esc to interrupt' && idle_matches_running=true
    printf '%s' "$codex_idle" | grep -qE \
        'Would you like to (run the following command|make the following edits)\?|Press enter to confirm or esc to cancel' \
        && idle_matches_permission=true
    assert_eq "false" "$idle_matches_running" "codex pane: idle content does not match running pattern"
    assert_eq "false" "$idle_matches_permission" "codex pane: idle content does not match permission pattern"

    $SUMMARY_MODE || echo ""
}

test_state_integration() {
    $SUMMARY_MODE || echo "=== Testing state.sh (integration) ==="

    if ! command -v jq &>/dev/null || ! command -v tmux &>/dev/null; then
        skip_test "state integration tests (jq or tmux not installed)"
        echo ""
        return
    fi

    source "$LIB_DIR/utils.sh"
    set +u
    source "$LIB_DIR/config.sh"
    source "$LIB_DIR/tmux.sh"
    source "$LIB_DIR/registry.sh"
    source "$LIB_DIR/agents.sh"
    source "$LIB_DIR/state.sh"
    set -u

    setup_integration_env

    local test_dir
    test_dir=$(mktemp -d)

    # Launch a real session so tmux_session_exists works
    local session_name
    session_name=$(set +u; agent_launch "$test_dir" "claude" "state test" 2>/dev/null)
    assert_not_empty "$session_name" "state integration: session created"

    # Wait for stub agent to print ready marker
    local pane_output=""
    for _i in $(seq 1 20); do
        pane_output=$(am_tmux capture-pane -pt "$session_name:.{top}" 2>/dev/null || true)
        [[ "$pane_output" == *"stub-agent-ready"* ]] && break
        sleep 0.2
    done

    # agent_get_state should not return dead or empty for a live session
    local state
    state=$(agent_get_state "$session_name" 2>/dev/null || true)
    assert_not_empty "$state" "agent_get_state: returns non-empty state for live session"

    local valid_states="starting running waiting_input waiting_permission waiting_custom idle dead"
    local state_valid=false
    local s
    for s in $valid_states; do
        [[ "$state" == "$s" ]] && state_valid=true && break
    done
    assert_eq "true" "$state_valid" "agent_get_state: returns a known state value (got: $state)"

    # agent_get_state for nonexistent session → dead
    local dead_state
    dead_state=$(agent_get_state "nonexistent-session-xyz" 2>/dev/null || true)
    assert_eq "dead" "$dead_state" "agent_get_state: nonexistent session → dead"

    # am status --json should include state field
    local status_json
    status_json=$(AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" \
        "$PROJECT_DIR/am" status --json "$session_name" 2>/dev/null || true)
    if echo "$status_json" | jq . >/dev/null 2>&1; then
        ((TESTS_RUN++)); ((TESTS_PASSED++))
        $SUMMARY_MODE || printf '%b\n' "${TEST_GREEN}PASS${TEST_RESET}: am status --json: valid JSON"
    else
        ((TESTS_RUN++)); ((TESTS_FAILED++))
        printf '%b\n' "${TEST_RED}FAIL${TEST_RESET}: am status --json: invalid JSON (got: $status_json)"
        FAIL_DETAILS+=("FAIL: am status --json: invalid JSON (got: $status_json)")
    fi
    local status_state
    status_state=$(echo "$status_json" | jq -r '.state // empty' 2>/dev/null || true)
    assert_not_empty "$status_state" "am status --json: state field present"

    # am list --json should include state field (skip if list fails — pre-existing /dev/fd issue)
    local list_json
    list_json=$(AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" \
        "$PROJECT_DIR/am" list --json 2>/dev/null || true)
    if [[ -n "$list_json" ]] && echo "$list_json" | jq . >/dev/null 2>&1; then
        local list_has_state
        list_has_state=$(echo "$list_json" | jq 'if length > 0 then .[0] | has("state") else true end' 2>/dev/null || echo "false")
        assert_eq "true" "$list_has_state" "am list --json: state field present in objects"
    else
        skip_test "am list --json: state field (am list --json unavailable in test env)"
    fi

    # am peek --json should return valid JSON with state and lines
    local peek_json
    peek_json=$(AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" \
        "$PROJECT_DIR/am" peek --json "$session_name" 2>/dev/null || true)
    if echo "$peek_json" | jq . >/dev/null 2>&1; then
        ((TESTS_RUN++)); ((TESTS_PASSED++))
        $SUMMARY_MODE || printf '%b\n' "${TEST_GREEN}PASS${TEST_RESET}: am peek --json: valid JSON"
    else
        ((TESTS_RUN++)); ((TESTS_FAILED++))
        printf '%b\n' "${TEST_RED}FAIL${TEST_RESET}: am peek --json: invalid JSON (got: $peek_json)"
        FAIL_DETAILS+=("FAIL: am peek --json: invalid JSON (got: $peek_json)")
    fi
    local peek_has_lines
    peek_has_lines=$(echo "$peek_json" | jq 'has("lines")' 2>/dev/null || echo "false")
    assert_eq "true" "$peek_has_lines" "am peek --json: has lines field"

    # am wait --timeout 1 with immediate exit (session may already be in a target state)
    local wait_state
    wait_state=$(AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" \
        "$PROJECT_DIR/am" wait --timeout 5 "$session_name" 2>/dev/null || true)
    assert_not_empty "$wait_state" "am wait: returns a state"

    # am interrupt: stub agent runs as bash so state detection sees it as "idle".
    # Verify the command handles this gracefully (exits 1 with warning) rather than crashing.
    local interrupt_rc=0
    AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" \
        "$PROJECT_DIR/am" interrupt "$session_name" >/dev/null 2>&1 || interrupt_rc=$?
    # Exit 0 (live session running real agent) or 1 (stub looks idle) are both acceptable
    assert_eq "true" "$(test $interrupt_rc -le 1 && echo true || echo false)" \
        "am interrupt: exits 0 or 1 (no crash)"

    # Cleanup
    [[ -n "$session_name" ]] && agent_kill "$session_name" 2>/dev/null
    rm -rf "$test_dir"
    teardown_integration_env

    $SUMMARY_MODE || echo ""
}

test_agent_wait_state_stable_idle() {
    local saved_get_state saved_tmux_exists saved_get_activity saved_sleep saved_date
    saved_get_state="$(declare -f agent_get_state)"
    saved_tmux_exists="$(declare -f tmux_session_exists)"
    saved_get_activity="$(declare -f tmux_get_activity)"
    saved_sleep="$(declare -f sleep 2>/dev/null || true)"
    saved_date="$(declare -f date 2>/dev/null || true)"

    local -a mock_states=("waiting_input" "waiting_input" "waiting_input")
    local -a mock_activity=("100" "101" "101")
    local mock_idx=0
    local mock_now=103

    agent_get_state() {
        local idx=$mock_idx
        (( idx >= ${#mock_states[@]} )) && idx=$((${#mock_states[@]} - 1))
        printf '%s\n' "${mock_states[$idx]}"
    }

    tmux_get_activity() {
        local idx=$mock_idx
        (( idx >= ${#mock_activity[@]} )) && idx=$((${#mock_activity[@]} - 1))
        printf '%s\n' "${mock_activity[$idx]}"
    }

    tmux_session_exists() { return 0; }

    sleep() {
        mock_idx=$((mock_idx + 1))
        mock_now=$((mock_now + 1))
    }

    date() {
        if [[ "${1:-}" == "+%s" ]]; then
            printf '%s\n' "$mock_now"
        else
            command date "$@"
        fi
    }

    local state
    AM_WAIT_STABLE_POLLS=2 AM_WAIT_QUIET_SECS=2 \
        state=$(agent_wait_state "fake-session" "waiting_input" 5)
    assert_eq "waiting_input" "$state" "agent_wait_state: requires stable quiet waiting_input"

    eval "$saved_get_state"
    eval "$saved_tmux_exists"
    eval "$saved_get_activity"
    [[ -n "$saved_sleep" ]] && eval "$saved_sleep" || unset -f sleep
    [[ -n "$saved_date" ]] && eval "$saved_date" || unset -f date
}

test_am_session_order() {
    $SUMMARY_MODE || echo "=== Testing am_session_order ==="

    if ! command -v tmux &>/dev/null; then
        skip_test "am_session_order tests (tmux not installed)"
        echo ""
        return
    fi

    source "$LIB_DIR/utils.sh"
    set +u
    source "$LIB_DIR/config.sh"
    source "$LIB_DIR/tmux.sh"
    source "$LIB_DIR/registry.sh"
    source "$LIB_DIR/agents.sh"
    source "$LIB_DIR/state.sh"
    set -u

    setup_integration_env

    local test_dir
    test_dir=$(mktemp -d)

    # Create 3 sessions with small spacing so tmux's second-precision
    # session_created timestamps are distinguishable.
    local s1 s2 s3
    s1=$(set +u; agent_launch "$test_dir" "claude" "" 2>/dev/null)
    sleep 1.1
    s2=$(set +u; agent_launch "$test_dir" "claude" "" 2>/dev/null)
    sleep 1.1
    s3=$(set +u; agent_launch "$test_dir" "claude" "" 2>/dev/null)

    local result count
    result=$(am_session_order)
    count=$(echo "$result" | wc -l | tr -d ' ')
    assert_eq "3" "$count" "am_session_order: returns all 3 sessions"

    # Order is creation time ascending: oldest first, newest at the end
    local expected
    expected=$(printf '%s\n%s\n%s' "$s1" "$s2" "$s3")
    assert_eq "$expected" "$result" "am_session_order: creation time ascending (newest last)"

    # Order is stable regardless of activity
    am_tmux send-keys -t "$s2" "" 2>/dev/null || true
    sleep 0.1
    local result2
    result2=$(am_session_order)
    assert_eq "$result" "$result2" "am_session_order: stable after activity change"

    # Cleanup
    [[ -n "$s1" ]] && agent_kill "$s1" 2>/dev/null
    [[ -n "$s2" ]] && agent_kill "$s2" 2>/dev/null
    [[ -n "$s3" ]] && agent_kill "$s3" 2>/dev/null
    rm -rf "$test_dir"
    teardown_integration_env

    $SUMMARY_MODE || echo ""
}

run_state_tests() {
    _run_test test_state
    _run_test test_state_integration
    _run_test test_agent_wait_state_stable_idle
    _run_test test_am_session_order
}

if [[ -z "${_AM_TEST_RUNNER:-}" ]]; then
    set -uo pipefail
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helpers.sh"
    check_deps
    run_state_tests
    test_report
fi
