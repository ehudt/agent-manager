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

# Annotate a directory path with its current git branch.
# Usage: _annotate_directory <path>
# Returns: annotation string like ' main' or empty
_annotate_directory() {
    local dir_path="$1"
    local branch=""
    branch=$(detect_git_branch "$dir_path")
    [[ -n "$branch" ]] || return 0
    echo " $branch"
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
    local initial_list
    initial_list=$(_list_directories | grep -v '^$')

    # Run fzf with dynamic completion
    local dir_preview_cmd="$SCRIPT_DIR/dir-preview"

    local selected
    selected=$(echo "$initial_list" | fzf \
        --ansi \
        --header="Directory: type path or select  |  Tab: complete  |  Ctrl-U: parent dir" \
        --preview="$dir_preview_cmd {}" \
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

fzf_pick_session_mode() {
    local default_mode="${1:-new}"
    local options selected

    options=$(cat <<EOF
${default_mode}
new
resume
continue
EOF
)

    selected=$(echo "$options" | awk '!seen[$0]++' | fzf \
        --ansi \
        --no-multi \
        --header="Select session mode (Enter to confirm, Esc to cancel)" \
        --height=8 \
        --layout=reverse \
    )

    if [[ -z "$selected" ]]; then
        echo ""
        return 1
    fi

    echo "$selected"
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

_new_session_form_rows() {
    local directory="$1"
    local agent="$2"
    local task="$3"
    local mode="$4"
    local yolo="$5"
    local worktree_enabled="$6"
    local worktree_name="$7"

    local task_display worktree_toggle worktree_name_display yolo_toggle
    local worktree_supported="false"
    task_display="${task:-<empty>}"
    worktree_name_display="<disabled>"
    yolo_toggle="[ ]"
    worktree_toggle="[ ]"

    [[ "$yolo" == "true" ]] && yolo_toggle="[x]"
    if agent_supports_worktree "$agent"; then
        worktree_supported="true"
    fi

    if [[ "$worktree_supported" != "true" ]]; then
        worktree_toggle="<unsupported>"
        worktree_name_display="<unsupported>"
    elif [[ "$worktree_enabled" == "true" ]]; then
        worktree_toggle="[x]"
        worktree_name_display="${worktree_name:-<auto>}"
    fi

    printf 'submit\tCreate Session\tLaunch with current values\n'
    printf 'directory\tDirectory\t%s\n' "$directory"
    printf 'agent\tAgent\t%s\n' "$agent"
    printf 'task\tTask\t%s\n' "$task_display"
    printf 'mode\tMode\t%s\n' "$mode"
    printf 'yolo\tYOLO\t%s\n' "$yolo_toggle"
    printf 'worktree_enabled\tWorktree\t%s\n' "$worktree_toggle"
    printf 'worktree_name\tWorktree Name\t%s\n' "$worktree_name_display"
}

_new_session_form_preview() {
    local directory="$1"
    local agent="$2"
    local task="$3"
    local mode="$4"
    local yolo="$5"
    local worktree_enabled="$6"
    local worktree_name="$7"
    local message="$8"
    local worktree_display="off"

    if ! agent_supports_worktree "$agent"; then
        worktree_display="unavailable for $agent"
    elif [[ "$worktree_enabled" == "true" ]]; then
        worktree_display="${worktree_name:-auto}"
    fi

    cat <<EOF
New Session

Enter edits the current field.
Space toggles checkboxes.
Esc goes back without creating a session.

Current values
  Directory: $directory
  Agent:     $agent
  Task:      ${task:-<empty>}
  Mode:      $mode
  YOLO:      $yolo
  Worktree:  $worktree_display

${message:+Note: $message}
EOF
}

_new_session_form_row_position() {
    case "$1" in
        submit) echo 1 ;;
        directory) echo 2 ;;
        agent) echo 3 ;;
        task) echo 4 ;;
        mode) echo 5 ;;
        yolo) echo 6 ;;
        worktree_enabled) echo 7 ;;
        worktree_name) echo 8 ;;
        *) echo 1 ;;
    esac
}

