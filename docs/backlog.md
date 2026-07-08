# Backlog

## In Progress

## Up Next

## Ideas

- **Inactive sessions issues** - some inactive sessions from the same directory are mismatched with their session id - one session name restores a different session

- **Replace docker vm with micro VM**

- **Rename skill to agent-manager-dispatch** and update the skill

- **Web dashboard** — `am peek --follow` already has the snapshot/stream contract; a web UI could share the same model. The vision for the web UI is a full AM implementation on the web. with session switching, creating sessions, chatting with the agent and integrated shell. etc etc

## Known Issues

- **State detection not 100% robust** — status-bar/list states occasionally lag or misclassify. The resolver is now hooks-first (`_state_resolve`: shell pane check → hook state file → unknown), but edge transitions (agent crash, manual `Ctrl-C`, tool-call timeout) can leave a stale hook state or fall through to `unknown`. Add explicit crash/exit transitions. Use `AM_STATE_DEBUG=1` for empirical data.

- **Backgrounded turns detach hook state (upstream)** — once a turn is backgrounded (ctrl-b), its lifecycle events fire from a bg session context (`stop_hook_summary` shows `sessionKind: bg`, different `session_id`) that doesn't resolve to the am session, so turn ends write nothing until the next foreground event (observed 2026-07-08, pink-wekapp session: state file frozen for 20+ min across 3 turn ends). The end-of-turn pane classifier now compensates on the read side; a write-side fix would need the hook to resolve bg-session events to their parent am session (e.g. via TMUX_PANE, which bg contexts may not carry, or a cwd→session map tolerant of scratchpad cwds).

- **[medium] `registry_update` is not locked** — `lib/registry.sh:67` does read-mktemp-jq-mv on the shared `sessions.json` with no flock. Concurrent writers (auto-title scan, `agent_launch` racing a kill, future hot writers) can clobber unrelated fields. State-hook.sh was moved off the registry to a per-session sidecar (`$AM_STATE_DIR/<session>.sid`) which dodges this, but the general primitive still races. Wrap the read-modify-write in `flock` on a `.lock` sibling.

- **[medium] `_state_resolve` bulk vs non-bulk shell semantics diverge** — bulk path returns `idle` for any shell pane (status-bar visual convention); non-bulk path runs the full classifier and can return `starting` / `idle` / `dead`. `tests/state_lab/cases/11-paths-agree.sh` does not exercise a shell-pane scenario, so the agreement assertion misses this. If `am list --json` ever flips to the bulk path it'll mask `dead` as `idle`. Add a shell-pane scenario to case 11 and either reconcile the two models or assert the documented divergence.

- **[low] Lab harness reuses `$AM_REGISTRY` across `_run_scenario` calls in `11-paths-agree.sh`** — confirm nothing in registry leaks between scenarios (sid sidecars now live outside the registry, so the immediate concern is gone, but other fields like `task` could still cross-contaminate if added later).
