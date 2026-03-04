# AI Navigation Guide

Architecture reference for AI agents working with this codebase.

## Key Files

| File | Purpose |
|------|---------|
| `am` | Main entry point. Handles CLI args, routes to commands. |
| `lib/utils.sh` | Shared: colors, logging, time formatting, paths, Claude JSONL extraction |
| `lib/registry.sh` | JSON storage for session metadata, persistent session history, auto-titling |
| `lib/tmux.sh` | tmux wrappers: create/kill/attach sessions |
| `lib/agents.sh` | Agent lifecycle: launch, display formatting, kill |
| `lib/fzf.sh` | fzf UI: list generation, directory picker with history annotations, main loop |
| `lib/preview` | Standalone preview script for fzf panel (extracts first user message, captures pane) |
| `lib/title-upgrade` | Standalone script: fire-and-forget Haiku title upgrade for a session |
| `lib/dir-preview` | Standalone preview script for directory picker fzf panel |
| `lib/config.sh` | User config: defaults, feature flags, persistent settings |
| `lib/sandbox.sh` | Docker sandbox lifecycle: start, attach, stop, remove, fleet ops |
| `sandbox/Dockerfile` | Docker image definition for sandbox containers |
| `sandbox/entrypoint.sh` | Container init: user alignment, Tailscale, SSH |
| `bin/switch-last` | tmux helper: switch to most recently active am-* session |
| `bin/kill-and-switch` | tmux helper: kill a session and switch to next best |

## Data Flow

```
am → fzf_main() → tmux_attach()
am new ~/project → agent_launch() → tmux_create_session() → registry_add() → tmux_send_keys()
fzf_list_sessions() / fzf_list_json() → auto_title_scan() → _title_fallback() → registry_update() + history_append()
Ctrl-N in fzf → fzf_pick_directory() → _annotate_directory() → history_for_directory()
am new --yolo ~/project → agent_launch() → sandbox_start() → tmux panes attach → agent runs in container
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
- If `stream_logs=true`, follow mode tails `/tmp/am-logs/<session>/{agent,shell}.log`.
- If logs are disabled, follow mode polls tmux pane text once per second.
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
- `sandbox_attach_cmd(session_name, dir)` - Return docker exec command string for tmux
- `sandbox_stop(session_name)` - Stop container without removing
- `sandbox_remove(session_name)` - Force-remove container
- `sandbox_status(session_name)` - Show container state and event log
- `sandbox_list()` - List all agent-sandbox containers
- `sandbox_prune()` - Remove stopped containers
- `sandbox_gc_orphans()` - Remove containers whose tmux session no longer exists
- `sandbox_build_image([no_cache])` - Build Docker image from sandbox directory
- `sandbox_rebuild_and_restart([no_cache])` - Rebuild image, recreate running containers
- `sandbox_identity_init()` - Initialize `~/.sb/` with dedicated sandbox credentials

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
| Change sandbox config | `lib/sandbox.sh` → globals, `sandbox/Dockerfile` |
| Add config option | `lib/config.sh` → `am_config_init()` defaults |
