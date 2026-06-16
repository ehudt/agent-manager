#!/usr/bin/env bash
# tests/test_cli.sh - Tests for the `am` entry point

test_cli() {
    $SUMMARY_MODE || echo "=== Testing am CLI ==="

    # Test help — one smoke assertion per command's help, plus the behavioral
    # hidden-flag checks (hidden flags must stay hidden).
    local help_output
    help_output=$("$PROJECT_DIR/am" help)
    assert_contains "$help_output" "Agent Manager" "am help: shows title"
    assert_contains "$help_output" "USAGE" "am help: shows usage"

    local new_help
    new_help=$("$PROJECT_DIR/am" new --help)
    assert_contains "$new_help" "-t, --type" "am new --help: shows flags"
    assert_not_contains "$new_help" "--yolo" "am new --help: hides yolo flag"
    assert_not_contains "$new_help" "--no-yolo" "am new --help: hides no-yolo flag"
    assert_not_contains "$new_help" "--no-worktree" "am new --help: hides no-worktree flag"

    local send_help
    send_help=$("$PROJECT_DIR/am" send --help)
    assert_contains "$send_help" "Usage: am send" "am send --help: shows usage"
    assert_contains "$send_help" "--wait" "am send --help: documents wait flag"
    assert_contains "$send_help" "--timeout" "am send --help: documents timeout flag"

    local peek_help
    peek_help=$("$PROJECT_DIR/am" peek --help)
    assert_contains "$peek_help" "--pane" "am peek --help: shows pane flag"
    assert_not_contains "$peek_help" "--json" "am peek --help: hides json flag"
    assert_not_contains "$peek_help" "--history" "am peek --help: hides history flag"
    assert_not_contains "$peek_help" "--grep" "am peek --help: hides grep flag"

    local status_help
    status_help=$("$PROJECT_DIR/am" status --help)
    assert_contains "$status_help" "--json" "am status --help: shows json flag"
    assert_not_contains "$status_help" "--wait" "am status --help: does not show unrelated flags"
    assert_not_contains "$status_help" "--timeout" "am status --help: does not show unrelated flags"

    # Test version
    local version_output
    version_output=$("$PROJECT_DIR/am" version)
    assert_contains "$version_output" "am version " "am version: shows version"

    $SUMMARY_MODE || echo ""
}