_new_session_validate_worktree_name() {
    local value="$1"

    [[ -z "$value" ]] && return 0
    [[ "$value" == "." || "$value" == ".." ]] && return 1
    [[ "$value" =~ ^[A-Za-z0-9._-]+$ ]]
}

_new_session_form_edit_text() {
    local prompt="$1"
    local current_value="${2:-}"
    local query selection value selected_row

    selection=$(printf 'apply\t%s\n' "$prompt" | fzf \
        --sync \
        --ansi \
        --height=100% \
        --delimiter=$'\t' \
        --with-nth=2 \
        --print-query \
        --query="$current_value" \
        --header="Edit value  Enter:apply  Esc:back" \
        --preview="printf '%s\n\n%s\n%s\n' 'Current value:' '{}' 'Tip: type - to clear'" \
        --preview-window="bottom:75%")

    [[ -z "$selection" ]] && return 1

    query=$(echo "$selection" | head -n1)
    selected_row=$(echo "$selection" | tail -n1)
    value="${query}"

    if [[ -z "$selected_row" ]]; then
        return 1
    fi

    if [[ "$value" == "-" ]]; then
        echo ""
    else
        echo "$value"
    fi
}

_new_session_form_prompt() {
    local prompt="$1"
    local current_value="${2:-}"
    local edited

    if edited=$(_new_session_form_edit_text "$prompt" "$current_value"); then
        if [[ -n "$edited" || "$current_value" == "-" || "$current_value" == "" ]]; then
            echo "$edited"
        else
            echo "$current_value"
        fi
    else
        return 1
    fi
}

