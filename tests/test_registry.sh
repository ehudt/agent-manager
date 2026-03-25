#!/usr/bin/env bash
# tests/test_registry.sh - Tests for lib/registry.sh

test_registry() {
    $SUMMARY_MODE || echo "=== Testing registry.sh ==="

    if ! command -v jq &>/dev/null; then
        skip_test "registry tests (jq not installed)"
        echo ""
        return
    fi

    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/registry.sh"

    # Use temp directory for test registry
    AM_DIR=$(mktemp -d)
    export AM_DIR
    export AM_REGISTRY="$AM_DIR/sessions.json"

    # Test init
    am_init
    assert_cmd_succeeds "am_init creates registry file" test -f "$AM_REGISTRY"

    # Test add
    registry_add "test-session" "/tmp/test" "main" "claude" "test task"
    assert_eq "true" "$(registry_exists test-session && echo true || echo false)" "registry_add: session exists"

    # Test get_field
    assert_eq "/tmp/test" "$(registry_get_field test-session directory)" "registry_get_field: directory"
    assert_eq "main" "$(registry_get_field test-session branch)" "registry_get_field: branch"
    assert_eq "claude" "$(registry_get_field test-session agent_type)" "registry_get_field: agent_type"

    # Test update
    registry_update "test-session" "branch" "feature"
    assert_eq "feature" "$(registry_get_field test-session branch)" "registry_update: changes field"

    # Test list
    registry_add "test-session-2" "/tmp/test2" "dev" "gemini" ""
    local count
    count=$(registry_list | wc -l | tr -d ' ')
    assert_eq "2" "$count" "registry_list: returns all sessions"

    # Test count
    assert_eq "2" "$(registry_count)" "registry_count: correct count"

    # Test remove
    registry_remove "test-session"
    assert_eq "false" "$(registry_exists test-session && echo true || echo false)" "registry_remove: session gone"
    assert_eq "1" "$(registry_count)" "registry_remove: count updated"

    # Cleanup
    rm -rf "$AM_DIR"

    $SUMMARY_MODE || echo ""
}

# ============================================
# Test: registry.sh (extended edge cases)
# ============================================
test_registry_extended() {
    $SUMMARY_MODE || echo "=== Testing registry.sh (extended) ==="

    if ! command -v jq &>/dev/null; then
        skip_test "registry extended tests (jq not installed)"
        echo ""
        return
    fi

    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/registry.sh"

    # Isolated registry
    local old_am_dir="$AM_DIR"
    local old_am_registry="$AM_REGISTRY"
    AM_DIR=$(mktemp -d)
    export AM_DIR
    export AM_REGISTRY="$AM_DIR/sessions.json"
    am_init

    # Test: get_field on nonexistent session returns empty
    local result
    result=$(registry_get_field "nonexistent" "directory")
    assert_eq "" "$result" "registry_get_field: empty for missing session"

    # Test: update on nonexistent session is a no-op (doesn't crash)
    assert_cmd_succeeds "registry_update: no-op for missing session" \
        registry_update "nonexistent" "branch" "value"
    assert_eq "0" "$(registry_count)" "registry_update: count unchanged after no-op"

    # Test: remove on nonexistent session is idempotent
    assert_cmd_succeeds "registry_remove: idempotent for missing session" \
        registry_remove "nonexistent"
    assert_eq "0" "$(registry_count)" "registry_remove: count stays 0"

    # Test: duplicate add overwrites
    registry_add "dup-session" "/tmp/first" "main" "claude" ""
    registry_add "dup-session" "/tmp/second" "dev" "gemini" ""
    assert_eq "/tmp/second" "$(registry_get_field dup-session directory)" \
        "registry_add: duplicate overwrites directory"
    assert_eq "gemini" "$(registry_get_field dup-session agent_type)" \
        "registry_add: duplicate overwrites agent_type"
    assert_eq "1" "$(registry_count)" "registry_add: duplicate doesn't increase count"

    # Test: rapid sequential adds don't corrupt
    registry_add "rapid-1" "/tmp/r1" "main" "claude" ""
    registry_add "rapid-2" "/tmp/r2" "main" "codex" ""
    registry_add "rapid-3" "/tmp/r3" "main" "gemini" ""
    assert_eq "4" "$(registry_count)" "registry: rapid adds all persisted"
    assert_eq "/tmp/r1" "$(registry_get_field rapid-1 directory)" "registry: rapid-1 correct"
    assert_eq "/tmp/r3" "$(registry_get_field rapid-3 directory)" "registry: rapid-3 correct"

    # Cleanup
    rm -rf "$AM_DIR"
    export AM_DIR="$old_am_dir"
    export AM_REGISTRY="$old_am_registry"

    $SUMMARY_MODE || echo ""
}

