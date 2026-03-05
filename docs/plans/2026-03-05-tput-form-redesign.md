# New Session Form Redesign: tput-based Form

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the fzf-based new-session form with a custom tput/ANSI form that supports inline text editing and an embedded fzf directory picker, gated behind a feature flag for safe rollout.

**Architecture:** New file `lib/form.sh` implements a terminal form using tput cursor control and `read -rsn1` keystroke handling. The directory field embeds fzf as a dropdown subprocess. All other fields use native terminal I/O (text input, select cycling, checkbox toggling). A config key `new_form` (default: `false`) gates which implementation is used. The new form has the same function signature and output format as the existing `fzf_new_session_form()`.

**Tech Stack:** bash, tput, ANSI escape sequences, fzf (directory picker only)

---

### Task 1: Add `new_form` feature flag to config

**Files:**
- Modify: `lib/config.sh`

**Step 1: Write the failing test**

Add to `tests/test_all.sh` inside a new `test_new_form_flag()` function:

```bash
test_new_form_flag() {
    echo "=== Testing new_form feature flag ==="

    source "$LIB_DIR/utils.sh"
    set +u
    source "$LIB_DIR/config.sh"
    set -u

    # Default is false
    local result
    am_new_form_enabled && result="true" || result="false"
    assert_eq "false" "$result" "new_form: default is false"

    # Env override works
    AM_NEW_FORM=true am_new_form_enabled && result="true" || result="false"
    assert_eq "true" "$result" "new_form: env override works"

    # Config key alias resolves
    local key
    key=$(am_config_key_alias "new-form")
    assert_eq "new_form" "$key" "new_form: key alias resolves"

    # Validation accepts boolean
    am_config_value_is_valid "new_form" "true" && result="true" || result="false"
    assert_eq "true" "$result" "new_form: validation accepts boolean"

    echo ""
}
```

**Step 2: Run test to verify it fails**

Run: `./tests/test_all.sh 2>&1 | tail -20`
Expected: FAIL — `am_new_form_enabled` not defined

**Step 3: Implement the feature flag**

In `lib/config.sh`:

1. Add `am_new_form_enabled()` function (same pattern as `am_default_yolo_enabled`):
```bash
am_new_form_enabled() {
    if [[ -n "${AM_NEW_FORM:-}" ]]; then
        am_bool_is_true "${AM_NEW_FORM,,}"
        return $?
    fi
    local configured
    configured=$(am_config_get "new_form")
    am_bool_is_true "${configured,,}"
}
```

2. Add `new_form` to `am_config_key_alias()`:
```bash
        new-form|new_form) echo "new_form" ;;
```

3. Add `new_form` to `am_config_key_type()`:
```bash
        new_form) echo "boolean" ;;
```

4. Add `new_form` to `am_config_value_is_valid()` — it's already covered by the `default_yolo|default_sandbox|stream_logs` case. Extend that:
```bash
        default_yolo|default_sandbox|stream_logs|new_form)
```

5. Add to `am_config_print()`:
```bash
    local new_form_value
    if am_new_form_enabled; then
        new_form_value=true
    else
        new_form_value=false
    fi
    # ... in the cat block:
    echo "new_form=$new_form_value"
```

**Step 4: Wire up test and run**

Add `test_new_form_flag` to the test runner list in `tests/test_all.sh` (after `test_fzf_helpers`).

Run: `./tests/test_all.sh 2>&1 | tail -20`
Expected: All tests pass

**Step 5: Commit**

```bash
git add lib/config.sh tests/test_all.sh
git commit -m "feat: add new_form feature flag for form redesign"
```

---

### Task 2: Create `lib/form.sh` with form state and rendering

**Files:**
- Create: `lib/form.sh`

This task creates the form rendering engine — drawing fields, cursor management, field display. No input handling yet.

**Step 1: Write the failing test**

Add `test_form_rendering()` to `tests/test_all.sh`:

