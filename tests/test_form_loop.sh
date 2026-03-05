#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
LIB_DIR="$PROJECT_DIR/lib"

TESTS_RUN=0; TESTS_PASSED=0; TESTS_FAILED=0
RED='\033[0;31m'; GREEN='\033[0;32m'; RESET='\033[0m'
assert_eq() {
    local expected="$1" actual="$2" msg="${3:-}"
    ((TESTS_RUN++))
    if [[ "$expected" == "$actual" ]]; then
        echo -e "${GREEN}PASS${RESET}: $msg"; ((TESTS_PASSED++))
    else
        echo -e "${RED}FAIL${RESET}: $msg"; echo "  Expected: '$expected'"; echo "  Actual: '$actual'"; ((TESTS_FAILED++))
    fi
}
assert_contains() {
    local haystack="$1" needle="$2" msg="${3:-}"
    ((TESTS_RUN++))
    if [[ "$haystack" == *"$needle"* ]]; then
        echo -e "${GREEN}PASS${RESET}: $msg"; ((TESTS_PASSED++))
    else
        echo -e "${RED}FAIL${RESET}: $msg"; echo "  String: '$haystack'"; echo "  Does not contain: '$needle'"; ((TESTS_FAILED++))
    fi
}

# Parse tab-delimited output using cut (read collapses empty fields)
_parse_field() {
    local output="$1" field="$2"
    printf '%s' "$output" | cut -d$'\t' -f"$field"
}

source "$LIB_DIR/utils.sh"
set +u
source "$LIB_DIR/config.sh"
source "$LIB_DIR/tmux.sh"
source "$LIB_DIR/registry.sh"
source "$LIB_DIR/agents.sh"
source "$LIB_DIR/form.sh"
set -u

echo "=== Testing form keystroke dispatch ==="

_form_init "/tmp" "claude" "" "new" "false" "false" "false" "" "true"

# Regular char on text field
FORM_CURSOR=2  # task
_form_process_key "H"
assert_eq "continue" "$FORM_KEY_RESULT" "dispatch: char returns continue"
assert_eq "H" "${FORM_VALUES[task]}" "dispatch: char is applied"

# Enter returns submit
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

# Tab
_form_process_key $'\t'
assert_eq "tab" "$FORM_KEY_RESULT" "dispatch: tab returns tab"

echo ""
echo "=== Testing form output contract ==="

_form_init "/tmp" "claude" "fix bugs" "new" "true" "false" "false" "" "true"

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

echo ""
echo "Results: $TESTS_PASSED/$TESTS_RUN passed"
[[ $TESTS_FAILED -gt 0 ]] && exit 1
echo "All tests passed!"
