#!/usr/bin/env bash
# tests/live_lab/run.sh - Drive a REAL Claude Code session through every am
# state and record ground truth: hook payloads, state-file transitions, pane
# title, tmux activity, and pane snapshots.
#
# This is the empirical layer of state-detection testing. It is NOT part of
# test_all.sh (it spends real tokens, ~5-10 min wall time). Run it:
#   - when Claude Code updates (verify signal contract still holds)
#   - when changing lib/state.sh or lib/hooks/state-hook.sh semantics
#   - to harvest fresh pane fixtures for tests/test_state.sh
#
# Usage:
#   ./tests/live_lab/run.sh [results_dir]     # run all scenarios
#   LAB_SCENARIOS="s2 s4" ./tests/live_lab/run.sh   # subset
#
# Outputs in results dir:
#   timeline.tsv     1s samples: ts scenario title_glyph hook_state hook_age act_age status_line
#   payloads.jsonl   every hook payload Claude fired (tee'd via --settings)
#   snapshots/       pane captures taken on every state/title transition
#   report.txt       per-scenario observed behavior summary
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

RESULTS="${1:-$SCRIPT_DIR/results/$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$RESULTS/snapshots"
LAB=$(mktemp -d -t am-live-lab.XXXXXX)
SOCKET="am-live-lab-$$"
SESSION="lab-live-1"
WORKDIR="$SCRIPT_DIR/workdir"
mkdir -p "$WORKDIR"

export AM_STATE_DIR="$LAB/state"
export AM_REGISTRY="$LAB/am/sessions.json"
export AM_DIR="$LAB/am"
mkdir -p "$AM_STATE_DIR" "$AM_DIR"

MODEL="${LAB_MODEL:-haiku}"
SCENARIOS="${LAB_SCENARIOS:-s1 s2 s3 s4 s5 s6 s7}"

log() { printf '\033[0;36m[live-lab]\033[0m %s\n' "$*" >&2; }
mark() {  # scenario phase note -> timeline marker + report
    printf '%s\tMARK\t%s\t%s\n' "$(date -u +%H:%M:%S)" "$1" "$2" >> "$RESULTS/timeline.tsv"
    printf '[%s] %s: %s\n' "$(date -u +%H:%M:%S)" "$1" "$2" >> "$RESULTS/report.txt"
    log "$1: $2"
}

# --- registry with the lab session ------------------------------------------
cat > "$AM_REGISTRY" <<EOF
{"sessions":{"$SESSION":{"name":"$SESSION","directory":"$WORKDIR","branch":"main","agent_type":"claude","task":"live lab","created_at":"$(date -u +%Y-%m-%dT%H:%M:%SZ)"}}}
EOF

