# shellcheck shell=bash
# state.sh - Session state detection
#
# Provides agent_get_state() and related helpers. State is derived on-demand
# by inspecting the Claude JSONL file (for Claude sessions) and/or tmux pane
# content. No persistent state is written.
#
# States: starting | running | waiting_input | waiting_permission |
#         waiting_custom | idle | dead

_STATE_LIB_DIR="${AM_LIB_DIR:-$(dirname "${BASH_SOURCE[0]}")}"
[[ -z "$AM_DIR" ]] && source "$_STATE_LIB_DIR/utils.sh"
[[ "$(type -t tmux_session_exists)" != "function" ]] && source "$_STATE_LIB_DIR/tmux.sh"
[[ "$(type -t registry_get_field)" != "function" ]] && source "$_STATE_LIB_DIR/registry.sh"

# ---------------------------------------------------------------------------
# JSONL helpers (Claude sessions)
# ---------------------------------------------------------------------------

# Encode a filesystem path as a Claude project directory name.
# Replaces every / and . with -, matching Claude's own encoding.
# e.g. /Users/foo/code → -Users-foo-code
# Usage: _state_encode_dir <path>
_state_encode_dir() {
    echo "$1" | sed -E 's|[/.]|-|g'
}

# Return the path to the Claude session JSONL for a directory.
# Usage: _state_jsonl_path <dir> [session_name]
# Returns: file path on stdout, or empty string if not found
#
# When session_name is given and a claude_session_id is resolvable (registry,
# pane args, or lsof), targets that exact conversation. Falls back to the
# newest mtime only when no signal is available — that fallback mis-attributes
# state when a fresher stub jsonl shadows the active conversation (Bug 1).
_state_jsonl_path() {
    local dir="$1" session="${2:-}"
    # Resolve symlinks to match Claude's encoding (e.g. /tmp → /private/tmp)
    local resolved
    resolved=$(cd "$dir" 2>/dev/null && pwd -P) || resolved="$dir"
    local encoded project_dir
    encoded=$(_state_encode_dir "$resolved")
    project_dir="$HOME/.claude/projects/$encoded"
    [[ -d "$project_dir" ]] || return 0

    if [[ -n "$session" ]]; then
        local sid
        sid=$(_state_claude_session_id "$session" "$resolved" "$project_dir")
        if [[ -n "$sid" && -f "$project_dir/$sid.jsonl" ]]; then
            echo "$project_dir/$sid.jsonl"
            return
        fi
    fi

    command ls -t "$project_dir"/*.jsonl 2>/dev/null | head -1
}

# Resolve the Claude conversation UUID owning a session's agent pane.
# Signals tried in order:
#   1. sidecar file $AM_STATE_DIR/<session>.sid  (written by state-hook.sh)
#   2. pane child process args                   (--session-id <uuid>)
#   3. lsof on the pane's claude child, intersected with the project dir
# Caches the resolved id to the sidecar file. Returns empty if none match.
#
# Sidecar is per-session (one writer) — avoids the registry read-modify-write
# race that hits shared sessions.json when multiple hooks fire concurrently.
# Usage: _state_claude_session_id <session> <resolved_dir> <project_dir>
_state_claude_session_id() {
    local session="$1" resolved_dir="$2" project_dir="$3"
    local sid="" sid_file="${AM_STATE_DIR:-/tmp/am-state}/$session.sid"

    if [[ -f "$sid_file" ]]; then
        # `read -r` returns non-zero when the file lacks a trailing newline
        # (state-hook.sh writes with `printf '%s'`) but still populates $sid.
        # Don't gate on read's exit status — check the var.
        IFS= read -r sid < "$sid_file" 2>/dev/null
        [[ -n "$sid" ]] && { echo "$sid"; return; }
    fi

    # Sidecar miss: resolve via pane args / lsof. Build the ps map once and
    # share it between both lookups (each previously forked ps independently).
    local -A _SID_COMM=() _SID_CHILD=()
    local _p _pp _c
    while read -r _p _pp _c; do
        [[ -z "$_p" || "$_p" == "PID" ]] && continue
        _SID_COMM[$_p]=$_c
        _SID_CHILD[$_pp]="${_SID_CHILD[$_pp]:-} $_p"
    done < <(ps -eo pid=,ppid=,comm= 2>/dev/null || true)

    local claude_pid
    claude_pid=$(_state_pane_claude_pid "$session" _SID_COMM _SID_CHILD)
    [[ -z "$claude_pid" ]] && return 0

    sid=$(_state_sid_from_pane_args_pid "$claude_pid")
    if [[ -n "$sid" ]]; then
        mkdir -p "${AM_STATE_DIR:-/tmp/am-state}" 2>/dev/null || true
        printf '%s' "$sid" > "$sid_file" 2>/dev/null || true
        echo "$sid"
        return
    fi

    sid=$(_state_sid_from_lsof_pid "$claude_pid" "$project_dir")
    if [[ -n "$sid" ]]; then
        mkdir -p "${AM_STATE_DIR:-/tmp/am-state}" 2>/dev/null || true
        printf '%s' "$sid" > "$sid_file" 2>/dev/null || true
        echo "$sid"
    fi
}

# Find the first `claude` descendant of a session's top pane pid.
# Usage: _state_pane_claude_pid <session> [<comm_map_name> <child_map_name>]
# Returns: pid on stdout, or empty
#
# When map names are supplied, reads from caller's pre-built tables instead of
# forking ps. Used by _state_claude_session_id to share one ps fork across
# sid_from_pane_args + sid_from_lsof.
_state_pane_claude_pid() {
    local session="$1"
    local pane_pid
    pane_pid=$(am_tmux display-message -p -t "${session}:.{top}" '#{pane_pid}' 2>/dev/null || true)
    [[ -z "$pane_pid" ]] && return 0

    local -A _PCHILD=() _PCOMM=()
    if (( $# >= 3 )); then
        local -n __cm="$2" __ch="$3"
        local _k
        for _k in "${!__cm[@]}"; do _PCOMM[$_k]="${__cm[$_k]}"; done
        for _k in "${!__ch[@]}"; do _PCHILD[$_k]="${__ch[$_k]}"; done
    else
        local _p _pp _c
        while read -r _p _pp _c; do
            [[ -z "$_p" || "$_p" == "PID" ]] && continue
            _PCOMM[$_p]=$_c
            _PCHILD[$_pp]="${_PCHILD[$_pp]:-} $_p"
        done < <(ps -eo pid=,ppid=,comm= 2>/dev/null || true)
    fi

    # BFS descendants
    local queue=("$pane_pid") cur child
    while (( ${#queue[@]} > 0 )); do
        cur="${queue[0]}"
        queue=("${queue[@]:1}")
        case "${_PCOMM[$cur]:-}" in
            claude|*[/\\]claude) echo "$cur"; return 0 ;;
        esac
        for child in ${_PCHILD[$cur]:-}; do
            queue+=("$child")
        done
    done
}

# Extract --session-id from the claude child's argv, if present.
# Two entry points so callers that already resolved the claude pid (via a
# shared ps map) don't re-fork ps inside _state_pane_claude_pid.
# Usage: _state_sid_from_pane_args <session>
#        _state_sid_from_pane_args_pid <claude_pid>
_state_sid_from_pane_args() {
    local pid
    pid=$(_state_pane_claude_pid "$1")
    [[ -z "$pid" ]] && return 0
    _state_sid_from_pane_args_pid "$pid"
}

_state_sid_from_pane_args_pid() {
    local pid="$1"
    [[ -z "$pid" ]] && return 0
    local args
    args=$(ps -p "$pid" -o args= 2>/dev/null || true)
    [[ -z "$args" ]] && return 0
    printf '%s' "$args" \
        | sed -nE 's/.*--session-id[= ]([0-9a-fA-F-]{8,})\b.*/\1/p' \
        | head -1
}

