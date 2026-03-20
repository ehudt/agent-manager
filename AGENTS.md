# AI Navigation Guide

Architecture reference for AI agents working with this codebase.

## Commands

- Run tests: `./tests/test_all.sh`
- Run tests (summary): `./tests/test_all.sh --summary` — suppresses PASS lines, shows only failures with details and a counts summary
- Run perf benchmark: `./tests/perf_test.sh` — standalone latency check for `am list-internal`; not part of `test_all.sh` and should not leave resources behind
- Typecheck/lint: `bash -n lib/*.sh am` (syntax check only — no linter)

## Code Style

- Libs in `lib/` are sourced, not executed — no shebang, no `set -euo pipefail` (the entry point `am` sets it)
- Functions prefixed by module name: `registry_add`, `tmux_create_session`, `agent_launch`
- Return values via stdout; all logging/UI output to stderr (`>&2`)
- Use `sed -E` (not `sed -r`) for portable regex (macOS + Linux)

## Gotchas

- `SCRIPT_DIR` is overwritten when sourcing `lib/agents.sh` — if you need a stable reference, save it before sourcing
- Tests source libs directly — test helpers like `registry_exists` live in `test_helpers.sh`, not in production code

## Key Files

| File | Purpose |
|------|---------|
| `am` | Main entry point. Handles CLI args, routes to commands. |
| `lib/utils.sh` | Shared: colors, logging, time formatting, paths, Claude JSONL extraction |
| `lib/registry.sh` | JSON storage for session metadata, persistent session history, auto-titling |
| `lib/tmux.sh` | tmux wrappers: create/kill/attach sessions |
| `lib/agents.sh` | Agent lifecycle: launch, display formatting, kill |
| `lib/form.sh` | tput-based new session form (two-mode: Navigate/Edit), gated by `new_form` config flag |
| `lib/fzf.sh` | fzf UI: list generation, directory picker with history annotations, main loop |
| `lib/preview` | Standalone preview script for fzf panel (extracts first user message, captures pane) |
| `lib/title-upgrade` | Standalone script: fire-and-forget Haiku title upgrade for a session |
| `lib/status-right` | Standalone script: tmux status-right showing sessions waiting for attention |
| `lib/dir-preview` | Standalone preview script for directory picker fzf panel |
| `lib/config.sh` | User config: defaults, feature flags, persistent settings |
| `lib/state.sh` | Session state detection: JSONL parsing, pane pattern matching, wait/poll |
| `skills/am-orchestration/SKILL.md` | Claude Code skill: teaches agents to use am for multi-session orchestration |
| `lib/sandbox.sh` | Docker sandbox lifecycle, state mappings, and fleet ops |
| `lib/sb_volume.sh` | Docker-volume helpers for sandbox state persistence |
| `sandbox/Dockerfile` | Docker image definition for sandbox containers |
| `sandbox/entrypoint.sh` | Container init: user alignment, Tailscale, SSH |
| `bin/switch-last` | tmux helper: switch to most recently active am-* session |
| `bin/kill-and-switch` | tmux helper: kill a session and switch to next best |

## Data Flow

