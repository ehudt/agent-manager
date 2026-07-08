#!/usr/bin/env bash
# tests/test_state.sh - Tests for lib/state.sh (hook + ps tree only)

test_state() {
    $SUMMARY_MODE || echo "=== Testing state.sh (unit) ==="

    source "$LIB_DIR/utils.sh"
    set +u
    source "$LIB_DIR/config.sh"
    source "$LIB_DIR/tmux.sh"
    source "$LIB_DIR/registry.sh"
    source "$LIB_DIR/agents.sh"
    source "$LIB_DIR/state.sh"
    set -u

    # --- _state_hook_read: fresh waiting_* states ---
    local tmp_state_dir
    tmp_state_dir=$(mktemp -d)
    AM_STATE_DIR="$tmp_state_dir"

    local got
    printf 'waiting_input' > "$tmp_state_dir/am-foo"
    _state_hook_read "am-foo" got
    assert_eq "waiting_input" "$got" "_state_hook_read: waiting_input"

    printf 'waiting_permission' > "$tmp_state_dir/am-foo"
    _state_hook_read "am-foo" got
    assert_eq "waiting_permission" "$got" "_state_hook_read: waiting_permission"

    printf 'waiting_custom' > "$tmp_state_dir/am-foo"
    _state_hook_read "am-foo" got
    assert_eq "waiting_custom" "$got" "_state_hook_read: waiting_custom"

    printf 'running' > "$tmp_state_dir/am-foo"
    _state_hook_read "am-foo" got
    assert_eq "running" "$got" "_state_hook_read: fresh running"

    # --- _state_hook_read: stale running drops to empty (resolver picks unknown) ---
    printf 'running' > "$tmp_state_dir/am-foo"
    local backdated
    backdated=$(date -v-5M '+%Y%m%d%H%M.%S' 2>/dev/null \
        || date -d '5 minutes ago' '+%Y%m%d%H%M.%S')
    touch -t "$backdated" "$tmp_state_dir/am-foo"
    got=""
    _state_hook_read "am-foo" got
    assert_eq "" "$got" "_state_hook_read: stale running drops"

    # --- waiting_* survives staleness (terminal states are persistent) ---
    printf 'waiting_input' > "$tmp_state_dir/am-foo"
    touch -t "$backdated" "$tmp_state_dir/am-foo"
    got=""
    _state_hook_read "am-foo" got
    assert_eq "waiting_input" "$got" "_state_hook_read: stale waiting_input persists"

    # --- bogus state rejected ---
    printf 'bogus' > "$tmp_state_dir/am-foo"
    got=""
    _state_hook_read "am-foo" got
    assert_eq "" "$got" "_state_hook_read: invalid state rejected"

    # --- missing file ---
    rm -f "$tmp_state_dir/am-foo"
    got=""
    _state_hook_read "am-foo" got
    assert_eq "" "$got" "_state_hook_read: missing file"

    rm -rf "$tmp_state_dir"

    $SUMMARY_MODE || echo ""
}

