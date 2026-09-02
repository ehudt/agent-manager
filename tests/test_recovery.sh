#!/usr/bin/env bash
# tests/test_recovery.sh - Durable desired-session and reboot recovery tests

test_recovery_store() {
    $SUMMARY_MODE || echo "=== Testing desired-session store ==="

    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/registry.sh"
    source "$LIB_DIR/recovery.sh"
    set +u; source "$LIB_DIR/agents.sh"; set -u

    setup_isolated_am_dir
    export AM_DESIRED_SESSIONS="$AM_DIR/desired_sessions.json"
    export AM_BOOT_ID="boot-a"
    export AM_MACHINE_ID="machine-a"

    recovery_desired_init
    assert_eq "1" "$(jq -r '.schema_version' "$AM_DESIRED_SESSIONS")" \
        "recovery store: schema version"

    recovery_desired_upsert "am-test01" "/tmp/project" "cursor" "fix auth"

    assert_eq "open" "$(jq -r '.sessions["am-test01"].desired_state' "$AM_DESIRED_SESSIONS")" \
        "recovery store: launch records open intent"
    assert_eq "cursor" "$(jq -r '.sessions["am-test01"].agent_type' "$AM_DESIRED_SESSIONS")" \
        "recovery store: records harness"
    assert_eq "boot-a" "$(jq -r '.sessions["am-test01"].launch_boot_id' "$AM_DESIRED_SESSIONS")" \
        "recovery store: records boot"
    assert_eq "/tmp/project" "$(jq -r '.sessions["am-test01"].effective_directory' "$AM_DESIRED_SESSIONS")" \
        "recovery store: effective directory is the session directory"
    assert_eq "fix auth" "$(jq -r '.sessions["am-test01"].task' "$AM_DESIRED_SESSIONS")" \
        "recovery store: records task"

    local original_order
    original_order=$(jq -r '.sessions["am-test01"].order_key' "$AM_DESIRED_SESSIONS")
    recovery_desired_identity "am-test01" "conversation-1" "/tmp/transcript.jsonl" "hook"
    recovery_desired_upsert "am-test01" "/tmp/project" "cursor" "updated task"

    assert_eq "$original_order" "$(jq -r '.sessions["am-test01"].order_key' "$AM_DESIRED_SESSIONS")" \
        "recovery store: upsert preserves durable order"
    assert_eq "conversation-1" "$(jq -r '.sessions["am-test01"].session_id' "$AM_DESIRED_SESSIONS")" \
        "recovery store: upsert preserves exact identity"

    recovery_desired_remove "am-test01"
    assert_eq "false" "$(jq -r '.sessions | has("am-test01")' "$AM_DESIRED_SESSIONS")" \
        "recovery store: explicit close removes open intent"

    unset AM_DESIRED_SESSIONS AM_BOOT_ID AM_MACHINE_ID
    teardown_isolated_am_dir
    $SUMMARY_MODE || echo ""
}

