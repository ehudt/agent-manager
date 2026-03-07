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
| `running` | Agent is actively executing (tool use in progress, response streaming) |
| `waiting_input` | Agent has finished a turn and is waiting for a user message |
| `waiting_permission` | Agent is blocked on a permission prompt (y/n/a) |
| `waiting_custom` | Agent is blocked on a non-permission question (e.g. `/ask`) |
| `idle` | Agent process has exited cleanly (task complete or `exit` sent) |
| `dead` | Agent process exited with an error, or tmux session no longer exists |

### Detection Strategy: Two-Source Model

Detection uses **two complementary sources** depending on agent type. Each
source has different reliability characteristics; together they cover all cases.

```
Source A: Claude JSONL file (Claude sessions only)
  Reliable, structured, no false positives
  Slightly trailing (last write may be seconds old for active responses)

Source B: tmux pane content (all agent types)
  Real-time but requires pattern matching; permission prompts only visible here
  Required for Codex, Gemini, and as tie-breaker for Claude
```

**For Claude sessions:** use Source A as primary; Source B only for
`waiting_permission` and `waiting_custom` (permission prompts are not logged
to JSONL — they are rendered in the terminal by Claude Code's UI layer).

**For all other agents:** use Source B exclusively.

### Source A: Claude JSONL State Inference

Claude Code appends a JSONL entry to its session file for every message and
every streaming chunk as it is produced. The file lives at:

```
~/.claude/projects/<encoded-dir>/<session-uuid>.jsonl
```

The directory encoding replaces `/` and `.` with `-` (e.g. `/home/user/myapp`
→ `home-user-myapp`). The active session file is the most recently modified
`.jsonl` in the project directory.

**JSONL entry schema (observed):**

```json
{"type": "user"|"assistant"|"queue-operation",
 "message": {
   "role": "user"|"assistant",
   "content": [{"type": "text"|"tool_use"|"tool_result"|"thinking", ...}],
   "stop_reason": null | "end_turn" | "tool_use"
 },
 "timestamp": "2026-03-07T09:31:48.604Z"}
```

**State rules (evaluated against the last entry in the file):**

| Last entry | State |
|------------|-------|
| `type=assistant, stop_reason=end_turn` | `waiting_input` |
| `type=assistant, stop_reason=tool_use` | `running` (tool call dispatched) |
| `type=assistant, stop_reason=null, content=[tool_use]` | `running` (stream in progress) |
| `type=assistant, stop_reason=null, content=[text\|thinking]` | `running` (response streaming) |
| `type=user, content=[tool_result]` | `running` (tool result sent; Claude processing) |
| `type=queue-operation, operation=enqueue` | `running` (new user message queued) |

**Staleness check:** if the JSONL mtime is > 30s old and the last entry has
`stop_reason=null`, the file may have been written by a crashed process. Fall
back to Source B to resolve.

**Locating the Claude session JSONL:**

`am` records the working directory at launch time in the registry. The JSONL
path can be derived without the session UUID by finding the newest `.jsonl`
in the encoded project dir:

```bash
encoded=$(echo "$dir" | sed -E 's|^/||; s|[/.]|-|g')
project_dir="$HOME/.claude/projects/$encoded"
jsonl=$(ls -t "$project_dir"/*.jsonl 2>/dev/null | head -1)
```

The session UUID is not stored in the `am` registry today. The implementation
should either:
- (Option A) Store the Claude session UUID in the registry at launch time by
  watching for the first new `.jsonl` to appear after launch, or
- (Option B) Always use the newest `.jsonl` in the project dir (simpler;
  correct as long as only one `am` session per directory, which is the common
  case; warn if multiple `.jsonl` files are < 60s old).

Option B is recommended for the initial implementation.

### Source B: tmux Pane Content Pattern Matching

Used for all agents for `waiting_permission`/`waiting_custom`, and as the sole
source for Codex/Gemini.

**Dead check (first, fast):**
- `tmux has-session` fails → `dead`
- `pane_current_command` is a shell (`bash`, `zsh`, `sh`, `fish`) → process
  exited; classify as `idle` or `dead` based on exit status heuristics

**Content pattern matching (ordered by priority):**

Patterns matched against the last 40 lines of the agent pane, ANSI stripped.

```
waiting_permission patterns (highest priority — checked even for Claude):
  - /Do you want to (proceed|continue|make this edit|allow)\?/i
  - /\[y\/n\]/i
  - /\(y\/n\/a\/s\)/i
  - /Allow .+ to (read|write|execute|run)\?/i

waiting_custom patterns:
  - Claude's /ask block header
  - /\?\s*$/ on a non-permission line

waiting_input patterns (Codex/Gemini only; Claude uses JSONL):
  - Bare prompt character with no spinner on same line
  - Known agent "ready" prompts

running patterns (Codex/Gemini only):
  - Spinner characters: ⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏
  - "Working…", "Thinking…"
  - Tool use indicators
```

**Fallback:**
- No pattern matches + agent process alive → `running` (conservative)

### Implementation Notes

- All state logic lives in a new `lib/state.sh` module.
- `agent_get_state(session_name)` → echoes one of the state strings to stdout.
- `_state_claude_jsonl(dir)` → reads JSONL; echoes state or empty string.
- `_state_pane_patterns(session)` → reads pane; echoes state or empty string.
- `agent_get_state` calls `_state_claude_jsonl` first (if Claude); falls back
  to `_state_pane_patterns` if result is empty or staleness check fails.
- ANSI stripping uses the existing `lib/strip-ansi` script.
- Target latency: < 150ms per call (JSONL tail is fast; pane capture adds ~50ms).

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

## State Detection Reference

### Source A: Claude JSONL (Claude sessions only)

```
File: ~/.claude/projects/<encoded-dir>/<newest>.jsonl
Read: last line only

Entry → state mapping:
  type=assistant  stop_reason=end_turn          → waiting_input
  type=assistant  stop_reason=tool_use          → running
  type=assistant  stop_reason=null              → running (stream in progress)
  type=user       content=[tool_result]         → running
  type=queue-operation  operation=enqueue       → running

Staleness guard: if mtime > 30s AND last stop_reason=null → fall back to pane

Directory encoding:
  strip leading /  →  replace / and . with -
  e.g. /home/user/myapp  →  home-user-myapp
  Newest .jsonl in project dir = active session file
```

### Source B: tmux Pane Patterns (all agents; primary for Codex/Gemini)

```
Checked first even for Claude (permission prompts not in JSONL):

# Permission prompt → waiting_permission
/Do you want to (proceed|continue|make this edit|allow)\?/i
/\[y\/n\]/i
/\(y\/n\/a\/s\)/i
/Allow .+ (read|write|execute|run)/i

# Custom question → waiting_custom
Claude /ask block header
Line ending in ? that is not a permission match

# Input ready → waiting_input  (Codex/Gemini only; Claude uses JSONL)
Known "ready" prompt with no spinner on same line

# Running → running  (Codex/Gemini only)
Spinner chars:  ⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏
"Working…" / "Thinking…"
Tool indicators:  ⎿ Running|Reading|Writing|Executing
```

### Shell-level check (all agents, evaluated first)

```bash
tmux_pane_current_command "$session" "top"
# bash/zsh/sh/fish → agent process exited → classify idle vs dead
```

### Exit classification heuristic

When pane command is a shell, check the last visible line:
- Shell prompt (`$`, `%`, `#`, `>`) → `idle`
- Error indicator (`error:`, `fatal:`, non-zero exit display) → `dead`
- Otherwise → `idle` (conservative)

---

## New Module: `lib/state.sh`

```
lib/state.sh
  agent_get_state(session_name)            → state string
  agent_wait_state(session, states[], timeout_s) → matched state or "timeout"
  agent_classify_exit(session)             → "idle" | "dead"
  _state_from_jsonl(dir)                   → state string or ""  [Claude only]
  _state_from_pane(session)               → state string or ""
  _state_jsonl_path(dir)                  → path to newest .jsonl or ""
  _state_jsonl_stale(path)               → 0 (fresh) | 1 (stale, >30s)
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