```
am → fzf_main() → tmux_attach()
am new ~/project → agent_launch() → tmux_create_session() → registry_add() → tmux_send_keys()
fzf_list_sessions() / fzf_list_json() → auto_title_scan() → _title_fallback() → registry_update() + history_append()
Ctrl-N in fzf → am_new_session_form() → _form_run() (if new_form) or fzf_new_session_form() (legacy)
am new --yolo ~/project → agent_launch() → sandbox_start() → tmux panes attach → agent runs in container
am sb map ~/.ssh --to ~/.ssh → sb_vol_copy_in() + manifest update → sandbox entrypoint hydrates ~/.am-state into target paths
agent_kill() → sandbox_remove() → tmux_kill_session() → registry_remove()
```

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
```

- Default pane is `agent` (top pane). `--pane shell` targets the lower shell pane.
- Plain `am peek` returns a snapshot using tmux pane capture.
- `am peek --follow` prefers streamed pane logs when available and falls back to polling tmux output.
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

## Key Functions

**Session lifecycle:**
- `agent_launch(dir, type, task, worktree_name, agent_args...)` - Creates session, registers, starts agent
- `agent_kill(name)` - Kills tmux + removes from registry
- `agent_kill_all()` - Kill all agent sessions
- `agent_info(name)` - Show session info
- `auto_title_scan([force])` - Piggyback scanner: titles untitled sessions during fzf touchpoints (throttled 60s), writes fallback immediately, spawns `lib/title-upgrade` for Haiku upgrade

**Title helpers:**
- `_title_fallback(message)` - Generate fallback title from first sentence of user message
- `_title_strip_haiku(raw_title)` - Strip markdown/quotes from Haiku output
- `_title_valid(title)` - Validate title (<=60 chars, no newlines)

**Registry (JSON metadata):**
- `registry_add/get_field/get_fields/update/remove/list` - CRUD for sessions.json
- `registry_gc()` - Remove entries for dead tmux sessions (uses `tmux_session_exists`)

**Session history (JSONL):**
- `history_append(dir, task, agent_type, branch)` - Append entry to `~/.agent-manager/history.jsonl` (prune throttled to once/hour)
- `history_prune()` - Remove entries older than 7 days
- `history_for_directory(path)` - Get recent sessions for a directory, newest first

**State detection (lib/state.sh):**
- `agent_get_state(session_name)` - Get current state: starting, running, waiting_input, waiting_permission, waiting_custom, idle, dead
- `agent_wait_state(session, [states], [timeout])` - Block until target state reached
- `agent_classify_exit(session)` - Classify shell exit as idle or dead
- `_state_from_jsonl(directory)` - Derive state from Claude JSONL (primary source for Claude sessions)
- `_state_from_pane(session, [agent_type])` - Derive state from pane content (all agents)
- `_state_jsonl_path(dir)` - Find newest Claude JSONL for directory
- `_state_jsonl_stale(path)` - Check if JSONL is >30s old

**Utils:**
- `_format_seconds(seconds, [ago])` - Shared duration formatter (used by `format_time_ago`/`format_duration`)
- `claude_first_user_message(dir)` - Extract first user message from Claude session JSONL

**tmux:**
- `tmux_create_session(name, dir)` - New detached session
- `tmux_get_activity(name)` - Last activity timestamp
- `tmux_enable_pipe_pane(session, pane, file)` - Stream pane output to log file
- `tmux_cleanup_logs(name)` - Remove log directory for a session
- `tmux_list_am_sessions()` - List all am-* session names
- `tmux_list_am_sessions_with_activity()` - List sessions with activity timestamps
- `tmux_send_keys(session, keys)` - Send keys to a tmux pane
- `tmux_count_am_sessions()` - Count active sessions

**Sandbox:**
- `sandbox_start(session_name, dir)` - Create and start per-session Docker container
- `sandbox_enter_cmd(session_name, dir)` - Build reconnecting shell-entry command for a running sandbox
- `sandbox_remove(session_name)` - Force-remove container
- `sandbox_status(session_name)` - Show container state and event log
- `sandbox_gc_orphans()` - Remove containers whose tmux session no longer exists
- `sb_build([no_cache])` - Build Docker image from sandbox directory
- `sb_map()` / `sb_unmap()` / `sb_maps()` / `sb_sync()` / `sb_edit()` - Manage manifest-driven state mappings in the sandbox volume
- `sb_ps()` / `sb_prune()` / `sb_reset()` / `sb_export()` / `sb_import()` / `sb_shell()` - Manage sandbox containers and the shared state volume

**Sandbox volume (`lib/sb_volume.sh`):**
- `sb_vol_ensure()` - Create the state volume and seed `meta.json` / `mappings.json`
- `sb_vol_read/write/rm/ls/mkdir()` - Low-level volume file operations
- `sb_vol_copy_in()` / `sb_vol_copy_out()` - Copy files between host paths and the sandbox state volume

**Form (lib/form.sh):**
- `am_new_session_form(...)` - Dispatch: picks tput form or legacy fzf form based on the new_form config flag
- `_form_init(directory, agent, task, mode, yolo, sandbox, worktree_enabled, worktree_name, docker_available)` - Initialize form state, fields, submit row
- `_form_run()` - Main loop: draw → read key → dispatch (navigate/edit) → repeat. Returns tab-delimited output on stdout
- `_form_process_key(key, [extra_seq])` - Route to `_form_process_key_navigate` or `_form_process_key_edit` based on `_FORM_MODE`
- `_form_draw()` - Buffer all fields + directory suggestions into `_FORM_BUF`, single write to `/dev/tty`
- `_form_filter_dir_suggestions(query, max)` - Filter cached zoxide/frecent list into `_FORM_DIR_FILTERED` array (no subshell)
- `_form_output()` - Format form values as `directory\tagent\ttask\tworktree\tflags` (same contract as fzf form)

**fzf:**
- `fzf_list_sessions()` - Format: `session|display_name`
- `fzf_list_simple()` - Plain text session list for `am list`
- `fzf_pick_directory()` - Directory picker with history annotations and path completion
- `_annotate_directory(path)` - Annotate path with recent session history (agent, task, age)
- `fzf_main()` - Main loop with keybindings

**Config:**
- `am_config_init()` - Initialize config file
- `am_config_get(key)` / `am_config_set(key, value)` - Read/write config
- `am_default_agent()` - Get default agent type
- `am_stream_logs_enabled()` - Check if log streaming is enabled
- `am_config_key_alias()` / `am_config_key_type()` / `am_config_value_is_valid()` - Normalize and validate config keys and values, including `sandbox-shares`

## Session Naming

Format: `am-XXXXXX` where XXXXXX = md5(directory + timestamp)[:6]

Display: `dirname/branch [agent] task (Xm ago)`

## Extension Points

| Task | Where |
|------|-------|
| Add agent type | `lib/agents.sh` → `AGENT_COMMANDS` associative array |
| Add CLI command | `am` → `case "$cmd"` in `main()` |
| Change fzf keybindings | `lib/fzf.sh` → `fzf_main()` |
| Modify session display | `lib/agents.sh` → `agent_display_name()` |
| Add metadata field | `lib/registry.sh` → `registry_add()` |
| Change preview content | `lib/preview` (session), `lib/dir-preview` (directory picker) |
| Change title upgrade | `lib/title-upgrade` (standalone script) |
| Add tmux helper | `bin/` directory (sourced by tmux keybindings) |
| Add history integration | `lib/registry.sh` → `history_append()` |
| Change sandbox config | `lib/sandbox.sh`, `lib/sb_volume.sh`, `sandbox/Dockerfile`, `config/presets.json` |
| Add form field | `lib/form.sh` → `_form_init()`, add `_form_add_field` call + handle in render/dispatch |
| Change form keybindings | `lib/form.sh` → `_form_process_key_navigate()` / `_form_process_key_edit()` |
| Add config option | `lib/config.sh` → `am_config_init()` defaults |
| Add state detection pattern | `lib/state.sh` → `_state_from_pane()` pattern list |
| Add/edit orchestration skill | `skills/am-orchestration/SKILL.md` |
