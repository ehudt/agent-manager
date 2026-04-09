#!/usr/bin/env bash
# lib/hooks/state-hook.sh - Claude Code hook: maps hook events to am session states
#
# Claude Code calls this script as a hook. Reads JSON from stdin, maps the event
# to an am state, finds the matching session in the registry, and writes the state
# to $AM_STATE_DIR/<session_name>.
#
# Supported events:
#   Stop (stop_hook_active != true)  → waiting_input
#   Notification[idle_prompt]        → waiting_input
#   Notification[permission_prompt]  → waiting_permission
#   Notification[elicitation_dialog] → waiting_custom
#   UserPromptSubmit                 → running
#   PostToolUse                      → running
#
# Environment overrides (for testing):
#   AM_REGISTRY   — path to sessions.json (default: ~/.agent-manager/sessions.json)
#   AM_STATE_DIR  — directory for state files (default: /tmp/am-state/)

set -euo pipefail

AM_REGISTRY="${AM_REGISTRY:-${HOME}/.agent-manager/sessions.json}"
AM_STATE_DIR="${AM_STATE_DIR:-/tmp/am-state}"

# Read full stdin
hook_input=$(cat)

# Require jq
if ! command -v jq &>/dev/null; then
    exit 0
fi

# Extract hook type
hook_type=$(printf '%s' "$hook_input" | jq -r '.hook_event_name // empty' 2>/dev/null || true)
[[ -z "$hook_type" ]] && exit 0

# Guard against infinite loops from the Stop hook
if [[ "$hook_type" == "Stop" ]]; then
    stop_hook_active=$(printf '%s' "$hook_input" | jq -r '.stop_hook_active // false' 2>/dev/null || echo "false")
    if [[ "$stop_hook_active" == "true" ]]; then
        exit 0
    fi
fi

# Map hook event to am state
am_state=""
case "$hook_type" in
    Stop)
        am_state="waiting_input"
        ;;
    Notification)
        notification_type=$(printf '%s' "$hook_input" | jq -r '.notification_type // empty' 2>/dev/null || true)
        case "$notification_type" in
            idle_prompt)        am_state="waiting_input" ;;
            permission_prompt)  am_state="waiting_permission" ;;
            elicitation_dialog) am_state="waiting_custom" ;;
            *)                  exit 0 ;;
        esac
        ;;
    UserPromptSubmit|PostToolUse)
        am_state="running"
        ;;
    *)
        exit 0
        ;;
esac

# Extract cwd from hook input
cwd=$(printf '%s' "$hook_input" | jq -r '.cwd // empty' 2>/dev/null || true)
[[ -z "$cwd" ]] && exit 0

# Resolve to absolute path — use `pwd` (not -P) to match registry's abspath()
cwd_real=$(cd "$cwd" 2>/dev/null && pwd) || exit 0

# Look up session in registry
[[ ! -f "$AM_REGISTRY" ]] && exit 0

session_name=$(jq -r --arg cwd "$cwd_real" '
    .sessions
    | to_entries[]
    | select(.value.directory == $cwd)
    | .key
' "$AM_REGISTRY" 2>/dev/null | head -1 || true)

[[ -z "$session_name" ]] && exit 0

# Write state to file
mkdir -p "$AM_STATE_DIR"
printf '%s' "$am_state" > "$AM_STATE_DIR/$session_name"
