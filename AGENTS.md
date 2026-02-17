# AI Navigation Guide

Architecture reference for AI agents working with this codebase.

## Key Files

| File | Purpose |
|------|---------|
| `am` | Main entry point. Handles CLI args, routes to commands. |
| `lib/utils.sh` | Shared: colors, logging, time formatting, paths |
| `lib/registry.sh` | JSON storage for session metadata (`~/.agent-manager/sessions.json`) |
| `lib/tmux.sh` | tmux wrappers: create/kill/attach/capture sessions |
| `lib/agents.sh` | Agent lifecycle: launch, display formatting, kill |
| `lib/fzf.sh` | fzf UI: list generation, preview, main loop |

## Data Flow

```
am → fzf_main() → tmux_attach()
am new ~/project → agent_launch() → tmux_create_session() → registry_add() → tmux_send_keys()
```

## Key Functions

**Session lifecycle:**
- `agent_launch(dir, type, task)` - Creates session, registers, starts agent
- `agent_kill(name)` - Kills tmux + removes from registry

**Registry (JSON metadata):**
- `registry_add/get/update/remove/list` - CRUD for sessions.json
- `registry_gc()` - Remove entries for dead tmux sessions

**tmux:**
- `tmux_create_session(name, dir)` - New detached session
- `tmux_capture_pane(name, lines)` - Get terminal content for preview
- `tmux_get_activity(name)` - Last activity timestamp

**fzf:**
- `fzf_list_sessions()` - Format: `session|display_name`
- `lib/preview` - Standalone preview script for fzf panel
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
