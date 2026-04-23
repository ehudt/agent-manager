# shellcheck shell=bash
# fzf.sh - fzf interface functions

# Source dependencies if not already loaded
_FZF_LIB_DIR="${AM_LIB_DIR:-$(dirname "${BASH_SOURCE[0]}")}"
[[ -z "$AM_DIR" ]] && source "$_FZF_LIB_DIR/utils.sh"
[[ "$(type -t am_default_agent)" != "function" ]] && source "$_FZF_LIB_DIR/config.sh"
[[ "$(type -t tmux_list_am_sessions)" != "function" ]] && source "$_FZF_LIB_DIR/tmux.sh"
[[ "$(type -t registry_get_field)" != "function" ]] && source "$_FZF_LIB_DIR/registry.sh"
# agents.sh is loaded lazily — only the interactive form functions need it

# Helper: List directories for picker (frecent + git repos)
# shellcheck disable=SC2120
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
            local parent_dir
            parent_dir=$(dirname "$base_path")
            local prefix
            prefix=$(basename "$base_path")
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
    # Lazy-load agents.sh (only interactive form functions need it)
    [[ "$(type -t agent_display_name)" != "function" ]] && source "$_FZF_LIB_DIR/agents.sh"
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
    # Lazy-load agents.sh (only interactive form functions need it)
    [[ "$(type -t agent_supports_worktree)" != "function" ]] && source "$_FZF_LIB_DIR/agents.sh"
    local directory="$1"
    local agent="$2"
    local task="$3"
    local mode="$4"
    local yolo="$5"
    local sandbox="$6"
    local worktree_enabled="$7"
    local worktree_name="$8"
    local docker_available="${9:-true}"

    local task_display worktree_toggle worktree_name_display yolo_toggle sandbox_toggle
    local worktree_supported="false"
    task_display="${task:-<empty>}"
    worktree_name_display="<disabled>"
    yolo_toggle="[ ]"
    worktree_toggle="[ ]"

    [[ "$yolo" == "true" ]] && yolo_toggle="[x]"

    if [[ "$docker_available" != "true" ]]; then
        sandbox_toggle="[disabled]"
    elif [[ "$sandbox" == "true" ]]; then
        sandbox_toggle="[x]"
    else
        sandbox_toggle="[ ]"
    fi

    if agent_supports_worktree "$agent"; then
        worktree_supported="true"
    fi

    if [[ "$worktree_supported" == "true" && "$worktree_enabled" == "true" ]]; then
        worktree_toggle="[x]"
        worktree_name_display="${worktree_name:-<auto>}"
    elif [[ "$worktree_supported" != "true" && "$worktree_enabled" == "true" ]]; then
        worktree_toggle="<unsupported>"
    fi

    printf 'directory\tDirectory\t%s\n' "$directory"
    printf 'agent\tAgent\t%s\n' "$agent"
    printf 'task\tTask\t%s\n' "$task_display"
    printf 'mode\tMode\t%s\n' "$mode"
    printf 'yolo\tYolo\t%s\n' "$yolo_toggle"
    printf 'sandbox\tSandbox\t%s\n' "$sandbox_toggle"
    if [[ "$worktree_supported" == "true" || "$worktree_enabled" == "true" ]]; then
        printf 'worktree_enabled\tWorktree\t%s\n' "$worktree_toggle"
        if [[ "$worktree_supported" == "true" ]]; then
            printf 'worktree_name\tWorktree Name\t%s\n' "$worktree_name_display"
        fi
    fi
}

_new_session_form_row_position() {
    case "$1" in
        directory) echo 1 ;;
        agent) echo 2 ;;
        task) echo 3 ;;
        mode) echo 4 ;;
        yolo) echo 5 ;;
        sandbox) echo 6 ;;
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

