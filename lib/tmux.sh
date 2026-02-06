#!/usr/bin/env bash
# tmux.sh - tmux wrapper functions

# Source utils if not already loaded
[[ -z "$AM_DIR" ]] && source "$(dirname "${BASH_SOURCE[0]}")/utils.sh"

# Ensure tmux is available
require_cmd tmux

# Check if a tmux session exists
# Usage: tmux_session_exists <name>
tmux_session_exists() {
    local name="$1"
    tmux has-session -t "$name" 2>/dev/null
}

# Create a new tmux session (detached)
# Usage: tmux_create_session <name> <directory>
tmux_create_session() {
    local name="$1"
    local directory="$2"

    if tmux_session_exists "$name"; then
        log_error "Session '$name' already exists"
        return 1
    fi

    # Create with explicit dimensions to work around tmux sizing bugs in detached sessions
    # https://github.com/tmux/tmux/issues/3060
    tmux new-session -d -s "$name" -c "$directory" -x 200 -y 60
}

# Kill a tmux session
# Usage: tmux_kill_session <name>
tmux_kill_session() {
    local name="$1"

    if ! tmux_session_exists "$name"; then
        log_warn "Session '$name' does not exist"
        return 1
    fi

    tmux kill-session -t "$name"
}

# Attach to a tmux session
# Usage: tmux_attach <name>
tmux_attach() {
    local name="$1"

    if ! tmux_session_exists "$name"; then
        log_error "Session '$name' does not exist"
        return 1
    fi

    if in_tmux; then
        # Already in tmux, switch client
        tmux switch-client -t "$name"
    else
        # Not in tmux, attach
        tmux attach-session -t "$name"
    fi
}

# Capture pane content from a session
# Usage: tmux_capture_pane <name> [lines] [skip_bottom]
# Returns the captured content to stdout
# Note: Captures top pane (pane 1) where agent runs, not bottom shell pane
# skip_bottom: lines to skip from bottom (default 0)
tmux_capture_pane() {
    local name="$1"
    local lines="${2:-50}"
    local skip_bottom="${3:-0}"

    if ! tmux_session_exists "$name"; then
        echo "(Session not found)"
        return 1
    fi

    # Capture the visible pane content (no -S means just visible area)
    # -p: print to stdout
    # -e: include escape sequences (colors)
    # -t: target the agent pane (window 1, pane 1 - top pane)
    local output
    output=$(tmux capture-pane -t "$name:1.1" -p -e 2>/dev/null || \
             tmux capture-pane -t "$name" -p -e 2>/dev/null)

    if [[ -z "$output" ]]; then
        echo "(Unable to capture)"
        return 1
    fi

    # Count total lines, remove bottom N (status bar), show last N lines
    local total_lines
    total_lines=$(echo "$output" | wc -l | tr -d ' ')
    local keep_lines=$((total_lines - skip_bottom))

    if (( keep_lines > 0 )); then
        echo "$output" | head -n "$keep_lines" | tail -n "$lines"
    else
        echo "$output" | tail -n "$lines"
    fi
}

# Get session activity timestamp (seconds since epoch)
# Usage: tmux_get_activity <name>
tmux_get_activity() {
    local name="$1"
    tmux list-sessions -F '#{session_name} #{session_activity}' 2>/dev/null \
        | grep "^$name " \
        | cut -d' ' -f2
}

# Get session creation time (seconds since epoch)
# Usage: tmux_get_created <name>
tmux_get_created() {
    local name="$1"
    tmux list-sessions -F '#{session_name} #{session_created}' 2>/dev/null \
        | grep "^$name " \
        | cut -d' ' -f2
}

# List all agent-manager sessions (those with AM_SESSION_PREFIX)
# Usage: tmux_list_am_sessions
# Returns: newline-separated session names
tmux_list_am_sessions() {
    tmux list-sessions -F '#{session_name}' 2>/dev/null \
        | grep "^${AM_SESSION_PREFIX}" \
        || true
}

# List all agent-manager sessions with activity info
# Usage: tmux_list_am_sessions_with_activity
# Returns: "name activity_timestamp" per line, sorted by activity (most recent first)
tmux_list_am_sessions_with_activity() {
    tmux list-sessions -F '#{session_activity} #{session_name}' 2>/dev/null \
        | grep " ${AM_SESSION_PREFIX}" \
        | sort -rn \
        | awk '{print $2, $1}' \
        || true
}

# Get detailed info about a session
# Usage: tmux_session_info <name>
# Returns JSON-like output
tmux_session_info() {
    local name="$1"

    if ! tmux_session_exists "$name"; then
        echo "{}"
        return 1
    fi

    local info
    info=$(tmux list-sessions -F '#{session_name}|#{session_created}|#{session_activity}|#{session_windows}|#{session_attached}' 2>/dev/null \
        | grep "^$name|")

    if [[ -n "$info" ]]; then
        local created activity windows attached
        IFS='|' read -r _ created activity windows attached <<< "$info"

        local now
        now=$(epoch_now)
        local age=$((now - created))
        local idle=$((now - activity))

        echo "created=$created"
        echo "activity=$activity"
        echo "windows=$windows"
        echo "attached=$attached"
        echo "age=$age"
        echo "idle=$idle"
    fi
}

# Send keys to a tmux session
# Usage: tmux_send_keys <name> <keys...>
tmux_send_keys() {
    local name="$1"
    shift
    tmux send-keys -t "$name" "$@"
}

# Count agent-manager sessions
# Usage: tmux_count_am_sessions
tmux_count_am_sessions() {
    local sessions
    sessions=$(tmux_list_am_sessions)
    if [[ -z "$sessions" ]]; then
        echo 0
    else
        echo "$sessions" | wc -l | tr -d ' '
    fi
}

# Kill all agent-manager sessions
# Usage: tmux_kill_all_am_sessions
tmux_kill_all_am_sessions() {
    local session
    local count=0

    for session in $(tmux_list_am_sessions); do
        tmux_kill_session "$session" && ((count++))
    done

    echo "$count"
}
