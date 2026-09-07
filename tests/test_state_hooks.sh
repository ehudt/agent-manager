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
    local tmp_dir registry_dir state_dir identity_dir
    tmp_dir=$(mktemp -d)
    registry_dir="$tmp_dir/registry"
    state_dir="$tmp_dir/state"
    identity_dir="$tmp_dir/identities"
    mkdir -p "$registry_dir" "$state_dir" "$identity_dir"
    export AM_IDENTITY_DIR="$identity_dir"

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

    # Helper: run hook with given JSON input, as the pane's own agent would
    # (AM_SESSION_NAME is seeded into every am pane at creation).
    run_hook() {
        local input="$1"
        AM_DIR="$tmp_dir/am" AM_REGISTRY="$registry" AM_STATE_DIR="$state_dir" \
            AM_IDENTITY_DIR="$identity_dir" AM_SESSION_NAME="am-abc123" \
            "$hook_script" <<< "$input"
    }

    # --- The hook never fails Claude's turn: exit 0 on garbage and on an
    # unreadable registry, under /bin/bash too (macOS 3.2 is what Claude's
    # `bash <path>` resolves to when Homebrew bash is not first in PATH) ---
    local hook_rc=0
    AM_DIR="$tmp_dir/am" AM_REGISTRY="$registry" AM_STATE_DIR="$state_dir" AM_SESSION_NAME="am-abc123" \
        /bin/bash "$hook_script" <<< "not json at all" || hook_rc=$?
    assert_eq "0" "$hook_rc" "hook: unparsable payload exits 0"
    hook_rc=0
    AM_DIR="$tmp_dir/am" AM_REGISTRY="$tmp_dir/nope.json" AM_STATE_DIR="$state_dir" AM_SESSION_NAME="am-abc123" \
        /bin/bash "$hook_script" <<< "{\"hook_event_name\":\"PostToolUse\",\"cwd\":\"$real_project_dir\"}" || hook_rc=$?
    assert_eq "0" "$hook_rc" "hook: missing registry exits 0"
    hook_rc=0
    AM_DIR="$tmp_dir/am" AM_REGISTRY="$registry" AM_STATE_DIR="$tmp_dir/unwritable/state" AM_SESSION_NAME="am-abc123" \
        /bin/bash "$hook_script" <<< "{\"hook_event_name\":\"PostToolUse\",\"cwd\":\"$real_project_dir\"}" 2>/dev/null || hook_rc=$?
    assert_eq "0" "$hook_rc" "hook: exits 0 even when a state write fails"

    # --- A state dir the hook has to create is user-only ---
    local fresh_state="$tmp_dir/fresh-state"
    AM_DIR="$tmp_dir/am" AM_REGISTRY="$registry" AM_STATE_DIR="$fresh_state" AM_SESSION_NAME="am-abc123" \
        /bin/bash "$hook_script" <<< "{\"hook_event_name\":\"Stop\",\"stop_hook_active\":false,\"cwd\":\"$real_project_dir\"}"
    assert_eq "ready" "$(cat "$fresh_state/am-abc123" 2>/dev/null)" "hook: writes state into a freshly created state dir"
    assert_eq "700" "$(stat -f %Lp "$fresh_state" 2>/dev/null || stat -c %a "$fresh_state")" \
        "hook: creates the state dir 0700"

    # --- Stop hook writes ready ---
    rm -f "$state_dir/am-abc123"
    run_hook "{\"hook_event_name\":\"Stop\",\"stop_hook_active\":false,\"cwd\":\"$real_project_dir\"}"
    local state
    state=$(cat "$state_dir/am-abc123" 2>/dev/null || echo "")
    assert_eq "ready" "$state" "Stop hook: writes ready"

    # --- stop_hook_active=true is a no-op ---
    rm -f "$state_dir/am-abc123"
    run_hook "{\"hook_event_name\":\"Stop\",\"stop_hook_active\":true,\"cwd\":\"$real_project_dir\"}"
    state=$(cat "$state_dir/am-abc123" 2>/dev/null || echo "")
    assert_eq "" "$state" "Stop hook (stop_hook_active=true): no state written"

    # --- User-blocking notifications share one truthful state ---
    rm -f "$state_dir/am-abc123"
    run_hook "{\"hook_event_name\":\"Notification\",\"notification_type\":\"permission_prompt\",\"cwd\":\"$real_project_dir\"}"
    state=$(cat "$state_dir/am-abc123" 2>/dev/null || echo "")
    assert_eq "waiting_user" "$state" \
        "Notification[permission_prompt]: writes waiting_user"

    rm -f "$state_dir/am-abc123"
    run_hook "{\"hook_event_name\":\"Notification\",\"notification_type\":\"elicitation_dialog\",\"cwd\":\"$real_project_dir\"}"
    state=$(cat "$state_dir/am-abc123" 2>/dev/null || echo "")
    assert_eq "waiting_user" "$state" \
        "Notification[elicitation_dialog]: writes waiting_user"

    # --- Notification[idle_prompt] writes ready ---
    rm -f "$state_dir/am-abc123"
    run_hook "{\"hook_event_name\":\"Notification\",\"notification_type\":\"idle_prompt\",\"cwd\":\"$real_project_dir\"}"
    state=$(cat "$state_dir/am-abc123" 2>/dev/null || echo "")
    assert_eq "ready" "$state" "Notification[idle_prompt]: writes ready"

    # --- same-state rewrites are skipped: the file mtime pins the
    #     moment the wait began (the status bar shows "waiting since" from it).
    #     A repeated idle_prompt Notification must not reset it. ---
    local mtime_before mtime_after
    printf 'ready' > "$state_dir/am-abc123"
    touch -t 202601010000 "$state_dir/am-abc123"
    mtime_before=$(stat -c %Y "$state_dir/am-abc123" 2>/dev/null || stat -f %m "$state_dir/am-abc123")
    run_hook "{\"hook_event_name\":\"Notification\",\"notification_type\":\"idle_prompt\",\"cwd\":\"$real_project_dir\"}"
    mtime_after=$(stat -c %Y "$state_dir/am-abc123" 2>/dev/null || stat -f %m "$state_dir/am-abc123")
    assert_eq "$mtime_before" "$mtime_after" \
        "idle_prompt over ready: same-state rewrite skipped (mtime pinned)"

    # Upgrade compatibility: normalize a legacy value for comparisons but do
    # not rewrite it merely to change the spelling, because that would reset
    # the live session's time-in-state timestamp.
    printf 'waiting_input' > "$state_dir/am-abc123"
    touch -t 202601010000 "$state_dir/am-abc123"
    mtime_before=$(stat -c %Y "$state_dir/am-abc123" 2>/dev/null || stat -f %m "$state_dir/am-abc123")
    run_hook "{\"hook_event_name\":\"Notification\",\"notification_type\":\"idle_prompt\",\"cwd\":\"$real_project_dir\"}"
    state=$(cat "$state_dir/am-abc123" 2>/dev/null || echo "")
    mtime_after=$(stat -c %Y "$state_dir/am-abc123" 2>/dev/null || stat -f %m "$state_dir/am-abc123")
    assert_eq "waiting_input" "$state" \
        "legacy waiting_input remains on a same-state ready event"
    assert_eq "$mtime_before" "$mtime_after" \
        "legacy waiting_input same-state event preserves mtime"

    # Stop re-fires while background work drains: background over background
    # must also keep the original mtime.
    printf 'background' > "$state_dir/am-abc123"
    touch -t 202601010000 "$state_dir/am-abc123"
    mtime_before=$(stat -c %Y "$state_dir/am-abc123" 2>/dev/null || stat -f %m "$state_dir/am-abc123")
    run_hook "{\"hook_event_name\":\"Stop\",\"stop_hook_active\":false,\"cwd\":\"$real_project_dir\",\"background_tasks\":[{\"id\":\"b1\",\"type\":\"shell\",\"status\":\"running\",\"description\":\"x\"}]}"
    state=$(cat "$state_dir/am-abc123" 2>/dev/null || echo "")
    mtime_after=$(stat -c %Y "$state_dir/am-abc123" 2>/dev/null || stat -f %m "$state_dir/am-abc123")
    assert_eq "background" "$state" "Stop re-fire keeps background"
    assert_eq "$mtime_before" "$mtime_after" \
        "Stop re-fire over background: mtime pinned"

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
    printf 'ready' > "$state_dir/am-abc123"
    touch -t 202601010000 "$state_dir/am-abc123"
    run_hook "{\"hook_event_name\":\"Notification\",\"notification_type\":\"permission_prompt\",\"cwd\":\"$real_project_dir\"}"
    state=$(cat "$state_dir/am-abc123" 2>/dev/null || echo "")
    assert_eq "waiting_user" "$state" \
        "ready -> waiting_user transition still writes"

    # --- UserPromptSubmit writes running ---
    rm -f "$state_dir/am-abc123"
    run_hook "{\"hook_event_name\":\"UserPromptSubmit\",\"cwd\":\"$real_project_dir\"}"
    state=$(cat "$state_dir/am-abc123" 2>/dev/null || echo "")
    assert_eq "running" "$state" "UserPromptSubmit: writes running"

    # --- session_id sidecar is written when present in hook payload ---
    rm -f "$state_dir/am-abc123" "$state_dir/am-abc123.sid"
    AM_DIR="$tmp_dir/am" AM_REGISTRY="$registry" AM_STATE_DIR="$state_dir" \
        AM_IDENTITY_DIR="$identity_dir" AM_SESSION_NAME="am-abc123" \
        "$hook_script" <<< "{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"sid-from-hook\",\"cwd\":\"$real_project_dir\"}"
    state=$(cat "$state_dir/am-abc123" 2>/dev/null || echo "")
    local sid
    sid=$(cat "$state_dir/am-abc123.sid" 2>/dev/null || echo "")
    assert_eq "running" "$state" "UserPromptSubmit with session_id: writes state"
    assert_eq "sid-from-hook" "$sid" "UserPromptSubmit with session_id: writes sid sidecar"
    assert_eq "sid-from-hook" "$(cat "$identity_dir/am-abc123.sid" 2>/dev/null || echo "")" \
        "UserPromptSubmit with session_id: persists durable identity"

    # --- Cursor hook events use camelCase names and conversation_id ---
    # Cursor events may only touch cursor-type sessions (agent-family gate),
    # so these run against a dedicated cursor-type registry.
    local cursor_registry="$tmp_dir/cursor.json"
    jq -n --arg dir "$real_project_dir" \
        '{sessions: {"am-cur456": {name: "am-cur456", directory: $dir, branch: "main", agent_type: "cursor", task: "t"}}}' \
        > "$cursor_registry"
    local cursor_transcript="$tmp_dir/cursor-transcript.jsonl"
    : > "$cursor_transcript"
    rm -f "$state_dir/am-cur456" "$state_dir/am-cur456.sid" \
        "$state_dir/am-cur456.transcript"
    AM_DIR="$tmp_dir/am" AM_REGISTRY="$cursor_registry" AM_STATE_DIR="$state_dir" \
        AM_IDENTITY_DIR="$identity_dir" AM_SESSION_NAME="am-cur456" \
        "$hook_script" <<< "{\"hook_event_name\":\"sessionStart\",\"conversation_id\":\"cursor-conv-1\",\"session_id\":\"cursor-conv-1\",\"transcript_path\":\"$cursor_transcript\",\"workspace_roots\":[\"$real_project_dir\"]}"
    assert_eq "ready" "$(cat "$state_dir/am-cur456" 2>/dev/null || echo)" \
        "Cursor sessionStart: writes ready"
    assert_eq "cursor-conv-1" "$(cat "$state_dir/am-cur456.sid" 2>/dev/null || echo)" \
        "Cursor sessionStart: writes conversation id sidecar"
    assert_eq "$cursor_transcript" "$(cat "$state_dir/am-cur456.transcript" 2>/dev/null || echo)" \
        "Cursor sessionStart: writes transcript path sidecar"
    assert_eq "$cursor_transcript" \
        "$(cat "$identity_dir/am-cur456.transcript" 2>/dev/null || echo)" \
        "Cursor sessionStart: persists durable transcript path"

    local background_transcript="$tmp_dir/background-conv.jsonl"
    : > "$background_transcript"
    AM_DIR="$tmp_dir/am" AM_REGISTRY="$cursor_registry" AM_STATE_DIR="$state_dir" \
        AM_IDENTITY_DIR="$identity_dir" AM_SESSION_NAME="am-cur456" \
        "$hook_script" <<< "{\"hook_event_name\":\"sessionStart\",\"is_background_agent\":true,\"conversation_id\":\"background-conv\",\"session_id\":\"background-conv\",\"transcript_path\":\"$background_transcript\",\"workspace_roots\":[\"$real_project_dir\"]}"
    assert_eq "cursor-conv-1" "$(cat "$identity_dir/am-cur456.sid" 2>/dev/null || echo)" \
        "Cursor background agent: does not clobber parent durable identity"
    assert_eq "$cursor_transcript" \
        "$(cat "$identity_dir/am-cur456.transcript" 2>/dev/null || echo)" \
        "Cursor background agent: does not clobber parent transcript"

    local nested_transcript="$tmp_dir/nested-conv.jsonl"
    : > "$nested_transcript"
    AM_DIR="$tmp_dir/am" AM_REGISTRY="$cursor_registry" AM_STATE_DIR="$state_dir" \
        AM_IDENTITY_DIR="$identity_dir" AM_SESSION_NAME="am-cur456" \
        "$hook_script" <<< "{\"hook_event_name\":\"sessionStart\",\"conversation_id\":\"nested-conv\",\"session_id\":\"nested-conv\",\"transcript_path\":\"$nested_transcript\",\"workspace_roots\":[\"$real_project_dir\"]}"
    assert_eq "cursor-conv-1" "$(cat "$identity_dir/am-cur456.sid" 2>/dev/null || echo)" \
        "Cursor nested agent without flag: cannot replace pinned physical-session identity"
    assert_eq "$cursor_transcript" \
        "$(cat "$identity_dir/am-cur456.transcript" 2>/dev/null || echo)" \
        "Cursor nested agent without flag: cannot replace pinned transcript"

    local resumed_transcript="$tmp_dir/resumed-conv.jsonl"
    : > "$resumed_transcript"
    : > "$identity_dir/am-cur456.rebind"
    AM_DIR="$tmp_dir/am" AM_REGISTRY="$cursor_registry" AM_STATE_DIR="$state_dir" \
        AM_IDENTITY_DIR="$identity_dir" AM_SESSION_NAME="am-cur456" \
        "$hook_script" <<< "{\"hook_event_name\":\"sessionStart\",\"conversation_id\":\"resumed-conv\",\"session_id\":\"resumed-conv\",\"transcript_path\":\"$resumed_transcript\",\"workspace_roots\":[\"$real_project_dir\"]}"
    assert_eq "resumed-conv" "$(cat "$identity_dir/am-cur456.sid" 2>/dev/null || echo)" \
        "Cursor recovered process: one rebind updates to its new identity"
    assert_eq "$resumed_transcript" \
        "$(cat "$identity_dir/am-cur456.transcript" 2>/dev/null || echo)" \
        "Cursor recovered process: one rebind updates transcript"
    assert_eq "false" "$(test -f "$identity_dir/am-cur456.rebind" && echo true || echo false)" \
        "Cursor recovered process: rebind permission is consumed"

    AM_REGISTRY="$cursor_registry" AM_STATE_DIR="$state_dir" AM_SESSION_NAME="am-cur456" \
        "$hook_script" <<< "{\"hook_event_name\":\"beforeSubmitPrompt\",\"conversation_id\":\"cursor-without-transcript\",\"workspace_roots\":[\"$real_project_dir\"]}"
    assert_eq "running" "$(cat "$state_dir/am-cur456" 2>/dev/null || echo)" \
        "Cursor beforeSubmitPrompt: writes running"
    assert_eq "resumed-conv" "$(cat "$identity_dir/am-cur456.sid" 2>/dev/null || echo)" \
        "Cursor hook without transcript: keeps last complete durable identity pair"

    AM_REGISTRY="$cursor_registry" AM_STATE_DIR="$state_dir" AM_SESSION_NAME="am-cur456" \
        "$hook_script" <<< "{\"hook_event_name\":\"stop\",\"conversation_id\":\"cursor-conv-1\",\"status\":\"completed\",\"loop_count\":0,\"workspace_roots\":[\"$real_project_dir\"]}"
    assert_eq "ready" "$(cat "$state_dir/am-cur456" 2>/dev/null || echo)" \
        "Cursor stop: writes ready"

    rm -f "$state_dir/am-cur456"
    AM_REGISTRY="$cursor_registry" AM_STATE_DIR="$state_dir" AM_SESSION_NAME="am-cur456" \
        "$hook_script" <<< "{\"hook_event_name\":\"preToolUse\",\"conversation_id\":\"cursor-conv-1\",\"tool_name\":\"Read\",\"cwd\":\"$real_project_dir\"}"
    assert_eq "running" "$(cat "$state_dir/am-cur456" 2>/dev/null || echo)" \
        "Cursor preToolUse: writes running"

    # --- Codex PermissionRequest writes waiting_user ---
    rm -f "$state_dir/am-abc123"
    run_hook "{\"hook_event_name\":\"PermissionRequest\",\"cwd\":\"$real_project_dir\"}"
    state=$(cat "$state_dir/am-abc123" 2>/dev/null || echo "")
    assert_eq "waiting_user" "$state" "PermissionRequest: writes waiting_user"

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

    # --- PostToolUse does NOT clobber a fresh ready (race protection) ---
    # Claude Code may deliver a delayed PostToolUse from a previous turn
    # milliseconds after Stop has already written ready. Within the
    # grace window (AM_STATE_GUARD_SECS) that must not revert the state.
    printf 'ready' > "$state_dir/am-abc123"
    run_hook "{\"hook_event_name\":\"PostToolUse\",\"cwd\":\"$real_project_dir\"}"
    state=$(cat "$state_dir/am-abc123" 2>/dev/null || echo "")
    assert_eq "ready" "$state" "PostToolUse: does not clobber fresh ready"

    # --- PostToolUse DOES flip an aged ready back to running ---
    # A turn can resume without UserPromptSubmit (answering an in-turn
    # question dialog continues the same turn), so tool hooks arriving after
    # the grace window are genuine new activity, not the trailing-hook race.
    # An unconditional guard pinned such sessions at ready forever.
    printf 'ready' > "$state_dir/am-abc123"
    touch -t 202601010000 "$state_dir/am-abc123"
    run_hook "{\"hook_event_name\":\"PostToolUse\",\"cwd\":\"$real_project_dir\"}"
    state=$(cat "$state_dir/am-abc123" 2>/dev/null || echo "")
    assert_eq "running" "$state" "PostToolUse: flips aged ready to running (resumed turn)"

    # --- PostToolUse does NOT clobber background, fresh OR aged ---
    # A background subagent's own tool calls fire PreToolUse/PostToolUse in
    # this session for as long as it runs (minutes), so background is
    # guarded unconditionally — no grace window. Stop re-fires when the work
    # completes, so the state cannot stick.
    printf 'background' > "$state_dir/am-abc123"
    run_hook "{\"hook_event_name\":\"PostToolUse\",\"cwd\":\"$real_project_dir\"}"
    state=$(cat "$state_dir/am-abc123" 2>/dev/null || echo "")
    assert_eq "background" "$state" "PostToolUse: does not clobber fresh background"

    printf 'background' > "$state_dir/am-abc123"
    touch -t 202601010000 "$state_dir/am-abc123"
    run_hook "{\"hook_event_name\":\"PostToolUse\",\"cwd\":\"$real_project_dir\"}"
    state=$(cat "$state_dir/am-abc123" 2>/dev/null || echo "")
    assert_eq "background" "$state" "PostToolUse: does not clobber aged background"

    # --- PostToolUse DOES transition waiting_user -> running ---
    # After the user grants a permission prompt, the tool runs and PostToolUse
    # fires. That must move the session out of waiting_user so the UI
    # reflects that the agent is working again. Without this, the session
    # appears stuck at waiting_user until Stop fires at end-of-turn.
    printf 'waiting_user' > "$state_dir/am-abc123"
    run_hook "{\"hook_event_name\":\"PostToolUse\",\"cwd\":\"$real_project_dir\"}"
    state=$(cat "$state_dir/am-abc123" 2>/dev/null || echo "")
    assert_eq "running" "$state" "PostToolUse: transitions waiting_user -> running"

    # --- PreToolUse DOES transition waiting_user -> running ---
    # After grant, the next tool's PreToolUse must flip the state forward too.
    printf 'waiting_user' > "$state_dir/am-abc123"
    run_hook "{\"hook_event_name\":\"PreToolUse\",\"cwd\":\"$real_project_dir\"}"
    state=$(cat "$state_dir/am-abc123" 2>/dev/null || echo "")
    assert_eq "running" "$state" "PreToolUse: transitions waiting_user -> running"

    # --- UserPromptSubmit DOES override ready (explicit user action) ---
    printf 'ready' > "$state_dir/am-abc123"
    run_hook "{\"hook_event_name\":\"UserPromptSubmit\",\"cwd\":\"$real_project_dir\"}"
    state=$(cat "$state_dir/am-abc123" 2>/dev/null || echo "")
    assert_eq "running" "$state" "UserPromptSubmit: overrides ready"

    # --- UserPromptSubmit DOES override background too ---
    printf 'background' > "$state_dir/am-abc123"
    run_hook "{\"hook_event_name\":\"UserPromptSubmit\",\"cwd\":\"$real_project_dir\"}"
    state=$(cat "$state_dir/am-abc123" 2>/dev/null || echo "")
    assert_eq "running" "$state" "UserPromptSubmit: overrides background"

    # --- Stop with running background_tasks writes background ---
    # Claude Code ≥2.1 Stop payload carries a background_tasks array — one
    # entry per still-running background item. Payload shapes below mirror
    # real captures (subagent and background shell).
    rm -f "$state_dir/am-abc123"
    run_hook "{\"hook_event_name\":\"Stop\",\"stop_hook_active\":false,\"cwd\":\"$real_project_dir\",\"background_tasks\":[{\"id\":\"a9596f8935c90b6cf\",\"type\":\"subagent\",\"status\":\"running\",\"description\":\"Sleep then reply OK\",\"agent_type\":\"general-purpose\"}]}"
    state=$(cat "$state_dir/am-abc123" 2>/dev/null || echo "")
    assert_eq "background" "$state" "Stop + running subagent in background_tasks: writes background"

    rm -f "$state_dir/am-abc123"
    run_hook "{\"hook_event_name\":\"Stop\",\"stop_hook_active\":false,\"cwd\":\"$real_project_dir\",\"background_tasks\":[{\"id\":\"b6p7gc49c\",\"type\":\"shell\",\"status\":\"running\",\"description\":\"Sleep 20s then echo done\",\"command\":\"sleep 20 && echo done\"}]}"
    state=$(cat "$state_dir/am-abc123" 2>/dev/null || echo "")
    assert_eq "background" "$state" "Stop + running shell in background_tasks: writes background"

    # --- Stop with empty background_tasks writes ready ---
    rm -f "$state_dir/am-abc123"
    run_hook "{\"hook_event_name\":\"Stop\",\"stop_hook_active\":false,\"cwd\":\"$real_project_dir\",\"background_tasks\":[]}"
    state=$(cat "$state_dir/am-abc123" 2>/dev/null || echo "")
    assert_eq "ready" "$state" "Stop + empty background_tasks: writes ready"

    # --- Stop with only non-running background_tasks writes ready ---
    rm -f "$state_dir/am-abc123"
    run_hook "{\"hook_event_name\":\"Stop\",\"stop_hook_active\":false,\"cwd\":\"$real_project_dir\",\"background_tasks\":[{\"id\":\"x\",\"type\":\"shell\",\"status\":\"completed\",\"description\":\"done already\"}]}"
    state=$(cat "$state_dir/am-abc123" 2>/dev/null || echo "")
    assert_eq "ready" "$state" "Stop + completed-only background_tasks: writes ready"

    # --- Monitors are watchers, not work: they never keep background ---
    # The Artifact tool arms a live-updates subscription on publish (and
    # re-arms it on resume); Claude lists it in background_tasks as
    # {type:"monitor", status:"running"} for the life of the session, with
    # no completion that would ever re-fire Stop. Observed live: two finished
    # sessions pinned at background for an hour by one artifact watch each.
    monitor_task='{"id":"st7gmduau","type":"monitor","status":"running","description":"live updates for artifact https://claude.ai/code/artifact/e0b2165b-1449-4cf1-8873-a373b3281ecc (auto-armed on publish)"}'
    rm -f "$state_dir/am-abc123"
    run_hook "{\"hook_event_name\":\"Stop\",\"stop_hook_active\":false,\"cwd\":\"$real_project_dir\",\"background_tasks\":[$monitor_task]}"
    state=$(cat "$state_dir/am-abc123" 2>/dev/null || echo "")
    assert_eq "ready" "$state" "Stop + running monitor only: writes ready"

    printf 'background' > "$state_dir/am-abc123"
    run_hook "{\"hook_event_name\":\"Stop\",\"stop_hook_active\":false,\"cwd\":\"$real_project_dir\",\"background_tasks\":[$monitor_task]}"
    state=$(cat "$state_dir/am-abc123" 2>/dev/null || echo "")
    assert_eq "ready" "$state" "Stop + running monitor only: clears background"

    rm -f "$state_dir/am-abc123"
    run_hook "{\"hook_event_name\":\"Stop\",\"stop_hook_active\":false,\"cwd\":\"$real_project_dir\",\"background_tasks\":[$monitor_task,{\"id\":\"a1\",\"type\":\"subagent\",\"status\":\"running\",\"description\":\"still working\"}]}"
    state=$(cat "$state_dir/am-abc123" 2>/dev/null || echo "")
    assert_eq "background" "$state" "Stop + monitor + running subagent: writes background"

    # A field-less idle_prompt may downgrade when the last Stop's snapshot
    # holds nothing but monitors.
    printf 'background' > "$state_dir/am-abc123"
    printf '[%s]' "$monitor_task" > "$state_dir/am-abc123.bg"
    run_hook "{\"hook_event_name\":\"Notification\",\"notification_type\":\"idle_prompt\",\"cwd\":\"$real_project_dir\"}"
    state=$(cat "$state_dir/am-abc123" 2>/dev/null || echo "")
    assert_eq "ready" "$state" "idle_prompt without field + sidecar of only monitors: downgrades"
    rm -f "$state_dir/am-abc123.bg"

    # --- Stop clears a previous background once work finishes ---
    # Stop re-fires when background work completes (the completion re-invokes
    # Claude for a wrap-up turn) with a pruned background_tasks.
    printf 'background' > "$state_dir/am-abc123"
    run_hook "{\"hook_event_name\":\"Stop\",\"stop_hook_active\":false,\"cwd\":\"$real_project_dir\",\"background_tasks\":[]}"
    state=$(cat "$state_dir/am-abc123" 2>/dev/null || echo "")
    assert_eq "ready" "$state" "Stop + empty background_tasks: clears background"

    # --- Notification[idle_prompt] honors background_tasks when present ---
    rm -f "$state_dir/am-abc123"
    run_hook "{\"hook_event_name\":\"Notification\",\"notification_type\":\"idle_prompt\",\"cwd\":\"$real_project_dir\",\"background_tasks\":[{\"id\":\"y\",\"type\":\"subagent\",\"status\":\"running\",\"description\":\"bg\"}]}"
    state=$(cat "$state_dir/am-abc123" 2>/dev/null || echo "")
    assert_eq "background" "$state" "Notification[idle_prompt] + running background_tasks: writes background"

    # --- Notification[idle_prompt] WITHOUT the background_tasks field must
    #     not downgrade background. idle_prompt fires ~60s into an
    #     idle wait with no background_tasks in its payload — it knows
    #     nothing about background work (observed live: it flipped
    #     background to ready exactly 60s after every Stop
    #     while the background shell/agent was still running). ---
    printf 'background' > "$state_dir/am-abc123"
    run_hook "{\"hook_event_name\":\"Notification\",\"notification_type\":\"idle_prompt\",\"cwd\":\"$real_project_dir\"}"
    state=$(cat "$state_dir/am-abc123" 2>/dev/null || echo "")
    assert_eq "background" "$state" "Notification[idle_prompt] without background_tasks: keeps background"

    # With the field present and pruned, the downgrade is legitimate.
    printf 'background' > "$state_dir/am-abc123"
    run_hook "{\"hook_event_name\":\"Notification\",\"notification_type\":\"idle_prompt\",\"cwd\":\"$real_project_dir\",\"background_tasks\":[]}"
    state=$(cat "$state_dir/am-abc123" 2>/dev/null || echo "")
    assert_eq "ready" "$state" "Notification[idle_prompt] + empty background_tasks: downgrades to ready"

    # Field-less idle_prompt over plain ready is still a same-state
    # no-op write path (nothing to protect).
    printf 'ready' > "$state_dir/am-abc123"
    run_hook "{\"hook_event_name\":\"Notification\",\"notification_type\":\"idle_prompt\",\"cwd\":\"$real_project_dir\"}"
    state=$(cat "$state_dir/am-abc123" 2>/dev/null || echo "")
    assert_eq "ready" "$state" "Notification[idle_prompt] without background_tasks over ready: unchanged"

    # --- Orphaned leftover shells do not pin background ---
    # A --fork-session / parent-Claude exit reparents still-running
    # run_in_background zsh loops to PID 1. Claude keeps listing them in
    # background_tasks as status=running, so every later Stop would otherwise
    # write background forever (observed live: recap + "new task?"
    # while the tab stayed ⧗ for hours). Ignore a running shell task whose
    # matching OS process is not owned by this Claude (PPID=1 when we cannot
    # see a claude ancestor; not a descendant when we can).
    local orphan_secs=98761
    local owned_secs=98762
    local orphan_pid="" owned_pid="" owned_ppid=""
    orphan_pid=$(
        ( sleep "$orphan_secs" >/dev/null 2>&1 & echo $! )
    )
    sleep 0.4
    local orphan_ppid
    orphan_ppid=$(ps -p "$orphan_pid" -o ppid= 2>/dev/null | tr -d ' ')
    if [[ "$orphan_ppid" == "1" ]]; then
        rm -f "$state_dir/am-abc123"
        run_hook "{\"hook_event_name\":\"Stop\",\"stop_hook_active\":false,\"cwd\":\"$real_project_dir\",\"background_tasks\":[{\"id\":\"orphan1\",\"type\":\"shell\",\"status\":\"running\",\"description\":\"leftover wait-loop\",\"command\":\"sleep $orphan_secs\"}]}"
        state=$(cat "$state_dir/am-abc123" 2>/dev/null || echo "")
        assert_eq "ready" "$state" "Stop + running shell whose process is PPID=1: leftover, writes ready"
    else
        skip_test "orphaned-shell PPID=1 (reparent did not happen, ppid=$orphan_ppid)"
    fi
    kill "$orphan_pid" 2>/dev/null || true

    sleep "$owned_secs" >/dev/null 2>&1 &
    owned_pid=$!
    owned_ppid=$(ps -p "$owned_pid" -o ppid= 2>/dev/null | tr -d ' ')
    if [[ -n "$owned_pid" && "$owned_ppid" != "1" ]]; then
        rm -f "$state_dir/am-abc123"
        run_hook "{\"hook_event_name\":\"Stop\",\"stop_hook_active\":false,\"cwd\":\"$real_project_dir\",\"background_tasks\":[{\"id\":\"owned1\",\"type\":\"shell\",\"status\":\"running\",\"description\":\"live bg sleep\",\"command\":\"sleep $owned_secs\"}]}"
        state=$(cat "$state_dir/am-abc123" 2>/dev/null || echo "")
        assert_eq "background" "$state" "Stop + running shell owned by this tree: writes background"
    else
        skip_test "owned-shell child process (pid=$owned_pid ppid=$owned_ppid)"
    fi
    kill "$owned_pid" 2>/dev/null || true
    wait "$owned_pid" 2>/dev/null || true

    # A live subagent still counts even if the only shell in the payload is
    # an orphan — do not drop the whole refinement.
    orphan_pid=$(
        ( sleep "$orphan_secs" >/dev/null 2>&1 & echo $! )
    )
    sleep 0.4
    orphan_ppid=$(ps -p "$orphan_pid" -o ppid= 2>/dev/null | tr -d ' ')
    if [[ "$orphan_ppid" == "1" ]]; then
        rm -f "$state_dir/am-abc123"
        run_hook "{\"hook_event_name\":\"Stop\",\"stop_hook_active\":false,\"cwd\":\"$real_project_dir\",\"background_tasks\":[{\"id\":\"orphan1\",\"type\":\"shell\",\"status\":\"running\",\"command\":\"sleep $orphan_secs\"},{\"id\":\"a1\",\"type\":\"subagent\",\"status\":\"running\",\"description\":\"still working\"}]}"
        state=$(cat "$state_dir/am-abc123" 2>/dev/null || echo "")
        assert_eq "background" "$state" "Stop + orphaned shell + running subagent: still background"
    else
        skip_test "orphaned-shell+subagent (reparent did not happen)"
    fi
    kill "$orphan_pid" 2>/dev/null || true

    # idle_prompt without the field may re-check the last Stop's snapshot:
    # if every leftover shell is now orphaned, allow the downgrade. This
    # heals a session whose wrap-up Stop already fired with stale running
    # tasks and will not fire again until the next user prompt.
    orphan_pid=$(
        ( sleep "$orphan_secs" >/dev/null 2>&1 & echo $! )
    )
    sleep 0.4
    orphan_ppid=$(ps -p "$orphan_pid" -o ppid= 2>/dev/null | tr -d ' ')
    if [[ "$orphan_ppid" == "1" ]]; then
        printf 'background' > "$state_dir/am-abc123"
        printf '[{"id":"orphan1","type":"shell","status":"running","command":"sleep %s"}]' \
            "$orphan_secs" > "$state_dir/am-abc123.bg"
        run_hook "{\"hook_event_name\":\"Notification\",\"notification_type\":\"idle_prompt\",\"cwd\":\"$real_project_dir\"}"
        state=$(cat "$state_dir/am-abc123" 2>/dev/null || echo "")
        assert_eq "ready" "$state" \
            "idle_prompt without field + sidecar of only PPID=1 shells: downgrades"
    else
        skip_test "idle_prompt sidecar orphan re-check (reparent did not happen)"
    fi
    kill "$orphan_pid" 2>/dev/null || true
    rm -f "$state_dir/am-abc123.bg"

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

    # --- Agent-family gate: a hook may only touch sessions whose registered
    #     agent_type matches the hook's source agent. CamelCase events come
    #     only from Claude Code / Codex; camelCase events only from Cursor;
    #     pi never calls this script (in-process extension instead).
    #     Observed live: a cursor-agent run by hand inside a pi session's
    #     shell pane inherited AM_SESSION_NAME and would otherwise have
    #     clobbered the pi session's state mid-turn (plus its .sid /
    #     .transcript sidecars). ---
    local fam_registry="$tmp_dir/family.json"
    jq -n --arg dir "$real_project_dir" \
        '{sessions: {
            "am-pi":  {name: "am-pi",  directory: $dir, branch: "main", agent_type: "pi",     task: "t"},
            "am-cur": {name: "am-cur", directory: $dir, branch: "main", agent_type: "cursor", task: "t"}
         }}' > "$fam_registry"

    # Cursor stop in the cursor pane: lands on the cursor session — sidecars
    # and durable identity included — and leaves the pi session alone.
    rm -f "$state_dir/am-pi" "$state_dir/am-pi.sid" "$state_dir/am-pi.transcript" \
        "$state_dir/am-cur" "$state_dir/am-cur.sid" "$identity_dir/am-cur.sid" \
        "$identity_dir/am-cur.transcript"
    AM_DIR="$tmp_dir/am" AM_REGISTRY="$fam_registry" AM_STATE_DIR="$state_dir" \
        AM_IDENTITY_DIR="$identity_dir" AM_SESSION_NAME="am-cur" \
        "$hook_script" <<< "{\"hook_event_name\":\"stop\",\"conversation_id\":\"conv-x\",\"transcript_path\":\"$cursor_transcript\",\"workspace_roots\":[\"$real_project_dir\"]}"
    assert_eq "" "$(cat "$state_dir/am-pi" 2>/dev/null || echo)" \
        "family gate: Cursor stop leaves pi session state untouched"
    assert_eq "" "$(cat "$state_dir/am-pi.sid" 2>/dev/null || echo)" \
        "family gate: Cursor stop leaves pi sid sidecar untouched"
    assert_eq "" "$(cat "$state_dir/am-pi.transcript" 2>/dev/null || echo)" \
        "family gate: Cursor stop leaves pi transcript sidecar untouched"
    assert_eq "ready" "$(cat "$state_dir/am-cur" 2>/dev/null || echo)" \
        "family gate: Cursor stop targets the cursor session"
    assert_eq "conv-x" "$(cat "$identity_dir/am-cur.sid" 2>/dev/null || echo)" \
        "pane-resolved Cursor stop establishes the durable recovery identity"

    # No AM_SESSION_NAME and no TMUX_PANE: not an am pane. The directory
    # hosts two am sessions, and neither may be written — by either family.
    rm -f "$state_dir/am-pi" "$state_dir/am-cur"
    AM_REGISTRY="$fam_registry" AM_STATE_DIR="$state_dir" AM_SESSION_NAME="" TMUX_PANE="" \
        "$hook_script" <<< "{\"hook_event_name\":\"stop\",\"conversation_id\":\"conv-y\",\"transcript_path\":\"$cursor_transcript\",\"workspace_roots\":[\"$real_project_dir\"]}"
    assert_eq "" "$(cat "$state_dir/am-pi"  2>/dev/null || echo)" \
        "no pane signal: Cursor stop in the launch dir leaves pi session untouched"
    assert_eq "" "$(cat "$state_dir/am-cur" 2>/dev/null || echo)" \
        "no pane signal: Cursor stop in the launch dir leaves cursor session untouched"
    AM_REGISTRY="$fam_registry" AM_STATE_DIR="$state_dir" AM_SESSION_NAME="" TMUX_PANE="" \
        "$hook_script" <<< "{\"hook_event_name\":\"Stop\",\"stop_hook_active\":false,\"cwd\":\"$real_project_dir\"}"
    assert_eq "" "$(cat "$state_dir/am-pi"  2>/dev/null || echo)" \
        "no pane signal: Claude Stop in the launch dir leaves pi session untouched"
    assert_eq "" "$(cat "$state_dir/am-cur" 2>/dev/null || echo)" \
        "no pane signal: Claude Stop in the launch dir leaves cursor session untouched"

    # AM_SESSION_NAME inherited by a foreign agent (e.g. cursor-agent run
    # manually inside a pi session's shell pane): wrong family → exit; the
    # cursor session in the same directory is not a candidate either.
    rm -f "$state_dir/am-pi" "$state_dir/am-cur"
    AM_REGISTRY="$fam_registry" AM_STATE_DIR="$state_dir" AM_SESSION_NAME="am-pi" \
        "$hook_script" <<< "{\"hook_event_name\":\"stop\",\"conversation_id\":\"conv-x\",\"workspace_roots\":[\"$real_project_dir\"]}"
    assert_eq "" "$(cat "$state_dir/am-pi"  2>/dev/null || echo)" \
        "family gate: AM_SESSION_NAME type mismatch writes nothing"
    assert_eq "" "$(cat "$state_dir/am-cur" 2>/dev/null || echo)" \
        "family gate: AM_SESSION_NAME type mismatch touches no other session"

    # CamelCase events come from Claude Code or Codex — a codex session is
    # family-compatible with them.
    local codex_registry="$tmp_dir/codex.json"
    jq -n --arg dir "$real_project_dir" \
        '{sessions: {"am-codex": {name: "am-codex", directory: $dir, branch: "main", agent_type: "codex", task: "t"}}}' \
        > "$codex_registry"
    rm -f "$state_dir/am-codex" "$identity_dir/am-codex.sid"
    AM_REGISTRY="$codex_registry" AM_STATE_DIR="$state_dir" AM_SESSION_NAME="am-codex" \
        "$hook_script" <<< "{\"hook_event_name\":\"Stop\",\"stop_hook_active\":false,\"session_id\":\"codex-parent\",\"cwd\":\"$real_project_dir\"}"
    assert_eq "ready" "$(cat "$state_dir/am-codex" 2>/dev/null || echo)" \
        "family gate: CamelCase Stop may target a codex session"
    assert_eq "codex-parent" "$(cat "$identity_dir/am-codex.sid" 2>/dev/null || echo)" \
        "Codex pane hook establishes the durable recovery identity"

    AM_REGISTRY="$codex_registry" AM_STATE_DIR="$state_dir" AM_SESSION_NAME="am-codex" \
        "$hook_script" <<< "{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"codex-parent\",\"cwd\":\"$real_project_dir\"}"
    AM_REGISTRY="$codex_registry" AM_STATE_DIR="$state_dir" AM_SESSION_NAME="am-codex" \
        "$hook_script" <<< "{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"codex-nested\",\"cwd\":\"$real_project_dir\"}"
    assert_eq "codex-parent" "$(cat "$identity_dir/am-codex.sid" 2>/dev/null || echo)" \
        "Codex nested same-family hook: cannot replace pinned physical identity"

    : > "$identity_dir/am-codex.rebind"
    AM_REGISTRY="$codex_registry" AM_STATE_DIR="$state_dir" AM_SESSION_NAME="am-codex" \
        "$hook_script" <<< "{\"hook_event_name\":\"Stop\",\"stop_hook_active\":false,\"cwd\":\"$real_project_dir\"}"
    assert_eq "true" "$(test -f "$identity_dir/am-codex.rebind" && echo true || echo false)" \
        "Codex recovered process: id-less hook does not consume rebind"
    AM_REGISTRY="$codex_registry" AM_STATE_DIR="$state_dir" AM_SESSION_NAME="am-codex" \
        "$hook_script" <<< "{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"codex-resumed\",\"cwd\":\"$real_project_dir\"}"
    assert_eq "codex-resumed" "$(cat "$identity_dir/am-codex.sid" 2>/dev/null || echo)" \
        "Codex recovered process: exact identity consumes rebind"

    assert_eq "false" "$(test -f "$identity_dir/am-codex.rebind" && echo true || echo false)" \
        "Codex recovered process: rebind consumed only after exact identity"

    # --- Agents outside am. Observed live: an interactive Claude started
    #     from Obsidian's terminal plugin in ~/obsidian (no AM_SESSION_NAME,
    #     no TMUX_PANE) was matched by directory to the am session launched
    #     there and drove its tab through running / background /
    #     waiting_user from a conversation the pane never ran, overwriting
    #     the .sid/.transcript sidecars along the way. A process with no
    #     positive pane signal now writes nothing: not state, not sidecars,
    #     not identity, whatever its payload says. ---
    local host_registry="$tmp_dir/host.json"
    jq -n --arg dir "$real_project_dir" \
        '{sessions: {"am-host": {name: "am-host", directory: $dir, branch: "main", agent_type: "claude", task: "t"}}}' \
        > "$host_registry"
    rm -f "$state_dir/am-host" "$state_dir/am-host.sid" "$state_dir/am-host.transcript" \
        "$state_dir/am-host.cwd" "$state_dir/am-host.bg" \
        "$identity_dir/am-host.sid" "$identity_dir/am-host.transcript" "$identity_dir/am-host.rebind"

    # The pane's own Claude binds the identity.
    AM_DIR="$tmp_dir/am" AM_REGISTRY="$host_registry" AM_STATE_DIR="$state_dir" \
        AM_IDENTITY_DIR="$identity_dir" AM_SESSION_NAME="am-host" \
        "$hook_script" <<< "{\"hook_event_name\":\"Stop\",\"stop_hook_active\":false,\"session_id\":\"pane-conv\",\"transcript_path\":\"$tmp_dir/pane.jsonl\",\"cwd\":\"$real_project_dir\"}"
    assert_eq "pane-conv" "$(cat "$identity_dir/am-host.sid" 2>/dev/null || echo)" \
        "stranger: pane hook binds the durable identity"
    assert_eq "ready" "$(cat "$state_dir/am-host" 2>/dev/null || echo)" \
        "stranger: pane hook writes state"
    assert_eq "$real_project_dir" "$(cat "$state_dir/am-host.cwd" 2>/dev/null || echo)" \
        "stranger: pane hook records the cwd sidecar"

    # A stranger in the same directory, every event kind: nothing moves.
    local stranger_payload
    for stranger_payload in \
        "{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"obsidian-conv\",\"transcript_path\":\"$tmp_dir/obsidian.jsonl\",\"cwd\":\"$real_project_dir\"}" \
        "{\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"Bash\",\"session_id\":\"obsidian-conv\",\"cwd\":\"$tmp_dir\"}" \
        "{\"hook_event_name\":\"Notification\",\"notification_type\":\"permission_prompt\",\"session_id\":\"obsidian-conv\",\"transcript_path\":\"$tmp_dir/obsidian.jsonl\",\"cwd\":\"$real_project_dir\"}" \
        "{\"hook_event_name\":\"Stop\",\"stop_hook_active\":false,\"session_id\":\"obsidian-conv\",\"transcript_path\":\"$tmp_dir/obsidian.jsonl\",\"background_tasks\":[{\"id\":\"x\",\"type\":\"shell\",\"status\":\"running\"}],\"cwd\":\"$real_project_dir\"}" \
        "{\"hook_event_name\":\"Stop\",\"stop_hook_active\":false,\"cwd\":\"$real_project_dir\"}"
    do
        AM_DIR="$tmp_dir/am" AM_REGISTRY="$host_registry" AM_STATE_DIR="$state_dir" \
            AM_IDENTITY_DIR="$identity_dir" AM_SESSION_NAME="" TMUX_PANE="" \
            "$hook_script" <<< "$stranger_payload"
    done
    assert_eq "ready" "$(cat "$state_dir/am-host" 2>/dev/null || echo)" \
        "stranger: state untouched by a same-family process outside am"
    assert_eq "pane-conv" "$(cat "$state_dir/am-host.sid" 2>/dev/null || echo)" \
        "stranger: sid sidecar untouched"
    assert_eq "$tmp_dir/pane.jsonl" "$(cat "$state_dir/am-host.transcript" 2>/dev/null || echo)" \
        "stranger: transcript sidecar untouched"
    assert_eq "pane-conv" "$(cat "$identity_dir/am-host.sid" 2>/dev/null || echo)" \
        "stranger: durable identity untouched"
    assert_eq "$real_project_dir" "$(cat "$state_dir/am-host.cwd" 2>/dev/null || echo)" \
        "stranger: cwd sidecar untouched"
    assert_cmd_fails "stranger: no background snapshot written" \
        test -f "$state_dir/am-host.bg"

    # A TMUX_PANE that names no am session (the user's own tmux) proves
    # nothing either.
    AM_DIR="$tmp_dir/am" AM_REGISTRY="$host_registry" AM_STATE_DIR="$state_dir" \
        AM_IDENTITY_DIR="$identity_dir" AM_SESSION_NAME="" TMUX_PANE="%999999" \
        "$hook_script" <<< "{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"other-conv\",\"cwd\":\"$real_project_dir\"}"
    assert_eq "ready" "$(cat "$state_dir/am-host" 2>/dev/null || echo)" \
        "stranger: foreign TMUX_PANE writes nothing"

    # The pane's own hook still moves the session.
    AM_DIR="$tmp_dir/am" AM_REGISTRY="$host_registry" AM_STATE_DIR="$state_dir" \
        AM_IDENTITY_DIR="$identity_dir" AM_SESSION_NAME="am-host" \
        "$hook_script" <<< "{\"hook_event_name\":\"UserPromptSubmit\",\"session_id\":\"pane-conv\",\"cwd\":\"$real_project_dir\"}"
    assert_eq "running" "$(cat "$state_dir/am-host" 2>/dev/null || echo)" \
        "stranger: the pane's own hook still writes state"

    # --- The pane's cwd is irrelevant to resolution: the agent may have
    #     cd'd anywhere, its events still land on its own session ---
    rm -f "$state_dir/am-abc123"
    local other_dir="$tmp_dir/other_project"
    mkdir -p "$other_dir"
    run_hook "{\"hook_event_name\":\"Stop\",\"stop_hook_active\":false,\"cwd\":\"$other_dir\"}"
    state=$(cat "$state_dir/am-abc123" 2>/dev/null || echo "")
    assert_eq "ready" "$state" "Pane-resolved hook writes state whatever the cwd"

    # --- No pane signal (no AM_SESSION_NAME, no TMUX_PANE) → nothing written,
    #     even from the registered directory ---
    rm -f "$state_dir/am-abc123"
    AM_DIR="$tmp_dir/am" AM_REGISTRY="$registry" AM_STATE_DIR="$state_dir" \
        AM_IDENTITY_DIR="$identity_dir" AM_SESSION_NAME="" TMUX_PANE="" \
        "$hook_script" <<< "{\"hook_event_name\":\"Stop\",\"stop_hook_active\":false,\"cwd\":\"$real_project_dir\"}"
    state=$(cat "$state_dir/am-abc123" 2>/dev/null || echo "")
    assert_eq "" "$state" "No pane signal: no state file written"

    # --- Unknown event → no state file written ---
    rm -f "$state_dir/am-abc123"
    run_hook "{\"hook_event_name\":\"SomeUnknownEvent\",\"cwd\":\"$real_project_dir\"}"
    state=$(cat "$state_dir/am-abc123" 2>/dev/null || echo "")
    assert_eq "" "$state" "Unknown event: no state file written"

    unset AM_IDENTITY_DIR
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
    printf 'waiting_user' > "$state_dir/am-test01"

    local result
    result=$(AM_STATE_DIR="$state_dir" _state_from_hook "am-test01")
    assert_eq "waiting_user" "$result" "_state_from_hook reads state file"
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
    # ready for hours without firing a new hook. The staleness gate
    # must not drop these.
    printf 'ready' > "$state_dir/am-test01"
    touch -t "$backdated" "$state_dir/am-test01"
    local result
    result=$(AM_STATE_DIR="$state_dir" _state_from_hook "am-test01")
    assert_eq "ready" "$result" \
        "_state_from_hook trusts stale ready (terminal state)"

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

