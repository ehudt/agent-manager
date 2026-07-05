# shellcheck shell=bash
# registry.sh - Session metadata storage using JSON

# Source utils if not already loaded
[[ -z "$AM_DIR" ]] && source "${AM_LIB_DIR:-$(dirname "${BASH_SOURCE[0]}")}/utils.sh"

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

# Garbage collection: remove registry entries for sessions that no longer exist in tmux
# Usage: registry_gc [force]
# Two independently throttled halves (60s each, unless force=1):
#   - Registry rows + hook state files: marker .gc_last, shared with the Go
#     twin (internal/sessions ReapOrphans) which does the same work.
#   - Bash-only extras (sandbox containers, sessions log GC, orphan state-file
#     sweep): marker .gc_extras_last. The Go twin never does this work, so it
#     must not be skipped just because Go stamped .gc_last first.
registry_gc() {
    local force="${1:-0}"
    local now
    now=$(date +%s)
    local removed=0

    local run_rows=1 run_extras=1
    if [[ "$force" != "1" ]]; then
        local last
        last=$(cat "$AM_DIR/.gc_last" 2>/dev/null || echo 0)
        (( now - last < 60 )) && run_rows=0
        last=$(cat "$AM_DIR/.gc_extras_last" 2>/dev/null || echo 0)
        (( now - last < 60 )) && run_extras=0
    fi
    if (( !run_rows && !run_extras )); then
        echo "0"
        return 0
    fi

    # Bulk-read live tmux sessions once (avoids N+1 tmux calls)
    local -A live_sessions
    local _sname
    while IFS= read -r _sname; do
        live_sessions[$_sname]=1
    done < <(tmux_list_am_sessions)

    # --- Registry rows + hook state files (Go twin: ReapOrphans) ---
    if (( run_rows )); then
        echo "$now" > "$AM_DIR/.gc_last"

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
                rm -f "${AM_STATE_DIR:-/tmp/am-state}/$name" \
                      "${AM_STATE_DIR:-/tmp/am-state}/$name.sid"
                ((removed++))
            fi
        done
    fi

    # --- Bash-only extras (no Go twin) ---
    if (( run_extras )); then
        echo "$now" > "$AM_DIR/.gc_extras_last"

        if [[ "$(type -t sandbox_gc_orphans)" == "function" ]]; then
            local orphaned_containers
            orphaned_containers=$(sandbox_gc_orphans)
            removed=$((removed + orphaned_containers))
        fi

        # Clean up orphan hook state files and sidecars (session gone but file remains).
        # State file is "<session>", sidecar is "<session>.sid" — strip the suffix
        # before checking liveness so live sessions don't lose their sidecar.
        local state_dir="${AM_STATE_DIR:-/tmp/am-state}"
        if [[ -d "$state_dir" ]]; then
            local state_file sname
            for state_file in "$state_dir"/${AM_SESSION_PREFIX}*; do
                [[ -f "$state_file" ]] || continue
                sname=$(basename "$state_file")
                sname="${sname%.sid}"
                if [[ -z "${live_sessions[$sname]:-}" ]]; then
                    rm -f "$state_file"
                fi
            done
        fi

        # Prune sessions log (for restore)
        sessions_log_gc 2>/dev/null || true
    fi

    if (( removed > 0 )); then
        log_info "Cleaned up $removed stale registry entries"
    fi

    echo "$removed"
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

    # Throttle. The Go twin (internal/sessions RefreshTitles) shares this
    # marker but never does the restore-log work, so on the throttled path we
    # still run sessions_log_scan (it has its own marker).
    local marker="$AM_DIR/.title_scan_last"
    local now
    now=$(date +%s)
    if [[ "$force" != "1" && -f "$marker" ]]; then
        local last
        last=$(cat "$marker" 2>/dev/null || echo 0)
        if (( now - last < 60 )); then
            _titler_log "throttled ($(( now - last ))s since last scan)"
            sessions_log_scan "$force"
            return 0
        fi
    fi
    echo "$now" > "$marker"

    _titler_log "scan start (force=$force)"

    # Bulk-read all sessions with their fields in one jq call (avoids N+1 registry reads)
    local -A reg_task reg_dir reg_agent reg_created
    local _rname _rtask _rdir _ragent _rcreated
    while IFS='|' read -r _rname _rtask _rdir _ragent _rcreated; do
        reg_task[$_rname]=$_rtask
        reg_dir[$_rname]=$_rdir
        reg_agent[$_rname]=$_ragent
        reg_created[$_rname]=$_rcreated
    done < <(jq -r '.sessions | to_entries[] | [.key, .value.task // "", .value.directory // "", .value.agent_type // "", .value.created_at // ""] | join("|")' "$AM_REGISTRY" 2>/dev/null || true)

    local name title scanned=0 updated=0
    for name in "${!reg_task[@]}"; do
        scanned=$((scanned + 1))

        # Read the agent pane title (set by the agent via terminal escape sequences)
        title=$(tmux_pane_title "${name}:.{top}" 2>/dev/null) || title=""
        # Trim leading non-alphanumeric characters (escape artifacts, symbols)
        title=$(echo "$title" | sed -E 's/^[^[:alnum:]]*//')

        if ! _title_valid "$title"; then
            # Fallback: for Claude sessions, derive task from JSONL first user message.
            # Covers fresh sessions (title not painted yet), bash-only panes, and
            # legacy sessions created before auto-titling existed.
            local fallback=""
            if [[ "${reg_agent[$name]}" == "claude" && -n "${reg_dir[$name]}" ]]; then
                # Resolve THIS session's Claude id (sidecar, else mtime>=created)
                # so two sessions in one directory don't share the newest JSONL's
                # first message as their title.
                local _sid
                _sid=$(_sessions_log_detect_id_for_session "$name" "${reg_dir[$name]}" "${reg_created[$name]}" 2>/dev/null || true)
                # strict=1: if we can't pin this session's id, don't guess from
                # a directory with multiple JSONLs (would inherit a sibling's task).
                fallback=$(claude_first_user_message "${reg_dir[$name]}" "$_sid" 1 2>/dev/null || true)
                fallback="${fallback:0:60}"
            fi
            if [[ -n "$fallback" ]] && _title_valid "$fallback"; then
                title="$fallback"
                _titler_log "  $name: jsonl fallback=\"$title\""
            else
                _titler_log "  $name: skip (no valid title: pane=${title:0:40})"
                continue
            fi
        fi

        # Skip if title hasn't changed
        [[ "$title" == "${reg_task[$name]}" ]] && continue

        registry_update "$name" "task" "$title"
        updated=$((updated + 1))
        _titler_log "  $name: title=\"$title\""
    done

    sessions_log_scan "$force"

    _titler_log "scan done: $scanned scanned, $updated updated"
}

