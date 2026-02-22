# Automated Test Plan Implementation

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add ~36 regression tests covering session lifecycle, registry edge cases, agent commands, CLI commands, and GC — tripling test count from 22 to ~58.

**Architecture:** Extend existing `tests/test_all.sh` with new test functions. Integration tests use a stub agent script (replaces real AI agents), isolated `AM_DIR`, and real tmux sessions. Cleanup via trap-based teardown.

**Tech Stack:** Bash, tmux, jq, fzf (existing deps only)

---

### Task 1: Add test infrastructure

**Files:**
- Create: `tests/stub_agent`
- Modify: `tests/test_all.sh:22-98` (add helpers after existing assert functions)

**Step 1: Create stub agent script**

Create `tests/stub_agent` — a minimal script that pretends to be an AI agent:

```bash
#!/usr/bin/env bash
# stub_agent - Fake agent for integration tests
# Stays alive until killed, prints a marker so tests can verify it started
echo "stub-agent-ready"
exec tail -f /dev/null
```

Make it executable: `chmod +x tests/stub_agent`

**Step 2: Add test helper functions to test_all.sh**

Add these helpers after the `check_deps()` function (after line 98), before the first test group:

```bash
# ============================================
# Integration test helpers
# ============================================

# Assert a command fails (non-zero exit)
assert_cmd_fails() {
    local msg="$1"
    shift
    ((TESTS_RUN++))
    if "$@" &>/dev/null; then
        echo -e "${RED}FAIL${RESET}: $msg (expected failure, got success)"
        ((TESTS_FAILED++))
    else
        echo -e "${GREEN}PASS${RESET}: $msg"
        ((TESTS_PASSED++))
    fi
}

# Setup isolated test environment for integration tests
# Sets AM_DIR to a temp dir, creates stub agent, overrides AGENT_COMMANDS
# Usage: setup_integration_env
# After calling, use $TEST_AM_DIR, $TEST_STUB_DIR
setup_integration_env() {
    TEST_AM_DIR=$(mktemp -d)
    TEST_STUB_DIR="$SCRIPT_DIR"  # stub_agent lives in tests/

    export AM_DIR="$TEST_AM_DIR"
    export AM_REGISTRY="$AM_DIR/sessions.json"
    am_init

    # Point agent commands to stub
    AGENT_COMMANDS[claude]="$TEST_STUB_DIR/stub_agent"
    AGENT_COMMANDS[codex]="$TEST_STUB_DIR/stub_agent"
    AGENT_COMMANDS[gemini]="$TEST_STUB_DIR/stub_agent"
}

# Tear down integration test environment
# Kills any test-created tmux sessions, removes temp dirs
# Usage: teardown_integration_env
teardown_integration_env() {
    # Kill all am- sessions registered in test registry
    if [[ -f "$AM_REGISTRY" ]]; then
        local session
        for session in $(jq -r '.sessions | keys[]' "$AM_REGISTRY" 2>/dev/null); do
            tmux kill-session -t "$session" 2>/dev/null || true
        done
    fi

    # Restore AM_DIR
    rm -rf "$TEST_AM_DIR"
    export AM_DIR="${HOME}/.agent-manager"
    export AM_REGISTRY="$AM_DIR/sessions.json"
}
```

**Step 3: Run existing tests to verify nothing broke**

Run: `./tests/test_all.sh`
Expected: All 22 existing tests pass.

**Step 4: Commit**

```bash
git add tests/stub_agent tests/test_all.sh
git commit -m "Add test infrastructure: stub agent and integration helpers"
```

---

### Task 2: Add extended utils unit tests

**Files:**
- Modify: `tests/test_all.sh` (add `test_utils_extended()` function after `test_utils`)

**Step 1: Write the test function**

Add after the existing `test_utils()` function:

