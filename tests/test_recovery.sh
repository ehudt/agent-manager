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

    record=$(jq -c '.project_directory="/definitely/missing/am-directory"' <<< "$base")
    assert_preflight_blocked "$record" "directory unavailable" \
        "recovery preflight: missing launch directory"

    # The resume runs in the launch directory (it keys the transcript store);
    # a vanished effective directory is only a lost label, never a block.
    record=$(jq -c '.effective_directory="/definitely/missing/am-workdir"' <<< "$base")
    local eff_reason
    eff_reason=$(recovery_preflight_record "$record") || true
    assert_not_contains "$eff_reason" "directory unavailable" \
        "recovery preflight: missing effective directory does not block"

    # Conversation history is looked up under the launch directory, not the
    # directory the agent had moved to.
    local jsonl_probe="$AM_DIR/jsonl-probe"
    _sessions_log_jsonl_exists() { printf '%s' "$1" > "$jsonl_probe"; return 0; }
    record=$(jq -c '.effective_directory="/definitely/missing/am-workdir"' <<< "$base")
    recovery_preflight_record "$record" >/dev/null || true
    assert_eq "/tmp" "$(cat "$jsonl_probe")" \
        "recovery preflight: transcript lookup uses the launch directory"
    unset -f _sessions_log_jsonl_exists

    # A pooled checkout that still exists but was re-allocated to another
    # branch is blocked with the expected/found pair.
    local repo_dir
    repo_dir=$(mktemp -d)
    (cd "$repo_dir" && git init -q && git checkout -q -b feature-a)
    record=$(jq -c --arg d "$repo_dir" '.project_directory=$d | .branch="feature-a"' <<< "$base")
    local same_reason
    same_reason=$(recovery_preflight_record "$record") || true
    assert_not_contains "$same_reason" "branch changed" \
        "recovery preflight: matching branch passes the branch guard"
    (cd "$repo_dir" && git checkout -q -b other)
    assert_preflight_blocked "$record" "branch changed: expected feature-a, found other" \
        "recovery preflight: re-allocated checkout"
    record=$(jq -c '.branch=""' <<< "$record")
    same_reason=$(recovery_preflight_record "$record") || true
    assert_not_contains "$same_reason" "branch changed" \
        "recovery preflight: records without a branch are not judged"
    rm -rf "$repo_dir"

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

test_recovery_restore_launch_directory() {
    $SUMMARY_MODE || echo "=== Testing restore directory and workdir label ==="

    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/registry.sh"
    source "$LIB_DIR/recovery.sh"
    set +u; source "$LIB_DIR/agents.sh"; set -u

    setup_isolated_am_dir
    export AM_DESIRED_SESSIONS="$AM_DIR/desired_sessions.json"
    export AM_MACHINE_ID="machine-a"
    export AM_BOOT_ID="boot-old"

    local workdir="$AM_DIR/moved-here"
    mkdir -p "$workdir"
    recovery_desired_upsert "am-moved" "/tmp" "cursor" "moved task"
    recovery_desired_identity "am-moved" "sid-moved" "" "hook"
    recovery_desired_set_workspace "am-moved" "$workdir" ""
    assert_eq "$workdir" "$(jq -r '.sessions["am-moved"].effective_directory' "$AM_DESIRED_SESSIONS")" \
        "restore directory: effective directory recorded"

    export AM_BOOT_ID="boot-new"
    agent_get_command() { echo "true"; }
    _sessions_log_jsonl_exists() { return 0; }
    local launch_capture="$AM_DIR/launch.txt" workdir_capture="$AM_DIR/workdir.txt"
    agent_launch() {
        printf '%s\n' "$1" > "$launch_capture"
        echo "$_AM_SESSION_NAME_OVERRIDE"
    }
    agent_set_workdir() { printf '%s|%s' "$1" "$2" > "$workdir_capture"; }
    recovery_agent_started() { return 0; }

    local record
    record=$(jq -c '.sessions["am-moved"]' "$AM_DESIRED_SESSIONS")
    recovery_restore_one "$record"
    assert_eq "/tmp" "$(cat "$launch_capture")" \
        "restore directory: resume runs in the launch directory, not the workdir"
    assert_eq "am-moved|$workdir" "$(cat "$workdir_capture")" \
        "restore directory: workdir label re-applied after launch"

    # Same launch and effective directory: the label is left alone.
    rm -f "$workdir_capture"
    recovery_desired_upsert "am-stayed" "/tmp" "cursor" ""
    recovery_desired_identity "am-stayed" "sid-stayed" "" "hook"
    record=$(jq -c '.sessions["am-stayed"]' "$AM_DESIRED_SESSIONS")
    recovery_restore_one "$record"
    assert_eq "false" "$([[ -f "$workdir_capture" ]] && echo true || echo false)" \
        "restore directory: unmoved session gets no workdir override"

    # A workdir that no longer exists is dropped rather than applied.
    recovery_desired_upsert "am-gone" "/tmp" "cursor" ""
    recovery_desired_identity "am-gone" "sid-gone" "" "hook"
    recovery_desired_set_workspace "am-gone" "/definitely/missing/am-workdir" ""
    record=$(jq -c '.sessions["am-gone"]' "$AM_DESIRED_SESSIONS")
    recovery_restore_one "$record"
    assert_eq "live" "$(jq -r '.sessions["am-gone"].recovery_state' "$AM_DESIRED_SESSIONS")" \
        "restore directory: vanished workdir still restores"
    assert_eq "false" "$([[ -f "$workdir_capture" ]] && echo true || echo false)" \
        "restore directory: vanished workdir is not applied"

    unset -f agent_get_command _sessions_log_jsonl_exists agent_launch agent_set_workdir \
        recovery_agent_started
    unset _AM_RECOVERY_MODE _AM_SESSION_NAME_OVERRIDE _AM_DEFER_SIDEBAR_REFRESH
    unset AM_DESIRED_SESSIONS AM_BOOT_ID AM_MACHINE_ID
    teardown_isolated_am_dir
    $SUMMARY_MODE || echo ""
}

