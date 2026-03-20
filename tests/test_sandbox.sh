#!/usr/bin/env bash
# tests/test_sandbox.sh - Tests for lib/sandbox.sh and lib/sb_volume.sh

test_sandbox() {
    $SUMMARY_MODE || echo "=== Testing sandbox helpers ==="

    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/config.sh"

    export AM_SCRIPT_DIR="$PROJECT_DIR"
    export SB_STATE_VOLUME="am-test-state-$$"
    source "$LIB_DIR/sb_volume.sh"
    source "$LIB_DIR/sandbox.sh"

    local cmd
    cmd=$(sandbox_enter_cmd "am-abc123" "/home/user/project")
    assert_contains "$cmd" "sandbox-shell" "sandbox_enter_cmd: invokes sandbox-shell script"
    assert_contains "$cmd" "am-abc123" "sandbox_enter_cmd: contains session name"

    # shellcheck disable=SC2088 # Tildes in quotes are intentional — testing tilde expansion
    assert_eq "$HOME/demo" "$(sb_expand_path "~/demo")" "sb_expand_path: expands tilde"
    # shellcheck disable=SC2088
    assert_eq "ssh" "$(_sb_name_from_target "~/.ssh")" "_sb_name_from_target: strips leading dot"
    # shellcheck disable=SC2088
    assert_eq "claude.json" "$(_sb_name_from_target "~/.claude.json")" "_sb_name_from_target: preserves basename"
    # shellcheck disable=SC2088
    assert_eq "$HOME/.vimrc|$HOME/.vimrc|ro" "$(_sb_share_spec_parse "~/.vimrc:ro")" "share parse: host+mode"
    # shellcheck disable=SC2088
    assert_eq "$HOME/.ssh|$HOME/.ssh|rw" "$(_sb_share_spec_parse "~/.ssh:~/.ssh:rw")" "share parse: explicit target+mode"

    sb_vol_ensure
    assert_cmd_succeeds "sb_vol_ensure: creates mappings.json" sb_vol_exists mappings.json
    assert_cmd_succeeds "sb_vol_ensure: creates data dir" sb_vol_exists data

    docker volume rm -f "$SB_STATE_VOLUME" >/dev/null 2>&1 || true

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
