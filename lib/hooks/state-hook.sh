#!/usr/bin/env bash
# lib/hooks/state-hook.sh - Agent hook: maps lifecycle events to am session states
#
# Claude Code, Codex, and Cursor Agent call this script as a hook. Reads JSON
# from stdin, maps the event to an am state, finds the matching session in the
# registry, and writes the state to $AM_STATE_DIR/<session_name>.
#
# Supported events:
#   Stop (stop_hook_active != true)  → ready, or background
#                                      when the payload's background_tasks
#                                      array lists work still running
#   Notification[idle_prompt]        → ready (same background_tasks
#                                      refinement when the field is present;
#                                      without it, never downgrades
#                                      background unless a prior
#                                      Stop snapshot's leftover shells are
#                                      all unowned)
#   Notification[permission_prompt]  → waiting_user
#   Notification[elicitation_dialog] → waiting_user
#   UserPromptSubmit                 → running
#   PreToolUse                       → running
#   PermissionRequest                → waiting_user
#   PostToolUse                      → running
#   sessionStart / stop              → ready                 (Cursor)
#   beforeSubmitPrompt               → running              (Cursor)
#   preToolUse / postToolUse /
#   postToolUseFailure /
#   afterAgentResponse/Thought       → running              (Cursor)
#
# background_tasks: Claude Code ≥2.1 includes a background_tasks array in the
# Stop payload — one entry per still-running background item ({id, type
# (subagent|shell), status, description, …}), pruned to [] once everything
# finishes. It is a fresh snapshot at each Stop, and Stop re-fires when
# background work completes (the completion re-invokes Claude for a wrap-up
# turn), so the state is self-healing without any pane scraping. Older CLIs
# and Codex simply lack the field → the jq filter counts 0 → ready.
#
# Leftover shells: --fork-session / a parent-Claude exit reparents
# run_in_background zsh loops to PID 1. Claude still lists them as
# status=running, which would pin background after wrap-up. A
# running shell/local_bash task is ignored when its matching OS process is
# not owned by this Claude. Unmatched tasks are still counted. The last
# Stop's array is snapshotted to $AM_STATE_DIR/<session>.bg so a field-less
# idle_prompt can re-check leftovers.
#
# Monitors: type=monitor entries are passive wake triggers, not work — the
# Artifact tool's live-updates watch (armed on publish, re-armed on resume)
# and Monitor waits. They stay status=running for the life of the session
# and never complete, so nothing would ever re-fire Stop to clear them
# (observed live: two finished sessions pinned at background for an hour by
# one artifact watch each). They are never counted.
#
# Environment overrides (for testing):
#   AM_REGISTRY          — path to sessions.json (default: ~/.agent-manager/sessions.json)
#   AM_STATE_DIR         — directory for state files (default: /tmp/am-state/)
#   AM_STATE_GUARD_SECS  — grace window (s) during which tool hooks may not
#                          flip ready back to running (default: 10)
#
# Session identification (in order of preference):
#   1. $AM_SESSION_NAME (exported by am when launching the agent) — exact match
#   2. $TMUX_PANE → tmux session name — works for sessions running before
#      AM_SESSION_NAME was added, since agents inherit TMUX_PANE from their pane
#   3. cwd match against registry — last resort; cannot disambiguate when
#      multiple am sessions share a directory (two Claude instances in one repo)
#
# All three layers are gated on the agent family: the hook's event name
# proves which agent fired it (CamelCase → Claude Code / Codex; camelCase →
# Cursor; pi never calls this script — its states come from the in-process
# extension lib/hooks/am-state.ts), and the resolved session's registered
# agent_type must belong to that family. Without the gate, an unmanaged
# agent process (e.g. a Cursor conversation run outside am) whose cwd hosts
# an am session of a *different* agent clobbers that session's state and
# .sid/.transcript sidecars — observed live: a stray Cursor daily-log run
# flipped a mid-turn pi session to ready. A positively identified
# session (layers 1–2) with the wrong type means a foreign agent is nested
# inside an am pane; the hook exits rather than guessing by cwd.

set -euo pipefail