test_recovery_rebind_marker_cleanup() {
    $SUMMARY_MODE || echo "=== Testing rebind marker cleanup on failed restore ==="

    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/tmux.sh"
    source "$LIB_DIR/registry.sh"
    source "$LIB_DIR/recovery.sh"
    set +u; source "$LIB_DIR/agents.sh"; set -u

    setup_isolated_am_dir
    export AM_DESIRED_SESSIONS="$AM_DIR/desired_sessions.json"
    export AM_MACHINE_ID="machine-a"
    export AM_BOOT_ID="boot-old"
    local identity_dir
    identity_dir=$(_recovery_identity_dir)

    recovery_desired_upsert "am-nolaunch" "/tmp" "cursor" ""
    recovery_desired_identity "am-nolaunch" "sid-nolaunch" "" "hook"
    recovery_desired_upsert "am-noagent" "/tmp" "cursor" ""
    recovery_desired_identity "am-noagent" "sid-noagent" "" "hook"

    export AM_BOOT_ID="boot-new"
    agent_get_command() { echo "true"; }
    _sessions_log_jsonl_exists() { return 0; }

    # agent_launch fails outright: the marker written just before it must go.
    agent_launch() { return 1; }
    local record
    record=$(jq -c '.sessions["am-nolaunch"]' "$AM_DESIRED_SESSIONS")
    assert_cmd_fails "rebind cleanup: failed launch fails recovery" \
        recovery_restore_one "$record"
    assert_eq "failed" "$(jq -r '.sessions["am-nolaunch"].recovery_state' "$AM_DESIRED_SESSIONS")" \
        "rebind cleanup: failed launch is recorded"
    assert_eq "false" "$([[ -f "$identity_dir/am-nolaunch.rebind" ]] && echo true || echo false)" \
        "rebind cleanup: failed launch removes the rebind marker"

    # The session came up but the agent exited before starting: runtime
    # cleanup also withdraws the marker.
    agent_launch() { echo "$_AM_SESSION_NAME_OVERRIDE"; }
    recovery_agent_started() { return 1; }
    tmux_kill_session() { :; }
    record=$(jq -c '.sessions["am-noagent"]' "$AM_DESIRED_SESSIONS")
    assert_cmd_fails "rebind cleanup: exited agent fails recovery" \
        recovery_restore_one "$record"
    assert_eq "false" "$([[ -f "$identity_dir/am-noagent.rebind" ]] && echo true || echo false)" \
        "rebind cleanup: exited agent removes the rebind marker"

    # Sanity: the marker is still written for a launch that proceeds.
    recovery_desired_upsert "am-okay" "/tmp" "cursor" ""
    recovery_desired_identity "am-okay" "sid-okay" "" "hook"
    recovery_agent_started() { return 0; }
    record=$(jq -c '.sessions["am-okay"]' "$AM_DESIRED_SESSIONS")
    recovery_restore_one "$record"
    assert_eq "true" "$([[ -f "$identity_dir/am-okay.rebind" ]] && echo true || echo false)" \
        "rebind cleanup: successful launch leaves the marker for the hook"

    unset -f agent_get_command _sessions_log_jsonl_exists agent_launch recovery_agent_started \
        tmux_kill_session
    unset _AM_RECOVERY_MODE _AM_SESSION_NAME_OVERRIDE _AM_DEFER_SIDEBAR_REFRESH
    unset AM_DESIRED_SESSIONS AM_BOOT_ID AM_MACHINE_ID
    teardown_isolated_am_dir
    $SUMMARY_MODE || echo ""
}

