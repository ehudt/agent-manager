#!/usr/bin/env bash
# tests/test_fzf.sh - Tests for lib/fzf.sh

test_fzf_helpers() {
    $SUMMARY_MODE || echo "=== Testing fzf helpers ==="

    source "$LIB_DIR/utils.sh"
    set +u
    source "$LIB_DIR/config.sh"
    source "$LIB_DIR/tmux.sh"
    source "$LIB_DIR/registry.sh"
    source "$LIB_DIR/agents.sh"
    source "$LIB_DIR/fzf.sh"
    set -u

    local first_agent
    first_agent=$(fzf_agent_options "codex" | head -n1)
    assert_eq "codex" "$first_agent" "fzf helpers: default agent listed first"

    local first_mode
    first_mode=$(fzf_mode_options "true" | head -n1)
    assert_contains "$first_mode" "--yolo" "fzf helpers: yolo default listed first"

    first_mode=$(fzf_mode_options "false" | head -n1)
    assert_eq "New session" "$first_mode" "fzf helpers: safe default listed first"

    # Updated form rows call with sandbox params
    local worktree_rows
    worktree_rows=$(_new_session_form_rows "/tmp/project" "gemini" "" "new" "false" "false" "true" "my-wt" "true")
    assert_contains "$worktree_rows" $'worktree_enabled\tWorktree\t<unsupported>' \
        "fzf helpers: unsupported agent marks worktree as unavailable"

    # No submit row anymore
    local submit_check
    submit_check=$(echo "$worktree_rows" | grep "^submit" || true)
    assert_eq "" "$submit_check" "fzf helpers: no submit row in form"

    # Sandbox row appears in form
    local sandbox_rows
    sandbox_rows=$(_new_session_form_rows "/tmp/project" "claude" "" "new" "false" "false" "false" "" "true")
    assert_contains "$sandbox_rows" $'sandbox\tSandbox' \
        "fzf helpers: sandbox row present"

    # Sandbox disabled when docker unavailable
    local sandbox_disabled_rows
    sandbox_disabled_rows=$(_new_session_form_rows "/tmp/project" "claude" "" "new" "false" "false" "false" "" "false")
    assert_contains "$sandbox_disabled_rows" "[disabled]" \
        "fzf helpers: sandbox disabled without docker"

    # Sandbox enabled toggle
    local sandbox_enabled_rows
    sandbox_enabled_rows=$(_new_session_form_rows "/tmp/project" "claude" "" "new" "false" "true" "false" "" "true")
    assert_contains "$sandbox_enabled_rows" $'sandbox\tSandbox\t[x]' \
        "fzf helpers: sandbox enabled shows [x]"

    $SUMMARY_MODE || echo ""
}

test_annotated_directories() {
    $SUMMARY_MODE || echo ""
    $SUMMARY_MODE || echo "=== Annotated Directory Tests ==="

    if ! command -v jq &>/dev/null; then
        skip_test "annotated directory tests (jq not installed)"
        echo ""
        return
    fi

    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/registry.sh"

    # Need fzf.sh helpers but it requires fzf + tmux + agents.sh
    # Source dependencies in the right order
    if ! command -v tmux &>/dev/null || ! command -v fzf &>/dev/null; then
        skip_test "annotated directory tests (tmux or fzf not installed)"
        echo ""
        return
    fi

    source "$LIB_DIR/tmux.sh"
    set +u; source "$LIB_DIR/agents.sh"; set -u
    source "$LIB_DIR/fzf.sh"

    export AM_DIR=$(mktemp -d)
    export AM_REGISTRY="$AM_DIR/sessions.json"
    am_init

    local git_dir non_git_dir
    git_dir=$(mktemp -d)
    non_git_dir=$(mktemp -d)
    git -C "$git_dir" init -q -b picker-branch
    git -C "$git_dir" -c user.name="test" -c user.email="test@test" commit --allow-empty -m "init" -q

    # Test _annotate_directory with current git branch
    local annotation
    annotation=$(_annotate_directory "$git_dir")
    assert_eq " picker-branch" "$annotation" "annotate: shows current git branch"

    # Test _annotate_directory with non-git directory
    annotation=$(_annotate_directory "$non_git_dir")
    assert_eq "" "$annotation" "annotate: empty for non-git directory"

    # Test _strip_annotation with tab-separated line
    local stripped
    stripped=$(_strip_annotation "$git_dir	picker-branch")
    assert_eq "$git_dir" "$stripped" "strip: extracts path from annotated line"

    # Test _strip_annotation with plain path
    stripped=$(_strip_annotation "/tmp/plain-path")
    assert_eq "/tmp/plain-path" "$stripped" "strip: handles plain path"

    rm -rf "$git_dir" "$non_git_dir"
    rm -rf "$AM_DIR"

    $SUMMARY_MODE || echo ""
}

run_fzf_tests() {
    _run_test test_fzf_helpers
    _run_test test_annotated_directories
}

if [[ -z "${_AM_TEST_RUNNER:-}" ]]; then
    set -uo pipefail
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helpers.sh"
    check_deps
    run_fzf_tests
    test_report
fi
