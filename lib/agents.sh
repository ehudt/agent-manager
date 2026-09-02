# shellcheck shell=bash
# agents.sh - Agent launcher functions

# Source dependencies if not already loaded
_AGENTS_LIB_DIR="${AM_LIB_DIR:-$(dirname "${BASH_SOURCE[0]}")}"
[[ -z "$AM_DIR" ]] && source "$_AGENTS_LIB_DIR/utils.sh"
[[ "$(type -t am_stream_logs_enabled)" != "function" ]] && source "$_AGENTS_LIB_DIR/config.sh"
[[ "$(type -t tmux_create_session)" != "function" ]] && source "$_AGENTS_LIB_DIR/tmux.sh"
[[ "$(type -t registry_add)" != "function" ]] && source "$_AGENTS_LIB_DIR/registry.sh"
[[ "$(type -t recovery_desired_upsert)" != "function" ]] && source "$_AGENTS_LIB_DIR/recovery.sh"

# Supported agent types and their commands
declare -A AGENT_COMMANDS=(
    [claude]="claude"
    [codex]="codex"
    [cursor]="agent"
    [pi]="pi"
)

# Normalize public aliases to the canonical registry/UI agent type.
# Usage: agent_normalize_type <type>
agent_normalize_type() {
    case "$1" in
        cursor-agent) echo "cursor" ;;
        *) echo "$1" ;;
    esac
}

# Check if an agent type accepts the initial prompt as a CLI argument.
# Codex, Cursor, and pi take [PROMPT] as a positional arg; Claude reads stdin.
_agent_prompt_as_arg() {
    case "$(agent_normalize_type "$1")" in
        codex|cursor|pi) return 0 ;;
        *) return 1 ;;
    esac
}

# Get the yolo mode flag for an agent type.
# Usage: agent_get_yolo_flag <type>
agent_get_yolo_flag() {
    local agent_type
    agent_type=$(agent_normalize_type "$1")
    case "$agent_type" in
        claude) echo "--dangerously-skip-permissions" ;;
        codex|cursor) echo "--yolo" ;;
        pi) echo "" ;;
        *) echo "--yolo" ;;
    esac
}

# Print the CLI args (one per line) that resume a conversation for an agent.
# Usage: agent_resume_args <agent_type> <session_id>
agent_resume_args() {
    local agent_type
    agent_type=$(agent_normalize_type "$1")
    local session_id="$2"
    case "$agent_type" in
        codex) printf '%s\n' "resume" "$session_id" ;;
        pi)    printf '%s\n' "--session" "$session_id" ;;
        *)     printf '%s\n' "--resume" "$session_id" ;;
    esac
}

# Get the command for an agent type
# Usage: agent_get_command <type>
agent_get_command() {
    local agent_type
    agent_type=$(agent_normalize_type "$1")
    echo "${AGENT_COMMANDS[$agent_type]-$agent_type}"
}

# Check if an agent type is supported
# Usage: agent_type_supported <type>
agent_type_supported() {
    local agent_type
    agent_type=$(agent_normalize_type "$1")
    [[ -n "${AGENT_COMMANDS[$agent_type]-}" ]]
}

# Check whether an agent supports git worktree isolation.
# Usage: agent_supports_worktree <type>
agent_supports_worktree() {
    local agent_type
    agent_type=$(agent_normalize_type "$1")
    case "$agent_type" in
        claude|codex|cursor|pi) return 0 ;;
        *) return 1 ;;
    esac
}

# Check whether an agent natively manages worktrees via its own CLI flag.
# Usage: agent_cli_manages_worktree <type>
agent_cli_manages_worktree() {
    local agent_type
    agent_type=$(agent_normalize_type "$1")
    [[ "$agent_type" == "claude" || "$agent_type" == "cursor" ]]
}

