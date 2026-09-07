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
    assert_eq "default_agent auto_restore stream_logs shell_pane notify notify_states" \
        "$(jq -r 'keys_unsorted | join(" ")' "$AM_CONFIG")" \
        "config: fresh config has no yolo/sandbox keys"
    assert_eq "true" "$(am_auto_restore_enabled && echo true || echo false)" \
        "config: reboot recovery defaults on"

    # Notifications: on by default, waiting_user only; keys validate
    assert_eq "true" "$(am_notify_enabled && echo true || echo false)" "config: notify defaults on"
    assert_eq "waiting_user" "$(am_notify_states)" "config: notify_states defaults to waiting_user"
    assert_eq "notify" "$(am_config_key_alias notifications)" "config: notifications alias"
    assert_eq "boolean" "$(am_config_key_type notify)" "config: notify is boolean"
    assert_eq "string" "$(am_config_key_type notify_cmd)" "config: notify_cmd is a string"
    assert_cmd_succeeds "config: notify_states accepts a state list" \
        am_config_value_is_valid notify_states "waiting_user,ready"
    assert_cmd_fails "config: notify_states rejects an unknown state" \
        am_config_value_is_valid notify_states "waiting_user,bogus"
    am_config_set "notify" "false" "boolean"
    assert_eq "false" "$(am_notify_enabled && echo true || echo false)" "config: saved notify=false"
    jq 'del(.notify)' "$AM_CONFIG" > "$AM_CONFIG.tmp" && mv "$AM_CONFIG.tmp" "$AM_CONFIG"
    assert_eq "true" "$(am_notify_enabled && echo true || echo false)" "config: missing notify key means on"
    AM_NOTIFY=0 assert_eq "false" "$(AM_NOTIFY=0 am_notify_enabled && echo true || echo false)" \
        "config: AM_NOTIFY env overrides"
    am_config_set "notify_states" "waiting_user,ready" "string"
    assert_eq "waiting_user,ready" "$(am_notify_states)" "config: saved notify_states"
    assert_contains "$(am_config_print)" "notify_states=waiting_user,ready" "config: print shows notify_states"
    am_config_unset "notify_states"

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

    # Directory provider (am new @spec)
    unset AM_DIR_PROVIDER
    assert_eq "" "$(am_dir_provider)" "config: dir_provider defaults empty"
    assert_eq "dir_provider" "$(am_config_key_alias provider)" "config: provider alias maps to dir_provider"
    assert_eq "dir_provider" "$(am_config_key_alias dir-provider)" "config: dir-provider alias maps to dir_provider"
    assert_eq "string" "$(am_config_key_type dir_provider)" "config: dir_provider is a string"
    assert_eq "true" "$(am_config_value_is_valid dir_provider 'MyTool --Flag' && echo true || echo false)" \
        "config: dir_provider accepts a command prefix"
    am_config_set "dir_provider" 'MyTool --Flag' "string"
    assert_eq 'MyTool --Flag' "$(am_dir_provider)" "config: saved dir_provider keeps its case"
    assert_contains "$(am_config_print)" 'dir_provider=MyTool --Flag' "config: print shows dir_provider"
    export AM_DIR_PROVIDER="wp"
    assert_eq "wp" "$(am_dir_provider)" "config: env overrides saved dir_provider"
    unset AM_DIR_PROVIDER
    am_config_unset "dir_provider"
    assert_eq "" "$(am_dir_provider)" "config: unset dir_provider is empty again"
    assert_eq "true" "$(am_dir_is_spec '@48351' && echo true || echo false)" "config: @48351 is a spec"
    assert_eq "true" "$(am_dir_is_spec '@' && echo true || echo false)" "config: bare @ is a spec"
    assert_eq "false" "$(am_dir_is_spec '/tmp' && echo true || echo false)" "config: a path is not a spec"
    assert_eq "0.3" "$(am_dir_suggest_timeout)" "config: suggest timeout defaults to 0.3s"
    assert_eq "1" "$(AM_DIR_SUGGEST_TIMEOUT=1 am_dir_suggest_timeout)" "config: env overrides suggest timeout"

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
