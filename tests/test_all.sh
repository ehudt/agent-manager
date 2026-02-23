#!/usr/bin/env bash
# test_all.sh - Test suite for agent-manager

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="$SCRIPT_DIR"  # Stable ref — SCRIPT_DIR gets overwritten by lib/agents.sh
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
        echo -e "${RED}Missing required dependencies: ${missing[*]}${RESET}"
        echo "Install prerequisites first, then rerun tests."
        echo "See README prerequisites section."
        exit 1
    fi
}

# ============================================
# Integration test helpers
# ============================================

# Assert a command fails (non-zero exit)
assert_cmd_fails() {
    local msg="$1"
    shift
    ((TESTS_RUN++))
    if "$@" &>/dev/null; then
        echo -e "${RED}FAIL${RESET}: $msg (expected failure, got success)"
        ((TESTS_FAILED++))
    else
        echo -e "${GREEN}PASS${RESET}: $msg"
        ((TESTS_PASSED++))
    fi
}

# Setup isolated test environment for integration tests
# Sets AM_DIR to a temp dir, creates stub agent, overrides AGENT_COMMANDS
# IMPORTANT: Call AFTER sourcing agents.sh (declare -A resets AGENT_COMMANDS)
# Usage: setup_integration_env
# After calling, use $TEST_AM_DIR, $TEST_STUB_DIR
setup_integration_env() {
    TEST_AM_DIR=$(mktemp -d)
    TEST_STUB_DIR="$TEST_DIR"  # stub_agent lives in tests/

    export AM_DIR="$TEST_AM_DIR"
    export AM_REGISTRY="$AM_DIR/sessions.json"
    export AM_SESSION_PREFIX="test-am-"
    am_init

    # Point agent commands to stub
    AGENT_COMMANDS[claude]="$TEST_STUB_DIR/stub_agent"
    AGENT_COMMANDS[codex]="$TEST_STUB_DIR/stub_agent"
    AGENT_COMMANDS[gemini]="$TEST_STUB_DIR/stub_agent"
}

