# AI Navigation Guide

Architecture reference for AI agents working with this codebase.

## Commands

- Run tests: `./tests/test_all.sh`
- Run tests (summary): `./tests/test_all.sh --summary` — suppresses PASS lines, shows only failures with details and a counts summary
- Run perf benchmark: `./tests/perf_test.sh` — standalone latency check for `am list-internal`; not part of `test_all.sh` and should not leave resources behind
- Run live state-detection lab: `./tests/live_lab/run.sh` — drives a real `claude --model haiku` through every state and records ground truth (hook payloads, pane titles, state transitions); not part of `test_all.sh` (spends tokens, ~8 min). Run after Claude Code updates or state.sh/state-hook.sh changes
- Typecheck/lint: `bash -n lib/*.sh am` (syntax check only — no linter)

## Versioning

SemVer (`MAJOR.MINOR.PATCH`). Single source of truth: `AM_VERSION` in `am` (help text and `am --version` both read it — never hardcode a version string elsewhere).

When to bump (pre-1.0, so `MAJOR` stays `0`):

- **PATCH** (`0.2.0` → `0.2.1`) — bug fixes, doc/test/skill tweaks, internal refactors with no user-facing behavior change.
- **MINOR** (`0.2.0` → `0.3.0`) — new user-facing capability: a new `am` command/flag, a new pane/UI mode, sandbox/restore/skill features, or a behavior change a user would notice.
- **MAJOR** — reserved; bump to `1.0.0` only on the first stability commitment.

How to bump: edit `AM_VERSION` in `am` in the same commit as the change that earns it; mention the bump in the commit body. Accumulate several small changes under one bump rather than bumping per-commit — bump when cutting a coherent batch.

## Code Style

- Libs in `lib/` are sourced, not executed — no shebang, no `set -euo pipefail` (the entry point `am` sets it)
- Functions prefixed by module name: `registry_add`, `tmux_create_session`, `agent_launch`
- Return values via stdout; all logging/UI output to stderr (`>&2`)
- Use `sed -E` (not `sed -r`) for portable regex (macOS + Linux)

## Gotchas

- Sourced libs derive their own dir as `_<MODULE>_LIB_DIR` from `AM_LIB_DIR` (exported by the `am` entry point); standalone scripts like `lib/status-bar` set their own `SCRIPT_DIR`
- Tests source libs directly — test helpers like `registry_exists` live in `test_helpers.sh`, not in production code
- Sandbox containers always run as the `ubuntu` user (UID/GID aligned to host). Use `SB_CONTAINER_HOME` for container-side path expansion, not `$HOME`
- Agents in sandbox can `sudo apt-get install` without a password. Full sudo requires `SB_UNSAFE_ROOT=1`

## Key Files

| File | Purpose |
|------|---------|
| `am` | Main entry point. Handles CLI args, routes to commands. |
| `lib/utils.sh` | Shared: colors, logging, time formatting, paths, Claude JSONL extraction |
| `lib/registry.sh` | JSON storage for session metadata, sessions log (restore), auto-titling |
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
| `lib/hooks/am-state.ts` | Pi extension: lifecycle events → am state files (session_start/agent_settled → waiting_input, agent_start → running) |
| `tests/live_lab/run.sh` | Empirical lab: drives a real Claude session through every state, records hook payloads / pane titles / transitions |
| `skills/am-orchestration/SKILL.md` | Claude Code skill: teaches agents to use am for multi-session orchestration |
| `skills/am-peek/SKILL.md` | Claude Code skill: teaches agents to read another session's full shell scrollback via `am peek --pane shell --history` |
| `lib/sandbox.sh` | Docker sandbox lifecycle and fleet ops |
| `sandbox/Dockerfile` | Docker image definition for sandbox containers |
| `sandbox/entrypoint.sh` | Container init: UID/GID alignment, skeleton seeding, sudoers |
| `bin/sandbox-shell` | Reconnecting shell loop for sandbox containers (used by shell pane) |
| `bin/switch-last` | tmux helper: switch to most recently active am-* session |
| `bin/switch-cycle` | tmux helper: cycle next/prev in canonical sidebar order |
| `bin/switch-index` | tmux helper: jump to Nth slot in canonical sidebar order |
| `bin/kill-and-switch` | tmux helper: kill a session and switch to next best |
| `docs/` | Architecture docs, backlog, perf notes, sandbox hardening notes |

