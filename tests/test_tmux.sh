#!/usr/bin/env bash
# tests/test_tmux.sh - Tests for lib/tmux.sh

test_tmux() {
    $SUMMARY_MODE || echo "=== Testing tmux.sh ==="

    if ! command -v tmux &>/dev/null; then
        skip_test "tmux tests (tmux not installed)"
        echo ""
        return
    fi

    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/tmux.sh"

    # Test session_exists for non-existent session
    assert_eq "false" "$(tmux_session_exists 'nonexistent-test-session-xyz' && echo true || echo false)" "tmux_session_exists: false for missing"

    # Test create and kill (only if not in CI/restricted env)
    local test_session="am-test-$$"
    if tmux_create_session "$test_session" "/tmp"; then
        assert_eq "true" "$(tmux_session_exists "$test_session" && echo true || echo false)" "tmux_create_session: creates session"

        # Cleanup
        tmux_kill_session "$test_session"
        assert_eq "false" "$(tmux_session_exists "$test_session" && echo true || echo false)" "tmux_kill_session: removes session"
    else
        skip_test "tmux create/kill tests (unable to create session)"
    fi

    $SUMMARY_MODE || echo ""
}

test_tmux_listing() {
    $SUMMARY_MODE || echo "=== Testing tmux listing ==="

    if ! command -v jq &>/dev/null || ! command -v tmux &>/dev/null; then
        skip_test "tmux listing tests (jq or tmux not installed)"
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

    # Test: count is 0 before any sessions
    local count
    count=$(tmux_count_am_sessions)
    assert_eq "0" "$count" "tmux_count: zero before sessions"

    # Test: list is empty before any sessions
    local list
    list=$(tmux_list_am_sessions)
    assert_eq "" "$list" "tmux_list: empty before sessions"

    # Create two sessions
    local s1 s2
    s1=$(set +u; agent_launch "$test_dir" "claude" "" 2>/dev/null)
    s2=$(set +u; agent_launch "$test_dir" "claude" "" 2>/dev/null)

    # Test: count is 2
    count=$(tmux_count_am_sessions)
    assert_eq "2" "$count" "tmux_count: two sessions"

    # Test: list contains both sessions
    list=$(tmux_list_am_sessions)
    assert_contains "$list" "$s1" "tmux_list: contains first session"
    assert_contains "$list" "$s2" "tmux_list: contains second session"

    # Test: list_with_activity returns both, sorted by activity
    local activity_list
    activity_list=$(tmux_list_am_sessions_with_activity)
    assert_contains "$activity_list" "$s1" "tmux_list_with_activity: contains first"
    assert_contains "$activity_list" "$s2" "tmux_list_with_activity: contains second"

    # Kill one, count should drop
    [[ -n "$s1" ]] && agent_kill "$s1" 2>/dev/null
    count=$(tmux_count_am_sessions)
    assert_eq "1" "$count" "tmux_count: one after kill"

    # Cleanup
    [[ -n "$s2" ]] && agent_kill "$s2" 2>/dev/null
    rm -rf "$test_dir"
    teardown_integration_env

    $SUMMARY_MODE || echo ""
}

