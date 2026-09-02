#!/usr/bin/env bash
# tests/test_agents.sh - Tests for lib/agents.sh

test_agents() {
    $SUMMARY_MODE || echo "=== Testing agents.sh ==="

    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/registry.sh"
    source "$LIB_DIR/tmux.sh"
    set +u; source "$LIB_DIR/agents.sh"; set -u

    # Test detect_git_branch
    # Just check it doesn't error; value is unused
    detect_git_branch "$PROJECT_DIR" >/dev/null
    assert_cmd_succeeds "detect_git_branch: runs without error" detect_git_branch "$PROJECT_DIR"

    # Test generate_session_name
    local name
    name=$(generate_session_name "/tmp/test")
    assert_contains "$name" "am-" "generate_session_name: has prefix"
    assert_eq 9 "${#name}" "generate_session_name: correct length (am- + 6 chars)"

    # Test agent_get_command
    assert_eq "claude" "$(agent_get_command claude)" "agent_get_command: claude"
    assert_eq "codex" "$(agent_get_command codex)" "agent_get_command: codex"
    assert_eq "agent" "$(agent_get_command cursor)" "agent_get_command: cursor"
    assert_eq "cursor" "$(agent_normalize_type cursor-agent)" \
        "agent_normalize_type: cursor-agent alias"

    # Test _agent_prompt_as_arg
    assert_eq "true" "$(_agent_prompt_as_arg codex && echo true || echo false)" \
        "_agent_prompt_as_arg: codex uses CLI arg"
    assert_eq "false" "$(_agent_prompt_as_arg claude && echo true || echo false)" \
        "_agent_prompt_as_arg: claude uses stdin"
    assert_eq "true" "$(_agent_prompt_as_arg cursor && echo true || echo false)" \
        "_agent_prompt_as_arg: cursor uses CLI arg"

    # --- pi agent type ---
    assert_eq "pi" "$(agent_get_command pi)" "agent_get_command: pi"
    assert_eq "true" "$(agent_type_supported pi && echo true || echo false)" \
        "agent_type_supported: pi"
    assert_eq "true" "$(_agent_prompt_as_arg pi && echo true || echo false)" \
        "_agent_prompt_as_arg: pi takes prompt as arg"

    # --- agent_resume_args ---
    assert_eq "--resume|abc123" "$(agent_resume_args claude abc123 | paste -sd'|' -)" \
        "agent_resume_args: claude"
    assert_eq "--resume|abc123" "$(agent_resume_args cursor abc123 | paste -sd'|' -)" \
        "agent_resume_args: cursor"
    assert_eq "--session|abc123" "$(agent_resume_args pi abc123 | paste -sd'|' -)" \
        "agent_resume_args: pi"
    assert_eq "resume|abc123" "$(agent_resume_args codex abc123 | paste -sd'|' -)" \
        "agent_resume_args: codex"

    $SUMMARY_MODE || echo ""
}

test_agents_extended() {
    $SUMMARY_MODE || echo "=== Testing agents.sh (extended) ==="

    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/tmux.sh"
    source "$LIB_DIR/registry.sh"
    set +u; source "$LIB_DIR/agents.sh"; set -u

    # Test agent_type_supported
    assert_eq "true" "$(agent_type_supported claude && echo true || echo false)" \
        "agent_type_supported: claude"
    assert_eq "true" "$(agent_type_supported codex && echo true || echo false)" \
        "agent_type_supported: codex"
    assert_eq "true" "$(agent_type_supported cursor && echo true || echo false)" \
        "agent_type_supported: cursor"
    assert_eq "true" "$(agent_type_supported cursor-agent && echo true || echo false)" \
        "agent_type_supported: cursor-agent alias"
    assert_eq "false" "$( (agent_type_supported bogus) 2>/dev/null && echo true || echo false)" \
        "agent_type_supported: bogus rejected"

    # Test generate_session_name: different dirs give different names
    # (prefix/length format is covered in test_agents)
    local name1
    name1=$(generate_session_name "/tmp/project-a")
    local name2
    name2=$(generate_session_name "/tmp/project-b")
    assert_cmd_succeeds "generate_session_name: different dirs different names" \
        test "$name1" != "$name2"

    $SUMMARY_MODE || echo ""
}

