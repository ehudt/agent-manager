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
    local dir_preview_cmd="$_FZF_LIB_DIR/dir-preview"

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

# Main interactive browser entry point (compiled Go TUI)
# Usage: fzf_main
fzf_main() {
    # Get the path to this script's directory for the preview command
    local lib_dir="${AM_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

    # Require non-zero size so test_install's fake-go stub doesn't fire.
    local browse_cmd="$lib_dir/../bin/am-browse"
    if [[ ! -x "$browse_cmd" || ! -s "$browse_cmd" ]]; then
        log_error "bin/am-browse is not built. Run 'make' (or 'am install') to build it."
        return 1
    fi

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
}

# Shared session row collector for `am list` text and JSON output.
# Output fields are separated by ASCII unit separator:
# name, state, directory, branch, agent_type, task, activity, created
# Usage: _fzf_session_rows
_fzf_session_rows() {
    # Lazy-load state.sh — only list/status JSON and plain CLI listing need state.
    [[ "$(type -t _state_resolve)" != "function" ]] && source "$_FZF_LIB_DIR/state.sh"
    # Warm the tmux config cache so parallel state subshells skip regeneration.
    am_tmux_config_path >/dev/null 2>&1

    local sep=$'\x1f'

    # Bulk-read tmux data: session_name activity created (one tmux call)
    local tmux_data
    tmux_data=$(am_tmux list-sessions -F '#{session_name} #{session_activity} #{session_created}' 2>/dev/null \
        | grep "^${AM_SESSION_PREFIX}" | sort -t' ' -k2 -rn || true)
    [[ -z "$tmux_data" ]] && return

    # Collect session names and tmux metadata.
    local session_names=()
    local -A tmux_activity tmux_created
    local _name _activity _created
    while IFS=' ' read -r _name _activity _created; do
        [[ -z "$_name" ]] && continue
        session_names+=("$_name")
        tmux_activity[$_name]=$_activity
        tmux_created[$_name]=$_created
    done <<< "$tmux_data"

    # Bulk-read all registry fields in one jq call.
    local -A reg_dir reg_branch reg_agent reg_task
    local _rname _rdir _rbranch _ragent _rtask
    while IFS=$'\x1f' read -r _rname _rdir _rbranch _ragent _rtask; do
        [[ -z "$_rname" ]] && continue
        reg_dir[$_rname]=$_rdir
        reg_branch[$_rname]=$_rbranch
        reg_agent[$_rname]=$_ragent
        reg_task[$_rname]=$_rtask
    done < <(jq -r --arg sep "$sep" '.sessions | to_entries[] | [.key, .value.directory // "", .value.branch // "", .value.agent_type // "", .value.task // ""] | join($sep)' "$AM_REGISTRY" 2>/dev/null || true)

    # Parallel state detection. _state_resolve in non-bulk mode handles its
    # own per-session tmux/ps lookups; running each session in its own
    # subshell keeps the fork-fanout overlapping.
    local state_tmpdir session
    state_tmpdir=$(mktemp -d)
    for session in "${session_names[@]}"; do
        ( _state_resolve "$session" "${reg_agent[$session]:-}" "${reg_dir[$session]:-}" \
            > "$state_tmpdir/$session" 2>/dev/null; true ) &
    done
    wait

    local -A session_states
    for session in "${session_names[@]}"; do
        [[ -f "$state_tmpdir/$session" ]] && session_states[$session]=$(< "$state_tmpdir/$session")
    done
    rm -rf "$state_tmpdir"

    for session in "${session_names[@]}"; do
        printf '%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s\n' \
            "$session" "$sep" \
            "${session_states[$session]:-}" "$sep" \
            "${reg_dir[$session]:-}" "$sep" \
            "${reg_branch[$session]:-}" "$sep" \
            "${reg_agent[$session]:-}" "$sep" \
            "${reg_task[$session]:-}" "$sep" \
            "${tmux_activity[$session]:-0}" "$sep" \
            "${tmux_created[$session]:-0}"
    done
}

_fzf_format_plain_row() {
    local session="$1"
    local directory="$2"
    local branch="$3"
    local agent_type="$4"
    local task="$5"
    local activity="$6"

    local now idle
    now=$(date +%s)
    idle=0
    [[ -n "$activity" ]] && idle=$((now - activity))

    local display="$session"
    [[ -n "$directory" ]] && display="$display ${directory##*/}"
    [[ -n "$branch" ]] && display="$display/$branch"
    display="$display [${agent_type:-unknown}]"
    [[ -n "$task" ]] && display="$display $task"
    display="$display ($(format_time_ago "$idle"))"

    echo "$display"
}

# Simplified list output (no fzf, just print)
# Usage: fzf_list_simple
fzf_list_simple() {
    local rows
    rows=$(_fzf_session_rows)
    [[ -z "$rows" ]] && return

    while IFS=$'\x1f' read -r session _state directory branch agent_type task activity _created; do
        [[ -z "$session" ]] && continue
        _fzf_format_plain_row "$session" "$directory" "$branch" "$agent_type" "$task" "$activity"
    done <<< "$rows"
}

# JSON output for scripting
# Usage: fzf_list_json
fzf_list_json() {
    # Skip GC and title scan for JSON output — they cause I/O contention
    # and are not needed for a read-only snapshot.

    local rows sep
    rows=$(_fzf_session_rows)
    sep=$'\x1f'

    printf '%s\n' "$rows" | jq -R -s --arg sep "$sep" '
        split("\n") | map(select(length > 0) | split($sep) |
         {name: .[0], state: .[1], directory: .[2], branch: .[3],
          agent_type: .[4], task: .[5],
          activity: (.[6] | tonumber), created: (.[7] | tonumber)})'
}

# Restore picker: browse closed sessions and resume one
# Usage: fzf_restore_picker
# Returns: "__RESTORE__<US>directory<US>session_id<US>agent_type" on success, or empty on cancel
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

        display="${display} ($(format_time_ago "$age"))"

        # Resolve snapshot to absolute path for preview
        local snap_path="${AM_DIR}/${snap}"
        [[ -z "$snap" || ! -f "$snap_path" ]] && snap_path=""

        lines+="${sid}|${dir}|${display}|${snap_path}|${agent}"$'\n'
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

    local selected_sid selected_dir selected_agent
    selected_sid=$(echo "$selected" | cut -d'|' -f1)
    selected_dir=$(echo "$selected" | cut -d'|' -f2)
    selected_agent=$(echo "$selected" | cut -d'|' -f5)

    printf '__RESTORE__\x1f%s\x1f%s\x1f%s\n' "$selected_dir" "$selected_sid" "${selected_agent:-claude}"
}