test_state_integration() {
    $SUMMARY_MODE || echo "=== Testing state.sh (integration) ==="

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

    local session_name
    session_name=$(set +u; agent_launch "$test_dir" "claude" "state test" 2>/dev/null)
    assert_not_empty "$session_name" "state integration: session created"

    wait_for_text "stub-agent-ready" am_tmux capture-pane -pt "$session_name:.{top}" >/dev/null

    local state
    state=$(agent_get_state "$session_name" 2>/dev/null || true)
    assert_not_empty "$state" "agent_get_state: returns non-empty state for live session"

    local valid_states="starting running waiting_input waiting_permission waiting_custom waiting_background idle unknown dead"
    local state_valid=false
    local s
    for s in $valid_states; do
        [[ "$state" == "$s" ]] && state_valid=true && break
    done
    assert_eq "true" "$state_valid" "agent_get_state: returns a known state value (got: $state)"

    local dead_state
    dead_state=$(agent_get_state "nonexistent-session-xyz" 2>/dev/null || true)
    assert_eq "dead" "$dead_state" "agent_get_state: nonexistent session → dead"

    # --- agent_get_state should pick up hook state file ---
    # The stub agent's pane is a shell, so the resolver classifies as idle
    # at stage 1 (shell check) before reaching the hook. Verify the hook
    # branch by stubbing the shell check.
    local mock_session="am-mock-state-test"
    local mock_state_dir
    mock_state_dir=$(mktemp -d)
    AM_STATE_DIR="$mock_state_dir"
    local mock_state_file="$AM_STATE_DIR/$mock_session"
    printf 'waiting_permission' > "$mock_state_file"

    # Stub tmux_session_exists + bypass shell check.
    _state_pane_is_shell_bulk() { return 1; }
    tmux_session_exists() { [[ "$1" == "$mock_session" ]] && return 0 || return 1; }
    registry_get_field() { echo ""; }

    local hook_state
    hook_state=$(agent_get_state "$mock_session")
    assert_eq "waiting_permission" "$hook_state" "agent_get_state: reads hook file when pane is not shell"

    # --- Hook silent but pane non-shell → unknown ---
    rm -f "$mock_state_file"
    local unknown_state
    unknown_state=$(agent_get_state "$mock_session")
    assert_eq "unknown" "$unknown_state" "agent_get_state: hook silent + agent alive → unknown"

    # Restore originals by re-sourcing.
    unset -f _state_pane_is_shell_bulk tmux_session_exists registry_get_field
    rm -rf "$mock_state_dir"
    unset AM_STATE_DIR
    set +u
    source "$LIB_DIR/tmux.sh"
    source "$LIB_DIR/registry.sh"
    source "$LIB_DIR/state.sh"
    set -u

    # am status --json should include state field
    local status_json
    status_json=$(AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" \
        "$PROJECT_DIR/am" status --json "$session_name" 2>/dev/null || true)
    assert_cmd_succeeds "am status --json: valid JSON" jq . <<< "$status_json"
    local status_state
    status_state=$(echo "$status_json" | jq -r '.state // empty' 2>/dev/null || true)
    assert_not_empty "$status_state" "am status --json: state field present"

    local list_json
    list_json=$(AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" \
        "$PROJECT_DIR/am" list --json 2>/dev/null || true)
    if [[ -n "$list_json" ]] && echo "$list_json" | jq . >/dev/null 2>&1; then
        local list_has_state
        list_has_state=$(echo "$list_json" | jq 'if length > 0 then .[0] | has("state") else true end' 2>/dev/null || echo "false")
        assert_eq "true" "$list_has_state" "am list --json: state field present in objects"

        local list_state_nonempty
        list_state_nonempty=$(echo "$list_json" | jq 'if length > 0 then (.[0].state | length > 0) else true end' 2>/dev/null || echo "false")
        assert_eq "true" "$list_state_nonempty" "am list --json: state field non-empty for live session"
    else
        skip_test "am list --json: state field (am list --json unavailable in test env)"
    fi

    local wait_state
    wait_state=$(AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" \
        "$PROJECT_DIR/am" wait --timeout 5 "$session_name" 2>/dev/null || true)
    assert_not_empty "$wait_state" "am wait: returns a state"

    local interrupt_rc=0
    AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" \
        "$PROJECT_DIR/am" interrupt "$session_name" >/dev/null 2>&1 || interrupt_rc=$?
    assert_eq "true" "$(test $interrupt_rc -le 1 && echo true || echo false)" \
        "am interrupt: exits 0 or 1 (no crash)"

    [[ -n "$session_name" ]] && agent_kill "$session_name" 2>/dev/null
    rm -rf "$test_dir"
    teardown_integration_env

    $SUMMARY_MODE || echo ""
}

test_state_background_wait() {
    $SUMMARY_MODE || echo "=== Testing waiting_background detection ==="

    source "$LIB_DIR/utils.sh"
    set +u
    source "$LIB_DIR/config.sh"
    source "$LIB_DIR/tmux.sh"
    source "$LIB_DIR/registry.sh"
    source "$LIB_DIR/state.sh"
    set -u

    local tmp_state_dir
    tmp_state_dir=$(mktemp -d)
    AM_STATE_DIR="$tmp_state_dir"

    # Mock the agent pane: am_tmux capture-pane echoes $MOCK_PANE. Other tmux
    # subcommands the resolver calls (display-message for pane_pid) return empty
    # so the shell check finds no top pid; we also stub the shell check below.
    local MOCK_PANE=""
    am_tmux() {
        case "${1:-}" in
            capture-pane) printf '%s\n' "$MOCK_PANE" ;;
            *) return 0 ;;
        esac
    }

    # --- _state_pane_has_background_wait: regex coverage ---
    MOCK_PANE=$'doing things\n✻ Waiting for 1 background agent to finish\n> '
    assert_cmd_succeeds "_state_pane_has_bg: singular agent banner" \
        _state_pane_has_background_wait am-bg
    MOCK_PANE='Waiting for 3 background agents to finish'
    assert_cmd_succeeds "_state_pane_has_bg: plural agents" \
        _state_pane_has_background_wait am-bg
    MOCK_PANE='Waiting for 2 background tasks to finish'
    assert_cmd_succeeds "_state_pane_has_bg: background tasks" \
        _state_pane_has_background_wait am-bg
    MOCK_PANE='Waiting for 1 background workflow to finish'
    assert_cmd_succeeds "_state_pane_has_bg: background workflow" \
        _state_pane_has_background_wait am-bg
    MOCK_PANE=$'normal output\n> waiting for your reply'
    assert_cmd_fails "_state_pane_has_bg: unrelated text ignored" \
        _state_pane_has_background_wait am-bg
    MOCK_PANE=''
    assert_cmd_fails "_state_pane_has_bg: empty pane" \
        _state_pane_has_background_wait am-bg

    # --- live vs. stale banner: the banner persists in scrollback after the
    #     background work finishes, so a match only counts when the banner is
    #     still the current status line (pinned just above the input box). ---
    local _rule='────────────────────────'
    local _foot='  opus | blue-wekapp/ehud-network-mix-setup | 180k (18%) · ⚡ 167k +13k · $176.9'
    # Live: banner pinned directly above the input box.
    MOCK_PANE=$'⏺ working\n✻ Waiting for 1 background agent to finish\n'"$_rule"$'\n❯ \n'"$_rule"
    assert_cmd_succeeds "_state_pane_has_bg: live banner above input box" \
        _state_pane_has_background_wait am-bg
    # Live: banner + right-aligned hint line still counts.
    MOCK_PANE=$'⏺ working\n✻ Waiting for 2 background tasks to finish\n                                        new task? /clear to save 5k tokens\n'"$_rule"$'\n❯ \n'"$_rule"
    assert_cmd_succeeds "_state_pane_has_bg: live banner above hint+box" \
        _state_pane_has_background_wait am-bg
    # Live: banner above the box, but the input box holds TYPED text. The typed
    # line sits between the two box rules and must be treated as box interior,
    # not as transcript that scrolled the banner away (regression: typed input
    # aborted the upward scan -> green session with agents still running).
    MOCK_PANE=$'⏺ working\n✻ Waiting for 2 background agents to finish\n'"$_rule"$'\n❯ continue with the remaining items\n'"$_rule"
    assert_cmd_succeeds "_state_pane_has_bg: live banner above box with typed input" \
        _state_pane_has_background_wait am-bg
    # Live: real auto-mode capture — banner above, typed input in the box, and
    # the auto-mode agent panel listed below (no "N monitor" counter token).
    MOCK_PANE=$'✻ Waiting for 2 background agents to finish\n                                                    ✘ Auto-update failed · Run /doctor\n'"$_rule"$'\n❯ continue with the remaining items\n'"$_rule"$'\n'"$_foot"$'\n  ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents\n  ⏺ main\n  ◯ general-purpose  Compiling reggie.py                    9m 53s · ↓ 145.0k tokens'
    assert_cmd_succeeds "_state_pane_has_bg: banner + typed input + auto-mode agent panel" \
        _state_pane_has_background_wait am-bg
    # Stale: work finished — completion output and a fresh status line sit
    # between the old banner and the input box (regression for the stuck
    # waiting_background bug).
    MOCK_PANE=$'⏺ starting\n✻ Waiting for 1 background agent to finish\n⏺ Agent "x" finished · 52s\n⏺ Verdict: done\n✻ Brewed for 2m 22s\n'"$_rule"$'\n❯ \n'"$_rule"
    assert_cmd_fails "_state_pane_has_bg: stale banner in scrollback ignored" \
        _state_pane_has_background_wait am-bg

    # --- background-shell counter (mode line below the input box) and the
    #     session-artifact line, which must NOT affect state. ---
    # "N shell" in the mode line -> background work running.
    MOCK_PANE=$'⏺ done\n✻ Brewed for 1m 2s\n'"$_rule"$'\n❯ \n'"$_rule"$'\n'"$_foot"$'\n  ⏵⏵ auto mode on · 1 shell  ← for agents\n🗀 netmix-coverage'
    assert_cmd_succeeds "_state_pane_has_bg: '1 shell' in mode line -> background" \
        _state_pane_has_background_wait am-bg
    MOCK_PANE=$'⏺ done\n'"$_rule"$'\n❯ \n'"$_rule"$'\n  ⏵⏵ auto mode on · 2 shells  ← for agents'
    assert_cmd_succeeds "_state_pane_has_bg: '2 shells' plural -> background" \
        _state_pane_has_background_wait am-bg
    # "N monitor" in the mode line -> background work running. Monitors are the
    # mode-line counter Claude shows for auto-mode background agents; the status
    # line above the box ("… · 1 monitor still running") also mentions it but the
    # below-box mode-line token is the authoritative live count.
    MOCK_PANE=$'⏺ done\n✻ Baked for 4m 5s · 1 monitor still running\n'"$_rule"$'\n❯ \n'"$_rule"$'\n'"$_foot"$'\n  ⏵⏵ auto mode on · 1 monitor · ← for agents'
    assert_cmd_succeeds "_state_pane_has_bg: '1 monitor' in mode line -> background" \
        _state_pane_has_background_wait am-bg
    MOCK_PANE=$'⏺ done\n'"$_rule"$'\n❯ \n'"$_rule"$'\n  ⏵⏵ auto mode on · 2 monitors · ← for agents'
    assert_cmd_succeeds "_state_pane_has_bg: '2 monitors' plural -> background" \
        _state_pane_has_background_wait am-bg
    # "monitor" in prose (no digit prefix) must NOT trigger background.
    MOCK_PANE=$'when the monitor fires Ready → quarantine\n'"$_rule"$'\n❯ \n'"$_rule"$'\n  ⏵⏵ auto mode on  ← for agents'
    assert_cmd_fails "_state_pane_has_bg: prose 'monitor' (no count) -> not background" \
        _state_pane_has_background_wait am-bg
    # No shell, no live banner, just a session artifact -> not background.
    MOCK_PANE=$'⏺ all done\n✻ Brewed for 1m 2s\n'"$_rule"$'\n❯ \n'"$_rule"$'\n'"$_foot"$'\n  ⏵⏵ auto mode on  ← for agents\n🗀 netmix-coverage'
    assert_cmd_fails "_state_pane_has_bg: session artifact alone -> not background" \
        _state_pane_has_background_wait am-bg

    # --- resolver wiring (bypass shell check so we reach the hook layer) ---
    _state_pane_is_shell_bulk() { return 1; }

    local st
    printf 'waiting_input' > "$tmp_state_dir/am-bg"
    MOCK_PANE='✻ Waiting for 1 background agent to finish'
    st=$(_state_resolve am-bg claude /tmp)
    assert_eq "waiting_background" "$st" \
        "_state_resolve: waiting_input + banner (claude) -> waiting_background"

    st=$(_state_resolve am-bg codex /tmp)
    assert_eq "waiting_input" "$st" \
        "_state_resolve: banner not scanned for non-claude agent"

    MOCK_PANE='> ready for input'
    st=$(_state_resolve am-bg claude /tmp)
    assert_eq "waiting_input" "$st" \
        "_state_resolve: waiting_input + no banner stays waiting_input"

    # Stale banner left in scrollback must not pin the session in
    # waiting_background after the work has finished.
    MOCK_PANE=$'✻ Waiting for 1 background agent to finish\n⏺ Agent "x" finished · 52s\n────────────────────────\n❯ \n────────────────────────'
    st=$(_state_resolve am-bg claude /tmp)
    assert_eq "waiting_input" "$st" \
        "_state_resolve: stale banner in scrollback stays waiting_input"

    # waiting_input + background shell counter -> waiting_background.
    MOCK_PANE=$'⏺ done\n────────────────────────\n❯ \n────────────────────────\n  ⏵⏵ auto mode on · 1 shell  ← for agents'
    st=$(_state_resolve am-bg claude /tmp)
    assert_eq "waiting_background" "$st" \
        "_state_resolve: waiting_input + '1 shell' -> waiting_background"

    # waiting_input + background monitor counter -> waiting_background.
    MOCK_PANE=$'⏺ done\n────────────────────────\n❯ \n────────────────────────\n  ⏵⏵ auto mode on · 1 monitor · ← for agents'
    st=$(_state_resolve am-bg claude /tmp)
    assert_eq "waiting_background" "$st" \
        "_state_resolve: waiting_input + '1 monitor' -> waiting_background"

    # A session-artifact line must not affect state -> stays waiting_input.
    MOCK_PANE=$'⏺ done\n✻ Brewed for 1m\n────────────────────────\n❯ \n────────────────────────\n  ⏵⏵ auto mode on  ← for agents\n🗀 netmix-coverage'
    st=$(_state_resolve am-bg claude /tmp)
    assert_eq "waiting_input" "$st" \
        "_state_resolve: session artifact alone stays waiting_input"

    # running hook is busy by definition — never scanned, even with a stale banner
    printf 'running' > "$tmp_state_dir/am-bg"
    MOCK_PANE='✻ Waiting for 1 background agent to finish'
    st=$(_state_resolve am-bg claude /tmp)
    assert_eq "running" "$st" \
        "_state_resolve: running hook not refined to waiting_background"

    # hook silent + banner -> waiting_background (fallback path)
    rm -f "$tmp_state_dir/am-bg"
    st=$(_state_resolve am-bg claude /tmp)
    assert_eq "waiting_background" "$st" \
        "_state_resolve: hook silent + banner -> waiting_background"

    # hook silent + no banner -> unknown
    MOCK_PANE=''
    st=$(_state_resolve am-bg claude /tmp)
    assert_eq "unknown" "$st" \
        "_state_resolve: hook silent + no banner -> unknown"

    unset -f am_tmux _state_pane_is_shell_bulk
    rm -rf "$tmp_state_dir"
    unset AM_STATE_DIR
    set +u
    source "$LIB_DIR/tmux.sh"
    source "$LIB_DIR/state.sh"
    set -u

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

# tmux session_created timestamps have 1-second resolution and
# am_session_order sorts by them, so consecutive launches must land in
# distinct seconds. Wait until the wall clock has moved past the given
# session's creation second (cheaper than a fixed sleep 1.1 — usually
# ~0.5s, and free when the launch itself took >1s).
_wait_past_creation_second() {
    local created
    created=$(tmux_get_created "$1" 2>/dev/null || echo 0)
    while (( $(date +%s) <= created )); do
        sleep 0.1
    done
}

test_am_session_order() {
    $SUMMARY_MODE || echo "=== Testing am_session_order ==="

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

    local s1 s2 s3
    s1=$(set +u; agent_launch "$test_dir" "claude" "" 2>/dev/null)
    _wait_past_creation_second "$s1"
    s2=$(set +u; agent_launch "$test_dir" "claude" "" 2>/dev/null)
    _wait_past_creation_second "$s2"
    s3=$(set +u; agent_launch "$test_dir" "claude" "" 2>/dev/null)

    local result count
    result=$(am_session_order)
    count=$(echo "$result" | wc -l | tr -d ' ')
    assert_eq "3" "$count" "am_session_order: returns all 3 sessions"

    local expected
    expected=$(printf '%s\n%s\n%s' "$s1" "$s2" "$s3")
    assert_eq "$expected" "$result" "am_session_order: creation time ascending (newest last)"

    am_tmux send-keys -t "$s2" "" 2>/dev/null || true
    sleep 0.1
    local result2
    result2=$(am_session_order)
    assert_eq "$result" "$result2" "am_session_order: stable after activity change"

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
    _run_test test_state_background_wait
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
