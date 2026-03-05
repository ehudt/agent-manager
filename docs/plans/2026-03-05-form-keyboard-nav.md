# Form Keyboard Navigation Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the ad-hoc key handling in `lib/form.sh` with a two-mode model (Navigate / Edit) that gives every key one unambiguous meaning, adds directory suggestion scrolling, and adds a `[ Create ]` submit row.

**Architecture:** Add a `_FORM_MODE` variable (`navigate` or `edit`). Split `_form_process_key` into `_form_process_key_navigate` and `_form_process_key_edit`. Track a directory suggestion highlight index `_FORM_DIR_HIGHLIGHT`. Add a `submit` pseudo-field at the end of `FORM_FIELDS`. Update rendering to show mode indicators. Update tests to cover both modes.

**Tech Stack:** Bash, ANSI escape sequences (pre-cached), `/dev/tty` for I/O.

**Design doc:** `docs/plans/2026-03-05-form-keyboard-nav-design.md`

---

### Task 1: Add mode state and submit pseudo-field

**Files:**
- Modify: `lib/form.sh:21-35` (state variables)
- Modify: `lib/form.sh:39-84` (`_form_init`)
- Test: `tests/test_all.sh`

**Step 1: Write the failing tests**

Add a new test function `test_form_modes` in `tests/test_all.sh` (after `test_form_loop`, before `main`). Add `test_form_modes` to the `main` function's test call list.

```bash
test_form_modes() {
    echo "=== Testing form mode state ==="

    source "$LIB_DIR/utils.sh"
    set +u
    source "$LIB_DIR/config.sh"
    source "$LIB_DIR/tmux.sh"
    source "$LIB_DIR/registry.sh"
    source "$LIB_DIR/agents.sh"
    source "$LIB_DIR/form.sh"
    set -u

    _form_init "/tmp" "claude" "" "new" "false" "false" "false" "" "true"

    # Mode starts as navigate
    assert_eq "navigate" "$_FORM_MODE" "mode: starts as navigate"

    # Last field is submit pseudo-field
    local last_idx=$(( ${#FORM_FIELDS[@]} - 1 ))
    assert_eq "submit" "${FORM_FIELDS[$last_idx]}" "mode: last field is submit"
    assert_eq "submit" "${FORM_TYPES[submit]}" "mode: submit field type is submit"

    # Dir highlight starts at 0
    assert_eq "0" "$_FORM_DIR_HIGHLIGHT" "mode: dir highlight starts at 0"

    echo ""
}
```

**Step 2: Run tests to verify they fail**

