#!/usr/bin/env bash
# tests/test_agents.sh - Tests for lib/agents.sh

test_agents() {
    $SUMMARY_MODE || echo "=== Testing agents.sh ==="

    source "$LIB_DIR/utils.sh"

    # Skip full test if deps missing
    if ! command -v jq &>/dev/null; then
        skip_test "agents tests (jq not installed)"
        echo ""
        return
    fi

    source "$LIB_DIR/registry.sh"

    if ! command -v tmux &>/dev/null; then
        skip_test "agents tests (tmux not installed)"
        echo ""
        return
    fi

    source "$LIB_DIR/tmux.sh"
    set +u; source "$LIB_DIR/agents.sh"; set -u

    # Test detect_git_branch
    local branch=$(detect_git_branch "$PROJECT_DIR")
    # May or may not be in a git repo, just check it doesn't error
    assert_cmd_succeeds "detect_git_branch: runs without error" detect_git_branch "$PROJECT_DIR"

    # Test generate_session_name
    local name=$(generate_session_name "/tmp/test")
    assert_contains "$name" "am-" "generate_session_name: has prefix"
    assert_eq 9 "${#name}" "generate_session_name: correct length (am- + 6 chars)"

    # Test agent_get_command
    assert_eq "claude" "$(agent_get_command claude)" "agent_get_command: claude"
    assert_eq "codex" "$(agent_get_command codex)" "agent_get_command: codex"
    assert_eq "gemini" "$(agent_get_command gemini)" "agent_get_command: gemini"

    # Test yolo flag mapping
    assert_eq "--dangerously-skip-permissions" "$(agent_get_yolo_flag claude)" "agent_get_yolo_flag: claude"
    assert_eq "--yolo" "$(agent_get_yolo_flag codex)" "agent_get_yolo_flag: codex"

    # Test _agent_prompt_as_arg
    assert_eq "true" "$(_agent_prompt_as_arg codex && echo true || echo false)" \
        "_agent_prompt_as_arg: codex uses CLI arg"
    assert_eq "false" "$(_agent_prompt_as_arg claude && echo true || echo false)" \
        "_agent_prompt_as_arg: claude uses stdin"
    assert_eq "false" "$(_agent_prompt_as_arg gemini && echo true || echo false)" \
        "_agent_prompt_as_arg: gemini uses stdin"

    $SUMMARY_MODE || echo ""
}

test_agents_extended() {
    $SUMMARY_MODE || echo "=== Testing agents.sh (extended) ==="

    if ! command -v jq &>/dev/null || ! command -v tmux &>/dev/null; then
        skip_test "agents extended tests (jq or tmux not installed)"
        echo ""
        return
    fi

    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/tmux.sh"
    source "$LIB_DIR/registry.sh"
    set +u; source "$LIB_DIR/agents.sh"; set -u

    # Test agent_type_supported
    assert_eq "true" "$(agent_type_supported claude && echo true || echo false)" \
        "agent_type_supported: claude"
    assert_eq "true" "$(agent_type_supported codex && echo true || echo false)" \
        "agent_type_supported: codex"
    assert_eq "true" "$(agent_type_supported gemini && echo true || echo false)" \
        "agent_type_supported: gemini"
    assert_eq "false" "$( (agent_type_supported bogus) 2>/dev/null && echo true || echo false)" \
        "agent_type_supported: bogus rejected"

    # Test generate_session_name: different dirs give different names
    local name1=$(generate_session_name "/tmp/project-a")
    local name2=$(generate_session_name "/tmp/project-b")
    if [[ "$name1" != "$name2" ]]; then
        ((TESTS_RUN++)); ((TESTS_PASSED++))
        $SUMMARY_MODE || printf '%b\n' "${TEST_GREEN}PASS${TEST_RESET}: generate_session_name: different dirs different names"
    else
        ((TESTS_RUN++)); ((TESTS_FAILED++))
        printf '%b\n' "${TEST_RED}FAIL${TEST_RESET}: generate_session_name: collision for different dirs"
        FAIL_DETAILS+=("FAIL: generate_session_name: collision for different dirs")
    fi

    # Test generate_session_name format: am-XXXXXX
    local name=$(generate_session_name "/tmp/test")
    assert_contains "$name" "am-" "generate_session_name: starts with am-"
    assert_eq 9 "${#name}" "generate_session_name: length is 9 (am- + 6)"

    # Test agent_get_yolo_flag for gemini (uses default --yolo)
    assert_eq "--yolo" "$(agent_get_yolo_flag gemini)" "agent_get_yolo_flag: gemini"

    $SUMMARY_MODE || echo ""
}

