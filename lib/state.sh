# shellcheck shell=bash
# state.sh - Session state detection (hook + ps tree only)
#
# State sources:
#   1. tmux + ps process tree   -> starting / idle / dead
#   2. hook file ($AM_STATE_DIR) -> running / waiting_input / waiting_permission / waiting_custom
#   3. pane banner scan          -> waiting_background (Claude: turn done, bg work running)
#   4. fallback                  -> unknown (agent alive, hook silent)
#
# States: starting | running | waiting_input | waiting_permission |
#         waiting_custom | waiting_background | idle | unknown | dead

_STATE_LIB_DIR="${AM_LIB_DIR:-$(dirname "${BASH_SOURCE[0]}")}"
[[ -z "$AM_DIR" ]] && source "$_STATE_LIB_DIR/utils.sh"
[[ "$(type -t tmux_session_exists)" != "function" ]] && source "$_STATE_LIB_DIR/tmux.sh"
[[ "$(type -t registry_get_field)" != "function" ]] && source "$_STATE_LIB_DIR/registry.sh"

AM_STATE_DIR="${AM_STATE_DIR:-/tmp/am-state}"

# Append a one-line trace of which resolver step produced an answer.
# Gated by AM_STATE_DEBUG=1.
_state_debug() {
    [[ "${AM_STATE_DEBUG:-}" != "1" ]] && return 0
    local sink="${AM_DIR:-$HOME/.agent-manager}/.state-debug.log"
    printf '%s\t%s\t%s\t%s\t%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "${2:-?}" "$3" "$4" \
        >> "$sink" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Hook state file
# ---------------------------------------------------------------------------

# Read session state from $AM_STATE_DIR/<session> into a caller-supplied var.
# Terminal waiting_* states are persistent (no staleness gate). running gets a
# 180s gate so a crashed mid-tool-call agent falls through to 'unknown' instead
# of looking busy forever.
# Usage: _state_hook_read <session> <out_var> [now_epoch]
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
    case "$line" in
        waiting_input|waiting_permission|waiting_custom)
            __out="$line" ;;
        running)
            (( now_epoch - mtime > 180 )) && return 0
            __out="$line" ;;
    esac
}

# ---------------------------------------------------------------------------
# Pane / process tree
# ---------------------------------------------------------------------------

# Bulk-data variant: read from caller-supplied tables, no forks.
# Usage: _state_pane_is_shell_bulk <session> <top_pid_map> <comm_map> <children_map>
# Returns: 0 if pane top process is a shell, 1 otherwise.
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

# Classify a session whose top pane process is a shell.
# Returns: idle (shell alive) or dead (pane gone).
agent_classify_exit() {
    local session="$1"
    tmux_session_pane_target "$session" "agent" >/dev/null 2>&1 || { echo "dead"; return; }
    echo "idle"
}

# Is this pane line part of Claude's input-box chrome (a full-width rule or the
# prompt line)? Used to anchor the live-status scan below. The prompt pattern
# lives in a variable so the literal '>' isn't parsed as redirection by [[ ]].
_STATE_PROMPT_RE='^[[:space:]]*[❯>][^[:alnum:]]*$'
_state_line_is_box_chrome() {
    local l="$1"
    [[ "$l" == *──────* ]] && return 0                # full-width box rule
    [[ "$l" =~ $_STATE_PROMPT_RE ]] && return 0        # prompt line
    return 1
}

# Banner Claude pins directly above the input box when the main turn has ended
# but a background agent/task/workflow is still in flight.
_STATE_BG_BANNER_RE='[Ww]aiting for [0-9]+ background [a-zA-Z]+ to finish'
# Background-shell counter in Claude's bottom mode line, e.g.
# "⏵⏵ auto mode on · 1 shell  ← for agents" — a digit-prefixed shell token.
_STATE_BG_SHELL_RE='[0-9]+ shells?([^[:alpha:]]|$)'

