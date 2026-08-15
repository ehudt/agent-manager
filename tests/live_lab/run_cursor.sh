#!/usr/bin/env bash
# Drive a REAL Cursor Agent CLI through its observable lifecycle and record
# hook payloads, pane titles, state transitions, and snapshots.
#
# NOT part of test_all.sh: this spends real Cursor tokens and may show an
# approval/question dialog. Run after Cursor CLI or state integration updates.
#
# Usage:
#   ./tests/live_lab/run_cursor.sh [results_dir]
#   LAB_SCENARIOS="c1 c2" ./tests/live_lab/run_cursor.sh
#   LAB_CURSOR_ARGS="--model auto" ./tests/live_lab/run_cursor.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
RESULTS="${1:-$SCRIPT_DIR/results/cursor-$(date +%Y%m%d-%H%M%S)}"
LAB=$(mktemp -d -t am-live-lab-cursor.XXXXXX)
SOCKET="am-live-lab-cursor-$$"
SESSION="lab-cursor-1"
WORKDIR="$LAB/workdir"
SCENARIOS="${LAB_SCENARIOS:-c1 c2 c3 c4 c5 c6}"
CURSOR_ARGS="${LAB_CURSOR_ARGS:-}"

mkdir -p "$RESULTS/snapshots" "$WORKDIR/.cursor" "$LAB/state" "$LAB/am"
export AM_STATE_DIR="$LAB/state"
export AM_REGISTRY="$LAB/am/sessions.json"
export AM_DIR="$LAB/am"
export AM_TMUX_SOCKET="$SOCKET"

log() { printf '\033[0;36m[live-lab-cursor]\033[0m %s\n' "$*" >&2; }
mark() {
    printf '%s\tMARK\t%s\t%s\n' "$(date -u +%H:%M:%S)" "$1" "$2" >> "$RESULTS/timeline.tsv"
    printf '[%s] %s: %s\n' "$(date -u +%H:%M:%S)" "$1" "$2" >> "$RESULTS/report.txt"
    log "$1: $2"
}

cat > "$AM_REGISTRY" <<EOF
{"sessions":{"$SESSION":{"name":"$SESSION","directory":"$WORKDIR","branch":"","agent_type":"cursor","task":"live lab","created_at":"$(date -u +%Y-%m-%dT%H:%M:%SZ)"}}}
EOF

# Record the exact Cursor payload before forwarding it to the production hook.
cat > "$LAB/hook-wrapper.sh" <<EOF
#!/usr/bin/env bash
payload=\$(cat)
printf '%s\n' "\$payload" >> "$RESULTS/payloads.jsonl"
printf '%s' "\$payload" | bash "$PROJECT_DIR/lib/hooks/state-hook.sh"
EOF
chmod +x "$LAB/hook-wrapper.sh"

# Force one shell command to request approval so the title signal can be
# observed even when the user's normal approval policy is permissive.
cat > "$LAB/permission-hook.sh" <<'EOF'
#!/usr/bin/env bash
payload=$(cat)
command=$(printf '%s' "$payload" | jq -r '.command // empty')
if [[ "$command" == *cursor-live-lab-permission* ]]; then
    printf '{"permission":"ask"}\n'
else
    printf '{"permission":"allow"}\n'
fi
EOF
chmod +x "$LAB/permission-hook.sh"

hook_cmd="bash $LAB/hook-wrapper.sh # am-state-hook"
jq -n --arg cmd "$hook_cmd" --arg permission "$LAB/permission-hook.sh" '{
  version: 1,
  hooks: {
    sessionStart: [{command: $cmd, timeout: 5}],
    beforeSubmitPrompt: [{command: $cmd, timeout: 5}],
    preToolUse: [{command: $cmd, timeout: 5}],
    postToolUse: [{command: $cmd, timeout: 5}],
    postToolUseFailure: [{command: $cmd, timeout: 5}],
    afterAgentResponse: [{command: $cmd, timeout: 5}],
    afterAgentThought: [{command: $cmd, timeout: 5}],
    stop: [{command: $cmd, timeout: 5}],
    beforeShellExecution: [{command: $permission, timeout: 5}]
  }
}' > "$WORKDIR/.cursor/hooks.json"