# Directory picker for the new session form.
# Usage: _new_session_form_directory <current>
# Returns: selected directory path
_new_session_form_directory() {
    local current="$1"

    # Export helpers for fzf reload
    export -f _list_directories
    export -f _annotate_directory
    export -f _strip_annotation
    export -f detect_git_branch

    local initial_list
    initial_list=$(_list_directories | grep -v '^$')

    local selected
    selected=$(echo "$initial_list" | fzf \
        --sync \
        --ansi \
        --height=10 \
        --layout=reverse \
        --print-query \
        --query="$current" \
        --header="Directory  Tab:complete  Type to filter" \
        --bind="tab:reload(bash -c '_list_directories {q}' | grep -v '^$')+clear-query" \
        --bind="ctrl-u:reload(bash -c '_list_directories \$(dirname {q})' | grep -v '^$')+transform-query(dirname {q})" \
    ) || true

    local query selection
    query=$(echo "$selected" | head -n1)
    selection=$(echo "$selected" | tail -n1)

    selection=$(_strip_annotation "$selection")
    query=$(_strip_annotation "$query")

    if [[ -z "$selection" && -n "$query" ]]; then
        selection="$query"
    fi

    selection="${selection/#\~/$HOME}"

    if [[ -n "$selection" ]]; then
        echo "$selection"
    else
        echo "$current"
    fi
}

# One-page form for new session creation.
# Usage: fzf_new_session_form [prefill_directory] [prefill_agent] [prefill_task] [prefill_worktree] [prefill_mode_flags]
# Returns: directory<US>agent<US>task<US>worktree_name<US>flags  (US = \x1f unit separator)
fzf_new_session_form() {
    local prefill_directory="${1:-.}"
    local prefill_agent="${2:-$(am_default_agent)}"
    local prefill_task="${3:-}"
    local prefill_worktree="${4:-}"
    local prefill_mode_flags="${5:-}"
    local mode="new"
    local yolo="false"
    local sandbox="false"
    local directory="${prefill_directory/#\~/$HOME}"
    local agent="$prefill_agent"
    local task="$prefill_task"
    local worktree_enabled="false"
    local worktree_name=""
    local selection key selected_row selected_field
    local current_field="agent"
    local docker_available="true"
    am_docker_available || docker_available="false"

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

    if [[ "$prefill_mode_flags" == *"--sandbox"* ]]; then
        sandbox="true"
    elif am_default_sandbox_enabled && [[ "$docker_available" == "true" ]]; then
        sandbox="true"
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

    # Directory picker first
    if selection=$(_new_session_form_directory "$directory"); then
        [[ -n "$selection" ]] && directory="$selection"
    fi

    # Main field loop
    while true; do
        local rows
        rows=$(_new_session_form_rows "$directory" "$agent" "$task" "$mode" \
            "$yolo" "$sandbox" "$worktree_enabled" "$worktree_name" "$docker_available")

        selection=$(echo "$rows" | fzf \
            --sync \
            --ansi \
            --height=100% \
            --delimiter=$'\t' \
            --with-nth=2,3 \
            --header="New Session  Enter:create  Space:toggle/cycle  Esc:cancel" \
            --no-preview \
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
                agent)
                    local options current_idx next_idx count
                    options=$(fzf_agent_options "$agent")
                    count=$(echo "$options" | wc -l | tr -d ' ')
                    current_idx=$(echo "$options" | grep -n "^${agent}$" | head -1 | cut -d: -f1)
                    next_idx=$(( (current_idx % count) + 1 ))
                    agent=$(echo "$options" | sed -n "${next_idx}p")
                    ;;
                mode)
                    case "$mode" in
                        new) mode="resume" ;;
                        resume) mode="continue" ;;
                        continue) mode="new" ;;
                    esac
                    ;;
                yolo)
                    [[ "$yolo" == "true" ]] && yolo="false" || yolo="true"
                    ;;
                sandbox)
                    if [[ "$docker_available" == "true" ]]; then
                        [[ "$sandbox" == "true" ]] && sandbox="false" || sandbox="true"
                    fi
                    ;;
                worktree_enabled)
                    if agent_supports_worktree "$agent"; then
                        [[ "$worktree_enabled" == "true" ]] && worktree_enabled="false" || worktree_enabled="true"
                    fi
                    ;;
            esac
            continue
        fi

        # Enter pressed — text fields open editor; other fields create session
        case "$selected_field" in
            directory)
                if selection=$(_new_session_form_directory "$directory"); then
                    [[ -n "$selection" ]] && directory="$selection"
                fi
                ;;
            task)
                if selection=$(_new_session_form_prompt "What are you working on this session?" "$task"); then
                    task="$selection"
                fi
                ;;
            worktree_name)
                if [[ "$worktree_enabled" == "true" ]] && agent_supports_worktree "$agent"; then
                    if selection=$(_new_session_form_prompt "Enter a custom name for your worktree" "$worktree_name"); then
                        if _new_session_validate_worktree_name "$selection"; then
                            worktree_name="$selection"
                        fi
                    fi
                fi
                ;;
            *)
                # Any other field on Enter → create session
                break
                ;;
        esac
    done

    # Validation
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

    local flags=""
    [[ "$mode" == "resume" ]] && flags+=" --resume"
    [[ "$mode" == "continue" ]] && flags+=" --continue"
    [[ "$yolo" == "true" ]] && flags+=" --yolo"
    [[ "$sandbox" == "true" ]] && flags+=" --sandbox"

    local worktree=""
    if [[ "$worktree_enabled" == "true" ]] && agent_supports_worktree "$agent"; then
        if [[ -n "$worktree_name" ]]; then
            worktree="$worktree_name"
        else
            worktree="__auto__"
        fi
    fi

    printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\n' "$directory" "$agent" "$task" "$worktree" "$flags"
}

