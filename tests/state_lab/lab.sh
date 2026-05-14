# shellcheck shell=bash
# tests/state_lab/lab.sh - State-detection lab harness
#
# Reusable scaffold for reproducing and debugging state-detection edge cases
# in isolation from the user's live am sessions. Three drivers exercise the
# three real input layers:
#
#   hook driver  -> lib/hooks/state-hook.sh   (push-based, primary for Claude)
#   jsonl driver -> _state_from_jsonl         (Claude conversation log)
#   pane  driver -> _state_from_pane          (tmux pane content, all agents)
#
# Each lab case sources this file, calls lab_init, sets up its inputs via
# the drivers, then queries state via the probe helpers and asserts results.
#
# Env contract (all overridable for nested labs / multi-session cases):
#   LAB_DIR             tmpdir root (auto, mktemp -d)
#   AM_DIR              $LAB_DIR/am          (registry, throttles)
#   AM_REGISTRY         $AM_DIR/sessions.json
#   AM_STATE_DIR        $LAB_DIR/state       (hook state files)
#   AM_TMUX_SOCKET      am-lab-$$            (isolated tmux server)
#   AM_SESSION_PREFIX   lab-                 (so list-internal/sidebar ignore real sessions)
#   HOME                $LAB_DIR/home        (Claude jsonl rooted here)
#
# Usage from a case file:
#   source "$(dirname "${BASH_SOURCE[0]}")/../lab.sh"
#   lab_init
#   trap lab_cleanup EXIT
#   ...drivers + assertions...

set -uo pipefail

_LAB_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$_LAB_SH_DIR/../.." && pwd)"
LIB_DIR="$PROJECT_DIR/lib"

# -- Counters / output -------------------------------------------------------

LAB_VERBOSE="${LAB_VERBOSE:-false}"
LAB_KEEP="${LAB_KEEP:-false}"
LAB_TESTS_RUN=0
LAB_TESTS_PASSED=0
LAB_TESTS_FAILED=0
LAB_FAIL_DETAILS=()

_C_RED='\033[0;31m'; _C_GREEN='\033[0;32m'; _C_YELLOW='\033[0;33m'
_C_DIM='\033[0;90m'; _C_RESET='\033[0m'

lab_log() { printf '%b\n' "${_C_DIM}[lab]${_C_RESET} $*" >&2; }
lab_say() { printf '%b\n' "$*" >&2; }

lab_assert() {
    local expected="$1" actual="$2" msg="${3:-}"
    LAB_TESTS_RUN=$((LAB_TESTS_RUN+1))
    if [[ "$expected" == "$actual" ]]; then
        LAB_TESTS_PASSED=$((LAB_TESTS_PASSED+1))
        printf '%b\n' "${_C_GREEN}PASS${_C_RESET} $msg" >&2
    else
        LAB_TESTS_FAILED=$((LAB_TESTS_FAILED+1))
        printf '%b\n' "${_C_RED}FAIL${_C_RESET} $msg" >&2
        printf '       expected: %q\n' "$expected" >&2
        printf '       actual:   %q\n' "$actual" >&2
        LAB_FAIL_DETAILS+=("$msg | want=$expected got=$actual")
    fi
}

lab_xfail() {
    # Known-broken assertion. Records as XFAIL when it fails (expected),
    # XPASS when it passes unexpectedly (bug was fixed -> promote to lab_assert).
    local expected="$1" actual="$2" msg="${3:-}"
    LAB_TESTS_RUN=$((LAB_TESTS_RUN+1))
    if [[ "$expected" == "$actual" ]]; then
        printf '%b\n' "${_C_YELLOW}XPASS${_C_RESET} $msg (expected to fail — promote to lab_assert)" >&2
        LAB_TESTS_PASSED=$((LAB_TESTS_PASSED+1))
    else
        printf '%b\n' "${_C_YELLOW}XFAIL${_C_RESET} $msg" >&2
        printf '       want: %q got: %q\n' "$expected" "$actual" >&2
    fi
}

# -- Setup / teardown --------------------------------------------------------

