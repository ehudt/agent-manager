# Backlog

## In Progress

- **Review follow-ups (2026-09-07)** — defects, daily-loop features, and the
  structural work (single ticker, Go-owned stores, agent adapter table,
  version canary). Tracked item by item in
  [plans/2026-09-07-review-followups.md](plans/2026-09-07-review-followups.md).

## Up Next

## Ideas

- **Web dashboard** — `am peek --follow` already has the snapshot/stream contract; a web UI could share the same model. The vision for the web UI is a full AM implementation on the web. with session switching, creating sessions, chatting with the agent and integrated shell. etc etc. State detection is the non-portable part (pane title + local process tree); see the architecture notes in the follow-ups plan.

## Known Issues

- **State detection edge transitions** — `_state_resolve` combines the shell
  process check, agent-maintained title status, canonical hook state, and
  Cursor's narrow Ready-footer refinement. Earlier pane classifiers flapped
  live sessions through `running`/`unknown`/`background`. Remaining edge:
  agents without reliable turn-boundary events still use the 180s running
  staleness gate. Use `am doctor <session>` first, `AM_STATE_DEBUG=1` for
  empirical data and `tests/live_lab/` for ground truth.

## Closed

- **Inactive sessions issues (session-id mismatch)** — closed in v0.21.0
  (5f7bd47): sessions are bound to their own pane and transcript; every
  directory-based guess was removed. History in
  [session-id-mismatch.md](session-id-mismatch.md).
- **Rename skill to agent-manager-dispatch** — done (`skills/agent-manager-dispatch/`).