test_integration_lifecycle() {
    $SUMMARY_MODE || echo "=== Testing Integration: Session Lifecycle ==="

    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/tmux.sh"
    source "$LIB_DIR/registry.sh"
    # Temporarily disable nounset: declare -A AGENT_COMMANDS=([claude]=...) in agents.sh
    # triggers "unbound variable" under set -u because bash interprets the keys as variables
    set +u
    source "$LIB_DIR/agents.sh"
    set -u

    setup_integration_env

    local test_dir
    test_dir=$(mktemp -d)

    # --- Test: agent_launch creates session ---
    local session_name
    session_name=$(set +u; agent_launch "$test_dir" "claude" "test task" 2>/dev/null)
    assert_not_empty "$session_name" "agent_launch: returns session name"

    # Verify tmux session exists
    assert_eq "true" "$(tmux_session_exists "$session_name" && echo true || echo false)" \
        "agent_launch: tmux session exists"

    # Verify registry entry
    assert_eq "true" "$(registry_exists "$session_name" && echo true || echo false)" \
        "agent_launch: registry entry exists"

    # Verify registry fields
    assert_eq "$test_dir" "$(registry_get_field "$session_name" directory)" \
        "agent_launch: correct directory in registry"
    assert_eq "claude" "$(registry_get_field "$session_name" agent_type)" \
        "agent_launch: correct agent_type in registry"
    assert_eq "test task" "$(registry_get_field "$session_name" task)" \
        "agent_launch: correct task in registry"
    assert_eq "open" \
        "$(jq -r --arg name "$session_name" '.sessions[$name].desired_state // ""' "$AM_DIR/desired_sessions.json")" \
        "agent_launch: records durable open intent"
    assert_contains "$(cat "$TEST_ZOXIDE_LOG")" "add -- $test_dir" \
        "agent_launch: records directory in zoxide"

    # Verify agent-only launch by default (shell panel is opt-in)
    local pane_count
    pane_count=$(am_tmux list-panes -t "$session_name" 2>/dev/null | wc -l | tr -d ' ')
    assert_eq "1" "$pane_count" "agent_launch: single agent pane by default"
    assert_eq "absent" "$(tmux_shell_pane_state "$session_name")" \
        "agent_launch: shell panel absent by default"
    assert_contains "$(am_tmux show-options -w -t "$session_name:" pane-border-status 2>/dev/null)" \
        "off" "agent_launch: pane-border-status off for lone agent pane"

    # --- Test: agent_kill cleans up ---
    # Safety: never call agent_kill with empty name (tmux -t "" kills current session)
    if [[ -n "$session_name" ]]; then
        agent_kill "$session_name" 2>/dev/null
    fi
    assert_eq "false" "$(tmux_session_exists "${session_name:-__none__}" && echo true || echo false)" \
        "agent_kill: tmux session removed"
    assert_eq "false" "$(registry_exists "${session_name:-__none__}" && echo true || echo false)" \
        "agent_kill: registry entry removed"
    assert_eq "false" \
        "$(jq -r --arg name "$session_name" '.sessions | has($name)' "$AM_DIR/desired_sessions.json")" \
        "agent_kill: removes durable open intent"

    # --- Test: kill multiple sessions (by name, NOT agent_kill_all which is global) ---
    local s1 s2
    s1=$(set +u; agent_launch "$test_dir" "claude" "" 2>/dev/null)
    s2=$(set +u; agent_launch "$test_dir" "claude" "" 2>/dev/null)
    assert_not_empty "$s1" "multi-kill: first session created"
    assert_not_empty "$s2" "multi-kill: second session created"

    # Kill individually — guard against empty names
    [[ -n "$s1" ]] && agent_kill "$s1" 2>/dev/null
    [[ -n "$s2" ]] && agent_kill "$s2" 2>/dev/null
    assert_eq "false" "$(tmux_session_exists "${s1:-__none__}" && echo true || echo false)" \
        "multi-kill: first session removed"
    assert_eq "false" "$(tmux_session_exists "${s2:-__none__}" && echo true || echo false)" \
        "multi-kill: second session removed"

    # Cleanup
    rm -rf "$test_dir"
    teardown_integration_env

    $SUMMARY_MODE || echo ""
}