lab_init() {
    LAB_DIR="${LAB_DIR:-$(mktemp -d -t am-state-lab.XXXXXX)}"
    export LAB_DIR

    export AM_DIR="$LAB_DIR/am"
    export AM_REGISTRY="$AM_DIR/sessions.json"
    export AM_STATE_DIR="$LAB_DIR/state"
    export AM_TMUX_SOCKET="${AM_TMUX_SOCKET:-am-lab-$$}"
    export AM_SESSION_PREFIX="${AM_SESSION_PREFIX:-lab-}"
    export HOME="$LAB_DIR/home"

    mkdir -p "$AM_DIR" "$AM_STATE_DIR" "$HOME/.claude/projects"
    printf '{"sessions":{}}\n' > "$AM_REGISTRY"

    # Load lib functions with isolated env.
    # shellcheck disable=SC1091
    source "$LIB_DIR/utils.sh"
    # config.sh references $HOME — needs to point at LAB.
    # shellcheck disable=SC1091
    source "$LIB_DIR/config.sh"
    # shellcheck disable=SC1091
    source "$LIB_DIR/tmux.sh"
    # shellcheck disable=SC1091
    source "$LIB_DIR/registry.sh"
    # shellcheck disable=SC1091
    source "$LIB_DIR/state.sh"

    # Install lab overrides AFTER libs are sourced so they win over the real
    # implementations.
    _lab_install_overrides

    lab_log "LAB_DIR=$LAB_DIR  socket=$AM_TMUX_SOCKET  prefix=$AM_SESSION_PREFIX"
}

# Installed by lab_init AFTER libs are sourced so our virtual pane / session
# implementations beat the real tmux-backed ones.
_lab_install_overrides() {
    tmux_capture_pane() {
        local target="$1" lines="${2:-}"
        local session="${target%%:*}"
        session="${session%%.*}"
        if [[ -n "${LAB_PANE_CONTENT[$session]+set}" ]]; then
            local content="${LAB_PANE_CONTENT[$session]}"
            if [[ -n "$lines" && "$lines" =~ ^[0-9]+$ ]]; then
                printf '%s' "$content" | tail -n "$lines"
            else
                printf '%s' "$content"
            fi
            return
        fi
        am_tmux capture-pane -t "$target" -p -e -S "${lines:+-$lines}" -E - 2>/dev/null
    }
    _state_pane_is_shell() { return 1; }
    tmux_session_pane_target() { printf '%s:.0' "$1"; }
    tmux_session_exists() {
        local session="$1"
        [[ -n "${LAB_PANE_CONTENT[$session]+set}" ]] && return 0
        am_tmux has-session -t "$session" 2>/dev/null
    }
}

lab_cleanup() {
    local rc=$?
    if [[ "${LAB_KEEP}" == "true" ]]; then
        lab_log "keeping LAB_DIR=$LAB_DIR (LAB_KEEP=true)"
    else
        # Tear down lab tmux server (only if we created one).
        tmux -L "$AM_TMUX_SOCKET" kill-server 2>/dev/null || true
        [[ -n "${LAB_DIR:-}" && -d "$LAB_DIR" ]] && rm -rf "$LAB_DIR"
    fi
    return $rc
}

# -- Registry driver --------------------------------------------------------

# lab_register <session_name> <directory> [agent_type=claude] [branch=main] [task=task]
lab_register() {
    local name="$1" dir="$2"
    local agent="${3:-claude}" branch="${4:-main}" task="${5:-test task}"
    mkdir -p "$dir"
    local real_dir
    real_dir=$(cd "$dir" && pwd -P)
    local tmp
    tmp=$(mktemp)
    jq --arg n "$name" --arg d "$real_dir" --arg a "$agent" \
       --arg b "$branch" --arg t "$task" \
       --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
        .sessions[$n] = {
            name:$n, directory:$d, branch:$b, agent_type:$a,
            task:$t, created_at:$ts
        }' "$AM_REGISTRY" > "$tmp" && mv "$tmp" "$AM_REGISTRY"
    echo "$real_dir"
}