```bash
# ============================================
# Test: utils.sh (extended edge cases)
# ============================================
test_utils_extended() {
    echo "=== Testing utils.sh (extended) ==="
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
        echo -e "${GREEN}PASS${RESET}: generate_hash: different inputs different output"
    else
        ((TESTS_RUN++)); ((TESTS_FAILED++))
        echo -e "${RED}FAIL${RESET}: generate_hash: different inputs produced same hash"
    fi

    # abspath: with real directories
    local tmpd=$(mktemp -d)
    assert_eq "$tmpd" "$(abspath "$tmpd")" "abspath: absolute path unchanged"
    rm -rf "$tmpd"

    echo ""
}
```

**Step 2: Register the new test in main()**

In the `main()` function, add `test_utils_extended` after `test_utils`:

```bash
    test_utils
    test_utils_extended
```

**Step 3: Run tests**

Run: `./tests/test_all.sh`
Expected: All tests pass (existing 22 + new ~11 = ~33).

**Step 4: Commit**

```bash
git add tests/test_all.sh
git commit -m "Add extended utils unit tests: edge cases for time, truncate, hash"
```

---

### Task 3: Add extended registry unit tests

**Files:**
- Modify: `tests/test_all.sh` (add `test_registry_extended()` after `test_registry`)

**Step 1: Write the test function**

```bash
# ============================================
# Test: registry.sh (extended edge cases)
# ============================================
test_registry_extended() {
    echo "=== Testing registry.sh (extended) ==="

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
    export AM_DIR=$(mktemp -d)
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

    echo ""
}
```

**Step 2: Register in main()**

Add `test_registry_extended` after `test_registry`.

**Step 3: Run tests**

Run: `./tests/test_all.sh`
Expected: All tests pass.

**Step 4: Commit**

```bash
git add tests/test_all.sh
git commit -m "Add extended registry tests: edge cases, duplicates, rapid writes"
```

---

### Task 4: Add extended agent unit tests

**Files:**
- Modify: `tests/test_all.sh` (add `test_agents_extended()` after `test_agents`)

**Step 1: Write the test function**

```bash
# ============================================
# Test: agents.sh (extended)
# ============================================
test_agents_extended() {
    echo "=== Testing agents.sh (extended) ==="

    if ! command -v jq &>/dev/null || ! command -v tmux &>/dev/null; then
        skip_test "agents extended tests (jq or tmux not installed)"
        echo ""
        return
    fi

    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/tmux.sh"
    source "$LIB_DIR/registry.sh"
    source "$LIB_DIR/agents.sh"

    # Test agent_type_supported
    assert_eq "true" "$(agent_type_supported claude && echo true || echo false)" \
        "agent_type_supported: claude"
    assert_eq "true" "$(agent_type_supported codex && echo true || echo false)" \
        "agent_type_supported: codex"
    assert_eq "true" "$(agent_type_supported gemini && echo true || echo false)" \
        "agent_type_supported: gemini"
    assert_eq "false" "$(agent_type_supported bogus && echo true || echo false)" \
        "agent_type_supported: bogus rejected"

    # Test generate_session_name: different dirs give different names
    local name1=$(generate_session_name "/tmp/project-a")
    local name2=$(generate_session_name "/tmp/project-b")
    if [[ "$name1" != "$name2" ]]; then
        ((TESTS_RUN++)); ((TESTS_PASSED++))
        echo -e "${GREEN}PASS${RESET}: generate_session_name: different dirs different names"
    else
        ((TESTS_RUN++)); ((TESTS_FAILED++))
        echo -e "${RED}FAIL${RESET}: generate_session_name: collision for different dirs"
    fi

    # Test generate_session_name format: am-XXXXXX
    local name=$(generate_session_name "/tmp/test")
    assert_contains "$name" "am-" "generate_session_name: starts with am-"
    assert_eq 9 "${#name}" "generate_session_name: length is 9 (am- + 6)"

    # Test agent_get_yolo_flag for gemini (uses default --yolo)
    assert_eq "--yolo" "$(agent_get_yolo_flag gemini)" "agent_get_yolo_flag: gemini"

    echo ""
}
```

**Step 2: Register in main()**

Add `test_agents_extended` after `test_agents`.

**Step 3: Run tests**

Run: `./tests/test_all.sh`
Expected: All tests pass.

**Step 4: Commit**

```bash
git add tests/test_all.sh
git commit -m "Add extended agent tests: type validation, name uniqueness, yolo flags"
```

