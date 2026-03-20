# Backlog

## In Progress

## Up Next

- **Sandbox shell pane cosmetics** — two issues visible when a sandbox session starts:
  1. The `_am_sandbox_enter()` reconnect loop (from `sandbox_enter_cmd()` in `lib/sandbox.sh`) is pasted verbatim into the shell pane via `tmux send-keys`, showing a wall of escaped shell code. Could suppress by writing to a temp script and sourcing it, or using `tmux send-keys -l` with `clear` after.
  2. `~/.zshrc:bindkey:127/128: cannot bind to an empty key sequence` — host `.zshrc` has keybindings referencing terminal sequences not available in the container. Could add a sandbox-specific `.zshrc` via `am sb map` / preset-managed state, or wrap the bindkey calls in the host `.zshrc` with guards (`[[ -n "$key" ]] && bindkey ...`).

## Ideas

- **Web dashboard** — `am peek --follow` already has the snapshot/stream contract; a web UI could share the same model. The vision for the web UI is a full AM implementation on the web. with session switching, creating sessions, chatting with the agent and integrated shell. etc etc
- **Session tagging** — add labels/tags to sessions for filtering (`am list --tag debug`)
- **Session templates** — predefined launch configs (agent type + flags + prompt skeleton) for common workflows
- **Inter-session messaging** — structured message passing between sessions (beyond raw `am send`)
- **Auto-cleanup** — kill sessions that have been idle beyond a configurable threshold
- **MCP server for am** — expose launch/send/peek/list/kill as structured tools instead of CLI-over-bash; better for agents that don't have shell access
- **Speed issues** - opening the popup on mac can be pretty slow. Fix it
