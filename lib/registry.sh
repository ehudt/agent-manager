# shellcheck shell=bash
# registry.sh - Session metadata storage using JSON

# Source utils if not already loaded
[[ -z "$AM_DIR" ]] && source "${AM_LIB_DIR:-$(dirname "${BASH_SOURCE[0]}")}/utils.sh"

# --- Registry write lock ---
#
# Every registry write is a read-whole-file -> jq -> rename cycle. The rename
# is atomic (no torn JSON) but the cycle is not: two overlapping writers each
# start from the same snapshot and the last rename silently erases the other's
# change (lost update), including rows they never touched. Writers overlap
# constantly (auto_title_scan, agent_launch/kill, the Go title-refresh/reaper
# invoked by the status bar every 5s), so every read-modify-write below runs
# under an exclusive lock on $AM_REGISTRY.lock. The Go twin
# (internal/sessions) takes the same lock via syscall.Flock.
#
# flock(1) is used where available (Linux); macOS ships no flock CLI, so a
# perl one-liner calls flock(2) on the shell's inherited fd instead. The lock
# lives on the open file description held by the shell, so it survives the
# perl child exiting and auto-releases if the holder dies. Not reentrant —
# callers must not nest _registry_lock.
_registry_lock() {
    exec {_REGISTRY_LOCK_FD}>>"$AM_REGISTRY.lock" || return 0
    # macOS may have third-party flock shims that do not support locking an
    # inherited numeric fd. Use the syscall-backed Perl path there.
    if [[ "$(uname -s)" != "Darwin" ]] && command -v flock >/dev/null 2>&1; then
        flock "$_REGISTRY_LOCK_FD" 2>/dev/null || true
    elif command -v perl >/dev/null 2>&1; then
        perl -MFcntl=:flock -e \
            'open(my $fh, ">&=", $ARGV[0]) or exit 1; flock($fh, LOCK_EX) or exit 1' \
            "$_REGISTRY_LOCK_FD" 2>/dev/null || true
    fi
    return 0
}

_registry_unlock() {
    [[ -n "${_REGISTRY_LOCK_FD:-}" ]] || return 0
    exec {_REGISTRY_LOCK_FD}>&-
    unset _REGISTRY_LOCK_FD
    return 0
}

# --- Temp-file guard for interrupted writers ---
#
# A writer killed between mktemp and the rename leaves its temp file behind
# (observed: ~300 .sessions-log.* files, half of them complete jq output —
# bash died while waiting on jq, jq finished on its own, nobody renamed).
# The guard registers the temp file so that HUP/INT/TERM/PIPE remove it and
# release the registry lock before the signal is re-raised; the caller's own
# traps are saved on guard and restored on release (and before the re-raise,
# so an outer handler still runs). Writers call the guard *after*
# _registry_lock — a writer blocked on the lock then owns no temp file — and
# _registry_tmp_release on every exit path. Not reentrant, like the lock.
# SIGKILL defeats it; registry_gc's extras half sweeps leftovers older than
# 60s as the backstop.
# Usage: _registry_tmp_guard <tmp_file> ... _registry_tmp_release
_registry_tmp_guard() {
    _REGISTRY_TMP_FILE="$1"
    _REGISTRY_TMP_SAVED_TRAPS=$(trap -p HUP INT TERM PIPE)
    trap '_registry_tmp_on_signal HUP' HUP
    trap '_registry_tmp_on_signal INT' INT
    trap '_registry_tmp_on_signal TERM' TERM
    trap '_registry_tmp_on_signal PIPE' PIPE
    return 0
}

_registry_tmp_release() {
    rm -f "${_REGISTRY_TMP_FILE:-}" 2>/dev/null
    trap - HUP INT TERM PIPE
    [[ -n "${_REGISTRY_TMP_SAVED_TRAPS:-}" ]] && eval "$_REGISTRY_TMP_SAVED_TRAPS"
    unset _REGISTRY_TMP_FILE _REGISTRY_TMP_SAVED_TRAPS
    return 0
}

_registry_tmp_on_signal() {
    local sig="$1"
    _registry_tmp_release
    _registry_unlock
    kill -s "$sig" "$BASHPID" 2>/dev/null
    # Only reached when the caller's restored trap swallowed the signal.
    return 0
}

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

    # Lock first, then mktemp: a writer blocked on the lock owns no temp file
    # (same order as sessions_log_update).
    _registry_lock
    local tmp_file rc=0
    tmp_file=$(mktemp) || { _registry_unlock; return 1; }
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
       }' "$AM_REGISTRY" > "$tmp_file" && command mv "$tmp_file" "$AM_REGISTRY" || rc=$?
    (( rc )) && rm -f "$tmp_file"
    _registry_unlock
    return $rc
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

    _registry_lock
    local tmp_file rc=0
    tmp_file=$(mktemp) || { _registry_unlock; return 1; }
    jq --arg name "$name" \
       --arg field "$field" \
       --arg value "$value" \
       'if .sessions[$name] then .sessions[$name][$field] = $value else . end' \
       "$AM_REGISTRY" > "$tmp_file" && command mv "$tmp_file" "$AM_REGISTRY" || rc=$?
    (( rc )) && rm -f "$tmp_file"
    _registry_unlock
    return $rc
}

