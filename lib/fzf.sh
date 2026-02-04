#!/usr/bin/env bash
# fzf.sh - fzf interface functions

# Source dependencies if not already loaded
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
[[ -z "$AM_DIR" ]] && source "$SCRIPT_DIR/utils.sh"
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

    # Default: show frecent directories and git repos
    echo ". (current directory)"

    # Zoxide frecent directories
    if command -v zoxide &>/dev/null; then
        zoxide query -l 2>/dev/null | head -30
    fi

    # Git repos from common locations
    local search_paths=("$HOME/code" "$HOME/projects" "$HOME/src" "$HOME/dev" "$HOME/work")
    for search_path in "${search_paths[@]}"; do
        if [[ -d "$search_path" ]]; then
            find "$search_path" -maxdepth 3 -type d -name ".git" 2>/dev/null | \
                sed 's/\/\.git$//' | head -20
        fi
    done
}

# Pick a directory using fzf with interactive path completion
# Usage: fzf_pick_directory
# Returns: selected directory path or empty if cancelled
fzf_pick_directory() {
    # Export helper for fzf reload
    export -f _list_directories

    local initial_list
    initial_list=$(_list_directories | awk '!seen[$0]++' | grep -v '^$')

    # Run fzf with dynamic completion
    local selected
    selected=$(echo "$initial_list" | fzf \
        --ansi \
        --header="Directory: type path or select  |  Tab: complete  |  Ctrl-U: parent dir" \
        --preview='d={};[[ "$d" == ". (current directory)" ]] && d="."; d="${d/#\~/$HOME}"; [[ -d "$d" ]] && command ls -la "$d" 2>/dev/null | head -20 || echo "Type a path or select from list"' \
        --preview-window="right:40%:wrap" \
        --print-query \
        --bind="tab:reload(bash -c '_list_directories {q}' | awk '!seen[\$0]++' | grep -v '^$')+clear-query" \
        --bind="ctrl-u:reload(bash -c '_list_directories \$(dirname {q})' | awk '!seen[\$0]++' | grep -v '^$')+transform-query(dirname {q})" \
    )

    # Parse result - fzf --print-query outputs: query on line 1, selection on line 2
    local query selection
    query=$(echo "$selected" | head -n1)
    selection=$(echo "$selected" | tail -n1)

    # If selection is empty but query exists, use query as typed path
    if [[ -z "$selection" && -n "$query" ]]; then
        selection="$query"
    fi

    # Handle special case
    if [[ "$selection" == ". (current directory)" ]]; then
        selection="."
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
# Returns: flags string (always includes --dangerously-skip-permissions), or empty if cancelled
fzf_pick_mode() {
    local options="New session
Resume (--resume)
Continue (--continue)"

    local selected
    selected=$(echo "$options" | fzf \
        --ansi \
        --no-multi \
        --header="Select mode (Enter to confirm, Esc to cancel)" \
        --height=8 \
        --layout=reverse \
    )

    # If cancelled (empty selection), return empty
    if [[ -z "$selected" ]]; then
        echo ""
        return 1
    fi

    # Always include --dangerously-skip-permissions
    local flags="--dangerously-skip-permissions"

    case "$selected" in
        *--resume*) flags+=" --resume" ;;
        *--continue*) flags+=" --continue" ;;
    esac

    echo "$flags"
}

# Generate session list for fzf
# Format: "session_name|display_name"
# Usage: fzf_list_sessions
fzf_list_sessions() {
    local session

    # Clean up stale registry entries first
    registry_gc >/dev/null 2>&1

    # Get sessions sorted by activity
    for session in $(tmux_list_am_sessions_with_activity | awk '{print $1}'); do
        local display
        display=$(agent_display_name "$session")
        echo "${session}|${display}"
    done
}

# Preview function for fzf
# Usage: fzf_preview <session_name>
fzf_preview() {
    local session_name="$1"

    if [[ -z "$session_name" ]]; then
        echo "No session selected"
        return
    fi

    if ! tmux_session_exists "$session_name"; then
        echo "Session not found: $session_name"
        return
    fi

    # Capture terminal output - just show the raw capture
    # Args: session_name, lines_to_capture, lines_to_skip_from_bottom
    tmux_capture_pane "$session_name" 35 0
}

# Export functions for fzf subshells
_fzf_export_functions() {
    export AM_DIR AM_REGISTRY AM_SESSION_PREFIX
    export -f fzf_preview agent_info agent_display_name
    export -f registry_get_field registry_init
    export -f tmux_capture_pane tmux_session_exists tmux_get_activity tmux_get_created
    export -f format_time_ago format_duration dir_basename truncate abspath epoch_now get_claude_session_title
    export -f require_cmd log_info log_error log_warn log_success am_init
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

    # Build preview command - must use bash (not zsh) for declare -A and BASH_SOURCE
    local src_libs="source '$lib_dir/utils.sh' && source '$lib_dir/tmux.sh' && source '$lib_dir/registry.sh' && source '$lib_dir/agents.sh' && source '$lib_dir/fzf.sh'"

    # Help text for ? key
    local help_text="
╔══════════════════════════════════════════════════════════════╗
║                    Agent Manager Help                        ║
╠══════════════════════════════════════════════════════════════╣
║  Navigation                                                  ║
║    ↑/↓         Move selection                                ║
║    Enter       Attach to selected session                    ║
║    Esc/q       Exit without action                           ║
║                                                              ║
║  Actions                                                     ║
║    Ctrl-N      Create new session                            ║
║    Ctrl-X      Kill selected session                         ║
║    Ctrl-R      Refresh session list                          ║
║                                                              ║
║  View                                                        ║
║    Ctrl-P      Toggle preview panel                          ║
║    ?           Show this help                                ║
║                                                              ║
║  In tmux session                                             ║
║    Ctrl-Z a    Open am menu (popup)                          ║
║    Ctrl-Z d    Detach (return to shell)                      ║
║    Ctrl-Z [    Scroll mode (q to exit)                       ║
╚══════════════════════════════════════════════════════════════╝
"

    # Run fzf
    local selected
    selected=$(echo "$sessions" | fzf \
        --ansi \
        --height=100% \
        --delimiter='|' \
        --with-nth=2 \
        --header="Agent Sessions  ?:help  Enter:attach  ^N:new  ^X:kill" \
        --preview="bash -c '$src_libs && fzf_preview {1}'" \
        --preview-window="bottom:75%:wrap" \
        --bind="ctrl-r:reload(bash -c '$src_libs && fzf_list_sessions')" \
        --bind="ctrl-p:toggle-preview" \
        --bind="ctrl-x:execute-silent(bash -c '$src_libs && agent_kill {1}')+reload(bash -c '$src_libs && fzf_list_sessions')" \
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

        # Pick mode (new/resume/continue)
        local flags
        flags=$(fzf_pick_mode)
        if [[ -z "$flags" ]]; then
            # Cancelled - return to main menu
            fzf_main
            return $?
        fi

        # Return new session command
        echo "__NEW_SESSION__|${directory}|${flags}"
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

    local sessions=()
    local session

    for session in $(tmux_list_am_sessions_with_activity | awk '{print $1}'); do
        local directory branch agent_type task
        directory=$(registry_get_field "$session" "directory")
        branch=$(registry_get_field "$session" "branch")
        agent_type=$(registry_get_field "$session" "agent_type")
        task=$(registry_get_field "$session" "task")

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
