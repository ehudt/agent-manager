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
# Session identification — positive signals only:
#   1. $AM_SESSION_NAME (seeded into the pane by am at creation) — exact match
#   2. $TMUX_PANE → tmux session name — agents inherit TMUX_PANE from their
#      pane, so this covers a pane whose environment lost the variable
#
# There is no cwd fallback. A directory is a shared resource: other am
# sessions, wp copies, and agents started outside am all run in it. Observed
# live: an interactive Claude launched from Obsidian's terminal plugin in
# ~/obsidian (neither variable set) was matched by directory to the am
# session launched there, drove its tab through running / background /
# waiting_user from a conversation the pane never ran, and overwrote its
# .sid/.transcript sidecars on the way. A process that carries neither
# variable is not in an am pane; its events are dropped (one line under
# AM_HOOK_DEBUG=1). The same holds for pi's in-process extension
# (lib/hooks/am-state.ts), which is a no-op without AM_SESSION_NAME.
#
# Both layers are gated on the agent family: the hook's event name proves
# which agent fired it (CamelCase → Claude Code / Codex; camelCase → Cursor;
# pi never calls this script), and the resolved session's registered
# agent_type must belong to that family. A positively identified session of
# the wrong type means a foreign agent is nested inside an am pane (observed
# live: a cursor-agent run by hand in a pi session's shell pane); the hook
# exits rather than write another agent's state.

set -euo pipefail

# A state hook must never fail the agent's turn: Claude Code surfaces a
# non-zero hook exit to the user. Every deliberate exit below is `exit 0`;
# this trap makes the same true of anything errexit or nounset trips.
trap 'exit 0' EXIT

# This script is invoked as `bash <path>` and stays Bash-3.2-clean on purpose
# (macOS /bin/bash): no associative arrays, namerefs, or 4.x expansions. It
# therefore needs no version gate — do not add 4.x features here.

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

