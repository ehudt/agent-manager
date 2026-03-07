# Spec: AI-Controllable Agent Manager

## Problem

`am` has the primitives to launch and communicate with sessions, but lacks the
observability and control surface needed for an AI orchestrator to reliably
drive them. The core gaps are:

1. **No session state** — there is no way to know if an agent is actively
   working, waiting for user input, blocked on a permission prompt, or idle.
2. **Blind sending** — `am send` injects text unconditionally; sending to a
   session that is still running overwrites a mid-execution context.
3. **No completion signal** — `am peek --follow` is a raw terminal stream;
   there is no structured event that says "the agent has finished this task."
4. **No machine-readable status** — `am list --json` gives metadata but no
   execution state; `am info` is human-formatted text.

## Goals

- An orchestrating agent can query the state of any session without screen
  scraping.
- An orchestrating agent can wait for a session to reach a specific state
  before acting.
- `am send` is safe: it either succeeds because the session is ready, or it
  fails clearly.
- State transitions are emitted as a structured event stream.
- All new surface area is CLI-first, JSON-serializable, and composable with
  pipes.

## Non-Goals

- A web API or HTTP server.
- Changing how agents run internally (no changes to Claude Code itself).
- Implementing task success/failure semantics — we detect readiness, not
  correctness.
- Replacing `am peek --follow` for humans watching sessions interactively.

---

## Feature 1: Session State Detection

### State Model

Each session is in exactly one of the following states at any moment:

| State | Meaning |
|-------|---------|
| `starting` | Session created; agent process not yet confirmed running |
| `running` | Agent is actively executing (spinner visible, tool use in progress) |
| `waiting_input` | Agent has finished a turn and is waiting for a user message |
| `waiting_permission` | Agent is blocked on a permission prompt (y/n/a) |
| `waiting_custom` | Agent is blocked on a non-permission question (e.g. `/ask`) |
| `idle` | Agent process has exited cleanly (task complete or `exit` sent) |
| `dead` | Agent process exited with an error, or tmux session no longer exists |

### Detection Mechanism

State is derived by inspecting live tmux pane content using
`tmux_capture_pane`. No persistent state is written — detection is stateless
and re-evaluable at any time.

**Dead check (first, fast):**
- `tmux has-session` fails → `dead`
- `pane_current_command` is a shell (`bash`, `zsh`, `sh`, `fish`) → process
  exited; classify as `idle` or `dead` based on exit status heuristics (see
  below)

**Content pattern matching (ordered by priority):**

Each pattern is matched against the last 40 lines of the agent pane, stripped
of ANSI codes.

```
waiting_permission patterns:
  - /Do you want to (proceed|continue|make this edit)\?/
  - /\[y\/n\]/i
  - /\(y\/n\/a\/s\)/i
  - /Allow .+ to (read|write|execute|run)\?/i

waiting_custom patterns (non-permission questions):
  - /\? .*:?\s*$/ (ends with question mark)
  - Claude's /ask block header

waiting_input patterns:
  - Claude's input box: "╭─" or "│" prompt frame at bottom of pane
  - Cursor visible on input line with no spinner

running patterns:
  - Spinner characters: ⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏ on any visible line
  - "Working…", "Thinking…", "Running tool", "Reading file", "Writing file"
  - Tool use block: "⎿ Running", "⎿ Reading"
```

**Fallback:**
- If no content pattern matches and the agent process is alive → `running`
  (conservative: assume work is in progress rather than falsely signaling ready)

### Implementation Notes

- Pattern matching lives in a new `lib/state.sh` module.
- `agent_get_state(session_name)` → echoes one of the state strings to stdout.
- Patterns are defined as arrays so they can be extended without changing
  detection logic.
- ANSI stripping uses the existing `lib/strip-ansi` script (already in repo).
- The function must be fast enough to call in a tight poll loop (target < 100ms
  per call; a single `tmux capture-pane` + sed pass satisfies this).

---

## Feature 2: `am status <session>` Command

### Description

Returns machine-readable status for a session. Intended for scripts and
orchestrators.

### Interface