# Return the repo-local directory used to store managed worktrees.
# Usage: agent_worktree_root <directory> <agent_type>
agent_worktree_root() {
    local directory="$1"
    local agent_type
    agent_type=$(agent_normalize_type "$2")

    case "$agent_type" in
        claude) echo "$directory/.claude/worktrees" ;;
        codex) echo "$directory/.codex/worktrees" ;;
        cursor) echo "$HOME/.cursor/worktrees/$(dir_basename "$directory")" ;;
        pi) echo "$directory/.pi/worktrees" ;;
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
    if ! git -C "$directory" worktree add -b "$worktree_name" "$worktree_path" HEAD >/dev/null; then
        log_error "Failed to create git worktree: $worktree_path"
        return 1
    fi

    echo "$worktree_path"
}

# Return the pane target used for the agent process.
# Usage: agent_target_pane <session_name>
agent_target_pane() {
    local session_name="$1"
    echo "${session_name}:.{top}"
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
# Set _AM_LAUNCH_PROMPT before calling to pipe an initial prompt to the agent.
# Returns: session name on success, empty on failure
agent_launch() {
    local directory="$1"
    local agent_type
    agent_type=$(agent_normalize_type "${2:-claude}")
    local task="${3:-}"
    local worktree_name="${4:-}"
    shift 4 2>/dev/null || shift $#
    local agent_args=("$@")
    local initial_prompt="${_AM_LAUNCH_PROMPT:-}"
    local recovery_mode="${_AM_RECOVERY_MODE:-0}"
    local defer_sidebar_refresh="${_AM_DEFER_SIDEBAR_REFRESH:-0}"
    _AM_LAUNCH_PROMPT=""
    _AM_RECOVERY_MODE=0
    _AM_DEFER_SIDEBAR_REFRESH=0

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

    # Normalize yolo mode and sandbox args to the target agent's expected flags.
    local normalized_args=()
    local wants_yolo=false
    local wants_sandbox=false
    local wants_shell=""
    local sandbox_shares=()
    local recovery_shares=()
    local arg
    for arg in "${agent_args[@]}"; do
        case "$arg" in
            --yolo|--dangerously-skip-permissions)
                wants_yolo=true
                ;;
            --sandbox)
                wants_sandbox=true
                ;;
            --no-sandbox)
                wants_sandbox=false
                ;;
            --shell)
                wants_shell=true
                ;;
            --no-shell)
                wants_shell=false
                ;;
            *)
                normalized_args+=("$arg")
                ;;
        esac
    done
    if [[ -z "$wants_shell" ]]; then
        if am_shell_pane_enabled; then wants_shell=true; else wants_shell=false; fi
    fi

    if $wants_yolo; then
        local _yolo_flag
        _yolo_flag=$(agent_get_yolo_flag "$agent_type")
        [[ -n "$_yolo_flag" ]] && normalized_args+=("$_yolo_flag")
    fi
    agent_args=("${normalized_args[@]}")
    if declare -p AM_SANDBOX_SHARES >/dev/null 2>&1; then
        sandbox_shares=("${AM_SANDBOX_SHARES[@]}")
    fi

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
    if [[ -n "${_AM_SESSION_NAME_OVERRIDE:-}" ]]; then
        session_name="$_AM_SESSION_NAME_OVERRIDE"
        _AM_SESSION_NAME_OVERRIDE=""
    else
        session_name=$(generate_session_name "$directory")
    fi

    local session_directory="$directory"
    local sandbox_directory="$directory"

    # Resolve worktree name
    local worktree_path=""
    local worktree_ready_path=""
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
                if [[ "$agent_type" == "cursor" && "$wants_sandbox" == "true" ]]; then
                    local cursor_worktree_rel=".cursor/worktrees/$(dir_basename "$directory")/$worktree_name"
                    worktree_path="${SB_CONTAINER_HOME:-/home/ubuntu}/$cursor_worktree_rel"
                    worktree_ready_path="${SB_HOME_DIR:-$HOME/.agent-manager/sandbox-home}/$cursor_worktree_rel"
                else
                    worktree_path="$(agent_worktree_root "$directory" "$agent_type")/$worktree_name"
                    worktree_ready_path="$worktree_path"
                fi
            else
                worktree_path=$(agent_prepare_managed_worktree "$directory" "$agent_type" "$worktree_name") || return 1
                worktree_ready_path="$worktree_path"
                session_directory="$worktree_path"
            fi
        fi
    fi

    # Create tmux session (with explicit dimensions for sizing workaround).
    # The pane env (AM_SESSION_NAME etc.) is seeded here via tmux -e; see
    # agent_pane_env for why it is never typed into the shell.
    local -a pane_env=()
    mapfile -t pane_env < <(agent_pane_env "$session_name" "$agent_type")
    if ! tmux_create_session "$session_name" "$session_directory" "${pane_env[@]}"; then
        log_error "Failed to create tmux session"
        return 1
    fi

    # Register session metadata. Status-bar refresh deferred to the single
    # am_refresh_sidebar_cache call at the end of agent_launch — running
    # status-bar in three separate places during launch (here, after sandbox
    # start, after worktree create) was the dominant source of new-session
    # latency.
    registry_add "$session_name" "$directory" "$branch" "$agent_type" "$task" \
        "$wants_yolo" "$wants_sandbox"

    # Append to sessions log for restore support.
    if [[ "$agent_type" == "claude" || "$agent_type" == "codex" || "$agent_type" == "pi" || "$agent_type" == "cursor" ]]; then
        sessions_log_append "$session_name" "$directory" "$branch" "$agent_type" "$task"
    fi

    # The session starts agent-only: the shell panel is a collapsible pane
    # added on demand (prefix+` / `am shell`), or at the end of this launch
    # when --shell / the shell_pane config default asks for it — by then the
    # sandbox and worktree metadata it needs are registered.
    local _pane_title="${task:-$(dir_basename "$directory")}"
    _pane_title=$(truncate "$_pane_title" 60)
    am_tmux select-pane -t "$session_name:.{top}" -T "$_pane_title"

    # Set up log streaming if enabled (AM_LOG_DIR is already in the pane env)
    if am_stream_logs_enabled; then
        local log_dir="/tmp/am-logs/${session_name}"
        mkdir -p "$log_dir"
        tmux_enable_pipe_pane "$session_name" ".{top}" "$log_dir/agent.log"
    fi

    # Build the full agent command with shell-safe argument quoting.
    local -a cmd_parts=("$agent_cmd")
    if [[ -n "$worktree_name" ]] && agent_cli_manages_worktree "$agent_type"; then
        cmd_parts+=("-w" "$worktree_name")
    fi
    if [[ ${#agent_args[@]} -gt 0 ]]; then
        cmd_parts+=("${agent_args[@]}")
    fi
    if [[ "$agent_type" == "cursor" && "$wants_sandbox" == "true" ]]; then
        local has_cursor_sandbox_override=false
        for arg in "${agent_args[@]}"; do
            [[ "$arg" == --sandbox=* ]] && has_cursor_sandbox_override=true
        done
        if ! $has_cursor_sandbox_override; then
            # The outer Docker container is already the sandbox. Cursor's
            # nested bubblewrap sandbox is unreliable under dropped caps.
            cmd_parts+=("--sandbox" "disabled")
        fi
    fi

    local full_cmd="" quoted_part part
    for part in "${cmd_parts[@]}"; do
        printf -v quoted_part '%q' "$part"
        if [[ -n "$full_cmd" ]]; then
            full_cmd+=" "
        fi
        full_cmd+="$quoted_part"
    done

    # If there's an initial prompt, inject it into the launch command.
    # - Agents that accept a CLI prompt arg (codex): append to command args.
    # - Agents that accept piped stdin (claude): pipe a temp file into the command
    #   to avoid overflowing the kernel tty input buffer (~4096 bytes on macOS).
    local prompt_file=""
    if [[ -n "$initial_prompt" ]]; then
        if _agent_prompt_as_arg "$agent_type"; then
            local quoted_prompt
            printf -v quoted_prompt '%q' "$initial_prompt"
            full_cmd+=" $quoted_prompt"
        else
            prompt_file="/tmp/am-prompt-${session_name}"
            printf '%s\n' "$initial_prompt" > "$prompt_file"
            full_cmd="cat ${prompt_file@Q} | $full_cmd; rm -f ${prompt_file@Q}"
        fi
    fi

    # Sandbox mode (independent of yolo)
    if $wants_sandbox; then
        # Lazy-load sandbox.sh
        [[ "$(type -t sandbox_start)" != "function" ]] && source "$_AGENTS_LIB_DIR/sandbox.sh"
        local parsed_share share_host share_target share_mode
        while IFS= read -r parsed_share; do
            [[ -n "$parsed_share" ]] || continue
            IFS='|' read -r share_host share_target share_mode <<< "$parsed_share"
            recovery_shares+=("$share_host:$share_target:$share_mode")
        done < <(_sb_collect_share_specs "${sandbox_shares[@]}")
        if ! am_docker_available; then
            log_error "Sandbox requires Docker but docker is not available"
            tmux_kill_session "$session_name" 2>/dev/null
            registry_remove "$session_name"
            return 1
        fi
        sandbox_start "$session_name" "$sandbox_directory" "${sandbox_shares[@]}"
        registry_update "$session_name" "container_name" "$session_name"
        local exec_cmd
        exec_cmd=$(sandbox_exec_cmd "$session_name" "$session_directory" "$full_cmd" "$agent_type")
        tmux_send_keys "$session_name:.{top}" "$exec_cmd" Enter
    else
        tmux_send_keys "$session_name:.{top}" "$full_cmd" Enter
    fi

    # Clean up prompt temp file after agent starts (for stdin-piped agents).
    if [[ -n "$prompt_file" ]]; then
        ( sleep 5; rm -f "$prompt_file" ) >/dev/null 2>&1 &
    fi

    # Record worktree paths; the shell panel cds into them when it is opened
    # (agent_shell_pane_add reads these fields).
    if [[ -n "$worktree_path" ]]; then
        registry_update "$session_name" "worktree_path" "$worktree_path"
        if [[ -n "$worktree_ready_path" && "$worktree_ready_path" != "$worktree_path" ]]; then
            registry_update "$session_name" "worktree_host_path" "$worktree_ready_path"
        fi
    fi

    # Shell panel: open now when requested, otherwise leave the session
    # agent-only and drop the pane-border line so the agent keeps the full
    # window height (prefix+` / `am shell` opens the panel on demand).
    if $wants_shell; then
        agent_shell_pane_add "$session_name"
        am_tmux select-pane -t "$session_name:.{top}"
    else
        am_tmux set-option -w -t "$session_name:" pane-border-status off
    fi

    # zoxide's shell hook only observes cd events. tmux starts directly in the
    # target directory, so explicitly record successful session launches.
    if command -v zoxide &>/dev/null; then
        zoxide add -- "$directory" >/dev/null 2>&1 || true
    fi

    local effective_directory="${worktree_ready_path:-$session_directory}"
    local shares_json
    shares_json=$(printf '%s\n' "${recovery_shares[@]}" \
        | jq -Rsc 'split("\n") | map(select(length > 0))')
    if [[ "$recovery_mode" != "1" ]]; then
        recovery_desired_upsert "$session_name" "$directory" "$agent_type" "$task" \
            "$wants_yolo" "$wants_sandbox" "$worktree_name" "$effective_directory" \
            "$worktree_ready_path" "$shares_json" \
            || log_warn "Could not persist reboot recovery for $session_name"
    fi

    # Refresh sidebar metadata without keeping the launcher popup open. The
    # client-session-changed hook also refreshes after an attached launch; this
    # background refresh covers detached launches and other clients.
    if [[ "$defer_sidebar_refresh" != "1" ]]; then
        (am_refresh_sidebar_cache) >/dev/null 2>&1 &
    fi

    log_success "Created session: $session_name"
    echo "$session_name"
}

# Environment every am pane starts with (agent pane and shell panel alike),
# one VAR=VALUE per line. Seeded at pane creation through tmux -e rather than
# typed `export` lines: nothing lands in the shell's history (even a
# space-prefixed export lingers as zsh's most recent entry until the next
# command), the vars exist before the first prompt, and the state hooks can
# identify the session by AM_SESSION_NAME instead of the ambiguous cwd.
# Usage: agent_pane_env <session_name> <agent_type>
agent_pane_env() {
    local session_name="$1" agent_type="$2"
    local identity_dir
    identity_dir=$(_recovery_identity_dir)
    mkdir -p "$identity_dir"
    printf 'AM_SESSION_NAME=%s\n' "$session_name"
    printf 'AM_AGENT_TYPE=%s\n' "$agent_type"
    printf 'AM_IDENTITY_DIR=%s\n' "$identity_dir"
    if am_stream_logs_enabled; then
        printf 'AM_LOG_DIR=%s\n' "/tmp/am-logs/${session_name}"
    fi
}

# Allocate an isolated working directory for `am new -W` through the user's
# configured workspace command (`am config set workspace_cmd '...'`). The
# command runs via bash -c with AM_BRANCH exported (empty when no branch was
# requested) and must print the directory on stdout; its stderr passes
# through so progress output (fetching, cloning) reaches the user.
# Usage: agent_workspace_allocate [branch]
agent_workspace_allocate() {
    local branch="${1:-}"
    local cmd
    cmd=$(am_workspace_cmd)
    if [[ -z "$cmd" ]]; then
        log_error "No workspace command configured for -W"
        echo "Set one with, e.g.: am config set workspace_cmd 'wp allocate \${AM_BRANCH:+--branch \"\$AM_BRANCH\"}'" >&2
        return 1
    fi
    local dir
    if ! dir=$(AM_BRANCH="$branch" "${BASH:-bash}" -c "$cmd"); then
        log_error "Workspace command failed: $cmd"
        return 1
    fi
    if [[ -z "$dir" || ! -d "$dir" ]]; then
        log_error "Workspace command did not print an existing directory: ${dir:-<empty>}"
        return 1
    fi
    echo "$dir"
}

# Create the shell panel for an existing session: split below the agent,
# wire env exports + log streaming, enter the sandbox container when the
# session is sandboxed, and cd into the worktree once it exists. Reads
# session metadata from the registry, so it serves both launch (--shell)
# and on-demand opening (`am shell` / prefix+`). The new pane gets focus.
# Usage: agent_shell_pane_add <session_name>
agent_shell_pane_add() {
    local session_name="$1"

    local fields directory agent_type sandbox_mode worktree_path worktree_host_path
    fields=$(registry_get_fields "$session_name" directory agent_type sandbox_mode worktree_path worktree_host_path)
    IFS='|' read -r directory agent_type sandbox_mode worktree_path worktree_host_path <<< "$fields"
    if [[ -z "$directory" ]]; then
        log_error "Session not in registry: $session_name"
        return 1
    fi

    local main_id
    main_id=$(tmux_main_window_id "$session_name")
    if [[ -z "$main_id" ]]; then
        log_error "Session not found: $session_name"
        return 1
    fi

    # Split at the worktree when it is host-visible; a container-side
    # worktree path (cursor sandbox) is handled by the cd below instead.
    local split_dir="$directory"
    if [[ -n "$worktree_path" && -d "$worktree_path" ]]; then
        split_dir="$worktree_path"
    fi

    # Split without size, then resize (workaround for detached session sizing
    # issues). -P returns the new pane's %id — unambiguous for the follow-up
    # wiring even if the user rearranges panes.
    # Seed the pane env with tmux -e (explicit, so sessions created before
    # the session environment was populated get it too).
    local -a pane_env=() env_flags=()
    local kv
    mapfile -t pane_env < <(agent_pane_env "$session_name" "$agent_type")
    for kv in "${pane_env[@]}"; do
        env_flags+=(-e "$kv")
    done
    local shell_pane
    shell_pane=$(am_tmux split-window -t "$main_id" -v -c "$split_dir" "${env_flags[@]}" -P -F '#{pane_id}') || return 1
    am_tmux resize-pane -t "$shell_pane" -y 15
    # Two panes again: restore the pane-border sidebar divider.
    am_tmux set-option -w -u -t "$main_id" pane-border-status

    if am_stream_logs_enabled; then
        local log_dir="/tmp/am-logs/${session_name}"
        mkdir -p "$log_dir"
        tmux_pipe_pane "$shell_pane" "$log_dir/shell.log"
    fi

    if am_bool_is_true "$sandbox_mode"; then
        [[ "$(type -t sandbox_enter_cmd)" != "function" ]] && source "$_AGENTS_LIB_DIR/sandbox.sh"
        local attach_cmd
        attach_cmd=$(sandbox_enter_cmd "$session_name" "$split_dir")
        tmux_send_keys "$shell_pane" "$attach_cmd" Enter
    fi

    # Background: wait for a CLI-managed worktree to appear, then cd into it
    # (inside the container shell for sandboxed sessions).
    if [[ -n "$worktree_path" && "$split_dir" != "$worktree_path" ]]; then
        local ready_path="${worktree_host_path:-$worktree_path}"
        (for _i in $(seq 1 20); do
            if [ -d "$ready_path" ]; then
                am_tmux send-keys -t "$shell_pane" "cd '$worktree_path'" Enter
                break
            fi
            sleep 0.5
        done) >/dev/null 2>&1 &
    fi
}

# Toggle the shell panel: create it on first use, park it when open,
# rejoin it when hidden.
# Usage: agent_shell_pane_toggle <session_name>
agent_shell_pane_toggle() {
    local session_name="$1"
    case "$(tmux_shell_pane_state "$session_name")" in
        open) tmux_shell_pane_hide "$session_name" ;;
        hidden) tmux_shell_pane_show "$session_name" ;;
        *) agent_shell_pane_add "$session_name" ;;
    esac
}