# Intersect open file descriptors of the claude child with jsonls in the
# project dir. Last-resort signal when args don't carry the id.
# Usage: _state_sid_from_lsof <session> <project_dir>
#        _state_sid_from_lsof_pid <claude_pid> <project_dir>
_state_sid_from_lsof() {
    command -v lsof >/dev/null 2>&1 || return 0
    local pid
    pid=$(_state_pane_claude_pid "$1")
    _state_sid_from_lsof_pid "$pid" "$2"
}

_state_sid_from_lsof_pid() {
    command -v lsof >/dev/null 2>&1 || return 0
    local pid="$1" project_dir="$2"
    [[ -z "$pid" ]] && return 0
    [[ -d "$project_dir" ]] || return 0
    # Escape regex metacharacters in project_dir so literal '.' in
    # ~/.claude/projects/<encoded> doesn't act as a wildcard (false positives
    # vanishingly unlikely in practice — paths still align byte-for-byte —
    # but the sharp edge has bitten enough times to be worth removing).
    local project_dir_esc
    project_dir_esc=$(printf '%s' "$project_dir" | sed 's/[][\.*^$/]/\\&/g')
    local path
    path=$(lsof -p "$pid" -Fn 2>/dev/null \
        | sed -nE "s|^n(${project_dir_esc}/[^/]+\\.jsonl)$|\\1|p" \
        | head -1)
    [[ -n "$path" ]] || return 0
    local base="${path##*/}"
    echo "${base%.jsonl}"
}