# ============================================
# Test: registry_get_fields helper
# ============================================
test_registry_get_fields() {
    $SUMMARY_MODE || echo "=== Testing registry_get_fields ==="

    if ! command -v jq &>/dev/null; then
        skip_test "registry_get_fields tests (jq not installed)"
        echo ""
        return
    fi

    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/registry.sh"

    local old_am_dir="$AM_DIR"
    local old_am_registry="$AM_REGISTRY"
    AM_DIR=$(mktemp -d)
    export AM_DIR
    export AM_REGISTRY="$AM_DIR/sessions.json"
    am_init

    # Seed test data
    registry_add "test-sess" "/home/user/project" "main" "claude" "fix auth bug"
    registry_update "test-sess" "worktree_path" "/home/user/project/.claude/worktrees/wt1"

    # Test: 4-field extraction (standard agent_display_name fields)
    local fields
    fields=$(registry_get_fields "test-sess" directory branch agent_type task)
    local directory branch agent_type task
    IFS='|' read -r directory branch agent_type task <<< "$fields"
    assert_eq "/home/user/project" "$directory" "registry_get_fields: directory"
    assert_eq "main" "$branch" "registry_get_fields: branch"
    assert_eq "claude" "$agent_type" "registry_get_fields: agent_type"
    assert_eq "fix auth bug" "$task" "registry_get_fields: task"

    # Test: 5-field extraction (agent_info with worktree_path)
    fields=$(registry_get_fields "test-sess" directory branch agent_type task worktree_path)
    local worktree_path
    IFS='|' read -r directory branch agent_type task worktree_path <<< "$fields"
    assert_eq "/home/user/project/.claude/worktrees/wt1" "$worktree_path" \
        "registry_get_fields: worktree_path (5th field)"

    # Test: missing fields return empty
    registry_add "minimal-sess" "/tmp/dir" "" "codex" ""
    fields=$(registry_get_fields "minimal-sess" directory branch agent_type task)
    IFS='|' read -r directory branch agent_type task <<< "$fields"
    assert_eq "/tmp/dir" "$directory" "registry_get_fields: directory for minimal session"
    assert_eq "" "$branch" "registry_get_fields: empty branch"
    assert_eq "" "$task" "registry_get_fields: empty task"

    # Test: nonexistent session returns all empty
    fields=$(registry_get_fields "nonexistent" directory branch agent_type task)
    IFS='|' read -r directory branch agent_type task <<< "$fields"
    assert_eq "" "$directory" "registry_get_fields: empty for nonexistent session"

    # Cleanup
    rm -rf "$AM_DIR"
    export AM_DIR="$old_am_dir"
    export AM_REGISTRY="$old_am_registry"

    $SUMMARY_MODE || echo ""
}

test_registry_gc() {
    $SUMMARY_MODE || echo "=== Testing Integration: Registry GC ==="

    if ! command -v jq &>/dev/null || ! command -v tmux &>/dev/null; then
        skip_test "registry GC tests (jq or tmux not installed)"
        echo ""
        return
    fi

    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/tmux.sh"
    source "$LIB_DIR/registry.sh"
    set +u; source "$LIB_DIR/agents.sh"; set -u

    setup_integration_env

    local test_dir
    test_dir=$(mktemp -d)

    # Create a live session
    local live_session
    live_session=$(set +u; agent_launch "$test_dir" "claude" "" 2>/dev/null)

    if [[ -z "$live_session" ]]; then
        skip_test "registry GC tests (agent_launch failed)"
        teardown_integration_env
        rm -rf "$test_dir"
        echo ""
        return
    fi

    # Manually add a stale entry (no corresponding tmux session)
    registry_add "test-am-stale-fake" "/tmp/gone" "main" "claude" ""
    assert_eq "true" "$(registry_exists test-am-stale-fake && echo true || echo false)" \
        "gc setup: stale entry exists"

    # Run GC (force to bypass throttle)
    local removed
    removed=$(registry_gc 1)
    assert_eq "true" "$(test "$removed" -ge 1 && echo true || echo false)" \
        "registry_gc: removed at least 1 stale item"

    # Verify stale entry gone, live entry preserved
    assert_eq "false" "$(registry_exists test-am-stale-fake && echo true || echo false)" \
        "registry_gc: stale entry removed"
    assert_eq "true" "$(registry_exists "$live_session" && echo true || echo false)" \
        "registry_gc: live entry preserved"

    # --- Test: GC throttling ---
    # Add another stale entry
    registry_add "test-am-stale-fake-2" "/tmp/gone2" "main" "claude" ""

    # Run GC without force — should be throttled (within 60s of last run)
    removed=$(registry_gc)
    assert_eq "0" "$removed" "registry_gc: throttled within 60s"

    # Stale entry should still exist (GC was skipped)
    assert_eq "true" "$(registry_exists test-am-stale-fake-2 && echo true || echo false)" \
        "registry_gc: stale entry survives throttle"

    # Force GC should still work
    removed=$(registry_gc 1)
    assert_eq "1" "$removed" "registry_gc: force bypasses throttle"

    # Cleanup
    [[ -n "$live_session" ]] && agent_kill "$live_session" 2>/dev/null
    rm -rf "$test_dir"
    teardown_integration_env

    $SUMMARY_MODE || echo ""
}

