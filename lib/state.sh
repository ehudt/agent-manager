# state.sh - Session state detection
#
# Provides agent_get_state() and related helpers. State is derived on-demand
# by inspecting the Claude JSONL file (for Claude sessions) and/or tmux pane
# content. No persistent state is written.
#
# States: starting | running | waiting_input | waiting_permission |
#         waiting_custom | idle | dead

[[ -z "$AM_DIR" ]] && source "$(dirname "${BASH_SOURCE[0]}")/utils.sh"
[[ "$(type -t tmux_session_exists)" != "function" ]] && source "$(dirname "${BASH_SOURCE[0]}")/tmux.sh"
[[ "$(type -t registry_get_field)" != "function" ]] && source "$(dirname "${BASH_SOURCE[0]}")/registry.sh"

# ---------------------------------------------------------------------------
# JSONL helpers (Claude sessions)
# ---------------------------------------------------------------------------

# Encode a filesystem path as a Claude project directory name.
# Strips the leading slash then replaces every / and . with -.
# Usage: _state_encode_dir <path>
_state_encode_dir() {
    echo "$1" | sed -E 's|^/||; s|[/.]|-|g'
}

# Return the path to the newest Claude session JSONL for a directory.
# Usage: _state_jsonl_path <dir>
# Returns: file path on stdout, or empty string if not found
_state_jsonl_path() {
    local dir="$1"
    local encoded project_dir
    encoded=$(_state_encode_dir "$dir")
    project_dir="$HOME/.claude/projects/$encoded"
    [[ -d "$project_dir" ]] || return 0
    ls -t "$project_dir"/*.jsonl 2>/dev/null | head -1
}

# Check whether a JSONL file is stale (mtime older than 30 seconds).
# Usage: _state_jsonl_stale <path>
# Returns: exit 0 if stale, exit 1 if fresh
_state_jsonl_stale() {
    local path="$1"
    [[ -f "$path" ]] || return 0
    local mtime now
    mtime=$(stat -c %Y "$path" 2>/dev/null || stat -f %m "$path" 2>/dev/null) || return 0
    now=$(date +%s)
    (( now - mtime > 30 ))
}

# Derive session state from the Claude JSONL file.
# Usage: _state_from_jsonl <directory>
# Returns: state string on stdout, or empty string if cannot determine
_state_from_jsonl() {
    local dir="$1"
    local jsonl
    jsonl=$(_state_jsonl_path "$dir")
    [[ -n "$jsonl" && -f "$jsonl" ]] || return 0

    local last_line
    last_line=$(tail -1 "$jsonl" 2>/dev/null) || return 0
    [[ -n "$last_line" ]] || return 0

    local entry_type stop_reason operation content_has_tool_result
    entry_type=$(printf '%s' "$last_line" | jq -r '.type // empty' 2>/dev/null)
    stop_reason=$(printf '%s' "$last_line" | jq -r '.message.stop_reason // empty' 2>/dev/null)
    operation=$(printf '%s' "$last_line" | jq -r '.operation // empty' 2>/dev/null)
    content_has_tool_result=$(printf '%s' "$last_line" \
        | jq -r 'if (.message.content | arrays | map(select(.type == "tool_result")) | length > 0) then "yes" else "" end' \
        2>/dev/null || true)

    case "$entry_type" in
        assistant)
            case "$stop_reason" in
                end_turn)
                    echo "waiting_input"
                    ;;
                tool_use)
                    echo "running"
                    ;;
                "")
                    # stop_reason null: response streaming or crashed write
                    if _state_jsonl_stale "$jsonl"; then
                        return 0  # stale — caller falls back to pane
                    fi
                    echo "running"
                    ;;
                *)
                    echo "running"
                    ;;
            esac
            ;;
        user)
            # tool_result: tool ran, Claude is processing the result
            [[ "$content_has_tool_result" == "yes" ]] && echo "running"
            ;;
        queue-operation)
            [[ "$operation" == "enqueue" ]] && echo "running"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Pane helpers (all agent types)
# ---------------------------------------------------------------------------

# Classify a session as idle or dead when the agent process has exited.
# Usage: agent_classify_exit <session>
agent_classify_exit() {
    local session="$1"
    local pane_target
    pane_target=$(tmux_session_pane_target "$session" "agent") || { echo "dead"; return; }

    local last_line
    last_line=$(tmux_capture_pane "$pane_target" 2>/dev/null \
        | sed -E 's/\x1b\[[0-9;]*[mGKHF]//g; s/\x1b\[?[0-9;]*[a-zA-Z]//g' \
        | grep -v '^[[:space:]]*$' | tail -1 || true)

    if printf '%s' "$last_line" \
            | grep -qE '(error:|fatal:|Error:|Fatal:|FAILED|non-zero exit|exit code [^0])'; then
        echo "dead"
    else
        echo "idle"
    fi
}

# Derive session state from tmux pane content.
# Usage: _state_from_pane <session> [agent_type]
# Returns: state string on stdout, or empty string if cannot determine
_state_from_pane() {
    local session="$1"
    local agent_type="${2:-}"

    # Dead check
    if ! tmux_session_exists "$session"; then
        echo "dead"
        return
    fi

    local pane_cmd
    pane_cmd=$(tmux_pane_current_command "${session}:.{top}" 2>/dev/null || true)

    case "${pane_cmd:-}" in
        bash|zsh|sh|fish|dash)
            agent_classify_exit "$session"
            return
            ;;
    esac

    # Capture and strip ANSI from last 40 lines
    local pane_target content
    pane_target=$(tmux_session_pane_target "$session" "agent") || { echo "running"; return; }
    content=$(tmux_capture_pane "$pane_target" 2>/dev/null \
        | tail -40 \
        | sed -E 's/\x1b\[[0-9;]*[mGKHF]//g; s/\x1b\[?[0-9;]*[a-zA-Z]//g' \
        || true)

    # Permission prompts — highest priority, checked for all agents
    if printf '%s' "$content" | grep -qiE \
            'Do you want to (proceed|continue|make this edit|allow)\?|\[y/n\]|\(y/n/a/s\)|Allow .+ to (read|write|execute|run)\?'; then
        echo "waiting_permission"
        return
    fi

    # Custom question prompts
    if printf '%s' "$content" | grep -qE '^\s*/ask|\?\s*$'; then
        echo "waiting_custom"
        return
    fi

    # For non-Claude agents, determine running vs waiting_input from pane
    if [[ "$agent_type" != "claude" ]]; then
        if printf '%s' "$content" | grep -qE \
                '[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]|Working…|Thinking…|⎿ (Running|Reading|Writing|Executing)'; then
            echo "running"
        else
            echo "waiting_input"
        fi
        return
    fi

    # Claude fallback: process is alive → conservative running
    echo "running"
}

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

