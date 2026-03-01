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
    local name

    for name in $(registry_list); do
        if ! tmux_session_exists "$name"; then
            registry_remove "$name"
            ((removed++))
        fi
    done

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

# Generate a fallback title from a user message (first sentence, cleaned)
# Usage: _title_fallback <message>
_title_fallback() {
    local msg="$1"
    echo "$msg" | sed -E 's/https?:\/\/[^ ]*//g; s/  +/ /g; s/[.?!].*//' | head -c 60
}

# Strip markdown/quotes from Haiku output
# Usage: _title_strip_haiku <raw_title>
_title_strip_haiku() {
    echo "$1" | sed 's/^[#*"`'\'']*//; s/[#*"`'\'']*$//' | tr -d '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

# Check if a title is valid (<=60 chars, no newlines)
# Usage: _title_valid <title> && echo yes
_title_valid() {
    local t="$1"
    [[ -n "$t" && ${#t} -le 60 && "$t" != *$'\n'* ]]
}

# Scan untitled active sessions and generate titles.
# Writes fallback immediately, spawns fire-and-forget Haiku upgrade.
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

    local name dir task first_msg fallback
    local scanned=0 titled=0
    for name in $(registry_list); do
        task=$(registry_get_field "$name" "task")
        [[ -n "$task" ]] && continue  # already titled

        scanned=$((scanned + 1))
        dir=$(registry_get_field "$name" "directory")
        if [[ -z "$dir" ]]; then
            _titler_log "  $name: skip (no directory)"
            continue
        fi

        first_msg=$(claude_first_user_message "$dir" 2>/dev/null)
        first_msg="${first_msg:0:200}"
        if [[ -z "$first_msg" ]]; then
            _titler_log "  $name: skip (no user message yet)"
            continue
        fi

        # Write fallback title immediately
        fallback=$(_title_fallback "$first_msg")
        if [[ -z "$fallback" ]]; then
            _titler_log "  $name: skip (fallback empty for: ${first_msg:0:60}...)"
            continue
        fi

        registry_update "$name" "task" "$fallback"
        local branch agent
        branch=$(registry_get_field "$name" "branch")
        agent=$(registry_get_field "$name" "agent_type")
        history_append "$dir" "$fallback" "$agent" "$branch"
        titled=$((titled + 1))
        _titler_log "  $name: fallback=\"$fallback\""

        # Fire-and-forget Haiku upgrade via standalone script
        if command -v claude &>/dev/null; then
            "$(dirname "${BASH_SOURCE[0]}")/title-upgrade" "$name" "$first_msg" &
        fi
    done

    _titler_log "scan done: $scanned untitled, $titled titled"
}
