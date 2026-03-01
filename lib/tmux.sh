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

    tmux_cleanup_logs "$name"
    tmux kill-session -t "$name"
}

# Stream pane output to a log file using tmux pipe-pane
tmux_enable_pipe_pane() {
    local session="$1"
    local pane="$2"
    local log_file="$3"

    tmux pipe-pane -t "${session}:${pane}" -o "cat >> '${log_file}'"
}

# Remove log directory for a session
tmux_cleanup_logs() {
    local name="$1"
    local log_dir="/tmp/am-logs/${name}"

    if [[ -d "$log_dir" ]]; then
        rm -rf "$log_dir"
    fi
}

# Attach to a tmux session
# Usage: tmux_attach <name>
tmux_attach() {
    local name="$1"

    if ! tmux_session_exists "$name"; then
        log_error "Session '$name' does not exist"
        return 1
    fi

    if [[ -n "${TMUX:-}" ]]; then
        # Already in tmux, switch client
        tmux switch-client -t "$name"
    else
        # Not in tmux, attach
        tmux attach-session -t "$name"
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
