#!/usr/bin/env bash
# utils.sh - Common utilities for agent-manager

# Configuration
AM_DIR="${AM_DIR:-$HOME/.agent-manager}"
AM_REGISTRY="$AM_DIR/sessions.json"
AM_CONFIG="$AM_DIR/config.yaml"
AM_SESSION_PREFIX="am-"

# Colors (only if terminal supports it)
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    MAGENTA='\033[0;35m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    DIM='\033[2m'
    RESET='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' MAGENTA='' CYAN='' BOLD='' DIM='' RESET=''
fi

# Logging functions (all to stderr to avoid polluting stdout for return values)
log_info() {
    echo -e "${BLUE}info:${RESET} $*" >&2
}

log_success() {
    echo -e "${GREEN}success:${RESET} $*" >&2
}

log_warn() {
    echo -e "${YELLOW}warn:${RESET} $*" >&2
}

log_error() {
    echo -e "${RED}error:${RESET} $*" >&2
}

die() {
    log_error "$@"
    exit 1
}

# Ensure required commands exist
require_cmd() {
    local cmd="$1"
    if ! command -v "$cmd" &>/dev/null; then
        die "Required command not found: $cmd"
    fi
}

# Initialize agent-manager directory
am_init() {
    mkdir -p "$AM_DIR"
    if [[ ! -f "$AM_REGISTRY" ]]; then
        echo '{"sessions":{}}' > "$AM_REGISTRY"
    fi
}

# Format seconds as human-readable time ago
format_time_ago() {
    local seconds="$1"

    if (( seconds < 0 )); then
        echo "just now"
    elif (( seconds < 60 )); then
        echo "${seconds}s ago"
    elif (( seconds < 3600 )); then
        echo "$(( seconds / 60 ))m ago"
    elif (( seconds < 86400 )); then
        local hours=$(( seconds / 3600 ))
        local mins=$(( (seconds % 3600) / 60 ))
        if (( mins > 0 )); then
            echo "${hours}h ${mins}m ago"
        else
            echo "${hours}h ago"
        fi
    else
        local days=$(( seconds / 86400 ))
        echo "${days}d ago"
    fi
}

# Format seconds as duration (for "running time")
format_duration() {
    local seconds="$1"

    if (( seconds < 60 )); then
        echo "${seconds}s"
    elif (( seconds < 3600 )); then
        echo "$(( seconds / 60 ))m"
    elif (( seconds < 86400 )); then
        local hours=$(( seconds / 3600 ))
        local mins=$(( (seconds % 3600) / 60 ))
        echo "${hours}h ${mins}m"
    else
        local days=$(( seconds / 86400 ))
        local hours=$(( (seconds % 86400) / 3600 ))
        echo "${days}d ${hours}h"
    fi
}

# Get absolute path
abspath() {
    local path="$1"
    if [[ -d "$path" ]]; then
        (cd "$path" && pwd)
    elif [[ -f "$path" ]]; then
        local dir=$(dirname "$path")
        local file=$(basename "$path")
        echo "$(cd "$dir" && pwd)/$file"
    else
        # Path doesn't exist, try to resolve anyway
        echo "$(cd "$(dirname "$path")" 2>/dev/null && pwd)/$(basename "$path")" 2>/dev/null || echo "$path"
    fi
}

# Get directory basename (last component)
dir_basename() {
    local path="$1"
    basename "$(abspath "$path")"
}

# Truncate string with ellipsis
truncate() {
    local str="$1"
    local max_len="${2:-30}"

    if (( ${#str} > max_len )); then
        echo "${str:0:$((max_len - 3))}..."
    else
        echo "$str"
    fi
}

# Check if we're inside a tmux session
in_tmux() {
    [[ -n "$TMUX" ]]
}

# Get current timestamp in ISO format
iso_timestamp() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# Get current timestamp as epoch seconds
epoch_now() {
    date +%s
}

# Generate a short hash for session naming
generate_hash() {
    local input="$1"
    if command -v md5sum &>/dev/null; then
        echo "$input" | md5sum | head -c 6
    elif command -v md5 &>/dev/null; then
        echo "$input" | md5 | head -c 6
    else
        # Fallback: use random
        echo "$RANDOM$RANDOM" | head -c 6
    fi
}
