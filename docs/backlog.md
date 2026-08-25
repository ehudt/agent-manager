# Backlog

## In Progress

## Up Next

## Ideas

- **Inactive sessions issues (session-id mismatch)** - some inactive sessions from the same directory are mismatched with their session id - one session name restores a different session. Partially fixed (5ca0724, 6640867, f4541ff, sidecar-authoritative sids) but still reproduces sometimes (2026-07). Residual suspects, diagnostic-capture checklist for the next occurrence, and fix directions: see [session-id-mismatch.md](session-id-mismatch.md).

- **Replace docker vm with micro VM**

- **Rename skill to agent-manager-dispatch** and update the skill

- **Web dashboard** — `am peek --follow` already has the snapshot/stream contract; a web UI could share the same model. The vision for the web UI is a full AM implementation on the web. with session switching, creating sessions, chatting with the agent and integrated shell. etc etc

## Known Issues

- **State detection edge transitions** — `_state_resolve` combines the shell
  process check, agent-maintained title status, canonical hook state, and
  Cursor's narrow Ready-footer refinement. Earlier pane classifiers flapped
  live sessions through `running`/`unknown`/`background`. Remaining edge:
  agents without reliable turn-boundary events still use the 180s running
  staleness gate. Use `AM_STATE_DEBUG=1` for empirical data and
  `tests/live_lab/` for ground truth.

