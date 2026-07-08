#!/usr/bin/env bash
# Case 04: hook race protection. PostToolUse can be delivered slightly after
# Stop has already moved the session to waiting_input. The race guard in
# state-hook.sh must prevent the late PostToolUse from clobbering the
# waiting_input state back to running.

set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lab.sh"

lab_init
trap lab_cleanup EXIT

DIR="$LAB_DIR/proj"
real=$(lab_register lab-ddd "$DIR")

# 1. Stop hook -> waiting_input
lab_hook lab-ddd "{\"hook_event_name\":\"Stop\",\"stop_hook_active\":false,\"cwd\":\"$real\"}"
lab_assert "waiting_input" "$(probe_hook lab-ddd)" "Stop -> waiting_input"

# 2. Late PostToolUse must NOT overwrite a fresh waiting_input -> running.
#    The guard is bounded by a grace window (AM_STATE_GUARD_SECS, default
#    10s); a trailing hook lands well inside it.
lab_hook lab-ddd "{\"hook_event_name\":\"PostToolUse\",\"cwd\":\"$real\"}"
lab_assert "waiting_input" "$(probe_hook lab-ddd)" \
    "PostToolUse after Stop: race guard preserves fresh waiting_input"

# 2b. Past the grace window, a tool hook is genuine resumed activity (a turn
#     can continue without UserPromptSubmit after an in-turn question dialog)
#     and MUST flip waiting_input -> running.
touch -t 202601010000 "$AM_STATE_DIR/lab-ddd"
lab_hook lab-ddd "{\"hook_event_name\":\"PostToolUse\",\"cwd\":\"$real\"}"
lab_assert "running" "$(probe_hook lab-ddd)" \
    "PostToolUse after grace window: flips aged waiting_input -> running"

# 3. UserPromptSubmit (explicit user action) transitions waiting_input ->
#    running immediately, with no grace-window wait.
lab_hook lab-ddd "{\"hook_event_name\":\"Stop\",\"stop_hook_active\":false,\"cwd\":\"$real\"}"
lab_hook lab-ddd "{\"hook_event_name\":\"UserPromptSubmit\",\"cwd\":\"$real\"}"
lab_assert "running" "$(probe_hook lab-ddd)" \
    "UserPromptSubmit can transition waiting_input -> running"

# 4. PermissionRequest while running -> waiting_permission
lab_hook lab-ddd "{\"hook_event_name\":\"PermissionRequest\",\"cwd\":\"$real\"}"
lab_assert "waiting_permission" "$(probe_hook lab-ddd)" \
    "PermissionRequest overrides running"

# 5. After permission grant, PostToolUse MUST transition waiting_permission ->
#    running. waiting_permission is transient: it unblocks when the user
#    answers, after which the tool runs and PostToolUse fires. The race guard
#    only protects waiting_input (grace window) and waiting_background
#    (unconditional).
lab_hook lab-ddd "{\"hook_event_name\":\"PostToolUse\",\"cwd\":\"$real\"}"
lab_assert "running" "$(probe_hook lab-ddd)" \
    "PostToolUse after PermissionRequest: transitions waiting_permission -> running"

lab_report
