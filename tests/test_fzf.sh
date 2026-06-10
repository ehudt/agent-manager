#!/usr/bin/env bash
# tests/test_fzf.sh - Tests for lib/fzf.sh

test_annotated_directories() {
    $SUMMARY_MODE || echo ""
    $SUMMARY_MODE || echo "=== Annotated Directory Tests ==="

    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/registry.sh"
    source "$LIB_DIR/tmux.sh"
    set +u; source "$LIB_DIR/agents.sh"; set -u
    source "$LIB_DIR/fzf.sh"

    local _tmpdir
    _tmpdir=$(mktemp -d)
    export AM_DIR="$_tmpdir"
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
    _run_test test_annotated_directories
}

if [[ -z "${_AM_TEST_RUNNER:-}" ]]; then
    set -uo pipefail
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helpers.sh"
    check_deps
    run_fzf_tests
    test_report
fi
