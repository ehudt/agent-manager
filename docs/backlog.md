# Backlog

## In Progress

## Up Next

## Ideas

- **remove shell fallback for go-implemented commands**

- **Inactive sessions issues** - some inactive sessions from the same directory are mismatched with their session id - one session name restores a different session

- **Replace docker vm with micro VM**

- **Rename skill to agent-manager-dispatch** and update the skill

- **Web dashboard** — `am peek --follow` already has the snapshot/stream contract; a web UI could share the same model. The vision for the web UI is a full AM implementation on the web. with session switching, creating sessions, chatting with the agent and integrated shell. etc etc

## Known Issues

- **State detection not 100% robust** — status-bar/list states occasionally lag or misclassify. Hooks-first path works for fresh Claude sessions but legacy sessions and edge transitions (agent crash, manual `Ctrl-C`, tool-call timeout) fall back to JSONL/pane-content heuristics that can stick on the previous state. Audit `_state_from_hook` → `_state_from_jsonl` → `_state_from_pane` priority and add explicit crash/exit transitions.

- **[medium] `registry_update` is not locked** — `lib/registry.sh:67` does read-mktemp-jq-mv on the shared `sessions.json` with no flock. Concurrent writers (auto-title scan, `agent_launch` racing a kill, future hot writers) can clobber unrelated fields. State-hook.sh was moved off the registry to a per-session sidecar (`$AM_STATE_DIR/<session>.sid`) which dodges this, but the general primitive still races. Wrap the read-modify-write in `flock` on a `.lock` sibling.

- **[medium] lsof regex doesn't escape `project_dir`** — `lib/state.sh:165` builds the sed pattern `^n(${project_dir}/[^/]+\.jsonl)$` with the path interpolated raw. `~/.claude/projects/...` contains literal `.` chars that act as regex wildcards. False positives in practice are vanishingly unlikely (path still has to align byte-for-byte) but it's a sharp edge. Escape with `sed 's/[][\.*^$/]/\\&/g'` before interpolation.

- **[medium] `_state_resolve` bulk vs non-bulk shell semantics diverge** — bulk path returns `idle` for any shell pane (status-bar visual convention); non-bulk path runs the full classifier and can return `starting` / `idle` / `dead`. `tests/state_lab/cases/11-paths-agree.sh` does not exercise a shell-pane scenario, so the agreement assertion misses this. If `am list --json` ever flips to the bulk path it'll mask `dead` as `idle`. Add a shell-pane scenario to case 11 and either reconcile the two models or assert the documented divergence.

- **[medium] Reverse-stream jsonl scan capped at 200 lines** — `lib/state.sh:182` re-reads the file reversed and stops after 200 lines. Survives today's metadata floods (file-history-snapshot / last-prompt / ai-title / attachment / system) but if a future Claude version dumps >200 metadata entries (e.g. session resume with large file-history-snapshot) the same class of bug returns. Make the cap configurable, scale with file size, or guarantee scan reaches the last `assistant`/`user`/`queue-operation` line.

- **[low] `_state_pane_claude_pid` builds full `ps` map per call** — `lib/state.sh:88-108` runs `ps -eo pid=,ppid=,comm=` once per call, and a single `_state_claude_session_id` invocation can call it twice (once via `_state_sid_from_pane_args`, once via `_state_sid_from_lsof`). Cache the map inside `_state_claude_session_id`, or have it build the map once and pass it down.

- **[low] state-hook.sh silently exits when `AM_SESSION_NAME` is set but missing from registry** — `lib/hooks/state-hook.sh:97` exits 0 with no log when the exported session name isn't in `sessions.json`. Correct behavior (don't fall through to cwd matching and clobber the wrong session) but invisible to debugging. Log to a hook debug file (`$AM_DIR/.hook-debug.log` gated by env flag) so vanished-session bugs aren't ghosts.

- **[low] Lab harness reuses `$AM_REGISTRY` across `_run_scenario` calls in `11-paths-agree.sh`** — confirm nothing in registry leaks between scenarios (sid sidecars now live outside the registry, so the immediate concern is gone, but other fields like `task` could still cross-contaminate if added later).
