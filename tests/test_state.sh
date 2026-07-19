#!/usr/bin/env bash
# tests/test_state.sh - Tests for lib/state.sh (title glyph + hook + ps tree)

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

    # --- running + fresh pane activity survives a stale state file. A turn can
    #     run for many minutes with zero tool calls (long thinking stretch), so
    #     no hook refreshes the file — but Claude repaints its spinner timer
    #     every second, keeping tmux session_activity fresh. Staleness is
    #     measured against max(file mtime, activity). ---
    local now_epoch
    now_epoch=$(date +%s)
    printf 'running' > "$tmp_state_dir/am-foo"
    touch -t "$backdated" "$tmp_state_dir/am-foo"
    got=""
    _state_hook_read "am-foo" got "$now_epoch" "$(( now_epoch - 3 ))"
    assert_eq "running" "$got" "_state_hook_read: stale file + fresh activity stays running"

    # Activity as stale as the file -> still drops (wedged agent).
    got=""
    _state_hook_read "am-foo" got "$now_epoch" "$(( now_epoch - 600 ))"
    assert_eq "" "$got" "_state_hook_read: stale file + stale activity drops"

    # Non-numeric / missing activity falls back to mtime-only behavior.
    got=""
    _state_hook_read "am-foo" got "$now_epoch" ""
    assert_eq "" "$got" "_state_hook_read: stale file + empty activity drops"

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

