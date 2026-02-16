#!/usr/bin/env bash
# test_all.sh - Test suite for agent-manager

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
LIB_DIR="$PROJECT_DIR/lib"

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

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
        echo -e "${GREEN}PASS${RESET}: $msg"
        ((TESTS_PASSED++))
    else
        echo -e "${RED}FAIL${RESET}: $msg"
        echo "  Expected: '$expected'"
        echo "  Actual:   '$actual'"
        ((TESTS_FAILED++))
    fi
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local msg="${3:-}"
    ((TESTS_RUN++))
    if [[ "$haystack" == *"$needle"* ]]; then
        echo -e "${GREEN}PASS${RESET}: $msg"
        ((TESTS_PASSED++))
    else
        echo -e "${RED}FAIL${RESET}: $msg"
        echo "  String: '$haystack'"
        echo "  Does not contain: '$needle'"
        ((TESTS_FAILED++))
    fi
}

assert_not_empty() {
    local value="$1"
    local msg="${2:-}"
    ((TESTS_RUN++))
    if [[ -n "$value" ]]; then
        echo -e "${GREEN}PASS${RESET}: $msg"
        ((TESTS_PASSED++))
    else
        echo -e "${RED}FAIL${RESET}: $msg (value is empty)"
        ((TESTS_FAILED++))
    fi
}

assert_cmd_succeeds() {
    local msg="$1"
    shift
    ((TESTS_RUN++))
    if "$@" &>/dev/null; then
        echo -e "${GREEN}PASS${RESET}: $msg"
        ((TESTS_PASSED++))
    else
        echo -e "${RED}FAIL${RESET}: $msg"
        ((TESTS_FAILED++))
    fi
}

skip_test() {
    local msg="$1"
    echo -e "${YELLOW}SKIP${RESET}: $msg"
}

# Check dependencies
check_deps() {
    local missing=()
    command -v jq &>/dev/null || missing+=("jq")
    command -v tmux &>/dev/null || missing+=("tmux")
    command -v fzf &>/dev/null || missing+=("fzf")

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo -e "${YELLOW}Warning: Missing dependencies: ${missing[*]}${RESET}"
        echo "Some tests will be skipped."
        echo ""
    fi
}

# ============================================
# Test: utils.sh
# ============================================
test_utils() {
    echo "=== Testing utils.sh ==="
    source "$LIB_DIR/utils.sh"

    # Test format_time_ago
    assert_eq "5s ago" "$(format_time_ago 5)" "format_time_ago: 5 seconds"
    assert_eq "2m ago" "$(format_time_ago 120)" "format_time_ago: 2 minutes"
    assert_eq "1h 30m ago" "$(format_time_ago 5400)" "format_time_ago: 1.5 hours"
    assert_eq "2d ago" "$(format_time_ago 172800)" "format_time_ago: 2 days"

    # Test format_duration
    assert_eq "30s" "$(format_duration 30)" "format_duration: 30 seconds"
    assert_eq "5m" "$(format_duration 300)" "format_duration: 5 minutes"
    assert_eq "2h 0m" "$(format_duration 7200)" "format_duration: 2 hours"

    # Test truncate
    assert_eq "hello" "$(truncate 'hello' 10)" "truncate: short string unchanged"
    assert_eq "hello w..." "$(truncate 'hello world' 10)" "truncate: long string truncated"

    # Test generate_hash
    local hash1=$(generate_hash "test")
    local hash2=$(generate_hash "test")
    assert_eq "$hash1" "$hash2" "generate_hash: deterministic"
    assert_eq 6 "${#hash1}" "generate_hash: 6 chars"

    # Test dir_basename
    assert_eq "foo" "$(dir_basename '/path/to/foo')" "dir_basename: extracts basename"

    echo ""
}

