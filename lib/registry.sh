# shellcheck shell=bash
# registry.sh - Session metadata storage using JSON

# Source utils if not already loaded
[[ -z "$AM_DIR" ]] && source "$(dirname "${BASH_SOURCE[0]}")/utils.sh"

# Ensure jq is available
require_cmd jq

# Add a session to the registry
# Usage: registry_add <name> <directory> <branch> <agent_type> [task_description]
registry_add() {
    local name="$1"
    local directory="$2"
    local branch="$3"
    local agent_type="$4"
    local task="${5:-}"

    local created_at
    created_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local tmp_file
    tmp_file=$(mktemp)

    jq --arg name "$name" \
       --arg dir "$directory" \
       --arg branch "$branch" \
       --arg agent "$agent_type" \
       --arg created "$created_at" \
       --arg task "$task" \
       '.sessions[$name] = {
           "name": $name,
           "directory": $dir,
           "branch": $branch,
           "agent_type": $agent,
           "created_at": $created,
           "task": $task
       }' "$AM_REGISTRY" > "$tmp_file" && command mv "$tmp_file" "$AM_REGISTRY"
}

# Get a specific field from a session
# Usage: registry_get_field <name> <field>
registry_get_field() {
    local name="$1"
    local field="$2"
    jq -r --arg name "$name" --arg field "$field" '.sessions[$name][$field] // empty' "$AM_REGISTRY"
}

# Get multiple fields from a session in one jq call
# Usage: registry_get_fields <name> <field1> [field2] ...
# Returns: pipe-delimited values, empty strings for missing fields
registry_get_fields() {
    local name="$1"; shift
    local fields=("$@")

    # Build jq template: "\(.field1 // "")|\(.field2 // "")|..."
    local parts=()
    local f
    for f in "${fields[@]}"; do
        parts+=("\\(.${f} // \"\")")
    done
    local template
    template=$(IFS='|'; echo "${parts[*]}")

    jq -r --arg name "$name" ".sessions[\$name] | \"${template}\"" "$AM_REGISTRY" 2>/dev/null
}

# Update a session field
# Usage: registry_update <name> <field> <value>
registry_update() {
    local name="$1"
    local field="$2"
    local value="$3"

    local tmp_file
    tmp_file=$(mktemp)

    jq --arg name "$name" \
       --arg field "$field" \
       --arg value "$value" \
       'if .sessions[$name] then .sessions[$name][$field] = $value else . end' \
       "$AM_REGISTRY" > "$tmp_file" && command mv "$tmp_file" "$AM_REGISTRY"
}

# Remove a session from the registry
# Usage: registry_remove <name>
registry_remove() {
    local name="$1"

    local tmp_file
    tmp_file=$(mktemp)

    jq --arg name "$name" 'del(.sessions[$name])' "$AM_REGISTRY" > "$tmp_file" && command mv "$tmp_file" "$AM_REGISTRY"
}

# List all sessions in the registry
# Usage: registry_list
# Returns newline-separated session names
registry_list() {
    jq -r '.sessions | keys[]' "$AM_REGISTRY" 2>/dev/null
}