test_resolve_session() {
    $SUMMARY_MODE || echo "=== Testing resolve_session ==="

    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/tmux.sh"
    source "$LIB_DIR/registry.sh"
    set +u; source "$LIB_DIR/agents.sh"; set -u

    # Source am to get resolve_session function
    # It's defined in the am script, so we extract it
    eval "$(sed -n '/^resolve_session()/,/^}/p' "$PROJECT_DIR/am")"

    setup_integration_env

    local test_dir
    test_dir=$(mktemp -d)

    # Create a session
    local session_name
    session_name=$(set +u; agent_launch "$test_dir" "claude" "resolve test" 2>/dev/null)

    if [[ -z "$session_name" ]]; then
        skip_test "resolve_session tests (agent_launch failed)"
        teardown_integration_env
        rm -rf "$test_dir"
        echo ""
        return
    fi

    # Test: exact match
    local resolved
    resolved=$(resolve_session "$session_name")
    assert_eq "$session_name" "$resolved" "resolve_session: exact match"

    # Test: short hash (without prefix) resolves via prefix expansion
    local short_name="${session_name#test-am-}"
    resolved=$(resolve_session "$short_name")
    assert_eq "$session_name" "$resolved" "resolve_session: prefix expansion"

    # Test: nonexistent returns failure
    assert_cmd_fails "resolve_session: nonexistent fails" resolve_session "nonexistent-xyz-999"

    # Cleanup
    [[ -n "$session_name" ]] && agent_kill "$session_name" 2>/dev/null
    rm -rf "$test_dir"
    teardown_integration_env

    $SUMMARY_MODE || echo ""
}

test_prompt_injection() {
    $SUMMARY_MODE || echo "=== Testing prompt injection paths ==="

    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/tmux.sh"
    source "$LIB_DIR/registry.sh"
    set +u; source "$LIB_DIR/agents.sh"; set -u

    setup_integration_env

    local test_dir
    test_dir=$(mktemp -d)

    # --- Test: claude gets piped prompt via cat ---
    _AM_LAUNCH_PROMPT="hello from pipe"
    local session_name
    session_name=$(set +u; agent_launch "$test_dir" "claude" "" 2>/dev/null)
    assert_not_empty "$session_name" "claude piped prompt: session created"

    if [[ -n "$session_name" ]]; then
        local pane_output
        pane_output=$(wait_for_text "stub-agent-input:hello from pipe" \
            am_tmux capture-pane -t "${session_name}:.{top}" -p)
        assert_contains "$pane_output" "stub-agent-input:hello from pipe" \
            "claude piped prompt: prompt delivered via stdin pipe"
        agent_kill "$session_name" 2>/dev/null
    fi

    # --- Test: codex gets prompt as CLI argument ---
    _AM_LAUNCH_PROMPT="hello from arg"
    session_name=$(set +u; agent_launch "$test_dir" "codex" "" 2>/dev/null)
    assert_not_empty "$session_name" "codex CLI arg prompt: session created"

    if [[ -n "$session_name" ]]; then
        local pane_output
        # The stub agent command should include the prompt as an argument
        pane_output=$(wait_for_text "hello from arg" \
            am_tmux capture-pane -t "${session_name}:.{top}" -p)
        assert_contains "$pane_output" "hello from arg" \
            "codex CLI arg prompt: prompt appears in pane (passed as arg)"
        agent_kill "$session_name" 2>/dev/null
    fi

    # --- Test: Cursor gets prompt as a positional CLI argument ---
    _AM_LAUNCH_PROMPT="hello cursor"
    session_name=$(set +u; agent_launch "$test_dir" "cursor-agent" "" 2>/dev/null)
    assert_not_empty "$session_name" "cursor CLI arg prompt: session created"

    if [[ -n "$session_name" ]]; then
        local cursor_agent_type
        cursor_agent_type=$(registry_get_field "$session_name" agent_type)
        assert_eq "cursor" "$cursor_agent_type" \
            "cursor alias launch: registry stores canonical type"
        local cursor_pane_output
        cursor_pane_output=$(wait_for_text "hello cursor" \
            am_tmux capture-pane -t "${session_name}:.{top}" -p)
        assert_contains "$cursor_pane_output" "hello cursor" \
            "cursor CLI arg prompt: prompt appears in pane"
        agent_kill "$session_name" 2>/dev/null
    fi

    rm -rf "$test_dir"
    teardown_integration_env

    $SUMMARY_MODE || echo ""
}