# ============================================
# Test: Session History (history.jsonl)
# ============================================
test_history() {
    $SUMMARY_MODE || echo "=== Testing Session History ==="

    if ! command -v jq &>/dev/null; then
        skip_test "history tests (jq not installed)"
        echo ""
        return
    fi

    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/registry.sh"

    # Isolated environment
    local old_am_dir="$AM_DIR"
    local old_am_registry="$AM_REGISTRY"
    local old_am_history="${AM_HISTORY:-}"
    AM_DIR=$(mktemp -d)
    export AM_DIR
    export AM_REGISTRY="$AM_DIR/sessions.json"
    export AM_HISTORY="$AM_DIR/history.jsonl"
    am_init

    # --- Test: history_append creates file and writes correct JSON ---
    history_append "/tmp/project-a" "fix login bug" "claude" "main"
    assert_cmd_succeeds "history_append: creates history file" test -f "$AM_HISTORY"

    local first_line
    first_line=$(head -1 "$AM_HISTORY")
    assert_contains "$first_line" '"task":"fix login bug"' "history_append: correct task"
    assert_contains "$first_line" '"directory":"/tmp/project-a"' "history_append: correct directory"
    assert_contains "$first_line" '"agent_type":"claude"' "history_append: correct agent_type"
    assert_contains "$first_line" '"branch":"main"' "history_append: correct branch"

    # Validate it's proper JSON
    assert_cmd_succeeds "history_append: valid JSON" jq . <<< "$first_line"

    # --- Test: multiple entries accumulate ---
    history_append "/tmp/project-a" "add tests" "claude" "main"
    history_append "/tmp/project-b" "refactor utils" "gemini" "dev"

    local line_count
    line_count=$(wc -l < "$AM_HISTORY" | tr -d ' ')
    assert_eq "3" "$line_count" "history_append: multiple entries accumulate"

    # --- Test: history_append with empty task is a no-op ---
    history_append "/tmp/project-a" "" "claude" "main"
    line_count=$(wc -l < "$AM_HISTORY" | tr -d ' ')
    assert_eq "3" "$line_count" "history_append: empty task is no-op"

    # --- Test: history_for_directory filters correctly and returns most recent first ---
    local dir_a_entries
    dir_a_entries=$(history_for_directory "/tmp/project-a")
    local dir_a_count
    dir_a_count=$(echo "$dir_a_entries" | wc -l | tr -d ' ')
    assert_eq "2" "$dir_a_count" "history_for_directory: filters to correct directory"

    # Most recent first: "add tests" should be before "fix login bug"
    local first_task
    first_task=$(echo "$dir_a_entries" | head -1 | jq -r '.task')
    assert_eq "add tests" "$first_task" "history_for_directory: most recent first"

    local second_task
    second_task=$(echo "$dir_a_entries" | tail -1 | jq -r '.task')
    assert_eq "fix login bug" "$second_task" "history_for_directory: oldest last"

    # --- Test: history_for_directory returns empty for unknown paths ---
    local unknown_entries
    unknown_entries=$(history_for_directory "/tmp/nonexistent-path")
    assert_eq "" "$unknown_entries" "history_for_directory: empty for unknown path"

    # --- Test: history_prune removes entries older than 7 days ---
    # Inject an old entry manually (8 days ago)
    local old_date
    old_date=$(date -u -v-8d +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || \
        date -u -d "8 days ago" +"%Y-%m-%dT%H:%M:%SZ")
    printf '%s\n' "$(jq -cn \
        --arg dir "/tmp/project-a" \
        --arg task "ancient task" \
        --arg agent "claude" \
        --arg branch "main" \
        --arg created "$old_date" \
        '{directory: $dir, task: $task, agent_type: $agent, branch: $branch, created_at: $created}')" \
        >> "$AM_HISTORY"

    # Verify old entry was added
    line_count=$(wc -l < "$AM_HISTORY" | tr -d ' ')
    assert_eq "4" "$line_count" "history_prune setup: old entry injected"

    # Run prune
    history_prune
    line_count=$(wc -l < "$AM_HISTORY" | tr -d ' ')
    assert_eq "3" "$line_count" "history_prune: removed old entry"

    # Verify the old entry is gone
    local ancient_count
    ancient_count=$(jq -c 'select(.task == "ancient task")' "$AM_HISTORY" 2>/dev/null | wc -l | tr -d ' ')
    assert_eq "0" "$ancient_count" "history_prune: ancient task removed"

    # Cleanup
    rm -rf "$AM_DIR"
    export AM_DIR="$old_am_dir"
    export AM_REGISTRY="$old_am_registry"
    export AM_HISTORY="$old_am_history"

    $SUMMARY_MODE || echo ""
}

