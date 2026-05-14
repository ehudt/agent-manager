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

# 2. Late PostToolUse must NOT overwrite waiting_input -> running
lab_hook lab-ddd "{\"hook_event_name\":\"PostToolUse\",\"cwd\":\"$real\"}"
lab_assert "waiting_input" "$(probe_hook lab-ddd)" \
    "PostToolUse after Stop: race guard preserves waiting_input"

# 3. UserPromptSubmit (explicit user action) is the only event that may
#    transition waiting_* back to running.
lab_hook lab-ddd "{\"hook_event_name\":\"UserPromptSubmit\",\"cwd\":\"$real\"}"
lab_assert "running" "$(probe_hook lab-ddd)" \
    "UserPromptSubmit can transition waiting_input -> running"

# 4. PermissionRequest while running -> waiting_permission
lab_hook lab-ddd "{\"hook_event_name\":\"PermissionRequest\",\"cwd\":\"$real\"}"
lab_assert "waiting_permission" "$(probe_hook lab-ddd)" \
    "PermissionRequest overrides running"

# 5. Late PostToolUse must NOT clobber waiting_permission
lab_hook lab-ddd "{\"hook_event_name\":\"PostToolUse\",\"cwd\":\"$real\"}"
lab_assert "waiting_permission" "$(probe_hook lab-ddd)" \
    "PostToolUse after PermissionRequest: race guard preserves waiting_permission"

lab_report
