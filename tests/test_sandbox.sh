#!/usr/bin/env bash
# tests/test_sandbox.sh - Tests for lib/sandbox.sh

test_sandbox() {
    $SUMMARY_MODE || echo "=== Testing sandbox helpers ==="

    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/config.sh"

    export AM_SCRIPT_DIR="$PROJECT_DIR"
    export SB_HOME_DIR="${TMPDIR:-/tmp}/sb-home-$$"
    source "$LIB_DIR/sandbox.sh"

    local cmd
    cmd=$(sandbox_enter_cmd "am-abc123" "/home/user/project")
    assert_contains "$cmd" "sandbox-shell" "sandbox_enter_cmd: invokes sandbox-shell script"
    assert_contains "$cmd" "am-abc123" "sandbox_enter_cmd: contains session name"

    # --- sandbox_exec_cmd exports AM_SESSION_NAME ---
    local exec_cmd
    exec_cmd=$(sandbox_exec_cmd "am-sbtest" "/tmp" "echo hi" "pi")
    assert_contains "$exec_cmd" "AM_SESSION_NAME=am-sbtest" "sandbox_exec_cmd: AM_SESSION_NAME exported"
    assert_contains "$exec_cmd" "AM_IDENTITY_DIR=/tmp/am-identities" \
        "sandbox_exec_cmd: durable identity channel exported"
    assert_contains "$exec_cmd" "AM_AGENT_TYPE=pi" \
        "sandbox_exec_cmd: registered agent family exported"

    # shellcheck disable=SC2088 # Tildes in quotes are intentional — testing tilde expansion
    assert_eq "$HOME/demo" "$(sb_expand_path "~/demo")" "sb_expand_path: expands tilde"
    # shellcheck disable=SC2088
    assert_eq "$HOME/.vimrc|$HOME/.vimrc|ro" "$(_sb_share_spec_parse "~/.vimrc:ro")" "share parse: host+mode"
    # shellcheck disable=SC2088
    assert_eq "$HOME/.ssh|$SB_CONTAINER_HOME/.ssh|rw" "$(_sb_share_spec_parse "~/.ssh:~/.ssh:rw")" "share parse: explicit target+mode"

    local saved_config_get exact_shares
    saved_config_get=$(declare -f am_config_get)
    am_config_get() { echo "$HOME:/configured:ro"; }
    exact_shares=$(AM_SANDBOX_SHARES_EXACT=1 _sb_collect_share_specs "/tmp:/explicit:rw")
    assert_contains "$exact_shares" "/tmp|/explicit|rw" \
        "sandbox recovery: exact stored share is replayed"
    assert_not_contains "$exact_shares" "/configured" \
        "sandbox recovery: changed config shares are not merged"
    eval "$saved_config_get"

    _sb_home_ensure
    assert_cmd_succeeds "_sb_home_ensure: creates home dir" test -d "$SB_HOME_DIR"

    # Cursor setup is seeded into the persistent sandbox home without
    # replacing unrelated hooks/config.
    mkdir -p "$SB_HOME_DIR/.cursor"
    printf '%s\n' '{"version":1,"hooks":{"stop":[{"command":"echo user-hook"}]}}' \
        > "$SB_HOME_DIR/.cursor/hooks.json"
    _sandbox_seed_cursor_hooks
    assert_cmd_succeeds "sandbox Cursor hooks: helper copied" \
        test -x "$SB_HOME_DIR/.cursor/hooks/am-state-hook.sh"
    assert_eq "2" "$(jq '.hooks.stop | length' "$SB_HOME_DIR/.cursor/hooks.json")" \
        "sandbox Cursor hooks: unrelated stop hook preserved"
    assert_eq "8" "$(jq '[.hooks[][] | select((.command // "") | contains("# am-state-hook"))] | length' "$SB_HOME_DIR/.cursor/hooks.json")" \
        "sandbox Cursor hooks: lifecycle hooks installed"
    _sandbox_seed_skills
    assert_cmd_succeeds "sandbox skills: Cursor dispatch skill seeded" \
        test -f "$SB_HOME_DIR/.cursor/skills/agent-manager-dispatch/SKILL.md"
    assert_cmd_succeeds "sandbox skills: Claude dispatch skill seeded" \
        test -f "$SB_HOME_DIR/.claude/skills/agent-manager-dispatch/SKILL.md"

    assert_contains "$(cat "$PROJECT_DIR/sandbox/Dockerfile")" "https://cursor.com/install" \
        "sandbox image: installs official Cursor Agent"
    assert_contains "$(cat "$PROJECT_DIR/sandbox/tinyproxy-filter.txt")" "cursor\\.sh" \
        "sandbox proxy: allows Cursor API domains"
    assert_contains "$(cat "$LIB_DIR/sandbox.sh")" "CURSOR_API_KEY" \
        "sandbox launch: forwards CURSOR_API_KEY"

    rm -rf "$SB_HOME_DIR"

    $SUMMARY_MODE || echo ""
}