test_send_prompt_delay() {
    $SUMMARY_MODE || echo "=== Testing agent_send_prompt paste/Enter pause ==="

    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/tmux.sh"
    source "$LIB_DIR/registry.sh"
    set +u; source "$LIB_DIR/agents.sh"; set -u

    setup_integration_env

    local test_dir
    test_dir=$(mktemp -d)

    # Create a real session so tmux_session_exists passes
    local session_name
    session_name=$(set +u; agent_launch "$test_dir" "claude" "delay test" 2>/dev/null)

    if [[ -z "$session_name" ]]; then
        skip_test "send_prompt delay (agent_launch failed)"
        teardown_integration_env
        rm -rf "$test_dir"
        echo ""
        return
    fi

    # --- Stub sleep to record calls ---
    local _sleep_called=false _sleep_arg=""
    sleep() { _sleep_called=true; _sleep_arg="$1"; }

    # --- Test: a short pause separates the paste from Enter ---
    _sleep_called=false
    agent_send_prompt "$session_name" "hello" 2>/dev/null
    assert_eq "true" "$_sleep_called" \
        "send_prompt: pauses between paste and Enter"
    assert_eq "0.1" "$_sleep_arg" \
        "send_prompt: pause is 0.1s"

    # Restore real sleep and clean up
    unset -f sleep
    [[ -n "$session_name" ]] && agent_kill "$session_name" 2>/dev/null
    rm -rf "$test_dir"
    teardown_integration_env

    $SUMMARY_MODE || echo ""
}