# Remove a session from the registry
# Usage: registry_remove <name>
registry_remove() {
    local name="$1"

    _registry_lock
    local tmp_file rc=0
    tmp_file=$(mktemp) || { _registry_unlock; return 1; }
    jq --arg name "$name" 'del(.sessions[$name])' "$AM_REGISTRY" > "$tmp_file" && command mv "$tmp_file" "$AM_REGISTRY" || rc=$?
    (( rc )) && rm -f "$tmp_file"
    _registry_unlock
    return $rc
}

# Garbage collection. Two independently throttled halves (60s each, unless
# force=1), both in Go (internal/sessions Env.GC):
#   - Registry rows + hook state files (marker .gc_last; ReapOrphans, also run
#     by am-browse / am-list-internal): one locked read-modify-write with the
#     tmux snapshot taken inside the lock, rows younger than AM_GC_GRACE_SECS
#     (default 5) spared.
#   - Extras (marker .gc_extras_last): orphan state files and sidecars,
#     sessions-log pruning, unreferenced snapshots older than 10 min, leaked
#     temps (.sessions-log.* >60s; .dir_repo_cache.tmp.* and *.log.?????? >1h).
# Prints the number of registry rows removed.
# Usage: registry_gc [force]
registry_gc() {
    local removed
    removed=$(am_core gc "${1:-0}") || removed=0
    echo "${removed:-0}"
}

# --- Periodic maintenance (compiled: bin/am-core, package internal/sessions) ---
# The title/workdir/branch refresh, the restore scan (rolling snapshots,
# session-id binding from the hook sidecars, task/branch sync into the
# sessions log), and both GC halves run in Go; bash used to carry a second
# copy of each. The names below are kept so callers, tests, and docs read the
# same. Each wrapper is one exec of bin/am-core with the caller's effective
# paths (see utils.sh am_core). The marker files (.title_scan_last,
# .restore_scan_last, .gc_last, .gc_extras_last) and their 60s throttles are
# unchanged; force=1 bypasses them. Tracing: AM_TITLER_DEBUG=1 appends to
# $AM_DIR/titler.log. A missing binary logs one line and returns 0: periodic
# work must never fail the status-bar tick or `am list`.

# One maintenance tick: title scan, restore scan, gc — each on its own marker.
# The status-bar tick and `am list` call this and nothing else.
# Usage: am_tick [force]
am_tick() { am_core tick "${1:-0}" || return 0; }

# Refresh each registry row's workdir (.cwd sidecar), branch (.git/HEAD of the
# effective directory) and task (agent pane title; first user message of the
# bound transcript as the fallback), then chain into sessions_log_scan.
# Usage: auto_title_scan [force]
auto_title_scan() { am_core titles "${1:-0}" || return 0; }

# Rolling pane snapshots + session_id binding + task/branch sync for
# resumable sessions (claude, codex, pi, cursor) that have a sessions-log
# entry. Own marker (.restore_scan_last): a fresh .title_scan_last must not
# starve it.
# Usage: sessions_log_scan [force]
sessions_log_scan() { am_core restore-scan "${1:-0}" || return 0; }

# --- Sessions Log (for session restore) ---
# Persistent log of resumable sessions with exact IDs and pane snapshots.
# Pruned when the backing conversation artifact is deleted, not by time.

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

    local line
    line=$(jq -cn \
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
          snapshot_file: $snap, transcript_path: ""}')
    _registry_lock
    printf '%s\n' "$line" >> "$AM_SESSIONS_LOG"
    _registry_unlock
}