source "$PROJECT_DIR/lib/utils.sh"
source "$PROJECT_DIR/lib/config.sh"
am_config_init >/dev/null 2>&1 || true
source "$PROJECT_DIR/lib/tmux.sh"
source "$PROJECT_DIR/lib/registry.sh"
source "$PROJECT_DIR/lib/state.sh"

pane_title() { tmux -L "$SOCKET" display-message -p -t "$SESSION" '#{pane_title}' 2>/dev/null; }
pane_text() { tmux -L "$SOCKET" capture-pane -p -t "$SESSION" 2>/dev/null; }
activity() { tmux -L "$SOCKET" display-message -p -t "$SESSION" '#{session_activity}' 2>/dev/null; }
hook_state() { [[ -f "$AM_STATE_DIR/$SESSION" ]] && { IFS= read -r _s < "$AM_STATE_DIR/$SESSION"; printf '%s\n' "$_s"; } || echo '<none>'; }
sid() { [[ -f "$AM_STATE_DIR/$SESSION.sid" ]] && { IFS= read -r _s < "$AM_STATE_DIR/$SESSION.sid"; printf '%s\n' "$_s"; } || true; }
transcript() { [[ -f "$AM_STATE_DIR/$SESSION.transcript" ]] && { IFS= read -r _s < "$AM_STATE_DIR/$SESSION.transcript"; printf '%s\n' "$_s"; } || true; }
resolved_state() { AM_TMUX_SOCKET="$SOCKET" agent_get_state "$SESSION" 2>/dev/null || echo unknown; }

CURRENT_SCENARIO_FILE="$LAB/current_scenario"
echo boot > "$CURRENT_SCENARIO_FILE"
sampler() {
    local previous="" n=0
    while :; do
        local scenario title state resolved key
        [[ -f "$CURRENT_SCENARIO_FILE" ]] || break
        scenario=$(<"$CURRENT_SCENARIO_FILE")
        [[ "$scenario" == STOP ]] && break
        title=$(pane_title)
        state=$(hook_state)
        resolved=$(resolved_state)
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$(date -u +%H:%M:%S)" "$scenario" "$title" "$state" "$resolved" "$(activity)" \
            >> "$RESULTS/timeline.tsv"
        key="$title|$state|$resolved"
        if [[ "$key" != "$previous" ]]; then
            n=$((n + 1))
            pane_text > "$RESULTS/snapshots/$(printf '%03d' "$n")-${scenario}-${state}-${resolved}.txt"
            previous="$key"
        fi
        sleep 1
    done
}

send_prompt() {
    tmux -L "$SOCKET" send-keys -t "$SESSION" -l "$1"
    sleep 0.5
    tmux -L "$SOCKET" send-keys -t "$SESSION" Enter
}
press() { tmux -L "$SOCKET" send-keys -t "$SESSION" "$@"; }
wait_state() {
    local wanted="$1" timeout="${2:-90}" start
    start=$(date +%s)
    while (( $(date +%s) - start < timeout )); do
        [[ "$(hook_state)" == "$wanted" ]] && return 0
        sleep 0.5
    done
    return 1
}
wait_pane() {
    local pattern="$1" timeout="${2:-90}" start
    start=$(date +%s)
    while (( $(date +%s) - start < timeout )); do
        pane_text | grep -qE "$pattern" && return 0
        sleep 0.5
    done
    return 1
}
observe() {
    mark "$1" "title='$(pane_title)' hook=$(hook_state) resolved=$(resolved_state) sid=$(sid) transcript=$(transcript)"
}
run_scenario() { echo "$1" > "$CURRENT_SCENARIO_FILE"; mark "$1" "=== begin ==="; }
cleanup() {
    echo STOP > "$CURRENT_SCENARIO_FILE" 2>/dev/null || true
    tmux -L "$SOCKET" kill-server 2>/dev/null || true
    [[ -n "${SAMPLER_PID:-}" ]] && wait "$SAMPLER_PID" 2>/dev/null || true
    rm -rf "$LAB"
}
trap cleanup EXIT