run_sandbox_tests() {
    _run_test test_sandbox
}

run_sandbox_slow_tests() {
    _run_test test_sandbox_pytest_integration
}

run_sandbox_slow_security_tests() {
    _run_test test_sandbox_pytest_integration_group security "security"
}

run_sandbox_slow_functional_tests() {
    _run_test test_sandbox_pytest_integration_group functional "functional"
}

run_sandbox_slow_ux_tests() {
    _run_test test_sandbox_pytest_integration_group ux "ux"
}

test_sandbox_pytest_integration() {
    $SUMMARY_MODE || echo "=== Testing sandbox pytest integration suite ==="

    if ! command -v docker &>/dev/null || ! docker info >/dev/null 2>&1; then
        skip_test "sandbox pytest integration (docker unavailable)"
        echo ""
        return
    fi

    if command -v uv &>/dev/null; then
        run_external_test \
            "sandbox pytest integration: tests/test_sandbox_security_integration.py" \
            uv run --with pytest pytest -q "$TEST_DIR/test_sandbox_security_integration.py"
        echo ""
        return
    fi

    if python3 -c 'import pytest' &>/dev/null; then
        run_external_test \
            "sandbox pytest integration: tests/test_sandbox_security_integration.py" \
            python3 -m pytest -q "$TEST_DIR/test_sandbox_security_integration.py"
    else
        skip_test "sandbox pytest integration (requires uv or python3 with pytest)"
    fi

    $SUMMARY_MODE || echo ""
}

test_sandbox_pytest_integration_group() {
    local group_name="$1"
    local marker_expr="$2"

    if ! command -v docker &>/dev/null || ! docker info >/dev/null 2>&1; then
        skip_test "sandbox pytest integration ($group_name, docker unavailable)"
        return
    fi

    if command -v uv &>/dev/null; then
        run_external_test \
            "sandbox pytest integration [$group_name]: tests/test_sandbox_security_integration.py" \
            uv run --with pytest pytest -q -m "$marker_expr" "$TEST_DIR/test_sandbox_security_integration.py"
        return
    fi

    if python3 -c 'import pytest' &>/dev/null; then
        run_external_test \
            "sandbox pytest integration [$group_name]: tests/test_sandbox_security_integration.py" \
            python3 -m pytest -q -m "$marker_expr" "$TEST_DIR/test_sandbox_security_integration.py"
    else
        skip_test "sandbox pytest integration [$group_name] (requires uv or python3 with pytest)"
    fi
}

if [[ -z "${_AM_TEST_RUNNER:-}" ]]; then
    set -uo pipefail
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helpers.sh"
    check_deps
    run_sandbox_tests
    [[ "${AM_TEST_SLOW:-}" == "1" ]] && run_sandbox_slow_tests
    test_report
fi
