#!/usr/bin/env bash
# tests/test_doctor.sh - Tests for lib/doctor.sh: version-drift canary and
# per-family hook-install checks.

_doctor_source_libs() {
    source "$LIB_DIR/utils.sh"
    set +u
    source "$LIB_DIR/config.sh"
    source "$LIB_DIR/tmux.sh"
    source "$LIB_DIR/registry.sh"
    source "$LIB_DIR/state.sh"
    source "$LIB_DIR/doctor.sh"
    set -u
    AM_VERSION="${AM_VERSION:-test}"
}

test_doctor_version_compare() {
    $SUMMARY_MODE || echo "=== Testing doctor version compare ==="
    _doctor_source_libs

    assert_eq "2.1.263" "$(_doc_ver_core '2.1.263 (Claude Code)')" "ver_core: strips trailing text"
    assert_eq "2026.09.02" "$(_doc_ver_core 'v2026.09.02-c22c1a3')" "ver_core: strips v prefix and suffix"
    assert_eq "" "$(_doc_ver_core 'unknown')" "ver_core: non-numeric is empty"

    assert_cmd_succeeds "ver_newer: patch newer" _doc_ver_newer "2.1.263" "2.1.237"
    assert_cmd_fails "ver_newer: equal is not newer" _doc_ver_newer "2.1.237" "2.1.237"
    assert_cmd_fails "ver_newer: older is not newer" _doc_ver_newer "2.1.200" "2.1.237"
    assert_cmd_succeeds "ver_newer: minor beats patch" _doc_ver_newer "2.2.0" "2.1.999"
    assert_cmd_succeeds "ver_newer: longer version vs short pin" _doc_ver_newer "2026.09.02" "2026.08"
    assert_cmd_fails "ver_newer: short pin equal to padded" _doc_ver_newer "2.1.0" "2.1"
    assert_cmd_succeeds "ver_newer: agent --version noise ignored" _doc_ver_newer "2.1.263 (Claude Code)" "2.1.237"
    assert_cmd_fails "ver_newer: garbage never warns" _doc_ver_newer "unknown" "2.1.237"
    assert_cmd_succeeds "ver_newer: leading zeros are decimal" _doc_ver_newer "1.09" "1.8"
}