# Check whether a JSONL file is stale (mtime older than 30 seconds).
# Usage: _state_jsonl_stale <path>
# Returns: exit 0 if stale, exit 1 if fresh
_state_jsonl_stale() {
    local path="$1"
    [[ -f "$path" ]] || return 0
    local mtime now
    mtime=$(stat -c %Y "$path" 2>/dev/null || stat -f %m "$path" 2>/dev/null) || return 0
    now=$(date +%s)
    (( now - mtime > 30 ))
}

# Derive session state from the Claude JSONL file.
# Usage: _state_from_jsonl <directory> [session_name]
# Returns: state string on stdout, or empty string if cannot determine
_state_from_jsonl() {
    local dir="$1" session="${2:-}"
    local jsonl
    jsonl=$(_state_jsonl_path "$dir" "$session")
    [[ -n "$jsonl" && -f "$jsonl" ]] || return 0

    # Find the last meaningful entry: assistant, user, or queue-operation.
    # Skip metadata entries (system, progress, file-history-snapshot, etc.)
    # that Claude appends after the actual conversation turn.
    #
    # Read the file reversed and scan from the bottom so a metadata flood
    # (file-history-snapshot / last-prompt / ai-title / attachment / system)
    # of arbitrary depth still finds the last meaningful line. Cap at 200
    # reversed lines to keep cost bounded on huge files.
    local last_line
    last_line=$( { tail -r "$jsonl" 2>/dev/null || tac "$jsonl" 2>/dev/null; } \
        | head -n 200 \
        | grep -m1 -E '"type"[[:space:]]*:[[:space:]]*"(assistant|user|queue-operation)"') || return 0
    [[ -n "$last_line" ]] || return 0

    # Extract all needed fields in a single jq call (avoids 4 separate process spawns)
    # Use pipe delimiter (not tab — bash read collapses consecutive tabs for empty fields)
    local entry_type stop_reason operation content_has_tool_result
    local _jsonl_fields
    _jsonl_fields=$(printf '%s' "$last_line" | jq -r '[
        (.type // ""),
        (.message.stop_reason // ""),
        (.operation // ""),
        (if (.message.content | arrays | map(select(.type == "tool_result")) | length > 0) then "yes" else "" end)
    ] | join("|")' 2>/dev/null || true)
    IFS='|' read -r entry_type stop_reason operation content_has_tool_result <<< "$_jsonl_fields"

    case "$entry_type" in
        assistant)
            case "$stop_reason" in
                end_turn)
                    echo "waiting_input"
                    ;;
                tool_use)
                    echo "running"
                    ;;
                "")
                    # stop_reason null: response streaming or crashed write
                    if _state_jsonl_stale "$jsonl"; then
                        return 0  # stale — caller falls back to pane
                    fi
                    echo "running"
                    ;;
                *)
                    echo "running"
                    ;;
            esac
            ;;
        user)
            # User entry as last meaningful line means Claude is processing:
            # either a tool_result (tool ran) or new user input.
            echo "running"
            ;;
        queue-operation)
            if [[ "$operation" == "enqueue" ]]; then echo "running"; fi
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Hook state file helpers
# ---------------------------------------------------------------------------

AM_STATE_DIR="${AM_STATE_DIR:-/tmp/am-state}"