---

### Task 5: Add integration tests — session lifecycle

This is the highest-value test group. Tests `agent_launch`, `agent_kill`, and `agent_kill_all` with real tmux sessions and the stub agent.

**Files:**
- Modify: `tests/test_all.sh` (add `test_integration_lifecycle()`)

**Step 1: Write the test function**

```bash
# ============================================
# Test: Integration - Session Lifecycle
# ============================================
test_integration_lifecycle() {
    echo "=== Testing Integration: Session Lifecycle ==="

    if ! command -v jq &>/dev/null || ! command -v tmux &>/dev/null; then
        skip_test "integration lifecycle tests (jq or tmux not installed)"
        echo ""
        return
    fi

    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/tmux.sh"
    source "$LIB_DIR/registry.sh"
    source "$LIB_DIR/agents.sh"

    setup_integration_env
    # Trap ensures cleanup even on test failure
    trap teardown_integration_env RETURN

    local test_dir=$(mktemp -d)

    # --- Test: agent_launch creates session ---
    local session_name
    session_name=$(agent_launch "$test_dir" "claude" "test task" 2>/dev/null)
    assert_not_empty "$session_name" "agent_launch: returns session name"

    # Verify tmux session exists
    assert_eq "true" "$(tmux_session_exists "$session_name" && echo true || echo false)" \
        "agent_launch: tmux session exists"

    # Verify registry entry
    assert_eq "true" "$(registry_exists "$session_name" && echo true || echo false)" \
        "agent_launch: registry entry exists"

    # Verify registry fields
    assert_eq "$test_dir" "$(registry_get_field "$session_name" directory)" \
        "agent_launch: correct directory in registry"
    assert_eq "claude" "$(registry_get_field "$session_name" agent_type)" \
        "agent_launch: correct agent_type in registry"
    assert_eq "test task" "$(registry_get_field "$session_name" task)" \
        "agent_launch: correct task in registry"

    # Verify two panes (agent top + shell bottom)
    local pane_count
    pane_count=$(tmux list-panes -t "$session_name" 2>/dev/null | wc -l | tr -d ' ')
    assert_eq "2" "$pane_count" "agent_launch: two panes created"

    # --- Test: agent_kill cleans up ---
    agent_kill "$session_name" 2>/dev/null
    assert_eq "false" "$(tmux_session_exists "$session_name" && echo true || echo false)" \
        "agent_kill: tmux session removed"
    assert_eq "false" "$(registry_exists "$session_name" && echo true || echo false)" \
        "agent_kill: registry entry removed"

    # --- Test: agent_kill_all ---
    local s1 s2
    s1=$(agent_launch "$test_dir" "claude" "" 2>/dev/null)
    s2=$(agent_launch "$test_dir" "claude" "" 2>/dev/null)
    assert_not_empty "$s1" "agent_kill_all: first session created"
    assert_not_empty "$s2" "agent_kill_all: second session created"

    local killed
    killed=$(agent_kill_all 2>/dev/null)
    assert_eq "false" "$(tmux_session_exists "$s1" && echo true || echo false)" \
        "agent_kill_all: first session removed"
    assert_eq "false" "$(tmux_session_exists "$s2" && echo true || echo false)" \
        "agent_kill_all: second session removed"

    # Cleanup
    rm -rf "$test_dir"

    echo ""
}
```

**Step 2: Register in main()**

Add `test_integration_lifecycle` after `test_cli`.

**Step 3: Run tests**

Run: `./tests/test_all.sh`
Expected: All tests pass. The integration tests should create/verify/kill tmux sessions in ~2-3 seconds total.

**Step 4: Commit**

```bash
git add tests/test_all.sh
git commit -m "Add integration tests: session launch, kill, kill-all lifecycle"
```

---

### Task 6: Add integration tests — CLI commands

Tests the `am` script as a subprocess with isolated AM_DIR.

**Files:**
- Modify: `tests/test_all.sh` (add `test_cli_extended()`)

**Step 1: Write the test function**