```bash
test_form_rendering() {
    echo "=== Testing form rendering ==="

    source "$LIB_DIR/utils.sh"
    set +u
    source "$LIB_DIR/config.sh"
    source "$LIB_DIR/tmux.sh"
    source "$LIB_DIR/registry.sh"
    source "$LIB_DIR/agents.sh"
    source "$LIB_DIR/form.sh"
    set -u

    # Test _form_field_display for each field type
    local display

    # Text field with value
    display=$(_form_field_display "text" "Fix the bug" "" "" "")
    assert_eq "Fix the bug" "$display" "form render: text field shows value"

    # Text field empty
    display=$(_form_field_display "text" "" "" "" "")
    assert_eq "" "$display" "form render: empty text field"

    # Select field
    display=$(_form_field_display "select" "claude" "" "" "")
    assert_eq "< claude >" "$display" "form render: select shows cycling indicator"

    # Checkbox on
    display=$(_form_field_display "checkbox" "true" "" "" "")
    assert_eq "[x]" "$display" "form render: checkbox on"

    # Checkbox off
    display=$(_form_field_display "checkbox" "false" "" "" "")
    assert_eq "[ ]" "$display" "form render: checkbox off"

    # Checkbox disabled
    display=$(_form_field_display "checkbox" "false" "" "true" "")
    assert_eq "[disabled]" "$display" "form render: checkbox disabled"

    # Directory field (just shows path)
    display=$(_form_field_display "directory" "/tmp/project" "" "" "")
    assert_eq "/tmp/project" "$display" "form render: directory shows path"

    echo ""
}
```

**Step 2: Run test to verify it fails**

Run: `./tests/test_all.sh 2>&1 | tail -20`
Expected: FAIL — `lib/form.sh` doesn't exist

**Step 3: Create `lib/form.sh`**

```bash
# form.sh - tput-based new session form
# Alternative to fzf_new_session_form(), gated by new_form config flag.

# Source dependencies if not already loaded
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
[[ -z "$AM_DIR" ]] && source "$SCRIPT_DIR/utils.sh"
[[ "$(type -t am_default_agent)" != "function" ]] && source "$SCRIPT_DIR/config.sh"
[[ "$(type -t agent_supports_worktree)" != "function" ]] && source "$SCRIPT_DIR/agents.sh"

# Field type display formatter
# Usage: _form_field_display <type> <value> <options> <disabled> <label>
_form_field_display() {
    local type="$1"
    local value="$2"
    local options="${3:-}"
    local disabled="${4:-}"
    local label="${5:-}"

    case "$type" in
        text|directory)
            echo "$value"
            ;;
        select)
            echo "< $value >"
            ;;
        checkbox)
            if [[ "$disabled" == "true" ]]; then
                echo "[disabled]"
            elif [[ "$value" == "true" ]]; then
                echo "[x]"
            else
                echo "[ ]"
            fi
            ;;
    esac
}

# Form field definitions: name, label, type, initial_value
# These are populated by _form_init and read by the renderer.
declare -a FORM_FIELDS=()
declare -A FORM_VALUES=()
declare -A FORM_TYPES=()
declare -A FORM_LABELS=()
declare -A FORM_OPTIONS=()
declare -A FORM_DISABLED=()
FORM_CURSOR=0

# Initialize form state
# Usage: _form_init <directory> <agent> <task> <mode> <yolo> <sandbox> <worktree_enabled> <worktree_name> <docker_available>
_form_init() {
    local directory="$1"
    local agent="$2"
    local task="$3"
    local mode="$4"
    local yolo="$5"
    local sandbox="$6"
    local worktree_enabled="$7"
    local worktree_name="$8"
    local docker_available="${9:-true}"

    FORM_FIELDS=()
    FORM_VALUES=()
    FORM_TYPES=()
    FORM_LABELS=()
    FORM_OPTIONS=()
    FORM_DISABLED=()
    FORM_CURSOR=0

    _form_add_field "directory"         "Directory"      "directory"  "$directory"
    _form_add_field "agent"             "Agent"          "select"     "$agent"
    _form_add_field "task"              "Task"           "text"       "$task"
    _form_add_field "mode"              "Mode"           "select"     "$mode"
    _form_add_field "yolo"              "Yolo"           "checkbox"   "$yolo"
    _form_add_field "sandbox"           "Sandbox"        "checkbox"   "$sandbox"

    FORM_OPTIONS[agent]=$(printf '%s\n' "${!AGENT_COMMANDS[@]}" | sort | tr '\n' ',')
    FORM_OPTIONS[mode]="new,resume,continue"

    if [[ "$docker_available" != "true" ]]; then
        FORM_DISABLED[sandbox]="true"
    fi

    if agent_supports_worktree "$agent" || [[ "$worktree_enabled" == "true" ]]; then
        _form_add_field "worktree_enabled" "Worktree" "checkbox" "$worktree_enabled"
        if agent_supports_worktree "$agent"; then
            _form_add_field "worktree_name" "Worktree Name" "text" "$worktree_name"
        fi
        if ! agent_supports_worktree "$agent"; then
            FORM_DISABLED[worktree_enabled]="true"
        fi
    fi
}

_form_add_field() {
    local name="$1" label="$2" type="$3" value="$4"
    FORM_FIELDS+=("$name")
    FORM_LABELS[$name]="$label"
    FORM_TYPES[$name]="$type"
    FORM_VALUES[$name]="$value"
}

# Get the currently selected field name
_form_current_field() {
    echo "${FORM_FIELDS[$FORM_CURSOR]}"
}

# Render a single field line to stdout (no cursor movement — caller positions)
# Usage: _form_render_field <field_name> <focused>
_form_render_field() {
    local name="$1"
    local focused="${2:-false}"
    local label="${FORM_LABELS[$name]}"
    local type="${FORM_TYPES[$name]}"
    local value="${FORM_VALUES[$name]}"
    local disabled="${FORM_DISABLED[$name]:-}"
    local options="${FORM_OPTIONS[$name]:-}"

    local display
    display=$(_form_field_display "$type" "$value" "$options" "$disabled" "$label")

    local prefix="  "
    [[ "$focused" == "true" ]] && prefix="> "

    printf '%s%-14s %s' "$prefix" "$label:" "$display"
}
```

