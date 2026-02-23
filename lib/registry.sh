#!/usr/bin/env bash
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
        # Check if tmux session exists (using tmux_session_exists from tmux.sh if loaded)
        if ! tmux has-session -t "$name" 2>/dev/null; then
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

    history_prune
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
    echo "$msg" | sed 's/https\?:\/\/[^ ]*//g; s/  */ /g; s/[.?!].*//' | head -c 60
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
# Usage: auto_title_scan [force]
auto_title_scan() {
    local force="${1:-0}"

    # Throttle
    local marker="$AM_DIR/.title_scan_last"
    local now
    now=$(date +%s)
    if [[ "$force" != "1" && -f "$marker" ]]; then
        local last
        last=$(cat "$marker" 2>/dev/null || echo 0)
        if (( now - last < 60 )); then
            return 0
        fi
    fi
    echo "$now" > "$marker"

    local name dir task first_msg fallback
    for name in $(registry_list); do
        task=$(registry_get_field "$name" "task")
        [[ -n "$task" ]] && continue  # already titled

        dir=$(registry_get_field "$name" "directory")
        [[ -z "$dir" ]] && continue

        first_msg=$(claude_first_user_message "$dir" 2>/dev/null)
        first_msg="${first_msg:0:200}"
        [[ -z "$first_msg" ]] && continue

        # Write fallback title immediately
        fallback=$(_title_fallback "$first_msg")
        [[ -z "$fallback" ]] && continue

        registry_update "$name" "task" "$fallback"
        local branch agent
        branch=$(registry_get_field "$name" "branch")
        agent=$(registry_get_field "$name" "agent_type")
        history_append "$dir" "$fallback" "$agent" "$branch"

        # Fire-and-forget Haiku upgrade
        if command -v claude &>/dev/null; then
            (
                set +e +o pipefail
                unset CLAUDECODE

                local haiku_title
                haiku_title=$(printf '%s' "$first_msg" | claude -p --model haiku \
                    "Reply with a short 2-5 word title summarizing this task. Plain text only, no markdown, no quotes, no punctuation. Examples: Fix auth login bug, Add user settings page, Refactor database layer" 2>/dev/null) || true

                haiku_title=$(_title_strip_haiku "$haiku_title")
                if _title_valid "$haiku_title"; then
                    source "$(dirname "${BASH_SOURCE[0]}")/registry.sh"
                    registry_update "$name" "task" "$haiku_title"
                fi
            ) >/dev/null 2>&1 &
        fi
    done
}