```bash
# ============================================
# Test: CLI commands (extended)
# ============================================
test_cli_extended() {
    echo "=== Testing CLI commands (extended) ==="

    if ! command -v jq &>/dev/null || ! command -v tmux &>/dev/null; then
        skip_test "cli extended tests (jq or tmux not installed)"
        echo ""
        return
    fi

    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/tmux.sh"
    source "$LIB_DIR/registry.sh"
    source "$LIB_DIR/agents.sh"

    setup_integration_env
    trap teardown_integration_env RETURN

    local test_dir=$(mktemp -d)

    # Create a session for testing against
    local session_name
    session_name=$(agent_launch "$test_dir" "claude" "cli test" 2>/dev/null)

    # --- Test: am list --json returns valid JSON ---
    local json_output
    json_output=$(AM_DIR="$TEST_AM_DIR" "$PROJECT_DIR/am" list --json 2>/dev/null)
    assert_cmd_succeeds "am list --json: valid JSON" echo "$json_output" | jq . > /dev/null 2>&1
    assert_contains "$json_output" "$session_name" "am list --json: contains session"

    # --- Test: am info <session> ---
    local info_output
    info_output=$(AM_DIR="$TEST_AM_DIR" "$PROJECT_DIR/am" info "$session_name" 2>/dev/null)
    assert_contains "$info_output" "Directory:" "am info: shows directory"
    assert_contains "$info_output" "Agent:" "am info: shows agent type"

    # --- Test: am kill <session> ---
    AM_DIR="$TEST_AM_DIR" "$PROJECT_DIR/am" kill "$session_name" 2>/dev/null
    assert_eq "false" "$(tmux_session_exists "$session_name" && echo true || echo false)" \
        "am kill: session removed"

    # --- Test: am attach nonexistent fails ---
    local attach_output
    attach_output=$(AM_DIR="$TEST_AM_DIR" "$PROJECT_DIR/am" attach nonexistent-xyz 2>&1) || true
    assert_contains "$attach_output" "not found\|No session" "am attach: error for missing session"

    # --- Test: am kill with no args fails ---
    local kill_output
    kill_output=$(AM_DIR="$TEST_AM_DIR" "$PROJECT_DIR/am" kill 2>&1) || true
    assert_contains "$kill_output" "required\|Usage" "am kill: error with no args"

    # --- Test: am status runs without error ---
    assert_cmd_succeeds "am status: exits 0" \
        env AM_DIR="$TEST_AM_DIR" "$PROJECT_DIR/am" status

    # Cleanup
    rm -rf "$test_dir"

    echo ""
}
```

**Step 2: Register in main()**

Add `test_cli_extended` after `test_integration_lifecycle`.

**Step 3: Run tests**

Run: `./tests/test_all.sh`
Expected: All tests pass. Note: `am list --json` requires the session to have a valid tmux activity timestamp.

If the `assert_contains` for attach/kill error messages fails, adjust the expected strings to match actual error output. The code uses `log_error "No session found matching:"` and `log_error "Session name required"`, so both `"not found"` and `"required"` should match.

**Step 4: Commit**

```bash
git add tests/test_all.sh
git commit -m "Add CLI integration tests: list --json, info, kill, error cases"
```

---

### Task 7: Add integration tests — registry GC

Tests `registry_gc()` with stale entries, live sessions, and throttling.

**Files:**
- Modify: `tests/test_all.sh` (add `test_registry_gc()`)

**Step 1: Write the test function**

