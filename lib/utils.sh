# utils.sh - Common utilities for agent-manager

# Configuration
AM_DIR="${AM_DIR:-$HOME/.agent-manager}"
AM_REGISTRY="$AM_DIR/sessions.json"
AM_HISTORY="$AM_DIR/history.jsonl"
AM_SESSION_PREFIX="${AM_SESSION_PREFIX:-am-}"
AM_TMUX_SOCKET="${AM_TMUX_SOCKET:-agent-manager}"
AM_TMUX_CONF="${AM_TMUX_CONF:-$AM_DIR/tmux.conf}"
AM_ROOT_DIR="${AM_ROOT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}"

# Colors (only if terminal supports it)
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    BOLD='\033[1m'
    RESET='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' BOLD='' RESET=''
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

# Format seconds as human-readable duration
# Usage: _format_seconds <seconds> [ago]
# If ago="ago", appends " ago" suffix and uses terse format (omits zero sub-units).
# Without ago, uses verbose format (always shows sub-units for hours+).
_format_seconds() {
    local seconds="$1"
    local ago="${2:-}"
    local terse=false
    [[ "$ago" == "ago" ]] && terse=true

    if $terse && (( seconds < 0 )); then
        echo "just now"
        return
    fi

    local result
    if (( seconds < 60 )); then
        result="${seconds}s"
    elif (( seconds < 3600 )); then
        result="$(( seconds / 60 ))m"
    elif (( seconds < 86400 )); then
        local hours=$(( seconds / 3600 ))
        local mins=$(( (seconds % 3600) / 60 ))
        if $terse && (( mins == 0 )); then
            result="${hours}h"
        else
            result="${hours}h ${mins}m"
        fi
    else
        local days=$(( seconds / 86400 ))
        if $terse; then
            result="${days}d"
        else
            local hours=$(( (seconds % 86400) / 3600 ))
            result="${days}d ${hours}h"
        fi
    fi

    if $terse; then
        echo "${result} ago"
    else
        echo "$result"
    fi
}

# Format seconds as human-readable time ago (terse: "2h ago", "3d ago")
format_time_ago() { _format_seconds "$1" ago; }

# Format seconds as duration (verbose: "2h 0m", "1d 0h")
format_duration() { _format_seconds "$1"; }

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
    basename "$1"
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

# Extract first meaningful user message from Claude session JSONL
# Usage: claude_first_user_message <directory>
# Returns: cleaned text of the first user message with >10 chars, or empty
claude_first_user_message() {
    local directory="$1"

    # Convert directory to Claude's project path format (/ and . become -)
    local project_path="${directory//\//-}"
    project_path="${project_path//./-}"
    local claude_project_dir="$HOME/.claude/projects/$project_path"

    [[ -d "$claude_project_dir" ]] || return 0

    local session_file
    session_file=$(command ls -t "$claude_project_dir"/*.jsonl 2>/dev/null | head -1)
    [[ -n "$session_file" && -f "$session_file" ]] || return 0

    local line content cleaned
    while IFS= read -r line; do
        content=$(echo "$line" | jq -r '
            .message.content |
            if type == "string" then .
            elif type == "array" then
                [.[] | select(.type == "text") | .text] | join(" ")
            else empty
            end
        ' 2>/dev/null) || continue

        [[ -z "$content" ]] && continue

        # Strip XML tags, collapse whitespace
        cleaned=$(echo "$content" | \
            sed 's/<[^>]*>[^<]*<\/[^>]*>//g; s/<[^>]*>//g' | \
            tr '\n' ' ' | \
            sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

        if [[ -n "$cleaned" && ${#cleaned} -gt 10 ]]; then
            echo "$cleaned"
            return 0
        fi
    done < <(grep '"type":"user"' "$session_file" 2>/dev/null | head -10)
}

# TRACE=1 profiling — uses bash set -x with timestamped PS4.
# Traces every line automatically, no per-function instrumentation needed.
# Usage: TRACE=1 am list-internal

declare -g TRACE_LOG=""

trace_init() {
    [[ "${TRACE:-0}" == "1" ]] || return 0

    TRACE_LOG="/tmp/am-trace-$$.log"
    : > "$TRACE_LOG"

    # Timestamp each traced line with function name and line number
    if command -v gdate &>/dev/null; then
        PS4='+ $(gdate +%s%N) ${FUNCNAME[0]:-main}:${LINENO} '
    else
        # macOS date lacks %N — fall back to second-level granularity
        PS4='+ $(date +%s)000000000 ${FUNCNAME[0]:-main}:${LINENO} '
    fi

    exec 19>"$TRACE_LOG"
    BASH_XTRACEFD=19
    set -x

    trap 'trace_on_exit' EXIT
}

trace_on_exit() {
    set +x
    exec 19>&-

    [[ -f "$TRACE_LOG" && -s "$TRACE_LOG" ]] || return 0

    echo "" >&2
    echo "=== Trace Summary ===" >&2
    echo "Log: $TRACE_LOG ($(wc -l < "$TRACE_LOG" | tr -d ' ') lines)" >&2
    echo "" >&2

    # Parse xtrace lines: "+ TIMESTAMP FUNC:LINE rest..."
    # Aggregate: line count per function, first/last timestamp per function
    awk '
    /^\+/ {
        split($3, a, ":")
        fn = a[1]
        ts = $2 + 0
        count[fn]++
        if (!(fn in first) || ts < first[fn]) first[fn] = ts
        if (!(fn in last) || ts > last[fn]) last[fn] = ts
    }
    END {
        n = 0
        for (fn in count) {
            span_ms = (last[fn] - first[fn]) / 1000000
            results[n] = sprintf("%d|%s|%d", span_ms, fn, count[fn])
            n++
        }
        # Sort by span descending (simple insertion sort)
        for (i = 1; i < n; i++) {
            key = results[i]
            split(key, k, "|")
            j = i - 1
            while (j >= 0) {
                split(results[j], jk, "|")
                if (jk[1]+0 >= k[1]+0) break
                results[j+1] = results[j]
                j--
            }
            results[j+1] = key
        }
        printf "Top functions by wall-clock span:\n"
        limit = (n < 15) ? n : 15
        for (i = 0; i < limit; i++) {
            split(results[i], r, "|")
            printf "  %s: %dms (%d lines)\n", r[2], r[1], r[3]
        }
    }' "$TRACE_LOG" >&2
}
