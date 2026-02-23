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

    # Resolve worktree name
    local worktree_path=""
    if [[ -n "$worktree_name" ]]; then
        if [[ "$agent_type" != "claude" ]]; then
            log_warn "Worktree isolation only supported for Claude, ignoring -w"
            worktree_name=""
        elif ! git -C "$directory" rev-parse --git-dir &>/dev/null; then
            log_warn "Not a git repo, ignoring -w"
            worktree_name=""
        else
            # Resolve __auto__ sentinel to am-hash name
            if [[ "$worktree_name" == "__auto__" ]]; then
                worktree_name="am-${session_name#am-}"
            fi
            worktree_path="$directory/.claude/worktrees/$worktree_name"
        fi
    fi

    # Create tmux session (with explicit dimensions for sizing workaround)
    if ! tmux_create_session "$session_name" "$directory"; then
        log_error "Failed to create tmux session"
        return 1
    fi

    # Register session metadata
    registry_add "$session_name" "$directory" "$branch" "$agent_type" "$task"

    # Log to persistent history if task is known at launch
    if [[ -n "$task" ]]; then
        history_append "$directory" "$task" "$agent_type" "$branch"
    fi

    # Create horizontal split: top pane for agent, bottom pane (15 lines) for shell
    # Split without size, then resize (workaround for detached session sizing issues)
    tmux split-window -t "$session_name" -v -c "$directory"
    tmux resize-pane -t "$session_name:.{bottom}" -y 15

    # Select top pane for the agent
    tmux select-pane -t "$session_name:.{top}"

    # Set up log streaming if enabled
    if [[ "${AM_STREAM_LOGS:-}" == "1" ]]; then
        local log_dir="/tmp/am-logs/${session_name}"
        mkdir -p "$log_dir"
        tmux_enable_pipe_pane "$session_name" ".{top}" "$log_dir/agent.log"
        tmux_enable_pipe_pane "$session_name" ".{bottom}" "$log_dir/shell.log"
        tmux_send_keys "$session_name:.{top}" "export AM_LOG_DIR='$log_dir'" Enter
        tmux_send_keys "$session_name:.{bottom}" "export AM_LOG_DIR='$log_dir'" Enter
    fi

    # Build the full agent command
    local full_cmd="$agent_cmd"
    if [[ -n "$worktree_name" ]]; then
        full_cmd="$full_cmd -w '$worktree_name'"
    fi
    if [[ ${#agent_args[@]} -gt 0 ]]; then
        full_cmd="$full_cmd ${agent_args[*]}"
    fi

    # Check if sandbox mode is needed (--yolo/permissive mode implies sandbox)
    local use_sandbox=false
    for arg in "${agent_args[@]}"; do
        if [[ "$arg" == "--dangerously-skip-permissions" || "$arg" == "--yolo" ]]; then
            use_sandbox=true
            break
        fi
    done

    if $use_sandbox && command -v sb &>/dev/null; then
        # Start sandbox once, then attach both panes to it
        sb "$directory" --start >&2
        tmux_send_keys "$session_name:.{bottom}" "sb . --attach && clear" Enter
        tmux_send_keys "$session_name:.{top}" "sb . --attach && clear" Enter
        tmux_send_keys "$session_name:.{top}" "$full_cmd" Enter
    else
        tmux_send_keys "$session_name:.{top}" "$full_cmd" Enter
    fi

    # Background: wait for worktree directory to appear, then cd shell pane into it
    if [[ -n "$worktree_path" ]]; then
        (for _i in $(seq 1 20); do
            if [ -d "$worktree_path" ]; then
                tmux send-keys -t "${session_name}:.{bottom}" "cd '$worktree_path'" Enter
                break
            fi
            sleep 0.5
        done) >/dev/null 2>&1 &
        registry_update "$session_name" "worktree_path" "$worktree_path"
    fi

    # Auto-title in background (Claude only, no task already set)
    if [[ "$agent_type" == "claude" && -z "$task" ]]; then
        auto_title_session "$session_name" "$directory"
    fi

    log_success "Created session: $session_name"
    echo "$session_name"
}

# Generate a session title from first user message using Haiku
# Runs in background, updates registry when done
# Usage: auto_title_session <session_name> <directory>
auto_title_session() {
    local session_name="$1"
    local directory="$2"

    (
        # Disable errexit+pipefail inherited from am's set -euo pipefail.
        # Without this, grep returning no matches (no user messages yet)
        # kills the subshell via errexit+pipefail before we can retry.
        set +e +o pipefail

        # Wait for Claude session to start and receive first message
        sleep 5

        # Convert directory to Claude's project path format
        local abs_dir
        abs_dir=$(cd "$directory" && pwd)
        local project_path="${abs_dir//\//-}"
        project_path="${project_path//./-}"
        local claude_project_dir="$HOME/.claude/projects/$project_path"

        # Poll for JSONL content - extract first real user message
        local first_msg=""
        for _i in $(seq 1 30); do
            if [[ -d "$claude_project_dir" ]]; then
                local session_file
                session_file=$(command ls -t "$claude_project_dir"/*.jsonl 2>/dev/null | head -1)
                if [[ -n "$session_file" && -f "$session_file" ]]; then
                    # Extract text from user messages; content can be string or array
                    first_msg=$(grep '"type":"user"' "$session_file" 2>/dev/null | head -10 | \
                        jq -r '
                            .message.content |
                            if type == "string" then .
                            elif type == "array" then
                                [.[] | select(.type == "text") | .text] | join(" ")
                            else empty
                            end
                        ' 2>/dev/null | \
                        sed 's/<[^>]*>[^<]*<\/[^>]*>//g; s/<[^>]*>//g' | \
                        tr '\n' ' ' | \
                        sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | \
                        head -c 500)
                    # Only accept if we got meaningful text
                    [[ ${#first_msg} -gt 10 ]] || first_msg=""
                fi
            fi
            [[ -n "$first_msg" ]] && break
            sleep 2
        done

        [[ -z "$first_msg" ]] && return 0

        # Truncate input to ~200 chars to keep Haiku call cheap
        first_msg="${first_msg:0:200}"

        # Try Haiku for a clean title
        local title=""
        if command -v claude &>/dev/null; then
            title=$(printf '%s' "$first_msg" | claude -p --model haiku \
                "Reply with a short 2-5 word title summarizing this task. Plain text only, no markdown, no quotes, no punctuation. Examples: Fix auth login bug, Add user settings page, Refactor database layer" 2>/dev/null) || true
            # Strip any markdown/quotes Haiku might add despite instructions
            title=$(echo "$title" | sed 's/^[#*"`'\'']*//; s/[#*"`'\'']*$//' | tr -d '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            # Reject if too long or multiline (Haiku went off-script)
            if [[ ${#title} -gt 60 || "$title" == *$'\n'* ]]; then
                title=""
            fi
        fi

        # Fallback: first sentence, cleaned up
        if [[ -z "$title" ]]; then
            title=$(echo "$first_msg" | sed 's/https\?:\/\/[^ ]*//g; s/  */ /g; s/[.?!].*//' | head -c 60)
        fi

        # Write to registry
        if [[ -n "$title" ]]; then
            source "$(dirname "${BASH_SOURCE[0]}")/utils.sh"
            source "$(dirname "${BASH_SOURCE[0]}")/registry.sh"
            registry_update "$session_name" "task" "$title"
            # Log to persistent history
            local dir branch agent
            dir=$(registry_get_field "$session_name" "directory")
            branch=$(registry_get_field "$session_name" "branch")
            agent=$(registry_get_field "$session_name" "agent_type")
            history_append "$dir" "$title" "$agent" "$branch"
        fi
    ) >/dev/null 2>&1 &
}

# Get display name for a session (for fzf listing)
# Usage: agent_display_name <session_name>
# Returns: "dirname/branch [type] (Xm ago)"
# Note: Title extraction moved to preview for faster startup
agent_display_name() {
    local session_name="$1"

    # Get all metadata fields in ONE jq call (critical for performance)
    # Use pipe delimiter (not tab) because bash read collapses consecutive tab delimiters
    local fields
    fields=$(jq -r --arg name "$session_name" \
        '.sessions[$name] | "\(.directory // "")|\(.branch // "")|\(.agent_type // "")|\(.task // "")"' \
        "$AM_REGISTRY" 2>/dev/null)

    local directory branch agent_type task
    IFS='|' read -r directory branch agent_type task <<< "$fields"

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

    # Get all metadata fields in one jq call
    # Use pipe delimiter (not tab) because bash read collapses consecutive tab delimiters
    local fields
    fields=$(jq -r --arg name "$session_name" \
        '.sessions[$name] | "\(.directory // "")|\(.branch // "")|\(.agent_type // "")|\(.task // "")|\(.worktree_path // "")"' \
        "$AM_REGISTRY" 2>/dev/null)

    local directory branch agent_type task worktree_path
    IFS='|' read -r directory branch agent_type task worktree_path <<< "$fields"

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
    if [[ -n "$worktree_path" ]]; then
        echo "Worktree: $worktree_path"
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

    echo "$count"
}