# One-page form for new session creation.
# Usage: fzf_new_session_form [prefill_directory] [prefill_agent] [prefill_task] [prefill_worktree] [prefill_mode_flags]
# Returns: directory<TAB>agent<TAB>task<TAB>worktree_name<TAB>flags
fzf_new_session_form() {
    local prefill_directory="${1:-.}"
    local prefill_agent="${2:-$(am_default_agent)}"
    local prefill_task="${3:-}"
    local prefill_worktree="${4:-}"
    local prefill_mode_flags="${5:-}"
    local tty_path="/dev/tty"
    local mode="new"
    local yolo="false"
    local directory="${prefill_directory/#\~/$HOME}"
    local agent="$prefill_agent"
    local task="$prefill_task"
    local worktree_enabled="false"
    local worktree_name=""
    local message=""
    local selection key selected_row selected_field
    local preview_file
    local current_field="submit"

    if [[ "$prefill_mode_flags" == *"--resume"* ]]; then
        mode="resume"
    elif [[ "$prefill_mode_flags" == *"--continue"* ]]; then
        mode="continue"
    fi

    if [[ "$prefill_mode_flags" == *"--yolo"* ]]; then
        yolo="true"
    elif am_default_yolo_enabled; then
        yolo="true"
    fi

    case "$prefill_worktree" in
        ""|false)
            worktree_enabled="false"
            worktree_name=""
            ;;
        true|__auto__)
            worktree_enabled="true"
            worktree_name=""
            ;;
        *)
            worktree_enabled="true"
            worktree_name="$prefill_worktree"
            ;;
    esac

    if [[ ! -e "$tty_path" ]]; then
        log_error "No terminal available for form editor"
        return 1
    fi

    preview_file=$(mktemp)
    trap 'rm -f "$preview_file"' RETURN

    while true; do
        _new_session_form_preview \
            "$directory" "$agent" "$task" "$mode" "$yolo" "$worktree_enabled" "$worktree_name" "$message" \
            > "$preview_file"
        message=""

        selection=$(_new_session_form_rows "$directory" "$agent" "$task" "$mode" "$yolo" "$worktree_enabled" "$worktree_name" | fzf \
            --sync \
            --ansi \
            --height=100% \
            --delimiter=$'\t' \
            --with-nth=2,3 \
            --header="New Session  Enter:edit  Space:toggle  Esc:back" \
            --preview="cat '$preview_file'" \
            --preview-window="bottom:75%" \
            --bind="ctrl-p:toggle-preview" \
            --bind="start:pos($(_new_session_form_row_position "$current_field"))" \
            --expect="space")

        key=$(echo "$selection" | head -n1)
        selected_row=$(echo "$selection" | tail -n1)
        selected_field=$(echo "$selected_row" | cut -f1)

        if [[ -z "$selected_row" ]]; then
            return 1
        fi

        current_field="$selected_field"

        if [[ "$key" == "space" ]]; then
            case "$selected_field" in
                yolo)
                    [[ "$yolo" == "true" ]] && yolo="false" || yolo="true"
                    ;;
                worktree_enabled)
                    if agent_supports_worktree "$agent"; then
                        [[ "$worktree_enabled" == "true" ]] && worktree_enabled="false" || worktree_enabled="true"
                    else
                        message="Worktree isolation is not available for $agent sessions."
                    fi
                    ;;
            esac
            continue
        fi

        case "$selected_field" in
            submit)
                break
                ;;
            directory)
                if selection=$(fzf_pick_directory); then
                    directory="$selection"
                fi
                ;;
            agent)
                if selection=$(fzf_pick_agent "$agent"); then
                    agent="$selection"
                fi
                ;;
            task)
                if selection=$(_new_session_form_prompt "What are you working on this session?" "$task"); then
                    task="$selection"
                fi
                ;;
            mode)
                if selection=$(fzf_pick_session_mode "$mode"); then
                    mode="$selection"
                fi
                ;;
            yolo)
                [[ "$yolo" == "true" ]] && yolo="false" || yolo="true"
                ;;
            worktree_enabled)
                if agent_supports_worktree "$agent"; then
                    [[ "$worktree_enabled" == "true" ]] && worktree_enabled="false" || worktree_enabled="true"
                else
                    message="Worktree isolation is not available for $agent sessions."
                fi
                ;;
            worktree_name)
                if ! agent_supports_worktree "$agent"; then
                    message="Worktree isolation is not available for $agent sessions."
                elif [[ "$worktree_enabled" != "true" ]]; then
                    message="Enable Worktree first to edit its name."
                elif selection=$(_new_session_form_prompt "Enter a custom name for your worktree" "$worktree_name"); then
                    if _new_session_validate_worktree_name "$selection"; then
                        worktree_name="$selection"
                    else
                        message="Invalid worktree name. Use only letters, numbers, dots, underscores, and dashes."
                    fi
                fi
                ;;
        esac
    done

    if [[ -z "$directory" ]]; then
        log_info "Cancelled"
        return 1
    fi
    directory="${directory/#\~/$HOME}"
    if [[ ! -d "$directory" ]]; then
        log_error "Directory does not exist: $directory"
        return 1
    fi

    if [[ -z "$agent" || -z "${AGENT_COMMANDS[$agent]:-}" ]]; then
        log_error "Invalid agent type: ${agent:-<empty>}"
        return 1
    fi

    case "$mode" in
        new|resume|continue) ;;
        *)
            log_error "Invalid mode: $mode"
            return 1
            ;;
    esac

    case "$yolo" in
        true|false) ;;
        *)
            log_error "Invalid YOLO value: $yolo"
            return 1
            ;;
    esac

    local flags=""
    [[ "$mode" == "resume" ]] && flags+=" --resume"
    [[ "$mode" == "continue" ]] && flags+=" --continue"
    [[ "$yolo" == "true" ]] && flags+=" --yolo"

    local worktree=""
    if [[ "$worktree_enabled" == "true" ]] && agent_supports_worktree "$agent"; then
        if [[ -n "$worktree_name" ]]; then
            worktree="$worktree_name"
        else
            worktree="__auto__"
        fi
    fi

    printf '%s\t%s\t%s\t%s\t%s\n' "$directory" "$agent" "$task" "$worktree" "$flags"
}

# Generate session list for fzf
# Format: "session_name|display_name"
# Usage: fzf_list_sessions
fzf_list_sessions() {
    local session activity

    # Clean up stale registry entries first
    registry_gc >/dev/null 2>&1
    auto_title_scan >/dev/null 2>&1 &

    # Get sessions sorted by activity — pass pre-fetched activity to avoid N+1 tmux calls
    while IFS=' ' read -r session activity; do
        [[ -z "$session" ]] && continue
        local display
        display=$(agent_display_name "$session" "$activity")
        echo "${session}|${display}"
    done < <(tmux_list_am_sessions_with_activity)
}

