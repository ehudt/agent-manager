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
    # Run against a fresh, empty config (no presets, no provider).
    unset AM_DIR_PROVIDER
    setup_isolated_am_dir
    am_config_init

    _form_init "/tmp/project" "claude" ""
    assert_contains "${FORM_OPTIONS[agent]}" "cursor," \
        "form input: cursor is available as an agent"
    assert_not_contains "${FORM_OPTIONS[agent]}" "cursor-agent" \
        "form input: cursor alias is not duplicated"

    # The form is just Directory / Agent / Task (plus Preset when any exist)
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
    # Run against a fresh, empty config (no presets, no provider).
    unset AM_DIR_PROVIDER
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
    local -a launch_agents=("claude" "codex" "cursor" "pi" "opencode")
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
    # Run against a fresh, empty config (no presets, no provider).
    unset AM_DIR_PROVIDER
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

test_form_provider() {
    $SUMMARY_MODE || echo "=== Testing form @spec directories (dir_provider) ==="

    source "$LIB_DIR/utils.sh"
    set +u
    source "$LIB_DIR/config.sh"
    source "$LIB_DIR/tmux.sh"
    source "$LIB_DIR/registry.sh"
    source "$LIB_DIR/agents.sh"
    source "$LIB_DIR/form.sh"
    set -u

    unset AM_DIR_PROVIDER
    setup_isolated_am_dir
    am_config_init
    _form_init "/tmp" "claude" ""
    assert_eq "directory agent task" "${FORM_FIELDS[*]}" "form provider: no extra fields, with or without a provider"

    # Without a provider a @spec is rejected at output with guidance
    FORM_VALUES[directory]="@48351"
    local rc=0 err
    err=$(_form_output 2>&1 >/dev/null) || rc=$?
    assert_eq "1" "$rc" "form provider: @spec rejected without a provider"
    assert_contains "$err" "dir_provider" "form provider: rejection names the config key"
    _form_filter_dir_suggestions "@48" 5
    assert_eq "1" "${#_FORM_DIR_FILTERED[@]}" "form provider: no provider → only the typed spec is offered"
    assert_eq "@48" "${_FORM_DIR_FILTERED[0]%%$'\t'*}" "form provider: the typed spec is the fallback entry"

    # Fake provider: suggestions are provider lines shown as @spec + label
    export FAKE_PROVIDER_DIR
    FAKE_PROVIDER_DIR=$(mktemp -d)
    export AM_DIR_PROVIDER="$TEST_DIR/fake_dir_provider"
    _form_init "/tmp" "claude" ""
    _form_filter_dir_suggestions "@48" 5
    assert_eq "2" "${#_FORM_DIR_FILTERED[@]}" "form provider: provider candidates listed"
    assert_eq "@48351" "${_FORM_DIR_FILTERED[0]%%$'\t'*}" "form provider: candidate spec carries the @"
    assert_eq "PR #48351 fix bbr" "${_FORM_DIR_FILTERED[0]#*$'\t'}" "form provider: provider label is the annotation"
    assert_eq "@48372" "${_FORM_DIR_FILTERED[1]%%$'\t'*}" "form provider: second candidate"

    # Bare @ asks the provider for its defaults; an empty-spec row renders as
    # bare `@` (the provider's default) and stays first so Enter resolves it
    _form_filter_dir_suggestions "@" 5
    assert_eq "@" "${_FORM_DIR_FILTERED[0]%%$'\t'*}" "form provider: bare @ offers the empty spec first"
    assert_eq "new copy on trunk" "${_FORM_DIR_FILTERED[0]#*$'\t'}" "form provider: empty spec keeps its label"
    assert_eq "@trunk" "${_FORM_DIR_FILTERED[1]%%$'\t'*}" "form provider: bare @ lists the provider defaults"

    # No match → the typed spec itself so Enter still resolves it
    _form_filter_dir_suggestions "@brand-new-branch" 5
    assert_eq "1" "${#_FORM_DIR_FILTERED[@]}" "form provider: no match → one fallback entry"
    assert_eq "@brand-new-branch" "${_FORM_DIR_FILTERED[0]%%$'\t'*}" "form provider: fallback keeps the typed spec"

    # Bare `@` (empty partial) is cached like any other partial
    _form_filter_dir_suggestions "@" 5
    assert_eq "2" "${#_FORM_DIR_FILTERED[@]}" "form provider: bare @ lists the provider's default candidates"
    assert_eq "1" "$(grep -c "^suggest $" "$FAKE_PROVIDER_DIR/calls.log")" "form provider: bare @ cached too"

    # Enter on bare `@` keeps `@` (cmd_new resolves the empty spec), never the
    # first branch the provider happens to list
    FORM_VALUES[directory]="@"
    FORM_CURSOR=0
    _FORM_DIR_HIGHLIGHT=0
    _FORM_MODE="edit"
    _form_process_key $'\n'
    assert_eq "submit" "$FORM_KEY_RESULT" "form provider: enter on bare @ submits"
    assert_eq "@" "${FORM_VALUES[directory]}" "form provider: enter on bare @ keeps the empty spec"

    # Cached per partial: a redraw with the same text does not re-run the provider
    local calls_before calls_after
    calls_before=$(grep -c "^suggest 48$" "$FAKE_PROVIDER_DIR/calls.log")
    _form_filter_dir_suggestions "@48" 5
    _form_filter_dir_suggestions "@48" 5
    calls_after=$(grep -c "^suggest 48$" "$FAKE_PROVIDER_DIR/calls.log")
    assert_eq "$calls_before" "$calls_after" "form provider: suggestions cached per partial"
    assert_eq "1" "$calls_before" "form provider: one provider run per distinct partial"

    # A slow provider is cut off at the suggest timeout instead of stalling the form
    local t0 t1 elapsed
    t0=$(perl -MTime::HiRes=time -e 'printf "%.2f\n", time')
    AM_DIR_SUGGEST_TIMEOUT=0.3 _form_filter_dir_suggestions "@slow" 5
    t1=$(perl -MTime::HiRes=time -e 'printf "%.2f\n", time')
    elapsed=$(perl -e 'printf "%d\n", ($ARGV[1] - $ARGV[0]) * 1000' "$t0" "$t1")
    assert_eq "true" "$([[ $elapsed -lt 1500 ]] && echo true || echo false)" \
        "form provider: slow suggest cut off (took ${elapsed}ms, provider sleeps 3s)"
    assert_eq "@slow" "${_FORM_DIR_FILTERED[0]%%$'\t'*}" "form provider: timeout falls back to the typed spec"

    # Tab / Enter accept the highlighted candidate into the field
    FORM_VALUES[directory]="@48"
    FORM_CURSOR=0
    _FORM_DIR_HIGHLIGHT=1
    _form_handle_tab
    assert_eq "@48372" "${FORM_VALUES[directory]}" "form provider: tab accepts the highlighted @spec"
    FORM_VALUES[directory]="@48"
    _FORM_MODE="edit"
    _form_process_key $'\n'
    assert_eq "submit" "$FORM_KEY_RESULT" "form provider: enter on a @spec submits"
    assert_eq "@48351" "${FORM_VALUES[directory]}" "form provider: enter accepts the top candidate"

    # Output passes the @spec through unvalidated (cmd_new resolves it)
    local out dir_out flags
    out=$(_form_output 2>/dev/null)
    IFS=$'\x1f' read -r dir_out _ _ flags <<< "$out"
    assert_eq "@48351" "$dir_out" "form provider: @spec reaches the output untouched"
    assert_eq "" "$flags" "form provider: no flags for a @spec"

    # A plain path is still validated
    FORM_VALUES[directory]="/definitely/not/a/dir"
    rc=0
    _form_output >/dev/null 2>&1 || rc=$?
    assert_eq "1" "$rc" "form provider: missing plain directory still rejected"

    # Entry point: prefill reaches the fields and the output contract holds
    local agent_out task_out
    _form_run() { _form_output; }
    out=$(am_new_session_form "@48351" "codex" "prefilled task")
    IFS=$'\x1f' read -r dir_out agent_out task_out flags <<< "$out"
    assert_eq "@48351" "$dir_out" "am_new_session_form: @spec prefill survives"
    assert_eq "codex" "$agent_out" "am_new_session_form: prefilled agent"
    assert_eq "prefilled task" "$task_out" "am_new_session_form: prefilled task"
    unset -f _form_run

    rm -rf "$FAKE_PROVIDER_DIR"
    unset AM_DIR_PROVIDER FAKE_PROVIDER_DIR
    teardown_isolated_am_dir

    $SUMMARY_MODE || echo ""
}