# Append a one-line trace of which resolver step produced an answer.
# Gated by AM_STATE_DEBUG=1 — silent no-op otherwise. Format:
#   <iso8601>\t<session>\t<agent_type>\t<source>\t<state>
# Sink: $AM_DIR/.state-debug.log (rotated by the caller, not here).
# Usage: _state_debug <session> <agent_type> <source> <state>
_state_debug() {
    [[ "${AM_STATE_DEBUG:-}" != "1" ]] && return 0
    local sink="${AM_DIR:-$HOME/.agent-manager}/.state-debug.log"
    # Append-only; ignore failure (read-only fs, permissions, etc).
    printf '%s\t%s\t%s\t%s\t%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "${2:-?}" "$3" "$4" \
        >> "$sink" 2>/dev/null || true
}

# Read session state from the hook state file into a caller-supplied variable.
# No subshell, no head fork — used by both the public _state_from_hook wrapper
# (one-shot calls) and _state_resolve's bulk path (avoids $() per session).
# Usage: _state_hook_read <session_name> <out_var_name> [now_epoch]
_state_hook_read() {
    local session="$1"
    local -n __out="$2"
    local now_epoch="${3:-}"
    __out=""
    local state_file="$AM_STATE_DIR/$session"
    [[ -f "$state_file" ]] || return 0
    local mtime
    mtime=$(stat -c %Y "$state_file" 2>/dev/null || stat -f %m "$state_file" 2>/dev/null) || return 0
    [[ -z "$now_epoch" ]] && now_epoch=$(date +%s)
    local line=""
    IFS= read -r line < "$state_file" 2>/dev/null || true
    # Terminal waiting states are persistent — an idle session can sit at
    # waiting_input for days without any new hook firing, and that's the
    # whole point. Only running has a staleness gate (3 min) since it
    # implies an in-progress turn that should produce PostToolUse / Stop
    # hooks; a stale `running` is the "agent crashed mid-tool-call" case
    # where we'd rather fall through to the pane check.
    case "$line" in
        waiting_input|waiting_permission|waiting_custom)
            __out="$line"
            ;;
        running)
            (( now_epoch - mtime > 180 )) && return 0
            __out="$line"
            ;;
    esac
}

# Read session state from the hook state file.
# Returns state string if file exists and is fresh (< 3 minutes old),
# or empty string if missing/stale.
# Usage: _state_from_hook <session_name>
_state_from_hook() {
    local _hs
    _state_hook_read "$1" _hs
    [[ -n "$_hs" ]] && echo "$_hs"
}

# ---------------------------------------------------------------------------
# Pane helpers (all agent types)
# ---------------------------------------------------------------------------

# Classify a session as idle or dead when the agent process has exited.
# Usage: agent_classify_exit <session>
agent_classify_exit() {
    local session="$1"
    local pane_target
    pane_target=$(tmux_session_pane_target "$session" "agent") || { echo "dead"; return; }

    local last_line
    last_line=$(tmux_capture_pane "$pane_target" 10 2>/dev/null \
        | sed -E 's/\x1b\[[0-9;]*[mGKHF]//g; s/\x1b\[?[0-9;]*[a-zA-Z]//g' \
        | grep -v '^[[:space:]]*$' | tail -1 || true)

    if printf '%s' "$last_line" \
            | grep -qE '(error:|fatal:|Error:|Fatal:|FAILED|non-zero exit|exit code [^0])'; then
        echo "dead"
    else
        echo "idle"
    fi
}

# Bulk-data variant of _state_pane_is_shell. Reads from pre-built tables
# instead of forking tmux+ps repeatedly. Used by status-bar where the same
# process tree is queried for every am session in one tick.
# Usage: _state_pane_is_shell_bulk <session> <top_pid_map> <comm_map> <children_map>
#   top_pid_map[session]   = pane top pid
#   comm_map[pid]          = comm
#   children_map[ppid]     = "space-separated child pids"
# Returns: 0 if shell, 1 otherwise
_state_pane_is_shell_bulk() {
    local session="$1"
    local -n __TOP="$2" __COMM="$3" __CHILD="$4"
    local pid="${__TOP[$session]:-}"
    [[ -z "$pid" ]] && return 1
    local comm="${__COMM[$pid]:-}"
    case "$comm" in
        bash|zsh|sh|fish|dash|-bash|-zsh|-sh|-fish|-dash) ;;
        *) return 1 ;;
    esac
    local cpid ccomm
    for cpid in ${__CHILD[$pid]:-}; do
        ccomm="${__COMM[$cpid]:-}"
        case "$ccomm" in
            bash|zsh|sh|fish|dash|-bash|-zsh|-sh|-fish|-dash|"") ;;
            *) return 1 ;;
        esac
    done
    return 0
}

