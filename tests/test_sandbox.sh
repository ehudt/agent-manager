#!/usr/bin/env bash
# tests/test_sandbox.sh - Tests for lib/sandbox.sh

test_sandbox() {
    $SUMMARY_MODE || echo "=== Testing sandbox.sh ==="

    source "$LIB_DIR/utils.sh"

    # Set AM_SCRIPT_DIR so sandbox.sh can compute SANDBOX_DIR
    export AM_SCRIPT_DIR="$PROJECT_DIR"
    source "$LIB_DIR/sandbox.sh"

    # --- Test 1: sandbox_attach_cmd output format ---
    local cmd
    cmd=$(sandbox_attach_cmd "am-abc123" "/home/user/project")
    assert_contains "$cmd" "docker exec" "sandbox_attach_cmd: contains docker exec"
    assert_contains "$cmd" "am-abc123" "sandbox_attach_cmd: contains session name"
    assert_contains "$cmd" "/home/user/project" "sandbox_attach_cmd: contains directory"
    assert_contains "$cmd" "docker inspect" "sandbox_attach_cmd: checks container state after exit"
    assert_contains "$cmd" "reconnecting..." "sandbox_attach_cmd: auto-reconnects after shell exit"
    assert_contains "$cmd" "exit 42" "sandbox_attach_cmd: documents explicit host-shell escape"
    assert_contains "$cmd" "./am sandbox enter am-abc123" "sandbox_attach_cmd: prints re-entry command"
    assert_contains "$cmd" "is gone; you are now on the host shell" "sandbox_attach_cmd: prints host-shell fallback message"
    assert_contains "$cmd" "$AM_DIR/logs/am-abc123/sandbox.log" "sandbox_attach_cmd: references session sandbox event log"

    # --- Test 1b: sandbox_enter_cmd output format ---
    cmd=$(sandbox_enter_cmd "am-abc123" "/home/user/project")
    assert_contains "$cmd" "docker exec" "sandbox_enter_cmd: contains docker exec"
    assert_contains "$cmd" "./am sandbox enter am-abc123" "sandbox_enter_cmd: contains am re-entry command"
    assert_contains "$cmd" "reconnecting..." "sandbox_enter_cmd: contains auto-reconnect message"
    assert_contains "$cmd" "exit 42" "sandbox_enter_cmd: contains explicit host-shell escape"

    # --- Test 1c: sandbox_enter_cmd defaults to ~/workspace ---
    cmd=$(sandbox_enter_cmd "am-abc123")
    assert_contains "$cmd" "workspace" "sandbox_enter_cmd: defaults working dir to workspace"

    # --- Test 2: SB_HOME is set correctly ---
    assert_contains "$SB_HOME" ".sb" "SB_HOME: contains '.sb'"

    # --- Test 3: SANDBOX_DIR is set correctly ---
    assert_contains "$SANDBOX_DIR" "sandbox" "SANDBOX_DIR: contains 'sandbox'"
    assert_cmd_succeeds "SANDBOX_DIR: directory exists" test -d "$SANDBOX_DIR"

    $SUMMARY_MODE || echo ""
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
    _run_test test_sandbox_pytest_integration_group ux "ux and not functional and not security"
}

if [[ -z "${_AM_TEST_RUNNER:-}" ]]; then
    set -uo pipefail
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helpers.sh"
    check_deps
    run_sandbox_tests
    [[ "${AM_TEST_SLOW:-}" == "1" ]] && run_sandbox_slow_tests
    test_report
fi