test_doctor_drift() {
    $SUMMARY_MODE || echo "=== Testing doctor drift section ==="
    _doctor_source_libs
    setup_isolated_am_dir

    local tmp fake_bin verified out
    tmp=$(mktemp -d)
    fake_bin="$tmp/bin"
    mkdir -p "$fake_bin"
    printf '#!/usr/bin/env bash\necho "9.9.9 (Claude Code)"\n' > "$fake_bin/claude"
    printf '#!/usr/bin/env bash\necho "0.1.0"\n' > "$fake_bin/pi"
    printf '#!/usr/bin/env bash\necho "codex-cli 0.1.0"\n' > "$fake_bin/codex"
    chmod +x "$fake_bin/claude" "$fake_bin/pi" "$fake_bin/codex"
    verified="$tmp/VERIFIED"
    printf '# comment\nclaude\t2.1.237\t2026-08-25\ttests/live_lab/run.sh\tnote\n' > "$verified"

    # Only the fake agents are visible; cursor-agent/codex absent → skipped.
    out=$(PATH="$fake_bin:/usr/bin:/bin" AM_VERIFIED_FILE="$verified" _doc_drift 2>&1)
    assert_contains "$out" "claude 9.9.9 (Claude Code) is newer than the last live-lab verified 2.1.237" "drift: newer install warns"
    assert_contains "$out" "run tests/live_lab/run.sh" "drift: warning names the lab to run"
    assert_contains "$out" "pi" "drift: unpinned agent is listed"
    assert_contains "$out" "no verified pin; run tests/live_lab/run_pi.sh" "drift: unpinned agent names its lab"
    assert_contains "$out" "codex-cli 0.1.0 (no live lab" "drift: agent without a lab is reported, not nagged"
    assert_not_contains "$out" "cursor-agent" "drift: absent agent is skipped"
    assert_contains "$out" "none yet" "drift: no schema observations yet"

    # Pin equal to the installed version → ok line, no warning.
    printf 'claude\t9.9.9\t2026-09-07\ttests/live_lab/run.sh\tnote\n' > "$verified"
    out=$(PATH="$fake_bin:/usr/bin:/bin" AM_VERIFIED_FILE="$verified" _doc_drift 2>&1)
    assert_contains "$out" "✓ claude 9.9.9 (Claude Code) (verified 9.9.9, 2026-09-07)" "drift: matching pin is ok"
    assert_not_contains "$out" "is newer" "drift: matching pin does not warn"

    # Missing pin file warns once but still reports agents.
    out=$(PATH="$fake_bin:/usr/bin:/bin" AM_VERIFIED_FILE="$tmp/nope" _doc_drift 2>&1)
    assert_contains "$out" "no verified-version pin file" "drift: missing pin file warns"

    # Hook payload schema: complete Stop payload is clean; a Stop that lost
    # background_tasks warns with the removed key.
    mkdir -p "$AM_DIR/hook-schema"
    printf 'background_tasks,cwd,hook_event_name,permission_mode,session_id,stop_hook_active,transcript_path\n' \
        > "$AM_DIR/hook-schema/claude.Stop.keys"
    printf 'conversation_id,generation_id,hook_event_name,workspace_roots\n' \
        > "$AM_DIR/hook-schema/cursor.stop.keys"
    out=$(PATH="$fake_bin:/usr/bin:/bin" AM_VERIFIED_FILE="$verified" _doc_drift 2>&1)
    assert_contains "$out" "claude.Stop:" "schema: observed file listed"
    assert_not_contains "$out" "load-bearing" "schema: complete payloads do not warn"

    printf 'cwd,hook_event_name,permission_mode,session_id,stop_hook_active,transcript_path\n' \
        > "$AM_DIR/hook-schema/claude.Stop.keys"
    printf 'background_tasks,cwd,hook_event_name,permission_mode,session_id,stop_hook_active,transcript_path\n' \
        > "$AM_DIR/hook-schema/claude.Stop.keys.prev"
    printf 'generation_id,hook_event_name\n' > "$AM_DIR/hook-schema/cursor.stop.keys"
    out=$(PATH="$fake_bin:/usr/bin:/bin" AM_VERIFIED_FILE="$verified" _doc_drift 2>&1)
    assert_contains "$out" "claude.Stop: load-bearing field(s) missing: background_tasks" "schema: missing Stop field warns"
    assert_contains "$out" "-background_tasks" "schema: diff against previous set shows the removed key"
    assert_contains "$out" "cursor.stop: load-bearing field(s) missing: conversation_id" "schema: cursor identity field checked"

    # Notification requires notification_type; other claude events only the common set.
    printf 'cwd,hook_event_name,message,session_id,transcript_path\n' > "$AM_DIR/hook-schema/claude.Notification.keys"
    printf 'cwd,hook_event_name,prompt,session_id,transcript_path\n' > "$AM_DIR/hook-schema/claude.UserPromptSubmit.keys"
    out=$(PATH="$fake_bin:/usr/bin:/bin" AM_VERIFIED_FILE="$verified" _doc_drift 2>&1)
    assert_contains "$out" "claude.Notification: load-bearing field(s) missing: notification_type" "schema: Notification field checked"
    assert_not_contains "$out" "claude.UserPromptSubmit: load-bearing" "schema: UserPromptSubmit with common fields is clean"

    assert_eq "-b +d" "$(_doc_keys_diff 'a,b,c' 'a,c,d')" "keys_diff: removed then added"
    assert_eq "" "$(_doc_keys_diff 'a,b' 'a,b')" "keys_diff: identical sets are empty"

    rm -rf "$tmp"
    teardown_isolated_am_dir
}

