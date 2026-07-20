# Backlog

## In Progress

## Up Next

## Ideas

- **Inactive sessions issues (session-id mismatch)** - some inactive sessions from the same directory are mismatched with their session id - one session name restores a different session. Partially fixed (5ca0724, 6640867, f4541ff, sidecar-authoritative sids) but still reproduces sometimes (2026-07). Residual suspects, diagnostic-capture checklist for the next occurrence, and fix directions: see [session-id-mismatch.md](session-id-mismatch.md).

- **Replace docker vm with micro VM**

- **Rename skill to agent-manager-dispatch** and update the skill

- **Web dashboard** — `am peek --follow` already has the snapshot/stream contract; a web UI could share the same model. The vision for the web UI is a full AM implementation on the web. with session switching, creating sessions, chatting with the agent and integrated shell. etc etc

## Known Issues

- **State detection edge transitions** — the resolver is now title-glyph-first (`_state_resolve`: shell pane check → title glyph × hook state → gated hook fallback → unknown; 2026-07-10 redesign after the pane-heuristic layers were shown to flap live sessions through running/unknown/waiting_background). Remaining edges: agent crash / manual `Ctrl-C` mid-turn can leave a stale glyph or hook state until the shell check catches the dead process; the no-glyph fallback (titles disabled, non-Claude agents) still relies on the 180s staleness gate. Use `AM_STATE_DEBUG=1` for empirical data; `tests/live_lab/run.sh` for ground truth against a real Claude.

- **Backgrounded turns detach hook state (upstream)** — once a turn is backgrounded (ctrl-b), its lifecycle events fire from a bg session context (`stop_hook_summary` shows `sessionKind: bg`, different `session_id`) that doesn't resolve to the am session, so turn ends write nothing until the next foreground event (observed 2026-07-08, pink-wekapp session: state file frozen for 20+ min across 3 turn ends). Covered on the read side since 2026-07-10 by the title glyph: Claude flips the pane title to `✳` at the true turn end regardless of hook routing, and the resolver self-heals the leftover `running` file. A write-side fix (hook resolving bg-session events to the parent am session) is no longer needed for state correctness.

- **[medium] `_state_resolve` bulk vs non-bulk shell semantics diverge** — bulk path returns `idle` for any shell pane (status-bar visual convention); non-bulk path runs the full classifier and can return `starting` / `idle` / `dead`. If `am list --json` ever flips to the bulk path it'll mask `dead` as `idle`. Either reconcile the two models or assert the documented divergence with a test (the old agreement case, `tests/state_lab/cases/11-paths-agree.sh`, was deleted in the 476d563 resolver collapse — a fresh shell-pane agreement scenario is needed either way).
