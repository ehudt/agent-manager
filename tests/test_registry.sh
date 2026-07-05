#!/usr/bin/env bash
# tests/test_registry.sh - Tests for lib/registry.sh

test_registry() {
    $SUMMARY_MODE || echo "=== Testing registry.sh ==="

    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/registry.sh"

    # Test init
    setup_isolated_am_dir
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

    registry_add "test-session-2" "/tmp/test2" "dev" "codex" ""
    # Test count
    assert_eq "2" "$(registry_count)" "registry_count: correct count"

    # Test remove
    registry_remove "test-session"
    assert_eq "false" "$(registry_exists test-session && echo true || echo false)" "registry_remove: session gone"
    assert_eq "1" "$(registry_count)" "registry_remove: count updated"

    teardown_isolated_am_dir

    $SUMMARY_MODE || echo ""
}

# ============================================
# Test: registry.sh (extended edge cases)
# ============================================
test_registry_extended() {
    $SUMMARY_MODE || echo "=== Testing registry.sh (extended) ==="

    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/registry.sh"

    setup_isolated_am_dir

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
    registry_add "dup-session" "/tmp/second" "dev" "codex" ""
    assert_eq "/tmp/second" "$(registry_get_field dup-session directory)" \
        "registry_add: duplicate overwrites directory"
    assert_eq "codex" "$(registry_get_field dup-session agent_type)" \
        "registry_add: duplicate overwrites agent_type"
    assert_eq "1" "$(registry_count)" "registry_add: duplicate doesn't increase count"

    # Test: rapid sequential adds don't corrupt
    registry_add "rapid-1" "/tmp/r1" "main" "claude" ""
    registry_add "rapid-2" "/tmp/r2" "main" "codex" ""
    registry_add "rapid-3" "/tmp/r3" "main" "codex" ""
    assert_eq "4" "$(registry_count)" "registry: rapid adds all persisted"
    assert_eq "/tmp/r1" "$(registry_get_field rapid-1 directory)" "registry: rapid-1 correct"
    assert_eq "/tmp/r3" "$(registry_get_field rapid-3 directory)" "registry: rapid-3 correct"

    teardown_isolated_am_dir

    $SUMMARY_MODE || echo ""
}

# ============================================
# Test: registry_get_fields helper
# ============================================
test_registry_get_fields() {
    $SUMMARY_MODE || echo "=== Testing registry_get_fields ==="

    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/registry.sh"

    setup_isolated_am_dir

    # Seed test data
    registry_add "test-sess" "/home/user/project" "main" "claude" "fix auth bug"
    registry_update "test-sess" "worktree_path" "/home/user/project/.claude/worktrees/wt1"

    # Test: 4-field extraction (directory/branch/agent_type/task)
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

    teardown_isolated_am_dir

    $SUMMARY_MODE || echo ""
}

test_registry_gc() {
    $SUMMARY_MODE || echo "=== Testing Integration: Registry GC ==="

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

    # --- Test: Go stamping .gc_last must not starve bash-only extras ---
    registry_add "test-am-stale-fake-3" "/tmp/gone3" "main" "claude" ""
    local extras_state_dir
    extras_state_dir=$(mktemp -d)
    printf 'waiting_input' > "$extras_state_dir/test-am-orphan"
    printf 'uuid-orphan' > "$extras_state_dir/test-am-orphan.sid"
    # Simulate the Go twin (ReapOrphans) having just stamped .gc_last
    date +%s > "$AM_DIR/.gc_last"
    rm -f "$AM_DIR/.gc_extras_last"
    removed=$(AM_STATE_DIR="$extras_state_dir" registry_gc)
    assert_eq "true" "$(registry_exists test-am-stale-fake-3 && echo true || echo false)" \
        "registry_gc: rows half stays throttled by fresh .gc_last"
    assert_eq "false" "$(test -f "$extras_state_dir/test-am-orphan" && echo true || echo false)" \
        "registry_gc: extras sweep removes orphan state file despite fresh .gc_last"
    assert_eq "false" "$(test -f "$extras_state_dir/test-am-orphan.sid" && echo true || echo false)" \
        "registry_gc: extras sweep removes orphan .sid sidecar despite fresh .gc_last"
    rm -rf "$extras_state_dir"
    registry_remove "test-am-stale-fake-3"

    # Cleanup
    [[ -n "$live_session" ]] && agent_kill "$live_session" 2>/dev/null
    rm -rf "$test_dir"
    teardown_integration_env

    $SUMMARY_MODE || echo ""
}

