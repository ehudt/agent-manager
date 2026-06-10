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

    if [[ -z "$session_name" ]] || ! wait_for_cmd tmux_session_exists "$session_name"; then
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

    local claude_dir
    claude_dir="$HOME/.claude/projects/$(echo "$test_dir" | sed 's|/|-|g; s|\.|-|g')"
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

test_standalone_status_bar() {
    $SUMMARY_MODE || echo "=== Testing lib/status-bar (standalone) ==="
    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/config.sh"
    source "$LIB_DIR/tmux.sh"
    source "$LIB_DIR/registry.sh"
    source "$LIB_DIR/state.sh"
    set +u; source "$LIB_DIR/agents.sh"; set -u
    setup_integration_env
    local old_state_dir="${AM_STATE_DIR:-}"
    local test_state_dir
    test_state_dir=$(mktemp -d)
    export AM_STATE_DIR="$test_state_dir"

    local output rc

    rc=0
    output=$("$LIB_DIR/status-bar" --print "" 2>&1) || rc=$?
    assert_eq "0" "$rc" "status-bar: exits 0 with no sessions"

    local test_dir1 test_dir2 test_dir3
    test_dir1=$(mktemp -d)
    test_dir2=$(mktemp -d)
    test_dir3=$(mktemp -d)

    local s1 s2 s3
    s1=$(set +u; agent_launch "$test_dir1" bash "task1" ""; set -u) 2>/dev/null
    s2=$(set +u; agent_launch "$test_dir2" bash "task2" ""; set -u) 2>/dev/null
    s3=$(set +u; agent_launch "$test_dir3" bash "task3" ""; set -u) 2>/dev/null
    [[ -n "$s3" ]] && wait_for_cmd tmux_session_exists "$s3"

    rc=0
    output=$("$LIB_DIR/status-bar" --print "$s1" 2>&1) || rc=$?
    assert_eq "0" "$rc" "status-bar: exits 0 with multiple sessions"

    [[ -n "$s1" ]] && tmux_send_keys "$s1" "sleep 10000"
    [[ -n "$s2" ]] && tmux_send_keys "$s2" "echo hello"
    sleep 0.3

    rc=0
    output=$("$LIB_DIR/status-bar" --print "$s1" 2>&1) || rc=$?
    assert_eq "0" "$rc" "status-bar: exits 0 with mixed states"

    # Missing hook + agent alive (non-shell pane) → status-bar renders '?' (unknown).
    local test_dir4 s4 old_claude_cmd
    test_dir4=$(mktemp -d)
    old_claude_cmd="${AGENT_COMMANDS[claude]}"
    AGENT_COMMANDS[claude]="sleep"
    s4=$(set +u; agent_launch "$test_dir4" claude "task4" "" 1000; set -u) 2>/dev/null
    AGENT_COMMANDS[claude]="$old_claude_cmd"
    if [[ -n "$s4" ]] && tmux_session_exists "$s4"; then
        local agent_ready=false
        for _ in {1..30}; do
            if ! _state_pane_is_shell "$s4"; then
                agent_ready=true
                break
            fi
            sleep 0.1
        done
        if $agent_ready; then
            rm -f "$AM_STATE_DIR/$s4"

            rc=0
            output=$("$LIB_DIR/status-bar" --print "" 2>&1) || rc=$?
            assert_eq "0" "$rc" "status-bar: exits 0 when hook state is missing"
            assert_contains "$output" "? $(basename "$test_dir4")" \
                "status-bar: hook silent + agent alive → unknown glyph"
        else
            skip_test "status-bar: fallback state test (agent process did not start)"
        fi
    else
        skip_test "status-bar: fallback state test (session creation failed)"
    fi

    rc=0
    output=$("$LIB_DIR/status-bar" --print "nonexistent" 2>&1) || rc=$?
    assert_eq "0" "$rc" "status-bar: exits 0 with nonexistent current session"

    [[ -n "$s1" ]] && agent_kill "$s1" 2>/dev/null
    [[ -n "$s2" ]] && agent_kill "$s2" 2>/dev/null
    [[ -n "$s3" ]] && agent_kill "$s3" 2>/dev/null
    [[ -n "${s4:-}" ]] && agent_kill "$s4" 2>/dev/null
    rm -rf "$test_dir1" "$test_dir2" "$test_dir3" "${test_dir4:-}" "$test_state_dir"
    if [[ -n "$old_state_dir" ]]; then
        export AM_STATE_DIR="$old_state_dir"
    else
        unset AM_STATE_DIR
    fi
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

    # ZLE-style in-place edit: type 'oyu', cursor back 3, overwrite with 'you'
    input=$'oyu\e[3Dyou'
    result=$(printf '%s' "$input" | "$strip")
    assert_eq "you" "$result" "strip-ansi: cursor-back overwrite renders final state"

    # ZLE-style edit: replace tail via cursor-back + erase-to-EOL + new content
    input=$'hello world\e[5D\e[Kthere'
    result=$(printf '%s' "$input" | "$strip")
    assert_eq "hello there" "$result" "strip-ansi: cursor-back + EL renders replacement"

    # Carriage-return redraw: \r returns to col 0, new content overwrites
    input=$'old line\rnew line'
    result=$(printf '%s' "$input" | "$strip")
    assert_eq "new line" "$result" "strip-ansi: CR redraw overwrites earlier content"

    # Single-char correction: type 'helli', cursor back 1, overwrite with 'o'
    input=$'helli\e[Do'
    result=$(printf '%s' "$input" | "$strip")
    assert_eq "hello" "$result" "strip-ansi: single-char cursor-back correction"

    # Delete characters CSI P: type 'abcXXXdef', cursor to col 3, delete 3
    input=$'abcXXXdef\e[6D\e[3P'
    result=$(printf '%s' "$input" | "$strip")
    assert_eq "abcdef" "$result" "strip-ansi: CSI P deletes characters"

    # Multi-param SGR (regression: int conversion must not warn on '38;2;...')
    input=$'\e[38;2;215;119;87mhello\e[0m'
    result=$(printf '%s' "$input" | "$strip" 2>&1)
    assert_eq "hello" "$result" "strip-ansi: multi-param SGR no warning"

    $SUMMARY_MODE || echo ""
}

run_standalone_scripts_tests() {
    _run_test test_standalone_preview
    _run_test test_standalone_dir_preview
    _run_test test_standalone_status_bar
    _run_test test_strip_ansi
}

if [[ -z "${_AM_TEST_RUNNER:-}" ]]; then
    set -uo pipefail
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helpers.sh"
    check_deps
    run_standalone_scripts_tests
    test_report
fi