AM_DIR="${AM_DIR:-${HOME}/.agent-manager}"
AM_REGISTRY="${AM_REGISTRY:-${AM_DIR}/sessions.json}"
AM_STATE_DIR="${AM_STATE_DIR:-/tmp/am-state}"
AM_IDENTITY_DIR="${AM_IDENTITY_DIR:-${AM_DIR}/identities}"

# Canonicalize state values read from files created by am <=0.11. Keep this
# Bash-3-compatible: the hook runs under /bin/bash on macOS.
_normalize_state_value() {
    case "$1" in
        waiting_input)                         NORMALIZED_STATE="ready" ;;
        waiting_permission|waiting_custom)     NORMALIZED_STATE="waiting_user" ;;
        waiting_background)                    NORMALIZED_STATE="background" ;;
        running|ready|waiting_user|background) NORMALIZED_STATE="$1" ;;
        *)                                     NORMALIZED_STATE="" ;;
    esac
}

# Optional debug trail. Gated by AM_HOOK_DEBUG=1 — silent no-op otherwise.
# Lets us see when a hook fires but the script exits without writing state
# (registry miss, missing AM_SESSION_NAME, cwd mismatch, etc).
# Sink: $AM_DIR/.hook-debug.log
_hook_debug() {
    [[ "${AM_HOOK_DEBUG:-}" != "1" ]] && return 0
    local dir="${AM_DIR:-${HOME}/.agent-manager}"
    printf '%s\t%s\t%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${hook_type:-?}" "$*" \
        >> "$dir/.hook-debug.log" 2>/dev/null || true
}

# Read full stdin
hook_input=$(cat)

# Require jq
if ! command -v jq &>/dev/null; then
    exit 0
fi

# Extract hook type
hook_type=$(printf '%s' "$hook_input" | jq -r '.hook_event_name // empty' 2>/dev/null || true)
[[ -z "$hook_type" ]] && exit 0

# Cursor background/subagent hook events inherit the parent pane's
# AM_SESSION_NAME. They describe a different conversation and must never
# overwrite the parent session's state or durable resume identity.
is_background_agent=$(printf '%s' "$hook_input" | jq -r '.is_background_agent // false' 2>/dev/null || echo "false")
[[ "$is_background_agent" == "true" ]] && exit 0

# Guard against infinite loops from the Stop hook
if [[ "$hook_type" == "Stop" ]]; then
    stop_hook_active=$(printf '%s' "$hook_input" | jq -r '.stop_hook_active // false' 2>/dev/null || echo "false")
    if [[ "$stop_hook_active" == "true" ]]; then
        exit 0
    fi
fi

# Ready states are refined to background when the payload reports
# background work (subagents / background shells) still running.
#
# Leftover shells: a --fork-session or parent-Claude exit reparents
# run_in_background zsh loops to PID 1. Claude keeps listing them as
# status=running, so a naive count pins background after the wrap-up
# Stop (the tab stays ⧗ while the pane shows recap / "new task?"). A running
# shell task is ignored when we can see its OS process and that process is
# not owned by this Claude. Unmatched tasks are still counted — the payload
# stays authoritative when we cannot verify.
#
# Monitors (type=monitor: artifact live-update watches, Monitor waits) are
# never counted: they are wake triggers with no completion of their own, so
# counting them pins background with no self-heal at all.

# One `ps` snapshot per count. No associative arrays — this script is
# invoked as `bash` by Claude and must survive macOS /bin/bash 3.2.
_bg_ps_table=""

_bg_load_ps() {
    _bg_ps_table=$(ps -ax -o pid=,ppid=,command= 2>/dev/null || true)
}

_bg_ppid_of() {
    printf '%s\n' "$_bg_ps_table" | awk -v p="$1" '$1 == p { print $2; exit }'
}

_bg_cmd_of() {
    printf '%s\n' "$_bg_ps_table" | awk -v p="$1" '
        $1 == p { $1 = ""; $2 = ""; sub(/^ +/, ""); print; exit }'
}

