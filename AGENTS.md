# AI Navigation Guide

Architecture reference for AI agents working with this codebase.

## Key Files

| File | Purpose |
|------|---------|
| `am` | Main entry point. Handles CLI args, routes to commands. |
| `lib/utils.sh` | Shared: colors, logging, time formatting, paths, Claude JSONL extraction |
| `lib/registry.sh` | JSON storage for session metadata + persistent session history |
| `lib/tmux.sh` | tmux wrappers: create/kill/attach sessions |
| `lib/agents.sh` | Agent lifecycle: launch, display formatting, kill, auto-titling |
| `lib/fzf.sh` | fzf UI: list generation, directory picker with history annotations, main loop |
| `lib/preview` | Standalone preview script for fzf panel (extracts first user message, captures pane) |
| `bin/switch-last` | tmux helper: switch to most recently active am-* session |
| `bin/kill-and-switch` | tmux helper: kill a session and switch to next best |

## Data Flow

```
am → fzf_main() → tmux_attach()
am new ~/project → agent_launch() → tmux_create_session() → registry_add() → tmux_send_keys()
                                   └→ auto_title_session() (background) → registry_update() + history_append()
Ctrl-N in fzf → fzf_pick_directory() → _annotate_directory() → history_for_directory()
```

## Key Functions

**Session lifecycle:**
- `agent_launch(dir, type, task, worktree_name, agent_args...)` - Creates session, registers, starts agent
- `agent_kill(name)` - Kills tmux + removes from registry
- `auto_title_session(session_name, dir)` - Background: polls Claude JSONL, generates title via Haiku, updates registry + history

**Registry (JSON metadata):**
- `registry_add/get/update/remove/list` - CRUD for sessions.json
- `registry_gc()` - Remove entries for dead tmux sessions

**Session history (JSONL):**
- `history_append(dir, task, agent_type, branch)` - Append entry to `~/.agent-manager/history.jsonl`
- `history_prune()` - Remove entries older than 7 days
- `history_for_directory(path)` - Get recent sessions for a directory, newest first

**Utils:**
- `claude_first_user_message(dir)` - Extract first user message from Claude session JSONL

**tmux:**
- `tmux_create_session(name, dir)` - New detached session
- `tmux_get_activity(name)` - Last activity timestamp
- `tmux_enable_pipe_pane(session, pane, file)` - Stream pane output to log file
- `tmux_cleanup_logs(name)` - Remove log directory for a session

**fzf:**
- `fzf_list_sessions()` - Format: `session|display_name`
- `fzf_pick_directory()` - Directory picker with history annotations and path completion
- `_annotate_directory(path)` - Annotate path with recent session history (agent, task, age)
- `fzf_main()` - Main loop with keybindings

## Session Naming

Format: `am-XXXXXX` where XXXXXX = md5(directory + timestamp)[:6]

Display: `dirname/branch [agent] (Xm ago) "task"`

## Extension Points

| Task | Where |
|------|-------|
| Add agent type | `lib/agents.sh` → `AGENT_COMMANDS` associative array |
| Add CLI command | `am` → `case "$cmd"` in `main()` |
| Change fzf keybindings | `lib/fzf.sh` → `fzf_main()` |
| Modify session display | `lib/agents.sh` → `agent_display_name()` |
| Add metadata field | `lib/registry.sh` → `registry_add()` |
| Change preview content | `lib/preview` (standalone script) |
| Add tmux helper | `bin/` directory (sourced by tmux keybindings) |
| Add history integration | `lib/registry.sh` → `history_append()` |
