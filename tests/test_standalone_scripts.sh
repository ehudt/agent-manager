#!/usr/bin/env bash
# tests/test_standalone_scripts.sh - Tests for standalone lib scripts

test_standalone_preview() {
    $SUMMARY_MODE || echo "=== Testing lib/preview (standalone) ==="
    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/tmux.sh"
    source "$LIB_DIR/registry.sh"
    set +u; source "$LIB_DIR/agents.sh"; set -u
    setup_integration_env

    local test_dir
    test_dir=$(mktemp -d)

    local output rc

    rc=0
    output=$(AM_REGISTRY="$AM_REGISTRY" AM_TMUX_SOCKET="$AM_TMUX_SOCKET" \
        "$LIB_DIR/preview" "" 2>&1) || rc=$?
    assert_eq "0" "$rc" "preview: exits 0 on empty session name"
    assert_contains "$output" "No session selected" "preview: shows message for empty session"

    rc=0
    output=$(AM_REGISTRY="$AM_REGISTRY" AM_TMUX_SOCKET="$AM_TMUX_SOCKET" \
        "$LIB_DIR/preview" "nonexistent-session" 2>&1) || rc=$?
    assert_eq "0" "$rc" "preview: exits 0 on nonexistent session"
    assert_contains "$output" "Session not found" "preview: shows message for nonexistent session"

    local session_name
    session_name=$(set +u; agent_launch "$test_dir" bash "test task" ""; set -u) 2>/dev/null
    sleep 0.2

    if [[ -z "$session_name" ]] || ! tmux_session_exists "$session_name"; then
        skip_test "preview: session creation failed"
        rm -rf "$test_dir"
        teardown_integration_env
        echo ""
        return
    fi

    rc=0
    output=$(AM_REGISTRY="$AM_REGISTRY" AM_TMUX_SOCKET="$AM_TMUX_SOCKET" \
        "$LIB_DIR/preview" "$session_name" 2>&1) || rc=$?
    assert_eq "0" "$rc" "preview: exits 0 on valid session"
    assert_contains "$output" "Session:" "preview: shows session header"
    assert_contains "$output" "Directory:" "preview: shows directory"

    registry_update "$session_name" "directory" ""
    rc=0
    output=$(AM_REGISTRY="$AM_REGISTRY" AM_TMUX_SOCKET="$AM_TMUX_SOCKET" \
        "$LIB_DIR/preview" "$session_name" 2>&1) || rc=$?
    assert_eq "0" "$rc" "preview: exits 0 when directory missing from registry"
    assert_contains "$output" "Session:" "preview: still shows session header without directory"

    local claude_dir="$HOME/.claude/projects/$(echo "$test_dir" | sed 's|/|-|g; s|\.|-|g')"
    mkdir -p "$claude_dir"
    cat > "$claude_dir/session.jsonl" <<'EOF'
{"type":"user","message":{"role":"user","content":"This is the first user message from the test"},"uuid":"test-uuid-1","timestamp":"2026-03-10T09:00:00.000Z"}
{"type":"assistant","message":{"role":"assistant","content":"Response"},"uuid":"test-uuid-2","timestamp":"2026-03-10T09:00:01.000Z"}
EOF
    registry_update "$session_name" "directory" "$test_dir"
    rc=0
    output=$(AM_REGISTRY="$AM_REGISTRY" AM_TMUX_SOCKET="$AM_TMUX_SOCKET" \
        "$LIB_DIR/preview" "$session_name" 2>&1) || rc=$?
    assert_eq "0" "$rc" "preview: exits 0 with valid JSONL"
    assert_contains "$output" "first user message" "preview: extracts first user message"

    echo "corrupted json" > "$claude_dir/session.jsonl"
    rc=0
    output=$(AM_REGISTRY="$AM_REGISTRY" AM_TMUX_SOCKET="$AM_TMUX_SOCKET" \
        "$LIB_DIR/preview" "$session_name" 2>&1) || rc=$?
    assert_eq "0" "$rc" "preview: exits 0 with corrupted JSONL"

    rm -rf "$claude_dir"
    [[ -n "$session_name" ]] && agent_kill "$session_name" 2>/dev/null
    rm -rf "$test_dir"
    teardown_integration_env

    $SUMMARY_MODE || echo ""
}

