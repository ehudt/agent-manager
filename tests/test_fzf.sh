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

    # Callers on the startup hot path can request bare paths and avoid one Git
    # subprocess per suggestion.
    local saved_annotate_directory plain_list
    saved_annotate_directory=$(declare -f _annotate_directory)
    _annotate_directory() { echo " branch"; }
    plain_list=$(_list_directories "" false)
    assert_not_contains "$plain_list" $'\t' "directory list: annotations can be disabled"
    eval "$saved_annotate_directory"

    rm -rf "$git_dir" "$non_git_dir"
    rm -rf "$AM_DIR"

    $SUMMARY_MODE || echo ""
}

test_dir_repo_cache() {
    $SUMMARY_MODE || echo ""
    $SUMMARY_MODE || echo "=== Directory Repo-Scan Cache Tests ==="

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

    local saved_scan
    saved_scan=$(declare -f _dir_repo_scan)
    _dir_repo_scan() { echo "/tmp/scanned-repo"; }

    local cache="$AM_DIR/.dir_repo_cache"

    # Cold cache: returns nothing now (the $() must not hang on the
    # background refresh) and builds the cache for the next open.
    local out i
    out=$(_dir_repo_scan_cached)
    assert_eq "" "$out" "repo cache: cold cache returns nothing"
    for ((i=0; i<40; i++)); do [[ -f "$cache" ]] && break; sleep 0.05; done
    assert_eq "/tmp/scanned-repo" "$(cat "$cache" 2>/dev/null)" \
        "repo cache: background refresh built the cache"

    # Warm cache: served as-is, no rescan
    echo "/tmp/cached-repo" > "$cache"
    out=$(_dir_repo_scan_cached)
    assert_eq "/tmp/cached-repo" "$out" "repo cache: warm cache is served as-is"

    # Stale cache: still served instantly, then refreshed in the background
    out=$(AM_DIR_REPO_CACHE_TTL=0 _dir_repo_scan_cached)
    assert_eq "/tmp/cached-repo" "$out" "repo cache: stale cache is served instantly"
    for ((i=0; i<40; i++)); do
        [[ "$(cat "$cache" 2>/dev/null)" == "/tmp/scanned-repo" ]] && break
        sleep 0.05
    done
    assert_eq "/tmp/scanned-repo" "$(cat "$cache" 2>/dev/null)" \
        "repo cache: stale cache is refreshed in the background"

    eval "$saved_scan"
    rm -rf "$_tmpdir"

    $SUMMARY_MODE || echo ""
}

run_fzf_tests() {
    _run_test test_annotated_directories
    _run_test test_dir_repo_cache
}

if [[ -z "${_AM_TEST_RUNNER:-}" ]]; then
    set -uo pipefail
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helpers.sh"
    check_deps
    run_fzf_tests
    test_report
fi
