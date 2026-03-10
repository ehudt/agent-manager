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
    local hash1=$(generate_hash "test")
    local hash2=$(generate_hash "test")
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
    local h1=$(generate_hash "same-input")
    local h2=$(generate_hash "same-input")
    local h3=$(generate_hash "different-input")
    assert_eq "$h1" "$h2" "generate_hash: same input same output"
    # Different inputs SHOULD produce different hashes (not guaranteed but overwhelmingly likely)
    if [[ "$h1" != "$h3" ]]; then
        ((TESTS_RUN++)); ((TESTS_PASSED++))
        $SUMMARY_MODE || echo -e "${GREEN}PASS${RESET}: generate_hash: different inputs different output"
    else
        ((TESTS_RUN++)); ((TESTS_FAILED++))
        echo -e "${RED}FAIL${RESET}: generate_hash: different inputs produced same hash"
        FAIL_DETAILS+=("FAIL: generate_hash: different inputs produced same hash")
    fi

    # abspath: with real directories
    local tmpd=$(mktemp -d)
    assert_eq "$tmpd" "$(abspath "$tmpd")" "abspath: absolute path unchanged"
    rm -rf "$tmpd"

    $SUMMARY_MODE || echo ""
}

test_claude_first_user_message() {
    $SUMMARY_MODE || echo "=== Testing claude_first_user_message ==="

    if ! command -v jq &>/dev/null; then
        skip_test "claude_first_user_message tests (jq not installed)"
        echo ""
        return
    fi

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

run_utils_tests() {
    _run_test test_utils
    _run_test test_utils_extended
    _run_test test_claude_first_user_message
}

if [[ -z "${_AM_TEST_RUNNER:-}" ]]; then
    set -uo pipefail
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helpers.sh"
    check_deps
    run_utils_tests
    test_report
fi