# Desktop notification when a session enters a state the user should know
# about. Runs only on a state *transition*, off the critical path (inside the
# detached tail subshell), and never when the session is the one an attached
# tmux client is already showing. Config keys (config.json): `notify`
# (default true), `notify_states` (default "waiting_user"; "waiting_user,ready"
# also announces finished turns), `notify_cmd` (a bash snippet; env carries
# AM_NOTIFY_SESSION / AM_NOTIFY_STATE / AM_NOTIFY_TITLE / AM_NOTIFY_BODY).
# AM_NOTIFY_CMD in the environment overrides notify_cmd (tests). Without a
# command: osascript on macOS, notify-send on Linux, otherwise nothing.
# Usage: _notify_maybe <session> <state>
_notify_maybe() {
    local session="$1" state="$2"
    local cfg="${AM_DIR:-$HOME/.agent-manager}/config.json"
    local enabled="true" states="waiting_user" cmd=""
    if [[ -f "$cfg" ]]; then
        IFS=$'\x1f' read -r enabled states cmd < <(jq -r \
            '[((if has("notify") then .notify else true end) | tostring),(.notify_states // "waiting_user"), (.notify_cmd // "")] | join("")' \
            "$cfg" 2>/dev/null || printf 'true\x1fwaiting_user\x1f\n')
    fi
    [[ -n "${AM_NOTIFY_CMD:-}" ]] && cmd="$AM_NOTIFY_CMD"
    case "${enabled,,}" in true|1|yes|on) ;; *) return 0 ;; esac
    [[ ",${states// /}," == *",$state,"* ]] || return 0
    # On screen already: an attached client is displaying this session.
    if [[ -z "${AM_NOTIFY_CMD:-}" ]] && command -v tmux >/dev/null 2>&1 \
        && tmux -L "${AM_TMUX_SOCKET:-agent-manager}" list-clients -F '#{client_session}' 2>/dev/null \
            | grep -qx -- "$session"; then
        return 0
    fi
    local task="" label="$session" reg="${AM_REGISTRY:-${AM_DIR:-$HOME/.agent-manager}/sessions.json}"
    if [[ -f "$reg" ]]; then
        IFS=$'\x1f' read -r task label < <(jq -r --arg n "$session" \
            '.sessions[$n] // {} | [(.task // ""),
              ((((.workdir // "") | select(. != "")) // .directory // "") | split("/") | last)
              + (if (.branch // "") != "" and .branch != "main" and .branch != "master" then "/" + .branch else "" end)]
             | join("")' "$reg" 2>/dev/null || printf '\x1f\n')
        [[ -n "$label" ]] || label="$session"
    fi
    local verb
    case "$state" in
        waiting_user) verb="needs you" ;;
        ready) verb="finished" ;;
        *) verb="$state" ;;
    esac
    export AM_NOTIFY_SESSION="$session" AM_NOTIFY_STATE="$state"
    export AM_NOTIFY_TITLE="am · $label · $verb"
    export AM_NOTIFY_BODY="${task:-$session}"
    if [[ -n "$cmd" ]]; then
        bash -c "$cmd" >/dev/null 2>&1 || true
    elif command -v osascript >/dev/null 2>&1; then
        osascript -e 'display notification (system attribute "AM_NOTIFY_BODY") with title (system attribute "AM_NOTIFY_TITLE")' \
            >/dev/null 2>&1 || true
    elif command -v notify-send >/dev/null 2>&1; then
        notify-send -- "$AM_NOTIFY_TITLE" "$AM_NOTIFY_BODY" >/dev/null 2>&1 || true
    fi
}

# Read full stdin
hook_input=$(cat)

# Require jq
if ! command -v jq &>/dev/null; then
    exit 0
fi

# Every payload field this script consults, extracted in one jq call: the
# hook runs synchronously on each tool call, so every avoided jq fork is
# time off Claude's turn. Fields are NUL-joined (a path may contain anything
# but NUL) and read back with `read -d ''`; background_tasks travels as
# compact JSON for the count below. Invalid JSON leaves every field empty,
# so the event name check exits.
{
    IFS= read -r -d '' hook_type || true
    IFS= read -r -d '' is_background_agent || true
    IFS= read -r -d '' stop_hook_active || true
    IFS= read -r -d '' notification_type || true
    IFS= read -r -d '' hook_session_id || true
    IFS= read -r -d '' transcript_path || true
    IFS= read -r -d '' hook_cwd || true
    IFS= read -r -d '' bg_field_present || true
    IFS= read -r -d '' bg_tasks_json || true
    IFS= read -r -d '' payload_keys || true
} < <(printf '%s' "$hook_input" | jq -j '
    def s: (. // "") | tostring;
    ([0] | implode) as $nul
    | [ (.hook_event_name | s),
        (.is_background_agent // false | tostring),
        (.stop_hook_active // false | tostring),
        (.notification_type | s),
        ((.conversation_id // .session_id // .sessionId) | s),
        (.transcript_path | s),
        (.cwd | s),
        (has("background_tasks") | tostring),
        (.background_tasks // null | tojson),
        (if type == "object" then (keys | sort | join(",")) else "" end) ]
    | join($nul)' 2>/dev/null; printf '\0')
[[ -z "$hook_type" ]] && exit 0

# Cursor background/subagent hook events inherit the parent pane's
# AM_SESSION_NAME. They describe a different conversation and must never
# overwrite the parent session's state or durable resume identity.
[[ "$is_background_agent" == "true" ]] && exit 0

# Guard against infinite loops from the Stop hook
if [[ "$hook_type" == "Stop" && "$stop_hook_active" == "true" ]]; then
    exit 0
fi

# The state dir is user-only: it holds cwd, conversation-id, and transcript
# sidecars for every session. umask covers the whole path mkdir -p creates.
_state_dir_ensure() {
    [[ -d "$AM_STATE_DIR" ]] || (umask 077; mkdir -p "$AM_STATE_DIR")
}

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

    # One jq call lists the running entries as NUL-separated type/id/command
    # triples (plain indexed arrays: bash 3.2 has no associative ones).
    local -a types=() ids=() commands=()
    local type id command
    while IFS= read -r -d '' type && IFS= read -r -d '' id && IFS= read -r -d '' command; do
        types+=("$type")
        ids+=("$id")
        commands+=("$command")
    done < <(printf '%s' "$tasks" | jq -j '
        def s: (. // "") | tostring;
        ([0] | implode) as $nul
        | [ .[]? | select(.status == "running") | (.type | s), (.id | s), (.command | s) ]
        | map(. + $nul) | add // ""' 2>/dev/null || true)
    local len=${#types[@]}
    (( len == 0 )) && echo 0 && return 0

    _bg_load_ps

    local idx n=0
    for (( idx = 0; idx < len; idx++ )); do
        type=${types[$idx]}
        id=${ids[$idx]}
        command=${commands[$idx]}
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
    _bg_owned_running_count "$bg_tasks_json"
}

# Does the payload carry the background_tasks field at all? Events that lack
# it (Notification idle_prompt fires without it) know nothing about
# background work and must not downgrade background — only an event
# that positively reports the field pruned/empty (Stop) may move it to
# ready, unless a previous Stop left a snapshot whose leftover
# shells have all been reparented off this Claude.
_bg_field_present() {
    [[ "$bg_field_present" == "true" ]]
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

# Helper: print the session's registered agent_type — empty when the session
# is not in the registry (every registry_add writes the field). One jq call
# serves both the existence check and the family gate. Always succeeds, for
# command substitution under set -e.
_registry_agent_type() {
    jq -r --arg k "$1" '.sessions[$k].agent_type // empty' "$AM_REGISTRY" 2>/dev/null || true
}

# Helper: true when a registered agent_type belongs to the hook's agent family.
_family_match() {
    [[ -n "$1" && " $hook_family " == *" $1 "* ]]
}

session_name=""
session_agent=""

# 1. AM_SESSION_NAME — authoritative when set by agent_launch. If set but not
#    in the registry, the session was removed or renamed; do not fall through
#    to cwd matching, which would silently clobber the wrong session's state.
if [[ -n "${AM_SESSION_NAME:-}" ]]; then
    session_agent=$(_registry_agent_type "$AM_SESSION_NAME")
    if [[ -z "$session_agent" ]]; then
        _hook_debug "AM_SESSION_NAME=$AM_SESSION_NAME not in registry; exiting"
        exit 0
    fi
    if ! _family_match "$session_agent"; then
        _hook_debug "AM_SESSION_NAME=$AM_SESSION_NAME agent_type $session_agent outside hook family ($hook_family); exiting"
        exit 0
    fi
    session_name="$AM_SESSION_NAME"
fi

# 2. TMUX_PANE — agents inherit this from their tmux pane; resolving it to the
#    tmux session name directly avoids the duplicate-cwd bug even for sessions
#    that predate the AM_SESSION_NAME export.
if [[ -z "$session_name" && -n "${TMUX_PANE:-}" ]] && command -v tmux &>/dev/null; then
    tmux_session=$(tmux display-message -p -t "$TMUX_PANE" '#S' 2>/dev/null || true)
    if [[ -n "$tmux_session" ]]; then
        session_agent=$(_registry_agent_type "$tmux_session")
        if [[ -n "$session_agent" ]]; then
            if ! _family_match "$session_agent"; then
                _hook_debug "tmux session $tmux_session agent_type $session_agent outside hook family ($hook_family); exiting"
                exit 0
            fi
            session_name="$tmux_session"
        fi
    fi
fi

# Neither variable named an am pane: this process was not launched by am
# (an agent started by hand in some directory, possibly one that also hosts
# an am session). Its events are not ours. There is deliberately no
# directory-based guess here — see the header. This is the exit every
# non-am Claude on the machine takes on every event, so nothing is computed
# for the log line unless debugging is on.
if [[ -z "$session_name" ]]; then
    if [[ "${AM_HOOK_DEBUG:-}" == "1" ]]; then
        dbg_cwd="$hook_cwd"
        [[ -n "$dbg_cwd" ]] || dbg_cwd=$(printf '%s' "$hook_input" | jq -r '.workspace_roots[0]? // "?"' 2>/dev/null || echo '?')
        _hook_debug "no AM_SESSION_NAME/TMUX_PANE match; not an am pane (cwd=$dbg_cwd); exiting"
    fi
    exit 0
fi

# Conversation identity carried by the payload (hook_session_id /
# transcript_path, extracted above), persisted as the .sid/.transcript
# sidecars further down.
if [[ -z "$hook_session_id" && -n "$transcript_path" ]]; then
    hook_session_id=$(basename "$transcript_path" .jsonl)
fi

# Live working directory sidecar. Claude Code stamps hook payloads (and every
# transcript entry) with the Bash tool's *tracked* cwd — the agent process cwd
# and tmux's pane_current_path never move, so this is the only cheap,
# non-scraped signal that the agent has cd'd into another checkout. Written on
# every event, rewritten only on change; the title scan turns it into the
# registry's `workdir` plus a refreshed `branch` (lib/registry.sh
# auto_title_scan / Go RefreshTitles). hook_cwd was extracted above.
if [[ "$hook_cwd" == /* && "$hook_cwd" != *$'\n'* && -d "$hook_cwd" ]]; then
    cwd_file="$AM_STATE_DIR/$session_name.cwd"
    prev_cwd=""
    if [[ -f "$cwd_file" ]]; then
        IFS= read -r prev_cwd < "$cwd_file" || true
    fi
    if [[ "$hook_cwd" != "$prev_cwd" ]]; then
        _state_dir_ensure
        printf '%s' "$hook_cwd" > "$cwd_file"
        # Let the next status-bar tick relabel within ~5s instead of 60s.
        rm -f "$AM_DIR/.title_scan_last" 2>/dev/null || true
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
    _state_dir_ensure
    printf '%s' "$bg_tasks_json" > "$state_file.bg" 2>/dev/null || true
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
_state_dir_ensure
current=$(head -1 "$state_file" 2>/dev/null || true)
_normalize_state_value "$current"
state_transitioned=false
if [[ "$NORMALIZED_STATE" != "$am_state" ]]; then
    printf '%s' "$am_state" > "$state_file"
    state_transitioned=true
fi

# Persist the Claude/Codex conversation id alongside the state when the hook
# payload exposes it (extracted above, before the cwd identity gate). This
# lets restore snapshots bind to the exact pane that fired the hook instead
# of guessing by cwd, which is ambiguous for duplicate sessions in one repo.
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
if [[ "$hook_family" == "cursor" ]]; then
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
else
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

# Everything after the state write is a side effect on am's own caches and
# display, not on the state itself, so it runs off Claude's critical path:
# Claude waits for this process to exit and for its stdout/stderr to close,
# so the subshell is detached with every fd pointed away from the hook's
# pipes and the hook returns immediately.
#
#  - list cache: the next fzf reload picks up the new state
#  - title-scan / restore-scan throttles, on prompt boundaries only (tool
#    hooks would defeat the throttle for busy sessions): the next status-bar
#    tick refreshes the registry task field within ~5s instead of up to 60s
#  - refresh-client on the dedicated tmux server: the new glyph appears now
#    instead of at the next 5s status-interval tick
(
    rm -f "$AM_DIR/.list_cache" 2>/dev/null || true
    case "$hook_type" in
        UserPromptSubmit|Stop|beforeSubmitPrompt|stop|sessionStart)
            rm -f "$AM_DIR/.title_scan_last" "$AM_DIR/.restore_scan_last" 2>/dev/null || true
            ;;
    esac
    if command -v tmux &>/dev/null; then
        tmux -L "${AM_TMUX_SOCKET:-agent-manager}" refresh-client -S 2>/dev/null || true
    fi
    if [[ "$state_transitioned" == true ]]; then
        _notify_maybe "$session_name" "$am_state"
    fi
    # Payload-schema canary: remember the top-level keys each agent's
    # events carry, one file per <agent>.<event>, rewritten only when the
    # set changes (the previous set is kept in .prev). `am doctor` compares
    # the latest set against the fields the state machine reads, so a field
    # that disappears after an agent upgrade is reported instead of silently
    # degrading state detection. Tool events raised by a Claude subagent
    # carry agent_id/agent_type and get their own `.sub` file, otherwise the
    # main-agent and subagent sets would alternate on every turn.
    if [[ -n "$payload_keys" && "$hook_type" =~ ^[A-Za-z]+$ ]]; then
        schema_dir="$AM_DIR/hook-schema"
        schema_origin=""
        [[ ",$payload_keys," == *",agent_id,"* ]] && schema_origin=".sub"
        schema_file="$schema_dir/${session_agent:-unknown}.${hook_type}${schema_origin}.keys"
        prev_keys=""
        if [[ -f "$schema_file" ]]; then
            IFS= read -r prev_keys < "$schema_file" || true
        fi
        if [[ "$prev_keys" != "$payload_keys" ]]; then
            umask 077
            mkdir -p "$schema_dir" 2>/dev/null || true
            [[ -n "$prev_keys" ]] && printf '%s\n' "$prev_keys" > "$schema_file.prev"
            printf '%s\n' "$payload_keys" > "$schema_file"
        fi
    fi
) </dev/null >/dev/null 2>&1 &
disown 2>/dev/null || true