# Send a prompt to a running agent session.
# Usage: agent_send_prompt <session_name> <prompt>
agent_send_prompt() {
    local session_name="$1"
    local prompt="$2"

    if [[ -z "$prompt" ]]; then
        log_error "Prompt cannot be empty"
        return 1
    fi

    if ! tmux_session_exists "$session_name"; then
        log_error "Session not found: $session_name"
        return 1
    fi

    local pane_target
    pane_target=$(agent_target_pane "$session_name")

    tmux_paste_text "$pane_target" "$prompt"

    # TUI agents (Codex) need a brief pause between paste and Enter —
    # without it, Enter arrives before the TUI finishes processing the
    # pasted text and gets interpreted as a newline instead of submit.
    # Sandboxed sessions need a longer delay due to the extra docker PTY layer.
    if [[ -n "$(registry_get_field "$session_name" container_name)" ]]; then
        sleep 0.3
    else
        sleep 0.1
    fi

    tmux_send_keys "$pane_target" Enter
}

# Get full info about a session for preview header
# Usage: agent_info <session_name>
agent_info() {
    local session_name="$1"

    local fields
    fields=$(registry_get_fields "$session_name" directory branch agent_type task worktree_path worktree_host_path yolo_mode container_name)

    local directory branch agent_type task worktree_path worktree_host_path yolo_mode container_name
    IFS='|' read -r directory branch agent_type task worktree_path worktree_host_path yolo_mode container_name <<< "$fields"

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
    echo "Session: $session_name"
    echo "Directory: ${directory:-unknown}"
    echo "Branch: ${branch:--}"
    echo "Agent: ${agent_type:-unknown}"
    echo "Yolo: $([[ "$yolo_mode" == "true" ]] && echo yes || echo no)"
    echo "Sandbox: $([[ -n "$container_name" ]] && echo yes || echo no)"
    if [[ -n "$container_name" ]]; then
        echo "Sandbox log: $AM_DIR/logs/$session_name/sandbox.log"
    fi
    echo "Running: $(format_duration "$running_time")"
    echo "Last active: $(format_time_ago "$idle_time")"
    if [[ -n "$task" ]]; then
        echo "Task: $task"
    fi
    if [[ -n "$worktree_path" ]]; then
        echo "Worktree: $worktree_path"
        [[ -n "$worktree_host_path" ]] && echo "Worktree (host): $worktree_host_path"
    fi
}