**Step 4: Wire up test and run**

Add `test_form_rendering` to the test runner list (after `test_new_form_flag`). Also source `lib/form.sh` in the test.

Run: `./tests/test_all.sh 2>&1 | tail -20`
Expected: All tests pass

**Step 5: Commit**

```bash
git add lib/form.sh tests/test_all.sh
git commit -m "feat: add form.sh with field state management and rendering"
```

---

### Task 3: Implement form input handling (select cycling, checkbox toggle)

**Files:**
- Modify: `lib/form.sh`

**Step 1: Write the failing test**

Add `test_form_input()` to `tests/test_all.sh`:

```bash
test_form_input() {
    echo "=== Testing form input handling ==="

    source "$LIB_DIR/utils.sh"
    set +u
    source "$LIB_DIR/config.sh"
    source "$LIB_DIR/tmux.sh"
    source "$LIB_DIR/registry.sh"
    source "$LIB_DIR/agents.sh"
    source "$LIB_DIR/form.sh"
    set -u

    _form_init "/tmp/project" "claude" "" "new" "false" "false" "false" "" "true"

    # Select cycling
    FORM_CURSOR=1  # agent field
    _form_handle_space
    local agent_after="${FORM_VALUES[agent]}"
    # Should have cycled to next agent (not claude anymore, since we cycle forward)
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

    echo ""
}
```

**Step 2: Run test to verify it fails**

Run: `./tests/test_all.sh 2>&1 | tail -20`
Expected: FAIL — `_form_handle_space` not defined

**Step 3: Implement input handlers in `lib/form.sh`**

```bash
# Handle space: toggle checkbox or cycle select
_form_handle_space() {
    local name="${FORM_FIELDS[$FORM_CURSOR]}"
    local type="${FORM_TYPES[$name]}"
    local disabled="${FORM_DISABLED[$name]:-}"

    [[ "$disabled" == "true" ]] && return 0

    case "$type" in
        checkbox)
            if [[ "${FORM_VALUES[$name]}" == "true" ]]; then
                FORM_VALUES[$name]="false"
            else
                FORM_VALUES[$name]="true"
            fi
            ;;
        select)
            local options_str="${FORM_OPTIONS[$name]}"
            local -a options
            IFS=',' read -ra options <<< "$options_str"
            local count=${#options[@]}
            local current="${FORM_VALUES[$name]}"
            local i next_idx
            for ((i=0; i<count; i++)); do
                if [[ "${options[$i]}" == "$current" ]]; then
                    next_idx=$(( (i + 1) % count ))
                    FORM_VALUES[$name]="${options[$next_idx]}"
                    return 0
                fi
            done
            # Not found — reset to first
            FORM_VALUES[$name]="${options[0]}"
            ;;
    esac
}

# Handle cursor movement
_form_handle_down() {
    local max=$(( ${#FORM_FIELDS[@]} - 1 ))
    if [[ $FORM_CURSOR -lt $max ]]; then
        ((FORM_CURSOR++))
    fi
}

_form_handle_up() {
    if [[ $FORM_CURSOR -gt 0 ]]; then
        ((FORM_CURSOR--))
    fi
}
```

