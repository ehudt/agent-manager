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
    assert_contains "$new_help" "cursor" "am new --help: lists Cursor agent"
    assert_contains "$new_help" "-W, --workspace" "am new --help: shows workspace flag"
    assert_not_contains "$new_help" "--yolo" "am new --help: no yolo flag"
    assert_not_contains "$new_help" "--sandbox" "am new --help: no sandbox flag"
    assert_not_contains "$new_help" "--worktree" "am new --help: no worktree flag"
    assert_not_contains "$help_output" "sandbox" "am help: no sandbox command"

    # Removed manager flags are rejected rather than silently forwarded
    local rc=0
    "$PROJECT_DIR/am" new --sandbox /tmp </dev/null >/dev/null 2>&1 || rc=$?
    assert_eq "1" "$rc" "am new --sandbox: unknown option"
    rc=0
    "$PROJECT_DIR/am" new -w /tmp </dev/null >/dev/null 2>&1 || rc=$?
    assert_eq "1" "$rc" "am new -w: unknown option"
    rc=0
    "$PROJECT_DIR/am" sb ps </dev/null >/dev/null 2>&1 || rc=$?
    assert_eq "1" "$rc" "am sb: unknown command"

    local send_help
    send_help=$("$PROJECT_DIR/am" send --help)
    assert_contains "$send_help" "Usage: am send" "am send --help: shows usage"
    assert_contains "$send_help" "--wait" "am send --help: documents wait flag"
    assert_contains "$send_help" "--timeout" "am send --help: documents timeout flag"
    assert_contains "$send_help" "ready" \
        "am send --help: --wait promises the canonical ready state"
    assert_not_contains "$send_help" "waiting_permission" \
        "am send --help: does not call a permission dialog ready"

    local wait_help
    wait_help=$("$PROJECT_DIR/am" wait --help)
    assert_contains "$wait_help" "ready" "am wait --help: lists ready"
    assert_contains "$wait_help" "waiting_user" "am wait --help: lists waiting_user"
    assert_contains "$wait_help" "background" "am wait --help: lists background"
    assert_contains "$wait_help" "legacy aliases" \
        "am wait --help: documents legacy state aliases"

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

    # Create a session for testing against (--shell: the peek tests below
    # exercise the shell pane, which is opt-in since 0.16)
    local session_name
    session_name=$(set +u; agent_launch "$test_dir" "claude" "cli test" --shell 2>/dev/null)

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
    assert_not_contains "$info_output" "Yolo:" "am info: no yolo line"
    assert_not_contains "$info_output" "Sandbox:" "am info: no sandbox line"

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

    # --- Test: am peek --pane shell errors clearly on an agent-only session ---
    local noshell_session
    noshell_session=$(set +u; agent_launch "$test_dir" "claude" "no shell" 2>/dev/null)
    if [[ -n "$noshell_session" ]]; then
        local noshell_err
        noshell_err=$(AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" \
            "$PROJECT_DIR/am" peek --pane shell "$noshell_session" 2>&1 || true)
        assert_contains "$noshell_err" "no shell pane" \
            "am peek --pane shell: explains missing shell pane"
        assert_contains "$noshell_err" "am shell" \
            "am peek --pane shell: suggests am shell"
        agent_kill "$noshell_session" 2>/dev/null
    else
        skip_test "am peek --pane shell error (agent_launch failed)"
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

    config_output=$(AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" "$PROJECT_DIR/am" config set agent cursor-agent 2>/dev/null)
    assert_contains "$config_output" "default_agent=cursor" \
        "am config set agent: canonicalizes cursor-agent alias"
    assert_eq "cursor" "$(jq -r '.default_agent' "$TEST_AM_DIR/config.json")" \
        "am config set agent: stores canonical Cursor type"

    config_get=$(AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" AM_DEFAULT_AGENT="claude" "$PROJECT_DIR/am" config get agent 2>/dev/null)
    assert_eq "claude" "$config_get" "am config get agent: env override wins"

    # --- Test: removed config keys are rejected ---
    local config_rc=0
    AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" "$PROJECT_DIR/am" config set sandbox true >/dev/null 2>&1 || config_rc=$?
    assert_eq "1" "$config_rc" "am config set sandbox: unknown key"
    config_rc=0
    AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" "$PROJECT_DIR/am" config get yolo >/dev/null 2>&1 || config_rc=$?
    assert_eq "1" "$config_rc" "am config get yolo: unknown key"

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
    detached_session=$(printf 'initial prompt from stdin\n' | AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" "$PROJECT_DIR/am" new --detach --print-session -t "$TEST_STUB_DIR/stub_agent" "$test_dir" 2>/dev/null)
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

test_cli_workspace_and_id() {
    $SUMMARY_MODE || echo "=== Testing am new -W and am id ==="

    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/config.sh"
    source "$LIB_DIR/tmux.sh"
    source "$LIB_DIR/registry.sh"
    set +u; source "$LIB_DIR/agents.sh"; set -u

    setup_integration_env

    local test_dir
    test_dir=$(mktemp -d)
    local am_env=(AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" AM_SESSION_NAME= TMUX=)

    # --- am id: outside any session ---
    local rc=0
    env "${am_env[@]}" "$PROJECT_DIR/am" id >/dev/null 2>&1 </dev/null || rc=$?
    assert_eq "1" "$rc" "am id: exits 1 outside an am session"

    # --- am id: inside (AM_SESSION_NAME seeded into every pane) ---
    assert_eq "test-am-abc123" "$(env "${am_env[@]}" AM_SESSION_NAME=test-am-abc123 "$PROJECT_DIR/am" id 2>/dev/null)" \
        "am id: prints AM_SESSION_NAME"
    assert_eq "test-am-abc123" "$(env "${am_env[@]}" AM_SESSION_NAME=test-am-abc123 "$PROJECT_DIR/am" whoami 2>/dev/null)" \
        "am whoami: alias of am id"
    rc=0
    env "${am_env[@]}" AM_SESSION_NAME=other-prefix-1 "$PROJECT_DIR/am" id >/dev/null 2>&1 || rc=$?
    assert_eq "1" "$rc" "am id: rejects a name outside the am prefix"

    # --- am new -W without workspace_cmd: fails with guidance ---
    rc=0
    local err
    err=$(env "${am_env[@]}" AM_WORKSPACE_CMD= "$PROJECT_DIR/am" new -W --detach --print-session -t "$TEST_STUB_DIR/stub_agent" 2>&1 </dev/null) || rc=$?
    assert_eq "1" "$rc" "am new -W: fails when workspace_cmd is unset"
    assert_contains "$err" "workspace_cmd" "am new -W: error names the config key"

    # --- am new -W plus a directory: rejected ---
    rc=0
    err=$(env "${am_env[@]}" AM_WORKSPACE_CMD="echo $test_dir" "$PROJECT_DIR/am" new -W --detach --print-session -t "$TEST_STUB_DIR/stub_agent" "$test_dir" 2>&1 </dev/null) || rc=$?
    assert_eq "1" "$rc" "am new -W <dir>: rejected"
    assert_contains "$err" "drop the directory" "am new -W <dir>: explains the conflict"

    # --- am new -W <branch>: the command sees AM_BRANCH and supplies the directory ---
    local ws_cmd="mkdir -p '$test_dir/ws-'\"\${AM_BRANCH:-trunk}\" && echo '$test_dir/ws-'\"\${AM_BRANCH:-trunk}\""
    local session_name
    session_name=$(env "${am_env[@]}" AM_WORKSPACE_CMD="$ws_cmd" "$PROJECT_DIR/am" new -W feature-x --detach --print-session -t "$TEST_STUB_DIR/stub_agent" </dev/null 2>/dev/null)
    assert_not_empty "$session_name" "am new -W <branch>: session created"
    assert_eq "$test_dir/ws-feature-x" "$(registry_get_field "$session_name" directory)" \
        "am new -W <branch>: session runs in the allocated directory"
    [[ -n "$session_name" ]] && agent_kill "$session_name" 2>/dev/null

    # --- args after -- reach the agent untouched ---
    session_name=$(env "${am_env[@]}" AM_WORKSPACE_CMD="$ws_cmd" "$PROJECT_DIR/am" new -W --detach --print-session -t "$TEST_STUB_DIR/stub_agent" -- --stub-extra </dev/null 2>/dev/null)
    assert_not_empty "$session_name" "am new -- extra: session created"
    local extra_pane
    extra_pane=$(wait_for_text "stub-extra" am_tmux capture-pane -pt "$session_name:.{top}" -S -)
    assert_contains "$extra_pane" "stub-extra" "am new -- extra: agent receives the extra arg"
    [[ -n "$session_name" ]] && agent_kill "$session_name" 2>/dev/null

    # --- am new -W with no branch: AM_BRANCH is empty ---
    session_name=$(env "${am_env[@]}" AM_WORKSPACE_CMD="$ws_cmd" "$PROJECT_DIR/am" new -W --detach --print-session -t "$TEST_STUB_DIR/stub_agent" </dev/null 2>/dev/null)
    assert_not_empty "$session_name" "am new -W: session created without a branch"
    assert_eq "$test_dir/ws-trunk" "$(registry_get_field "$session_name" directory)" \
        "am new -W: empty AM_BRANCH reaches the command"
    [[ -n "$session_name" ]] && agent_kill "$session_name" 2>/dev/null

    # --- a command that prints no directory fails cleanly ---
    rc=0
    err=$(env "${am_env[@]}" AM_WORKSPACE_CMD="echo /nonexistent/$$" "$PROJECT_DIR/am" new -W --detach --print-session -t "$TEST_STUB_DIR/stub_agent" 2>&1 </dev/null) || rc=$?
    assert_eq "1" "$rc" "am new -W: bad command output fails"
    assert_contains "$err" "did not print an existing directory" "am new -W: reports the bad output"

    rm -rf "$test_dir"
    teardown_integration_env

    $SUMMARY_MODE || echo ""
}

run_cli_tests() {
    _run_test test_cli
    _run_test test_cli_workspace_and_id
    _run_test test_cli_extended
}

if [[ -z "${_AM_TEST_RUNNER:-}" ]]; then
    set -uo pipefail
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helpers.sh"
    check_deps
    run_cli_tests
    test_report
fi