# Garbage collection: remove registry entries for sessions that no longer exist in tmux
# Usage: registry_gc [force]
# Runs at most once per 60 seconds unless force=1
registry_gc() {
    local force="${1:-0}"

    # Time-based throttling: only run every 60 seconds
    local gc_marker="$AM_DIR/.gc_last"
    local now
    now=$(date +%s)

    if [[ "$force" != "1" && -f "$gc_marker" ]]; then
        local last_gc
        last_gc=$(cat "$gc_marker" 2>/dev/null || echo 0)
        if (( now - last_gc < 60 )); then
            echo "0"
            return 0
        fi
    fi

    # Update marker
    echo "$now" > "$gc_marker"

    local removed=0
    local orphaned_containers=0

    if [[ "$(type -t sandbox_gc_orphans)" == "function" ]]; then
        orphaned_containers=$(sandbox_gc_orphans)
        removed=$((removed + orphaned_containers))
    fi

    # Bulk-read live tmux sessions and registry in parallel (avoids N+1 tmux calls)
    local -A live_sessions
    local _sname
    while IFS= read -r _sname; do
        live_sessions[$_sname]=1
    done < <(tmux_list_am_sessions)

    # Bulk-read container_name for all registry entries (one jq call)
    local -A reg_containers
    local _rname _rcontainer
    while IFS='|' read -r _rname _rcontainer; do
        reg_containers[$_rname]=$_rcontainer
    done < <(jq -r '.sessions | to_entries[] | [.key, .value.container_name // ""] | join("|")' "$AM_REGISTRY" 2>/dev/null || true)

    local name
    for name in "${!reg_containers[@]}"; do
        if [[ -z "${live_sessions[$name]:-}" ]]; then
            # Clean up sandbox container if one exists
            if [[ -n "${reg_containers[$name]}" ]]; then
                sandbox_remove "$name"
            fi
            registry_remove "$name"
            rm -f "${AM_STATE_DIR:-/tmp/am-state}/$name"
            ((removed++))
        fi
    done

    # Clean up orphan hook state files (session gone but file remains)
    local state_dir="${AM_STATE_DIR:-/tmp/am-state}"
    if [[ -d "$state_dir" ]]; then
        local state_file sname
        for state_file in "$state_dir"/${AM_SESSION_PREFIX}*; do
            [[ -f "$state_file" ]] || continue
            sname=$(basename "$state_file")
            if [[ -z "${live_sessions[$sname]:-}" ]]; then
                rm -f "$state_file"
            fi
        done
    fi

    # Prune sessions log (for restore)
    sessions_log_gc 2>/dev/null || true

    if (( removed > 0 )); then
        log_info "Cleaned up $removed stale registry entries"
    fi

    echo "$removed"
}

# --- Session History ---
# Persistent log of sessions with their tasks, survives GC.
# Format: one JSON object per line in $AM_HISTORY

# Append a session to history and prune old entries
# Usage: history_append <directory> <task> <agent_type> <branch>
history_append() {
    local directory="$1"
    local task="$2"
    local agent_type="$3"
    local branch="$4"

    [[ -z "$task" ]] && return 0

    am_init

    local created_at
    created_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    printf '%s\n' "$(jq -cn \
        --arg dir "$directory" \
        --arg task "$task" \
        --arg agent "$agent_type" \
        --arg branch "$branch" \
        --arg created "$created_at" \
        '{directory: $dir, task: $task, agent_type: $agent, branch: $branch, created_at: $created}')" \
        >> "$AM_HISTORY"

    # Throttled prune: avoid full file rewrite on every append
    local _prune_marker="$AM_DIR/.prune_last"
    local _prune_now
    _prune_now=$(date +%s)
    if [[ -f "$_prune_marker" ]]; then
        local _prune_last
        _prune_last=$(cat "$_prune_marker" 2>/dev/null || echo 0)
        (( _prune_now - _prune_last < 3600 )) || { echo "$_prune_now" > "$_prune_marker"; history_prune; }
    else
        echo "$_prune_now" > "$_prune_marker"
        history_prune
    fi
}

# Remove history entries older than 7 days
history_prune() {
    [[ -f "$AM_HISTORY" ]] || return 0

    local cutoff
    cutoff=$(date -u -v-7d +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d "7 days ago" +"%Y-%m-%dT%H:%M:%SZ")

    local tmp_file
    tmp_file=$(mktemp)

    jq -c --arg cutoff "$cutoff" 'select(.created_at >= $cutoff)' "$AM_HISTORY" > "$tmp_file" 2>/dev/null
    command mv "$tmp_file" "$AM_HISTORY"
}

# Get recent sessions for a directory, most recent first
# Usage: history_for_directory <path>
# Returns: JSONL lines filtered to directory, newest first
history_for_directory() {
    local path="$1"
    [[ -f "$AM_HISTORY" ]] || return 0

    jq -c --arg dir "$path" 'select(.directory == $dir)' "$AM_HISTORY" 2>/dev/null | \
        jq -sc 'sort_by(.created_at) | reverse | .[]' 2>/dev/null
}

