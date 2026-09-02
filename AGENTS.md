# AI Navigation Guide

Architecture reference for AI agents working with this codebase.

## Commands

- Run tests: `./tests/test_all.sh`
- Run tests (summary): `./tests/test_all.sh --summary` — suppresses PASS lines, shows only failures with details and a counts summary
- Run perf benchmark: `./tests/perf_test.sh` — standalone latency check for `am list-internal`; not part of `test_all.sh` and should not leave resources behind
- Run live state-detection labs: `tests/live_lab/run.sh` (Claude), `run_cursor.sh` (Cursor), and `run_pi.sh` (pi). They record hook payloads, pane titles, and transitions; they are opt-in and spend tokens.
- Typecheck/lint: `bash -n lib/*.sh am` (syntax check only — no linter)

## Versioning

SemVer (`MAJOR.MINOR.PATCH`). Single source of truth: `AM_VERSION` in `am` (help text and `am --version` both read it — never hardcode a version string elsewhere).

When to bump (pre-1.0, so `MAJOR` stays `0`):

- **PATCH** (`0.2.0` → `0.2.1`) — bug fixes, doc/test/skill tweaks, internal refactors with no user-facing behavior change.
- **MINOR** (`0.2.0` → `0.3.0`) — new user-facing capability: a new `am` command/flag, a new pane/UI mode, restore/skill features, or a behavior change a user would notice.
- **MAJOR** — reserved; bump to `1.0.0` only on the first stability commitment.

How to bump: edit `AM_VERSION` in `am` in the same commit as the change that earns it; mention the bump in the commit body. Accumulate several small changes under one bump rather than bumping per-commit — bump when cutting a coherent batch.

## Code Style

- Libs in `lib/` are sourced, not executed — no shebang, no `set -euo pipefail` (the entry point `am` sets it)
- Functions prefixed by module name: `registry_add`, `tmux_create_session`, `agent_launch`
- Return values via stdout; all logging/UI output to stderr (`>&2`)
- Use `sed -E` (not `sed -r`) for portable regex (macOS + Linux)

## Gotchas