test_recovery_sidecar_mirror() {
    $SUMMARY_MODE || echo "=== Testing durable .cwd/.bg sidecar mirror ==="

    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/registry.sh"
    source "$LIB_DIR/recovery.sh"

    setup_isolated_am_dir
    export AM_DESIRED_SESSIONS="$AM_DIR/desired_sessions.json"
    export AM_MACHINE_ID="machine-a"
    export AM_BOOT_ID="boot-a"
    local identity_dir
    identity_dir=$(_recovery_identity_dir)

    local repo_dir workdir
    repo_dir=$(mktemp -d)
    (cd "$repo_dir" && git init -q && git checkout -q -b feature-a)
    workdir="$AM_DIR/moved-here"
    mkdir -p "$workdir"

    recovery_desired_upsert "am-mirror" "$repo_dir" "claude" ""
    assert_eq "feature-a" "$(jq -r '.sessions["am-mirror"].branch' "$AM_DESIRED_SESSIONS")" \
        "sidecar mirror: launch records the launch-directory branch"
    recovery_desired_upsert "am-dead" "$repo_dir" "claude" ""

    mkdir -p "$AM_STATE_DIR"
    printf '%s' "$workdir" > "$AM_STATE_DIR/am-mirror.cwd"
    printf '%s' '[{"id":"b1","type":"shell","status":"running"}]' > "$AM_STATE_DIR/am-mirror.bg"
    printf '%s' "$workdir" > "$AM_STATE_DIR/am-dead.cwd"
    tmux_list_am_sessions() { printf '%s\n' "am-mirror"; }

    recovery_sync_live_sidecars
    assert_eq "$workdir" "$(cat "$identity_dir/am-mirror.cwd" 2>/dev/null)" \
        "sidecar mirror: live .cwd copied to the identity dir"
    assert_contains "$(cat "$identity_dir/am-mirror.bg" 2>/dev/null)" '"id":"b1"' \
        "sidecar mirror: live .bg copied to the identity dir"
    assert_eq "$workdir" "$(jq -r '.sessions["am-mirror"].effective_directory' "$AM_DESIRED_SESSIONS")" \
        "sidecar mirror: desired record follows the mirrored cwd"
    assert_eq "false" "$([[ -f "$identity_dir/am-dead.cwd" ]] && echo true || echo false)" \
        "sidecar mirror: only live sessions are mirrored"

    # A checkout in place is picked up by the branch refresh.
    (cd "$repo_dir" && git checkout -q -b feature-b)
    recovery_sync_live_sidecars
    assert_eq "feature-b" "$(jq -r '.sessions["am-mirror"].branch' "$AM_DESIRED_SESSIONS")" \
        "sidecar mirror: branch refreshed from the launch directory"

    # After a reboot the ephemeral copies are gone but the mirror remains,
    # and the restore seeds the new session's .cwd from it.
    rm -rf "$AM_STATE_DIR"
    recovery_sync_live_sidecars
    assert_eq "$workdir" "$(cat "$identity_dir/am-mirror.cwd" 2>/dev/null)" \
        "sidecar mirror: durable copy survives a missing state dir"
    unset -f agent_set_workdir 2>/dev/null || true
    recovery_apply_workdir "am-mirror" "$repo_dir" \
        "$(jq -r '.sessions["am-mirror"].effective_directory' "$AM_DESIRED_SESSIONS")"
    assert_eq "$workdir" "$(cat "$AM_STATE_DIR/am-mirror.cwd" 2>/dev/null)" \
        "sidecar mirror: restore seeds the ephemeral .cwd before the first hook event"

    unset -f tmux_list_am_sessions
    rm -rf "$repo_dir"
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
    local old_state_dir="${AM_STATE_DIR:-}"
    export AM_STATE_DIR="$AM_DIR/state"

    local test_dir work_dir transcript session_name
    test_dir=$(mktemp -d)
    work_dir=$(mktemp -d)
    transcript="$test_dir/sid-reboot.jsonl"
    : > "$transcript"
    session_name=$(set +u; agent_launch "$test_dir" "cursor" "reboot task" 2>/dev/null)
    recovery_desired_identity "$session_name" "sid-reboot" "$transcript" "hook"

    # The agent moved to another checkout (its hook wrote the .cwd sidecar)
    # and a browser open made that durable before the reboot.
    mkdir -p "$AM_STATE_DIR"
    printf '%s' "$work_dir" > "$AM_STATE_DIR/$session_name.cwd"
    recovery_sync_live_sidecars

    # Simulate reboot/tmux-server loss: runtime disappears without agent_kill,
    # leaving desired-open intent intact; /tmp state is gone too.
    am_tmux kill-session -t "$session_name"
    rm -rf "$AM_STATE_DIR"
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
        "reboot recovery: session resumes in its launch directory"
    assert_eq "$work_dir" "$(cat "$AM_STATE_DIR/$session_name.cwd" 2>/dev/null)" \
        "reboot recovery: .cwd sidecar seeded from the durable mirror"
    assert_eq "$work_dir" "$(registry_get_field "$session_name" workdir)" \
        "reboot recovery: workdir label survives the reboot"
    assert_eq "$(cd "$test_dir" && pwd -P)" \
        "$(cd "$(registry_get_field "$session_name" directory)" && pwd -P)" \
        "reboot recovery: registry directory stays the launch directory"
    [[ -n "$session_name" ]] && agent_kill "$session_name" 2>/dev/null

    rm -rf "$test_dir" "$work_dir"
    if [[ -n "$old_state_dir" ]]; then export AM_STATE_DIR="$old_state_dir"; else unset AM_STATE_DIR; fi
    unset AM_BOOT_ID AM_MACHINE_ID
    teardown_integration_env
    $SUMMARY_MODE || echo ""
}

