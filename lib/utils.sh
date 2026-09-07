# shellcheck shell=bash
# utils.sh - Common utilities for agent-manager

# Configuration
AM_DIR="${AM_DIR:-$HOME/.agent-manager}"
AM_REGISTRY="$AM_DIR/sessions.json"
AM_SESSION_PREFIX="${AM_SESSION_PREFIX:-am-}"
AM_SESSIONS_LOG="$AM_DIR/sessions_log.jsonl"
AM_SNAPSHOTS_DIR="$AM_DIR/snapshots"
AM_TMUX_SOCKET="${AM_TMUX_SOCKET:-agent-manager}"
AM_TMUX_CONF="${AM_TMUX_CONF:-$AM_DIR/tmux.conf}"
AM_LIB_DIR="${AM_LIB_DIR:-$(dirname "${BASH_SOURCE[0]}")}"
AM_ROOT_DIR="${AM_ROOT_DIR:-$(cd "$AM_LIB_DIR/.." && pwd -P)}"

# Agent adapter manifest: every agent-specific fact (launch command, aliases,
# prompt delivery, resume args, transcript store layout, title parser,
# title→state signal, turn-boundary reliability, hook family, restore
# preflight, version binary, live lab) lives in lib/agents.manifest, a symlink
# to internal/sessions/agents.manifest, which Go embeds. Loaded once per
# process into _AM_AGENT_FIELDS["<type>.<field>"]; libs branch on fields via
# am_agent_field, never on agent names.
AM_AGENT_MANIFEST="${AM_AGENT_MANIFEST:-$AM_LIB_DIR/agents.manifest}"
# -g: utils.sh is sometimes sourced inside a function (tests, am's own
# entry); a plain declare -A there would make the tables function-local.
declare -gA _AM_AGENT_FIELDS=()
declare -gA _AM_AGENT_ALIASES=()
declare -ga AM_AGENT_TYPES=()