- Registry writes must go through `registry_add/update/remove` (or Go's `lockRegistry`-wrapped paths) — a bare jq-rewrite of `sessions.json` bypasses the write lock and reintroduces lost updates. Don't spawn background jobs while `_registry_lock` is held (children inherit the lock fd and keep the lock alive until they exit)
- Sourced libs derive their own dir as `_<MODULE>_LIB_DIR` from `AM_LIB_DIR` (exported by the `am` entry point); standalone scripts like `lib/status-bar` set their own `SCRIPT_DIR`
- Tests source libs directly — test helpers like `registry_exists` live in `test_helpers.sh`, not in production code
- The shell panel is optional and collapsible: sessions launch agent-only (override: `--shell` / `am config set shell true`), and hiding the panel parks its pane in the hidden `_amshell` window. Session-keyed pane enumeration (e.g. status-bar's bulk `list-panes -a`) must skip that window or the parked shell's pid clobbers the agent pid and flips running sessions to idle. Non-bulk `.{top}` targets resolve against the session's *current* window — briefly wrong only if a user manually navigates into `_amshell` (self-heals on toggle)
- Pane environment (`AM_SESSION_NAME`, `AM_AGENT_TYPE`, `AM_IDENTITY_DIR`, `AM_LOG_DIR`) is seeded at pane creation via tmux `-e` (`agent_pane_env` → `tmux_create_session` env args / `split-window -e`) plus the session environment. Never `send-keys` an `export` into a pane: even a space-prefixed one lingers as zsh's most recent history entry, and the vars must exist before the agent command runs. Requires tmux ≥ 3.2 (`display-popup` already did)
- `am new -W [branch]` never takes a directory: `agent_workspace_allocate` runs the user's `workspace_cmd` (bash -c, `AM_BRANCH` exported, may be empty) and uses its stdout. The form emits `--workspace[=branch]` in its flags field and `cmd_new` strips it before the flags reach `agent_launch`

## Key Files

| File | Purpose |
|------|---------|
| `am` | Main entry point. Handles CLI args, routes to commands. |
| `lib/utils.sh` | Shared: colors, logging, time formatting, paths, agent JSONL extraction |
| `lib/registry.sh` | JSON storage for session metadata, sessions log (restore), auto-titling |
| `lib/recovery.sh` | Durable desired-session store, boot/machine identity, reboot preflight, and progressive recovery worker |
| `lib/tmux.sh` | tmux wrappers: create/kill/attach sessions |
| `lib/agents.sh` | Agent lifecycle: launch, display formatting, kill |
| `lib/form.sh` | tput-based new session form (two-mode: Navigate/Edit) |
| `cmd/am-browse/main.go` | Compiled Go TUI session browser (bubbletea); primary UI for `am` |
| `cmd/am-list-internal/main.go` | Compiled Go binary for fast session list generation |
| `internal/sessions/` | Shared Go package: tmux queries, registry parsing, formatting, title refresh (`titles.go`) |
| `lib/fzf.sh` | Browser launcher (`fzf_main`), directory picker, restore picker, `am list` helpers |
| `lib/preview` | Standalone preview script (extracts first user message, captures pane) |
| `lib/status-bar` | Standalone script: renders whole bottom bar as a clickable session-tab strip (idx, state glyph, dir/branch, task, age). Tab age is time-in-state (state-file mtime) for waiting_* and running sessions, tmux activity otherwise. Also writes `@am_sidebar` (compact pane-border variant) and `@am_attention` (status-right counter). |
| `lib/strip-ansi` | Standalone script: strips ANSI escape codes from pane output |
| `lib/dir-preview` | Standalone preview script for directory picker fzf panel |
| `lib/config.sh` | User config: defaults, feature flags, persistent settings |
| `lib/state.sh` | Session state detection: title glyph + hook file + process tree, wait/poll |
| `lib/hooks/am-state.ts` | Pi extension: lifecycle events → am state files (session_start/agent_settled → ready, agent_start → running) |
| `tests/live_lab/run.sh`, `run_cursor.sh`, `run_pi.sh` | Empirical state labs for real agent sessions |
| `skills/agent-manager-dispatch/SKILL.md` | Claude/Cursor skill: teaches agents to use am for multi-session dispatch/orchestration |
| `skills/am-peek/SKILL.md` | Claude Code skill: teaches agents to read another session's full shell scrollback via `am peek --pane shell --history` |
| `bin/toggle-shell` | tmux helper (prefix+\`): toggle the collapsible shell panel — create on first use via `am shell`, then hide/show by parking the pane in the hidden `_amshell` window |
| `bin/switch-last` | tmux helper: switch to most recently active am-* session |
| `bin/switch-cycle` | tmux helper: cycle next/prev in canonical sidebar order |
| `bin/switch-index` | tmux helper: jump to Nth slot in canonical sidebar order |
| `bin/kill-and-switch` | tmux helper: kill a session and switch to next best |
| `docs/` | Architecture docs, backlog, perf notes |

## Data Flow

```
am → fzf_main() → am-browse (Go TUI) → stdout protocol → tmux_attach()
am new ~/project → agent_launch() → tmux_create_session(name, dir, VAR=VAL...) → registry_add() → tmux_send_keys()
am new -W branch → agent_workspace_allocate(branch) → $workspace_cmd (AM_BRANCH=branch) → agent_launch(dir, ...)
am id → current_session() → $AM_SESSION_NAME, else attached session on the am tmux server
am list-internal → am-list-internal (Go binary) → stdout
Ctrl-N in browser → am_new_session_form() → _form_run()
prefix+` / am shell → bin/toggle-shell → agent_shell_pane_toggle() → agent_shell_pane_add() (first use) | tmux_shell_pane_hide/show() (park in / rejoin from hidden _amshell window; pane state and shell.log streaming survive)
agent_kill() → sessions_log_snapshot() + sessions_log_update(closed_at) → tmux_kill_session() → registry_remove()
am restore → fzf_restore_picker() → sessions_log_restorable() → agent_launch(dir, agent_type, agent_resume_args...) → tmux_attach() (claude/cursor → --resume, pi → --session, codex → resume)
bare `am` → recovery_start_for_browser() → migrate live intent → prior-boot candidates queued → am-browse shows restoring rows while recovery_run() recreates sessions detached
```

## State Detection (hooks + title paint)

Claude sessions are resolved from documented-behavior signals — no
pane-content scraping:

1. **Hook state file** (primary). Claude Code lifecycle hooks (`Stop`,
   `Notification`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`,
   `PermissionRequest`) call `lib/hooks/state-hook.sh`, which maps the event
   to an am state and writes it to `/tmp/am-state/<session_name>`. The state
   is read **ungated**: `Stop`/`UserPromptSubmit` are reliable turn-boundary
   events (like pi's in-process extension and Cursor's stop hooks), a dead
   process drops the pane to a shell (caught by the shell-pane check), and a
   ctrl-b backgrounded turn fires its own `Stop` on Claude Code ≥2.1.237
   (live lab s6) — so `running` no longer goes silently stale. No staleness
   gate: hooks skip same-state rewrites (mtime pins turn start) and tmux
   `session_activity` is empirically unreliable (live lab s7 on 2.1.237:
   activity age grew unbounded while the pane visibly repainted), so any
   mtime/activity gate flaps long live turns to `unknown`.
2. **Pane title paint** (fresh-session detection + legacy busy glyph).
   Claude Code ≤2.1.233 animated a busy glyph in the terminal title — a
   braille spinner frame (`⠂` …, U+2800–U+28FF) up to 2.1.221, a
   circle-phase glyph (`◐◓◑◒`, U+25D0–U+25D3) from 2.1.232 — and painted
   `✳` when it needed the user. **Since 2.1.234 the title is written only
   when its text changes** (the 960ms spinner animation was removed to stop
   tab-bar jitter — see that version's changelog): the busy glyph is gone
   and `✳ <task>` stays painted from boot through running turns (verified on
   2.1.237, live lab: the title never left `✳ …` across all seven
   scenarios). So `✳` now proves only that Claude is alive and has painted;
   the one case it still decides is a **fresh session idle at its first
   prompt** (`✳` + no hook file → `ready`, since the very first
   `UserPromptSubmit` would have created the file). A busy glyph, where an
   old version still emits one, remains authoritative for `running`.

State detection priority: **shell pane check → busy glyph (legacy) / fresh
`✳`+no-hook-file → ungated hook state → unknown**.

Glyph × hook decision table (`_state_resolve`, Claude sessions):

| Glyph | Hook state | Result |
|---|---|---|
| busy (braille / circle-phase; ≤2.1.233 only) | `waiting_user` | pass through — a pending dialog needs the user; answering it fires `PreToolUse` which moves the file forward |
| busy | anything else | `running` — trust the legacy indicator |
| `✳` | missing | `ready` — fresh session idle at its first prompt |
| `✳` | any state | hook state, ungated — `✳` carries no busy/waiting information on ≥2.1.234; resurrecting the old attention rows flips every running turn to `ready` within one status-bar tick |
| none (hostname / booting / titles unavailable) | any state | hook state, ungated; `unknown` when no file |
| — (non-Claude, non-pi, non-Cursor agents) | — | hook state with the 180s running-staleness gate, else `unknown` |

Known display wart (accepted): a wrap-up turn that starts when background
work completes fires no `UserPromptSubmit`, and its tool hooks are blocked
by the unconditional `background` race guard, so the session shows
`background` until the wrap-up turn's own `Stop`. Self-healing and
not user-blocking (it never fakes "waiting for you").

Hooks are installed via `am install` into `~/.claude/settings.json`. State
files are cleaned up on session kill and during registry GC.

The state file's mtime doubles as the state-entry timestamp: the hook only
writes on state *transitions*, skipping same-state rewrites (repeated
`idle_prompt` notifications, Stop re-fires while background work drains,
per-tool `running` rewrites), so the mtime pins the moment the state was
entered. The status bar renders tab ages from it — "waiting for you since"
for waiting_* tabs, "running for" on running tabs.

| Hook Event | Matcher | am State |
|---|---|---|
| `Stop` | — | `ready`, or `background` when the payload's `background_tasks` lists running work |
| `Notification` | `idle_prompt` | `ready` (same `background_tasks` refinement; without the field it cannot downgrade `background` unless a prior Stop snapshot's leftover shells are all unowned) |
| `Notification` | `permission_prompt` | `waiting_user` |
| `Notification` | `elicitation_dialog` | `waiting_user` |
| `UserPromptSubmit` | — | `running` |
| `PostToolUse` | — | `running` |

States not covered by hooks (`starting`, `idle`, `dead`) use existing
process/tmux checks which are already reliable.

Hook writes are gated by **agent family**: the event name proves the source
(CamelCase → Claude Code / Codex; camelCase → Cursor; pi never calls the
script — its states come from the in-process extension), and the resolved
session's registered `agent_type` must belong to that family. A positively
identified session (`AM_SESSION_NAME` / `TMUX_PANE`) of the wrong family
makes the hook exit — no fallthrough to cwd matching — and the cwd fallback
filters candidates by family. Without the gate, an unmanaged agent process
(e.g. a Cursor conversation run outside am) whose cwd hosts another agent's
am session clobbers that session's state and `.sid`/`.transcript` sidecars
(observed live: a stray Cursor run flipped a mid-turn pi session to `ready`).
Cursor nested agents are a same-family exception: they inherit
`AM_SESSION_NAME` and do not reliably set `is_background_agent`, so reboot
identity is pinned to the physical session's first complete
conversation-id/transcript pair.

`background` (Claude's main turn ended but a background agent/task/
workflow/shell is still running) is written directly by the hook: the `Stop`
payload carries a `background_tasks` array (documented; Claude Code ≥2.1) —
one entry per still-running background item (`{id, type (subagent|shell),
status, description, …}`), pruned to `[]` once everything finishes — and the
hook writes `background` when any *owned* entry has `status ==
"running"`. A running `shell` / `local_bash` task whose matching OS process
is not owned by this Claude (PPID=1 after `--fork-session` or a parent
Claude exit) is ignored — otherwise leftover wait-loops keep every later
Stop at `background` while the pane already shows recap / "new
task?". `Stop` re-fires when owned background work completes (the
completion re-invokes Claude for a wrap-up turn). The last Stop's array is
snapshotted to `$AM_STATE_DIR/<session>.bg` so a field-less `idle_prompt`
can re-check leftovers after wrap-up. No pane scraping.

The race guard in `state-hook.sh` protects `background`
unconditionally: a background subagent's own tool calls fire
`PreToolUse`/`PostToolUse` in the session for as long as it runs, and must
not flip the state to `running`; only `UserPromptSubmit` or the next `Stop`
moves it forward. `ready` gets a *bounded* guard instead (grace
window, `AM_STATE_GUARD_SECS`, default 10s): the trailing-hook race it
absorbs is milliseconds-scale, and a turn can resume without
`UserPromptSubmit` (answering an in-turn question dialog continues the same
turn), so tool hooks arriving after the window are genuine activity and flip
the state back to `running`.

History note: earlier revisions scraped pane content for a fourth signal
layer (background-wait banner, "N shell(s)" mode-line counters, hollow-bullet
agent panels, end-of-turn status classification with box-chrome/todo-widget
anchoring). That machinery misread live turns whose hook file and tmux
activity had both gone stale (>180s quiet tool calls are routine) and flapped
sessions through running/unknown/background hundreds of times a day.
The title glyph replaced all of it; do not reintroduce broad pane-content
classifiers for state. The sole narrow exception is Cursor's own structural
footer task counter, consulted only after its authoritative `✅ Ready` title
has established that the main turn is idle. Empirical ground truth lives in
`tests/live_lab/`.

**Pi sessions:** State comes from the in-process extension
`lib/hooks/am-state.ts` (`session_start` / `agent_settled` → `ready`,
`agent_start` → `running`), read ungated by `_state_resolve` (in-process
writes can't go silently stale; a dead pi drops the pane to a shell, which
the shell-pane check catches). Pi never reports `waiting_user` or `background`.

**Cursor sessions:** `~/.cursor/hooks.json` calls `state-hook.sh` for
`sessionStart`/`stop` (waiting) and prompt/tool/response activity (running).
The hook also writes `.sid` and `.transcript` identity sidecars from
`conversation_id` and `transcript_path`. Cursor hook state is read ungated:
turn-boundary events remain authoritative during long quiet tools, and the
shell-pane check catches process exit. Cursor 2026.08 added empirically stable
terminal-title suffixes: `✅ Ready`, `⏳ Working`, and `❓ Waiting for you`.
They self-heal missed/stale hook transitions and expose `waiting_user`
without broad pane scraping. The permission dialog still shows `⏳ Working`,
so it remains `running`. Cursor exposes no background-wait lifecycle event,
but while a Ready session owns background work its footer renders a nonzero
`<N> tasks` row after the exact `→ Add a follow-up` input placeholder (some
terminal captures also include the input border). `_state_resolve` matches only
that Cursor-owned structure to refine `ready` to `background`;
disappearance of the row returns it to `ready`. It cannot override a
Working title, and task-like text in
the conversation does not match.

### Verifying against real agents

`tests/live_lab/run.sh` drives a real `claude --model haiku` session in an
isolated tmux/state sandbox through every state (fresh idle, running,
permission dialog, background shell via `background_tasks`, AskUserQuestion
dialog, ctrl-b backgrounded turn, >180s quiet tool call) and records hook
payloads, state-file transitions, pane titles, and pane snapshots. Not part
of `test_all.sh` (spends real tokens, ~8 min). `tests/live_lab/run_pi.sh`
verifies pi state detection (session_start, agent_start, agent_settled). Run
the Claude lab when Claude Code updates or when changing `lib/state.sh` /
`lib/hooks/state-hook.sh`, and check `results/<ts>/report.txt` +
`timeline.tsv` for glyph/hook/state agreement.
`tests/live_lab/run_cursor.sh` records Cursor's fresh, running, permission,
question, subagent, stop, resume, and background-task footer behavior.
`tests/live_lab/run_pi.sh` covers pi.

### Debug instrumentation

- `AM_STATE_DEBUG=1` — `_state_resolve` appends one line per call to
  `$AM_DIR/.state-debug.log` (`<iso8601>\t<session>\t<agent>\t<source>\t<state>`)
  recording which layer (`shell` / `title` / `pane` / `hook` / `fallback` /
  `classify_exit`) produced the answer. Use for empirical data on which
  fallbacks are still load-bearing before cutting them.
- `AM_HOOK_DEBUG=1` — `state-hook.sh` appends to `$AM_DIR/.hook-debug.log`
  every time a hook fires but exits without writing state (registry miss,
  missing `AM_SESSION_NAME`, cwd mismatch). Surfaces vanished-session bugs
  that otherwise look like ghosts.

Both are opt-in. Logs are append-only; rotate externally if they grow.

## Agent-to-Agent CLI Guide

Use these commands when one CLI process or agent needs to launch, monitor, or message another `am` session without attaching to it.

### Launch a background session

Use `am new --detach` when the caller should keep control of its own terminal:

```bash
am new --detach ~/project
am new --detach --print-session ~/project
printf 'Investigate the test failure\n' | am new --detach --print-session ~/project
```

- `--detach` creates the tmux session and does not attach.
- `--print-session` writes the new session id to stdout, which makes scripting easier.
- Stdin becomes the initial prompt. `am` waits for the agent pane to be ready, then injects that prompt.

### Send a follow-up prompt

Use `am send` to talk to an already-running session:

```bash
am send am-abc123 "Review the latest diff"
printf 'Run the test suite and summarize failures\n' | am send am-abc123
```

- Session resolution supports exact names, stripped prefixes, and single fuzzy matches.
- Prompt text may come from argv or stdin.
- The prompt is pasted literally into the top agent pane, then Enter is sent.

### Peek at another session

Use `am peek` when you need visibility without attaching:

```bash
am peek am-abc123
am peek --pane shell am-abc123
am peek --follow am-abc123
am peek --pane shell --follow am-abc123
am peek --pane shell --history --lines 200 am-abc123
am peek --pane shell --history --grep "ERROR|FAIL" --lines 50 am-abc123
```

- Default pane is `agent` (top pane). `--pane shell` targets the shell panel — it follows the panel into the hidden `_amshell` window when toggled away, and errors with guidance (`am shell <session>`) when the panel was never opened (sessions start agent-only).
- Plain `am peek` returns a snapshot using tmux pane capture.
- `am peek --follow` prefers streamed pane logs when available and falls back to polling tmux output.
- `am peek --pane shell --history` reads the full streamed scrollback from `/tmp/am-logs/<session>/shell.log` instead of the viewport. Supports `--lines N` (default 200) and `--grep PAT` (filtered via `grep -E` then `tail`). Output is already ANSI-stripped. Mutually exclusive with `--follow`. See `skills/am-peek/SKILL.md` for context-conserving usage patterns.
- This follow contract is the right primitive for a future web wrapper: CLI and web can share the same snapshot/stream model.

### Recommended automation pattern

For agent orchestration, prefer this sequence:

1. Start worker: `session=$(am new --detach --print-session ~/repo)`
2. Give task: `printf 'Implement X\n' | am send "$session"`
3. Monitor progress: `am peek --follow "$session"`
4. Hand control to a human later: `am attach "$session"`

### Operational caveats

- `am peek --follow` is near-real-time, not a structured event stream.
- Log streaming is on by default (`stream_logs=true`). Follow mode tails `/tmp/am-logs/<session>/{agent,shell}.log`.
- If logs are disabled (`am config set logs false`), follow mode polls tmux pane text once per second.
- Every session exports `$AM_LOG_DIR` into both panes, pointing to `/tmp/am-logs/<session>/`.
- `am send` and `am peek` are transport primitives. They do not confirm task completion or parse agent state.

### Restore a closed session

Use `am restore` to browse recently closed Claude sessions and resume one:

```bash
am restore
```

- Opens an fzf picker showing closed sessions with pane snapshot previews.
- Sessions are available as long as their harness conversation identity remains resumable.
- Enter uses the harness-native adapter (Claude/Cursor `--resume`, pi `--session`, Codex `resume`).
- Also available as `Ctrl-H` in the main session browser (`am` with no args).

## Key Functions

**Session lifecycle:**
- `agent_launch(dir, type, task, agent_args...)` - Creates session, registers, starts agent. `--shell`/`--no-shell` are consumed here; every other arg reaches the agent verbatim
- `agent_kill(name)` - Kills tmux + removes from registry
- `agent_kill_all()` - Kill all agent sessions
- `agent_info(name)` - Show session info
- `auto_title_scan([force])` - Piggyback scanner: reads agent pane titles and updates session task field (throttled 60s). For Claude and pi sessions, falls back to the JSONL first user message when the pane title is empty/invalid. Mirrored in Go (`internal/sessions.RefreshTitles`) for the am-browse / am-list-internal path; both share the `$AM_DIR/.title_scan_last` throttle marker. Always chains into `sessions_log_scan` (even when title-throttled), which does the bash-only restore work — rolling snapshots, session_id backfill, sessions-log task sync — on its own `$AM_DIR/.restore_scan_last` marker so Go stamping can't starve it.
- `agent_resume_args(agent_type, session_id)` - Build agent-specific resume args (claude → --resume, pi → --session)

**Pane environment / workspaces:**
- `agent_pane_env(session_name, agent_type)` - Print the `VAR=VALUE` lines every am pane starts with (`AM_SESSION_NAME`, `AM_AGENT_TYPE`, `AM_IDENTITY_DIR`, `AM_LOG_DIR` when streaming); consumed by `tmux_create_session` and the shell-panel `split-window -e`
- `agent_workspace_allocate([branch])` - Run the configured workspace_cmd (config key) with AM_BRANCH exported and return the directory it prints; errors with setup guidance when unset or when the output is not an existing directory
- `current_session()` (in the am entry point) - Name of the am session the caller runs inside; backs the id command (aliases current, whoami) and the no-arg defaults of the shell and info commands

**Shell panel (collapsible; sessions launch agent-only by default):**
- `agent_shell_pane_add(session_name)` - Create the shell panel below the agent: split in the session directory, wire `AM_SESSION_NAME`/`AM_AGENT_TYPE`/`AM_IDENTITY_DIR`/`AM_LOG_DIR` exports + shell.log pipe-pane. Registry-driven, so it serves both `--shell` at launch and on-demand opening
- `agent_shell_pane_toggle(session_name)` - absent → add, open → hide, hidden → show; backs `am shell` and prefix+\` (via bin/toggle-shell)
- `tmux_shell_pane_state(session)` - Print absent/open/hidden from live tmux (no persisted layout state)
- `tmux_shell_pane_hide(session)` / `tmux_shell_pane_show(session)` - Park the panel in the hidden _amshell window / rejoin it below the agent (tmux break-pane/join-pane; the pane keeps running, so cwd, history, jobs, and pipe-pane streaming survive). Hide/show also toggle the window's pane-border-status so a lone agent pane wastes no row
- `tmux_main_window_id(session)` - @id of the session's non-_amshell window; unambiguous even when the current window is the hidden one

**Reboot recovery (`lib/recovery.sh`):**
- `recovery_desired_upsert/remove/identity()` - Maintain `desired_sessions.json`, the durable set of sessions the user still considers open
- `recovery_migrate_live_registry()` - One-time/idempotent capture of already-live sessions after upgrade
- `recovery_desired_candidates()` - Return exact-identity, prior-boot sessions missing from tmux
- `recovery_start_for_browser()` - Queue recovery only for the interactive browser and launch the detached worker
- `recovery_run()` / `recovery_restore_one()` - Locked, bounded-concurrency coordinator and per-session preflight/native resume

**Title helpers:**
- `_title_valid(title)` - Validate title (<=60 chars, no newlines)

**Registry (JSON metadata):**
- `registry_add/get_field/get_fields/update/remove` - CRUD for sessions.json. All writes are read-jq-rename cycles serialized under an exclusive lock on `$AM_REGISTRY.lock` (`_registry_lock`/`_registry_unlock`: the flock CLI on Linux, a perl flock syscall on an inherited fd on macOS — no flock CLI there; **not reentrant**, don't nest). The Go twin (`internal/sessions/lock.go:lockRegistry`) takes the same lock via `syscall.Flock`, so bash and Go writers can't lost-update each other; `RefreshTitles` computes titles unlocked, then re-reads and applies under the lock
- `registry_gc()` - Remove entries for dead tmux sessions. Two independently throttled halves: registry rows + hook state files (incl. `.sid` sidecars) on `$AM_DIR/.gc_last`, mirrored in Go (`internal/sessions.ReapOrphans`) for the am-browse / am-list-internal path; bash-only extras (`sessions_log_gc`, orphan state-file sweep) on `$AM_DIR/.gc_extras_last` so Go stamping `.gc_last` can't starve them.

**Sessions log (for restore):**
- `sessions_log_append(session_name, directory, branch, agent_type, [task])` - Append session to `~/.agent-manager/sessions_log.jsonl`
- `sessions_log_update(session_name, field, value)` - Update field in most recent log entry for a session
- `sessions_log_snapshot(session_name, [snapshot_key])` - Capture pane text to `~/.agent-manager/snapshots/`
- `sessions_log_scan([force])` - Rolling snapshots + session_id backfill + task sync for live Claude, Codex, Cursor, and pi sessions (throttled 60s via `.restore_scan_last`); chained from `auto_title_scan`. Ephemeral and durable hook sidecars are authoritative for session_id: a logged sid that disagrees with the sidecar is corrected (heals wrong guesses, tracks forked resumes)
- `sessions_log_gc()` - Remove entries whose JSONL no longer exists
- `sessions_log_restorable()` - List sessions that can be restored (not alive, JSONL exists)
- `_sessions_log_detect_id(directory, [not_before_iso], [agent])` - Detect session UUID from JSONL filename (agent defaults to claude; newest-mtime guess; callers must not use it when the directory hosts multiple sessions)
- `_sessions_log_dir_is_shared(session_name, directory, [agent])` - True when another registered session of the same agent type shares the directory; gates the mtime-based session-id guess in `_sessions_log_detect_id_for_session`
- `_sessions_log_field(session_name, field)` - Read a field from the most recent sessions-log entry for a session
- `_sessions_log_jsonl_exists(directory, session_id, [agent])` - Check if JSONL still exists (agent defaults to claude)
- `_slog_encode_pi_dir(directory)` - Encode directory path for pi session storage (strip leading slash, replace [/\:] with -, wrap with --)
- `_pi_sessions_root()` - Return pi sessions root (~/.pi/agent/sessions)
- `_pi_title_extract(raw_title)` - Extract task from pi pane title (strips cwd prefix)

**State detection (lib/state.sh):**
- `agent_get_state(session_name)` - Public entry: checks existence, looks up registry fields, delegates to `_state_resolve`, and returns one canonical lifecycle state. State-file reads and `am wait --state` accept the pre-0.12 `waiting_*` aliases, but all public output is canonical.
- `_state_resolve(session, agent_type, dir [, top_pid_map, comm_map, children_map, now_epoch [, activity_epoch [, title_map [, created_epoch [, cursor_tasks_map]]]]])` - **Single source of truth** for state derivation. Without bulk fixtures (last args), forks per-session for tmux/ps (fetching pane_pid + session_activity + pane_title in one call); with bulk fixtures passed by nameref (bash 4.3+), reads pre-built maps in place, plus optional per-session activity epoch, title map, created epoch, and pre-probed Cursor task signal. Used by `agent_get_state` / `lib/fzf.sh` (non-bulk) and `lib/status-bar` (bulk; passes tmux `#{session_created}` as created_epoch). Canonical order: shell pane check → title glyph/status × hook state → Cursor Ready-footer refinement → hook state when the title carries no signal → unknown. Bulk and non-bulk shell-pane semantics agree: shell pane + session <5s → starting (bulk needs created_epoch, else idle), otherwise idle; dead from `agent_classify_exit` is a non-bulk race-window branch only — missing sessions are reported dead by `agent_get_state`'s existence check
- `_state_title_signal(title, out_var)` - Classify Claude's self-maintained pane title into busy (braille spinner frame U+2800–U+28FF, or circle-phase glyph ◐◓◑◒ U+25D0–U+25D3 on Claude Code ≥2.1.232) / attention (✳) / none. Byte-oriented (LC_ALL=C) so it is locale-independent; fork-free
- `_state_cursor_tasks_signal(pane_text, out_var)` - Detect Cursor's nonzero footer task count only after the current `→ Add a follow-up` placeholder or captured input border; later footers supersede stale rows still visible in scrollback
- `agent_wait_state(session, [states], [timeout])` - Block until target state reached
- `agent_classify_exit(session)` - Classify shell exit as idle or dead
- `_state_hook_raw(session, out_var)` - Read the hook file ungated and canonicalize pre-0.12 aliases; used by title/status layers even when the file is stale
- `_state_hook_read(session, out_var [, now_epoch [, activity_epoch]])` - Gated hook-file read for agents without reliable turn-boundary events. Ready, waiting_user, and background persist; running gets a 180s staleness gate measured against max(file mtime, tmux session_activity), so a wedged agent falls to unknown. Claude, Cursor, and pi bypass this gate because long live turns routinely outlast it.
- `_state_pane_is_shell_bulk(session, top_pid_map, comm_map, children_map)` - Detect whether top pane is a plain shell (vs an agent process) from nameref bulk maps

**Utils:**
- `_format_seconds(seconds, [ago])` - Shared duration formatter (used by `format_time_ago`/`format_duration`)
- `claude_first_user_message(dir)` - Extract first user message from Claude session JSONL
- `pi_first_user_message(dir, [session_id], [strict])` - Extract first user message from pi session JSONL

**tmux:**
- `tmux_create_session(name, dir, [VAR=VALUE...])` - New detached session; env args are passed as new-session -e and stored in the session environment so later splits inherit them
- `tmux_get_activity(name)` - Last activity timestamp
- `tmux_get_created(name)` - Session creation timestamp
- `tmux_enable_pipe_pane(session, pane, file)` - Stream pane output to log file
- `tmux_pipe_pane(target, file)` - Same, for a raw pane target (e.g. a `%id`)
- `tmux_cleanup_logs(name)` - Remove log directory for a session
- `tmux_list_am_sessions()` - List all am-* session names
- `tmux_send_keys(session, keys)` - Send keys to a tmux pane
- `tmux_pane_title(target)` - Read pane title set by the application
- `tmux_count_am_sessions()` - Count active sessions
- `am_session_order()` - Canonical sidebar order: tmux session creation time ascending (oldest first, newest appended). Stable — only changes on create/kill
- `am_refresh_sidebar_cache()` - Regenerate each session's `@am_sidebar` tmux option and force a client-wide redraw. Called from `agent_launch` / `agent_kill` so pane-border updates are instant instead of waiting for the 5s `status-interval`

**Form (lib/form.sh):**
- `am_new_session_form(...)` - Entry point: parses prefill values, then runs the tput form
- `_form_init(directory, agent, task, [workspace_enabled], [workspace_branch])` - Initialize form state and fields: Directory, Agent, Task, plus Workspace/Branch when a workspace_cmd is configured
- `_form_run()` - Main loop: draw → read key → dispatch (navigate/edit) → repeat. Returns tab-delimited output on stdout
- `_form_process_key(key, [extra_seq])` - Route to `_form_process_key_navigate` or `_form_process_key_edit` based on `_FORM_MODE`
- `_form_draw()` - Buffer all fields + directory suggestions into `_FORM_BUF`, single write to `/dev/tty`
- `_form_filter_dir_suggestions(query, max)` - Filter cached zoxide/frecent list into `_FORM_DIR_FILTERED` array (no subshell)
- `_form_size_to_terminal()` - Grow `_FORM_DIR_SUGGESTION_LINES` (default 7) to fill the terminal height; called once by `_form_run`
- `_form_output()` - Format form values as `directory<US>agent<US>task<US>flags` (US = \x1f); flags carries only `--workspace[=branch]`

**Session browser (Go TUI — `cmd/am-browse`):**
- Compiled bubbletea binary; primary UI for the interactive session browser
- Output protocol: session name (attach), `__NEW__`, `__RESTORE__`, or empty (cancel)
- Flags: `--preview-cmd`, `--kill-cmd`, `--client-name`, `--benchmark`

**fzf helpers (lib/fzf.sh):**
- `fzf_main()` - Launches am-browse; errors if the binary is not built (run make)
- `fzf_list_json()` - JSON output of sessions for `am list --json`
- `fzf_list_simple()` - Plain text session list for `am list`
- `fzf_pick_directory()` - Directory picker with git-branch annotations and path completion
- `_annotate_directory(path)` - Annotate path with its current git branch
- `_dir_repo_scan_cached()` - Git-repo suggestions for `_list_directories`, served from `$AM_DIR/.dir_repo_cache` and refreshed in the background when older than `AM_DIR_REPO_CACHE_TTL` (default 1h); the raw `_dir_repo_scan` find is ~1s+ on large trees and never runs on the interactive path
- `fzf_restore_picker()` - Browse closed sessions, select to resume via `claude --resume`

**Config:**
- `am_config_init()` - Initialize config file
- `am_config_get(key)` / `am_config_set(key, value)` - Read/write config
- `am_default_agent()` - Get default agent type
- `am_stream_logs_enabled()` - Check if log streaming is enabled
- `am_shell_pane_enabled()` - Whether new sessions open with the shell panel visible (shell_pane key, default false)
- `am_workspace_cmd()` - Shell snippet behind -W on new (workspace_cmd key, env override AM_WORKSPACE_CMD; empty disables -W and hides the form's Workspace fields). Stored case-preserving — the config set path skips its lowercase normalization for this key
- `am_config_key_alias()` / `am_config_key_type()` / `am_config_value_is_valid()` - Normalize and validate config keys and values

## Session Naming

Format: `am-XXXXXX` where XXXXXX = md5(directory + timestamp)[:6]

Display: `dirname/branch [agent] task (Xm ago)`

## Extension Points

| Task | Where |
|------|-------|
| Add agent type | `lib/agents.sh` → `AGENT_COMMANDS` associative array |
| Add CLI command | `am` → `case "$cmd"` in `main()` |
| Change browser keybindings | `cmd/am-browse/main.go` |
| Modify session display | `internal/sessions/sessions.go` → `FormatDisplayBase()` |
| Add metadata field | `lib/registry.sh` → `registry_add()` |
| Change preview content | `lib/preview` (session), `lib/dir-preview` (directory picker) |
| Change title source | `lib/registry.sh` → `auto_title_scan()` |
| Add tmux helper | `bin/` directory (sourced by tmux keybindings) |
| Add form field | `lib/form.sh` → `_form_init()`, add `_form_add_field` call + handle in render/dispatch (Workspace/Branch are conditional on `am_workspace_cmd`, so field indices only shift when it is configured) |
| Change form keybindings | `lib/form.sh` → `_form_process_key_navigate()` / `_form_process_key_edit()` |
| Add config option | `lib/config.sh` → `am_config_init()` defaults |
| Add state detection signal | `lib/state.sh` → extend `_state_resolve()` ordering |
| Add hook state event | `lib/hooks/state-hook.sh` → event-to-state mapping |
| Add/edit dispatch skill | `skills/agent-manager-dispatch/SKILL.md` |
| Add/edit peek skill | `skills/am-peek/SKILL.md` |
| Add new skill (auto-installed) | drop `skills/<name>/SKILL.md`; `am install` loops `skills/*/` |
| Add restore agent support | `lib/agents.sh` → `agent_resume_args()`, `lib/registry.sh` → `sessions_log_restorable()` filter, `am` → `cmd_restore_internal()`, `internal/sessions` → Go mirrors |
| Change pi state mapping | `lib/hooks/am-state.ts` → event-to-state mapping |
