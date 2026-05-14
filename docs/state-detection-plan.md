# State-detection plan

Pinning the open bugs and the consolidation plan that removes the
duplication letting these bugs hide. Captured 2026-05-13 after building
`tests/state_lab/` and observing two confirmed failures on a real session.

## Confirmed bugs

### Bug 1 — `_state_jsonl_path` picks the wrong Claude conversation

`_state_jsonl_path` returns the newest `*.jsonl` (by mtime) in the project
directory. When a Claude pane is attached to conversation A but a fresher
stub B (e.g. a sidechain or cancelled new session) exists in the same
project dir, B shadows A and state derivation operates on the wrong file.

- Repro: `tests/state_lab/cases/01-jsonl-newest-vs-active.sh` (XFAIL).
- Real-world hit: `am-6bb668` on 2026-05-13. Pane in
  `green-wekapp/0cf2837e` (end_turn → `waiting_input`); stub
  `green-wekapp/fe93abc7` had a newer mtime → reported `running`.

### Bug 2 — `_state_from_jsonl` only inspects `tail -20`

The function reads the last 20 lines, then greps for
`assistant|user|queue-operation`. If Claude appends 20+ metadata rows
(file-history-snapshot / last-prompt / ai-title / attachment / system)
after the last meaningful turn, the meaningful entry falls out of view and
state is reported as empty (caller falls back to pane, which may
default-to-running).

- Repro: `tests/state_lab/cases/05-jsonl-tail20-metadata-flood.sh` (XFAIL).
- Real-world hit: same `green-wekapp` jsonl had 8+ metadata rows after the
  last `end_turn`; lucky that the tail window still caught it.

## Current duplication map

State detection is implemented three times in bash:

| Implementation | File | Used by |
|---|---|---|
| `agent_get_state` | `lib/state.sh` | `am list --json`, `am wait`, agent-manager CLI |
| `_agent_get_state_fast` | `lib/state.sh` | internal lean variant (not currently called by anything outside state.sh itself — leftover) |
| `_fast_state` | `lib/status-bar` | tmux status-bar / sidebar render |

Plus inlined re-implementations in `status-bar` for performance:

- `_pane_is_shell_bulk` reimplements `_state_pane_is_shell` using a bulk
  `ps -eo` table shared across all sessions.
- `_hook_state_set` reimplements `_state_from_hook` to avoid the
  `$(...)` subshell.

Priority orders differ:

| Path | Order |
|---|---|
| `agent_get_state` | exists → shell → pane (permission/custom/dead/idle) → hook → JSONL → pane fallback |
| `_agent_get_state_fast` | shell → hook (non-running short-circuits) → JSONL (waiting_input short-circuits) → pane |
| status-bar `_fast_state` | hook (**short-circuits on ANY value**) → shell → JSONL → pane |

The status-bar variant short-circuiting on any hook value is the visible
"▸ in sidebar / ● in browser" divergence — a permission prompt painted
during a tool call is never seen.

The Go side (`cmd/am-list-internal`, `cmd/am-browse`) does **not** derive
state today; both consume the bash-formatted display string. So
divergence is bash-internal only — for now.

## Plan

### Phase 1 — fix the two bugs (lab pins regression contract)

1. **Resolve Claude conversation by session id, not by mtime.**
   Three signals, used in order:
   - **Hook payload (new sessions).** In `state-hook.sh`, extract
     `.session_id` from the Claude hook input and persist it to
     `sessions.json` (add a `claude_session_id` field). Covers every
     session opened after the fix lands.
   - **Pane child process (legacy sessions).** When the registry has no
     `claude_session_id` yet, walk the pane top-pid's children for
     `claude`, then `ps -o args` to extract any `--session-id <uuid>`
     argument. If found, cache it back into the registry.
   - **`lsof` on the pane PID tree (last resort, when args don't carry
     the id).** Intersect the project dir's jsonls with open file
     descriptors from the claude child. Cache once found.
   - Update `_state_jsonl_path` to prefer
     `~/.claude/projects/<encoded>/<claude_session_id>.jsonl` when known
     and fall back to "newest mtime" only when no id can be resolved.
     Mtime fallback stays only for sessions where every signal fails
     (e.g. headless agent crashes); flag it as a known limitation rather
     than silently mis-attributing state.
   - Promote both `01-jsonl-newest-vs-active.sh` and
     `01b-jsonl-newest-shadow-endturn.sh` from `lab_xfail` to
     `lab_assert`. The fix must clear both directions (running mistakenly
     reported as waiting_input, *and* waiting_input mistakenly reported
     as running).