# Generate session list for fzf
# Format: "session_name|display_name"
# Uses a file-based cache ($AM_DIR/.list_cache) to avoid regenerating the
# display list on every fzf reload.  Cache is valid for 2 seconds and is
# invalidated when the tmux session count changes.
# Usage: fzf_list_sessions
# NOTE: Fallback-only. Primary path uses the compiled am-browse/am-list-internal Go binaries.
fzf_list_sessions() {
    # Background GC and title scan — don't block list rendering
    { registry_gc >/dev/null 2>&1; } &
    { auto_title_scan >/dev/null 2>&1; } &
    disown 2>/dev/null || true

    local cache_file="$AM_DIR/.list_cache"
    local current_count
    current_count=$(tmux_count_am_sessions)

    # Try to serve from cache: fresh (< 2s) and session count unchanged
    if [[ -f "$cache_file" ]]; then
        local cache_mtime
        cache_mtime=$(stat -f %m "$cache_file" 2>/dev/null || stat -c %Y "$cache_file" 2>/dev/null || echo 0)
        if (( $(date +%s) - cache_mtime < 2 )); then
            # First line is the stored session count; rest is cached output
            local stored_count
            { read -r stored_count; } < "$cache_file"
            if [[ "$stored_count" == "$current_count" ]]; then
                tail -n +2 "$cache_file"
                return
            fi
        fi
    fi

    # Cache miss — regenerate
    local output
    output=$(_fzf_list_display "with_name")

    # Write count + output atomically (write to tmp then rename)
    {
        printf '%s\n' "$current_count"
        [[ -n "$output" ]] && printf '%s\n' "$output"
    } > "${cache_file}.tmp" && mv -f "${cache_file}.tmp" "$cache_file" 2>/dev/null || true

    [[ -n "$output" ]] && printf '%s\n' "$output"
}