# Return the current state of a session.
# Usage: agent_get_state <session_name>
# Outputs one of: starting | running | waiting_input | waiting_permission |
#                 waiting_custom | idle | dead
agent_get_state() {
    local session="$1"

    # Fast dead check
    if ! tmux_session_exists "$session"; then
        echo "dead"
        return
    fi

    local pane_cmd
    pane_cmd=$(tmux_pane_current_command "${session}:.{top}" 2>/dev/null || true)

    case "${pane_cmd:-}" in
        bash|zsh|sh|fish|dash)
            # Shell running in agent pane: either still starting or already exited
            local created_at created_epoch now age
            created_at=$(registry_get_field "$session" created_at 2>/dev/null || true)
            if [[ -n "$created_at" ]]; then
                now=$(date +%s)
                created_epoch=$(date -d "$created_at" +%s 2>/dev/null \
                    || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$created_at" +%s 2>/dev/null \
                    || echo 0)
                age=$(( now - created_epoch ))
                if (( age < 5 )); then
                    echo "starting"
                    return
                fi
            fi
            agent_classify_exit "$session"
            return
            ;;
    esac

    local agent_type
    agent_type=$(registry_get_field "$session" agent_type 2>/dev/null || true)

    # Check permission/custom prompts first via pane (applies to all agents)
    local pane_state
    pane_state=$(_state_from_pane "$session" "$agent_type" 2>/dev/null || true)
    case "$pane_state" in
        waiting_permission|waiting_custom|dead|idle)
            echo "$pane_state"
            return
            ;;
    esac

    # For Claude: use JSONL as primary source
    if [[ "$agent_type" == "claude" ]]; then
        local dir jsonl_state
        dir=$(registry_get_field "$session" directory 2>/dev/null || true)
        if [[ -n "$dir" ]]; then
            jsonl_state=$(_state_from_jsonl "$dir")
            if [[ -n "$jsonl_state" ]]; then
                echo "$jsonl_state"
                return
            fi
        fi
    fi

    # Fall back to pane result (running or waiting_input)
    echo "${pane_state:-running}"
}

# Block until a session reaches one of the target states.
# Usage: agent_wait_state <session> [states] [timeout_seconds]
#   states: comma-separated list, default: waiting_input,waiting_permission,waiting_custom,idle,dead
#   timeout_seconds: default 600
# Outputs: matched state string, or "timeout"
# Exit codes: 0=matched, 1=session not found, 3=timeout
agent_wait_state() {
    local session="$1"
    local target_states="${2:-waiting_input,waiting_permission,waiting_custom,idle,dead}"
    local timeout_s="${3:-600}"

    if ! tmux_session_exists "$session"; then
        log_error "Session not found: $session" >&2
        echo "not_found"
        return 1
    fi

    local start elapsed state
    start=$(date +%s)

    while true; do
        state=$(agent_get_state "$session")

        local t
        local IFS=','
        for t in $target_states; do
            if [[ "$state" == "$t" ]]; then
                echo "$state"
                return 0
            fi
        done

        elapsed=$(( $(date +%s) - start ))
        if (( elapsed >= timeout_s )); then
            echo "timeout"
            return 3
        fi

        sleep 0.5
    done
}