test_recovery_branch_guard_integration() {
    $SUMMARY_MODE || echo "=== Testing branch guard on re-allocated checkouts ==="

    source "$LIB_DIR/utils.sh"
    source "$LIB_DIR/tmux.sh"
    source "$LIB_DIR/registry.sh"
    set +u; source "$LIB_DIR/agents.sh"; set -u
    source "$LIB_DIR/recovery.sh"

    setup_integration_env
    export AM_BOOT_ID="boot-before"
    export AM_MACHINE_ID="machine-a"
    local old_state_dir="${AM_STATE_DIR:-}"
    export AM_STATE_DIR="$AM_DIR/state"

    # Two pooled checkouts on the same branch. After the reboot one still
    # holds it; the other was released and re-allocated to another branch.
    local repo_kept repo_moved transcript kept_session moved_session
    repo_kept=$(mktemp -d)
    repo_moved=$(mktemp -d)
    (cd "$repo_kept" && git init -q && git checkout -q -b feature-a)
    (cd "$repo_moved" && git init -q && git checkout -q -b feature-a)
    transcript="$repo_kept/sid-branch.jsonl"
    : > "$transcript"
    kept_session=$(set +u; agent_launch "$repo_kept" "cursor" "kept task" 2>/dev/null)
    moved_session=$(set +u; agent_launch "$repo_moved" "cursor" "moved task" 2>/dev/null)
    recovery_desired_identity "$kept_session" "sid-kept" "$transcript" "hook"
    recovery_desired_identity "$moved_session" "sid-moved" "$transcript" "hook"
    assert_eq "feature-a" \
        "$(jq -r --arg id "$moved_session" '.sessions[$id].branch' "$AM_DIR/desired_sessions.json")" \
        "branch guard: launch records the checkout's branch"

    am_tmux kill-session -t "$kept_session"
    am_tmux kill-session -t "$moved_session"
    rm -rf "$AM_STATE_DIR"
    (cd "$repo_moved" && git checkout -q -b other-branch)

    export AM_BOOT_ID="boot-after"
    recovery_run

    assert_eq "true" "$(tmux_session_exists "$kept_session" && echo true || echo false)" \
        "branch guard: checkout still on its branch is restored"
    assert_eq "live" \
        "$(jq -r --arg id "$kept_session" '.sessions[$id].recovery_state' "$AM_DIR/desired_sessions.json")" \
        "branch guard: unchanged checkout converges to live"
    assert_eq "false" "$(tmux_session_exists "$moved_session" && echo true || echo false)" \
        "branch guard: re-allocated checkout is not resumed"
    assert_eq "blocked" \
        "$(jq -r --arg id "$moved_session" '.sessions[$id].recovery_state' "$AM_DIR/desired_sessions.json")" \
        "branch guard: re-allocated checkout is blocked"
    assert_eq "branch changed: expected feature-a, found other-branch" \
        "$(jq -r --arg id "$moved_session" '.sessions[$id].recovery_error' "$AM_DIR/desired_sessions.json")" \
        "branch guard: block reason names expected and found branches"

    [[ -n "$kept_session" ]] && agent_kill "$kept_session" 2>/dev/null
    rm -rf "$repo_kept" "$repo_moved"
    if [[ -n "$old_state_dir" ]]; then export AM_STATE_DIR="$old_state_dir"; else unset AM_STATE_DIR; fi
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
    _run_test test_recovery_restore_launch_directory
    _run_test test_recovery_rebind_marker_cleanup
    _run_test test_recovery_sidecar_mirror
    _run_test test_recovery_native_adapters
    _run_test test_recovery_reboot_integration
    _run_test test_recovery_branch_guard_integration
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