# ============================================
# Test: History Integration (wiring into lifecycle)
# ============================================
test_history_integration() {
    $SUMMARY_MODE || echo "=== Testing History Integration ==="

    if ! command -v jq &>/dev/null; then
        skip_test "history integration tests (jq not installed)"
        echo ""
        return
    fi

    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/registry.sh"

    # Isolated environment
    local old_am_dir="$AM_DIR"
    local old_am_registry="$AM_REGISTRY"
    local old_am_history="${AM_HISTORY:-}"
    AM_DIR=$(mktemp -d)
    export AM_DIR
    export AM_REGISTRY="$AM_DIR/sessions.json"
    export AM_HISTORY="$AM_DIR/history.jsonl"
    am_init

    # Simulate what agent_launch does: registry_add + history_append
    registry_add "test-hist-session" "/tmp/myproject" "main" "claude" "fix auth bug"
    history_append "/tmp/myproject" "fix auth bug" "claude" "main"

    # Verify history file exists and contains the task
    assert_cmd_succeeds "history_integration: history file created" test -f "$AM_HISTORY"

    local hist_content
    hist_content=$(cat "$AM_HISTORY")
    assert_contains "$hist_content" '"task":"fix auth bug"' \
        "history_integration: task recorded in history"
    assert_contains "$hist_content" '"directory":"/tmp/myproject"' \
        "history_integration: directory recorded in history"

    # Simulate auto_title_session path: registry_update + history_append via registry_get_field
    registry_add "test-hist-auto" "/tmp/another" "dev" "gemini" ""
    # Simulate what auto_title_session does after getting a title
    registry_update "test-hist-auto" "task" "refactor utils"
    local dir branch agent
    dir=$(registry_get_field "test-hist-auto" "directory")
    branch=$(registry_get_field "test-hist-auto" "branch")
    agent=$(registry_get_field "test-hist-auto" "agent_type")
    history_append "$dir" "refactor utils" "$agent" "$branch"

    local line_count
    line_count=$(wc -l < "$AM_HISTORY" | tr -d ' ')
    assert_eq "2" "$line_count" "history_integration: two entries after both paths"

    # Verify the second entry
    local second_line
    second_line=$(tail -1 "$AM_HISTORY")
    assert_contains "$second_line" '"task":"refactor utils"' \
        "history_integration: auto-title task recorded"
    assert_contains "$second_line" '"agent_type":"gemini"' \
        "history_integration: auto-title agent_type correct"

    # Cleanup
    rm -rf "$AM_DIR"
    export AM_DIR="$old_am_dir"
    export AM_REGISTRY="$old_am_registry"
    export AM_HISTORY="$old_am_history"

    $SUMMARY_MODE || echo ""
}