test_recovery_candidates() {
    $SUMMARY_MODE || echo "=== Testing reboot recovery candidates ==="

    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/registry.sh"
    source "$LIB_DIR/recovery.sh"

    setup_isolated_am_dir
    export AM_DESIRED_SESSIONS="$AM_DIR/desired_sessions.json"
    export AM_MACHINE_ID="machine-a"
    export AM_BOOT_ID="boot-old"

    recovery_desired_upsert "am-missing" "/tmp" "claude" ""
    recovery_desired_identity "am-missing" "sid-missing" "" "hook"
    recovery_desired_upsert "am-live" "/tmp" "cursor" ""
    recovery_desired_identity "am-live" "sid-live" "" "hook"
    recovery_desired_upsert "am-durable" "/tmp" "pi" ""
    mkdir -p "$AM_DIR/identities"
    printf '%s' "sid-durable" > "$AM_DIR/identities/am-durable.sid"
    export AM_MACHINE_ID="machine-b"
    recovery_desired_upsert "am-other-machine" "/tmp" "claude" ""
    recovery_desired_identity "am-other-machine" "sid-other" "" "hook"
    export AM_MACHINE_ID="machine-a"
    local durable_transcript="$AM_DIR/transcripts/sid-transcript.jsonl"
    mkdir -p "$(dirname "$durable_transcript")"
    : > "$durable_transcript"
    recovery_desired_upsert "am-transcript-id" "/tmp" "cursor" ""
    printf '%s' "sid-transcript" > "$AM_DIR/identities/am-transcript-id.sid"
    printf '%s' "$durable_transcript" > "$AM_DIR/identities/am-transcript-id.transcript"

    export AM_BOOT_ID="boot-new"
    tmux_list_am_sessions() { printf '%s\n' "am-live"; }

    local candidates
    candidates=$(recovery_desired_candidates)
    assert_contains "$candidates" '"logical_id":"am-missing"' \
        "recovery candidates: missing prior-boot session selected"
    assert_not_contains "$candidates" '"logical_id":"am-live"' \
        "recovery candidates: already-live session excluded"
    assert_contains "$candidates" '"session_id":"sid-durable"' \
        "recovery candidates: durable sidecar is synchronized before recovery"
    assert_not_contains "$candidates" '"logical_id":"am-other-machine"' \
        "recovery candidates: records from another machine are excluded"
    assert_contains "$candidates" "$durable_transcript" \
        "recovery candidates: durable transcript sidecar is synchronized before recovery"

    recovery_desired_upsert "am-same-boot" "/tmp" "pi" ""
    recovery_desired_identity "am-same-boot" "sid-same" "" "hook"
    candidates=$(recovery_desired_candidates)
    assert_not_contains "$candidates" '"logical_id":"am-same-boot"' \
        "recovery candidates: same-boot loss is not auto-restored"

    recovery_desired_set_status "am-durable" "failed" "test failure" "boot-new"
    candidates=$(recovery_desired_candidates)
    assert_not_contains "$candidates" '"logical_id":"am-durable"' \
        "recovery candidates: failed session is not retried repeatedly in one boot"

    recovery_desired_remove "am-missing"
    candidates=$(recovery_desired_candidates)
    assert_not_contains "$candidates" '"logical_id":"am-missing"' \
        "recovery candidates: explicitly closed session excluded"

    unset -f tmux_list_am_sessions
    unset AM_DESIRED_SESSIONS AM_BOOT_ID AM_MACHINE_ID
    teardown_isolated_am_dir
    $SUMMARY_MODE || echo ""
}

test_recovery_migration() {
    $SUMMARY_MODE || echo "=== Testing live-session migration ==="

    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/registry.sh"
    source "$LIB_DIR/recovery.sh"

    setup_isolated_am_dir
    export AM_DESIRED_SESSIONS="$AM_DIR/desired_sessions.json"
    export AM_MACHINE_ID="machine-a"
    export AM_BOOT_ID="boot-a"

    registry_add "am-live-legacy" "/tmp" "main" "cursor" "legacy task"
    registry_add "am-stale-legacy" "/tmp" "main" "claude" "stale task"
    mkdir -p "$AM_STATE_DIR"
    printf '%s' "legacy-exact-id" > "$AM_STATE_DIR/am-live-legacy.sid"
    printf '%s' "/tmp/legacy-exact-id.jsonl" > "$AM_STATE_DIR/am-live-legacy.transcript"
    tmux_list_am_sessions() { printf '%s\n' "am-live-legacy"; }
    am_session_order() { printf '%s\n' "am-live-legacy"; }

    recovery_migrate_live_registry
    assert_eq "open" \
        "$(jq -r '.sessions["am-live-legacy"].desired_state // ""' "$AM_DESIRED_SESSIONS")" \
        "recovery migration: imports currently live registry row"
    assert_eq "legacy task" \
        "$(jq -r '.sessions["am-live-legacy"].task // ""' "$AM_DESIRED_SESSIONS")" \
        "recovery migration: preserves task"
    assert_eq "legacy-exact-id" \
        "$(jq -r '.sessions["am-live-legacy"].session_id // ""' "$AM_DESIRED_SESSIONS")" \
        "recovery migration: persists ephemeral exact identity"
    assert_eq "false" \
        "$(jq -r '.sessions | has("am-stale-legacy")' "$AM_DESIRED_SESSIONS")" \
        "recovery migration: does not import stale registry row"

    unset -f tmux_list_am_sessions am_session_order
    unset AM_DESIRED_SESSIONS AM_BOOT_ID AM_MACHINE_ID
    teardown_isolated_am_dir
    $SUMMARY_MODE || echo ""
}

