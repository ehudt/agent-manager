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
#
# Session identification (in order of preference):
#   1. $AM_SESSION_NAME (exported by am when launching the agent) — exact match
#   2. $TMUX_PANE → tmux session name — works for sessions running before
#      AM_SESSION_NAME was added, since Claude inherits TMUX_PANE from its pane
#   3. cwd match against registry — last resort; cannot disambiguate when
#      multiple am sessions share a directory (two Claude instances in one repo)

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

# Registry is required for any session lookup or validation
[[ ! -f "$AM_REGISTRY" ]] && exit 0

# Helper: echo the session name if it exists in the registry, otherwise empty.
# Always returns success so callers can use command substitution under set -e.
_registry_has() {
    jq -e --arg k "$1" '.sessions[$k] // empty' "$AM_REGISTRY" &>/dev/null && echo "$1"
    return 0
}

session_name=""

# 1. AM_SESSION_NAME — authoritative when set by agent_launch. If set but not
#    in the registry, the session was removed or renamed; do not fall through
#    to cwd matching, which would silently clobber the wrong session's state.
if [[ -n "${AM_SESSION_NAME:-}" ]]; then
    session_name=$(_registry_has "$AM_SESSION_NAME")
    [[ -z "$session_name" ]] && exit 0
fi

# 2. TMUX_PANE — Claude inherits this from its tmux pane; resolving it to the
#    tmux session name directly avoids the duplicate-cwd bug even for sessions
#    that predate the AM_SESSION_NAME export.
if [[ -z "$session_name" && -n "${TMUX_PANE:-}" ]] && command -v tmux &>/dev/null; then
    tmux_session=$(tmux display-message -p -t "$TMUX_PANE" '#S' 2>/dev/null || true)
    if [[ -n "$tmux_session" ]]; then
        session_name=$(_registry_has "$tmux_session")
    fi
fi

# 3. cwd match — last resort; ambiguous when two sessions share a directory
if [[ -z "$session_name" ]]; then
    cwd=$(printf '%s' "$hook_input" | jq -r '.cwd // empty' 2>/dev/null || true)
    [[ -z "$cwd" ]] && exit 0
    cwd_real=$(cd "$cwd" 2>/dev/null && pwd) || exit 0
    session_name=$(jq -r --arg cwd "$cwd_real" '
        .sessions
        | to_entries[]
        | select(.value.directory == $cwd)
        | .key
    ' "$AM_REGISTRY" 2>/dev/null | head -1 || true)
fi

[[ -z "$session_name" ]] && exit 0

# Race protection: PostToolUse can be delivered after Stop/Notification has
# already moved the session into a waiting_* state (hooks run concurrently and
# a slow PostToolUse script can finish last). Skip the write in that case —
# only UserPromptSubmit (explicit user action) transitions waiting_* → running.
state_file="$AM_STATE_DIR/$session_name"
if [[ "$hook_type" == "PostToolUse" && -f "$state_file" ]]; then
    current=$(head -1 "$state_file" 2>/dev/null || true)
    case "$current" in
        waiting_input|waiting_permission|waiting_custom) exit 0 ;;
    esac
fi

# Write state to file
mkdir -p "$AM_STATE_DIR"
printf '%s' "$am_state" > "$state_file"

# Invalidate list cache so the next fzf reload picks up the new state
AM_DIR="${AM_DIR:-${HOME}/.agent-manager}"
rm -f "$AM_DIR/.list_cache" 2>/dev/null || true