```bash
am status <session>            # human-readable (one line)
am status --json <session>     # JSON object
am status --json               # JSON array for all sessions (extends am list --json)
```

### Human-readable output (one line per session)

```
am-abc123  waiting_input  /home/user/myproject  main  Fix auth bug  (3m ago)
```

### JSON output (single session)

```json
{
  "name": "am-abc123",
  "state": "waiting_input",
  "directory": "/home/user/myproject",
  "branch": "main",
  "agent_type": "claude",
  "task": "Fix auth bug",
  "activity": 1709812345,
  "created": 1709812100,
  "yolo": false,
  "sandbox": false,
  "worktree": null
}
```

### JSON output (all sessions) — extends `am list --json`

Same as the current `am list --json` format with `state` added to each object.
The existing `am list --json` should delegate to this implementation so the
format stays consistent.

### Exit codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Session not found |
| 2 | Session exists but state is `dead` |

---

## Feature 3: `am wait <session> [options]`

### Description

Blocks until a session reaches one of the specified states, then exits. Gives
orchestrators a clean synchronization point without polling loops in shell
scripts.

### Interface

```bash
am wait <session>
am wait --state waiting_input <session>
am wait --state idle,dead <session>
am wait --state waiting_input,waiting_permission <session>
am wait --timeout 300 <session>          # seconds; default 600
am wait --json <session>                 # print final status JSON on exit
```

**Default target states** (when `--state` is omitted):
`waiting_input,waiting_permission,waiting_custom,idle,dead`

i.e., "wait until the agent is no longer actively running."

### Behavior

- Polls `agent_get_state()` every 500ms.
- On match: prints the matched state to stdout (or JSON with `--json`), exits 0.
- On timeout: prints `timeout` to stdout, exits 3.
- If session disappears: exits 1.
- Respects `--timeout 0` as "poll once and return immediately" (useful for
  checking without blocking).

### Exit codes

| Code | Meaning |
|------|---------|
| 0 | Target state reached |
| 1 | Session not found |
| 3 | Timeout |

### Example orchestration pattern

```bash
session=$(printf 'Refactor auth module\n' | am new --detach --print-session ~/myproject)
am wait --state waiting_input "$session"
am send "$session" "Also add rate limiting"
am wait --state idle,dead "$session"
result=$(am status --json "$session")
```

---

## Feature 4: Safe `am send` with State Guard

### Description

Add a `--wait` flag to `am send` that first waits for the session to reach a
receivable state before injecting the prompt. Without `--wait`, the current
behavior is preserved (send unconditionally) so existing scripts are not
broken.

### Interface

```bash
am send <session> "prompt"                    # unchanged: send immediately
am send --wait <session> "prompt"             # wait for ready, then send
am send --wait --timeout 120 <session> "prompt"
```

**Receivable states** for `--wait`: `waiting_input`, `waiting_permission`,
`waiting_custom`, `idle`

If the session reaches `dead` while waiting, `am send --wait` exits 2 with an
error message to stderr.

### Why not make `--wait` the default?

Changing default behavior would break existing orchestration scripts that rely
on `am send` being instantaneous. The opt-in flag lets callers migrate at their
own pace. A future major version may flip the default.

---

## Feature 5: `am events <session>` — Structured Event Stream

### Description

Emits a newline-delimited JSON (JSONL) stream of state-change events for a
session. Each line is a complete JSON object. The stream ends when the session
reaches `idle` or `dead`.

### Interface

```bash
am events <session>
am events --follow <session>    # alias for --follow; don't stop at idle
am events --timeout 600 <session>
```

### Event format

```jsonl
{"event":"started","session":"am-abc123","state":"starting","ts":1709812100}
{"event":"state_change","session":"am-abc123","from":"starting","to":"running","ts":1709812105}
{"event":"state_change","session":"am-abc123","from":"running","to":"waiting_input","ts":1709812140}
{"event":"state_change","session":"am-abc123","from":"waiting_input","to":"running","ts":1709812145}
{"event":"state_change","session":"am-abc123","from":"running","to":"idle","ts":1709812200}
{"event":"ended","session":"am-abc123","state":"idle","ts":1709812200}
```

