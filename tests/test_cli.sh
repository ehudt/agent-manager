#!/usr/bin/env bash
# tests/test_cli.sh - Tests for the `am` entry point

test_cli() {
    $SUMMARY_MODE || echo "=== Testing am CLI ==="

    # Test help — one smoke assertion per command's help, plus the behavioral
    # hidden-flag checks (hidden flags must stay hidden).
    local help_output
    help_output=$("$PROJECT_DIR/am" help)
    assert_contains "$help_output" "Agent Manager" "am help: shows title"
    assert_contains "$help_output" "USAGE" "am help: shows usage"

    local new_help
    new_help=$("$PROJECT_DIR/am" new --help)
    assert_contains "$new_help" "-t, --type" "am new --help: shows flags"
    assert_contains "$new_help" "cursor" "am new --help: lists Cursor agent"
    assert_contains "$new_help" "dir_provider" "am new --help: explains @spec directories"
    assert_not_contains "$new_help" "--workspace" "am new --help: the -W flag is gone"
    assert_not_contains "$new_help" "--yolo" "am new --help: no yolo flag"
    assert_not_contains "$new_help" "--sandbox" "am new --help: no sandbox flag"
    assert_not_contains "$new_help" "--worktree" "am new --help: no worktree flag"
    assert_not_contains "$help_output" "sandbox" "am help: no sandbox command"

    # Removed manager flags are rejected rather than silently forwarded
    local rc=0
    "$PROJECT_DIR/am" new --sandbox /tmp </dev/null >/dev/null 2>&1 || rc=$?
    assert_eq "1" "$rc" "am new --sandbox: unknown option"
    rc=0
    "$PROJECT_DIR/am" new -w /tmp </dev/null >/dev/null 2>&1 || rc=$?
    assert_eq "1" "$rc" "am new -w: unknown option"
    rc=0
    "$PROJECT_DIR/am" sb ps </dev/null >/dev/null 2>&1 || rc=$?
    assert_eq "1" "$rc" "am sb: unknown command"

    # interrupt: -i/--interactive asks before sending Ctrl-C; the pre-0.22
    # --confirm spelling stays accepted with the same meaning but is not
    # advertised. All three must parse as flags, not as unknown options.
    local interrupt_help
    interrupt_help=$("$PROJECT_DIR/am" interrupt --help)
    assert_contains "$interrupt_help" "-i|--interactive" "am interrupt --help: documents -i/--interactive"
    assert_not_contains "$interrupt_help" "--confirm" "am interrupt --help: --confirm is a hidden alias"
    local flag interrupt_err
    for flag in -i --interactive --confirm; do
        interrupt_err=$("$PROJECT_DIR/am" interrupt "$flag" 2>&1 >/dev/null </dev/null || true)
        assert_not_contains "$interrupt_err" "Unknown option" "am interrupt $flag: accepted as a flag"
        assert_contains "$interrupt_err" "Session name required" "am interrupt $flag: still requires a session"
    done

    # Bash version gate: 4.4 is the floor (namerefs in lib/state.sh, ${var@Q}
    # in lib/agents.sh). Exercised for real where an older bash exists
    # (macOS ships 3.2 at /bin/bash); the static check runs everywhere.
    local old_bash_major
    old_bash_major=$(/bin/bash -c 'echo "${BASH_VERSINFO[0]}"' 2>/dev/null || echo 9)
    if (( old_bash_major < 4 )); then
        local gate_err gate_rc=0
        gate_err=$(/bin/bash "$PROJECT_DIR/am" --version 2>&1 >/dev/null) || gate_rc=$?
        assert_eq "1" "$gate_rc" "am under bash 3.2: refuses to run"
        assert_contains "$gate_err" "bash >= 4.4" "am under bash 3.2: names the 4.4 floor"
    else
        skip_test "bash version gate under bash 3.2 (no bash < 4 at /bin/bash)"
    fi
    assert_contains "$(head -12 "$PROJECT_DIR/am")" "BASH_VERSINFO[1] < 4" \
        "am: version gate checks the minor version"

    local send_help
    send_help=$("$PROJECT_DIR/am" send --help)
    assert_contains "$send_help" "Usage: am send" "am send --help: shows usage"
    assert_contains "$send_help" "--wait" "am send --help: documents wait flag"
    assert_contains "$send_help" "--timeout" "am send --help: documents timeout flag"
    assert_contains "$send_help" "ready" \
        "am send --help: --wait promises the canonical ready state"
    assert_not_contains "$send_help" "waiting_permission" \
        "am send --help: does not call a permission dialog ready"

    local wait_help
    wait_help=$("$PROJECT_DIR/am" wait --help)
    assert_contains "$wait_help" "ready" "am wait --help: lists ready"
    assert_contains "$wait_help" "waiting_user" "am wait --help: lists waiting_user"
    assert_contains "$wait_help" "background" "am wait --help: lists background"
    assert_contains "$wait_help" "legacy aliases" \
        "am wait --help: documents legacy state aliases"

    local peek_help
    peek_help=$("$PROJECT_DIR/am" peek --help)
    assert_contains "$peek_help" "--pane" "am peek --help: shows pane flag"
    assert_not_contains "$peek_help" "--json" "am peek --help: hides json flag"
    assert_not_contains "$peek_help" "--history" "am peek --help: hides history flag"
    assert_not_contains "$peek_help" "--grep" "am peek --help: hides grep flag"

    local status_help
    status_help=$("$PROJECT_DIR/am" status --help)
    assert_contains "$status_help" "--json" "am status --help: shows json flag"
    assert_not_contains "$status_help" "--wait" "am status --help: does not show unrelated flags"
    assert_not_contains "$status_help" "--timeout" "am status --help: does not show unrelated flags"

    # Test version
    local version_output
    version_output=$("$PROJECT_DIR/am" version)
    assert_contains "$version_output" "am version " "am version: shows version"

    $SUMMARY_MODE || echo ""
}