# The state hook records the payload key set per <agent>.<event>, only on
# change, keeping the previous set.
test_doctor_hook_schema_recording() {
    $SUMMARY_MODE || echo "=== Testing state-hook payload schema recording ==="

    local hook_script="$PROJECT_DIR/lib/hooks/state-hook.sh"
    local tmp_dir registry state_dir am_dir home
    tmp_dir=$(mktemp -d)
    registry="$tmp_dir/sessions.json"
    state_dir="$tmp_dir/state"
    am_dir="$tmp_dir/am"
    mkdir -p "$state_dir" "$am_dir" "$tmp_dir/home"
    home=$(cd "$tmp_dir/home" && pwd -P)
    jq -n --arg dir "$home" \
        '{sessions: {"am-sch1": {name: "am-sch1", directory: $dir, agent_type: "claude"}}}' > "$registry"

    run_hook() {
        AM_DIR="$am_dir" AM_REGISTRY="$registry" AM_STATE_DIR="$state_dir" \
            AM_IDENTITY_DIR="$tmp_dir/ids" AM_SESSION_NAME="am-sch1" AM_NOTIFY_CMD="true" \
            "$hook_script" <<< "$1"
    }
    local f="$am_dir/hook-schema/claude.Stop.keys"
    settle() { local i; for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do [[ -s "$1" ]] && return 0; sleep 0.2; done; return 0; }

    run_hook '{"hook_event_name":"Stop","stop_hook_active":false,"background_tasks":[],"session_id":"s1","transcript_path":"/t/s1.jsonl","cwd":"'"$home"'"}'
    settle "$f"
    assert_eq "background_tasks,cwd,hook_event_name,session_id,stop_hook_active,transcript_path" "$(cat "$f" 2>/dev/null)" \
        "schema: Stop keys recorded sorted"
    assert_cmd_fails "schema: no .prev on first observation" test -e "$f.prev"
    local mode
    mode=$(stat -f %Lp "$am_dir/hook-schema" 2>/dev/null || stat -c %a "$am_dir/hook-schema" 2>/dev/null)
    assert_eq "700" "$mode" "schema: directory is private"

    # Same key set again (different values, different state): no rewrite.
    touch -t 200001010000 "$f"
    run_hook '{"hook_event_name":"UserPromptSubmit","session_id":"s1","transcript_path":"/t/s1.jsonl","cwd":"'"$home"'"}'
    run_hook '{"hook_event_name":"Stop","stop_hook_active":true,"background_tasks":[{"id":"x","type":"shell","status":"running"}],"session_id":"s1","transcript_path":"/t/s1.jsonl","cwd":"'"$home"'"}'
    settle "$am_dir/hook-schema/claude.UserPromptSubmit.keys"
    sleep 0.3
    local y
    y=$(date -r "$f" +%Y 2>/dev/null || stat -c %y "$f" | cut -c1-4)
    assert_eq "2000" "$y" "schema: same key set does not rewrite the file"
    assert_eq "cwd,hook_event_name,session_id,transcript_path" "$(cat "$am_dir/hook-schema/claude.UserPromptSubmit.keys")" \
        "schema: one file per event"

    # Key set changes: file rewritten, previous set kept.
    run_hook '{"hook_event_name":"Stop","stop_hook_active":false,"session_id":"s1","transcript_path":"/t/s1.jsonl","cwd":"'"$home"'"}'
    settle "$f.prev"
    assert_eq "cwd,hook_event_name,session_id,stop_hook_active,transcript_path" "$(cat "$f")" "schema: changed set replaces the file"
    assert_eq "background_tasks,cwd,hook_event_name,session_id,stop_hook_active,transcript_path" "$(cat "$f.prev" 2>/dev/null)" \
        "schema: previous set kept in .prev"

    # Subagent tool events (agent_id present) go to their own .sub file and
    # leave the main-agent file untouched.
    run_hook '{"hook_event_name":"UserPromptSubmit","session_id":"s1","transcript_path":"/t/s1.jsonl","cwd":"'"$home"'"}'
    run_hook '{"hook_event_name":"PostToolUse","tool_name":"Read","session_id":"s1","transcript_path":"/t/s1.jsonl","cwd":"'"$home"'"}'
    settle "$am_dir/hook-schema/claude.PostToolUse.keys"
    run_hook '{"hook_event_name":"PostToolUse","tool_name":"Read","agent_id":"a1","agent_type":"Explore","session_id":"s1","transcript_path":"/t/s1.jsonl","cwd":"'"$home"'"}'
    settle "$am_dir/hook-schema/claude.PostToolUse.sub.keys"
    assert_eq "cwd,hook_event_name,session_id,tool_name,transcript_path" "$(cat "$am_dir/hook-schema/claude.PostToolUse.keys")" \
        "schema: main-agent tool event set unchanged by subagent event"
    assert_eq "agent_id,agent_type,cwd,hook_event_name,session_id,tool_name,transcript_path" "$(cat "$am_dir/hook-schema/claude.PostToolUse.sub.keys" 2>/dev/null)" \
        "schema: subagent tool event recorded under .sub"
    assert_cmd_fails "schema: subagent event leaves no .prev on the main file" test -e "$am_dir/hook-schema/claude.PostToolUse.keys.prev"

    rm -rf "$tmp_dir"
}