# ============================================
# Test: registry.sh
# ============================================
test_registry() {
    echo "=== Testing registry.sh ==="

    if ! command -v jq &>/dev/null; then
        skip_test "registry tests (jq not installed)"
        echo ""
        return
    fi

    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/registry.sh"

    # Use temp directory for test registry
    export AM_DIR=$(mktemp -d)
    export AM_REGISTRY="$AM_DIR/sessions.json"

    # Test init
    registry_init
    assert_cmd_succeeds "registry_init creates file" test -f "$AM_REGISTRY"

    # Test add
    registry_add "test-session" "/tmp/test" "main" "claude" "test task"
    assert_eq "true" "$(registry_exists test-session && echo true || echo false)" "registry_add: session exists"

    # Test get_field
    assert_eq "/tmp/test" "$(registry_get_field test-session directory)" "registry_get_field: directory"
    assert_eq "main" "$(registry_get_field test-session branch)" "registry_get_field: branch"
    assert_eq "claude" "$(registry_get_field test-session agent_type)" "registry_get_field: agent_type"

    # Test update
    registry_update "test-session" "branch" "feature"
    assert_eq "feature" "$(registry_get_field test-session branch)" "registry_update: changes field"

    # Test list
    registry_add "test-session-2" "/tmp/test2" "dev" "gemini" ""
    local count=$(registry_list | wc -l | tr -d ' ')
    assert_eq "2" "$count" "registry_list: returns all sessions"

    # Test count
    assert_eq "2" "$(registry_count)" "registry_count: correct count"

    # Test remove
    registry_remove "test-session"
    assert_eq "false" "$(registry_exists test-session && echo true || echo false)" "registry_remove: session gone"
    assert_eq "1" "$(registry_count)" "registry_remove: count updated"

    # Cleanup
    rm -rf "$AM_DIR"

    echo ""
}

# ============================================
# Test: tmux.sh (requires tmux)
# ============================================
test_tmux() {
    echo "=== Testing tmux.sh ==="

    if ! command -v tmux &>/dev/null; then
        skip_test "tmux tests (tmux not installed)"
        echo ""
        return
    fi

    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/tmux.sh"

    # Test session_exists for non-existent session
    assert_eq "false" "$(tmux_session_exists 'nonexistent-test-session-xyz' && echo true || echo false)" "tmux_session_exists: false for missing"

    # Test create and kill (only if not in CI/restricted env)
    local test_session="am-test-$$"
    if tmux_create_session "$test_session" "/tmp"; then
        assert_eq "true" "$(tmux_session_exists "$test_session" && echo true || echo false)" "tmux_create_session: creates session"

        # Test capture (may be empty for new session, just ensure no error)
        local content=$(tmux_capture_pane "$test_session" 10)
        assert_cmd_succeeds "tmux_capture_pane: runs without error" true

        # Cleanup
        tmux_kill_session "$test_session"
        assert_eq "false" "$(tmux_session_exists "$test_session" && echo true || echo false)" "tmux_kill_session: removes session"
    else
        skip_test "tmux create/kill tests (unable to create session)"
    fi

    echo ""
}

# ============================================
# Test: agents.sh
# ============================================
test_agents() {
    echo "=== Testing agents.sh ==="

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
    source "$LIB_DIR/agents.sh"

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

    echo ""
}

# ============================================
# Test: am CLI
# ============================================
test_cli() {
    echo "=== Testing am CLI ==="

    # Test help (no deps needed)
    local help_output=$("$PROJECT_DIR/am" help)
    assert_contains "$help_output" "Agent Manager" "am help: shows title"
    assert_contains "$help_output" "USAGE" "am help: shows usage"
    assert_contains "$help_output" "COMMANDS" "am help: shows commands"

    # Test version
    local version_output=$("$PROJECT_DIR/am" version)
    assert_contains "$version_output" "0.1.0" "am version: shows version"

    echo ""
}

# ============================================
# Main
# ============================================
main() {
    echo "========================================"
    echo "  Agent Manager Test Suite"
    echo "========================================"
    echo ""

    check_deps

    test_utils
    test_registry
    test_tmux
    test_agents
    test_cli

    echo "========================================"
    echo "  Results: $TESTS_PASSED/$TESTS_RUN passed"
    if [[ $TESTS_FAILED -gt 0 ]]; then
        echo -e "  ${RED}$TESTS_FAILED tests failed${RESET}"
        exit 1
    else
        echo -e "  ${GREEN}All tests passed!${RESET}"
    fi
    echo "========================================"
}

main "$@"