test_recovery_preflight_matrix() {
    $SUMMARY_MODE || echo "=== Testing recovery safety preflight ==="

    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/config.sh"
    source "$LIB_DIR/registry.sh"
    set +u; source "$LIB_DIR/agents.sh"; set -u
    source "$LIB_DIR/recovery.sh"

    setup_isolated_am_dir
    export AM_SESSION_PREFIX="am-"

    agent_get_command() {
        [[ "$1" == "missing-agent" ]] && echo "definitely-not-installed-am-agent" || echo "true"
    }

    assert_preflight_blocked() {
        local record="$1" expected="$2" label="$3" reason rc=0
        reason=$(recovery_preflight_record "$record") || rc=$?
        assert_eq "1" "$rc" "$label: rejected"
        assert_contains "$reason" "$expected" "$label: actionable reason"
    }

    local base record
    base=$(jq -cn '{
        logical_id: "am-preflight", session_name: "am-preflight",
        agent_type: "claude", project_directory: "/tmp",
        effective_directory: "/tmp", session_id: "sid-exact",
        identity_source: "hook"
    }')

    record=$(jq -c '.effective_directory="/definitely/missing/am-directory"' <<< "$base")
    assert_preflight_blocked "$record" "directory unavailable" \
        "recovery preflight: missing directory"

    record=$(jq -c '.agent_type="missing-agent"' <<< "$base")
    assert_preflight_blocked "$record" "agent command not found" \
        "recovery preflight: missing harness"

    # Records written by pre-0.18 releases still carry sandbox/worktree
    # fields; they are ignored rather than blocking recovery.
    record=$(jq -c '.agent_type="codex" | .sandbox_mode="true" | .worktree_name="feature" | .sandbox_shares=["/definitely/missing:/share:ro"]' <<< "$base")
    local legacy_reason legacy_rc=0
    legacy_reason=$(recovery_preflight_record "$record") || legacy_rc=$?
    assert_eq "0" "$legacy_rc" "recovery preflight: legacy sandbox/worktree fields are ignored"
    assert_eq "" "$legacy_reason" "recovery preflight: legacy fields produce no block reason"

    assert_preflight_blocked "$base" "conversation history unavailable" \
        "recovery preflight: missing conversation history"

    record=$(jq -c '.agent_type="unsupported"' <<< "$base")
    assert_preflight_blocked "$record" "automatic resume unsupported" \
        "recovery preflight: unsupported harness"

    unset -f agent_get_command assert_preflight_blocked
    unset AM_SESSION_PREFIX
    teardown_isolated_am_dir
    $SUMMARY_MODE || echo ""
}

