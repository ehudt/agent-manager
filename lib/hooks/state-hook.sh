#!/usr/bin/env bash
# lib/hooks/state-hook.sh - Agent hook: maps lifecycle events to am session states
#
# Claude Code and Codex call this script as a hook. Reads JSON from stdin, maps
# the event to an am state, finds the matching session in the registry, and
# writes the state to $AM_STATE_DIR/<session_name>.
#
# Supported events:
#   Stop (stop_hook_active != true)  → waiting_input, or waiting_background
#                                      when the payload's background_tasks
#                                      array lists work still running
#   Notification[idle_prompt]        → waiting_input (same background_tasks
#                                      refinement, when the field is present)
#   Notification[permission_prompt]  → waiting_permission
#   Notification[elicitation_dialog] → waiting_custom
#   UserPromptSubmit                 → running
#   PreToolUse                       → running
#   PermissionRequest                → waiting_permission
#   PostToolUse                      → running
#
# background_tasks: Claude Code ≥2.1 includes a background_tasks array in the
# Stop payload — one entry per still-running background item ({id, type
# (subagent|shell), status, description, …}), pruned to [] once everything
# finishes. It is a fresh snapshot at each Stop, and Stop re-fires when
# background work completes (the completion re-invokes Claude for a wrap-up
# turn), so the state is self-healing without any pane scraping. Older CLIs
# and Codex simply lack the field → the jq filter counts 0 → waiting_input,
# and the pane-scan fallback in lib/state.sh still applies.
#
# Environment overrides (for testing):
#   AM_REGISTRY          — path to sessions.json (default: ~/.agent-manager/sessions.json)
#   AM_STATE_DIR         — directory for state files (default: /tmp/am-state/)
#   AM_STATE_GUARD_SECS  — grace window (s) during which tool hooks may not
#                          flip waiting_input back to running (default: 10)
#
# Session identification (in order of preference):
#   1. $AM_SESSION_NAME (exported by am when launching the agent) — exact match
#   2. $TMUX_PANE → tmux session name — works for sessions running before
#      AM_SESSION_NAME was added, since agents inherit TMUX_PANE from their pane
#   3. cwd match against registry — last resort; cannot disambiguate when
#      multiple am sessions share a directory (two Claude instances in one repo)

set -euo pipefail

AM_REGISTRY="${AM_REGISTRY:-${HOME}/.agent-manager/sessions.json}"
AM_STATE_DIR="${AM_STATE_DIR:-/tmp/am-state}"

# Optional debug trail. Gated by AM_HOOK_DEBUG=1 — silent no-op otherwise.
# Lets us see when a hook fires but the script exits without writing state
# (registry miss, missing AM_SESSION_NAME, cwd mismatch, etc).
# Sink: $AM_DIR/.hook-debug.log
_hook_debug() {
    [[ "${AM_HOOK_DEBUG:-}" != "1" ]] && return 0
    local dir="${AM_DIR:-${HOME}/.agent-manager}"
    printf '%s\t%s\t%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${hook_type:-?}" "$*" \
        >> "$dir/.hook-debug.log" 2>/dev/null || true
}

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

# Idle states are refined to waiting_background when the payload reports
# background work (subagents / background shells) still running.
_bg_running_count() {
    printf '%s' "$hook_input" \
        | jq '[.background_tasks[]? | select(.status == "running")] | length' 2>/dev/null \
        || echo 0
}

# Map hook event to am state
am_state=""
case "$hook_type" in
    Stop)
        am_state="waiting_input"
        [[ "$(_bg_running_count)" =~ ^[1-9] ]] && am_state="waiting_background"
        ;;
    Notification)
        notification_type=$(printf '%s' "$hook_input" | jq -r '.notification_type // empty' 2>/dev/null || true)
        case "$notification_type" in
            idle_prompt)
                am_state="waiting_input"
                [[ "$(_bg_running_count)" =~ ^[1-9] ]] && am_state="waiting_background"
                ;;
            permission_prompt)  am_state="waiting_permission" ;;
            elicitation_dialog) am_state="waiting_custom" ;;
            *)                  exit 0 ;;
        esac
        ;;
    PermissionRequest)
        am_state="waiting_permission"
        ;;
    UserPromptSubmit|PreToolUse|PostToolUse)
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
    if [[ -z "$session_name" ]]; then
        _hook_debug "AM_SESSION_NAME=$AM_SESSION_NAME not in registry; exiting"
        exit 0
    fi
fi

