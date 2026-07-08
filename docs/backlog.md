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

- **`waiting_input` can get permanently stuck after an `AskUserQuestion`-style pause, even while the agent is actively working** — `lib/hooks/state-hook.sh`'s race guard (`am_state=="running" && hook_type != UserPromptSubmit && current-file-state=="waiting_input"` → skip the write) exists to drop a slow trailing `PostToolUse` hook that arrives milliseconds after `Stop` already wrote `waiting_input` for the *same* turn boundary. But it also blocks legitimate new activity whenever a turn resumes without a fresh `UserPromptSubmit` — which is exactly what happens when the assistant calls `AskUserQuestion`: Claude Code appears to treat that pause as an end-of-turn `Stop` (writing `waiting_input`), and answering it resumes the same turn without ever firing `UserPromptSubmit`. Every subsequent `PreToolUse`/`PostToolUse` hook is then silently swallowed by the guard, pinning the session at `waiting_input` indefinitely, even during active tool-call work. Reproduced live and confirmed via `~/.agent-manager/.state-debug.log` (2026-07-08, session `am-80552c`: resolved `hook → waiting_input` continuously for minutes across dozens of tool calls after an `AskUserQuestion` round-trip). Likely fix: bound the guard to a short grace window after the `waiting_input` write (long enough to absorb the original late-hook race, short enough that genuine new activity after a pause still flips back to `running`) instead of suppressing unconditionally.

- **[medium] `registry_update` is not locked** — `lib/registry.sh:67` does read-mktemp-jq-mv on the shared `sessions.json` with no flock. Concurrent writers (auto-title scan, `agent_launch` racing a kill, future hot writers) can clobber unrelated fields. State-hook.sh was moved off the registry to a per-session sidecar (`$AM_STATE_DIR/<session>.sid`) which dodges this, but the general primitive still races. Wrap the read-modify-write in `flock` on a `.lock` sibling.

- **[medium] `_state_resolve` bulk vs non-bulk shell semantics diverge** — bulk path returns `idle` for any shell pane (status-bar visual convention); non-bulk path runs the full classifier and can return `starting` / `idle` / `dead`. `tests/state_lab/cases/11-paths-agree.sh` does not exercise a shell-pane scenario, so the agreement assertion misses this. If `am list --json` ever flips to the bulk path it'll mask `dead` as `idle`. Add a shell-pane scenario to case 11 and either reconcile the two models or assert the documented divergence.

- **[low] Lab harness reuses `$AM_REGISTRY` across `_run_scenario` calls in `11-paths-agree.sh`** — confirm nothing in registry leaks between scenarios (sid sidecars now live outside the registry, so the immediate concern is gone, but other fields like `task` could still cross-contaminate if added later).
