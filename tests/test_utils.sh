#!/usr/bin/env bash
# tests/test_utils.sh - Tests for lib/utils.sh

test_utils() {
    $SUMMARY_MODE || echo "=== Testing utils.sh ==="
    source "$LIB_DIR/utils.sh"

    # Test format_time_ago
    assert_eq "5s ago" "$(format_time_ago 5)" "format_time_ago: 5 seconds"
    assert_eq "2m ago" "$(format_time_ago 120)" "format_time_ago: 2 minutes"
    assert_eq "1h 30m ago" "$(format_time_ago 5400)" "format_time_ago: 1.5 hours"
    assert_eq "2d ago" "$(format_time_ago 172800)" "format_time_ago: 2 days"

    # Test format_duration
    assert_eq "30s" "$(format_duration 30)" "format_duration: 30 seconds"
    assert_eq "5m" "$(format_duration 300)" "format_duration: 5 minutes"
    assert_eq "2h 0m" "$(format_duration 7200)" "format_duration: 2 hours"

    # Test truncate
    assert_eq "hello" "$(truncate 'hello' 10)" "truncate: short string unchanged"
    assert_eq "hello w..." "$(truncate 'hello world' 10)" "truncate: long string truncated"

    # Test generate_hash
    local hash1
    hash1=$(generate_hash "test")
    local hash2
    hash2=$(generate_hash "test")
    assert_eq "$hash1" "$hash2" "generate_hash: deterministic"
    assert_eq 6 "${#hash1}" "generate_hash: 6 chars"

    # Test dir_basename
    assert_eq "foo" "$(dir_basename '/path/to/foo')" "dir_basename: extracts basename"

    $SUMMARY_MODE || echo ""
}

# ============================================
# Test: utils.sh (extended edge cases)
# ============================================
test_utils_extended() {
    $SUMMARY_MODE || echo "=== Testing utils.sh (extended) ==="
    source "$LIB_DIR/utils.sh"

    # format_time_ago: edge cases
    assert_eq "0s ago" "$(format_time_ago 0)" "format_time_ago: zero seconds"
    assert_eq "just now" "$(format_time_ago -5)" "format_time_ago: negative"
    assert_eq "11574d ago" "$(format_time_ago 1000000000)" "format_time_ago: very large"

    # format_duration: edge cases
    assert_eq "0s" "$(format_duration 0)" "format_duration: zero"
    assert_eq "1d 0h" "$(format_duration 86400)" "format_duration: exactly 1 day"

    # truncate: edge cases
    assert_eq "" "$(truncate '' 10)" "truncate: empty string"
    assert_eq "hi" "$(truncate 'hi' 10)" "truncate: shorter than limit"
    assert_eq "0123456789" "$(truncate '0123456789' 10)" "truncate: exact limit length"

    # generate_hash: consistency
    local h1
    h1=$(generate_hash "same-input")
    local h2
    h2=$(generate_hash "same-input")
    local h3
    h3=$(generate_hash "different-input")
    assert_eq "$h1" "$h2" "generate_hash: same input same output"
    # Different inputs SHOULD produce different hashes (not guaranteed but overwhelmingly likely)
    assert_cmd_succeeds "generate_hash: different inputs different output" \
        test "$h1" != "$h3"

    # abspath: with real directories
    local tmpd
    tmpd=$(mktemp -d)
    assert_eq "$tmpd" "$(abspath "$tmpd")" "abspath: absolute path unchanged"
    rm -rf "$tmpd"

    $SUMMARY_MODE || echo ""
}