_bg_find_claude_pid() {
    local pid="${PPID:-}" i=0 cmd first
    while [[ -n "$pid" && "$pid" != "0" && "$pid" != "1" && $i -lt 20 ]]; do
        cmd=$(_bg_cmd_of "$pid")
        first=${cmd%% *}
        first=${first##*/}
        if [[ "$first" == "claude" ]]; then
            echo "$pid"
            return 0
        fi
        pid=$(_bg_ppid_of "$pid")
        i=$((i + 1))
    done
    return 1
}

_bg_is_descendant() {
    local pid="$1" ancestor="$2" i=0
    while [[ -n "$pid" && "$pid" != "0" && $i -lt 24 ]]; do
        [[ "$pid" == "$ancestor" ]] && return 0
        [[ "$pid" == "1" ]] && return 1
        pid=$(_bg_ppid_of "$pid")
        i=$((i + 1))
    done
    return 1
}

# True when this running shell task matches only leftover (unowned) processes.
_bg_shell_task_is_leftover() {
    local id="$1" command="$2"
    local claude_pid="" pid ppid rest matched=0
    claude_pid=$(_bg_find_claude_pid || true)
    while read -r pid ppid rest; do
        [[ "$pid" =~ ^[0-9]+$ ]] || continue
        if [[ -n "$id" && ${#id} -ge 6 && "$rest" == *"$id"* ]]; then
            :
        elif [[ -n "$command" && ${#command} -ge 8 && "$rest" == *"$command"* ]]; then
            :
        else
            continue
        fi
        matched=1
        if [[ -n "$claude_pid" ]]; then
            if _bg_is_descendant "$pid" "$claude_pid"; then
                return 1
            fi
        elif [[ "$ppid" != "1" ]]; then
            return 1
        fi
    done < <(printf '%s\n' "$_bg_ps_table")
    [[ "$matched" -eq 1 ]]
}

# Count running background_tasks that should keep background.
# $1 = JSON array (the background_tasks value).
_bg_owned_running_count() {
    local tasks="$1"
    [[ -z "$tasks" || "$tasks" == "null" ]] && echo 0 && return 0
    local running
    running=$(printf '%s' "$tasks" | jq -c '[.[]? | select(.status == "running")]' 2>/dev/null) \
        || { echo 0; return 0; }
    local len
    len=$(printf '%s' "$running" | jq 'length' 2>/dev/null) || { echo 0; return 0; }
    [[ "$len" =~ ^[0-9]+$ ]] || { echo 0; return 0; }
    (( len == 0 )) && echo 0 && return 0

    _bg_load_ps

    local idx type id command n=0
    for (( idx = 0; idx < len; idx++ )); do
        type=$(printf '%s' "$running" | jq -r --argjson i "$idx" '.[$i].type // empty' 2>/dev/null || true)
        id=$(printf '%s' "$running" | jq -r --argjson i "$idx" '.[$i].id // empty' 2>/dev/null || true)
        command=$(printf '%s' "$running" | jq -r --argjson i "$idx" '.[$i].command // empty' 2>/dev/null || true)
        case "$type" in
            monitor)
                # Passive watcher (artifact live updates, Monitor wait): never work.
                continue
                ;;
            shell|local_bash|"")
                if [[ "$type" == "shell" || "$type" == "local_bash" || -n "$command" ]]; then
                    if _bg_shell_task_is_leftover "$id" "$command"; then
                        continue
                    fi
                fi
                ;;
        esac
        n=$((n + 1))
    done
    echo "$n"
}

_bg_running_count() {
    local tasks
    tasks=$(printf '%s' "$hook_input" | jq -c '.background_tasks // empty' 2>/dev/null) \
        || { echo 0; return 0; }
    [[ -z "$tasks" || "$tasks" == "null" ]] && echo 0 && return 0
    _bg_owned_running_count "$tasks"
}

# Does the payload carry the background_tasks field at all? Events that lack
# it (Notification idle_prompt fires without it) know nothing about
# background work and must not downgrade background — only an event
# that positively reports the field pruned/empty (Stop) may move it to
# ready, unless a previous Stop left a snapshot whose leftover
# shells have all been reparented off this Claude.
_bg_field_present() {
    printf '%s' "$hook_input" | jq -e 'has("background_tasks")' >/dev/null 2>&1
}

# Map hook event to am state
am_state=""
case "$hook_type" in
    Stop)
        am_state="ready"
        [[ "$(_bg_running_count)" =~ ^[1-9] ]] && am_state="background"
        ;;
    sessionStart|stop)
        am_state="ready"
        ;;
    Notification)
        notification_type=$(printf '%s' "$hook_input" | jq -r '.notification_type // empty' 2>/dev/null || true)
        case "$notification_type" in
            idle_prompt)
                am_state="ready"
                [[ "$(_bg_running_count)" =~ ^[1-9] ]] && am_state="background"
                ;;
            permission_prompt|elicitation_dialog) am_state="waiting_user" ;;
            *)                  exit 0 ;;
        esac
        ;;
    PermissionRequest)
        am_state="waiting_user"
        ;;
    UserPromptSubmit|PreToolUse|PostToolUse|beforeSubmitPrompt|preToolUse|postToolUse|postToolUseFailure|afterAgentResponse|afterAgentThought)
        am_state="running"
        ;;
    *)
        exit 0
        ;;