**Step 4: Run tests**

Run: `./tests/test_all.sh 2>&1 | tail -20`
Expected: All tests pass

**Step 5: Commit**

```bash
git add lib/form.sh tests/test_all.sh
git commit -m "feat: add form input handlers for space/toggle/cycle/navigation"
```

---

### Task 4: Implement text field editing (inline character input)

**Files:**
- Modify: `lib/form.sh`

**Step 1: Write the failing test**

```bash
test_form_text_editing() {
    echo "=== Testing form text editing ==="

    source "$LIB_DIR/utils.sh"
    set +u
    source "$LIB_DIR/config.sh"
    source "$LIB_DIR/tmux.sh"
    source "$LIB_DIR/registry.sh"
    source "$LIB_DIR/agents.sh"
    source "$LIB_DIR/form.sh"
    set -u

    _form_init "/tmp/project" "claude" "" "new" "false" "false" "false" "" "true"

    # Simulate typing into task field
    FORM_CURSOR=2  # task
    _form_handle_char "H"
    _form_handle_char "i"
    assert_eq "Hi" "${FORM_VALUES[task]}" "form text: typing appends chars"

    # Backspace
    _form_handle_backspace
    assert_eq "H" "${FORM_VALUES[task]}" "form text: backspace removes last char"

    # Backspace on empty is safe
    _form_handle_backspace
    _form_handle_backspace
    assert_eq "" "${FORM_VALUES[task]}" "form text: backspace on empty is noop"

    # Typing into select field is ignored
    FORM_CURSOR=1  # agent
    local before="${FORM_VALUES[agent]}"
    _form_handle_char "x"
    assert_eq "$before" "${FORM_VALUES[agent]}" "form text: char ignored on select field"

    echo ""
}
```

**Step 2: Run test to verify it fails**

Run: `./tests/test_all.sh 2>&1 | tail -20`
Expected: FAIL — `_form_handle_char` not defined

**Step 3: Implement in `lib/form.sh`**

```bash
# Handle a printable character: append to text/directory fields
_form_handle_char() {
    local ch="$1"
    local name="${FORM_FIELDS[$FORM_CURSOR]}"
    local type="${FORM_TYPES[$name]}"

    case "$type" in
        text|directory)
            FORM_VALUES[$name]+="$ch"
            ;;
    esac
}

# Handle backspace: remove last character from text/directory fields
_form_handle_backspace() {
    local name="${FORM_FIELDS[$FORM_CURSOR]}"
    local type="${FORM_TYPES[$name]}"

    case "$type" in
        text|directory)
            local val="${FORM_VALUES[$name]}"
            if [[ -n "$val" ]]; then
                FORM_VALUES[$name]="${val%?}"
            fi
            ;;
    esac
}
```

**Step 4: Run tests**

Run: `./tests/test_all.sh 2>&1 | tail -20`
Expected: All tests pass

**Step 5: Commit**

```bash
git add lib/form.sh tests/test_all.sh
git commit -m "feat: add inline text editing to form fields"
```

---

### Task 5: Implement terminal draw loop (tput rendering)

**Files:**
- Modify: `lib/form.sh`