### Implementation

- Polls `agent_get_state()` every 500ms.
- Emits an event only when state changes (debounced: state must be stable for
  1 poll interval before emitting).
- `ts` is Unix epoch seconds.
- The stream is unbuffered (`printf` to stdout); callers can `| jq` or pipe to
  any consumer.
- `--follow` keeps watching even after `idle` (useful if agent will be
  restarted or sent new work).

### Use case: orchestrator waits for completion

```bash
am events am-abc123 | while IFS= read -r line; do
  state=$(printf '%s' "$line" | jq -r '.state // empty')
  event=$(printf '%s' "$line" | jq -r '.event // empty')
  if [[ "$event" == "ended" ]]; then
    printf 'Session finished in state: %s\n' "$state"
    break
  fi
done
```

---

## Feature 6: `am peek --json` — Structured Snapshot

### Description

Add `--json` to `am peek` to return a structured object instead of raw
terminal output. Useful when an orchestrator wants both state and recent output
in one call.

### Interface

```bash
am peek --json <session>
am peek --json --lines 100 <session>
```

### Output

```json
{
  "name": "am-abc123",
  "state": "waiting_input",
  "pane": "agent",
  "lines": [
    "I've refactored the auth module. Here's what I changed:",
    "...",
    "Would you like me to also add rate limiting?"
  ],
  "ts": 1709812140
}
```

- `lines`: last N lines of pane content, ANSI stripped.
- Default `--lines`: 50.
- `state` is computed from the same pane content that was captured, so it is
  consistent with the returned lines.

---

## Feature 7: Extend `am list --json` with State

### Description

The existing `am list --json` output should include a `state` field for each
session. This is a backward-compatible addition (new field in existing objects).

### Updated JSON shape

```json
[
  {
    "name": "am-abc123",
    "state": "waiting_input",
    "directory": "/home/user/myproject",
    "branch": "main",
    "agent_type": "claude",
    "task": "Fix auth bug",
    "activity": 1709812345,
    "created": 1709812100
  }
]
```

State is fetched for all sessions in one pass to avoid per-session overhead
(batch `tmux capture-pane` calls).

---

## Feature 8: `am interrupt <session>`

### Description

Sends an interrupt signal to the active agent pane. Useful when an agent is
stuck, running a long tool, or needs to be stopped before sending new
instructions.

### Interface

```bash
am interrupt <session>
am interrupt --confirm <session>    # prompt before sending (safety guard)
```

### Behavior

- Sends `Ctrl-C` (`q` key in some Claude UI states, raw `C-c` otherwise) to
  the top (agent) pane.
- Does **not** kill the tmux session; the agent process remains running but its
  current operation is interrupted.
- After interrupt, the session typically transitions to `waiting_input`; callers
  should `am wait --state waiting_input` after interrupting.
- If the session is already `idle` or `dead`, prints a warning to stderr and
  exits 1.

---

## State Detection Patterns (Reference)

All patterns matched against ANSI-stripped pane content (last 40 lines).

### Claude Code specific

```
# Spinner → running
[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]

# Tool use → running
^⎿\s+(Running|Reading|Writing|Executing|Searching)

# Input prompt frame → waiting_input
^╭─
^│\s*$        (empty input box line)
^\s*>\s*$     (bare prompt)

# Permission prompt → waiting_permission
Do you want to (proceed|continue|make this edit|allow)\?
\[y/n\]
\(y/n/a/s\)
Allow .+ \(read|write|execute|run\)

# Question prompt → waiting_custom
\?\s*$        (line ending in question mark)
```

### Shell-level check (all agent types)

```bash
tmux_pane_current_command "$session" "top"
# If result is bash/zsh/sh/fish → agent exited; classify idle vs dead
```

### Exit classification heuristic

When pane command is a shell, check the last visible line:
- Matches shell prompt (`$`, `%`, `#`, `>`) → `idle`
- Matches error indicator (non-zero exit, `error:`, `fatal:`) → `dead`
- Otherwise → `idle` (conservative)

---

## New Module: `lib/state.sh`