# Build size-1 bulk fixtures into the named maps for a single session and call
# _state_pane_is_shell_bulk. Replaces the previous non-bulk implementation,
# which forked ps twice and reimplemented shell-child detection. Kept as a
# named function because tests call it directly (test_standalone_scripts.sh).
# Usage: _state_pane_is_shell <session>
# Returns: 0 if shell, 1 otherwise
_state_pane_is_shell() {
    local session="$1"
    local -A __ps_top=() __ps_comm=() __ps_child=()
    local pane_pid
    pane_pid=$(am_tmux display-message -p -t "${session}:.{top}" '#{pane_pid}' 2>/dev/null || true)
    [[ -z "$pane_pid" ]] && return 1
    __ps_top[$session]=$pane_pid
    local _p _pp _c
    while read -r _p _pp _c; do
        [[ -z "$_p" || "$_p" == "PID" ]] && continue
        __ps_comm[$_p]=$_c
        __ps_child[$_pp]="${__ps_child[$_pp]:-} $_p"
    done < <(ps -eo pid=,ppid=,comm= 2>/dev/null || true)
    _state_pane_is_shell_bulk "$session" __ps_top __ps_comm __ps_child
}

# Derive session state from tmux pane content.
# Usage: _state_from_pane <session> [agent_type] [--skip-alive-check]
# Returns: state string on stdout, or empty string if cannot determine
_state_from_pane() {
    local session="$1"
    local agent_type="${2:-}"
    local skip_alive="${3:-}"

    if [[ "$skip_alive" != "--skip-alive-check" ]]; then
        # Dead check
        if ! tmux_session_exists "$session"; then
            echo "dead"
            return
        fi

        if _state_pane_is_shell "$session"; then
            agent_classify_exit "$session"
            return
        fi
    fi

    # Capture and strip ANSI from last 40 lines
    local pane_target content
    pane_target=$(tmux_session_pane_target "$session" "agent") || { echo "running"; return; }
    content=$(tmux_capture_pane "$pane_target" 40 2>/dev/null \
        | sed -E 's/\x1b\[[0-9;]*[mGKHF]//g; s/\x1b\[?[0-9;]*[a-zA-Z]//g' \
        || true)

    # --- Permission prompts (checked first for all agents) ---

    # Claude permission patterns
    if printf '%s' "$content" | grep -qiE \
            'Do you want to (proceed|continue|make this edit|allow)\?|\[y/n\]|\(y/n/a/s\)|Allow .+ to (read|write|execute|run)\?'; then
        echo "waiting_permission"
        return
    fi

    # Codex permission patterns: command approval and edit approval dialogs
    # "Would you like to run the following command?"
    # "Would you like to make the following edits?"
    # Both end with "Press enter to confirm or esc to cancel"
    if printf '%s' "$content" | grep -qE \
            'Would you like to (run the following command|make the following edits)\?|Press enter to confirm or esc to cancel'; then
        echo "waiting_permission"
        return
    fi

    # --- Custom question prompts ---

    # Claude plan approval prompt ("Would you like to proceed?" with numbered options)
    if printf '%s' "$content" | grep -qE 'Would you like to proceed\?' \
       && printf '%s' "$content" | grep -qE '(auto mode|manually approve|Tell Claude what to change)'; then
        echo "waiting_custom"
        return
    fi

    # Claude /ask block
    if printf '%s' "$content" | grep -qE '^\s*/ask'; then
        echo "waiting_custom"
        return
    fi

    # --- Agent-specific running vs waiting_input ---

    if [[ "$agent_type" == "codex" ]]; then
        # Codex shows "• Working (Xs • esc to interrupt)" or "○ Working (Xs •..."
        # while busy. Absence of this indicator means it is waiting for input.
        if printf '%s' "$content" | grep -qE 'Working \([0-9]+s|esc to interrupt'; then
            echo "running"
        else
            echo "waiting_input"
        fi
        return
    fi

    # Claude: detect input prompt as waiting_input (fallback when JSONL unavailable)
    if [[ "$agent_type" == "claude" ]]; then
        # Positive running indicators: spinner or legacy (running) tag.
        # The ❯ prompt is always visible in Claude Code's TUI, so check
        # running indicators FIRST — they take priority.
        if printf '%s' "$content" | grep -qE '\(running\)|·[[:space:]]+\S+…'; then
            echo "running"
        elif printf '%s' "$content" | grep -qE '(^|\s)❯\s*$'; then
            echo "waiting_input"
        else
            echo "running"
        fi
        return
    fi

    # Generic fallback: process is alive → conservative running
    echo "running"
}

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

