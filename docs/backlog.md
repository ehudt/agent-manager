# Backlog

## In Progress

## Up Next

## Ideas

- **Web dashboard** — `am peek --follow` already has the snapshot/stream contract; a web UI could share the same model. The vision for the web UI is a full AM implementation on the web. with session switching, creating sessions, chatting with the agent and integrated shell. etc etc

## Known Issues

- **Orphan registry rows** — `sessions.json` keeps entries whose tmux session is gone (observed: 3 rows on `agent-manager` socket pointing to nonexistent sessions). `registry_gc` runs on the fzf-fallback path but not on the Go TUI path, so rows accumulate.  Reap from `LoadEntries` (Go) or on session-kill hook.
- **State detection not 100% robust** — status-bar/list states occasionally lag or misclassify. Hooks-first path works for fresh Claude sessions but legacy sessions and edge transitions (agent crash, manual `Ctrl-C`, tool-call timeout) fall back to JSONL/pane-content heuristics that can stick on the previous state. Audit `_state_from_hook` → `_state_from_jsonl` → `_state_from_pane` priority and add explicit crash/exit transitions.
