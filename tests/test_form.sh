#!/usr/bin/env bash
# tests/test_form.sh - Tests for lib/form.sh

test_form_core() {
    $SUMMARY_MODE || echo "=== Testing form input handling ==="

    source "$LIB_DIR/utils.sh"
    set +u
    source "$LIB_DIR/config.sh"
    source "$LIB_DIR/tmux.sh"
    source "$LIB_DIR/registry.sh"
    source "$LIB_DIR/agents.sh"
    source "$LIB_DIR/form.sh"
    set -u
    # The user's real config may define workspace_cmd, which adds fields and
    # shifts every index below; run against a fresh, empty config.
    unset AM_WORKSPACE_CMD
    setup_isolated_am_dir
    am_config_init

    _form_init "/tmp/project" "claude" ""
    assert_contains "${FORM_OPTIONS[agent]}" "cursor," \
        "form input: cursor is available as an agent"
    assert_not_contains "${FORM_OPTIONS[agent]}" "cursor-agent" \
        "form input: cursor alias is not duplicated"

    # The form is just Directory / Agent / Task (plus Workspace fields when
    # a workspace_cmd is configured — see test_form_workspace)
    assert_eq "directory agent task" "${FORM_FIELDS[*]}" "form input: fields are directory, agent, task"
    assert_eq "" "${FORM_TYPES[mode]:-}${FORM_TYPES[yolo]:-}${FORM_TYPES[sandbox]:-}${FORM_TYPES[worktree_enabled]:-}" \
        "form input: no mode/yolo/sandbox/worktree fields"

    # Select cycling
    FORM_CURSOR=1  # agent field
    _form_handle_space
    local agent_after="${FORM_VALUES[agent]}"
    assert_eq "false" "$( [[ "$agent_after" == "claude" ]] && echo true || echo false )" \
        "form input: space cycles select field"
    FORM_VALUES[agent]="pi"
    _form_handle_space
    assert_eq "claude" "${FORM_VALUES[agent]}" "form input: select wraps to first option"

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

    _form_init "/tmp/project" "claude" ""

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

    # The launcher requests bare paths so slow per-repository branch
    # annotations do not block its first render.
    local saved_list_directories=""
    if declare -F _list_directories >/dev/null; then
        saved_list_directories=$(declare -f _list_directories)
    fi
    _list_directories() { printf '/tmp/project\tannotations=%s\n' "${2:-missing}"; }
    _FORM_DIR_SUGGESTIONS_LOADED=false
    _form_load_dir_suggestions
    assert_eq $'/tmp/project\tannotations=false' "${_FORM_DIR_SUGGESTIONS[0]}" \
        "form startup: directory list skips branch annotations"
    if [[ -n "$saved_list_directories" ]]; then
        eval "$saved_list_directories"
    else
        unset -f _list_directories
    fi

    teardown_isolated_am_dir
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
    # The user's real config may define workspace_cmd, which adds fields and
    # shifts every index below; run against a fresh, empty config.
    unset AM_WORKSPACE_CMD
    setup_isolated_am_dir
    am_config_init

    # Parse unit-separator-delimited output using cut (tab would collapse empty fields)
    _parse_field() {
        local output="$1" field="$2"
        printf '%s' "$output" | cut -d$'\x1f' -f"$field"
    }

    _form_init "/tmp" "claude" ""

    # The initial screen is a directory launcher
    assert_eq "false" "$_FORM_OPTIONS_OPEN" "launcher: options start closed"
    assert_eq "edit" "$_FORM_MODE" "launcher: directory starts in edit mode"

    # Enter accepts the highlighted directory and launches the current harness
    FORM_VALUES[directory]=""
    _FORM_DIR_SUGGESTIONS=("/tmp/project1" "/tmp/project2")
    _FORM_DIR_SUGGESTIONS_LOADED=true
    _form_filter_dir_suggestions "" 5
    _FORM_DIR_HIGHLIGHT=1
    _form_process_key $'\n'
    assert_eq "submit" "$FORM_KEY_RESULT" "launcher: enter submits"
    assert_eq "/tmp/project2" "${FORM_VALUES[directory]}" "launcher: enter accepts highlighted directory"
    assert_eq "claude" "${FORM_VALUES[agent]}" "launcher: enter keeps current harness"

    # Each harness has a direct launch shortcut
    local -a launch_keys=($'\x0c' $'\x18' $'\x12' $'\x10')
    local -a launch_agents=("claude" "codex" "cursor" "pi")
    local launch_idx
    for ((launch_idx=0; launch_idx<${#launch_keys[@]}; launch_idx++)); do
        _form_init "/tmp" "claude" ""
        FORM_VALUES[directory]=""
        _FORM_DIR_SUGGESTIONS=("/tmp/project1")
        _FORM_DIR_SUGGESTIONS_LOADED=true
        _form_filter_dir_suggestions "" 5
        _form_process_key "${launch_keys[$launch_idx]}"
        assert_eq "submit" "$FORM_KEY_RESULT" \
            "launcher: shortcut submits ${launch_agents[$launch_idx]}"
        assert_eq "/tmp/project1" "${FORM_VALUES[directory]}" \
            "launcher: shortcut accepts highlighted directory for ${launch_agents[$launch_idx]}"
        assert_eq "${launch_agents[$launch_idx]}" "${FORM_VALUES[agent]}" \
            "launcher: shortcut selects ${launch_agents[$launch_idx]}"
    done

    # Tab accepts the directory and progressively reveals advanced options
    _form_init "/tmp" "claude" ""
    FORM_VALUES[directory]=""
    _FORM_DIR_SUGGESTIONS=("/tmp/project1" "/tmp/project2")
    _FORM_DIR_SUGGESTIONS_LOADED=true
    _form_filter_dir_suggestions "" 5
    _FORM_DIR_HIGHLIGHT=1
    _form_process_key $'\t'
    assert_eq "continue" "$FORM_KEY_RESULT" "launcher: tab continues"
    assert_eq "/tmp/project2" "${FORM_VALUES[directory]}" "launcher: tab accepts highlighted directory"
    assert_eq "true" "$_FORM_OPTIONS_OPEN" "launcher: tab opens options"
    assert_eq "navigate" "$_FORM_MODE" "launcher: tab enters option navigation"
    assert_eq "1" "$FORM_CURSOR" "launcher: tab focuses harness option"

    # Escape from option navigation returns to the directory launcher
    _form_process_key $'\x1b' ""
    assert_eq "continue" "$FORM_KEY_RESULT" "options: escape returns to launcher"
    assert_eq "false" "$_FORM_OPTIONS_OPEN" "options: escape closes options"
    assert_eq "edit" "$_FORM_MODE" "options: escape resumes directory editing"
    assert_eq "0" "$FORM_CURSOR" "options: escape focuses directory"

    # Selecting Directory from options also returns to the fuzzy finder
    _form_process_key $'\t'
    FORM_CURSOR=0
    _form_process_key $'\n'
    assert_eq "continue" "$FORM_KEY_RESULT" "options: enter on directory continues"
    assert_eq "false" "$_FORM_OPTIONS_OPEN" "options: enter on directory closes options"
    assert_eq "edit" "$_FORM_MODE" "options: enter on directory resumes directory editing"

    # Ctrl-S remains compatible and now submits directly from directory editing
    _form_init "/tmp" "claude" ""
    FORM_VALUES[directory]=""
    _FORM_DIR_SUGGESTIONS=("/tmp/project1")
    _FORM_DIR_SUGGESTIONS_LOADED=true
    _form_filter_dir_suggestions "" 5
    _form_process_key $'\x13'
    assert_eq "submit" "$FORM_KEY_RESULT" "launcher: ctrl-s submits from directory editing"
    assert_eq "/tmp/project1" "${FORM_VALUES[directory]}" \
        "launcher: ctrl-s accepts highlighted directory"

    # Regular char on text field — only works in edit mode
    _form_init "/tmp" "claude" ""
    _FORM_OPTIONS_OPEN=true
    FORM_CURSOR=2  # task
    _FORM_MODE="edit"
    _form_process_key "H"
    assert_eq "continue" "$FORM_KEY_RESULT" "dispatch: char returns continue"
    assert_eq "H" "${FORM_VALUES[task]}" "dispatch: char is applied"
    _FORM_MODE="navigate"

    # Escape from the directory launcher returns cancel
    _form_init "/tmp" "claude" ""
    _form_process_key $'\x1b' ""
    assert_eq "cancel" "$FORM_KEY_RESULT" "launcher: escape returns cancel"

    # Advanced-option navigation
    _FORM_OPTIONS_OPEN=true
    _FORM_MODE="navigate"
    FORM_CURSOR=0
    _form_process_key $'\x1b' "[B"
    assert_eq "continue" "$FORM_KEY_RESULT" "dispatch: arrow down returns continue"
    assert_eq "1" "$FORM_CURSOR" "dispatch: arrow down moves cursor"

    # Arrow up
    _form_process_key $'\x1b' "[A"
    assert_eq "continue" "$FORM_KEY_RESULT" "dispatch: arrow up returns continue"
    assert_eq "0" "$FORM_CURSOR" "dispatch: arrow up moves cursor"

    # Space cycles a select
    FORM_CURSOR=1  # agent
    FORM_VALUES[agent]="claude"
    _form_process_key " "
    assert_eq "continue" "$FORM_KEY_RESULT" "dispatch: space returns continue"
    assert_eq "codex" "${FORM_VALUES[agent]}" "dispatch: space cycled agent"

    # Right arrow cycles select forward
    FORM_VALUES[agent]="claude"
    _FORM_MODE="navigate"
    _form_process_key $'\x1b' "[C"
    assert_eq "continue" "$FORM_KEY_RESULT" "dispatch: right arrow returns continue"
    assert_eq "codex" "${FORM_VALUES[agent]}" "dispatch: right arrow cycles select forward"

    # Left arrow cycles select backward
    _form_process_key $'\x1b' "[D"
    assert_eq "claude" "${FORM_VALUES[agent]}" "dispatch: left arrow cycles select backward"

    $SUMMARY_MODE || echo ""
    $SUMMARY_MODE || echo "=== Testing form output contract ==="

    _form_init "/tmp" "claude" "fix bugs"

    local output directory agent task flags
    output=$(_form_output)
    directory=$(_parse_field "$output" 1)
    agent=$(_parse_field "$output" 2)
    task=$(_parse_field "$output" 3)
    flags=$(_parse_field "$output" 4)

    assert_eq "/tmp" "$directory" "form output: directory"
    assert_eq "claude" "$agent" "form output: agent"
    assert_eq "fix bugs" "$task" "form output: task"
    assert_eq "" "$flags" "form output: no flags without workspace"
    assert_eq "3" "$(printf '%s' "$output" | tr -cd $'\x1f' | wc -c | tr -d ' ')" \
        "form output: exactly four fields (directory, agent, task, flags)"

    teardown_isolated_am_dir
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
    # The user's real config may define workspace_cmd, which adds fields and
    # shifts every index below; run against a fresh, empty config.
    unset AM_WORKSPACE_CMD
    setup_isolated_am_dir
    am_config_init

    _form_init "/tmp" "claude" ""

    # Mode starts as edit (on directory field)
    assert_eq "edit" "$_FORM_MODE" "mode: starts as edit"

    # Advanced options are progressively disclosed and there is no submit row
    assert_eq "false" "$_FORM_OPTIONS_OPEN" "mode: options start closed"
    local has_submit="false" field
    for field in "${FORM_FIELDS[@]}"; do
        [[ "$field" == "submit" ]] && has_submit="true"
    done
    assert_eq "false" "$has_submit" "mode: submit is not a scrollable field"

    # Dir highlight starts at 0
    assert_eq "0" "$_FORM_DIR_HIGHLIGHT" "mode: dir highlight starts at 0"
    assert_eq "7" "$_FORM_DIR_SUGGESTION_LINES" "mode: compact launcher shows seven suggestions"

    $SUMMARY_MODE || echo ""
    $SUMMARY_MODE || echo "=== Testing navigate mode key dispatch ==="

    _form_init "/tmp" "claude" ""
    _FORM_OPTIONS_OPEN=true
    _FORM_MODE="navigate"

    # In navigate mode, Enter on text field enters edit mode
    FORM_CURSOR=2  # task (text field)
    _form_process_key $'\n'
    assert_eq "continue" "$FORM_KEY_RESULT" "nav: enter on text field returns continue"
    assert_eq "edit" "$_FORM_MODE" "nav: enter on text field enters edit mode"

    # Reset
    _FORM_MODE="navigate"

    # In navigate mode, Enter on select submits
    _FORM_MODE="navigate"
    FORM_CURSOR=1  # agent (select)
    FORM_VALUES[agent]="claude"
    _form_process_key $'\n'
    assert_eq "submit" "$FORM_KEY_RESULT" "nav: enter on select submits"
    assert_eq "claude" "${FORM_VALUES[agent]}" "nav: enter on select does not cycle"

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

    _form_init "/tmp" "claude" ""
    _FORM_OPTIONS_OPEN=true
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

    _form_init "/tmp" "claude" ""
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

    # Enter in advanced directory editing accepts without launching
    _FORM_MODE="edit"
    _FORM_OPTIONS_OPEN=true
    FORM_CURSOR=0
    FORM_VALUES[directory]=""
    _FORM_DIR_HIGHLIGHT=2
    _form_filter_dir_suggestions "" 5
    _form_process_key $'\n'
    assert_eq "/home/user/project3" "${FORM_VALUES[directory]}" "dir scroll: enter accepts highlighted"
    assert_eq "navigate" "$_FORM_MODE" "dir scroll: enter returns to navigate"
    assert_eq "continue" "$FORM_KEY_RESULT" "dir scroll: advanced enter does not launch"

    $SUMMARY_MODE || echo ""
    $SUMMARY_MODE || echo "=== Testing directory scroll offset ==="

    _form_init "/tmp" "claude" ""
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

    # Navigate mode: enter on a disabled text field does not enter edit mode
    _form_init "/tmp" "claude" ""
    FORM_DISABLED[task]="true"
    FORM_CURSOR=2  # task
    _FORM_MODE="navigate"
    _form_process_key $'\n'
    assert_eq "navigate" "$_FORM_MODE" "disabled: enter on disabled text stays in navigate"
    _form_process_key "x"
    assert_eq "" "${FORM_VALUES[task]}" "disabled: typing into a disabled text field is ignored"
    FORM_DISABLED[task]=""

    # Cursor block only shows in edit mode (not navigate)
    _form_init "/tmp" "claude" ""
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

    teardown_isolated_am_dir
    $SUMMARY_MODE || echo ""
}

test_form_workspace() {
    $SUMMARY_MODE || echo "=== Testing form workspace fields ==="

    source "$LIB_DIR/utils.sh"
    set +u
    source "$LIB_DIR/config.sh"
    source "$LIB_DIR/tmux.sh"
    source "$LIB_DIR/registry.sh"
    source "$LIB_DIR/agents.sh"
    source "$LIB_DIR/form.sh"
    set -u

    # Without a workspace_cmd the fields are absent and the order is unchanged
    unset AM_WORKSPACE_CMD
    setup_isolated_am_dir
    am_config_init
    _form_init "/tmp" "claude" ""
    assert_eq "agent" "${FORM_FIELDS[1]}" "form workspace: fields hidden when workspace_cmd unset"
    assert_eq "" "${FORM_TYPES[workspace_enabled]:-}" "form workspace: no workspace field when unset"

    export AM_WORKSPACE_CMD="echo /tmp"
    _form_init "/tmp" "claude" ""
    assert_eq "workspace_enabled" "${FORM_FIELDS[1]}" "form workspace: Workspace follows Directory"
    assert_eq "workspace_branch" "${FORM_FIELDS[2]}" "form workspace: Branch follows Workspace"
    assert_eq "false" "${FORM_VALUES[workspace_enabled]}" "form workspace: starts off"
    assert_eq "true" "${FORM_DISABLED[workspace_branch]}" "form workspace: branch disabled while off"
    assert_eq "" "${FORM_DISABLED[directory]:-}" "form workspace: directory enabled while off"

    # Toggle on: branch editable, directory out of play
    FORM_CURSOR=1
    _form_handle_space
    assert_eq "true" "${FORM_VALUES[workspace_enabled]}" "form workspace: space toggles on"
    assert_eq "" "${FORM_DISABLED[workspace_branch]}" "form workspace: branch enabled when on"
    assert_eq "true" "${FORM_DISABLED[directory]}" "form workspace: directory disabled when on"

    # Checkbox key dispatch in navigate mode: arrows toggle, Enter submits without toggling
    _FORM_OPTIONS_OPEN=true
    _FORM_MODE="navigate"
    _form_process_key $'\x1b' "[D"
    assert_eq "false" "${FORM_VALUES[workspace_enabled]}" "form workspace: left arrow toggles checkbox off"
    _form_process_key $'\x1b' "[C"
    assert_eq "true" "${FORM_VALUES[workspace_enabled]}" "form workspace: right arrow toggles checkbox on"
    _form_process_key $'\n'
    assert_eq "submit" "$FORM_KEY_RESULT" "form workspace: enter on checkbox submits"
    assert_eq "true" "${FORM_VALUES[workspace_enabled]}" "form workspace: enter does not toggle"

    # A disabled checkbox ignores space
    FORM_DISABLED[workspace_enabled]="true"
    _form_handle_space
    assert_eq "true" "${FORM_VALUES[workspace_enabled]}" "form workspace: disabled checkbox ignores space"
    FORM_DISABLED[workspace_enabled]=""

    # Output carries --workspace=<branch> and skips directory validation
    FORM_VALUES[workspace_branch]="review-48351"
    FORM_VALUES[directory]="/definitely/not/a/dir"
    local out flags agent_out task_out
    out=$(_form_output 2>/dev/null)
    IFS=$'\x1f' read -r _ _ _ flags <<< "$out"
    assert_contains "$flags" "--workspace=review-48351" "form workspace: output flags carry the branch"

    FORM_VALUES[workspace_branch]=""
    out=$(_form_output 2>/dev/null)
    IFS=$'\x1f' read -r _ _ _ flags <<< "$out"
    assert_contains "$flags" "--workspace" "form workspace: output flags carry bare --workspace without branch"
    assert_not_contains "$flags" "--workspace=" "form workspace: no empty branch suffix"

    # Toggle off: directory validated again
    _form_handle_space
    assert_eq "" "${FORM_DISABLED[directory]:-}" "form workspace: directory re-enabled when off"
    local rc=0
    _form_output >/dev/null 2>&1 || rc=$?
    assert_eq "1" "$rc" "form workspace: off → missing directory rejected again"

    # Entry point: prefill reaches the fields and the output contract holds
    _form_run() { _form_output; }
    out=$(am_new_session_form "/tmp" "codex" "prefilled task")
    IFS=$'\x1f' read -r _ agent_out task_out flags <<< "$out"
    assert_eq "codex" "$agent_out" "am_new_session_form: prefilled agent"
    assert_eq "prefilled task" "$task_out" "am_new_session_form: prefilled task"
    assert_eq "" "$flags" "am_new_session_form: no flags while workspace is off"
    unset -f _form_run

    unset AM_WORKSPACE_CMD
    teardown_isolated_am_dir

    $SUMMARY_MODE || echo ""
}

run_form_tests() {
    _run_test test_form_core
    _run_test test_form_workspace
    _run_test test_form_loop
    _run_test test_form_modes
}

if [[ -z "${_AM_TEST_RUNNER:-}" ]]; then
    set -uo pipefail
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helpers.sh"
    check_deps
    run_form_tests
    test_report
fi