# Rolling snapshots + session_id backfill + sessions-log task sync (Claude
# sessions only). Bash-only restore plumbing with no Go twin, so it runs on
# its own throttle marker (.restore_scan_last) — the Go title scanner stamping
# .title_scan_last must not starve it.
# Usage: sessions_log_scan [force]
sessions_log_scan() {
    local force="${1:-0}"
    [[ -f "$AM_SESSIONS_LOG" ]] || return 0

    local _log="$AM_DIR/titler.log"
    _titler_log() { echo "$(date '+%H:%M:%S') $*" >> "$_log" 2>/dev/null; }

    # Throttle (independent of .title_scan_last)
    local marker="$AM_DIR/.restore_scan_last"
    local now
    now=$(date +%s)
    if [[ "$force" != "1" && -f "$marker" ]]; then
        local last
        last=$(cat "$marker" 2>/dev/null || echo 0)
        (( now - last < 60 )) && return 0
    fi
    echo "$now" > "$marker"

    # Bulk-read registry fields (one jq call)
    local -A reg_task reg_dir reg_agent reg_created
    local _rname _rtask _rdir _ragent _rcreated
    while IFS='|' read -r _rname _rtask _rdir _ragent _rcreated; do
        reg_task[$_rname]=$_rtask
        reg_dir[$_rname]=$_rdir
        reg_agent[$_rname]=$_ragent
        reg_created[$_rname]=$_rcreated
    done < <(jq -r '.sessions | to_entries[] | [.key, .value.task // "", .value.directory // "", .value.agent_type // "", .value.created_at // ""] | join("|")' "$AM_REGISTRY" 2>/dev/null || true)

    # Build lookup of sessions_log entries (bulk parse — one jq call)
    local -A slog_sid slog_snap
    local _sl_sname _sl_sid _sl_snap
    while IFS='|' read -r _sl_sname _sl_sid _sl_snap; do
        [[ -z "$_sl_sname" ]] && continue
        # Keep last entry per session_name (later lines overwrite)
        slog_sid[$_sl_sname]="$_sl_sid"
        slog_snap[$_sl_sname]="$_sl_snap"
    done < <(jq -r '[.session_name // "", .session_id // "", .snapshot_file // ""] | join("|")' "$AM_SESSIONS_LOG" 2>/dev/null)

    local name snap_count=0
    for name in "${!reg_agent[@]}"; do
        [[ "${reg_agent[$name]}" == "claude" ]] || continue
        # Only process sessions that have a log entry
        [[ -n "${slog_sid[$name]+x}" ]] || continue

        local sid="${slog_sid[$name]}"

        # The hook sidecar is authoritative — it was written by the agent pane
        # itself. Correct the logged sid whenever it disagrees (heals wrong
        # mtime-based guesses and tracks forked resumes); fall back to
        # directory detection only while no sidecar exists yet.
        local sidecar_sid=""
        if [[ -n "${reg_dir[$name]}" ]]; then
            sidecar_sid=$(_sessions_log_sidecar_id "$name")
            if [[ -n "$sidecar_sid" ]] && ! _sessions_log_jsonl_exists "${reg_dir[$name]}" "$sidecar_sid"; then
                sidecar_sid=""
            fi
        fi
        if [[ -n "$sidecar_sid" && "$sidecar_sid" != "$sid" ]]; then
            sessions_log_update "$name" "session_id" "$sidecar_sid"
            _titler_log "  $name: session_id ${sid:-<empty>} -> $sidecar_sid (sidecar)"
            sid="$sidecar_sid"
            slog_sid[$name]="$sid"
        elif [[ -z "$sid" && -n "${reg_dir[$name]}" ]]; then
            sid=$(_sessions_log_detect_id_for_session "$name" "${reg_dir[$name]}" "${reg_created[$name]}")
            if [[ -n "$sid" ]]; then
                sessions_log_update "$name" "session_id" "$sid"
                slog_sid[$name]="$sid"
                _titler_log "  $name: backfilled session_id=$sid"
            fi
        fi
        # Migrate a snapshot still keyed by session_name once the sid is known
        if [[ -n "$sid" && -f "$AM_SNAPSHOTS_DIR/${name}.txt" ]]; then
            command mv "$AM_SNAPSHOTS_DIR/${name}.txt" "$AM_SNAPSHOTS_DIR/${sid}.txt" 2>/dev/null || true
            sessions_log_update "$name" "snapshot_file" "snapshots/${sid}.txt"
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

    # Also sync task into the sessions log
    for name in "${!reg_agent[@]}"; do
        [[ "${reg_agent[$name]}" == "claude" ]] || continue
        [[ -n "${slog_sid[$name]+x}" ]] || continue
        local current_task="${reg_task[$name]}"
        [[ -n "$current_task" ]] && sessions_log_update "$name" "task" "$current_task"
    done
}