# --- Title Helpers ---

# Check if a title is valid (<=60 chars, no newlines)
# Usage: _title_valid <title> && echo yes
_title_valid() {
    local t="$1"
    [[ -n "$t" && ${#t} -le 60 && "$t" != *$'\n'* ]]
}

# Scan active sessions and update task from agent pane title.
# Agents set the terminal title via escape sequences; tmux exposes it as #{pane_title}.
# Throttled to once per 60s unless force=1.
# Logs to $AM_DIR/titler.log (tail -f ~/.agent-manager/titler.log)
# Usage: auto_title_scan [force]
auto_title_scan() {
    local force="${1:-0}"
    local _log="$AM_DIR/titler.log"

    _titler_log() { echo "$(date '+%H:%M:%S') $*" >> "$_log" 2>/dev/null; }

    # Throttle
    local marker="$AM_DIR/.title_scan_last"
    local now
    now=$(date +%s)
    if [[ "$force" != "1" && -f "$marker" ]]; then
        local last
        last=$(cat "$marker" 2>/dev/null || echo 0)
        if (( now - last < 60 )); then
            _titler_log "throttled ($(( now - last ))s since last scan)"
            return 0
        fi
    fi
    echo "$now" > "$marker"

    _titler_log "scan start (force=$force)"

    # Bulk-read all sessions with their fields in one jq call (avoids N+1 registry reads)
    local -A reg_task reg_dir reg_branch reg_agent
    local _rname _rtask _rdir _rbranch _ragent
    while IFS='|' read -r _rname _rtask _rdir _rbranch _ragent; do
        reg_task[$_rname]=$_rtask
        reg_dir[$_rname]=$_rdir
        reg_branch[$_rname]=$_rbranch
        reg_agent[$_rname]=$_ragent
    done < <(jq -r '.sessions | to_entries[] | [.key, .value.task // "", .value.directory // "", .value.branch // "", .value.agent_type // ""] | join("|")' "$AM_REGISTRY" 2>/dev/null || true)

    local name title scanned=0 updated=0
    for name in "${!reg_task[@]}"; do
        scanned=$((scanned + 1))

        # Read the agent pane title (set by the agent via terminal escape sequences)
        title=$(tmux_pane_title "${name}:.{top}" 2>/dev/null) || continue
        # Trim leading non-alphanumeric characters (escape artifacts, symbols)
        title=$(echo "$title" | sed -E 's/^[^[:alnum:]]*//')

        if ! _title_valid "$title"; then
            _titler_log "  $name: skip (invalid pane title: ${title:0:40})"
            continue
        fi

        # Skip if title hasn't changed
        [[ "$title" == "${reg_task[$name]}" ]] && continue

        registry_update "$name" "task" "$title"
        # Append to history on first title (was previously untitled)
        if [[ -z "${reg_task[$name]}" ]]; then
            history_append "${reg_dir[$name]}" "$title" "${reg_agent[$name]}" "${reg_branch[$name]}"
        fi
        updated=$((updated + 1))
        _titler_log "  $name: title=\"$title\""
    done

    # --- Rolling snapshots + session_id backfill (Claude sessions only) ---
    if [[ -f "$AM_SESSIONS_LOG" ]]; then
        # Build lookup of sessions_log entries needing backfill or snapshot
        local -A slog_sid slog_snap
        local _sl_sname _sl_sid _sl_snap
        while IFS= read -r _sl_line; do
            [[ -z "$_sl_line" ]] && continue
            local _sl_fields
            _sl_fields=$(printf '%s' "$_sl_line" | jq -r '[.session_name // "", .session_id // "", .snapshot_file // ""] | join("|")' 2>/dev/null)
            IFS='|' read -r _sl_sname _sl_sid _sl_snap <<< "$_sl_fields"
            # Keep last entry per session_name
            slog_sid[$_sl_sname]="$_sl_sid"
            slog_snap[$_sl_sname]="$_sl_snap"
        done < "$AM_SESSIONS_LOG"

        local snap_count=0
        for name in "${!reg_agent[@]}"; do
            [[ "${reg_agent[$name]}" == "claude" ]] || continue
            # Only process sessions that have a log entry
            [[ -n "${slog_sid[$name]+x}" ]] || continue

            local sid="${slog_sid[$name]}"

            # Backfill session_id if empty
            if [[ -z "$sid" && -n "${reg_dir[$name]}" ]]; then
                sid=$(_sessions_log_detect_id "${reg_dir[$name]}")
                if [[ -n "$sid" ]]; then
                    sessions_log_update "$name" "session_id" "$sid"
                    slog_sid[$name]="$sid"
                    _titler_log "  $name: backfilled session_id=$sid"
                    # Rename snapshot file from session_name to session_id
                    if [[ -f "$AM_SNAPSHOTS_DIR/${name}.txt" ]]; then
                        command mv "$AM_SNAPSHOTS_DIR/${name}.txt" "$AM_SNAPSHOTS_DIR/${sid}.txt" 2>/dev/null || true
                        sessions_log_update "$name" "snapshot_file" "snapshots/${sid}.txt"
                    fi
                fi
            fi

            # Capture pane snapshot
            local snap_key="${sid:-$name}"
            local snap_file
            snap_file=$(sessions_log_snapshot "$name" "$snap_key")
            if [[ -n "$snap_file" ]]; then
                # Update snapshot_file in log if changed
                if [[ "$snap_file" != "${slog_snap[$name]}" ]]; then
                    sessions_log_update "$name" "snapshot_file" "$snap_file"
                fi
                ((snap_count++))
            fi
        done
        _titler_log "  snapshots captured: $snap_count"

        # Also update task in sessions log if title changed
        for name in "${!reg_agent[@]}"; do
            [[ "${reg_agent[$name]}" == "claude" ]] || continue
            [[ -n "${slog_sid[$name]+x}" ]] || continue
            local current_task="${reg_task[$name]}"
            [[ -n "$current_task" ]] && sessions_log_update "$name" "task" "$current_task"
        done
    fi

    _titler_log "scan done: $scanned scanned, $updated updated"
}

# --- Sessions Log (for session restore) ---
# Persistent log of all sessions with Claude session IDs and pane snapshots.
# Unlike history.jsonl, this stores session_id for --resume and snapshot paths.
# Pruned when the backing Claude JSONL is deleted, not by time.

# Append a new session to the sessions log.
# Usage: sessions_log_append <session_name> <directory> <branch> <agent_type> [task]
sessions_log_append() {
    local session_name="$1"
    local directory="$2"
    local branch="$3"
    local agent_type="$4"
    local task="${5:-}"

    am_init
    mkdir -p "$AM_SNAPSHOTS_DIR"

    local created_at
    created_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    printf '%s\n' "$(jq -cn \
        --arg sname "$session_name" \
        --arg sid "" \
        --arg dir "$directory" \
        --arg branch "$branch" \
        --arg agent "$agent_type" \
        --arg task "$task" \
        --arg created "$created_at" \
        --arg snap "" \
        '{session_name: $sname, session_id: $sid, directory: $dir, branch: $branch,
          agent_type: $agent, task: $task, created_at: $created, closed_at: null,
          snapshot_file: $snap}')" \
        >> "$AM_SESSIONS_LOG"
}

# Update a field in the most recent sessions log entry for a session.
# Usage: sessions_log_update <session_name> <field> <value>
sessions_log_update() {
    local session_name="$1"
    local field="$2"
    local value="$3"

    [[ -f "$AM_SESSIONS_LOG" ]] || return 0

    local tmp_file
    tmp_file=$(mktemp)

    # Update the LAST entry matching session_name (most recent launch)
    jq -c --arg sname "$session_name" --arg field "$field" --arg value "$value" '
        if .session_name == $sname then .[$field] = $value else . end
    ' "$AM_SESSIONS_LOG" > "$tmp_file" 2>/dev/null

    # Only the last match should be updated — reverse, update first, reverse back
    tac "$AM_SESSIONS_LOG" | jq -c --arg sname "$session_name" --arg field "$field" --arg value "$value" '
        . as $entry | if ($entry.session_name == $sname) then null else . end
    ' > /dev/null 2>&1 || true

    # Simpler approach: rewrite with awk-style last-match logic via jq slurp
    jq -sc --arg sname "$session_name" --arg field "$field" --arg value "$value" '
        (length - 1 - ([range(length)] | reverse | map(select(.[0] == $sname)) | .[0] // -1)) as $idx |
        . # this is getting complex, use a different approach
    ' "$AM_SESSIONS_LOG" > /dev/null 2>&1 || true

    # Pragmatic approach: read all lines, find last matching index, update it
    rm -f "$tmp_file"
    tmp_file=$(mktemp)
    local last_idx=-1 idx=0
    while IFS= read -r line; do
        local sname_check
        sname_check=$(printf '%s' "$line" | jq -r '.session_name // ""' 2>/dev/null)
        if [[ "$sname_check" == "$session_name" ]]; then
            last_idx=$idx
        fi
        ((idx++))
    done < "$AM_SESSIONS_LOG"

    if (( last_idx < 0 )); then
        rm -f "$tmp_file"
        return 0
    fi

    idx=0
    while IFS= read -r line; do
        if (( idx == last_idx )); then
            printf '%s\n' "$line" | jq -c --arg field "$field" --arg value "$value" '.[$field] = $value' >> "$tmp_file"
        else
            printf '%s\n' "$line" >> "$tmp_file"
        fi
        ((idx++))
    done < "$AM_SESSIONS_LOG"

    command mv "$tmp_file" "$AM_SESSIONS_LOG"
}

# Capture a pane snapshot and save to snapshots directory.
# Usage: sessions_log_snapshot <session_name> [snapshot_key]
# snapshot_key defaults to session_name; set to session_id when known.
# Returns: snapshot filename (relative to AM_DIR) on stdout
sessions_log_snapshot() {
    local session_name="$1"
    local snapshot_key="${2:-$session_name}"

    mkdir -p "$AM_SNAPSHOTS_DIR"

    local pane_target content
    pane_target=$(tmux_session_pane_target "$session_name" "agent" 2>/dev/null) || pane_target="${session_name}:.{top}"
    content=$(tmux_capture_pane "$pane_target" 50 2>/dev/null || true)

    [[ -z "$content" ]] && return 0

    local snap_file="snapshots/${snapshot_key}.txt"
    printf '%s\n' "$content" > "$AM_DIR/$snap_file"
    echo "$snap_file"
}

# Encode a path as a Claude project directory name (/ and . become -).
# Local copy of _state_encode_dir to avoid depending on state.sh.
_slog_encode_dir() {
    echo "$1" | sed -E 's|[/.]|-|g'
}

# Detect the Claude session ID for a directory.
# Usage: _sessions_log_detect_id <directory>
# Returns the session UUID of the most recently modified JSONL file.
# Returns: session UUID on stdout, or empty
_sessions_log_detect_id() {
    local dir="$1"

    local resolved encoded project_dir
    resolved=$(cd "$dir" 2>/dev/null && pwd -P) || resolved="$dir"
    encoded=$(_slog_encode_dir "$resolved")
    project_dir="$HOME/.claude/projects/$encoded"
    [[ -d "$project_dir" ]] || return 0

    local jsonl_path
    jsonl_path=$(command ls -t "$project_dir"/*.jsonl 2>/dev/null | head -1)
    [[ -n "$jsonl_path" && -f "$jsonl_path" ]] || return 0
    basename "$jsonl_path" .jsonl
}

# Check if a Claude JSONL file still exists for a given directory and session_id.
# Usage: _sessions_log_jsonl_exists <directory> <session_id>
_sessions_log_jsonl_exists() {
    local dir="$1"
    local session_id="$2"

    local resolved encoded project_dir
    resolved=$(cd "$dir" 2>/dev/null && pwd -P) || resolved="$dir"
    encoded=$(_slog_encode_dir "$resolved")
    project_dir="$HOME/.claude/projects/$encoded"
    [[ -f "$project_dir/${session_id}.jsonl" ]]
}

# GC for sessions log: remove entries whose Claude JSONL no longer exists.
# Usage: sessions_log_gc
sessions_log_gc() {
    [[ -f "$AM_SESSIONS_LOG" ]] || return 0

    local tmp_file
    tmp_file=$(mktemp)
    local removed=0
    local now
    now=$(date +%s)
    local cutoff_24h=$(( now - 86400 ))

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local agent sid dir created_at
        local _fields
        _fields=$(printf '%s' "$line" | jq -r '[.agent_type // "", .session_id // "", .directory // "", .created_at // ""] | join("|")' 2>/dev/null)
        IFS='|' read -r agent sid dir created_at <<< "$_fields"

        local keep=true

        if [[ "$agent" == "claude" && -n "$sid" && -n "$dir" ]]; then
            if ! _sessions_log_jsonl_exists "$dir" "$sid"; then
                keep=false
            fi
        elif [[ "$agent" == "claude" && -z "$sid" ]]; then
            # No session_id — prune if older than 24h (failed launch)
            local created_epoch=0
            created_epoch=$(date -d "$created_at" +%s 2>/dev/null \
                || TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$created_at" +%s 2>/dev/null \
                || echo 0)
            if (( created_epoch > 0 && created_epoch < cutoff_24h )); then
                keep=false
            fi
        fi

        if $keep; then
            printf '%s\n' "$line" >> "$tmp_file"
        else
            # Delete snapshot file
            local snap
            snap=$(printf '%s' "$line" | jq -r '.snapshot_file // ""' 2>/dev/null)
            [[ -n "$snap" && -f "$AM_DIR/$snap" ]] && rm -f "$AM_DIR/$snap"
            ((removed++))
        fi
    done < "$AM_SESSIONS_LOG"

    command mv "$tmp_file" "$AM_SESSIONS_LOG"

    if (( removed > 0 )); then
        log_info "Sessions log: pruned $removed stale entries"
    fi
}

# List restorable sessions for the restore picker.
# Usage: sessions_log_restorable
# Returns: JSONL lines for sessions that can be restored (not alive, JSONL exists)
sessions_log_restorable() {
    [[ -f "$AM_SESSIONS_LOG" ]] || return 0

    # Get set of live tmux sessions
    local -A live_sessions
    local _sname
    while IFS= read -r _sname; do
        live_sessions[$_sname]=1
    done < <(tmux_list_am_sessions)

    # Deduplicate: keep only the latest entry per session_id
    # (a session could appear multiple times if relaunched)
    local -A seen_ids
    local lines=()

    # Read in reverse (newest first), keep first occurrence of each session_id
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        lines+=("$line")
    done < "$AM_SESSIONS_LOG"

    local i result=()
    for (( i=${#lines[@]}-1; i>=0; i-- )); do
        local line="${lines[$i]}"
        local _fields
        _fields=$(printf '%s' "$line" | jq -r '[.session_name // "", .session_id // "", .agent_type // "", .directory // ""] | join("|")' 2>/dev/null)
        local sname sid agent dir
        IFS='|' read -r sname sid agent dir <<< "$_fields"

        # Skip non-claude, no session_id, still alive
        [[ "$agent" == "claude" ]] || continue
        [[ -n "$sid" ]] || continue
        [[ -z "${live_sessions[$sname]:-}" ]] || continue
        [[ -z "${seen_ids[$sid]:-}" ]] || continue

        # Check JSONL still exists
        if _sessions_log_jsonl_exists "$dir" "$sid"; then
            seen_ids[$sid]=1
            result+=("$line")
        fi
    done

    # Output newest first
    for line in "${result[@]}"; do
        printf '%s\n' "$line"
    done
}
