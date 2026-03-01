# fzf.sh - fzf interface functions

# Source dependencies if not already loaded
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
[[ -z "$AM_DIR" ]] && source "$SCRIPT_DIR/utils.sh"
[[ "$(type -t am_default_agent)" != "function" ]] && source "$SCRIPT_DIR/config.sh"
[[ "$(type -t tmux_list_am_sessions)" != "function" ]] && source "$SCRIPT_DIR/tmux.sh"
[[ "$(type -t registry_get_field)" != "function" ]] && source "$SCRIPT_DIR/registry.sh"
[[ "$(type -t agent_display_name)" != "function" ]] && source "$SCRIPT_DIR/agents.sh"

# Ensure fzf is available
require_cmd fzf

# Helper: List directories for picker (frecent + git repos)
_list_directories() {
    local query="${1:-}"

    # If query looks like a path, show completions for that path
    if [[ "$query" == /* || "$query" == ~* || "$query" == .* ]]; then
        local base_path="${query/#\~/$HOME}"
        # If it's a directory, show its contents
        if [[ -d "$base_path" ]]; then
            find "$base_path" -maxdepth 1 -type d 2>/dev/null | grep -v "^$base_path$" | sort
        else
            # Show parent directory contents that match
            local parent_dir=$(dirname "$base_path")
            local prefix=$(basename "$base_path")
            if [[ -d "$parent_dir" ]]; then
                find "$parent_dir" -maxdepth 1 -type d -name "${prefix}*" 2>/dev/null | sort
            fi
        fi
        return
    fi

    # Build raw path list
    local paths=()
    paths+=("$(pwd)")

    if command -v zoxide &>/dev/null; then
        while IFS= read -r p; do
            paths+=("$p")
        done < <(zoxide query -l 2>/dev/null | head -30)
    fi

    local search_paths=("$HOME/code" "$HOME/projects" "$HOME/src" "$HOME/dev" "$HOME/work")
    for search_path in "${search_paths[@]}"; do
        if [[ -d "$search_path" ]]; then
            while IFS= read -r p; do
                paths+=("$p")
            done < <(find "$search_path" -maxdepth 3 -type d -name ".git" 2>/dev/null | sed 's/\/\.git$//' | head -20)
        fi
    done

    # Deduplicate preserving order
    local -A seen
    local unique_paths=()
    for p in "${paths[@]}"; do
        if [[ -z "${seen[$p]:-}" ]]; then
            seen[$p]=1
            unique_paths+=("$p")
        fi
    done

    # Output with annotations
    for p in "${unique_paths[@]}"; do
        local annotation
        annotation=$(_annotate_directory "$p")
        if [[ -n "$annotation" ]]; then
            printf '%s\t%s\n' "$p" "$annotation"
        else
            echo "$p"
        fi
    done
}

# Annotate a directory path with recent session history
# Usage: _annotate_directory <path>
# Returns: annotation string like 'claude: "Task" (2h) | gemini: "Task2" (1d)' or empty
_annotate_directory() {
    local dir_path="$1"
    [[ -f "$AM_HISTORY" ]] || return 0

    local entries
    entries=$(history_for_directory "$dir_path" | head -3)
    [[ -z "$entries" ]] && return 0

    local parts=()
    local now
    now=$(date +%s)

    while IFS= read -r line; do
        local task agent created_at
        IFS=$'\t' read -r task agent created_at <<< "$(echo "$line" | jq -r '[.task, .agent_type, .created_at] | @tsv')"

        # Calculate relative time
        local ts
        ts=$(date -jf "%Y-%m-%dT%H:%M:%SZ" "$created_at" +%s 2>/dev/null || \
             date -d "$created_at" +%s 2>/dev/null || echo "$now")
        local age=$(( now - ts ))
        local age_str
        if (( age < 3600 )); then
            age_str="$(( age / 60 ))m"
        elif (( age < 86400 )); then
            age_str="$(( age / 3600 ))h"
        else
            age_str="$(( age / 86400 ))d"
        fi

        # Truncate task to 30 chars
        task=$(truncate "$task" 30)

        parts+=("${agent}: ${task} (${age_str})")
    done <<< "$entries"

    local IFS='|'
    echo " ${parts[*]}"
}

# Strip annotation from a picker line, returning just the path
# Usage: _strip_annotation <line>
_strip_annotation() {
    local line="$1"
    # Tab separates path from annotation; if no tab, line is the path
    echo "$line" | cut -f1
}

# Pick a directory using fzf with interactive path completion
# Usage: fzf_pick_directory
# Returns: selected directory path or empty if cancelled
fzf_pick_directory() {
    # Export helpers for fzf reload
    export -f _list_directories
    export -f _annotate_directory
    export -f _strip_annotation
    export -f history_for_directory
    export AM_HISTORY

    local initial_list
    initial_list=$(_list_directories | grep -v '^$')

    # Run fzf with dynamic completion
    local selected
    selected=$(echo "$initial_list" | fzf \
        --ansi \
        --header="Directory: type path or select  |  Tab: complete  |  Ctrl-U: parent dir" \
        --preview='d="{}"; d=$(echo "$d" | cut -f1); d="${d/#\~/$HOME}"; if [[ -d "$d" ]]; then echo "── Recent Sessions ──"; if [[ -f "'"$AM_HISTORY"'" ]]; then jq -r --arg dir "$d" "select(.directory == \$dir) | \"\(.agent_type): \(.task) [\(.branch)]\"" "'"$AM_HISTORY"'" 2>/dev/null | tail -r 2>/dev/null || tac 2>/dev/null || cat | head -5; else echo "(no history)"; fi; echo ""; echo "── Files ──"; command ls -la "$d" 2>/dev/null | head -15; else echo "Type a path or select from list"; fi' \
        --preview-window="right:40%:wrap" \
        --print-query \
        --bind="tab:reload(bash -c '_list_directories {q}' | grep -v '^$')+clear-query" \
        --bind="ctrl-u:reload(bash -c '_list_directories \$(dirname {q})' | grep -v '^$')+transform-query(dirname {q})" \
    )

    # Parse result - fzf --print-query outputs: query on line 1, selection on line 2
    local query selection
    query=$(echo "$selected" | head -n1)
    selection=$(echo "$selected" | tail -n1)

    # Strip annotation (everything after tab)
    selection=$(_strip_annotation "$selection")
    query=$(_strip_annotation "$query")

    # If selection is empty but query exists, use query as typed path
    if [[ -z "$selection" && -n "$query" ]]; then
        selection="$query"
    fi

    # Expand ~ if present
    selection="${selection/#\~/$HOME}"

    # Validate directory exists
    if [[ -n "$selection" && -d "$selection" ]]; then
        echo "$selection"
    elif [[ -n "$selection" ]]; then
        log_error "Directory does not exist: $selection" >&2
        echo ""
    else
        echo ""
    fi
}

# Pick session mode (new/resume/continue)
# Usage: fzf_pick_mode
# Returns: flags string, or empty if cancelled
fzf_mode_options() {
    local default_yolo="${1:-false}"
    if [[ "$default_yolo" == "true" ]]; then
        cat <<'EOF'
New session (--yolo)
Resume (--resume --yolo)
Continue (--continue --yolo)
New session
Resume (--resume)
Continue (--continue)
EOF
    else
        cat <<'EOF'
New session
Resume (--resume)
Continue (--continue)
New session (--yolo)
Resume (--resume --yolo)
Continue (--continue --yolo)
EOF
    fi
}

fzf_pick_mode() {
    local default_yolo="${1:-false}"
    local options
    options=$(fzf_mode_options "$default_yolo")

    local selected
    selected=$(echo "$options" | fzf \
        --ansi \
        --no-multi \
        --header="Select mode (Enter to confirm, Esc to cancel)" \
        --height=11 \
        --layout=reverse \
    )

    # If cancelled (empty selection), return empty
    if [[ -z "$selected" ]]; then
        echo ""
        return 1
    fi

    local flags=""

    case "$selected" in
        *--resume*) flags+=" --resume" ;;
        *--continue*) flags+=" --continue" ;;
    esac

    if [[ "$selected" == *--yolo* ]]; then
        flags+=" --yolo"
    fi

    echo "$flags"
}

# Pick agent type for a new session
# Usage: fzf_pick_agent
# Returns: selected agent type, or empty if cancelled
fzf_agent_options() {
    local default_agent="${1:-}"
    local options=()
    local agent

    if [[ -n "$default_agent" && -n "${AGENT_COMMANDS[$default_agent]:-}" ]]; then
        options+=("$default_agent")
    fi

    while IFS= read -r agent; do
        [[ "$agent" == "$default_agent" ]] && continue
        options+=("$agent")
    done < <(printf '%s\n' "${!AGENT_COMMANDS[@]}" | sort)

    printf '%s\n' "${options[@]}"
}

fzf_pick_agent() {
    local default_agent="${1:-}"
    local options
    options=$(fzf_agent_options "$default_agent")

    local selected
    selected=$(echo "$options" | fzf \
        --ansi \
        --no-multi \
        --header="Select agent type (Enter to confirm, Esc to cancel)" \
        --height=10 \
        --layout=reverse \
    )

    if [[ -z "$selected" ]]; then
        echo ""
        return 1
    fi

    echo "$selected"
}

# Generate session list for fzf
# Format: "session_name|display_name"
# Usage: fzf_list_sessions
fzf_list_sessions() {
    local session

    # Clean up stale registry entries first
    registry_gc >/dev/null 2>&1
    auto_title_scan >/dev/null 2>&1 &

    # Get sessions sorted by activity
    for session in $(tmux_list_am_sessions_with_activity | awk '{print $1}'); do
        local display
        display=$(agent_display_name "$session")
        echo "${session}|${display}"
    done
}

# Export functions for fzf subshells (reload uses fzf_list_sessions -> agent_display_name)
_fzf_export_functions() {
    export AM_DIR AM_REGISTRY AM_SESSION_PREFIX AM_HISTORY AM_CONFIG
    export -f fzf_list_sessions agent_display_name
    export -f registry_gc registry_list registry_remove am_init
    export -f registry_get_field registry_update history_append history_prune
    export -f auto_title_scan _title_fallback _title_strip_haiku _title_valid
    export -f am_config_init am_config_get am_default_agent am_default_yolo_enabled
    export -f claude_first_user_message
    export -f tmux_list_am_sessions_with_activity tmux_get_activity
    export -f dir_basename format_time_ago epoch_now
    export -f require_cmd log_info log_error log_warn am_init
}

# Main fzf interface
# Usage: fzf_main
fzf_main() {
    _fzf_export_functions

    # Get the path to this script's directory for the preview command
    local lib_dir
    lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    # Check if any sessions exist
    local sessions
    sessions=$(fzf_list_sessions)

    # If no sessions, add placeholder for new session
    if [[ -z "$sessions" ]]; then
        sessions="__new__|➕ Create new session"
    fi

    # Build preview command - use standalone script for speed
    local preview_cmd="$lib_dir/preview"

    # Fallback for reload commands that need full library access
    local src_libs="source '$lib_dir/utils.sh' && source '$lib_dir/tmux.sh' && source '$lib_dir/registry.sh' && source '$lib_dir/agents.sh' && source '$lib_dir/fzf.sh'"

    # Help text for ? key
    local help_text="
  Agent Manager Help

  Navigation
    Up/Down     Move selection
    Enter       Attach to selected session
    Esc/q       Exit without action

  Actions
    Ctrl-N      Create new session
    Ctrl-X      Kill selected session
    Ctrl-R      Refresh session list

  View
    Ctrl-P      Toggle preview panel
    Ctrl-J/K    Scroll preview down/up
    Ctrl-D/U    Scroll preview half-page
    ?           Show this help

  In tmux session
    Ctrl-Z a    Open am menu (popup)
    Ctrl-Z n    Open new-session popup
    Ctrl-Z d    Detach (return to shell)
    Ctrl-Z x    Kill current am session
    Ctrl-Z [    Scroll mode (q to exit)
"

    # Run fzf
    local selected
    selected=$(echo "$sessions" | fzf \
        --sync \
        --ansi \
        --height=100% \
        --delimiter='|' \
        --with-nth=2 \
        --header="Agent Sessions  ?:help  Enter:attach  ^N:new  ^X:kill" \
        --preview="$preview_cmd {1}" \
        --preview-window="bottom:75%" \
        --bind="ctrl-j:preview-down,ctrl-k:preview-up" \
        --bind="ctrl-d:preview-half-page-down,ctrl-u:preview-half-page-up" \
        --bind="ctrl-r:reload(bash -c '$src_libs && fzf_list_sessions')" \
        --bind="ctrl-p:toggle-preview" \
        --bind="ctrl-x:execute-silent($lib_dir/../bin/kill-and-switch {1})+reload(bash -c '$src_libs && fzf_list_sessions')" \
        --bind="?:preview(echo '$help_text')" \
        --expect="ctrl-n" \
    )

    # Parse result
    local key session_name
    key=$(echo "$selected" | head -n1)
    session_name=$(echo "$selected" | tail -n1 | cut -d'|' -f1)

    # Handle new session request (either Ctrl-N or selecting the "new" option)
    if [[ "$key" == "ctrl-n" || "$session_name" == "__new__" ]]; then
        # Pick directory
        local directory
        directory=$(fzf_pick_directory)
        if [[ -z "$directory" ]]; then
            return 0  # Cancelled
        fi

        # Pick agent type
        local agent_type
        if ! agent_type=$(fzf_pick_agent "$(am_default_agent)"); then
            fzf_main
            return $?
        fi

        # Pick mode (new/resume/continue)
        local flags yolo_default
        yolo_default=$(am_default_yolo_enabled && echo true || echo false)
        if ! flags=$(fzf_pick_mode "$yolo_default"); then
            # Cancelled - return to main menu
            fzf_main
            return $?
        fi

        # Return new session command
        echo "__NEW_SESSION__|${directory}|${agent_type}|${flags}"
        return 0
    fi

    # Attach to selected session
    if [[ -n "$session_name" ]]; then
        echo "$session_name"
    fi
}

# Simplified list output (no fzf, just print)
# Usage: fzf_list_simple
fzf_list_simple() {
    local session
    for session in $(tmux_list_am_sessions_with_activity | awk '{print $1}'); do
        local display
        display=$(agent_display_name "$session")
        echo "$display"
    done
}

# JSON output for scripting
# Usage: fzf_list_json
fzf_list_json() {
    registry_gc >/dev/null 2>&1
    auto_title_scan >/dev/null 2>&1 &

    local sessions=()
    local session

    for session in $(tmux_list_am_sessions_with_activity | awk '{print $1}'); do
        # Get all registry fields in one jq call
        local fields
        fields=$(jq -r --arg name "$session" \
            '.sessions[$name] | "\(.directory // "")|\(.branch // "")|\(.agent_type // "")|\(.task // "")"' \
            "$AM_REGISTRY" 2>/dev/null)

        local directory branch agent_type task
        IFS='|' read -r directory branch agent_type task <<< "$fields"

        local activity
        activity=$(tmux_get_activity "$session")
        local created
        created=$(tmux_get_created "$session")

        sessions+=("$(jq -n \
            --arg name "$session" \
            --arg dir "$directory" \
            --arg branch "$branch" \
            --arg agent "$agent_type" \
            --arg task "$task" \
            --arg activity "$activity" \
            --arg created "$created" \
            '{name: $name, directory: $dir, branch: $branch, agent_type: $agent, task: $task, activity: ($activity | tonumber), created: ($created | tonumber)}'
        )")
    done

    # Combine into array
    if [[ ${#sessions[@]} -eq 0 ]]; then
        echo "[]"
    else
        printf '%s\n' "${sessions[@]}" | jq -s '.'
    fi
}