test_recovery_coordinator() {
    $SUMMARY_MODE || echo "=== Testing recovery coordinator ==="

    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/registry.sh"
    source "$LIB_DIR/recovery.sh"
    set +u; source "$LIB_DIR/agents.sh"; set -u

    setup_isolated_am_dir
    export AM_DESIRED_SESSIONS="$AM_DIR/desired_sessions.json"
    export AM_MACHINE_ID="machine-a"
    export AM_BOOT_ID="boot-old"

    local transcript="$AM_DIR/sid-restore.jsonl"
    : > "$transcript"
    recovery_desired_upsert "am-restore" "/tmp" "cursor" "resume task"
    recovery_desired_identity "am-restore" "sid-restore" "$transcript" "hook"

    export AM_BOOT_ID="boot-new"
    tmux_list_am_sessions() { :; }
    agent_get_command() { echo "true"; }
    local capture="$AM_DIR/launch.txt"
    agent_launch() {
        printf 'name=%s\nargs=%s\n' "$_AM_SESSION_NAME_OVERRIDE" "$*" > "$capture"
        echo "$_AM_SESSION_NAME_OVERRIDE"
    }
    recovery_agent_started() { return 0; }

    local record
    record=$(jq -c '.sessions["am-restore"]' "$AM_DESIRED_SESSIONS")
    recovery_restore_one "$record"

    assert_contains "$(cat "$capture")" "name=am-restore" \
        "recovery coordinator: preserves physical session name"
    assert_contains "$(cat "$capture")" "--resume sid-restore" \
        "recovery coordinator: uses exact native resume identity"
    assert_eq "args=/tmp cursor resume task --resume sid-restore" "$(sed -n 2p "$capture")" \
        "recovery coordinator: launch args are directory, agent, task, resume args"
    assert_eq "live" "$(jq -r '.sessions["am-restore"].recovery_state' "$AM_DESIRED_SESSIONS")" \
        "recovery coordinator: successful restore becomes live"
    assert_eq "boot-new" "$(jq -r '.sessions["am-restore"].launch_boot_id' "$AM_DESIRED_SESSIONS")" \
        "recovery coordinator: successful restore records current boot"

    recovery_desired_upsert "am-blocked" "/tmp" "claude" ""
    local blocked
    blocked=$(jq -c '.sessions["am-blocked"]' "$AM_DESIRED_SESSIONS")
    assert_cmd_fails "recovery coordinator: missing exact identity is blocked" \
        recovery_restore_one "$blocked"
    assert_contains "$(jq -r '.sessions["am-blocked"].recovery_error' "$AM_DESIRED_SESSIONS")" \
        "exact conversation identity" \
        "recovery coordinator: blocked reason is actionable"

    recovery_desired_upsert "am-exited" "/tmp" "cursor" ""
    recovery_desired_identity "am-exited" "sid-exited" "$transcript" "hook"
    recovery_agent_started() { return 1; }
    recovery_cleanup_failed_runtime() { printf '%s' "$1" > "$AM_DIR/cleaned-runtime"; }
    record=$(jq -c '.sessions["am-exited"]' "$AM_DESIRED_SESSIONS")
    assert_cmd_fails "recovery coordinator: exited resume command fails recovery" \
        recovery_restore_one "$record"
    assert_eq "am-exited" "$(cat "$AM_DIR/cleaned-runtime")" \
        "recovery coordinator: exited resume runtime is cleaned"
    assert_contains "$(jq -r '.sessions["am-exited"].recovery_error' "$AM_DESIRED_SESSIONS")" \
        "exited before agent started" \
        "recovery coordinator: exited agent remains actionable"

    recovery_desired_upsert "am-cancelled" "/tmp" "cursor" ""
    recovery_desired_identity "am-cancelled" "sid-cancelled" "$transcript" "hook"
    recovery_agent_started() {
        recovery_desired_remove "am-cancelled"
        return 0
    }
    record=$(jq -c '.sessions["am-cancelled"]' "$AM_DESIRED_SESSIONS")
    assert_cmd_fails "recovery coordinator: cancellation during startup wins" \
        recovery_restore_one "$record"
    assert_eq "am-cancelled" "$(cat "$AM_DIR/cleaned-runtime")" \
        "recovery coordinator: cancelled runtime is cleaned after startup wait"

    unset -f tmux_list_am_sessions agent_get_command agent_launch recovery_agent_started \
        recovery_cleanup_failed_runtime
    unset _AM_RECOVERY_MODE _AM_SESSION_NAME_OVERRIDE _AM_DEFER_SIDEBAR_REFRESH
    unset AM_DESIRED_SESSIONS AM_BOOT_ID AM_MACHINE_ID
    teardown_isolated_am_dir
    $SUMMARY_MODE || echo ""
}