# Main fzf interface
# Usage: fzf_main
fzf_main() {
    # Get the path to this script's directory for the preview command
    local lib_dir="${AM_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

    # Try compiled TUI browser first (eliminates fzf + bash overhead)
    local browse_cmd="$lib_dir/../bin/am-browse"
    if [[ -x "$browse_cmd" ]]; then
        export AM_TMUX_SOCKET AM_DIR AM_SESSION_PREFIX
        local result
        result=$("$browse_cmd" \
            --preview-cmd="$lib_dir/preview" \
            --kill-cmd="$lib_dir/../bin/kill-and-switch") || return

        case "$result" in
            __NEW__)
                # Delegate to bash form (still needs tput/fzf)
                [[ "$(type -t am_new_session_form)" != "function" ]] && source "$_FZF_LIB_DIR/form.sh"
                local form_values directory agent_type task worktree_name flags
                if ! form_values=$(am_new_session_form); then
                    fzf_main
                    return $?
                fi
                IFS=$'\x1f' read -r directory agent_type task worktree_name flags <<< "$form_values"
                printf "__NEW_SESSION__\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n" "$directory" "$agent_type" "$flags" "$task" "$worktree_name"
                ;;
            __RESTORE__)
                local restore_result
                if ! restore_result=$(fzf_restore_picker); then
                    fzf_main
                    return $?
                fi
                echo "$restore_result"
                ;;
            "")
                # User cancelled
                ;;
            *)
                # Session name — attach
                echo "$result"
                ;;
        esac
        return
    fi

    # --- fzf fallback (when Go binary is not built) ---

    # Path to the list command for fzf reload subshells.
    # Prefer compiled binary; fall back to am entry point if not built.
    local list_cmd="$lib_dir/../bin/am-list-internal"
    [[ -x "$list_cmd" ]] || list_cmd="$lib_dir/../am list-internal"

    # Build preview command - use standalone script for speed
    local preview_cmd="$lib_dir/preview"

    # Resolve tmux client name lazily inside ctrl-x binding (saves ~18ms at startup)
    local client_name_cmd="tmux -L ${AM_TMUX_SOCKET} display-message -p '#{client_name}'"

    # Help text for ? key
    local help_text="
  Agent Manager Help

  Navigation
    Up/Down     Move selection
    Enter       Attach to selected session
    Esc/q       Exit without action

  Actions
    Ctrl-N      Create new session
    Ctrl-H      Restore a closed session
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

    # Run fzf — start with placeholder and load list async for instant frame render
    local selected
    selected=$(echo "__loading__|Loading..." | fzf \
        --sync \
        --ansi \
        --height=100% \
        --delimiter='|' \
        --with-nth=2 \
        --header="Agent Sessions  ?:help  Enter:attach  ^N:new  ^X:kill  ^H:restore" \
        --preview="$preview_cmd {1}" \
        --preview-window="bottom:75%:follow" \
        --bind="start:reload($list_cmd || echo '__new__|➕ Create new session')" \
        --bind="ctrl-j:preview-down,ctrl-k:preview-up" \
        --bind="ctrl-d:preview-half-page-down,ctrl-u:preview-half-page-up" \
        --bind="ctrl-r:reload($list_cmd)" \
        --bind="ctrl-p:toggle-preview" \
        --bind="ctrl-x:execute-silent($lib_dir/../bin/kill-and-switch \$($client_name_cmd) {1})+reload($list_cmd)" \
        --bind="?:preview(echo '$help_text')" \
        --expect="ctrl-n,ctrl-h" \
    )

    # Parse result
    local key session_name
    key=$(echo "$selected" | head -n1)
    session_name=$(echo "$selected" | tail -n1 | cut -d'|' -f1)

    # Handle restore request (Ctrl-H)
    if [[ "$key" == "ctrl-h" ]]; then
        local restore_result
        if ! restore_result=$(fzf_restore_picker); then
            fzf_main
            return $?
        fi
        echo "$restore_result"
        return 0
    fi

    # Handle new session request (either Ctrl-N or selecting the "new" option)
    if [[ "$key" == "ctrl-n" || "$session_name" == "__new__" ]]; then
        # Lazy-load form.sh (defines am_new_session_form)
        [[ "$(type -t am_new_session_form)" != "function" ]] && source "$_FZF_LIB_DIR/form.sh"
        local form_values directory agent_type task worktree_name flags
        if ! form_values=$(am_new_session_form); then
            fzf_main
            return $?
        fi

        IFS=$'\x1f' read -r directory agent_type task worktree_name flags <<< "$form_values"

        # Return new session command
        printf "__NEW_SESSION__\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n" "$directory" "$agent_type" "$flags" "$task" "$worktree_name"
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
    _fzf_list_display "without_name"
}