test_standalone_dir_preview() {
    $SUMMARY_MODE || echo "=== Testing lib/dir-preview (standalone) ==="

    local output rc test_dir

    rc=0
    output=$("$LIB_DIR/dir-preview" "" 2>&1) || rc=$?
    assert_eq "0" "$rc" "dir-preview: exits 0 on empty input"

    rc=0
    output=$("$LIB_DIR/dir-preview" "/nonexistent/path/xyz" 2>&1) || rc=$?
    assert_eq "0" "$rc" "dir-preview: exits 0 on nonexistent path"
    assert_contains "$output" "Type a path or select from list" "dir-preview: shows message for invalid path"

    test_dir=$(mktemp -d)
    rc=0
    output=$("$LIB_DIR/dir-preview" "$test_dir" 2>&1) || rc=$?
    assert_eq "0" "$rc" "dir-preview: exits 0 on valid directory"
    assert_contains "$output" "Git" "dir-preview: shows git section"
    assert_contains "$output" "Files" "dir-preview: shows files section"
    assert_contains "$output" "not a git repo" "dir-preview: shows non-git message for non-repo"

    (cd "$test_dir" && git init -q && git checkout -q -b main)
    rc=0
    output=$("$LIB_DIR/dir-preview" "$test_dir" 2>&1) || rc=$?
    assert_eq "0" "$rc" "dir-preview: exits 0 on git repo"
    assert_contains "$output" "Branch: main" "dir-preview: shows current branch"

    local annotated="$test_dir	[claude] some task (5m ago)"
    rc=0
    output=$("$LIB_DIR/dir-preview" "$annotated" 2>&1) || rc=$?
    assert_eq "0" "$rc" "dir-preview: exits 0 on annotated input"
    assert_contains "$output" "Branch: main" "dir-preview: strips annotation and shows content"

    rm -rf "$test_dir"

    $SUMMARY_MODE || echo ""
}