# -- Hook driver ------------------------------------------------------------

# lab_hook <session_name> <event_json>
#   Sends event_json to lib/hooks/state-hook.sh with AM_SESSION_NAME exported.
#   event_json fields: hook_event_name, plus event-specific keys
#   (notification_type, stop_hook_active, cwd, ...).
lab_hook() {
    local session="$1" input="$2"
    AM_SESSION_NAME="$session" \
    AM_REGISTRY="$AM_REGISTRY" AM_STATE_DIR="$AM_STATE_DIR" \
        "$PROJECT_DIR/lib/hooks/state-hook.sh" <<< "$input"
}

# lab_hook_age <session> <seconds_ago>
#   Backdate the hook state file's mtime — used to test the 180s staleness gate.
lab_hook_age() {
    local session="$1" seconds="$2"
    local f="$AM_STATE_DIR/$session"
    [[ -f "$f" ]] || return 0
    if date -j -v "-${seconds}S" >/dev/null 2>&1; then
        # macOS
        local t; t=$(date -j -v "-${seconds}S" +%Y%m%d%H%M.%S)
        touch -t "$t" "$f"
    else
        # GNU
        touch -d "@$(( $(date +%s) - seconds ))" "$f"
    fi
}

# -- JSONL driver -----------------------------------------------------------

# lab_jsonl_path <dir> <session_id>
lab_jsonl_path() {
    local dir="$1" sid="$2"
    local encoded
    encoded=$(echo "$dir" | sed -E 's|[/.]|-|g')
    local pdir="$HOME/.claude/projects/$encoded"
    mkdir -p "$pdir"
    echo "$pdir/$sid.jsonl"
}

# lab_jsonl <dir> <session_id> <line1> [line2 ...]
#   Writes JSONL with given lines (one per arg). Honors LAB_JSONL_AGE_SECS for
#   backdating the mtime (used to test the 30s staleness gate).
lab_jsonl() {
    local dir="$1" sid="$2"; shift 2
    local path
    path=$(lab_jsonl_path "$dir" "$sid")
    : > "$path"
    local line
    for line in "$@"; do printf '%s\n' "$line" >> "$path"; done
    if [[ -n "${LAB_JSONL_AGE_SECS:-}" ]]; then
        if date -j -v "-${LAB_JSONL_AGE_SECS}S" >/dev/null 2>&1; then
            local t; t=$(date -j -v "-${LAB_JSONL_AGE_SECS}S" +%Y%m%d%H%M.%S)
            touch -t "$t" "$path"
        else
            touch -d "@$(( $(date +%s) - LAB_JSONL_AGE_SECS ))" "$path"
        fi
    fi
    echo "$path"
}

# JSONL line builders — return one JSON line to feed lab_jsonl.
jsonl_assistant_end_turn()   { printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"done"}],"stop_reason":"end_turn"}}'; }
jsonl_assistant_tool_use()   { printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use"}],"stop_reason":"tool_use"}}'; }
jsonl_assistant_null_stop()  { printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"streaming"}],"stop_reason":null}}'; }
jsonl_user_text()            { printf '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"%s"}]}}' "${1:-hello}"; }
jsonl_user_tool_result()     { printf '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]}}'; }
jsonl_queue_enqueue()        { printf '{"type":"queue-operation","operation":"enqueue"}'; }
jsonl_system()               { printf '{"type":"system","content":"%s"}' "${1:-info}"; }
jsonl_file_history()         { printf '{"type":"file-history-snapshot","snapshot":{}}'; }
jsonl_attachment()           { printf '{"type":"attachment","filename":"x"}'; }

# -- Pane driver ------------------------------------------------------------

# Pane driver — virtual pane content.
#
# Running a real tmux pane and replaying keystrokes through a pty turned out
# to be brittle (cat doesn't process ESC c reliably; bash interprets payloads
# as commands and emits "command not found" noise). State detection only
# inspects the *captured text*, so the lab overrides `tmux_capture_pane` to
# return a per-session string from $LAB_PANE_CONTENT[session].
#
# `lab_tmux_start` is kept as a no-op shim so older cases can still call it
# while the new pane driver is purely in-memory.

