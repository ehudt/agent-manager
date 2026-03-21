#!/usr/bin/env bash
# test_all.sh - Test suite runner for agent-manager (parallel)

set -uo pipefail

# Parse test runner flags before anything else
SUMMARY_MODE=false
INCLUDE_SLOW=true
for _arg in "$@"; do
    case "$_arg" in
        --summary|-s) SUMMARY_MODE=true ;;
        --include-slow) INCLUDE_SLOW=true ;;
        --no-include-slow) INCLUDE_SLOW=false ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared test infrastructure (assertions, helpers, integration env)
source "$SCRIPT_DIR/test_helpers.sh"

# Check required tools
check_deps

# ============================================
# Parallel worker infrastructure
# ============================================

_WORK_DIR=$(mktemp -d)

# run_worker WORKER_ID SOCKET_NAME TEST_FUNCTIONS...
# Runs test functions in a subshell with isolated tmux socket and AM_DIR.
# Writes output to $_WORK_DIR/output-$WORKER_ID
# Writes counters to $_WORK_DIR/results-$WORKER_ID
run_worker() {
    local worker_id="$1"
    local socket_name="$2"
    shift 2
    local test_functions=("$@")

    (
        # Capture values the EXIT trap needs — local vars from the outer
        # function are not reliably available inside subshell traps.
        _worker_start=$(date +%s)
        _worker_results_file="$_WORK_DIR/results-$worker_id"
        _worker_tmux_socket="$socket_name"

        # Isolated environment for this worker
        export _AM_PARALLEL_WORKER=1
        export AM_TMUX_SOCKET="$socket_name"
        export SUMMARY_MODE
        export INCLUDE_SLOW

        # Reset counters for this worker
        TESTS_RUN=0
        TESTS_PASSED=0
        TESTS_FAILED=0
        TESTS_SKIPPED=0
        FAIL_DETAILS=()

        # Source test helpers (picks up our AM_TMUX_SOCKET, skips EXIT trap)
        source "$SCRIPT_DIR/test_helpers.sh"

        # Source all test module files
        _AM_TEST_RUNNER=1
        for _test_file in "$SCRIPT_DIR"/test_*.sh; do
            _basename="$(basename "$_test_file")"
            case "$_basename" in
                test_all.sh|test_helpers.sh) continue ;;
                test_cap_chown.sh) continue ;;
            esac
            # shellcheck source=/dev/null
            source "$_test_file"
        done

        # Always write worker results, even if the shell exits on an error like set -u.
        # shellcheck disable=SC2154 # _worker_rc and detail are assigned inside the trap body
        trap '
            _worker_rc=$?
            _worker_end=$(date +%s)
            {
                echo "TESTS_RUN=$TESTS_RUN"
                echo "TESTS_PASSED=$TESTS_PASSED"
                echo "TESTS_FAILED=$TESTS_FAILED"
                echo "TESTS_SKIPPED=$TESTS_SKIPPED"
                echo "WORKER_ELAPSED=$(( _worker_end - _worker_start ))"
                echo "WORKER_STATUS=$_worker_rc"
                for detail in "${FAIL_DETAILS[@]+${FAIL_DETAILS[@]}}"; do
                    echo "FAIL_DETAIL=$detail"
                done
            } > "$_worker_results_file"
            tmux -L "$_worker_tmux_socket" kill-server 2>/dev/null || true
            exit $_worker_rc
        ' EXIT

        # Run assigned test functions
        for func in "${test_functions[@]}"; do
            "$func"
        done
        :  # ensure exit 0 — actual failures are tracked in TESTS_FAILED
    ) > "$_WORK_DIR/output-$worker_id" 2>&1
}