```bash
# ============================================
# Test: Integration - Registry GC
# ============================================
test_registry_gc() {
    echo "=== Testing Integration: Registry GC ==="

    if ! command -v jq &>/dev/null || ! command -v tmux &>/dev/null; then
        skip_test "registry GC tests (jq or tmux not installed)"
        echo ""
        return
    fi

    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/tmux.sh"
    source "$LIB_DIR/registry.sh"
    source "$LIB_DIR/agents.sh"

    setup_integration_env
    trap teardown_integration_env RETURN

    local test_dir=$(mktemp -d)

    # Create a live session
    local live_session
    live_session=$(agent_launch "$test_dir" "claude" "" 2>/dev/null)

    # Manually add a stale entry (no corresponding tmux session)
    registry_add "am-stale-fake" "/tmp/gone" "main" "claude" ""
    assert_eq "true" "$(registry_exists am-stale-fake && echo true || echo false)" \
        "gc setup: stale entry exists"

    # Run GC (force to bypass throttle)
    local removed
    removed=$(registry_gc 1)
    assert_eq "1" "$removed" "registry_gc: removed 1 stale entry"

    # Verify stale entry gone, live entry preserved
    assert_eq "false" "$(registry_exists am-stale-fake && echo true || echo false)" \
        "registry_gc: stale entry removed"
    assert_eq "true" "$(registry_exists "$live_session" && echo true || echo false)" \
        "registry_gc: live entry preserved"

    # --- Test: GC throttling ---
    # Add another stale entry
    registry_add "am-stale-fake-2" "/tmp/gone2" "main" "claude" ""

    # Run GC without force — should be throttled (within 60s of last run)
    removed=$(registry_gc)
    assert_eq "0" "$removed" "registry_gc: throttled within 60s"

    # Stale entry should still exist (GC was skipped)
    assert_eq "true" "$(registry_exists am-stale-fake-2 && echo true || echo false)" \
        "registry_gc: stale entry survives throttle"

    # Force GC should still work
    removed=$(registry_gc 1)
    assert_eq "1" "$removed" "registry_gc: force bypasses throttle"

    # Cleanup
    agent_kill "$live_session" 2>/dev/null
    rm -rf "$test_dir"

    echo ""
}
```

**Step 2: Register in main()**

Add `test_registry_gc` after `test_cli_extended`.

**Step 3: Run tests**

Run: `./tests/test_all.sh`
Expected: All tests pass.

**Step 4: Commit**

```bash
git add tests/test_all.sh
git commit -m "Add registry GC integration tests: stale cleanup, preservation, throttling"
```

---

### Task 8: Final verification and cleanup

**Step 1: Run the full test suite**

Run: `./tests/test_all.sh`
Expected: All ~58 tests pass. Output should show:

```
========================================
  Agent Manager Test Suite
========================================

=== Testing utils.sh ===
...
=== Testing utils.sh (extended) ===
...
=== Testing registry.sh ===
...
=== Testing registry.sh (extended) ===
...
=== Testing tmux.sh ===
...
=== Testing agents.sh ===
...
=== Testing agents.sh (extended) ===
...
=== Testing am CLI ===
...
=== Testing Integration: Session Lifecycle ===
...
=== Testing CLI commands (extended) ===
...
=== Testing Integration: Registry GC ===
...

========================================
  Results: XX/XX passed
  All tests passed!
========================================
```

**Step 2: Verify no leftover tmux sessions**

Run: `tmux list-sessions 2>/dev/null | grep '^am-' || echo "Clean"`
Expected: No am- test sessions remaining.

**Step 3: Verify test runs clean a second time**

Run: `./tests/test_all.sh`
Expected: Same result — tests are idempotent.

**Step 4: Final commit if any fixups were needed**

```bash
git add tests/
git commit -m "Fix test issues found during final verification"
```

---

## Summary: Test call order in main()

After all tasks, `main()` should call tests in this order:

```bash
main() {
    echo "========================================"
    echo "  Agent Manager Test Suite"
    echo "========================================"
    echo ""

    check_deps

    test_utils
    test_utils_extended
    test_registry
    test_registry_extended
    test_tmux
    test_agents
    test_agents_extended
    test_cli
    test_integration_lifecycle
    test_cli_extended
    test_registry_gc

    echo "========================================"
    echo "  Results: $TESTS_PASSED/$TESTS_RUN passed"
    ...
}
```

## Expected final test counts

| Group | Tests |
|-------|-------|
| utils (existing) | 8 |
| utils extended | 11 |
| registry (existing) | 7 |
| registry extended | 9 |
| tmux (existing) | 3 |
| agents (existing) | 4 |
| agents extended | 7 |
| cli (existing) | 3 |
| integration lifecycle | 13 |
| cli extended | 6 |
| registry gc | 8 |
| **Total** | **~79** |
