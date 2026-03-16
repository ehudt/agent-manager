# Backlog

## In Progress

- **Codex launch prompt via stdin is broken** — `printf '...\n' | am new --detach --print-session <dir>` currently fails for Codex sessions with `Error: stdin is not a terminal`, so the initial prompt never reaches the agent. Reproduced on 2026-03-16 while launching three `compression-autoresearch` workers from `/home/ehud/code/compression`.
- **`am send` does not reliably submit prompts to sandboxed Codex TUI** — with `am new --detach --print-session --yolo --sandbox <dir>`, a follow-up `am send --wait <session> "..."` pastes text into the Codex input area but leaves the session in `waiting_input` without an assistant turn. Reproduced on 2026-03-16 in sandboxed sessions `am-99e39c`, `am-986733`, and `am-05ad60`; `am peek --json` showed the pasted prompt in the TUI and no response.

## Up Next

## Ideas

- **Web dashboard** — `am peek --follow` already has the snapshot/stream contract; a web UI could share the same model. The vision for the web UI is a full AM implementation on the web. with session switching, creating sessions, chatting with the agent and integrated shell. etc etc
- **Session tagging** — add labels/tags to sessions for filtering (`am list --tag debug`)
- **Session templates** — predefined launch configs (agent type + flags + prompt skeleton) for common workflows
- **Inter-session messaging** — structured message passing between sessions (beyond raw `am send`)
- **Auto-cleanup** — kill sessions that have been idle beyond a configurable threshold
- **MCP server for am** — expose launch/send/peek/list/kill as structured tools instead of CLI-over-bash; better for agents that don't have shell access
- **Speed issues** - opening the popup on mac can be pretty slow. Fix it