test_recovery_native_adapters() {
    $SUMMARY_MODE || echo "=== Testing native recovery adapters ==="

    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/registry.sh"
    set +u; source "$LIB_DIR/agents.sh"; set -u
    source "$LIB_DIR/recovery.sh"

    setup_isolated_am_dir
    export AM_DESIRED_SESSIONS="$AM_DIR/desired_sessions.json"
    export AM_MACHINE_ID="machine-a"
    export AM_BOOT_ID="boot-old"

    local capture="$AM_DIR/native-launches.txt"
    agent_get_command() { echo "true"; }
    _sessions_log_jsonl_exists() { return 0; }
    agent_launch() {
        printf '%s|%s\n' "$_AM_SESSION_NAME_OVERRIDE" "$*" >> "$capture"
        echo "$_AM_SESSION_NAME_OVERRIDE"
    }
    recovery_agent_started() { return 0; }

    local agent
    for agent in claude cursor pi codex; do
        recovery_desired_upsert "am-$agent" "/tmp" "$agent" "$agent task"
        recovery_desired_identity "am-$agent" "sid-$agent" "" "hook"
    done

    export AM_BOOT_ID="boot-new"
    local record
    for agent in claude cursor pi codex; do
        record=$(jq -c --arg id "am-$agent" '.sessions[$id]' "$AM_DESIRED_SESSIONS")
        recovery_restore_one "$record"
    done

    local launches
    launches=$(cat "$capture")
    assert_contains "$launches" "am-claude|/tmp claude claude task --resume sid-claude" \
        "recovery adapter: Claude uses --resume"
    assert_contains "$launches" "am-cursor|/tmp cursor cursor task --resume sid-cursor" \
        "recovery adapter: Cursor uses --resume"
    assert_contains "$launches" "am-pi|/tmp pi pi task --session sid-pi" \
        "recovery adapter: pi uses --session"
    assert_contains "$launches" "am-codex|/tmp codex codex task resume sid-codex" \
        "recovery adapter: Codex uses resume subcommand"

    unset -f agent_get_command _sessions_log_jsonl_exists agent_launch recovery_agent_started
    unset _AM_RECOVERY_MODE _AM_SESSION_NAME_OVERRIDE _AM_DEFER_SIDEBAR_REFRESH
    unset AM_DESIRED_SESSIONS AM_BOOT_ID AM_MACHINE_ID
    teardown_isolated_am_dir
    $SUMMARY_MODE || echo ""
}

test_recovery_reboot_integration() {
    $SUMMARY_MODE || echo "=== Testing reboot recovery integration ==="

    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/tmux.sh"
    source "$LIB_DIR/registry.sh"
    set +u; source "$LIB_DIR/agents.sh"; set -u
    source "$LIB_DIR/recovery.sh"

    setup_integration_env
    export AM_BOOT_ID="boot-before"
    export AM_MACHINE_ID="machine-a"

    local test_dir transcript session_name
    test_dir=$(mktemp -d)
    transcript="$test_dir/sid-reboot.jsonl"
    : > "$transcript"
    session_name=$(set +u; agent_launch "$test_dir" "cursor" "reboot task" 2>/dev/null)
    recovery_desired_identity "$session_name" "sid-reboot" "$transcript" "hook"

    # Simulate reboot/tmux-server loss: runtime disappears without agent_kill,
    # leaving desired-open intent intact.
    am_tmux kill-session -t "$session_name"
    assert_eq "false" "$(tmux_session_exists "$session_name" && echo true || echo false)" \
        "reboot recovery: simulated runtime is gone"

    export AM_BOOT_ID="boot-after"
    recovery_run

    assert_eq "true" "$(tmux_session_exists "$session_name" && echo true || echo false)" \
        "reboot recovery: recreates missing physical session"
    assert_contains "$(tmux_capture_pane "$session_name:.{top}" 20 2>/dev/null || true)" \
        "stub-agent-ready" \
        "reboot recovery: resumed agent process actually starts"
    assert_eq "live" \
        "$(jq -r --arg id "$session_name" '.sessions[$id].recovery_state' "$AM_DIR/desired_sessions.json")" \
        "reboot recovery: desired session converges to live"
    assert_eq "boot-after" \
        "$(jq -r --arg id "$session_name" '.sessions[$id].launch_boot_id' "$AM_DIR/desired_sessions.json")" \
        "reboot recovery: records restored boot"

    assert_eq "$(cd "$test_dir" && pwd -P)" \
        "$(cd "$(am_tmux display-message -p -t "$session_name" '#{pane_current_path}')" && pwd -P)" \
        "reboot recovery: session resumes in its recorded directory"
    [[ -n "$session_name" ]] && agent_kill "$session_name" 2>/dev/null

    rm -rf "$test_dir"
    unset AM_BOOT_ID AM_MACHINE_ID
    teardown_integration_env
    $SUMMARY_MODE || echo ""
}

