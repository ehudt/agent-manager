#!/usr/bin/env bash
# tests/live_lab/run_opencode.sh - Drive a REAL opencode session through every
# opencode-visible am state and record ground truth: plugin state-file
# transitions, sid/transcript sidecars, the first-message mirror, pane titles,
# and pane snapshots.
#
# opencode twin of run_pi.sh. NOT part of test_all.sh (spends real tokens).
# Run it when opencode updates, or when changing lib/state.sh /
# lib/hooks/opencode-state.js.
#
# Usage:
#   ./tests/live_lab/run_opencode.sh [results_dir]
#   LAB_SCENARIOS="o1 o3" ./tests/live_lab/run_opencode.sh
#   LAB_OPENCODE_ARGS="--model openrouter/deepseek/deepseek-v4.1-flash" \
#       ./tests/live_lab/run_opencode.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

RESULTS="${1:-$SCRIPT_DIR/results/opencode-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$RESULTS/snapshots"
LAB=$(mktemp -d -t am-live-lab-opencode.XXXXXX)
SOCKET="am-live-lab-opencode-$$"
SESSION="lab-opencode-1"
WORKDIR="$LAB/workdir"
mkdir -p "$WORKDIR"

# Hermetic environment: when the lab is launched from inside an am session,
# the pane's AM_SESSION_NAME / AM_AGENT_TYPE / AM_IDENTITY_DIR / AM_LOG_DIR
# would leak into the lab's tmux server and its opencode pane. AM_AGENT_TYPE
# in particular makes the plugin's family gate skip the session entirely.
unset AM_SESSION_NAME AM_AGENT_TYPE AM_IDENTITY_DIR AM_LOG_DIR
export AM_STATE_DIR="$LAB/state"
export AM_REGISTRY="$LAB/am/sessions.json"
export AM_DIR="$LAB/am"
export AM_IDENTITY_DIR="$LAB/identities"
export AM_TMUX_SOCKET="$SOCKET"
mkdir -p "$AM_STATE_DIR" "$AM_DIR" "$AM_IDENTITY_DIR"

# Project-level plugin dir so the lab never depends on a global `am install`.
mkdir -p "$WORKDIR/.opencode/plugins"
ln -sfn "$PROJECT_DIR/lib/hooks/opencode-state.js" "$WORKDIR/.opencode/plugins/am-state.js"

# Auto-allow bash so the long-quiet-tool scenario runs unattended instead of
# parking on a permission dialog (which would be waiting_user, not running).
printf '%s\n' '{"$schema":"https://opencode.ai/config.json","permission":{"bash":"allow"}}' \
    > "$WORKDIR/opencode.json"

OPENCODE_ARGS="${LAB_OPENCODE_ARGS:-}"
SCENARIOS="${LAB_SCENARIOS:-o1 o2 o3 o4}"

log() { printf '\033[0;36m[live-lab-opencode]\033[0m %s\n' "$*" >&2; }
mark() {  # scenario phase note -> timeline marker + report
    printf '%s\tMARK\t%s\t%s\n' "$(date -u +%H:%M:%S)" "$1" "$2" >> "$RESULTS/timeline.tsv"
    printf '[%s] %s: %s\n' "$(date -u +%H:%M:%S)" "$1" "$2" >> "$RESULTS/report.txt"
    log "$1: $2"
}

# --- registry with the lab session ------------------------------------------
cat > "$AM_REGISTRY" <<EOF
{"sessions":{"$SESSION":{"name":"$SESSION","directory":"$WORKDIR","branch":"main","agent_type":"opencode","task":"live lab","created_at":"$(date -u +%Y-%m-%dT%H:%M:%SZ)"}}}
EOF

# --- probes ------------------------------------------------------------------
pane_title()   { tmux -L "$SOCKET" display-message -p -t "$SESSION" '#{pane_title}' 2>/dev/null; }
pane_text()    { tmux -L "$SOCKET" capture-pane -p -t "$SESSION" 2>/dev/null; }
activity()     { tmux -L "$SOCKET" display-message -p -t "$SESSION" '#{session_activity}' 2>/dev/null; }
hook_state()   { head -1 "$AM_STATE_DIR/$SESSION" 2>/dev/null || echo '<none>'; }
hook_mtime()   { stat -f %m "$AM_STATE_DIR/$SESSION" 2>/dev/null || stat -c %Y "$AM_STATE_DIR/$SESSION" 2>/dev/null || echo 0; }
sid_exists()   { [[ -f "$AM_STATE_DIR/$SESSION.sid" ]] && echo 'yes' || echo 'no'; }
transcript_of(){ head -1 "$AM_STATE_DIR/$SESSION.transcript" 2>/dev/null || true; }