test_auto_title_session() {
    $SUMMARY_MODE || echo ""
    $SUMMARY_MODE || echo "=== Auto-Title Session Tests ==="

    if ! command -v jq &>/dev/null; then
        skip_test "auto-title tests (jq not installed)"
        echo ""
        return
    fi

    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/registry.sh"

    # Isolated AM environment
    local old_am_dir="$AM_DIR"
    local old_am_registry="$AM_REGISTRY"
    local old_am_history="${AM_HISTORY:-}"
    AM_DIR=$(mktemp -d)
    export AM_DIR
    export AM_REGISTRY="$AM_DIR/sessions.json"
    export AM_HISTORY="$AM_DIR/history.jsonl"
    am_init

    # Use production title functions directly (sourced from lib/registry.sh)

    # --- Test 1: Title validation - length check ---
    if _title_valid "Short title"; then
        ((TESTS_RUN++)); ((TESTS_PASSED++))
        $SUMMARY_MODE || printf '%b\n' "${TEST_GREEN}PASS${TEST_RESET}: title_gen: accepts valid short title"
    else
        ((TESTS_RUN++)); ((TESTS_FAILED++))
        printf '%b\n' "${TEST_RED}FAIL${TEST_RESET}: title_gen: accepts valid short title"
        FAIL_DETAILS+=("FAIL: title_gen: accepts valid short title")
    fi

    if _title_valid "This is a really really really really really really really long title over 60 chars"; then
        ((TESTS_RUN++)); ((TESTS_FAILED++))
        printf '%b\n' "${TEST_RED}FAIL${TEST_RESET}: title_gen: rejects title >60 chars"
        FAIL_DETAILS+=("FAIL: title_gen: rejects title >60 chars")
    else
        ((TESTS_RUN++)); ((TESTS_PASSED++))
        $SUMMARY_MODE || printf '%b\n' "${TEST_GREEN}PASS${TEST_RESET}: title_gen: rejects title >60 chars"
    fi

    # --- Test 2: Title validation - newline check ---
    if _title_valid $'Multi\nline'; then
        ((TESTS_RUN++)); ((TESTS_FAILED++))
        printf '%b\n' "${TEST_RED}FAIL${TEST_RESET}: title_gen: rejects multiline titles"
        FAIL_DETAILS+=("FAIL: title_gen: rejects multiline titles")
    else
        ((TESTS_RUN++)); ((TESTS_PASSED++))
        $SUMMARY_MODE || printf '%b\n' "${TEST_GREEN}PASS${TEST_RESET}: title_gen: rejects multiline titles"
    fi

    # --- Test 3: Integration - registry update on successful title ---
    registry_add "test-title-reg" "/tmp/test" "main" "claude" ""
    registry_update "test-title-reg" "task" "Refactor API layer"
    local stored_task
    stored_task=$(registry_get_field "test-title-reg" "task")
    assert_eq "Refactor API layer" "$stored_task" \
        "title_gen: registry_update persists title"

    # --- Test 4: Integration - history append on title set ---
    history_append "/tmp/test" "Refactor API layer" "claude" "main"
    local hist_count=0
    [[ -f "$AM_HISTORY" ]] && hist_count=$(wc -l < "$AM_HISTORY" | tr -d ' ')
    assert_eq "1" "$hist_count" \
        "title_gen: history_append records task"

    # --- Test 5: History is skipped for empty task ---
    history_append "/tmp/test" "" "claude" "main"
    local hist_count_after=0
    [[ -f "$AM_HISTORY" ]] && hist_count_after=$(wc -l < "$AM_HISTORY" | tr -d ' ')
    assert_eq "$hist_count" "$hist_count_after" \
        "title_gen: history_append skips empty task"

    # --- Cleanup ---
    rm -rf "$AM_DIR"
    export AM_DIR="$old_am_dir"
    export AM_REGISTRY="$old_am_registry"
    export AM_HISTORY="$old_am_history"

    $SUMMARY_MODE || echo ""
}

