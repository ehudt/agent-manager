#!/usr/bin/env bash
# tests/test_form.sh - Tests for lib/form.sh

test_form_core() {
    $SUMMARY_MODE || echo "=== Testing form field display ==="

    source "$LIB_DIR/utils.sh"
    set +u
    source "$LIB_DIR/config.sh"
    source "$LIB_DIR/tmux.sh"
    source "$LIB_DIR/registry.sh"
    source "$LIB_DIR/agents.sh"
    source "$LIB_DIR/form.sh"
    set -u

    local display

    display=$(_form_field_display "text" "Fix the bug" "" "" "" "false")
    assert_eq "Fix the bug" "$display" "form render: text field shows value"

    display=$(_form_field_display "text" "" "" "" "" "false")
    assert_eq "" "$display" "form render: empty text field"

    display=$(_form_field_display "select" "claude" "claude,codex,gemini" "" "" "false")
    assert_eq "[claude]  codex  gemini" "$display" "form render: select shows all options"

    display=$(_form_field_display "select" "codex" "claude,codex,gemini" "" "" "false")
    assert_eq "claude  [codex]  gemini" "$display" "form render: select highlights current"

    display=$(_form_field_display "select" "unknown" "" "" "" "false")
    assert_eq "[unknown]" "$display" "form render: select without options shows value"

    display=$(_form_field_display "checkbox" "true" "" "" "" "false")
    assert_eq "[x]" "$display" "form render: checkbox on"

    display=$(_form_field_display "checkbox" "false" "" "" "" "false")
    assert_eq "[ ]" "$display" "form render: checkbox off"

    display=$(_form_field_display "checkbox" "false" "" "true" "" "false")
    assert_eq "[disabled]" "$display" "form render: checkbox disabled"

    display=$(_form_field_display "directory" "/tmp/project" "" "" "" "false")
    assert_eq "/tmp/project" "$display" "form render: directory shows path"

    display=$(_form_field_display "submit" "" "" "" "" "false")
    assert_eq "[ Create ]" "$display" "form render: submit shows button"

    $SUMMARY_MODE || echo ""
    $SUMMARY_MODE || echo "=== Testing form input handling ==="

    _form_init "/tmp/project" "claude" "" "new" "false" "false" "false" "" "true"

    # Select cycling
    FORM_CURSOR=1  # agent field
    _form_handle_space
    local agent_after="${FORM_VALUES[agent]}"
    assert_eq "false" "$( [[ "$agent_after" == "claude" ]] && echo true || echo false )" \
        "form input: space cycles select field"

    # Checkbox toggle
    FORM_CURSOR=4  # yolo field
    assert_eq "false" "${FORM_VALUES[yolo]}" "form input: yolo starts false"
    _form_handle_space
    assert_eq "true" "${FORM_VALUES[yolo]}" "form input: space toggles yolo on"
    _form_handle_space
    assert_eq "false" "${FORM_VALUES[yolo]}" "form input: space toggles yolo off"

    # Disabled checkbox doesn't toggle
    # shellcheck disable=SC2154  # sandbox comes from sourced _form_init
    FORM_DISABLED[sandbox]="true"
    FORM_CURSOR=5  # sandbox
    FORM_VALUES[sandbox]="false"
    _form_handle_space
    assert_eq "false" "${FORM_VALUES[sandbox]}" "form input: disabled checkbox ignores space"

    # Mode cycling
    FORM_CURSOR=3  # mode field
    assert_eq "new" "${FORM_VALUES[mode]}" "form input: mode starts at new"
    _form_handle_space
    assert_eq "resume" "${FORM_VALUES[mode]}" "form input: mode cycles to resume"
    _form_handle_space
    assert_eq "continue" "${FORM_VALUES[mode]}" "form input: mode cycles to continue"
    _form_handle_space
    assert_eq "new" "${FORM_VALUES[mode]}" "form input: mode wraps to new"

    # Navigation
    FORM_CURSOR=0
    _form_handle_down
    assert_eq "1" "$FORM_CURSOR" "form input: down increments cursor"
    _form_handle_up
    assert_eq "0" "$FORM_CURSOR" "form input: up decrements cursor"
    _form_handle_up
    assert_eq "0" "$FORM_CURSOR" "form input: up clamps at 0"

    $SUMMARY_MODE || echo ""
    $SUMMARY_MODE || echo "=== Testing form text editing ==="

    _form_init "/tmp/project" "claude" "" "new" "false" "false" "false" "" "true"

    FORM_CURSOR=2  # task
    _form_handle_char "H"
    _form_handle_char "i"
    assert_eq "Hi" "${FORM_VALUES[task]}" "form text: typing appends chars"

    _form_handle_backspace
    assert_eq "H" "${FORM_VALUES[task]}" "form text: backspace removes last char"

    _form_handle_backspace
    _form_handle_backspace
    assert_eq "" "${FORM_VALUES[task]}" "form text: backspace on empty is noop"

    FORM_CURSOR=1  # agent (select)
    local before="${FORM_VALUES[agent]}"
    _form_handle_char "x"
    assert_eq "$before" "${FORM_VALUES[agent]}" "form text: char ignored on select field"

    $SUMMARY_MODE || echo ""
}