am_agent_manifest_load() {
    local key value type
    _AM_AGENT_FIELDS=(); _AM_AGENT_ALIASES=(); AM_AGENT_TYPES=()
    [[ -r "$AM_AGENT_MANIFEST" ]] || {
        echo "error: agent manifest not readable: $AM_AGENT_MANIFEST" >&2
        return 1
    }
    while read -r key value; do
        [[ -z "$key" || "$key" == \#* ]] && continue
        type="${key%%.*}"
        [[ "$type" == "$key" || -z "$type" ]] && continue
        if [[ -z "${_AM_AGENT_FIELDS[$type.type]-}" ]]; then
            _AM_AGENT_FIELDS[$type.type]=$type
            AM_AGENT_TYPES+=("$type")
        fi
        [[ "$value" == "-" ]] && value=""
        _AM_AGENT_FIELDS[$key]=$value
        if [[ "${key#*.}" == "aliases" ]]; then
            local alias
            for alias in $value; do _AM_AGENT_ALIASES[$alias]=$type; done
        fi
    done < "$AM_AGENT_MANIFEST"
}

# Canonical type for a name or alias; unknown names pass through unchanged.
# Usage: am_agent_normalize <name> [out_var]
am_agent_normalize() {
    # Locals carry a function-specific prefix so an out_var of the same
    # plain name is never shadowed.
    local _an_canon="${_AM_AGENT_ALIASES[$1]-$1}"
    if [[ -n "${2:-}" ]]; then printf -v "$2" '%s' "$_an_canon"; else printf '%s\n' "$_an_canon"; fi
}

# One manifest field for an agent type (or alias); empty for unknown types,
# unknown fields, and `-` values. Fork-free with out_var.
# Usage: am_agent_field <type> <field> [out_var]
am_agent_field() {
    local _af_canon _af_val
    am_agent_normalize "$1" _af_canon
    _af_val="${_AM_AGENT_FIELDS[$_af_canon.$2]-}"
    if [[ -n "${3:-}" ]]; then printf -v "$3" '%s' "$_af_val"; else printf '%s\n' "$_af_val"; fi
}

# True when the name (or alias) is a manifest type.
am_agent_known() {
    local _ak_canon
    am_agent_normalize "$1" _ak_canon
    [[ -n "${_AM_AGENT_FIELDS[$_ak_canon.type]-}" ]]
}

am_agent_manifest_load

# Colors (only if terminal supports it)
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    BOLD='\033[1m'
    RESET='\033[0m'
else
    # shellcheck disable=SC2034
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
        local dir
        dir=$(dirname "$path")
        local file
        file=$(basename "$path")
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

# Fork-free git branch lookup. Walks up from <dir> to the nearest .git — a
# directory, or the pointer file a worktree/submodule carries — and reads HEAD.
# Prints the branch name, an 8-char sha for a detached HEAD, or nothing when
# <dir> is missing or outside a repository. With <out_var> the result is
# assigned instead of printed, so callers on a hot path skip the subshell.
# Cheap enough for periodic scans (auto_title_scan) and mirrored in Go
# (internal/sessions.GitHeadBranch).
# Usage: git_head_branch <dir> [out_var]
git_head_branch() {
    local dir="$1" gitdir="" head="" result=""
    if [[ -n "${2:-}" ]]; then
        local -n _ghb_out="$2"
        _ghb_out=""
    fi
    [[ -n "$dir" && -d "$dir" ]] || return 0
    while :; do
        if [[ -d "$dir/.git" ]]; then
            gitdir="$dir/.git"
            break
        elif [[ -f "$dir/.git" ]]; then
            IFS= read -r gitdir < "$dir/.git" || true
            gitdir="${gitdir#gitdir: }"
            [[ "$gitdir" == /* ]] || gitdir="$dir/$gitdir"
            break
        fi
        [[ "$dir" == "/" || "$dir" == "." ]] && return 0
        local parent="${dir%/*}"
        if [[ "$parent" == "$dir" ]]; then
            # Bare relative name ("sub"): the parent is the cwd, checked
            # once and then the walk ends (Go: filepath.Dir("sub") == ".").
            parent="."
        elif [[ -z "$parent" ]]; then
            parent="/"
        fi
        dir="$parent"
    done
    [[ -f "$gitdir/HEAD" ]] || return 0
    IFS= read -r head < "$gitdir/HEAD" || true
    if [[ "$head" == "ref: refs/heads/"* ]]; then
        result="${head#ref: refs/heads/}"
    elif [[ "$head" =~ ^[0-9a-f]{40} ]]; then
        result="${head:0:8}"
    fi
    if [[ -n "${2:-}" ]]; then
        _ghb_out="$result"
    else
        printf '%s\n' "$result"
    fi
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

# --- File mtimes without a per-call flavor probe ---
#
# `stat -c %Y file || stat -f %m file` costs two forks on macOS (the GNU form
# always fails first). The flavor is guessed once per process from $OSTYPE
# (fork-free) and corrected if the guess turns out wrong (GNU coreutils on
# PATH on macOS), so every later call is a single fork.

# The flavor lives in _AM_STAT_FLAVOR and is set in the calling shell (not
# inside the $(...) that runs stat, where it would not persist).
_am_stat_flavor_init() {
    [[ -n "${_AM_STAT_FLAVOR:-}" ]] && return 0
    case "$OSTYPE" in
        darwin*|*bsd*) _AM_STAT_FLAVOR=bsd ;;
        *)             _AM_STAT_FLAVOR=gnu ;;
    esac
}

_am_stat_flavor_flip() {
    if [[ "${_AM_STAT_FLAVOR:-}" == bsd ]]; then _AM_STAT_FLAVOR=gnu; else _AM_STAT_FLAVOR=bsd; fi
}

# Print "<epoch> <path>" lines for the given files with the current flavor,
# one stat call. Missing files print nothing. Usage: _am_stat_mtimes <file>...
_am_stat_mtimes() {
    case "${_AM_STAT_FLAVOR:-}" in
        bsd) stat -f '%m %N' "$@" 2>/dev/null ;;
        *)   stat -c '%Y %n' "$@" 2>/dev/null ;;
    esac
    return 0
}

# Mtime of one file as epoch seconds. Prints it, or assigns it to <out_var>
# when given (callers on a hot path skip the subshell). Empty and rc 1 when
# the file is missing.
# Usage: am_file_mtime <file> [out_var]
am_file_mtime() {
    _am_stat_flavor_init
    local __afm_line __afm_m=""
    __afm_line=$(_am_stat_mtimes "$1")
    if [[ -z "$__afm_line" && -e "$1" ]]; then
        # The file exists but stat printed nothing: wrong flavor guess
        # (e.g. GNU coreutils first on PATH on macOS). Flip and remember.
        _am_stat_flavor_flip
        __afm_line=$(_am_stat_mtimes "$1")
    fi
    __afm_m="${__afm_line%% *}"
    [[ "$__afm_m" =~ ^[0-9]+$ ]] || __afm_m=""
    if [[ -n "${2:-}" ]]; then
        local -n __afm_out="$2"
        __afm_out="$__afm_m"
    else
        [[ -n "$__afm_m" ]] && printf '%s\n' "$__afm_m"
    fi
    [[ -n "$__afm_m" ]]
}

# Mtimes of many files in one stat call, filled into an associative array
# keyed by path (missing files get no entry).
# Usage: am_files_mtime <assoc_out_var> <file>...
am_files_mtime() {
    local -n __afms_out="$1"
    shift
    (( $# )) || return 0
    _am_stat_flavor_init
    local -a __afms_lines=()
    mapfile -t __afms_lines < <(_am_stat_mtimes "$@")
    if (( ${#__afms_lines[@]} == 0 )); then
        local __afms_f
        for __afms_f in "$@"; do
            [[ -e "$__afms_f" ]] || continue
            _am_stat_flavor_flip
            mapfile -t __afms_lines < <(_am_stat_mtimes "$@")
            break
        done
    fi
    local __afms_l __afms_m __afms_p
    for __afms_l in "${__afms_lines[@]}"; do
        __afms_m="${__afms_l%% *}"
        __afms_p="${__afms_l#* }"
        [[ "$__afms_m" =~ ^[0-9]+$ && -n "$__afms_p" && "$__afms_p" != "$__afms_l" ]] || continue
        __afms_out[$__afms_p]=$__afms_m
    done
    return 0
}

# Run the compiled maintenance/query back end (bin/am-core, package
# internal/sessions) with the caller's effective paths. Bash derives
# AM_SESSIONS_LOG and friends from AM_DIR after sourcing (tests re-point them),
# so the values are passed explicitly rather than trusted to be exported; the
# binary applies utils.sh's defaults for anything unset. A missing binary
# prints one line and returns 127: periodic wrappers turn that into 0, query
# wrappers into a failed lookup.
# Usage: am_core <subcommand> [args...]
am_core() {
    local bin="$AM_ROOT_DIR/bin/am-core"
    if [[ ! -x "$bin" || ! -s "$bin" ]]; then
        echo "am: bin/am-core is not built. Run 'make' (or 'am install') to build it." >&2
        return 127
    fi
    command env "AM_DIR=$AM_DIR" "AM_SESSIONS_LOG=$AM_SESSIONS_LOG" \
        "AM_TMUX_SOCKET=$AM_TMUX_SOCKET" "AM_SESSION_PREFIX=$AM_SESSION_PREFIX" \
        ${AM_STATE_DIR:+"AM_STATE_DIR=$AM_STATE_DIR"} \
        ${AM_IDENTITY_DIR:+"AM_IDENTITY_DIR=$AM_IDENTITY_DIR"} \
        "$bin" "$@"
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

# First meaningful user message (>10 chars, tags stripped) of exactly the
# transcript bound to a session — the id the pane's own hook reported. The
# directory only locates the agent's per-project store; it never chooses among
# the transcripts in it, because that store is shared with other am sessions
# and with agents started outside am. No id → nothing. The readers live in Go
# (internal/sessions FirstMessage, behind bin/am-core); these wrappers keep
# the call sites in lib/preview and lib/doctor.sh. Store overrides for tests:
# AM_PI_SESSIONS_DIR, AM_CURSOR_PROJECTS_DIR (inherited from the environment).
# Usage: claude_first_user_message <directory> <session_id>
claude_first_user_message() { am_core first-message claude "$1" "${2:-}"; }

# Usage: pi_first_user_message <directory> <session_id>
pi_first_user_message() { am_core first-message pi "$1" "${2:-}"; }

# Cursor: the hook-provided transcript_path is authoritative; the standard
# layout addressed by session_id is the fallback.
# Usage: cursor_first_user_message <directory> [session_id] [transcript_path]
cursor_first_user_message() { am_core first-message cursor "$1" "${2:-}" "${3:-}"; }

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