test_pi_durable_identity_guard() {
    $SUMMARY_MODE || echo "=== Testing pi durable identity guard ==="

    local tmp_dir registry state_dir identity_dir
    tmp_dir=$(mktemp -d)
    registry="$tmp_dir/sessions.json"
    state_dir="$tmp_dir/state"
    identity_dir="$tmp_dir/identities"
    mkdir -p "$state_dir" "$identity_dir"

    jq -n '{sessions: {"am-pi-guard": {name: "am-pi-guard", agent_type: "cursor"}}}' > "$registry"
    local rc=0
    AM_DIR="$tmp_dir" AM_REGISTRY="$registry" AM_STATE_DIR="$state_dir" \
        AM_IDENTITY_DIR="$identity_dir" AM_SESSION_NAME="am-pi-guard" \
        EXPECT_PI_REGISTERED=false TEST_PI_SESSION_ID=nested-pi \
        node "$PROJECT_DIR/tests/pi_identity_probe.mjs" || rc=$?
    assert_eq "0" "$rc" "pi identity: extension rejects non-pi registry session"
    assert_eq "false" "$(test -f "$identity_dir/am-pi-guard.sid" && echo true || echo false)" \
        "pi identity: foreign session remains untouched"

    rm -f "$registry"
    rc=0
    AM_DIR="$tmp_dir" AM_REGISTRY="$registry" AM_STATE_DIR="$state_dir" \
        AM_IDENTITY_DIR="$identity_dir" AM_SESSION_NAME="am-pi-guard" \
        AM_AGENT_TYPE="cursor" EXPECT_PI_REGISTERED=false TEST_PI_SESSION_ID=nested-pi \
        node "$PROJECT_DIR/tests/pi_identity_probe.mjs" || rc=$?
    assert_eq "0" "$rc" "pi identity: without a registry, wrong agent family is rejected"

    EXPECT_PI_REGISTERED=true TEST_PI_SESSION_ID=pi-noreg \
        AM_DIR="$tmp_dir" AM_REGISTRY="$registry" AM_STATE_DIR="$state_dir" \
        AM_IDENTITY_DIR="$identity_dir" AM_SESSION_NAME="am-pi-guard" AM_AGENT_TYPE="pi" \
        node "$PROJECT_DIR/tests/pi_identity_probe.mjs"
    assert_eq "pi-noreg" "$(cat "$identity_dir/am-pi-guard.sid")" \
        "pi identity: pi session persists durable identity without registry"

    jq -n '{sessions: {"am-pi-guard": {name: "am-pi-guard", agent_type: "pi"}}}' > "$registry"
    rm -f "$identity_dir/am-pi-guard.sid"
    printf '%s' "pi-parent" > "$identity_dir/am-pi-guard.sid"
    EXPECT_PI_REGISTERED=true TEST_PI_SESSION_ID=pi-nested \
        AM_DIR="$tmp_dir" AM_REGISTRY="$registry" AM_STATE_DIR="$state_dir" \
        AM_IDENTITY_DIR="$identity_dir" AM_SESSION_NAME="am-pi-guard" AM_AGENT_TYPE="pi" \
        node "$PROJECT_DIR/tests/pi_identity_probe.mjs"
    assert_eq "pi-parent" "$(cat "$identity_dir/am-pi-guard.sid")" \
        "pi identity: nested process cannot replace pinned identity"

    : > "$identity_dir/am-pi-guard.rebind"
    EXPECT_PI_REGISTERED=true TEST_PI_SESSION_ID=pi-resumed \
        AM_DIR="$tmp_dir" AM_REGISTRY="$registry" AM_STATE_DIR="$state_dir" \
        AM_IDENTITY_DIR="$identity_dir" AM_SESSION_NAME="am-pi-guard" AM_AGENT_TYPE="pi" \
        node "$PROJECT_DIR/tests/pi_identity_probe.mjs"
    assert_eq "pi-resumed" "$(cat "$identity_dir/am-pi-guard.sid")" \
        "pi identity: recovered physical process consumes one rebind"
    assert_eq "false" "$(test -f "$identity_dir/am-pi-guard.rebind" && echo true || echo false)" \
        "pi identity: rebind permission is consumed"

    rm -rf "$tmp_dir"
}


