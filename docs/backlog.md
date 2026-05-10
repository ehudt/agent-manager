# Backlog

## In Progress

## Up Next

## Ideas

- **Web dashboard** — `am peek --follow` already has the snapshot/stream contract; a web UI could share the same model. The vision for the web UI is a full AM implementation on the web. with session switching, creating sessions, chatting with the agent and integrated shell. etc etc

## Known Issues

- **Task detection misses live sessions** — status-bar tabs show `∅` for sessions whose registry `task` field was never populated, even when the session has an active conversation with a clear topic. `auto_title_scan` should backfill from the agent pane title or the Claude JSONL first user message; investigate why long-running sessions still have empty `task`. Reproducer: existing sessions created before auto-titling existed, or any bash session.
- **State detection not 100% robust** — status-bar/list states occasionally lag or misclassify. Hooks-first path works for fresh Claude sessions but legacy sessions and edge transitions (agent crash, manual `Ctrl-C`, tool-call timeout) fall back to JSONL/pane-content heuristics that can stick on the previous state. Audit `_state_from_hook` → `_state_from_jsonl` → `_state_from_pane` priority and add explicit crash/exit transitions.
