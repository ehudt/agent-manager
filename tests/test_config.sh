#!/usr/bin/env bash
# tests/test_config.sh - Tests for lib/config.sh

test_config() {
    $SUMMARY_MODE || echo "=== Testing config.sh ==="

    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/config.sh"

    local original_default_agent="${AM_DEFAULT_AGENT:-}"
    local original_default_yolo="${AM_DEFAULT_YOLO:-}"
    local original_stream_logs="${AM_STREAM_LOGS:-}"

    setup_isolated_am_dir

    am_config_init
    assert_eq "true" "$(test -f "$AM_CONFIG" && echo true || echo false)" "config: creates config file"
    assert_eq "claude" "$(am_default_agent)" "config: default agent fallback"
    assert_eq "false" "$(am_default_yolo_enabled && echo true || echo false)" "config: default yolo fallback"
    assert_eq "true" "$(am_stream_logs_enabled && echo true || echo false)" "config: default logs fallback"

    am_config_set "default_agent" "codex" "string"
    am_config_set "default_yolo" "true" "boolean"
    am_config_set "stream_logs" "yes" "boolean"

    assert_eq "codex" "$(am_default_agent)" "config: saved default agent"
    assert_eq "true" "$(am_default_yolo_enabled && echo true || echo false)" "config: saved default yolo"
    assert_eq "true" "$(am_stream_logs_enabled && echo true || echo false)" "config: saved stream logs"
    assert_eq "true" "$(am_maybe_apply_default_yolo --resume && echo true || echo false)" "config: applies default yolo when missing"
    assert_eq "false" "$(am_maybe_apply_default_yolo --yolo && echo true || echo false)" "config: does not duplicate yolo flag"

    export AM_DEFAULT_AGENT="claude"
    export AM_DEFAULT_YOLO="false"
    export AM_STREAM_LOGS="0"
    assert_eq "claude" "$(am_default_agent)" "config: env overrides saved agent"
    assert_eq "false" "$(am_default_yolo_enabled && echo true || echo false)" "config: env overrides saved yolo"
    assert_eq "false" "$(am_stream_logs_enabled && echo true || echo false)" "config: env overrides saved logs"

    # Sandbox config
    assert_eq "false" "$(am_default_sandbox_enabled && echo true || echo false)" "config: default sandbox fallback"

    am_config_set "default_sandbox" "true" "boolean"
    assert_eq "true" "$(am_default_sandbox_enabled && echo true || echo false)" "config: saved default sandbox"

    export AM_DEFAULT_SANDBOX="false"
    assert_eq "false" "$(am_default_sandbox_enabled && echo true || echo false)" "config: env overrides saved sandbox"
    unset AM_DEFAULT_SANDBOX

    am_config_unset "default_agent"
    unset AM_DEFAULT_AGENT AM_DEFAULT_YOLO AM_STREAM_LOGS
    assert_eq "claude" "$(am_default_agent)" "config: unset falls back to built-in default"

    teardown_isolated_am_dir
    export AM_DEFAULT_AGENT="$original_default_agent"
    export AM_DEFAULT_YOLO="$original_default_yolo"
    export AM_STREAM_LOGS="$original_stream_logs"

    $SUMMARY_MODE || echo ""
}

run_config_tests() {
    _run_test test_config
}

if [[ -z "${_AM_TEST_RUNNER:-}" ]]; then
    set -uo pipefail
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helpers.sh"
    check_deps
    run_config_tests
    test_report
fi