test_cli_extended() {
    $SUMMARY_MODE || echo "=== Testing CLI commands (extended) ==="

    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/tmux.sh"
    source "$LIB_DIR/registry.sh"
    set +u; source "$LIB_DIR/agents.sh"; set -u

    setup_integration_env

    local test_dir
    test_dir=$(mktemp -d)

    # Create a session for testing against (--shell: the peek tests below
    # exercise the shell pane, which is opt-in since 0.16)
    local session_name
    session_name=$(set +u; agent_launch "$test_dir" "claude" "cli test" --shell 2>/dev/null)

    if [[ -z "$session_name" ]]; then
        skip_test "cli extended tests (agent_launch failed)"
        teardown_integration_env
        rm -rf "$test_dir"
        echo ""
        return
    fi

    # --- Test: am list --json returns valid JSON containing our session ---
    local json_output
    json_output=$(AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" "$PROJECT_DIR/am" list --json 2>/dev/null)
    assert_cmd_succeeds "am list --json: valid JSON" jq . <<< "$json_output"
    assert_contains "$json_output" "$session_name" "am list --json: contains session"
    assert_eq "claude" "$(echo "$json_output" | jq -r '.[0].agent_type')" \
        "am list --json: preserves agent_type when branch is empty"
    assert_eq "" "$(echo "$json_output" | jq -r '.[0].branch')" \
        "am list --json: preserves empty branch field"

    # --- Test: list helpers share one row collection shape ---
    set +u
    source "$LIB_DIR/fzf.sh"
    set -u
    local row_output
    row_output=$(AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" _fzf_session_rows 2>/dev/null || true)
    assert_contains "$row_output" "$session_name" "list row collector: contains session"

    local row_line
    row_line=$(printf '%s\n' "$row_output" | head -n1)
    assert_not_empty "$row_line" "list row collector: emits a row"

    local row_name row_state row_dir row_branch row_agent row_task row_activity row_created row_workdir row_review
    IFS=$'\x1f' read -r row_name row_state row_dir row_branch row_agent row_task row_activity row_created row_workdir row_review <<< "$row_line"
    assert_eq "$session_name" "$row_name" "list row collector: name field"
    assert_not_empty "$row_state" "list row collector: state field"
    assert_eq "$test_dir" "$row_dir" "list row collector: directory field"
    assert_eq "" "$row_branch" "list row collector: branch field"
    assert_eq "claude" "$row_agent" "list row collector: agent field"
    assert_eq "cli test" "$row_task" "list row collector: task field"
    assert_not_empty "$row_activity" "list row collector: activity field"
    assert_not_empty "$row_created" "list row collector: created field"
    assert_eq "" "$row_workdir" "list row collector: workdir empty until the agent moves"
    assert_eq "0 0 0" "$row_review" "list row collector: review counts zero for a non-repo session"

    # --- Test: am list-internal returns session list for the browser ---
    if [[ -x "$PROJECT_DIR/bin/am-list-internal" && -s "$PROJECT_DIR/bin/am-list-internal" ]]; then
        local internal_output
        internal_output=$(AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" "$PROJECT_DIR/am" list-internal 2>/dev/null)
        assert_contains "$internal_output" "$session_name" "am list-internal: contains session"
        assert_contains "$internal_output" "[claude]" "am list-internal: contains agent type"
    else
        skip_test "am list-internal (bin/am-list-internal not built — run 'make build')"
    fi

    # --- Test: am info <session> ---
    local info_output
    info_output=$(AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" "$PROJECT_DIR/am" info "$session_name" 2>/dev/null)
    assert_contains "$info_output" "Directory:" "am info: shows directory"
    assert_contains "$info_output" "Agent:" "am info: shows agent type"
    assert_not_contains "$info_output" "Yolo:" "am info: no yolo line"
    assert_not_contains "$info_output" "Sandbox:" "am info: no sandbox line"

    # --- Test: am peek snapshots agent and shell panes ---
    local peek_output
    peek_output=$(wait_for_text "stub-agent-ready" \
        env AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" "$PROJECT_DIR/am" peek "$session_name")
    assert_contains "$peek_output" "stub-agent-ready" "am peek: captures agent pane"

    tmux_send_keys "$session_name:.{bottom}" "echo shell-peek-ready" Enter
    local shell_peek
    shell_peek=$(wait_for_text "shell-peek-ready" \
        env AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" "$PROJECT_DIR/am" peek --pane shell "$session_name")
    assert_contains "$shell_peek" "shell-peek-ready" "am peek --pane shell: captures shell pane"

    tmux_send_keys "$session_name:.{bottom}" 'prefix=shell-tail-; printf "%s%s\n%s%s" "$prefix" old "$prefix" new; sleep 60' Enter
    local shell_tail
    shell_tail=$(wait_for_text "shell-tail-new" \
        env AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" "$PROJECT_DIR/am" peek --pane shell --lines 1 "$session_name")
    assert_contains "$shell_tail" "shell-tail-new" "am peek --lines: captures requested tail"
    assert_not_contains "$shell_tail" "shell-tail-old" "am peek --lines: excludes older output"

    local follow_log="/tmp/am-logs/${session_name}/shell.log"
    if [[ -f "$follow_log" ]]; then
        printf 'follow-tail-old\nfollow-tail-new\n' >> "$follow_log"
        local follow_file follow_pid follow_output
        follow_file=$(mktemp)
        AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" "$PROJECT_DIR/am" peek --pane shell --follow --lines 1 "$session_name" >"$follow_file" 2>/dev/null &
        follow_pid=$!
        wait_for_text "follow-tail-new" cat "$follow_file" >/dev/null
        kill "$follow_pid" 2>/dev/null || true
        wait "$follow_pid" 2>/dev/null || true
        follow_output=$(cat "$follow_file" 2>/dev/null || true)
        rm -f "$follow_file"
        assert_contains "$follow_output" "follow-tail-new" "am peek --follow --lines: seeds requested tail"
        assert_not_contains "$follow_output" "follow-tail-old" "am peek --follow --lines: excludes older log output"
    else
        skip_test "am peek --follow --lines: log streaming disabled"
    fi

    # --- Test: am peek --pane shell errors clearly on an agent-only session ---
    local noshell_session
    noshell_session=$(set +u; agent_launch "$test_dir" "claude" "no shell" 2>/dev/null)
    if [[ -n "$noshell_session" ]]; then
        local noshell_err
        noshell_err=$(AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" \
            "$PROJECT_DIR/am" peek --pane shell "$noshell_session" 2>&1 || true)
        assert_contains "$noshell_err" "no shell pane" \
            "am peek --pane shell: explains missing shell pane"
        assert_contains "$noshell_err" "am shell" \
            "am peek --pane shell: suggests am shell"
        agent_kill "$noshell_session" 2>/dev/null
    else
        skip_test "am peek --pane shell error (agent_launch failed)"
    fi

    # --- Test: am status <session> shows detailed info plus state ---
    local status_output
    status_output=$(AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" "$PROJECT_DIR/am" status "$session_name" 2>/dev/null)
    assert_contains "$status_output" "Directory:" "am status <session>: shows directory"
    assert_contains "$status_output" "Agent:" "am status <session>: shows agent type"
    assert_contains "$status_output" "State:" "am status <session>: shows state"

    # --- Test: am kill <session> ---
    AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" "$PROJECT_DIR/am" kill "$session_name" 2>/dev/null
    assert_eq "false" "$(tmux_session_exists "$session_name" && echo true || echo false)" \
        "am kill: session removed"

    # --- Test: am attach nonexistent fails ---
    local attach_rc=0
    AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" "$PROJECT_DIR/am" attach nonexistent-xyz </dev/null 2>/dev/null || attach_rc=$?
    assert_eq "false" "$(test $attach_rc -eq 0 && echo true || echo false)" \
        "am attach nonexistent: exits with error"

    # --- Test: am kill with no args fails ---
    local kill_rc=0
    AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" "$PROJECT_DIR/am" kill </dev/null 2>/dev/null || kill_rc=$?
    assert_eq "false" "$(test $kill_rc -eq 0 && echo true || echo false)" \
        "am kill no args: exits with error"

    # --- Test: am status runs without error ---
    local status_rc=0
    AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" "$PROJECT_DIR/am" status >/dev/null 2>&1 || status_rc=$?
    assert_eq "true" "$(test $status_rc -eq 0 && echo true || echo false)" \
        "am status: exits 0"

    # --- Test: am config commands ---
    local config_output
    config_output=$(AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" "$PROJECT_DIR/am" config set agent codex 2>/dev/null)
    assert_contains "$config_output" "default_agent=codex" "am config set agent: persists default"

    local config_get
    config_get=$(AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" "$PROJECT_DIR/am" config get agent 2>/dev/null)
    assert_eq "codex" "$config_get" "am config get agent: returns saved default"

    config_output=$(AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" "$PROJECT_DIR/am" config set agent cursor-agent 2>/dev/null)
    assert_contains "$config_output" "default_agent=cursor" \
        "am config set agent: canonicalizes cursor-agent alias"
    assert_eq "cursor" "$(jq -r '.default_agent' "$TEST_AM_DIR/config.json")" \
        "am config set agent: stores canonical Cursor type"

    config_get=$(AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" AM_DEFAULT_AGENT="claude" "$PROJECT_DIR/am" config get agent 2>/dev/null)
    assert_eq "claude" "$config_get" "am config get agent: env override wins"

    # --- Test: removed config keys are rejected ---
    local config_rc=0
    AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" "$PROJECT_DIR/am" config set sandbox true >/dev/null 2>&1 || config_rc=$?
    assert_eq "1" "$config_rc" "am config set sandbox: unknown key"
    config_rc=0
    AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" "$PROJECT_DIR/am" config get yolo >/dev/null 2>&1 || config_rc=$?
    assert_eq "1" "$config_rc" "am config get yolo: unknown key"

    # auto-restore is readable like every other key (it used to print nothing)
    config_get=$(AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" "$PROJECT_DIR/am" config get auto-restore 2>/dev/null)
    assert_eq "true" "$config_get" "am config get auto-restore: prints the default"
    AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" "$PROJECT_DIR/am" config set auto-restore false >/dev/null 2>&1
    config_get=$(AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" "$PROJECT_DIR/am" config get auto_restore 2>/dev/null)
    assert_eq "false" "$config_get" "am config get auto_restore: reflects the saved value"
    AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" "$PROJECT_DIR/am" config set auto-restore true >/dev/null 2>&1
    local config_usage
    config_usage=$(AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" "$PROJECT_DIR/am" config get 2>&1 || true)
    assert_contains "$config_usage" "auto-restore" "am config get usage: lists auto-restore"

    # --- Test: am send injects prompt text into running session ---
    session_name=$(set +u; agent_launch "$test_dir" "claude" "send test" 2>/dev/null)
    assert_not_empty "$session_name" "am send setup: session created"
    wait_for_text "stub-agent-ready" am_tmux capture-pane -pt "$session_name:.{top}" >/dev/null

    # The stub agent is a bash script, which the shell-pane check reads as
    # "agent exited" (idle). The default send refuses that with exit 2 rather
    # than typing into a shell; --force overrides. A session younger than 5s
    # still resolves as `starting` (refused with exit 4), so wait it out first:
    # a fast CI runner reaches this line well inside the window.
    AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" "$PROJECT_DIR/am" wait --state idle --timeout 20 "$session_name" >/dev/null 2>&1 || true
    local send_rc=0 send_err
    send_err=$(AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" "$PROJECT_DIR/am" send "$session_name" "run tests now" 2>&1 >/dev/null) || send_rc=$?
    assert_eq "2" "$send_rc" "am send: refuses a session with no running agent (exit 2)"
    assert_contains "$send_err" "no running agent" "am send: explains the refusal"
    pane_output=$(am_tmux capture-pane -pt "$session_name:.{top}")
    assert_not_contains "$pane_output" "stub-agent-input:run tests now" "am send: refused prompt never reaches the pane"

    send_rc=0
    AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" "$PROJECT_DIR/am" send --force "$session_name" "run tests now" >/dev/null 2>/dev/null || send_rc=$?
    assert_eq "0" "$send_rc" "am send: exits 0"
    local pane_output
    pane_output=$(wait_for_text "stub-agent-input:run tests now" \
        am_tmux capture-pane -pt "$session_name:.{top}")
    assert_contains "$pane_output" "stub-agent-input:run tests now" "am send: prompt reaches agent pane"

    # A multi-line stdin prompt is read whole with its newlines (the stub is
    # not in bracketed-paste mode, so tmux hands it one line per read).
    send_rc=0
    printf 'first line\nsecond line\n' | AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" "$PROJECT_DIR/am" send --force "$session_name" >/dev/null 2>/dev/null || send_rc=$?
    assert_eq "0" "$send_rc" "am send (stdin): exits 0"
    pane_output=$(wait_for_text "stub-agent-input:second line" \
        am_tmux capture-pane -pt "$session_name:.{top}")
    assert_contains "$pane_output" "stub-agent-input:first line" "am send (stdin): first line reaches the agent"
    assert_contains "$pane_output" "stub-agent-input:second line" "am send (stdin): second line reaches the agent"

    # C0 control characters are stripped before the paste (ESC would start a
    # key sequence, ^C would interrupt the agent); tabs survive. If ^C got
    # through, the stub would die and nothing would be echoed.
    AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" "$PROJECT_DIR/am" send -f "$session_name" \
        $'ctl\033[31m\007a\tb\003end' >/dev/null 2>/dev/null || true
    pane_output=$(wait_for_text "stub-agent-input:ctl" \
        am_tmux capture-pane -pt "$session_name:.{top}")
    assert_contains "$pane_output" "stub-agent-input:ctl[31ma" "am send: ESC and BEL stripped from the prompt"
    assert_eq "true" "$([[ "$pane_output" =~ ctl\[31ma[[:space:]]+bend ]] && echo true || echo false)" \
        "am send: ^C stripped, tab kept (stub survived and echoed the rest)"
    [[ -n "$session_name" ]] && agent_kill "$session_name" 2>/dev/null

    # --- Test: am new --detach can pass initial prompt from stdin (piped to agent) ---
    local detached_session
    detached_session=$(printf 'initial prompt from stdin\n' | AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" "$PROJECT_DIR/am" new --detach --print-session -t "$TEST_STUB_DIR/stub_agent" "$test_dir" 2>/dev/null)
    assert_not_empty "$detached_session" "am new --detach: returns session name"
    assert_eq "true" "$(tmux_session_exists "$detached_session" && echo true || echo false)" \
        "am new --detach: session created"

    pane_output=$(wait_for_text "stub-agent-input:initial prompt from stdin" \
        am_tmux capture-pane -pt "$detached_session:.{top}")
    assert_contains "$pane_output" "stub-agent-input:initial prompt from stdin" \
        "am new --detach: stdin prompt piped to agent"
    [[ -n "$detached_session" ]] && agent_kill "$detached_session" 2>/dev/null

    # Cleanup
    rm -rf "$test_dir"
    teardown_integration_env

    $SUMMARY_MODE || echo ""
}

test_cli_workspace_and_id() {
    $SUMMARY_MODE || echo "=== Testing am new @spec and am id ==="

    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/config.sh"
    source "$LIB_DIR/tmux.sh"
    source "$LIB_DIR/registry.sh"
    set +u; source "$LIB_DIR/agents.sh"; set -u

    setup_integration_env

    local test_dir
    test_dir=$(mktemp -d)
    local am_env=(AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" AM_SESSION_NAME= TMUX=)

    # --- am id: outside any session ---
    local rc=0
    env "${am_env[@]}" "$PROJECT_DIR/am" id >/dev/null 2>&1 </dev/null || rc=$?
    assert_eq "1" "$rc" "am id: exits 1 outside an am session"

    # --- am id: inside (AM_SESSION_NAME seeded into every pane) ---
    assert_eq "test-am-abc123" "$(env "${am_env[@]}" AM_SESSION_NAME=test-am-abc123 "$PROJECT_DIR/am" id 2>/dev/null)" \
        "am id: prints AM_SESSION_NAME"
    assert_eq "test-am-abc123" "$(env "${am_env[@]}" AM_SESSION_NAME=test-am-abc123 "$PROJECT_DIR/am" whoami 2>/dev/null)" \
        "am whoami: alias of am id"
    rc=0
    env "${am_env[@]}" AM_SESSION_NAME=other-prefix-1 "$PROJECT_DIR/am" id >/dev/null 2>&1 || rc=$?
    assert_eq "1" "$rc" "am id: rejects a name outside the am prefix"

    # --- am new @spec without a dir_provider: fails with guidance ---
    rc=0
    local err
    err=$(env "${am_env[@]}" AM_DIR_PROVIDER= "$PROJECT_DIR/am" new @48351 --detach --print-session -t "$TEST_STUB_DIR/stub_agent" 2>&1 </dev/null) || rc=$?
    assert_eq "1" "$rc" "am new @spec: fails when dir_provider is unset"
    assert_contains "$err" "dir_provider" "am new @spec: error names the config key"

    # --- -W is gone ---
    rc=0
    err=$(env "${am_env[@]}" "$PROJECT_DIR/am" new -W feature-x --detach 2>&1 </dev/null) || rc=$?
    assert_eq "1" "$rc" "am new -W: no longer accepted"
    assert_contains "$err" "Unknown option: -W" "am new -W: reported as an unknown option"

    # --- am new @spec: the provider's resolve verb supplies the directory ---
    local prov_env=(FAKE_PROVIDER_DIR="$test_dir" AM_DIR_PROVIDER="$TEST_STUB_DIR/fake_dir_provider")
    local session_name
    session_name=$(env "${am_env[@]}" "${prov_env[@]}" "$PROJECT_DIR/am" new @feature-x --detach --print-session -t "$TEST_STUB_DIR/stub_agent" </dev/null 2>/dev/null)
    assert_not_empty "$session_name" "am new @spec: session created"
    assert_eq "$test_dir/ws-feature-x" "$(registry_get_field "$session_name" directory)" \
        "am new @spec: session runs in the resolved directory"
    assert_contains "$(cat "$test_dir/calls.log")" "resolve feature-x" "am new @spec: provider called with resolve <spec>"
    [[ -n "$session_name" ]] && agent_kill "$session_name" 2>/dev/null

    # --- -d @spec works too, and args after -- reach the agent untouched ---
    session_name=$(env "${am_env[@]}" "${prov_env[@]}" "$PROJECT_DIR/am" new -d @feature-y --detach --print-session -t "$TEST_STUB_DIR/stub_agent" -- --stub-extra </dev/null 2>/dev/null)
    assert_not_empty "$session_name" "am new -d @spec -- extra: session created"
    assert_eq "$test_dir/ws-feature-y" "$(registry_get_field "$session_name" directory)" \
        "am new -d @spec: resolved through the provider"
    local extra_pane
    extra_pane=$(wait_for_text "stub-extra" am_tmux capture-pane -pt "$session_name:.{top}" -S -)
    assert_contains "$extra_pane" "stub-extra" "am new -- extra: agent receives the extra arg"
    [[ -n "$session_name" ]] && agent_kill "$session_name" 2>/dev/null

    # --- bare @: the provider sees an empty spec ---
    session_name=$(env "${am_env[@]}" "${prov_env[@]}" "$PROJECT_DIR/am" new @ --detach --print-session -t "$TEST_STUB_DIR/stub_agent" </dev/null 2>/dev/null)
    assert_not_empty "$session_name" "am new @: session created from the provider default"
    assert_eq "$test_dir/ws-trunk" "$(registry_get_field "$session_name" directory)" \
        "am new @: empty spec reaches the provider"
    [[ -n "$session_name" ]] && agent_kill "$session_name" 2>/dev/null

    # --- a preset whose directory is a @spec resolves the same way ---
    env "${am_env[@]}" "$PROJECT_DIR/am" preset save wsx -n "preset task" @feature-z >/dev/null 2>&1 </dev/null || true
    session_name=$(env "${am_env[@]}" "${prov_env[@]}" "$PROJECT_DIR/am" new -p wsx --detach --print-session -t "$TEST_STUB_DIR/stub_agent" </dev/null 2>/dev/null)
    assert_not_empty "$session_name" "am new -p <@spec preset>: session created"
    assert_eq "$test_dir/ws-feature-z" "$(registry_get_field "$session_name" directory)" \
        "am new -p <@spec preset>: preset directory resolved through the provider"
    [[ -n "$session_name" ]] && agent_kill "$session_name" 2>/dev/null

    # --- provider failures are reported, not launched ---
    rc=0
    err=$(env "${am_env[@]}" "${prov_env[@]}" "$PROJECT_DIR/am" new @nowhere --detach --print-session -t "$TEST_STUB_DIR/stub_agent" 2>&1 </dev/null) || rc=$?
    assert_eq "1" "$rc" "am new @spec: bad provider output fails"
    assert_contains "$err" "did not print an existing directory" "am new @spec: reports the bad output"
    rc=0
    err=$(env "${am_env[@]}" "${prov_env[@]}" "$PROJECT_DIR/am" new @fail --detach --print-session -t "$TEST_STUB_DIR/stub_agent" 2>&1 </dev/null) || rc=$?
    assert_eq "1" "$rc" "am new @spec: provider exit status fails the launch"
    assert_contains "$err" "could not resolve @fail" "am new @spec: reports the provider failure"
    assert_contains "$err" "cannot resolve fail" "am new @spec: provider stderr reaches the user"

    rm -rf "$test_dir"
    teardown_integration_env

    $SUMMARY_MODE || echo ""
}


# am cd: record where the current session's agent works now
test_cli_cd() {
    $SUMMARY_MODE || echo "=== Testing am cd ==="

    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/config.sh"
    source "$LIB_DIR/tmux.sh"
    source "$LIB_DIR/registry.sh"
    set +u; source "$LIB_DIR/agents.sh"; set -u

    setup_integration_env
    local state_dir launch other
    state_dir=$(mktemp -d)
    launch=$(mktemp -d)
    other=$(mktemp -d)
    mkdir -p "$launch/.git" "$other/.git"
    echo "ref: refs/heads/main" > "$launch/.git/HEAD"
    echo "ref: refs/heads/pr-42" > "$other/.git/HEAD"
    local am_env=(AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" AM_STATE_DIR="$state_dir" TMUX=)

    local rc=0
    env "${am_env[@]}" AM_SESSION_NAME= "$PROJECT_DIR/am" cd "$other" >/dev/null 2>&1 </dev/null || rc=$?
    assert_eq "1" "$rc" "am cd: exits 1 outside an am session"

    rc=0
    env "${am_env[@]}" AM_SESSION_NAME=test-am-ghost "$PROJECT_DIR/am" cd "$other" >/dev/null 2>&1 </dev/null || rc=$?
    assert_eq "1" "$rc" "am cd: exits 1 for an unregistered session"

    registry_add "test-am-cd1" "$launch" "main" "claude" "cd test"

    rc=0
    env "${am_env[@]}" AM_SESSION_NAME=test-am-cd1 "$PROJECT_DIR/am" cd "$other" >/dev/null 2>&1 </dev/null || rc=$?
    assert_eq "0" "$rc" "am cd: succeeds inside a registered session"
    assert_eq "$other" "$(registry_get_field test-am-cd1 workdir)" "am cd: sets workdir"
    assert_eq "pr-42" "$(registry_get_field test-am-cd1 branch)" "am cd: refreshes the branch from the new dir"
    assert_eq "$launch" "$(registry_get_field test-am-cd1 directory)" "am cd: keeps the launch directory"
    assert_eq "$other" "$(cat "$state_dir/test-am-cd1.cwd" 2>/dev/null)" "am cd: writes the .cwd sidecar"

    env "${am_env[@]}" AM_SESSION_NAME=test-am-cd1 "$PROJECT_DIR/am" cd "$launch" >/dev/null 2>&1 </dev/null || true
    assert_eq "" "$(registry_get_field test-am-cd1 workdir)" "am cd: clears workdir back in the launch dir"
    assert_eq "main" "$(registry_get_field test-am-cd1 branch)" "am cd: branch follows back"

    (cd "$other" && env "${am_env[@]}" AM_SESSION_NAME=test-am-cd1 "$PROJECT_DIR/am" cd >/dev/null 2>&1 </dev/null) || true
    assert_eq "$other" "$(registry_get_field test-am-cd1 workdir)" "am cd: defaults to the caller's cwd"

    rc=0
    env "${am_env[@]}" AM_SESSION_NAME=test-am-cd1 "$PROJECT_DIR/am" cd "$other/nope" >/dev/null 2>&1 </dev/null || rc=$?
    assert_eq "1" "$rc" "am cd: rejects a missing directory"

    assert_contains "$(env "${am_env[@]}" "$PROJECT_DIR/am" cd --help 2>&1)" "Usage: am cd" "am cd --help: prints usage"

    teardown_integration_env
    rm -rf "$state_dir" "$launch" "$other"
}

# Dispatch surface added in 0.22: multi-session wait, done/result, state
# filters on list/kill, presets on new, doctor.
test_cli_dispatch() {
    $SUMMARY_MODE || echo "=== Testing am wait/done/result/list --state/kill --state/new -p/doctor ==="

    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/config.sh"
    source "$LIB_DIR/tmux.sh"
    source "$LIB_DIR/registry.sh"
    set +u; source "$LIB_DIR/agents.sh"; set -u

    setup_integration_env
    local test_dir state_dir
    test_dir=$(mktemp -d)
    state_dir=$(mktemp -d)
    local am_env=(AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" AM_STATE_DIR="$state_dir" TMUX=)

    local s1 s2
    s1=$(set +u; agent_launch "$test_dir" "claude" "worker one" 2>/dev/null)
    s2=$(set +u; agent_launch "$test_dir" "claude" "worker two" 2>/dev/null)
    if [[ -z "$s1" || -z "$s2" ]]; then
        skip_test "cli dispatch tests (agent_launch failed)"
        teardown_integration_env
        rm -rf "$test_dir" "$state_dir"
        return
    fi
    wait_for_text "stub-agent-ready" am_tmux capture-pane -pt "$s1:.{top}" >/dev/null
    wait_for_text "stub-agent-ready" am_tmux capture-pane -pt "$s2:.{top}" >/dev/null
    # Stub agents are bash scripts: the shell-pane check resolves them as idle,
    # which is in the default wait target set.

    # --- am wait: several sessions ---
    local out rc
    out=$(env "${am_env[@]}" "$PROJECT_DIR/am" wait --timeout 20 "$s1" "$s2" 2>/dev/null); rc=$?
    assert_eq "0" "$rc" "am wait --all: exits 0 when every session arrives"
    assert_eq "2" "$(printf '%s\n' "$out" | grep -c ' idle$')" "am wait --all: one '<session> <state>' line per session"
    assert_contains "$out" "$s1 idle" "am wait --all: names the first session"
    assert_contains "$out" "$s2 idle" "am wait --all: names the second session"

    out=$(env "${am_env[@]}" "$PROJECT_DIR/am" wait --any --timeout 20 "$s1" "$s2" 2>/dev/null); rc=$?
    assert_eq "0" "$rc" "am wait --any: exits 0"
    assert_eq "1" "$(printf '%s\n' "$out" | grep -c .)" "am wait --any: prints exactly one line"

    out=$(env "${am_env[@]}" "$PROJECT_DIR/am" wait --json --timeout 20 "$s1" "$s2" 2>/dev/null)
    assert_eq "2" "$(jq 'length' <<< "$out")" "am wait --json: array with one object per session"
    assert_eq "idle" "$(jq -r '.[0].state' <<< "$out")" "am wait --json: carries the state"

    rc=0
    out=$(env "${am_env[@]}" "$PROJECT_DIR/am" wait --state ready --timeout 1 "$s1" "$s2" 2>/dev/null) || rc=$?
    assert_eq "3" "$rc" "am wait --all: exit 3 when a session times out"

    out=$(env "${am_env[@]}" "$PROJECT_DIR/am" wait --timeout 20 "$s1" 2>/dev/null)
    assert_eq "idle" "$out" "am wait: single-session output is just the state"

    rc=0
    env "${am_env[@]}" "$PROJECT_DIR/am" wait --timeout 1 "$s1" test-am-nope >/dev/null 2>&1 || rc=$?
    assert_eq "1" "$rc" "am wait: unknown session among several is an error"

    # --- am done / am result ---
    rc=0
    env "${am_env[@]}" AM_SESSION_NAME= "$PROJECT_DIR/am" done "orphan" >/dev/null 2>&1 </dev/null || rc=$?
    assert_eq "1" "$rc" "am done: exits 1 outside a session without --session"
    env "${am_env[@]}" AM_SESSION_NAME="$s1" "$PROJECT_DIR/am" done "Fixed 3 tests; PR #1 open" >/dev/null 2>&1 </dev/null
    assert_eq "Fixed 3 tests; PR #1 open" "$(cat "$TEST_AM_DIR/results/$s1.txt" 2>/dev/null)" \
        "am done: records the summary under results/"
    assert_eq "Fixed 3 tests; PR #1 open" "$(env "${am_env[@]}" "$PROJECT_DIR/am" result "$s1" 2>/dev/null)" \
        "am result: prints the recorded summary"
    printf 'multi\nline\n' | env "${am_env[@]}" "$PROJECT_DIR/am" done --session "$s2" >/dev/null 2>&1
    assert_eq $'multi\nline' "$(env "${am_env[@]}" "$PROJECT_DIR/am" result --clear "$s2" 2>/dev/null)" \
        "am done: stdin summary with --session; result --clear prints it"
    rc=0
    env "${am_env[@]}" "$PROJECT_DIR/am" result "$s2" >/dev/null 2>&1 || rc=$?
    assert_eq "1" "$rc" "am result: exit 1 once cleared"
    rc=0
    env "${am_env[@]}" "$PROJECT_DIR/am" result --wait --timeout 3 test-am-gone >/dev/null 2>&1 || rc=$?
    assert_eq "2" "$rc" "am result --wait: exit 2 when the session does not exist"
    env "${am_env[@]}" AM_SESSION_NAME="$s2" "$PROJECT_DIR/am" done >/dev/null 2>&1 </dev/null
    assert_eq "done" "$(env "${am_env[@]}" "$PROJECT_DIR/am" result "$s2" 2>/dev/null)" \
        "am done: no text records 'done'"

    # --- am list --state ---
    out=$(env "${am_env[@]}" "$PROJECT_DIR/am" list --state idle 2>/dev/null)
    assert_contains "$out" "$s1" "am list --state idle: includes an idle session"
    out=$(env "${am_env[@]}" "$PROJECT_DIR/am" list --state ready,running 2>/dev/null)
    assert_not_contains "$out" "$s1" "am list --state ready,running: excludes idle sessions"
    out=$(env "${am_env[@]}" "$PROJECT_DIR/am" list --json --state idle 2>/dev/null)
    assert_eq "2" "$(jq 'length' <<< "$out")" "am list --json --state: filters the array"
    out=$(env "${am_env[@]}" "$PROJECT_DIR/am" list --json --state ready 2>/dev/null)
    assert_eq "0" "$(jq 'length' <<< "$out")" "am list --json --state: empty array when nothing matches"

    # --- am new -p (preset) ---
    env "${am_env[@]}" "$PROJECT_DIR/am" preset save qa -t claude -n "preset task" -- --flag-from-preset >/dev/null 2>&1
    assert_contains "$(env "${am_env[@]}" "$PROJECT_DIR/am" preset list 2>/dev/null)" "qa" "am preset: dispatch reaches preset_main"
    local s3
    s3=$(env "${am_env[@]}" "$PROJECT_DIR/am" new --detach --print-session -p qa "$test_dir" 2>/dev/null </dev/null)
    assert_not_empty "$s3" "am new -p: launches"
    assert_eq "preset task" "$(registry_get_field "$s3" task)" "am new -p: preset fills the task"
    pane_output=$(wait_for_text "stub-agent-argv" am_tmux capture-pane -pt "$s3:.{top}")
    assert_contains "$pane_output" "--flag-from-preset" "am new -p: preset agent args reach the agent"
    local s4
    s4=$(env "${am_env[@]}" "$PROJECT_DIR/am" new --detach --print-session -p qa -n "explicit wins" "$test_dir" -- --extra 2>/dev/null </dev/null)
    assert_eq "explicit wins" "$(registry_get_field "$s4" task)" "am new -p: explicit -n overrides the preset"
    pane_output=$(wait_for_text "stub-agent-argv" am_tmux capture-pane -pt "$s4:.{top}")
    assert_contains "$pane_output" "--flag-from-preset --extra" "am new -p: preset args first, CLI args appended"
    rc=0
    env "${am_env[@]}" "$PROJECT_DIR/am" new --detach -p nosuch "$test_dir" >/dev/null 2>&1 </dev/null || rc=$?
    assert_eq "1" "$rc" "am new -p: unknown preset is an error"

    # --- am doctor ---
    out=$(env "${am_env[@]}" "$PROJECT_DIR/am" doctor "$s1" 2>&1); rc=$?
    assert_eq "0" "$rc" "am doctor <session>: exits 0"
    assert_contains "$out" "$s1" "am doctor: names the session"
    assert_contains "$out" "idle" "am doctor: reports the resolved state"
    out=$(env "${am_env[@]}" "$PROJECT_DIR/am" doctor 2>&1); rc=$?
    assert_eq "0" "$rc" "am doctor (global): exits 0"

    # --- am kill --state ---
    # s3/s4 were created moments ago and read as `starting` for their first
    # 5s; the idle filter must see them settled or it skips them on a fast runner.
    env "${am_env[@]}" "$PROJECT_DIR/am" wait --state idle --timeout 20 "$s3" >/dev/null 2>&1 || true
    env "${am_env[@]}" "$PROJECT_DIR/am" wait --state idle --timeout 20 "$s4" >/dev/null 2>&1 || true
    rc=0
    out=$(env "${am_env[@]}" "$PROJECT_DIR/am" kill --state ready -y 2>&1) || rc=$?
    assert_eq "0" "$rc" "am kill --state: no match is not an error"
    assert_eq "true" "$(tmux_session_exists "$s1" && echo true || echo false)" "am kill --state ready: leaves idle sessions alone"
    env "${am_env[@]}" "$PROJECT_DIR/am" kill --state idle -y >/dev/null 2>&1
    assert_eq "false" "$(tmux_session_exists "$s1" && echo true || echo false)" "am kill --state idle -y: kills matching sessions"
    assert_eq "false" "$(tmux_session_exists "$s3" && echo true || echo false)" "am kill --state idle -y: kills every match"
    assert_cmd_fails "am kill: removes the session's recorded result" test -f "$TEST_AM_DIR/results/$s1.txt"

    teardown_integration_env
    rm -rf "$test_dir" "$state_dir"
    $SUMMARY_MODE || echo ""
}

# Review checkpoints: `am diff` and its --ack / --reset / --list /
# --checkpoint forms against a real git repository.
test_cli_diff() {
    $SUMMARY_MODE || echo "=== Testing am diff ==="

    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/config.sh"
    source "$LIB_DIR/tmux.sh"
    source "$LIB_DIR/registry.sh"
    set +u; source "$LIB_DIR/agents.sh"; set -u

    setup_integration_env
    local state_dir repo plain
    state_dir=$(mktemp -d)
    repo=$(mktemp -d)
    plain=$(mktemp -d)
    repo=$(cd "$repo" && pwd -P)
    local am_env=(AM_DIR="$TEST_AM_DIR" AM_SESSION_PREFIX="test-am-" AM_STATE_DIR="$state_dir" TMUX= AM_SESSION_NAME= GIT_PAGER=cat)
    local g=(git -C "$repo" -c user.name=am-test -c user.email=am@test -c commit.gpgsign=false -c init.defaultBranch=main)

    "${g[@]}" init -q "$repo"
    echo one > "$repo/a.txt"
    "${g[@]}" add a.txt
    "${g[@]}" commit -q -m first

    # Session resolution goes through tmux, so the sessions must exist there.
    tmux_create_session "test-am-diff1" "$repo" 2>/dev/null
    tmux_create_session "test-am-diff2" "$plain" 2>/dev/null
    registry_add "test-am-diff1" "$repo" "main" "claude" "diff test"
    registry_add "test-am-diff2" "$plain" "" "claude" "not a repo"

    local rc=0 out err
    err=$(env "${am_env[@]}" "$PROJECT_DIR/am" diff test-am-diff1 2>&1 >/dev/null </dev/null) || rc=$?
    assert_eq "0" "$rc" "am diff: clean session exits 0"
    assert_contains "$err" "no changes" "am diff: clean session reports no changes"
    assert_contains "$err" "launch checkpoint" "am diff: baseline is the launch checkpoint (created on demand)"

    echo two > "$repo/a.txt"
    echo new > "$repo/b.txt"
    rc=0
    out=$(env "${am_env[@]}" "$PROJECT_DIR/am" diff test-am-diff1 --stat 2>"$state_dir/err" </dev/null) || rc=$?
    err=$(cat "$state_dir/err")
    assert_eq "0" "$rc" "am diff: dirty session exits 0"
    assert_contains "$out" "a.txt" "am diff --stat: modified tracked file listed"
    assert_contains "$out" "b.txt" "am diff --stat: untracked file listed"
    assert_contains "$err" "2 files +2 −1" "am diff: header counts files and lines"
    assert_eq "2" "$(registry_get_field test-am-diff1 review_files)" "am diff: records review_files in the registry"
    assert_eq "2" "$(registry_get_field test-am-diff1 review_added)" "am diff: records review_added"
    assert_eq "1" "$(registry_get_field test-am-diff1 review_deleted)" "am diff: records review_deleted"

    # Committing does not hide the change: trees are compared, not HEAD.
    "${g[@]}" add -A
    "${g[@]}" commit -q -m second
    out=$(env "${am_env[@]}" "$PROJECT_DIR/am" diff test-am-diff1 --stat 2>"$state_dir/err" </dev/null || true)
    err=$(cat "$state_dir/err")
    assert_contains "$out" "b.txt" "am diff: committed changes stay unreviewed"
    assert_contains "$err" "HEAD moved" "am diff: header notes that HEAD moved"

    # --ack: the working copy becomes the baseline.
    rc=0
    err=$(env "${am_env[@]}" "$PROJECT_DIR/am" diff test-am-diff1 --ack 2>&1 </dev/null) || rc=$?
    assert_eq "0" "$rc" "am diff --ack: exits 0"
    assert_contains "$err" "marked reviewed" "am diff --ack: confirms"
    local ack_files
    ack_files=$(registry_get_field test-am-diff1 review_files)
    assert_eq "0" "${ack_files:-0}" "am diff --ack: zeroes the registry count"
    err=$(env "${am_env[@]}" "$PROJECT_DIR/am" diff test-am-diff1 2>&1 >/dev/null </dev/null || true)
    assert_contains "$err" "no changes since the ack checkpoint" "am diff: nothing unreviewed after --ack"

    # --list: launch + head + ack, ack starred as the baseline.
    out=$(env "${am_env[@]}" "$PROJECT_DIR/am" diff test-am-diff1 --list 2>/dev/null </dev/null || true)
    assert_contains "$out" "launch" "am diff --list: launch checkpoint listed"
    assert_contains "$out" "head" "am diff --list: head checkpoint recorded for the commit"
    assert_contains "$out" "ack" "am diff --list: ack checkpoint listed"
    local ack_line ack_id
    ack_line=$(printf '%s\n' "$out" | grep -E '^\* ' | head -n1)
    assert_contains "$ack_line" "ack" "am diff --list: the ack checkpoint is the baseline"
    ack_id=$(printf '%s' "$ack_line" | awk '{print $2}')
    assert_not_empty "$ack_id" "am diff --list: baseline row carries an id"

    # --reset: back to the launch tree, both files unreviewed again.
    rc=0
    err=$(env "${am_env[@]}" "$PROJECT_DIR/am" diff test-am-diff1 --reset 2>&1 </dev/null) || rc=$?
    assert_eq "0" "$rc" "am diff --reset: exits 0"
    assert_contains "$err" "launch checkpoint" "am diff --reset: names the launch checkpoint"
    out=$(env "${am_env[@]}" "$PROJECT_DIR/am" diff test-am-diff1 --stat 2>/dev/null </dev/null || true)
    assert_contains "$out" "b.txt" "am diff --reset: changes since launch visible again"

    # --checkpoint: one-off diff from the ack checkpoint, baseline untouched.
    err=$(env "${am_env[@]}" "$PROJECT_DIR/am" diff test-am-diff1 --checkpoint "$ack_id" 2>&1 >/dev/null </dev/null || true)
    assert_contains "$err" "no changes since the ack checkpoint" "am diff --checkpoint: diffs from the named checkpoint"
    out=$(env "${am_env[@]}" "$PROJECT_DIR/am" diff test-am-diff1 --list 2>/dev/null </dev/null || true)
    assert_contains "$(printf '%s\n' "$out" | grep -E '^\* ')" "launch" "am diff --checkpoint: baseline stays where --reset put it"

    # Branch switch: a branch checkpoint at the new HEAD's tree moves the
    # baseline, so the switch itself is not "unreviewed".
    "${g[@]}" checkout -q -b feature
    echo three > "$repo/c.txt"
    "${g[@]}" add -A
    "${g[@]}" commit -q -m third
    err=$(env "${am_env[@]}" "$PROJECT_DIR/am" diff test-am-diff1 2>&1 >/dev/null </dev/null || true)
    assert_contains "$err" "no changes since the branch checkpoint" "am diff: branch switch moves the baseline"
    echo four > "$repo/c.txt"
    out=$(env "${am_env[@]}" "$PROJECT_DIR/am" diff test-am-diff1 --stat 2>/dev/null </dev/null || true)
    assert_contains "$out" "c.txt" "am diff: edits after the switch are unreviewed"
    assert_not_contains "$out" "b.txt" "am diff: files unchanged since the switch are not"

    # Session from the pane environment.
    rc=0
    env "${am_env[@]}" AM_SESSION_NAME=test-am-diff1 "$PROJECT_DIR/am" diff >/dev/null 2>&1 </dev/null || rc=$?
    assert_eq "0" "$rc" "am diff: resolves the session from AM_SESSION_NAME"

    # Errors.
    rc=0
    env "${am_env[@]}" "$PROJECT_DIR/am" diff >/dev/null 2>&1 </dev/null || rc=$?
    assert_eq "2" "$rc" "am diff: exits 2 outside a session with no name"
    rc=0
    env "${am_env[@]}" "$PROJECT_DIR/am" diff test-am-nope >/dev/null 2>&1 </dev/null || rc=$?
    assert_eq "2" "$rc" "am diff: exits 2 for an unknown session"
    rc=0
    err=$(env "${am_env[@]}" "$PROJECT_DIR/am" diff test-am-diff2 2>&1 >/dev/null </dev/null) || rc=$?
    assert_eq "3" "$rc" "am diff: exits 3 outside a git repository"
    assert_contains "$err" "Not a git repository" "am diff: names the problem outside a repository"
    rc=0
    env "${am_env[@]}" "$PROJECT_DIR/am" diff test-am-diff1 --bogus >/dev/null 2>&1 </dev/null || rc=$?
    assert_eq "1" "$rc" "am diff: rejects unknown options"
    assert_contains "$(env "${am_env[@]}" "$PROJECT_DIR/am" diff --help 2>&1)" "Usage: am diff" "am diff --help: prints usage"

    # Refs survive removal from the registry (restore needs them).
    registry_remove "test-am-diff1"
    assert_cmd_succeeds "am diff: checkpoint refs survive registry removal" \
        git -C "$repo" show-ref --verify --quiet refs/am/test-am-diff1/baseline

    am_tmux kill-session -t test-am-diff1 2>/dev/null || true
    am_tmux kill-session -t test-am-diff2 2>/dev/null || true
    registry_remove "test-am-diff2" 2>/dev/null || true
    teardown_integration_env
    rm -rf "$state_dir" "$repo" "$plain"
}

run_cli_tests() {
    _run_test test_cli
    _run_test test_cli_workspace_and_id
    _run_test test_cli_extended
    _run_test test_cli_cd
    _run_test test_cli_dispatch
    _run_test test_cli_diff
}

if [[ -z "${_AM_TEST_RUNNER:-}" ]]; then
    set -uo pipefail
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helpers.sh"
    check_deps
    run_cli_tests
    test_report
fi
