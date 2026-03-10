# tests/test_bin_helpers.sh - Tests for bin/kill-and-switch, bin/switch-last

test_symlinked_kill_and_switch() {
    $SUMMARY_MODE || echo "=== Testing symlinked kill-and-switch ==="

    local temp_root bin_dir linked_bin tmux_stub am_dir
    temp_root=$(mktemp -d)
    bin_dir="$temp_root/bin"
    linked_bin="$temp_root/.local/bin"
    am_dir="$temp_root/am-data"
    mkdir -p "$bin_dir" "$linked_bin" "$am_dir"

cat > "$bin_dir/tmux" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "-L" ]]; then
    shift 2
fi

case "${1:-}" in
    -c)
        shift 2
        case "${1:-}" in
            display-message)
                printf '%s\n' "am-16fdf3"
                ;;
            switch-client)
                exit 0
                ;;
            *)
                exit 0
                ;;
        esac
        ;;
    display-message)
        printf '%s\n' "am-16fdf3"
        ;;
    has-session)
        exit 0
        ;;
    kill-session)
        exit 0
        ;;
    list-sessions)
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
EOF
    chmod +x "$bin_dir/tmux"

    ln -s "$PROJECT_DIR/bin/kill-and-switch" "$linked_bin/kill-and-switch"
    printf '{"sessions":{"am-16fdf3":{"name":"am-16fdf3"}}}\n' > "$am_dir/sessions.json"

    assert_cmd_succeeds "symlinked helper: resolves repo libs and exits cleanly" \
        env PATH="$bin_dir:$PATH" AM_DIR="$am_dir" "$linked_bin/kill-and-switch" "client-1" "am-16fdf3"

    rm -rf "$temp_root"
    $SUMMARY_MODE || echo ""
}

test_kill_and_switch_switches_client_before_kill() {
    $SUMMARY_MODE || echo "=== Testing kill-and-switch switch ordering ==="

    local temp_root bin_dir linked_bin am_dir log_file
    temp_root=$(mktemp -d)
    bin_dir="$temp_root/bin"
    linked_bin="$temp_root/.local/bin"
    am_dir="$temp_root/am-data"
    log_file="$temp_root/tmux.log"
    mkdir -p "$bin_dir" "$linked_bin" "$am_dir"

    cat > "$bin_dir/tmux" <<EOF
#!/usr/bin/env bash
set -euo pipefail

log_file="$log_file"
printf '%s\n' "\$*" >> "\$log_file"

if [[ "\${1:-}" == "-L" ]]; then
    shift 2
fi

case "\${1:-}" in
    -f)
        shift 2
        ;;
esac

case "\${1:-}" in
    display-message)
        shift
        if [[ "\${1:-}" == "-c" ]]; then
            shift 2
        fi
        printf '%s\n' "am-111111"
        ;;
    list-sessions)
        printf '%s\n' "200 am-222222"
        printf '%s\n' "100 am-111111"
        ;;
    has-session)
        exit 0
        ;;
    switch-client)
        exit 0
        ;;
    kill-session)
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
EOF
    chmod +x "$bin_dir/tmux"

    ln -s "$PROJECT_DIR/bin/kill-and-switch" "$linked_bin/kill-and-switch"
    printf '{"sessions":{"am-111111":{"name":"am-111111"},"am-222222":{"name":"am-222222"}}}\n' > "$am_dir/sessions.json"

    assert_cmd_succeeds "kill-and-switch: current client switches before kill" \
        env PATH="$bin_dir:$PATH" AM_DIR="$am_dir" "$linked_bin/kill-and-switch" "client-1" "am-111111"

    local tmux_log switch_line kill_line
    tmux_log=$(cat "$log_file")
    assert_contains "$tmux_log" 'display-message -c client-1 -p #{session_name}' \
        "kill-and-switch: resolves current session for invoking client"
    assert_contains "$tmux_log" 'switch-client -c client-1 -t am-222222' \
        "kill-and-switch: switches invoking client to fallback session"
    assert_contains "$tmux_log" 'kill-session -t am-111111' \
        "kill-and-switch: kills target session"

    switch_line=$(grep -n 'switch-client -c client-1 -t am-222222' "$log_file" | head -1 | cut -d: -f1)
    kill_line=$(grep -n 'kill-session -t am-111111' "$log_file" | head -1 | cut -d: -f1)
    assert_eq "true" "$([[ -n "$switch_line" && -n "$kill_line" && "$switch_line" -lt "$kill_line" ]] && echo true || echo false)" \
        "kill-and-switch: switch happens before kill"

    rm -rf "$temp_root"
    $SUMMARY_MODE || echo ""
}

