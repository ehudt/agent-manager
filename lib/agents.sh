#!/usr/bin/env bash
# agents.sh - Agent launcher functions

# Source dependencies if not already loaded
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
[[ -z "$AM_DIR" ]] && source "$SCRIPT_DIR/utils.sh"
[[ "$(type -t tmux_create_session)" != "function" ]] && source "$SCRIPT_DIR/tmux.sh"
[[ "$(type -t registry_add)" != "function" ]] && source "$SCRIPT_DIR/registry.sh"

# Supported agent types and their commands
declare -A AGENT_COMMANDS=(
    [claude]="claude"
    [gemini]="gemini"
    [aider]="aider"
)

# Get the command for an agent type
# Usage: agent_get_command <type>
agent_get_command() {
    local agent_type="$1"
    echo "${AGENT_COMMANDS[$agent_type]:-$agent_type}"
}

# Check if an agent type is supported
# Usage: agent_type_supported <type>
agent_type_supported() {
    local agent_type="$1"
    [[ -n "${AGENT_COMMANDS[$agent_type]}" ]]
}

# Detect git branch for a directory
# Usage: detect_git_branch <directory>
detect_git_branch() {
    local directory="$1"
    git -C "$directory" branch --show-current 2>/dev/null || echo ""
}

# Generate a unique session name
# Usage: generate_session_name <directory>
generate_session_name() {
    local directory="$1"
    local timestamp
    timestamp=$(date +%s%N 2>/dev/null || date +%s)
    local hash
    hash=$(generate_hash "${directory}${timestamp}")
    echo "${AM_SESSION_PREFIX}${hash}"
}

# Launch an agent in a new tmux session
# Usage: agent_launch <directory> [agent_type] [task_description] [agent_args...]
# Returns: session name on success, empty on failure
agent_launch() {
    local directory="$1"
    local agent_type="${2:-claude}"
    local task="${3:-}"
    shift 3 2>/dev/null || shift $#
    local agent_args=("$@")

    # Validate directory
    if [[ ! -d "$directory" ]]; then
        log_error "Directory does not exist: $directory"
        return 1
    fi

    # Get absolute path
    directory=$(abspath "$directory")

    # Validate agent type
    if ! agent_type_supported "$agent_type"; then
        log_warn "Unknown agent type '$agent_type', using as command directly"
    fi

    # Get agent command
    local agent_cmd
    agent_cmd=$(agent_get_command "$agent_type")

    # Check if agent command exists
    if ! command -v "$agent_cmd" &>/dev/null; then
        log_error "Agent command not found: $agent_cmd"
        return 1
    fi

    # Detect git branch
    local branch=""
    branch=$(detect_git_branch "$directory")

    # Generate session name
    local session_name
    session_name=$(generate_session_name "$directory")

    # Create tmux session (with explicit dimensions for sizing workaround)
    if ! tmux_create_session "$session_name" "$directory"; then
        log_error "Failed to create tmux session"
        return 1
    fi

    # Register session metadata
    registry_add "$session_name" "$directory" "$branch" "$agent_type" "$task"

    # Create horizontal split: top pane for agent, bottom pane (15 lines) for shell
    # Split without size, then resize (workaround for detached session sizing issues)
    tmux split-window -t "$session_name" -v -c "$directory"
    tmux resize-pane -t "$session_name:.{bottom}" -y 15

    # Select top pane for the agent
    tmux select-pane -t "$session_name:.{top}"

    # Launch the agent in the top pane
    local full_cmd="$agent_cmd"
    if [[ ${#agent_args[@]} -gt 0 ]]; then
        full_cmd="$agent_cmd ${agent_args[*]}"
    fi
    tmux_send_keys "$session_name:.{top}" "$full_cmd" Enter

    log_success "Created session: $session_name"
    echo "$session_name"
}

# Get display name for a session (for fzf listing)
# Usage: agent_display_name <session_name>
# Returns: "dirname/branch [type] (Xm ago)"
# Note: Title extraction moved to preview for faster startup
agent_display_name() {
    local session_name="$1"

    # Get all metadata fields in ONE jq call (critical for performance)
    local fields
    fields=$(jq -r --arg name "$session_name" \
        '.sessions[$name] | "\(.directory // "")\t\(.branch // "")\t\(.agent_type // "")"' \
        "$AM_REGISTRY" 2>/dev/null)

    local directory branch agent_type
    IFS=$'\t' read -r directory branch agent_type <<< "$fields"

    # Get activity from tmux
    local activity
    activity=$(tmux_get_activity "$session_name")
    local now
    now=$(epoch_now)
    local idle=0
    if [[ -n "$activity" ]]; then
        idle=$((now - activity))
    fi

    # Build display name
    local display=""

    # Directory basename
    if [[ -n "$directory" ]]; then
        display=$(dir_basename "$directory")
    else
        display="$session_name"
    fi

    # Add branch if available
    if [[ -n "$branch" ]]; then
        display="${display}/${branch}"
    fi

    # Add agent type
    display="${display} [${agent_type:-unknown}]"

    # Add activity
    display="${display} ($(format_time_ago "$idle"))"

    echo "$display"
}

# Get full info about a session for preview header
# Usage: agent_info <session_name>
agent_info() {
    local session_name="$1"

    # Get all metadata fields in one jq call
    local fields
    fields=$(jq -r --arg name "$session_name" \
        '.sessions[$name] | "\(.directory // "")\t\(.branch // "")\t\(.agent_type // "")\t\(.task // "")"' \
        "$AM_REGISTRY" 2>/dev/null)

    local directory branch agent_type task
    IFS=$'\t' read -r directory branch agent_type task <<< "$fields"

    # Get tmux info
    local activity created_ts
    activity=$(tmux_get_activity "$session_name")
    created_ts=$(tmux_get_created "$session_name")

    local now
    now=$(epoch_now)

    # Calculate times
    local running_time=0 idle_time=0
    if [[ -n "$created_ts" ]]; then
        running_time=$((now - created_ts))
    fi
    if [[ -n "$activity" ]]; then
        idle_time=$((now - activity))
    fi

    # Output info
    echo "Directory: ${directory:-unknown}"
    echo "Branch: ${branch:--}"
    echo "Agent: ${agent_type:-unknown}"
    echo "Running: $(format_duration "$running_time")"
    echo "Last active: $(format_time_ago "$idle_time")"
    if [[ -n "$task" ]]; then
        echo "Task: $task"
    fi
}

# Kill an agent session (tmux + registry cleanup)
# Usage: agent_kill <session_name>
agent_kill() {
    local session_name="$1"
    local rc=0

    tmux_kill_session "$session_name" || rc=$?

    # Always clean up registry (session might already be dead)
    registry_remove "$session_name"

    if [[ $rc -eq 0 ]]; then
        log_success "Killed session: $session_name"
    fi

    return $rc
}

# Kill all agent sessions
# Usage: agent_kill_all
agent_kill_all() {
    local session
    local count=0

    for session in $(tmux_list_am_sessions); do
        agent_kill "$session" && ((count++))
    done

    log_info "Killed $count sessions"
    echo "$count"
}
