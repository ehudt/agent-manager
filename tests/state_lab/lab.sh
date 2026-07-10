# shellcheck shell=bash
# tests/state_lab/lab.sh - State-detection lab harness (hook + ps tree only)
#
# Reusable scaffold for hook-driven state-detection scenarios. Pane and JSONL
# layers were removed when the resolver collapsed to hook + ps tree only;
# this harness retains only the hook driver and resolver probes.
#
# Env contract:
#   LAB_DIR             tmpdir root (auto, mktemp -d)
#   AM_DIR              $LAB_DIR/am          (registry, throttles)
#   AM_REGISTRY         $AM_DIR/sessions.json
#   AM_STATE_DIR        $LAB_DIR/state       (hook state files)
#   AM_TMUX_SOCKET      am-lab-$$            (isolated tmux server)
#   AM_SESSION_PREFIX   lab-
#   HOME                $LAB_DIR/home
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/../lab.sh"
#   lab_init
#   trap lab_cleanup EXIT
#   ...drivers + assertions...

set -uo pipefail

_LAB_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$_LAB_SH_DIR/../.." && pwd)"
LIB_DIR="$PROJECT_DIR/lib"

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

# Records XFAIL when assertion fails (expected), XPASS when it passes
# unexpectedly (bug fixed — promote to lab_assert).
lab_xfail() {
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

declare -gA LAB_PANE_CONTENT=()

lab_init() {
    LAB_DIR="${LAB_DIR:-$(mktemp -d -t am-state-lab.XXXXXX)}"
    export LAB_DIR

    export AM_DIR="$LAB_DIR/am"
    export AM_REGISTRY="$AM_DIR/sessions.json"
    export AM_STATE_DIR="$LAB_DIR/state"
    export AM_TMUX_SOCKET="${AM_TMUX_SOCKET:-am-lab-$$}"
    export AM_SESSION_PREFIX="${AM_SESSION_PREFIX:-lab-}"
    export HOME="$LAB_DIR/home"

    mkdir -p "$AM_DIR" "$AM_STATE_DIR" "$HOME"
    printf '{"sessions":{}}\n' > "$AM_REGISTRY"

    # shellcheck disable=SC1091
    source "$LIB_DIR/utils.sh"
    # shellcheck disable=SC1091
    source "$LIB_DIR/config.sh"
    # shellcheck disable=SC1091
    source "$LIB_DIR/tmux.sh"
    # shellcheck disable=SC1091
    source "$LIB_DIR/registry.sh"
    # shellcheck disable=SC1091
    source "$LIB_DIR/state.sh"

    _lab_install_overrides

    lab_log "LAB_DIR=$LAB_DIR  socket=$AM_TMUX_SOCKET  prefix=$AM_SESSION_PREFIX"
}

# Lab overrides: virtual sessions, no real tmux required. Session is "alive"
# if its name is in LAB_PANE_CONTENT (any value). Pane is never shell so the
# resolver always advances past stage 1 to the hook layer.
_lab_install_overrides() {
    _state_pane_is_shell() { return 1; }
    _state_pane_is_shell_bulk() { return 1; }
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
    # Mark session as alive for tmux_session_exists override.
    LAB_PANE_CONTENT[$name]="(opaque)"
    echo "$real_dir"
}

# -- Hook driver ------------------------------------------------------------

# lab_hook <session_name> <event_json>
lab_hook() {
    local session="$1" input="$2"
    AM_SESSION_NAME="$session" \
    AM_REGISTRY="$AM_REGISTRY" AM_STATE_DIR="$AM_STATE_DIR" \
        "$PROJECT_DIR/lib/hooks/state-hook.sh" <<< "$input"
}

# Backdate hook state file mtime — tests the 180s staleness gate.
lab_hook_age() {
    local session="$1" seconds="$2"
    local f="$AM_STATE_DIR/$session"
    [[ -f "$f" ]] || return 0
    if date -j -v "-${seconds}S" >/dev/null 2>&1; then
        local t; t=$(date -j -v "-${seconds}S" +%Y%m%d%H%M.%S)
        touch -t "$t" "$f"
    else
        touch -d "@$(( $(date +%s) - seconds ))" "$f"
    fi
}

# -- Probes ------------------------------------------------------------------

probe_hook() {
    local f="$AM_STATE_DIR/$1"
    [[ -f "$f" ]] || { echo "<missing>"; return; }
    head -1 "$f"
}

probe_agent_get_state() {
    agent_get_state "$1" 2>/dev/null || true
}

probe_resolve() {
    _state_resolve "$1" "$2" "$3" 2>/dev/null || true
}

# Bulk path — builds empty fixtures; with no top pid in the map, the bulk
# shell check returns false and the resolver advances to the hook layer.
probe_resolve_bulk() {
    declare -A __PB_TOP=() __PB_COMM=() __PB_CHILD=()
    local __PB_NOW
    __PB_NOW=$(date +%s)
    _state_resolve "$1" "$2" "$3" \
        __PB_TOP __PB_COMM __PB_CHILD "$__PB_NOW" 2>/dev/null || true
}

# Bulk path with an injected pane title (Claude's self-maintained glyph
# title). Drives the title-glyph layer without a real tmux pane.
# Usage: probe_resolve_titled <session> <agent> <dir> <title>
probe_resolve_titled() {
    declare -A __PT_TOP=() __PT_COMM=() __PT_CHILD=() __PT_TITLE=()
    __PT_TITLE[$1]="$4"
    local __PT_NOW
    __PT_NOW=$(date +%s)
    _state_resolve "$1" "$2" "$3" \
        __PT_TOP __PT_COMM __PT_CHILD "$__PT_NOW" "" __PT_TITLE 2>/dev/null || true
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
