#!/usr/bin/env bash
# tests/test_presets.sh - Tests for lib/presets.sh (the form's Preset field
# is covered by cmd/am-browse/newform_test.go)

test_presets() {
    $SUMMARY_MODE || echo "=== Testing presets.sh ==="

    source "$LIB_DIR/utils.sh"
    set +u
    source "$LIB_DIR/config.sh"
    source "$LIB_DIR/tmux.sh"
    source "$LIB_DIR/registry.sh"
    source "$LIB_DIR/agents.sh"
    source "$LIB_DIR/presets.sh"
    set -u
    unset AM_DIR_PROVIDER
    setup_isolated_am_dir
    am_config_init

    # Empty state
    assert_eq "" "$(am_preset_names)" "presets: none by default"
    assert_eq "false" "$(am_preset_get nope >/dev/null 2>&1 && echo true || echo false)" \
        "presets: get of a missing preset fails"

    # Save from flags, including agent args after --
    local out
    out=$(preset_main save review -t claude @ -- --model opus --effort high 2>&1)
    assert_eq "review" "$(am_preset_names)" "presets: name listed after save"
    assert_eq "claude" "$(am_preset_field review agent)" "presets: agent field"
    assert_eq "@" "$(am_preset_field review directory)" "presets: a @spec is stored as the directory"
    # Keep: the only check that the -- sentinel stays out of the stored args.
    assert_eq "--model
opus
--effort
high" "$(am_preset_field review args)" "presets: args preserved in order"
    assert_eq "false" "$(am_preset_field review shell)" "presets: shell defaults false"

    # Second preset with directory + shell; ~ expands. There is no task (-n).
    preset_main save scratch -t pi --shell "~/my tools" >/dev/null 2>&1
    assert_eq "review
scratch" "$(am_preset_names)" "presets: names sorted"
    assert_eq "$HOME/my tools" "$(am_preset_field scratch directory)" "presets: tilde expanded"
    assert_eq "true" "$(am_preset_field scratch shell)" "presets: shell stored"
    assert_eq "false" "$(preset_main save x -n "a task" >/dev/null 2>&1 && echo true || echo false)" \
        "presets: -n (task) is not an option"

    # list renders an equivalent am new line
    out=$(preset_main list)
    assert_contains "$out" "review           am new -t claude @ --" "presets: list renders the @spec directory"

    # A preset saved before 0.24 (workspace + branch) reads back as @<branch>
    am_preset_save legacy '{"agent":"claude","workspace":true,"branch":"review-48351"}'
    assert_eq "@review-48351" "$(am_preset_field legacy directory)" "presets: legacy workspace+branch → @branch"
    assert_contains "$(_preset_render legacy)" "@review-48351" "presets: legacy preset renders as a @spec"
    am_preset_save legacy2 '{"workspace":true}'
    assert_eq "@" "$(am_preset_field legacy2 directory)" "presets: legacy bare workspace → @"
    am_preset_rm legacy; am_preset_rm legacy2
    assert_contains "$out" "-- --model opus --effort high" "presets: list renders agent args"
    assert_contains "$out" "'$HOME/my tools'" "presets: list quotes a directory with spaces"

    # Validation
    assert_eq "false" "$(preset_main save 'bad name' -t claude >/dev/null 2>&1 && echo true || echo false)" \
        "presets: rejects names with spaces"
    assert_eq "false" "$(preset_main save x -t nosuchagent >/dev/null 2>&1 && echo true || echo false)" \
        "presets: rejects unknown agent type"
    assert_eq "" "$(am_preset_get x 2>/dev/null)" "presets: failed save leaves nothing behind"

    # Remove
    assert_eq "true" "$(preset_main rm review >/dev/null 2>&1 && echo true || echo false)" "presets: rm succeeds"
    assert_eq "scratch" "$(am_preset_names)" "presets: rm removes only its name"
    assert_eq "false" "$(preset_main rm review >/dev/null 2>&1 && echo true || echo false)" "presets: rm of missing fails"
    preset_main rm scratch >/dev/null 2>&1
    assert_eq "false" "$(jq 'has("presets")' "$AM_CONFIG")" "presets: empty presets key is dropped"
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