test_shell_panel() {
    $SUMMARY_MODE || echo "=== Testing Shell Panel (open/hide/show) ==="

    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/tmux.sh"
    source "$LIB_DIR/registry.sh"
    set +u; source "$LIB_DIR/agents.sh"; set -u

    setup_integration_env

    local test_dir
    test_dir=$(mktemp -d)

    # --- Test: --shell opens the panel at launch ---
    local session_name
    session_name=$(set +u; agent_launch "$test_dir" "claude" "shell test" --shell 2>/dev/null)
    assert_not_empty "$session_name" "shell panel: --shell launch returns session name"

    local pane_count
    pane_count=$(am_tmux list-panes -t "$session_name" 2>/dev/null | wc -l | tr -d ' ')
    assert_eq "2" "$pane_count" "shell panel: --shell creates agent + shell panes"
    assert_eq "open" "$(tmux_shell_pane_state "$session_name")" \
        "shell panel: state open after --shell launch"

    # Mark the shell so we can prove hide/show preserves the same pane
    tmux_send_keys "$session_name:.{bottom}" "SHELL_PANEL_MARKER=alive; echo panel-marker-set" Enter
    wait_for_text "panel-marker-set" \
        am_tmux capture-pane -t "$session_name:.{bottom}" -p >/dev/null

    # Pane env is seeded by tmux -e: the shell knows its session and log dir
    # without any `export` line having been typed (nothing in shell history).
    tmux_send_keys "$session_name:.{bottom}" 'echo "env-marker:$AM_SESSION_NAME:${AM_LOG_DIR##*/}:$AM_AGENT_TYPE"' Enter
    local shell_text
    shell_text=$(wait_for_text "env-marker:$session_name:$session_name:claude" \
        am_tmux capture-pane -t "$session_name:.{bottom}" -p -S -)
    assert_contains "$shell_text" "env-marker:$session_name:$session_name:claude" \
        "shell panel: AM_SESSION_NAME/AM_LOG_DIR/AM_AGENT_TYPE present in shell env"
    assert_not_contains "$shell_text" "export AM_" \
        "shell panel: no export lines typed into the shell"
    assert_not_contains "$(am_tmux capture-pane -t "$session_name:.{top}" -p -S - 2>/dev/null)" "export AM_" \
        "agent pane: no export lines typed before the agent command"

    # Streamed shell.log picks up pane output while the panel is open
    local shell_log="/tmp/am-logs/${session_name}/shell.log"
    wait_for_text "panel-marker-set" cat "$shell_log" >/dev/null
    assert_contains "$(cat "$shell_log" 2>/dev/null)" "panel-marker-set" \
        "shell panel: shell.log streams while open"

    # --- Test: toggle hides the panel (pane parked, not killed) ---
    agent_shell_pane_toggle "$session_name"
    assert_eq "hidden" "$(tmux_shell_pane_state "$session_name")" \
        "shell panel: toggle parks the open panel"
    pane_count=$(am_tmux list-panes -t "$(tmux_main_window_id "$session_name")" 2>/dev/null | wc -l | tr -d ' ')
    assert_eq "1" "$pane_count" "shell panel: main window back to one pane when hidden"

    # peek --pane shell follows the panel into the hidden window
    local hidden_target
    hidden_target=$(tmux_session_pane_target "$session_name" shell)
    assert_not_empty "$hidden_target" "shell panel: resolver targets hidden panel"

    # pipe-pane survives break-pane: output while hidden still reaches shell.log
    am_tmux send-keys -t "$hidden_target" 'echo "hidden-marker-$SHELL_PANEL_MARKER"' Enter
    wait_for_text "hidden-marker-alive" cat "$shell_log" >/dev/null
    assert_contains "$(cat "$shell_log" 2>/dev/null)" "hidden-marker-alive" \
        "shell panel: shell state and shell.log streaming survive hide"

    # --- Test: toggle shows the panel again ---
    agent_shell_pane_toggle "$session_name"
    assert_eq "open" "$(tmux_shell_pane_state "$session_name")" \
        "shell panel: toggle rejoins the parked panel"
    pane_count=$(am_tmux list-panes -t "$session_name" 2>/dev/null | wc -l | tr -d ' ')
    assert_eq "2" "$pane_count" "shell panel: two panes after show"
    assert_eq "" "$(am_tmux list-windows -t "$session_name" -F '#{window_name}' | grep -x _amshell || true)" \
        "shell panel: hidden window gone after show"

    [[ -n "$session_name" ]] && agent_kill "$session_name" 2>/dev/null

    # --- Test: toggle on an agent-only session creates the panel ---
    local plain_session
    plain_session=$(set +u; agent_launch "$test_dir" "claude" "" 2>/dev/null)
    assert_eq "absent" "$(tmux_shell_pane_state "$plain_session")" \
        "shell panel: absent on default launch"
    agent_shell_pane_toggle "$plain_session"
    assert_eq "open" "$(tmux_shell_pane_state "$plain_session")" \
        "shell panel: toggle creates panel on first use"
    [[ -n "$plain_session" ]] && agent_kill "$plain_session" 2>/dev/null

    rm -rf "$test_dir"
    teardown_integration_env

    $SUMMARY_MODE || echo ""
}

run_agents_tests() {
    _run_test test_agents
    _run_test test_agents_extended
    _run_test test_integration_lifecycle
    _run_test test_shell_panel
    _run_test test_resolve_session
    _run_test test_prompt_injection
    _run_test test_send_prompt_delay
}

if [[ -z "${_AM_TEST_RUNNER:-}" ]]; then
    set -uo pipefail
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helpers.sh"
    check_deps
    run_agents_tests
    test_report
fi