test_cli_extended() {
    $SUMMARY_MODE || echo "=== Testing CLI commands (extended) ==="

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
    assert_cmd_succeeds "am list --json: valid JSON" jq . <<< "$json_output"
    assert_contains "$json_output" "$session_name" "am list --json: contains session"
    assert_eq "claude" "$(echo "$json_output" | jq -r '.[0].agent_type')" \
        "am list --json: preserves agent_type when branch is empty"
    assert_eq "" "$(echo "$json_output" | jq -r '.[0].branch')" \
        "am list --json: preserves empty branch field"

    # --- Test: list helpers share one row collection shape ---
    set +u
    source "$LIB_DIR/fzf.sh"
    set -u
    local row_output
    row_output=$(AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" _fzf_session_rows 2>/dev/null || true)
    assert_contains "$row_output" "$session_name" "list row collector: contains session"

    local row_line
    row_line=$(printf '%s\n' "$row_output" | head -n1)
    assert_not_empty "$row_line" "list row collector: emits a row"

    local row_name row_state row_dir row_branch row_agent row_task row_activity row_created
    IFS=$'\x1f' read -r row_name row_state row_dir row_branch row_agent row_task row_activity row_created <<< "$row_line"
    assert_eq "$session_name" "$row_name" "list row collector: name field"
    assert_not_empty "$row_state" "list row collector: state field"
    assert_eq "$test_dir" "$row_dir" "list row collector: directory field"
    assert_eq "" "$row_branch" "list row collector: branch field"
    assert_eq "claude" "$row_agent" "list row collector: agent field"
    assert_eq "cli test" "$row_task" "list row collector: task field"
    assert_not_empty "$row_activity" "list row collector: activity field"
    assert_not_empty "$row_created" "list row collector: created field"

    # --- Test: am list-internal returns session list for the browser ---
    if [[ -x "$PROJECT_DIR/bin/am-list-internal" && -s "$PROJECT_DIR/bin/am-list-internal" ]]; then
        local internal_output
        internal_output=$(AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" "$PROJECT_DIR/am" list-internal 2>/dev/null)
        assert_contains "$internal_output" "$session_name" "am list-internal: contains session"
        assert_contains "$internal_output" "[claude]" "am list-internal: contains agent type"
    else
        skip_test "am list-internal (bin/am-list-internal not built — run 'make build')"
    fi

    # --- Test: am info <session> ---
    local info_output
    info_output=$(AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" "$PROJECT_DIR/am" info "$session_name" 2>/dev/null)
    assert_contains "$info_output" "Directory:" "am info: shows directory"
    assert_contains "$info_output" "Agent:" "am info: shows agent type"

    # --- Test: am peek snapshots agent and shell panes ---
    local peek_output
    peek_output=$(wait_for_text "stub-agent-ready" \
        env AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" "$PROJECT_DIR/am" peek "$session_name")
    assert_contains "$peek_output" "stub-agent-ready" "am peek: captures agent pane"

    tmux_send_keys "$session_name:.{bottom}" "echo shell-peek-ready" Enter
    local shell_peek
    shell_peek=$(wait_for_text "shell-peek-ready" \
        env AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" "$PROJECT_DIR/am" peek --pane shell "$session_name")
    assert_contains "$shell_peek" "shell-peek-ready" "am peek --pane shell: captures shell pane"

    tmux_send_keys "$session_name:.{bottom}" 'prefix=shell-tail-; printf "%s%s\n%s%s" "$prefix" old "$prefix" new; sleep 60' Enter
    local shell_tail
    shell_tail=$(wait_for_text "shell-tail-new" \
        env AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" "$PROJECT_DIR/am" peek --pane shell --lines 1 "$session_name")
    assert_contains "$shell_tail" "shell-tail-new" "am peek --lines: captures requested tail"
    assert_not_contains "$shell_tail" "shell-tail-old" "am peek --lines: excludes older output"

    local follow_log="/tmp/am-logs/${session_name}/shell.log"
    if [[ -f "$follow_log" ]]; then
        printf 'follow-tail-old\nfollow-tail-new\n' >> "$follow_log"
        local follow_file follow_pid follow_output
        follow_file=$(mktemp)
        AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" "$PROJECT_DIR/am" peek --pane shell --follow --lines 1 "$session_name" >"$follow_file" 2>/dev/null &
        follow_pid=$!
        wait_for_text "follow-tail-new" cat "$follow_file" >/dev/null
        kill "$follow_pid" 2>/dev/null || true
        wait "$follow_pid" 2>/dev/null || true
        follow_output=$(cat "$follow_file" 2>/dev/null || true)
        rm -f "$follow_file"
        assert_contains "$follow_output" "follow-tail-new" "am peek --follow --lines: seeds requested tail"
        assert_not_contains "$follow_output" "follow-tail-old" "am peek --follow --lines: excludes older log output"
    else
        skip_test "am peek --follow --lines: log streaming disabled"
    fi

    # --- Test: am status <session> shows detailed info plus state ---
    local status_output
    status_output=$(AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" "$PROJECT_DIR/am" status "$session_name" 2>/dev/null)
    assert_contains "$status_output" "Directory:" "am status <session>: shows directory"
    assert_contains "$status_output" "Agent:" "am status <session>: shows agent type"
    assert_contains "$status_output" "State:" "am status <session>: shows state"

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

    config_get=$(AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" AM_DEFAULT_AGENT="claude" "$PROJECT_DIR/am" config get agent 2>/dev/null)
    assert_eq "claude" "$config_get" "am config get agent: env override wins"

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
    local pane_output
    pane_output=$(wait_for_text "stub-agent-input:run tests now" \
        am_tmux capture-pane -pt "$session_name:.{top}")
    assert_contains "$pane_output" "stub-agent-input:run tests now" "am send: prompt reaches agent pane"
    [[ -n "$session_name" ]] && agent_kill "$session_name" 2>/dev/null

    # --- Test: am new --detach can pass initial prompt from stdin (piped to agent) ---
    local detached_session
    detached_session=$(printf 'initial prompt from stdin\n' | AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" "$PROJECT_DIR/am" new --detach --print-session --no-sandbox -t "$TEST_STUB_DIR/stub_agent" "$test_dir" 2>/dev/null)
    assert_not_empty "$detached_session" "am new --detach: returns session name"
    assert_eq "true" "$(tmux_session_exists "$detached_session" && echo true || echo false)" \
        "am new --detach: session created"

    pane_output=$(wait_for_text "stub-agent-input:initial prompt from stdin" \
        am_tmux capture-pane -pt "$detached_session:.{top}")
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

    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/config.sh"
    source "$LIB_DIR/tmux.sh"
    source "$LIB_DIR/registry.sh"
    set +u; source "$LIB_DIR/agents.sh"; set -u

    setup_integration_env

    local test_dir
    test_dir=$(mktemp -d)

    local docker_available=false
    am_docker_available && docker_available=true

    # --- Test: am new --yolo implies sandbox ---
    local session_name
    session_name=$(AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" \
        "$PROJECT_DIR/am" new --yolo --detach --print-session -t "$TEST_STUB_DIR/stub_agent" "$test_dir" </dev/null 2>/dev/null)
    assert_not_empty "$session_name" "cli yolo: session created"
    assert_eq "true" "$(registry_get_field "$session_name" yolo_mode)" \
        "cli yolo: yolo_mode is true"
    if $docker_available; then
        assert_not_empty "$(registry_get_field "$session_name" container_name)" \
            "cli yolo: implies sandbox (container created)"
    else
        assert_eq "" "$(registry_get_field "$session_name" container_name)" \
            "cli yolo: skips implied sandbox when docker unavailable"
    fi
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

    # --- Test: manager flags before -- survive agent extra args ---
    local sandbox_extra_rc=0 sandbox_extra_output
    sandbox_extra_output=$(AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" AM_DOCKER_AVAILABLE="false" \
        "$PROJECT_DIR/am" new --sandbox --detach --print-session -t "$TEST_STUB_DIR/stub_agent" "$test_dir" -- --stub-extra \
        </dev/null 2>/dev/null) || sandbox_extra_rc=$?
    [[ -n "$sandbox_extra_output" ]] && agent_kill "$sandbox_extra_output" 2>/dev/null
    assert_eq "false" "$(test $sandbox_extra_rc -eq 0 && echo true || echo false)" \
        "cli sandbox-extra-args-no-docker: preserves sandbox before --"

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
    am_config_set "default_sandbox" "false" "boolean"
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