test_tmux_binding_snippets() {
    $SUMMARY_MODE || echo "=== Testing tmux binding snippets ==="

    local example_conf
    example_conf=$(cat "$PROJECT_DIR/config/tmux.conf.example")
    assert_contains "$example_conf" "source-file \"\$HOME/.tmux.conf\"" \
        "tmux snippet: sources base tmux config"
    assert_contains "$example_conf" "set -g detach-on-destroy off" \
        "tmux snippet: keeps clients inside agent-manager when sessions are killed"
    assert_contains "$example_conf" 'bind n if-shell -F '\''#{m:am-*,#{session_name}}'\'' '\''display-popup -E -w 90% -h 80% "am new"'\''' \
        "tmux snippet: prefix+n opens new-session popup"
    assert_contains "$example_conf" 'bind-key -T prefix x if-shell -F '\''#{m:am-*,#{session_name}}'\'' '\''run-shell "kill-and-switch #{client_name} #{session_name}"'\'' '\''confirm-before -p "kill-pane #P? (y/n)" kill-pane'\''' \
        "tmux snippet: prefix+x kills current session"
    assert_contains "$example_conf" 'dedicated server' \
        "tmux snippet: prefix+x documents default fallback"

    local install_script
    install_script=$(cat "$PROJECT_DIR/scripts/install.sh")
    assert_contains "$install_script" 'Remove legacy agent-manager bindings from $TMUX_CONF?' \
        "install script: prompts to clean legacy tmux bindings"
    assert_contains "$install_script" 'agent-manager now uses its own tmux server/socket' \
        "install script: documents dedicated tmux server"

    local fzf_script
    fzf_script=$(cat "$PROJECT_DIR/lib/fzf.sh")
    assert_contains "$fzf_script" "tmux_client_name=\$(am_tmux display-message -p '#{client_name}' 2>/dev/null || true)" \
        "fzf: resolves tmux client name before binding ctrl-x"
    assert_contains "$fzf_script" 'ctrl-x:execute-silent($lib_dir/../bin/kill-and-switch $tmux_client_name {1})+reload($list_cmd)' \
        "fzf: ctrl-x passes resolved client name to kill-and-switch"

    $SUMMARY_MODE || echo ""
}

test_tmux_config_refreshes_stale_helpers() {
    $SUMMARY_MODE || echo "=== Testing tmux config refresh ==="

    if ! command -v tmux &>/dev/null; then
        skip_test "tmux config refresh test (tmux not installed)"
        echo ""
        return
    fi

    local temp_am_dir temp_conf rendered_conf
    temp_am_dir=$(mktemp -d)
    temp_conf="$temp_am_dir/tmux.conf"

    cat > "$temp_conf" <<'EOF'
# Generated by agent-manager. Edit ~/.tmux.conf for your base tmux settings.
bind a if-shell -F '#{m:am-*,#{session_name}}' 'run-shell "switch-last"' 'display-message "am shortcuts are active only in am-* sessions"'
bind-key -T prefix x if-shell -F '#{m:am-*,#{session_name}}' 'run-shell "kill-and-switch #{client_name} #{session_name}"' 'confirm-before -p "kill-pane #P? (y/n)" kill-pane'
EOF

    AM_DIR="$temp_am_dir" \
    AM_TMUX_CONF="$temp_conf" \
    AM_ROOT_DIR="$PROJECT_DIR" \
    bash -lc '
        source "$1/lib/utils.sh"
        source "$1/lib/tmux.sh"
        am_tmux_config_path >/dev/null
    ' _ "$PROJECT_DIR"

    rendered_conf=$(cat "$temp_conf")
    assert_contains "$rendered_conf" "run-shell \"$PROJECT_DIR/bin/switch-last\"" \
        "tmux config refresh: rewrites prefix+a helper to absolute path"
    assert_contains "$rendered_conf" "run-shell \"$PROJECT_DIR/bin/kill-and-switch #{client_name} #{session_name}\"" \
        "tmux config refresh: rewrites prefix+x helper to absolute path"
    assert_cmd_fails "tmux config refresh: removes bare switch-last helper" \
        grep -Fq 'run-shell "switch-last"' "$temp_conf"
    assert_cmd_fails "tmux config refresh: removes bare kill-and-switch helper" \
        grep -Fq 'run-shell "kill-and-switch #{client_name} #{session_name}"' "$temp_conf"

    rm -rf "$temp_am_dir"
    $SUMMARY_MODE || echo ""
}

run_tmux_tests() {
    _run_test test_tmux
    _run_test test_tmux_listing
    _run_test test_tmux_binding_snippets
    _run_test test_tmux_config_refreshes_stale_helpers
}

if [[ -z "${_AM_TEST_RUNNER:-}" ]]; then
    set -uo pipefail
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helpers.sh"
    check_deps
    run_tmux_tests
    test_report
fi