test_state_title_glyph() {
    $SUMMARY_MODE || echo "=== Testing title-glyph state detection ==="

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

    # --- _state_title_signal: glyph classification ---
    local sig
    local frame
    for frame in "⠂" "⠐" "⠋" "⣿" "⠀"; do
        _state_title_signal "${frame} Fixing the bug" sig
        assert_eq "busy" "$sig" "_state_title_signal: braille frame '${frame}' -> busy"
    done
    _state_title_signal "✳ Fix the bug" sig
    assert_eq "attention" "$sig" "_state_title_signal: ✳ -> attention"
    _state_title_signal "✳ Claude Code" sig
    assert_eq "attention" "$sig" "_state_title_signal: fresh-session '✳ Claude Code' -> attention"
    _state_title_signal "myhost.local" sig
    assert_eq "none" "$sig" "_state_title_signal: hostname title -> none"
    _state_title_signal "" sig
    assert_eq "none" "$sig" "_state_title_signal: empty title -> none"
    _state_title_signal "~/code/agent-manager" sig
    assert_eq "none" "$sig" "_state_title_signal: shell path title -> none"
    _state_title_signal "✻ Baked for 5m" sig
    assert_eq "none" "$sig" "_state_title_signal: other decoration (✻) -> none"

    # --- resolver decision table (bulk path; empty maps bypass the shell
    #     check, title injected via the title map) ---
    local -A _T_TOP=() _T_COMM=() _T_CHILD=() _T_TITLE=()
    local _t_now _t_backdated st
    _t_now=$(date +%s)
    _t_backdated=$(date -v-10M '+%Y%m%d%H%M.%S' 2>/dev/null \
        || date -d '10 minutes ago' '+%Y%m%d%H%M.%S')

    _resolve() {  # session agent -> state (bulk, stale activity by default)
        _state_resolve "$1" "$2" /tmp _T_TOP _T_COMM _T_CHILD "$_t_now" "$(( _t_now - 600 ))" _T_TITLE
    }

    # busy glyph: trust Claude's own indicator
    _T_TITLE[am-g]="⠂ Fixing the bug"
    printf 'running' > "$tmp_state_dir/am-g"
    assert_eq "running" "$(_resolve am-g claude)" \
        "resolve: busy + fresh running -> running"

    # THE regression case: long quiet tool call — state file AND tmux activity
    # both >180s stale while the turn is live. Old resolver fell to pane
    # heuristics / unknown and flapped; the glyph keeps it running.
    printf 'running' > "$tmp_state_dir/am-g"
    touch -t "$_t_backdated" "$tmp_state_dir/am-g"
    assert_eq "running" "$(_resolve am-g claude)" \
        "resolve: busy + stale running + stale activity -> running (no flap)"

    # wrap-up turn after background work: file still waiting_input, spinner up
    printf 'waiting_input' > "$tmp_state_dir/am-g"
    assert_eq "running" "$(_resolve am-g claude)" \
        "resolve: busy + waiting_input -> running (turn resumed / wrap-up)"

    # pending dialogs need the user even if a spinner frame lingers
    printf 'waiting_permission' > "$tmp_state_dir/am-g"
    assert_eq "waiting_permission" "$(_resolve am-g claude)" \
        "resolve: busy + waiting_permission passes through"
    printf 'waiting_custom' > "$tmp_state_dir/am-g"
    assert_eq "waiting_custom" "$(_resolve am-g claude)" \
        "resolve: busy + waiting_custom passes through"

    # hook never fired (first turn just started)
    rm -f "$tmp_state_dir/am-g"
    assert_eq "running" "$(_resolve am-g claude)" \
        "resolve: busy + no hook file -> running"

    # attention glyph: waiting_* flavors pass through from the hook
    _T_TITLE[am-g]="✳ Fixing the bug"
    printf 'waiting_input' > "$tmp_state_dir/am-g"
    assert_eq "waiting_input" "$(_resolve am-g claude)" \
        "resolve: attention + waiting_input -> waiting_input"
    printf 'waiting_background' > "$tmp_state_dir/am-g"
    assert_eq "waiting_background" "$(_resolve am-g claude)" \
        "resolve: attention + waiting_background passes through (no pane scan)"
    printf 'waiting_permission' > "$tmp_state_dir/am-g"
    assert_eq "waiting_permission" "$(_resolve am-g claude)" \
        "resolve: attention + waiting_permission passes through"

    # attention + 'running' left behind: backgrounded turn whose lifecycle
    # hooks never resolved here. Resolves waiting_input AND self-heals the
    # file so its mtime stamps the waiting-entry time for tab ages.
    printf 'running' > "$tmp_state_dir/am-g"
    touch -t "$_t_backdated" "$tmp_state_dir/am-g"
    assert_eq "waiting_input" "$(_resolve am-g claude)" \
        "resolve: attention + stale running -> waiting_input"
    assert_eq "waiting_input" "$(head -1 "$tmp_state_dir/am-g")" \
        "resolve: attention + running self-heals the state file"

    # fresh session: Claude idle at the first prompt, no hook ever fired.
    # Old resolver showed 'unknown' until the first prompt; glyph fixes it.
    rm -f "$tmp_state_dir/am-g"
    assert_eq "waiting_input" "$(_resolve am-g claude)" \
        "resolve: attention + no hook file -> waiting_input (fresh session)"
    assert_eq "false" "$([[ -f "$tmp_state_dir/am-g" ]] && echo true || echo false)" \
        "resolve: no-hook case does not fabricate a state file"

    # no glyph signal (claude still booting / titles unavailable): hook
    # fallback with the staleness gate, else unknown
    _T_TITLE[am-g]="myhost.local"
    printf 'running' > "$tmp_state_dir/am-g"
    assert_eq "running" "$(_resolve am-g claude)" \
        "resolve: no glyph + fresh running -> running (fallback)"
    touch -t "$_t_backdated" "$tmp_state_dir/am-g"
    assert_eq "unknown" "$(_resolve am-g claude)" \
        "resolve: no glyph + stale running + stale activity -> unknown (wedge gate)"
    st=$(_state_resolve am-g claude /tmp _T_TOP _T_COMM _T_CHILD "$_t_now" "$(( _t_now - 2 ))" _T_TITLE)
    assert_eq "running" "$st" \
        "resolve: no glyph + stale running + fresh activity -> running"
    printf 'waiting_input' > "$tmp_state_dir/am-g"
    assert_eq "waiting_input" "$(_resolve am-g claude)" \
        "resolve: no glyph + waiting_input -> waiting_input (fallback)"
    rm -f "$tmp_state_dir/am-g"
    assert_eq "unknown" "$(_resolve am-g claude)" \
        "resolve: no glyph + no hook -> unknown"

    # non-Claude agents never consult the title (codex out of scope: their
    # CLIs own the title differently); pure hook fallback.
    _T_TITLE[am-g]="⠂ busy-looking title"
    printf 'waiting_input' > "$tmp_state_dir/am-g"
    assert_eq "waiting_input" "$(_resolve am-g codex)" \
        "resolve: non-claude ignores busy-looking title, uses hook"

    # hook-written waiting_background with busy glyph: wrap-up turn is live ->
    # running wins; Stop rewrites the file when it ends.
    _T_TITLE[am-g]="⠐ Fixing the bug"
    printf 'waiting_background' > "$tmp_state_dir/am-g"
    assert_eq "running" "$(_resolve am-g claude)" \
        "resolve: busy + waiting_background -> running (wrap-up turn live)"

    # --- non-bulk path: title parsed from the display-message fetch ---
    am_tmux() {
        case "${1:-}" in
            display-message) printf '999999 %s ⠂ Fixing the bug\n' "$(( $(date +%s) - 600 ))" ;;
            *) return 1 ;;
        esac
    }
    printf 'running' > "$tmp_state_dir/am-g"
    touch -t "$_t_backdated" "$tmp_state_dir/am-g"
    st=$(_state_resolve am-g claude /tmp)
    assert_eq "running" "$st" \
        "resolve non-bulk: title from display-message keeps stale running alive"
    unset -f am_tmux

    # --- pi: hook state trusted without staleness gate ---
    printf 'running' > "$tmp_state_dir/am-pi1"
    # backdate the state file far beyond the 180s gate
    touch -t "$_t_backdated" "$tmp_state_dir/am-pi1"
    # top pane process is a non-shell (the agent), no title signal
    local -A pi_top_map=( [am-pi1]=99991 )
    local -A pi_comm_map=( [99991]=node )
    local -A pi_child_map=()
    local -A pi_title_map=()
    local pi_state
    pi_state=$(_state_resolve "am-pi1" "pi" "/tmp" pi_top_map pi_comm_map pi_child_map "$_t_now" "$(( _t_now - 600 ))" pi_title_map)
    assert_eq "running" "$pi_state" "_state_resolve: pi stale running stays running (ungated)"

    printf 'waiting_input' > "$tmp_state_dir/am-pi1"
    pi_state=$(_state_resolve "am-pi1" "pi" "/tmp" pi_top_map pi_comm_map pi_child_map "$_t_now" "$(( _t_now - 600 ))" pi_title_map)
    assert_eq "waiting_input" "$pi_state" "_state_resolve: pi waiting_input"

    rm -f "$tmp_state_dir/am-pi1"
    pi_state=$(_state_resolve "am-pi1" "pi" "/tmp" pi_top_map pi_comm_map pi_child_map "$_t_now" "$(( _t_now - 600 ))" pi_title_map)
    assert_eq "unknown" "$pi_state" "_state_resolve: pi no state file -> unknown"

    # shell pane still wins over a pi state file
    printf 'running' > "$tmp_state_dir/am-pi1"
    local -A pi_top_map2=( [am-pi1]=99992 )
    local -A pi_comm_map2=( [99992]=zsh )
    local -A pi_title_map2=()
    pi_state=$(_state_resolve "am-pi1" "pi" "/tmp" pi_top_map2 pi_comm_map2 pi_child_map "$_t_now" "$(( _t_now - 600 ))" pi_title_map2)
    assert_eq "idle" "$pi_state" "_state_resolve: pi shell pane wins"
    rm -f "$tmp_state_dir/am-pi1"

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
    _run_test test_state_title_glyph
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