test_claude_first_user_message() {
    $SUMMARY_MODE || echo "=== Testing claude_first_user_message ==="

    source "$LIB_DIR/utils.sh"

    # Create a fake Claude project directory structure
    local test_dir
    test_dir=$(mktemp -d)

    local project_path="${test_dir//\//-}"
    project_path="${project_path//./-}"
    local claude_dir="$HOME/.claude/projects/$project_path"
    mkdir -p "$claude_dir"

    # Test: no JSONL files returns empty
    local result
    result=$(claude_first_user_message "$test_dir")
    assert_eq "" "$result" "claude_first_msg: empty when no JSONL"

    # Test: JSONL with string content
    echo '{"type":"user","message":{"role":"user","content":"Fix the login bug in the auth module"}}' \
        > "$claude_dir/session1.jsonl"
    result=$(claude_first_user_message "$test_dir")
    assert_contains "$result" "Fix the login bug" "claude_first_msg: extracts string content"

    # Test: skips messages with only XML tags
    echo '{"type":"user","message":{"role":"user","content":"<system-tag>short</system-tag>"}}
{"type":"user","message":{"role":"user","content":"Refactor the database connection pooling"}}' \
        > "$claude_dir/session2.jsonl"
    result=$(claude_first_user_message "$test_dir")
    assert_contains "$result" "Refactor the database" "claude_first_msg: skips XML-only messages"

    # Test: handles array content format
    echo '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Add pagination to the API endpoints"}]}}' \
        > "$claude_dir/session3.jsonl"
    result=$(claude_first_user_message "$test_dir")
    assert_contains "$result" "Add pagination" "claude_first_msg: handles array content"

    # Test: nonexistent directory returns empty
    result=$(claude_first_user_message "/tmp/nonexistent-dir-xyz-$$")
    assert_eq "" "$result" "claude_first_msg: empty for nonexistent dir"

    # Cleanup
    rm -rf "$claude_dir" "$test_dir"

    $SUMMARY_MODE || echo ""
}

test_pi_first_user_message() {
    $SUMMARY_MODE || echo "=== Testing pi_first_user_message ==="

    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/registry.sh"

    # --- pi_first_user_message ---
    local pfum_home
    pfum_home=$(mktemp -d)
    local pfum_dir="$pfum_home/proj"
    mkdir -p "$pfum_dir"
    local pfum_resolved pfum_enc
    pfum_resolved=$(cd "$pfum_dir" && pwd -P)
    pfum_enc="--${pfum_resolved#/}--"
    pfum_enc="${pfum_enc//\//-}"
    export AM_PI_SESSIONS_DIR="$pfum_home/sessions"
    mkdir -p "$AM_PI_SESSIONS_DIR/$pfum_enc"
    local pfum_file="$AM_PI_SESSIONS_DIR/$pfum_enc/2026-07-19T08-00-00-000Z_0199aaaa-0000-0000-0000-000000000001.jsonl"
    printf '%s\n%s\n' \
        '{"type":"session","version":3,"id":"0199aaaa-0000-0000-0000-000000000001","cwd":"'"$pfum_resolved"'"}' \
        '{"type":"message","id":"a1","parentId":null,"message":{"role":"user","content":"Refactor the state machine please"}}' \
        > "$pfum_file"
    assert_eq "Refactor the state machine please" \
        "$(pi_first_user_message "$pfum_dir")" "pi_first_user_message: string content"

    printf '%s\n%s\n' \
        '{"type":"session","version":3,"id":"0199aaaa-0000-0000-0000-000000000001","cwd":"'"$pfum_resolved"'"}' \
        '{"type":"message","id":"a1","parentId":null,"message":{"role":"user","content":[{"type":"text","text":"Fix the flaky test in registry"}]}}' \
        > "$pfum_file"
    assert_eq "Fix the flaky test in registry" \
        "$(pi_first_user_message "$pfum_dir")" "pi_first_user_message: block content"

    assert_eq "" "$(pi_first_user_message /nonexistent/xyz)" "pi_first_user_message: missing dir"

    # strict mode with two jsonls and no sid -> empty
    touch "$AM_PI_SESSIONS_DIR/$pfum_enc/2026-07-19T09-00-00-000Z_0199aaaa-0000-0000-0000-000000000002.jsonl"
    assert_eq "" "$(pi_first_user_message "$pfum_dir" "" 1)" "pi_first_user_message: strict ambiguous"
    # sid pin still works with two jsonls
    assert_eq "Fix the flaky test in registry" \
        "$(pi_first_user_message "$pfum_dir" "0199aaaa-0000-0000-0000-000000000001" 1)" \
        "pi_first_user_message: sid pinned"
    unset AM_PI_SESSIONS_DIR

    # Cleanup
    rm -rf "$pfum_home"

    $SUMMARY_MODE || echo ""
}

