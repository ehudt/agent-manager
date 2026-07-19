#!/usr/bin/env bash
# tests/live_lab/run_pi.sh - Drive a REAL pi session through every pi-visible
# am state and record ground truth: state-file transitions, sid sidecar,
# pane titles, and pane snapshots.
#
# Pi twin of run.sh (Claude). NOT part of test_all.sh (spends real tokens).
# Run it when pi updates or when changing lib/state.sh / lib/hooks/am-state.ts.
#
# Usage:
#   ./tests/live_lab/run_pi.sh [results_dir]
#   LAB_SCENARIOS="p1 p3" ./tests/live_lab/run_pi.sh
#   LAB_PI_ARGS="--provider anthropic --model claude-haiku-4-5" ./tests/live_lab/run_pi.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

RESULTS="${1:-$SCRIPT_DIR/results/pi-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$RESULTS/snapshots"
LAB=$(mktemp -d -t am-live-lab-pi.XXXXXX)
SOCKET="am-live-lab-pi-$$"
SESSION="lab-pi-1"
WORKDIR="$SCRIPT_DIR/workdir"
mkdir -p "$WORKDIR"

export AM_STATE_DIR="$LAB/state"
export AM_REGISTRY="$LAB/am/sessions.json"
export AM_DIR="$LAB/am"
export AM_TMUX_SOCKET="$SOCKET"
mkdir -p "$AM_STATE_DIR" "$AM_DIR"

PI_ARGS="${LAB_PI_ARGS:-}"
SCENARIOS="${LAB_SCENARIOS:-p1 p2 p3 p4}"

log() { printf '\033[0;36m[live-lab-pi]\033[0m %s\n' "$*" >&2; }
mark() {  # scenario phase note -> timeline marker + report
    printf '%s\tMARK\t%s\t%s\n' "$(date -u +%H:%M:%S)" "$1" "$2" >> "$RESULTS/timeline.tsv"
    printf '[%s] %s: %s\n' "$(date -u +%H:%M:%S)" "$1" "$2" >> "$RESULTS/report.txt"
    log "$1: $2"
}

# --- registry with the lab session ------------------------------------------
cat > "$AM_REGISTRY" <<EOF
{"sessions":{"$SESSION":{"name":"$SESSION","directory":"$WORKDIR","branch":"main","agent_type":"pi","task":"live lab","created_at":"$(date -u +%Y-%m-%dT%H:%M:%SZ)"}}}
EOF

# --- probes ------------------------------------------------------------------
pane_title()   { tmux -L "$SOCKET" display-message -p -t "$SESSION" '#{pane_title}' 2>/dev/null; }
pane_text()    { tmux -L "$SOCKET" capture-pane -p -t "$SESSION" 2>/dev/null; }
activity()     { tmux -L "$SOCKET" display-message -p -t "$SESSION" '#{session_activity}' 2>/dev/null; }
hook_state()   { head -1 "$AM_STATE_DIR/$SESSION" 2>/dev/null || echo '<none>'; }
hook_mtime()   { stat -f %m "$AM_STATE_DIR/$SESSION" 2>/dev/null || stat -c %Y "$AM_STATE_DIR/$SESSION" 2>/dev/null || echo 0; }
sid_exists()   { [[ -f "$AM_STATE_DIR/$SESSION.sid" ]] && echo 'yes' || echo 'no'; }

# Resolve state via lib/state.sh _state_resolve (needs libs sourced)
source "$PROJECT_DIR/lib/utils.sh"
source "$PROJECT_DIR/lib/config.sh"
am_config_init >/dev/null 2>&1 || true
source "$PROJECT_DIR/lib/tmux.sh"
source "$PROJECT_DIR/lib/registry.sh"
source "$PROJECT_DIR/lib/state.sh"

