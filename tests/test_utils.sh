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

    # Test: no JSONL for the bound id returns empty
    local result
    result=$(claude_first_user_message "$test_dir" session1)
    assert_eq "" "$result" "claude_first_msg: empty when no JSONL"

    # Test: JSONL with string content
    echo '{"type":"user","message":{"role":"user","content":"Fix the login bug in the auth module"}}' \
        > "$claude_dir/session1.jsonl"
    result=$(claude_first_user_message "$test_dir" session1)
    assert_contains "$result" "Fix the login bug" "claude_first_msg: extracts string content"

    # Test: skips messages with only XML tags
    echo '{"type":"user","message":{"role":"user","content":"<system-tag>short</system-tag>"}}
{"type":"user","message":{"role":"user","content":"Refactor the database connection pooling"}}' \
        > "$claude_dir/session2.jsonl"
    result=$(claude_first_user_message "$test_dir" session2)
    assert_contains "$result" "Refactor the database" "claude_first_msg: skips XML-only messages"

    # Test: handles array content format
    echo '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Add pagination to the API endpoints"}]}}' \
        > "$claude_dir/session3.jsonl"
    result=$(claude_first_user_message "$test_dir" session3)
    assert_contains "$result" "Add pagination" "claude_first_msg: handles array content"

    # Test: each bound id reads its own transcript, newest or not
    result=$(claude_first_user_message "$test_dir" session1)
    assert_contains "$result" "Fix the login bug" "claude_first_msg: bound id ignores newer transcripts"

    # Test: no id → nothing, however many transcripts the store holds
    result=$(claude_first_user_message "$test_dir")
    assert_eq "" "$result" "claude_first_msg: empty without a bound id"

    # Test: an id whose transcript is missing → nothing, no substitute
    result=$(claude_first_user_message "$test_dir" stranger)
    assert_eq "" "$result" "claude_first_msg: empty for an unknown id"

    # Test: nonexistent directory returns empty
    result=$(claude_first_user_message "/tmp/nonexistent-dir-xyz-$$" session1)
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
    local pfum_sid="0199aaaa-0000-0000-0000-000000000001"
    assert_eq "Refactor the state machine please" \
        "$(pi_first_user_message "$pfum_dir" "$pfum_sid")" "pi_first_user_message: string content"

    printf '%s\n%s\n' \
        '{"type":"session","version":3,"id":"0199aaaa-0000-0000-0000-000000000001","cwd":"'"$pfum_resolved"'"}' \
        '{"type":"message","id":"a1","parentId":null,"message":{"role":"user","content":[{"type":"text","text":"Fix the flaky test in registry"}]}}' \
        > "$pfum_file"
    assert_eq "Fix the flaky test in registry" \
        "$(pi_first_user_message "$pfum_dir" "$pfum_sid")" "pi_first_user_message: block content"

    assert_eq "" "$(pi_first_user_message /nonexistent/xyz "$pfum_sid")" "pi_first_user_message: missing dir"

    # no sid -> nothing, even with a lone transcript in the store
    assert_eq "" "$(pi_first_user_message "$pfum_dir")" "pi_first_user_message: empty without a bound id"
    # sid pin still works with two jsonls
    touch "$AM_PI_SESSIONS_DIR/$pfum_enc/2026-07-19T09-00-00-000Z_0199aaaa-0000-0000-0000-000000000002.jsonl"
    assert_eq "Fix the flaky test in registry" \
        "$(pi_first_user_message "$pfum_dir" "$pfum_sid")" \
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
        "$(cursor_first_user_message "$project_dir" "$sid" "$transcript")" \
        "cursor_first_user_message: authoritative transcript path"
    assert_eq "Implement exact Cursor restore support" \
        "$(cursor_first_user_message "$project_dir" "$sid" "")" \
        "cursor_first_user_message: standard-layout fallback"
    assert_eq "" "$(cursor_first_user_message "$project_dir" missing "")" \
        "cursor_first_user_message: missing session"
    assert_eq "" "$(cursor_first_user_message "$project_dir" "" "")" \
        "cursor_first_user_message: empty without id or transcript"

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

    # Relative paths. A bare name with no .git above it used to loop forever
    # ("${dir%/*}" of "sub" is "sub"). The walk now ends at the cwd, like
    # Go's filepath.Dir("sub") == ".". Each call is bounded by a watchdog so
    # a regression fails instead of hanging the suite.
    mkdir -p "$root/plain/sub"
    echo "ref: refs/heads/rel-branch" > "$repo/.git/HEAD"
    _ghb_bounded() {
        # Usage: _ghb_bounded <cwd> <arg> → prints result, or "TIMEOUT"
        local out_file
        out_file=$(mktemp)
        ( cd "$1" && git_head_branch "$2" > "$out_file" ) &
        local pid=$! i
        for (( i = 0; i < 50; i++ )); do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.1
        done
        if kill -0 "$pid" 2>/dev/null; then
            kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
            echo "TIMEOUT"
        else
            wait "$pid" 2>/dev/null
            cat "$out_file"
        fi
        rm -f "$out_file"
    }
    assert_eq "" "$(_ghb_bounded "$root/plain" sub)" \
        "git_head_branch: relative name outside a repo terminates and is empty"
    assert_eq "" "$(_ghb_bounded "$root/plain" ./sub)" \
        "git_head_branch: ./relative outside a repo terminates and is empty"
    assert_eq "" "$(_ghb_bounded "$root/plain/sub" ..)" \
        "git_head_branch: .. outside a repo terminates and is empty"
    assert_eq "" "$(_ghb_bounded "$root/plain" .)" \
        "git_head_branch: . outside a repo is empty"
    assert_eq "rel-branch" "$(_ghb_bounded "$repo" sub/deep)" \
        "git_head_branch: relative path inside a repo walks up to the cwd's .git"
    assert_eq "rel-branch" "$(_ghb_bounded "$repo" sub)" \
        "git_head_branch: bare relative name resolves when the cwd holds .git"
    assert_eq "rel-branch" "$(_ghb_bounded "$repo" .)" \
        "git_head_branch: . resolves when the cwd holds .git"
    # Like Go (filepath.Dir("deep") == "."), the relative walk ends at the
    # cwd and does not continue into the cwd's absolute parents.
    assert_eq "" "$(_ghb_bounded "$repo/sub" deep)" \
        "git_head_branch: relative walk stops at the cwd (Go parity)"
    unset -f _ghb_bounded

    rm -rf "$root"
}