test_cursor_first_user_message() {
    $SUMMARY_MODE || echo "=== Testing cursor_first_user_message ==="

    source "$LIB_DIR/utils.sh"

    local root project_dir transcript sid
    root=$(mktemp -d)
    project_dir="$root/project.with-dot"
    sid="cursor-session-1"
    mkdir -p "$project_dir"
    export AM_CURSOR_PROJECTS_DIR="$root/cursor-projects"
    local resolved
    resolved=$(cd "$project_dir" && pwd -P)
    local encoded="${resolved#/}"
    encoded="${encoded//\//-}"
    encoded="${encoded//./-}"
    transcript="$AM_CURSOR_PROJECTS_DIR/$encoded/agent-transcripts/$sid/$sid.jsonl"
    mkdir -p "$(dirname "$transcript")"
    printf '%s\n' \
        '{"role":"user","message":{"content":[{"type":"text","text":"<user_query>Implement exact Cursor restore support</user_query>"}]}}' \
        '{"role":"assistant","message":{"content":[{"type":"text","text":"Working"}]}}' \
        > "$transcript"

    assert_eq "Implement exact Cursor restore support" \
        "$(cursor_first_user_message "$project_dir" "$sid" "$transcript" 1)" \
        "cursor_first_user_message: authoritative transcript path"
    assert_eq "Implement exact Cursor restore support" \
        "$(cursor_first_user_message "$project_dir" "$sid" "" 1)" \
        "cursor_first_user_message: standard-layout fallback"
    assert_eq "" "$(cursor_first_user_message "$project_dir" missing "" 1)" \
        "cursor_first_user_message: strict missing session"

    unset AM_CURSOR_PROJECTS_DIR
    rm -rf "$root"
    $SUMMARY_MODE || echo ""
}


# git_head_branch: fork-free .git/HEAD reader used by the workdir/branch refresh
test_git_head_branch() {
    $SUMMARY_MODE || echo "=== Testing git_head_branch ==="
    source "$LIB_DIR/utils.sh"

    local root repo
    root=$(mktemp -d)
    repo="$root/repo"
    mkdir -p "$repo/.git" "$repo/sub/deep"

    echo "ref: refs/heads/feature/x" > "$repo/.git/HEAD"
    assert_eq "feature/x" "$(git_head_branch "$repo")" \
        "git_head_branch: branch name from .git/HEAD"
    assert_eq "feature/x" "$(git_head_branch "$repo/sub/deep")" \
        "git_head_branch: walks up from a subdirectory"

    echo "0123456789abcdef0123456789abcdef01234567" > "$repo/.git/HEAD"
    assert_eq "01234567" "$(git_head_branch "$repo")" \
        "git_head_branch: detached HEAD gives a short sha"

    # Worktree: .git is a pointer file to the main repo's worktree gitdir.
    local wt="$root/wt"
    mkdir -p "$wt" "$repo/.git/worktrees/wt"
    echo "gitdir: $repo/.git/worktrees/wt" > "$wt/.git"
    echo "ref: refs/heads/wt-branch" > "$repo/.git/worktrees/wt/HEAD"
    assert_eq "wt-branch" "$(git_head_branch "$wt")" \
        "git_head_branch: follows a worktree gitdir pointer"

    # Submodule: relative pointer.
    local sm="$repo/sub/mod"
    mkdir -p "$sm" "$repo/.git/modules/mod"
    echo "gitdir: ../../.git/modules/mod" > "$sm/.git"
    echo "ref: refs/heads/sm-branch" > "$repo/.git/modules/mod/HEAD"
    assert_eq "sm-branch" "$(git_head_branch "$sm")" \
        "git_head_branch: resolves a relative gitdir pointer"

    mkdir -p "$root/plain"
    assert_eq "" "$(git_head_branch "$root/plain")" \
        "git_head_branch: empty outside a repository"
    assert_eq "" "$(git_head_branch "$root/missing")" \
        "git_head_branch: empty for a missing directory"
    assert_eq "" "$(git_head_branch "")" \
        "git_head_branch: empty for an empty argument"

    # Agrees with git on a real checkout (this repo).
    if command -v git >/dev/null 2>&1; then
        local want
        want=$(git -C "$PROJECT_DIR" branch --show-current 2>/dev/null || true)
        [[ -n "$want" ]] && assert_eq "$want" "$(git_head_branch "$PROJECT_DIR")" \
            "git_head_branch: agrees with git branch --show-current"
    fi

    rm -rf "$root"
}

run_utils_tests() {
    _run_test test_utils
    _run_test test_utils_extended
    _run_test test_claude_first_user_message
    _run_test test_pi_first_user_message
    _run_test test_cursor_first_user_message
    _run_test test_git_head_branch
}

if [[ -z "${_AM_TEST_RUNNER:-}" ]]; then
    set -uo pipefail
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helpers.sh"
    check_deps
    run_utils_tests
    test_report
fi