declare -gA LAB_PANE_CONTENT=()

lab_tmux_start() { :; }

# lab_pane_paint <session> [pane=0] — heredoc or argv content becomes the
# pane's current capture. Auto-resets prior content.
lab_pane_paint() {
    local session="$1"; shift
    [[ "${1:-}" =~ ^[0-9]+$ ]] && shift
    local payload
    if [[ $# -gt 0 ]]; then payload="$*"; else payload=$(cat); fi
    LAB_PANE_CONTENT[$session]="$payload"
}

lab_pane_clear() {
    LAB_PANE_CONTENT[$1]=""
}

# (lab overrides for tmux_capture_pane, _state_pane_is_shell,
#  tmux_session_pane_target, and tmux_session_exists are installed by
#  _lab_install_overrides at the end of lab_init.)

# -- Probes ------------------------------------------------------------------

# probe_hook <session>  -> contents of hook state file, or "<missing>"
probe_hook() {
    local f="$AM_STATE_DIR/$1"
    [[ -f "$f" ]] || { echo "<missing>"; return; }
    head -1 "$f"
}

# probe_jsonl <dir> [session]  -> _state_from_jsonl output
probe_jsonl() {
    _state_from_jsonl "$1" "${2:-}" || true
}

# probe_pane <session> <agent_type>
probe_pane() {
    _state_from_pane "$1" "$2" --skip-alive-check 2>/dev/null || true
}

# probe_agent_get_state <session> — calls the public API (used by am list)
probe_agent_get_state() {
    agent_get_state "$1" 2>/dev/null || true
}

# probe_resolve <session> <agent_type> <dir> — non-bulk _state_resolve path
probe_resolve() {
    _state_resolve "$1" "$2" "$3" 2>/dev/null || true
}

# probe_resolve_bulk <session> <agent_type> <dir>
#   Builds empty bulk fixtures and runs the bulk variant. Use to assert both
#   call sites agree on a given fixture.
probe_resolve_bulk() {
    declare -A __PB_TOP=() __PB_COMM=() __PB_CHILD=()
    local __PB_NOW
    __PB_NOW=$(date +%s)
    _state_resolve "$1" "$2" "$3" \
        __PB_TOP __PB_COMM __PB_CHILD "$__PB_NOW" 2>/dev/null || true
}

# probe_all <session> [agent_type=claude]
#   Snapshot every layer side-by-side. Use to spot divergence between paths.
probe_all() {
    local session="$1" agent_type="${2:-claude}"
    local dir; dir=$(registry_get_field "$session" directory 2>/dev/null || true)
    printf '  %-22s = %s\n' "hook file"           "$(probe_hook "$session")"
    printf '  %-22s = %s\n' "_state_from_jsonl"   "$(probe_jsonl "$dir")"
    printf '  %-22s = %s\n' "_state_from_pane"    "$(probe_pane "$session" "$agent_type")"
    printf '  %-22s = %s\n' "agent_get_state"     "$(probe_agent_get_state "$session")"
    printf '  %-22s = %s\n' "_state_resolve"       "$(probe_resolve "$session" "$agent_type" "$dir")"
    printf '  %-22s = %s\n' "_state_resolve bulk"  "$(probe_resolve_bulk "$session" "$agent_type" "$dir")"
}

lab_report() {
    local total=$LAB_TESTS_RUN pass=$LAB_TESTS_PASSED fail=$LAB_TESTS_FAILED
    printf '\n' >&2
    if (( fail == 0 )); then
        printf '%b\n' "${_C_GREEN}OK${_C_RESET} $pass/$total passed" >&2
    else
        printf '%b\n' "${_C_RED}FAIL${_C_RESET} $fail/$total failed" >&2
        local d
        for d in "${LAB_FAIL_DETAILS[@]}"; do printf '  - %s\n' "$d" >&2; done
    fi
    return "$fail"
}
