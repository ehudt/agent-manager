# Backlog

## In Progress

## Up Next

## Ideas

- **Web dashboard** — `am peek --follow` already has the snapshot/stream contract; a web UI could share the same model. The vision for the web UI is a full AM implementation on the web. with session switching, creating sessions, chatting with the agent and integrated shell. etc etc

## Known Issues

### Sidebar shows `-` (idle) when hook state file is missing

**Symptom:** A session that is actually `waiting_input` (or any other state) renders
as `-` in the pane-border / status-right sidebar. `am list --json` reports the
correct state for the same session.

**Why it happens:** `lib/status-right` reads only `/tmp/am-state/<session>` (the
hook-written cache) for speed. The hook only writes that file when an event fires
— `Stop`, `Notification`, `UserPromptSubmit`, `PostToolUse`. For a session no one
has interacted with since the file was created (or for one whose file was deleted
or `/tmp` was cleared), no hook has fired and the file is missing. `_fast_state`
returns empty and the case falls through to the unknown branch that renders `-`.

`am list --json` does not have this gap because `_agent_get_state_fast` in
`lib/state.sh` falls back to JSONL parsing and pane-content inspection when the
hook state file is missing. Pane inspection also disambiguates the duplicate-
directory case (two am sessions whose `cwd` is the same git repo) since each
session has its own pane content.

**Workarounds today:**
- Interact with the session once (any keypress that triggers a hook) and the
  state file repopulates correctly via the `AM_SESSION_NAME` / `TMUX_PANE`
  routing fixed in `state-hook.sh`.
- Manually seed: `am list --json` to get the real state, then write it to
  `/tmp/am-state/<session>`.

**Possible fixes (not implemented):**
1. Have `status-right` source `state.sh` and call `_agent_get_state_fast` when
   `_fast_state` returns empty. Cost: a `tmux capture-pane` per affected session
   on every 5s status refresh — fine for 1–2 idle sessions, may add up with many.
   Consider gating on N (e.g. only fall back when fewer than 5 sessions need it).
2. Seed `/tmp/am-state/<session>` from `agent_launch` so a state file always
   exists for the session's lifetime. Covers new sessions only — does not help
   sessions that predate the change or sessions whose file is removed mid-life.
3. Have `am-list-internal` (or a periodic background job) write to the state
   file as a side effect of state computation. Always-fresh cache, but mixes
   responsibilities and creates a write path outside the hook.

Option 1 is the most principled — it makes `status-right` and `am list` agree
without splitting the source of truth — and is the recommended direction when
this issue is prioritized.
