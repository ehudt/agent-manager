#!/usr/bin/env bash
# tests/test_config.sh - Tests for lib/config.sh

test_config() {
    $SUMMARY_MODE || echo "=== Testing config.sh ==="

    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/config.sh"

    local original_default_agent="${AM_DEFAULT_AGENT:-}"
    local original_stream_logs="${AM_STREAM_LOGS:-}"

    setup_isolated_am_dir

    am_config_init
    assert_eq "true" "$(test -f "$AM_CONFIG" && echo true || echo false)" "config: creates config file"
    assert_eq "claude" "$(am_default_agent)" "config: default agent fallback"
    assert_eq "true" "$(am_stream_logs_enabled && echo true || echo false)" "config: default logs fallback"
    assert_eq "default_agent auto_restore stream_logs shell_pane" \
        "$(jq -r 'keys_unsorted | join(" ")' "$AM_CONFIG")" \
        "config: fresh config has no yolo/sandbox keys"
    assert_eq "true" "$(am_auto_restore_enabled && echo true || echo false)" \
        "config: reboot recovery defaults on"

    am_config_set "default_agent" "codex" "string"
    am_config_set "stream_logs" "yes" "boolean"
    am_config_set "auto_restore" "false" "boolean"

    assert_eq "codex" "$(am_default_agent)" "config: saved default agent"
    am_config_set "default_agent" "cursor-agent" "string"
    assert_eq "cursor" "$(am_default_agent)" "config: Cursor alias is canonicalized"
    am_config_set "default_agent" "codex" "string"
    assert_eq "true" "$(am_stream_logs_enabled && echo true || echo false)" "config: saved stream logs"
    assert_eq "false" "$(am_auto_restore_enabled && echo true || echo false)" \
        "config: saved reboot recovery setting"

    export AM_DEFAULT_AGENT="claude"
    export AM_STREAM_LOGS="0"
    assert_eq "claude" "$(am_default_agent)" "config: env overrides saved agent"
    assert_eq "false" "$(am_stream_logs_enabled && echo true || echo false)" "config: env overrides saved logs"

    # Keys left behind by pre-0.18 releases are pruned on init; the rest survive
    jq '. + {default_yolo: true, default_sandbox: false, "sandbox.shares": "~/.ssh:ro", new_form: true}' \
        "$AM_CONFIG" > "$AM_CONFIG.tmp" && mv "$AM_CONFIG.tmp" "$AM_CONFIG"
    am_config_init
    assert_eq "false" "$(jq 'has("default_yolo") or has("default_sandbox") or has("sandbox.shares")' "$AM_CONFIG")" \
        "config: init prunes yolo/sandbox keys"
    assert_eq "codex" "$(jq -r '.default_agent' "$AM_CONFIG")" "config: prune keeps live keys"
    assert_eq "true" "$(jq -r '.new_form' "$AM_CONFIG")" "config: prune leaves unrelated keys alone"

    # Removed keys are no longer recognized
    assert_cmd_fails "config: yolo is not a config key" am_config_key_alias yolo
    assert_cmd_fails "config: sandbox is not a config key" am_config_key_alias sandbox
    assert_cmd_fails "config: sandbox-shares is not a config key" am_config_key_alias sandbox-shares
    assert_not_contains "$(am_config_print)" "yolo" "config: print omits yolo"
    assert_not_contains "$(am_config_print)" "sandbox" "config: print omits sandbox"

    # Shell panel config
    assert_eq "false" "$(am_shell_pane_enabled && echo true || echo false)" "config: shell panel defaults closed"
    assert_eq "shell_pane" "$(am_config_key_alias shell)" "config: shell alias maps to shell_pane"
    assert_eq "boolean" "$(am_config_key_type shell_pane)" "config: shell_pane is boolean"

    am_config_set "shell_pane" "true" "boolean"
    assert_eq "true" "$(am_shell_pane_enabled && echo true || echo false)" "config: saved shell panel default"
    assert_contains "$(am_config_print)" "shell_pane=true" "config: print shows shell_pane"

    export AM_SHELL_PANE="false"
    assert_eq "false" "$(am_shell_pane_enabled && echo true || echo false)" "config: env overrides saved shell panel"
    unset AM_SHELL_PANE
    am_config_set "shell_pane" "false" "boolean"

    # Workspace command (am new -W)
    unset AM_WORKSPACE_CMD
    assert_eq "" "$(am_workspace_cmd)" "config: workspace_cmd defaults empty"
    assert_eq "workspace_cmd" "$(am_config_key_alias workspace)" "config: workspace alias maps to workspace_cmd"
    assert_eq "string" "$(am_config_key_type workspace_cmd)" "config: workspace_cmd is a string"
    assert_eq "true" "$(am_config_value_is_valid workspace_cmd 'wp allocate ${AM_BRANCH:+--branch "$AM_BRANCH"}' && echo true || echo false)" \
        "config: workspace_cmd accepts a shell snippet"
    am_config_set "workspace_cmd" 'wp allocate ${AM_BRANCH:+--branch "$AM_BRANCH"}' "string"
    assert_eq 'wp allocate ${AM_BRANCH:+--branch "$AM_BRANCH"}' "$(am_workspace_cmd)" \
        "config: saved workspace_cmd keeps its case and quoting"
    assert_contains "$(am_config_print)" 'workspace_cmd=wp allocate ${AM_BRANCH:+--branch "$AM_BRANCH"}' \
        "config: print shows workspace_cmd"
    export AM_WORKSPACE_CMD="echo /tmp"
    assert_eq "echo /tmp" "$(am_workspace_cmd)" "config: env overrides saved workspace_cmd"
    unset AM_WORKSPACE_CMD
    am_config_unset "workspace_cmd"
    assert_eq "" "$(am_workspace_cmd)" "config: unset workspace_cmd is empty again"

    am_config_unset "default_agent"
    unset AM_DEFAULT_AGENT AM_STREAM_LOGS
    assert_eq "claude" "$(am_default_agent)" "config: unset falls back to built-in default"

    teardown_isolated_am_dir
    export AM_DEFAULT_AGENT="$original_default_agent"
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