# --- Sessions Log (for session restore) ---
# Persistent log of all sessions with Claude session IDs and pane snapshots.
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

    # Single jq -sc call: slurp all lines, find and update the last matching entry
    if jq -sc --arg sname "$session_name" --arg field "$field" --arg value "$value" '
        . as $arr |
        (reduce range(length) as $i (-1;
            if $arr[$i].session_name == $sname then $i else . end)) as $last_idx |
        if $last_idx >= 0 then .[$last_idx][$field] = $value else . end |
        .[]
    ' "$AM_SESSIONS_LOG" > "$tmp_file" 2>/dev/null; then
        command mv "$tmp_file" "$AM_SESSIONS_LOG"
    else
        rm -f "$tmp_file"
    fi
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
# Mirrored in Go (internal/sessions encodedClaudeProjectDir) and inline in
# utils.sh claude_first_user_message.
_slog_encode_dir() {
    echo "$1" | sed -E 's|[/.]|-|g'
}

_slog_iso_epoch() {
    local value="$1"
    [[ -n "$value" ]] || return 1
    date -d "$value" +%s 2>/dev/null \
        || TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$value" +%s 2>/dev/null
}

_slog_file_mtime() {
    local path="$1"
    stat -c %Y "$path" 2>/dev/null || stat -f %m "$path" 2>/dev/null
}

