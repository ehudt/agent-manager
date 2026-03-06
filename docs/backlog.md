# Backlog

## In Progress


## Up Next

- **`am install` command** — automate first-time setup:
  - Symlink `skills/am-orchestration/` into `~/.claude/skills/` for Claude Code discovery
  - Verify dependencies (tmux, fzf, jq, git)
  - Create `~/.agent-manager/` and default config
  - Optionally set up tmux plugin (source am's tmux config)
- **Completion detection** — structured way to know if an agent session's task is done (idle pane heuristic, exit code capture, or explicit signal file in `$AM_LOG_DIR`)
- **MCP server for am** — expose launch/send/peek/list/kill as structured tools instead of CLI-over-bash; better for agents that don't have shell access
- **Speed issues** - opening the popup on mac can be pretty slow. Fix it
- **Detach mode doesn't trigger agent** - it pastes the prompt but doesn't send the Enter
- **New session form** - select box in multi-select style (see all options all the time)
- **New session form** - toggle multi select options with left/right arrow keys
- **New session form** - directory selector - allow scrolling down/up for more options

## Ideas

- **Web dashboard** — `am peek --follow` already has the snapshot/stream contract; a web UI could share the same model
- **Session tagging** — add labels/tags to sessions for filtering (`am list --tag debug`)
- **Session templates** — predefined launch configs (agent type + flags + prompt skeleton) for common workflows
- **Inter-session messaging** — structured message passing between sessions (beyond raw `am send`)
- **Auto-cleanup** — kill sessions that have been idle beyond a configurable threshold