test_registry_gc_go_path() {
    $SUMMARY_MODE || echo "=== Testing Integration: Registry GC (Go path) ==="

    local repo_root
    repo_root=$(cd "$LIB_DIR/.." && pwd)
    local bin="$repo_root/bin/am-list-internal"

    if [[ ! -x "$bin" || ! -s "$bin" ]]; then
        skip_test "Go path GC (bin/am-list-internal not built — run 'make build')"
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

    local live_session
    live_session=$(set +u; agent_launch "$test_dir" "claude" "" 2>/dev/null)

    if [[ -z "$live_session" ]]; then
        skip_test "Go path GC (agent_launch failed)"
        teardown_integration_env
        rm -rf "$test_dir"
        echo ""
        return
    fi

    registry_add "test-am-stale-go" "/tmp/gone-go" "main" "claude" ""
    # Seed an orphan hook state file the Go path should remove.
    local state_dir="${AM_STATE_DIR:-/tmp/am-state}"
    mkdir -p "$state_dir"
    : > "$state_dir/test-am-stale-go"

    # Ensure throttle does not skip.
    rm -f "$AM_DIR/.gc_last"

    "$bin" >/dev/null 2>&1 || true

    assert_eq "false" "$(registry_exists test-am-stale-go && echo true || echo false)" \
        "go path: stale entry removed"
    assert_eq "true" "$(registry_exists "$live_session" && echo true || echo false)" \
        "go path: live entry preserved"
    assert_cmd_fails "go path: orphan state file removed" test -f "$state_dir/test-am-stale-go"
    assert_cmd_succeeds "go path: .gc_last marker written" test -f "$AM_DIR/.gc_last"

    # Throttle check: add another orphan, run again immediately, marker should block reap.
    registry_add "test-am-stale-go-2" "/tmp/gone-go-2" "main" "claude" ""
    "$bin" >/dev/null 2>&1 || true
    assert_eq "true" "$(registry_exists test-am-stale-go-2 && echo true || echo false)" \
        "go path: throttle keeps stale entry within 60s"

    [[ -n "$live_session" ]] && agent_kill "$live_session" 2>/dev/null
    rm -rf "$test_dir"
    teardown_integration_env

    $SUMMARY_MODE || echo ""
}

test_auto_title_session() {
    $SUMMARY_MODE || echo ""
    $SUMMARY_MODE || echo "=== Auto-Title Session Tests ==="

    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/registry.sh"

    setup_isolated_am_dir

    # Use production title functions directly (sourced from lib/registry.sh)

    # --- Test 1: Title validation - length check ---
    assert_cmd_succeeds "title_gen: accepts valid short title" \
        _title_valid "Short title"
    assert_cmd_fails "title_gen: rejects title >60 chars" \
        _title_valid "This is a really really really really really really really long title over 60 chars"

    # --- Test 2: Title validation - newline check ---
    assert_cmd_fails "title_gen: rejects multiline titles" \
        _title_valid $'Multi\nline'

    # --- Test 3: Integration - registry update on successful title ---
    registry_add "test-title-reg" "/tmp/test" "main" "claude" ""
    registry_update "test-title-reg" "task" "Refactor API layer"
    local stored_task
    stored_task=$(registry_get_field "test-title-reg" "task")
    assert_eq "Refactor API layer" "$stored_task" \
        "title_gen: registry_update persists title"

    teardown_isolated_am_dir

    $SUMMARY_MODE || echo ""
}