esac

# Agent family of the hook source, proven by the event name. CamelCase
# events exist only in the Claude Code / Codex hook API; camelCase events
# only in Cursor's. Unknown events already exited above.
case "$hook_type" in
    Stop|Notification|UserPromptSubmit|PreToolUse|PostToolUse|PermissionRequest)
        hook_family="claude codex" ;;
    *)
        hook_family="cursor" ;;
esac

# Registry is required for any session lookup or validation
[[ ! -f "$AM_REGISTRY" ]] && exit 0

# Helper: echo the session name if it exists in the registry, otherwise empty.
# Always returns success so callers can use command substitution under set -e.
_registry_has() {
    jq -e --arg k "$1" '.sessions[$k] // empty' "$AM_REGISTRY" &>/dev/null && echo "$1"
    return 0
}

# Helper: true when the session's registered agent_type belongs to the
# hook's agent family.
_family_match() {
    local t
    t=$(jq -r --arg k "$1" '.sessions[$k].agent_type // empty' "$AM_REGISTRY" 2>/dev/null || true)
    [[ -n "$t" && " $hook_family " == *" $t "* ]]
}

session_name=""
session_resolution=""

# 1. AM_SESSION_NAME — authoritative when set by agent_launch. If set but not
#    in the registry, the session was removed or renamed; do not fall through
#    to cwd matching, which would silently clobber the wrong session's state.
if [[ -n "${AM_SESSION_NAME:-}" ]]; then
    session_name=$(_registry_has "$AM_SESSION_NAME")
    if [[ -z "$session_name" ]]; then
        _hook_debug "AM_SESSION_NAME=$AM_SESSION_NAME not in registry; exiting"
        exit 0
    fi
    if ! _family_match "$session_name"; then
        _hook_debug "AM_SESSION_NAME=$session_name agent_type outside hook family ($hook_family); exiting"
        exit 0
    fi
    session_resolution="env"
fi

# 2. TMUX_PANE — agents inherit this from their tmux pane; resolving it to the
#    tmux session name directly avoids the duplicate-cwd bug even for sessions
#    that predate the AM_SESSION_NAME export.
if [[ -z "$session_name" && -n "${TMUX_PANE:-}" ]] && command -v tmux &>/dev/null; then
    tmux_session=$(tmux display-message -p -t "$TMUX_PANE" '#S' 2>/dev/null || true)
    if [[ -n "$tmux_session" ]]; then
        session_name=$(_registry_has "$tmux_session")
        if [[ -n "$session_name" ]] && ! _family_match "$session_name"; then
            _hook_debug "tmux session $session_name agent_type outside hook family ($hook_family); exiting"
            exit 0
        fi
        [[ -n "$session_name" ]] && session_resolution="tmux"
    fi
fi

