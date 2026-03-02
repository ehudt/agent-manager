# agents.sh - Agent launcher functions

# Source dependencies if not already loaded
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
[[ -z "$AM_DIR" ]] && source "$SCRIPT_DIR/utils.sh"
[[ "$(type -t am_stream_logs_enabled)" != "function" ]] && source "$SCRIPT_DIR/config.sh"
[[ "$(type -t tmux_create_session)" != "function" ]] && source "$SCRIPT_DIR/tmux.sh"
[[ "$(type -t registry_add)" != "function" ]] && source "$SCRIPT_DIR/registry.sh"

# Supported agent types and their commands
declare -A AGENT_COMMANDS=(
    [claude]="claude"
    [codex]="codex"
    [gemini]="gemini"
)

# Get the permissive/sandbox-bypass flag for an agent type.
# Usage: agent_get_yolo_flag <type>
agent_get_yolo_flag() {
    local agent_type="$1"
    case "$agent_type" in
        claude) echo "--dangerously-skip-permissions" ;;
        codex) echo "--yolo" ;;
        *) echo "--yolo" ;;
    esac
}

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

# Check whether an agent supports git worktree isolation.
# Usage: agent_supports_worktree <type>
agent_supports_worktree() {
    local agent_type="$1"
    case "$agent_type" in
        claude|codex) return 0 ;;
        *) return 1 ;;
    esac
}

# Check whether an agent natively manages worktrees via its own CLI flag.
# Usage: agent_cli_manages_worktree <type>
agent_cli_manages_worktree() {
    local agent_type="$1"
    [[ "$agent_type" == "claude" ]]
}

# Return the repo-local directory used to store managed worktrees.
# Usage: agent_worktree_root <directory> <agent_type>
agent_worktree_root() {
    local directory="$1"
    local agent_type="$2"

    case "$agent_type" in
        claude) echo "$directory/.claude/worktrees" ;;
        codex) echo "$directory/.codex/worktrees" ;;
        *) return 1 ;;
    esac
}

# Create or reuse a repo-local git worktree for agents that rely on cwd isolation.
# Usage: agent_prepare_managed_worktree <directory> <agent_type> <worktree_name>
agent_prepare_managed_worktree() {
    local directory="$1"
    local agent_type="$2"
    local worktree_name="$3"
    local worktree_root worktree_path

    worktree_root=$(agent_worktree_root "$directory" "$agent_type") || return 1
    worktree_path="$worktree_root/$worktree_name"

    if git -C "$worktree_path" rev-parse --git-dir &>/dev/null; then
        echo "$worktree_path"
        return 0
    fi

    if [[ -e "$worktree_path" ]]; then
        log_error "Worktree path already exists and is not a git worktree: $worktree_path"
        return 1
    fi

    mkdir -p "$worktree_root"
    if ! git -C "$directory" worktree add --detach "$worktree_path" HEAD >/dev/null; then
        log_error "Failed to create git worktree: $worktree_path"
        return 1
    fi

    echo "$worktree_path"
}