# ============================================
# Test: auto_title_scan (piggyback scanner)
# ============================================
test_auto_title_scan() {
    $SUMMARY_MODE || echo ""
    $SUMMARY_MODE || echo "=== Auto-Title Scan Tests ==="

    if ! command -v jq &>/dev/null; then
        skip_test "auto-title scan tests (jq not installed)"
        echo ""
        return
    fi

    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/registry.sh"

    # Isolated AM environment
    local old_am_dir="$AM_DIR"
    local old_am_registry="$AM_REGISTRY"
    local old_am_history="${AM_HISTORY:-}"
    AM_DIR=$(mktemp -d)
    export AM_DIR
    export AM_REGISTRY="$AM_DIR/sessions.json"
    export AM_HISTORY="$AM_DIR/history.jsonl"
    am_init

    # Stub tmux_pane_title to return titles based on session name
    tmux_pane_title() {
        local target="$1"
        case "$target" in
            test-scan-1:*) echo "Fix the login bug in auth" ;;
            test-scan-2:*) echo "Updated title from pane" ;;
            test-scan-3:*) echo "" ;;
            test-scan-4:*) echo "Throttle test title" ;;
            test-scan-5:*) echo "First title for history" ;;
            test-scan-6:*) echo "Existing Title" ;;
            test-scan-7:*) echo ">>> Clean up the mess" ;;
            *) echo "" ;;
        esac
    }

    # --- Test 1: Updates session task from pane title ---
    registry_add "test-scan-1" "/tmp/project" "main" "claude" ""
    auto_title_scan 1  # force
    local task
    task=$(registry_get_field "test-scan-1" "task")
    assert_eq "Fix the login bug in auth" "$task" \
        "scan: updates task from pane title"

    # --- Test 2: Skips session with empty/invalid pane title ---
    registry_add "test-scan-3" "/tmp/project" "main" "claude" ""
    auto_title_scan 1
    task=$(registry_get_field "test-scan-3" "task")
    assert_eq "" "$task" \
        "scan: skips session with empty pane title"

    # --- Test 3: Throttling works ---
    registry_add "test-scan-4" "/tmp/project" "main" "claude" ""
    auto_title_scan  # throttled (ran <60s ago from test 1)
    task=$(registry_get_field "test-scan-4" "task")
    assert_eq "" "$task" \
        "scan: throttled within 60s"

    # --- Test 4: Force bypasses throttle ---
    auto_title_scan 1
    task=$(registry_get_field "test-scan-4" "task")
    assert_eq "Throttle test title" "$task" \
        "scan: force bypasses throttle"

    # --- Test 5: History entry created on first title ---
    registry_add "test-scan-5" "/tmp/histproject" "dev" "gemini" ""
    auto_title_scan 1
    task=$(registry_get_field "test-scan-5" "task")
    assert_eq "First title for history" "$task" \
        "scan: sets first title"
    local hist_entry
    hist_entry=$(tail -1 "$AM_HISTORY")
    assert_contains "$hist_entry" '"task":"First title for history"' \
        "scan: history entry created on first title"
    assert_contains "$hist_entry" '"directory":"/tmp/histproject"' \
        "scan: history entry has correct directory"

    # --- Test 6: Does not update if pane title unchanged ---
    registry_add "test-scan-6" "/tmp/project" "main" "claude" "Existing Title"
    local hist_count_before=0
    [[ -f "$AM_HISTORY" ]] && hist_count_before=$(wc -l < "$AM_HISTORY" | tr -d ' ')
    auto_title_scan 1
    task=$(registry_get_field "test-scan-6" "task")
    assert_eq "Existing Title" "$task" \
        "scan: no update when pane title matches existing task"
    local hist_count_after=0
    [[ -f "$AM_HISTORY" ]] && hist_count_after=$(wc -l < "$AM_HISTORY" | tr -d ' ')
    assert_eq "$hist_count_before" "$hist_count_after" \
        "scan: no history entry when title unchanged"

    # --- Test 7: Trims leading non-alphanumeric characters from pane title ---
    registry_add "test-scan-7" "/tmp/project" "main" "claude" ""
    auto_title_scan 1
    task=$(registry_get_field "test-scan-7" "task")
    assert_eq "Clean up the mess" "$task" \
        "scan: trims leading non-alphanumeric chars from pane title"

    # --- Cleanup ---
    unset -f tmux_pane_title
    rm -rf "$AM_DIR"
    export AM_DIR="$old_am_dir"
    export AM_REGISTRY="$old_am_registry"
    export AM_HISTORY="$old_am_history"

    $SUMMARY_MODE || echo ""
}

run_registry_tests() {
    _run_test test_registry
    _run_test test_registry_extended
    _run_test test_registry_get_fields
    _run_test test_registry_gc
    _run_test test_history
    _run_test test_history_integration
    _run_test test_auto_title_session
    _run_test test_auto_title_scan
}

if [[ -z "${_AM_TEST_RUNNER:-}" ]]; then
    set -uo pipefail
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helpers.sh"
    check_deps
    run_registry_tests
    test_report
fi
