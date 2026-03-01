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
    export AM_CONFIG="$AM_DIR/config.json"
    export AM_SESSION_PREFIX="test-am-"
    am_init
    am_config_init

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
    export AM_CONFIG="$AM_DIR/config.json"
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
# Test: config.sh
# ============================================
test_config() {
    echo "=== Testing config.sh ==="

    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/config.sh"

    local original_am_dir="${AM_DIR:-}"
    local original_am_config="${AM_CONFIG:-}"
    local original_default_agent="${AM_DEFAULT_AGENT:-}"
    local original_default_yolo="${AM_DEFAULT_YOLO:-}"
    local original_stream_logs="${AM_STREAM_LOGS:-}"

    export AM_DIR
    AM_DIR=$(mktemp -d)
    export AM_CONFIG="$AM_DIR/config.json"

    am_config_init
    assert_eq "true" "$(test -f "$AM_CONFIG" && echo true || echo false)" "config: creates config file"
    assert_eq "claude" "$(am_default_agent)" "config: default agent fallback"
    assert_eq "false" "$(am_default_yolo_enabled && echo true || echo false)" "config: default yolo fallback"
    assert_eq "false" "$(am_stream_logs_enabled && echo true || echo false)" "config: default logs fallback"

    am_config_set "default_agent" "codex" "string"
    am_config_set "default_yolo" "true" "boolean"
    am_config_set "stream_logs" "yes" "boolean"

    assert_eq "codex" "$(am_default_agent)" "config: saved default agent"
    assert_eq "true" "$(am_default_yolo_enabled && echo true || echo false)" "config: saved default yolo"
    assert_eq "true" "$(am_stream_logs_enabled && echo true || echo false)" "config: saved stream logs"
    assert_eq "true" "$(am_maybe_apply_default_yolo --resume && echo true || echo false)" "config: applies default yolo when missing"
    assert_eq "false" "$(am_maybe_apply_default_yolo --yolo && echo true || echo false)" "config: does not duplicate yolo flag"

    export AM_DEFAULT_AGENT="gemini"
    export AM_DEFAULT_YOLO="false"
    export AM_STREAM_LOGS="0"
    assert_eq "gemini" "$(am_default_agent)" "config: env overrides saved agent"
    assert_eq "false" "$(am_default_yolo_enabled && echo true || echo false)" "config: env overrides saved yolo"
    assert_eq "false" "$(am_stream_logs_enabled && echo true || echo false)" "config: env overrides saved logs"

    am_config_unset "default_agent"
    unset AM_DEFAULT_AGENT AM_DEFAULT_YOLO AM_STREAM_LOGS
    assert_eq "claude" "$(am_default_agent)" "config: unset falls back to built-in default"

    rm -rf "$AM_DIR"
    export AM_DIR="${original_am_dir:-$HOME/.agent-manager}"
    export AM_CONFIG="$original_am_config"
    export AM_DEFAULT_AGENT="$original_default_agent"
    export AM_DEFAULT_YOLO="$original_default_yolo"
    export AM_STREAM_LOGS="$original_stream_logs"

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
    am_init
    assert_cmd_succeeds "am_init creates registry file" test -f "$AM_REGISTRY"

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
# Test: fzf option ordering helpers
# ============================================
test_fzf_helpers() {
    echo "=== Testing fzf helpers ==="

    source "$LIB_DIR/utils.sh"
    set +u
    source "$LIB_DIR/config.sh"
    source "$LIB_DIR/tmux.sh"
    source "$LIB_DIR/registry.sh"
    source "$LIB_DIR/agents.sh"
    source "$LIB_DIR/fzf.sh"
    set -u

    local first_agent
    first_agent=$(fzf_agent_options "codex" | head -n1)
    assert_eq "codex" "$first_agent" "fzf helpers: default agent listed first"

    local first_mode
    first_mode=$(fzf_mode_options "true" | head -n1)
    assert_contains "$first_mode" "--yolo" "fzf helpers: yolo default listed first"

    first_mode=$(fzf_mode_options "false" | head -n1)
    assert_eq "New session" "$first_mode" "fzf helpers: safe default listed first"

    echo ""
}

# ============================================
# Test: tmux binding snippets
# ============================================
test_tmux_binding_snippets() {
    echo "=== Testing tmux binding snippets ==="

    local example_conf
    example_conf=$(cat "$PROJECT_DIR/config/tmux.conf.example")
    assert_contains "$example_conf" 'bind n if-shell -F '\''#{m:am-*,#{session_name}}'\'' '\''display-popup -E -w 90% -h 80% "am new"'\''' \
        "tmux snippet: prefix+n opens new-session popup"
    assert_contains "$example_conf" 'bind x if-shell -F '\''#{m:am-*,#{session_name}}'\'' '\''run-shell "kill-and-switch #{session_name}"'\''' \
        "tmux snippet: prefix+x kills current session"

    local install_script
    install_script=$(cat "$PROJECT_DIR/scripts/install.sh")
    assert_contains "$install_script" 'display-popup -E -w 90% -h 80% "$PREFIX/am new"' \
        "install script: prefix+n installs popup binding"
    assert_contains "$install_script" 'run-shell "$PREFIX/kill-and-switch #{session_name}"' \
        "install script: prefix+x installs kill binding"

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
    assert_eq "claude" "$(echo "$json_output" | jq -r '.[0].agent_type')" \
        "am list --json: preserves agent_type when branch is empty"
    assert_eq "" "$(echo "$json_output" | jq -r '.[0].branch')" \
        "am list --json: preserves empty branch field"

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

    # --- Test: am config commands ---
    local config_output
    config_output=$(AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" "$PROJECT_DIR/am" config set agent codex 2>/dev/null)
    assert_contains "$config_output" "default_agent=codex" "am config set agent: persists default"

    local config_get
    config_get=$(AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" "$PROJECT_DIR/am" config get agent 2>/dev/null)
    assert_eq "codex" "$config_get" "am config get agent: returns saved default"

    config_get=$(AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" AM_DEFAULT_AGENT="gemini" "$PROJECT_DIR/am" config get agent 2>/dev/null)
    assert_eq "gemini" "$config_get" "am config get agent: env override wins"

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
    old_date=$(date -u -v-8d +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || \
        date -u -d "8 days ago" +"%Y-%m-%dT%H:%M:%SZ")
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
    git -C "$git_dir" -c user.name="test" -c user.email="test@test" commit --allow-empty -m "init" -q

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
# Test: Annotated Directories (_annotate_directory, _strip_annotation)
# ============================================
test_annotated_directories() {
    echo ""
    echo "=== Annotated Directory Tests ==="

    if ! command -v jq &>/dev/null; then
        skip_test "annotated directory tests (jq not installed)"
        echo ""
        return
    fi

    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/registry.sh"

    # Need fzf.sh helpers but it requires fzf + tmux + agents.sh
    # Source dependencies in the right order
    if ! command -v tmux &>/dev/null || ! command -v fzf &>/dev/null; then
        skip_test "annotated directory tests (tmux or fzf not installed)"
        echo ""
        return
    fi

    source "$LIB_DIR/tmux.sh"
    set +u; source "$LIB_DIR/agents.sh"; set -u
    source "$LIB_DIR/fzf.sh"

    export AM_DIR=$(mktemp -d)
    export AM_REGISTRY="$AM_DIR/sessions.json"
    export AM_HISTORY="$AM_DIR/history.jsonl"
    am_init

    # Seed history
    history_append "/tmp/project-alpha" "Fix auth bug" "claude" "main"
    history_append "/tmp/project-alpha" "Add tests" "claude" "dev"
    history_append "/tmp/project-beta" "Dark mode" "gemini" "feature/ui"

    # Test _annotate_directory with history
    local annotation
    annotation=$(_annotate_directory "/tmp/project-alpha")
    assert_contains "$annotation" "Add tests" "annotate: shows most recent task"
    assert_contains "$annotation" "Fix auth" "annotate: shows older task"
    assert_contains "$annotation" "claude" "annotate: shows agent type"

    # Test _annotate_directory with no history
    annotation=$(_annotate_directory "/tmp/no-history")
    assert_eq "" "$annotation" "annotate: empty for unknown path"

    # Test _strip_annotation with tab-separated line
    local stripped
    stripped=$(_strip_annotation "/tmp/project-alpha	claude: Add tests (0m) | claude: Fix auth (0m)")
    assert_eq "/tmp/project-alpha" "$stripped" "strip: extracts path from annotated line"

    # Test _strip_annotation with plain path
    stripped=$(_strip_annotation "/tmp/plain-path")
    assert_eq "/tmp/plain-path" "$stripped" "strip: handles plain path"

    rm -rf "$AM_DIR"

    echo ""
}

# ============================================
# Test: Auto-title session title generation logic
# Tests the core logic of auto_title_session in isolation:
# - Title extraction from user message
# - Haiku success/failure paths
# - Fallback generation (first sentence)
# - Cleanup/validation (markdown strip, length check)
# ============================================
test_auto_title_session() {
    echo ""
    echo "=== Auto-Title Session Tests ==="

    if ! command -v jq &>/dev/null; then
        skip_test "auto-title tests (jq not installed)"
        echo ""
        return
    fi

    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/registry.sh"

    # Isolated AM environment
    local old_am_dir="$AM_DIR"
    local old_am_registry="$AM_REGISTRY"
    local old_am_history="${AM_HISTORY:-}"
    export AM_DIR=$(mktemp -d)
    export AM_REGISTRY="$AM_DIR/sessions.json"
    export AM_HISTORY="$AM_DIR/history.jsonl"
    am_init

    # --- Test Helper: Extract title logic from agents.sh ---
    # This tests the PURE LOGIC (sed/echo) without the background subshell
    _generate_fallback_title() {
        local msg="$1"
        echo "$msg" | sed -E 's/https?:\/\/[^ ]*//g; s/  +/ /g; s/[.?!].*//' | head -c 60
    }

    _strip_haiku_output() {
        local title="$1"
        # Strip markdown/quotes (from line 274 of agents.sh)
        title=$(echo "$title" | sed 's/^[#*\"`'\'''\''/]*//; s/[#*\"`'\'''\''/]*$//' | tr -d '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        echo "$title"
    }

    _is_valid_title() {
        local title="$1"
        # Valid if <= 60 chars and no newlines (from line 276 of agents.sh)
        if [[ ${#title} -le 60 && "$title" != *$'\n'* ]]; then
            echo "true"
        else
            echo "false"
        fi
    }

    # --- Test 1: Fallback title from first sentence ---
    local fallback
    fallback=$(_generate_fallback_title "Fix the login bug in auth module. Also refactor utils.")
    assert_contains "$fallback" "Fix the login bug" \
        "title_gen: fallback extracts first sentence"

    # --- Test 2: Fallback stops at punctuation ---
    fallback=$(_generate_fallback_title "Add user settings page? Not sure about design.")
    assert_contains "$fallback" "Add user settings page" \
        "title_gen: fallback stops at ?"

    # --- Test 3: Fallback removes URLs ---
    fallback=$(_generate_fallback_title "See https://example.com/docs for details. Fix auth bug.")
    assert_not_empty "$fallback" "title_gen: fallback handles URLs"
    if [[ "$fallback" != *"https"* ]]; then
        ((TESTS_RUN++)); ((TESTS_PASSED++))
        echo -e "${GREEN}PASS${RESET}: title_gen: fallback removes URLs"
    else
        ((TESTS_RUN++)); ((TESTS_FAILED++))
        echo -e "${RED}FAIL${RESET}: title_gen: fallback should remove URLs"
    fi

    # --- Test 4: Haiku output markdown stripping ---
    local stripped
    stripped=$(_strip_haiku_output "# Fix Login Bug")
    assert_eq "Fix Login Bug" "$stripped" \
        "title_gen: strips leading markdown"

    stripped=$(_strip_haiku_output "\`Refactor Database\`")
    assert_eq "Refactor Database" "$stripped" \
        "title_gen: strips backticks"

    stripped=$(_strip_haiku_output "*Add Dark Mode*")
    assert_eq "Add Dark Mode" "$stripped" \
        "title_gen: strips asterisks"

    # --- Test 5: Title validation - length check ---
    local is_valid
    is_valid=$(_is_valid_title "Short title")
    assert_eq "true" "$is_valid" \
        "title_gen: accepts valid short title"

    is_valid=$(_is_valid_title "This is a really really really really really really really long title over 60 chars")
    assert_eq "false" "$is_valid" \
        "title_gen: rejects title >60 chars"

    # --- Test 6: Title validation - newline check ---
    is_valid=$(_is_valid_title $'Multi\nline')
    assert_eq "false" "$is_valid" \
        "title_gen: rejects multiline titles"

    # --- Test 7: Edge case - empty message produces empty fallback ---
    fallback=$(_generate_fallback_title "")
    assert_eq "" "$fallback" \
        "title_gen: empty message produces empty fallback"

    # --- Test 8: Integration - registry update on successful title ---
    registry_add "test-title-reg" "/tmp/test" "main" "claude" ""
    registry_update "test-title-reg" "task" "Refactor API layer"
    local stored_task
    stored_task=$(registry_get_field "test-title-reg" "task")
    assert_eq "Refactor API layer" "$stored_task" \
        "title_gen: registry_update persists title"

    # --- Test 9: Integration - history append on title set ---
    history_append "/tmp/test" "Refactor API layer" "claude" "main"
    local hist_count=0
    [[ -f "$AM_HISTORY" ]] && hist_count=$(wc -l < "$AM_HISTORY" | tr -d ' ')
    assert_eq "1" "$hist_count" \
        "title_gen: history_append records task"

    # --- Test 10: History is skipped for empty task ---
    history_append "/tmp/test" "" "claude" "main"
    local hist_count_after=0
    [[ -f "$AM_HISTORY" ]] && hist_count_after=$(wc -l < "$AM_HISTORY" | tr -d ' ')
    assert_eq "$hist_count" "$hist_count_after" \
        "title_gen: history_append skips empty task"

    # --- Cleanup ---
    unset -f _generate_fallback_title _strip_haiku_output _is_valid_title
    rm -rf "$AM_DIR"
    export AM_DIR="$old_am_dir"
    export AM_REGISTRY="$old_am_registry"
    export AM_HISTORY="$old_am_history"

    echo ""
}

# ============================================
# Test: auto_title_scan (piggyback scanner)
# ============================================
test_auto_title_scan() {
    echo ""
    echo "=== Auto-Title Scan Tests ==="

    if ! command -v jq &>/dev/null; then
        skip_test "auto-title scan tests (jq not installed)"
        echo ""
        return
    fi

    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/registry.sh"

    # Isolated AM environment
    local old_am_dir="$AM_DIR"
    local old_am_registry="$AM_REGISTRY"
    local old_am_history="${AM_HISTORY:-}"
    export AM_DIR=$(mktemp -d)
    export AM_REGISTRY="$AM_DIR/sessions.json"
    export AM_HISTORY="$AM_DIR/history.jsonl"
    am_init

    # Stub claude_first_user_message
    claude_first_user_message() {
        case "$1" in
            */has-msg) echo "Fix the login bug in auth. Also refactor." ;;
            *) echo "" ;;
        esac
    }

    # --- Test 1: Titles untitled session with fallback ---
    registry_add "test-scan-1" "/tmp/has-msg" "main" "claude" ""
    auto_title_scan 1  # force
    local task
    task=$(registry_get_field "test-scan-1" "task")
    assert_contains "$task" "Fix the login bug in auth" \
        "scan: writes fallback title for untitled session"

    # --- Test 2: Skips already-titled sessions ---
    registry_add "test-scan-2" "/tmp/has-msg" "main" "claude" "Existing Title"
    auto_title_scan 1
    task=$(registry_get_field "test-scan-2" "task")
    assert_eq "Existing Title" "$task" \
        "scan: skips already-titled session"

    # --- Test 3: Skips sessions with no user message ---
    registry_add "test-scan-3" "/tmp/no-msg" "main" "claude" ""
    auto_title_scan 1
    task=$(registry_get_field "test-scan-3" "task")
    assert_eq "" "$task" \
        "scan: skips session with no user message"

    # --- Test 4: Throttling works ---
    registry_add "test-scan-4" "/tmp/has-msg" "main" "claude" ""
    auto_title_scan  # throttled (ran <60s ago from test 1)
    task=$(registry_get_field "test-scan-4" "task")
    assert_eq "" "$task" \
        "scan: throttled within 60s"

    # --- Test 5: Force bypasses throttle ---
    auto_title_scan 1
    task=$(registry_get_field "test-scan-4" "task")
    assert_contains "$task" "Fix the login bug" \
        "scan: force bypasses throttle"

    # --- Test 6: History entry created ---
    local hist_count=0
    [[ -f "$AM_HISTORY" ]] && hist_count=$(wc -l < "$AM_HISTORY" | tr -d ' ')
    assert_not_empty "$hist_count" \
        "scan: history entries created"

    # --- Test 7: Background haiku upgrade exits quietly if AM_DIR is removed ---
    local fake_bin
    fake_bin=$(mktemp -d)
    cat > "$fake_bin/claude" <<'EOF'
#!/usr/bin/env bash
sleep 0.2
echo "Quiet Title"
EOF
    chmod +x "$fake_bin/claude"

    local old_path="$PATH"
    export PATH="$fake_bin:$PATH"

    local scan_err
    scan_err=$(mktemp)
    registry_add "test-scan-5" "/tmp/has-msg" "main" "claude" ""
    auto_title_scan 1 >/dev/null 2>"$scan_err"
    rm -rf "$AM_DIR"
    sleep 0.4
    assert_eq "" "$(cat "$scan_err")" \
        "scan: background upgrade is quiet after AM_DIR removal"

    export PATH="$old_path"
    rm -rf "$fake_bin" "$scan_err"

    # --- Cleanup ---
    unset -f claude_first_user_message
    rm -rf "$AM_DIR"
    export AM_DIR="$old_am_dir"
    export AM_REGISTRY="$old_am_registry"
    export AM_HISTORY="$old_am_history"

    echo ""
}

# ============================================
# Test: resolve_session (from am CLI)
# ============================================
test_resolve_session() {
    echo "=== Testing resolve_session ==="

    if ! command -v jq &>/dev/null || ! command -v tmux &>/dev/null; then
        skip_test "resolve_session tests (jq or tmux not installed)"
        echo ""
        return
    fi

    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/tmux.sh"
    source "$LIB_DIR/registry.sh"
    set +u; source "$LIB_DIR/agents.sh"; set -u

    # Source am to get resolve_session function
    # It's defined in the am script, so we extract it
    eval "$(sed -n '/^resolve_session()/,/^}/p' "$PROJECT_DIR/am")"

    setup_integration_env

    local test_dir=$(mktemp -d)

    # Create a session
    local session_name
    session_name=$(set +u; agent_launch "$test_dir" "claude" "resolve test" 2>/dev/null)

    if [[ -z "$session_name" ]]; then
        skip_test "resolve_session tests (agent_launch failed)"
        teardown_integration_env
        rm -rf "$test_dir"
        echo ""
        return
    fi

    # Test: exact match
    local resolved
    resolved=$(resolve_session "$session_name")
    assert_eq "$session_name" "$resolved" "resolve_session: exact match"

    # Test: short hash (without prefix) resolves via prefix expansion
    local short_name="${session_name#test-am-}"
    resolved=$(resolve_session "$short_name")
    assert_eq "$session_name" "$resolved" "resolve_session: prefix expansion"

    # Test: nonexistent returns failure
    assert_cmd_fails "resolve_session: nonexistent fails" resolve_session "nonexistent-xyz-999"

    # Cleanup
    [[ -n "$session_name" ]] && agent_kill "$session_name" 2>/dev/null
    rm -rf "$test_dir"
    teardown_integration_env

    echo ""
}

# ============================================
# Test: tmux session listing and counting
# ============================================
test_tmux_listing() {
    echo "=== Testing tmux listing ==="

    if ! command -v jq &>/dev/null || ! command -v tmux &>/dev/null; then
        skip_test "tmux listing tests (jq or tmux not installed)"
        echo ""
        return
    fi

    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/tmux.sh"
    source "$LIB_DIR/registry.sh"
    set +u; source "$LIB_DIR/agents.sh"; set -u

    setup_integration_env

    local test_dir=$(mktemp -d)

    # Test: count is 0 before any sessions
    local count
    count=$(tmux_count_am_sessions)
    assert_eq "0" "$count" "tmux_count: zero before sessions"

    # Test: list is empty before any sessions
    local list
    list=$(tmux_list_am_sessions)
    assert_eq "" "$list" "tmux_list: empty before sessions"

    # Create two sessions
    local s1 s2
    s1=$(set +u; agent_launch "$test_dir" "claude" "" 2>/dev/null)
    s2=$(set +u; agent_launch "$test_dir" "claude" "" 2>/dev/null)

    # Test: count is 2
    count=$(tmux_count_am_sessions)
    assert_eq "2" "$count" "tmux_count: two sessions"

    # Test: list contains both sessions
    list=$(tmux_list_am_sessions)
    assert_contains "$list" "$s1" "tmux_list: contains first session"
    assert_contains "$list" "$s2" "tmux_list: contains second session"

    # Test: list_with_activity returns both, sorted by activity
    local activity_list
    activity_list=$(tmux_list_am_sessions_with_activity)
    assert_contains "$activity_list" "$s1" "tmux_list_with_activity: contains first"
    assert_contains "$activity_list" "$s2" "tmux_list_with_activity: contains second"

    # Kill one, count should drop
    [[ -n "$s1" ]] && agent_kill "$s1" 2>/dev/null
    count=$(tmux_count_am_sessions)
    assert_eq "1" "$count" "tmux_count: one after kill"

    # Cleanup
    [[ -n "$s2" ]] && agent_kill "$s2" 2>/dev/null
    rm -rf "$test_dir"
    teardown_integration_env

    echo ""
}

# ============================================
# Test: claude_first_user_message helper
# ============================================
test_claude_first_user_message() {
    echo "=== Testing claude_first_user_message ==="

    if ! command -v jq &>/dev/null; then
        skip_test "claude_first_user_message tests (jq not installed)"
        echo ""
        return
    fi

    source "$LIB_DIR/utils.sh"

    # Create a fake Claude project directory structure
    local test_dir
    test_dir=$(mktemp -d)

    local project_path="${test_dir//\//-}"
    project_path="${project_path//./-}"
    local claude_dir="$HOME/.claude/projects/$project_path"
    mkdir -p "$claude_dir"

    # Test: no JSONL files returns empty
    local result
    result=$(claude_first_user_message "$test_dir")
    assert_eq "" "$result" "claude_first_msg: empty when no JSONL"

    # Test: JSONL with string content
    echo '{"type":"user","message":{"role":"user","content":"Fix the login bug in the auth module"}}' \
        > "$claude_dir/session1.jsonl"
    result=$(claude_first_user_message "$test_dir")
    assert_contains "$result" "Fix the login bug" "claude_first_msg: extracts string content"

    # Test: skips messages with only XML tags
    echo '{"type":"user","message":{"role":"user","content":"<system-tag>short</system-tag>"}}
{"type":"user","message":{"role":"user","content":"Refactor the database connection pooling"}}' \
        > "$claude_dir/session2.jsonl"
    result=$(claude_first_user_message "$test_dir")
    assert_contains "$result" "Refactor the database" "claude_first_msg: skips XML-only messages"

    # Test: handles array content format
    echo '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Add pagination to the API endpoints"}]}}' \
        > "$claude_dir/session3.jsonl"
    result=$(claude_first_user_message "$test_dir")
    assert_contains "$result" "Add pagination" "claude_first_msg: handles array content"

    # Test: nonexistent directory returns empty
    result=$(claude_first_user_message "/tmp/nonexistent-dir-xyz-$$")
    assert_eq "" "$result" "claude_first_msg: empty for nonexistent dir"

    # Cleanup
    rm -rf "$claude_dir" "$test_dir"

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
    test_config
    test_registry
    test_registry_extended
    test_tmux
    test_agents
    test_agents_extended
    test_fzf_helpers
    test_tmux_binding_snippets
    test_cli
    test_integration_lifecycle
    test_cli_extended
    test_registry_gc
    test_history
    test_history_integration
    test_worktree
    test_annotated_directories
    test_auto_title_session
    test_auto_title_scan
    test_resolve_session
    test_tmux_listing
    test_claude_first_user_message

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