## Data Flow

```
am → fzf_main() → am-browse (Go TUI) → stdout protocol → tmux_attach()
am new ~/project → agent_launch() → tmux_create_session() → registry_add() → tmux_send_keys()
am list-internal → am-list-internal (Go binary) → stdout
Ctrl-N in browser → am_new_session_form() → _form_run()
am new --sandbox ~/project → agent_launch() → sandbox_start() → sandbox_enter_cmd (shell pane) + sandbox_exec_cmd (agent pane) → agent runs in container
am new --sandbox ~/project → agent_launch() → sandbox_start() → bind-mounts ~/.agent-manager/sandbox-home as /home/ubuntu
agent_kill() → sessions_log_snapshot() + sessions_log_update(closed_at) → sandbox_remove() → tmux_kill_session() → registry_remove()
am restore → fzf_restore_picker() → sessions_log_restorable() → agent_launch(dir, agent_type, agent_resume_args...) → tmux_attach() (claude → --resume, pi → --session)
```

## State Detection (title glyph + hooks)

Claude sessions are resolved from two complementary, documented-behavior
signals — no pane-content scraping:

1. **Pane title glyph** (busy vs attention). Claude Code maintains the
   terminal title itself: a braille spinner frame (`⠂` …, U+2800–U+28FF)
   while a turn is running, `✳` when it needs the user. tmux exposes it as
   `#{pane_title}`. It is event-driven, self-healing, survives detachment,
   and never goes stale — verified empirically (tests/live_lab): tmux
   `session_activity` and the hook file's mtime both go quiet for minutes
   during long tool calls, the glyph does not. It also covers cases hooks
   structurally miss: a fresh session idle at its first prompt (no hook has
   fired yet) and a backgrounded turn whose lifecycle events fire from a bg
   session context that never resolves to the am session.
2. **Hook state file** (which *flavor* of waiting). Claude Code lifecycle
   hooks (`Stop`, `Notification`, `UserPromptSubmit`, `PreToolUse`,
   `PostToolUse`, `PermissionRequest`) call `lib/hooks/state-hook.sh`, which
   maps the event to an am state and writes it to
   `/tmp/am-state/<session_name>`.

State detection priority: **shell pane check → title glyph × hook state
(decision table below) → gated hook state (no glyph signal) → unknown**.

Glyph × hook decision table (`_state_resolve`, Claude sessions):