```
lib/state.sh
  agent_get_state(session_name)       → state string
  agent_wait_state(session, states[], timeout_s) → matched state or "timeout"
  agent_classify_exit(pane_content)   → "idle" | "dead"
  _state_capture_pane(session)        → stripped pane lines
  _state_match_patterns(lines)        → state string or ""
```

All functions follow existing conventions:
- Return values via stdout
- Logging/errors to stderr
- No global state (re-entrant safe for parallel use)
- Source-able from test scripts

---

## Changes to Existing Commands

### `am send`
- Add `--wait` and `--timeout` flags (Feature 4)
- No behavior change without `--wait`

### `am peek`
- Add `--json` and `--lines` flags (Feature 6)
- No behavior change without `--json`

### `am list --json`
- Add `state` field to each session object (Feature 7)
- Additive change; existing consumers unaffected by extra field

### `am status`
- Current `am status` (alias for summary view) is renamed to `am summary` or
  kept as-is with a new `--json` flag and the single-session form added.
  See CLI design note below.

### `am` help / usage text
- Add `wait`, `events`, `interrupt` to help output
- Add state values to `--json` documentation

---

## CLI Design Notes

### Naming consistency

| Command | Purpose |
|---------|---------|
| `am status [session]` | Show state; human or `--json`. No session = all. |
| `am wait <session>` | Block until state matches |
| `am events <session>` | Stream state-change events as JSONL |
| `am interrupt <session>` | Send Ctrl-C to agent pane |
| `am peek --json <session>` | Snapshot with state |

`am status` without a session argument replaces the existing `am status`
(summary) behavior. The summary view gains a `state` column.

### Backward compatibility

- `am list --json`: new `state` field is additive.
- `am send`: unchanged without `--wait`.
- `am peek`: unchanged without `--json`.
- `am status`: currently shows a human summary of all sessions; this behavior
  is preserved; `--json` and single-session targeting are new.

---

## Testing Requirements

Each new feature requires tests in `tests/test_all.sh` (following existing
test patterns: source libs, create mock state, assert output).

| Test | What to verify |
|------|----------------|
| `agent_get_state` with mock pane output | Pattern matching correctness for all states |
| `am status --json` | JSON is valid; `state` field present |
| `am wait` timeout | Exits with code 3 after timeout |
| `am wait` success | Exits 0 when state matches |
| `am send --wait` | Waits before sending; error on `dead` session |
| `am events` | Emits valid JSONL; ends on `idle` |
| `am peek --json` | Valid JSON; `lines` array present |
| `am list --json` | All objects include `state` field |
| `am interrupt` | Sends keys to pane; warns on non-running session |

Pattern tests should be pure unit tests (no tmux required): pass canned
multi-line strings to `_state_match_patterns` and assert the returned state.

---

## Implementation Order

1. **`lib/state.sh`** — foundation; all features depend on it
2. **`am status --json`** — validates the detection module end-to-end
3. **`am wait`** — most useful for orchestrators; unlocks safe sequencing
4. **`am send --wait`** — wraps `am wait`; low additional complexity
5. **`am list --json` state field** — small addition once state module exists
6. **`am peek --json`** — snapshot + state in one call
7. **`am events`** — highest complexity; built on state poll loop
8. **`am interrupt`** — lowest complexity; single tmux send-keys call
9. **Tests** — written alongside each feature, not deferred

---

## Success Criteria

An AI orchestrator can:

- [ ] Launch a session and reliably detect when it is first ready for input
      (`am wait --state waiting_input`)
- [ ] Send a follow-up prompt only when the agent is not mid-execution
      (`am send --wait`)
- [ ] Detect and handle permission prompts without human intervention
      (`am status --json` + pattern match + `am send`)
- [ ] Know when a session's task is complete (`am wait --state idle,dead`)
- [ ] Get structured state for all running sessions in one call
      (`am list --json` with `state` field)
- [ ] Subscribe to a session's state transitions without polling
      (`am events`)
- [ ] Interrupt a stuck or misdirected agent (`am interrupt`)
- [ ] Get a structured snapshot of what the agent last said
      (`am peek --json`)