# Aggregate results from all workers
aggregate_results() {
    local total_run=0 total_passed=0 total_failed=0 total_skipped=0
    local all_fail_details=()
    _WORKER_TIMES=""

    local worker_id
    for worker_id in "$@"; do
        local results_file="$_WORK_DIR/results-$worker_id"
        if [[ ! -f "$results_file" ]]; then
            total_failed=$(( total_failed + 1 ))
            all_fail_details+=("FAIL: Worker $worker_id exited before writing results")
            continue
        fi
        while IFS= read -r line; do
            case "$line" in
                TESTS_RUN=*)      total_run=$(( total_run + ${line#TESTS_RUN=} )) ;;
                TESTS_PASSED=*)   total_passed=$(( total_passed + ${line#TESTS_PASSED=} )) ;;
                TESTS_FAILED=*)   total_failed=$(( total_failed + ${line#TESTS_FAILED=} )) ;;
                TESTS_SKIPPED=*)  total_skipped=$(( total_skipped + ${line#TESTS_SKIPPED=} )) ;;
                WORKER_ELAPSED=*) _WORKER_TIMES="${_WORKER_TIMES}  Worker $worker_id: ${line#WORKER_ELAPSED=}s\n" ;;
                WORKER_STATUS=*)
                    if [[ "${line#WORKER_STATUS=}" -ne 0 ]]; then
                        total_failed=$(( total_failed + 1 ))
                        all_fail_details+=("FAIL: Worker $worker_id exited with status ${line#WORKER_STATUS=}")
                    fi
                    ;;
                FAIL_DETAIL=*)    all_fail_details+=("${line#FAIL_DETAIL=}") ;;
            esac
        done < "$results_file"
    done

    # Set globals for test_report
    TESTS_RUN=$total_run
    TESTS_PASSED=$total_passed
    TESTS_FAILED=$total_failed
    TESTS_SKIPPED=$total_skipped
    FAIL_DETAILS=("${all_fail_details[@]+${all_fail_details[@]}}")
}

# Replay worker output in order
replay_output() {
    local worker_ids=("$@")
    for worker_id in "${worker_ids[@]}"; do
        local output_file="$_WORK_DIR/output-$worker_id"
        [[ -f "$output_file" ]] && command cat "$output_file"
    done
}

# ============================================
# Worker definitions — balanced by measured runtime
#
# Solo times (ms):
#   utils=393 config=437 form=441 fzf=419 install=636 sandbox=418
#   registry=2486 tmux=1108 agents=7490 state=7632
#   cli=6980 bin_helpers=4768 standalone_scripts=5028
#
# Note: tmux-heavy tests incur ~1.5x contention when running in
# parallel due to concurrent socket I/O. The 7-worker split below
# keeps each worker under ~8s solo, yielding ~10-14s wall time
# depending on system load (vs ~42s sequential).
# ============================================

# Worker 1: Pure function tests + install + sandbox (~3s solo)
worker1_tests() {
    run_utils_tests
    run_config_tests
    run_form_tests
    run_fzf_tests
    run_sandbox_tests
    run_install_tests
}

# Worker 8-10: Sandbox slow tests, sharded by marker to avoid one long pole
worker8_tests() {
    $INCLUDE_SLOW && run_sandbox_slow_security_tests || true
}

worker9_tests() {
    $INCLUDE_SLOW && run_sandbox_slow_functional_tests || true
}

worker10_tests() {
    $INCLUDE_SLOW && run_sandbox_slow_ux_tests || true
}

# Worker 2: Registry + tmux (~4s solo)
worker2_tests() {
    run_registry_tests
    run_tmux_tests
}

# Worker 3: Agents (~7.5s solo)
worker3_tests() {
    run_agents_tests
}

# Worker 4: State (~7.5s solo)
worker4_tests() {
    run_state_tests
}

# Worker 5: CLI (~7s solo)
worker5_tests() {
    run_cli_tests
}

# Worker 6: Bin helpers (~5s solo)
worker6_tests() {
    run_bin_helpers_tests
}

# Worker 7: Standalone scripts (~5s solo)
worker7_tests() {
    run_standalone_scripts_tests
}

# ============================================
# Docker cleanup — remove containers and networks left by sandbox tests
# ============================================

_cleanup_docker_test_resources() {
    command -v docker &>/dev/null || return 0
    # Remove test containers (main + proxy), then their networks.
    # All test resources use the test-am- prefix.
    local containers
    containers=$(docker ps -a --filter 'name=test-am-' --format '{{.Names}}' 2>/dev/null) || return 0
    [[ -n "$containers" ]] && echo "$containers" | xargs -r docker rm -f &>/dev/null || true
    local networks
    networks=$(docker network ls --filter 'name=test-am-' --format '{{.Name}}' 2>/dev/null) || return 0
    [[ -n "$networks" ]] && echo "$networks" | xargs -r docker network rm &>/dev/null || true
    docker network prune -f &>/dev/null || true
}

# ============================================
# Main
# ============================================

main() {
    # Clean up Docker resources on exit (normal, failure, or interruption)
    trap '_cleanup_docker_test_resources' EXIT

    $SUMMARY_MODE || echo "========================================"
    $SUMMARY_MODE || echo "  Agent Manager Test Suite (parallel)"
    $SUMMARY_MODE || echo "========================================"
    $SUMMARY_MODE || echo ""

    local worker_ids=(1 2 3 4 5 6 7 8 9 10)
    local pids=()

    # Launch workers in parallel, each with its own tmux socket
    # PID in socket name allows concurrent test_all.sh runs
    local _run_id=$$
    run_worker 1 "am-test-${_run_id}-w1" worker1_tests &
    pids+=($!)
    run_worker 2 "am-test-${_run_id}-w2" worker2_tests &
    pids+=($!)
    run_worker 3 "am-test-${_run_id}-w3" worker3_tests &
    pids+=($!)
    run_worker 4 "am-test-${_run_id}-w4" worker4_tests &
    pids+=($!)
    run_worker 5 "am-test-${_run_id}-w5" worker5_tests &
    pids+=($!)
    run_worker 6 "am-test-${_run_id}-w6" worker6_tests &
    pids+=($!)
    run_worker 7 "am-test-${_run_id}-w7" worker7_tests &
    pids+=($!)
    run_worker 8 "am-test-${_run_id}-w8" worker8_tests &
    pids+=($!)
    run_worker 9 "am-test-${_run_id}-w9" worker9_tests &
    pids+=($!)
    run_worker 10 "am-test-${_run_id}-w10" worker10_tests &
    pids+=($!)

    # Wait for all workers
    local _wait_rc
    for pid in "${pids[@]}"; do
        _wait_rc=0
        wait "$pid" || _wait_rc=$?
    done

    # Replay output in worker order
    replay_output "${worker_ids[@]}"

    # Aggregate counters from all workers
    aggregate_results "${worker_ids[@]}"

    # Print combined report
    $SUMMARY_MODE || echo -e "$_WORKER_TIMES"
    test_report

    # Cleanup
    rm -rf "$_WORK_DIR"
}

main "$@"
