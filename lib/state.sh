# shellcheck shell=bash
# state.sh - Session state detection (title glyph + hook file + ps tree)
#
# State sources, in order:
#   1. tmux + ps process tree     -> starting / idle / dead
#   2. pane title glyph (Claude)  -> a *version-dependent* signal:
#      - ≤2.1.233: Claude Code animates a busy glyph while a turn runs — a
#        braille spinner frame (U+2800-U+28FF) up to 2.1.221, a circle-phase
#        glyph ◐◓◑◒ (U+25D0-U+25D3) from 2.1.232 — and paints "✳" when it
#        needs the user. On those versions busy-vs-✳ is authoritative.
#      - ≥2.1.234: the title is written only when its *text* changes (the
#        960ms spinner animation was removed to stop tab-bar jitter — see
#        that version's changelog); the busy glyph is gone and "✳ <task>" is
#        painted from boot and stays through running turns. Verified
#        empirically on 2.1.237 (tests/live_lab): the title never leaves
#        "✳ …" across fresh/running/waiting/background states. So "✳" only
#        proves Claude is alive and has painted at least once; the ONE case
#        it still decides is a fresh session before any hook has fired
#        (no hook file + ✳ -> idle at the first prompt, since the very first
#        UserPromptSubmit would have created the file).
#   3. title status (Cursor 2026.08+) -> ready / working / in-turn question
#   4. turn-boundary hook (pi/Cursor/Claude) -> ungated: all three emit
#      explicit start/stop lifecycle transitions (pi's in-process extension;
#      Cursor's stop/beforeSubmitPrompt; Claude's Stop/UserPromptSubmit). A
#      dead process drops the pane to a shell, which step 1 already catches.
#      The hook file is the flavor source: waiting_input / waiting_permission
#      / waiting_custom / waiting_background (the hook writes
#      waiting_background directly from the Stop payload's background_tasks
#      on Claude Code ≥2.1)
#   5. fallback (other agents)    -> hook state with staleness gate, else unknown
#
# States: starting | running | waiting_input | waiting_permission |
#         waiting_custom | waiting_background | idle | unknown | dead
#
# Glyph x hook decision table (Claude sessions):
#   busy      + waiting_permission/custom -> pass through (a pending dialog
#               needs the user even if a spinner frame lingers; approval fires
#               PreToolUse which flips the file to running)
#   busy      + anything else             -> running (trust Claude's own
#               indicator; ≤2.1.233 only — the glyph no longer exists after)
#   attention + no hook file              -> waiting_input (fresh session idle
#               at its first prompt; correct on every version)
#   attention + hook file present         -> no title information: fall
#               through to the ungated hook read. On ≥2.1.234 "✳" is
#               permanent, so treating it as "needs the user" flipped every
#               RUNNING turn to waiting_input within one status-bar tick (and
#               fought the hooks by rewriting the state file). Do not
#               resurrect the old attention rows.
#   no signal (title disabled / claude still booting) -> ungated hook state,
#               else unknown. Other agents (codex): hook state with the 180s
#               running-staleness gate, else unknown

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
# Pane title glyph
# ---------------------------------------------------------------------------

# Classify Claude's self-maintained pane title.
# Byte-oriented (LC_ALL=C) so the match is identical under any caller locale:
# braille spinner frames U+2800-U+28FF (Claude Code ≤2.1.221) encode as
# E2 A0 80 .. E2 A3 BF, circle-phase busy glyphs ◐◓◑◒ U+25D0-U+25D3
# (Claude Code 2.1.232-2.1.233; live lab observed ◐ and ◑ frames) as
# E2 97 90 .. E2 97 93, the asterisk U+2733 as E2 9C B3. Anything else
# (hostname before Claude boots, user-set titles, other agents) is "none".
# NOTE: "attention" is a historical name — on ≥2.1.234 the ✳ is permanent and
# means only "Claude has painted its title"; the resolver treats it as an
# is-alive marker, not a needs-the-user marker (see the header table).
# Usage: _state_title_signal <title> <out_var>   (out: busy|attention|none)
_state_title_signal() {
    local LC_ALL=C
    local -n __sig="$2"
    case "$1" in
        $'\xe2\xa0'*|$'\xe2\xa1'*|$'\xe2\xa2'*|$'\xe2\xa3'*)  __sig="busy" ;;
        $'\xe2\x97\x90'*|$'\xe2\x97\x91'*|$'\xe2\x97\x92'*|$'\xe2\x97\x93'*)
                                                              __sig="busy" ;;
        $'\xe2\x9c\xb3'*)                                     __sig="attention" ;;
        *)                                                    __sig="none" ;;
    esac
}