| Glyph | Hook state | Result |
|---|---|---|
| busy (braille) | `waiting_permission` / `waiting_custom` | pass through — a pending dialog needs the user; approval fires `PreToolUse` which moves the file forward |
| busy | anything else (incl. stale `running`, `waiting_input`, `waiting_background`, missing) | `running` — trust Claude's own indicator (covers hook-silent gaps, wrap-up turns after background work, turns resumed without `UserPromptSubmit`) |
| attention (`✳`) | any `waiting_*` | pass through — the hook has the precise flavor |
| attention | `running` / missing | `waiting_input`; a leftover `running` file is self-healed so its mtime stamps the waiting-entry time (backgrounded-turn ends, fresh sessions) |
| none (hostname / booting / titles unavailable / non-Claude agent) | — | hook state with the 180s running-staleness gate, else `unknown` |

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
| `Stop` | — | `waiting_input`, or `waiting_background` when the payload's `background_tasks` lists running work |
| `Notification` | `idle_prompt` | `waiting_input` (same `background_tasks` refinement; without the field it cannot downgrade `waiting_background` — idle_prompt's payload omits it) |
| `Notification` | `permission_prompt` | `waiting_permission` |
| `Notification` | `elicitation_dialog` | `waiting_custom` |
| `UserPromptSubmit` | — | `running` |
| `PostToolUse` | — | `running` |

States not covered by hooks (`starting`, `idle`, `dead`) use existing
process/tmux checks which are already reliable.

`waiting_background` (Claude's main turn ended but a background agent/task/
workflow/shell is still running) is written directly by the hook: the `Stop`
payload carries a `background_tasks` array (documented; Claude Code ≥2.1) —
one entry per still-running background item (`{id, type (subagent|shell),
status, description, …}`), pruned to `[]` once everything finishes — and the
hook writes `waiting_background` when any entry has `status == "running"`.
`Stop` re-fires when background work completes (the completion re-invokes
Claude for a wrap-up turn), so the state self-heals without any pane
involvement. The race guard in `state-hook.sh` protects `waiting_background`
unconditionally: a background subagent's own tool calls fire
`PreToolUse`/`PostToolUse` in the session for as long as it runs, and must
not flip the state to `running`; only `UserPromptSubmit` or the next `Stop`
moves it forward. `waiting_input` gets a *bounded* guard instead (grace
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
sessions through running/unknown/waiting_background hundreds of times a day.
The title glyph replaced all of it; do not reintroduce pane-content
heuristics for state. Empirical ground truth lives in `tests/live_lab/`.

**Pi sessions:** State comes from the in-process extension
`lib/hooks/am-state.ts` (`session_start` / `agent_settled` → `waiting_input`,
`agent_start` → `running`), read ungated by `_state_resolve` (in-process
writes can't go silently stale; a dead pi drops the pane to a shell, which
the shell-pane check catches). Pi never reports `waiting_permission` /
`waiting_custom` / `waiting_background`.

### Verifying against a real Claude

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

### Debug instrumentation

- `AM_STATE_DEBUG=1` — `_state_resolve` appends one line per call to
  `$AM_DIR/.state-debug.log` (`<iso8601>\t<session>\t<agent>\t<source>\t<state>`)
  recording which layer (`shell` / `title` / `hook` / `fallback` /
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

- Default pane is `agent` (top pane). `--pane shell` targets the lower shell pane.
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
- Sessions are available as long as their Claude conversation JSONL exists on disk.
- Enter resumes via `claude --resume <session_id>` in the original directory.
- Also available as `Ctrl-H` in the main session browser (`am` with no args).

## Key Functions

**Session lifecycle:**
- `agent_launch(dir, type, task, worktree_name, agent_args...)` - Creates session, registers, starts agent
- `agent_kill(name)` - Kills tmux + removes from registry
- `agent_kill_all()` - Kill all agent sessions
- `agent_info(name)` - Show session info
- `auto_title_scan([force])` - Piggyback scanner: reads agent pane titles and updates session task field (throttled 60s). For Claude and pi sessions, falls back to the JSONL first user message when the pane title is empty/invalid. Mirrored in Go (`internal/sessions.RefreshTitles`) for the am-browse / am-list-internal path; both share the `$AM_DIR/.title_scan_last` throttle marker. Always chains into `sessions_log_scan` (even when title-throttled), which does the bash-only restore work — rolling snapshots, session_id backfill, sessions-log task sync — on its own `$AM_DIR/.restore_scan_last` marker so Go stamping can't starve it.
- `agent_resume_args(agent_type, session_id)` - Build agent-specific resume args (claude → --resume, pi → --session)

**Title helpers:**
- `_title_valid(title)` - Validate title (<=60 chars, no newlines)

**Registry (JSON metadata):**
- `registry_add/get_field/get_fields/update/remove` - CRUD for sessions.json
- `registry_gc()` - Remove entries for dead tmux sessions. Two independently throttled halves: registry rows + hook state files (incl. `.sid` sidecars) on `$AM_DIR/.gc_last`, mirrored in Go (`internal/sessions.ReapOrphans`) for the am-browse / am-list-internal path; bash-only extras (`sandbox_gc_orphans`, `sessions_log_gc`, orphan state-file sweep) on `$AM_DIR/.gc_extras_last` so Go stamping `.gc_last` can't starve them.

**Sessions log (for restore):**
- `sessions_log_append(session_name, directory, branch, agent_type, [task])` - Append session to `~/.agent-manager/sessions_log.jsonl`
- `sessions_log_update(session_name, field, value)` - Update field in most recent log entry for a session
- `sessions_log_snapshot(session_name, [snapshot_key])` - Capture pane text to `~/.agent-manager/snapshots/`
- `sessions_log_scan([force])` - Rolling snapshots + session_id backfill + task sync for live Claude and pi sessions (throttled 60s via `.restore_scan_last`); chained from `auto_title_scan`. The hook sidecar is authoritative for session_id: a logged sid that disagrees with the sidecar is corrected (heals wrong guesses, tracks forked resumes)
- `sessions_log_gc()` - Remove entries whose JSONL no longer exists
- `sessions_log_restorable()` - List sessions that can be restored (not alive, JSONL exists)
- `_sessions_log_detect_id(directory, [agent])` - Detect session UUID from JSONL filename (agent defaults to claude; newest-mtime guess; callers must not use it when the directory hosts multiple sessions)
- `_sessions_log_dir_is_shared(session_name, directory, [agent])` - True when another registered session of the same agent type shares the directory; gates the mtime-based session-id guess in `_sessions_log_detect_id_for_session`
- `_sessions_log_field(session_name, field)` - Read a field from the most recent sessions-log entry for a session
- `_sessions_log_jsonl_exists(directory, session_id, [agent])` - Check if JSONL still exists (agent defaults to claude)
- `_slog_encode_pi_dir(directory)` - Encode directory path for pi session storage (base64url)
- `_pi_sessions_root()` - Return pi sessions root (~/.pi/sessions)
- `_pi_title_extract(raw_title)` - Extract task from pi pane title (strips cwd prefix)

**State detection (lib/state.sh):**
- `agent_get_state(session_name)` - Public entry: checks existence, looks up registry fields, delegates to `_state_resolve`. Returns: starting, running, waiting_input, waiting_permission, waiting_custom, waiting_background, idle, unknown, dead
- `_state_resolve(session, agent_type, dir [, top_pid_map, comm_map, children_map, now_epoch [, activity_epoch [, title_map]]])` - **Single source of truth** for state derivation. Without bulk fixtures (last args), forks per-session for tmux/ps (fetching pane_pid + session_activity + pane_title in one call); with bulk fixtures passed by nameref (bash 4.3+), reads pre-built maps in place, plus optional per-session activity epoch and title map. Used by `agent_get_state` / `lib/fzf.sh` (non-bulk) and `lib/status-bar` (bulk). Canonical order: shell pane check → title glyph × hook state per the decision table in "State Detection" above → gated hook state when the title carries no signal → unknown
- `_state_title_signal(title, out_var)` - Classify Claude's self-maintained pane title into busy (braille spinner frame, U+2800–U+28FF) / attention (✳) / none. Byte-oriented (LC_ALL=C) so it is locale-independent; fork-free
- `agent_wait_state(session, [states], [timeout])` - Block until target state reached
- `agent_classify_exit(session)` - Classify shell exit as idle or dead
- `_state_hook_raw(session, out_var)` - Read the raw (ungated) hook state into a nameref; used by the title-glyph layer, which needs the flavor even when the file is stale
- `_state_hook_read(session, out_var [, now_epoch [, activity_epoch]])` - Gated hook-file read for the no-glyph fallback path. waiting_* states are persistent; the running state gets a 180s staleness gate measured against max(file mtime, tmux session_activity) so a wedged agent falls to unknown instead of looking busy forever. Note: both mtime and activity routinely go stale during long quiet tool calls on a *live* turn — only the title glyph distinguishes that from a wedge, which is why this gate is fallback-only
- `_state_pane_is_shell_bulk(session, top_pid_map, comm_map, children_map)` - Detect whether top pane is a plain shell (vs an agent process) from nameref bulk maps

**Utils:**
- `_format_seconds(seconds, [ago])` - Shared duration formatter (used by `format_time_ago`/`format_duration`)
- `claude_first_user_message(dir)` - Extract first user message from Claude session JSONL
- `pi_first_user_message(dir, [session_id], [strict])` - Extract first user message from pi session JSONL

**tmux:**
- `tmux_create_session(name, dir)` - New detached session
- `tmux_get_activity(name)` - Last activity timestamp
- `tmux_get_created(name)` - Session creation timestamp
- `tmux_enable_pipe_pane(session, pane, file)` - Stream pane output to log file
- `tmux_cleanup_logs(name)` - Remove log directory for a session
- `tmux_list_am_sessions()` - List all am-* session names
- `tmux_send_keys(session, keys)` - Send keys to a tmux pane
- `tmux_pane_title(target)` - Read pane title set by the application
- `tmux_count_am_sessions()` - Count active sessions
- `am_session_order()` - Canonical sidebar order: tmux session creation time ascending (oldest first, newest appended). Stable — only changes on create/kill
- `am_refresh_sidebar_cache()` - Regenerate each session's `@am_sidebar` tmux option and force a client-wide redraw. Called from `agent_launch` / `agent_kill` so pane-border updates are instant instead of waiting for the 5s `status-interval`

**Sandbox:**
- `sandbox_start(session_name, dir)` - Create and start per-session Docker container
- `sandbox_enter_cmd(session_name, dir)` - Build reconnecting shell-entry command for a running sandbox
- `sandbox_exec_cmd(session_name, dir, cmd)` - Build docker exec command that runs a command directly inside the container via `zsh -lc`
- `sandbox_enter(session_name)` - Enter running sandbox container interactively
- `sandbox_remove(session_name)` - Force-remove container
- `sandbox_status(session_name)` - Show container state and event log
- `sandbox_gc_orphans()` - Remove containers whose tmux session no longer exists
- `sb_build([no_cache])` - Build Docker image from sandbox directory
- `sb_ps()` / `sb_prune()` / `sb_reset()` - Manage sandbox containers and the shared home directory
- `sb_prune()` - Force-remove all sandbox containers (running + stopped) and their proxies


**Form (lib/form.sh):**
- `am_new_session_form(...)` - Entry point: parses prefill values, then runs the tput form
- `_form_init(directory, agent, task, mode, yolo, sandbox, worktree_enabled, worktree_name, docker_available)` - Initialize form state, fields, submit row
- `_form_run()` - Main loop: draw → read key → dispatch (navigate/edit) → repeat. Returns tab-delimited output on stdout
- `_form_process_key(key, [extra_seq])` - Route to `_form_process_key_navigate` or `_form_process_key_edit` based on `_FORM_MODE`
- `_form_draw()` - Buffer all fields + directory suggestions into `_FORM_BUF`, single write to `/dev/tty`
- `_form_filter_dir_suggestions(query, max)` - Filter cached zoxide/frecent list into `_FORM_DIR_FILTERED` array (no subshell)
- `_form_output()` - Format form values as `directory\tagent\ttask\tworktree\tflags` (same contract as fzf form)

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
- `fzf_restore_picker()` - Browse closed sessions, select to resume via `claude --resume`

**Config:**
- `am_config_init()` - Initialize config file
- `am_config_get(key)` / `am_config_set(key, value)` - Read/write config
- `am_default_agent()` - Get default agent type
- `am_stream_logs_enabled()` - Check if log streaming is enabled
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
| Change sandbox config | `lib/sandbox.sh`, `sandbox/Dockerfile` |
| Add form field | `lib/form.sh` → `_form_init()`, add `_form_add_field` call + handle in render/dispatch |
| Change form keybindings | `lib/form.sh` → `_form_process_key_navigate()` / `_form_process_key_edit()` |
| Add config option | `lib/config.sh` → `am_config_init()` defaults |
| Add state detection signal | `lib/state.sh` → extend `_state_resolve()` ordering |
| Add hook state event | `lib/hooks/state-hook.sh` → event-to-state mapping |
| Add/edit orchestration skill | `skills/am-orchestration/SKILL.md` |
| Add/edit peek skill | `skills/am-peek/SKILL.md` |
| Add new skill (auto-installed) | drop `skills/<name>/SKILL.md`; `am install` loops `skills/*/` |
| Add restore agent support | `lib/agents.sh` → `agent_resume_args()`, `lib/registry.sh` → `sessions_log_restorable()` filter, `am` → `cmd_restore_internal()`, `internal/sessions` → Go mirrors |
| Change pi state mapping | `lib/hooks/am-state.ts` → event-to-state mapping |
