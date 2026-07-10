#!/usr/bin/env bash
# tests/test_state_hooks.sh - Tests for lib/hooks/state-hook.sh

test_state_hooks() {
    $SUMMARY_MODE || echo "=== Testing lib/hooks/state-hook.sh ==="

    local hook_script="$PROJECT_DIR/lib/hooks/state-hook.sh"
    if [[ ! -x "$hook_script" ]]; then
        skip_test "state hook tests (script not found or not executable)"
        echo ""
        return
    fi

    # Set up isolated temp dirs
    local tmp_dir registry_dir state_dir
    tmp_dir=$(mktemp -d)
    registry_dir="$tmp_dir/registry"
    state_dir="$tmp_dir/state"
    mkdir -p "$registry_dir" "$state_dir"

    local registry="$registry_dir/sessions.json"
    local test_project_dir="$tmp_dir/myproject"
    mkdir -p "$test_project_dir"
    local real_project_dir
    real_project_dir=$(cd "$test_project_dir" && pwd -P)

    # Build a minimal registry with one session
    jq -n \
        --arg session "am-abc123" \
        --arg dir "$real_project_dir" \
        '{sessions: {($session): {name: $session, directory: $dir, branch: "main", agent_type: "claude", task: "test task"}}}' \
        > "$registry"

    # Helper: run hook with given JSON input
    run_hook() {
        local input="$1"
        AM_REGISTRY="$registry" AM_STATE_DIR="$state_dir" AM_SESSION_NAME="" \
            "$hook_script" <<< "$input"
    }

    # --- Stop hook writes waiting_input ---
    rm -f "$state_dir/am-abc123"
    run_hook "{\"hook_event_name\":\"Stop\",\"stop_hook_active\":false,\"cwd\":\"$real_project_dir\"}"
    local state
    state=$(cat "$state_dir/am-abc123" 2>/dev/null || echo "")
    assert_eq "waiting_input" "$state" "Stop hook: writes waiting_input"

    # --- stop_hook_active=true is a no-op ---
    rm -f "$state_dir/am-abc123"
    run_hook "{\"hook_event_name\":\"Stop\",\"stop_hook_active\":true,\"cwd\":\"$real_project_dir\"}"
    state=$(cat "$state_dir/am-abc123" 2>/dev/null || echo "")
    assert_eq "" "$state" "Stop hook (stop_hook_active=true): no state written"

    # --- Notification[permission_prompt] writes waiting_permission ---
    rm -f "$state_dir/am-abc123"
    run_hook "{\"hook_event_name\":\"Notification\",\"notification_type\":\"permission_prompt\",\"cwd\":\"$real_project_dir\"}"
    state=$(cat "$state_dir/am-abc123" 2>/dev/null || echo "")
    assert_eq "waiting_permission" "$state" "Notification[permission_prompt]: writes waiting_permission"

    # --- Notification[elicitation_dialog] writes waiting_custom ---
    rm -f "$state_dir/am-abc123"
    run_hook "{\"hook_event_name\":\"Notification\",\"notification_type\":\"elicitation_dialog\",\"cwd\":\"$real_project_dir\"}"
    state=$(cat "$state_dir/am-abc123" 2>/dev/null || echo "")
    assert_eq "waiting_custom" "$state" "Notification[elicitation_dialog]: writes waiting_custom"

    # --- Notification[idle_prompt] writes waiting_input ---
    rm -f "$state_dir/am-abc123"
    run_hook "{\"hook_event_name\":\"Notification\",\"notification_type\":\"idle_prompt\",\"cwd\":\"$real_project_dir\"}"
    state=$(cat "$state_dir/am-abc123" 2>/dev/null || echo "")
    assert_eq "waiting_input" "$state" "Notification[idle_prompt]: writes waiting_input"

    # --- same-state waiting_* rewrites are skipped: the file mtime pins the
    #     moment the wait began (the status bar shows "waiting since" from it).
    #     A repeated idle_prompt Notification must not reset it. ---
    local mtime_before mtime_after
    printf 'waiting_input' > "$state_dir/am-abc123"
    touch -t 202601010000 "$state_dir/am-abc123"
    mtime_before=$(stat -c %Y "$state_dir/am-abc123" 2>/dev/null || stat -f %m "$state_dir/am-abc123")
    run_hook "{\"hook_event_name\":\"Notification\",\"notification_type\":\"idle_prompt\",\"cwd\":\"$real_project_dir\"}"
    mtime_after=$(stat -c %Y "$state_dir/am-abc123" 2>/dev/null || stat -f %m "$state_dir/am-abc123")
    assert_eq "$mtime_before" "$mtime_after" \
        "idle_prompt over waiting_input: same-state rewrite skipped (mtime pinned)"

    # Stop re-fires while background work drains: waiting_background over
    # waiting_background must also keep the original mtime.
    printf 'waiting_background' > "$state_dir/am-abc123"
    touch -t 202601010000 "$state_dir/am-abc123"
    mtime_before=$(stat -c %Y "$state_dir/am-abc123" 2>/dev/null || stat -f %m "$state_dir/am-abc123")
    run_hook "{\"hook_event_name\":\"Stop\",\"stop_hook_active\":false,\"cwd\":\"$real_project_dir\",\"background_tasks\":[{\"id\":\"b1\",\"type\":\"shell\",\"status\":\"running\",\"description\":\"x\"}]}"
    state=$(cat "$state_dir/am-abc123" 2>/dev/null || echo "")
    mtime_after=$(stat -c %Y "$state_dir/am-abc123" 2>/dev/null || stat -f %m "$state_dir/am-abc123")
    assert_eq "waiting_background" "$state" "Stop re-fire keeps waiting_background"
    assert_eq "$mtime_before" "$mtime_after" \
        "Stop re-fire over waiting_background: mtime pinned"

    # running over running is also skipped: the mtime pins the moment the turn
    # started ("running for" tab age). Liveness comes from tmux activity, not
    # file rewrites, so the heartbeat is not needed.
    printf 'running' > "$state_dir/am-abc123"
    touch -t 202601010000 "$state_dir/am-abc123"
    mtime_before=$(stat -c %Y "$state_dir/am-abc123" 2>/dev/null || stat -f %m "$state_dir/am-abc123")
    run_hook "{\"hook_event_name\":\"PostToolUse\",\"cwd\":\"$real_project_dir\"}"
    state=$(cat "$state_dir/am-abc123" 2>/dev/null || echo "")
    mtime_after=$(stat -c %Y "$state_dir/am-abc123" 2>/dev/null || stat -f %m "$state_dir/am-abc123")
    assert_eq "running" "$state" "PostToolUse over running: state unchanged"
    assert_eq "$mtime_before" "$mtime_after" \
        "PostToolUse over running: same-state rewrite skipped (mtime pinned)"

    # A genuine state *transition* between waiting states must still write.
    printf 'waiting_input' > "$state_dir/am-abc123"
    touch -t 202601010000 "$state_dir/am-abc123"
    run_hook "{\"hook_event_name\":\"Notification\",\"notification_type\":\"permission_prompt\",\"cwd\":\"$real_project_dir\"}"
    state=$(cat "$state_dir/am-abc123" 2>/dev/null || echo "")
    assert_eq "waiting_permission" "$state" \
        "waiting_input -> waiting_permission transition still writes"

    # --- UserPromptSubmit writes running ---
    rm -f "$state_dir/am-abc123"
    run_hook "{\"hook_event_name\":\"UserPromptSubmit\",\"cwd\":\"$real_project_dir\"}"
    state=$(cat "$state_dir/am-abc123" 2>/dev/null || echo "")
    assert_eq "running" "$state" "UserPromptSubmit: writes running"

    # --- session_id sidecar is written when present in hook payload ---
    rm -f "$state_dir/am-abc123" "$state_dir/am-abc123.sid"
    run_hook "{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"sid-from-hook\",\"cwd\":\"$real_project_dir\"}"
    state=$(cat "$state_dir/am-abc123" 2>/dev/null || echo "")
    local sid
    sid=$(cat "$state_dir/am-abc123.sid" 2>/dev/null || echo "")
    assert_eq "running" "$state" "UserPromptSubmit with session_id: writes state"
    assert_eq "sid-from-hook" "$sid" "UserPromptSubmit with session_id: writes sid sidecar"

    # --- Codex PermissionRequest writes waiting_permission ---
    rm -f "$state_dir/am-abc123"
    run_hook "{\"hook_event_name\":\"PermissionRequest\",\"cwd\":\"$real_project_dir\"}"
    state=$(cat "$state_dir/am-abc123" 2>/dev/null || echo "")
    assert_eq "waiting_permission" "$state" "PermissionRequest: writes waiting_permission"

    # --- Codex PreToolUse writes running ---
    rm -f "$state_dir/am-abc123"
    run_hook "{\"hook_event_name\":\"PreToolUse\",\"cwd\":\"$real_project_dir\"}"
    state=$(cat "$state_dir/am-abc123" 2>/dev/null || echo "")
    assert_eq "running" "$state" "PreToolUse: writes running"

    # --- PostToolUse writes running ---
    rm -f "$state_dir/am-abc123"
    run_hook "{\"hook_event_name\":\"PostToolUse\",\"cwd\":\"$real_project_dir\"}"
    state=$(cat "$state_dir/am-abc123" 2>/dev/null || echo "")
    assert_eq "running" "$state" "PostToolUse: writes running"

    # --- PostToolUse does NOT clobber a fresh waiting_input (race protection) ---
    # Claude Code may deliver a delayed PostToolUse from a previous turn
    # milliseconds after Stop has already written waiting_input. Within the
    # grace window (AM_STATE_GUARD_SECS) that must not revert the state.
    printf 'waiting_input' > "$state_dir/am-abc123"
    run_hook "{\"hook_event_name\":\"PostToolUse\",\"cwd\":\"$real_project_dir\"}"
    state=$(cat "$state_dir/am-abc123" 2>/dev/null || echo "")
    assert_eq "waiting_input" "$state" "PostToolUse: does not clobber fresh waiting_input"

    # --- PostToolUse DOES flip an aged waiting_input back to running ---
    # A turn can resume without UserPromptSubmit (answering an in-turn
    # question dialog continues the same turn), so tool hooks arriving after
    # the grace window are genuine new activity, not the trailing-hook race.
    # An unconditional guard pinned such sessions at waiting_input forever.
    printf 'waiting_input' > "$state_dir/am-abc123"
    touch -t 202601010000 "$state_dir/am-abc123"
    run_hook "{\"hook_event_name\":\"PostToolUse\",\"cwd\":\"$real_project_dir\"}"
    state=$(cat "$state_dir/am-abc123" 2>/dev/null || echo "")
    assert_eq "running" "$state" "PostToolUse: flips aged waiting_input to running (resumed turn)"

    # --- PostToolUse does NOT clobber waiting_background, fresh OR aged ---
    # A background subagent's own tool calls fire PreToolUse/PostToolUse in
    # this session for as long as it runs (minutes), so waiting_background is
    # guarded unconditionally — no grace window. Stop re-fires when the work
    # completes, so the state cannot stick.
    printf 'waiting_background' > "$state_dir/am-abc123"
    run_hook "{\"hook_event_name\":\"PostToolUse\",\"cwd\":\"$real_project_dir\"}"
    state=$(cat "$state_dir/am-abc123" 2>/dev/null || echo "")
    assert_eq "waiting_background" "$state" "PostToolUse: does not clobber fresh waiting_background"

    printf 'waiting_background' > "$state_dir/am-abc123"
    touch -t 202601010000 "$state_dir/am-abc123"
    run_hook "{\"hook_event_name\":\"PostToolUse\",\"cwd\":\"$real_project_dir\"}"
    state=$(cat "$state_dir/am-abc123" 2>/dev/null || echo "")
    assert_eq "waiting_background" "$state" "PostToolUse: does not clobber aged waiting_background"

    # --- PostToolUse DOES transition waiting_permission -> running ---
    # After the user grants a permission prompt, the tool runs and PostToolUse
    # fires. That must move the session out of waiting_permission so the UI
    # reflects that the agent is working again. Without this, the session
    # appears stuck at waiting_permission until Stop fires at end-of-turn.
    printf 'waiting_permission' > "$state_dir/am-abc123"
    run_hook "{\"hook_event_name\":\"PostToolUse\",\"cwd\":\"$real_project_dir\"}"
    state=$(cat "$state_dir/am-abc123" 2>/dev/null || echo "")
    assert_eq "running" "$state" "PostToolUse: transitions waiting_permission -> running"

    # --- PostToolUse DOES transition waiting_custom -> running ---
    printf 'waiting_custom' > "$state_dir/am-abc123"
    run_hook "{\"hook_event_name\":\"PostToolUse\",\"cwd\":\"$real_project_dir\"}"
    state=$(cat "$state_dir/am-abc123" 2>/dev/null || echo "")
    assert_eq "running" "$state" "PostToolUse: transitions waiting_custom -> running"

    # --- PreToolUse DOES transition waiting_permission -> running ---
    # After grant, the next tool's PreToolUse must flip the state forward too.
    printf 'waiting_permission' > "$state_dir/am-abc123"
    run_hook "{\"hook_event_name\":\"PreToolUse\",\"cwd\":\"$real_project_dir\"}"
    state=$(cat "$state_dir/am-abc123" 2>/dev/null || echo "")
    assert_eq "running" "$state" "PreToolUse: transitions waiting_permission -> running"

    # --- UserPromptSubmit DOES override waiting_input (explicit user action) ---
    printf 'waiting_input' > "$state_dir/am-abc123"
    run_hook "{\"hook_event_name\":\"UserPromptSubmit\",\"cwd\":\"$real_project_dir\"}"
    state=$(cat "$state_dir/am-abc123" 2>/dev/null || echo "")
    assert_eq "running" "$state" "UserPromptSubmit: overrides waiting_input"

    # --- UserPromptSubmit DOES override waiting_background too ---
    printf 'waiting_background' > "$state_dir/am-abc123"
    run_hook "{\"hook_event_name\":\"UserPromptSubmit\",\"cwd\":\"$real_project_dir\"}"
    state=$(cat "$state_dir/am-abc123" 2>/dev/null || echo "")
    assert_eq "running" "$state" "UserPromptSubmit: overrides waiting_background"

    # --- Stop with running background_tasks writes waiting_background ---
    # Claude Code ≥2.1 Stop payload carries a background_tasks array — one
    # entry per still-running background item. Payload shapes below mirror
    # real captures (subagent and background shell).
    rm -f "$state_dir/am-abc123"
    run_hook "{\"hook_event_name\":\"Stop\",\"stop_hook_active\":false,\"cwd\":\"$real_project_dir\",\"background_tasks\":[{\"id\":\"a9596f8935c90b6cf\",\"type\":\"subagent\",\"status\":\"running\",\"description\":\"Sleep then reply OK\",\"agent_type\":\"general-purpose\"}]}"
    state=$(cat "$state_dir/am-abc123" 2>/dev/null || echo "")
    assert_eq "waiting_background" "$state" "Stop + running subagent in background_tasks: writes waiting_background"

    rm -f "$state_dir/am-abc123"
    run_hook "{\"hook_event_name\":\"Stop\",\"stop_hook_active\":false,\"cwd\":\"$real_project_dir\",\"background_tasks\":[{\"id\":\"b6p7gc49c\",\"type\":\"shell\",\"status\":\"running\",\"description\":\"Sleep 20s then echo done\",\"command\":\"sleep 20 && echo done\"}]}"
    state=$(cat "$state_dir/am-abc123" 2>/dev/null || echo "")
    assert_eq "waiting_background" "$state" "Stop + running shell in background_tasks: writes waiting_background"

    # --- Stop with empty background_tasks writes waiting_input ---
    rm -f "$state_dir/am-abc123"
    run_hook "{\"hook_event_name\":\"Stop\",\"stop_hook_active\":false,\"cwd\":\"$real_project_dir\",\"background_tasks\":[]}"
    state=$(cat "$state_dir/am-abc123" 2>/dev/null || echo "")
    assert_eq "waiting_input" "$state" "Stop + empty background_tasks: writes waiting_input"

    # --- Stop with only non-running background_tasks writes waiting_input ---
    rm -f "$state_dir/am-abc123"
    run_hook "{\"hook_event_name\":\"Stop\",\"stop_hook_active\":false,\"cwd\":\"$real_project_dir\",\"background_tasks\":[{\"id\":\"x\",\"type\":\"shell\",\"status\":\"completed\",\"description\":\"done already\"}]}"
    state=$(cat "$state_dir/am-abc123" 2>/dev/null || echo "")
    assert_eq "waiting_input" "$state" "Stop + completed-only background_tasks: writes waiting_input"

    # --- Stop clears a previous waiting_background once work finishes ---
    # Stop re-fires when background work completes (the completion re-invokes
    # Claude for a wrap-up turn) with a pruned background_tasks.
    printf 'waiting_background' > "$state_dir/am-abc123"
    run_hook "{\"hook_event_name\":\"Stop\",\"stop_hook_active\":false,\"cwd\":\"$real_project_dir\",\"background_tasks\":[]}"
    state=$(cat "$state_dir/am-abc123" 2>/dev/null || echo "")
    assert_eq "waiting_input" "$state" "Stop + empty background_tasks: clears waiting_background"

    # --- Notification[idle_prompt] honors background_tasks when present ---
    rm -f "$state_dir/am-abc123"
    run_hook "{\"hook_event_name\":\"Notification\",\"notification_type\":\"idle_prompt\",\"cwd\":\"$real_project_dir\",\"background_tasks\":[{\"id\":\"y\",\"type\":\"subagent\",\"status\":\"running\",\"description\":\"bg\"}]}"
    state=$(cat "$state_dir/am-abc123" 2>/dev/null || echo "")
    assert_eq "waiting_background" "$state" "Notification[idle_prompt] + running background_tasks: writes waiting_background"

    # --- Notification[idle_prompt] WITHOUT the background_tasks field must
    #     not downgrade waiting_background. idle_prompt fires ~60s into an
    #     idle wait with no background_tasks in its payload — it knows
    #     nothing about background work (observed live: it flipped
    #     waiting_background to waiting_input exactly 60s after every Stop
    #     while the background shell/agent was still running). ---
    printf 'waiting_background' > "$state_dir/am-abc123"
    run_hook "{\"hook_event_name\":\"Notification\",\"notification_type\":\"idle_prompt\",\"cwd\":\"$real_project_dir\"}"
    state=$(cat "$state_dir/am-abc123" 2>/dev/null || echo "")
    assert_eq "waiting_background" "$state" "Notification[idle_prompt] without background_tasks: keeps waiting_background"

    # With the field present and pruned, the downgrade is legitimate.
    printf 'waiting_background' > "$state_dir/am-abc123"
    run_hook "{\"hook_event_name\":\"Notification\",\"notification_type\":\"idle_prompt\",\"cwd\":\"$real_project_dir\",\"background_tasks\":[]}"
    state=$(cat "$state_dir/am-abc123" 2>/dev/null || echo "")
    assert_eq "waiting_input" "$state" "Notification[idle_prompt] + empty background_tasks: downgrades to waiting_input"

    # Field-less idle_prompt over a plain waiting_input is still a same-state
    # no-op write path (nothing to protect).
    printf 'waiting_input' > "$state_dir/am-abc123"
    run_hook "{\"hook_event_name\":\"Notification\",\"notification_type\":\"idle_prompt\",\"cwd\":\"$real_project_dir\"}"
    state=$(cat "$state_dir/am-abc123" 2>/dev/null || echo "")
    assert_eq "waiting_input" "$state" "Notification[idle_prompt] without background_tasks over waiting_input: unchanged"

    # --- Duplicate cwd: AM_SESSION_NAME disambiguates which session to update ---
    # Two am sessions can share a cwd (e.g., multiple Claude instances in the
    # same repo). Without AM_SESSION_NAME the hook would blindly pick the first
    # match and keep overwriting the wrong session's state file forever.
    local dup_registry="$tmp_dir/dup.json"
    jq -n --arg dir "$real_project_dir" \
        '{sessions: {
            "am-first":  {name: "am-first",  directory: $dir, branch: "main", agent_type: "claude", task: "t1"},
            "am-second": {name: "am-second", directory: $dir, branch: "main", agent_type: "claude", task: "t2"}
         }}' > "$dup_registry"

    rm -f "$state_dir/am-first" "$state_dir/am-second"
    AM_REGISTRY="$dup_registry" AM_STATE_DIR="$state_dir" AM_SESSION_NAME="am-second" \
        "$hook_script" <<< "{\"hook_event_name\":\"UserPromptSubmit\",\"cwd\":\"$real_project_dir\"}"
    assert_eq ""        "$(cat "$state_dir/am-first"  2>/dev/null || echo)" "AM_SESSION_NAME: first session untouched"
    assert_eq "running" "$(cat "$state_dir/am-second" 2>/dev/null || echo)" "AM_SESSION_NAME: targeted session updated"

    # --- AM_SESSION_NAME pointing at non-existent session → no write ---
    rm -f "$state_dir/am-first" "$state_dir/am-second"
    AM_REGISTRY="$dup_registry" AM_STATE_DIR="$state_dir" AM_SESSION_NAME="am-bogus" \
        "$hook_script" <<< "{\"hook_event_name\":\"UserPromptSubmit\",\"cwd\":\"$real_project_dir\"}"
    assert_eq "" "$(cat "$state_dir/am-first"  2>/dev/null || echo)" "AM_SESSION_NAME bogus: first session untouched"
    assert_eq "" "$(cat "$state_dir/am-second" 2>/dev/null || echo)" "AM_SESSION_NAME bogus: second session untouched"

    # --- No matching session → no state file written ---
    rm -f "$state_dir/am-abc123"
    local other_dir="$tmp_dir/other_project"
    mkdir -p "$other_dir"
    run_hook "{\"hook_event_name\":\"Stop\",\"stop_hook_active\":false,\"cwd\":\"$other_dir\"}"
    state=$(cat "$state_dir/am-abc123" 2>/dev/null || echo "")
    assert_eq "" "$state" "No matching session: no state file written"

    # --- Unknown event → no state file written ---
    rm -f "$state_dir/am-abc123"
    run_hook "{\"hook_event_name\":\"SomeUnknownEvent\",\"cwd\":\"$real_project_dir\"}"
    state=$(cat "$state_dir/am-abc123" 2>/dev/null || echo "")
    assert_eq "" "$state" "Unknown event: no state file written"

    rm -rf "$tmp_dir"

    $SUMMARY_MODE || echo ""
}