# Resolve state via lib/state.sh _state_resolve (needs libs sourced)
source "$PROJECT_DIR/lib/utils.sh"
source "$PROJECT_DIR/lib/config.sh"
am_config_init >/dev/null 2>&1 || true
source "$PROJECT_DIR/lib/tmux.sh"
source "$PROJECT_DIR/lib/registry.sh"
source "$PROJECT_DIR/lib/state.sh"

resolved_state() {
    local state
    AM_TMUX_SOCKET="$SOCKET" state=$(agent_get_state "$SESSION" 2>/dev/null) || state="unknown"
    echo "$state"
}

# --- sampler (background): 1s cadence + snapshot on transitions -------------
CURRENT_SCENARIO_FILE="$LAB/current_scenario"
echo "boot" > "$CURRENT_SCENARIO_FILE"
sampler() {
    local prev_key="" n=0
    while :; do
        local now scen title hs ha act aa rs sid key
        now=$(date +%s)
        scen=$(cat "$CURRENT_SCENARIO_FILE" 2>/dev/null || echo '?')
        [[ "$scen" == "STOP" ]] && break
        title=$(pane_title)
        hs=$(hook_state)
        ha=$(( now - $(hook_mtime) )); [[ "$hs" == "<none>" ]] && ha=-1
        act=$(activity); aa=-1; [[ "$act" =~ ^[0-9]+$ ]] && aa=$(( now - act ))
        rs=$(resolved_state)
        sid=$(sid_exists)
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$(date -u +%H:%M:%S)" "$scen" "$title" "$hs" "$ha" "$aa" "$rs" "$sid" >> "$RESULTS/timeline.tsv"
        key="$hs|$rs"
        if [[ "$key" != "$prev_key" ]]; then
            n=$((n+1))
            pane_text > "$RESULTS/snapshots/$(printf '%03d' "$n")-${scen}-hook-${hs}-resolved-${rs}.txt"
            prev_key="$key"
        fi
        sleep 1
    done
}

# --- drivers ------------------------------------------------------------------
send_prompt() {  # paste literally, then Enter
    tmux -L "$SOCKET" send-keys -t "$SESSION" -l "$1"
    sleep 0.4
    tmux -L "$SOCKET" send-keys -t "$SESSION" Enter
}

wait_hook_state() {  # state timeout -> 0 if reached
    local want="$1" timeout="${2:-60}" t0
    t0=$(date +%s)
    while (( $(date +%s) - t0 < timeout )); do
        [[ "$(hook_state)" == "$want" ]] && return 0
        sleep 0.5
    done
    return 1
}
observe() {  # scenario: record title+state now
    mark "$1" "observed title='$(pane_title)' hook=$(hook_state) resolved=$(resolved_state) sid=$(sid_exists)"
}

cleanup() {
    echo "STOP" > "$CURRENT_SCENARIO_FILE"
    [[ -n "${SAMPLER_PID:-}" ]] && kill "$SAMPLER_PID" 2>/dev/null || true
    tmux -L "$SOCKET" kill-server 2>/dev/null || true
    rm -rf "$LAB"
}
trap cleanup EXIT

# --- launch -------------------------------------------------------------------
log "results -> $RESULTS"
tmux -L "$SOCKET" new-session -d -s "$SESSION" -c "$WORKDIR" -x 200 -y 50
tmux -L "$SOCKET" set-option -t "$SESSION" allow-rename off
tmux -L "$SOCKET" send-keys -t "$SESSION" -l "export AM_SESSION_NAME=$SESSION AM_AGENT_TYPE=opencode AM_REGISTRY=$AM_REGISTRY AM_STATE_DIR=$AM_STATE_DIR AM_DIR=$AM_DIR AM_IDENTITY_DIR=$AM_IDENTITY_DIR AM_TMUX_SOCKET=$SOCKET; opencode $OPENCODE_ARGS"
tmux -L "$SOCKET" send-keys -t "$SESSION" Enter

sampler & SAMPLER_PID=$!

# Wait for opencode to boot (session.created fires ready)
sleep 8
if ! wait_hook_state ready 60; then
    mark boot "FATAL: opencode did not reach ready within ~68s (state=$(hook_state))"
    exit 1
fi
mark boot "opencode booted, state=$(hook_state)"
sleep 2

run_scenario() { echo "$1" > "$CURRENT_SCENARIO_FILE"; mark "$1" "=== begin ==="; }

