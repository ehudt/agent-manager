#!/usr/bin/env bash
# tests/test_perf_session_switch.sh - Regression: session switch / new-session
# latency.
#
# agent_launch calls am_refresh_sidebar_cache (which runs lib/status-bar once
# per session). status-bar itself writes 3*N tmux set-option values, so the
# whole cascade is O(N^2)+ forks on the synchronous user path.
#
# This test pins a wall-clock budget against a small fleet of tmux sessions.
# It guards the "instant attach" behavior that was lost in the
# clickable-tab-strip work (commits f94c922 / bb05977 / 5f5479d).

_perf_now_ms() {
    if command -v gdate &>/dev/null; then
        echo $(( $(gdate +%s%N) / 1000000 ))
    else
        # macOS date doesn't do %N — fall back to python for sub-second precision
        python3 -c 'import time; print(int(time.time()*1000))'
    fi
}

# Spawn N detached am-* tmux sessions and register matching rows. Pure tmux
# new-session (no agent_launch) so the timing test isolates the status-bar
# cost rather than the agent startup cost.
_perf_setup_fleet() {
    local count="$1" i name
    for i in $(seq 1 "$count"); do
        name="${AM_SESSION_PREFIX}perf${i}"
        am_tmux new-session -d -s "$name" -x 200 -y 50 2>/dev/null || continue
        registry_add "$name" "/tmp/perf${i}" "main" "claude" "task ${i}" >/dev/null
    done
}

_perf_teardown_fleet() {
    local sess
    for sess in $(am_tmux list-sessions -F '#{session_name}' 2>/dev/null \
                  | grep "^${AM_SESSION_PREFIX}perf" || true); do
        am_tmux kill-session -t "$sess" 2>/dev/null || true
    done
}

test_perf_am_refresh_sidebar_cache_under_budget() {
    $SUMMARY_MODE || echo "=== Testing am_refresh_sidebar_cache perf ==="

    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/tmux.sh"
    source "$LIB_DIR/registry.sh"
    set +u; source "$LIB_DIR/agents.sh"; set -u

    setup_integration_env
    export AM_LIB_DIR="$LIB_DIR"

    _perf_setup_fleet 10

    local min=9999999 i start end elapsed
    for i in 1 2 3; do
        start=$(_perf_now_ms)
        am_refresh_sidebar_cache >/dev/null 2>&1 || true
        end=$(_perf_now_ms)
        elapsed=$(( end - start ))
        (( elapsed < min )) && min=$elapsed
    done

    local budget_ms=1500
    assert_cmd_succeeds "am_refresh_sidebar_cache best-of-3 = ${min}ms (budget ${budget_ms}ms)" \
        test "$min" -lt "$budget_ms"

    _perf_teardown_fleet
    teardown_integration_env

    $SUMMARY_MODE || echo ""
}

run_perf_session_switch_tests() {
    _run_test test_perf_am_refresh_sidebar_cache_under_budget
}

if [[ -z "${_AM_TEST_RUNNER:-}" ]]; then
    set -uo pipefail
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helpers.sh"
    check_deps
    run_perf_session_switch_tests
    test_report
fi
