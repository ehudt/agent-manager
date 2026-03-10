#!/usr/bin/env bash
# tests/test_config.sh - Tests for lib/config.sh

test_config() {
    $SUMMARY_MODE || echo "=== Testing config.sh ==="

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
    assert_eq "true" "$(am_stream_logs_enabled && echo true || echo false)" "config: default logs fallback"

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

    rm -rf "$AM_DIR"
    export AM_DIR="${original_am_dir:-$HOME/.agent-manager}"
    export AM_CONFIG="$original_am_config"
    export AM_DEFAULT_AGENT="$original_default_agent"
    export AM_DEFAULT_YOLO="$original_default_yolo"
    export AM_STREAM_LOGS="$original_stream_logs"

    $SUMMARY_MODE || echo ""
}

test_new_form_flag() {
    $SUMMARY_MODE || echo "=== Testing new_form feature flag ==="

    source "$LIB_DIR/utils.sh"
    set +u
    source "$LIB_DIR/config.sh"
    set -u

    # Isolate from user's real config
    local original_am_dir="${AM_DIR:-}"
    local original_am_config="${AM_CONFIG:-}"
    local original_new_form="${AM_NEW_FORM:-}"
    export AM_DIR=$(mktemp -d)
    export AM_CONFIG="$AM_DIR/config.json"
    unset AM_NEW_FORM
    am_config_init

    # Default is false
    local result=""
    am_new_form_enabled && result="true" || result="false"
    assert_eq "false" "$result" "new_form: default is false"

    # Env override works
    result=""
    AM_NEW_FORM=true am_new_form_enabled && result="true" || result="false"
    assert_eq "true" "$result" "new_form: env override works"

    # Config key alias resolves
    local key
    key=$(am_config_key_alias "new-form")
    assert_eq "new_form" "$key" "new_form: key alias resolves"

    # Validation accepts boolean
    am_config_value_is_valid "new_form" "true" && result="true" || result="false"
    assert_eq "true" "$result" "new_form: validation accepts boolean"

    # Type is boolean
    local ktype
    ktype=$(am_config_key_type "new_form")
    assert_eq "boolean" "$ktype" "new_form: type is boolean"

    # am_new_session_form dispatch function exists (from Task 4)
    set +u
    source "$LIB_DIR/tmux.sh"
    source "$LIB_DIR/registry.sh"
    source "$LIB_DIR/agents.sh"
    source "$LIB_DIR/fzf.sh"
    source "$LIB_DIR/form.sh"
    set -u

    local fn_type
    fn_type="$(type -t am_new_session_form 2>/dev/null || true)"
    assert_eq "function" "$fn_type" "new_form: am_new_session_form function exists"

    # Cleanup
    rm -rf "$AM_DIR"
    export AM_DIR="${original_am_dir:-$HOME/.agent-manager}"
    export AM_CONFIG="$original_am_config"
    [[ -n "$original_new_form" ]] && export AM_NEW_FORM="$original_new_form" || unset AM_NEW_FORM

    $SUMMARY_MODE || echo ""
}

run_config_tests() {
    _run_test test_config
    _run_test test_new_form_flag
}

if [[ -z "${_AM_TEST_RUNNER:-}" ]]; then
    set -uo pipefail
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helpers.sh"
    check_deps
    run_config_tests
    test_report
fi