_sessions_log_valid_id() {
    local sid="$1"
    [[ -n "$sid" && "$sid" =~ ^[A-Za-z0-9._-]+$ ]]
}

_sessions_log_sidecar_id() {
    local session_name="$1"
    local sid_file="${AM_STATE_DIR:-/tmp/am-state}/$session_name.sid"
    [[ -f "$sid_file" ]] || return 0

    local sid=""
    IFS= read -r sid < "$sid_file" 2>/dev/null || true
    if _sessions_log_valid_id "$sid"; then
        echo "$sid"
    fi
}

# Read a field from the most recent sessions log entry for a session.
# Usage: _sessions_log_field <session_name> <field>
_sessions_log_field() {
    local session_name="$1"
    local field="$2"
    [[ -f "$AM_SESSIONS_LOG" ]] || return 0

    jq -rs --arg sname "$session_name" --arg field "$field" \
        '[.[] | select(.session_name == $sname)] | last | .[$field] // empty' \
        "$AM_SESSIONS_LOG" 2>/dev/null || true
}

# True when another registered Claude session shares the directory.
# Usage: _sessions_log_dir_is_shared <session_name> <directory>
_sessions_log_dir_is_shared() {
    local session_name="$1"
    local dir="$2"
    [[ -f "$AM_REGISTRY" ]] || return 1

    local count
    count=$(jq -r --arg name "$session_name" --arg dir "$dir" \
        '[.sessions | to_entries[]
          | select(.key != $name and .value.agent_type == "claude" and .value.directory == $dir)]
         | length' "$AM_REGISTRY" 2>/dev/null) || return 1
    [[ "$count" =~ ^[0-9]+$ ]] && (( count > 0 ))
}

# Detect the Claude session ID for a specific am session.
# Prefer the hook sidecar, because it was written by the agent pane itself.
# Fall back to directory scanning only for JSONLs updated after this am session
# was created; older same-directory JSONLs belong to previous sessions.
_sessions_log_detect_id_for_session() {
    local session_name="$1"
    local dir="$2"
    local created_at="${3:-}"

    local sid sid_file="${AM_STATE_DIR:-/tmp/am-state}/$session_name.sid"
    sid=$(_sessions_log_sidecar_id "$session_name")
    if [[ -f "$sid_file" ]]; then
        if [[ -n "$sid" ]] && _sessions_log_jsonl_exists "$dir" "$sid"; then
            echo "$sid"
        fi
        return 0
    fi

    # The mtime fallback below guesses "newest JSONL in this directory", which
    # binds the wrong conversation whenever another am session shares the
    # directory. Skip it then: a missing sid gets retried on the next scan,
    # a wrong one sticks forever.
    if _sessions_log_dir_is_shared "$session_name" "$dir"; then
        return 0
    fi

    _sessions_log_detect_id "$dir" "$created_at"
}