log "results -> $RESULTS"
tmux -L "$SOCKET" new-session -d -s "$SESSION" -c "$WORKDIR" -x 200 -y 50
tmux -L "$SOCKET" set-option -t "$SESSION" allow-rename on
tmux -L "$SOCKET" send-keys -t "$SESSION" -l \
    "export AM_SESSION_NAME='$SESSION' AM_REGISTRY='$AM_REGISTRY' AM_STATE_DIR='$AM_STATE_DIR' AM_DIR='$AM_DIR' AM_TMUX_SOCKET='$SOCKET'; agent --trust $CURSOR_ARGS"
tmux -L "$SOCKET" send-keys -t "$SESSION" Enter
sampler &
SAMPLER_PID=$!

if ! wait_state waiting_input 60; then
    mark boot "FATAL: Cursor did not reach waiting_input (hook=$(hook_state))"
    exit 1
fi

if [[ " $SCENARIOS " == *" c1 "* ]]; then
    run_scenario c1-fresh
    observe c1-fresh
    [[ -n "$(sid)" ]] \
        && mark c1-fresh "PASS: conversation sidecar present (transcript begins with first turn)" \
        || mark c1-fresh "FAIL: missing conversation sidecar"
fi

if [[ " $SCENARIOS " == *" c2 "* ]]; then
    run_scenario c2-roundtrip
    send_prompt "Reply with exactly: cursor-pong"
    wait_state running 15 && observe c2-running || mark c2-roundtrip "FAIL: no running hook"
    if wait_state waiting_input 120; then
        observe c2-waiting
        [[ -n "$(transcript)" ]] \
            && mark c2-waiting "PASS: exact transcript sidecar present" \
            || mark c2-waiting "FAIL: missing transcript sidecar after turn"
    else
        mark c2-roundtrip "FAIL: no stop hook"
    fi
fi

if [[ " $SCENARIOS " == *" c3 "* ]]; then
    run_scenario c3-permission
    send_prompt "Run this exact shell command: printf cursor-live-lab-permission"
    if wait_state running 20; then
        sleep 8
        observe c3-permission
        press a
        wait_state waiting_input 60 || { press C-c; wait_state waiting_input 20 || true; }
    else
        mark c3-permission "WARN: permission turn did not start"
    fi
fi

if [[ " $SCENARIOS " == *" c4 "* ]]; then
    wait_state waiting_input 20 || { press C-c; wait_state waiting_input 20 || true; }
    run_scenario c4-question
    send_prompt "Use the AskQuestion tool to ask me to choose red or blue. Do not choose for me."
    if wait_state running 20; then
        sleep 10
        observe c4-question
        press Enter
        wait_state waiting_input 60 || { press C-c; wait_state waiting_input 20 || true; }
    else
        mark c4-question "WARN: question turn did not start"
    fi
fi

if [[ " $SCENARIOS " == *" c5 "* ]]; then
    run_scenario c5-subagent
    send_prompt "Launch one general-purpose subagent that replies with exactly subagent-ok, then report its result."
    wait_state running 20 && observe c5-subagent-running || true
    wait_state waiting_input 180 && observe c5-subagent-waiting \
        || mark c5-subagent "WARN: subagent turn did not settle"
fi

if [[ " $SCENARIOS " == *" c6 "* ]]; then
    run_scenario c6-resume
    resume_sid=$(sid)
    press C-c
    press C-d
    sleep 3
    if [[ -n "$resume_sid" ]]; then
        tmux -L "$SOCKET" send-keys -t "$SESSION" -l \
            "export AM_SESSION_NAME='$SESSION'; agent --trust --resume '$resume_sid' $CURSOR_ARGS"
        tmux -L "$SOCKET" send-keys -t "$SESSION" Enter
        wait_state waiting_input 60 && observe c6-resume \
            || mark c6-resume "WARN: resumed session did not reach waiting_input"
    fi
fi

echo STOP > "$CURRENT_SCENARIO_FILE"
wait "$SAMPLER_PID" 2>/dev/null || true
mark done "Cursor live lab complete; results in $RESULTS"