# ============================================
# Test: auto_title_scan (piggyback scanner)
# ============================================
test_auto_title_scan() {
    $SUMMARY_MODE || echo ""
    $SUMMARY_MODE || echo "=== Auto-Title Scan Tests ==="

    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/registry.sh"

    setup_isolated_am_dir

    # Stub tmux_pane_title to return titles based on session name
    tmux_pane_title() {
        local target="$1"
        case "$target" in
            test-scan-1:*) echo "Fix the login bug in auth" ;;
            test-scan-2:*) echo "Updated title from pane" ;;
            test-scan-3:*) echo "" ;;
            test-scan-4:*) echo "Throttle test title" ;;
            test-scan-5:*) echo "First scanned title" ;;
            test-scan-6:*) echo "Existing Title" ;;
            test-scan-7:*) echo ">>> Clean up the mess" ;;
            test-scan-10:*) echo "Stale JSONL guard" ;;
            test-scan-11:*) echo "Sidecar session id" ;;
            test-scan-12:*) echo "Sidecar pending JSONL" ;;
            test-scan-13:*) echo "Title that must not land" ;;
            *) echo "" ;;
        esac
    }
    tmux_session_pane_target() {
        echo "$1:.{top}"
    }
    tmux_capture_pane() {
        local target="$1"
        case "$target" in
            test-scan-10:*) echo "snapshot for test-scan-10" ;;
            test-scan-11:*) echo "snapshot for test-scan-11" ;;
            test-scan-12:*) echo "snapshot for test-scan-12" ;;
            test-scan-13:*) echo "snapshot for test-scan-13" ;;
            test-scan-14:*) echo "snapshot for test-scan-14" ;;
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
    # Isolate HOME so the JSONL fallback can't find a real Claude project dir
    # that happens to match /tmp/project on the developer's machine.
    local old_home_2="$HOME"
    export HOME="$AM_DIR/fake_home_2"
    mkdir -p "$HOME"
    registry_add "test-scan-3" "/tmp/project" "main" "claude" ""
    auto_title_scan 1
    task=$(registry_get_field "test-scan-3" "task")
    export HOME="$old_home_2"
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

    # --- Test 5: Sets first title for an untitled session ---
    registry_add "test-scan-5" "/tmp/scanproject" "dev" "codex" ""
    auto_title_scan 1
    task=$(registry_get_field "test-scan-5" "task")
    assert_eq "First scanned title" "$task" \
        "scan: sets first title"

    # --- Test 6: Does not update if pane title unchanged ---
    registry_add "test-scan-6" "/tmp/project" "main" "claude" "Existing Title"
    auto_title_scan 1
    task=$(registry_get_field "test-scan-6" "task")
    assert_eq "Existing Title" "$task" \
        "scan: no update when pane title matches existing task"

    # --- Test 7: Trims leading non-alphanumeric characters from pane title ---
    registry_add "test-scan-7" "/tmp/project" "main" "claude" ""
    auto_title_scan 1
    task=$(registry_get_field "test-scan-7" "task")
    assert_eq "Clean up the mess" "$task" \
        "scan: trims leading non-alphanumeric chars from pane title"

    # --- Test 8: JSONL fallback when pane title is empty (Claude only) ---
    # Set up a fake Claude project dir with a JSONL whose first user message
    # should be used as the task.
    local fake_home_8="$AM_DIR/fake_home_8"
    local fake_dir_8="/tmp/jsonl-fallback-test-8"
    local fake_proj_8
    fake_proj_8="${fake_dir_8//\//-}"
    fake_proj_8="${fake_proj_8//./-}"
    mkdir -p "$fake_home_8/.claude/projects/$fake_proj_8"
    printf '%s\n' '{"type":"user","message":{"content":"Investigate JSONL fallback path"}}' \
        > "$fake_home_8/.claude/projects/$fake_proj_8/test.jsonl"
    local old_home_8="$HOME"
    export HOME="$fake_home_8"
    registry_add "test-scan-8" "$fake_dir_8" "main" "claude" ""
    auto_title_scan 1
    task=$(registry_get_field "test-scan-8" "task")
    export HOME="$old_home_8"
    assert_eq "Investigate JSONL fallback path" "$task" \
        "scan: falls back to Claude JSONL first user message when pane title empty"

    # --- Test 9: No JSONL fallback for non-Claude agents ---
    local fake_home_9="$AM_DIR/fake_home_9"
    local fake_dir_9="/tmp/jsonl-fallback-test-9"
    local fake_proj_9
    fake_proj_9="${fake_dir_9//\//-}"
    fake_proj_9="${fake_proj_9//./-}"
    mkdir -p "$fake_home_9/.claude/projects/$fake_proj_9"
    printf '%s\n' '{"type":"user","message":{"content":"Should not appear"}}' \
        > "$fake_home_9/.claude/projects/$fake_proj_9/test.jsonl"
    local old_home_9="$HOME"
    export HOME="$fake_home_9"
    registry_add "test-scan-9" "$fake_dir_9" "main" "codex" ""
    auto_title_scan 1
    task=$(registry_get_field "test-scan-9" "task")
    export HOME="$old_home_9"
    assert_eq "" "$task" \
        "scan: no JSONL fallback for non-Claude agents"

    # --- Test 10: A pre-existing JSONL from the same directory is not this session ---
    local fake_home_10="$AM_DIR/fake_home_10"
    local fake_dir_10="$AM_DIR/jsonl-stale-project"
    local fake_real_10 fake_proj_10
    mkdir -p "$fake_dir_10"
    fake_real_10=$(cd "$fake_dir_10" && pwd -P)
    fake_proj_10="${fake_real_10//\//-}"
    fake_proj_10="${fake_proj_10//./-}"
    mkdir -p "$fake_home_10/.claude/projects/$fake_proj_10"
    printf '%s\n' '{"sessionId":"sid-old","type":"user","message":{"content":"Old session"}}' \
        > "$fake_home_10/.claude/projects/$fake_proj_10/sid-old.jsonl"
    touch -t 200001010000.00 "$fake_home_10/.claude/projects/$fake_proj_10/sid-old.jsonl"
    local old_home_10="$HOME"
    export HOME="$fake_home_10"
    registry_add "test-scan-10" "$fake_dir_10" "main" "claude" ""
    sessions_log_append "test-scan-10" "$fake_dir_10" "main" "claude" ""
    auto_title_scan 1
    local sid_10 snap_10 snap_content_10
    sid_10=$(jq -r 'select(.session_name == "test-scan-10") | .session_id' "$AM_SESSIONS_LOG")
    snap_10=$(jq -r 'select(.session_name == "test-scan-10") | .snapshot_file' "$AM_SESSIONS_LOG")
    snap_content_10=$(cat "$AM_DIR/$snap_10" 2>/dev/null || true)
    export HOME="$old_home_10"
    assert_eq "" "$sid_10" \
        "scan: does not backfill a stale directory JSONL into a newer session"
    assert_eq "snapshots/test-scan-10.txt" "$snap_10" \
        "scan: snapshots by am session until Claude session id is known"
    assert_contains "$snap_content_10" "snapshot for test-scan-10" \
        "scan: keeps the new session snapshot separate from stale JSONL"

    # --- Test 11: Hook sidecar disambiguates two plausible JSONLs in one directory ---
    local fake_home_11="$AM_DIR/fake_home_11"
    local fake_dir_11="$AM_DIR/jsonl-sidecar-project"
    local fake_real_11 fake_proj_11
    mkdir -p "$fake_dir_11"
    fake_real_11=$(cd "$fake_dir_11" && pwd -P)
    fake_proj_11="${fake_real_11//\//-}"
    fake_proj_11="${fake_proj_11//./-}"
    mkdir -p "$fake_home_11/.claude/projects/$fake_proj_11" "$AM_STATE_DIR"
    local old_home_11="$HOME"
    export HOME="$fake_home_11"
    registry_add "test-scan-11" "$fake_dir_11" "main" "claude" ""
    sessions_log_append "test-scan-11" "$fake_dir_11" "main" "claude" ""
    printf '%s\n' '{"sessionId":"sid-correct","type":"user","message":{"content":"Correct session"}}' \
        > "$fake_home_11/.claude/projects/$fake_proj_11/sid-correct.jsonl"
    printf '%s\n' '{"sessionId":"sid-other","type":"user","message":{"content":"Other same-dir session"}}' \
        > "$fake_home_11/.claude/projects/$fake_proj_11/sid-other.jsonl"
    # Backdate sid-correct so sid-other is strictly newer (mtime has 1s
    # resolution) — the sidecar must beat the newest same-directory JSONL.
    touch -t 202001010000.00 "$fake_home_11/.claude/projects/$fake_proj_11/sid-correct.jsonl"
    printf '%s' "sid-correct" > "$AM_STATE_DIR/test-scan-11.sid"
    auto_title_scan 1
    local sid_11 snap_11 snap_content_11
    sid_11=$(jq -r 'select(.session_name == "test-scan-11") | .session_id' "$AM_SESSIONS_LOG")
    snap_11=$(jq -r 'select(.session_name == "test-scan-11") | .snapshot_file' "$AM_SESSIONS_LOG")
    snap_content_11=$(cat "$AM_DIR/$snap_11" 2>/dev/null || true)
    export HOME="$old_home_11"
    assert_eq "sid-correct" "$sid_11" \
        "scan: sidecar session id wins over newer same-directory JSONL"
    assert_eq "snapshots/sid-correct.txt" "$snap_11" \
        "scan: snapshot uses the sidecar Claude session id"
    assert_contains "$snap_content_11" "snapshot for test-scan-11" \
        "scan: writes the disambiguated session snapshot"

    # --- Test 12: If sidecar exists but JSONL is pending, do not guess by directory ---
    local fake_home_12="$AM_DIR/fake_home_12"
    local fake_dir_12="$AM_DIR/jsonl-pending-sidecar-project"
    local fake_real_12 fake_proj_12
    mkdir -p "$fake_dir_12"
    fake_real_12=$(cd "$fake_dir_12" && pwd -P)
    fake_proj_12="${fake_real_12//\//-}"
    fake_proj_12="${fake_proj_12//./-}"
    mkdir -p "$fake_home_12/.claude/projects/$fake_proj_12" "$AM_STATE_DIR"
    local old_home_12="$HOME"
    export HOME="$fake_home_12"
    registry_add "test-scan-12" "$fake_dir_12" "main" "claude" ""
    sessions_log_append "test-scan-12" "$fake_dir_12" "main" "claude" ""
    printf '%s\n' '{"sessionId":"sid-other","type":"user","message":{"content":"Other same-dir session"}}' \
        > "$fake_home_12/.claude/projects/$fake_proj_12/sid-other.jsonl"
    printf '%s' "sid-pending" > "$AM_STATE_DIR/test-scan-12.sid"
    auto_title_scan 1
    local sid_12 snap_12 snap_content_12
    sid_12=$(jq -r 'select(.session_name == "test-scan-12") | .session_id' "$AM_SESSIONS_LOG")
    snap_12=$(jq -r 'select(.session_name == "test-scan-12") | .snapshot_file' "$AM_SESSIONS_LOG")
    snap_content_12=$(cat "$AM_DIR/$snap_12" 2>/dev/null || true)
    export HOME="$old_home_12"
    assert_eq "" "$sid_12" \
        "scan: sidecar without JSONL suppresses directory-wide guessing"
    assert_eq "snapshots/test-scan-12.txt" "$snap_12" \
        "scan: pending sidecar snapshots by am session name"
    assert_contains "$snap_content_12" "snapshot for test-scan-12" \
        "scan: pending sidecar keeps snapshot isolated"

    # --- Test 13: Fresh .title_scan_last (e.g. stamped by Go RefreshTitles)
    # must not starve the bash-only snapshot/backfill work, which runs on its
    # own marker (.restore_scan_last).
    local fake_home_13="$AM_DIR/fake_home_13"
    mkdir -p "$fake_home_13"
    local old_home_13="$HOME"
    export HOME="$fake_home_13"
    registry_add "test-scan-13" "/tmp/project13" "main" "claude" "task 13"
    sessions_log_append "test-scan-13" "/tmp/project13" "main" "claude" ""
    date +%s > "$AM_DIR/.title_scan_last"
    rm -f "$AM_DIR/.restore_scan_last"
    auto_title_scan  # unforced: title half throttled, restore half must run
    local snap_13
    snap_13=$(jq -r 'select(.session_name == "test-scan-13") | .snapshot_file' "$AM_SESSIONS_LOG" | tail -n1)
    task=$(registry_get_field "test-scan-13" "task")
    export HOME="$old_home_13"
    assert_eq "snapshots/test-scan-13.txt" "$snap_13" \
        "scan: restore snapshot captured despite fresh .title_scan_last"
    assert_eq "task 13" "$task" \
        "scan: title half stays throttled by fresh .title_scan_last"

    # --- Test 14: Sidecar corrects a wrong (previously guessed) session_id ---
    local fake_home_14="$AM_DIR/fake_home_14"
    local fake_dir_14="$AM_DIR/jsonl-correction-project"
    local fake_real_14 fake_proj_14
    mkdir -p "$fake_dir_14"
    fake_real_14=$(cd "$fake_dir_14" && pwd -P)
    fake_proj_14="${fake_real_14//\//-}"
    fake_proj_14="${fake_proj_14//./-}"
    mkdir -p "$fake_home_14/.claude/projects/$fake_proj_14" "$AM_STATE_DIR"
    local old_home_14="$HOME"
    export HOME="$fake_home_14"
    registry_add "test-scan-14" "$fake_dir_14" "main" "claude" ""
    sessions_log_append "test-scan-14" "$fake_dir_14" "main" "claude" ""
    printf '%s\n' '{"sessionId":"sid-wrong","type":"user","message":{"content":"Wrong conversation"}}' \
        > "$fake_home_14/.claude/projects/$fake_proj_14/sid-wrong.jsonl"
    printf '%s\n' '{"sessionId":"sid-right","type":"user","message":{"content":"Right conversation"}}' \
        > "$fake_home_14/.claude/projects/$fake_proj_14/sid-right.jsonl"
    sessions_log_update "test-scan-14" "session_id" "sid-wrong"
    printf '%s' "sid-right" > "$AM_STATE_DIR/test-scan-14.sid"
    auto_title_scan 1
    local sid_14 snap_14
    sid_14=$(jq -r 'select(.session_name == "test-scan-14") | .session_id' "$AM_SESSIONS_LOG")
    snap_14=$(jq -r 'select(.session_name == "test-scan-14") | .snapshot_file' "$AM_SESSIONS_LOG")
    export HOME="$old_home_14"
    assert_eq "sid-right" "$sid_14" \
        "scan: sidecar corrects a wrong logged session_id"
    assert_eq "snapshots/sid-right.txt" "$snap_14" \
        "scan: snapshot re-keyed to the corrected session_id"

    # --- Test 15: No mtime guess when another Claude session shares the directory ---
    local fake_home_15="$AM_DIR/fake_home_15"
    local fake_dir_15="$AM_DIR/jsonl-shared-project"
    local fake_real_15 fake_proj_15
    mkdir -p "$fake_dir_15"
    fake_real_15=$(cd "$fake_dir_15" && pwd -P)
    fake_proj_15="${fake_real_15//\//-}"
    fake_proj_15="${fake_proj_15//./-}"
    mkdir -p "$fake_home_15/.claude/projects/$fake_proj_15"
    local old_home_15="$HOME"
    export HOME="$fake_home_15"
    registry_add "test-scan-15a" "$fake_dir_15" "main" "claude" ""
    registry_add "test-scan-15b" "$fake_dir_15" "main" "claude" ""
    sessions_log_append "test-scan-15a" "$fake_dir_15" "main" "claude" ""
    # Fresh JSONL that the mtime fallback would otherwise claim for 15a —
    # but it may belong to 15b, so no sidecar means no guess.
    printf '%s\n' '{"sessionId":"sid-ambiguous","type":"user","message":{"content":"Whose is this?"}}' \
        > "$fake_home_15/.claude/projects/$fake_proj_15/sid-ambiguous.jsonl"
    auto_title_scan 1
    local sid_15
    sid_15=$(jq -r 'select(.session_name == "test-scan-15a") | .session_id' "$AM_SESSIONS_LOG")
    export HOME="$old_home_15"
    assert_eq "" "$sid_15" \
        "scan: no session_id guess when the directory is shared by another Claude session"

    # --- Cleanup ---
    unset -f tmux_pane_title tmux_session_pane_target tmux_capture_pane
    teardown_isolated_am_dir

    $SUMMARY_MODE || echo ""
}

