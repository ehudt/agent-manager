# test_helpers.sh - Shared test infrastructure for agent-manager test suite
# Sourced by test runners — no shebang, no set -euo pipefail

# Parse test runner flags before anything else
# Preserve SUMMARY_MODE if already set (e.g., by parallel worker)
SUMMARY_MODE="${SUMMARY_MODE:-false}"
for _arg in "$@"; do
    case "$_arg" in
        --summary|-s) SUMMARY_MODE=true ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$SCRIPT_DIR"  # Stable ref — SCRIPT_DIR gets overwritten by lib/agents.sh
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
LIB_DIR="$PROJECT_DIR/lib"

# Dedicated tmux socket so tests never touch the user's live sessions
# Workers in parallel mode override this before sourcing test files
export AM_TMUX_SOCKET="${AM_TMUX_SOCKET:-am-test-$$}"

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

# Summary mode: collect failure details for replay
FAIL_DETAILS=()

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RESET='\033[0m'

# Test utilities
assert_eq() {
    local expected="$1"
    local actual="$2"
    local msg="${3:-}"
    ((TESTS_RUN++))
    if [[ "$expected" == "$actual" ]]; then
        ((TESTS_PASSED++))
        $SUMMARY_MODE || echo -e "${GREEN}PASS${RESET}: $msg"
    else
        ((TESTS_FAILED++))
        echo -e "${RED}FAIL${RESET}: $msg"
        echo "  Expected: '$expected'"
        echo "  Actual:   '$actual'"
        FAIL_DETAILS+=("FAIL: $msg|  Expected: '$expected'|  Actual:   '$actual'")
    fi
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local msg="${3:-}"
    ((TESTS_RUN++))
    if [[ "$haystack" == *"$needle"* ]]; then
        ((TESTS_PASSED++))
        $SUMMARY_MODE || echo -e "${GREEN}PASS${RESET}: $msg"
    else
        ((TESTS_FAILED++))
        echo -e "${RED}FAIL${RESET}: $msg"
        echo "  String: '$haystack'"
        echo "  Does not contain: '$needle'"
        FAIL_DETAILS+=("FAIL: $msg|  String: '$haystack'|  Does not contain: '$needle'")
    fi
}

assert_not_empty() {
    local value="$1"
    local msg="${2:-}"
    ((TESTS_RUN++))
    if [[ -n "$value" ]]; then
        ((TESTS_PASSED++))
        $SUMMARY_MODE || echo -e "${GREEN}PASS${RESET}: $msg"
    else
        ((TESTS_FAILED++))
        echo -e "${RED}FAIL${RESET}: $msg (value is empty)"
        FAIL_DETAILS+=("FAIL: $msg (value is empty)")
    fi
}

assert_cmd_succeeds() {
    local msg="$1"
    shift
    ((TESTS_RUN++))
    if "$@" &>/dev/null; then
        ((TESTS_PASSED++))
        $SUMMARY_MODE || echo -e "${GREEN}PASS${RESET}: $msg"
    else
        ((TESTS_FAILED++))
        echo -e "${RED}FAIL${RESET}: $msg"
        FAIL_DETAILS+=("FAIL: $msg")
    fi
}

assert_cmd_fails() {
    local msg="$1"
    shift
    ((TESTS_RUN++))
    if "$@" &>/dev/null; then
        ((TESTS_FAILED++))
        echo -e "${RED}FAIL${RESET}: $msg (expected failure, got success)"
        FAIL_DETAILS+=("FAIL: $msg (expected failure, got success)")
    else
        ((TESTS_PASSED++))
        $SUMMARY_MODE || echo -e "${GREEN}PASS${RESET}: $msg"
    fi
}

skip_test() {
    local msg="$1"
    ((TESTS_SKIPPED++))
    $SUMMARY_MODE || echo -e "${YELLOW}SKIP${RESET}: $msg"
}

run_external_test() {
    local msg="$1"
    shift
    ((TESTS_RUN++))
    local _ext_output _ext_rc=0
    if $SUMMARY_MODE; then
        _ext_output=$("$@" 2>&1) || _ext_rc=$?
    else
        "$@" || _ext_rc=$?
    fi
    if [[ $_ext_rc -eq 0 ]]; then
        ((TESTS_PASSED++))
        $SUMMARY_MODE || echo -e "${GREEN}PASS${RESET}: $msg"
    else
        ((TESTS_FAILED++))
        echo -e "${RED}FAIL${RESET}: $msg"
        echo "  Exit code: $_ext_rc"
        [[ -n "${_ext_output:-}" ]] && echo "$_ext_output"
        FAIL_DETAILS+=("FAIL: $msg|  Exit code: $_ext_rc")
    fi
}

# Test-only helpers (these functions were removed from production code)
registry_exists() {
    [[ -n "$(registry_get_field "$1" "name")" ]]
}