test_doctor_hooks_installed() {
    $SUMMARY_MODE || echo "=== Testing doctor hook-install checks ==="
    _doctor_source_libs

    local tmp out expected
    tmp=$(mktemp -d)
    expected="$AM_LIB_DIR/hooks/state-hook.sh"
    mkdir -p "$tmp/.claude"
    jq -n --arg h "$expected" '{hooks: {
        Stop: [{hooks: [{type: "command", command: $h}]}],
        Notification: [{hooks: [{type: "command", command: $h}]}],
        UserPromptSubmit: [{hooks: [{type: "command", command: $h}]}],
        PostToolUse: [{hooks: [{type: "command", command: "/elsewhere/lib/hooks/state-hook.sh"}]}]
    }}' > "$tmp/.claude/settings.json"

    out=$(HOME="$tmp" CODEX_HOME="$tmp/.codex" CURSOR_CONFIG_HOME="$tmp/.cursor" _doc_hooks_installed 2>&1)
    assert_contains "$out" "✓ claude Stop" "hooks: installed event is ok"
    assert_contains "$out" "✓ claude UserPromptSubmit" "hooks: UserPromptSubmit ok"
    assert_contains "$out" "claude PostToolUse: hook points elsewhere" "hooks: foreign path flagged"
    assert_not_contains "$out" "PreToolUse: no am state hook" "hooks: Claude is not expected to have PreToolUse"
    assert_not_contains "$out" "PermissionRequest: no am state hook" "hooks: Claude is not expected to have PermissionRequest"
    assert_contains "$out" "codex:" "hooks: codex row present"
    assert_contains "$out" "not configured" "hooks: optional families report not configured, not a warning"
    assert_not_contains "$out" "! codex" "hooks: missing codex file is not a warning"
    assert_not_contains "$out" "! cursor" "hooks: missing cursor file is not a warning"

    # Cursor: flat .hooks[ev][].command entries run a copy of the hook.
    mkdir -p "$tmp/.cursor/hooks"
    cp "$expected" "$tmp/.cursor/hooks/am-state-hook.sh"
    jq -n --arg cmd "bash $tmp/.cursor/hooks/am-state-hook.sh # am-state-hook" '{version: 1, hooks: {
        sessionStart: [{command: $cmd, timeout: 5}],
        stop: [{command: $cmd, timeout: 5}]
    }}' > "$tmp/.cursor/hooks.json"
    out=$(HOME="$tmp" CODEX_HOME="$tmp/.codex" CURSOR_CONFIG_HOME="$tmp/.cursor" _doc_hooks_installed 2>&1)
    assert_contains "$out" "✓ cursor sessionStart" "hooks: cursor flat command shape recognised"
    assert_contains "$out" "✓ cursor stop" "hooks: cursor stop ok"
    assert_contains "$out" "cursor preToolUse: no am state hook installed" "hooks: missing cursor event warns"
    assert_not_contains "$out" "helper" "hooks: identical copy of the hook is accepted"

    printf '\n# drifted\n' >> "$tmp/.cursor/hooks/am-state-hook.sh"
    out=$(HOME="$tmp" CODEX_HOME="$tmp/.codex" CURSOR_CONFIG_HOME="$tmp/.cursor" _doc_hooks_installed 2>&1)
    assert_contains "$out" "is a stale copy of the hook; run: am install --refresh" "hooks: stale helper copy warns"

    rm -rf "$tmp"
}

run_doctor_tests() {
    _run_test test_doctor_version_compare
    _run_test test_doctor_drift
    _run_test test_doctor_hook_schema_recording
    _run_test test_doctor_hooks_installed
}

if [[ -z "${_AM_TEST_RUNNER:-}" ]]; then
    set -uo pipefail
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_helpers.sh"
    check_deps
    run_doctor_tests
    test_report
fi