2. **Read backwards until a meaningful line is found.**
   - Replace `tail -20 | grep -E '...'` with a reverse-stream pipeline.
     Use `tail -r` on macOS, `tac` on Linux; pin the implementation as
     `(tail -r 2>/dev/null || tac) < "$jsonl"` so the bash gymnastics
     don't drift back in during implementation.
   - Cap at, say, 200 lines via `head -n 200` after the reverse so cost
     stays bounded on huge files. 200 is well above the observed
     metadata-flood depth.
   - Promote case 05 from `lab_xfail` to `lab_assert`.

3. **Align status-bar's hook short-circuit with state.sh.**
   - One-line regex change. Land this as its own commit ahead of the
     bigger consolidation — it's the most visible user-facing win (kills
     the "▸ in sidebar / ● in browser" divergence).
   - In `lib/status-bar` `_fast_state`, short-circuit on hook value only
     when value is `waiting_input | waiting_permission | waiting_custom`.
     If hook says `running`, fall through to pane (so permission prompts
     during tool calls are caught).
   - Add `tests/state_lab/cases/10-statusbar-running-with-permission.sh`
     to lock this in (requires lab to source status-bar's helpers, not
     just lib/state.sh — see Phase 3).

### Phase 2 — single implementation, two access patterns

Goal: one definition of "given (session, agent_type, dir, optional bulk
data), return state". Two call sites: one-shot (`agent_get_state`) and
bulk (status-bar).

1. Define a single `_state_resolve` in `lib/state.sh` that takes per-
   session inputs **and** optional pre-fetched bulk data (top pid,
   process table, hook content/mtime). When bulk is absent, fetch
   per-session inline. When present, use the supplied values.
   Prototype the signature on one call site before rolling it out —
   bash doesn't pass associative arrays cleanly, and the current bulk
   inlining in status-bar exists for fork-cost reasons that must not
   regress. Likely shape: pass bulk fixtures by name (`local -n` /
   nameref) rather than by value.

2. `agent_get_state` becomes a thin wrapper:
   ```
   agent_get_state(session) {
       tmux_session_exists $session || { echo dead; return; }
       _state_resolve $session  # no bulk inputs
   }
   ```

3. `lib/status-bar` builds the bulk data once (current behavior), then
   loops calling `_state_resolve` with the bulk inputs for each session.
   `_fast_state`, `_pane_is_shell_bulk`, `_hook_state_set` all collapse
   into one path.

4. Delete `_agent_get_state_fast` — unused after wrapper refactor.

### Phase 3 — make the lab a CI gate for both paths

The lab currently exercises `lib/state.sh`. After Phase 2, status-bar
shares the same function — but to lock that in, refactor status-bar to
source the new `_state_resolve` and bulk helpers from `lib/state.sh`
(rather than redefining them inline). The lab's bulk variant simply
prepares the bulk fixtures and calls the same function.

Add a case that runs all 9 existing cases through both call paths and
asserts identical output. Concretely:
- `case 11-paths-agree.sh`: for every probe scenario, call both
  `agent_get_state` and the status-bar path; `lab_assert` they agree.

Wire `tests/state_lab/run.sh` into `tests/test_all.sh`.

### Phase 4 — secondary cleanups (optional, follow-up)

- Promote `_state_jsonl_path` to use `AM_CLAUDE_DIR` (defaulting to
  `$HOME/.claude`) so the lab doesn't have to override `HOME`. Removes a
  source of flakiness for cases that need real Claude paths.
- Fix the `dup-cwd` ambiguity (case 09) by writing all matching sessions
  rather than the first, or by refusing to write when ambiguous. Trade-
  off: silent miss vs. clobber. Decide once we see a real-world hit; for
  now the case just pins current behavior.
- Port `_state_resolve` to Go in `internal/sessions/state.go` when/if
  `am-list-internal` starts emitting state in its output (it currently
  doesn't, which is why the divergence between Go list and bash
  `am list --json` exists only at the bash layer).

## Acceptance

Done when:

1. All 9 `tests/state_lab/cases/*.sh` pass (no XFAILs).
2. New case `10-statusbar-running-with-permission.sh` passes.
3. New case `11-paths-agree.sh` passes.
4. `lib/state.sh` exports exactly one state-resolution function.
5. `lib/status-bar` contains no copy of pane/hook/jsonl logic — only bulk
   data prep and presentation.
6. `tests/test_all.sh` runs the lab cases.