registry_count() {
    jq '.sessions | length' "$AM_REGISTRY"
}

# Check dependencies
check_deps() {
    local missing=()
    command -v jq &>/dev/null || missing+=("jq")
    command -v tmux &>/dev/null || missing+=("tmux")
    command -v fzf &>/dev/null || missing+=("fzf")

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo -e "${RED}Missing required dependencies: ${missing[*]}${RESET}"
        echo "Install prerequisites first, then rerun tests."
        echo "See README prerequisites section."
        exit 1
    fi
}

# Kill the dedicated test tmux server on exit (even on failure/signal)
# In parallel mode (_AM_PARALLEL_WORKER=1), workers manage their own cleanup
cleanup_test_tmux_server() {
    tmux -L "$AM_TMUX_SOCKET" kill-server 2>/dev/null || true
}
if [[ -z "${_AM_PARALLEL_WORKER:-}" ]]; then
    trap cleanup_test_tmux_server EXIT
fi

# ============================================
# Integration test helpers
# ============================================

# Setup isolated test environment for integration tests
# Sets AM_DIR to a temp dir, creates stub agent, overrides AGENT_COMMANDS
# IMPORTANT: Call AFTER sourcing agents.sh (declare -A resets AGENT_COMMANDS)
# Usage: setup_integration_env
# After calling, use $TEST_AM_DIR, $TEST_STUB_DIR
setup_integration_env() {
    TEST_AM_DIR=$(mktemp -d)
    TEST_STUB_DIR="$TEST_DIR"  # stub_agent lives in tests/
    TEST_STUB_BIN=$(mktemp -d)

    export AM_DIR="$TEST_AM_DIR"
    export AM_REGISTRY="$AM_DIR/sessions.json"
    export AM_CONFIG="$AM_DIR/config.json"
    export AM_SESSION_PREFIX="test-am-"
    am_init
    am_config_init

    ln -sf "$TEST_STUB_DIR/stub_agent" "$TEST_STUB_BIN/claude"
    ln -sf "$TEST_STUB_DIR/stub_agent" "$TEST_STUB_BIN/codex"
    ln -sf "$TEST_STUB_DIR/stub_agent" "$TEST_STUB_BIN/gemini"
    TEST_OLD_PATH="${PATH:-}"
    export PATH="$TEST_STUB_BIN:$PATH"
    # Propagate test env into the tmux server so run-shell commands inherit it
    tmux -L "$AM_TMUX_SOCKET" set-environment -g PATH "$PATH" 2>/dev/null || true
    tmux -L "$AM_TMUX_SOCKET" set-environment -g AM_TMUX_SOCKET "$AM_TMUX_SOCKET" 2>/dev/null || true
    tmux -L "$AM_TMUX_SOCKET" set-environment -g AM_SESSION_PREFIX "$AM_SESSION_PREFIX" 2>/dev/null || true
    tmux -L "$AM_TMUX_SOCKET" set-environment -g AM_DIR "$AM_DIR" 2>/dev/null || true
    tmux -L "$AM_TMUX_SOCKET" set-environment -g HISTFILE /dev/null 2>/dev/null || true

    # Point agent commands to stub
    AGENT_COMMANDS[claude]="$TEST_STUB_DIR/stub_agent"
    AGENT_COMMANDS[codex]="$TEST_STUB_DIR/stub_agent"
    AGENT_COMMANDS[gemini]="$TEST_STUB_DIR/stub_agent"
}

# Tear down integration test environment
# Kills any test-created tmux sessions, removes temp dirs
# Usage: teardown_integration_env
teardown_integration_env() {
    # Kill only test sessions by their unique prefix
    local session
    for session in $(tmux -L "$AM_TMUX_SOCKET" list-sessions -F '#{session_name}' 2>/dev/null | grep '^test-am-' || true); do
        tmux -L "$AM_TMUX_SOCKET" kill-session -t "$session" 2>/dev/null || true
    done

    # Restore AM_DIR and session prefix
    rm -rf "${TEST_AM_DIR:-}"
    rm -rf "${TEST_STUB_BIN:-}"
    TEST_AM_DIR=""
    TEST_STUB_BIN=""
    export AM_DIR="${HOME}/.agent-manager"
    export AM_REGISTRY="$AM_DIR/sessions.json"
    export AM_CONFIG="$AM_DIR/config.json"
    export AM_SESSION_PREFIX="am-"
    export PATH="${TEST_OLD_PATH:-$PATH}"
}

# ============================================
# Test runner
# ============================================

_run_test() {
    if $SUMMARY_MODE; then
        "$1" 2>/dev/null
    else
        "$1"
    fi
}

# Print test results summary and exit with appropriate code
# Usage: test_report
test_report() {
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
        echo "========================================"
        exit 1
    else
        echo -e "  ${GREEN}All tests passed!${RESET}"
    fi
    echo "========================================"
}