# ── O1: fresh session → ready (identity sidecars land with the first prompt) ─
if [[ " $SCENARIOS " == *" o1 "* ]]; then
    run_scenario o1-fresh
    if [[ "$(hook_state)" == "ready" ]]; then
        mark o1-fresh "PASS: plugin wrote ready at boot (no session until first prompt)"
        observe o1-fresh
    else
        mark o1-fresh "FAIL: state $(hook_state), expected ready"
    fi
fi

# ── O2: prompt round-trip → running → ready ─────────────────────────────────
if [[ " $SCENARIOS " == *" o2 "* ]]; then
    run_scenario o2-roundtrip
    send_prompt "Reply with exactly: pong"
    if wait_hook_state running 15; then
        mark o2-roundtrip "PASS: plugin wrote running within 15s"
        observe o2-roundtrip
    else
        mark o2-roundtrip "FAIL: NO running within 15s (state=$(hook_state))"
    fi
    if wait_hook_state ready 120; then
        mark o2-roundtrip "PASS: plugin wrote ready within 120s"
        observe o2-roundtrip
        local_mirror=$(transcript_of)
        if [[ -n "$local_mirror" && -f "$local_mirror" ]]; then
            mark o2-roundtrip "mirror: $(head -1 "$local_mirror")"
        else
            mark o2-roundtrip "FAIL: first-message mirror missing"
        fi
    else
        mark o2-roundtrip "FAIL: NO ready within 120s (state=$(hook_state))"
        observe o2-roundtrip
    fi
fi

# ── O3: long quiet tool call → resolved state NEVER leaves running ──────────
if [[ " $SCENARIOS " == *" o3 "* ]]; then
    run_scenario o3-long-quiet
    send_prompt "Run this exact bash command and tell me when it finishes: sleep 200"
    if wait_hook_state running 15; then
        mark o3-long-quiet "plugin wrote running"
    else
        mark o3-long-quiet "FAIL: NO running before sleep started (state=$(hook_state))"
    fi

    mark o3-long-quiet "sampling 200s, asserting resolved==running throughout"
    violations=0
    t0=$(date +%s)
    while (( $(date +%s) - t0 < 200 )); do
        rs=$(resolved_state)
        elapsed=$(( $(date +%s) - t0 ))
        if [[ "$rs" != "running" ]]; then
            violations=$((violations + 1))
            mark o3-long-quiet "VIOLATION at t+${elapsed}s: resolved=$rs (expected running)"
        fi
        if (( elapsed % 30 == 0 )) && (( elapsed > 0 )); then
            mark o3-long-quiet "t+${elapsed}s: resolved=$rs hook=$(hook_state)"
        fi
        sleep 1
    done

    if (( violations == 0 )); then
        mark o3-long-quiet "PASS: resolved state stayed running for 200s (0 violations)"
    else
        mark o3-long-quiet "FAIL: $violations violations detected"
    fi

    if wait_hook_state ready 120; then
        mark o3-long-quiet "plugin wrote ready after turn completed"
        observe o3-long-quiet
    else
        mark o3-long-quiet "FAIL: NO ready after turn (state=$(hook_state))"
        observe o3-long-quiet
    fi
fi

# ── O4: death → shell → resolved should be idle ─────────────────────────────
if [[ " $SCENARIOS " == *" o4 "* ]]; then
    run_scenario o4-death
    tmux -L "$SOCKET" send-keys -t "$SESSION" C-c
    sleep 3
    title=$(pane_title)
    if [[ "$title" != "OC | "* && "$title" != "OpenCode" ]]; then
        mark o4-death "title changed to shell: '$title'"
        sleep 2
        rs=$(resolved_state)
        if [[ "$rs" == "idle" ]]; then
            mark o4-death "PASS: resolved state is idle despite stale plugin file"
            observe o4-death
        else
            mark o4-death "FAIL: resolved state is $rs (expected idle)"
            observe o4-death
        fi
    else
        mark o4-death "FAIL: opencode still running (title='$title')"
        observe o4-death
    fi
fi

echo "STOP" > "$CURRENT_SCENARIO_FILE"
wait "$SAMPLER_PID" 2>/dev/null || true
mark done "opencode live lab complete; results in $RESULTS"
agent_ver=$(opencode --version 2>/dev/null | head -1 | tr -d '\r')
printf 'agent_version\topencode\t%s\n' "${agent_ver:-unknown}" >> "$RESULTS/report.txt"
log "opencode ${agent_ver:-unknown}: if the report agrees, update the opencode line in tests/live_lab/VERIFIED"
log "report: $RESULTS/report.txt"
log "timeline: $RESULTS/timeline.tsv"