# --- lab settings: tee every hook payload + run the real state hook ---------
cat > "$LAB/tee-payload.sh" <<'TEESH'
#!/bin/sh
{ printf '{"ts":"%s","payload":' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"; cat; printf '}\n'; } >> "$1"
TEESH
chmod +x "$LAB/tee-payload.sh"
STATE_HOOK="bash $PROJECT_DIR/lib/hooks/state-hook.sh"
hook_entry() { printf '{"matcher":"","hooks":[{"type":"command","command":"%s %s","timeout":5000},{"type":"command","command":"%s","timeout":5000}]}' "$LAB/tee-payload.sh" "$RESULTS/payloads.jsonl" "$STATE_HOOK"; }
cat > "$LAB/settings.json" <<EOF
{
  "permissions": {
    "allow": ["Bash(sleep:*)", "Bash(echo:*)", "Bash(sleep *)", "Bash(echo *)"]
  },
  "hooks": {
    "SessionStart":     [$(hook_entry)],
    "UserPromptSubmit": [$(hook_entry)],
    "PreToolUse":       [$(hook_entry)],
    "PostToolUse":      [$(hook_entry)],
    "Stop":             [$(hook_entry)],
    "SubagentStop":     [$(hook_entry)],
    "Notification":     [$(hook_entry)],
    "PermissionRequest":[$(hook_entry)],
    "SessionEnd":       [$(hook_entry)]
  }
}
EOF

# --- probes ------------------------------------------------------------------
pane_title()   { tmux -L "$SOCKET" display-message -p -t "$SESSION" '#{pane_title}' 2>/dev/null; }
pane_text()    { tmux -L "$SOCKET" capture-pane -p -t "$SESSION" 2>/dev/null; }
activity()     { tmux -L "$SOCKET" display-message -p -t "$SESSION" '#{session_activity}' 2>/dev/null; }
hook_state()   { head -1 "$AM_STATE_DIR/$SESSION" 2>/dev/null || echo '<none>'; }
hook_mtime()   { stat -f %m "$AM_STATE_DIR/$SESSION" 2>/dev/null || stat -c %Y "$AM_STATE_DIR/$SESSION" 2>/dev/null || echo 0; }

# status line = first substantive line above the input box (mirrors state.sh scan)
status_line() {
    pane_text | awk '
      { lines[NR]=$0 }
      END {
        bb=NR+1
        for (i=NR; i>=1; i--) if (lines[i] ~ /──────/) { bb=i; break }
        bt=bb
        for (i=bb-1;i>=1;i--) if (lines[i] ~ /──────/) { bt=i; break }
        for (i=bt-1; i>=1; i--) {
          l=lines[i]; gsub(/^[[:space:]]+|[[:space:]]+$/,"",l)
          if (l=="") continue
          print substr(l,1,100); exit
        }
      }'
}

# --- sampler (background): 1s cadence + snapshot on transitions -------------
CURRENT_SCENARIO_FILE="$LAB/current_scenario"
echo "boot" > "$CURRENT_SCENARIO_FILE"
SNAP_N=0
sampler() {
    local prev_key="" n=0
    while :; do
        local now scen title glyph hs ha act aa sl key
        now=$(date +%s)
        scen=$(cat "$CURRENT_SCENARIO_FILE" 2>/dev/null || echo '?')
        [[ "$scen" == "STOP" ]] && break
        title=$(pane_title); glyph="${title:0:1}"
        hs=$(hook_state)
        ha=$(( now - $(hook_mtime) )); [[ "$hs" == "<none>" ]] && ha=-1
        act=$(activity); aa=-1; [[ "$act" =~ ^[0-9]+$ ]] && aa=$(( now - act ))
        sl=$(status_line)
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$(date -u +%H:%M:%S)" "$scen" "$glyph" "$hs" "$ha" "$aa" "$sl" >> "$RESULTS/timeline.tsv"
        key="$glyph|$hs"
        if [[ "$key" != "$prev_key" ]]; then
            n=$((n+1))
            pane_text > "$RESULTS/snapshots/$(printf '%03d' "$n")-${scen}-${hs}-glyph-${glyph// /_}.txt"
            prev_key="$key"
        fi
        sleep 1
    done
}

# --- drivers ------------------------------------------------------------------
send_prompt() {  # paste literally, then Enter (same as am send)
    # Escape first: a prior scenario (ctrl-b panel, dialog) may have left UI
    # chrome open that would swallow the text. A second Enter after a beat
    # catches a submit that didn't take; on an empty box it is a no-op.
    tmux -L "$SOCKET" send-keys -t "$SESSION" Escape
    sleep 0.3
    tmux -L "$SOCKET" send-keys -t "$SESSION" -l "$1"
    sleep 0.4
    tmux -L "$SOCKET" send-keys -t "$SESSION" Enter
    sleep 1
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
observe() {  # scenario: record title+state+status now
    mark "$1" "observed title='$(pane_title)' hook=$(hook_state) status='$(status_line)'"
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
tmux -L "$SOCKET" send-keys -t "$SESSION" -l "export AM_SESSION_NAME=$SESSION AM_REGISTRY=$AM_REGISTRY AM_STATE_DIR=$AM_STATE_DIR AM_DIR=$AM_DIR AM_HOOK_DEBUG=1; exec claude --model $MODEL --settings $LAB/settings.json"
tmux -L "$SOCKET" send-keys -t "$SESSION" Enter

sampler & SAMPLER_PID=$!

# trust dialog / splash handling: wait for the input box, accept trust if asked
sleep 6
if pane_text | grep -qi 'trust'; then
    mark boot "trust dialog shown — accepting"
    press Enter; sleep 3
fi
wait_pane_contains '❯|>' 30 || { mark boot "FATAL: no input box"; exit 1; }
sleep 2

run_scenario() { echo "$1" > "$CURRENT_SCENARIO_FILE"; mark "$1" "=== begin ==="; }

# ── S1: fresh session, no hook has fired ────────────────────────────────────
if [[ " $SCENARIOS " == *" s1 "* ]]; then
    run_scenario s1-fresh
    sleep 3; observe s1-fresh
fi

# ── S2: plain running turn (allowlisted sleep 25), then waiting_input ───────
if [[ " $SCENARIOS " == *" s2 "* ]]; then
    run_scenario s2-running
    send_prompt "Use the Bash tool to run exactly: sleep 25 && echo lab-done-s2 . Do not run anything else. Then reply with exactly one word: DONE"
    wait_hook_state running 30 && mark s2-running "hook wrote running"
    sleep 10; observe s2-running    # mid-turn: spinner + title glyph
    wait_hook_state waiting_input 90 && mark s2-running "hook wrote waiting_input at turn end" \
        || mark s2-running "NO waiting_input within 90s (state=$(hook_state))"
    sleep 2; observe s2-running
fi

# ── S3: permission prompt (non-allowlisted command) ──────────────────────────
if [[ " $SCENARIOS " == *" s3 "* ]]; then
    run_scenario s3-permission
    send_prompt "Use the Bash tool to run exactly: touch $WORKDIR/lab-s3-marker . Then reply DONE"
    if wait_pane_contains 'Do you want|Allow|permission' 45; then
        mark s3-permission "permission dialog visible"
        sleep 8; observe s3-permission   # what do hooks/title say while dialog is up?
        press Enter                       # approve
        mark s3-permission "approved"
    else
        mark s3-permission "NO permission dialog appeared"
    fi
    wait_hook_state waiting_input 60 && observe s3-permission
fi

# ── S4: background shell -> Stop with background_tasks -> waiting_background ─
if [[ " $SCENARIOS " == *" s4 "* ]]; then
    run_scenario s4-background
    send_prompt "Use the Bash tool with run_in_background set to true to start exactly: sleep 45 && echo lab-done-s4 . Immediately after starting it, end your turn replying with exactly one word: STARTED. Do not wait for the background command."
    wait_hook_state running 30
    if wait_hook_state waiting_background 90; then
        mark s4-background "hook wrote waiting_background"
        sleep 3; observe s4-background
    else
        mark s4-background "NO waiting_background (state=$(hook_state))"
        observe s4-background
    fi
    # background completes -> Stop re-fires -> waiting_input self-heal
    if wait_hook_state waiting_input 150; then
        mark s4-background "self-healed to waiting_input after bg completion"
    else
        mark s4-background "NO self-heal (state=$(hook_state))"
    fi
    observe s4-background
fi

# ── S5: AskUserQuestion dialog mid-turn ──────────────────────────────────────
if [[ " $SCENARIOS " == *" s5 "* ]]; then
    run_scenario s5-question
    send_prompt "Use the AskUserQuestion tool to ask me: 'Which color?' with options Red and Blue. After I answer, reply with exactly the color I chose."
    if wait_pane_contains 'Which color' 45; then
        mark s5-question "question dialog visible"
        sleep 75; observe s5-question    # long enough for any idle_prompt notification
        press Enter                       # pick first option
        mark s5-question "answered"
        sleep 5; observe s5-question      # did state move back to running?
        wait_hook_state waiting_input 60 && mark s5-question "turn ended -> waiting_input" \
            || mark s5-question "stuck: state=$(hook_state)"
    else
        mark s5-question "NO question dialog"
    fi
    observe s5-question
fi

# ── S6: backgrounded turn (ctrl-b) — hooks go silent, state file left stale ─
if [[ " $SCENARIOS " == *" s6 "* ]]; then
    run_scenario s6-ctrl-b
    send_prompt "Use the Bash tool to run exactly: sleep 60 && echo lab-done-s6 . Then reply DONE"
    wait_hook_state running 30
    sleep 5
    press C-b                             # background the turn
    mark s6-ctrl-b "sent ctrl-b"
    sleep 8; observe s6-ctrl-b
    # true turn end ~60s later; watch what (if anything) hooks write
    sleep 75; observe s6-ctrl-b
    mark s6-ctrl-b "final: hook=$(hook_state) title='$(pane_title)'"
fi

# ── S7: long quiet tool (sleep 200 > 180s gate): does activity stay fresh? ──
if [[ " $SCENARIOS " == *" s7 "* ]]; then
    run_scenario s7-long-quiet
    send_prompt "Use the Bash tool to run exactly: sleep 200 && echo lab-done-s7 . Then reply DONE"
    wait_hook_state running 30
    for i in 1 2 3 4; do
        sleep 50
        mark s7-long-quiet "t+$((i*50))s hook=$(hook_state) hook_age=$(( $(date +%s) - $(hook_mtime) )) act_age=$(( $(date +%s) - $(activity) )) title='$(pane_title)'"
    done
    wait_hook_state waiting_input 60 && mark s7-long-quiet "turn ended -> waiting_input"
    observe s7-long-quiet
fi

echo "STOP" > "$CURRENT_SCENARIO_FILE"
wait "$SAMPLER_PID" 2>/dev/null || true
mark done "live lab complete; results in $RESULTS"
log "report: $RESULTS/report.txt"