_ensure_state_lib_sourced() {
    if [[ "$(type -t _state_hook_read)" != "function" ]]; then
        set +u
        source "$LIB_DIR/utils.sh"
        source "$LIB_DIR/tmux.sh"
        source "$LIB_DIR/registry.sh"
        source "$LIB_DIR/state.sh"
        set -u
    fi
}

test_state_from_hook_reads_file() {
    _ensure_state_lib_sourced
    local state_dir
    state_dir=$(mktemp -d)
    printf 'waiting_permission' > "$state_dir/am-test01"

    local result
    result=$(AM_STATE_DIR="$state_dir" _state_from_hook "am-test01")
    assert_eq "waiting_permission" "$result" "_state_from_hook reads state file"
    rm -rf "$state_dir"
}

test_state_from_hook_missing_file() {
    _ensure_state_lib_sourced
    local state_dir
    state_dir=$(mktemp -d)

    local result
    result=$(AM_STATE_DIR="$state_dir" _state_from_hook "am-nonexist")
    assert_eq "" "$result" "_state_from_hook returns empty for missing file"
    rm -rf "$state_dir"
}

test_state_from_hook_stale_file() {
    _ensure_state_lib_sourced
    local state_dir
    state_dir=$(mktemp -d)
    local backdated
    backdated=$(date -v-5M '+%Y%m%d%H%M.%S' 2>/dev/null \
        || date -d '5 minutes ago' '+%Y%m%d%H%M.%S')

    # Terminal waiting states are persistent — an idle session can sit at
    # waiting_input for hours without firing a new hook. The staleness gate
    # must not drop these.
    printf 'waiting_input' > "$state_dir/am-test01"
    touch -t "$backdated" "$state_dir/am-test01"
    local result
    result=$(AM_STATE_DIR="$state_dir" _state_from_hook "am-test01")
    assert_eq "waiting_input" "$result" \
        "_state_from_hook trusts stale waiting_input (terminal state)"

    # Running implies an in-progress turn; missing PostToolUse/Stop for
    # >3 min means the agent likely crashed. Pane fallback should take over.
    printf 'running' > "$state_dir/am-test02"
    touch -t "$backdated" "$state_dir/am-test02"
    result=$(AM_STATE_DIR="$state_dir" _state_from_hook "am-test02")
    assert_eq "" "$result" \
        "_state_from_hook drops stale running (>3m) so pane fallback runs"

    rm -rf "$state_dir"
}

test_state_from_hook_invalid_state() {
    _ensure_state_lib_sourced
    local state_dir
    state_dir=$(mktemp -d)
    printf 'bogus_state' > "$state_dir/am-test01"

    local result
    result=$(AM_STATE_DIR="$state_dir" _state_from_hook "am-test01")
    assert_eq "" "$result" "_state_from_hook rejects invalid state values"
    rm -rf "$state_dir"
}

run_state_hooks_tests() {
    _run_test test_state_hooks
    _run_test test_state_from_hook_reads_file
    _run_test test_state_from_hook_missing_file
    _run_test test_state_from_hook_stale_file
    _run_test test_state_from_hook_invalid_state
}

if [[ -z "${_AM_TEST_RUNNER:-}" ]]; then
    set -uo pipefail
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helpers.sh"
    check_deps
    run_state_hooks_tests
    test_report
fi