# Refresh the tmux status bar from registry metadata.
# Usage: agent_refresh_tmux_status <session_name>
agent_refresh_tmux_status() {
    local session_name="$1"
    local fields
    fields=$(registry_get_fields "$session_name" directory branch worktree_path yolo_mode container_name)

    local directory branch worktree_path yolo_mode container_name
    IFS='|' read -r directory branch worktree_path yolo_mode container_name <<< "$fields"

    local worktree_label=""
    [[ -n "$worktree_path" ]] && worktree_label="$(basename "$worktree_path")"

    tmux_set_session_status "$session_name" "$directory" "$branch" "$worktree_label" "$yolo_mode" "${container_name:+true}"
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
# Usage: agent_launch <directory> [agent_type] [task_description] [worktree_name] [agent_args...]
# Returns: session name on success, empty on failure
agent_launch() {
    local directory="$1"
    local agent_type="${2:-claude}"
    local task="${3:-}"
    local worktree_name="${4:-}"
    shift 4 2>/dev/null || shift $#
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

    # Normalize permissive mode args to the target agent's expected flag.
    local normalized_args=()
    local wants_yolo=false
    local arg
    for arg in "${agent_args[@]}"; do
        case "$arg" in
            --yolo|--dangerously-skip-permissions)
                wants_yolo=true
                ;;
            *)
                normalized_args+=("$arg")
                ;;
        esac
    done

    if $wants_yolo; then
        normalized_args+=("$(agent_get_yolo_flag "$agent_type")")
    fi
    agent_args=("${normalized_args[@]}")

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

    local session_directory="$directory"
    local sandbox_directory="$directory"

    # Resolve worktree name
    local worktree_path=""
    if [[ -n "$worktree_name" ]]; then
        if ! agent_supports_worktree "$agent_type"; then
            log_warn "Worktree isolation is not supported for $agent_type, ignoring -w"
            worktree_name=""
        elif ! git -C "$directory" rev-parse --git-dir &>/dev/null; then
            log_warn "Not a git repo, ignoring -w"
            worktree_name=""
        else
            # Resolve __auto__ sentinel to am-hash name
            if [[ "$worktree_name" == "__auto__" ]]; then
                worktree_name="am-${session_name#am-}"
            fi

            if agent_cli_manages_worktree "$agent_type"; then
                worktree_path="$(agent_worktree_root "$directory" "$agent_type")/$worktree_name"
            else
                worktree_path=$(agent_prepare_managed_worktree "$directory" "$agent_type" "$worktree_name") || return 1
                session_directory="$worktree_path"
            fi
        fi
    fi

    # Create tmux session (with explicit dimensions for sizing workaround)
    if ! tmux_create_session "$session_name" "$session_directory"; then
        log_error "Failed to create tmux session"
        return 1
    fi

    # Register session metadata
    registry_add "$session_name" "$directory" "$branch" "$agent_type" "$task"
    registry_update "$session_name" "yolo_mode" "$wants_yolo"
    agent_refresh_tmux_status "$session_name"

    # Log to persistent history if task is known at launch
    if [[ -n "$task" ]]; then
        history_append "$directory" "$task" "$agent_type" "$branch"
    fi

    # Create horizontal split: top pane for agent, bottom pane (15 lines) for shell
    # Split without size, then resize (workaround for detached session sizing issues)
    tmux split-window -t "$session_name" -v -c "$session_directory"
    tmux resize-pane -t "$session_name:.{bottom}" -y 15

    # Select top pane for the agent
    tmux select-pane -t "$session_name:.{top}"

    # Set up log streaming if enabled
    if am_stream_logs_enabled; then
        local log_dir="/tmp/am-logs/${session_name}"
        mkdir -p "$log_dir"
        tmux_enable_pipe_pane "$session_name" ".{top}" "$log_dir/agent.log"
        tmux_enable_pipe_pane "$session_name" ".{bottom}" "$log_dir/shell.log"
        tmux_send_keys "$session_name:.{top}" "export AM_LOG_DIR='$log_dir'" Enter
        tmux_send_keys "$session_name:.{bottom}" "export AM_LOG_DIR='$log_dir'" Enter
    fi

    # Build the full agent command
    local full_cmd="$agent_cmd"
    if [[ -n "$worktree_name" ]] && agent_cli_manages_worktree "$agent_type"; then
        full_cmd="$full_cmd -w '$worktree_name'"
    fi
    if [[ ${#agent_args[@]} -gt 0 ]]; then
        full_cmd="$full_cmd ${agent_args[*]}"
    fi

    # Sandbox mode when permissive flags are active
    if $wants_yolo && command -v docker &>/dev/null; then
        sandbox_start "$session_name" "$sandbox_directory"
        registry_update "$session_name" "container_name" "$session_name"
        agent_refresh_tmux_status "$session_name"
        local attach_cmd
        attach_cmd=$(sandbox_attach_cmd "$session_name" "$session_directory")
        tmux_send_keys "$session_name:.{bottom}" "$attach_cmd && clear" Enter
        tmux_send_keys "$session_name:.{top}" "$attach_cmd && clear" Enter
        tmux_send_keys "$session_name:.{top}" "$full_cmd" Enter
    else
        tmux_send_keys "$session_name:.{top}" "$full_cmd" Enter
    fi

    # Background: wait for CLI-managed worktrees to appear, then cd shell pane into them.
    if [[ -n "$worktree_path" ]]; then
        registry_update "$session_name" "worktree_path" "$worktree_path"
        agent_refresh_tmux_status "$session_name"
        if [[ "$session_directory" != "$worktree_path" ]]; then
            (for _i in $(seq 1 20); do
                if [ -d "$worktree_path" ]; then
                    tmux send-keys -t "${session_name}:.{bottom}" "cd '$worktree_path'" Enter
                    break
                fi
                sleep 0.5
            done) >/dev/null 2>&1 &
        fi
    fi

    log_success "Created session: $session_name"
    echo "$session_name"
}

# Get display name for a session (for fzf listing)
# Usage: agent_display_name <session_name> [activity_ts]
# Returns: "dirname/branch [type] (Xm ago)"
# Pass activity_ts to avoid an extra tmux subprocess per session.
agent_display_name() {
    local session_name="$1"
    local activity="${2:-}"

    local fields
    fields=$(registry_get_fields "$session_name" directory branch agent_type task)

    local directory branch agent_type task
    IFS='|' read -r directory branch agent_type task <<< "$fields"

    # Use pre-fetched activity or fetch from tmux
    if [[ -z "$activity" ]]; then
        activity=$(tmux_get_activity "$session_name")
    fi
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

    # Add task/title if available
    if [[ -n "$task" ]]; then
        display="${display} ${task}"
    fi

    # Add activity
    display="${display} ($(format_time_ago "$idle"))"

    echo "$display"
}

# Get full info about a session for preview header
# Usage: agent_info <session_name>
agent_info() {
    local session_name="$1"

    local fields
    fields=$(registry_get_fields "$session_name" directory branch agent_type task worktree_path yolo_mode container_name)

    local directory branch agent_type task worktree_path yolo_mode container_name
    IFS='|' read -r directory branch agent_type task worktree_path yolo_mode container_name <<< "$fields"

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
    echo "Yolo: $([[ "$yolo_mode" == "true" ]] && echo yes || echo no)"
    echo "Sandbox: $([[ -n "$container_name" ]] && echo yes || echo no)"
    echo "Running: $(format_duration "$running_time")"
    echo "Last active: $(format_time_ago "$idle_time")"
    if [[ -n "$task" ]]; then
        echo "Task: $task"
    fi
    if [[ -n "$worktree_path" ]]; then
        echo "Worktree: $worktree_path"
    fi
}

# Kill an agent session (tmux + registry cleanup)
# Usage: agent_kill <session_name>
agent_kill() {
    local session_name="$1"
    local rc=0

    # Remove sandbox container if session had one
    local container_name
    container_name=$(registry_get_field "$session_name" "container_name")
    if [[ -n "$container_name" ]]; then
        sandbox_remove "$session_name"
    fi

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

    echo "$count"
}