# The hook records the payload cwd — Claude's tracked Bash-tool cwd — in a .cwd
# sidecar so the title scan can relabel a session that moved to another checkout.
test_state_hook_cwd_sidecar() {
    $SUMMARY_MODE || echo "=== Testing state-hook .cwd sidecar ==="

    local hook_script="$PROJECT_DIR/lib/hooks/state-hook.sh"
    local tmp_dir registry state_dir am_dir home away
    tmp_dir=$(mktemp -d)
    registry="$tmp_dir/sessions.json"
    state_dir="$tmp_dir/state"
    am_dir="$tmp_dir/am"
    mkdir -p "$state_dir" "$am_dir" "$tmp_dir/home" "$tmp_dir/away"
    home=$(cd "$tmp_dir/home" && pwd -P)
    away=$(cd "$tmp_dir/away" && pwd -P)
    jq -n --arg dir "$home" \
        '{sessions: {"am-cwd1": {name: "am-cwd1", directory: $dir, branch: "main", agent_type: "claude", task: ""}}}' \
        > "$registry"

    run_hook() {
        AM_DIR="$am_dir" AM_REGISTRY="$registry" AM_STATE_DIR="$state_dir" \
            AM_IDENTITY_DIR="$tmp_dir/ids" AM_SESSION_NAME="am-cwd1" "$hook_script" <<< "$1"
    }

    # A tool hook from another checkout writes the sidecar and drops the
    # title-scan throttle so the tab relabels on the next status-bar tick.
    touch "$am_dir/.title_scan_last"
    run_hook "{\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"Bash\",\"cwd\":\"$away\"}"
    assert_eq "$away" "$(cat "$state_dir/am-cwd1.cwd" 2>/dev/null)" \
        "hook: .cwd sidecar records the tool cwd"
    assert_cmd_fails "hook: cwd change invalidates the title-scan throttle" \
        test -f "$am_dir/.title_scan_last"

    # Same cwd again: no rewrite, throttle marker left alone.
    touch "$am_dir/.title_scan_last"
    touch -t 200001010000 "$state_dir/am-cwd1.cwd"
    local before after
    before=$(stat -f %m "$state_dir/am-cwd1.cwd" 2>/dev/null || stat -c %Y "$state_dir/am-cwd1.cwd")
    run_hook "{\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"Bash\",\"cwd\":\"$away\"}"
    after=$(stat -f %m "$state_dir/am-cwd1.cwd" 2>/dev/null || stat -c %Y "$state_dir/am-cwd1.cwd")
    assert_eq "$before" "$after" "hook: unchanged cwd does not rewrite the sidecar"
    assert_cmd_succeeds "hook: unchanged cwd leaves the throttle marker alone" \
        test -f "$am_dir/.title_scan_last"

    # Stop while back home: the sidecar follows.
    run_hook "{\"hook_event_name\":\"Stop\",\"stop_hook_active\":false,\"cwd\":\"$home\"}"
    assert_eq "$home" "$(cat "$state_dir/am-cwd1.cwd")" "hook: sidecar follows the cwd back home"

    # A cwd that is not an existing directory is ignored.
    run_hook "{\"hook_event_name\":\"PostToolUse\",\"tool_name\":\"Bash\",\"cwd\":\"$tmp_dir/nope\"}"
    assert_eq "$home" "$(cat "$state_dir/am-cwd1.cwd")" \
        "hook: missing cwd does not overwrite the sidecar"

    # A process with no positive pane signal (no AM_SESSION_NAME, no
    # TMUX_PANE) is not in an am pane, even when it runs in the launch
    # directory: nothing is written, not state and not the sidecar.
    rm -f "$state_dir/am-cwd1" "$state_dir/am-cwd1.cwd"
    AM_DIR="$am_dir" AM_REGISTRY="$registry" AM_STATE_DIR="$state_dir" \
        AM_IDENTITY_DIR="$tmp_dir/ids" AM_SESSION_NAME="" TMUX_PANE="" \
        "$hook_script" <<< "{\"hook_event_name\":\"Stop\",\"stop_hook_active\":false,\"cwd\":\"$home\"}"
    assert_cmd_fails "hook: unmanaged process in the launch dir writes no state" \
        test -f "$state_dir/am-cwd1"
    assert_cmd_fails "hook: unmanaged process in the launch dir writes no sidecar" \
        test -f "$state_dir/am-cwd1.cwd"

    rm -rf "$tmp_dir"
}

