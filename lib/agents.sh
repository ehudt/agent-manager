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
# Usage: agent_launch <directory> [agent_type] [task_description] [agent_args...]
# Set _AM_LAUNCH_PROMPT before calling to pipe an initial prompt to the agent.
# Returns: session name on success, empty on failure
agent_launch() {
    local directory="$1"
    local agent_type
    agent_type=$(agent_normalize_type "${2:-claude}")
    local task="${3:-}"
    shift 3 2>/dev/null || shift $#
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

    # Strip am's own launch flags; everything else goes to the agent verbatim.
    local normalized_args=()
    local wants_shell=""
    local arg
    for arg in "${agent_args[@]}"; do
        case "$arg" in
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
    if [[ -n "${_AM_SESSION_NAME_OVERRIDE:-}" ]]; then
        session_name="$_AM_SESSION_NAME_OVERRIDE"
        _AM_SESSION_NAME_OVERRIDE=""
    else
        session_name=$(generate_session_name "$directory")
    fi

    # Create tmux session (with explicit dimensions for sizing workaround).
    # The pane env (AM_SESSION_NAME etc.) is seeded here via tmux -e; see
    # agent_pane_env for why it is never typed into the shell.
    local -a pane_env=()
    mapfile -t pane_env < <(agent_pane_env "$session_name" "$agent_type")
    if ! tmux_create_session "$session_name" "$directory" "${pane_env[@]}"; then
        log_error "Failed to create tmux session"
        return 1
    fi

    # Register session metadata. Status-bar refresh deferred to the single
    # am_refresh_sidebar_cache call at the end of agent_launch — running
    # status-bar in several places during launch was the dominant source of
    # new-session latency.
    registry_add "$session_name" "$directory" "$branch" "$agent_type" "$task"

    # Append to sessions log for restore support.
    if [[ "$agent_type" == "claude" || "$agent_type" == "codex" || "$agent_type" == "pi" || "$agent_type" == "cursor" ]]; then
        sessions_log_append "$session_name" "$directory" "$branch" "$agent_type" "$task"
    fi

    # The session starts agent-only: the shell panel is a collapsible pane
    # added on demand (prefix+` / `am shell`), or at the end of this launch
    # when --shell / the shell_pane config default asks for it.
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
    if [[ ${#agent_args[@]} -gt 0 ]]; then
        cmd_parts+=("${agent_args[@]}")
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

    tmux_send_keys "$session_name:.{top}" "$full_cmd" Enter

    # Clean up prompt temp file after agent starts (for stdin-piped agents).
    if [[ -n "$prompt_file" ]]; then
        ( sleep 5; rm -f "$prompt_file" ) >/dev/null 2>&1 &
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

    if [[ "$recovery_mode" != "1" ]]; then
        recovery_desired_upsert "$session_name" "$directory" "$agent_type" "$task" \
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

# Create the shell panel for an existing session: split below the agent in
# the session directory and wire env exports + log streaming. Reads session
# metadata from the registry, so it serves both launch (--shell) and
# on-demand opening (`am shell` / prefix+`). The new pane gets focus.
# Usage: agent_shell_pane_add <session_name>
agent_shell_pane_add() {
    local session_name="$1"

    local fields directory agent_type
    fields=$(registry_get_fields "$session_name" directory agent_type)
    IFS='|' read -r directory agent_type <<< "$fields"
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
    shell_pane=$(am_tmux split-window -t "$main_id" -v -c "$directory" "${env_flags[@]}" -P -F '#{pane_id}') || return 1
    am_tmux resize-pane -t "$shell_pane" -y 15
    # Two panes again: restore the pane-border sidebar divider.
    am_tmux set-option -w -u -t "$main_id" pane-border-status

    if am_stream_logs_enabled; then
        local log_dir="/tmp/am-logs/${session_name}"
        mkdir -p "$log_dir"
        tmux_pipe_pane "$shell_pane" "$log_dir/shell.log"
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
    sleep 0.1

    tmux_send_keys "$pane_target" Enter
}

# Get full info about a session for preview header
# Usage: agent_info <session_name>
agent_info() {
    local session_name="$1"

    local fields
    fields=$(registry_get_fields "$session_name" directory branch agent_type task)

    local directory branch agent_type task
    IFS='|' read -r directory branch agent_type task <<< "$fields"

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

    # Explicit close wins even if runtime teardown is interrupted.
    recovery_desired_remove "$session_name" 2>/dev/null || true

    # Bulk-read registry fields (one jq call instead of three)
    local agent_type dir created_at
    IFS='|' read -r agent_type dir created_at \
        <<< "$(registry_get_fields "$session_name" agent_type directory created_at)"

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
