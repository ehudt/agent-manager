#!/usr/bin/env bash
# tests/test_presets.sh - Tests for lib/presets.sh and the form's Preset field

test_presets() {
    $SUMMARY_MODE || echo "=== Testing presets.sh ==="

    source "$LIB_DIR/utils.sh"
    set +u
    source "$LIB_DIR/config.sh"
    source "$LIB_DIR/tmux.sh"
    source "$LIB_DIR/registry.sh"
    source "$LIB_DIR/agents.sh"
    source "$LIB_DIR/presets.sh"
    source "$LIB_DIR/form.sh"
    set -u
    unset AM_WORKSPACE_CMD
    setup_isolated_am_dir
    am_config_init

    # Empty state
    assert_eq "" "$(am_preset_names)" "presets: none by default"
    assert_eq "false" "$(am_preset_get nope >/dev/null 2>&1 && echo true || echo false)" \
        "presets: get of a missing preset fails"

    # Save from flags, including agent args after --
    local out
    out=$(preset_main save review -t claude -W -- --model opus --effort high 2>&1)
    assert_contains "$out" "Saved preset review" "presets: save reports"
    assert_eq "review" "$(am_preset_names)" "presets: name listed after save"
    assert_eq "claude" "$(am_preset_field review agent)" "presets: agent field"
    assert_eq "true" "$(am_preset_field review workspace)" "presets: workspace flag"
    assert_eq "" "$(am_preset_field review branch)" "presets: empty branch omitted"
    assert_eq "--model
opus
--effort
high" "$(am_preset_field review args)" "presets: args preserved in order"
    assert_eq "false" "$(am_preset_field review shell)" "presets: shell defaults false"

    # Other config keys are untouched
    assert_eq "claude" "$(am_default_agent)" "presets: config keys survive preset writes"

    # Second preset with directory + task + shell; ~ expands
    preset_main save scratch -t pi -n "poke around" --shell "~/tools" >/dev/null 2>&1
    assert_eq "review
scratch" "$(am_preset_names)" "presets: names sorted"
    assert_eq "$HOME/tools" "$(am_preset_field scratch directory)" "presets: tilde expanded"
    assert_eq "poke around" "$(am_preset_field scratch task)" "presets: task stored"
    assert_eq "true" "$(am_preset_field scratch shell)" "presets: shell stored"

    # list renders an equivalent am new line
    out=$(preset_main list)
    assert_contains "$out" "review" "presets: list shows names"
    assert_contains "$out" "-W" "presets: list renders workspace flag"
    assert_contains "$out" "-- --model opus --effort high" "presets: list renders agent args"
    assert_contains "$out" "'poke around'" "presets: list quotes task with spaces"

    # Validation
    assert_eq "false" "$(preset_main save 'bad name' -t claude >/dev/null 2>&1 && echo true || echo false)" \
        "presets: rejects names with spaces"
    assert_eq "false" "$(preset_main save x -t nosuchagent >/dev/null 2>&1 && echo true || echo false)" \
        "presets: rejects unknown agent type"
    assert_eq "" "$(am_preset_get x 2>/dev/null)" "presets: failed save leaves nothing behind"

    # Form: Preset field appears first and fills fields when picked
    _form_init "/tmp/project" "claude" ""
    assert_eq "preset directory agent task" "${FORM_FIELDS[*]}" "presets: form gains a Preset field when presets exist"
    assert_eq "-,review,scratch" "${FORM_OPTIONS[preset]}" "presets: form options are - plus names"
    FORM_CURSOR=0
    _form_handle_space   # -> review
    assert_eq "review" "${FORM_VALUES[preset]}" "presets: space cycles to first preset"
    assert_eq "claude" "${FORM_VALUES[agent]}" "presets: review keeps agent"
    _form_handle_space   # -> scratch
    assert_eq "pi" "${FORM_VALUES[agent]}" "presets: picking scratch sets agent"
    assert_eq "$HOME/tools" "${FORM_VALUES[directory]}" "presets: picking scratch sets directory"
    assert_eq "poke around" "${FORM_VALUES[task]}" "presets: picking scratch sets task"
    mkdir -p "$HOME/tools" 2>/dev/null || true
    local form_out flags
    form_out=$(_form_output 2>/dev/null) || form_out=""
    flags="${form_out##*$'\x1f'}"
    assert_contains "$flags" "--preset=scratch" "presets: form output carries --preset for cmd_new"

    # Remove
    assert_eq "true" "$(preset_main rm review >/dev/null 2>&1 && echo true || echo false)" "presets: rm succeeds"
    assert_eq "scratch" "$(am_preset_names)" "presets: rm removes only its name"
    assert_eq "false" "$(preset_main rm review >/dev/null 2>&1 && echo true || echo false)" "presets: rm of missing fails"
    preset_main rm scratch >/dev/null 2>&1
    assert_eq "false" "$(jq 'has("presets")' "$AM_CONFIG")" "presets: empty presets key is dropped"

    # Without presets the form is unchanged
    _form_init "/tmp/project" "claude" ""
    assert_eq "directory agent task" "${FORM_FIELDS[*]}" "presets: form has no Preset field without presets"
}

run_presets_tests() {
    _run_test test_presets
}

if [[ -z "${_AM_TEST_RUNNER:-}" ]]; then
    set -uo pipefail
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helpers.sh"
    check_deps
    run_presets_tests
    test_report
fi