# Cursor 2026.08+ appends a status suffix to context/task titles. These are
# terminal-title signals, not pane-content heuristics. Older releases omit the
# suffix and safely fall back to lifecycle hooks.
# Usage: _state_cursor_title_signal <title> <out_var>
# out: running|waiting_input|waiting_custom|none
_state_cursor_title_signal() {
    local -n __sig="$2"
    case "$1" in
        *" - ✅ Ready")          __sig="waiting_input" ;;
        *" - ⏳ Working"*)      __sig="running" ;;
        *" - ❓ Waiting for you") __sig="waiting_custom" ;;
        *)                      __sig="none" ;;
    esac
}

# ---------------------------------------------------------------------------
# Hook state file
# ---------------------------------------------------------------------------

# Read the raw hook state (ungated) into a caller-supplied var. Empty when
# the file is missing/unreadable or holds an unrecognized value.
# Usage: _state_hook_raw <session> <out_var>
_state_hook_raw() {
    local -n __raw="$2"
    __raw=""
    local line=""
    IFS= read -r line < "$AM_STATE_DIR/$1" 2>/dev/null || true
    case "$line" in
        running|waiting_input|waiting_permission|waiting_custom|waiting_background)
            __raw="$line" ;;
    esac
}

# Read session state from $AM_STATE_DIR/<session> into a caller-supplied var,
# with the staleness gate. Terminal waiting_* states are persistent. running
# gets a 180s gate — measured against max(file mtime, tmux session_activity)
# — so a wedged agent falls through to 'unknown' instead of looking busy
# forever. Only agents without turn-boundary lifecycle events use this
# (pi/Cursor/Claude are read ungated in the resolver): a live turn routinely
# outlives any staleness window — hooks skip same-state rewrites, and tmux
# session_activity is empirically unreliable (it goes stale while a pane
# visibly repaints; live lab, 2.1.237).
# Usage: _state_hook_read <session> <out_var> [now_epoch] [activity_epoch]
_state_hook_read() {
    local session="$1"
    local -n __out="$2"
    local now_epoch="${3:-}"
    local activity_epoch="${4:-}"
    __out=""
    local state_file="$AM_STATE_DIR/$session"
    [[ -f "$state_file" ]] || return 0
    local mtime
    mtime=$(stat -c %Y "$state_file" 2>/dev/null || stat -f %m "$state_file" 2>/dev/null) || return 0
    [[ -z "$now_epoch" ]] && now_epoch=$(date +%s)
    local line=""
    IFS= read -r line < "$state_file" 2>/dev/null || true
    case "$line" in
        waiting_input|waiting_permission|waiting_custom|waiting_background)
            __out="$line" ;;
        running)
            local fresh_ref=$mtime
            [[ "$activity_epoch" =~ ^[0-9]+$ ]] && (( activity_epoch > fresh_ref )) \
                && fresh_ref=$activity_epoch
            (( now_epoch - fresh_ref > 180 )) && return 0
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

# ---------------------------------------------------------------------------
# Resolver
# ---------------------------------------------------------------------------