test_form_loop() {
    $SUMMARY_MODE || echo "=== Testing form keystroke dispatch ==="

    source "$LIB_DIR/utils.sh"
    set +u
    source "$LIB_DIR/config.sh"
    source "$LIB_DIR/tmux.sh"
    source "$LIB_DIR/registry.sh"
    source "$LIB_DIR/agents.sh"
    source "$LIB_DIR/form.sh"
    set -u

    # Parse unit-separator-delimited output using cut (tab would collapse empty fields)
    _parse_field() {
        local output="$1" field="$2"
        printf '%s' "$output" | cut -d$'\x1f' -f"$field"
    }

    _form_init "/tmp" "claude" "" "new" "false" "false" "false" "" "true"

    # Regular char on text field — only works in edit mode
    FORM_CURSOR=2  # task
    _FORM_MODE="edit"
    _form_process_key "H"
    assert_eq "continue" "$FORM_KEY_RESULT" "dispatch: char returns continue"
    assert_eq "H" "${FORM_VALUES[task]}" "dispatch: char is applied"
    _FORM_MODE="navigate"

    # Enter on submit field returns submit
    local submit_idx=$(( ${#FORM_FIELDS[@]} - 1 ))
    FORM_CURSOR=$submit_idx
    _form_process_key $'\n'
    assert_eq "submit" "$FORM_KEY_RESULT" "dispatch: enter returns submit"

    # Escape returns cancel
    _form_process_key $'\x1b' ""
    assert_eq "cancel" "$FORM_KEY_RESULT" "dispatch: escape returns cancel"

    # Arrow down
    FORM_CURSOR=0
    _form_process_key $'\x1b' "[B"
    assert_eq "continue" "$FORM_KEY_RESULT" "dispatch: arrow down returns continue"
    assert_eq "1" "$FORM_CURSOR" "dispatch: arrow down moves cursor"

    # Arrow up
    _form_process_key $'\x1b' "[A"
    assert_eq "continue" "$FORM_KEY_RESULT" "dispatch: arrow up returns continue"
    assert_eq "0" "$FORM_CURSOR" "dispatch: arrow up moves cursor"

    # Space
    FORM_CURSOR=4  # yolo
    _form_process_key " "
    assert_eq "continue" "$FORM_KEY_RESULT" "dispatch: space returns continue"
    assert_eq "true" "${FORM_VALUES[yolo]}" "dispatch: space toggled yolo"

    # Right arrow cycles select forward
    FORM_CURSOR=3  # mode
    FORM_VALUES[mode]="new"
    _FORM_MODE="navigate"
    _form_process_key $'\x1b' "[C"
    assert_eq "continue" "$FORM_KEY_RESULT" "dispatch: right arrow returns continue"
    assert_eq "resume" "${FORM_VALUES[mode]}" "dispatch: right arrow cycles select forward"

    # Left arrow cycles select backward
    _form_process_key $'\x1b' "[D"
    assert_eq "new" "${FORM_VALUES[mode]}" "dispatch: left arrow cycles select backward"

    # Right arrow toggles checkbox
    FORM_CURSOR=4  # yolo
    FORM_VALUES[yolo]="false"
    _form_process_key $'\x1b' "[C"
    assert_eq "true" "${FORM_VALUES[yolo]}" "dispatch: right arrow toggles checkbox"
    _form_process_key $'\x1b' "[D"
    assert_eq "false" "${FORM_VALUES[yolo]}" "dispatch: left arrow toggles checkbox"

    # Tab (handled inline now, returns continue)
    FORM_CURSOR=0  # directory field
    _form_process_key $'\t'
    assert_eq "continue" "$FORM_KEY_RESULT" "dispatch: tab returns continue"

    $SUMMARY_MODE || echo ""
    $SUMMARY_MODE || echo "=== Testing form output contract ==="

    _form_init "/tmp" "claude" "fix bugs" "new" "true" "false" "false" "" "true"

    local output directory agent task worktree flags
    output=$(_form_output)
    directory=$(_parse_field "$output" 1)
    agent=$(_parse_field "$output" 2)
    task=$(_parse_field "$output" 3)
    worktree=$(_parse_field "$output" 4)
    flags=$(_parse_field "$output" 5)

    assert_eq "/tmp" "$directory" "form output: directory"
    assert_eq "claude" "$agent" "form output: agent"
    assert_eq "fix bugs" "$task" "form output: task"
    assert_eq "" "$worktree" "form output: no worktree"
    assert_contains "$flags" "--yolo" "form output: yolo flag"

    # With worktree
    _form_init "/tmp" "claude" "" "resume" "false" "true" "true" "my-branch" "true"
    output=$(_form_output)
    worktree=$(_parse_field "$output" 4)
    flags=$(_parse_field "$output" 5)
    assert_eq "my-branch" "$worktree" "form output: worktree name"
    assert_contains "$flags" "--resume" "form output: resume flag"
    assert_contains "$flags" "--sandbox" "form output: sandbox flag"

    # Auto worktree
    _form_init "/tmp" "claude" "" "new" "false" "false" "true" "" "true"
    output=$(_form_output)
    worktree=$(_parse_field "$output" 4)
    assert_eq "__auto__" "$worktree" "form output: auto worktree"

    $SUMMARY_MODE || echo ""
}

test_form_modes() {
    $SUMMARY_MODE || echo "=== Testing form mode state ==="

    source "$LIB_DIR/utils.sh"
    set +u
    source "$LIB_DIR/config.sh"
    source "$LIB_DIR/tmux.sh"
    source "$LIB_DIR/registry.sh"
    source "$LIB_DIR/agents.sh"
    source "$LIB_DIR/form.sh"
    set -u

    _form_init "/tmp" "claude" "" "new" "false" "false" "false" "" "true"

    # Mode starts as edit (on directory field)
    assert_eq "edit" "$_FORM_MODE" "mode: starts as edit"

    # Last field is submit pseudo-field
    local last_idx=$(( ${#FORM_FIELDS[@]} - 1 ))
    assert_eq "submit" "${FORM_FIELDS[$last_idx]}" "mode: last field is submit"
    assert_eq "submit" "${FORM_TYPES[submit]}" "mode: submit field type is submit"

    # Dir highlight starts at 0
    assert_eq "0" "$_FORM_DIR_HIGHLIGHT" "mode: dir highlight starts at 0"

    $SUMMARY_MODE || echo ""
    $SUMMARY_MODE || echo "=== Testing navigate mode key dispatch ==="

    _form_init "/tmp" "claude" "" "new" "false" "false" "false" "" "true"
    _FORM_MODE="navigate"

    # In navigate mode, Enter on text field enters edit mode
    FORM_CURSOR=2  # task (text field)
    _form_process_key $'\n'
    assert_eq "continue" "$FORM_KEY_RESULT" "nav: enter on text field returns continue"
    assert_eq "edit" "$_FORM_MODE" "nav: enter on text field enters edit mode"

    # Reset
    _FORM_MODE="navigate"

    # In navigate mode, Enter on checkbox submits
    FORM_CURSOR=4  # yolo
    FORM_VALUES[yolo]="false"
    _form_process_key $'\n'
    assert_eq "submit" "$FORM_KEY_RESULT" "nav: enter on checkbox submits"
    assert_eq "false" "${FORM_VALUES[yolo]}" "nav: enter on checkbox does not toggle"

    # In navigate mode, Enter on select submits
    _FORM_MODE="navigate"
    FORM_CURSOR=3  # mode (select)
    FORM_VALUES[mode]="new"
    _form_process_key $'\n'
    assert_eq "submit" "$FORM_KEY_RESULT" "nav: enter on select submits"
    assert_eq "new" "${FORM_VALUES[mode]}" "nav: enter on select does not cycle"

    # In navigate mode, Enter on submit returns submit
    _FORM_MODE="navigate"
    local submit_idx=$(( ${#FORM_FIELDS[@]} - 1 ))
    FORM_CURSOR=$submit_idx
    _form_process_key $'\n'
    assert_eq "submit" "$FORM_KEY_RESULT" "nav: enter on submit returns submit"

    # In navigate mode, Space on checkbox toggles
    _FORM_MODE="navigate"
    FORM_CURSOR=4  # yolo
    FORM_VALUES[yolo]="false"
    _form_process_key " "
    assert_eq "true" "${FORM_VALUES[yolo]}" "nav: space toggles checkbox"

    # In navigate mode, typing is ignored on text fields
    _FORM_MODE="navigate"
    FORM_CURSOR=2  # task
    FORM_VALUES[task]=""
    _form_process_key "x"
    assert_eq "" "${FORM_VALUES[task]}" "nav: typing ignored on text field"

    # In navigate mode, Ctrl-S submits
    _FORM_MODE="navigate"
    FORM_CURSOR=0
    _form_process_key $'\x13'
    assert_eq "submit" "$FORM_KEY_RESULT" "nav: ctrl-s submits"

    $SUMMARY_MODE || echo ""
    $SUMMARY_MODE || echo "=== Testing edit mode key dispatch ==="

    _form_init "/tmp" "claude" "" "new" "false" "false" "false" "" "true"
    _FORM_MODE="edit"
    FORM_CURSOR=2  # task (text field)

    # Typing works in edit mode
    _form_process_key "H"
    assert_eq "H" "${FORM_VALUES[task]}" "edit: typing works"
    assert_eq "edit" "$_FORM_MODE" "edit: stays in edit mode"

    # Space types a space in edit mode
    _form_process_key " "
    assert_eq "H " "${FORM_VALUES[task]}" "edit: space types space"

    # Backspace works
    _form_process_key $'\x7f'
    assert_eq "H" "${FORM_VALUES[task]}" "edit: backspace works"

    # Enter exits edit mode
    _form_process_key $'\n'
    assert_eq "navigate" "$_FORM_MODE" "edit: enter exits to navigate"
    assert_eq "continue" "$FORM_KEY_RESULT" "edit: enter returns continue"

    # Esc exits edit mode
    _FORM_MODE="edit"
    _form_process_key $'\x1b' ""
    assert_eq "navigate" "$_FORM_MODE" "edit: esc exits to navigate"
    assert_eq "continue" "$FORM_KEY_RESULT" "edit: esc returns continue (not cancel)"

    $SUMMARY_MODE || echo ""
    $SUMMARY_MODE || echo "=== Testing directory highlight scrolling ==="

    _form_init "/tmp" "claude" "" "new" "false" "false" "false" "" "true"
    _FORM_MODE="edit"
    FORM_CURSOR=0  # directory

    # Preload some fake suggestions for testing
    _FORM_DIR_SUGGESTIONS=("/home/user/project1" "/home/user/project2" "/home/user/project3")
    _FORM_DIR_SUGGESTIONS_LOADED=true
    _form_filter_dir_suggestions "" 5

    # Highlight starts at 0
    assert_eq "0" "$_FORM_DIR_HIGHLIGHT" "dir scroll: starts at 0"

    # Down moves highlight
    _form_process_key $'\x1b' "[B"
    assert_eq "1" "$_FORM_DIR_HIGHLIGHT" "dir scroll: down moves to 1"

    # Down again
    _form_process_key $'\x1b' "[B"
    assert_eq "2" "$_FORM_DIR_HIGHLIGHT" "dir scroll: down moves to 2"

    # Down clamps at max
    _form_process_key $'\x1b' "[B"
    assert_eq "2" "$_FORM_DIR_HIGHLIGHT" "dir scroll: down clamps at max"

    # Up moves back
    _form_process_key $'\x1b' "[A"
    assert_eq "1" "$_FORM_DIR_HIGHLIGHT" "dir scroll: up moves to 1"

    # Tab accepts highlighted suggestion
    FORM_VALUES[directory]=""
    _FORM_DIR_HIGHLIGHT=1
    _form_handle_tab
    assert_eq "/home/user/project2" "${FORM_VALUES[directory]}" "dir scroll: tab accepts highlighted"

    # Typing resets highlight to 0
    _FORM_DIR_HIGHLIGHT=2
    _form_handle_char "x"
    assert_eq "0" "$_FORM_DIR_HIGHLIGHT" "dir scroll: typing resets highlight"

    # Enter in edit mode accepts highlighted suggestion
    _FORM_MODE="edit"
    FORM_CURSOR=0
    FORM_VALUES[directory]=""
    _FORM_DIR_HIGHLIGHT=2
    _form_filter_dir_suggestions "" 5
    _form_process_key $'\n'
    assert_eq "/home/user/project3" "${FORM_VALUES[directory]}" "dir scroll: enter accepts highlighted"
    assert_eq "navigate" "$_FORM_MODE" "dir scroll: enter returns to navigate"

    $SUMMARY_MODE || echo ""
    $SUMMARY_MODE || echo "=== Testing directory scroll offset ==="

    _form_init "/tmp" "claude" "" "new" "false" "false" "false" "" "true"
    _FORM_MODE="edit"
    FORM_CURSOR=0  # directory

    # Create 15 fake suggestions (more than visible window of 10)
    _FORM_DIR_SUGGESTIONS=()
    local di
    for ((di=0; di<15; di++)); do
        _FORM_DIR_SUGGESTIONS+=("/home/user/project$di")
    done
    _FORM_DIR_SUGGESTIONS_LOADED=true
    _form_filter_dir_suggestions "" 50

    # Scroll offset starts at 0
    assert_eq "0" "$_FORM_DIR_SCROLL_OFFSET" "dir scroll offset: starts at 0"

    # Move highlight down past visible window
    for ((di=0; di<12; di++)); do
        _form_process_key $'\x1b' "[B"
    done
    assert_eq "12" "$_FORM_DIR_HIGHLIGHT" "dir scroll offset: highlight at 12"
    # Scroll offset should have moved
    assert_eq "true" "$( [[ $_FORM_DIR_SCROLL_OFFSET -gt 0 ]] && echo true || echo false )" \
        "dir scroll offset: offset moved from 0"

    # Move back up to 0
    for ((di=0; di<12; di++)); do
        _form_process_key $'\x1b' "[A"
    done
    assert_eq "0" "$_FORM_DIR_HIGHLIGHT" "dir scroll offset: highlight back at 0"
    assert_eq "0" "$_FORM_DIR_SCROLL_OFFSET" "dir scroll offset: offset back at 0"

    # Typing resets scroll offset
    _FORM_DIR_SCROLL_OFFSET=5
    _form_handle_char "x"
    assert_eq "0" "$_FORM_DIR_SCROLL_OFFSET" "dir scroll offset: typing resets offset"

    # Tab resets scroll offset
    _FORM_DIR_SCROLL_OFFSET=5
    FORM_VALUES[directory]=""
    _form_handle_tab
    assert_eq "0" "$_FORM_DIR_SCROLL_OFFSET" "dir scroll offset: tab resets offset"

    $SUMMARY_MODE || echo ""
    $SUMMARY_MODE || echo "=== Testing disabled field behavior ==="

    _form_init "/tmp" "claude" "" "new" "false" "false" "true" "" "true"

    # worktree_name is not disabled when worktree_enabled=true
    assert_eq "" "${FORM_DISABLED[worktree_name]:-}" "disabled: worktree_name enabled when worktree on"

    # Toggling worktree off disables worktree_name
    FORM_CURSOR=6  # worktree_enabled
    _form_handle_space  # toggle off
    assert_eq "true" "${FORM_DISABLED[worktree_name]}" "disabled: worktree_name disabled when worktree off"

    # Toggling worktree back on re-enables worktree_name
    _form_handle_space  # toggle on
    assert_eq "" "${FORM_DISABLED[worktree_name]:-}" "disabled: worktree_name re-enabled when worktree on"

    # Disabled text field shows "--"
    local display
    display=$(_form_field_display "text" "anything" "" "true" "" "false")
    assert_eq "--" "$display" "disabled: text field shows --"

    # Navigate mode: enter on disabled text field does not enter edit mode
    _form_init "/tmp" "claude" "" "new" "false" "false" "false" "" "true"
    FORM_DISABLED[worktree_name]="true"
    local wt_idx=-1 fi_idx
    for ((fi_idx=0; fi_idx<${#FORM_FIELDS[@]}; fi_idx++)); do
        [[ "${FORM_FIELDS[$fi_idx]}" == "worktree_name" ]] && wt_idx=$fi_idx
    done
    if [[ $wt_idx -ge 0 ]]; then
        FORM_CURSOR=$wt_idx
        _FORM_MODE="navigate"
        _form_process_key $'\n'
        assert_eq "navigate" "$_FORM_MODE" "disabled: enter on disabled text stays in navigate"
    fi

    # Cursor block only shows in edit mode (not navigate)
    _form_init "/tmp" "claude" "" "new" "false" "false" "false" "" "true"
    FORM_CURSOR=2  # task field
    _FORM_MODE="navigate"
    _FORM_BUF=""
    _form_render_field "task" "true"
    local nav_render="$_FORM_BUF"
    # In navigate mode, should NOT contain inverse block cursor
    assert_eq "false" "$( [[ "$nav_render" == *$'\033[7m'* ]] && echo true || echo false )" \
        "cursor: no inverse block in navigate mode"

    _FORM_MODE="edit"
    _FORM_BUF=""
    _form_render_field "task" "true"
    local edit_render="$_FORM_BUF"
    # In edit mode, SHOULD contain inverse block cursor
    assert_eq "true" "$( [[ "$edit_render" == *$'\033[7m'* ]] && echo true || echo false )" \
        "cursor: inverse block shown in edit mode"

    # Background highlight: navigate=gray (236), edit=blue (24), only on label
    _FORM_MODE="navigate"
    _FORM_BUF=""
    _form_render_field "task" "true"
    assert_eq "true" "$( [[ "$_FORM_BUF" == *$'\033[48;5;236m'* ]] && echo true || echo false )" \
        "highlight: navigate mode uses gray bg"
    assert_eq "false" "$( [[ "$_FORM_BUF" == *$'\033[48;5;24m'* ]] && echo true || echo false )" \
        "highlight: navigate mode does not use blue bg"

    _FORM_MODE="edit"
    _FORM_BUF=""
    _form_render_field "task" "true"
    assert_eq "true" "$( [[ "$_FORM_BUF" == *$'\033[48;5;24m'* ]] && echo true || echo false )" \
        "highlight: edit mode uses blue bg"
    assert_eq "false" "$( [[ "$_FORM_BUF" == *$'\033[48;5;236m'* ]] && echo true || echo false )" \
        "highlight: edit mode does not use gray bg"

    $SUMMARY_MODE || echo ""
}

test_form_config_defaults() {
    $SUMMARY_MODE || echo "=== Testing form config defaults ==="

    source "$LIB_DIR/utils.sh"
    set +u
    source "$LIB_DIR/config.sh"
    source "$LIB_DIR/tmux.sh"
    source "$LIB_DIR/registry.sh"
    source "$LIB_DIR/agents.sh"
    source "$LIB_DIR/form.sh"
    set -u

    _parse_field() {
        local output="$1" field="$2"
        printf '%s' "$output" | cut -d$'\x1f' -f"$field"
    }

    # Mock _form_run to skip interactive loop, just emit output
    _form_run() { _form_output; }

    # Mock config functions
    am_new_form_enabled() { return 0; }
    am_docker_available() { return 0; }

    # Test 1: default_yolo=true, default_sandbox=false
    # sandbox should NOT be checked (config default respected, not overridden by yolo)
    am_default_yolo_enabled() { return 0; }    # true
    am_default_sandbox_enabled() { return 1; }  # false

    local output flags
    output=$(am_new_session_form "/tmp")
    flags=$(_parse_field "$output" 5)
    assert_contains "$flags" "--yolo" "config defaults: yolo flag present when default_yolo=true"
    assert_not_contains "$flags" "--sandbox" "config defaults: sandbox NOT present when default_sandbox=false (even with yolo)"

    # Test 2: explicit --yolo flag SHOULD imply sandbox
    am_default_yolo_enabled() { return 1; }    # false (not from config)
    am_default_sandbox_enabled() { return 1; }  # false
    output=$(am_new_session_form "/tmp" "" "" "" "--yolo")
    flags=$(_parse_field "$output" 5)
    assert_contains "$flags" "--yolo" "config defaults: explicit --yolo flag present"
    assert_contains "$flags" "--sandbox" "config defaults: explicit --yolo implies sandbox"

    # Test 3: both defaults true
    am_default_yolo_enabled() { return 0; }    # true
    am_default_sandbox_enabled() { return 0; }  # true
    output=$(am_new_session_form "/tmp")
    flags=$(_parse_field "$output" 5)
    assert_contains "$flags" "--yolo" "config defaults: both defaults - yolo present"
    assert_contains "$flags" "--sandbox" "config defaults: both defaults - sandbox present"

    # Test 4: default_yolo=false, default_sandbox=true
    am_default_yolo_enabled() { return 1; }    # false
    am_default_sandbox_enabled() { return 0; }  # true
    output=$(am_new_session_form "/tmp")
    flags=$(_parse_field "$output" 5)
    assert_not_contains "$flags" "--yolo" "config defaults: yolo not present when default_yolo=false"
    assert_contains "$flags" "--sandbox" "config defaults: sandbox present when default_sandbox=true"

    $SUMMARY_MODE || echo ""
}

run_form_tests() {
    _run_test test_form_core
    _run_test test_form_loop
    _run_test test_form_modes
    _run_test test_form_config_defaults
}

if [[ -z "${_AM_TEST_RUNNER:-}" ]]; then
    set -uo pipefail
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helpers.sh"
    check_deps
    run_form_tests
    test_report
fi
