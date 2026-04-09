# shellcheck shell=bash
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
# Replaces every / and . with -, matching Claude's own encoding.
# e.g. /Users/foo/code → -Users-foo-code
# Usage: _state_encode_dir <path>
_state_encode_dir() {
    echo "$1" | sed -E 's|[/.]|-|g'
}

# Return the path to the newest Claude session JSONL for a directory.
# Usage: _state_jsonl_path <dir>
# Returns: file path on stdout, or empty string if not found
_state_jsonl_path() {
    local dir="$1"
    # Resolve symlinks to match Claude's encoding (e.g. /tmp → /private/tmp)
    local resolved
    resolved=$(cd "$dir" 2>/dev/null && pwd -P) || resolved="$dir"
    local encoded project_dir
    encoded=$(_state_encode_dir "$resolved")
    project_dir="$HOME/.claude/projects/$encoded"
    [[ -d "$project_dir" ]] || return 0
    command ls -t "$project_dir"/*.jsonl 2>/dev/null | head -1
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

    # Find the last meaningful entry: assistant, user, or queue-operation.
    # Skip metadata entries (system, progress, file-history-snapshot, etc.)
    # that Claude appends after the actual conversation turn.
    local last_line
    last_line=$(tail -20 "$jsonl" 2>/dev/null \
        | grep -E '"type"\s*:\s*"(assistant|user|queue-operation)"' \
        | tail -1) || return 0
    [[ -n "$last_line" ]] || return 0

    # Extract all needed fields in a single jq call (avoids 4 separate process spawns)
    # Use pipe delimiter (not tab — bash read collapses consecutive tabs for empty fields)
    local entry_type stop_reason operation content_has_tool_result
    local _jsonl_fields
    _jsonl_fields=$(printf '%s' "$last_line" | jq -r '[
        (.type // ""),
        (.message.stop_reason // ""),
        (.operation // ""),
        (if (.message.content | arrays | map(select(.type == "tool_result")) | length > 0) then "yes" else "" end)
    ] | join("|")' 2>/dev/null || true)
    IFS='|' read -r entry_type stop_reason operation content_has_tool_result <<< "$_jsonl_fields"

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
            if [[ "$content_has_tool_result" == "yes" ]]; then echo "running"; fi
            ;;
        queue-operation)
            if [[ "$operation" == "enqueue" ]]; then echo "running"; fi
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
    last_line=$(tmux_capture_pane "$pane_target" 10 2>/dev/null \
        | sed -E 's/\x1b\[[0-9;]*[mGKHF]//g; s/\x1b\[?[0-9;]*[a-zA-Z]//g' \
        | grep -v '^[[:space:]]*$' | tail -1 || true)

    if printf '%s' "$last_line" \
            | grep -qE '(error:|fatal:|Error:|Fatal:|FAILED|non-zero exit|exit code [^0])'; then
        echo "dead"
    else
        echo "idle"
    fi
}

# Check whether the pane's foreground process is a bare shell (agent exited).
# Some agents (e.g. Claude) override process.title to a version string,
# so pane_current_command returns e.g. "2.1.69" instead of "claude".
# We check the pane PID: if it's a shell with no child processes, the agent
# has exited and we're back at the prompt.
# Usage: _state_pane_is_shell <session>
# Returns: 0 if shell, 1 otherwise
_state_pane_is_shell() {
    local session="$1"

    local pane_pid
    pane_pid=$(am_tmux display-message -p -t "${session}:.{top}" '#{pane_pid}' 2>/dev/null || true)
    [[ -z "$pane_pid" ]] && return 1

    local pane_proc
    pane_proc=$(ps -p "$pane_pid" -o comm= 2>/dev/null || true)
    case "${pane_proc:-}" in
        bash|zsh|sh|fish|dash|-bash|-zsh|-sh|-fish|-dash) ;;
        *) return 1 ;;
    esac

    # Pane PID is a shell. If it has no child processes, the agent has exited.
    if ! pgrep -P "$pane_pid" >/dev/null 2>&1; then
        return 0
    fi

    return 1
}

# Derive session state from tmux pane content.
# Usage: _state_from_pane <session> [agent_type] [--skip-alive-check]
# Returns: state string on stdout, or empty string if cannot determine
_state_from_pane() {
    local session="$1"
    local agent_type="${2:-}"
    local skip_alive="${3:-}"

    if [[ "$skip_alive" != "--skip-alive-check" ]]; then
        # Dead check
        if ! tmux_session_exists "$session"; then
            echo "dead"
            return
        fi

        if _state_pane_is_shell "$session"; then
            agent_classify_exit "$session"
            return
        fi
    fi

    # Capture and strip ANSI from last 40 lines
    local pane_target content
    pane_target=$(tmux_session_pane_target "$session" "agent") || { echo "running"; return; }
    content=$(tmux_capture_pane "$pane_target" 40 2>/dev/null \
        | sed -E 's/\x1b\[[0-9;]*[mGKHF]//g; s/\x1b\[?[0-9;]*[a-zA-Z]//g' \
        || true)

    # --- Permission prompts (checked first for all agents) ---

    # Claude permission patterns
    if printf '%s' "$content" | grep -qiE \
            'Do you want to (proceed|continue|make this edit|allow)\?|\[y/n\]|\(y/n/a/s\)|Allow .+ to (read|write|execute|run)\?'; then
        echo "waiting_permission"
        return
    fi

    # Codex permission patterns: command approval and edit approval dialogs
    # "Would you like to run the following command?"
    # "Would you like to make the following edits?"
    # Both end with "Press enter to confirm or esc to cancel"
    if printf '%s' "$content" | grep -qE \
            'Would you like to (run the following command|make the following edits)\?|Press enter to confirm or esc to cancel'; then
        echo "waiting_permission"
        return
    fi

    # --- Custom question prompts ---

    # Claude plan approval prompt ("Would you like to proceed?" with numbered options)
    if printf '%s' "$content" | grep -qE 'Would you like to proceed\?' \
       && printf '%s' "$content" | grep -qE '(auto mode|manually approve|Tell Claude what to change)'; then
        echo "waiting_custom"
        return
    fi

    # Claude /ask block
    if printf '%s' "$content" | grep -qE '^\s*/ask'; then
        echo "waiting_custom"
        return
    fi

    # --- Agent-specific running vs waiting_input ---

    if [[ "$agent_type" == "codex" ]]; then
        # Codex shows "• Working (Xs • esc to interrupt)" or "○ Working (Xs •..."
        # while busy. Absence of this indicator means it is waiting for input.
        if printf '%s' "$content" | grep -qE 'Working \([0-9]+s|esc to interrupt'; then
            echo "running"
        else
            echo "waiting_input"
        fi
        return
    fi

    # Claude: detect input prompt as waiting_input (fallback when JSONL unavailable)
    if [[ "$agent_type" == "claude" ]]; then
        # Claude shows ❯ (or >) at the start of a line when waiting for input,
        # plus a status line with token counts like "░░░░" or "███".
        # The (running) indicator means a tool is executing.
        if printf '%s' "$content" | grep -qE '\(running\)'; then
            echo "running"
        elif printf '%s' "$content" | grep -qE '(^|\s)❯\s*$'; then
            echo "waiting_input"
        else
            echo "running"
        fi
        return
    fi

    # Generic fallback: process is alive → conservative running
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

    if _state_pane_is_shell "$session"; then
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
    fi

    local agent_type
    agent_type=$(registry_get_field "$session" agent_type 2>/dev/null || true)

    # Check permission/custom prompts first via pane (applies to all agents)
    # Skip alive check — we already verified session exists and is not a bare shell above
    local pane_state
    pane_state=$(_state_from_pane "$session" "$agent_type" --skip-alive-check 2>/dev/null || true)
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

# Lean state detection for a single session.
# Skips session-existence check and registry reads; caller provides metadata.
# Usage: _agent_get_state_fast <session> <agent_type> <directory>
# Outputs: state string
_agent_get_state_fast() {
    local session="$1" agent_type="$2" dir="$3"

    # 1. Shell check — catches idle/dead quickly
    if _state_pane_is_shell "$session"; then
        agent_classify_exit "$session"
        return
    fi

    # 2. For Claude: try JSONL first (cheaper than pane capture)
    if [[ "$agent_type" == "claude" && -n "$dir" ]]; then
        local jsonl_state
        jsonl_state=$(_state_from_jsonl "$dir")
        if [[ -n "$jsonl_state" ]]; then
            # JSONL says waiting_input → done (no permission prompt can exist)
            if [[ "$jsonl_state" == "waiting_input" ]]; then
                echo "waiting_input"
                return
            fi
            # JSONL says running → still need to check pane for permission prompts
        fi
    fi

    # 3. Pane-based detection (permission prompts, agent-specific patterns)
    local pane_state
    pane_state=$(_state_from_pane "$session" "$agent_type" --skip-alive-check 2>/dev/null || true)
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
    local stable_polls_required="${AM_WAIT_STABLE_POLLS:-3}"
    local quiet_secs_required="${AM_WAIT_QUIET_SECS:-2}"

    if ! tmux_session_exists "$session"; then
        log_error "Session not found: $session" >&2
        echo "not_found"
        return 1
    fi

    local start elapsed state
    local last_match_state="" last_match_activity="" stable_polls=0
    start=$(date +%s)

    while true; do
        state=$(agent_get_state "$session")

        local matched=false
        local t
        local IFS=','
        for t in $target_states; do
            if [[ "$state" == "$t" ]]; then
                matched=true
                case "$state" in
                    waiting_input|waiting_permission|waiting_custom|idle)
                        local activity now quiet_age
                        activity=$(tmux_get_activity "$session")
                        now=$(date +%s)
                        quiet_age=0
                        [[ -n "$activity" ]] && quiet_age=$(( now - activity ))

                        if [[ "$state" == "$last_match_state" && "$activity" == "$last_match_activity" ]]; then
                            stable_polls=$((stable_polls + 1))
                        else
                            stable_polls=1
                            last_match_state="$state"
                            last_match_activity="$activity"
                        fi

                        if (( quiet_age >= quiet_secs_required && stable_polls >= stable_polls_required )); then
                            echo "$state"
                            return 0
                        fi
                        ;;
                    *)
                        echo "$state"
                        return 0
                        ;;
                esac
            fi
        done

        if ! $matched; then
            last_match_state=""
            last_match_activity=""
            stable_polls=0
        fi

        elapsed=$(( $(date +%s) - start ))
        if (( elapsed >= timeout_s )); then
            echo "timeout"
            return 3
        fi

        sleep 0.5
    done
}