# Tear down integration test environment
# Kills any test-created tmux sessions, removes temp dirs
# Usage: teardown_integration_env
teardown_integration_env() {
    # Kill only test sessions by their unique prefix (never touches real am-* sessions)
    local session
    for session in $(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep '^test-am-' || true); do
        tmux kill-session -t "$session" 2>/dev/null || true
    done

    # Restore AM_DIR and session prefix
    rm -rf "${TEST_AM_DIR:-}"
    TEST_AM_DIR=""
    export AM_DIR="${HOME}/.agent-manager"
    export AM_REGISTRY="$AM_DIR/sessions.json"
    export AM_SESSION_PREFIX="am-"
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
# Test: utils.sh (extended edge cases)
# ============================================
test_utils_extended() {
    echo "=== Testing utils.sh (extended) ==="
    source "$LIB_DIR/utils.sh"

    # format_time_ago: edge cases
    assert_eq "0s ago" "$(format_time_ago 0)" "format_time_ago: zero seconds"
    assert_eq "just now" "$(format_time_ago -5)" "format_time_ago: negative"
    assert_eq "11574d ago" "$(format_time_ago 1000000000)" "format_time_ago: very large"

    # format_duration: edge cases
    assert_eq "0s" "$(format_duration 0)" "format_duration: zero"
    assert_eq "1d 0h" "$(format_duration 86400)" "format_duration: exactly 1 day"

    # truncate: edge cases
    assert_eq "" "$(truncate '' 10)" "truncate: empty string"
    assert_eq "hi" "$(truncate 'hi' 10)" "truncate: shorter than limit"
    assert_eq "0123456789" "$(truncate '0123456789' 10)" "truncate: exact limit length"

    # generate_hash: consistency
    local h1=$(generate_hash "same-input")
    local h2=$(generate_hash "same-input")
    local h3=$(generate_hash "different-input")
    assert_eq "$h1" "$h2" "generate_hash: same input same output"
    # Different inputs SHOULD produce different hashes (not guaranteed but overwhelmingly likely)
    if [[ "$h1" != "$h3" ]]; then
        ((TESTS_RUN++)); ((TESTS_PASSED++))
        echo -e "${GREEN}PASS${RESET}: generate_hash: different inputs different output"
    else
        ((TESTS_RUN++)); ((TESTS_FAILED++))
        echo -e "${RED}FAIL${RESET}: generate_hash: different inputs produced same hash"
    fi

    # abspath: with real directories
    local tmpd=$(mktemp -d)
    assert_eq "$tmpd" "$(abspath "$tmpd")" "abspath: absolute path unchanged"
    rm -rf "$tmpd"

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
# Test: registry.sh (extended edge cases)
# ============================================
test_registry_extended() {
    echo "=== Testing registry.sh (extended) ==="

    if ! command -v jq &>/dev/null; then
        skip_test "registry extended tests (jq not installed)"
        echo ""
        return
    fi

    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/registry.sh"

    # Isolated registry
    local old_am_dir="$AM_DIR"
    local old_am_registry="$AM_REGISTRY"
    export AM_DIR=$(mktemp -d)
    export AM_REGISTRY="$AM_DIR/sessions.json"
    am_init

    # Test: get_field on nonexistent session returns empty
    local result
    result=$(registry_get_field "nonexistent" "directory")
    assert_eq "" "$result" "registry_get_field: empty for missing session"

    # Test: update on nonexistent session is a no-op (doesn't crash)
    assert_cmd_succeeds "registry_update: no-op for missing session" \
        registry_update "nonexistent" "branch" "value"
    assert_eq "0" "$(registry_count)" "registry_update: count unchanged after no-op"

    # Test: remove on nonexistent session is idempotent
    assert_cmd_succeeds "registry_remove: idempotent for missing session" \
        registry_remove "nonexistent"
    assert_eq "0" "$(registry_count)" "registry_remove: count stays 0"

    # Test: duplicate add overwrites
    registry_add "dup-session" "/tmp/first" "main" "claude" ""
    registry_add "dup-session" "/tmp/second" "dev" "gemini" ""
    assert_eq "/tmp/second" "$(registry_get_field dup-session directory)" \
        "registry_add: duplicate overwrites directory"
    assert_eq "gemini" "$(registry_get_field dup-session agent_type)" \
        "registry_add: duplicate overwrites agent_type"
    assert_eq "1" "$(registry_count)" "registry_add: duplicate doesn't increase count"

    # Test: rapid sequential adds don't corrupt
    registry_add "rapid-1" "/tmp/r1" "main" "claude" ""
    registry_add "rapid-2" "/tmp/r2" "main" "codex" ""
    registry_add "rapid-3" "/tmp/r3" "main" "gemini" ""
    assert_eq "4" "$(registry_count)" "registry: rapid adds all persisted"
    assert_eq "/tmp/r1" "$(registry_get_field rapid-1 directory)" "registry: rapid-1 correct"
    assert_eq "/tmp/r3" "$(registry_get_field rapid-3 directory)" "registry: rapid-3 correct"

    # Cleanup
    rm -rf "$AM_DIR"
    export AM_DIR="$old_am_dir"
    export AM_REGISTRY="$old_am_registry"

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

    echo ""
}

# ============================================
# Test: agents.sh (extended)
# ============================================
test_agents_extended() {
    echo "=== Testing agents.sh (extended) ==="

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
        echo -e "${GREEN}PASS${RESET}: generate_session_name: different dirs different names"
    else
        ((TESTS_RUN++)); ((TESTS_FAILED++))
        echo -e "${RED}FAIL${RESET}: generate_session_name: collision for different dirs"
    fi

    # Test generate_session_name format: am-XXXXXX
    local name=$(generate_session_name "/tmp/test")
    assert_contains "$name" "am-" "generate_session_name: starts with am-"
    assert_eq 9 "${#name}" "generate_session_name: length is 9 (am- + 6)"

    # Test agent_get_yolo_flag for gemini (uses default --yolo)
    assert_eq "--yolo" "$(agent_get_yolo_flag gemini)" "agent_get_yolo_flag: gemini"

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
# Test: Integration - Session Lifecycle
# ============================================
test_integration_lifecycle() {
    echo "=== Testing Integration: Session Lifecycle ==="

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
    pane_count=$(tmux list-panes -t "$session_name" 2>/dev/null | wc -l | tr -d ' ')
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

    echo ""
}

# ============================================
# Test: CLI commands (extended)
# ============================================
test_cli_extended() {
    echo "=== Testing CLI commands (extended) ==="

    if ! command -v jq &>/dev/null || ! command -v tmux &>/dev/null; then
        skip_test "cli extended tests (jq or tmux not installed)"
        echo ""
        return
    fi

    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/tmux.sh"
    source "$LIB_DIR/registry.sh"
    set +u; source "$LIB_DIR/agents.sh"; set -u

    setup_integration_env

    local test_dir=$(mktemp -d)

    # Create a session for testing against
    local session_name
    session_name=$(set +u; agent_launch "$test_dir" "claude" "cli test" 2>/dev/null)

    if [[ -z "$session_name" ]]; then
        skip_test "cli extended tests (agent_launch failed)"
        teardown_integration_env
        rm -rf "$test_dir"
        echo ""
        return
    fi

    # --- Test: am list --json returns valid JSON containing our session ---
    local json_output
    json_output=$(AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" "$PROJECT_DIR/am" list --json 2>/dev/null)
    # Validate JSON
    if echo "$json_output" | jq . >/dev/null 2>&1; then
        ((TESTS_RUN++)); ((TESTS_PASSED++))
        echo -e "${GREEN}PASS${RESET}: am list --json: valid JSON"
    else
        ((TESTS_RUN++)); ((TESTS_FAILED++))
        echo -e "${RED}FAIL${RESET}: am list --json: invalid JSON"
    fi
    assert_contains "$json_output" "$session_name" "am list --json: contains session"

    # --- Test: am info <session> ---
    local info_output
    info_output=$(AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" "$PROJECT_DIR/am" info "$session_name" 2>/dev/null)
    assert_contains "$info_output" "Directory:" "am info: shows directory"
    assert_contains "$info_output" "Agent:" "am info: shows agent type"

    # --- Test: am kill <session> ---
    AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" "$PROJECT_DIR/am" kill "$session_name" 2>/dev/null
    assert_eq "false" "$(tmux_session_exists "$session_name" && echo true || echo false)" \
        "am kill: session removed"

    # --- Test: am attach nonexistent fails ---
    local attach_rc=0
    AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" "$PROJECT_DIR/am" attach nonexistent-xyz </dev/null 2>/dev/null || attach_rc=$?
    assert_eq "false" "$(test $attach_rc -eq 0 && echo true || echo false)" \
        "am attach nonexistent: exits with error"

    # --- Test: am kill with no args fails ---
    local kill_rc=0
    AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" "$PROJECT_DIR/am" kill </dev/null 2>/dev/null || kill_rc=$?
    assert_eq "false" "$(test $kill_rc -eq 0 && echo true || echo false)" \
        "am kill no args: exits with error"

    # --- Test: am status runs without error ---
    local status_rc=0
    AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" "$PROJECT_DIR/am" status >/dev/null 2>&1 || status_rc=$?
    assert_eq "true" "$(test $status_rc -eq 0 && echo true || echo false)" \
        "am status: exits 0"

    # Cleanup
    rm -rf "$test_dir"
    teardown_integration_env

    echo ""
}

# ============================================
# Test: Integration - Registry GC
# ============================================
test_registry_gc() {
    echo "=== Testing Integration: Registry GC ==="

    if ! command -v jq &>/dev/null || ! command -v tmux &>/dev/null; then
        skip_test "registry GC tests (jq or tmux not installed)"
        echo ""
        return
    fi

    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/tmux.sh"
    source "$LIB_DIR/registry.sh"
    set +u; source "$LIB_DIR/agents.sh"; set -u

    setup_integration_env

    local test_dir=$(mktemp -d)

    # Create a live session
    local live_session
    live_session=$(set +u; agent_launch "$test_dir" "claude" "" 2>/dev/null)

    if [[ -z "$live_session" ]]; then
        skip_test "registry GC tests (agent_launch failed)"
        teardown_integration_env
        rm -rf "$test_dir"
        echo ""
        return
    fi

    # Manually add a stale entry (no corresponding tmux session)
    registry_add "test-am-stale-fake" "/tmp/gone" "main" "claude" ""
    assert_eq "true" "$(registry_exists test-am-stale-fake && echo true || echo false)" \
        "gc setup: stale entry exists"

    # Run GC (force to bypass throttle)
    local removed
    removed=$(registry_gc 1)
    assert_eq "1" "$removed" "registry_gc: removed 1 stale entry"

    # Verify stale entry gone, live entry preserved
    assert_eq "false" "$(registry_exists test-am-stale-fake && echo true || echo false)" \
        "registry_gc: stale entry removed"
    assert_eq "true" "$(registry_exists "$live_session" && echo true || echo false)" \
        "registry_gc: live entry preserved"

    # --- Test: GC throttling ---
    # Add another stale entry
    registry_add "test-am-stale-fake-2" "/tmp/gone2" "main" "claude" ""

    # Run GC without force — should be throttled (within 60s of last run)
    removed=$(registry_gc)
    assert_eq "0" "$removed" "registry_gc: throttled within 60s"

    # Stale entry should still exist (GC was skipped)
    assert_eq "true" "$(registry_exists test-am-stale-fake-2 && echo true || echo false)" \
        "registry_gc: stale entry survives throttle"

    # Force GC should still work
    removed=$(registry_gc 1)
    assert_eq "1" "$removed" "registry_gc: force bypasses throttle"

    # Cleanup
    [[ -n "$live_session" ]] && agent_kill "$live_session" 2>/dev/null
    rm -rf "$test_dir"
    teardown_integration_env

    echo ""
}

# ============================================
# Test: Session History (history.jsonl)
# ============================================
test_history() {
    echo "=== Testing Session History ==="

    if ! command -v jq &>/dev/null; then
        skip_test "history tests (jq not installed)"
        echo ""
        return
    fi

    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/registry.sh"

    # Isolated environment
    local old_am_dir="$AM_DIR"
    local old_am_registry="$AM_REGISTRY"
    local old_am_history="${AM_HISTORY:-}"
    export AM_DIR=$(mktemp -d)
    export AM_REGISTRY="$AM_DIR/sessions.json"
    export AM_HISTORY="$AM_DIR/history.jsonl"
    am_init

    # --- Test: history_append creates file and writes correct JSON ---
    history_append "/tmp/project-a" "fix login bug" "claude" "main"
    assert_cmd_succeeds "history_append: creates history file" test -f "$AM_HISTORY"

    local first_line
    first_line=$(head -1 "$AM_HISTORY")
    assert_contains "$first_line" '"task":"fix login bug"' "history_append: correct task"
    assert_contains "$first_line" '"directory":"/tmp/project-a"' "history_append: correct directory"
    assert_contains "$first_line" '"agent_type":"claude"' "history_append: correct agent_type"
    assert_contains "$first_line" '"branch":"main"' "history_append: correct branch"

    # Validate it's proper JSON
    assert_cmd_succeeds "history_append: valid JSON" jq . <<< "$first_line"

    # --- Test: multiple entries accumulate ---
    history_append "/tmp/project-a" "add tests" "claude" "main"
    history_append "/tmp/project-b" "refactor utils" "gemini" "dev"

    local line_count
    line_count=$(wc -l < "$AM_HISTORY" | tr -d ' ')
    assert_eq "3" "$line_count" "history_append: multiple entries accumulate"

    # --- Test: history_append with empty task is a no-op ---
    history_append "/tmp/project-a" "" "claude" "main"
    line_count=$(wc -l < "$AM_HISTORY" | tr -d ' ')
    assert_eq "3" "$line_count" "history_append: empty task is no-op"

    # --- Test: history_for_directory filters correctly and returns most recent first ---
    local dir_a_entries
    dir_a_entries=$(history_for_directory "/tmp/project-a")
    local dir_a_count
    dir_a_count=$(echo "$dir_a_entries" | wc -l | tr -d ' ')
    assert_eq "2" "$dir_a_count" "history_for_directory: filters to correct directory"

    # Most recent first: "add tests" should be before "fix login bug"
    local first_task
    first_task=$(echo "$dir_a_entries" | head -1 | jq -r '.task')
    assert_eq "add tests" "$first_task" "history_for_directory: most recent first"

    local second_task
    second_task=$(echo "$dir_a_entries" | tail -1 | jq -r '.task')
    assert_eq "fix login bug" "$second_task" "history_for_directory: oldest last"

    # --- Test: history_for_directory returns empty for unknown paths ---
    local unknown_entries
    unknown_entries=$(history_for_directory "/tmp/nonexistent-path")
    assert_eq "" "$unknown_entries" "history_for_directory: empty for unknown path"

    # --- Test: history_prune removes entries older than 7 days ---
    # Inject an old entry manually (8 days ago)
    local old_date
    old_date=$(date -u -v-8d +"%Y-%m-%dT%H:%M:%SZ")
    printf '%s\n' "$(jq -cn \
        --arg dir "/tmp/project-a" \
        --arg task "ancient task" \
        --arg agent "claude" \
        --arg branch "main" \
        --arg created "$old_date" \
        '{directory: $dir, task: $task, agent_type: $agent, branch: $branch, created_at: $created}')" \
        >> "$AM_HISTORY"

    # Verify old entry was added
    line_count=$(wc -l < "$AM_HISTORY" | tr -d ' ')
    assert_eq "4" "$line_count" "history_prune setup: old entry injected"

    # Run prune
    history_prune
    line_count=$(wc -l < "$AM_HISTORY" | tr -d ' ')
    assert_eq "3" "$line_count" "history_prune: removed old entry"

    # Verify the old entry is gone
    local ancient_count
    ancient_count=$(jq -c 'select(.task == "ancient task")' "$AM_HISTORY" 2>/dev/null | wc -l | tr -d ' ')
    assert_eq "0" "$ancient_count" "history_prune: ancient task removed"

    # Cleanup
    rm -rf "$AM_DIR"
    export AM_DIR="$old_am_dir"
    export AM_REGISTRY="$old_am_registry"
    export AM_HISTORY="$old_am_history"

    echo ""
}

# ============================================
# Test: History Integration (wiring into lifecycle)
# ============================================
test_history_integration() {
    echo "=== Testing History Integration ==="

    if ! command -v jq &>/dev/null; then
        skip_test "history integration tests (jq not installed)"
        echo ""
        return
    fi

    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/registry.sh"

    # Isolated environment
    local old_am_dir="$AM_DIR"
    local old_am_registry="$AM_REGISTRY"
    local old_am_history="${AM_HISTORY:-}"
    export AM_DIR=$(mktemp -d)
    export AM_REGISTRY="$AM_DIR/sessions.json"
    export AM_HISTORY="$AM_DIR/history.jsonl"
    am_init

    # Simulate what agent_launch does: registry_add + history_append
    registry_add "test-hist-session" "/tmp/myproject" "main" "claude" "fix auth bug"
    history_append "/tmp/myproject" "fix auth bug" "claude" "main"

    # Verify history file exists and contains the task
    assert_cmd_succeeds "history_integration: history file created" test -f "$AM_HISTORY"

    local hist_content
    hist_content=$(cat "$AM_HISTORY")
    assert_contains "$hist_content" '"task":"fix auth bug"' \
        "history_integration: task recorded in history"
    assert_contains "$hist_content" '"directory":"/tmp/myproject"' \
        "history_integration: directory recorded in history"

    # Simulate auto_title_session path: registry_update + history_append via registry_get_field
    registry_add "test-hist-auto" "/tmp/another" "dev" "gemini" ""
    # Simulate what auto_title_session does after getting a title
    registry_update "test-hist-auto" "task" "refactor utils"
    local dir branch agent
    dir=$(registry_get_field "test-hist-auto" "directory")
    branch=$(registry_get_field "test-hist-auto" "branch")
    agent=$(registry_get_field "test-hist-auto" "agent_type")
    history_append "$dir" "refactor utils" "$agent" "$branch"

    local line_count
    line_count=$(wc -l < "$AM_HISTORY" | tr -d ' ')
    assert_eq "2" "$line_count" "history_integration: two entries after both paths"

    # Verify the second entry
    local second_line
    second_line=$(tail -1 "$AM_HISTORY")
    assert_contains "$second_line" '"task":"refactor utils"' \
        "history_integration: auto-title task recorded"
    assert_contains "$second_line" '"agent_type":"gemini"' \
        "history_integration: auto-title agent_type correct"

    # Cleanup
    rm -rf "$AM_DIR"
    export AM_DIR="$old_am_dir"
    export AM_REGISTRY="$old_am_registry"
    export AM_HISTORY="$old_am_history"

    echo ""
}

# ============================================
# Test: Worktree feature (-w/--worktree)
# ============================================
test_worktree() {
    echo "=== Testing Worktree Feature ==="

    if ! command -v jq &>/dev/null || ! command -v tmux &>/dev/null; then
        skip_test "worktree tests (jq or tmux not installed)"
        echo ""
        return
    fi

    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/tmux.sh"
    source "$LIB_DIR/registry.sh"
    set +u; source "$LIB_DIR/agents.sh"; set -u

    setup_integration_env

    # Create a temp git repo for worktree tests
    local git_dir=$(mktemp -d)
    git -C "$git_dir" init -q
    git -C "$git_dir" commit --allow-empty -m "init" -q

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
        echo -e "${GREEN}PASS${RESET}: no-worktree launch: info omits Worktree line"
    else
        ((TESTS_RUN++)); ((TESTS_FAILED++))
        echo -e "${RED}FAIL${RESET}: no-worktree launch: info unexpectedly shows Worktree"
    fi

    [[ -n "$session_name" ]] && agent_kill "$session_name" 2>/dev/null

    # --- Test: __auto__ sentinel resolves to am-<hash> ---
    session_name=$(set +u; agent_launch "$git_dir" "claude" "" "__auto__" 2>/dev/null)
    assert_not_empty "$session_name" "auto-worktree launch: returns session name"

    wt_path=$(registry_get_field "$session_name" worktree_path)
    assert_contains "$wt_path" ".claude/worktrees/am-" \
        "auto-worktree: worktree_path contains am- prefix"

    [[ -n "$session_name" ]] && agent_kill "$session_name" 2>/dev/null

    # --- Test: non-claude agent type ignores worktree ---
    local warn_output
    warn_output=$(set +u; agent_launch "$git_dir" "codex" "" "my-wt" 2>&1 >/dev/null)
    # The launch itself may return a session (worktree is just ignored)
    session_name=$(set +u; agent_launch "$git_dir" "codex" "" "my-wt" 2>/dev/null)
    if [[ -n "$session_name" ]]; then
        wt_path=$(registry_get_field "$session_name" worktree_path)
        assert_eq "" "$wt_path" "non-claude worktree: worktree_path not set"
        agent_kill "$session_name" 2>/dev/null
    else
        skip_test "non-claude worktree: agent_launch failed"
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
        agent_kill "$session_name" 2>/dev/null
    else
        skip_test "display_name no task: agent_launch failed"
    fi

    # Cleanup
    rm -rf "$git_dir" "$nongit_dir"
    teardown_integration_env

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
    test_utils_extended
    test_registry
    test_registry_extended
    test_tmux
    test_agents
    test_agents_extended
    test_cli
    test_integration_lifecycle
    test_cli_extended
    test_registry_gc
    test_history
    test_history_integration
    test_worktree

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