test_integration_lifecycle() {
    $SUMMARY_MODE || echo "=== Testing Integration: Session Lifecycle ==="

    if ! command -v jq &>/dev/null || ! command -v tmux &>/dev/null; then
        skip_test "integration lifecycle tests (jq or tmux not installed)"
        echo ""
        return
    fi

    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/tmux.sh"
    source "$LIB_DIR/registry.sh"
    # Temporarily disable nounset: declare -A AGENT_COMMANDS=([claude]=...) in agents.sh
    # triggers "unbound variable" under set -u because bash interprets the keys as variables
    set +u
    source "$LIB_DIR/agents.sh"
    set -u

    setup_integration_env

    local test_dir=$(mktemp -d)

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

    # Verify two panes (agent top + shell bottom)
    local pane_count
    pane_count=$(am_tmux list-panes -t "$session_name" 2>/dev/null | wc -l | tr -d ' ')
    assert_eq "2" "$pane_count" "agent_launch: two panes created"

    # --- Test: agent_kill cleans up ---
    # Safety: never call agent_kill with empty name (tmux -t "" kills current session)
    if [[ -n "$session_name" ]]; then
        agent_kill "$session_name" 2>/dev/null
    fi
    assert_eq "false" "$(tmux_session_exists "${session_name:-__none__}" && echo true || echo false)" \
        "agent_kill: tmux session removed"
    assert_eq "false" "$(registry_exists "${session_name:-__none__}" && echo true || echo false)" \
        "agent_kill: registry entry removed"

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

test_worktree() {
    $SUMMARY_MODE || echo "=== Testing Worktree Feature ==="

    if ! command -v jq &>/dev/null || ! command -v tmux &>/dev/null; then
        skip_test "worktree tests (jq or tmux not installed)"
        echo ""
        return
    fi

    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/tmux.sh"
    source "$LIB_DIR/registry.sh"
    set +u; source "$LIB_DIR/agents.sh"; set -u
    export AM_SCRIPT_DIR="$PROJECT_DIR"
    source "$LIB_DIR/sandbox.sh"

    setup_integration_env

    # Create a temp git repo for worktree tests
    local git_dir=$(mktemp -d)
    git -C "$git_dir" init -q
    git -C "$git_dir" -c user.name="test" -c user.email="test@test" commit --allow-empty -m "init" -q

    # Also create a non-git temp dir
    local nongit_dir=$(mktemp -d)

    # --- Test: help text includes -w/--worktree ---
    local help_output=$("$PROJECT_DIR/am" help)
    assert_contains "$help_output" "--worktree" "help: mentions --worktree flag"

    # --- Test: agent_launch with worktree_name sets registry worktree_path ---
    local session_name
    session_name=$(set +u; agent_launch "$git_dir" "claude" "" "my-wt" 2>/dev/null)
    assert_not_empty "$session_name" "worktree launch: returns session name"

    local wt_path
    wt_path=$(registry_get_field "$session_name" worktree_path)
    assert_eq "$git_dir/.claude/worktrees/my-wt" "$wt_path" \
        "worktree launch: registry has correct worktree_path"

    # Verify the agent info shows the worktree
    local info_output
    info_output=$(agent_info "$session_name")
    assert_contains "$info_output" "Worktree:" "worktree launch: info shows Worktree line"

    [[ -n "$session_name" ]] && agent_kill "$session_name" 2>/dev/null

    # --- Test: agent_launch WITHOUT worktree has no worktree_path ---
    session_name=$(set +u; agent_launch "$git_dir" "claude" "" "" 2>/dev/null)
    assert_not_empty "$session_name" "no-worktree launch: returns session name"

    wt_path=$(registry_get_field "$session_name" worktree_path)
    assert_eq "" "$wt_path" "no-worktree launch: registry has no worktree_path"

    # Verify info does NOT show worktree line
    info_output=$(agent_info "$session_name")
    if [[ "$info_output" != *"Worktree:"* ]]; then
        ((TESTS_RUN++)); ((TESTS_PASSED++))
        $SUMMARY_MODE || printf '%b\n' "${TEST_GREEN}PASS${TEST_RESET}: no-worktree launch: info omits Worktree line"
    else
        ((TESTS_RUN++)); ((TESTS_FAILED++))
        printf '%b\n' "${TEST_RED}FAIL${TEST_RESET}: no-worktree launch: info unexpectedly shows Worktree"
        FAIL_DETAILS+=("FAIL: no-worktree launch: info unexpectedly shows Worktree")
    fi

    [[ -n "$session_name" ]] && agent_kill "$session_name" 2>/dev/null

    # --- Test: __auto__ sentinel resolves to am-<hash> ---
    session_name=$(set +u; agent_launch "$git_dir" "claude" "" "__auto__" 2>/dev/null)
    assert_not_empty "$session_name" "auto-worktree launch: returns session name"

    wt_path=$(registry_get_field "$session_name" worktree_path)
    assert_contains "$wt_path" ".claude/worktrees/am-" \
        "auto-worktree: worktree_path contains am- prefix"

    [[ -n "$session_name" ]] && agent_kill "$session_name" 2>/dev/null

    # --- Test: codex uses a manager-created git worktree ---
    session_name=$(set +u; agent_launch "$git_dir" "codex" "" "my-wt" 2>/dev/null)
    if [[ -n "$session_name" ]]; then
        wt_path=$(registry_get_field "$session_name" worktree_path)
        assert_eq "$git_dir/.codex/worktrees/my-wt" "$wt_path" \
            "codex worktree: registry has correct worktree_path"
        assert_cmd_succeeds "codex worktree: directory exists" test -d "$wt_path"
        assert_cmd_succeeds "codex worktree: is a git worktree" git -C "$wt_path" rev-parse --git-dir
        agent_kill "$session_name" 2>/dev/null
    else
        skip_test "codex worktree: agent_launch failed"
    fi

    # --- Test: sandboxed codex worktree keeps repo mount and worktree cwd ---
    if command -v docker &>/dev/null && docker info >/dev/null 2>&1; then
        session_name=$(set +u; agent_launch "$git_dir" "codex" "" "my-sb-wt" "--sandbox" 2>/dev/null)
        if [[ -n "$session_name" ]]; then
            wt_path=$(registry_get_field "$session_name" worktree_path)
            local attach_cmd
            attach_cmd=$(sandbox_enter_cmd "$session_name" "$wt_path")
            assert_contains "$attach_cmd" "-w '$wt_path'" \
                "codex sandbox worktree: attach command enters worktree cwd"
            local container_name
            container_name=$(registry_get_field "$session_name" container_name)
            assert_eq "$session_name" "$container_name" \
                "codex sandbox worktree: container registered"
            agent_kill "$session_name" 2>/dev/null
        else
            skip_test "codex sandbox worktree: agent_launch failed"
        fi
    else
        skip_test "codex sandbox worktree: docker unavailable"
    fi

    # --- Test: unsupported agent type ignores worktree ---
    local warn_output
    warn_output=$(set +u; agent_launch "$git_dir" "gemini" "" "my-wt" 2>&1 >/dev/null)
    session_name=$(set +u; agent_launch "$git_dir" "gemini" "" "my-wt" 2>/dev/null)
    if [[ -n "$session_name" ]]; then
        wt_path=$(registry_get_field "$session_name" worktree_path)
        assert_eq "" "$wt_path" "unsupported worktree: worktree_path not set"
        agent_kill "$session_name" 2>/dev/null
    else
        skip_test "unsupported worktree: agent_launch failed"
    fi

    # --- Test: non-git directory ignores worktree ---
    session_name=$(set +u; agent_launch "$nongit_dir" "claude" "" "my-wt" 2>/dev/null)
    if [[ -n "$session_name" ]]; then
        wt_path=$(registry_get_field "$session_name" worktree_path)
        assert_eq "" "$wt_path" "non-git worktree: worktree_path not set"
        agent_kill "$session_name" 2>/dev/null
    else
        skip_test "non-git worktree: agent_launch failed"
    fi

    # --- Test: agent_display_name shows task when set ---
    session_name=$(set +u; agent_launch "$git_dir" "claude" "fix login bug" "" 2>/dev/null)
    if [[ -n "$session_name" ]]; then
        local display
        display=$(agent_display_name "$session_name")
        assert_contains "$display" "fix login bug" "display_name: shows task"
        agent_kill "$session_name" 2>/dev/null
    else
        skip_test "display_name: agent_launch failed"
    fi

    # --- Test: agent_display_name omits task when empty ---
    session_name=$(set +u; agent_launch "$git_dir" "claude" "" "" 2>/dev/null)
    if [[ -n "$session_name" ]]; then
        local display
        display=$(agent_display_name "$session_name")
        # Should have [claude] but no extra task text between type and time
        assert_contains "$display" "[claude]" "display_name no task: shows agent type"

        # --- Test: agent_display_name accepts pre-fetched activity ---
        local activity
        activity=$(tmux_get_activity "$session_name")
        local display_with_activity
        display_with_activity=$(agent_display_name "$session_name" "$activity")
        assert_contains "$display_with_activity" "[claude]" "display_name with activity: shows agent type"
        assert_contains "$display_with_activity" "ago)" "display_name with activity: shows time"

        agent_kill "$session_name" 2>/dev/null
    else
        skip_test "display_name no task: agent_launch failed"
    fi

    # Cleanup
    rm -rf "$git_dir" "$nongit_dir"
    teardown_integration_env

    $SUMMARY_MODE || echo ""
}

test_sandbox_yolo_independence() {
    $SUMMARY_MODE || echo "=== Testing sandbox/yolo independence ==="

    if ! command -v jq &>/dev/null || ! command -v tmux &>/dev/null; then
        skip_test "sandbox/yolo tests (jq or tmux not installed)"
        echo ""
        return
    fi

    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/config.sh"
    source "$LIB_DIR/tmux.sh"
    source "$LIB_DIR/registry.sh"
    set +u; source "$LIB_DIR/agents.sh"; set -u

    setup_integration_env

    local test_dir=$(mktemp -d)

    # Test: yolo without sandbox — no container_name in registry
    local session_name
    session_name=$(set +u; agent_launch "$test_dir" "claude" "yolo-only" "" --yolo 2>/dev/null)
    assert_not_empty "$session_name" "yolo-only: session created"
    assert_eq "true" "$(registry_get_field "$session_name" yolo_mode)" \
        "yolo-only: yolo_mode is true"
    assert_eq "" "$(registry_get_field "$session_name" container_name)" \
        "yolo-only: no container_name"
    [[ -n "$session_name" ]] && agent_kill "$session_name" 2>/dev/null

    # Test: sandbox without docker fails with descriptive error
    # Override am_docker_available to simulate missing docker
    am_docker_available() { return 1; }
    local sandbox_rc=0
    local sandbox_err
    sandbox_err=$(set +u; agent_launch "$test_dir" "claude" "sandbox-no-docker" "" --sandbox 2>&1 >/dev/null) || sandbox_rc=$?
    assert_eq "false" "$(test $sandbox_rc -eq 0 && echo true || echo false)" \
        "sandbox-no-docker: fails when docker unavailable"
    assert_contains "$sandbox_err" "docker" \
        "sandbox-no-docker: error mentions docker"
    # Restore original function
    am_docker_available() { command -v docker &>/dev/null; }

    rm -rf "$test_dir"
    teardown_integration_env

    $SUMMARY_MODE || echo ""
}

test_resolve_session() {
    $SUMMARY_MODE || echo "=== Testing resolve_session ==="

    if ! command -v jq &>/dev/null || ! command -v tmux &>/dev/null; then
        skip_test "resolve_session tests (jq or tmux not installed)"
        echo ""
        return
    fi

    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/tmux.sh"
    source "$LIB_DIR/registry.sh"
    set +u; source "$LIB_DIR/agents.sh"; set -u

    # Source am to get resolve_session function
    # It's defined in the am script, so we extract it
    eval "$(sed -n '/^resolve_session()/,/^}/p' "$PROJECT_DIR/am")"

    setup_integration_env

    local test_dir=$(mktemp -d)

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

    if ! command -v jq &>/dev/null || ! command -v tmux &>/dev/null; then
        skip_test "prompt injection tests (jq or tmux not installed)"
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

    # --- Test: claude gets piped prompt via cat ---
    _AM_LAUNCH_PROMPT="hello from pipe"
    local session_name
    session_name=$(set +u; agent_launch "$test_dir" "claude" "" "" 2>/dev/null)
    assert_not_empty "$session_name" "claude piped prompt: session created"

    if [[ -n "$session_name" ]]; then
        sleep 0.5
        local pane_output
        pane_output=$(am_tmux capture-pane -t "${session_name}:.{top}" -p 2>/dev/null || true)
        assert_contains "$pane_output" "stub-agent-input:hello from pipe" \
            "claude piped prompt: prompt delivered via stdin pipe"
        agent_kill "$session_name" 2>/dev/null
    fi

    # --- Test: codex gets prompt as CLI argument ---
    _AM_LAUNCH_PROMPT="hello from arg"
    session_name=$(set +u; agent_launch "$test_dir" "codex" "" "" 2>/dev/null)
    assert_not_empty "$session_name" "codex CLI arg prompt: session created"

    if [[ -n "$session_name" ]]; then
        sleep 0.5
        local pane_output
        pane_output=$(am_tmux capture-pane -t "${session_name}:.{top}" -p 2>/dev/null || true)
        # The stub agent command should include the prompt as an argument
        assert_contains "$pane_output" "hello from arg" \
            "codex CLI arg prompt: prompt appears in pane (passed as arg)"
        agent_kill "$session_name" 2>/dev/null
    fi

    rm -rf "$test_dir"
    teardown_integration_env

    $SUMMARY_MODE || echo ""
}

test_send_prompt_sandbox_delay() {
    $SUMMARY_MODE || echo "=== Testing agent_send_prompt sandbox delay ==="

    if ! command -v jq &>/dev/null || ! command -v tmux &>/dev/null; then
        skip_test "send_prompt sandbox delay tests (jq or tmux not installed)"
        echo ""
        return
    fi

    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/tmux.sh"
    source "$LIB_DIR/registry.sh"
    set +u; source "$LIB_DIR/agents.sh"; set -u

    setup_integration_env

    local test_dir=$(mktemp -d)

    # Create a real session so tmux_session_exists passes
    local session_name
    session_name=$(set +u; agent_launch "$test_dir" "claude" "delay test" 2>/dev/null)

    if [[ -z "$session_name" ]]; then
        skip_test "send_prompt sandbox delay (agent_launch failed)"
        teardown_integration_env
        rm -rf "$test_dir"
        echo ""
        return
    fi

    # --- Stub sleep to record calls ---
    local _sleep_called=false _sleep_arg=""
    sleep() { _sleep_called=true; _sleep_arg="$1"; }

    # --- Test: non-sandbox session gets short delay ---
    _sleep_called=false
    agent_send_prompt "$session_name" "hello no sandbox" 2>/dev/null
    assert_eq "true" "$_sleep_called" \
        "send_prompt: delay for non-sandboxed session"
    assert_eq "0.1" "$_sleep_arg" \
        "send_prompt: delay is 0.1s for non-sandboxed session"

    # --- Test: sandbox session (container_name set) gets longer delay ---
    registry_update "$session_name" "container_name" "$session_name"
    _sleep_called=false
    agent_send_prompt "$session_name" "hello sandbox" 2>/dev/null
    assert_eq "true" "$_sleep_called" \
        "send_prompt: delay added for sandboxed session"
    assert_eq "0.3" "$_sleep_arg" \
        "send_prompt: delay is 0.3s for sandboxed session"

    # --- Test: clearing container_name reverts to short delay ---
    registry_update "$session_name" "container_name" ""
    _sleep_called=false
    agent_send_prompt "$session_name" "hello again" 2>/dev/null
    assert_eq "0.1" "$_sleep_arg" \
        "send_prompt: delay reverts to 0.1s after container_name cleared"

    # Restore real sleep and clean up
    unset -f sleep
    [[ -n "$session_name" ]] && agent_kill "$session_name" 2>/dev/null
    rm -rf "$test_dir"
    teardown_integration_env

    $SUMMARY_MODE || echo ""
}

run_agents_tests() {
    _run_test test_agents
    _run_test test_agents_extended
    _run_test test_integration_lifecycle
    _run_test test_worktree
    _run_test test_sandbox_yolo_independence
    _run_test test_resolve_session
    _run_test test_prompt_injection
    _run_test test_send_prompt_sandbox_delay
}

if [[ -z "${_AM_TEST_RUNNER:-}" ]]; then
    set -uo pipefail
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helpers.sh"
    check_deps
    run_agents_tests
    test_report
fi