Run: `bash ./tests/test_all.sh > /tmp/test_out.txt 2>&1; grep -E "FAIL|PASS" /tmp/test_out.txt | tail -10`
Expected: FAIL for the 3 new assertions (variables don't exist yet)

**Step 3: Implement mode state and submit field**

In `lib/form.sh`, add these state variables after the existing declarations (around line 28):

```bash
# Mode: "navigate" or "edit"
_FORM_MODE="navigate"

# Directory suggestion highlight index (used in edit mode)
_FORM_DIR_HIGHLIGHT=0
```

In `_form_init`, after resetting existing state, add:

```bash
_FORM_MODE="navigate"
_FORM_DIR_HIGHLIGHT=0
```

At the end of `_form_init` (after the worktree fields block), add the submit pseudo-field:

```bash
# Submit button (always last)
_form_add_field "submit" "Create" "submit" ""
```

**Step 4: Run tests to verify they pass**

Run: `bash ./tests/test_all.sh > /tmp/test_out.txt 2>&1; grep -E "FAIL|PASS" /tmp/test_out.txt | tail -10`
Expected: All new tests PASS

**Step 5: Commit**

```bash
git add lib/form.sh tests/test_all.sh
git commit -m "feat: add form mode state, dir highlight, submit pseudo-field"
```

---

### Task 2: Split key dispatch into Navigate and Edit handlers

**Files:**
- Modify: `lib/form.sh:295-337` (`_form_process_key`)
- Test: `tests/test_all.sh`

**Step 1: Write the failing tests**

Add to `test_form_modes` (append before the closing `echo ""`):

```bash
    echo ""
    echo "=== Testing navigate mode key dispatch ==="

    _form_init "/tmp" "claude" "" "new" "false" "false" "false" "" "true"

    # In navigate mode, Enter on text field enters edit mode
    FORM_CURSOR=2  # task (text field)
    _form_process_key $'\n'
    assert_eq "continue" "$FORM_KEY_RESULT" "nav: enter on text field returns continue"
    assert_eq "edit" "$_FORM_MODE" "nav: enter on text field enters edit mode"

    # Reset
    _FORM_MODE="navigate"

    # In navigate mode, Enter on checkbox toggles it
    FORM_CURSOR=4  # yolo
    FORM_VALUES[yolo]="false"
    _form_process_key $'\n'
    assert_eq "continue" "$FORM_KEY_RESULT" "nav: enter on checkbox returns continue"
    assert_eq "true" "${FORM_VALUES[yolo]}" "nav: enter on checkbox toggles"
    assert_eq "navigate" "$_FORM_MODE" "nav: enter on checkbox stays in navigate"

    # In navigate mode, Enter on select cycles it
    _FORM_MODE="navigate"
    FORM_CURSOR=3  # mode (select)
    FORM_VALUES[mode]="new"
    _form_process_key $'\n'
    assert_eq "continue" "$FORM_KEY_RESULT" "nav: enter on select returns continue"
    assert_eq "resume" "${FORM_VALUES[mode]}" "nav: enter on select cycles"
    assert_eq "navigate" "$_FORM_MODE" "nav: enter on select stays in navigate"

    # In navigate mode, Enter on submit returns submit
    _FORM_MODE="navigate"
    local last_idx=$(( ${#FORM_FIELDS[@]} - 1 ))
    FORM_CURSOR=$last_idx
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

    echo ""
    echo "=== Testing edit mode key dispatch ==="

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

    echo ""
```

**Step 2: Run tests to verify they fail**

Run: `bash ./tests/test_all.sh > /tmp/test_out.txt 2>&1; grep "FAIL" /tmp/test_out.txt | head -5`
Expected: Multiple failures (old dispatch doesn't know about modes)

**Step 3: Rewrite `_form_process_key`**

Replace `_form_process_key` (and add two new functions) in `lib/form.sh`:

```bash
# Process a single keystroke. Sets FORM_KEY_RESULT to "continue", "submit", or "cancel".
# Must be called in current shell (not a subshell) so mutations take effect.
# Dispatches to mode-specific handler based on _FORM_MODE.
FORM_KEY_RESULT=""
_form_process_key() {
    local key="$1"
    local extra="${2:-__unset__}"

    if [[ "$_FORM_MODE" == "edit" ]]; then
        _form_process_key_edit "$key" "$extra"
    else
        _form_process_key_navigate "$key" "$extra"
    fi
}

# Navigate mode: move between fields, toggle/cycle, enter edit mode
_form_process_key_navigate() {
    local key="$1"
    local extra="$2"

    case "$key" in
        $'\n'|"")
            local name="${FORM_FIELDS[$FORM_CURSOR]}"
            local type="${FORM_TYPES[$name]}"
            case "$type" in
                text|directory)
                    _FORM_MODE="edit"
                    FORM_KEY_RESULT="continue"
                    ;;
                checkbox)
                    _form_handle_space
                    FORM_KEY_RESULT="continue"
                    ;;
                select)
                    _form_handle_space
                    FORM_KEY_RESULT="continue"
                    ;;
                submit)
                    FORM_KEY_RESULT="submit"
                    ;;
            esac
            ;;
        $'\x1b')
            if [[ "$extra" == "__unset__" || -z "$extra" ]]; then
                FORM_KEY_RESULT="cancel"
            else
                case "$extra" in
                    "[A") _form_handle_up; FORM_KEY_RESULT="continue" ;;
                    "[B") _form_handle_down; FORM_KEY_RESULT="continue" ;;
                    *) FORM_KEY_RESULT="continue" ;;
                esac
            fi
            ;;
        " ")
            _form_handle_space
            FORM_KEY_RESULT="continue"
            ;;
        $'\x13')
            # Ctrl-S: submit from anywhere
            FORM_KEY_RESULT="submit"
            ;;
        *)
            # Ignore all other keys in navigate mode
            FORM_KEY_RESULT="continue"
            ;;
    esac
}

# Edit mode: type into current field, scroll directory suggestions
_form_process_key_edit() {
    local key="$1"
    local extra="$2"

    case "$key" in
        $'\n'|"")
            # Exit edit mode
            _FORM_MODE="navigate"
            FORM_KEY_RESULT="continue"
            ;;
        $'\x1b')
            if [[ "$extra" == "__unset__" || -z "$extra" ]]; then
                # Esc: exit edit mode (not cancel)
                _FORM_MODE="navigate"
                FORM_KEY_RESULT="continue"
            else
                local name="${FORM_FIELDS[$FORM_CURSOR]}"
                local type="${FORM_TYPES[$name]}"
                case "$extra" in
                    "[A")
                        # Up: scroll directory suggestions
                        if [[ "$type" == "directory" && $_FORM_DIR_HIGHLIGHT -gt 0 ]]; then
                            ((_FORM_DIR_HIGHLIGHT--))
                        fi
                        FORM_KEY_RESULT="continue"
                        ;;
                    "[B")
                        # Down: scroll directory suggestions
                        if [[ "$type" == "directory" ]]; then
                            local max=$(( ${#_FORM_DIR_FILTERED[@]} - 1 ))
                            [[ $max -lt 0 ]] && max=0
                            if [[ $_FORM_DIR_HIGHLIGHT -lt $max ]]; then
                                ((_FORM_DIR_HIGHLIGHT++))
                            fi
                        fi
                        FORM_KEY_RESULT="continue"
                        ;;
                    *) FORM_KEY_RESULT="continue" ;;
                esac
            fi
            ;;
        " ")
            # Space types a literal space in edit mode
            _form_handle_char " "
            FORM_KEY_RESULT="continue"
            ;;
        $'\x7f'|$'\b')
            _form_handle_backspace
            FORM_KEY_RESULT="continue"
            ;;
        $'\t')
            _form_handle_tab
            FORM_KEY_RESULT="continue"
            ;;
        *)
            if [[ "$key" =~ [[:print:]] ]]; then
                _form_handle_char "$key"
            fi
            FORM_KEY_RESULT="continue"
            ;;
    esac
}
```

**Step 4: Run tests to verify they pass**

Run: `bash ./tests/test_all.sh > /tmp/test_out.txt 2>&1; grep -E "FAIL|Results:" /tmp/test_out.txt`
Expected: All tests PASS (both new mode tests and old dispatch tests)

**Note:** Some old tests in `test_form_loop` call `_form_process_key` and expect the old behavior. These need updating:
- The Enter test (`_form_process_key $'\n'`) currently expects `submit`. With modes, Enter on task field (FORM_CURSOR=2) now enters edit mode. Fix: set FORM_CURSOR to the submit field index, or change to test Ctrl-S.
- The char test (`_form_process_key "H"`) currently expects `FORM_VALUES[task]="H"`. In navigate mode, typing is now ignored. Fix: set `_FORM_MODE="edit"` first.
- The Space test works unchanged (space still toggles in navigate mode).
- The Tab test works unchanged.
- The Esc test currently expects `cancel`. In navigate mode, bare Esc still cancels. This is fine.

Update the relevant lines in `test_form_loop`:

```bash
    # Regular char on text field — only works in edit mode now
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
    assert_eq "submit" "$FORM_KEY_RESULT" "dispatch: enter on submit returns submit"
```

**Step 5: Commit**

```bash
git add lib/form.sh tests/test_all.sh
git commit -m "feat: split key dispatch into navigate/edit mode handlers"
```

---

### Task 3: Directory suggestion highlight scrolling

**Files:**
- Modify: `lib/form.sh` (`_form_handle_tab`, `_form_handle_char`, `_form_draw`)
- Test: `tests/test_all.sh`

**Step 1: Write the failing tests**

Add to `test_form_modes` (append before the closing `echo ""`):

```bash
    echo ""
    echo "=== Testing directory highlight scrolling ==="

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
    _FORM_DIR_HIGHLIGHT=1
    _form_handle_tab
    assert_eq "/home/user/project2" "${FORM_VALUES[directory]}" "dir scroll: tab accepts highlighted"

    # Typing resets highlight to 0
    _FORM_DIR_HIGHLIGHT=2
    _form_handle_char "x"
    assert_eq "0" "$_FORM_DIR_HIGHLIGHT" "dir scroll: typing resets highlight"

    echo ""
```

**Step 2: Run tests to verify they fail**

Run: `bash ./tests/test_all.sh > /tmp/test_out.txt 2>&1; grep "FAIL" /tmp/test_out.txt`
Expected: "tab accepts highlighted" fails (currently always takes index 0), "typing resets highlight" fails

**Step 3: Implement highlight tracking**

In `_form_handle_tab`, change to use `_FORM_DIR_HIGHLIGHT` instead of always taking index 0:

```bash
_form_handle_tab() {
    local name="${FORM_FIELDS[$FORM_CURSOR]}"
    local type="${FORM_TYPES[$name]}"

    if [[ "$type" == "directory" ]]; then
        local query="${FORM_VALUES[$name]}"
        _form_filter_dir_suggestions "$query" "$_FORM_DIR_SUGGESTION_LINES"
        if [[ ${#_FORM_DIR_FILTERED[@]} -gt 0 ]]; then
            local idx=$_FORM_DIR_HIGHLIGHT
            [[ $idx -ge ${#_FORM_DIR_FILTERED[@]} ]] && idx=0
            local entry="${_FORM_DIR_FILTERED[$idx]}"
            FORM_VALUES[$name]="${entry%%$'\t'*}"
        fi
    fi
}
```

In `_form_handle_char`, reset highlight when typing on directory field:

```bash
_form_handle_char() {
    local ch="$1"
    local name="${FORM_FIELDS[$FORM_CURSOR]}"
    local type="${FORM_TYPES[$name]}"

    case "$type" in
        text|directory)
            FORM_VALUES[$name]+="$ch"
            [[ "$type" == "directory" ]] && _FORM_DIR_HIGHLIGHT=0
            ;;
    esac
}
```

Also reset highlight in `_form_handle_backspace` for directory:

```bash
_form_handle_backspace() {
    local name="${FORM_FIELDS[$FORM_CURSOR]}"
    local type="${FORM_TYPES[$name]}"

    case "$type" in
        text|directory)
            local val="${FORM_VALUES[$name]}"
            if [[ -n "$val" ]]; then
                FORM_VALUES[$name]="${val%?}"
                [[ "$type" == "directory" ]] && _FORM_DIR_HIGHLIGHT=0
            fi
            ;;
    esac
}
```

**Step 4: Update `_form_draw` to use `_FORM_DIR_HIGHLIGHT`**

In the directory suggestions rendering section of `_form_draw`, change the highlight condition from `$si -eq 0` to `$si -eq $_FORM_DIR_HIGHLIGHT`:

```bash
                if [[ "$dir_focused" == "true" && $si -eq $_FORM_DIR_HIGHLIGHT ]]; then
```

**Step 5: Run tests to verify they pass**

Run: `bash ./tests/test_all.sh > /tmp/test_out.txt 2>&1; grep -E "FAIL|Results:" /tmp/test_out.txt`
Expected: All tests PASS

**Step 6: Commit**

```bash
git add lib/form.sh tests/test_all.sh
git commit -m "feat: directory suggestion scrolling with highlight tracking"
```

---

### Task 4: Render mode indicators and submit row

**Files:**
- Modify: `lib/form.sh` (`_form_render_field`, `_form_draw_header`)

**Step 1: Update `_form_render_field` for mode and submit type**

The prefix indicator changes based on mode:
- Navigate, focused: `> `
- Edit, focused: `» ` (right-pointing double angle, U+00BB)
- Not focused: `  `

Add rendering for the `submit` field type. In `_form_render_field`, add to the display case:

```bash
        submit)
            display="[ Create ]"
            ;;
```

Update the prefix logic:

```bash
    local prefix="  "
    if [[ "$focused" == "true" ]]; then
        if [[ "$_FORM_MODE" == "edit" ]]; then
            prefix="» "
        else
            prefix="> "
        fi
    fi
```

**Step 2: Update header help text**

In `_form_draw_header`, update the help line to reflect the new model:

```bash
    printf '  ↑↓: move  Enter: edit/toggle  Space: toggle  Ctrl-S: create  Esc: back/cancel%s\n' "${_FORM_EL}" > /dev/tty
```

**Step 3: Run tests to verify nothing breaks**

Run: `bash ./tests/test_all.sh > /tmp/test_out.txt 2>&1; grep -E "FAIL|Results:" /tmp/test_out.txt`
Expected: All tests PASS

**Step 4: Commit**

```bash
git add lib/form.sh
git commit -m "feat: mode indicators, submit row, updated help text"
```

---

### Task 5: Update existing tests for new behavior

**Files:**
- Modify: `tests/test_all.sh`

**Context:** Some existing tests in `test_form_loop` and `test_form_core` may break due to:
1. The submit pseudo-field changes field count (affects cursor bounds tests)
2. `_form_handle_space` is now only called in navigate mode
3. Enter behavior changed (mode-dependent)
4. Char handling only works in edit mode

**Step 1: Run full test suite and identify all failures**

Run: `bash ./tests/test_all.sh > /tmp/test_out.txt 2>&1; grep "FAIL" /tmp/test_out.txt`

**Step 2: Fix each failure**

For each failing test, adjust it to work with the new mode system. Key patterns:
- Tests that call `_form_handle_char` directly still work (they bypass dispatch)
- Tests that use `_form_process_key` need `_FORM_MODE` set correctly
- Tests that count fields need to account for the `submit` field
- The `_form_handle_down` bounds test needs updating (max is now +1 for submit)

**Step 3: Run tests to verify all pass**

Run: `bash ./tests/test_all.sh > /tmp/test_out.txt 2>&1; grep -E "FAIL|Results:" /tmp/test_out.txt`
Expected: All tests PASS, 0 failures

**Step 4: Commit**

```bash
git add tests/test_all.sh
git commit -m "test: update existing form tests for two-mode navigation"
```

---

### Task 6: Manual testing and edge cases

**Step 1: Enable the new form**

```bash
./am config set new_form true
```

**Step 2: Test the full flow**

Open `am` and press Ctrl-N to open the new session form. Verify:

1. Form opens in Navigate mode
2. Up/Down moves between fields (including submit row at bottom)
3. Enter on Directory field enters Edit mode (prefix changes to `»`)
4. In Edit mode, typing filters directory suggestions
5. Up/Down in directory Edit mode scrolls the cyan highlight through suggestions
6. Tab accepts the highlighted suggestion
7. Enter exits Edit mode back to Navigate
8. Space toggles checkboxes and cycles selects in Navigate mode
9. Typing is ignored in Navigate mode (no stray characters)
10. Esc in Edit mode → Navigate mode
11. Esc in Navigate mode → cancels form
12. Ctrl-S submits from anywhere
13. Enter on `[ Create ]` row submits
14. Spaces can be typed in Task field while in Edit mode

**Step 3: Fix any issues found**

**Step 4: Commit fixes if any**

```bash
git add lib/form.sh tests/test_all.sh
git commit -m "fix: form keyboard nav edge cases from manual testing"
```