test_kill_and_switch_no_alternate_session() {
    $SUMMARY_MODE || echo "=== Testing kill-and-switch with no alternate session ==="

    local temp_root bin_dir linked_bin am_dir log_file
    temp_root=$(mktemp -d)
    bin_dir="$temp_root/bin"
    linked_bin="$temp_root/.local/bin"
    am_dir="$temp_root/am-data"
    log_file="$temp_root/tmux.log"
    mkdir -p "$bin_dir" "$linked_bin" "$am_dir"

    cat > "$bin_dir/tmux" <<EOF
#!/usr/bin/env bash
set -euo pipefail

log_file="$log_file"
printf '%s\n' "\$*" >> "\$log_file"

if [[ "\${1:-}" == "-L" ]]; then
    shift 2
fi

case "\${1:-}" in
    -f)
        shift 2
        ;;
esac

case "\${1:-}" in
    display-message)
        shift
        if [[ "\${1:-}" == "-c" ]]; then
            shift 2
        fi
        printf '%s\n' "am-111111"
        ;;
    list-sessions)
        printf '%s\n' "100 am-111111"
        ;;
    has-session)
        exit 0
        ;;
    kill-session)
        exit 0
        ;;
    switch-client)
        printf '%s\n' "unexpected switch-client call" >&2
        exit 1
        ;;
    *)
        exit 0
        ;;
esac
EOF
    chmod +x "$bin_dir/tmux"

    ln -s "$PROJECT_DIR/bin/kill-and-switch" "$linked_bin/kill-and-switch"
    printf '{"sessions":{"am-111111":{"name":"am-111111"}}}\n' > "$am_dir/sessions.json"

    assert_cmd_succeeds "kill-and-switch: no alternate session only kills target" \
        env PATH="$bin_dir:$PATH" AM_DIR="$am_dir" "$linked_bin/kill-and-switch" "client-1" "am-111111"

    local tmux_log
    tmux_log=$(cat "$log_file")
    assert_contains "$tmux_log" 'kill-session -t am-111111' \
        "kill-and-switch: still kills target when no alternate exists"
    assert_eq "false" "$([[ "$tmux_log" == *'switch-client'* ]] && echo true || echo false)" \
        "kill-and-switch: does not switch when no alternate exists"

    rm -rf "$temp_root"
    $SUMMARY_MODE || echo ""
}

test_kill_and_switch_legacy_single_arg() {
    $SUMMARY_MODE || echo "=== Testing kill-and-switch legacy one-arg mode ==="

    local temp_root bin_dir linked_bin am_dir log_file
    temp_root=$(mktemp -d)
    bin_dir="$temp_root/bin"
    linked_bin="$temp_root/.local/bin"
    am_dir="$temp_root/am-data"
    log_file="$temp_root/tmux.log"
    mkdir -p "$bin_dir" "$linked_bin" "$am_dir"

    cat > "$bin_dir/tmux" <<EOF
#!/usr/bin/env bash
set -euo pipefail

log_file="$log_file"
printf '%s\n' "\$*" >> "\$log_file"

if [[ "\${1:-}" == "-L" ]]; then
    shift 2
fi

case "\${1:-}" in
    -f)
        shift 2
        ;;
esac

case "\${1:-}" in
    display-message)
        shift
        if [[ "\${1:-}" == "-p" && "\${2:-}" == '#{client_name}' ]]; then
            printf '%s\n' "client-legacy"
            exit 0
        fi
        if [[ "\${1:-}" == "-c" ]]; then
            shift 2
        fi
        printf '%s\n' "am-111111"
        ;;
    list-sessions)
        printf '%s\n' "200 am-222222"
        printf '%s\n' "100 am-111111"
        ;;
    has-session)
        exit 0
        ;;
    switch-client)
        exit 0
        ;;
    kill-session)
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
EOF
    chmod +x "$bin_dir/tmux"

    ln -s "$PROJECT_DIR/bin/kill-and-switch" "$linked_bin/kill-and-switch"
    printf '{"sessions":{"am-111111":{"name":"am-111111"},"am-222222":{"name":"am-222222"}}}\n' > "$am_dir/sessions.json"

    assert_cmd_succeeds "kill-and-switch: legacy one-arg form still works" \
        env PATH="$bin_dir:$PATH" AM_DIR="$am_dir" "$linked_bin/kill-and-switch" "am-111111"

    local tmux_log
    tmux_log=$(cat "$log_file")
    assert_contains "$tmux_log" 'display-message -p #{client_name}' \
        "kill-and-switch: legacy mode resolves current client implicitly"
    assert_contains "$tmux_log" 'switch-client -c client-legacy -t am-222222' \
        "kill-and-switch: legacy mode still switches the resolved client"
    assert_contains "$tmux_log" 'kill-session -t am-111111' \
        "kill-and-switch: legacy mode still kills target session"

    rm -rf "$temp_root"
    $SUMMARY_MODE || echo ""
}

