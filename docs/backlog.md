# Backlog

## In Progress

## Up Next

- new sessions with --yolo default to sandbox and worktree. support for both launching from cli and from new session dialog

## Ideas

- **Web dashboard** — `am peek --follow` already has the snapshot/stream contract; a web UI could share the same model. The vision for the web UI is a full AM implementation on the web. with session switching, creating sessions, chatting with the agent and integrated shell. etc etc
- **Session tagging** — add labels/tags to sessions for filtering (`am list --tag debug`)
- **Session templates** — predefined launch configs (agent type + flags + prompt skeleton) for common workflows
- **Inter-session messaging** — structured message passing between sessions (beyond raw `am send`)
- **Auto-cleanup** — kill sessions that have been idle beyond a configurable threshold
- **MCP server for am** — expose launch/send/peek/list/kill as structured tools instead of CLI-over-bash; better for agents that don't have shell access
- **Speed issues** - opening the popup on mac can be pretty slow. Fix it