# ============================================
# Test: agent_kill session-id binding
# ============================================
test_agent_kill_sid_binding() {
    $SUMMARY_MODE || echo "=== Testing agent_kill session-id binding ==="

    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/registry.sh"
    set +u; source "$LIB_DIR/agents.sh"; set -u

    setup_isolated_am_dir
    mkdir -p "$AM_STATE_DIR"

    # Stub tmux + sidebar so agent_kill runs without a real tmux server
    tmux_session_exists() { return 0; }
    tmux_kill_session() { return 0; }
    tmux_session_pane_target() { echo "$1:.{top}"; }
    tmux_capture_pane() { echo "final pane content for kill test"; }
    am_refresh_sidebar_cache() { return 0; }

    local fake_home="$AM_DIR/fake_home_kill"
    local fake_dir="$AM_DIR/kill-shared-project"
    local fake_real fake_proj
    mkdir -p "$fake_dir"
    fake_real=$(cd "$fake_dir" && pwd -P)
    fake_proj="${fake_real//\//-}"
    fake_proj="${fake_proj//./-}"
    mkdir -p "$fake_home/.claude/projects/$fake_proj"
    local old_home="$HOME"
    export HOME="$fake_home"

    # Session with a correct logged sid whose sidecar has vanished; a strictly
    # newer same-directory JSONL from another conversation is the bait the old
    # kill-time detection used to swallow.
    registry_add "test-kill-1" "$fake_dir" "main" "claude" ""
    sessions_log_append "test-kill-1" "$fake_dir" "main" "claude" ""
    printf '%s\n' '{"sessionId":"sid-mine","type":"user","message":{"content":"Mine"}}' \
        > "$fake_home/.claude/projects/$fake_proj/sid-mine.jsonl"
    printf '%s\n' '{"sessionId":"sid-other","type":"user","message":{"content":"Other"}}' \
        > "$fake_home/.claude/projects/$fake_proj/sid-other.jsonl"
    touch -t 202001010000.00 "$fake_home/.claude/projects/$fake_proj/sid-mine.jsonl"
    sessions_log_update "test-kill-1" "session_id" "sid-mine"

    agent_kill "test-kill-1" 2>/dev/null

    local sid snap
    sid=$(jq -r 'select(.session_name == "test-kill-1") | .session_id' "$AM_SESSIONS_LOG")
    snap=$(jq -r 'select(.session_name == "test-kill-1") | .snapshot_file' "$AM_SESSIONS_LOG")
    assert_eq "sid-mine" "$sid" \
        "kill: logged session_id survives when the sidecar is gone"
    assert_eq "snapshots/sid-mine.txt" "$snap" \
        "kill: final snapshot keyed by the logged session_id"

    export HOME="$old_home"
    unset -f tmux_session_exists tmux_kill_session tmux_session_pane_target \
        tmux_capture_pane am_refresh_sidebar_cache
    teardown_isolated_am_dir

    $SUMMARY_MODE || echo ""
}

run_registry_tests() {
    _run_test test_registry
    _run_test test_registry_extended
    _run_test test_registry_get_fields
    _run_test test_registry_gc
    _run_test test_registry_gc_go_path
    _run_test test_auto_title_session
    _run_test test_auto_title_scan
    _run_test test_agent_kill_sid_binding
}

if [[ -z "${_AM_TEST_RUNNER:-}" ]]; then
    set -uo pipefail
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helpers.sh"
    check_deps
    run_registry_tests
    test_report
fi