test_switch_last_no_alternate_session() {
    $SUMMARY_MODE || echo "=== Testing switch-last with no alternate session ==="

    local temp_root bin_dir linked_bin
    temp_root=$(mktemp -d)
    bin_dir="$temp_root/bin"
    linked_bin="$temp_root/.local/bin"
    mkdir -p "$bin_dir" "$linked_bin"

    cat > "$bin_dir/tmux" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "-L" ]]; then
    shift 2
fi

case "${1:-}" in
    display-message)
        printf '%s\n' "am-16fdf3"
        ;;
    list-sessions)
        printf '%s\n' "123 am-16fdf3"
        ;;
    switch-client)
        printf '%s\n' "unexpected switch-client call" >&2
        exit 1
        ;;
    *)
        exit 0
        ;;
esac
EOF
    chmod +x "$bin_dir/tmux"

    ln -s "$PROJECT_DIR/bin/switch-last" "$linked_bin/switch-last"

    assert_cmd_succeeds "switch-last: no alternate session is a no-op" \
        env PATH="$bin_dir:$PATH" "$linked_bin/switch-last"

    rm -rf "$temp_root"
    $SUMMARY_MODE || echo ""
}

test_standalone_switch_last_errors() {
    $SUMMARY_MODE || echo "=== Testing bin/switch-last error handling ==="
    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/tmux.sh"
    set +u; source "$LIB_DIR/agents.sh"; set -u
    setup_integration_env

    local test_dir1 test_dir2 s1 s2

    test_dir1=$(mktemp -d)
    test_dir2=$(mktemp -d)
    s1=$(set +u; agent_launch "$test_dir1" bash "task1" ""; set -u) 2>/dev/null
    s2=$(set +u; agent_launch "$test_dir2" bash "task2" ""; set -u) 2>/dev/null
    sleep 0.5

    if [[ -z "$s1" ]] || ! am_tmux has-session -t "$s1" 2>/dev/null; then
        skip_test "switch-last error handling: session creation failed"
        teardown_integration_env
        rm -rf "$test_dir1" "$test_dir2"
        echo ""
        return
    fi

    TMUX= am_tmux attach-session -t "$s1" 2>/dev/null &
    local attach_pid=$!
    sleep 0.3

    local rc=0
    am_tmux run-shell -t "$s1" "$PROJECT_DIR/bin/switch-last" 2>/dev/null || rc=$?
    assert_eq "0" "$rc" "switch-last: exits 0 in tmux context"

    kill "$attach_pid" 2>/dev/null || true
    wait "$attach_pid" 2>/dev/null || true

    [[ -n "$s1" ]] && agent_kill "$s1" 2>/dev/null
    [[ -n "$s2" ]] && agent_kill "$s2" 2>/dev/null
    rm -rf "$test_dir1" "$test_dir2"
    teardown_integration_env

    $SUMMARY_MODE || echo ""
}

test_standalone_kill_and_switch_errors() {
    $SUMMARY_MODE || echo "=== Testing bin/kill-and-switch error handling ==="
    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/tmux.sh"
    source "$LIB_DIR/registry.sh"
    set +u; source "$LIB_DIR/agents.sh"; set -u
    setup_integration_env

    local rc

    rc=0
    "$PROJECT_DIR/bin/kill-and-switch" "" 2>/dev/null || rc=$?
    assert_eq "1" "$rc" "kill-and-switch: exits 1 on empty target"

    rc=0
    AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" \
        "$PROJECT_DIR/bin/kill-and-switch" "nonexistent-session" 2>/dev/null || rc=$?
    assert_eq "1" "$rc" "kill-and-switch: exits 1 on nonexistent session"

    local test_dir s1
    test_dir=$(mktemp -d)
    s1=$(set +u; agent_launch "$test_dir" bash "task" ""; set -u) 2>/dev/null
    sleep 0.5

    if [[ -z "$s1" ]] || ! am_tmux has-session -t "$s1" 2>/dev/null; then
        skip_test "kill-and-switch: session creation failed"
        teardown_integration_env
        rm -rf "$test_dir"
        echo ""
        return
    fi

    rc=0
    AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" \
        "$PROJECT_DIR/bin/kill-and-switch" "$s1" 2>/dev/null || rc=$?
    assert_eq "0" "$rc" "kill-and-switch: exits 0 on valid session"

    local exists=0
    am_tmux has-session -t "$s1" 2>/dev/null && exists=1
    assert_eq "0" "$exists" "kill-and-switch: actually kills the session"

    rm -rf "$test_dir"
    teardown_integration_env

    $SUMMARY_MODE || echo ""
}

run_bin_helpers_tests() {
    _run_test test_symlinked_kill_and_switch
    _run_test test_kill_and_switch_switches_client_before_kill
    _run_test test_kill_and_switch_no_alternate_session
    _run_test test_kill_and_switch_legacy_single_arg
    _run_test test_switch_last_no_alternate_session
    _run_test test_standalone_switch_last_errors
    _run_test test_standalone_kill_and_switch_errors
}