# Update a field in the most recent sessions log entry for a session.
# Usage: sessions_log_update <session_name> <field> <value>
sessions_log_update() {
    local session_name="$1"
    local field="$2"
    local value="$3"

    [[ -f "$AM_SESSIONS_LOG" ]] || return 0

    # Lock first, then mktemp: a writer blocked on the lock owns no temp file,
    # and the guard removes it if we are killed before the rename.
    _registry_lock
    local tmp_file
    tmp_file=$(mktemp "$AM_DIR/.sessions-log.XXXXXX") || { _registry_unlock; return 1; }
    _registry_tmp_guard "$tmp_file"

    # Single jq -sc call: slurp all lines, find and update the last matching entry.
    local rc=0
    if jq -sc --arg sname "$session_name" --arg field "$field" --arg value "$value" '
        . as $arr |
        (reduce range(length) as $i (-1;
            if $arr[$i].session_name == $sname then $i else . end)) as $last_idx |
        if $last_idx >= 0 then .[$last_idx][$field] = $value else . end |
        .[]
    ' "$AM_SESSIONS_LOG" > "$tmp_file" 2>/dev/null; then
        command mv "$tmp_file" "$AM_SESSIONS_LOG" || rc=1
    else
        rc=1
    fi
    _registry_tmp_release
    _registry_unlock
    return $rc
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
    pane_target=$(tmux_session_pane_target "$session_name" "agent" 2>/dev/null) || pane_target="${session_name}:.{top-left}"
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

# Encode a path as a pi session directory name. Mirrors pi's session-manager
# encoding: "--" + path minus leading slash, with / \ : replaced by -, + "--".
# Unlike Claude's encoding, dots are preserved.
_slog_encode_pi_dir() {
    local p="${1#/}"
    p=$(printf '%s' "$p" | sed -E 's|[/\\:]|-|g')
    printf -- '--%s--\n' "$p"
}

# Cursor's project key strips the leading slash, then replaces slash/dot.
_slog_encode_cursor_dir() {
    local p="${1#/}"
    printf '%s\n' "$p" | sed -E 's|[/.]|-|g'
}

_cursor_projects_root() {
    echo "${AM_CURSOR_PROJECTS_DIR:-$HOME/.cursor/projects}"
}

# Root of pi's session storage (override: AM_PI_SESSIONS_DIR, for tests).
_pi_sessions_root() {
    echo "${AM_PI_SESSIONS_DIR:-$HOME/.pi/agent/sessions}"
}

_sessions_log_valid_id() {
    local sid="$1"
    [[ -n "$sid" && "$sid" =~ ^[A-Za-z0-9._-]+$ ]]
}

_sessions_log_sidecar_id() {
    local session_name="$1"
    local durable_file="${AM_IDENTITY_DIR:-$AM_DIR/identities}/$session_name.sid"
    local sid_file="${AM_STATE_DIR:-/tmp/am-state}/$session_name.sid"
    local source_file="$sid_file"
    [[ -f "$durable_file" ]] && source_file="$durable_file"
    [[ -f "$source_file" ]] || return 0

    local sid=""
    IFS= read -r sid < "$source_file" 2>/dev/null || true
    if _sessions_log_valid_id "$sid"; then
        echo "$sid"
    fi
}

_sessions_log_sidecar_transcript() {
    local session_name="$1"
    local durable_file="${AM_IDENTITY_DIR:-$AM_DIR/identities}/$session_name.transcript"
    local path_file="${AM_STATE_DIR:-/tmp/am-state}/$session_name.transcript"
    [[ -f "$durable_file" ]] && path_file="$durable_file"
    [[ -f "$path_file" ]] || return 0

    local transcript=""
    IFS= read -r transcript < "$path_file" 2>/dev/null || true
    [[ "$transcript" == /* && -f "$transcript" ]] && echo "$transcript"
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

# Conversation id bound to an am session: the sidecar its own hook wrote
# (ephemeral $AM_STATE_DIR/<session>.sid, else the durable identity), verified
# against the transcript store. There is no directory-based guess: the store
# is shared with other am sessions and with agents started outside am, so the
# newest transcript in it is not this session. Until the first hook fires the
# session has no identity, and nothing worth restoring either.
# Go: internal/sessions Env.DetectID.
# Usage: _sessions_log_detect_id_for_session <session_name> <directory> [agent_type]
_sessions_log_detect_id_for_session() {
    am_core detect-id "$1" "$2" "${3:-claude}"
}

# Check if an agent conversation JSONL still exists for a directory + sid
# (codex: any well-formed id; cursor: the hook-reported transcript path first).
# Go: internal/sessions Env.JSONLExists.
# Usage: _sessions_log_jsonl_exists <directory> <session_id> [agent_type] [transcript_path]
_sessions_log_jsonl_exists() {
    am_core jsonl-exists "$1" "$2" "${3:-claude}" "${4:-}"
}

# Prune the sessions log: drop entries whose transcript is gone (and their
# snapshot), and id-less entries older than 24h. One locked rewrite. Runs from
# registry_gc's extras half; exposed for `am` callers and tests.
# Go: internal/sessions Env.SessionsLogGC.
# Usage: sessions_log_gc
sessions_log_gc() { am_core slog-gc || return 0; }

# JSONL lines of the sessions that can be restored (resumable agent, id
# bound, not alive, transcript present), newest first, one line per
# conversation id. Go: internal/sessions Env.Restorable.
# Usage: sessions_log_restorable
sessions_log_restorable() { am_core restorable; }
