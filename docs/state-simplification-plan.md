# State detection simplification — instrumentation phase

Captured 2026-05-14. Follow-up to `state-detection-plan.md` (Phases 1–3
already landed). Records what just landed, how to collect data, and what
to do with that data when deciding the next cut.

## What landed (2026-05-14)

| Change | File | Status |
|---|---|---|
| D-lite: single-path `_state_resolve`, builds size-1 fixtures when no bulk supplied | `lib/state.sh` | done |
| `_state_pane_is_shell` → thin shim over `_state_pane_is_shell_bulk` | `lib/state.sh` | done |
| `AM_STATE_DEBUG=1` instrumentation — every resolver return path tags source | `lib/state.sh` | done |
| `AM_HOOK_DEBUG=1` instrumentation — silent hook exits get logged | `lib/hooks/state-hook.sh` | done |
| lsof regex escapes `project_dir` metachars | `lib/state.sh:165` | done |
| Shared ps map across `_state_sid_from_pane_args` + `_state_sid_from_lsof` | `lib/state.sh` | done |
| `AGENTS.md` documents new env vars | `AGENTS.md` | done |

Tests: 576/576 pass on `./tests/test_all.sh --summary`. No semantic change
for status-bar (still treats any shell pane as `idle`; per-session
`agent_get_state` still runs full classifier).

## Step 1 — turn on instrumentation

Add to shell rc, then reopen any am sessions (env var must reach agent
panes via tmux):

```bash
export AM_STATE_DEBUG=1
export AM_HOOK_DEBUG=1
```

Verify both sinks exist after a few minutes of real use:

```bash
ls -la ~/.agent-manager/.state-debug.log ~/.agent-manager/.hook-debug.log
```

Format reminder:

```
.state-debug.log: <iso8601>\t<session>\t<agent>\t<source>\t<state>
.hook-debug.log:  <iso8601>\t<hook_type>\t<reason>
```

`<source>` is one of: `shell`, `classify_exit`, `hook`, `pane`, `jsonl`,
`fallback`.

## Step 2 — collect data

Run for at least 5 working days. Aim for a sample that covers:

- Fresh Claude sessions started after the change.
- At least one Codex session.
- At least one session where Claude crashed mid-tool (`Ctrl-C` while a
  bash tool is running) — exercises the running-stuck fallback that A
  would remove.
- At least one session that hit a permission prompt.
- At least one session that hit an elicitation dialog (`waiting_custom`).

Rotate the log if it crosses ~10 MB:

```bash
mv ~/.agent-manager/.state-debug.log ~/.agent-manager/.state-debug.log.1
mv ~/.agent-manager/.hook-debug.log ~/.agent-manager/.hook-debug.log.1
```

## Step 3 — analyze

Headline question: how often does each layer win? Cut layers that never
or rarely win.

```bash
# distribution of winning source
cut -f4 ~/.agent-manager/.state-debug.log | sort | uniq -c | sort -rn

# distribution of (source, state) pairs — finds which states each layer is
# actually responsible for
awk -F'\t' '{print $4, $5}' ~/.agent-manager/.state-debug.log | sort | uniq -c | sort -rn

# per-agent breakdown — Codex behavior may differ wildly from Claude
awk -F'\t' '{print $3, $4}' ~/.agent-manager/.state-debug.log | sort | uniq -c | sort -rn

# sessions where pane scan won — these are the cases A breaks if cut
awk -F'\t' '$4=="pane" {print $2, $5}' ~/.agent-manager/.state-debug.log | sort -u

# sessions where jsonl won — these are the cases B breaks
awk -F'\t' '$4=="jsonl" {print $2, $5}' ~/.agent-manager/.state-debug.log | sort -u

# hook silent exits — each line is a hook fire that produced no state
wc -l ~/.agent-manager/.hook-debug.log
cut -f2 ~/.agent-manager/.hook-debug.log | sort | uniq -c
```

## Step 4 — decision tree

Apply each rule in order. If the rule says "skip", that cut isn't safe
yet; move to the next.

### A — drop pane regex

- **Cut if:** `pane` rows are < 1% of total AND no `pane` row produced
  `waiting_permission` or `waiting_custom` for an agent that has hooks
  installed for those (Claude: yes; Codex: no `Notification` hook today
  so `waiting_custom` is pane-only).
- **Skip if:** any of:
  - Codex sessions in the sample produced `waiting_custom` via `pane`
    (Codex install in `scripts/install.sh` does not register a
    `Notification` hook, so pane is the only path).
  - More than a handful of `waiting_permission` decisions came from
    `pane` on Claude — would indicate the `permission_prompt`
    notification hook is unreliable.
- **Partial cut:** drop Claude pane regex, keep Codex pane regex. Adds
  an `if [[ "$agent_type" == "codex" ]]` branch but removes most of the
  drift surface.

### B — drop JSONL parsing

- **Cut if:** `jsonl` rows are < 0.5% AND no `jsonl` row produced
  `running` (the case where hooks went silent mid-tool).
- **Skip if:** `jsonl` rows show `running` for any session — that's the
  exact "agent crashed mid-tool, hooks silent" case JSONL still
  resolves. Removing it regresses observability for crash cases.
- **Bundled cleanup if cut:** also remove `_state_claude_session_id`,
  `_state_sid_from_pane_args*`, `_state_sid_from_lsof*`, sidecar writes
  in `state-hook.sh`, and `_state_pane_claude_pid`. ~150 lines.

### C — unified state file (status-bar writes idle/dead/starting)

- **Cut if:** the distribution shows `shell` and `classify_exit` are the
  dominant non-hook winners AND they cluster around predictable
  transitions (agent exit, manual kill) rather than random races.
- **Pre-write semantic:** pick one of the two rules before writing code:
  1. **Last writer wins.** Status-bar tick can clobber a fresh
     `waiting_input` if its write lands later. Risk: ms-scale mis-paints
     near transitions.
  2. **Status-bar writes only when file absent or shell is currently
     visible.** Hook writes only when shell is NOT visible. Codifies
     "shell wins" without abandoning the file as source of truth.
  Pick rule 2 unless data shows hook timing is robust enough for rule 1.
- **Skip if:** the data shows hook silent exits (`.hook-debug.log`) are
  common — that means hooks miss too often for status-bar to be the
  authority on non-hook states.

### Other backlog items to consider regardless of A/B/C

From `docs/backlog.md`:

- `flock` around `registry_update` — concurrency bug independent of
  state detection.
- Make 200-line JSONL scan cap configurable (`AM_JSONL_SCAN_MAX`).
- Add a shell-pane scenario to `tests/state_lab/cases/11-paths-agree.sh`
  — currently misses the bulk-vs-non-bulk shell divergence.

## Acceptance — when this phase is done

| # | Criterion |
|---|---|
| 1 | At least one week of `AM_STATE_DEBUG` data covering the scenarios in step 2 |
| 2 | Hook silent-exit log shows zero unexplained exits, or every exit reason is understood |
| 3 | Decision recorded for A / B / C — cut or skip, with the data slice that drove the choice |
| 4 | If any of A/B/C cut: PR lands with `state_lab` cases promoted/added so removed code stays removed |

## Reverting instrumentation

When the decision is made, decide whether to keep instrumentation:

- **Keep** — overhead is one var compare per resolver return when
  disabled. Useful for future debugging. Default-off env gate is cheap.
- **Remove** — only if the resolver gets cut down so far that the
  `_state_debug` calls become more code than the resolver itself.

Recommendation: keep. Cost is negligible; value on the next bug hunt is
high.
