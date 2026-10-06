#!/usr/bin/env bash
# tests/test_state_lab.sh - State-detection lab regression gate
#
# Runs every script under tests/state_lab/cases/*.sh and asserts they all
# pass. Each lab case is a self-contained scenario that drives the real hook
# script and the real resolver via the harness in tests/state_lab/lab.sh.
#
# Current cases: 12 (hook-silent agent -> unknown; the non-bulk resolver
# path), 13 (background work through the real hook, read by the real
# resolver).

# Keep (docs/test-value-plan.md 3c): case 12 is the sole guard of the
# non-bulk display-message failure path, and case 13 the only place the
# hook's written state meets the resolver's read.
test_state_lab_cases() {
    local lab_runner="$SCRIPT_DIR/state_lab/run.sh"
    local output
    if output=$("$lab_runner" 2>&1); then
        TESTS_RUN=$((TESTS_RUN + 1))
        TESTS_PASSED=$((TESTS_PASSED + 1))
        $SUMMARY_MODE || printf '%bPASS%b: state_lab: all cases\n' "$TEST_GREEN" "$TEST_RESET"
    else
        TESTS_RUN=$((TESTS_RUN + 1))
        TESTS_FAILED=$((TESTS_FAILED + 1))
        printf '%bFAIL%b: state_lab: at least one case failed\n' "$TEST_RED" "$TEST_RESET"
        # Print the lab summary tail so CI logs show which case failed.
        printf '%s\n' "$output" | tail -40 | sed 's/^/    /'
        FAIL_DETAILS+=("state_lab: see lab output above")
    fi
}

run_state_lab_tests() {
    _run_test test_state_lab_cases
}