test_form_line_editing() {
    $SUMMARY_MODE || echo "=== Testing form line editing ==="

    source "$LIB_DIR/utils.sh"
    set +u
    source "$LIB_DIR/config.sh"
    source "$LIB_DIR/tmux.sh"
    source "$LIB_DIR/registry.sh"
    source "$LIB_DIR/agents.sh"
    source "$LIB_DIR/form.sh"
    set -u
    unset AM_DIR_PROVIDER
    setup_isolated_am_dir
    am_config_init

    _form_init "/tmp" "claude" "fix the bug"
    _FORM_OPTIONS_OPEN=true
    _FORM_MODE="edit"
    FORM_CURSOR=2  # task

    # The cursor starts at the end of a prefilled value
    _form_pos_sync
    assert_eq "11" "$_FORM_POS" "line edit: cursor starts at the end"

    # Left arrow + insert lands mid-value
    _form_process_key $'\x1b' "[D"
    _form_process_key $'\x1b' "[D"
    _form_process_key $'\x1b' "[D"
    _form_process_key "X"
    assert_eq "fix the Xbug" "${FORM_VALUES[task]}" "line edit: insert at the cursor"
    assert_eq "9" "$_FORM_POS" "line edit: cursor follows the insert"

    # Backspace deletes before the cursor, Delete at it
    _form_process_key $'\x7f'
    assert_eq "fix the bug" "${FORM_VALUES[task]}" "line edit: backspace before the cursor"
    _form_process_key $'\x1b' "[3~"
    assert_eq "fix the ug" "${FORM_VALUES[task]}" "line edit: delete at the cursor"
    _form_process_key $'\x04'
    assert_eq "fix the g" "${FORM_VALUES[task]}" "line edit: ctrl-d deletes at the cursor"

    # Home / End in every encoding
    local seq
    for seq in "[H" "OH" "[1~" "[7~"; do
        _form_edit end
        _form_process_key $'\x1b' "$seq"
        assert_eq "0" "$_FORM_POS" "line edit: home ($seq)"
    done
    for seq in "[F" "OF" "[4~" "[8~"; do
        _form_edit home
        _form_process_key $'\x1b' "$seq"
        assert_eq "9" "$_FORM_POS" "line edit: end ($seq)"
    done
    _form_process_key $'\x01'
    assert_eq "0" "$_FORM_POS" "line edit: ctrl-a goes home"
    _form_process_key $'\x06'
    assert_eq "1" "$_FORM_POS" "line edit: ctrl-f moves right"
    _form_process_key $'\x02'
    assert_eq "0" "$_FORM_POS" "line edit: ctrl-b moves left"
    _form_process_key $'\x1b' "[D"
    assert_eq "0" "$_FORM_POS" "line edit: left clamps at 0"
    _form_process_key $'\x05'
    assert_eq "9" "$_FORM_POS" "line edit: ctrl-e goes to the end"
    _form_process_key $'\x1b' "[C"
    assert_eq "9" "$_FORM_POS" "line edit: right clamps at the end"

    # Word movement: Alt-B/F, Alt/Ctrl/Cmd-arrows
    FORM_VALUES[task]="one two-three  four"
    _form_pos_sync
    for seq in "b" "[1;3D" "[1;5D" "[1;9D"; do
        _form_edit end
        _form_process_key $'\x1b' "$seq"
        assert_eq "15" "$_FORM_POS" "line edit: word left ($seq)"
    done
    _form_process_key $'\x1b' "b"
    assert_eq "8" "$_FORM_POS" "line edit: word left stops at punctuation"
    for seq in "f" "[1;3C" "[1;5C" "[1;9C"; do
        _form_edit home
        _form_process_key $'\x1b' "$seq"
        assert_eq "3" "$_FORM_POS" "line edit: word right ($seq)"
    done
    _form_process_key $'\x1b' "f"
    assert_eq "7" "$_FORM_POS" "line edit: word right stops at punctuation"

    # Word deletion
    FORM_VALUES[task]="cd ~/code/agent-manager"
    _form_pos_sync
    _form_process_key $'\x1b' $'\x7f'
    assert_eq "cd ~/code/agent-" "${FORM_VALUES[task]}" "line edit: alt-backspace kills one path component"
    _form_process_key $'\x17'
    assert_eq "cd " "${FORM_VALUES[task]}" "line edit: ctrl-w kills back to whitespace"
    FORM_VALUES[task]="alpha beta gamma"
    _form_pos_sync
    _form_edit home
    _form_process_key $'\x1b' "d"
    assert_eq " beta gamma" "${FORM_VALUES[task]}" "line edit: alt-d kills the next word"
    assert_eq "0" "$_FORM_POS" "line edit: alt-d keeps the cursor"

    # Kill to start / end
    FORM_VALUES[task]="alpha beta gamma"
    _form_pos_sync
    _form_process_key $'\x1b' "b"
    _form_process_key $'\x15'
    assert_eq "gamma" "${FORM_VALUES[task]}" "line edit: ctrl-u kills to the start"
    assert_eq "0" "$_FORM_POS" "line edit: ctrl-u leaves the cursor at 0"
    _form_process_key $'\x1b' "f"
    _form_process_key $'\x1b' "b"
    _form_process_key $'\x06'
    _form_process_key $'\x0b'
    assert_eq "g" "${FORM_VALUES[task]}" "line edit: ctrl-k kills to the end"

    # A value replaced from outside puts the cursor back at its end
    _form_edit home
    FORM_VALUES[task]="replaced"
    _form_process_key "!"
    assert_eq "replaced!" "${FORM_VALUES[task]}" "line edit: outside change resets the cursor to the end"

    # Editing keys never touch a select field
    FORM_CURSOR=1
    FORM_VALUES[agent]="claude"
    _form_process_key $'\x15'
    _form_process_key $'\x1b' "[1;3D"
    assert_eq "claude" "${FORM_VALUES[agent]}" "line edit: select field untouched"

    # Directory field: cursor keys move within the text, edits reset the highlight
    _form_init "/tmp" "claude" ""
    FORM_VALUES[directory]="/tmp/pro"
    _FORM_DIR_SUGGESTIONS=("/tmp/project1" "/tmp/project2")
    _FORM_DIR_SUGGESTIONS_LOADED=true
    _FORM_DIR_HIGHLIGHT=1
    _form_process_key $'\x1b' "[D"
    assert_eq "1" "$_FORM_DIR_HIGHLIGHT" "line edit: cursor move keeps the suggestion highlight"
    _form_process_key $'\x1b' $'\x7f'
    assert_eq "/tmp/o" "${FORM_VALUES[directory]}" "line edit: word kill in the directory field"
    assert_eq "0" "$_FORM_DIR_HIGHLIGHT" "line edit: an edit resets the suggestion highlight"

    $SUMMARY_MODE || echo ""
    $SUMMARY_MODE || echo "=== Testing form rendering with a cursor ==="

    _form_init "/tmp" "claude" "abc"
    _FORM_OPTIONS_OPEN=true
    _FORM_MODE="edit"
    FORM_CURSOR=2
    _form_edit left
    _FORM_BUF=""
    _form_render_field "task" "true"
    assert_contains "$_FORM_BUF" "ab"$'\033[7m'"c"$'\033[0m' "render: inverse cell sits on the cursor"

    # A value wider than the field scrolls instead of wrapping
    _FORM_COLS=40   # 22 cells for the value
    FORM_VALUES[task]="0123456789abcdefghijklmnopqrstuvwxyz"
    _form_pos_sync
    _form_value_view "${FORM_VALUES[task]}" "$_FORM_POS" 22
    local plain="${_FORM_VIEW//$'\033[7m'/}"
    plain="${plain//$'\033[0m'/}"
    assert_eq "22" "${#plain}" "render: scrolled view fills the field exactly"
    assert_eq "…" "${plain:0:1}" "render: left marker when the start is hidden"
    assert_contains "$plain" "xyz " "render: cursor end in view"
    _form_edit home
    _form_value_view "${FORM_VALUES[task]}" "$_FORM_POS" 22
    plain="${_FORM_VIEW//$'\033[7m'/}"
    plain="${plain//$'\033[0m'/}"
    assert_eq "0123456789abcdefghijk…" "$plain" "render: home scrolls back, right marker"
    _form_value_view "${FORM_VALUES[task]}" -1 22
    assert_eq "0123456789abcdefghijk…" "$_FORM_VIEW" "render: unfocused long value is cut"

    $SUMMARY_MODE || echo ""
    $SUMMARY_MODE || echo "=== Testing form input reader and paste ==="

    local inp="$AM_DIR/form_input"
    _form_init "/tmp" "claude" ""
    _FORM_OPTIONS_OPEN=true
    _FORM_MODE="edit"
    FORM_CURSOR=2

    # Bracketed paste: inserted at the cursor as text, line breaks flattened,
    # trailing newline dropped, keys inside not interpreted
    FORM_VALUES[task]="ab"
    _form_pos_sync
    _form_edit left
    printf '\033[200~line one\nline\ttwo\x01\n\033[201~' > "$inp"
    exec {_FORM_TTY_FD}<"$inp"
    _form_read_input
    exec {_FORM_TTY_FD}<&-
    assert_eq "aline one line twob" "${FORM_VALUES[task]}" "paste: inserted at the cursor, flattened"
    assert_eq "continue" "$FORM_KEY_RESULT" "paste: does not submit"
    assert_eq "18" "$_FORM_POS" "paste: cursor after the pasted text"

    # An ESC inside the paste is kept as text
    FORM_VALUES[task]=""
    printf '\033[200~a\033b\033[201~' > "$inp"
    exec {_FORM_TTY_FD}<"$inp"
    _form_read_input
    exec {_FORM_TTY_FD}<&-
    assert_eq "ab" "${FORM_VALUES[task]}" "paste: embedded ESC does not end the paste (control chars dropped)"

    # Paste outside edit mode is ignored
    _FORM_MODE="navigate"
    FORM_VALUES[task]=""
    printf '\033[200~xyz\033[201~' > "$inp"
    exec {_FORM_TTY_FD}<"$inp"
    _form_read_input
    exec {_FORM_TTY_FD}<&-
    assert_eq "" "${FORM_VALUES[task]}" "paste: ignored in navigate mode"
    _FORM_MODE="edit"

    # Multi-byte CSI sequences arrive whole
    FORM_VALUES[task]="one two"
    _form_pos_sync
    printf '\033[1;5D' > "$inp"
    exec {_FORM_TTY_FD}<"$inp"
    _form_read_input
    exec {_FORM_TTY_FD}<&-
    assert_eq "4" "$_FORM_POS" "reader: ctrl-left read as one sequence"
    printf '\033[3~' > "$inp"
    exec {_FORM_TTY_FD}<"$inp"
    _form_read_input
    exec {_FORM_TTY_FD}<&-
    assert_eq "one wo" "${FORM_VALUES[task]}" "reader: delete key read as one sequence"
    printf '\033\033[D' > "$inp"
    _form_edit end
    exec {_FORM_TTY_FD}<"$inp"
    _form_read_input
    exec {_FORM_TTY_FD}<&-
    assert_eq "4" "$_FORM_POS" "reader: ESC ESC [D is alt-left"
    printf '\033' > "$inp"
    exec {_FORM_TTY_FD}<"$inp"
    _form_read_input
    exec {_FORM_TTY_FD}<&-
    assert_eq "navigate" "$_FORM_MODE" "reader: lone ESC is escape"
    _FORM_TTY_FD=0

    teardown_isolated_am_dir
    $SUMMARY_MODE || echo ""
}

run_form_tests() {
    _run_test test_form_core
    _run_test test_form_line_editing
    _run_test test_form_provider
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