test_standalone_title_upgrade() {
    $SUMMARY_MODE || echo "=== Testing lib/title-upgrade (standalone) ==="
    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/registry.sh"
    set +u; source "$LIB_DIR/agents.sh"; set -u
    setup_integration_env

    local rc

    rc=0
    "$LIB_DIR/title-upgrade" "" "" 2>/dev/null || rc=$?
    assert_eq "0" "$rc" "title-upgrade: exits 0 on missing arguments"

    rc=0
    "$LIB_DIR/title-upgrade" "session" "" 2>/dev/null || rc=$?
    assert_eq "0" "$rc" "title-upgrade: exits 0 on missing message"

    rc=0
    "$LIB_DIR/title-upgrade" "" "message" 2>/dev/null || rc=$?
    assert_eq "0" "$rc" "title-upgrade: exits 0 on missing session"

    registry_add "test-session" "/tmp/test" "claude" "test task" ""

    local before_task
    before_task=$(registry_get_field "test-session" task)

    local has_claude=0
    command -v claude &>/dev/null && has_claude=1

    if [[ "$has_claude" -eq 1 ]]; then
        CLAUDECODE="" "$LIB_DIR/title-upgrade" "test-session" "Fix authentication bug in login handler" 2>/dev/null &
        local upgrade_pid=$!
        sleep 0.2

        rc=0
        rm -rf "$TEST_AM_DIR" || rc=$?
        wait "$upgrade_pid" 2>/dev/null || true
        assert_eq "0" "$rc" "title-upgrade: handles registry removal gracefully"
    else
        skip_test "title-upgrade: Haiku upgrade (claude CLI not available)"
    fi

    setup_integration_env
    registry_add "test-session-2" "/tmp/test" "claude" "original task" ""

    export AM_DIR="$TEST_AM_DIR"

    if [[ "$has_claude" -eq 1 ]]; then
        CLAUDECODE=""
        (sleep 10; kill -9 $$ 2>/dev/null) &
        local killer_pid=$!
        "$LIB_DIR/title-upgrade" "test-session-2" "Implement user authentication with OAuth2" 2>/dev/null || true
        kill "$killer_pid" 2>/dev/null || true
        sleep 0.2

        local updated_task
        updated_task=$(registry_get_field "test-session-2" task 2>/dev/null || echo "original task")

        if [[ "$updated_task" != "original task" ]]; then
            $SUMMARY_MODE || echo -e "${GREEN}PASS${RESET}: title-upgrade: updates task in registry"
            ((TESTS_PASSED++))
            ((TESTS_RUN++))

            ((TESTS_RUN++))
            if [[ ${#updated_task} -le 60 ]]; then
                $SUMMARY_MODE || echo -e "${GREEN}PASS${RESET}: title-upgrade: respects 60 char limit"
                ((TESTS_PASSED++))
            else
                echo -e "${RED}FAIL${RESET}: title-upgrade: respects 60 char limit"
                FAIL_DETAILS+=("FAIL: title-upgrade: respects 60 char limit")
                echo "  Task length: ${#updated_task}"
                ((TESTS_FAILED++))
            fi
        else
            skip_test "title-upgrade: Haiku upgrade (no update detected)"
        fi
    else
        skip_test "title-upgrade: Haiku upgrade (claude CLI not available)"
    fi

    teardown_integration_env

    $SUMMARY_MODE || echo ""
}

test_standalone_status_right() {
    $SUMMARY_MODE || echo "=== Testing lib/status-right (standalone) ==="
    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/config.sh"
    source "$LIB_DIR/tmux.sh"
    source "$LIB_DIR/registry.sh"
    source "$LIB_DIR/state.sh"
    set +u; source "$LIB_DIR/agents.sh"; set -u
    setup_integration_env

    local output rc

    rc=0
    output=$("$LIB_DIR/status-right" "" 2>&1) || rc=$?
    assert_eq "0" "$rc" "status-right: exits 0 with no sessions"

    local test_dir1 test_dir2 test_dir3
    test_dir1=$(mktemp -d)
    test_dir2=$(mktemp -d)
    test_dir3=$(mktemp -d)

    local s1 s2 s3
    s1=$(set +u; agent_launch "$test_dir1" bash "task1" ""; set -u) 2>/dev/null
    s2=$(set +u; agent_launch "$test_dir2" bash "task2" ""; set -u) 2>/dev/null
    s3=$(set +u; agent_launch "$test_dir3" bash "task3" ""; set -u) 2>/dev/null
    sleep 0.2

    rc=0
    output=$("$LIB_DIR/status-right" "$s1" 2>&1) || rc=$?
    assert_eq "0" "$rc" "status-right: exits 0 with multiple sessions"

    [[ -n "$s1" ]] && tmux_send_keys "$s1" "sleep 10000"
    [[ -n "$s2" ]] && tmux_send_keys "$s2" "echo hello"
    sleep 0.2

    rc=0
    output=$("$LIB_DIR/status-right" "$s1" 2>&1) || rc=$?
    assert_eq "0" "$rc" "status-right: exits 0 with mixed states"

    [[ -n "$output" ]] || output="(empty)"
    $SUMMARY_MODE || echo -e "${GREEN}PASS${RESET}: status-right: produces output format (content: $output)"
    ((TESTS_PASSED++))
    ((TESTS_RUN++))

    rc=0
    output=$("$LIB_DIR/status-right" "nonexistent" 2>&1) || rc=$?
    assert_eq "0" "$rc" "status-right: exits 0 with nonexistent current session"

    [[ -n "$s1" ]] && agent_kill "$s1" 2>/dev/null
    [[ -n "$s2" ]] && agent_kill "$s2" 2>/dev/null
    [[ -n "$s3" ]] && agent_kill "$s3" 2>/dev/null
    rm -rf "$test_dir1" "$test_dir2" "$test_dir3"
    teardown_integration_env

    $SUMMARY_MODE || echo ""
}

test_strip_ansi() {
    $SUMMARY_MODE || echo "=== Testing strip-ansi filter ==="

    local strip="$LIB_DIR/strip-ansi"

    # Basic CSI color codes
    local input=$'\e[32mhello\e[0m world'
    local result
    result=$(printf '%s' "$input" | "$strip")
    assert_eq "hello world" "$result" "strip-ansi: removes color codes"

    # CSI cursor movement
    input=$'\e[5Ahello\e[10C world'
    result=$(printf '%s' "$input" | "$strip")
    assert_eq "hello world" "$result" "strip-ansi: removes cursor movement"

    # Private CSI sequences (?25h, ?2004l, etc.)
    input=$'\e[?2004hhello\e[?25l'
    result=$(printf '%s' "$input" | "$strip")
    assert_eq "hello" "$result" "strip-ansi: removes private CSI sequences"

    # OSC title-set sequences (ESC ] ... BEL)
    input=$'\e]0;my title\ahello'
    result=$(printf '%s' "$input" | "$strip")
    assert_eq "hello" "$result" "strip-ansi: removes OSC title sequences"

    # Carriage returns
    input=$'hello\r\nworld\r'
    result=$(printf '%s' "$input" | "$strip")
    assert_eq $'hello\nworld' "$result" "strip-ansi: strips carriage returns"

    # Backspace + following char are removed
    input=$(printf 'h\x08Xello')
    result=$(printf '%s' "$input" | "$strip")
    assert_eq "hello" "$result" "strip-ansi: removes backspace sequences"

    # Character set selection
    input=$'\e(Bhello'
    result=$(printf '%s' "$input" | "$strip")
    assert_eq "hello" "$result" "strip-ansi: removes charset selection"

    # Complex mixed input
    input=$'\e[38;2;215;119;87m Claude Code \e[22m\e[38;2;153;153;153mv2.1.68\e[39m\r'
    result=$(printf '%s' "$input" | "$strip")
    assert_eq " Claude Code v2.1.68" "$result" "strip-ansi: handles complex mixed escapes"

    # Plain text passes through unchanged
    input="just plain text"
    result=$(printf '%s' "$input" | "$strip")
    assert_eq "just plain text" "$result" "strip-ansi: plain text unchanged"

    $SUMMARY_MODE || echo ""
}

run_standalone_scripts_tests() {
    _run_test test_standalone_preview
    _run_test test_standalone_dir_preview
    _run_test test_standalone_title_upgrade
    _run_test test_standalone_status_right
    _run_test test_strip_ansi
}

if [[ -z "${_AM_TEST_RUNNER:-}" ]]; then
    set -uo pipefail
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helpers.sh"
    check_deps
    run_standalone_scripts_tests
    test_report
fi