# Resolve session state.
#
# Bulk fixtures (status-bar tick): pass map names by nameref to avoid per-
# session forks. Without fixtures the resolver builds size-1 fixtures inline
# (one tmux display-message fetches pane_pid, session_activity and pane_title
# together; one ps -eo builds the process maps).
#
# Pipeline:
#   1. shell check   -> starting (created<5s; bulk needs created_epoch) / idle / dead (non-bulk classify_exit race only)
#   2. title glyph   -> running / waiting_* per the decision table above
#   3. hook fallback -> gated hook state (no glyph signal), else unknown
#
# Usage:
#   _state_resolve <session> <agent_type> <dir>
#   _state_resolve <session> <agent_type> <dir> <top_pid_map> <comm_map> <children_map> <now_epoch> [activity_epoch] [title_map] [created_epoch]
_state_resolve() {
    local session="$1" agent_type="${2:-}" dir="${3:-}"

    local top_name comm_name child_name now_val activity_val="" title_val="" created_val=""
    local -A __auto_top=() __auto_comm=() __auto_child=()
    local skip_classifier=false
    if (( $# >= 7 )); then
        top_name="$4"; comm_name="$5"; child_name="$6"; now_val="$7"
        activity_val="${8:-}"
        if [[ -n "${9:-}" ]]; then
            local -n __TITLES="$9"
            title_val="${__TITLES[$session]:-}"
        fi
        created_val="${10:-}"
        skip_classifier=true
    else
        local pane_pid
        read -r pane_pid activity_val title_val <<< "$(am_tmux display-message -p \
            -t "${session}:.{top}" '#{pane_pid} #{session_activity} #{pane_title}' 2>/dev/null || true)"
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
            # Agree with the non-bulk classifier: a shell pane in a session
            # younger than 5s is the agent still starting, not idle. The bulk
            # caller supplies created_epoch (tmux #{session_created}); the
            # non-bulk path below derives the same from registry created_at.
            if [[ -n "$created_val" ]] && (( now_val - created_val < 5 )); then
                _state_debug "$_dbg_session" "$_dbg_agent" shell starting
                echo "starting"
                return
            fi
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

    # 2. Title glyph (version-dependent; see decision table in the header)
    if [[ "$agent_type" == "claude" ]]; then
        local sig="none"
        _state_title_signal "$title_val" sig
        if [[ "$sig" == "busy" ]]; then
            # Busy glyphs only exist on Claude Code ≤2.1.233; where present
            # they are authoritative for a live turn.
            local raw=""
            _state_hook_raw "$session" raw
            case "$raw" in
                waiting_permission|waiting_custom)
                    # A pending dialog needs the user; approval fires
                    # PreToolUse which moves the file forward.
                    _state_debug "$_dbg_session" "$_dbg_agent" title "$raw"
                    echo "$raw"
                    return ;;
            esac
            _state_debug "$_dbg_session" "$_dbg_agent" title running
            echo "running"
            return
        elif [[ "$sig" == "attention" ]]; then
            # Since 2.1.234 "✳ <task>" is painted at boot and never changes
            # glyph, so it carries no busy/waiting information. The one case
            # it still decides: Claude alive but no hook has ever fired —
            # a fresh session idle at its first prompt (the first
            # UserPromptSubmit would have created the file). Everything else
            # falls through to the hook read below.
            local raw=""
            _state_hook_raw "$session" raw
            if [[ -z "$raw" ]]; then
                _state_debug "$_dbg_session" "$_dbg_agent" title waiting_input
                echo "waiting_input"
                return
            fi
        fi
    fi

    # Cursor 2026.08+ publishes explicit status suffixes. Trust them when
    # present; older versions fall through to ungated lifecycle hooks.
    if [[ "$agent_type" == "cursor" ]]; then
        local cursor_sig="none" cursor_raw=""
        _state_cursor_title_signal "$title_val" cursor_sig
        if [[ "$cursor_sig" != "none" ]]; then
            _state_hook_raw "$session" cursor_raw
            if [[ "$cursor_sig" == "running" ]]; then
                case "$cursor_raw" in
                    waiting_permission|waiting_custom)
                        _state_debug "$_dbg_session" "$_dbg_agent" title "$cursor_raw"
                        echo "$cursor_raw"
                        return ;;
                esac
            elif [[ "$cursor_sig" == "waiting_input" && "$cursor_raw" == "running" ]]; then
                printf 'waiting_input' > "$AM_STATE_DIR/$session" 2>/dev/null || true
            fi
            _state_debug "$_dbg_session" "$_dbg_agent" title "$cursor_sig"
            echo "$cursor_sig"
            return
        fi
    fi

    # 3a. pi/Cursor/Claude: all three emit explicit turn-boundary lifecycle
    # events (pi's in-process extension; Cursor's stop/beforeSubmitPrompt;
    # Claude's Stop/UserPromptSubmit), so read their state ungated. Long
    # quiet tool calls and long thinking stretches must not flap a live turn
    # to unknown — and the old staleness gate would: hooks skip same-state
    # rewrites (mtime pins turn start) and tmux session_activity is
    # empirically unreliable (live lab on 2.1.237: activity age grew
    # unbounded while the pane visibly repainted). Process exit still drops
    # the pane to a shell, which step 1 catches; a ctrl-b backgrounded turn
    # fires its own Stop on 2.1.237 (live lab s6), so running files no
    # longer go silently stale.
    if [[ "$agent_type" == "pi" || "$agent_type" == "cursor" || "$agent_type" == "claude" ]]; then
        local lifecycle_hook=""
        _state_hook_raw "$session" lifecycle_hook
        if [[ -n "$lifecycle_hook" ]]; then
            _state_debug "$_dbg_session" "$_dbg_agent" hook "$lifecycle_hook"
            echo "$lifecycle_hook"
            return
        fi
        _state_debug "$_dbg_session" "$_dbg_agent" fallback unknown
        echo "unknown"
        return
    fi

    # 3b. Hook state, gated: Claude with a hook file (the primary path on
    #     ≥2.1.234, where "✳" carries no signal), no glyph at all (title
    #     disabled, agent still booting), or a non-Claude agent.
    local hook_state=""
    _state_hook_read "$session" hook_state "$now_val" "$activity_val"
    if [[ -n "$hook_state" ]]; then
        _state_debug "$_dbg_session" "$_dbg_agent" hook "$hook_state"
        echo "$hook_state"
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
#                 waiting_custom | waiting_background | idle | unknown | dead
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