# Shared bulk-display helper for fzf_list_sessions and fzf_list_simple.
# NOTE: Fallback-only. Primary path uses compiled Go binaries.
# Reads all registry fields in one jq call, then formats each session inline.
# Usage: _fzf_list_display <mode>   (mode: "with_name" or "without_name")
_fzf_list_display() {
    local mode="$1"

    # Bulk-read tmux: session activity (sorted most recent first)
    local tmux_data
    tmux_data=$(am_tmux list-sessions -F '#{session_name} #{session_activity}' 2>/dev/null \
        | grep "^${AM_SESSION_PREFIX}" | sort -t' ' -k2 -rn || true)
    [[ -z "$tmux_data" ]] && return

    # Bulk-read all registry fields in one jq call
    local -A reg_dir reg_branch reg_agent reg_task
    local _rname _rdir _rbranch _ragent _rtask
    while IFS='|' read -r _rname _rdir _rbranch _ragent _rtask; do
        reg_dir[$_rname]=$_rdir
        reg_branch[$_rname]=$_rbranch
        reg_agent[$_rname]=$_ragent
        reg_task[$_rname]=$_rtask
    done < <(jq -r '.sessions | to_entries[] | [.key, .value.directory // "", .value.branch // "", .value.agent_type // "", .value.task // ""] | join("|")' "$AM_REGISTRY" 2>/dev/null || true)

    local now session activity
    now=$(date +%s)

    while IFS=' ' read -r session activity; do
        [[ -z "$session" ]] && continue

        local directory="${reg_dir[$session]:-}"
        local branch="${reg_branch[$session]:-}"
        local agent_type="${reg_agent[$session]:-}"
        local task="${reg_task[$session]:-}"

        local idle=0
        [[ -n "$activity" ]] && idle=$((now - activity))

        # Build display string (same format as agent_display_name)
        local display="$session"
        [[ -n "$directory" ]] && display="$display ${directory##*/}"
        [[ -n "$branch" ]] && display="$display/$branch"
        display="$display [${agent_type:-unknown}]"
        [[ -n "$task" ]] && display="$display $task"

        # Inline format_time_ago (avoids function call per session)
        local _ago
        if (( idle < 0 )); then _ago="just now"
        elif (( idle < 60 )); then _ago="${idle}s ago"
        elif (( idle < 3600 )); then _ago="$(( idle / 60 ))m ago"
        elif (( idle < 86400 )); then
            local _h=$(( idle / 3600 )) _m=$(( (idle % 3600) / 60 ))
            if (( _m == 0 )); then _ago="${_h}h ago"; else _ago="${_h}h ${_m}m ago"; fi
        else _ago="$(( idle / 86400 ))d ago"
        fi
        display="$display ($_ago)"

        if [[ "$mode" == "with_name" ]]; then
            echo "${session}|${display}"
        else
            echo "$display"
        fi
    done <<< "$tmux_data"
}

# JSON output for scripting
# Usage: fzf_list_json
fzf_list_json() {
    # Lazy-load state.sh — only this function needs parallel state detection
    [[ "$(type -t _agent_get_state_fast)" != "function" ]] && source "$_FZF_LIB_DIR/state.sh"
    # Warm the tmux config cache so subshells skip regeneration
    am_tmux_config_path >/dev/null 2>&1

    # Skip GC and title scan for JSON output — they cause I/O contention
    # and are not needed for a read-only snapshot. The interactive fzf path
    # (fzf_list_sessions) handles these.

    # Bulk-read tmux data: session_name activity created (one tmux call)
    local tmux_data
    tmux_data=$(am_tmux list-sessions -F '#{session_name} #{session_activity} #{session_created}' 2>/dev/null \
        | grep "^${AM_SESSION_PREFIX}" | sort -t' ' -k2 -rn || true)

    if [[ -z "$tmux_data" ]]; then
        echo "[]"
        return
    fi

    # Collect session names
    local session_names=()
    local -A tmux_activity tmux_created
    local _name _activity _created
    while IFS=' ' read -r _name _activity _created; do
        session_names+=("$_name")
        tmux_activity[$_name]=$_activity
        tmux_created[$_name]=$_created
    done <<< "$tmux_data"

    # Bulk-read all registry fields in one jq call
    # Use pipe delimiter (not tab — bash read collapses consecutive tabs)
    local -A reg_dir reg_branch reg_agent reg_task
    local _rname _rdir _rbranch _ragent _rtask
    while IFS='|' read -r _rname _rdir _rbranch _ragent _rtask; do
        reg_dir[$_rname]=$_rdir
        reg_branch[$_rname]=$_rbranch
        reg_agent[$_rname]=$_ragent
        reg_task[$_rname]=$_rtask
    done < <(jq -r '.sessions | to_entries[] | [.key, .value.directory // "", .value.branch // "", .value.agent_type // "", .value.task // ""] | join("|")' "$AM_REGISTRY" 2>/dev/null || true)

    # Parallel state detection using lean per-session function
    local state_tmpdir session
    state_tmpdir=$(mktemp -d)
    for session in "${session_names[@]}"; do
        ( _agent_get_state_fast "$session" "${reg_agent[$session]:-}" "${reg_dir[$session]:-}" \
            > "$state_tmpdir/$session" 2>/dev/null; true ) &
    done
    wait

    local -A session_states
    for session in "${session_names[@]}"; do
        [[ -f "$state_tmpdir/$session" ]] && session_states[$session]=$(< "$state_tmpdir/$session")
    done
    rm -rf "$state_tmpdir"

    # Build JSON array in one jq call using TSV input
    local tsv_lines=""
    for session in "${session_names[@]}"; do
        local state="${session_states[$session]:-}"
        tsv_lines+="${session}\t${state}\t${reg_dir[$session]:-}\t${reg_branch[$session]:-}\t${reg_agent[$session]:-}\t${reg_task[$session]:-}\t${tmux_activity[$session]:-0}\t${tmux_created[$session]:-0}\n"
    done

    printf '%b' "$tsv_lines" | jq -Rsn '
        [inputs | split("\n")[] | select(length > 0) | split("\t") |
         {name: .[0], state: .[1], directory: .[2], branch: .[3],
          agent_type: .[4], task: .[5],
          activity: (.[6] | tonumber), created: (.[7] | tonumber)}]'
}