test_recovery_progressive_start() {
    $SUMMARY_MODE || echo "=== Testing progressive recovery startup ==="

    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/config.sh"
    source "$LIB_DIR/registry.sh"
    source "$LIB_DIR/recovery.sh"

    setup_isolated_am_dir
    am_config_init
    export AM_DESIRED_SESSIONS="$AM_DIR/desired_sessions.json"
    export AM_MACHINE_ID="machine-a"
    export AM_BOOT_ID="boot-old"
    recovery_desired_upsert "am-progress" "/tmp" "codex" ""
    recovery_desired_identity "am-progress" "codex-progress" "" "hook"

    export AM_BOOT_ID="boot-new"
    tmux_list_am_sessions() { :; }
    local old_root="$AM_ROOT_DIR" stub_root
    stub_root=$(mktemp -d)
    cat > "$stub_root/am" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$AM_DIR/worker-invoked"
EOF
    chmod +x "$stub_root/am"
    AM_ROOT_DIR="$stub_root"

    recovery_start_for_browser
    assert_eq "queued" \
        "$(jq -r '.sessions["am-progress"].recovery_state' "$AM_DESIRED_SESSIONS")" \
        "progressive recovery: browser sees queued row immediately"

    local waited=0
    while [[ ! -f "$AM_DIR/worker-invoked" && $waited -lt 20 ]]; do
        sleep 0.05
        waited=$((waited + 1))
    done
    assert_contains "$(cat "$AM_DIR/worker-invoked" 2>/dev/null || echo "")" \
        "recover-open --worker" \
        "progressive recovery: detached worker starts"

    AM_ROOT_DIR="$old_root"
    unset -f tmux_list_am_sessions
    unset AM_DESIRED_SESSIONS AM_BOOT_ID AM_MACHINE_ID
    rm -rf "$stub_root"
    teardown_isolated_am_dir
    $SUMMARY_MODE || echo ""
}

test_recovery_disabled_still_scopes_browser_machine() {
    $SUMMARY_MODE || echo "=== Testing disabled recovery machine scope ==="

    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/config.sh"
    source "$LIB_DIR/registry.sh"
    source "$LIB_DIR/recovery.sh"
    setup_isolated_am_dir

    export AM_AUTO_RESTORE="false"
    unset AM_MACHINE_ID
    recovery_start_for_browser
    assert_not_empty "${AM_MACHINE_ID:-}" \
        "disabled recovery: browser still receives current machine identity"

    unset AM_AUTO_RESTORE AM_MACHINE_ID
    teardown_isolated_am_dir
    $SUMMARY_MODE || echo ""
}

test_recovery_worker_locking() {
    $SUMMARY_MODE || echo "=== Testing recovery worker locking ==="

    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/registry.sh"
    source "$LIB_DIR/recovery.sh"

    setup_isolated_am_dir
    export AM_DESIRED_SESSIONS="$AM_DIR/desired_sessions.json"
    export AM_MACHINE_ID="machine-a"
    export AM_BOOT_ID="boot-old"

    assert_cmd_succeeds "recovery lock: first worker acquires coordinator" \
        _recovery_worker_lock
    assert_cmd_fails "recovery lock: concurrent worker is rejected" \
        _recovery_worker_lock
    _recovery_worker_unlock

    recovery_desired_upsert "am-stale-claim" "/tmp" "codex" ""
    recovery_desired_identity "am-stale-claim" "sid-stale" "" "hook"
    recovery_desired_set_status "am-stale-claim" "restoring" "" "boot-new"
    mkdir -p "$AM_DIR/.recovery-worker.lock"
    printf '%s\n' "$$" > "$AM_DIR/.recovery-worker.lock/pid"
    printf '%s\n' "0" > "$AM_DIR/.recovery-worker.lock/started_at"
    tmux_list_am_sessions() { :; }

    recovery_reclaim_stale_claims
    assert_eq "pending" \
        "$(jq -r '.sessions["am-stale-claim"].recovery_state' "$AM_DESIRED_SESSIONS")" \
        "recovery lock: stale restoring claim becomes retryable"
    assert_eq "" \
        "$(jq -r '.sessions["am-stale-claim"].last_attempt_boot' "$AM_DESIRED_SESSIONS")" \
        "recovery lock: stale attempt lease is cleared"

    unset -f tmux_list_am_sessions
    unset AM_DESIRED_SESSIONS AM_BOOT_ID AM_MACHINE_ID
    teardown_isolated_am_dir
    $SUMMARY_MODE || echo ""
}

