#!/usr/bin/env bash
# test_all.sh - Test suite runner for agent-manager

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

# Source all test module files (excluding this runner, helpers, and container-level scripts)
_AM_TEST_RUNNER=1
for _test_file in "$SCRIPT_DIR"/test_*.sh; do
    _basename="$(basename "$_test_file")"
    case "$_basename" in
        test_all.sh|test_helpers.sh) continue ;;
        test_cap_chown.sh|test_claude_mount.sh|test_codex_permissions.sh) continue ;;
    esac
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
    $INCLUDE_SLOW && run_sandbox_slow_tests
    run_fzf_tests
    run_form_tests
    run_state_tests
    run_cli_tests
    run_bin_helpers_tests
    run_standalone_scripts_tests
    run_install_tests

    test_report
}

main "$@"