# Detect the Claude session ID for a directory.
# Usage: _sessions_log_detect_id <directory> [not_before_iso]
# Returns the session UUID of the most recently modified JSONL file.
# Returns: session UUID on stdout, or empty
_sessions_log_detect_id() {
    local dir="$1"
    local not_before="${2:-}"

    local resolved encoded project_dir
    resolved=$(cd "$dir" 2>/dev/null && pwd -P) || resolved="$dir"
    encoded=$(_slog_encode_dir "$resolved")
    project_dir="$HOME/.claude/projects/$encoded"
    [[ -d "$project_dir" ]] || return 0

    local min_epoch=0
    if [[ -n "$not_before" ]]; then
        min_epoch=$(_slog_iso_epoch "$not_before" 2>/dev/null || echo 0)
    fi

    local jsonl_path mtime sid
    while IFS= read -r jsonl_path; do
        [[ -n "$jsonl_path" && -f "$jsonl_path" ]] || continue
        if (( min_epoch > 0 )); then
            mtime=$(_slog_file_mtime "$jsonl_path" 2>/dev/null || echo 0)
            (( mtime > 0 && mtime < min_epoch )) && continue
        fi
        sid=$(basename "$jsonl_path" .jsonl)
        _sessions_log_valid_id "$sid" || continue
        echo "$sid"
        return 0
    done < <(command ls -t "$project_dir"/*.jsonl 2>/dev/null)
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

    # Bulk-parse all fields in one jq call
    local all_fields
    all_fields=$(jq -r '[.agent_type // "", .session_id // "", .directory // "", .created_at // "", .snapshot_file // ""] | join("|")' "$AM_SESSIONS_LOG" 2>/dev/null) || return 0

    # Read raw lines and parsed fields into parallel arrays
    local lines=() fields_arr=()
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        lines+=("$line")
    done < "$AM_SESSIONS_LOG"

    while IFS= read -r fline; do
        fields_arr+=("$fline")
    done <<< "$all_fields"

    local removed=0

    # Compute 24h cutoff as ISO string — avoids per-entry date subprocess calls
    local cutoff_iso
    cutoff_iso=$(date -u -v-24H +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
        || date -u -d "24 hours ago" +"%Y-%m-%dT%H:%M:%SZ")

    local tmp_file
    tmp_file=$(mktemp)

    local i
    for (( i=0; i<${#lines[@]}; i++ )); do
        local agent sid dir created_at snap
        IFS='|' read -r agent sid dir created_at snap <<< "${fields_arr[$i]}"

        local keep=true

        if [[ "$agent" == "claude" && -n "$sid" && -n "$dir" ]]; then
            if ! _sessions_log_jsonl_exists "$dir" "$sid"; then
                keep=false
            fi
        elif [[ "$agent" == "claude" && -z "$sid" ]]; then
            # ISO 8601 UTC timestamps sort lexicographically
            if [[ -n "$created_at" && "$created_at" < "$cutoff_iso" ]]; then
                keep=false
            fi
        fi

        if $keep; then
            printf '%s\n' "${lines[$i]}" >> "$tmp_file"
        else
            [[ -n "$snap" && -f "$AM_DIR/$snap" ]] && rm -f "$AM_DIR/$snap"
            ((removed++))
        fi
    done

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

    # Bulk-parse all fields in one jq call
    local all_fields
    all_fields=$(jq -r '[.session_name // "", .session_id // "", .agent_type // "", .directory // ""] | join("|")' "$AM_SESSIONS_LOG" 2>/dev/null) || return 0

    # Read raw lines and parsed fields into parallel arrays
    local lines=() fields_arr=()
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        lines+=("$line")
    done < "$AM_SESSIONS_LOG"

    while IFS= read -r fline; do
        fields_arr+=("$fline")
    done <<< "$all_fields"

    # Deduplicate: iterate in reverse (newest first), keep first occurrence of each session_id
    local -A seen_ids
    local i result=()
    for (( i=${#lines[@]}-1; i>=0; i-- )); do
        local sname sid agent dir
        IFS='|' read -r sname sid agent dir <<< "${fields_arr[$i]}"

        [[ "$agent" == "claude" ]] || continue
        [[ -n "$sid" ]] || continue
        [[ -z "${live_sessions[$sname]:-}" ]] || continue
        [[ -z "${seen_ids[$sid]:-}" ]] || continue

        if _sessions_log_jsonl_exists "$dir" "$sid"; then
            seen_ids[$sid]=1
            result+=("${lines[$i]}")
        fi
    done

    for line in "${result[@]}"; do
        printf '%s\n' "$line"
    done
}