# 2. TMUX_PANE — agents inherit this from their tmux pane; resolving it to the
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
    if [[ -z "$cwd" ]]; then
        _hook_debug "no AM_SESSION_NAME/TMUX_PANE/cwd; cannot resolve session"
        exit 0
    fi
    cwd_real=$(cd "$cwd" 2>/dev/null && pwd) || {
        _hook_debug "cwd '$cwd' not accessible; exiting"
        exit 0
    }
    session_name=$(jq -r --arg cwd "$cwd_real" '
        .sessions
        | to_entries[]
        | select(.value.directory == $cwd)
        | .key
    ' "$AM_REGISTRY" 2>/dev/null | head -1 || true)
fi

if [[ -z "$session_name" ]]; then
    _hook_debug "no session matched (cwd=${cwd_real:-?})"
    exit 0
fi

# Race protection: a late PostToolUse can arrive after Stop has already
# written waiting_input (hooks run concurrently, slow tool hook finishes last).
# waiting_input is terminal — the agent is idle and the user is in the loop —
# so a late tool hook must not flip it back to running.
#
# The waiting_input guard is bounded by a grace window (AM_STATE_GUARD_SECS
# after the write, default 10s) because a turn can *resume without
# UserPromptSubmit*: an in-turn question dialog (AskUserQuestion) idles long
# enough for Notification[idle_prompt] to write waiting_input, and answering
# it continues the same turn — no new prompt event, only PreToolUse/
# PostToolUse. An unconditional guard swallowed those forever, pinning the
# session at waiting_input while it was actively working. The trailing-hook
# race it exists for is a milliseconds-scale problem, so a short window
# absorbs it while letting genuine resumed activity flip to running.
#
# waiting_background is guarded *unconditionally*: a background subagent's
# own tool calls fire PreToolUse/PostToolUse in this session for as long as
# it runs (minutes), so any time window would eventually let them erase the
# refinement. The state still moves forward on its own — Stop re-fires when
# the background work completes (with a pruned background_tasks) — and
# UserPromptSubmit remains the user-driven exit.
#
# waiting_permission and waiting_custom are explicitly *transient*: they unblock
# when the user answers, after which Claude/Codex resumes work and fires
# PreToolUse/PostToolUse. Those hooks MUST move the state forward to running,
# otherwise the session appears stuck at waiting_permission until end-of-turn.
state_file="$AM_STATE_DIR/$session_name"
if [[ "$am_state" == "running" && "$hook_type" != "UserPromptSubmit" && -f "$state_file" ]]; then
    current=$(head -1 "$state_file" 2>/dev/null || true)
    case "$current" in
        waiting_background) exit 0 ;;
        waiting_input)
            state_mtime=$(stat -c %Y "$state_file" 2>/dev/null || stat -f %m "$state_file" 2>/dev/null || echo 0)
            if (( $(date +%s) - state_mtime <= ${AM_STATE_GUARD_SECS:-10} )); then
                exit 0
            fi
            ;;
    esac
fi

# Write state to file
mkdir -p "$AM_STATE_DIR"
printf '%s' "$am_state" > "$state_file"

# Persist the Claude/Codex conversation id alongside the state when the hook
# payload exposes it. This lets restore snapshots bind to the exact pane that
# fired the hook instead of guessing by cwd, which is ambiguous for duplicate
# sessions in one repo.
hook_session_id=$(printf '%s' "$hook_input" | jq -r '.session_id // .sessionId // empty' 2>/dev/null || true)
if [[ -z "$hook_session_id" ]]; then
    transcript_path=$(printf '%s' "$hook_input" | jq -r '.transcript_path // empty' 2>/dev/null || true)
    if [[ -n "$transcript_path" ]]; then
        hook_session_id=$(basename "$transcript_path" .jsonl)
    fi
fi
if [[ -n "$hook_session_id" && "$hook_session_id" =~ ^[A-Za-z0-9._-]+$ ]]; then
    printf '%s' "$hook_session_id" > "$AM_STATE_DIR/$session_name.sid"
fi

# Invalidate list cache so the next fzf reload picks up the new state
AM_DIR="${AM_DIR:-${HOME}/.agent-manager}"
rm -f "$AM_DIR/.list_cache" 2>/dev/null || true

# Invalidate title-scan throttle on prompt boundaries so the next status-bar
# tick refreshes the registry task field within ~5s instead of waiting up to
# 60s. Only fire on prompt boundaries — tool hooks would defeat the throttle
# for busy sessions.
case "$hook_type" in
    UserPromptSubmit|Stop)
        rm -f "$AM_DIR/.title_scan_last" 2>/dev/null || true
        ;;
esac

# Push status-bar refresh to the dedicated tmux server so the new glyph
# appears immediately instead of waiting for the 5s status-interval tick.
if command -v tmux &>/dev/null; then
    tmux -L "${AM_TMUX_SOCKET:-agent-manager}" refresh-client -S 2>/dev/null || true
fi
