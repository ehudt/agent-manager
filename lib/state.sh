# shellcheck shell=bash
# state.sh - Session state detection (hook + ps tree only)
#
# State sources:
#   1. tmux + ps process tree   -> starting / idle / dead
#   2. hook file ($AM_STATE_DIR) -> running / waiting_input / waiting_permission /
#                                   waiting_custom / waiting_background (the hook
#                                   writes it directly from the Stop payload's
#                                   background_tasks on Claude Code ≥2.1)
#   3. pane banner scan          -> waiting_background (fallback for CLIs whose
#                                   Stop payload lacks background_tasks)
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
# 180s gate so a wedged agent falls through to 'unknown' instead of looking
# busy forever — measured against max(file mtime, tmux session_activity). The
# hook only writes on state *transitions* (the mtime doubles as the state-
# entry timestamp for tab ages), so for any turn longer than the gate the
# mtime is stale by design; tmux activity is the liveness signal — Claude
# repaints its spinner timer every second, keeping it fresh for the whole
# turn, while a genuinely wedged agent stops repainting and ages out.
# Usage: _state_hook_read <session> <out_var> [now_epoch] [activity_epoch]
# Side channel: _STATE_HOOK_RUNNING_MTIME_STALE=1 when a returned 'running'
# was rescued by fresh activity but its file mtime (= state-entry time) is
# past the gate. Normal for any turn longer than the gate; the resolver uses
# it to decide when the pane must corroborate that the turn is still live.
_state_hook_read() {
    local session="$1"
    local -n __out="$2"
    local now_epoch="${3:-}"
    local activity_epoch="${4:-}"
    __out=""
    _STATE_HOOK_RUNNING_MTIME_STALE=0
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
            (( now_epoch - mtime > 180 )) && _STATE_HOOK_RUNNING_MTIME_STALE=1
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

# Claude pins a persistent todo/task-list widget (header + one checkbox line
# per task) near the input box while any tasks are tracked. It can render
# between the background-wait banner and the box, so the upward scan in
# _state_pane_has_background_wait must skip it like other chrome instead of
# treating it as scrolled-away transcript.
_STATE_TODO_HEADER_RE='^[[:space:]]*[0-9]+ tasks?[[:space:]]*\(.*\)[[:space:]]*$'
_STATE_TODO_ITEM_RE='^[[:space:]]*[✓✔☑☒✗✘■□▪▫☐○●][[:space:]].*$'
_state_line_is_todo_widget() {
    local l="$1"
    [[ "$l" =~ $_STATE_TODO_HEADER_RE ]] && return 0
    [[ "$l" =~ $_STATE_TODO_ITEM_RE ]] && return 0
    return 1
}

# Banner Claude pins directly above the input box when the main turn has ended
# but a background agent/task/workflow is still in flight.
_STATE_BG_BANNER_RE='[Ww]aiting for [0-9]+ background [a-zA-Z]+ to finish'
# Completed-turn status with background work still live, e.g.
# "✻ Worked for 1m 2s · 1 shell still running". "still running" never appears
# in a live turn's spinner status ("· Billowing… (10s · ↓ 289 tokens)"), so
# this is end-of-turn evidence — usable even when the hook state claims the
# session is busy (a backgrounded turn's Stop fires from a bg session context
# that never resolves to the am session, leaving a stale 'running' behind).
_STATE_BG_STILL_RUNNING_RE='[0-9]+ (shells?|monitors?|agents?|tasks?|workflows?) still running'
# Completed-turn status without background work: spinner glyph, past-tense
# verb, "for <duration>" — "✻ Baked for 5m 25s". The live counterpart is a
# gerund with an ellipsis and parenthesized duration ("✻ Improvising… (2m 1s")
# and never contains " for <digit>"; the '…' exclusion in the classifier
# guards the distinction.
_STATE_TURN_DONE_RE='^[[:space:]]*[^[:alnum:][:space:]][[:space:]]+[A-Z][a-z]+ for [0-9]'
# Background-work counter in Claude's bottom mode line, e.g.
# "⏵⏵ auto mode on · 1 shell  ← for agents" or "… · 1 monitor · ← for agents"
# — a digit-prefixed shell/monitor token. "monitor" is the counter Claude shows
# for auto-mode background agents; either token means background work is live.
# The digit prefix keeps prose ("when the monitor fires …") from matching.
_STATE_BG_COUNTER_RE='[0-9]+ (shells?|monitors?)([^[:alpha:]]|$)'
# Live agent-context panel below the mode line: a filled-bullet "main" line
# (the foreground context) plus one hollow-bullet line per spawned agent still
# being tracked, e.g. "● main" / "○ general-purpose  Reading foo.py". Any
# hollow-bullet line means a background agent context is still live. The
# anchored form is for the per-line box scan; bash's [[ =~ ]] anchors '^' to
# the whole captured-pane string, not per embedded newline, so an unanchored
# twin is used for the whole-pane fast-path substring check.
_STATE_BG_AGENT_LINE_RE='^[[:space:]]*[○◯◦][[:space:]]+[[:alnum:]_-]+'
_STATE_BG_AGENT_LINE_ANY_RE='[○◯◦][[:space:]]+[[:alnum:]_-]'

# Detect whether the session's agent (top) pane shows that background work is
# still running while the main turn looks idle (Stop fired -> waiting_input).
# Four on-screen signals, any of which means waiting_background:
#
#   A. The "Waiting for N background <agent|task|workflow> to finish" banner,
#      pinned directly above the input box while the turn blocks on background
#      agents/tasks/workflows.
#   B. The "N shell(s)" / "N monitor(s)" counter in the bottom mode line, shown
#      while background shells or auto-mode background agents ("monitors")
#      launched this turn are still running.
#   C. A hollow-bullet line in the agent-context panel below the mode line
#      (e.g. "○ general-purpose  Reading foo.py"), listing a spawned agent
#      still tracked alongside the filled-bullet "● main" foreground line.
#   D. The completed-turn status line with a live background count, e.g.
#      "✻ Worked for 1m 2s · 1 shell still running", pinned above the input
#      box like Signal A.
#
# Signal A's banner text persists in scrollback after the work finishes: Claude
# then prints completion output ("⏺ … finished") and a fresh status line
# ("✻ Brewed for 2m 22s") *below* the old banner and re-renders the input box at
# the bottom. A naive "banner appears anywhere in the viewport" match therefore
# stays stuck on waiting_background long after the wait is over. So we only count
# the banner when it is still the current status: anchor on the input box
# (bottom-most prompt / full-width rule), then scan upward past blank lines, box
# chrome, the live todo/task-list widget, and the right-aligned hint line ("new
# task? /clear …"). The first substantive line decides — the banner means live;
# any other left-aligned transcript/status line means the banner has scrolled
# into history.
#
# Signal B's counter renders in the mode line *below* the input box, alongside
# the footer and any session-artifact line ("⧉ name"). There is no transcript
# below the box, so a "N shell"/"N monitor" token there is always the live
# count; the artifact line carries no such token and so never affects state.
# Signal B is a live count maintained by Claude, so it is self-healing — no
# stale-scrollback problem.
#
# Signal C's agent panel renders in that same below-box footer region, right
# alongside Signal B's counter, so it shares the same self-healing property —
# Claude drops the hollow-bullet line once the agent finishes, no scrollback
# staleness to guard against.
#
# Captures the current viewport (one fork); the scan itself is fork-free bash.
# Callers gate this to idle-looking Claude sessions so busy/running and non-
# Claude sessions never pay the capture-pane fork.
# Usage: _state_pane_has_background_wait <session>   (0 = background work live)
_state_pane_has_background_wait() {
    local session="$1" pane line
    pane=$(am_tmux capture-pane -p -t "${session}:.{top}" 2>/dev/null) || return 1
    # Fast path: no signal anywhere in the pane -> skip the line scan.
    [[ "$pane" =~ $_STATE_BG_BANNER_RE || "$pane" =~ $_STATE_BG_STILL_RUNNING_RE \
        || "$pane" =~ $_STATE_BG_COUNTER_RE \
        || "$pane" =~ $_STATE_BG_AGENT_LINE_ANY_RE ]] || return 1

    local -a lines=()
    while IFS= read -r line; do lines+=("$line"); done <<< "$pane"
    local n=${#lines[@]} i

    # Anchor on the input box. box_bottom = bottom-most chrome line (the box's
    # bottom rule, or a bare prompt in rule-less fixtures); Signal B scans below
    # it. When the box is delimited by full-width rules it may hold TYPED text
    # between them ("❯ continue …"), which must not be mistaken for transcript
    # that scrolled the banner away — so box_top climbs past the box interior to
    # the top rule, and Signal A scans from above it. Fall back to scanning the
    # whole pane when no chrome is visible (minimal test fixtures).
    local box_bottom=$n box_top=$n
    for (( i = n - 1; i >= 0; i-- )); do
        if _state_line_is_box_chrome "${lines[i]}"; then box_bottom=$i; break; fi
    done
    box_top=$box_bottom
    if [[ "${lines[box_bottom]:-}" == *──────* ]]; then
        for (( i = box_bottom - 1; i >= 0; i-- )); do
            if [[ "${lines[i]}" == *──────* ]]; then box_top=$i; break; fi
        done
    fi

    # Signal B/C — background-work counter (shell/monitor) or a hollow-bullet
    # agent-panel line, both in the mode line / footer region below the box.
    if (( box_bottom < n )); then
        for (( i = box_bottom + 1; i < n; i++ )); do
            [[ "${lines[i]}" =~ $_STATE_BG_COUNTER_RE ]] && return 0
            [[ "${lines[i]}" =~ $_STATE_BG_AGENT_LINE_RE ]] && return 0
        done
    fi

    # Signal A/D — live "Waiting for N background … to finish" banner or the
    # completed-turn "… still running" status (above box).
    for (( i = box_top - 1; i >= 0; i-- )); do
        line="${lines[i]}"
        [[ "$line" =~ $_STATE_BG_BANNER_RE ]] && return 0
        [[ "$line" =~ $_STATE_BG_STILL_RUNNING_RE ]] && return 0
        [[ -z "${line//[[:space:]]/}" ]] && continue        # blank line
        _state_line_is_box_chrome "$line" && continue        # box rule / prompt
        _state_line_is_todo_widget "$line" && continue       # todo/task list widget
        # Left-aligned content below the banner -> banner has scrolled away.
        [[ "$line" =~ ^[[:space:]]{0,3}[^[:space:]] ]] && return 1
        # else: a right-aligned hint line -> keep scanning upward.
    done
    return 1
}

# Classify whether the agent pane shows the turn is OVER, from the live status
# line pinned directly above the input box. Echoes:
#   waiting_background — banner (Signal A) or a completed-turn status carrying
#                        a live background count ("… · 1 shell still running")
#   waiting_input      — completed-turn status without background work
#                        ("✻ Baked for 5m 25s")
#   ""                 — inconclusive: live spinner ("· Billowing… (10s …"),
#                        no status visible, or non-status transcript
#
# Used when the hook state cannot be trusted: a backgrounded turn (ctrl-b /
# "Backgrounding after the current tool finishes") continues under a bg
# session context whose hooks never resolve to the am session, so its turn
# end writes nothing and the state file stays 'running'. tmux activity can't
# break the tie — user presence (viewing/typing) keeps it fresh. Only the
# end-of-turn signals count here: the mode-line counter and agent panel
# (Signals B/C) also render during live turns, so they prove nothing, while
# a live turn always pins its spinner status above the box, which stops this
# scan before any stale scrollback can match. Same anchoring as the banner
# scan; one capture-pane fork.
# Usage: _state_pane_end_of_turn_state <session>
_state_pane_end_of_turn_state() {
    local session="$1" pane line
    pane=$(am_tmux capture-pane -p -t "${session}:.{top}" 2>/dev/null) || return 0

    local -a lines=()
    while IFS= read -r line; do lines+=("$line"); done <<< "$pane"
    local n=${#lines[@]} i

    # Anchor on the input box (see _state_pane_has_background_wait).
    local box_bottom=$n box_top=$n
    for (( i = n - 1; i >= 0; i-- )); do
        if _state_line_is_box_chrome "${lines[i]}"; then box_bottom=$i; break; fi
    done
    box_top=$box_bottom
    if [[ "${lines[box_bottom]:-}" == *──────* ]]; then
        for (( i = box_bottom - 1; i >= 0; i-- )); do
            if [[ "${lines[i]}" == *──────* ]]; then box_top=$i; break; fi
        done
    fi

    for (( i = box_top - 1; i >= 0; i-- )); do
        line="${lines[i]}"
        if [[ "$line" =~ $_STATE_BG_BANNER_RE || "$line" =~ $_STATE_BG_STILL_RUNNING_RE ]]; then
            echo "waiting_background"
            return 0
        fi
        if [[ "$line" =~ $_STATE_TURN_DONE_RE && "$line" != *…* ]]; then
            echo "waiting_input"
            return 0
        fi
        [[ -z "${line//[[:space:]]/}" ]] && continue        # blank line
        _state_line_is_box_chrome "$line" && continue        # box rule / prompt
        _state_line_is_todo_widget "$line" && continue       # todo/task list widget
        # First substantive left-aligned line is not a completed-turn status:
        # a live spinner or plain transcript -> inconclusive.
        [[ "$line" =~ ^[[:space:]]{0,3}[^[:space:]] ]] && return 0
        # else: a right-aligned hint line -> keep scanning upward.
    done
    return 0
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
#   _state_resolve <session> <agent_type> <dir> <top_pid_map> <comm_map> <children_map> <now_epoch> [activity_epoch]
_state_resolve() {
    local session="$1" agent_type="${2:-}" dir="${3:-}"

    local top_name comm_name child_name now_val activity_val=""
    local -A __auto_top=() __auto_comm=() __auto_child=()
    local skip_classifier=false
    if (( $# >= 7 )); then
        top_name="$4"; comm_name="$5"; child_name="$6"; now_val="$7"
        activity_val="${8:-}"
        skip_classifier=true
    else
        local pane_pid
        read -r pane_pid activity_val <<< "$(am_tmux display-message -p \
            -t "${session}:.{top}" '#{pane_pid} #{session_activity}' 2>/dev/null || true)"
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
    _state_hook_read "$session" hook_state "$now_val" "$activity_val"
    if [[ -n "$hook_state" ]]; then
        # Claude's main turn can stop (waiting_input) while background agents /
        # tasks / shells keep running. On Claude Code ≥2.1 the hook writes
        # waiting_background itself (Stop payload background_tasks) and that
        # state passes straight through below; this pane scan is the fallback
        # for CLIs whose Stop payload lacks the field. Scanning only
        # waiting_input Claude sessions keeps busy/running and non-Claude
        # sessions fork-free.
        if [[ "$hook_state" == "waiting_input" && "$agent_type" == "claude" ]] \
            && _state_pane_has_background_wait "$session"; then
            _state_debug "$_dbg_session" "$_dbg_agent" pane waiting_background
            echo "waiting_background"
            return
        fi
        # A running state past the mtime gate survives only via fresh tmux
        # activity — which user presence also bumps (viewing/typing). A
        # backgrounded turn's end writes nothing (its Stop fires from a bg
        # session context), leaving a wrong 'running' pinned while the user
        # looks at the session. Demand end-of-turn evidence from the pane (a
        # completed-turn status / banner; a live turn's spinner blocks the
        # scan) before trusting it.
        if [[ "$hook_state" == "running" && "$agent_type" == "claude" \
            && "${_STATE_HOOK_RUNNING_MTIME_STALE:-0}" == "1" ]]; then
            local _eot
            _eot=$(_state_pane_end_of_turn_state "$session")
            if [[ -n "$_eot" ]]; then
                _state_debug "$_dbg_session" "$_dbg_agent" pane "$_eot"
                echo "$_eot"
                return
            fi
        fi
        _state_debug "$_dbg_session" "$_dbg_agent" hook "$hook_state"
        echo "$hook_state"
        return
    fi

    # 3. Fallback: agent alive, hook silent or stale. The pane is the last
    #    honest signal before "unknown": a completed-turn status classifies
    #    the session as waiting_input / waiting_background, and the broader
    #    background-wait signals (mode-line counter, agent panel) still catch
    #    a background wait whose status line isn't visible.
    if [[ "$agent_type" == "claude" ]]; then
        local _eot_fb
        _eot_fb=$(_state_pane_end_of_turn_state "$session")
        if [[ -n "$_eot_fb" ]]; then
            _state_debug "$_dbg_session" "$_dbg_agent" pane "$_eot_fb"
            echo "$_eot_fb"
            return
        fi
        if _state_pane_has_background_wait "$session"; then
            _state_debug "$_dbg_session" "$_dbg_agent" pane waiting_background
            echo "waiting_background"
            return
        fi
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