# 3. cwd match — last resort; ambiguous when two sessions share a directory
if [[ -z "$session_name" ]]; then
    cwd=$(printf '%s' "$hook_input" | jq -r '.cwd // .workspace_roots[0] // empty' 2>/dev/null || true)
    if [[ -z "$cwd" ]]; then
        _hook_debug "no AM_SESSION_NAME/TMUX_PANE/cwd; cannot resolve session"
        exit 0
    fi
    cwd_real=$(cd "$cwd" 2>/dev/null && pwd) || {
        _hook_debug "cwd '$cwd' not accessible; exiting"
        exit 0
    }
    session_name=$(jq -r --arg cwd "$cwd_real" --arg fam "$hook_family" '
        .sessions
        | to_entries[]
        | select(.value.directory == $cwd)
        | select((.value.agent_type // "") as $t | ($fam | split(" ") | index($t)) != null)
        | .key
    ' "$AM_REGISTRY" 2>/dev/null | head -1 || true)
    [[ -n "$session_name" ]] && session_resolution="cwd"
fi

if [[ -z "$session_name" ]]; then
    _hook_debug "no session matched (cwd=${cwd_real:-?})"
    exit 0
fi

# Live working directory sidecar. Claude Code stamps hook payloads (and every
# transcript entry) with the Bash tool's *tracked* cwd — the agent process cwd
# and tmux's pane_current_path never move, so this is the only cheap,
# non-scraped signal that the agent has cd'd into another checkout. Written on
# every event, rewritten only on change; the title scan turns it into the
# registry's `workdir` plus a refreshed `branch` (lib/registry.sh
# auto_title_scan / Go RefreshTitles). Sessions matched by cwd have
# cwd == directory by construction, so there is nothing to record.
if [[ "$session_resolution" != "cwd" ]]; then
    hook_cwd=$(printf '%s' "$hook_input" | jq -r '.cwd // empty' 2>/dev/null || true)
    if [[ "$hook_cwd" == /* && "$hook_cwd" != *$'\n'* && -d "$hook_cwd" ]]; then
        cwd_file="$AM_STATE_DIR/$session_name.cwd"
        prev_cwd=""
        if [[ -f "$cwd_file" ]]; then
            IFS= read -r prev_cwd < "$cwd_file" || true
        fi
        if [[ "$hook_cwd" != "$prev_cwd" ]]; then
            mkdir -p "$AM_STATE_DIR"
            printf '%s' "$hook_cwd" > "$cwd_file"
            # Let the next status-bar tick relabel within ~5s instead of 60s.
            rm -f "$AM_DIR/.title_scan_last" 2>/dev/null || true
        fi
    fi
fi

# Race protection: a late PostToolUse can arrive after Stop has already
# written ready (hooks run concurrently, slow tool hook finishes last).
# ready is terminal — the agent is idle and the user is in the loop —
# so a late tool hook must not flip it back to running.
#
# The ready guard is bounded by a grace window (AM_STATE_GUARD_SECS
# after the write, default 10s) because a turn can *resume without
# UserPromptSubmit*: an in-turn question dialog (AskUserQuestion) idles long
# enough for Notification[idle_prompt] to write ready, and answering
# it continues the same turn — no new prompt event, only PreToolUse/
# PostToolUse. An unconditional guard swallowed those forever, pinning the
# session at ready while it was actively working. The trailing-hook
# race it exists for is a milliseconds-scale problem, so a short window
# absorbs it while letting genuine resumed activity flip to running.
#
# background is guarded *unconditionally*: a background subagent's
# own tool calls fire PreToolUse/PostToolUse in this session for as long as
# it runs (minutes), so any time window would eventually let them erase the
# refinement. The state still moves forward on its own — Stop re-fires when
# the background work completes (with a pruned background_tasks) — and
# UserPromptSubmit remains the user-driven exit.
#
# waiting_user is explicitly *transient*: it unblocks
# when the user answers, after which Claude/Codex resumes work and fires
# PreToolUse/PostToolUse. Those hooks MUST move the state forward to running,
# otherwise the session appears stuck at waiting_user until end-of-turn.
state_file="$AM_STATE_DIR/$session_name"
if [[ "$am_state" == "running" && "$hook_type" != "UserPromptSubmit" && "$hook_type" != "beforeSubmitPrompt" && -f "$state_file" ]]; then
    current=$(head -1 "$state_file" 2>/dev/null || true)
    _normalize_state_value "$current"
    current="$NORMALIZED_STATE"
    case "$current" in
        background) exit 0 ;;
        ready)
            state_mtime=$(stat -c %Y "$state_file" 2>/dev/null || stat -f %m "$state_file" 2>/dev/null || echo 0)
            if (( $(date +%s) - state_mtime <= ${AM_STATE_GUARD_SECS:-10} )); then
                exit 0
            fi
            ;;
    esac
fi

# Snapshot the last background_tasks array so a later field-less
# idle_prompt can re-check leftover shells after a wrap-up Stop that
# will not fire again until the next user prompt.
if _bg_field_present; then
    printf '%s' "$hook_input" | jq -c '.background_tasks' > "$state_file.bg" 2>/dev/null || true
fi

# background may only be downgraded to ready by an event
# whose payload actually carries the background_tasks field (Stop always
# does; it re-fires with a pruned array when the work finishes). Events
# without the field — Notification[idle_prompt] fires ~60s into an idle
# wait with no background_tasks — carry no information about background
# work and must not clobber the state (observed live: idle_prompt flipped
# background to ready exactly 60s after every Stop while
# the background shell/agent was still running).
#
# Exception: if a previous Stop left a snapshot and every leftover shell
# in it is now unowned (PPID=1 / not a child of this Claude), the session
# is done — allow the downgrade. The wrap-up Stop already fired; it will
# not fire again until the user types.
if [[ "$am_state" == "ready" && -f "$state_file" ]]; then
    current=$(head -1 "$state_file" 2>/dev/null || true)
    _normalize_state_value "$current"
    current="$NORMALIZED_STATE"
    if [[ "$current" == "background" ]] && ! _bg_field_present; then
        if [[ -f "$state_file.bg" ]] \
            && [[ "$(_bg_owned_running_count "$(cat "$state_file.bg" 2>/dev/null || echo '[]')")" == "0" ]]; then
            :
        else
            exit 0
        fi
    fi
fi

# Write state to file — only on a state *transition*. Same-state rewrites are
# skipped so the file's mtime pins the moment the state was entered: the
# status bar renders tab age from it ("waiting for you since" / "running
# for"). Repeated idle_prompt notifications, background-work Stop re-fires,
# and per-tool running rewrites would otherwise keep resetting it. Liveness
# of a running session is covered by tmux session_activity (the staleness
# gate in lib/state.sh measures against max(mtime, activity)), so the old
# rewrite-as-heartbeat behavior is not needed.
mkdir -p "$AM_STATE_DIR"
current=$(head -1 "$state_file" 2>/dev/null || true)
_normalize_state_value "$current"
if [[ "$NORMALIZED_STATE" != "$am_state" ]]; then
    printf '%s' "$am_state" > "$state_file"
fi

# Persist the Claude/Codex conversation id alongside the state when the hook
# payload exposes it. This lets restore snapshots bind to the exact pane that
# fired the hook instead of guessing by cwd, which is ambiguous for duplicate
# sessions in one repo.
hook_session_id=$(printf '%s' "$hook_input" | jq -r '.conversation_id // .session_id // .sessionId // empty' 2>/dev/null || true)
transcript_path=$(printf '%s' "$hook_input" | jq -r '.transcript_path // empty' 2>/dev/null || true)
if [[ -z "$hook_session_id" ]]; then
    if [[ -n "$transcript_path" ]]; then
        hook_session_id=$(basename "$transcript_path" .jsonl)
    fi
fi
if [[ -n "$hook_session_id" && "$hook_session_id" =~ ^[A-Za-z0-9._-]+$ ]]; then
    printf '%s' "$hook_session_id" > "$AM_STATE_DIR/$session_name.sid"
fi

if [[ "$transcript_path" == /* && "$transcript_path" != *$'\n'* ]]; then
    printf '%s' "$transcript_path" > "$AM_STATE_DIR/$session_name.transcript"
fi

# Durable Cursor identity is a pair. Some events expose a new conversation id
# without a transcript path; persisting only half would combine unrelated
# generations. Background agents were rejected above, and durable fields are
# updated together only from one complete hook payload.
if [[ "$session_resolution" != "cwd" && "$hook_family" == "cursor" ]]; then
    if [[ -n "$hook_session_id" && "$hook_session_id" =~ ^[A-Za-z0-9._-]+$ \
        && "$transcript_path" == /* && "$transcript_path" != *$'\n'* ]]; then
        mkdir -p "$AM_IDENTITY_DIR"
        durable_sid=""
        if [[ -f "$AM_IDENTITY_DIR/$session_name.sid" \
            && -f "$AM_IDENTITY_DIR/$session_name.transcript" ]]; then
            IFS= read -r durable_sid < "$AM_IDENTITY_DIR/$session_name.sid" 2>/dev/null || true
        fi
        # A physical Cursor process is pinned to its first complete identity
        # pair. Nested agents inherit AM_SESSION_NAME and do not reliably set
        # is_background_agent, so a later different id is not authoritative.
        if [[ -f "$AM_IDENTITY_DIR/$session_name.rebind" \
            || -z "$durable_sid" || "$durable_sid" == "$hook_session_id" ]]; then
            printf '%s' "$hook_session_id" > "$AM_IDENTITY_DIR/$session_name.sid"
            printf '%s' "$transcript_path" > "$AM_IDENTITY_DIR/$session_name.transcript"
            rm -f "$AM_IDENTITY_DIR/$session_name.rebind"
        fi
    fi
elif [[ "$session_resolution" != "cwd" ]]; then
    mkdir -p "$AM_IDENTITY_DIR"
    durable_sid=""
    allow_rebind=false
    wrote_durable_identity=false
    if [[ -f "$AM_IDENTITY_DIR/$session_name.sid" ]]; then
        IFS= read -r durable_sid < "$AM_IDENTITY_DIR/$session_name.sid" 2>/dev/null || true
    fi
    [[ -f "$AM_IDENTITY_DIR/$session_name.rebind" ]] && allow_rebind=true
    if [[ -n "$hook_session_id" && "$hook_session_id" =~ ^[A-Za-z0-9._-]+$ \
        && ( "$allow_rebind" == "true" \
            || -z "$durable_sid" || "$durable_sid" == "$hook_session_id" ) ]]; then
        printf '%s' "$hook_session_id" > "$AM_IDENTITY_DIR/$session_name.sid"
        wrote_durable_identity=true
    fi
    if [[ "$transcript_path" == /* && "$transcript_path" != *$'\n'* \
        && ( "$allow_rebind" == "true" \
            || -z "$durable_sid" || "$durable_sid" == "$hook_session_id" ) ]]; then
        printf '%s' "$transcript_path" > "$AM_IDENTITY_DIR/$session_name.transcript"
    fi
    if [[ "$allow_rebind" == "true" && "$wrote_durable_identity" == "true" ]]; then
        rm -f "$AM_IDENTITY_DIR/$session_name.rebind"
    fi
fi

# Invalidate list cache so the next fzf reload picks up the new state
rm -f "$AM_DIR/.list_cache" 2>/dev/null || true

# Invalidate title-scan throttle on prompt boundaries so the next status-bar
# tick refreshes the registry task field within ~5s instead of waiting up to
# 60s. Only fire on prompt boundaries — tool hooks would defeat the throttle
# for busy sessions.
case "$hook_type" in
    UserPromptSubmit|Stop|beforeSubmitPrompt|stop|sessionStart)
        rm -f "$AM_DIR/.title_scan_last" "$AM_DIR/.restore_scan_last" 2>/dev/null || true
        ;;
esac

# Push status-bar refresh to the dedicated tmux server so the new glyph
# appears immediately instead of waiting for the 5s status-interval tick.
if command -v tmux &>/dev/null; then
    tmux -L "${AM_TMUX_SOCKET:-agent-manager}" refresh-client -S 2>/dev/null || true
fi