# Desktop notifications: fired off the critical path on a transition into a
# configured state; AM_NOTIFY_CMD stands in for osascript/notify-send.
test_state_hook_notify() {
    $SUMMARY_MODE || echo "=== Testing state-hook notifications ==="

    local hook_script="$PROJECT_DIR/lib/hooks/state-hook.sh"
    local tmp_dir registry state_dir am_dir home log
    tmp_dir=$(mktemp -d)
    registry="$tmp_dir/sessions.json"
    state_dir="$tmp_dir/state"
    am_dir="$tmp_dir/am"
    log="$tmp_dir/notify.log"
    mkdir -p "$state_dir" "$am_dir" "$tmp_dir/home"
    home=$(cd "$tmp_dir/home" && pwd -P)
    jq -n --arg dir "$home" \
        '{sessions: {"am-ntf1": {name: "am-ntf1", directory: $dir, branch: "feat/x", agent_type: "claude", task: "Fix the flaky test"}}}' \
        > "$registry"
    local notify_cmd='printf "%s|%s|%s|%s\n" "$AM_NOTIFY_SESSION" "$AM_NOTIFY_STATE" "$AM_NOTIFY_TITLE" "$AM_NOTIFY_BODY" >> '"$log"

    run_hook() {
        AM_DIR="$am_dir" AM_REGISTRY="$registry" AM_STATE_DIR="$state_dir" \
            AM_IDENTITY_DIR="$tmp_dir/ids" AM_SESSION_NAME="am-ntf1" AM_NOTIFY_CMD="$notify_cmd" \
            "$hook_script" <<< "$1"
    }
    # The notifier runs in the hook's detached tail; give it a moment.
    settle() { local i; for i in 1 2 3 4 5 6 7 8 9 10; do [[ -s "$log" && "$(wc -l < "$log")" -ge "${1:-1}" ]] && return 0; sleep 0.2; done; return 0; }

    run_hook '{"hook_event_name":"UserPromptSubmit","cwd":"'"$home"'"}'
    sleep 0.3
    assert_cmd_fails "notify: running does not notify" test -s "$log"

    run_hook '{"hook_event_name":"Notification","notification_type":"permission_prompt","cwd":"'"$home"'"}'
    settle 1
    assert_eq "1" "$(wc -l < "$log" 2>/dev/null | tr -d ' ')" "notify: waiting_user fires once"
    assert_contains "$(cat "$log")" "am-ntf1|waiting_user|" "notify: env carries session and state"
    assert_contains "$(cat "$log")" "home/feat/x" "notify: title labels dir/branch"
    assert_contains "$(cat "$log")" "needs you" "notify: title says the session needs the user"
    assert_contains "$(cat "$log")" "|Fix the flaky test" "notify: body is the session task"

    # Same state again: no transition, no second notification
    run_hook '{"hook_event_name":"Notification","notification_type":"permission_prompt","cwd":"'"$home"'"}'
    sleep 0.4
    assert_eq "1" "$(wc -l < "$log" | tr -d ' ')" "notify: same-state re-fire does not notify again"

    # Stop → ready is not in the default notify_states
    run_hook '{"hook_event_name":"Stop","stop_hook_active":false,"cwd":"'"$home"'"}'
    sleep 0.4
    assert_eq "1" "$(wc -l < "$log" | tr -d ' ')" "notify: ready is silent by default"

    # notify_states=waiting_user,ready announces finished turns
    printf '{"notify": true, "notify_states": "waiting_user,ready"}\n' > "$am_dir/config.json"
    run_hook '{"hook_event_name":"UserPromptSubmit","cwd":"'"$home"'"}'
    run_hook '{"hook_event_name":"Stop","stop_hook_active":false,"cwd":"'"$home"'"}'
    settle 2
    assert_eq "2" "$(wc -l < "$log" | tr -d ' ')" "notify: ready notifies when configured"
    assert_contains "$(tail -1 "$log")" "|ready|" "notify: ready transition carries its state"
    assert_contains "$(tail -1 "$log")" "finished" "notify: ready title says finished"

    # notify=false silences everything
    printf '{"notify": false, "notify_states": "waiting_user,ready"}\n' > "$am_dir/config.json"
    run_hook '{"hook_event_name":"Notification","notification_type":"permission_prompt","cwd":"'"$home"'"}'
    sleep 0.4
    assert_eq "2" "$(wc -l < "$log" | tr -d ' ')" "notify: notify=false is silent"

    rm -rf "$tmp_dir"
}

run_state_hooks_tests() {
    _run_test test_state_hooks
    _run_test test_state_from_hook_reads_file
    _run_test test_state_from_hook_missing_file
    _run_test test_state_from_hook_stale_file
    _run_test test_state_from_hook_invalid_state
    _run_test test_pi_durable_identity_guard
    _run_test test_state_hook_cwd_sidecar
    _run_test test_state_hook_notify
}

if [[ -z "${_AM_TEST_RUNNER:-}" ]]; then
    set -uo pipefail
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helpers.sh"
    check_deps
    run_state_hooks_tests
    test_report
fi