# Kill an agent session (tmux + registry cleanup)
# Usage: agent_kill <session_name>
agent_kill() {
    local session_name="$1"
    local rc=0

    # Explicit close wins even if runtime teardown is interrupted.
    recovery_desired_remove "$session_name" 2>/dev/null || true

    # Bulk-read registry fields (one jq call instead of four)
    local agent_type dir created_at container_name
    IFS='|' read -r agent_type dir created_at container_name \
        <<< "$(registry_get_fields "$session_name" agent_type directory created_at container_name)"

    # Final snapshot + close timestamp for session restore (before killing tmux)
    if [[ ( "$agent_type" == "claude" || "$agent_type" == "codex" || "$agent_type" == "pi" || "$agent_type" == "cursor" ) ]] && tmux_session_exists "$session_name"; then
        # Bind the conversation id: sidecar (authoritative) → already-logged
        # sid → guarded directory detection. A kill-time guess must never
        # overwrite a binding established while hooks were alive.
        local sid transcript=""
        if [[ "$agent_type" == "cursor" ]]; then
            transcript=$(_sessions_log_sidecar_transcript "$session_name" 2>/dev/null || true)
            [[ -z "$transcript" ]] && transcript=$(_sessions_log_field "$session_name" "transcript_path" 2>/dev/null || true)
            [[ -n "$transcript" ]] && sessions_log_update "$session_name" "transcript_path" "$transcript"
        fi
        sid=$(_sessions_log_sidecar_id "$session_name" 2>/dev/null || true)
        if [[ -n "$sid" ]] && ! _sessions_log_jsonl_exists "$dir" "$sid" "$agent_type" "$transcript"; then
            sid=""
        fi
        if [[ -z "$sid" ]]; then
            sid=$(_sessions_log_field "$session_name" "session_id" 2>/dev/null || true)
        fi
        if [[ -z "$sid" ]]; then
            sid=$(_sessions_log_detect_id_for_session "$session_name" "$dir" "$created_at" "$agent_type" 2>/dev/null || true)
        fi
        local snap_file
        if [[ -n "$sid" ]]; then
            sessions_log_update "$session_name" "session_id" "$sid"
            snap_file=$(sessions_log_snapshot "$session_name" "$sid")
        else
            snap_file=$(sessions_log_snapshot "$session_name" "$session_name")
        fi
        [[ -n "$snap_file" ]] && sessions_log_update "$session_name" "snapshot_file" "$snap_file"
        local closed_at
        closed_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        sessions_log_update "$session_name" "closed_at" "$closed_at"
    fi

    # Remove sandbox container if session had one
    if [[ -n "$container_name" ]]; then
        [[ "$(type -t sandbox_remove)" != "function" ]] && source "$_AGENTS_LIB_DIR/sandbox.sh"
        sandbox_remove "$session_name"
    fi

    tmux_kill_session "$session_name" || rc=$?

    # Always clean up registry and hook state file
    registry_remove "$session_name"
    rm -f "${AM_STATE_DIR:-/tmp/am-state}/$session_name" \
          "${AM_STATE_DIR:-/tmp/am-state}/$session_name.sid" \
          "${AM_STATE_DIR:-/tmp/am-state}/$session_name.transcript" \
          "$(_recovery_identity_dir)/$session_name.sid" \
          "$(_recovery_identity_dir)/$session_name.transcript" \
          "$(_recovery_identity_dir)/$session_name.rebind"

    # Rebuild sidebar cache for surviving sessions so the killed entry
    # disappears from every pane-border immediately.
    am_refresh_sidebar_cache

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