This is the actual terminal rendering engine. It draws the form using tput, reads keystrokes, and dispatches to the handlers from Tasks 3-4. This task is harder to unit test (it's interactive), so we test the wiring via a simulated keystroke sequence.

**Step 1: Write the failing test**

```bash
test_form_keystroke_dispatch() {
    echo "=== Testing form keystroke dispatch ==="

    source "$LIB_DIR/utils.sh"
    set +u
    source "$LIB_DIR/config.sh"
    source "$LIB_DIR/tmux.sh"
    source "$LIB_DIR/registry.sh"
    source "$LIB_DIR/agents.sh"
    source "$LIB_DIR/form.sh"
    set -u

    _form_init "/tmp/project" "claude" "" "new" "false" "false" "false" "" "true"

    # _form_process_key returns: "continue", "submit", "cancel"
    local result

    # Regular char on text field
    FORM_CURSOR=2  # task
    result=$(_form_process_key "H")
    assert_eq "continue" "$result" "dispatch: char returns continue"
    assert_eq "H" "${FORM_VALUES[task]}" "dispatch: char is applied"

    # Enter returns submit
    result=$(_form_process_key $'\n')
    assert_eq "submit" "$result" "dispatch: enter returns submit"

    # Escape returns cancel
    result=$(_form_process_key $'\x1b' "")
    assert_eq "cancel" "$result" "dispatch: escape returns cancel"

    echo ""
}
```

**Step 2: Run test to verify it fails**

Expected: FAIL — `_form_process_key` not defined

**Step 3: Implement `_form_process_key` and `_form_draw` in `lib/form.sh`**

```bash
# Process a single keystroke. Returns "continue", "submit", or "cancel".
# Usage: _form_process_key <key> [extra_seq]
_form_process_key() {
    local key="$1"
    local extra="${2:-__unset__}"

    case "$key" in
        $'\n'|"")
            # Enter: submit form
            echo "submit"
            ;;
        $'\x1b')
            # Escape sequence or plain Esc
            if [[ "$extra" == "__unset__" ]]; then
                # Try to read escape sequence (caller should pass it)
                echo "cancel"
            elif [[ -z "$extra" ]]; then
                echo "cancel"
            else
                # Arrow keys: ESC [ A/B
                case "$extra" in
                    "[A") _form_handle_up; echo "continue" ;;
                    "[B") _form_handle_down; echo "continue" ;;
                    *) echo "continue" ;;
                esac
            fi
            ;;
        " ")
            _form_handle_space
            echo "continue"
            ;;
        $'\x7f'|$'\b')
            _form_handle_backspace
            echo "continue"
            ;;
        $'\t')
            # Tab: trigger directory completion if on directory field
            echo "tab"
            ;;
        *)
            # Printable character
            if [[ "$key" =~ [[:print:]] ]]; then
                _form_handle_char "$key"
            fi
            echo "continue"
            ;;
    esac
}

# Draw the full form to terminal.
# Usage: _form_draw
_form_draw() {
    local cols
    cols=$(tput cols 2>/dev/null || echo 80)

    # Move to top of form area and clear
    tput cup 0 0 2>/dev/null || true
    tput ed 2>/dev/null || true  # Clear to end of screen

    # Header
    printf '\033[1m  New Session\033[0m\n'
    printf '  Enter: create  Space: toggle/cycle  Esc: cancel\n'
    printf '\n'

    # Render each field
    local i name
    for ((i=0; i<${#FORM_FIELDS[@]}; i++)); do
        name="${FORM_FIELDS[$i]}"
        local focused="false"
        [[ $i -eq $FORM_CURSOR ]] && focused="true"
        _form_render_field "$name" "$focused"
        # Clear to end of line (remove previous longer text)
        tput el 2>/dev/null || true
        printf '\n'
    done
}

# Main form loop — reads keystrokes and dispatches.
# Usage: _form_run
# Returns form values on stdout (same format as fzf_new_session_form)
_form_run() {
    # Hide cursor, save terminal state
    tput civis 2>/dev/null || true  # hide cursor
    tput smcup 2>/dev/null || true  # alt screen

    # Trap to restore terminal on exit
    trap '_form_cleanup' EXIT INT TERM

    local result=""
    while true; do
        _form_draw

        # Read one keystroke
        local key=""
        IFS= read -rsn1 key

        # If escape, read possible sequence
        if [[ "$key" == $'\x1b' ]]; then
            local seq=""
            IFS= read -rsn1 -t 0.05 seq || true
            if [[ -n "$seq" ]]; then
                local seq2=""
                IFS= read -rsn1 -t 0.05 seq2 || true
                seq+="$seq2"
            fi
            result=$(_form_process_key "$key" "$seq")
        else
            result=$(_form_process_key "$key")
        fi

        case "$result" in
            submit) break ;;
            cancel)
                _form_cleanup
                return 1
                ;;
            tab)
                # Directory picker popup
                local name="${FORM_FIELDS[$FORM_CURSOR]}"
                if [[ "${FORM_TYPES[$name]}" == "directory" ]]; then
                    _form_cleanup_screen
                    local picked
                    if picked=$(_form_directory_popup "${FORM_VALUES[$name]}"); then
                        [[ -n "$picked" ]] && FORM_VALUES[$name]="$picked"
                    fi
                    tput smcup 2>/dev/null || true
                fi
                ;;
        esac
    done

    _form_cleanup
    _form_output
}

_form_cleanup_screen() {
    tput rmcup 2>/dev/null || true
    tput cnorm 2>/dev/null || true
}

_form_cleanup() {
    _form_cleanup_screen
    trap - EXIT INT TERM
}

# Directory picker popup — delegates to fzf
# Usage: _form_directory_popup <current_path>
_form_directory_popup() {
    local current="$1"

    # Re-use existing fzf directory picker
    export -f _list_directories _annotate_directory _strip_annotation detect_git_branch 2>/dev/null || true

    local initial_list
    initial_list=$(_list_directories "$current" | grep -v '^$')

    local selected
    selected=$(echo "$initial_list" | fzf \
        --ansi \
        --height=12 \
        --layout=reverse \
        --print-query \
        --query="$current" \
        --header="Directory  Tab:complete  Type to filter  Esc:back" \
        --bind="tab:reload(bash -c '_list_directories {q}' | grep -v '^$')+clear-query" \
        --bind="ctrl-u:reload(bash -c '_list_directories \$(dirname {q})' | grep -v '^$')+transform-query(dirname {q})" \
    ) || true

    local query selection
    query=$(echo "$selected" | head -n1)
    selection=$(echo "$selected" | tail -n1)
    selection=$(_strip_annotation "$selection")
    query=$(_strip_annotation "$query")

    [[ -z "$selection" && -n "$query" ]] && selection="$query"
    selection="${selection/#\~/$HOME}"

    if [[ -n "$selection" ]]; then
        echo "$selection"
    else
        echo "$current"
    fi
}

# Format output matching fzf_new_session_form contract:
# directory<TAB>agent<TAB>task<TAB>worktree_name<TAB>flags
_form_output() {
    local directory="${FORM_VALUES[directory]}"
    local agent="${FORM_VALUES[agent]}"
    local task="${FORM_VALUES[task]}"
    local mode="${FORM_VALUES[mode]}"
    local yolo="${FORM_VALUES[yolo]}"
    local sandbox="${FORM_VALUES[sandbox]}"
    local worktree_enabled="${FORM_VALUES[worktree_enabled]:-false}"
    local worktree_name="${FORM_VALUES[worktree_name]:-}"

    # Expand ~
    directory="${directory/#\~/$HOME}"

    # Validate directory
    if [[ -z "$directory" || ! -d "$directory" ]]; then
        log_error "Directory does not exist: ${directory:-<empty>}" >&2
        return 1
    fi

    # Validate agent
    if [[ -z "$agent" || -z "${AGENT_COMMANDS[$agent]:-}" ]]; then
        log_error "Invalid agent type: ${agent:-<empty>}" >&2
        return 1
    fi

    # Build flags
    local flags=""
    [[ "$mode" == "resume" ]] && flags+=" --resume"
    [[ "$mode" == "continue" ]] && flags+=" --continue"
    [[ "$yolo" == "true" ]] && flags+=" --yolo"
    [[ "$sandbox" == "true" ]] && flags+=" --sandbox"

    # Build worktree value
    local worktree=""
    if [[ "$worktree_enabled" == "true" ]] && agent_supports_worktree "$agent"; then
        if [[ -n "$worktree_name" ]]; then
            worktree="$worktree_name"
        else
            worktree="__auto__"
        fi
    fi

    printf '%s\t%s\t%s\t%s\t%s\n' "$directory" "$agent" "$task" "$worktree" "$flags"
}
```

**Step 4: Run tests**

Run: `./tests/test_all.sh 2>&1 | tail -20`
Expected: All tests pass

**Step 5: Commit**

```bash
git add lib/form.sh tests/test_all.sh
git commit -m "feat: add terminal draw loop and keystroke dispatch"
```

---

### Task 6: Wire the feature flag — gate form selection in fzf.sh and am

**Files:**
- Modify: `lib/fzf.sh`
- Modify: `am`

**Step 1: Write the failing test**

```bash
test_form_flag_wiring() {
    echo "=== Testing form flag wiring ==="

    source "$LIB_DIR/utils.sh"
    set +u
    source "$LIB_DIR/config.sh"
    source "$LIB_DIR/tmux.sh"
    source "$LIB_DIR/registry.sh"
    source "$LIB_DIR/agents.sh"
    source "$LIB_DIR/fzf.sh"
    source "$LIB_DIR/form.sh"
    set -u

    # Verify the dispatch function exists
    assert_cmd_succeeds "form wiring: am_new_session_form function exists" \
        bash -c "type am_new_session_form" 2>/dev/null

    echo ""
}
```

Note: We can't easily test interactive form invocation in unit tests. The test verifies the dispatch function exists.

**Step 2: Run test to verify it fails**

Expected: FAIL — `am_new_session_form` not defined

**Step 3: Implement the dispatch**

Add to `lib/form.sh` (at the end):

```bash
# Dispatch function: picks form implementation based on feature flag.
# Same signature and output as fzf_new_session_form().
am_new_session_form() {
    if am_new_form_enabled; then
        local prefill_directory="${1:-.}"
        local prefill_agent="${2:-$(am_default_agent)}"
        local prefill_task="${3:-}"
        local prefill_worktree="${4:-}"
        local prefill_mode_flags="${5:-}"

        local directory="${prefill_directory/#\~/$HOME}"
        local agent="$prefill_agent"
        local task="$prefill_task"
        local mode="new"
        local yolo="false"
        local sandbox="false"
        local worktree_enabled="false"
        local worktree_name=""
        local docker_available="true"
        am_docker_available || docker_available="false"

        # Parse prefill flags
        [[ "$prefill_mode_flags" == *"--resume"* ]] && mode="resume"
        [[ "$prefill_mode_flags" == *"--continue"* ]] && mode="continue"
        if [[ "$prefill_mode_flags" == *"--yolo"* ]]; then
            yolo="true"
        elif am_default_yolo_enabled; then
            yolo="true"
        fi
        if [[ "$prefill_mode_flags" == *"--sandbox"* ]]; then
            sandbox="true"
        elif am_default_sandbox_enabled && [[ "$docker_available" == "true" ]]; then
            sandbox="true"
        fi

        case "$prefill_worktree" in
            ""|false) worktree_enabled="false"; worktree_name="" ;;
            true|__auto__) worktree_enabled="true"; worktree_name="" ;;
            *) worktree_enabled="true"; worktree_name="$prefill_worktree" ;;
        esac

        _form_init "$directory" "$agent" "$task" "$mode" "$yolo" "$sandbox" \
            "$worktree_enabled" "$worktree_name" "$docker_available"
        _form_run
    else
        fzf_new_session_form "$@"
    fi
}
```

In `lib/fzf.sh`, change `fzf_main()` at line 738 to use the dispatch:
```bash
# Change from:
        if ! form_values=$(fzf_new_session_form); then
# To:
        if ! form_values=$(am_new_session_form); then
```

In `am` at line 315, same change:
```bash
# Change from:
        if ! form_values=$(fzf_new_session_form "$directory" "$(am_default_agent)" "$task" "$worktree_name"); then
# To:
        if ! form_values=$(am_new_session_form "$directory" "$(am_default_agent)" "$task" "$worktree_name"); then
```

Also add `source "$AM_LIB_DIR/form.sh"` in `am` after the fzf.sh source (line 135).

**Step 4: Run tests**

Run: `./tests/test_all.sh 2>&1 | tail -20`
Expected: All tests pass. Feature flag is off, so existing fzf form is still the default.

**Step 5: Commit**

```bash
git add lib/form.sh lib/fzf.sh am tests/test_all.sh
git commit -m "feat: wire form feature flag — am_new_session_form dispatches based on new_form config"
```

---

### Task 7: Test form output contract (integration test)

**Files:**
- Modify: `tests/test_all.sh`

This verifies that `_form_output` produces the same tab-delimited format that `cmd_new` and `cmd_list` expect.

**Step 1: Write the test**

```bash
test_form_output_contract() {
    echo "=== Testing form output contract ==="

    source "$LIB_DIR/utils.sh"
    set +u
    source "$LIB_DIR/config.sh"
    source "$LIB_DIR/tmux.sh"
    source "$LIB_DIR/registry.sh"
    source "$LIB_DIR/agents.sh"
    source "$LIB_DIR/form.sh"
    set -u

    # Set up form state
    _form_init "/tmp" "claude" "fix bugs" "new" "true" "false" "false" "" "true"

    # Capture output
    local output
    output=$(_form_output)

    local directory agent task worktree flags
    IFS=$'\t' read -r directory agent task worktree flags <<< "$output"

    assert_eq "/tmp" "$directory" "form output: directory"
    assert_eq "claude" "$agent" "form output: agent"
    assert_eq "fix bugs" "$task" "form output: task"
    assert_eq "" "$worktree" "form output: no worktree"
    assert_contains "$flags" "--yolo" "form output: yolo flag"

    # With worktree
    _form_init "/tmp" "claude" "" "resume" "false" "true" "true" "my-branch" "true"
    output=$(_form_output)
    IFS=$'\t' read -r directory agent task worktree flags <<< "$output"

    assert_eq "my-branch" "$worktree" "form output: worktree name"
    assert_contains "$flags" "--resume" "form output: resume flag"
    assert_contains "$flags" "--sandbox" "form output: sandbox flag"

    # Auto worktree
    _form_init "/tmp" "claude" "" "new" "false" "false" "true" "" "true"
    output=$(_form_output)
    IFS=$'\t' read -r directory agent task worktree flags <<< "$output"
    assert_eq "__auto__" "$worktree" "form output: auto worktree"

    echo ""
}
```

**Step 2: Run test**

Run: `./tests/test_all.sh 2>&1 | tail -20`
Expected: All tests pass

**Step 3: Commit**

```bash
git add tests/test_all.sh
git commit -m "test: add form output contract tests"
```

---

### Task 8: Manual testing and polish

**Files:**
- Possibly modify: `lib/form.sh`

This is the hands-on testing task. No automated test — just interactive verification.

**Step 1: Enable the flag**

```bash
am config set new-form true
```

Or for one-shot: `AM_NEW_FORM=true am new`

**Step 2: Test the form interactively**

- [ ] Form renders with all fields
- [ ] Up/Down navigates between fields
- [ ] Space toggles checkboxes (yolo, sandbox, worktree)
- [ ] Space cycles selects (agent, mode)
- [ ] Typing in task field works inline
- [ ] Backspace works in text fields
- [ ] Tab on directory field opens fzf popup
- [ ] Selecting directory from popup returns to form
- [ ] Enter creates session with correct values
- [ ] Esc cancels cleanly (terminal restored)
- [ ] Terminal is clean after exit (no artifacts, cursor visible)
- [ ] Disabled sandbox shows [disabled] and ignores Space

**Step 3: Fix any issues found**

Address terminal rendering, cursor positioning, or edge cases.

**Step 4: Disable the flag**

```bash
am config set new-form false
```

Verify old form still works unchanged.

**Step 5: Commit any fixes**

```bash
git add lib/form.sh
git commit -m "fix: polish tput form rendering after manual testing"
```

---

## Summary of files

| File | Action |
|------|--------|
| `lib/config.sh` | Add `new_form` flag, alias, type, validation |
| `lib/form.sh` | New file — tput form: state, rendering, input, draw loop, output |
| `lib/fzf.sh` | Change `fzf_new_session_form` call → `am_new_session_form` |
| `am` | Source `form.sh`, change form call → `am_new_session_form` |
| `tests/test_all.sh` | Add tests: flag, rendering, input, text editing, dispatch, output contract |

## Rollback

Set `new_form` to `false` (the default) or `am config unset new-form`. The old fzf form is always available and remains the default path.