# Single state-resolution function — given (session, agent_type, dir), return
# state. Optional bulk fixtures let status-bar share this function without
# paying per-session tmux+ps forks: pass map names by reference (bash 4.3+
# nameref) and the resolver reads them in place of forking.
#
# Bulk fixtures (all must be supplied together; otherwise the resolver does
# its own per-session lookups):
#   <top_pid_map_name>     associative: session  -> pane top pid
#   <comm_map_name>        associative: pid      -> comm
#   <children_map_name>    associative: ppid     -> space-separated child pids
#   <now_epoch>            integer: seconds since epoch (one date+%s per tick)
#
# Resolution order (single canonical path used by both call sites):
#   1. shell check  → starting (created<5s, non-bulk only) / idle / dead
#   2. hook         → waiting_* short-circuits (skip pane fork)
#   3. pane         → permission / custom / dead / idle
#   4. jsonl        → Claude only, when dir is set
#   5. pane result fallback (running / waiting_input)
#
# Usage:
#   _state_resolve <session> <agent_type> <dir>
#   _state_resolve <session> <agent_type> <dir> <top_pid_map> <comm_map> <children_map> <now_epoch>
_state_resolve() {
    local session="$1" agent_type="${2:-}" dir="${3:-}"

    # Bulk fixtures: when caller supplies (status-bar tick), reuse. Otherwise
    # build size-1 fixtures inline. One code path either way.
    local top_name comm_name child_name now_val
    local -A __auto_top=() __auto_comm=() __auto_child=()
    # skip_classifier: bulk callers skip starting/dead classification (status-
    # bar treats any shell as idle; the per-session agent_get_state path can
    # upgrade later). Non-bulk callers run the full classifier.
    local skip_classifier=false
    if (( $# >= 7 )); then
        top_name="$4"; comm_name="$5"; child_name="$6"; now_val="$7"
        skip_classifier=true
    else
        local pane_pid
        pane_pid=$(am_tmux display-message -p -t "${session}:.{top}" '#{pane_pid}' 2>/dev/null || true)
        [[ -n "$pane_pid" ]] && __auto_top[$session]=$pane_pid
        local _p _pp _c
        while read -r _p _pp _c; do
            [[ -z "$_p" || "$_p" == "PID" ]] && continue
            __auto_comm[$_p]=$_c
            __auto_child[$_pp]="${__auto_child[$_pp]:-} $_p"
        done < <(ps -eo pid=,ppid=,comm= 2>/dev/null || true)
        now_val=$(date +%s)
        top_name=__auto_top; comm_name=__auto_comm; child_name=__auto_child
    fi

    # Optional instrumentation (AM_STATE_DEBUG=1). Each return path tags
    # itself via _state_debug; sink is appended to $AM_DIR/.state-debug.log
    # so empirical layer-usage data can drive future simplifications.
    local _dbg_session="$session" _dbg_agent="$agent_type"

    # 1. Shell check
    if _state_pane_is_shell_bulk "$session" "$top_name" "$comm_name" "$child_name"; then
        if $skip_classifier; then
            _state_debug "$_dbg_session" "$_dbg_agent" shell idle
            echo "idle"
            return
        fi
        local created_at created_epoch age
        created_at=$(registry_get_field "$session" created_at 2>/dev/null || true)
        if [[ -n "$created_at" ]]; then
            created_epoch=$(date -d "$created_at" +%s 2>/dev/null \
                || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$created_at" +%s 2>/dev/null \
                || echo 0)
            age=$(( now_val - created_epoch ))
            if (( age < 5 )); then
                _state_debug "$_dbg_session" "$_dbg_agent" shell starting
                echo "starting"
                return
            fi
        fi
        local _exit_state
        _exit_state=$(agent_classify_exit "$session")
        _state_debug "$_dbg_session" "$_dbg_agent" classify_exit "$_exit_state"
        echo "$_exit_state"
        return
    fi

    # 2. Hook terminal short-circuit. waiting_* states are authoritative; we
    # skip the pane fork. running falls through so concurrent permission
    # prompts painted during a tool call are caught.
    local hook_state=""
    _state_hook_read "$session" hook_state "$now_val"
    case "$hook_state" in
        waiting_input|waiting_permission|waiting_custom)
            _state_debug "$_dbg_session" "$_dbg_agent" hook "$hook_state"
            echo "$hook_state"
            return
            ;;
    esac

    # 3. Pane (skip-alive — we already filtered shell / dead session above)
    local pane_state
    pane_state=$(_state_from_pane "$session" "$agent_type" --skip-alive-check 2>/dev/null || true)
    case "$pane_state" in
        waiting_permission|waiting_custom|dead|idle)
            _state_debug "$_dbg_session" "$_dbg_agent" pane "$pane_state"
            echo "$pane_state"
            return
            ;;
    esac

    # 4. JSONL fallback for Claude
    if [[ "$agent_type" == "claude" && -n "$dir" ]]; then
        local jstate
        jstate=$(_state_from_jsonl "$dir" "$session" 2>/dev/null || true)
        if [[ -n "$jstate" ]]; then
            _state_debug "$_dbg_session" "$_dbg_agent" jsonl "$jstate"
            echo "$jstate"
            return
        fi
    fi

    # 5. Fall back to pane result (running / waiting_input), then hook running,
    # then conservative running.
    local _fallback="${pane_state:-${hook_state:-running}}"
    _state_debug "$_dbg_session" "$_dbg_agent" fallback "$_fallback"
    echo "$_fallback"
}

# Return the current state of a session.
# Usage: agent_get_state <session_name>
# Outputs one of: starting | running | waiting_input | waiting_permission |
#                 waiting_custom | idle | dead
agent_get_state() {
    local session="$1"

    if ! tmux_session_exists "$session"; then
        echo "dead"
        return
    fi

    local agent_type dir
    agent_type=$(registry_get_field "$session" agent_type 2>/dev/null || true)
    dir=$(registry_get_field "$session" directory 2>/dev/null || true)

    _state_resolve "$session" "$agent_type" "$dir"
}

# Block until a session reaches one of the target states.
# Usage: agent_wait_state <session> [states] [timeout_seconds]
#   states: comma-separated list, default: waiting_input,waiting_permission,waiting_custom,idle,dead
#   timeout_seconds: default 600
# Outputs: matched state string, or "timeout"
# Exit codes: 0=matched, 1=session not found, 3=timeout
agent_wait_state() {
    local session="$1"
    local target_states="${2:-waiting_input,waiting_permission,waiting_custom,idle,dead}"
    local timeout_s="${3:-600}"
    local stable_polls_required="${AM_WAIT_STABLE_POLLS:-3}"
    local quiet_secs_required="${AM_WAIT_QUIET_SECS:-2}"

    if ! tmux_session_exists "$session"; then
        log_error "Session not found: $session" >&2
        echo "not_found"
        return 1
    fi

    local start elapsed state
    local last_match_state="" last_match_activity="" stable_polls=0
    start=$(date +%s)

    while true; do
        state=$(agent_get_state "$session")

        local matched=false
        local t
        local IFS=','
        for t in $target_states; do
            if [[ "$state" == "$t" ]]; then
                matched=true
                case "$state" in
                    waiting_input|waiting_permission|waiting_custom|idle)
                        local activity now quiet_age
                        activity=$(tmux_get_activity "$session")
                        now=$(date +%s)
                        quiet_age=0
                        [[ -n "$activity" ]] && quiet_age=$(( now - activity ))

                        if [[ "$state" == "$last_match_state" && "$activity" == "$last_match_activity" ]]; then
                            stable_polls=$((stable_polls + 1))
                        else
                            stable_polls=1
                            last_match_state="$state"
                            last_match_activity="$activity"
                        fi

                        if (( quiet_age >= quiet_secs_required && stable_polls >= stable_polls_required )); then
                            echo "$state"
                            return 0
                        fi
                        ;;
                    *)
                        echo "$state"
                        return 0
                        ;;
                esac
            fi
        done

        if ! $matched; then
            last_match_state=""
            last_match_activity=""
            stable_polls=0
        fi

        elapsed=$(( $(date +%s) - start ))
        if (( elapsed >= timeout_s )); then
            echo "timeout"
            return 3
        fi

        sleep 0.5
    done
}