# A first-message title must exceed 10 *characters* (bash ${#var} under a
# UTF-8 locale); the Go readers count runes to match. Pinned with Hebrew:
# 6 letters are 12 bytes (a byte count would accept them) but 6 characters.
test_first_user_message_char_length() {
    $SUMMARY_MODE || echo "=== Testing first-message length is counted in characters ==="
    source "$LIB_DIR/utils.sh"

    # Pick a UTF-8 locale that exists here; skip when none does.
    local loc=""
    if [[ "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" == *[Uu][Tt][Ff]-8* || "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" == *[Uu][Tt][Ff]8* ]]; then
        loc="${LC_ALL:-${LC_CTYPE:-$LANG}}"
    else
        local cand
        for cand in C.UTF-8 en_US.UTF-8 C.utf8 en_US.utf8; do
            if locale -a 2>/dev/null | grep -qx "$cand"; then loc="$cand"; break; fi
        done
    fi
    if [[ -z "$loc" ]]; then
        skip_test "first-message char length (no UTF-8 locale available)"
        return
    fi

    local short="אבגדהו"          # 6 letters, 12 bytes
    local long="אבגדהוזחטיכ"      # 11 letters, 22 bytes
    assert_eq "6" "$(LC_ALL="$loc" bash -c 'printf %s "${#1}"' _ "$short")" \
        "char length: fixture sanity — 6 Hebrew letters"

    # Claude
    local test_dir project_path claude_dir
    test_dir=$(mktemp -d)
    project_path="${test_dir//\//-}"; project_path="${project_path//./-}"
    claude_dir="$HOME/.claude/projects/$project_path"
    mkdir -p "$claude_dir"
    jq -cn --arg c "$short" '{type:"user",message:{role:"user",content:$c}}' > "$claude_dir/heb-short.jsonl"
    jq -cn --arg c "$long" '{type:"user",message:{role:"user",content:$c}}' > "$claude_dir/heb-long.jsonl"
    assert_eq "" "$(LC_ALL="$loc" claude_first_user_message "$test_dir" heb-short)" \
        "claude_first_msg: 6 Hebrew letters (12 bytes) rejected as too short"
    assert_eq "$long" "$(LC_ALL="$loc" claude_first_user_message "$test_dir" heb-long)" \
        "claude_first_msg: 11 Hebrew letters accepted"

    # Pi (its store is keyed by the symlink-resolved cwd)
    local pi_root pi_dir resolved enc
    pi_root=$(mktemp -d)
    resolved=$(cd "$test_dir" && pwd -P)
    enc="${resolved#/}"; enc="${enc//\//-}"
    pi_dir="$pi_root/--${enc}--"
    mkdir -p "$pi_dir"
    jq -cn --arg c "$short" '{type:"message",message:{role:"user",content:$c}}' > "$pi_dir/20260101_pi-short.jsonl"
    jq -cn --arg c "$long" '{type:"message",message:{role:"user",content:$c}}' > "$pi_dir/20260101_pi-long.jsonl"
    assert_eq "" "$(AM_PI_SESSIONS_DIR="$pi_root" LC_ALL="$loc" pi_first_user_message "$test_dir" pi-short)" \
        "pi_first_msg: 6 Hebrew letters rejected as too short"
    assert_eq "$long" "$(AM_PI_SESSIONS_DIR="$pi_root" LC_ALL="$loc" pi_first_user_message "$test_dir" pi-long)" \
        "pi_first_msg: 11 Hebrew letters accepted"

    # Cursor (authoritative transcript path)
    local cur_short cur_long
    cur_short="$pi_root/cur-short.jsonl"; cur_long="$pi_root/cur-long.jsonl"
    jq -cn --arg c "$short" '{role:"user",message:{content:[{type:"text",text:$c}]}}' > "$cur_short"
    jq -cn --arg c "$long" '{role:"user",message:{content:[{type:"text",text:$c}]}}' > "$cur_long"
    assert_eq "" "$(LC_ALL="$loc" cursor_first_user_message "$test_dir" "" "$cur_short")" \
        "cursor_first_msg: 6 Hebrew letters rejected as too short"
    assert_eq "$long" "$(LC_ALL="$loc" cursor_first_user_message "$test_dir" "" "$cur_long")" \
        "cursor_first_msg: 11 Hebrew letters accepted"

    rm -rf "$claude_dir" "$test_dir" "$pi_root"
}

# am_file_mtime / am_files_mtime: one stat flavor probe per process, one
# stat call for a batch.
test_file_mtime_and_log_cap() {
    $SUMMARY_MODE || echo "=== Testing am_file_mtime / am_files_mtime ==="
    source "$LIB_DIR/utils.sh"

    local root now
    root=$(mktemp -d)
    : > "$root/a"
    : > "$root/b with space"
    touch -t 202001020304.05 "$root/b with space"
    now=$(date +%s)

    local m=""
    assert_cmd_succeeds "am_file_mtime: rc 0 for an existing file" am_file_mtime "$root/a"
    m=$(am_file_mtime "$root/a")
    assert_eq "true" "$([[ "$m" =~ ^[0-9]+$ ]] && (( now - m < 60 && m - now < 60 )) && echo true || echo false)" \
        "am_file_mtime: prints a current epoch for a fresh file (got '$m')"
    m="stale"
    am_file_mtime "$root/a" m
    assert_eq "true" "$([[ "$m" =~ ^[0-9]+$ ]] && echo true || echo false)" \
        "am_file_mtime: out_var form assigns the epoch"
    m="stale"
    assert_cmd_fails "am_file_mtime: rc 1 for a missing file" am_file_mtime "$root/missing"
    am_file_mtime "$root/missing" m || true
    assert_eq "" "$m" "am_file_mtime: out_var cleared for a missing file"
    assert_eq "" "$(am_file_mtime "$root/missing")" "am_file_mtime: prints nothing for a missing file"
    assert_eq "true" "$([[ "${_AM_STAT_FLAVOR:-}" == bsd || "${_AM_STAT_FLAVOR:-}" == gnu ]] && echo true || echo false)" \
        "am_file_mtime: stat flavor cached per process (${_AM_STAT_FLAVOR:-unset})"

    declare -A MT=()
    am_files_mtime MT "$root/a" "$root/missing" "$root/b with space"
    assert_eq "2" "${#MT[@]}" "am_files_mtime: one entry per existing file, missing skipped"
    assert_eq "true" "$([[ "${MT[$root/a]:-}" =~ ^[0-9]+$ ]] && echo true || echo false)" \
        "am_files_mtime: entry for a"
    local want_b
    want_b=$(am_file_mtime "$root/b with space")
    assert_eq "$want_b" "${MT[$root/b with space]:-}" \
        "am_files_mtime: path with a space keyed intact and agrees with am_file_mtime"
    assert_eq "true" "$( (( want_b < now - 86400 )) && echo true || echo false)" \
        "am_files_mtime: touched-back file reports its old mtime"
    declare -A MT2=()
    am_files_mtime MT2
    assert_eq "0" "${#MT2[@]}" "am_files_mtime: no files, no entries, no error"

    # The debug-log cap moved to Go (internal/sessions capLog, TestCapLog).

    rm -rf "$root"
}

run_utils_tests() {
    _run_test test_utils
    _run_test test_utils_extended
    _run_test test_claude_first_user_message
    _run_test test_pi_first_user_message
    _run_test test_cursor_first_user_message
    _run_test test_git_head_branch
    _run_test test_first_user_message_char_length
    _run_test test_file_mtime_and_log_cap
}

if [[ -z "${_AM_TEST_RUNNER:-}" ]]; then
    set -uo pipefail
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helpers.sh"
    check_deps
    run_utils_tests
    test_report
fi