# Restore picker: browse closed sessions and resume one
# Usage: fzf_restore_picker
# Returns: "__RESTORE__<US>directory<US>session_id" on success, or empty on cancel
fzf_restore_picker() {
    local lib_dir
    lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    local entries
    entries=$(sessions_log_restorable)
    if [[ -z "$entries" ]]; then
        log_info "No restorable sessions found" >&2
        return 1
    fi

    # Build display list: "session_id|directory|display|snapshot_file"
    # Bulk-parse all fields in one jq call (pipe entries through jq -sc)
    local all_fields
    all_fields=$(printf '%s\n' "$entries" | jq -r '[.session_id // "", .directory // "", .branch // "", .agent_type // "", .task // "", .closed_at // "", .created_at // "", .snapshot_file // ""] | join("|")' 2>/dev/null)

    local lines=""
    local now
    now=$(date +%s)

    while IFS='|' read -r sid dir branch agent task closed_at created_at snap; do
        [[ -z "$sid" ]] && continue

        # Calculate age from closed_at or created_at (timestamps are UTC)
        local ref_time="${closed_at:-$created_at}"
        local ref_epoch=0 age=0
        if [[ -n "$ref_time" ]]; then
            ref_epoch=$(date -d "$ref_time" +%s 2>/dev/null \
                || TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$ref_time" +%s 2>/dev/null \
                || echo 0)
            (( ref_epoch > 0 )) && age=$(( now - ref_epoch ))
        fi

        local display="${dir##*/}"
        [[ -n "$branch" ]] && display="${display}/${branch}"
        display="${display} [${agent}]"
        [[ -n "$task" ]] && display="${display} ${task}"

        # Inline format_time_ago (avoids function call per session)
        local _ago
        if (( age < 0 )); then _ago="just now"
        elif (( age < 60 )); then _ago="${age}s ago"
        elif (( age < 3600 )); then _ago="$(( age / 60 ))m ago"
        elif (( age < 86400 )); then
            local _h=$(( age / 3600 )) _m=$(( (age % 3600) / 60 ))
            if (( _m == 0 )); then _ago="${_h}h ago"; else _ago="${_h}h ${_m}m ago"; fi
        else _ago="$(( age / 86400 ))d ago"
        fi
        display="${display} ($_ago)"

        # Resolve snapshot to absolute path for preview
        local snap_path="${AM_DIR}/${snap}"
        [[ -z "$snap" || ! -f "$snap_path" ]] && snap_path=""

        lines+="${sid}|${dir}|${display}|${snap_path}"$'\n'
    done <<< "$all_fields"

    [[ -z "$lines" ]] && return 1

    # Preview command: show snapshot file (field 4 = absolute snapshot path)
    local preview_cmd="$lib_dir/restore-preview {4}"

    local selected
    selected=$(printf '%s' "$lines" | fzf \
        --sync \
        --ansi \
        --height=100% \
        --layout=reverse \
        --header-first \
        --prompt='/ ' \
        --pointer='>' \
        --delimiter='|' \
        --with-nth=3 \
        --header="Restore Session  Enter:resume  Esc:back" \
        --preview="$preview_cmd" \
        --preview-window="bottom:75%:wrap" \
    ) || return 1

    [[ -z "$selected" ]] && return 1

    local selected_sid selected_dir
    selected_sid=$(echo "$selected" | cut -d'|' -f1)
    selected_dir=$(echo "$selected" | cut -d'|' -f2)

    printf '__RESTORE__\x1f%s\x1f%s\n' "$selected_dir" "$selected_sid"
}
