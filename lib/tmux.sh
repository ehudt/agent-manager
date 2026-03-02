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

_tmux_bool_label() {
    case "${1:-}" in
        1|true|yes|on) echo "yes" ;;
        *) echo "no" ;;
    esac
}

_tmux_status_value() {
    local value="${1:-}"
    value=${value//$'\n'/ }
    echo "${value:-"-"}"
}

# Set a per-session status-left string with session metadata.
# Usage: tmux_set_session_status <name> <directory> <branch> <worktree_mode> <yolo_mode> <sandbox_mode>
tmux_set_session_status() {
    local name="$1"
    local directory="$2"
    local branch="$3"
    local worktree_mode="$4"
    local yolo_mode="$5"
    local sandbox_mode="$6"

    local dir_label branch_label status_left
    dir_label=$(_tmux_status_value "$(dir_basename "${directory:-$name}")")
    branch_label=$(_tmux_status_value "$branch")

    status_left="#[bold]#{session_name}#[default] ${dir_label}:${branch_label}"
    [[ "$worktree_mode" == "true" ]] && status_left="${status_left} (GIT WORKTREE)"
    [[ "$yolo_mode" == "true" ]] && status_left="${status_left} yolo"
    [[ "$sandbox_mode" == "true" ]] && status_left="${status_left} sandbox"
    status_left="${status_left} "

    tmux set-option -t "$name" status-left-length 160 >/dev/null
    tmux set-option -t "$name" status-left "$status_left" >/dev/null
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

# Get a tmux session field value
# Usage: _tmux_get_session_field <name> <format_token>
_tmux_get_session_field() {
    local name="$1" format="$2"
    tmux list-sessions -F "#{session_name} #{$format}" 2>/dev/null \
        | grep "^${name} " | cut -d' ' -f2
}

# Get session activity timestamp (seconds since epoch)
tmux_get_activity() { _tmux_get_session_field "$1" session_activity; }

# Get session creation time (seconds since epoch)
tmux_get_created() { _tmux_get_session_field "$1" session_created; }

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