# Main fzf interface
# Usage: fzf_main
fzf_main() {
    # Get the path to this script's directory for the preview command
    local lib_dir
    lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    # Path to the am entry point for fzf reload subshells.
    # Using the entry point avoids exporting 22+ functions for subshell access.
    local am_cmd="$lib_dir/../am"

    # Check if any sessions exist
    local sessions
    sessions=$(fzf_list_sessions)

    # If no sessions, add placeholder for new session
    if [[ -z "$sessions" ]]; then
        sessions="__new__|➕ Create new session"
    fi

    # Build preview command - use standalone script for speed
    local preview_cmd="$lib_dir/preview"

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
    Prefix + a  Switch to last am session
    Prefix + n  Open new-session popup
    Prefix + s  Open am browser popup
    Prefix + x  Kill current am session
    Prefix + d  Detach from session
    Prefix Up/Down
                Switch panes (agent/shell)
    :am         Open am browser (tmux command)
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
        --bind="ctrl-r:reload($am_cmd list-internal)" \
        --bind="ctrl-p:toggle-preview" \
        --bind="ctrl-x:execute-silent($lib_dir/../bin/kill-and-switch {1})+reload($am_cmd list-internal)" \
        --bind="?:preview(echo '$help_text')" \
        --expect="ctrl-n" \
    )

    # Parse result
    local key session_name
    key=$(echo "$selected" | head -n1)
    session_name=$(echo "$selected" | tail -n1 | cut -d'|' -f1)

    # Handle new session request (either Ctrl-N or selecting the "new" option)
    if [[ "$key" == "ctrl-n" || "$session_name" == "__new__" ]]; then
        local form_values directory agent_type task worktree_name flags
        if ! form_values=$(fzf_new_session_form); then
            fzf_main
            return $?
        fi

        IFS=$'\t' read -r directory agent_type task worktree_name flags <<< "$form_values"

        # Return new session command
        printf "__NEW_SESSION__\t%s\t%s\t%s\t%s\t%s\n" "$directory" "$agent_type" "$flags" "$task" "$worktree_name"
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
    local session activity
    while IFS=' ' read -r session activity; do
        [[ -z "$session" ]] && continue
        local display
        display=$(agent_display_name "$session" "$activity")
        echo "$display"
    done < <(tmux_list_am_sessions_with_activity)
}

# JSON output for scripting
# Usage: fzf_list_json
fzf_list_json() {
    registry_gc >/dev/null 2>&1
    auto_title_scan >/dev/null 2>&1 &

    # Bulk-read tmux data: session_name activity created (one tmux call total)
    local -A tmux_activity tmux_created
    local _name _activity _created
    while IFS=' ' read -r _name _activity _created; do
        tmux_activity[$_name]=$_activity
        tmux_created[$_name]=$_created
    done < <(tmux list-sessions -F '#{session_name} #{session_activity} #{session_created}' 2>/dev/null \
        | grep "^${AM_SESSION_PREFIX}" || true)

    # Build JSON for each session sorted by activity (most recent first)
    local sessions=()
    local session activity
    while IFS=' ' read -r session activity; do
        [[ -z "$session" ]] && continue

        local fields
        fields=$(registry_get_fields "$session" directory branch agent_type task)

        local directory branch agent_type task
        IFS='|' read -r directory branch agent_type task <<< "$fields"

        sessions+=("$(jq -n \
            --arg name "$session" \
            --arg dir "$directory" \
            --arg branch "$branch" \
            --arg agent "$agent_type" \
            --arg task "$task" \
            --arg activity "${tmux_activity[$session]:-0}" \
            --arg created "${tmux_created[$session]:-0}" \
            '{name: $name, directory: $dir, branch: $branch, agent_type: $agent, task: $task, activity: ($activity | tonumber), created: ($created | tonumber)}'
        )")
    done < <(tmux_list_am_sessions_with_activity)

    # Combine into array
    if [[ ${#sessions[@]} -eq 0 ]]; then
        echo "[]"
    else
        printf '%s\n' "${sessions[@]}" | jq -s '.'
    fi
}