# Detect whether the session's agent (top) pane shows that background work is
# still running while the main turn looks idle (Stop fired -> waiting_input).
# Two on-screen signals, either of which means waiting_background:
#
#   A. The "Waiting for N background <agent|task|workflow> to finish" banner,
#      pinned directly above the input box while the turn blocks on background
#      agents/tasks/workflows.
#   B. The "N shell(s)" counter in the bottom mode line, shown while background
#      shells launched this turn are still running.
#
# Signal A's banner text persists in scrollback after the work finishes: Claude
# then prints completion output ("⏺ … finished") and a fresh status line
# ("✻ Brewed for 2m 22s") *below* the old banner and re-renders the input box at
# the bottom. A naive "banner appears anywhere in the viewport" match therefore
# stays stuck on waiting_background long after the wait is over. So we only count
# the banner when it is still the current status: anchor on the input box
# (bottom-most prompt / full-width rule), then scan upward past blank lines, box
# chrome, and the right-aligned hint line ("new task? /clear …"). The first
# substantive line decides — the banner means live; any other left-aligned
# transcript/status line means the banner has scrolled into history.
#
# Signal B's counter renders in the mode line *below* the input box, alongside
# the footer and any session-artifact line ("⧉ name"). There is no transcript
# below the box, so a "N shell" token there is always the live count; the
# artifact line carries no such token and so never affects state. Signal B is a
# live count maintained by Claude, so it is self-healing — no stale-scrollback
# problem.
#
# Captures the current viewport (one fork); the scan itself is fork-free bash.
# Callers gate this to idle-looking Claude sessions so busy/running and non-
# Claude sessions never pay the capture-pane fork.
# Usage: _state_pane_has_background_wait <session>   (0 = background work live)
_state_pane_has_background_wait() {
    local session="$1" pane line
    pane=$(am_tmux capture-pane -p -t "${session}:.{top}" 2>/dev/null) || return 1
    # Fast path: neither signal anywhere in the pane -> skip the line scan.
    [[ "$pane" =~ $_STATE_BG_BANNER_RE || "$pane" =~ $_STATE_BG_SHELL_RE ]] || return 1

    local -a lines=()
    while IFS= read -r line; do lines+=("$line"); done <<< "$pane"
    local n=${#lines[@]} i

    # Find the input box (bottom-most chrome line); fall back to scanning the
    # whole pane if none is visible (e.g. minimal test fixtures).
    local box=$n
    for (( i = n - 1; i >= 0; i-- )); do
        if _state_line_is_box_chrome "${lines[i]}"; then box=$i; break; fi
    done

    # Signal B — background-shell counter in the mode line (below the box).
    if (( box < n )); then
        for (( i = box + 1; i < n; i++ )); do
            [[ "${lines[i]}" =~ $_STATE_BG_SHELL_RE ]] && return 0
        done
    fi

    # Signal A — live "Waiting for N background … to finish" banner (above box).
    for (( i = box - 1; i >= 0; i-- )); do
        line="${lines[i]}"
        [[ "$line" =~ $_STATE_BG_BANNER_RE ]] && return 0
        [[ -z "${line//[[:space:]]/}" ]] && continue        # blank line
        _state_line_is_box_chrome "$line" && continue        # box rule / prompt
        # Left-aligned content below the banner -> banner has scrolled away.
        [[ "$line" =~ ^[[:space:]]{0,3}[^[:space:]] ]] && return 1
        # else: a right-aligned hint line -> keep scanning upward.
    done
    return 1
}

# ---------------------------------------------------------------------------
# Resolver
# ---------------------------------------------------------------------------

# Resolve session state.
#
# Bulk fixtures (status-bar tick): pass map names by nameref to avoid per-
# session forks. Without fixtures the resolver builds size-1 fixtures inline.
#
# Pipeline:
#   1. shell check  -> starting (created<5s, non-bulk) / idle / dead
#   2. hook file    -> running / waiting_* (Claude waiting_input is refined to
#                      waiting_background when the bg-work banner is on screen)
#   3. fallback     -> waiting_background (Claude banner) / unknown
#
# Usage:
#   _state_resolve <session> <agent_type> <dir>
#   _state_resolve <session> <agent_type> <dir> <top_pid_map> <comm_map> <children_map> <now_epoch>
_state_resolve() {
    local session="$1" agent_type="${2:-}" dir="${3:-}"

    local top_name comm_name child_name now_val
    local -A __auto_top=() __auto_comm=() __auto_child=()
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

    # 2. Hook file
    local hook_state=""
    _state_hook_read "$session" hook_state "$now_val"
    if [[ -n "$hook_state" ]]; then
        # Claude's main turn can stop (waiting_input) while background agents /
        # tasks / shells keep running. The hook can't see that; the on-screen
        # banner or the mode-line "N shell" counter can. Scanning only
        # waiting_input Claude sessions keeps busy/running and non-Claude
        # sessions fork-free.
        if [[ "$hook_state" == "waiting_input" && "$agent_type" == "claude" ]] \
            && _state_pane_has_background_wait "$session"; then
            _state_debug "$_dbg_session" "$_dbg_agent" pane waiting_background
            echo "waiting_background"
            return
        fi
        _state_debug "$_dbg_session" "$_dbg_agent" hook "$hook_state"
        echo "$hook_state"
        return
    fi

    # 3. Fallback: agent alive, hook silent or stale. A Claude session blocked
    #    on background work can land here if Stop never wrote a terminal state;
    #    the banner is the last honest signal before "unknown".
    if [[ "$agent_type" == "claude" ]] && _state_pane_has_background_wait "$session"; then
        _state_debug "$_dbg_session" "$_dbg_agent" pane waiting_background
        echo "waiting_background"
        return
    fi
    _state_debug "$_dbg_session" "$_dbg_agent" fallback unknown
    echo "unknown"
}

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

# Return current state of a session.
# Outputs one of: starting | running | waiting_input | waiting_permission |
#                 waiting_custom | idle | unknown | dead
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
#   states: comma-separated, default: waiting_input,waiting_permission,waiting_custom,idle,dead
#   timeout_seconds: default 600
# Outputs: matched state, or "timeout"
# Exit: 0=matched, 1=session not found, 3=timeout
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