test_recovery_agent_start_stability() {
    $SUMMARY_MODE || echo "=== Testing recovered agent startup stability ==="

    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/tmux.sh"
    source "$LIB_DIR/registry.sh"
    source "$LIB_DIR/recovery.sh"
    set +u; source "$LIB_DIR/agents.sh"; set -u
    setup_integration_env

    local session="test-am-start-stability"
    tmux_create_session "$session" "/tmp"
    tmux_send_keys "$session:.{top}" "sleep 0.4" Enter
    assert_cmd_fails "recovery startup: short-lived process is rejected" \
        recovery_agent_started "$session"

    tmux_send_keys "$session:.{top}" "sleep 2" Enter
    assert_cmd_succeeds "recovery startup: stable process is accepted" \
        recovery_agent_started "$session"

    tmux_kill_session "$session" 2>/dev/null || true
    teardown_integration_env
    $SUMMARY_MODE || echo ""
}

test_recovery_batch_partial_success() {
    $SUMMARY_MODE || echo "=== Testing recovery batch partial success ==="

    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/registry.sh"
    set +u; source "$LIB_DIR/agents.sh"; set -u
    source "$LIB_DIR/recovery.sh"

    setup_isolated_am_dir
    export AM_DESIRED_SESSIONS="$AM_DIR/desired_sessions.json"
    export AM_MACHINE_ID="machine-a"
    export AM_BOOT_ID="boot-old"

    recovery_desired_upsert "am-good" "/tmp" "cursor" ""
    recovery_desired_identity "am-good" "sid-good" "/tmp/sid-good.jsonl" "hook"
    recovery_desired_upsert "am-bad" "/tmp" "cursor" ""

    export AM_BOOT_ID="boot-new"
    tmux_list_am_sessions() { :; }
    agent_get_command() { echo "true"; }
    _sessions_log_jsonl_exists() { return 0; }
    agent_launch() {
        echo "$_AM_SESSION_NAME_OVERRIDE"
    }
    recovery_agent_started() { return 0; }
    am_refresh_sidebar_cache() { :; }

    recovery_run
    assert_eq "live" "$(jq -r '.sessions["am-good"].recovery_state' "$AM_DESIRED_SESSIONS")" \
        "recovery batch: successful session remains restored"
    assert_eq "blocked" "$(jq -r '.sessions["am-bad"].recovery_state' "$AM_DESIRED_SESSIONS")" \
        "recovery batch: one blocked session does not roll back successes"

    unset -f tmux_list_am_sessions agent_get_command _sessions_log_jsonl_exists \
        agent_launch recovery_agent_started am_refresh_sidebar_cache
    unset AM_DESIRED_SESSIONS AM_BOOT_ID AM_MACHINE_ID
    teardown_isolated_am_dir
    $SUMMARY_MODE || echo ""
}

run_recovery_tests() {
    _run_test test_recovery_store
    _run_test test_recovery_candidates
    _run_test test_recovery_migration
    _run_test test_recovery_preflight_matrix
    _run_test test_recovery_coordinator
    _run_test test_recovery_native_adapters
    _run_test test_recovery_reboot_integration
    _run_test test_recovery_progressive_start
    _run_test test_recovery_disabled_still_scopes_browser_machine
    _run_test test_recovery_worker_locking
    _run_test test_recovery_agent_start_stability
    _run_test test_recovery_batch_partial_success
}

if [[ -z "${_AM_TEST_RUNNER:-}" ]]; then
    set -uo pipefail
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helpers.sh"
    check_deps
    run_recovery_tests
    test_report
fi
