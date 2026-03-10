#!/usr/bin/env bash
# test_all.sh - Test suite runner for agent-manager

set -uo pipefail

# Parse test runner flags before anything else
SUMMARY_MODE=false
for _arg in "$@"; do
    case "$_arg" in
        --summary|-s) SUMMARY_MODE=true ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared test infrastructure (assertions, helpers, integration env)
source "$SCRIPT_DIR/test_helpers.sh"

# Check required tools
check_deps

# Source all test_*.sh files (excluding this runner, helpers, and standalone scripts)
for _test_file in "$SCRIPT_DIR"/test_*.sh; do
    _basename="$(basename "$_test_file")"
    case "$_basename" in
        test_all.sh|test_helpers.sh) continue ;;
    esac
    # Skip standalone executable scripts (they have shebangs and run on source)
    head -1 "$_test_file" | grep -q '^#!' && continue
    source "$_test_file"
done

# ============================================
# Main
# ============================================

main() {
    $SUMMARY_MODE || echo "========================================"
    $SUMMARY_MODE || echo "  Agent Manager Test Suite"
    $SUMMARY_MODE || echo "========================================"
    $SUMMARY_MODE || echo ""

    run_utils_tests
    run_config_tests
    run_registry_tests
    run_tmux_tests
    run_agents_tests
    run_sandbox_tests
    run_fzf_tests
    run_form_tests
    run_state_tests
    run_cli_tests
    run_bin_helpers_tests
    run_standalone_scripts_tests
    run_install_tests

    echo "========================================"
    echo "  Results: $TESTS_PASSED/$TESTS_RUN passed"
    [[ $TESTS_SKIPPED -gt 0 ]] && echo "  $TESTS_SKIPPED skipped"
    if [[ $TESTS_FAILED -gt 0 ]]; then
        echo -e "  ${RED}$TESTS_FAILED tests failed${RESET}"
        if $SUMMARY_MODE && [[ ${#FAIL_DETAILS[@]} -gt 0 ]]; then
            echo ""
            echo "  Failed tests:"
            for detail in "${FAIL_DETAILS[@]}"; do
                echo "$detail" | tr '|' '\n' | sed 's/^/    /'
            done
        fi
        exit 1
    else
        echo -e "  ${GREEN}All tests passed!${RESET}"
    fi
    echo "========================================"
}

main "$@"