resolved_state() {
    # Must call with the lab socket override
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
press() { tmux -L "$SOCKET" send-keys -t "$SESSION" "$@"; }

wait_hook_state() {  # state timeout -> 0 if reached
    local want="$1" timeout="${2:-60}" t0
    t0=$(date +%s)
    while (( $(date +%s) - t0 < timeout )); do
        [[ "$(hook_state)" == "$want" ]] && return 0
        sleep 0.5
    done
    return 1
}
wait_pane_contains() {  # regex timeout
    local re="$1" timeout="${2:-60}" t0
    t0=$(date +%s)
    while (( $(date +%s) - t0 < timeout )); do
        pane_text | grep -qE "$re" && return 0
        sleep 0.5
    done
    return 1
}
observe() {  # scenario: record title+state now
    mark "$1" "observed title='$(pane_title)' hook=$(hook_state) resolved=$(resolved_state) sid=$(sid_exists)"
}

cleanup() {
    echo "STOP" > "$CURRENT_SCENARIO_FILE"
    tmux -L "$SOCKET" kill-server 2>/dev/null || true
    rm -rf "$LAB"
}
trap cleanup EXIT

# --- launch -------------------------------------------------------------------
log "results -> $RESULTS"
tmux -L "$SOCKET" new-session -d -s "$SESSION" -c "$WORKDIR" -x 200 -y 50
tmux -L "$SOCKET" set-option -t "$SESSION" allow-rename off
tmux -L "$SOCKET" send-keys -t "$SESSION" -l "export AM_SESSION_NAME=$SESSION AM_REGISTRY=$AM_REGISTRY AM_STATE_DIR=$AM_STATE_DIR AM_DIR=$AM_DIR AM_TMUX_SOCKET=$SOCKET; pi --no-extensions -e '$PROJECT_DIR/lib/hooks/am-state.ts' --no-session $PI_ARGS"
tmux -L "$SOCKET" send-keys -t "$SESSION" Enter

sampler & SAMPLER_PID=$!

# Wait for pi to boot (wait for state file to exist and be waiting_input)
sleep 5
if ! wait_hook_state waiting_input 40; then
    mark boot "FATAL: pi did not reach waiting_input within 45s (state=$(hook_state))"
    exit 1
fi
mark boot "pi booted, state=$(hook_state)"
sleep 2

run_scenario() { echo "$1" > "$CURRENT_SCENARIO_FILE"; mark "$1" "=== begin ==="; }

# ── P1: fresh session, hook should write waiting_input ──────────────────────
if [[ " $SCENARIOS " == *" p1 "* ]]; then
    run_scenario p1-fresh
    if wait_hook_state waiting_input 30; then
        mark p1-fresh "PASS: hook wrote waiting_input within 30s"
        observe p1-fresh
        # .sid sidecar should exist (tracks the session ID pi is using,
        # even with --no-session — the ID exists, it's just not persisted)
        if [[ "$(sid_exists)" == "yes" ]]; then
            mark p1-fresh "PASS: .sid present (tracks current session ID)"
        else
            mark p1-fresh "FAIL: .sid absent (expected present)"
        fi
    else
        mark p1-fresh "FAIL: NO waiting_input within 30s (state=$(hook_state))"
        observe p1-fresh
    fi
fi

# ── P2: prompt round-trip → running → waiting_input ─────────────────────────
if [[ " $SCENARIOS " == *" p2 "* ]]; then
    run_scenario p2-roundtrip
    send_prompt "Reply with exactly: pong"
    if wait_hook_state running 10; then
        mark p2-roundtrip "PASS: hook wrote running within 10s"
        observe p2-roundtrip
    else
        mark p2-roundtrip "FAIL: NO running within 10s (state=$(hook_state))"
    fi
    if wait_hook_state waiting_input 120; then
        mark p2-roundtrip "PASS: hook wrote waiting_input within 120s"
        observe p2-roundtrip
    else
        mark p2-roundtrip "FAIL: NO waiting_input within 120s (state=$(hook_state))"
        observe p2-roundtrip
    fi
fi

# ── P3: long quiet tool call → assert resolved state NEVER leaves running ───
if [[ " $SCENARIOS " == *" p3 "* ]]; then
    run_scenario p3-long-quiet
    send_prompt "Run this exact bash command and tell me when done: sleep 200"
    if wait_hook_state running 10; then
        mark p3-long-quiet "hook wrote running"
    else
        mark p3-long-quiet "FAIL: NO running state before sleep started (state=$(hook_state))"
    fi
    
    # Sample for 200s (the sleep duration), asserting resolved state stays running
    mark p3-long-quiet "sampling 200s, asserting resolved==running throughout"
    violations=0
    t0=$(date +%s)
    while (( $(date +%s) - t0 < 200 )); do
        rs=$(resolved_state)
        elapsed=$(( $(date +%s) - t0 ))
        if [[ "$rs" != "running" ]]; then
            violations=$((violations + 1))
            mark p3-long-quiet "VIOLATION at t+${elapsed}s: resolved=$rs (expected running)"
        fi
        # Log every 30s
        if (( elapsed % 30 == 0 )) && (( elapsed > 0 )); then
            mark p3-long-quiet "t+${elapsed}s: resolved=$rs hook=$(hook_state)"
        fi
        sleep 1
    done
    
    if (( violations == 0 )); then
        mark p3-long-quiet "PASS: resolved state stayed running for 200s (0 violations)"
    else
        mark p3-long-quiet "FAIL: $violations violations detected"
    fi
    
    # Wait for turn to complete
    if wait_hook_state waiting_input 60; then
        mark p3-long-quiet "hook wrote waiting_input after turn completed"
        observe p3-long-quiet
    else
        mark p3-long-quiet "FAIL: NO waiting_input after turn (state=$(hook_state))"
        observe p3-long-quiet
    fi
fi

# ── P4: death → shell → resolved should be idle ──────────────────────────────
if [[ " $SCENARIOS " == *" p4 "* ]]; then
    run_scenario p4-death
    # Quit pi: /quit or C-d (pi doesn't use C-c to quit)
    send_prompt "/quit"
    sleep 2
    # If /quit didn't work, try C-d
    if pane_title | grep -q 'π'; then
        press C-d
        sleep 2
    fi
    
    # Check if title changed from pi to shell (hostname or similar)
    # A pi title looks like "π - workdir" or "π - ..."
    # A shell title is typically the hostname or working directory without π
    title=$(pane_title)
    if [[ ! "$title" =~ π ]]; then
        mark p4-death "title changed to shell: '$title'"
        sleep 2
        rs=$(resolved_state)
        if [[ "$rs" == "idle" ]]; then
            mark p4-death "PASS: resolved state is idle despite stale hook file"
            observe p4-death
        else
            mark p4-death "FAIL: resolved state is $rs (expected idle)"
            observe p4-death
        fi
    else
        mark p4-death "FAIL: pi still running (title='$title')"
        observe p4-death
    fi
fi

echo "STOP" > "$CURRENT_SCENARIO_FILE"
wait "$SAMPLER_PID" 2>/dev/null || true
mark done "pi live lab complete; results in $RESULTS"
log "report: $RESULTS/report.txt"
log "timeline: $RESULTS/timeline.tsv"
