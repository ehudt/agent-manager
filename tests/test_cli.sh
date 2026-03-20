#!/usr/bin/env bash
# tests/test_cli.sh - Tests for the `am` entry point

test_cli() {
    $SUMMARY_MODE || echo "=== Testing am CLI ==="

    # Test help (no deps needed)
    local help_output
    help_output=$("$PROJECT_DIR/am" help)
    assert_contains "$help_output" "Agent Manager" "am help: shows title"
    assert_contains "$help_output" "USAGE" "am help: shows usage"
    assert_contains "$help_output" "COMMANDS" "am help: shows commands"
    assert_contains "$help_output" "send" "am help: mentions send command"
    assert_contains "$help_output" "peek" "am help: mentions peek command"
    assert_contains "$help_output" "--detach" "am help: mentions detach flag"
    assert_contains "$help_output" "--sandbox" "am help: mentions sandbox flag"
    assert_contains "$help_output" "am sb ps" "am help: mentions sandbox ps command"

    # Test version
    local version_output
    version_output=$("$PROJECT_DIR/am" version)
    assert_contains "$version_output" "0.1.0" "am version: shows version"

    $SUMMARY_MODE || echo ""
}

test_cli_extended() {
    $SUMMARY_MODE || echo "=== Testing CLI commands (extended) ==="

    if ! command -v jq &>/dev/null || ! command -v tmux &>/dev/null; then
        skip_test "cli extended tests (jq or tmux not installed)"
        echo ""
        return
    fi

    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/tmux.sh"
    source "$LIB_DIR/registry.sh"
    set +u; source "$LIB_DIR/agents.sh"; set -u

    setup_integration_env

    local test_dir
    test_dir=$(mktemp -d)

    # Create a session for testing against
    local session_name
    session_name=$(set +u; agent_launch "$test_dir" "claude" "cli test" 2>/dev/null)

    if [[ -z "$session_name" ]]; then
        skip_test "cli extended tests (agent_launch failed)"
        teardown_integration_env
        rm -rf "$test_dir"
        echo ""
        return
    fi

    # --- Test: am list --json returns valid JSON containing our session ---
    local json_output
    json_output=$(AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" "$PROJECT_DIR/am" list --json 2>/dev/null)
    # Validate JSON
    if echo "$json_output" | jq . >/dev/null 2>&1; then
        ((TESTS_RUN++)); ((TESTS_PASSED++))
        $SUMMARY_MODE || printf '%b\n' "${TEST_GREEN}PASS${TEST_RESET}: am list --json: valid JSON"
    else
        ((TESTS_RUN++)); ((TESTS_FAILED++))
        printf '%b\n' "${TEST_RED}FAIL${TEST_RESET}: am list --json: invalid JSON"
        FAIL_DETAILS+=("FAIL: am list --json: invalid JSON")
    fi
    assert_contains "$json_output" "$session_name" "am list --json: contains session"
    assert_eq "claude" "$(echo "$json_output" | jq -r '.[0].agent_type')" \
        "am list --json: preserves agent_type when branch is empty"
    assert_eq "" "$(echo "$json_output" | jq -r '.[0].branch')" \
        "am list --json: preserves empty branch field"

    # --- Test: am list-internal returns session list for fzf ---
    local internal_output
    internal_output=$(AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" "$PROJECT_DIR/am" list-internal 2>/dev/null)
    assert_contains "$internal_output" "$session_name" "am list-internal: contains session"
    assert_contains "$internal_output" "[claude]" "am list-internal: contains agent type"

    # --- Test: am info <session> ---
    local info_output
    info_output=$(AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" "$PROJECT_DIR/am" info "$session_name" 2>/dev/null)
    assert_contains "$info_output" "Directory:" "am info: shows directory"
    assert_contains "$info_output" "Agent:" "am info: shows agent type"

    # --- Test: am peek snapshots agent and shell panes ---
    local peek_output=""
    for _i in $(seq 1 20); do
        peek_output=$(AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" "$PROJECT_DIR/am" peek "$session_name" 2>/dev/null)
        [[ "$peek_output" == *"stub-agent-ready"* ]] && break
        sleep 0.2
    done
    assert_contains "$peek_output" "stub-agent-ready" "am peek: captures agent pane"

    tmux_send_keys "$session_name:.{bottom}" "echo shell-peek-ready" Enter
    local shell_peek=""
    for _i in $(seq 1 20); do
        shell_peek=$(AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" "$PROJECT_DIR/am" peek --pane shell "$session_name" 2>/dev/null)
        [[ "$shell_peek" == *"shell-peek-ready"* ]] && break
        sleep 0.2
    done
    assert_contains "$shell_peek" "shell-peek-ready" "am peek --pane shell: captures shell pane"

    # --- Test: am kill <session> ---
    AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" "$PROJECT_DIR/am" kill "$session_name" 2>/dev/null
    assert_eq "false" "$(tmux_session_exists "$session_name" && echo true || echo false)" \
        "am kill: session removed"

    # --- Test: am attach nonexistent fails ---
    local attach_rc=0
    AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" "$PROJECT_DIR/am" attach nonexistent-xyz </dev/null 2>/dev/null || attach_rc=$?
    assert_eq "false" "$(test $attach_rc -eq 0 && echo true || echo false)" \
        "am attach nonexistent: exits with error"

    # --- Test: am kill with no args fails ---
    local kill_rc=0
    AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" "$PROJECT_DIR/am" kill </dev/null 2>/dev/null || kill_rc=$?
    assert_eq "false" "$(test $kill_rc -eq 0 && echo true || echo false)" \
        "am kill no args: exits with error"

    # --- Test: am status runs without error ---
    local status_rc=0
    AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" "$PROJECT_DIR/am" status >/dev/null 2>&1 || status_rc=$?
    assert_eq "true" "$(test $status_rc -eq 0 && echo true || echo false)" \
        "am status: exits 0"

    # --- Test: am config commands ---
    local config_output
    config_output=$(AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" "$PROJECT_DIR/am" config set agent codex 2>/dev/null)
    assert_contains "$config_output" "default_agent=codex" "am config set agent: persists default"

    local config_get
    config_get=$(AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" "$PROJECT_DIR/am" config get agent 2>/dev/null)
    assert_eq "codex" "$config_get" "am config get agent: returns saved default"

    config_get=$(AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" AM_DEFAULT_AGENT="gemini" "$PROJECT_DIR/am" config get agent 2>/dev/null)
    assert_eq "gemini" "$config_get" "am config get agent: env override wins"

    # --- Test: am config sandbox ---
    config_output=$(AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" "$PROJECT_DIR/am" config set sandbox true 2>/dev/null)
    assert_contains "$config_output" "default_sandbox=true" "am config set sandbox: persists default"
    config_get=$(AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" "$PROJECT_DIR/am" config get sandbox 2>/dev/null)
    assert_eq "true" "$config_get" "am config get sandbox: returns saved default"

    # --- Test: am send injects prompt text into running session ---
    session_name=$(set +u; agent_launch "$test_dir" "claude" "send test" 2>/dev/null)
    assert_not_empty "$session_name" "am send setup: session created"
    local send_rc=0
    AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" "$PROJECT_DIR/am" send "$session_name" "run tests now" >/dev/null 2>/dev/null || send_rc=$?
    assert_eq "0" "$send_rc" "am send: exits 0"
    local pane_output=""
    for _i in $(seq 1 20); do
        pane_output=$(am_tmux capture-pane -pt "$session_name:.{top}" 2>/dev/null || true)
        [[ "$pane_output" == *"stub-agent-input:run tests now"* ]] && break
        sleep 0.2
    done
    assert_contains "$pane_output" "stub-agent-input:run tests now" "am send: prompt reaches agent pane"
    [[ -n "$session_name" ]] && agent_kill "$session_name" 2>/dev/null

    # --- Test: am new --detach can pass initial prompt from stdin (piped to agent) ---
    local detached_session
    detached_session=$(printf 'initial prompt from stdin\n' | AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" "$PROJECT_DIR/am" new --detach --print-session --no-sandbox -t "$TEST_STUB_DIR/stub_agent" "$test_dir" 2>/dev/null)
    assert_not_empty "$detached_session" "am new --detach: returns session name"
    assert_eq "true" "$(tmux_session_exists "$detached_session" && echo true || echo false)" \
        "am new --detach: session created"

    pane_output=""
    for _i in $(seq 1 20); do
        pane_output=$(am_tmux capture-pane -pt "$detached_session:.{top}" 2>/dev/null || true)
        [[ "$pane_output" == *"stub-agent-input:initial prompt from stdin"* ]] && break
        sleep 0.2
    done
    assert_contains "$pane_output" "stub-agent-input:initial prompt from stdin" \
        "am new --detach: stdin prompt piped to agent"
    [[ -n "$detached_session" ]] && agent_kill "$detached_session" 2>/dev/null

    # Cleanup
    rm -rf "$test_dir"
    teardown_integration_env

    $SUMMARY_MODE || echo ""
}

test_cli_yolo_sandbox_integration() {
    $SUMMARY_MODE || echo "=== Testing CLI yolo/sandbox integration ==="

    if ! command -v jq &>/dev/null || ! command -v tmux &>/dev/null; then
        skip_test "cli yolo/sandbox tests (jq or tmux not installed)"
        echo ""
        return
    fi

    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/config.sh"
    source "$LIB_DIR/tmux.sh"
    source "$LIB_DIR/registry.sh"
    set +u; source "$LIB_DIR/agents.sh"; set -u

    setup_integration_env

    local test_dir
    test_dir=$(mktemp -d)

    # --- Test: am new --yolo implies sandbox ---
    local session_name
    session_name=$(AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" \
        "$PROJECT_DIR/am" new --yolo --detach --print-session -t "$TEST_STUB_DIR/stub_agent" "$test_dir" </dev/null 2>/dev/null)
    assert_not_empty "$session_name" "cli yolo: session created"
    assert_eq "true" "$(registry_get_field "$session_name" yolo_mode)" \
        "cli yolo: yolo_mode is true"
    assert_not_empty "$(registry_get_field "$session_name" container_name)" \
        "cli yolo: implies sandbox (container created)"
    [[ -n "$session_name" ]] && agent_kill "$session_name" 2>/dev/null

    # --- Test: am new --yolo --no-sandbox opts out of implied sandbox ---
    session_name=$(AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" \
        "$PROJECT_DIR/am" new --yolo --no-sandbox --detach --print-session -t "$TEST_STUB_DIR/stub_agent" "$test_dir" </dev/null 2>/dev/null)
    assert_not_empty "$session_name" "cli yolo-no-sandbox: session created"
    assert_eq "true" "$(registry_get_field "$session_name" yolo_mode)" \
        "cli yolo-no-sandbox: yolo_mode is true"
    assert_eq "" "$(registry_get_field "$session_name" container_name)" \
        "cli yolo-no-sandbox: sandbox opted out"
    [[ -n "$session_name" ]] && agent_kill "$session_name" 2>/dev/null

    # --- Test: am new --sandbox without docker fails ---
    local sandbox_rc=0
    AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" AM_DOCKER_AVAILABLE="false" \
        "$PROJECT_DIR/am" new --sandbox --detach --print-session -t "$TEST_STUB_DIR/stub_agent" "$test_dir" \
        </dev/null >/dev/null 2>/dev/null || sandbox_rc=$?
    assert_eq "false" "$(test $sandbox_rc -eq 0 && echo true || echo false)" \
        "cli sandbox-no-docker: fails when docker unavailable"

    # --- Test: am new --yolo --sandbox enables both independently ---
    session_name=$(AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" \
        "$PROJECT_DIR/am" new --yolo --sandbox --detach --print-session -t "$TEST_STUB_DIR/stub_agent" "$test_dir" </dev/null 2>/dev/null) || true
    if [[ -n "$session_name" ]]; then
        assert_eq "true" "$(registry_get_field "$session_name" yolo_mode)" \
            "cli yolo+sandbox: yolo_mode is true"
        assert_eq "true" "$(registry_get_field "$session_name" sandbox_mode)" \
            "cli yolo+sandbox: sandbox_mode is true"
        agent_kill "$session_name" 2>/dev/null
    else
        # If docker unavailable, sandbox creation fails — that's expected
        skip_test "cli yolo+sandbox: skipped (docker unavailable)"
    fi

    # --- Test: config default_sandbox applies ---
    am_config_set "default_sandbox" "false" "boolean"
    session_name=$(AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" \
        "$PROJECT_DIR/am" new --detach --print-session -t "$TEST_STUB_DIR/stub_agent" "$test_dir" </dev/null 2>/dev/null)
    assert_not_empty "$session_name" "cli sandbox-default-off: session created"
    assert_eq "" "$(registry_get_field "$session_name" container_name)" \
        "cli sandbox-default-off: no container when default_sandbox=false"
    assert_eq "false" "$(registry_get_field "$session_name" sandbox_mode)" \
        "cli sandbox-default-off: sandbox_mode is false"
    [[ -n "$session_name" ]] && agent_kill "$session_name" 2>/dev/null

    # --- Test: --no-sandbox overrides config default ---
    am_config_set "default_sandbox" "true" "boolean"
    session_name=$(AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" \
        "$PROJECT_DIR/am" new --no-sandbox --detach --print-session -t "$TEST_STUB_DIR/stub_agent" "$test_dir" </dev/null 2>/dev/null)
    assert_not_empty "$session_name" "cli no-sandbox-override: session created"
    assert_eq "" "$(registry_get_field "$session_name" container_name)" \
        "cli no-sandbox-override: no container with --no-sandbox"
    assert_eq "false" "$(registry_get_field "$session_name" sandbox_mode)" \
        "cli no-sandbox-override: sandbox_mode is false"
    [[ -n "$session_name" ]] && agent_kill "$session_name" 2>/dev/null

    # --- Test: --no-yolo overrides config default ---
    am_config_set "default_yolo" "true" "boolean"
    session_name=$(AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" \
        "$PROJECT_DIR/am" new --no-yolo --detach --print-session -t "$TEST_STUB_DIR/stub_agent" "$test_dir" </dev/null 2>/dev/null)
    assert_not_empty "$session_name" "cli no-yolo-override: session created"
    assert_eq "false" "$(registry_get_field "$session_name" yolo_mode)" \
        "cli no-yolo-override: yolo_mode is false with --no-yolo"
    [[ -n "$session_name" ]] && agent_kill "$session_name" 2>/dev/null

    rm -rf "$test_dir"
    teardown_integration_env

    $SUMMARY_MODE || echo ""
}

run_cli_tests() {
    _run_test test_cli
    _run_test test_cli_extended
    _run_test test_cli_yolo_sandbox_integration
}

if [[ -z "${_AM_TEST_RUNNER:-}" ]]; then
    set -uo pipefail
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helpers.sh"
    check_deps
    run_cli_tests
    test_report
fi
